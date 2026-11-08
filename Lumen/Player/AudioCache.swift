import Foundation

/// Trwały zapis piosenek na dysku. Pierwsze odtworzenie leci ze strumienia, a w tle utwór jest pobierany
/// do końca i zostaje na stałe - każde kolejne odtworzenie startuje natychmiast i działa bez internetu.
actor AudioCache {
    static let shared = AudioCache()

    private let dir: URL
    private let session: URLSession
    private var inflight: [String: Task<URL?, Never>] = [:]
    private var slots = 0
    private let maxSlots = 3
    private var urgentWaiters: [CheckedContinuation<Void, Never>] = []
    private var normalWaiters: [CheckedContinuation<Void, Never>] = []

    /// yt-dlp pobiera w kawałkach ~10 MB, bo YouTube dławi długie, pojedyncze żądania.
    private static let chunk = 9_437_184

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true      // duże pliki nie lecą do iCloud
        try? folder.setResourceValues(values)
        dir = folder
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    // MARK: Lookup

    /// Pobrany plik utworu (jeśli już jest na dysku).
    func localURL(for id: String) -> URL? {
        for ext in ["m4a", "mp4"] {
            let url = dir.appendingPathComponent("\(id).\(ext)")
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 50_000 {
                return url
            }
        }
        return nil
    }

    func remove(id: String) {
        for ext in ["m4a", "mp4"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).\(ext)"))
        }
    }

    /// Usuwa wszystkie pobrane piosenki. Zwraca liczbę usuniętych plików.
    @discardableResult
    func removeAll() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var n = 0
        for f in files {
            if (try? FileManager.default.removeItem(at: f)) != nil, f.pathExtension != "part" { n += 1 }
        }
        return n
    }

    func stats() -> (count: Int, bytes: Int64) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var count = 0
        var bytes: Int64 = 0
        for f in files where f.pathExtension == "m4a" || f.pathExtension == "mp4" {
            count += 1
            bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (count, bytes)
    }

    // MARK: Download

    /// Upewnia się, że utwór jest na dysku (pobiera go, jeśli trzeba). Zwraca adres pliku.
    /// `urgent` = bieżący / następny utwór (omija kolejkę masowego pobierania playlisty).
    @discardableResult
    func ensure(_ id: String, urgent: Bool = true) async -> URL? {
        if let local = localURL(for: id) { return local }
        if let running = inflight[id] { return await running.value }
        await DownloadProgress.shared.set(id, 0)
        let task = Task<URL?, Never> { await self.fetch(id, urgent: urgent) }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        await DownloadProgress.shared.clear(id)
        if result != nil {
            // Do pobranej piosenki zapisujemy też jej dużą okładkę (tło i ekran odtwarzacza bez internetu).
            Task.detached(priority: .utility) { _ = await ArtworkLoader.shared.artwork(for: id) }
        }
        return result
    }

    private func acquire(urgent: Bool) async {
        if slots < maxSlots { slots += 1; return }
        await withCheckedContinuation { cont in
            if urgent { urgentWaiters.append(cont) } else { normalWaiters.append(cont) }
        }
    }

    private func release() {
        if !urgentWaiters.isEmpty { urgentWaiters.removeFirst().resume() }
        else if !normalWaiters.isEmpty { normalWaiters.removeFirst().resume() }
        else { slots -= 1 }
    }

    private func fetch(_ id: String, urgent: Bool) async -> URL? {
        await acquire(urgent: urgent)
        defer { release() }
        if let local = localURL(for: id) { return local }
        for attempt in 0..<2 {
            guard let stream = try? await StreamResolver.shared.resolve(id, forceRefresh: attempt > 0) else { continue }
            let target = dir.appendingPathComponent("\(id).\(stream.ext)")
            if await download(stream.url, to: target, id: id) { return target }
        }
        return nil
    }

    /// Pierwszy kawałek jest mały (żeby od razu znać rozmiar pliku i ruszyć), reszta w kawałkach po 1,5 MB.
    private static let firstChunk = 786_432
    private static let parallelChunk = 1_572_864
    private static let parallelism = 8

    nonisolated private func fetchRange(_ remote: URL, from: Int, to: Int) async -> (data: Data, total: Int?, status: Int)? {
        var request = URLRequest(url: remote)
        request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        var total: Int? = nil
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"), let t = Int(range[range.index(after: slash)...]) { total = t }
        return (data, total, http.statusCode)
    }

    /// Szybkie pobieranie: kawałki Range, do 8 równolegle w "przesuwanym oknie" - gdy jeden kawałek skończy,
    /// od razu startuje następny (bez czekania na najwolniejszy z paczki).
    private func download(_ remote: URL, to target: URL, id: String) async -> Bool {
        let part = target.appendingPathExtension("\(UUID().uuidString).part")
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: part) else { return false }
        defer { try? handle.close() }

        guard let first = await fetchRange(remote, from: 0, to: AudioCache.firstChunk - 1) else {
            try? fm.removeItem(at: part); return false
        }
        let total: Int
        switch first.status {
        case 206:
            guard let t = first.total else { try? fm.removeItem(at: part); return false }
            total = t
        case 200:
            total = first.data.count
        default:
            try? fm.removeItem(at: part); return false
        }
        do { try handle.write(contentsOf: first.data) } catch { try? fm.removeItem(at: part); return false }
        var written = first.data.count
        await DownloadProgress.shared.set(id, total > 0 ? Double(written) / Double(total) : -1)

        if first.status == 206 && written < total {
            var offsets = Array(stride(from: written, to: total, by: AudioCache.parallelChunk))
            let size = total
            let failed: Bool = await withTaskGroup(of: (Int, Data?).self) { group in
                func launch(_ off: Int) {
                    group.addTask {
                        let end = min(off + AudioCache.parallelChunk, size) - 1
                        for _ in 0..<3 {
                            if Task.isCancelled { return (off, nil) }
                            if let r = await self.fetchRange(remote, from: off, to: end),
                               r.status == 206, r.data.count == end - off + 1 { return (off, r.data) }
                        }
                        return (off, nil)
                    }
                }
                var inFlight = 0
                while inFlight < AudioCache.parallelism, !offsets.isEmpty {
                    launch(offsets.removeFirst()); inFlight += 1
                }
                while let (off, data) = await group.next() {
                    inFlight -= 1
                    guard let data = data else { group.cancelAll(); return true }
                    do { try handle.seek(toOffset: UInt64(off)); try handle.write(contentsOf: data) }
                    catch { group.cancelAll(); return true }
                    written += data.count
                    await DownloadProgress.shared.set(id, Double(written) / Double(total))
                    if !offsets.isEmpty { launch(offsets.removeFirst()); inFlight += 1 }
                }
                return false
            }
            if failed || Task.isCancelled { try? fm.removeItem(at: part); return false }
        }
        try? handle.close()
        guard written > 50_000, written == total else { try? fm.removeItem(at: part); return false }
        try? fm.removeItem(at: target)
        do { try fm.moveItem(at: part, to: target) } catch { try? fm.removeItem(at: part); return false }
        return true
    }
}
