import SwiftUI
import AppKit
import Combine
import ServiceManagement

// MenuBarExtra accetta solo un'immagine statica come label: niente animazioni e
// padding fisso. Con NSStatusItem + Core Animation lo switch scorre in modo fluido
// e la larghezza della voce è esattamente quella dello switch.
@main
struct BUSYApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let sampler = Sampler()
    private var statusItem: NSStatusItem!
    private let switchView = StatusSwitchView()
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    /// Vero solo al primo avvio, finché la procedura guidata è aperta.
    private var onboarding = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: StatusSwitchView.itemWidth)
        if let button = statusItem.button {
            switchView.frame = button.bounds
            switchView.autoresizingMask = [.width, .height]
            button.addSubview(switchView)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityLabel("BUSY")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: StatusBarView(sampler: sampler,
                                    openWindow: { [weak self] in self?.openWindow(tab: $0) }))

        sampler.$currentState
            .map(\.category)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] category in
                MainActor.assumeIsolated { self?.switchView.setCategory(category, animated: true) }
            }
            .store(in: &cancellables)

        Appearance.apply()
        switchView.setCategory(sampler.currentState.category, animated: false)
        Task {
            await sampler.start()
            // Solo al primo avvio: la procedura guidata. Chiusa la finestra, non torna più.
            if sampler.rules.isFirstRun {
                onboarding = true
                openWindow()
            }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Una sola finestra con sidebar: Recap, Regole (App, Siti), Impostazioni. Se è già aperta la porta
    /// davanti senza toccarla; con `tab` passa a quella scheda.
    private func openWindow(tab: MainTab? = nil) {
        popover.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "BUSY"
            // Come le app Apple con sidebar: barra unificata, sidebar fino in cima sotto i
            // pulsanti della finestra. Su macOS 26 solo una finestra con toolbar ha gli angoli
            // ampi, concentrici con quelli della sidebar di vetro: serve anche se vuota.
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            // Il titolo nella barra è piccolo: MainDetail ne mette uno più grande.
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Come Impostazioni di Sistema: larghezza fissa (sidebar 230 + pagina più stretta 620),
            // si allunga solo in altezza; niente tutto schermo, il pulsante verde allunga al massimo.
            window.contentMinSize = NSSize(width: 860, height: 580)
            window.contentMaxSize = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
            window.collectionBehavior.insert(.fullScreenNone)
            mainWindow = window
        }
        let reopening = mainWindow?.contentViewController == nil
        // Vista nuova a ogni apertura (riparte da "Oggi" e rilegge le regole).
        if reopening || tab != nil {
            if onboarding {
                let host = NSHostingController(rootView: OnboardingView(sampler: sampler) { [weak self] in
                    self?.onboarding = false
                    self?.openWindow(tab: .recap)
                })
                // Il titolo della pagina passa alla finestra.
                host.sceneBridgingOptions = [.title]
                mainWindow?.contentViewController = host
            } else {
                mainWindow?.contentViewController = MainSplitViewController(sampler: sampler, tab: tab ?? .recap)
            }
        }
        // Il contenuto nuovo stringe la finestra alla sua misura minima: si riporta a quella iniziale.
        if reopening {
            mainWindow?.setContentSize(NSSize(width: 860, height: 760))
            mainWindow?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sampler.terminate()
    }

    // Una finestra chiusa resta viva (isReleasedWhenClosed = false) e la sua vista
    // continuerebbe a ridisegnarsi a ogni campione del Sampler: su macOS 26 ogni
    // ridisegno di un Picker segmentato perde memoria (~300 MB in 3 giorni).
    // La vista si ricrea comunque a ogni apertura.
    func windowWillClose(_ notification: Notification) {
        onboarding = false
        (notification.object as? NSWindow)?.contentViewController = nil
    }
}

enum MainTab: Hashable {
    case recap, apps, sites, settings
    var title: String {
        switch self {
        case .recap: return "Recap"
        case .apps: return "App"
        case .sites: return "Siti"
        case .settings: return "Impostazioni"
        }
    }
}

/// Sidebar di AppKit e non NavigationSplitView: su macOS 26 è la stessa sidebar di vetro
/// staccata dai bordi delle app Apple e, con canCollapse = false, trascinando il bordo
/// non si chiude (come in Impostazioni di Sistema).
final class MainSplitViewController: NSSplitViewController {
    init(sampler: Sampler, tab: MainTab) {
        super.init(nibName: nil, bundle: nil)
        let nav = MainNavigation(tab: tab)
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: MainSidebar(nav: nav)))
        sidebar.canCollapse = false
        sidebar.minimumThickness = 230
        sidebar.maximumThickness = 230
        let detail = NSHostingController(rootView: MainDetail(sampler: sampler, nav: nav))
        // Il titolo e la barra della pagina passano alla finestra.
        detail.sceneBridgingOptions = [.title, .toolbars]
        addSplitViewItem(sidebar)
        addSplitViewItem(NSSplitViewItem(viewController: detail))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }
}

@Observable final class MainNavigation {
    /// Un clic nella sidebar chiude la scheda dell'app.
    var tab: MainTab { didSet { statsFocus = nil } }
    /// App o sito cliccato nelle Regole o nella Top 10: al posto della pagina si vede la sua scheda.
    var statsFocus: String?
    init(tab: MainTab) { self.tab = tab }
}

struct MainSidebar: View {
    @Bindable var nav: MainNavigation

    var body: some View {
        List(selection: $nav.tab) {
            row("Recap", "chart.bar.fill", .blue).tag(MainTab.recap)
            Section("Regole") {
                row("App", "square.grid.2x2.fill", .indigo).tag(MainTab.apps)
                row("Siti", "globe", .teal).tag(MainTab.sites)
            }
            row("Impostazioni", "gearshape.fill", .gray).tag(MainTab.settings)
        }
        .listStyle(.sidebar)
        // Righe alte come in Impostazioni di Sistema.
        .environment(\.sidebarRowSize, .large)
        .safeAreaInset(edge: .bottom) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("Mac acceso da \(Self.uptime(at: context.date))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    /// Icona bianca su riquadro colorato, come le voci di Impostazioni di Sistema.
    private func row(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// Avvio del Mac (kern.boottime): l'uptime include il tempo in stop, come `uptime`.
    private static let bootDate: Date? = {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }()

    private static func uptime(at now: Date) -> String {
        guard let bootDate else { return "—" }
        let seconds = now.timeIntervalSince(bootDate)
        let days = Int(seconds / 86_400)
        return days > 0 ? "\(days)g \(Totals.duration(seconds.truncatingRemainder(dividingBy: 86_400)))"
                        : Totals.duration(seconds)
    }
}

struct MainDetail: View {
    let sampler: Sampler
    let nav: MainNavigation

    var body: some View {
        let openStats: (String) -> Void = { nav.statsFocus = $0 }
        let title = nav.statsFocus.map(AppName.display) ?? nav.tab.title
        Group {
            if let statsFocus = nav.statsFocus {
                AppStatsView(sampler: sampler, name: statsFocus) { nav.statsFocus = nil }
                    .id(statsFocus)
            } else {
                switch nav.tab {
                case .recap: RecapView(sampler: sampler, openStats: openStats)
                case .apps: RulesEditorView(sampler: sampler, tab: .apps, openStats: openStats)
                case .sites: RulesEditorView(sampler: sampler, tab: .sites, openStats: openStats)
                case .settings: SettingsView(sampler: sampler)
                }
            }
        }
        // Liste e moduli senza il loro fondo bianco: si vede lo sfondo smorzato.
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        // Il titolo di sistema nella barra è piccolo (15 pt) e non si ingrandisce: al suo posto
        // un elemento della barra senza vetro. Sotto la barra il contenuto finirebbe sfocato.
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .navigation) { Self.title(title) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { Self.title(title) }
            }
        }
        // Nascosto nella barra, serve per il menu Finestra e Mission Control.
        .navigationTitle(title)
    }

    private static func title(_ text: String) -> some View {
        Text(text).font(.title.bold()).padding(.leading, 4)
    }
}

/// Tema dell'app (finestra e pannello del menu), salvato tra un avvio e l'altro.
/// "Sistema" segue Impostazioni di Sistema. Lo switch nella barra dei menu non cambia.
enum Appearance: String, CaseIterable {
    case system = "Sistema", light = "Chiaro", dark = "Scuro"
    static let key = "appearance"

    static func apply(_ value: Appearance? = nil) {
        let value = value ?? Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        NSApp.appearance = switch value {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    let sampler: Sampler
    @AppStorage(Appearance.key) private var appearance: Appearance = .system
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var defaultCategory: Category = .unknown
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                Picker("Aspetto", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: appearance) { _, value in Appearance.apply(value) }
            }
            Section {
                // Secondo Text nell'etichetta: sottotitolo sotto il nome, come in Impostazioni di Sistema.
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    Text("Apri all'accensione del Mac")
                    Text("Importante: BUSY registra solo mentre è aperta. Attivala all'accensione per avere la cronologia completa, senza buchi.")
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(Theme.red) }
            }
            Section {
                Picker("App e siti non segnati", selection: Binding(
                    get: { defaultCategory }, set: { setDefault($0) })) {
                    Text("Grigi (non contano)").tag(Category.unknown)
                    Text(Category.green.title).tag(Category.green)
                    Text(Category.red.title).tag(Category.red)
                }
                if let saveError { Text(saveError).font(.caption).foregroundStyle(Theme.red) }
            } footer: {
                HStack {
                    Text("Le modifiche valgono subito, anche sul passato.")
                    Spacer()
                    Button("Apri rules.json") { sampler.editRules() }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 300)
        // Si può cambiare anche da Impostazioni di Sistema → Generali → Elementi login.
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            defaultCategory = sampler.rules.entries.last(where: { $0.type == .default })?.category ?? .red
        }
    }

    private func setDefault(_ category: Category) {
        do {
            try sampler.rules.setDefault(category)
            sampler.reloadRules()
            defaultCategory = category
            saveError = nil
        } catch { saveError = error.localizedDescription }
    }

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
}

/// Switch in stile macOS 26: binario a capsula con bordo chiaro e pomello a
/// capsula allungato, grigio perla. Il binario è verde/rosso acceso invece del blu.
final class StatusSwitchView: NSView {
    static let itemWidth: CGFloat = 32
    private static let trackSize = CGSize(width: 32, height: 16)
    private static let knobSize = CGSize(width: 20, height: 14)
    private static let inset: CGFloat = 1

    private let track = CALayer()
    private let knob = CAGradientLayer()
    private var category: Category = .unknown

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.cornerRadius = Self.trackSize.height / 2
        track.borderWidth = 1
        track.borderColor = NSColor.white.withAlphaComponent(0.75).cgColor

        knob.colors = [NSColor(white: 0.97, alpha: 1).cgColor, NSColor(white: 0.86, alpha: 1).cgColor]
        knob.startPoint = CGPoint(x: 0.5, y: 1)
        knob.endPoint = CGPoint(x: 0.5, y: 0)
        knob.cornerRadius = Self.knobSize.height / 2
        knob.borderWidth = 0.5
        knob.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -0.5)

        layer?.addSublayer(track)
        layer?.addSublayer(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    // I click passano al bottone della status item.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyLayout()
        CATransaction.commit()
    }

    func setCategory(_ newValue: Category, animated: Bool) {
        category = newValue
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.32)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(controlPoints: 0.25, 1.0, 0.35, 1.0))
        } else {
            CATransaction.setDisableActions(true)
        }
        applyLayout()
        CATransaction.commit()
    }

    private func applyLayout() {
        let origin = CGPoint(x: (bounds.width - Self.trackSize.width) / 2,
                             y: (bounds.height - Self.trackSize.height) / 2)
        track.frame = CGRect(origin: origin, size: Self.trackSize)

        let minX = track.frame.minX + Self.inset + Self.knobSize.width / 2
        let maxX = track.frame.maxX - Self.inset - Self.knobSize.width / 2
        let color: NSColor
        let x: CGFloat
        switch category {
        case .green: color = Theme.greenNS; x = maxX
        case .red: color = Theme.redNS; x = minX
        case .paused, .unknown: color = Theme.neutralNS; x = (minX + maxX) / 2
        }
        track.backgroundColor = color.cgColor
        knob.bounds = CGRect(origin: .zero, size: Self.knobSize)
        knob.position = CGPoint(x: x, y: track.frame.midY)
    }
}
