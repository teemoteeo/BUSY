import Foundation

enum Category: String, Codable, Sendable {
    case green, red, paused, unknown
    var title: String {
        switch self {
        case .green: return "Produttiva"
        case .red: return "Distrazione"
        case .paused: return "In pausa"
        case .unknown: return "Non classificato"
        }
    }
    var isClassified: Bool { self == .green || self == .red }
}

struct Session: Identifiable, Sendable, Equatable {
    var id: Int64 = 0
    let timestamp: Date
    let bundleID: String
    let domain: String?
    let category: Category
    let matchedRule: String?

    func hasSameActivity(as other: Session) -> Bool {
        bundleID == other.bundleID && domain == other.domain && category == other.category
    }
}

struct Totals {
    var green: TimeInterval = 0
    var red: TimeInterval = 0
    var paused: TimeInterval = 0
    var unclassified: TimeInterval = 0
    var total: TimeInterval { green + red }
    var recorded: TimeInterval { total + paused + unclassified }
    mutating func add(_ seconds: TimeInterval, category: Category) {
        switch category {
        case .green: green += seconds
        case .red: red += seconds
        case .paused: paused += seconds
        case .unknown: unclassified += seconds
        }
    }
    func percentage(_ category: Category) -> Double {
        guard total > 0, category.isClassified else { return 0 }
        return (category == .green ? green : red) / total * 100
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

struct DailyTotal: Identifiable {
    let id: Date
    var totals = Totals()
}

struct ActivityTotal: Identifiable {
    struct Key: Hashable {
        let name: String
        let category: Category
    }
    let id: Key
    var seconds: TimeInterval
}

struct TimelineSegment: Identifiable {
    let id: Int
    let start: Date
    let end: Date
    let category: Category
    let name: String
}

struct Recap {
    var totals = Totals()
    var days: [DailyTotal] = []
    var activities: [ActivityTotal] = []
    /// Intervalli consecutivi già tagliati su [from, to), in ordine cronologico.
    var segments: [TimelineSegment] = []

    // Intervalli semiaperti [from, to). Il primo sample può precedere from.
    // `only`: conta solo quell'app o dominio. Gli altri sample servono comunque
    // a chiudere gli intervalli, quindi il filtro va qui e non prima.
    static func aggregate(_ samples: [Session], from: Date, to: Date, only: String? = nil,
                          calendar: Calendar = .current) -> Recap {
        guard from < to else { return Recap() }
        var result = Recap()
        var day = calendar.startOfDay(for: from)
        // Fine di ogni giorno calcolata una volta sola: le operazioni di Calendar
        // per ogni sample erano quasi tutto il tempo del recap annuale.
        var dayEnds: [Date] = []
        while day < to {
            result.days.append(DailyTotal(id: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            dayEnds.append(next)
            day = next
        }
        var dayIndex = 0
        var activities: [ActivityTotal.Key: TimeInterval] = [:]
        let ordered = samples.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        for (index, sample) in ordered.enumerated() {
            let start = max(from, sample.timestamp)
            let end = min(to, index + 1 < ordered.count ? ordered[index + 1].timestamp : to)
            let name = sample.category == .paused ? "Pausa" : (sample.domain ?? sample.bundleID)
            guard start < end, only == nil || only == name else { continue }
            let seconds = end.timeIntervalSince(start)
            result.totals.add(seconds, category: sample.category)
            result.segments.append(TimelineSegment(id: index, start: start, end: end,
                category: sample.category, name: name))
            // Pausa e URL illeggibili sono diagnostica, esclusa dalla classifica.
            // Le app non segnate (grigie) restano: servono per decidere cosa segnare.
            if sample.category != .paused && sample.matchedRule != Classifier.urlUnavailable {
                let key = ActivityTotal.Key(name: sample.domain ?? sample.bundleID,
                                           category: sample.category)
                activities[key, default: 0] += seconds
            }
            // I sample sono in ordine: il giorno di partenza avanza e non torna mai indietro.
            while dayIndex < dayEnds.count && dayEnds[dayIndex] <= start { dayIndex += 1 }
            var i = dayIndex
            while i < dayEnds.count {
                let dayStart = result.days[i].id
                guard dayStart < end else { break }
                let overlap = min(end, dayEnds[i]).timeIntervalSince(max(start, dayStart))
                if overlap > 0 { result.days[i].totals.add(overlap, category: sample.category) }
                i += 1
            }
        }
        result.activities = activities.map { ActivityTotal(id: $0.key, seconds: $0.value) }
            .sorted {
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                if $0.id.name != $1.id.name { return $0.id.name < $1.id.name }
                return $0.id.category.rawValue < $1.id.category.rawValue
            }
        return result
    }
}
