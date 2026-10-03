import SwiftUI
import AppKit

/// Scheda di un'app o di un sito: tutto in una pagina, sugli ultimi 30 giorni.
/// Niente scelta di periodo: i numeri chiave, l'andamento per giorno, le ore in cui
/// la usi e le sessioni stanno insieme.
struct AppStatsView: View {
    let sampler: Sampler
    /// Bundle ID o dominio.
    let name: String
    let back: () -> Void

    private static let dayCount = 30
    private static let sessionGap: TimeInterval = 5 * 60
    private static let italian = Locale(identifier: "it_IT")

    struct Stats {
        var days: [DailyTotal] = []
        var category: Category?
        /// Tempo per ora del giorno sui 30 giorni, indice 0 = 06:00.
        var hours = [TimeInterval](repeating: 0, count: 24)
        var sessions = 0
        var longest: TimeInterval = 0
        var lastUse: Date?

        static func used(_ totals: Totals) -> TimeInterval { totals.recorded - totals.paused }
        var total: TimeInterval { days.reduce(0) { $0 + Self.used($1.totals) } }
        var usedDays: Int { days.filter { Self.used($0.totals) > 0 }.count }
    }

    @State private var stats: Stats?
    @State private var errorMessage: String?

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // settimana da lunedì
        return calendar
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                Button(action: back) { Label("Indietro", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                header
                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.red) }
                if let stats {
                    if stats.total == 0 {
                        Text("Nessun uso negli ultimi 30 giorni.").foregroundStyle(.secondary)
                    } else {
                        content(stats)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 580)
        .environment(\.locale, Self.italian)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ActivityIcon(name: name).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppName.display(name)).font(.title2.bold())
                HStack(spacing: 6) {
                    if let category = stats?.category {
                        Text(category.title).foregroundStyle(category.color)
                    }
                    if AppName.display(name) != name { Text(name).foregroundStyle(.tertiary) }
                }
                .font(.caption)
            }
        }
    }

    private func content(_ stats: Stats) -> some View {
        let color = stats.category?.color ?? Theme.unknown
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? .distantPast
        let week = stats.days.filter { $0.id >= weekStart }.reduce(0) { $0 + Stats.used($1.totals) }
        let today = stats.days.last.map { Stats.used($0.totals) } ?? 0
        let average = stats.usedDays > 0 ? stats.total / Double(stats.usedDays) : 0
        return VStack(alignment: .leading) {
            HStack(alignment: .top, spacing: 32) {
                stat("Oggi", Totals.duration(today))
                stat("Questa settimana", Totals.duration(week))
                stat("Ultimi 30 giorni", Totals.duration(stats.total))
                stat("Media al giorno", Totals.duration(average), note: "nei \(stats.usedDays) giorni d'uso")
            }
            TitledSection("Ultimi 30 giorni") { DailyChart(days: stats.days) }
            TitledSection("Quando la usi") { HourChart(hours: stats.hours, color: color) }
            TitledSection("Sessioni") {
                HStack(alignment: .top, spacing: 32) {
                    stat("Sessioni", "\(stats.sessions)", small: true)
                    stat("Durata media", Totals.duration(stats.sessions > 0 ? stats.total / Double(stats.sessions) : 0), small: true)
                    stat("Più lunga", Totals.duration(stats.longest), small: true)
                    stat("Ultimo uso", stats.lastUse.map(lastUseText) ?? "—", small: true)
                }
                Text("Una sessione finisce dopo 5 minuti senza usarla.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func lastUseText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Oggi, \(time)" }
        if calendar.isDateInYesterday(date) { return "Ieri, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Self.italian)) + ", \(time)"
    }

    private func stat(_ label: String, _ value: String, note: String? = nil, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(small ? .title3 : .title2).monospacedDigit()
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    // MARK: Dati

    @MainActor private func load() async {
        let now = Date()
        guard let start = calendar.date(byAdding: .day, value: -(Self.dayCount - 1), to: calendar.startOfDay(for: now)) else { return }
        do {
            let recap = try await sampler.recap(from: start, to: now, only: name)
            stats = Self.stats(from: recap, calendar: calendar)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    static func stats(from recap: Recap, calendar: Calendar) -> Stats {
        var result = Stats(days: recap.days, category: recap.activities.first?.id.category)
        var sessionEnd: Date?
        var sessionLength: TimeInterval = 0
        for segment in recap.segments where segment.category != .paused {
            // Sessioni: segmenti a meno di 5 minuti l'uno dall'altro sono la stessa.
            if let end = sessionEnd, segment.start.timeIntervalSince(end) <= sessionGap {
                sessionLength += segment.end.timeIntervalSince(segment.start)
            } else {
                result.sessions += 1
                sessionLength = segment.end.timeIntervalSince(segment.start)
            }
            result.longest = max(result.longest, sessionLength)
            sessionEnd = max(sessionEnd ?? segment.end, segment.end)
            // Ore del giorno, a fette di un'ora: 06 in testa come nelle barre 06→06.
            var t = segment.start
            while t < segment.end {
                let hourEnd = min(segment.end, calendar.dateInterval(of: .hour, for: t)?.end ?? segment.end)
                result.hours[(calendar.component(.hour, from: t) + 18) % 24] += hourEnd.timeIntervalSince(t)
                t = hourEnd
            }
        }
        result.lastUse = sessionEnd
        return result
    }
}

/// Una colonna per giorno, verde/rosso/grigio impilati. Il mouse mostra data e ore.
private struct DailyChart: View {
    let days: [DailyTotal]
    @State private var hover: Int?

    var body: some View {
        let longest = days.map { AppStatsView.Stats.used($0.totals) }.max() ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text(hoverText ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geo in
                let step = geo.size.width / CGFloat(max(1, days.count))
                Canvas { context, size in
                    for (index, day) in days.enumerated() {
                        let x = CGFloat(index) * step
                        let width = max(1, step - 3)
                        let used = AppStatsView.Stats.used(day.totals)
                        guard used > 0, longest > 0 else {
                            context.fill(Path(CGRect(x: x, y: size.height - 1, width: width, height: 1)),
                                         with: .color(Theme.track))
                            continue
                        }
                        var y = size.height
                        let height = max(2, size.height * CGFloat(used / longest))
                        for (value, color) in [(day.totals.green, Theme.green), (day.totals.unclassified, Theme.unknown),
                                               (day.totals.red, Theme.red)] where value > 0 {
                            let h = height * CGFloat(value / used)
                            y -= h
                            context.fill(Path(CGRect(x: x, y: y, width: width, height: h)),
                                         with: .color(color.opacity(hover == nil || hover == index ? 1 : 0.5)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase, step > 0 {
                        hover = min(days.count - 1, max(0, Int(point.x / step)))
                    } else { hover = nil }
                }
            }
            .frame(height: 90)
            HStack {
                if let first = days.first?.id {
                    Text(first.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "it_IT"))))
                }
                Spacer()
                Text("Oggi")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var hoverText: String? {
        guard let hover, days.indices.contains(hover) else { return nil }
        let day = days[hover]
        let date = day.id.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Locale(identifier: "it_IT")))
        return "\(date.capitalized) · \(Totals.duration(AppStatsView.Stats.used(day.totals)))"
    }
}

/// Le 24 ore dalle 06 alle 06: più è pieno il colore, più l'hai usata in quell'ora.
private struct HourChart: View {
    let hours: [TimeInterval]
    let color: Color
    @State private var hover: Int?

    var body: some View {
        let longest = hours.max() ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text(hoverText ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geo in
                let step = geo.size.width / 24
                Canvas { context, size in
                    for (index, value) in hours.enumerated() {
                        let rect = CGRect(x: CGFloat(index) * step, y: 0, width: max(1, step - 2), height: size.height)
                        let path = Path(roundedRect: rect, cornerRadius: 3)
                        context.fill(path, with: .color(Theme.track))
                        if value > 0, longest > 0 {
                            context.fill(path, with: .color(color.opacity(0.15 + 0.85 * value / longest)))
                        }
                        if hover == index { context.stroke(path, with: .color(.primary.opacity(0.5)), lineWidth: 1) }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase, step > 0 {
                        hover = min(23, max(0, Int(point.x / step)))
                    } else { hover = nil }
                }
            }
            .frame(height: 22)
            DayPartLabels()
        }
    }

    private var hoverText: String? {
        guard let hover else { return nil }
        let start = (hover + 6) % 24
        return String(format: "%02d–%02d", start, (start + 1) % 24) + " · \(Totals.duration(hours[hover])) in 30 giorni"
    }
}
