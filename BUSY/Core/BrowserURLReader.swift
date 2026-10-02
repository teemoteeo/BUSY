import Foundation

enum BrowserURLReader {
    static let supported: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"
    ]
    private static let queue = DispatchQueue(label: "BUSY.appleScript", qos: .utility)
    private static let responseTimeout: TimeInterval = 2
    private static let scriptTimeoutSeconds = 2

    // Script e deadline possono finire contemporaneamente: riprendiamo una sola volta.
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: String?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static let lock = NSLock()
    private static var reading = false
    // Compilati una volta e riusati: prima ogni tick da 2,5 s ricompilava lo script.
    // Accesso solo da `queue` (seriale).
    private static var scripts: [String: NSAppleScript] = [:]

    private static func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !reading else { return false }
        reading = true
        return true
    }

    private static func release() {
        lock.lock()
        reading = false
        lock.unlock()
    }

    static func domain(from url: String) -> String? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    static func readURL(bundleID: String) async -> String? {
        guard supported.contains(bundleID) else { return nil }
        return await execute {
            let command: String
            switch bundleID {
            case "com.apple.Safari":
                command = "tell application \"Safari\" to get URL of front document"
            case "com.google.Chrome":
                command = "tell application \"Google Chrome\" to get URL of active tab of front window"
            default:
                command = "tell application \"Arc\" to get URL of active tab of front window"
            }
            guard let script = scripts[bundleID]
                ?? NSAppleScript(source: "with timeout of \(scriptTimeoutSeconds) seconds\n\(command)\nend timeout")
            else { return nil }
            scripts[bundleID] = script
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil, let value = result.stringValue, !value.isEmpty else { return nil }
            return value
        }
    }

    private static func execute(_ operation: @escaping () -> String?) async -> String? {
        // Evita accodamenti illimitati mentre un dialogo Automation resta aperto.
        guard acquire() else { return nil }
        return await withCheckedContinuation { continuation in
            let request = Request(continuation)
            // Deadline indipendente: anche il dialogo Automation può fermare lo script.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + responseTimeout) {
                request.finish(nil)
            }
            queue.async {
                let url = autoreleasepool(invoking: operation)
                // Il lock resta occupato finché lo script termina davvero, anche
                // se la deadline ha già restituito nil al chiamante.
                release()
                request.finish(url)
            }
        }
    }
}
