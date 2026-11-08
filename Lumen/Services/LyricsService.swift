import Foundation

struct LyricsCandidate: Identifiable, Codable, Equatable, Sendable {
    var id: Int
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
    /// "LRCLIB", "NetEase", "Kugou", "BetterLyrics"...
    var source: String?
    /// true = `syncedLyrics` ma czasy słów/sylab ("enhanced LRC"). Stare wpisy z cache mają tu nil.
    var wordSynced: Bool? = nil

    var title: String { trackName ?? "" }
    var artist: String { artistName ?? "" }
    var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasWords: Bool { wordSynced == true && hasSynced }
    /// Unique across providers (ids of different services can be equal).
    var uid: String { "\(source ?? "?")-\(id)" }
}

enum LyricsResult: Equatable, Sendable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    /// Brak internetu (albo błąd sieci): to NIE znaczy, że tekstu nie ma - aplikacja spróbuje ponownie.
    case offline
}

/// Wynik wyszukiwania tekstu jednej piosenki.
struct LyricsLookup: Sendable {
    let result: LyricsResult
    let candidate: LyricsCandidate?
}

/// Time-synced lyrics from many free services at once (Apple Music TTML mirrors, LRCLIB, NetEase, Kugou...) -
/// the best matching version (title, artist and above all the same duration as the video) wins.
/// Results are cached on disk, so a song's lyrics are downloaded only once.
///
/// Szybkość:
/// - wszystkie źródła i wszystkie warianty tytułu startują naraz (z małym rozstawieniem), a nie jedno po drugim,
/// - tekst z czasem linijek pokazuje się od razu (`interim`), a wersja słowo po słowie podmienia go, gdy przyjdzie,
/// - ta sama piosenka nigdy nie jest szukana dwa razy jednocześnie (np. pobieranie z wyprzedzeniem + odtwarzanie),
/// - pobieranie całej biblioteki w tle ustępuje miejsca piosence, która właśnie gra.
actor LyricsService {
    static let shared = LyricsService()

    typealias Interim = @Sendable (LyricsCandidate) async -> Void

    private var memory: [String: LyricsCandidate] = [:]
    private var inflight: [String: Task<LyricsLookup, Never>] = [:]
    /// Ile wyszukiwań "na pierwszym planie" (grająca piosenka) trwa teraz - tło wtedy czeka.
    private var foreground = 0
    private var sawNetworkError = false
    private var prefetching = false
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 14
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "MusicPlayer/1.29 (iOS music player)"]
        session = URLSession(configuration: cfg)
    }

    // MARK: Public

    /// Tekst piosenki z pamięci, dysku albo internetu. `interim` dostaje tekst z czasem linijek, gdy jest gotowy
    /// wcześniej niż wersja słowo po słowie (którą zwraca dopiero wynik końcowy).
    func lyrics(for track: Track, foreground isForeground: Bool = false, interim: Interim? = nil) async -> LyricsLookup {
        if let c = cached(track.id) {
            return LyricsLookup(result: LyricsService.result(from: c), candidate: c)
        }
        // Ta piosenka już jest szukana (np. pobieranie z wyprzedzeniem): czekamy na ten sam wynik zamiast pytać drugi raz.
        if let running = inflight[track.id] {
            if isForeground { foreground += 1 }
            let out = await running.value
            if isForeground { foreground -= 1 }
            return out
        }
        let task = Task { await self.lookupFresh(track, interim: interim) }
        inflight[track.id] = task
        if isForeground { foreground += 1 }
        let out = await task.value
        if isForeground { foreground -= 1 }
        inflight[track.id] = nil
        return out
    }

    /// Tekst z pamięci albo z dysku (bez sieci).
    func cached(_ id: String) -> LyricsCandidate? {
        if let c = memory[id] { return c }
        if let c = readCache(id) {
            memory[id] = c
            return c
        }
        return nil
    }

    private func lookupFresh(_ track: Track, interim: Interim?) async -> LyricsLookup {
        // Nie polegamy na samym NWPathMonitor (bywa nieaktualny) - po prostu próbujemy.
        sawNetworkError = false
        var attempt = await find(track, interim: interim)
        // Drugie podejście tylko wtedy, gdy po drodze był błąd sieci (a nie zwykły brak tekstu) - wcześniej
        // każde "nie znaleziono" było szukane dwa razy, co podwajało czekanie.
        if attempt == nil, sawNetworkError, Reachability.shared.online {
            try? await Task.sleep(nanoseconds: 900_000_000)
            sawNetworkError = false
            attempt = await find(track, interim: interim)
        }
        guard let found = attempt else {
            let offline = !Reachability.shared.online
            return LyricsLookup(result: offline ? .offline : .notFound, candidate: nil)
        }
        memory[track.id] = found
        writeCache(found, id: track.id)
        return LyricsLookup(result: LyricsService.result(from: found), candidate: found)
    }

    /// Manual search (picker): all line services, any version.
    func search(query: String) async -> [LyricsCandidate] {
        async let a = lrclibSafe(["q": query])
        async let b = netease(query: query, guess: nil, duration: 0, limit: 6)
        async let k = kugou(query: query, duration: 0, limit: 4)
        let all = (await a) + (await b) + (await k)
        var seen = Set<String>()
        return Array(all.filter { ($0.hasSynced || $0.hasPlain || $0.instrumental == true) && seen.insert($0.uid).inserted }.prefix(40))
    }

    func choose(_ candidate: LyricsCandidate, for trackID: String) {
        memory[trackID] = candidate
        writeCache(candidate, id: trackID)
    }

    /// Usuwa zapamiętany tekst jednej piosenki (np. "Szukaj tekstu od nowa").
    func forget(_ trackID: String) {
        memory[trackID] = nil
        try? FileManager.default.removeItem(at: fileURL(trackID))
    }

    func clearCache() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: LyricsService.cacheDir)
    }

    static func result(from c: LyricsCandidate) -> LyricsResult {
        if c.hasSynced {
            let lines = LRCParser.parse(cleanCredits(c.syncedLyrics ?? ""))
            if !lines.isEmpty { return .synced(lines) }
        }
        if c.hasPlain { return .plain(LRCParser.stripSpam(plain: c.plainLyrics ?? "")) }
        if c.instrumental == true { return .instrumental }
        return .notFound
    }

    /// NetEase puts "作词 : …" credit lines at the start of the lyrics.
    private static let creditRegex = try? NSRegularExpression(
        pattern: "^\\[[^\\]]*\\]\\s*(作词|作曲|编曲|制作人|制作|录音|混音|母带|监制|词|曲|吉他|贝斯|鼓|和声|企划|OP|SP)\\s*[:：].*$",
        options: [.anchorsMatchLines])

    static func cleanCredits(_ raw: String) -> String {
        guard let re = creditRegex else { return raw }
        return re.stringByReplacingMatches(in: raw, options: [], range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
    }

    // MARK: Matching

    private enum Stage: Sendable {
        case providers(word: LyricsCandidate?, fallback: LyricsCandidate?)
        case lines(Scored?)
    }

    typealias Scored = (score: Double, cand: LyricsCandidate)

    private func find(_ track: Track, interim: Interim?) async -> LyricsCandidate? {
        let guesses = TitleCleaner.guesses(title: track.title, channel: track.artist)
        let prefs = LyricsSourcePrefs.current

        // Obie grupy źródeł startują jednocześnie. Kto pierwszy, ten lepszy:
        // - słowo po słowie (Apple Music i spółka) wygrywa od razu i przerywa resztę,
        // - zwykły tekst z czasem linijek pokazuje się od razu jako wersja tymczasowa.
        var wordHit: LyricsCandidate? = nil
        var providerFallback: LyricsCandidate? = nil
        var best: Scored? = nil
        await withTaskGroup(of: Stage.self) { group in
            group.addTask {
                let r = await self.providerStage(track: track, guesses: guesses, prefs: prefs)
                return Stage.providers(word: r.word, fallback: r.fallback)
            }
            group.addTask {
                let found = await self.lineStage(track: track, guesses: guesses, prefs: prefs)
                return Stage.lines(found)
            }
            var providersDone = false
            while let stage = await group.next() {
                switch stage {
                case .providers(let word, let fallback):
                    providersDone = true
                    wordHit = word
                    providerFallback = fallback
                    if word != nil { group.cancelAll() }
                case .lines(let found):
                    best = found
                    if !providersDone, wordHit == nil, let b = found, b.score >= 100, let interim = interim {
                        await interim(b.cand)
                    }
                }
            }
        }

        // 1) Źródła z czasem słowo po słowie.
        if let w = wordHit { return w }
        // 2) Zwykłe źródła z czasem linijek (LRCLIB, NetEase, Kugou), a gdy słabe - zapas ze źródeł "słownych".
        if best == nil || (best?.score ?? 0) < 100, let fallback = providerFallback {
            return fallback
        }
        // Sam tytuł (bez wykonawcy): wykonawca z kanału YouTube bywa błędny (np. nazwa wytwórni), a tytuł wystarcza.
        if best == nil || (best?.score ?? 0) < 60, prefs.isEnabled("lrclib") {
            let titleOnly = await withTaskGroup(of: Scored?.self, returning: Scored?.self) { group in
                for g in guesses.prefix(3) {
                    group.addTask {
                        let results = await self.lrclibSafe(["q": g.title])
                        return self.pick(results, guess: g, duration: track.duration)
                    }
                }
                var top: Scored? = nil
                while let hit = await group.next() {
                    if let h = hit, h.score > (top?.score ?? -1) { top = h }
                }
                return top
            }
            if let hit = titleOnly, hit.score > (best?.score ?? -1) { best = hit }
        }
        if best == nil, let fallback = providerFallback { return fallback }
        // Ostatnia deska ratunku: sam tekst bez czasów (potem aplikacja ustawi czasy ze słuchu).
        if best == nil, prefs.isEnabled("ovh") {
            let plain = await withTaskGroup(of: LyricsCandidate?.self, returning: LyricsCandidate?.self) { group in
                for g in guesses.prefix(4) {
                    group.addTask { await self.lyricsOvh(g) }
                }
                while let hit = await group.next() {
                    if let h = hit { group.cancelAll(); return h }
                }
                return nil
            }
            if let p = plain { return p }
        }
        return best?.cand
    }

    private func providerStage(track: Track, guesses: [TitleCleaner.Guess],
                               prefs: LyricsSourcePrefs) async -> (word: LyricsCandidate?, fallback: LyricsCandidate?) {
        guard !prefs.activeProviders.isEmpty else { return (nil, nil) }
        var fallback: LyricsCandidate? = nil
        for (n, g) in guesses.prefix(2).enumerated() {
            if Task.isCancelled { break }
            // Drugi wariant (zamienione wykonawca/tytuł) tylko wtedy, gdy pierwszy nie dał nic.
            if n > 0, fallback != nil { break }
            let results = await LyricsProviders.lookup(videoId: track.id, title: g.title, artist: g.artist,
                                                      duration: track.duration, prefs: prefs, all: false)
            let usable = results.filter { $0.plausible(for: track.duration) }
            if let w = usable.first(where: { $0.hasWords && $0.hasTiming }) {
                return (LyricsCandidate(provider: w, title: g.title, artist: g.artist), fallback)
            }
            if fallback == nil, let l = usable.first(where: { $0.hasTiming }) {
                fallback = LyricsCandidate(provider: l, title: g.title, artist: g.artist)
            }
        }
        return (nil, fallback)
    }

    /// Wszystkie warianty tytułu naraz (kolejne startują z małym opóźnieniem, bo zwykle trafia już pierwszy).
    private func lineStage(track: Track, guesses: [TitleCleaner.Guess], prefs: LyricsSourcePrefs) async -> Scored? {
        let duration = track.duration
        let wide = prefs.isEnabled("lrclib") ? guesses.first : nil
        return await withTaskGroup(of: Scored?.self, returning: Scored?.self) { group in
            for (i, g) in guesses.enumerated() {
                group.addTask {
                    if i > 0 { try? await Task.sleep(nanoseconds: UInt64(i) * 220_000_000) }
                    if Task.isCancelled { return nil }
                    let results = await self.lineSourceResults(g, duration: duration, neteaseLimit: 3, prefs: prefs)
                    return self.pick(results, guess: g, duration: duration)
                }
            }
            if let first = wide {
                // Szerokie wyszukiwanie "wykonawca tytuł" - zapas, gdy dokładne pola nie trafiły.
                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return nil }
                    let results = await self.lrclibSafe(["q": "\(first.artist) \(first.title)"])
                    return self.pick(results, guess: first, duration: duration)
                }
            }
            var best: Scored? = nil
            while let hit = await group.next() {
                if let h = hit, h.score > (best?.score ?? -1) { best = h }
                // Idealne trafienie (synchronizacja + ten sam czas trwania) - nie czekamy na resztę.
                if let b = best, b.score >= 128 {
                    group.cancelAll()
                    break
                }
            }
            return best
        }
    }

    /// LRCLIB + NetEase + Kugou naraz, z uwzględnieniem włączonych w Ustawieniach.
    private func lineSourceResults(_ g: TitleCleaner.Guess, duration: Double, neteaseLimit: Int,
                                   prefs: LyricsSourcePrefs) async -> [LyricsCandidate] {
        async let a: [LyricsCandidate] = prefs.isEnabled("lrclib") ? lrclibSafe(["track_name": g.title, "artist_name": g.artist]) : []
        async let b: [LyricsCandidate] = prefs.isEnabled("netease") ? netease(query: "\(g.artist) \(g.title)", guess: g, duration: duration, limit: neteaseLimit) : []
        async let k: [LyricsCandidate] = prefs.isEnabled("kugou") ? kugou(query: "\(g.artist) \(g.title)", duration: duration, limit: 3) : []
        return (await a) + (await b) + (await k)
    }

    nonisolated private func pick(_ results: [LyricsCandidate], guess: TitleCleaner.Guess, duration: Double) -> Scored? {
        scored(results, guess: guess, duration: duration).max(by: { $0.score < $1.score })
    }

    nonisolated private func scored(_ results: [LyricsCandidate], guess: TitleCleaner.Guess, duration: Double) -> [Scored] {
        var out: [Scored] = []
        for c in results {
            let titleSim = TitleCleaner.similarity(c.title, guess.title)
            if titleSim < 0.34 { continue }
            let artistSim = TitleCleaner.similarity(c.artist, guess.artist)
            var score = 0.0
            if c.hasSynced { score += 100 } else if c.hasPlain { score += 40 } else if c.instrumental == true { score += 20 } else { continue }
            score += titleSim * 30 + artistSim * 20
            // Wersja tekstu z innym czasem trwania niż film = tekst rozjeżdża się z piosenką (inne tempo / intro).
            // Dlatego zgodność czasu trwania liczy się mocno: ±1,5 s prawie bez kary, a każda sekunda więcej boli.
            if duration > 0, let d = c.duration, d > 0 {
                let diff = abs(d - duration)
                score -= diff <= 1.5 ? diff : 1.5 + min(diff - 1.5, 60) * 3
            }
            out.append((score, c))
        }
        return out
    }

    /// Kilka najlepszych wersji tekstu z synchronizacją (ze wszystkich źródeł) - rozstrzyga je potem słuchanie nagrania.
    /// Wersje ze słowami są na początku, więc przy remisie wygrywają. Wszystko naraz (wcześniej po kolei).
    func candidates(for track: Track) async -> [LyricsCandidate] {
        let guesses = TitleCleaner.guesses(title: track.title, channel: track.artist)
        let prefs = LyricsSourcePrefs.current
        let duration = track.duration

        enum Part: Sendable {
            case front([LyricsCandidate])
            case scored([Scored])
        }

        var front: [LyricsCandidate] = []
        var all: [Scored] = []
        await withTaskGroup(of: Part.self) { group in
            if !prefs.activeProviders.isEmpty, let g = guesses.first {
                group.addTask {
                    let results = await LyricsProviders.lookup(videoId: track.id, title: g.title, artist: g.artist,
                                                              duration: duration, prefs: prefs, all: true)
                    let usable = results.filter { $0.hasTiming && $0.plausible(for: duration) }
                    let ordered = usable.filter { $0.hasWords } + usable.filter { !$0.hasWords }
                    return Part.front(ordered.prefix(3).map { LyricsCandidate(provider: $0, title: g.title, artist: g.artist) })
                }
            }
            for g in guesses.prefix(3) {
                group.addTask {
                    let results = await self.lineSourceResults(g, duration: duration, neteaseLimit: 6, prefs: prefs)
                    return Part.scored(self.scored(results, guess: g, duration: duration))
                }
            }
            if let first = guesses.first, prefs.isEnabled("lrclib") {
                group.addTask {
                    let results = await self.lrclibSafe(["q": "\(first.artist) \(first.title)"])
                    return Part.scored(self.scored(results, guess: first, duration: duration))
                }
            }
            while let part = await group.next() {
                switch part {
                case .front(let f): front = f
                case .scored(let s): all += s
                }
            }
        }
        var seen = Set<String>()
        var out: [LyricsCandidate] = []
        for cand in front where cand.hasSynced {
            if seen.insert(cand.uid).inserted { out.append(cand) }
        }
        for item in all.sorted(by: { $0.score > $1.score }) where item.cand.hasSynced {
            if seen.insert(item.cand.uid).inserted { out.append(item.cand) }
            if out.count >= 8 { break }
        }
        return out
    }

    /// Wynik każdego włączonego źródła osobno - do ręcznego wyboru wersji (lista "Źródła").
    func providerCandidates(for track: Track) async -> [LyricsCandidate] {
        let prefs = LyricsSourcePrefs.current
        guard !prefs.activeProviders.isEmpty,
              let g = TitleCleaner.guesses(title: track.title, channel: track.artist).first else { return [] }
        let results = await LyricsProviders.lookup(videoId: track.id, title: g.title, artist: g.artist,
                                                  duration: track.duration, prefs: prefs, all: true)
        return results.map { LyricsCandidate(provider: $0, title: g.title, artist: g.artist) }
    }

    // MARK: LRCLIB

    /// Jak `lrclib`, ale błąd sieci nie jest mylony z brakiem tekstu.
    private func lrclibSafe(_ params: [String: String]) async -> [LyricsCandidate] {
        do { return try await lrclib(params) } catch {
            sawNetworkError = true
            return []
        }
    }

    /// Pobiera w tle (gdy jest internet) teksty wszystkich piosenek z biblioteki i zapisuje je na dysku,
    /// żeby były też bez internetu.
    func prefetch(_ tracks: [Track]) async {
        guard !prefetching else { return }
        prefetching = true
        defer { prefetching = false }
        var seen = Set<String>()
        for t in tracks where seen.insert(t.id).inserted {
            if Task.isCancelled { break }
            if cached(t.id) != nil { continue }
            guard Reachability.shared.online else { break }
            // Grająca piosenka ma pierwszeństwo: tło czeka, aż jej tekst się znajdzie.
            var waited = 0
            while foreground > 0, waited < 100 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                waited += 1
            }
            _ = await lyrics(for: t)
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func lrclib(_ params: [String: String]) async throws -> [LyricsCandidate] {
        let qs = LyricsService.query(params)
        guard let url = URL(string: "https://lrclib.net/api/search?\(qs)") else { return [] }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        var list = (try? JSONDecoder().decode([LyricsCandidate].self, from: data)) ?? []
        for i in list.indices { list[i].source = "LRCLIB" }
        return list
    }

    // MARK: NetEase

    private struct NESearch: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                struct Artist: Decodable { let name: String? }
                struct Album: Decodable { let name: String? }
                let id: Int
                let name: String?
                let duration: Int?
                let artists: [Artist]?
                let album: Album?
            }
            let songs: [Song]?
        }
        let result: Result?
    }

    private struct NELyric: Decodable {
        struct Block: Decodable { let lyric: String? }
        let lrc: Block?
    }

    private func neteaseRequest(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.setValue("appver=2.0.2", forHTTPHeaderField: "Cookie")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// Search + download of the lyrics of the best few hits.
    private func netease(query: String, guess: TitleCleaner.Guess?, duration: Double, limit: Int) async -> [LyricsCandidate] {
        let qs = LyricsService.query(["s": query, "type": "1", "offset": "0", "limit": "10"])
        guard let data = await neteaseRequest("https://music.163.com/api/search/get/web?\(qs)"),
              let decoded = try? JSONDecoder().decode(NESearch.self, from: data),
              let songs = decoded.result?.songs, !songs.isEmpty else { return [] }

        // Rank the hits before downloading lyrics (one request per hit).
        let ranked = songs.map { song -> (NESearch.Result.Song, Double) in
            let artist = (song.artists ?? []).compactMap { $0.name }.joined(separator: " ")
            var score = 0.0
            if let g = guess {
                score += TitleCleaner.similarity(song.name ?? "", g.title) * 30 + TitleCleaner.similarity(artist, g.artist) * 20
            }
            if duration > 0, let ms = song.duration, ms > 0 {
                score -= min(abs(Double(ms) / 1000 - duration), 60)
            }
            return (song, score)
        }.sorted { $0.1 > $1.1 }.prefix(limit)

        var out: [LyricsCandidate] = []
        await withTaskGroup(of: LyricsCandidate?.self) { group in
            for (song, _) in ranked {
                group.addTask { await self.neteaseLyrics(song) }
            }
            for await c in group { if let c = c { out.append(c) } }
        }
        return out
    }

    private func neteaseLyrics(_ song: NESearch.Result.Song) async -> LyricsCandidate? {
        let qs = LyricsService.query(["id": String(song.id), "lv": "1", "kv": "1", "tv": "-1"])
        guard let data = await neteaseRequest("https://music.163.com/api/song/lyric?\(qs)"),
              let decoded = try? JSONDecoder().decode(NELyric.self, from: data),
              let raw = decoded.lrc?.lyric,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var c = LyricsCandidate(
            id: song.id,
            trackName: song.name,
            artistName: (song.artists ?? []).compactMap { $0.name }.joined(separator: ", "),
            albumName: song.album?.name,
            duration: song.duration.map { Double($0) / 1000 },
            instrumental: false,
            plainLyrics: nil,
            syncedLyrics: nil,
            source: "NetEase")
        let cleaned = LyricsService.cleanCredits(raw)
        if !LRCParser.parse(cleaned).isEmpty { c.syncedLyrics = cleaned } else { c.plainLyrics = cleaned }
        return c
    }

    // MARK: Kugou

    private struct KGSearch: Decodable {
        struct Cand: Decodable {
            let id: String?
            let accesskey: String?
            let song: String?
            let singer: String?
            let duration: Int?
        }
        let candidates: [Cand]?
    }

    private struct KGDownload: Decodable { let content: String? }

    private func getData(_ url: String) async -> Data? {
        guard let u = URL(string: url),
              let (data, resp) = try? await session.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private func kugou(query: String, duration: Double, limit: Int) async -> [LyricsCandidate] {
        let ms = duration > 0 ? Int(duration * 1000) : 0
        let qs = LyricsService.query(["ver": "1", "man": "yes", "client": "pc", "keyword": query, "duration": String(ms)])
        guard let data = await getData("https://lyrics.kugou.com/search?\(qs)"),
              let decoded = try? JSONDecoder().decode(KGSearch.self, from: data),
              let cands = decoded.candidates, !cands.isEmpty else { return [] }
        var out: [LyricsCandidate] = []
        await withTaskGroup(of: LyricsCandidate?.self) { group in
            for c in cands.prefix(limit) {
                group.addTask {
                    guard let id = c.id, let key = c.accesskey else { return nil }
                    let q = LyricsService.query(["ver": "1", "client": "pc", "id": id, "accesskey": key, "fmt": "lrc", "charset": "utf8"])
                    guard let d = await self.getData("https://lyrics.kugou.com/download?\(q)"),
                          let dec = try? JSONDecoder().decode(KGDownload.self, from: d),
                          let b64 = dec.content, let raw = Data(base64Encoded: b64),
                          var text = String(data: raw, encoding: .utf8) else { return nil }
                    text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
                    let cleaned = LyricsService.cleanCredits(text)
                    guard !LRCParser.parse(cleaned).isEmpty else { return nil }
                    return LyricsCandidate(id: Int(id) ?? LyricsProviders.stableID(id), trackName: c.song, artistName: c.singer,
                                           albumName: nil, duration: c.duration.map { Double($0) / 1000 },
                                           instrumental: false, plainLyrics: nil, syncedLyrics: cleaned, source: "Kugou")
                }
            }
            for await c in group { if let c = c { out.append(c) } }
        }
        return out
    }

    // MARK: lyrics.ovh (sam tekst)

    private struct OvhResponse: Decodable { let lyrics: String? }

    private func lyricsOvh(_ g: TitleCleaner.Guess) async -> LyricsCandidate? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard !g.artist.isEmpty, !g.title.isEmpty,
              let a = g.artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let t = g.title.addingPercentEncoding(withAllowedCharacters: allowed),
              let data = await getData("https://api.lyrics.ovh/v1/\(a)/\(t)"),
              let decoded = try? JSONDecoder().decode(OvhResponse.self, from: data),
              let text = decoded.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 40 else { return nil }
        return LyricsCandidate(id: LyricsProviders.stableID("ovh|" + g.artist + "|" + g.title), trackName: g.title, artistName: g.artist,
                               albumName: nil, duration: nil, instrumental: false,
                               plainLyrics: LRCParser.stripSpam(plain: text), syncedLyrics: nil, source: "lyrics.ovh")
    }

    // MARK: Helpers

    private static func query(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    // MARK: Disk cache

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Lumen/Lyrics", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL {
        LyricsService.cacheDir.appendingPathComponent("\(id).json")
    }

    private func readCache(_ id: String) -> LyricsCandidate? {
        guard let data = try? Data(contentsOf: fileURL(id)) else { return nil }
        return try? JSONDecoder().decode(LyricsCandidate.self, from: data)
    }

    private func writeCache(_ c: LyricsCandidate, id: String) {
        try? FileManager.default.createDirectory(at: LyricsService.cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: fileURL(id), options: .atomic) }
    }
}
