import Foundation

/// Ciche pobieranie w tle: gdy jest internet, wszystkie piosenki z playlist, których nie ma jeszcze na dysku,
/// są pobierane po jednej (bez pasków i komunikatów). Startuje przy uruchomieniu, po zmianie biblioteki
/// i za każdym razem, gdy internet wraca. Bieżąca piosenka i następna mają pierwszeństwo (urgent).
actor BackgroundSync {
    static let shared = BackgroundSync()

    private var ids: [String] = []
    private var running = false

    func update(_ newIDs: [String]) {
        var seen = Set<String>()
        ids = newIDs.filter { seen.insert($0).inserted }
        kick()
    }

    func kick() {
        guard !running, !ids.isEmpty, Reachability.shared.online else { return }
        running = true
        Task(priority: .utility) { await self.run() }
    }

    private func run() async {
        var failed = Set<String>()
        outer: while Reachability.shared.online {
            for id in ids where !failed.contains(id) {
                if await AudioCache.shared.localURL(for: id) != nil { continue }
                if Task.isCancelled || !Reachability.shared.online { break outer }
                let ok = await AudioCache.shared.ensure(id, urgent: false) != nil
                if !ok { failed.insert(id) }
                continue outer      // lista mogła się zmienić w trakcie - szukamy od nowa
            }
            break
        }
        running = false
    }
}
