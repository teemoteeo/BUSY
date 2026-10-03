import SwiftUI
import AppKit
import Charts

enum RecapPeriod: String, CaseIterable, Identifiable {
    case day = "Giorno", week = "Settimana", month = "Mese", year = "Anno"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}

struct RecapView: View {
    // Niente @ObservedObject: il recap si aggiorna ogni 30 s, non a ogni campione.
    let sampler: Sampler
    @State private var period: RecapPeriod = .day
    /// Una data qualsiasi dentro il periodo mostrato.
    @State private var anchor = Date()
    @State private var recap = Recap()
    @State private var errorMessage: String?
    /// App o dominio scelto nella Top 10: tutto il Recap mostra solo quello.
    @State private var focus: String?
    /// Periodo a cui appartiene `recap`. Finché non coincide con quello scelto, grafici
    /// e timeline restano invisibili: altrimenti per un attimo disegnano i dati del
    /// periodo precedente nel formato nuovo (es. un mese solo come barra gigante).
    @State private var loadedKey: String?
    private var key: String { "\(period.rawValue)-\(interval.start.timeIntervalSince1970)-\(focus ?? "")" }
    @State private var daySegments: [TimelineSegment] = []

    private static let italian = Locale(identifier: "it_IT")
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // settimana da lunedì
        calendar.locale = Self.italian
        return calendar
    }

    private var interval: DateInterval {
        calendar.dateInterval(of: period.component, for: anchor)
            ?? DateInterval(start: calendar.startOfDay(for: anchor), duration: 86_400)
    }
    private var isCurrentPeriod: Bool { interval.contains(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let focus {
                            appHeader(focus)
                        } else {
                            HStack(alignment: .top, spacing: 32) {
                                StatCard(category: .green, seconds: recap.totals.green,
                                         percentage: recap.totals.percentage(.green))
                                StatCard(category: .red, seconds: recap.totals.red,
                                         percentage: recap.totals.percentage(.red))
                            }
                        }
                        if focus == nil {
                            HStack(spacing: 16) {
                                LegendChip(category: .paused, seconds: recap.totals.paused)
                                LegendChip(category: .unknown, seconds: recap.totals.unclassified)
                            }
                        }
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(Theme.red) }
                    section("Timeline") {
                        CompactTimelineView(segments: recap.segments, height: 28, period: period)
                            .opacity(loadedKey == key ? 1 : 0)
                    }
                    breakdown.opacity(loadedKey == key ? 1 : 0)
                    if focus == nil { section("Top 10 per tempo speso") {
                        if recap.activities.isEmpty {
                            Text("Nessuna sessione nell'intervallo.").foregroundStyle(.secondary)
                        }
                        VStack(spacing: Theme.rowSpacing) {
                            ForEach(Array(recap.activities.prefix(10))) { entry in
                                Button { focus = entry.id.name } label: {
                                    ActivityRow(entry: entry, longest: recap.activities.first?.seconds ?? 1,
                                                nameWidth: 180)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Statistiche di \(AppName.display(entry.id.name))")
                            }
                        }
                    } }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 580)
        .environment(\.locale, Self.italian)
        .task(id: key) {
            // Sul periodo in corso si aggiorna da solo (giorno e settimana ogni 30 s, mese e
            // anno ogni 2 min: rileggono molti più dati); i periodi passati non cambiano.
            repeat {
                await refresh()
                try? await Task.sleep(for: .seconds(period == .day || period == .week ? 30 : 120))
            } while !Task.isCancelled && isCurrentPeriod
        }
        .onReceive(sampler.$isReady.dropFirst()) { _ in Task { await refresh() } }
        .onReceive(sampler.$rulesVersion.dropFirst()) { _ in Task { await refresh() } }
    }

    // MARK: Singola app

    private func appHeader(_ name: String) -> some View {
        let category = recap.activities.first?.id.category
        let used = recap.totals.recorded - recap.totals.paused
        let usedDays = recap.days.filter { $0.totals.recorded - $0.totals.paused > 0 }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if let icon = AppName.icon(name) { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "globe").resizable().foregroundStyle(.secondary) }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(AppName.display(name)).font(.title3.bold())
                    if let category {
                        Text(category == .green ? "Verde" : category == .red ? "Rosso" : category.title)
                            .font(.caption).foregroundStyle(category.color)
                    }
                }
                Spacer()
                Button("Tutte le app") { focus = nil }.buttonStyle(.link)
            }
            HStack(alignment: .top, spacing: 32) {
                stat("Totale", Totals.duration(used))
                if period == .day {
                    stat("Prima volta", recap.segments.first.map { $0.start.formatted(date: .omitted, time: .shortened) } ?? "—")
                    stat("Ultima volta", recap.segments.last.map { $0.end.formatted(date: .omitted, time: .shortened) } ?? "—")
                } else {
                    stat("Media nei giorni d'uso", Totals.duration(usedDays > 0 ? used / Double(usedDays) : 0))
                    stat("Giorni d'uso", "\(usedDays) su \(recap.days.count)")
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(isCurrentPeriod)
            Text(title).font(.title2.bold()).lineLimit(1)
            if !isCurrentPeriod {
                Button(period == .day ? "Oggi" : "Attuale") { anchor = Date() }
                    .buttonStyle(.link)
            }
            Spacer()
            Picker("", selection: $period) {
                ForEach(RecapPeriod.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var title: String {
        let it = Self.italian
        let start = interval.start
        switch period {
        case .day:
            if calendar.isDateInToday(start) { return "Oggi" }
            if calendar.isDateInYesterday(start) { return "Ieri" }
            return start.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(it)).capitalized
        case .week:
            let last = interval.end.addingTimeInterval(-1)
            return "\(start.formatted(.dateTime.day().month(.abbreviated).locale(it))) – \(last.formatted(.dateTime.day().month(.abbreviated).year().locale(it)))"
        case .month:
            return start.formatted(.dateTime.month(.wide).year().locale(it)).capitalized
        case .year:
            return start.formatted(.dateTime.year().locale(it))
        }
    }

    private func move(_ step: Int) {
        guard let next = calendar.date(byAdding: period.component, value: step, to: interval.start),
              next <= Date() else { return }
        anchor = next
    }

    private func open(_ newPeriod: RecapPeriod, at date: Date) {
        period = newPeriod
        anchor = date
    }

    // MARK: Breakdown

    /// Settimana: una riga per giorno con la sua barra 06→06 e le ore. Mese: calendario.
    /// Anno: barre impilate per mese. Clic: apre quel giorno o quel mese.
    @ViewBuilder private var breakdown: some View {
        switch period {
        case .day:
            EmptyView()
        case .month:
            section("Per giorno") { monthCalendar }
        case .week:
            section("Per giorno") {
                VStack(spacing: 6) {
                    dayRowLayout(Text(""), DayPartLabels(), green: "Verde", red: "Rosso")
                        .font(.caption2).foregroundStyle(.secondary)
                    ForEach(recap.days) { day in
                        Button { open(.day, at: day.id) } label: {
                            dayRowLayout(
                                Text(day.id.formatted(.dateTime.weekday(.abbreviated).day().locale(Self.italian)).capitalized),
                                DayBar(segments: daySegments, window: DayBar.window(for: day.id),
                                       height: 8, showsLabels: false),
                                green: Totals.duration(day.totals.green),
                                red: Totals.duration(day.totals.red))
                            .font(.callout)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(day.id > Date())
                    }
                }
            }
        case .year:
            section("Per mese") {
                MonthChart(rows: monthTotals.map { ($0.month, $0.totals) }) { open(.month, at: $0) }
            }
        }
    }

    /// Mese come un calendario largo quanto la pagina: ogni giorno è un pallino (vedi DayDot).
    /// Clic: apre il giorno. Al passaggio del mouse, le ore.
    private var monthCalendar: some View {
        let first = interval.start
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
        // Caselle vuote prima del primo giorno: la settimana parte da lunedì.
        let offset = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let totals = Dictionary(recap.days.map { ($0.id, $0.totals) }, uniquingKeysWith: { a, _ in a })
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(["L", "M", "M", "G", "V", "S", "D"].enumerated()), id: \.offset) { _, name in
                Text(name).font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 1) }
            ForEach(days, id: \.self) { day in
                let dayTotals = totals[day] ?? Totals()
                Button { open(.day, at: day) } label: {
                    VStack(spacing: 2) {
                        DayDot(green: dayTotals.green, red: dayTotals.red, total: dayTotals.recorded).frame(width: 28, height: 28)
                        Text("\(calendar.component(.day, from: day))").font(.caption2).monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(day > Date())
                .opacity(day > Date() ? 0.4 : 1)
                .help("Verde \(Totals.duration(dayTotals.green)) · Rosso \(Totals.duration(dayTotals.red))")
            }
        }
    }

    private func dayRowLayout(_ label: Text, _ bar: some View, green: String, red: String) -> some View {
        HStack(spacing: 10) {
            label.frame(width: 64, alignment: .leading)
            bar
            Text(green).frame(width: 58, alignment: .trailing)
            Text(red).frame(width: 58, alignment: .trailing)
        }
        .monospacedDigit()
    }

    private struct MonthTotal: Identifiable {
        var id: Date { month }
        let month: Date
        var totals = Totals()
    }

    private var monthTotals: [MonthTotal] {
        var result: [MonthTotal] = []
        for day in recap.days {
            guard let month = calendar.dateInterval(of: .month, for: day.id)?.start else { continue }
            if result.last?.month != month { result.append(MonthTotal(month: month)) }
            let t = day.totals
            result[result.count - 1].totals.add(t.green, category: .green)
            result[result.count - 1].totals.add(t.red, category: .red)
            result[result.count - 1].totals.add(t.paused, category: .paused)
            result[result.count - 1].totals.add(t.unclassified, category: .unknown)
        }
        return result
    }

    @MainActor private func refresh() async {
        guard sampler.isReady else { return }
        let now = Date()
        let requested = interval
        let end = min(requested.end, now)
        let requestedKey = key
        guard requested.start < end else { recap = Recap(); loadedKey = requestedKey; return }
        do {
            let requestedFocus = focus
            let result = try await sampler.recap(from: requested.start, to: end, only: requestedFocus)
            // Righe 06→06 della settimana: dalle 06 del primo giorno alle 06 dopo l'ultimo.
            let window: DateInterval? = period == .week
                ? DateInterval(start: DayBar.window(for: requested.start).start,
                               end: DayBar.window(for: requested.end.addingTimeInterval(-1)).end)
                : nil
            var barSegments: [TimelineSegment] = []
            if let window, window.start < min(window.end, now) {
                barSegments = try await sampler.recap(from: window.start, to: min(window.end, now),
                                                      only: requestedFocus).segments
            }
            // Una risposta lenta non deve sovrascrivere il periodo appena selezionato.
            guard requested == interval, requestedFocus == focus else { return }
            recap = result
            loadedKey = requestedKey
            daySegments = barSegments
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Anno: barre impilate verde/rosso per mese. Clic apre il mese, il mouse mostra le ore.
/// Vista a sé: lo stato del mouse ridisegna solo il grafico, non tutto il Recap.
private struct MonthChart: View {
    let rows: [(Date, Totals)]
    let open: (Date) -> Void
    @State private var hover: String?

    private struct BarValue: Identifiable {
        var id: String { "\(date.timeIntervalSince1970)-\(category.rawValue)" }
        let date: Date
        let category: Category
        let hours: Double
    }

    private func month(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> Date? {
        guard let plot = proxy.plotFrame,
              let date: Date = proxy.value(atX: location.x - geo[plot].origin.x) else { return nil }
        return Calendar.current.dateInterval(of: .month, for: date)?.start
    }

    var body: some View {
        let values = rows.flatMap { date, totals in
            [BarValue(date: date, category: .green, hours: totals.green / 3600),
             BarValue(date: date, category: .red, hours: totals.red / 3600)]
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(hover ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Chart(values) { value in
                BarMark(x: .value("Mese", value.date, unit: .month),
                        y: .value("Ore", value.hours),
                        width: .ratio(0.55))
                    .foregroundStyle(by: .value("Categoria", value.category.title))
                    .opacity(0.85)
            }
            .chartForegroundStyleScale([Category.green.title: Theme.green, Category.red.title: Theme.red])
            .chartLegend(.hidden)
            // Scala ridotta al minimo: due valori a destra, niente griglia.
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text("\(hours, specifier: "%.0f")h").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                        .font(.caption2)
                        // Color.primary, non .primary: nel grafico .primary prende il colore d'accento (blu).
                        .foregroundStyle(Color.primary)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            if let start = month(at: location, proxy: proxy, geo: geo), start <= Date() { open(start) }
                        }
                        .onContinuousHover { phase in
                            guard case .active(let location) = phase,
                                  let start = month(at: location, proxy: proxy, geo: geo),
                                  let totals = rows.first(where: { $0.0 == start })?.1 else {
                                hover = nil
                                return
                            }
                            let label = start.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "it_IT")))
                            hover = "\(label.capitalized) · Verde \(Totals.duration(totals.green)) · Rosso \(Totals.duration(totals.red))"
                        }
                }
            }
            .frame(height: 80)
        }
    }
}

/// Mostra "Claude" invece di "com.anthropic.claudefordesktop". I domini restano invariati.
enum AppName {
    private static var cache: [String: String] = [:]
    static func display(_ identifier: String) -> String {
        if let cached = cache[identifier] { return cached }
        var name = identifier
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
        }
        cache[identifier] = name
        return name
    }

    private static var icons: [String: NSImage?] = [:]
    /// Icona dell'app; nil per i domini e le app non più installate.
    static func icon(_ identifier: String) -> NSImage? {
        if let cached = icons[identifier] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[identifier] = icon
        return icon
    }
}
