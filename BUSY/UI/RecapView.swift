import SwiftUI
import AppKit

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
    // Niente @ObservedObject: il recap si aggiorna su richiesta, non a ogni campione.
    let sampler: Sampler
    @State private var period: RecapPeriod = .day
    /// Una data qualsiasi dentro il periodo mostrato.
    @State private var anchor = Date()
    @State private var recap = Recap()
    @State private var errorMessage: String?
    @State private var updatedAt: Date?

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
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            HStack(spacing: 32) {
                summary("Verde", seconds: recap.totals.green, category: .green)
                summary("Rosso", seconds: recap.totals.red, category: .red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("In pausa: \(Totals.duration(recap.totals.paused))")
                Text("Non classificato: \(Totals.duration(recap.totals.unclassified))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Text("Timeline").font(.headline)
            CompactTimelineView(segments: recap.segments, height: 28, period: period)
            List {
                breakdown
                Section("Top 10 per tempo speso") {
                    if recap.activities.isEmpty { Text("Nessuna sessione nell'intervallo.") }
                    ForEach(Array(recap.activities.prefix(10))) { entry in
                        HStack {
                            Circle().fill(entry.id.category.color).frame(width: 8, height: 8)
                            Text(AppName.display(entry.id.name)).lineLimit(1).help(entry.id.name)
                            Spacer()
                            Text(entry.id.category.title).foregroundStyle(.secondary)
                            Text(Totals.duration(entry.seconds)).monospacedDigit()
                        }
                    }
                }
            }
            if let updatedAt {
                Text("Aggiornato alle \(updatedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 580)
        .environment(\.locale, Self.italian)
        .task(id: "\(period.rawValue)-\(interval.start.timeIntervalSince1970)") { await refresh() }
        .onReceive(sampler.$isReady.dropFirst()) { _ in Task { await refresh() } }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $period) {
                    ForEach(RecapPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
                Button("Aggiorna") { Task { await refresh() } }
            }
            HStack(spacing: 8) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(isCurrentPeriod)
                Text(title).font(.title2.bold())
                Spacer()
                if !isCurrentPeriod {
                    Button(period == .day ? "Oggi" : "Periodo attuale") { anchor = Date() }
                }
            }
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

    @ViewBuilder private var breakdown: some View {
        switch period {
        case .day:
            EmptyView()
        case .week, .month:
            Section("Per giorno") {
                ForEach(recap.days.reversed()) { day in
                    row(day.id.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(Self.italian)).capitalized,
                        totals: day.totals) { open(.day, at: day.id) }
                }
            }
        case .year:
            Section("Per mese") {
                ForEach(monthTotals.reversed()) { entry in
                    row(entry.month.formatted(.dateTime.month(.wide).locale(Self.italian)).capitalized,
                        totals: entry.totals) { open(.month, at: entry.month) }
                }
            }
        }
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

    private func row(_ label: String, totals: Totals, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).frame(maxWidth: .infinity, alignment: .leading)
                Text("Verde  \(Totals.duration(totals.green))").frame(width: 130, alignment: .trailing)
                Text("Rosso  \(Totals.duration(totals.red))").frame(width: 130, alignment: .trailing)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func summary(_ title: String, seconds: TimeInterval, category: Category) -> some View {
        VStack(alignment: .leading) {
            Text(title).foregroundStyle(category.color)
            Text(Totals.duration(seconds)).font(.title2).monospacedDigit()
            Text("\(recap.totals.percentage(category), specifier: "%.1f")% del tempo classificato")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor private func refresh() async {
        guard sampler.isReady else { return }
        let now = Date()
        let requested = interval
        let end = min(requested.end, now)
        guard requested.start < end else { recap = Recap(); return }
        do {
            let result = try await sampler.recap(from: requested.start, to: end)
            // Una risposta lenta non deve sovrascrivere il periodo appena selezionato.
            guard requested == interval else { return }
            recap = result
            updatedAt = now
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
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
}
