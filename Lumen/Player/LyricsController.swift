import Foundation

/// Holds the lyrics of the current track and which line is active.
@MainActor
final class LyricsController: ObservableObject {
    enum Phase: Equatable { case idle, loading, synced, plain, instrumental, notFound, offline }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var plainText: String = ""
    @Published private(set) var activeIndex: Int = -1
    /// Positive = lyrics appear earlier, negative = later (seconds).
    @Published private(set) var offset: Double = 0
    /// Time stretch of the lyrics (1.0 = as is). Above 1 the lyrics run slower, below 1 faster.
    @Published private(set) var stretch: Double = 1
    /// The version that is currently shown (for the picker).
    @Published private(set) var current: LyricsCandidate? = nil
    /// Rośnie przy każdej zmianie tekstu (nowa piosenka, inna wersja, czyszczenie) - po tym widok odświeża listę linijek.
    @Published private(set) var revision = 0

    /// Fragmenty nagrania (czas odtwarzacza, sekundy) z wulgaryzmami - te chwile są wyciszane.
    /// To suma: dokładnych czasów z nasłuchu nagrania (`heardWindows`) i szacunku z tekstu (`lyricWindows`).
    private(set) var muteWindows: [(start: Double, end: Double)] = []
    private var heardWindows: [(start: Double, end: Double)] = []
    private var lyricWindows: [(start: Double, end: Double)] = []
    /// Mapa czasu tekstu: punkty kontrolne w całej piosence (puste = tylko przesunięcie + tempo).
    private(set) var warp: [LyricsAligner.Anchor] = []

    private var trackID: String?
    private var loadTask: Task<Void, Never>?
    private var lastTime: Double = 0
    /// Output latency of the current audio route (seconds). What the user hears is this much behind the
    /// player clock (Bluetooth: ~0.2 s), so the lyrics are held back by the same amount.
    private var latency: Double = 0

    func load(track: Track, offset: Double, stretch: Double = 1) {
        trackID = track.id
        revision += 1
        self.offset = offset
        self.stretch = stretch
        current = nil
        loadTask?.cancel()
        phase = .loading
        muteWindows = []
        heardWindows = []
        lyricWindows = []
        warp = []
        lines = []
        plainText = ""
        activeIndex = -1
        loadTask = Task { [weak self] in
            var notFoundRetries = 0
            while true {
                let found = await LyricsService.shared.lyrics(for: track)
                guard let self = self, !Task.isCancelled, self.trackID == track.id else { return }
                if case .offline = found.result {
                    // Brak internetu: pokaż komunikat i próbuj dalej, aż połączenie wróci (bez klikania).
                    self.apply(.offline)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                if case .notFound = found.result, notFoundRetries < 1, Reachability.shared.online {
                    // Fałszywe "brak tekstu" bywa chwilowe (timeout serwera) - spróbuj jeszcze raz po chwili.
                    notFoundRetries += 1
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    continue
                }
                self.current = found.candidate
                if let c = found.candidate, let stored = LyricsWarpStore.load(track.id), stored.uid == c.uid {
                    self.warp = stored.anchors
                }
                self.apply(found.result)
                // Teksty ze słowami z Apple/BiniLyrics itp. mają dokładne czasy - żadnej "mapy czasu" na wierzch,
                // bo raz działała, raz nie (to było źródło losowych przesunięć).
                if self.lines.contains(where: { $0.isWordSynced }) { self.warp = []; self.rebuildMuteWindows() }
                return
            }
        }
    }

    /// Czyści tekst (np. przy zmianie stacji radiowej, zanim pojawi się nowy utwór).
    func clear() {
        loadTask?.cancel()
        loadTask = nil
        trackID = nil
        revision += 1
        phase = .idle
        lines = []
        plainText = ""
        activeIndex = -1
        current = nil
        offset = 0
        stretch = 1
        muteWindows = []
        heardWindows = []
        lyricWindows = []
        warp = []
    }

    func setOffset(_ value: Double) {
        offset = value
        rebuildMuteWindows()
        tick(lastTime)
    }

    func setWarp(_ anchors: [LyricsAligner.Anchor]) {
        if lines.contains(where: { $0.isWordSynced }) { return }
        warp = anchors
        rebuildMuteWindows()
        tick(lastTime)
    }

    /// Dokładne czasy przekleństw z nasłuchu nagrania (działa też bez żadnego tekstu).
    func setHeardWindows(_ windows: [(start: Double, end: Double)]) {
        heardWindows = windows
        combineWindows()
    }

    /// Próbka tekstu do rozpoznania języka (puste, gdy tekstu nie ma).
    var languageSample: String {
        if !lines.isEmpty { return lines.prefix(40).map { $0.text }.joined(separator: " ") }
        return String(plainText.prefix(1500))
    }

    // MARK: Mapa czasu

    /// Przesunięcie tekstu (sekundy) w chwili `u` nagrania - interpolacja między punktami kontrolnymi.
    private func warpDelta(at u: Double) -> Double {
        guard let first = warp.first, let last = warp.last else { return 0 }
        if u <= first.t { return first.d }
        if u >= last.t { return last.d }
        var lo = 0
        var hi = warp.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if warp[mid].t <= u { lo = mid } else { hi = mid }
        }
        let a = warp[lo], b = warp[hi]
        let span = b.t - a.t
        guard span > 0.001 else { return a.d }
        return a.d + (b.d - a.d) * (u - a.t) / span
    }

    /// Czas odtwarzacza -> czas w tekście (to, co robi `tick`).
    func lyricTime(forPlayer time: Double) -> Double {
        let u = (time - latency) / stretch
        return u + warpDelta(at: u) + offset
    }

    /// Czas w tekście -> czas odtwarzacza (np. po dotknięciu linijki).
    func playerTime(forLyric lyricTime: Double) -> Double {
        var u = lyricTime - offset
        for _ in 0..<5 { u = lyricTime - offset - warpDelta(at: u) }
        return u * stretch + latency
    }

    func setStretch(_ value: Double) {
        stretch = min(max(value, 0.8), 1.25)
        rebuildMuteWindows()
        tick(lastTime)
    }

    func setLatency(_ value: Double) {
        latency = value
        rebuildMuteWindows()
        tick(lastTime)
    }

    func isMuted(at time: Double) -> Bool {
        for w in muteWindows where time >= w.start && time <= w.end { return true }
        return false
    }

    /// Szacuje, kiedy w nagraniu pada wulgarne słowo (gdy mamy tekst z czasem): pozycja słowa w linijce
    /// (proporcjonalnie do liczby znaków) rozłożona na czas trwania linijki, z zapasem po bokach.
    private func rebuildMuteWindows() {
        guard phase == .synced else { lyricWindows = []; combineWindows(); return }
        var out: [(start: Double, end: Double)] = []
        for (i, line) in lines.enumerated() {
            // Źródło z czasem słów: wyciszamy dokładnie te słowa/sylaby, a nie szacunek z długości tekstu.
            if !line.words.isEmpty {
                let joined = line.words.map { $0.text }.joined()
                let wordSpans = Profanity.spans(in: joined)
                if wordSpans.isEmpty { continue }
                var ranges: [(from: Int, to: Int)] = []
                var pos = 0
                for r in line.words {
                    let n = r.text.count
                    ranges.append((pos, pos + n))
                    pos += n
                }
                for s in wordSpans {
                    let sEnd = s.start + s.length
                    let hit = line.words.indices.filter { ranges[$0].from < sEnd && ranges[$0].to > s.start }
                    guard let f = hit.first, let l = hit.last else { continue }
                    out.append((playerTime(forLyric: line.words[f].start) - 0.15, playerTime(forLyric: line.words[l].end) + 0.15))
                }
                continue
            }
            let spans = Profanity.spans(in: line.text)
            if spans.isEmpty { continue }
            let next = i + 1 < lines.count ? lines[i + 1].time : line.time + 4
            let dur = min(max(next - line.time, 1.0), 7.0) * 0.9
            let total = Double(max(line.text.count, 1))
            for s in spans {
                let a = line.time + dur * Double(s.start) / total
                let b = a + max(0.4, dur * Double(s.length) / total)
                out.append((playerTime(forLyric: a) - 0.2, playerTime(forLyric: b) + 0.2))
            }
        }
        lyricWindows = out
        combineWindows()
    }

    /// Dokładny czas z nasłuchu ma pierwszeństwo: szacunek z tekstu zostaje tylko tam, gdzie nasłuch niczego
    /// nie znalazł (rozpoznawanie mowy w muzyce bywa dziurawe, więc wolimy wyciszyć o jedno słowo za dużo).
    private func combineWindows() {
        var out = heardWindows
        for w in lyricWindows {
            let covered = heardWindows.contains { abs($0.start - w.start) < 3.0 || ($0.start <= w.end && $0.end >= w.start) }
            if !covered { out.append(w) }
        }
        muteWindows = out
    }

    func choose(_ candidate: LyricsCandidate, for track: Track) {
        Task { [weak self] in
            await LyricsService.shared.choose(candidate, for: track.id)
            guard let self = self, self.trackID == track.id else { return }
            self.current = candidate
            self.apply(LyricsService.result(from: candidate))
        }
    }

    func tick(_ time: Double) {
        lastTime = time
        guard phase == .synced else { return }
        let idx = LRCParser.activeIndex(in: lines, at: lyricTime(forPlayer: time))
        if idx != activeIndex { activeIndex = idx }
    }

    private func apply(_ result: LyricsResult) {
        revision += 1
        switch result {
        case .synced(let l):
            lines = l
            phase = .synced
            activeIndex = -1
            rebuildMuteWindows()
            tick(lastTime)
        case .plain(let text):
            plainText = text
            phase = .plain
        case .instrumental:
            phase = .instrumental
        case .notFound:
            phase = .notFound
        case .offline:
            phase = .offline
        }
    }
}
