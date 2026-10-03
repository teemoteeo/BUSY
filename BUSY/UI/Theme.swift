import SwiftUI
import AppKit

// MARK: - Token

/// Unica fonte per colori e misure. Category.color, la timeline e lo switch
/// nella barra dei menu leggono tutti da qui: cambi un valore, cambia ovunque.
enum Theme {
    // Base AppKit: lo switch nella barra lavora con NSColor/CGColor.
    // Colori di sistema: la stessa tinta delle app Apple, adattata a chiaro e scuro.
    static let greenNS = NSColor.systemGreen
    static let redNS = NSColor.systemRed
    static let neutralNS = NSColor(white: 0.40, alpha: 1)

    static let green = Color(nsColor: greenNS)
    static let red = Color(nsColor: redNS)
    static let unknown = Color.gray.opacity(0.6)
    static let paused = Color.secondary.opacity(0.35)
    /// Fondo della finestra: nel tema chiaro un bianco appena smorzato, nello scuro
    /// quello di sistema.
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(white: 0.955, alpha: 1)
    })
    /// Fondo delle barre vuote.
    static let track = Color.secondary.opacity(0.12)

    static let rowSpacing: CGFloat = 8
}

extension Category {
    var color: Color {
        switch self {
        case .green: return Theme.green
        case .red: return Theme.red
        case .unknown: return Theme.unknown
        case .paused: return Theme.paused
        }
    }
}

// MARK: - StatCard

/// Totale di una categoria, come in origine: "Verde"/"Rosso" colorato, durata, quota.
struct StatCard: View {
    let category: Category
    let seconds: TimeInterval
    let percentage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(category.title).foregroundStyle(category.color)
            Text(Totals.duration(seconds)).font(.title2).monospacedDigit()
            Text("\(percentage, specifier: "%.1f")% del tempo classificato")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - DayBar

/// La giornata dalle 06 alle 06: ogni attività sta all'orario in cui è avvenuta,
/// pause e ore senza dati restano vuote. A differenza della timeline compatta
/// non toglie i buchi, quindi si vede quando hai lavorato. Le 06 come confine
/// tengono la notte attaccata alla sera prima.
struct DayBar: View {
    let segments: [TimelineSegment]
    let window: DateInterval
    var height: CGFloat = 10
    /// Falso nelle righe per giorno: i nomi delle fasce stanno una volta sola in testa.
    var showsLabels = true

    /// Dalle 06 di `day` alle 06 del giorno dopo (23 o 25 ore al cambio dell'ora legale).
    static func window(for day: Date) -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: day) ?? calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    var body: some View {
        let start = window.start
        let length = window.duration
        VStack(spacing: 3) {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.clip(to: Path(roundedRect: rect, cornerRadius: 3))
                context.fill(Path(rect), with: .color(Theme.track))
                for segment in segments where segment.category != .paused {
                    let x0 = size.width * CGFloat(max(0, segment.start.timeIntervalSince(start)) / length)
                    let x1 = size.width * CGFloat(min(length, segment.end.timeIntervalSince(start)) / length)
                    guard x1 > x0 else { continue }
                    context.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)),
                                 with: .color(segment.category.color))
                }
                for quarter in [0.25, 0.5, 0.75] {
                    let x = (size.width * quarter).rounded()
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                                 with: .color(.primary.opacity(0.15)))
                }
            }
            .frame(height: height)
            if showsLabels { DayPartLabels() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Giornata dalle 06 alle 06")
    }
}

/// Sotto la DayBar: le ore sulle tacche (06 12 18 00 06) e il nome di ogni quarto
/// al centro del suo tratto: mattina 06–12, pomeriggio 12–18, sera 18–00, notte 00–06.
struct DayPartLabels: View {
    var body: some View {
        GeometryReader { geo in
            let quarter = geo.size.width / 4
            ForEach(Array(["Mattina", "Pomeriggio", "Sera", "Notte"].enumerated()), id: \.offset) { index, name in
                Text(name).foregroundStyle(.secondary)
                    .position(x: quarter * (CGFloat(index) + 0.5), y: geo.size.height / 2)
            }
            ForEach(Array(["06", "12", "18", "00", "06"].enumerated()), id: \.offset) { index, hour in
                Text(hour).monospacedDigit().foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(width: 0, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
                    .position(x: quarter * CGFloat(index), y: geo.size.height / 2)
            }
        }
        .font(.caption2)
        .frame(height: 12)
    }
}

// MARK: - DayDot

/// Pallino del calendario: colore di chi ha dominato la giornata (verde o rosso).
/// Si riempie (in area) per la quota di quel colore sul tempo totale del Mac quel
/// giorno, pause e non classificato compresi. Anello vuoto senza dati.
struct DayDot: View {
    let green: TimeInterval
    let red: TimeInterval
    /// Tutto il tempo registrato nella giornata.
    let total: TimeInterval

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            context.stroke(Path(ellipseIn: rect), with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            let dominant = max(green, red)
            guard total > 0, dominant > 0 else { return }
            let radius = max(2, rect.width / 2 * CGFloat(min(1, dominant / total).squareRoot()))
            let dot = CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(green >= red ? Theme.green : Theme.red))
        }
    }
}

// MARK: - UsageSparkline

/// Una colonnina per giorno, alta in proporzione al giorno più usato della serie.
/// I giorni senza uso restano una tacca sottile, così si vede anche quando non c'è.
struct UsageSparkline: View {
    let values: [TimeInterval]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let longest = values.max() ?? 0
            let step = size.width / CGFloat(values.count)
            let barWidth = max(1, step - 1)
            for (index, value) in values.enumerated() {
                let height = longest > 0 && value > 0 ? max(2, size.height * CGFloat(value / longest)) : 1
                let rect = CGRect(x: CGFloat(index) * step, y: size.height - height, width: barWidth, height: height)
                context.fill(Path(rect), with: .color(value > 0 ? color : Theme.track))
            }
        }
        .accessibilityLabel("Uso negli ultimi \(values.count) giorni")
    }
}

// MARK: - LegendChip

/// Voce secondaria (pausa, non classificato): pallino + nome + durata, senza card.
struct LegendChip: View {
    let category: Category
    let seconds: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(category.color).frame(width: 7, height: 7)
            Text(category.title).foregroundStyle(.secondary)
            Text(Totals.duration(seconds)).monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - ActivityRow

/// Riga attività: icona (globo per i siti), nome, barra proporzionale all'attività più lunga, durata.
/// Usata nel pannello della barra e nella classifica del Recap.
struct ActivityRow: View {
    let entry: ActivityTotal
    let longest: TimeInterval
    var nameWidth: CGFloat = 130

    var body: some View {
        HStack(spacing: 8) {
            ActivityIcon(name: entry.id.name).frame(width: 16, height: 16)
            Text(AppName.display(entry.id.name)).lineLimit(1).truncationMode(.middle)
                .frame(width: nameWidth, alignment: .leading)
                .help(entry.id.name)
            GeometryReader { geo in
                Capsule()
                    .fill(entry.id.category.color.opacity(0.75))
                    .frame(width: max(3, geo.size.width * CGFloat(entry.seconds / max(longest, 1))))
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 6)
            Text(Totals.duration(entry.seconds)).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - CategoryPill

/// Una sola pill per riga: pulsante di sistema pieno del colore della categoria,
/// semplice se non segnata.
/// Il click cicla verde → rosso → nessuna (solo verde ↔ rosso se `allowsNone` è falso);
/// il menu contestuale sceglie direttamente. Niente Picker segmentato: su macOS 26
/// perde memoria a ogni ridisegno.
struct CategoryPill: View {
    @Binding var selection: Category?
    var allowsNone = true

    private var next: Category? {
        switch selection {
        case .green: return .red
        case .red: return allowsNone ? nil : .green
        default: return .green
        }
    }

    var body: some View {
        let button = Button { selection = next } label: {
            Text(selection?.title ?? "Non segnata").frame(minWidth: 72)
        }
        Group {
            if let color = selection?.color {
                button.buttonStyle(.borderedProminent).tint(color)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .contextMenu {
            Button(Category.green.title) { selection = .green }
            Button(Category.red.title) { selection = .red }
            if allowsNone { Button("Non segnata") { selection = nil } }
        }
        .help("Clic per cambiare")
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

// MARK: - TitledSection

/// Sezione con titolo in grassetto sopra il contenuto, a tutta larghezza.
struct TitledSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
