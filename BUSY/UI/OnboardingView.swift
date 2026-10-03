import SwiftUI
import AppKit

/// Primo avvio: quattro passi nella finestra, come l'assistente di configurazione di macOS.
/// Benvenuto → app → siti → permesso dei browser → ultimi dettagli. Solo al primo avvio.
struct OnboardingView: View {
    let sampler: Sampler
    let finish: () -> Void
    @State private var step = 0

    private static let steps: [(title: String, text: String)] = [
        ("", ""),
        ("Segna le app che usi",
         "Verde: ci lavori. Rosso: ti distrae. Clic sulla pill per cambiare; puoi farlo anche dopo, nelle Regole."),
        ("Segna i siti",
         "Ecco i più comuni: scegli tu il colore, o incolla il link di un altro sito. Una regola vale anche per i sottodomini."),
        ("Consenti la lettura dei siti",
         "Per distinguere un sito di lavoro da uno che ti distrae, BUSY legge l'indirizzo della scheda attiva. macOS chiede il permesso una volta per browser."),
        ("Ultimi dettagli", "Attiva soprattutto l'apertura all'accensione del Mac: BUSY registra solo mentre è aperta. Il resto puoi cambiarlo più tardi in Impostazioni."),
    ]

    /// Proposti al passo dei siti, non segnati finché non scegli.
    private static let commonSites = [
        "youtube.com", "netflix.com", "primevideo.com", "twitch.tv", "instagram.com", "facebook.com",
        "tiktok.com", "reddit.com", "x.com", "amazon.it",
        "github.com", "stackoverflow.com", "notion.so", "figma.com", "linkedin.com", "slack.com",
        "mail.google.com", "docs.google.com", "chatgpt.com", "claude.ai",
    ]

    var body: some View {
        VStack(spacing: 0) {
            if step > 0 {
                VStack(alignment: .leading) {
                    Text(Self.steps[step].title).font(.title2.bold())
                    Text(Self.steps[step].text).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
            }
            Group {
                switch step {
                case 0: welcome
                case 1: RulesEditorView(sampler: sampler, tab: .apps)
                case 2: RulesEditorView(sampler: sampler, tab: .sites, suggestedSites: Self.commonSites)
                case 3: BrowserAccessStep()
                default: SettingsView(sampler: sampler)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Pulsanti sempre in fondo alla finestra: è il contenuto a stringersi, mai loro.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button("Salta introduzione", action: finish).buttonStyle(.link)
                Spacer()
                Text("Passo \(step + 1) di \(Self.steps.count)").foregroundStyle(.secondary)
                if step > 0 { Button("Indietro") { step -= 1 } }
                Button(step == Self.steps.count - 1 ? "Inizia" : "Continua") {
                    if step == Self.steps.count - 1 { finish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(alignment: .top) { Divider() }
        }
        // Stessa misura minima della finestra principale.
        .frame(minWidth: 860)
        .frame(minHeight: 580, idealHeight: 760)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Benvenuto in BUSY")
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Benvenuto in BUSY").font(.largeTitle.bold())
            Text("BUSY misura quanto tempo passi a lavorare e quanto a distrarti, guardando l'app e il sito in primo piano.")
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                legend(Theme.green, "Verde nella barra dei menu: stai lavorando.")
                legend(Theme.red, "Rosso: ti stai distraendo.")
                legend(Theme.unknown, "Al centro: in pausa o su qualcosa di non segnato.")
            }
            Text("I dati restano su questo Mac.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }
}

/// Un riga per browser installato: stato del permesso di Automazione e il pulsante giusto.
/// Lo stato si rilegge ogni 2 s, così cambia anche se rispondi da Impostazioni di Sistema.
private struct BrowserAccessStep: View {
    @State private var statuses: [String: OSStatus] = [:]
    private let browsers = BrowserURLReader.supported.sorted()
        .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }

    var body: some View {
        VStack(alignment: .leading) {
            if browsers.isEmpty {
                Text("Nessun browser supportato installato (Safari, Chrome, Arc): puoi saltare questo passo.")
                    .foregroundStyle(.secondary)
            }
            ForEach(browsers, id: \.self) { id in
                HStack(spacing: 10) {
                    ActivityIcon(name: id).frame(width: 22, height: 22)
                    Text(AppName.display(id))
                    Spacer()
                    status(id)
                }
                .controlSize(.small)
                Divider()
            }
            Spacer()
        }
        .padding()
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder private func status(_ id: String) -> some View {
        let status = Int(statuses[id] ?? noErr - 1)
        if status == Int(noErr) {
            Label("Consentito", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
        } else if status == errAEEventNotPermitted {
            Text("Negato").foregroundStyle(.secondary)
            Button("Apri Impostazioni") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        } else if status == procNotFound {
            Text("Va aperto per chiedere il permesso").foregroundStyle(.secondary)
            Button("Apri") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
        } else {
            Button("Consenti…") {
                Task {
                    _ = await Task.detached { BrowserURLReader.automationPermission(id, ask: true) }.value
                    await refresh()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func refresh() async {
        let ids = browsers
        statuses = await Task.detached {
            Dictionary(uniqueKeysWithValues: ids.map { ($0, BrowserURLReader.automationPermission($0, ask: false)) })
        }.value
    }
}
