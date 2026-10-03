import Foundation

struct Rule: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case bundle, domain, `default` }
    let match: String
    let type: Kind
    let category: Category
}

@MainActor
final class Rules {
    private(set) var entries: [Rule] = []
    /// Vero se a questo avvio rules.json non esisteva: primo avvio, si mostra l'onboarding.
    private(set) var isFirstRun = false
    let fileURL: URL
    private let resourceURL: URL?

    init(fileURL: URL = AppPaths.rules,
         resourceURL: URL? = Bundle.main.url(forResource: "rules", withExtension: "json")) {
        self.fileURL = fileURL
        self.resourceURL = resourceURL
    }

    func reload() throws {
        try seedIfNeeded()
        let decoded = try JSONDecoder().decode([Rule].self, from: Data(contentsOf: fileURL))
        for (index, rule) in decoded.enumerated() {
            guard !rule.match.isEmpty else { throw RulesError.invalid("Regola \(index + 1): match vuoto.") }
            if rule.type == .default && index != decoded.count - 1 {
                throw RulesError.invalid("La regola default deve essere l'ultima.")
            }
        }
        // Un file non valido lascia intatte le ultime regole caricate con successo.
        entries = decoded
    }

    /// Scrive le regole su disco (default sempre in fondo) e le rende attive.
    /// Il watcher del Sampler vede il salvataggio e ricalcola pallino e totali.
    func save(_ newRules: [Rule]) throws {
        let fallback = newRules.last(where: { $0.type == .default })
            ?? entries.last(where: { $0.type == .default })
            ?? Rule(match: "*", type: .default, category: .red)
        let ordered = newRules.filter { $0.type == .bundle }
            + newRules.filter { $0.type == .domain }
            + [fallback]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(ordered).write(to: fileURL, options: .atomic)
        entries = ordered
    }

    /// Cambia solo la regola default (app e siti non segnati).
    func setDefault(_ category: Category) throws {
        try save(entries.filter { $0.type != .default } + [Rule(match: "*", type: .default, category: category)])
    }

    private func seedIfNeeded() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: fileURL.path) else { return }
        guard let resourceURL else {
            throw RulesError.invalid("Impossibile inizializzare \(fileURL.path): rules.json manca nelle risorse del bundle.")
        }
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
            // copyItem non sovrascrive un file già esistente.
            try manager.copyItem(at: resourceURL, to: fileURL)
            isFirstRun = true
        } catch {
            throw RulesError.invalid("Impossibile inizializzare \(fileURL.path) dal bundle: \(error.localizedDescription)")
        }
    }

    enum RulesError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }
}
