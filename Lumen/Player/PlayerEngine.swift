import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer

final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
}

enum RepeatMode: Int { case off, all, one }

enum NowPlayingArtwork {
    // Built outside any actor: MediaPlayer calls this block on a background queue.
    static func make(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var artwork: UIImage? = nil
    /// Ostatnio grane piosenki (najnowsza pierwsza), zapisane między uruchomieniami - dla zakładki Główna.
    @Published private(set) var recent: [Track] = PlayerEngine.loadRecent()
    nonisolated private static let recentKey = "lumen.recent.v1"

    private func remember(_ track: Track) {
        guard !track.isRadio else { return }
        var list = recent.filter { $0.id != track.id }
        list.insert(track, at: 0)
        if list.count > 30 { list.removeLast(list.count - 30) }
        recent = list
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: PlayerEngine.recentKey) }
    }

    nonisolated private static func loadRecent() -> [Track] {
        guard let data = UserDefaults.standard.data(forKey: recentKey),
              let list = try? JSONDecoder().decode([Track].self, from: data) else { return [] }
        return list
    }

    /// Piosenka, do której należy `artwork` (przy przełączaniu stara okładka nie może trafić do nowej piosenki).
    @Published private(set) var artworkTrackID: String? = nil
    /// Kolor "klimatu" grającej piosenki (z okładki): poświata, pasek postępu, świecący tekst. nil = szara okładka.
    @Published private(set) var vibe: UIColor? = nil
    @Published private(set) var shuffle = false
    @Published private(set) var playbackRate: Double = 1
    private var keepPitch = true
    /// True, gdy gra radio (transmisja na żywo): bez tekstów, przewijania i pobierania.
    @Published private(set) var isRadio = false
    private var radioURLs: [String: URL] = [:]
    private var radioStations: [String: RadioStation] = [:]
    /// Utwór grany teraz w stacji (z metadanych strumienia albo rozpoznany ze słuchu).
    @Published private(set) var radioSong: RadioSong? = nil
    /// True, dopóki łączymy się ze stacją i szukamy tytułu (zanim pokażemy "brak informacji o utworze").
    @Published private(set) var radioDetecting = false
    /// True, gdy wiemy, w którym miejscu piosenki jesteśmy - wtedy tekst ma animację.
    @Published private(set) var radioPositionKnown = false
    private var radioPosBase = 0.0
    private var radioPosDate = Date()
    private var radioHasMeta = false
    private var radioPausedAt: Date?
    private var radioDetectTask: Task<Void, Never>?
    private let radioMeta = RadioMetaReader()

    var currentStation: RadioStation? {
        guard isRadio, let t = currentTrack else { return nil }
        return radioStations[t.id]
    }
    @Published private(set) var repeatMode: RepeatMode = .off

    let clock = PlaybackClock()
    let lyrics = LyricsController()

    private let settings: AppSettings
    private let toast: ToastCenter

    /// Natywny odtwarzacz: dźwięk idzie bezpośrednio przez AVPlayer, więc iOS traktuje aplikację jak
    /// zwykły odtwarzacz muzyki - gra w tle i przy zablokowanym ekranie bez żadnych obejść.
    private let player = AVPlayer()
    private var itemObservers: [NSKeyValueObservation] = []
    private var playerObservers: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    /// What the user wants (play / pause). The button always follows this, never the delayed player state,
    /// so tapping fast cannot leave the button and the sound out of sync.
    @Published private(set) var wantsPlaying = false
    private var ended = false
    private var durationSuspect = false
    private var censoring = false
    private lazy var bleepPlayer: AVAudioPlayer? = PlayerEngine.makeBleep()

    /// Krótki, cichy sygnał "pip" (1 kHz), puszczany w pętli na czas wyciszonego wulgaryzmu.
    private static func makeBleep() -> AVAudioPlayer? {
        let rate = 44_100.0
        let count = Int(rate * 0.5)
        var pcm = Data(capacity: count * 2)
        for n in 0..<count {
            let sample = Int16(sin(2 * Double.pi * 1000 * Double(n) / rate) * 9000)
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
        func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
        var wav = Data("RIFF".utf8)
        wav += le32(UInt32(36 + pcm.count)); wav += Data("WAVEfmt ".utf8)
        wav += le32(16); wav += le16(1); wav += le16(1); wav += le32(UInt32(rate)); wav += le32(UInt32(rate) * 2)
        wav += le16(2); wav += le16(16); wav += Data("data".utf8); wav += le32(UInt32(pcm.count)); wav += pcm
        let p = try? AVAudioPlayer(data: wav)
        p?.numberOfLoops = -1
        p?.volume = 0.3
        p?.prepareToPlay()
        return p
    }

    /// Wyciszenie nagrania (i krótki sygnał) w chwilach z wulgaryzmami.
    private func updateCensor(at t: Double) {
        if isRadio { return }
        // Piosenka bez tekstu: nasłuchujemy nagrania (raz na piosenkę), żeby znaleźć wulgaryzmy.
        if settings.data.censorProfanity, censorScanTrackID != currentTrack?.id { scheduleCensorScan() }
        let muted = settings.data.censorProfanity && lyrics.isMuted(at: t)
        guard muted != censoring else { return }
        censoring = muted
        player.volume = muted ? 0 : 1
        applyBleep()
    }

    /// Pisk gra TYLKO wtedy, gdy piosenka naprawdę gra i jest w wyciszanym fragmencie.
    /// Pauza, przerwanie, zmiana utworu, przewinięcie - wszystko przechodzi przez tę jedną funkcję,
    /// więc pisk nie może już "zostać" po zatrzymaniu muzyki.
    private func applyBleep() {
        let shouldBleep = censoring && wantsPlaying && isPlaying && !interrupted
        guard let b = bleepPlayer else { return }
        if shouldBleep {
            if !b.isPlaying { b.currentTime = 0; b.play() }
        } else if b.isPlaying {
            b.pause()
            b.currentTime = 0
        }
    }

    private func stopBleepNow() {
        censoring = false
        player.volume = 1
        if let b = bleepPlayer, b.isPlaying { b.pause(); b.currentTime = 0 }
    }

    private var censorScanTrackID: String?
    private var censorScanTask: Task<Void, Never>?

    /// Skanuje pobrany plik (rozpoznawanie mowy na urządzeniu) i zapisuje dokładne czasy wulgarnych słów.
    private func scheduleCensorScan() {
        guard let t = currentTrack else { return }
        censorScanTrackID = t.id
        censorScanTask?.cancel()
        let id = t.id
        let duration = clock.duration > 0 ? clock.duration : t.duration
        censorScanTask = Task { [weak self] in
            // czekamy, aż plik będzie na dysku (przy pierwszym odtworzeniu pobiera się w tle)
            var file: URL? = nil
            for _ in 0..<120 {
                if Task.isCancelled { return }
                file = await AudioCache.shared.localURL(for: id)
                if file != nil { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard let file = file else { return }
            // z tekstem znamy język; bez tekstu próbujemy języka urządzenia i angielskiego
            // chwila na tekst (język), ale bez tekstu też działamy
            var waited = 0
            while let self = self, [.idle, .loading].contains(self.lyrics.phase), waited < 20 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 1
                if Task.isCancelled { return }
            }
            let hint = self?.lyrics.languageSample ?? ""
            let windows = await ProfanityScanner.windows(id: id, file: file, duration: duration, textSample: hint)
            guard let self = self, !Task.isCancelled, self.currentTrack?.id == id else { return }
            self.lyrics.setHeardWindows(windows)
        }
    }
    private var interrupted = false
    private var wasPlayingBeforeInterruption = false
    private var failures = 0
    private var lastTime = 0.0
    private var isSeeking = false
    private var history: [Int] = []
    private var shuffleBag: [Int] = []
    private var plannedNext: Int? = nil
    private var observers: [NSObjectProtocol] = []
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var lastNowPlayingDuration = 0.0
    private var nowPlayingTick = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var loadTask: Task<Void, Never>?
    private var loadToken = UUID()
    private var watchdog: Task<Void, Never>?
    private var stalledTicks = 0
    private var reloadAttempts = 0
    private var lastToggle = Date.distantPast
    private var refreshedURLForCurrent = false
    /// True while the stream address is being fetched (the player has no item yet).
    private var resolving = false
    private var resolveTicks = 0
    private var playingLocalFile = false
    /// Piosenki, które w tej sesji skończyły się pobierać (gra jeszcze strumień, ale plik już jest na dysku).
    private var localFiles: [String: URL] = [:]
    private var alignTask: Task<Void, Never>?
    private var prematureRetries = 0
    /// Piosenka, do której należy `lastTime`. Pozycja starej piosenki nigdy nie może trafić do nowej.
    private var lastTimeID: String?

    private func resumeTime(for track: Track) -> Double {
        lastTimeID == track.id ? lastTime : 0
    }

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    init(settings: AppSettings, toast: ToastCenter) {
        self.settings = settings
        self.toast = toast
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        activateSession()
        setupPlayerObservers()
        setupRemoteCommands()
        observeSystem()
        updateLatency()
        startWatchdog()
    }

    // MARK: - Wyłącznik czasowy

    /// Kiedy muzyka sama się zatrzyma (nil = wyłączony).
    @Published private(set) var sleepAt: Date? = nil
    /// Zatrzymanie po bieżącej piosence.
    @Published private(set) var sleepAfterTrack = false
    private var sleepFadeTask: Task<Void, Never>?

    func setSleepTimer(minutes: Int) {
        sleepFadeTask?.cancel()
        sleepAfterTrack = false
        sleepAt = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        toast.show(minutes > 0 ? "Muzyka zatrzyma się za \(minutes) min" : "Wyłącznik czasowy wyłączony")
    }

    func setSleepAfterTrack() {
        sleepFadeTask?.cancel()
        sleepAt = nil
        sleepAfterTrack = true
        toast.show("Muzyka zatrzyma się po tej piosence")
    }

    func cancelSleepTimer() {
        sleepFadeTask?.cancel()
        sleepAt = nil
        sleepAfterTrack = false
        toast.show("Wyłącznik czasowy wyłączony")
    }

    /// Wywoływane co sekundę (watchdog): gdy czas minął, muzyka cichnie przez kilka sekund i się zatrzymuje.
    private func checkSleepTimer() {
        guard let at = sleepAt, Date() >= at else { return }
        sleepAt = nil
        guard wantsPlaying else { return }
        sleepFadeTask?.cancel()
        sleepFadeTask = Task { [weak self] in
            guard let self = self else { return }
            let start = self.player.volume
            for step in 1...24 {
                try? await Task.sleep(nanoseconds: 160_000_000)
                if Task.isCancelled || !self.wantsPlaying { self.player.volume = start; return }
                self.player.volume = start * Float(24 - step) / 24
            }
            self.pause()
            self.player.volume = start
            self.toast.show("Dobranoc! Muzyka zatrzymana przez wyłącznik czasowy.")
        }
    }

    // MARK: - Public controls

    func play(_ tracks: [Track], startAt index: Int, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        isRadio = false
        radioURLs = [:]
        queue = tracks
        history = []
        plannedNext = nil
        // Każde nowe odtworzenie ustawia tryb od nowa: "Losowo" = losowo, kliknięcie piosenki / "Odtwórz" = po kolei.
        shuffle = shuffled
        let start = shuffled ? Int.random(in: 0..<tracks.count) : min(max(index, 0), tracks.count - 1)
        shuffleBag = shuffle ? Array(tracks.indices) : []
        failures = 0
        load(index: start, pushHistory: false)
    }

    func playNow(_ track: Track) { play([track], startAt: 0) }

    func enqueueNext(_ track: Track) {
        guard let cur = currentIndex, !isRadio else { playNow(track); return }
        queue.insert(track, at: cur + 1)
        shuffleBag = shuffle ? Array(queue.indices).filter { $0 != cur } : []
        plannedNext = nil
        prefetchNext()
        toast.show("Zagra jako następna")
    }

    func enqueueLast(_ track: Track) {
        guard currentIndex != nil, !isRadio else { playNow(track); return }
        queue.append(track)
        if shuffle { shuffleBag.append(queue.count - 1) }
        plannedNext = nil
        prefetchNext()
        toast.show("Dodano do kolejki")
    }

    func jump(to index: Int) { load(index: index, pushHistory: true) }

    func removeFromQueue(at offsets: IndexSet) {
        guard let cur = currentIndex else { return }
        let removable = offsets.filter { $0 != cur }
        let shift = removable.filter { $0 < cur }.count
        queue.remove(atOffsets: IndexSet(removable))
        currentIndex = cur - shift
        history = []
        plannedNext = nil
        shuffleBag = shuffle ? Array(queue.indices).filter { $0 != currentIndex } : []
        prefetchNext()
    }

    func play() {
        guard let t = currentTrack else { return }
        wantsPlaying = true
        interrupted = false
        stalledTicks = 0
        reloadAttempts = 0
        activateSession()
        if ended {
            ended = false
            clock.time = 0
            lastTime = 0
            startLoad(track: t, startAt: 0)
        } else if player.currentItem == nil {
            if !resolving { startLoad(track: t, startAt: resumeTime(for: t)) }
        } else if t.isRadio, let paused = radioPausedAt, Date().timeIntervalSince(paused) > 3 {
            // Po dłuższej pauzie radio wraca na żywo (a nie do miejsca, w którym je zatrzymano).
            radioPausedAt = nil
            // Po powrocie na żywo pierwszy tytuł może dotyczyć utworu trwającego od dawna - pozycja znów nieznana.
            radioHasMeta = false
            isBuffering = true
            startLoad(track: t, startAt: 0, forceRefresh: true)
            startRadioDetection(for: t)
        } else {
            if t.isRadio, let paused = radioPausedAt {
                // Krótka pauza: odtwarzacz wznawia od miejsca zatrzymania, więc pozycja w piosence też "czekała".
                radioPosDate = radioPosDate.addingTimeInterval(Date().timeIntervalSince(paused))
            }
            radioPausedAt = nil
            player.play()
        }
        applyBleep()
        updateNowPlaying()
    }

    func pause() {
        if isRadio && wantsPlaying { radioPausedAt = Date() }
        wantsPlaying = false
        player.pause()
        isPlaying = false
        isBuffering = false
        // W pauzie nic nie słychać - dobra chwila, żeby przejść ze strumienia na pobrany plik.
        swapToLocal(at: livePlaybackTime())
        applyBleep()
        updateNowPlaying()
    }

    func togglePlayPause() {
        // Ignore the accidental extra tap of a fast double-tap.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = now
        if wantsPlaying { pause() } else { play() }
    }

    func next() {
        if isRadio, let cur = currentIndex, !queue.isEmpty {
            load(index: (cur + 1) % queue.count, pushHistory: false)
            return
        }
        if let n = nextIndex(auto: false) { load(index: n, pushHistory: true) }
    }

    func previous() {
        if isRadio, let cur = currentIndex, !queue.isEmpty {
            load(index: (cur - 1 + queue.count) % queue.count, pushHistory: false)
            return
        }
        if clock.time > 3 || currentIndex == nil { seek(to: 0); return }
        if shuffle, let last = history.popLast() { load(index: last, pushHistory: false); return }
        if !shuffle, let cur = currentIndex, cur > 0 { load(index: cur - 1, pushHistory: false); return }
        seek(to: 0)
    }

    func seek(to seconds: Double) {
        if isRadio { return }       // transmisji na żywo nie da się przewijać
        let upper = clock.duration > 0 ? clock.duration : max(seconds, 0)
        let t = max(0, min(seconds, upper))
        clock.time = t
        lastTime = t
        lastTimeID = currentTrack?.id
        lyrics.tick(t)
        updateCensor(at: t)
        // Przewijanie i tak przerywa dźwięk na chwilę - jeśli plik już jest pobrany, przewijamy od razu w pliku.
        if swapToLocal(at: t) { updateNowPlaying(); return }
        guard player.currentItem != nil else { updateNowPlaying(); return }
        isSeeking = true
        let target = CMTime(seconds: t, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.isSeeking = false
                self.updateNowPlaying()
            }
        }
        updateNowPlaying()
    }

    func skip(by delta: Double) { seek(to: clock.time + delta) }

    /// Szybkość odtwarzania i (opcjonalnie) zmiana wysokości tonu: slowed, nightcore, speed up.
    func setPlayback(rate: Double, keepPitch: Bool) {
        let r = min(max(rate, 0.5), 2.0)
        playbackRate = r
        self.keepPitch = keepPitch
        player.defaultRate = Float(r)
        player.currentItem?.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
        if wantsPlaying && player.timeControlStatus != .paused { player.rate = Float(r) }
        updateNowPlaying()
    }

    func toggleShuffle() {
        shuffle.toggle()
        history = []
        plannedNext = nil
        shuffleBag = shuffle ? Array(queue.indices).filter { $0 != currentIndex } : []
        prefetchNext()
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
        plannedNext = nil
        prefetchNext()
    }

    func adjustLyricsOffset(by delta: Double) {
        guard let t = currentTrack else { return }
        let value = ((lyrics.offset + delta) * 1000).rounded() / 1000
        lyrics.setOffset(value)
        settings.setLyricsOffset(value, for: t.id)
        let shown = String(format: "%+.2f s", value).replacingOccurrences(of: ".", with: ",")
        toast.show(value == 0 ? "Tekst: oryginalny czas" : "Przesunięcie tekstu: \(shown)")
    }

    func resetLyricsOffset() {
        guard let t = currentTrack else { return }
        lyrics.setOffset(0)
        lyrics.setStretch(1)
        lyrics.setWarp([])
        LyricsWarpStore.markTried(t.id)     // wracamy do oryginalnych czasów i nie dopasowujemy ponownie
        settings.setLyricsOffset(0, for: t.id)
        settings.setLyricsStretch(1, for: t.id)
    }

    /// Tempo tekstu: dodatnie `percent` = tekst wolniejszy, ujemne = szybszy (zapamiętywane dla piosenki).
    func adjustLyricsTempo(byPercent percent: Double) {
        guard let t = currentTrack else { return }
        let value = ((lyrics.stretch * (1 + percent / 100)) * 1000).rounded() / 1000
        lyrics.setStretch(value)
        settings.setLyricsStretch(lyrics.stretch, for: t.id)
    }

    func chooseLyrics(_ candidate: LyricsCandidate) {
        guard let t = currentTrack else { return }
        // Inna wersja tekstu = stare dopasowanie przestaje obowiązywać.
        settings.setLyricsOffset(0, for: t.id)
        settings.setLyricsStretch(1, for: t.id)
        settings.data.lyricsAligned[t.id] = nil
        LyricsWarpStore.remove(t.id)
        lyrics.setOffset(0)
        lyrics.setStretch(1)
        lyrics.setWarp([])
        lyrics.choose(candidate, for: t)
        Task { [weak self] in
            if let file = await AudioCache.shared.localURL(for: t.id) {
                try? await Task.sleep(nanoseconds: 600_000_000)
                self?.scheduleAutoAlign(track: t, file: file)
            }
        }
    }

    /// Szuka tekstu bieżącej piosenki od nowa (menu "•••" → Tekst piosenki → Szukaj tekstu od nowa).
    func refreshLyrics() {
        guard let t = currentTrack, !t.isRadio else { return }
        settings.setLyricsOffset(0, for: t.id)
        settings.setLyricsStretch(1, for: t.id)
        settings.data.lyricsAligned[t.id] = nil
        lyrics.reload(track: t)
        toast.show("Szukam tekstu od nowa…")
        Task { [weak self] in
            if let file = await AudioCache.shared.localURL(for: t.id) {
                self?.scheduleAutoAlign(track: t, file: file, force: true)
            }
        }
    }

    private func autoLyricsFallback(track: Track, file: URL) async {
        let plain = lyrics.phase == .plain ? lyrics.plainText : ""
        if plain.isEmpty { toast.show("Brak tekstu w internecie. Piszę go ze słuchu, mogą być błędy.") }
        let duration = clock.duration
        let cand = await Task.detached(priority: .utility) {
            await AutoLyrics.build(track: track, file: file, duration: duration, plain: plain)
        }.value
        guard let cand = cand, currentTrack?.id == track.id, !Task.isCancelled else { return }
        chooseLyrics(cand)
        LyricsWarpStore.markTried(track.id)
    }

    /// Ręczne uruchomienie automatycznego dopasowania tekstu (menu "•••").
    func autoAlignCurrent() {
        guard let t = currentTrack else { return }
        Task { [weak self] in
            guard let file = await AudioCache.shared.localURL(for: t.id) else {
                self?.toast.show("Piosenka jeszcze się pobiera. Spróbuj za chwilę.")
                return
            }
            self?.scheduleAutoAlign(track: t, file: file, force: true)
        }
    }

    // MARK: - Automatic lyrics alignment

    private func scheduleAutoAlign(track: Track, file: URL, force: Bool = false) {
                // Nie nadpisuj ręcznych poprawek ani nie próbuj drugi raz tej samej piosenki.
        if !force {
            // Mapa czasu już jest (albo użytkownik ją zresetował) - nie słuchamy drugi raz.
            if LyricsWarpStore.exists(track.id) { return }
            // Ręczne poprawki użytkownika zostają. Stare, proste dopasowanie (sam offset + tempo) zastępujemy
            // nowym, dokładniejszym.
            let manual = settings.lyricsOffset(for: track.id) != 0 || settings.lyricsStretch(for: track.id) != 1
            if manual && settings.data.lyricsAligned[track.id] != true { return }
        }
        alignTask?.cancel()
        alignTask = Task { [weak self] in
            guard let self = self else { return }
            // poczekaj na tekst (max ~20 s)
            var waited = 0
            // (też gdy widać tymczasowy tekst z linijkami, a wersja słowo po słowie jeszcze może przyjść)
            while self.lyrics.phase == .loading || self.lyrics.phase == .idle || self.lyrics.phase == .offline
                    || self.lyrics.isUpgrading {
                try? await Task.sleep(nanoseconds: 500_000_000)
                // limit czasu dotyczy tylko zwykłego ładowania; przy braku internetu czekamy aż wróci
                if self.lyrics.phase != .offline { waited += 1 }
                if waited >= 40 { break }
                if Task.isCancelled || self.currentTrack?.id != track.id { return }
            }
            guard self.currentTrack?.id == track.id, self.lyrics.phase != .instrumental, !Task.isCancelled else { return }
            // Brak tekstu z czasami w internecie: zrób go ze słuchu.
            if self.lyrics.phase == .notFound || self.lyrics.phase == .plain {
                await self.autoLyricsFallback(track: track, file: file)
                return
            }
            // Tekst ze słowami (Apple i spółka) jest już dokładny - nie psujemy go dopasowaniem ze słuchu.
            if self.lyrics.lines.contains(where: { $0.isWordSynced }) { return }
            // Wszystkie znalezione wersje tekstu: aktualna + alternatywy. O wyborze decyduje to, co słychać w nagraniu.
            var versions = await LyricsService.shared.candidates(for: track)
            if let cur = self.lyrics.current, cur.hasSynced {
                versions.removeAll { $0.uid == cur.uid }
                versions.insert(cur, at: 0)
            }
            if Task.isCancelled || self.currentTrack?.id != track.id { return }
            let duration = self.clock.duration
            let candidates = versions
            let pick = await Task.detached(priority: .utility) {
                await LyricsAligner.choose(file: file, candidates: candidates, duration: duration)
            }.value
            if Task.isCancelled || self.currentTrack?.id != track.id { return }
            // W międzyczasie przyszedł tekst słowo po słowie (dokładny) - nie podmieniamy go wersją z linijkami.
            if self.lyrics.lines.contains(where: { $0.isWordSynced }) { return }
            guard let pick = pick else {
                // Było z czym porównywać, ale nic nie pasuje: zapamiętaj, żeby nie słuchać w kółko.
                if !candidates.isEmpty { LyricsWarpStore.markTried(track.id); self.settings.data.lyricsAligned[track.id] = false }
                return
            }
            LyricsWarpStore.save(track.id, uid: pick.candidate.uid, anchors: pick.anchors)
            self.settings.data.lyricsAligned[track.id] = true
            // Mapa czasu zawiera całe dopasowanie, więc ręczne offset/tempo wracają do zera (do dalszego dostrajania).
            self.settings.setLyricsOffset(0, for: track.id)
            self.settings.setLyricsStretch(1, for: track.id)
            if self.currentTrack?.id == track.id {
                if self.lyrics.current?.uid != pick.candidate.uid {
                    self.lyrics.choose(pick.candidate, for: track)
                }
                self.lyrics.setOffset(0)
                self.lyrics.setStretch(1)
                self.lyrics.setWarp(pick.anchors)
            }
        }
    }

    /// Pobiera od nowa adres strumienia bieżącego utworu i wznawia od tego samego miejsca.
    func reloadPlayer() {
        guard let t = currentTrack else { return }
        reloadAttempts = 0
        stalledTicks = 0
        isBuffering = wantsPlaying
        startLoad(track: t, startAt: resumeTime(for: t), forceRefresh: true)
    }

    // MARK: - Loading

    private func load(index: Int, pushHistory: Bool, startAt: Double = 0) {
        guard queue.indices.contains(index) else { return }
        if pushHistory, let cur = currentIndex {
            history.append(cur)
            if history.count > 200 { history.removeFirst() }
        }
        currentIndex = index
        plannedNext = nil
        shuffleBag.removeAll { $0 == index }
        let track = queue[index]
        wantsPlaying = true
        ended = false
        isBuffering = true
        isPlaying = false
        stalledTicks = 0
        reloadAttempts = 0
        refreshedURLForCurrent = false
        durationSuspect = false
        prematureRetries = 0
        stopBleepNow()
        censorScanTask?.cancel()
        censorScanTrackID = nil
        clock.time = startAt
        clock.duration = track.duration
        lastTime = startAt
        lastTimeID = track.id
        artwork = nil
        artworkTrackID = nil
        nowPlayingArtwork = nil
        activateSession()
        beginBackgroundGrace()
        detachItem()
        startLoad(track: track, startAt: startAt)
        resetRadioState()
        if !track.isRadio {
            remember(track)
            lyrics.load(track: track, offset: settings.lyricsOffset(for: track.id), stretch: settings.lyricsStretch(for: track.id))
            loadArtwork(for: track)
        } else {
            lyrics.clear()
            loadRadioArtwork(for: track)
            startRadioDetection(for: track)
        }
        updateNowPlaying()
    }

    // MARK: - Radio: logo, tytuł utworu, pozycja w piosence, tekst

    /// Pozycja w odtwarzanej piosence (sekundy). Z niej liczymy animację tekstu klatka po klatce.
    func livePlaybackTime() -> Double {
        if isRadio {
            guard radioPositionKnown else { return 0 }
            return max(0, radioPosBase + Date().timeIntervalSince(radioPosDate))
        }
        let t = player.currentTime().seconds
        return t.isFinite ? t : lastTime
    }

    /// Adres strumienia grającej stacji (dla strony z tekstem na drugim urządzeniu).
    var currentRadioURL: URL? { currentTrack.flatMap { radioURLs[$0.id] } }

    /// Telefon wyciszony, bo dźwięk gra na innym urządzeniu (strona z tekstem w przeglądarce).
    @Published private(set) var phoneMuted = false

    func setPhoneMuted(_ muted: Bool) {
        guard muted != phoneMuted else { return }
        phoneMuted = muted
        player.isMuted = muted
    }

    /// Ręczne przesunięcie tekstu w radiu (dodatnie = tekst pojawia się wcześniej).
    func nudgeRadioLyrics(by seconds: Double) {
        lyrics.setOffset(((lyrics.offset + seconds) * 100).rounded() / 100)
    }

    /// Ponowne wykrywanie utworu na żądanie (menu radia).
    func redetectRadioSong() {
        guard isRadio, let t = currentTrack else { return }
        startRadioDetection(for: t, immediate: true)
    }

    private func resetRadioState() {
        radioDetectTask?.cancel()
        radioDetectTask = nil
        radioSong = nil
        radioDetecting = false
        radioPositionKnown = false
        radioHasMeta = false
        radioPausedAt = nil
    }

    private func loadRadioArtwork(for track: Track) {
        guard let station = radioStations[track.id] else { return }
        Task { [weak self] in
            guard let img = await RadioIconCache.shared.resolve(station) else { return }
            guard let self = self, self.currentTrack?.id == track.id else { return }
            self.artwork = img
            self.artworkTrackID = track.id
            self.vibe = ArtworkLoader.vibe(of: img)
            self.nowPlayingArtwork = NowPlayingArtwork.make(img)
            self.updateNowPlaying()
        }
    }

    private func attachRadioMeta(to item: AVPlayerItem, station: String) {
        radioMeta.onUpdate = { [weak self] stream, artist, title in
            MainActor.assumeIsolated {
                self?.handleRadioMeta(stream: stream, artist: artist, title: title, station: station)
            }
        }
        radioMeta.attach(to: item)
    }

    private func handleRadioMeta(stream: String?, artist: String?, title: String?, station: String) {
        guard isRadio, currentTrack?.title == station else { return }
        var parsed: RadioSong? = nil
        if let s = stream {
            parsed = RadioSong.parse(s, station: station)
        } else if let t = title {
            parsed = RadioSong.parse(artist.map { "\($0) - \(t)" } ?? t, station: station)
        }
        guard let song = parsed else { return }
        // Pierwszy tytuł po połączeniu może dotyczyć piosenki trwającej już od dawna (pozycja nieznana).
        // Każdy kolejny oznacza, że nowa piosenka dopiero się zaczęła (pozycja 0).
        let alreadySeen = radioHasMeta
        radioHasMeta = true
        if let cur = radioSong, cur.matches(song) { return }
        applyRadioSong(song, position: 0, known: alreadySeen)
    }

    /// Ustawia grany utwór. Gdy to nowa piosenka, od razu szuka jej tekstu (z animacją, jeśli znamy pozycję).
    private func applyRadioSong(_ song: RadioSong, position: Double, known: Bool) {
        if let cur = radioSong, cur.matches(song) {
            if known && (!radioPositionKnown || abs(livePlaybackTime() - position) > 3) { setRadioPosition(position) }
            return
        }
        radioSong = song
        radioDetecting = false
        if known { setRadioPosition(position) } else { radioPositionKnown = false }
        lyrics.load(track: Track(id: song.cacheID, title: song.title, artist: song.artist, duration: 0), offset: 0, stretch: 1)
        updateNowPlaying()
    }

    private func setRadioPosition(_ seconds: Double) {
        radioPosBase = max(0, seconds)
        radioPosDate = Date()
        radioPositionKnown = true
        lyrics.tick(radioPosBase)
    }

    /// Wykrywanie utworu: najpierw dajemy stacji chwilę na podanie tytułu (metadane), a gdy go nie podaje,
    /// nagrywamy kilka sekund strumienia i rozpoznajemy go (AudD). Rozpoznanie podaje też miejsce w piosence.
    private func startRadioDetection(for track: Track, immediate: Bool = false) {
        radioDetectTask?.cancel()
        radioDetecting = (radioSong == nil)
        let id = track.id
        radioDetectTask = Task { [weak self] in
            if !immediate {
                // Najpierw połączenie: czekamy, aż strumień naprawdę zagra (maks. ok. 20 s), potem 6 s na metadane.
                var waited = 0
                while let me = self, !me.isPlaying, waited < 40 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    waited += 1
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
            var attempt = 0
            while !Task.isCancelled {
                guard let me = self, me.currentTrack?.id == id else { return }
                if !me.wantsPlaying {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                if me.radioHasMeta && me.radioPositionKnown { me.radioDetecting = false; return }
                if attempt >= 40 || (me.radioHasMeta && attempt >= 2) { me.radioDetecting = false; return }
                attempt += 1
                await me.recognizeRadio(trackID: id)
                guard !Task.isCancelled, me.currentTrack?.id == id else { return }
                me.radioDetecting = false
                if me.radioHasMeta && me.radioPositionKnown { return }
                let wait: UInt64 = (me.radioSong == nil && attempt < 3) ? 25 : 90
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    private func recognizeRadio(trackID: String) async {
        guard let url = radioURLs[trackID] else { return }
        let started = Date()
        guard let clip = await StreamClipCapture.capture(url: url, seconds: 12, maxBytes: 700_000),
              let hit = await AudDClient.recognize(data: clip.data, fileName: clip.fileName, mime: clip.mime) else { return }
        guard isRadio, currentTrack?.id == trackID else { return }
        // Pozycja teraz = miejsce, w którym zaczynała się próbka + czas, który od tego upłynął,
        // minus opóźnienie odtwarzacza względem transmisji na żywo (ok. 3 s).
        let position = hit.timecode + Date().timeIntervalSince(started) - 3.0
        applyRadioSong(RadioSong(artist: hit.artist, title: hit.title), position: position, known: true)
    }

    /// Gra stacje radiowe (transmisja na żywo).
    func playRadio(_ stations: [RadioStation], startAt index: Int) {
        guard !stations.isEmpty else { return }
        var urls: [String: URL] = [:]
        var byID: [String: RadioStation] = [:]
        var tracks: [Track] = []
        for s in stations {
            guard let u = URL(string: s.url) else { continue }
            let t = s.track
            urls[t.id] = u
            byID[t.id] = s
            tracks.append(t)
        }
        guard !tracks.isEmpty else { return }
        let wanted = stations[min(max(index, 0), stations.count - 1)].track.id
        isRadio = true
        radioURLs = urls
        radioStations = byID
        queue = tracks
        history = []
        plannedNext = nil
        shuffleBag = []
        failures = 0
        load(index: tracks.firstIndex { $0.id == wanted } ?? 0, pushHistory: false)
    }

    /// Gets the stream address (YouTubeKit) and hands it to AVPlayer.
    private func startLoad(track: Track, startAt: Double, forceRefresh: Bool = false) {
        loadTask?.cancel()
        let token = UUID()
        loadToken = token
        resolving = true
        loadTask = Task { [weak self] in
            do {
                // 0) Radio: strumień na żywo, bez pobierania.
                if track.isRadio {
                    guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                    guard let url = self.radioURLs[track.id] else {
                        self.handleResolveFailure(URLError(.badURL))
                        return
                    }
                    self.attach(url: url, track: track, startAt: 0, local: false)
                    return
                }
                // 1) Już pobrany na dysk -> start natychmiast, bez internetu.
                if !forceRefresh, let local = await AudioCache.shared.localURL(for: track.id) {
                    guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                    self.attach(url: local, track: track, startAt: startAt, local: true)
                    return
                }
                // 2) Nie ma go jeszcze: gramy ze strumienia, a w tle pobieramy go na stałe.
                let stream = try await StreamResolver.shared.resolve(track.id, forceRefresh: forceRefresh)
                guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                self.attach(url: stream.url, track: track, startAt: startAt, local: false)
            } catch {
                guard let self = self, self.loadToken == token, !Task.isCancelled else { return }
                self.handleResolveFailure(error)
            }
        }
    }

    /// Stops the previous song so its time can never leak into the next one.
    private func detachItem() {
        itemObservers.removeAll()
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player.pause()
        stopBleepNow()
        player.replaceCurrentItem(with: nil)
        isSeeking = false
    }

    private func attach(url: URL, track: Track, startAt: Double, local: Bool, align: Bool = true) {
        // Spóźniony wynik dla innej piosenki niż ta, która ma teraz grać, nigdy nie może zacząć grać.
        guard currentTrack?.id == track.id else { return }
        resolving = false
        playingLocalFile = local
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
        observe(item: item)
        if track.isRadio { attachRadioMeta(to: item, station: track.title) }
        player.replaceCurrentItem(with: item)
        if startAt > 0.5 {
            isSeeking = true
            player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in self?.isSeeking = false }
            }
        }
        // Radio zawsze gra w normalnym tempie (ustawienie szybkości dotyczy piosenek).
        player.defaultRate = track.isRadio ? 1 : Float(playbackRate)
        if wantsPlaying && !interrupted { player.play() }
        if track.isRadio { return }
        if local {
            if align { scheduleAutoAlign(track: track, file: url) }
        } else {
            // Pobierz utwór na stałe w tle, a gdy będzie na dysku - dopasuj do niego tekst. Od tej chwili
            // odtwarzacz może po cichu przejść ze strumienia na plik (bez internetu).
            let id = track.id
            Task(priority: .utility) { [weak self] in
                guard let file = await AudioCache.shared.ensure(id) else { return }
                self?.downloadFinished(id, file: file)
                self?.scheduleAutoAlign(track: track, file: file)
            }
        }
        prefetchNext()
    }

    // MARK: - Ze strumienia na plik (bez przerwy)

    /// Piosenka skończyła się pobierać. Zwykle gra dalej ze strumienia (przełączenie w trakcie grania byłoby
    /// słychać), a na plik przechodzi w chwili, gdy tego nie słychać: pauza, przewinięcie, zacięcie strumienia.
    /// Bez internetu - od razu, żeby muzyka nie stanęła.
    private func downloadFinished(_ id: String, file: URL) {
        localFiles[id] = file
        if localFiles.count > 40, let any = localFiles.keys.first(where: { $0 != id }) { localFiles[any] = nil }
        if currentTrack?.id == id, !Reachability.shared.online {
            swapToLocal(at: livePlaybackTime())
        }
    }

    /// Gra strumień, a plik tej piosenki już jest na dysku: przejdź na plik w tym samym miejscu.
    @discardableResult
    private func swapToLocal(at seconds: Double) -> Bool {
        guard !isRadio, !playingLocalFile, let t = currentTrack, let file = localFiles[t.id] else { return false }
        guard FileManager.default.fileExists(atPath: file.path) else {
            localFiles[t.id] = nil
            return false
        }
        let at = max(0, seconds.isFinite ? seconds : lastTime)
        lastTime = at
        lastTimeID = t.id
        stalledTicks = 0
        reloadAttempts = 0
        attach(url: file, track: t, startAt: at, local: true, align: false)
        return true
    }

    private func loadArtwork(for track: Track) {
        Task { [weak self] in
            let image = await ArtworkLoader.shared.artwork(for: track.id)
            guard let self = self, self.currentTrack?.id == track.id else { return }
            self.artwork = image
            self.artworkTrackID = image == nil ? nil : track.id
            self.vibe = image.flatMap { ArtworkLoader.vibe(of: $0) }
            self.nowPlayingArtwork = image.map { NowPlayingArtwork.make($0) }
            self.updateNowPlaying()
        }
    }

    private func nextIndex(auto: Bool) -> Int? {
        if let p = plannedNext, queue.indices.contains(p) { return p }
        guard let cur = currentIndex, !queue.isEmpty else { return nil }
        var result: Int? = nil
        if shuffle && queue.count > 1 {
            if shuffleBag.isEmpty {
                if auto && repeatMode == .off { return nil }
                shuffleBag = Array(queue.indices).filter { $0 != cur }
            }
            result = shuffleBag.randomElement()
        } else if cur + 1 < queue.count {
            result = cur + 1
        } else if repeatMode == .all {
            result = 0
        }
        plannedNext = result
        return result
    }

    /// Resolves the stream of the upcoming song in advance, so switching songs (also in the background) is instant.
    private func prefetchNext() {
        // Radio nic nie pobiera w tle.
        guard !isRadio else { return }
        guard repeatMode != .one, let n = nextIndex(auto: true), queue.indices.contains(n) else { return }
        // Następna piosenka dostaje pierwszeństwo, po niej jeszcze jedna - żeby przejścia były natychmiastowe.
        var upcoming = [queue[n]]
        if !shuffle, n + 1 < queue.count { upcoming.append(queue[n + 1]) }
        for (i, track) in upcoming.enumerated() {
            let id = track.id
            Task.detached(priority: .utility) { await AudioCache.shared.ensure(id, urgent: i == 0) }
            // Tekst też ściągamy z wyprzedzeniem (trafia na dysk), więc po przejściu jest od razu.
            Task.detached(priority: .utility) { _ = await LyricsService.shared.lyrics(for: track) }
        }
    }

    // MARK: - Player events

    private func setupPlayerObservers() {
        playerObservers.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncTimeControlStatus() }
        })
        // 10x na sekundę: dokładny zegar dla tekstów (wcześniej zdarzenia z YouTube przychodziły rzadko).
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.handleTime(time.seconds) }
        }
    }

    private func observe(item: AVPlayerItem) {
        itemObservers.removeAll()
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }

        itemObservers.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.handleItemStatus(status, item: item) }
        })
        itemObservers.append(item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let d = item.duration.seconds
            Task { @MainActor in self?.handleDuration(d) }
        })
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                // Koniec starego elementu (który już wymieniono) nie może przełączyć piosenki drugi raz.
                guard let self = self, let item = item, item === self.player.currentItem else { return }
                self.handleItemEnded()
            }
        }
    }

    private func syncTimeControlStatus() {
        switch player.timeControlStatus {
        case .playing:
            isPlaying = true
            isBuffering = false
            ended = false
            failures = 0
            stalledTicks = 0
            reloadAttempts = 0
            endBackgroundGrace()
            updateLatency()
        case .waitingToPlayAtSpecifiedRate:
            isPlaying = false
            isBuffering = wantsPlaying
        case .paused:
            isPlaying = false
            isBuffering = wantsPlaying && resolving
        @unknown default:
            break
        }
        applyBleep()
        updateNowPlaying()
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        guard item === player.currentItem, status == .failed else { return }
        handlePlaybackFailure()
    }

    private func handleDuration(_ d: Double) {
        guard d.isFinite, d > 1 else { return }
        // Zabezpieczenie: odtwarzacz zgłasza ~2x dłuższy czas niż ma piosenka. Pobranych plików NIGDY nie
        // usuwamy z tego powodu (mają zostać na stałe i grać bez internetu) - pokazujemy prawdziwą długość.
        if let t = currentTrack, t.duration > 10, d > t.duration * 1.8, d < t.duration * 2.2 {
            durationSuspect = true
            if abs(clock.duration - t.duration) > 0.5 { clock.duration = t.duration }
            return
        }
        durationSuspect = false
        if abs(d - clock.duration) > 0.5 {
            clock.duration = d
            if let i = currentIndex, queue.indices.contains(i), queue[i].duration <= 0 { queue[i].duration = d }
        }
        if abs(d - lastNowPlayingDuration) > 0.5 { updateNowPlaying() }
    }

    private func handleTime(_ t: Double) {
        guard t.isFinite, !isSeeking else { return }
        // Spóźniony odczyt czasu ze starej piosenki (albo gdy nic nie jest załadowane) nie może przestawić zegara nowej.
        guard player.currentItem != nil, !resolving else { return }
        lastTimeID = currentTrack?.id
        if clock.duration > 0, t > clock.duration + 2 { return }
        lastTime = t
        clock.time = t
        // Radio: tekst idzie za pozycją w piosence (nie za czasem strumienia). Nieznana pozycja = bez animacji.
        lyrics.tick(isRadio ? (radioPositionKnown ? livePlaybackTime() : -1) : t)
        updateCensor(at: t)
        if let d = player.currentItem?.duration.seconds { handleDuration(d) }
        // Gdy czas pliku jest podwojony, kończymy piosenkę w jej prawdziwej długości (bez grania jej drugi raz).
        if durationSuspect, let tr = currentTrack, tr.duration > 10, t >= tr.duration - 0.3, !ended {
            durationSuspect = false
            handleItemEnded()
            return
        }
        // Odświeżaj ekran blokady co ~10 s, żeby pozycja nie "uciekała".
        nowPlayingTick += 1
        if nowPlayingTick >= 100 { nowPlayingTick = 0; updateNowPlaying() }
    }

    private func handleItemEnded() {
        guard !ended else { return }
        // Strumień urwał się w środku (np. na 0:38) - to nie koniec piosenki. Wznów od tego miejsca zamiast przechodzić dalej.
        if let tr = currentTrack, tr.duration > 20, lastTime < tr.duration - 8, prematureRetries < 3 {
            prematureRetries += 1
            isBuffering = wantsPlaying
            if swapToLocal(at: resumeTime(for: tr)) { return }
            startLoad(track: tr, startAt: resumeTime(for: tr), forceRefresh: true)
            return
        }
        ended = true
        isPlaying = false
        stopBleepNow()
        trackEnded()
    }

    private func trackEnded() {
        // Strumień radiowy się urwał: łączymy się z tą samą stacją od nowa.
        if isRadio, let t = currentTrack {
            ended = false
            startLoad(track: t, startAt: 0, forceRefresh: true)
            return
        }
        if sleepAfterTrack {
            // Wyłącznik czasowy "po tej piosence".
            sleepAfterTrack = false
            wantsPlaying = false
            isPlaying = false
            isBuffering = false
            updateNowPlaying()
            toast.show("Dobranoc! Muzyka zatrzymana po piosence.")
            return
        }
        if repeatMode == .one, currentTrack != nil {
            ended = false
            clock.time = 0
            lastTime = 0
            lyrics.tick(0)
            stopBleepNow()
            player.seek(to: .zero)
            player.play()
            return
        }
        if let n = nextIndex(auto: true) {
            load(index: n, pushHistory: true)
        } else {
            wantsPlaying = false
            updateNowPlaying()
        }
    }

    private func handleResolveFailure(_ error: Error) {
        resolving = false
        isBuffering = false
        fail(FailureText.describe(error))
    }

    /// The stream address may have expired or been refused - fetch a fresh one once, then give up.
    private func handlePlaybackFailure() {
        guard let t = currentTrack, wantsPlaying else { return }
        // Strumień padł, a plik już jest pobrany: gramy dalej z pliku.
        if swapToLocal(at: resumeTime(for: t)) { return }
        if !refreshedURLForCurrent {
            refreshedURLForCurrent = true
            isBuffering = true
            if playingLocalFile {
                // Uszkodzony plik na dysku - usuń go i zagraj ze strumienia.
                let id = t.id
                localFiles[id] = nil
                Task { await AudioCache.shared.remove(id: id) }
            }
            startLoad(track: t, startAt: resumeTime(for: t), forceRefresh: true)
        } else {
            fail(t.isRadio ? "Nie udało się połączyć ze stacją." : "Nie udało się odtworzyć tego utworu.")
        }
    }

    private func fail(_ message: String) {
        toast.show(message)
        stalledTicks = -6   // give the "skip to next song" below time before the watchdog reacts
        if isRadio {
            // Przy radiu nie przeskakujemy na inną stację - zatrzymujemy i czekamy na decyzję.
            wantsPlaying = false
            isBuffering = false
            updateNowPlaying()
            return
        }
        failures += 1
        if failures >= 5 {
            wantsPlaying = false
            isBuffering = false
            return
        }
        let failedID = currentTrack?.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self = self, self.currentTrack?.id == failedID, self.wantsPlaying else { return }
            if let n = self.nextIndex(auto: true) { self.load(index: n, pushHistory: true) }
        }
    }

    // MARK: - Audio session, background

    /// Playback category once; re-activate when needed.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setActive(true)
    }

    /// Opóźnienie wyjścia audio (np. Bluetooth ~0,2 s): to, co słychać, jest tyle "spóźnione" względem zegara
    /// odtwarzacza. Teksty muszą to uwzględnić, inaczej wyprzedzają piosenkę.
    private func updateLatency() {
        let latency = AVAudioSession.sharedInstance().outputLatency
        lyrics.setLatency(latency.isFinite ? min(max(latency, 0), 1.0) : 0)
    }

    /// Co 1 s: jeśli ma grać, a nie gra (zerwana sieć, wygasły link), próbuje wznowić, potem pobiera nowy adres.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                self.watchdogTick()
            }
        }
    }

    private func watchdogTick() {
        checkSleepTimer()
        guard wantsPlaying, !interrupted, !ended, let t = currentTrack else { stalledTicks = 0; return }
        if isPlaying { stalledTicks = 0; reloadAttempts = 0; resolveTicks = 0; return }
        if stalledTicks < 0 { stalledTicks += 1; return }
        if resolving {
            // Pobieranie adresu strumienia trwa podejrzanie długo - przerwij i przejdź dalej.
            resolveTicks += 1
            if resolveTicks > 30 {
                resolveTicks = 0
                resolving = false
                loadTask?.cancel()
                fail("YouTube nie odpowiada. Sprawdź internet.")
            }
            return
        }
        resolveTicks = 0
        guard player.currentItem != nil else { return }
        stalledTicks += 1
        // Strumień się zaciął (słaby internet), a plik już jest na dysku: od razu gramy z pliku.
        if stalledTicks >= 2, swapToLocal(at: resumeTime(for: t)) { return }
        if stalledTicks % 5 == 0 {
            // Za długo bez dźwięku: nowy adres strumienia od bieżącej pozycji.
            reloadAttempts += 1
            if reloadAttempts > 4 {
                wantsPlaying = false
                isBuffering = false
                player.pause()
                applyBleep()
                toast.show("Odtwarzanie zatrzymane. Kliknij play, aby spróbować ponownie.")
                updateNowPlaying()
                return
            }
            isBuffering = true
            startLoad(track: t, startAt: resumeTime(for: t), forceRefresh: true)
        } else if player.timeControlStatus == .paused {
            activateSession()
            player.play()
        }
    }

    /// Keeps the app running for a few seconds while the next song is being loaded in the background.
    private func beginBackgroundGrace() {
        endBackgroundGrace()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "track-change") { [weak self] in
            Task { @MainActor in self?.endBackgroundGrace() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            self?.endBackgroundGrace()
        }
    }

    private func endBackgroundGrace() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let reason = n.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Task { @MainActor in self?.handleInterruption(type, opts, reason) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let reason = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.updateLatency()
                self?.handleRouteChange(reason)
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                self?.activateSession()
                if self?.wantsPlaying == true, let t = self?.currentTrack {
                    self?.startLoad(track: t, startAt: self?.resumeTime(for: t) ?? 0)
                }
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.activateSession()
                self.updateLatency()
                if self.wantsPlaying && !self.interrupted && self.player.currentItem != nil && self.player.timeControlStatus == .paused {
                    self.player.play()
                }
            }
        })
    }

    private func handleInterruption(_ type: UInt?, _ options: UInt, _ reason: UInt?) {
        guard let raw = type, let t = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if t == .began {
            // Powód 1 = aplikacja została zawieszona, 2 = wyciszony mikrofon: to nie jest prawdziwe przerwanie.
            if let r = reason, r == 1 || r == 2 { return }
            interrupted = true
            wasPlayingBeforeInterruption = wantsPlaying
            applyBleep()
        } else {
            interrupted = false
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            if shouldResume && wasPlayingBeforeInterruption { play() }
        }
    }

    private func handleRouteChange(_ reason: UInt?) {
        guard let raw = reason, let r = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if r == .oldDeviceUnavailable && isPlaying { pause() }
    }

    // MARK: - Lock screen / headphones

    private func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerEngine) -> Void) {
        command.addTarget { [weak self] _ in
            Task { @MainActor in
                if let engine = self { action(engine) }
            }
            return .success
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        bind(c.playCommand) { $0.play() }
        bind(c.pauseCommand) { $0.pause() }
        bind(c.stopCommand) { $0.pause() }
        bind(c.togglePlayPauseCommand) { $0.togglePlayPause() }
        bind(c.nextTrackCommand) { $0.next() }
        bind(c.previousTrackCommand) { $0.previous() }
        c.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.skip(by: interval) }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in self?.skip(by: -interval) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        applyRemoteEnablement()
    }

    /// Ekran blokady i słuchawki: zawsze przyciski następny / poprzedni utwór (bez przewijania o sekundy).
    func applyRemoteEnablement() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.stopCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.changePlaybackPositionCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        lastNowPlayingDuration = clock.duration
        // Radio: na ekranie blokady tytuł utworu, a pod nim nazwa stacji.
        var shownTitle = t.title
        var shownArtist = t.artist
        if t.isRadio, let s = radioSong {
            shownTitle = s.title
            shownArtist = s.artist.isEmpty ? t.title : "\(s.artist) · \(t.title)"
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: shownTitle,
            MPMediaItemPropertyArtist: shownArtist,
            MPMediaItemPropertyPlaybackDuration: max(clock.duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(clock.time, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if t.isRadio { info[MPNowPlayingInfoPropertyIsLiveStream] = true }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }
}
