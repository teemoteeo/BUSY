import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor delle regole: segni le app installate come verdi/rosse e aggiungi
/// siti incollando un link. Ogni modifica si salva subito in rules.json.
struct RulesEditorView: View {
    // Niente @ObservedObject: la finestra non mostra lo stato live. Serve solo rulesError.
    let sampler: Sampler
    /// Scelta dalla sidebar della finestra.
    let tab: Tab

    enum Tab { case apps, sites }

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "Tutte", green = "Verdi", red = "Rosse", unmarked = "Non segnate"
        var id: String { rawValue }
        func includes(_ category: Category?) -> Bool {
            switch self {
            case .all: return true
            case .green: return category == .green
            case .red: return category == .red
            case .unmarked: return category == nil
            }
        }
    }

    private struct DomainRule: Identifiable, Equatable {
        var id: String { domain }
        let domain: String
        var category: Category
    }

    @State private var apps: [InstalledApp] = []
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var bundleRules: [String: Category] = [:]
    @State private var domainRules: [DomainRule] = []
    @State private var newLink = ""
    @State private var newCategory: Category = .red
    @State private var linkError: String?
    @State private var saveError: String?
    @State private var rulesError: String?

    private var defaultCategory: Category {
        sampler.rules.entries.last(where: { $0.type == .default })?.category ?? .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch tab {
            case .apps: appsTab
            case .sites: sitesTab
            }
            if let error = saveError ?? rulesError {
                Text("Regole: \(error)").font(.caption).foregroundStyle(Theme.red)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: load)
        .onReceive(sampler.$rulesError) { rulesError = $0 }
        .task {
            // Prima le app già verdi/rosse, poi le altre (scan le dà già in ordine alfabetico).
            // Ordine fissato all'apertura: una riga classificata ora non salta via sotto il cursore.
            let scanned = await InstalledApp.scan(extra: Array(bundleRules.keys))
            apps = scanned.filter { bundleRules[$0.id] != nil } + scanned.filter { bundleRules[$0.id] == nil }
        }
    }

    // MARK: App

    private var searchedApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return apps.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.id.contains(query) }
    }

    private var unmarkedNote: String {
        switch defaultCategory {
        case .green: return "Le app non segnate contano come verdi."
        case .red: return "Le app non segnate contano come rosse."
        default: return "Le app non segnate restano grigie e non entrano nel rapporto verde/rosso."
        }
    }

    private var appsTab: some View {
        let searched = searchedApps
        return VStack(alignment: .leading, spacing: 10) {
            if sampler.rules.isFirstRun {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Benvenuto in BUSY").font(.headline)
                    Text("Segna in verde le app con cui lavori e in rosso quelle che ti distraggono: ogni clic sulla pill cambia colore. Puoi farlo anche più tardi, da qui.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            TextField("Cerca app", text: $search).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                ForEach(Filter.allCases) { option in
                    filterChip(option, count: searched.filter { option.includes(bundleRules[$0.id]) }.count)
                }
            }
            Text(unmarkedNote).font(.caption).foregroundStyle(.secondary)
            List(searched.filter { filter.includes(bundleRules[$0.id]) }) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                    Text(app.name).lineLimit(1).help(app.id)
                    Spacer()
                    CategoryPill(selection: bundleBinding(app.id))
                }
                .padding(.vertical, 1)
            }
            if apps.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    private func filterChip(_ option: Filter, count: Int) -> some View {
        let selected = filter == option
        let tint: Color = switch option {
        case .green: Theme.green
        case .red: Theme.red
        default: .secondary
        }
        return Button { filter = option } label: {
            HStack(spacing: 4) {
                Text(option.rawValue)
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? tint : .secondary)
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? tint.opacity(0.18) : Theme.track))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func bundleBinding(_ bundleID: String) -> Binding<Category?> {
        Binding(
            get: { bundleRules[bundleID] },
            set: { bundleRules[bundleID] = $0; save() }
        )
    }

    // MARK: Siti

    private var sitesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Incolla un link, es. https://www.youtube.com/…", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addLink)
                CategoryPill(category: $newCategory)
                Button("Aggiungi", action: addLink)
                    .disabled(newLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let linkError { Text(linkError).font(.caption).foregroundStyle(Theme.red) }
            Text("Vale per tutto il sito e i suoi sottodomini (youtube.com include m.youtube.com).")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if domainRules.isEmpty { Text("Nessun sito.").foregroundStyle(.secondary) }
                ForEach($domainRules) { $rule in
                    HStack {
                        Text(rule.domain)
                        Spacer()
                        CategoryPill(category: $rule.category)
                            .onChange(of: rule.category) { _, _ in save() }
                        Button {
                            domainRules.removeAll { $0.domain == rule.domain }
                            save()
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func addLink() {
        guard let domain = Self.domain(from: newLink) else {
            linkError = "Link non valido."
            return
        }
        linkError = nil
        if let index = domainRules.firstIndex(where: { $0.domain == domain }) {
            domainRules[index].category = newCategory
        } else {
            domainRules.insert(DomainRule(domain: domain, category: newCategory), at: 0)
        }
        newLink = ""
        save()
    }

    static func domain(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let domain = BrowserURLReader.domain(from: text), domain.contains(".") else { return nil }
        return domain
    }

    // MARK: Persistenza

    private func load() {
        let entries = sampler.rules.entries
        bundleRules = Dictionary(entries.filter { $0.type == .bundle }.map { ($0.match, $0.category) },
                                 uniquingKeysWith: { first, _ in first })
        domainRules = entries.filter { $0.type == .domain }
            .map { DomainRule(domain: $0.match, category: $0.category) }
    }

    private func save() {
        let bundles = bundleRules
            .sorted { $0.key < $1.key }
            .map { Rule(match: $0.key, type: .bundle, category: $0.value) }
        let domains = domainRules.map { Rule(match: $0.domain, type: .domain, category: $0.category) }
        do {
            try sampler.rules.save(bundles + domains)
            saveError = nil
            sampler.reloadRules()
        } catch { saveError = error.localizedDescription }
    }
}

struct InstalledApp: Identifiable {
    let id: String   // bundle ID
    let name: String
    let url: URL?

    var icon: NSImage {
        if let url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// App nelle cartelle standard + quelle già presenti nelle regole ma non trovate lì.
    static func scan(extra: [String]) async -> [InstalledApp] {
        await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let folders = ["/Applications", "/Applications/Utilities",
                           "/System/Applications", "/System/Applications/Utilities",
                           manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            var found: [String: InstalledApp] = [:]
            for folder in folders {
                guard let items = try? manager.contentsOfDirectory(atPath: folder) else { continue }
                for item in items where item.hasSuffix(".app") {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                    guard let bundleID = Bundle(url: url)?.bundleIdentifier, found[bundleID] == nil else { continue }
                    var name = manager.displayName(atPath: url.path)
                    if name.hasSuffix(".app") { name.removeLast(4) }
                    found[bundleID] = InstalledApp(id: bundleID, name: name, url: url)
                }
            }
            for bundleID in extra where found[bundleID] == nil {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                let name = url.map { manager.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
                found[bundleID] = InstalledApp(id: bundleID, name: name, url: url)
            }
            return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }
}
