import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

/// Editor delle regole: segni le app installate come verdi/rosse e aggiungi
/// siti incollando un link. Ogni modifica si salva subito in rules.json.
struct RulesEditorView: View {
    // Niente @ObservedObject: la finestra non mostra lo stato live, e ogni ridisegno
    // dei Picker segmentati perde memoria su macOS 26. Serve solo rulesError.
    let sampler: Sampler

    private enum Tab: String, CaseIterable, Identifiable {
        case apps = "App", sites = "Siti"
        var id: String { rawValue }
    }

    private struct DomainRule: Identifiable, Equatable {
        var id: String { domain }
        let domain: String
        var category: Category
    }

    @State private var tab: Tab = .apps
    @State private var apps: [InstalledApp] = []
    @State private var search = ""
    @State private var bundleRules: [String: Category] = [:]
    @State private var domainRules: [DomainRule] = []
    @State private var newLink = ""
    @State private var linkError: String?
    @State private var saveError: String?
    @State private var rulesError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var defaultCategory: Category {
        sampler.rules.entries.last(where: { $0.type == .default })?.category ?? .red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            switch tab {
            case .apps: appsTab
            case .sites: sitesTab
            }

            // Riquadro come le righe di Impostazioni di Sistema.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Apri all'accensione del Mac")
                    Spacer()
                    Toggle("Apri all'accensione del Mac", isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let error = saveError ?? rulesError {
                Text("Regole: \(error)").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Le modifiche sono attive subito.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Apri rules.json") { sampler.editRules() }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: load)
        // Si può cambiare anche da Impostazioni → Generali → Elementi login.
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
        .onReceive(sampler.$rulesError) { rulesError = $0 }
        .task {
            // Prima le app già verdi/rosse, poi le altre (scan le dà già in ordine alfabetico).
            // Ordine fissato all'apertura: una riga classificata ora non salta via sotto il cursore.
            let scanned = await InstalledApp.scan(extra: Array(bundleRules.keys))
            apps = scanned.filter { bundleRules[$0.id] != nil } + scanned.filter { bundleRules[$0.id] == nil }
        }
    }

    // MARK: App

    private var filteredApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return apps.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.id.contains(query) }
    }

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Cerca app", text: $search).textFieldStyle(.roundedBorder)
            Text("Le app non segnate contano come \(defaultCategory == .green ? "verdi" : "rosse").")
                .font(.caption).foregroundStyle(.secondary)
            List(filteredApps) { app in
                HStack(spacing: 10) {
                    Image(nsImage: app.icon).resizable().frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name).lineLimit(1)
                        Text(app.id).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                    Picker("", selection: bundleBinding(app.id)) {
                        Text("Verde").tag(Category?.some(.green))
                        Text("—").tag(Category?.none)
                        Text("Rosso").tag(Category?.some(.red))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
                }
            }
            if apps.isEmpty { ProgressView().frame(maxWidth: .infinity) }
        }
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
                Button("Aggiungi come rosso", action: addLink)
                    .disabled(newLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let linkError { Text(linkError).font(.caption).foregroundStyle(.red) }
            Text("Vale per tutto il sito e i suoi sottodomini (youtube.com include m.youtube.com).")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if domainRules.isEmpty { Text("Nessun sito.").foregroundStyle(.secondary) }
                ForEach($domainRules) { $rule in
                    HStack {
                        Circle().fill(rule.category.color).frame(width: 8, height: 8)
                        Text(rule.domain)
                        Spacer()
                        Picker("", selection: $rule.category) {
                            Text("Verde").tag(Category.green)
                            Text("Rosso").tag(Category.red)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 120)
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
            domainRules[index].category = .red
        } else {
            domainRules.insert(DomainRule(domain: domain, category: .red), at: 0)
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

    // MARK: Avvio automatico

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginError = "Da approvare in Impostazioni di Sistema → Generali → Elementi login."
        }
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
