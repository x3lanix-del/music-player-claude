import Foundation
import Network

/// Czy telefon ma teraz internet. Dzięki temu brak sieci nie jest mylony z "nie znaleziono tekstu".
final class Reachability: @unchecked Sendable {
    static let shared = Reachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _online = true

    var online: Bool {
        lock.lock(); defer { lock.unlock() }
        return _online
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            let was = self._online
            self._online = (path.status == .satisfied)
            let now = self._online
            self.lock.unlock()
            // Internet wrócił: dociągnij w tle brakujące piosenki.
            if now && !was { Task { await BackgroundSync.shared.kick() } }
        }
        monitor.start(queue: DispatchQueue(label: "musicplayer.reachability"))
    }
}
