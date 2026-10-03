import SwiftUI
import AppKit

struct StatusBarView: View {
    @ObservedObject var sampler: Sampler
    /// nil: porta davanti la finestra così com'è; .recap: passa alla scheda Recap.
    var openWindow: (MainTab?) -> Void
    @State private var totals = Totals()
    @State private var segments: [TimelineSegment] = []
    @State private var activities: [ActivityTotal] = []
    @State private var queryError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(sampler.currentState.category.color)
                    .frame(width: 10, height: 10)
                Text(sampler.currentState.appName).font(.headline)
                Spacer()
                Text(sampler.currentState.category.title).foregroundStyle(.secondary)
            }
            if let domain = sampler.currentState.domain { Text(domain).textSelection(.enabled) }
            if sampler.currentState.category == .unknown && sampler.currentState.domain == nil
                && BrowserURLReader.supported.contains(sampler.currentState.bundleID) {
                Text("URL non leggibile — pagina interna/locale o accesso non disponibile. Controlla Impostazioni di Sistema → Privacy e sicurezza → Automazione.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Oggi").font(.title3.bold())
            HStack(alignment: .top, spacing: 24) {
                StatCard(category: .green, seconds: totals.green,
                         percentage: totals.percentage(.green))
                StatCard(category: .red, seconds: totals.red,
                         percentage: totals.percentage(.red))
            }
            HStack(spacing: 14) {
                LegendChip(category: .paused, seconds: totals.paused)
                LegendChip(category: .unknown, seconds: totals.unclassified)
            }
            CompactTimelineView(segments: segments)
            if !activities.isEmpty {
                Text("Usato oggi").font(.headline).padding(.top, 4)
                VStack(spacing: 6) {
                    ForEach(Array(activities.prefix(6))) { entry in
                        ActivityRow(entry: entry, longest: activities.first?.seconds ?? 1)
                    }
                }
                if activities.count > 6 {
                    Button("Altre \(activities.count - 6) nel Recap") { openWindow(.recap) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if let error = sampler.rulesError { Text("Regole: \(error)").foregroundStyle(Theme.red) }
            if let error = sampler.storageError ?? queryError { Text("Database: \(error)").foregroundStyle(Theme.red) }
            Divider()
            HStack(spacing: 8) {
                Button("Recap & Regole") { openWindow(nil) }
                Spacer()
                Button("Esci") { confirmQuit() }
            }
        }
        .padding(16)
        .frame(width: 350)
        .task(id: "\(sampler.currentState.bundleID)-\(sampler.currentState.domain ?? "")-\(sampler.currentState.category.rawValue)-\(sampler.rulesVersion)") {
            // Aggiorna subito e poi ogni 30 s finché il pannello è aperto.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: sampler.isReady) { _, _ in Task { await refresh() } }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "Uscire da BUSY?"
        alert.informativeText = "Finché non la riapri, il tempo non verrà registrato."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Esci").hasDestructiveAction = true
        alert.addButton(withTitle: "Annulla")
        // App senza Dock: senza activate l'avviso può finire dietro le altre finestre.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    @MainActor private func refresh() async {
        guard sampler.isReady else { return }
        let now = Date()
        do {
            // Una sola query per totali, barra e "Usato oggi": i tre dati tornano sempre.
            let today = try await sampler.recap(from: Calendar.current.startOfDay(for: now), to: now)
            totals = today.totals
            activities = today.activities
            segments = today.segments
            queryError = nil
        } catch { queryError = error.localizedDescription }
    }
}

/// Timeline compatta per il menu.
/// 1. Solo tempo attivo: le pause si tolgono e le sessioni si accodano. Le pause
///    oltre soglia diventano una tacca sottile, con l'orario di ripresa sotto.
/// 2. Colonne da ~3 pt: ognuna mostra in verticale la quota rosso/verde del suo
///    intervallo, con altezza minima 2 pt. Anche 20 s di distrazione restano visibili.
/// 3. Stessa logica per ogni periodo, cambia solo la soglia: 5 min, 6 h, 8 h, 36 h
///    (settimana e mese: in pratica una tacca per notte).
struct CompactTimelineView: View {
    let segments: [TimelineSegment]
    var height: CGFloat = 22
    var period: RecapPeriod = .day

    private static func gapThreshold(_ period: RecapPeriod) -> TimeInterval {
        switch period {
        case .day: return 5 * 60
        case .week: return 6 * 3600
        case .month: return 8 * 3600
        case .year: return 36 * 3600
        }
    }

    private static func label(_ date: Date, period: RecapPeriod) -> String {
        let it = Locale(identifier: "it_IT")
        switch period {
        case .day: return date.formatted(date: .omitted, time: .shortened)
        case .week: return "\(date.formatted(.dateTime.weekday(.abbreviated).locale(it))) \(date.formatted(date: .omitted, time: .shortened))"
        case .month, .year: return date.formatted(.dateTime.day().month(.abbreviated).locale(it))
        }
    }
    private static let separatorWidth: CGFloat = 5
    private static let columnWidth: CGFloat = 3

    @State private var hoverText: String?

    private struct Column {
        let x: CGFloat, width: CGFloat, start: Date, end: Date
        var green: TimeInterval = 0, red: TimeInterval = 0, unknown: TimeInterval = 0
        var top: String?
        /// Date vere della colonna: start/end sono su un asse senza pause.
        var realStart: Date?, realEnd: Date?
    }
    private struct Layout {
        var columns: [Column] = []
        var separators: [CGFloat] = []
        var labels: [(x: CGFloat, text: String)] = []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hoverText ?? " ")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            GeometryReader { geo in
                let layout = Self.layout(segments, width: geo.size.width, period: period)
                VStack(spacing: 3) {
                    Canvas { context, size in draw(layout, in: &context, size: size) }
                        .frame(height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): hoverText = describe(layout, at: point.x)
                            case .ended: hoverText = nil
                            }
                        }
                    Canvas { context, size in drawLabels(layout, in: &context, size: size) }
                        .frame(height: 12)
                }
            }
            .frame(height: height + 15)
            if segments.allSatisfy({ $0.category == .paused }) {
                Text("Nessuna attività").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static func layout(_ segments: [TimelineSegment], width: CGFloat,
                               period: RecapPeriod) -> Layout {
        var result = Layout()
        var active = segments.filter { $0.category != .paused }.sorted { $0.start < $1.start }
        let threshold = gapThreshold(period)
        // Inizio reale meno inizio in barra, per segmento: serve a etichette e hover.
        var shifts = [TimeInterval](repeating: 0, count: active.count)
        var blocks: [(start: Date, end: Date)] = []
        // Le pause sotto soglia diventerebbero vuoti grigi dentro i blocchi: si tolgono
        // tutte e le sessioni si accodano. Restano solo i separatori sulle pause lunghe.
        var t = Date(timeIntervalSinceReferenceDate: 0)
        var previousEnd: Date?
        for (i, segment) in active.enumerated() {
            let end = t.addingTimeInterval(segment.end.timeIntervalSince(segment.start))
            if let previousEnd, segment.start.timeIntervalSince(previousEnd) <= threshold {
                blocks[blocks.count - 1].end = end
            } else {
                blocks.append((t, end))
            }
            shifts[i] = segment.start.timeIntervalSince(t)
            previousEnd = max(previousEnd ?? segment.end, segment.end)
            active[i] = TimelineSegment(id: segment.id, start: t, end: end,
                                        category: segment.category, name: segment.name)
            t = end
        }
        guard !blocks.isEmpty, width > 0 else { return result }
        let available = width - CGFloat(blocks.count - 1) * separatorWidth
        let total = blocks.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard available > 0, total > 0 else { return result }

        var x: CGFloat = 0
        // `active` è ordinato: ogni colonna riparte da qui invece di scorrere tutto
        // l'anno a ogni colonna (e a ogni movimento del mouse).
        var first = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.separators.append(x + separatorWidth / 2)
                x += separatorWidth
            }
            while first < active.count && active[first].end <= block.start { first += 1 }
            let realStart = block.start.addingTimeInterval(first < active.count ? shifts[first] : 0)
            result.labels.append((x, label(realStart, period: period)))
            let duration = block.end.timeIntervalSince(block.start)
            let blockWidth = max(columnWidth, available * CGFloat(duration / total))
            let count = max(1, Int(blockWidth / columnWidth))
            let colWidth = blockWidth / CGFloat(count)
            for c in 0..<count {
                let start = block.start.addingTimeInterval(duration * Double(c) / Double(count))
                let end = block.start.addingTimeInterval(duration * Double(c + 1) / Double(count))
                var column = Column(x: x + CGFloat(c) * colWidth, width: colWidth, start: start, end: end)
                var names: [String: TimeInterval] = [:]
                while first < active.count && active[first].end <= start { first += 1 }
                var i = first
                while i < active.count, active[i].start < end {
                    let segment = active[i]
                    let shift = shifts[i]
                    i += 1
                    guard segment.end > start else { continue }
                    if column.realStart == nil {
                        column.realStart = max(segment.start, start).addingTimeInterval(shift)
                    }
                    column.realEnd = min(segment.end, end).addingTimeInterval(shift)
                    let overlap = min(segment.end, end).timeIntervalSince(max(segment.start, start))
                    switch segment.category {
                    case .green: column.green += overlap
                    case .red: column.red += overlap
                    case .unknown: column.unknown += overlap
                    case .paused: break
                    }
                    names[segment.name, default: 0] += overlap
                }
                column.top = names.max { $0.value < $1.value }?.key
                result.columns.append(column)
            }
            x += blockWidth
        }
        return result
    }

    private func draw(_ layout: Layout, in context: inout GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.track))
        for column in layout.columns {
            let parts: [(TimeInterval, Color)] = [(column.red, Theme.red),
                                                  (column.unknown, Theme.unknown),
                                                  (column.green, Theme.green)]
            let sum = parts.reduce(0) { $0 + $1.0 }
            guard sum > 0 else { continue }
            // Altezza minima 2 pt per ogni quota presente, poi si riscala su tutta l'altezza.
            let raw = parts.map { $0.0 > 0 ? max(2, size.height * CGFloat($0.0 / sum)) : 0 }
            let scale = size.height / raw.reduce(0, +)
            var y: CGFloat = 0
            for (index, part) in parts.enumerated() where raw[index] > 0 {
                let h = raw[index] * scale
                context.fill(Path(CGRect(x: column.x, y: y, width: column.width, height: h)),
                             with: .color(part.1))
                y += h
            }
        }
        for x in layout.separators {
            context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                         with: .color(.secondary.opacity(0.6)))
        }
    }

    private func drawLabels(_ layout: Layout, in context: inout GraphicsContext, size: CGSize) {
        var lastEnd: CGFloat = -.infinity
        for label in layout.labels {
            let text = context.resolve(Text(label.text).font(.caption2).foregroundColor(.secondary))
            let width = text.measure(in: size).width
            let x = min(label.x, size.width - width)
            guard x >= lastEnd + 4 else { continue } // niente etichette sovrapposte
            context.draw(text, at: CGPoint(x: x, y: size.height / 2), anchor: .leading)
            lastEnd = x + width
        }
    }

    private func describe(_ layout: Layout, at x: CGFloat) -> String? {
        guard let column = layout.columns.first(where: { x >= $0.x && x < $0.x + $0.width }) else { return nil }
        let classified = column.green + column.red
        let share = classified > 0 ? Int((column.green / classified * 100).rounded()) : 0
        let it = Locale(identifier: "it_IT")
        let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(it)
        var parts: [String] = []
        switch period {
        case .day:
            if let realStart = column.realStart, let realEnd = column.realEnd {
                parts.append("\(realStart.formatted(date: .omitted, time: .shortened))–\(realEnd.formatted(date: .omitted, time: .shortened))")
            }
        case .week, .month:
            if let real = column.realStart {
                parts.append("\(real.formatted(day)) \(real.formatted(date: .omitted, time: .shortened))")
            }
        case .year:
            if let real = column.realStart { parts.append(real.formatted(day)) }
        }
        if let top = column.top { parts.append(AppName.display(top)) }
        parts.append("\(share)% verde")
        return parts.joined(separator: " · ")
    }
}
