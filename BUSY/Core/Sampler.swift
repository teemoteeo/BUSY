import AppKit
import Combine
import CoreGraphics

@MainActor
final class Sampler: ObservableObject {
    private static let idleThreshold: TimeInterval = 300
    private static let idleInterval: TimeInterval = 60
    // 2.5 s tra letture: lascia sempre completare il timeout di 2 s dello script
    // prima del prossimo tick, altrimenti ogni lettura viene cancellata in corsa
    // con la successiva e il pallino non si aggiorna mai (bug: aggiornamento fermo).
    private static let browserInterval: TimeInterval = 2.5
    private static let resumeInterval: TimeInterval = 2
    // kCGAnyInputEventType è ~0 nell'SDK. .null rappresenta l'evento nullo,
    // non tutti gli input: per l'idle serve il valore documentato da Apple.
    private static let anyInputEvent = CGEventType(rawValue: UInt32.max)!

    struct State: Equatable {
        var appName = "In attesa"
        var bundleID = ""
        var domain: String?
        var category: Category = .unknown
    }

    @Published private(set) var currentState = State()
    @Published private(set) var rulesError: String?
    @Published private(set) var storageError: String?
    @Published private(set) var isReady = false
    /// Cambia a ogni ricarica delle regole: la UI lo usa per ricalcolare i totali.
    @Published private(set) var rulesVersion = 0
    private var rulesWatcher: DispatchSourceFileSystemObject?
    let rules = Rules()
    private var database: Database?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?
    private var browserTimer: Timer?
    private var idleTimer: Timer?
    private var resumeTimer: Timer?
    private var sampleTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var generation = 0
    private var started = false
    private var sleeping = false
    private var inactiveSession = false
    private var poweringOff = false
    private var terminating = false
    private var suspended: Bool { sleeping || inactiveSession || poweringOff || terminating }

    func start() async {
        guard !started else { return }
        started = true
        reloadRules()
        do {
            database = try await Database()
            try await closePendingSession()
            isReady = true
        } catch { storageError = error.localizedDescription }
        installObservers()
        watchRules()
        let timer = Timer(timeInterval: Self.idleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sample()
    }

    private func closePendingSession(at now: Date = Date()) async throws {
        if let last = try await database?.lastSample(), last.category != .paused {
            let date = min(now, last.timestamp.addingTimeInterval(Self.idleThreshold))
            await writePauseMarker(at: date)
        }
    }

    private func installObservers() {
        observeWorkspace(NSWorkspace.didActivateApplicationNotification) { $0.sample() }
        observeWorkspace(NSWorkspace.willSleepNotification) {
            $0.sleeping = true
            $0.pause()
        }
        observeWorkspace(NSWorkspace.willPowerOffNotification) {
            $0.poweringOff = true
            $0.pause()
        }
        observeWorkspace(NSWorkspace.sessionDidResignActiveNotification) {
            $0.inactiveSession = true
            $0.pause()
        }
        observeWorkspace(NSWorkspace.didWakeNotification) {
            $0.sleeping = false
            $0.sample()
        }
        observeWorkspace(NSWorkspace.sessionDidBecomeActiveNotification) {
            $0.inactiveSession = false
            $0.sample()
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminate() }
        }
    }

    private func observeWorkspace(_ name: Notification.Name,
                                  action: @escaping @MainActor (Sampler) -> Void) {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        workspaceObservers.append(token)
    }

    func reloadRules() {
        do { try rules.reload(); rulesError = nil }
        catch { rulesError = error.localizedDescription }
        rulesVersion += 1
        if started && !workspaceObservers.isEmpty { sample() }
    }

    /// Apre rules.json nell'editor predefinito. Al salvataggio le regole si
    /// ricaricano da sole (vedi watchRules), niente più "Ricarica regole".
    func editRules() {
        NSWorkspace.shared.open(rules.fileURL)
    }

    // Gli editor salvano spesso in modo atomico (file nuovo + rename): il vecchio
    // descrittore punta al file cancellato, quindi dopo ogni evento lo riapriamo.
    private func watchRules() {
        rulesWatcher?.cancel()
        rulesWatcher = nil
        let descriptor = open(rules.fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Breve attesa: lascia finire la scrittura prima di rileggere.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated {
                        self.reloadRules()
                        self.watchRules()
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        rulesWatcher = source
        source.resume()
    }

    private func checkIdle() {
        guard !suspended else { return }
        let idle = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: Self.anyInputEvent)
        handleIdle(idle, at: Date())
    }

    private func handleIdle(_ idle: TimeInterval, at date: Date) {
        guard !suspended else { return }
        guard idle.isFinite, idle >= 0 else { return }
        if idle >= Self.idleThreshold && currentState.category != .paused {
            pause(at: date.addingTimeInterval(-idle))
        } else if idle < Self.idleThreshold && currentState.category == .paused {
            // Il tick misura solo l'idle. La ripresa usa il normale task di campionamento.
            sample()
        }
    }

    private static func pauseSession(at date: Date) -> Session {
        Session(timestamp: date, bundleID: "__paused__", domain: nil,
                category: .paused, matchedRule: nil)
    }

    private func writePauseMarker(at date: Date = Date()) async {
        guard let database else { return }
        do {
            try await database.insertSample(Self.pauseSession(at: date))
            if storageError != nil { storageError = nil }
        } catch { storageError = error.localizedDescription }
    }

    private func pause(at date: Date = Date()) {
        generation += 1
        sampleTask?.cancel()
        stopBrowserTimer()
        setState(State(appName: "BUSY", bundleID: "__paused__", category: .paused))
        if suspended { stopResumeTimer() } else { startResumeTimer() }
        let previousPause = pauseTask
        pauseTask = Task { [weak self] in
            await previousPause?.value
            await self?.writePauseMarker(at: date)
        }
    }

    private func terminate() {
        terminating = true
        generation += 1
        sampleTask?.cancel()
        pauseTask?.cancel()
        stopBrowserTimer()
        stopResumeTimer()
        idleTimer?.invalidate()
        idleTimer = nil
        do {
            // queue.sync aspetta il commit prima del ritorno dalla notifica.
            try database?.insertSampleSync(Self.pauseSession(at: Date()))
        } catch {
            storageError = error.localizedDescription
            NSLog("BUSY: impossibile salvare la pausa in terminazione: %@", error.localizedDescription)
        }
    }

    private func sample() {
        guard !suspended else { return }
        generation += 1
        let request = generation
        sampleTask?.cancel()
        // Anche cambi focus automatici devono rispettare una pausa per inattività.
        if currentState.category == .paused {
            let idle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: Self.anyInputEvent)
            if idle.isFinite && idle >= Self.idleThreshold {
                startResumeTimer()
                return
            }
        }
        stopResumeTimer()
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            stopBrowserTimer()
            setState(State())
            return
        }
        let isBrowser = BrowserURLReader.supported.contains(bundleID)
        if isBrowser {
            if browserTimer == nil {
                let timer = Timer(timeInterval: Self.browserInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                }
                browserTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else { stopBrowserTimer() }
        let timestamp = Date()
        let name = app.localizedName ?? bundleID
        let pid = app.processIdentifier
        let pendingPause = pauseTask
        publishAppChange(bundleID: bundleID, name: name, isBrowser: isBrowser)
        sampleTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let url = isBrowser ? await BrowserURLReader.readURL(bundleID: bundleID) : nil
            guard !Task.isCancelled, let self, self.generation == request,
                  !self.suspended,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            // Una lettura fallita non conferma che la scheda sia ancora quella
            // precedente: classifica senza dominio e registra il cambio di stato.
            let domain = url.flatMap(BrowserURLReader.domain(from:))
            let result = Classifier.classify(bundleID: bundleID, domain: domain,
                                             isBrowser: isBrowser, rules: self.rules.entries)
            self.setState(State(appName: name, bundleID: bundleID,
                                domain: domain, category: result.category))
            // Solo la persistenza aspetta il marker precedente, non il pallino.
            await pendingPause?.value
            guard !Task.isCancelled, self.generation == request, !self.suspended,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let database = self.database else { return }
            do {
                try await database.insertSample(Session(timestamp: timestamp, bundleID: bundleID,
                    domain: domain, category: result.category, matchedRule: result.matchedRule))
                if self.storageError != nil { self.storageError = nil }
            } catch { self.storageError = error.localizedDescription }
        }
    }

    // @Published notifica a ogni assegnazione, anche se il valore è identico: senza
    // questo controllo ogni tick del browser (2,5 s) ridisegnerebbe tutte le viste.
    private func setState(_ state: State) {
        if currentState != state { currentState = state }
    }

    private func publishAppChange(bundleID: String, name: String, isBrowser: Bool) {
        let fallback = Classifier.classify(bundleID: bundleID, domain: nil,
                                            isBrowser: isBrowser, rules: rules.entries)
        // Il cambio app si riflette subito nella UI, prima di qualsiasi await.
        // Su un nuovo browser il grigio evita di mostrare il colore dell'app precedente.
        // Nei tick dello stesso browser conserviamo il colore solo fino alla risposta,
        // inclusa una risposta senza URL leggibile.
        if !isBrowser || currentState.bundleID != bundleID {
            setState(State(appName: name, bundleID: bundleID,
                           category: fallback.category))
        }
    }

    func recap(from: Date, to: Date) async throws -> Recap {
        guard let database else {
            throw NSError(domain: "BUSY", code: 1, userInfo: [NSLocalizedDescriptionKey:
                storageError ?? "Database in apertura"])
        }
        await pauseTask?.value
        if currentState.category != .paused { await sampleTask?.value }
        let samples = try await database.samplesInRange(from: from, to: to)
        return Recap.aggregate(reclassified(samples), from: from, to: to)
    }

    // Il colore salvato nel DB è quello delle regole di quel momento. Nel recap
    // ricalcoliamo con le regole attuali, così una modifica vale anche sul passato.
    // Pause e URL illeggibili (browser senza dominio) restano come sono.
    private func reclassified(_ samples: [Session]) -> [Session] {
        samples.map { sample in
            guard sample.category != .paused else { return sample }
            let isBrowser = BrowserURLReader.supported.contains(sample.bundleID)
            if isBrowser && sample.domain == nil { return sample }
            let result = Classifier.classify(bundleID: sample.bundleID, domain: sample.domain,
                                             isBrowser: isBrowser, rules: rules.entries)
            return Session(id: sample.id, timestamp: sample.timestamp, bundleID: sample.bundleID,
                           domain: sample.domain, category: result.category,
                           matchedRule: result.matchedRule)
        }
    }

    private func stopBrowserTimer() {
        browserTimer?.invalidate()
        browserTimer = nil
    }

    // Solo durante una pausa idle: un cambio tab al ritorno non deve aspettare
    // il controllo globale da 60 s. Non esegue letture URL finché l'utente è idle.
    private func startResumeTimer() {
        guard !suspended, resumeTimer == nil else { return }
        let timer = Timer(timeInterval: Self.resumeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        resumeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopResumeTimer() {
        resumeTimer?.invalidate()
        resumeTimer = nil
    }

    deinit {
        rulesWatcher?.cancel()
        sampleTask?.cancel()
        pauseTask?.cancel()
        browserTimer?.invalidate()
        idleTimer?.invalidate()
        resumeTimer?.invalidate()
        for token in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }
}
