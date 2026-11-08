import Foundation

/// Masowe pobieranie piosenek w tle (np. po zaimportowaniu playlisty) z licznikiem postępu.
@MainActor
final class DownloadMonitor: ObservableObject {
    static let shared = DownloadMonitor()

    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var failed = 0

    var active: Bool { total > 0 && done + failed < total }

    private var pending: [String] = []
    private var known = Set<String>()
    private var running = false

    /// Dodaje piosenki do kolejki pobierania (3 naraz). Już pobrane są pomijane.
    func enqueue(_ ids: [String]) {
        var added = 0
        for id in ids where !known.contains(id) {
            known.insert(id)
            pending.append(id)
            added += 1
        }
        guard added > 0 else { return }
        if !active { total = 0; done = 0; failed = 0 }
        total += added
        if !running {
            running = true
            Task { await self.runAll() }
        }
    }

    private func runAll() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    while let id = await self.next() {
                        if await AudioCache.shared.localURL(for: id) != nil {
                            await self.finish(ok: true)
                            continue
                        }
                        let ok = await AudioCache.shared.ensure(id, urgent: false) != nil
                        await self.finish(ok: ok)
                    }
                }
            }
        }
        running = false
        known.removeAll()
        // Pasek postępu znika po chwili.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if !running && !active { total = 0; done = 0; failed = 0 }
    }

    private func next() -> String? { pending.isEmpty ? nil : pending.removeFirst() }

    private func finish(ok: Bool) {
        if ok { done += 1 } else { failed += 1 }
    }
}

/// Postęp pobierania poszczególnych piosenek (0...1, -1 = rozmiar nieznany). Pokazuje go odtwarzacz.
@MainActor
final class DownloadProgress: ObservableObject {
    static let shared = DownloadProgress()

    @Published private(set) var fraction: [String: Double] = [:]

    func set(_ id: String, _ value: Double) {
        let v = value < 0 ? -1 : min(value, 1)
        // aktualizacja co ~1%, żeby nie przerysowywać ekranu bez potrzeby
        if let old = fraction[id], abs(old - v) < 0.01, v >= 0 { return }
        fraction[id] = v
    }

    func clear(_ id: String) { fraction[id] = nil }
}
