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
    /// Clic su un'app o un sito: apre le sue statistiche nel Recap.
    var openStats: (String) -> Void = { _ in }

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

    /// Giorni mostrati nella colonnina di ogni riga e usati per l'ordinamento.
    private static let usageDays = 30

    @State private var apps: [InstalledApp] = []
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var bundleRules: [String: Category] = [:]
    /// Regole dei siti per dominio; `domainOrder` tiene l'ordine del file, che conta
    /// quando due regole si sovrappongono (vince la prima).
    @State private var siteRules: [String: Category] = [:]
    @State private var domainOrder: [String] = []
    /// Siti mostrati: quelli con una regola più quelli visitati senza regola.
    @State private var sites: [String] = []
    /// Tempo di ogni giorno degli ultimi 30, per bundle ID (app) e per regola o dominio (siti).
    @State private var appUsage: [String: [TimeInterval]] = [:]
    @State private var siteUsage: [String: [TimeInterval]] = [:]
    @State private var loaded = false
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
            let (perApp, perSite) = await loadUsage()
            // Ordine fissato all'apertura: una riga classificata ora non salta via sotto il cursore.
            // Prima le più usate, poi quelle con una regola, poi le altre in ordine alfabetico.
            let scanned = await InstalledApp.scan(extra: Array(bundleRules.keys) + Array(perApp.keys))
            apps = scanned.enumerated().sorted { a, b in
                let ua = Self.total(perApp[a.element.id]), ub = Self.total(perApp[b.element.id])
                if ua != ub { return ua > ub }
                let ra = bundleRules[a.element.id] != nil, rb = bundleRules[b.element.id] != nil
                if ra != rb { return ra }
                return a.offset < b.offset
            }.map(\.element)
            appUsage = perApp
            // Un dominio visitato conta per la regola che lo copre (m.youtube.com → youtube.com).
            var bySite: [String: [TimeInterval]] = [:]
            for (domain, days) in perSite {
                let key = domainOrder.first { domain == $0 || domain.hasSuffix("." + $0) } ?? domain
                bySite[key] = zip(bySite[key] ?? Array(repeating: 0, count: days.count), days).map(+)
            }
            siteUsage = bySite
            sites = Set(domainOrder).union(bySite.keys).sorted { a, b in
                let ua = Self.total(bySite[a]), ub = Self.total(bySite[b])
                if ua != ub { return ua > ub }
                return a < b
            }
            loaded = true
        }
    }

    private static func total(_ days: [TimeInterval]?) -> TimeInterval { days?.reduce(0, +) ?? 0 }

    /// Ultimi 30 giorni divisi per giorno, una sola query per app e siti insieme.
    private func loadUsage() async -> (apps: [String: [TimeInterval]], sites: [String: [TimeInterval]]) {
        let calendar = Calendar.current
        let now = Date()
        guard let start = calendar.date(byAdding: .day, value: -(Self.usageDays - 1), to: calendar.startOfDay(for: now)),
              let recap = try? await sampler.recap(from: start, to: now) else { return ([:], [:]) }
        let starts = recap.days.map(\.id)
        var apps: [String: [TimeInterval]] = [:]
        var sites: [String: [TimeInterval]] = [:]
        var day = 0
        for segment in recap.segments where segment.category != .paused {
            while day + 1 < starts.count && starts[day + 1] <= segment.start { day += 1 }
            var i = day
            while i < starts.count && starts[i] < segment.end {
                let dayEnd = i + 1 < starts.count ? starts[i + 1] : segment.end
                let overlap = min(segment.end, dayEnd).timeIntervalSince(max(segment.start, starts[i]))
                if overlap > 0 {
                    if segment.isSite {
                        sites[segment.name, default: Array(repeating: 0, count: starts.count)][i] += overlap
                    } else {
                        apps[segment.name, default: Array(repeating: 0, count: starts.count)][i] += overlap
                    }
                }
                i += 1
            }
        }
        return (apps, sites)
    }

    /// Icona, nome, uso degli ultimi 30 giorni e totale: tutta la parte sinistra apre le statistiche.
    private func usageRow(name: String, help: String, icon: some View, category: Category?,
                          usage: [TimeInterval]?, pill: some View) -> some View {
        HStack(spacing: 10) {
            Button { openStats(help) } label: {
                HStack(spacing: 10) {
                    icon.frame(width: 22, height: 22)
                    Text(name).lineLimit(1)
                    Spacer(minLength: 8)
                    UsageSparkline(values: usage ?? Array(repeating: 0, count: Self.usageDays),
                                   color: category?.color ?? Theme.unknown)
                        .frame(width: 90, height: 16)
                    Text(Self.total(usage) > 0 ? Totals.duration(Self.total(usage)) : "—")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Statistiche di \(name) (\(help))")
            pill
        }
        .padding(.vertical, 1)
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
            Text("\(unmarkedNote) Ordinate per uso negli ultimi 30 giorni; clic su un'app per le sue statistiche.")
                .font(.caption).foregroundStyle(.secondary)
            List(searched.filter { filter.includes(bundleRules[$0.id]) }) { app in
                usageRow(name: app.name, help: app.id,
                         icon: Image(nsImage: app.icon).resizable(),
                         category: bundleRules[app.id], usage: appUsage[app.id],
                         pill: CategoryPill(selection: bundleBinding(app.id)))
            }
            if !loaded { ProgressView().frame(maxWidth: .infinity) }
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
            Text("Vale per tutto il sito e i suoi sottodomini (youtube.com include m.youtube.com). Ci sono anche i siti visitati senza regola, ordinati per uso negli ultimi 30 giorni.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                if loaded && sites.isEmpty { Text("Nessun sito.").foregroundStyle(.secondary) }
                ForEach(sites, id: \.self) { domain in
                    usageRow(name: domain, help: domain,
                             icon: ActivityIcon(name: domain),
                             category: siteRules[domain], usage: siteUsage[domain],
                             pill: CategoryPill(selection: siteBinding(domain)))
                }
            }
            if !loaded { ProgressView().frame(maxWidth: .infinity) }
        }
    }

    /// "Non segnata" toglie la regola: il sito resta in elenco finché non riapri la pagina.
    private func siteBinding(_ domain: String) -> Binding<Category?> {
        Binding(
            get: { siteRules[domain] },
            set: {
                siteRules[domain] = $0
                if $0 != nil && !domainOrder.contains(domain) { domainOrder.insert(domain, at: 0) }
                save()
            }
        )
    }

    private func addLink() {
        guard let domain = Self.domain(from: newLink) else {
            linkError = "Link non valido."
            return
        }
        linkError = nil
        siteBinding(domain).wrappedValue = newCategory
        if !sites.contains(domain) { sites.insert(domain, at: 0) }
        newLink = ""
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
        let domains = entries.filter { $0.type == .domain }
        siteRules = Dictionary(domains.map { ($0.match, $0.category) }, uniquingKeysWith: { first, _ in first })
        domainOrder = domains.map(\.match)
    }

    private func save() {
        let bundles = bundleRules
            .sorted { $0.key < $1.key }
            .map { Rule(match: $0.key, type: .bundle, category: $0.value) }
        let domains = domainOrder.compactMap { domain in
            siteRules[domain].map { Rule(match: domain, type: .domain, category: $0) }
        }
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
