import SwiftUI
import AppKit
import Combine

extension Category {
    var color: Color {
        switch self {
        case .green: return .green
        case .red: return .red
        case .paused, .unknown: return .gray
        }
    }
}

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

        switchView.setCategory(sampler.currentState.category, animated: false)
        Task { await sampler.start() }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Una sola finestra con le schede Recap e Regole. Se è già aperta la porta
    /// davanti senza toccarla; con `tab` passa a quella scheda.
    private func openWindow(tab: MainTab? = nil) {
        popover.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "BUSY"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 660, height: 760))
            window.center()
            mainWindow = window
        }
        // Vista nuova a ogni apertura (riparte da "Oggi" e rilegge le regole).
        if mainWindow?.contentViewController == nil || tab != nil {
            mainWindow?.contentViewController = NSHostingController(
                rootView: MainView(sampler: sampler, tab: tab ?? .recap))
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    // Una finestra chiusa resta viva (isReleasedWhenClosed = false) e la sua vista
    // continuerebbe a ridisegnarsi a ogni campione del Sampler: su macOS 26 ogni
    // ridisegno di un Picker segmentato perde memoria (~300 MB in 3 giorni).
    // La vista si ricrea comunque a ogni apertura.
    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.contentViewController = nil
    }
}

enum MainTab { case recap, rules }

struct MainView: View {
    let sampler: Sampler
    @State var tab: MainTab

    var body: some View {
        TabView(selection: $tab) {
            RecapView(sampler: sampler).tabItem { Text("Recap") }.tag(MainTab.recap)
            RulesEditorView(sampler: sampler).tabItem { Text("Regole") }.tag(MainTab.rules)
        }
        .padding(.top, 8)
    }
}

/// Switch in stile macOS 26: binario a capsula con bordo chiaro e pomello a
/// capsula allungato, grigio perla. Il binario è verde/rosso acceso invece del blu.
final class StatusSwitchView: NSView {
    static let itemWidth: CGFloat = 32
    private static let trackSize = CGSize(width: 32, height: 16)
    private static let knobSize = CGSize(width: 20, height: 14)
    private static let inset: CGFloat = 1
    private static let brightGreen = NSColor(srgbRed: 0.10, green: 0.82, blue: 0.30, alpha: 1)
    private static let brightRed = NSColor(srgbRed: 1.00, green: 0.20, blue: 0.22, alpha: 1)
    private static let neutral = NSColor(white: 0.40, alpha: 1)

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
        case .green: color = Self.brightGreen; x = maxX
        case .red: color = Self.brightRed; x = minX
        case .paused, .unknown: color = Self.neutral; x = (minX + maxX) / 2
        }
        track.backgroundColor = color.cgColor
        knob.bounds = CGRect(origin: .zero, size: Self.knobSize)
        knob.position = CGPoint(x: x, y: track.frame.midY)
    }
}
