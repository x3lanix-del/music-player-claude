import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Mądre słuchanie piosenki. Aplikacja nasłuchuje CAŁEGO pobranego nagrania (rozpoznawanie mowy Apple, na
/// urządzeniu), porównuje usłyszane słowa ze WSZYSTKIMI znalezionymi wersjami tekstu i wybiera tę, która
/// najlepiej pasuje do nagrania. Potem buduje "mapę czasu" tekstu: wiele punktów kontrolnych w całym utworze
/// (a nie jedną prostą), więc tekst nadąża także wtedy, gdy wersja z tekstem ma inne tempo, wycięty fragment
/// albo przerwę w innym miejscu niż nagranie z YouTube.
enum LyricsAligner {
    struct Fit {
        var offset: Double      // sekundy (dodatnie = tekst wcześniej) - używane tylko przy ręcznym dostrajaniu
        var stretch: Double     // 1.0 = bez zmian
        var votes: Int
    }

    /// Punkt kontrolny: w chwili `t` nagrania tekst jest przesunięty o `d` sekund (czas tekstu = t + d).
    struct Anchor: Codable, Equatable {
        var t: Double
        var d: Double
    }

    struct Pick {
        var candidate: LyricsCandidate
        var fit: Fit
        var anchors: [Anchor]
    }

    // MARK: Public

    /// Wybiera wersję tekstu najlepiej pasującą do nagrania i buduje mapę czasu dla całej piosenki.
    static func choose(file: URL, candidates: [LyricsCandidate], duration: Double) async -> Pick? {
        guard await authorize() else { return nil }
        var versions: [(cand: LyricsCandidate, lines: [LyricLine])] = []
        for c in candidates {
            if case .synced(let all) = LyricsService.result(from: c) {
                let sung = all.filter { !$0.text.isEmpty }
                if sung.count >= 6 { versions.append((c, sung)) }
            }
        }
        guard let first = versions.first else { return nil }
        let sample = first.lines.prefix(60).map { $0.text }.joined(separator: " ")
        let locale = SongTranscript.localeID(forText: sample)
        let id = file.deletingPathExtension().lastPathComponent
        guard let heardAll = await SongTranscript.words(id: id, file: file, duration: duration, locale: locale),
              heardAll.count >= 12 else { return nil }
        let words = heardAll.map { (word: normalize($0.word), time: $0.time) }.filter { !$0.word.isEmpty }

        var best: (score: Int, pick: Pick)? = nil
        for v in versions {
            guard let r = buildAnchors(words: words, lines: v.lines) else { continue }
            // Przy remisie zostaje wcześniejsza (lepiej oceniona z nazwy i czasu trwania) wersja.
            if r.votes > (best?.score ?? 0) {
                best = (r.votes, Pick(candidate: v.cand, fit: Fit(offset: 0, stretch: 1, votes: r.votes), anchors: r.anchors))
            }
        }
        return best?.pick
    }

    // MARK: Matching

    /// Dopasowuje linijki tekstu do usłyszanych słów w całej piosence i zamienia to na punkty kontrolne.
    private static func buildAnchors(words: [(word: String, time: Double)], lines: [LyricLine]) -> (anchors: [Anchor], votes: Int)? {
        let found = matchPairs(words: words, lines: lines)
        guard found.count >= 4 else { return nil }

        // Główne przesunięcie: największa grupa zgodnych wyników (±0,6 s). Refreny dają rozproszone wyniki.
        guard let base = densestCluster(found.map { $0.delta }, width: 2.0)?.median else { return nil }
        let near = found.filter { abs($0.delta - base) <= 20 }.sorted { $0.time < $1.time }
        guard near.count >= 4 else { return nil }

        // Co ~20 s osobny punkt kontrolny (mediana najliczniejszej grupy w tym przedziale).
        var buckets: [Int: [(time: Double, delta: Double)]] = [:]
        for p in near { buckets[Int(p.time / 20), default: []].append(p) }
        var anchors: [(t: Double, d: Double, votes: Int)] = []
        for key in buckets.keys.sorted() {
            let items = buckets[key]!
            guard let c = densestCluster(items.map { $0.delta }, width: 2.0), c.count >= 2 else { continue }
            let members = items.filter { abs($0.delta - c.median) <= 1.0 }
            let t = members.map { $0.time }.reduce(0, +) / Double(max(members.count, 1))
            anchors.append((t, c.median, c.count))
        }
        guard !anchors.isEmpty else { return nil }

        // Pojedynczy punkt "z kosmosu" (różni się o >2,5 s od obu sąsiadów, mało głosów) to pomyłka rozpoznawania.
        var cleaned: [(t: Double, d: Double, votes: Int)] = []
        for (k, a) in anchors.enumerated() {
            let prev = k > 0 ? anchors[k - 1].d : nil
            let next = k + 1 < anchors.count ? anchors[k + 1].d : nil
            let farPrev = prev.map { abs(a.d - $0) > 2.5 } ?? true
            let farNext = next.map { abs(a.d - $0) > 2.5 } ?? true
            if anchors.count >= 3, farPrev, farNext, a.votes < 4 { continue }
            cleaned.append(a)
        }
        // Czas tekstu musi płynąć do przodu: zbyt gwałtowne cofnięcie oznacza błędny punkt.
        var mono: [(t: Double, d: Double, votes: Int)] = []
        for a in cleaned {
            if let last = mono.last, a.t > last.t, (a.d - last.d) / (a.t - last.t) < -0.4 { continue }
            mono.append(a)
        }
        guard !mono.isEmpty else { return nil }
        let votes = mono.map { $0.votes }.reduce(0, +)
        guard votes >= 4 else { return nil }
        let out = mono.map { Anchor(t: ($0.t * 100).rounded() / 100, d: ($0.d * 100).rounded() / 100) }
        return (out, votes)
    }

    /// Dopasowanie CAŁEGO tekstu do CAŁEGO nagrania naraz (najdłuższy wspólny podciąg słów, w kolejności).
    /// Dzięki temu tekst, który zaczyna się od innej zwrotki albo ma powtórzone refreny, jest ustawiany
    /// tam, gdzie słowa naprawdę padają - a nie według pierwszej pasującej linijki.
    private static func matchPairs(words: [(word: String, time: Double)], lines: [LyricLine]) -> [(time: Double, delta: Double)] {
        // słowa tekstu z szacowanym czasem (pozycja w linijce rozłożona na czas jej trwania)
        var lyric: [(word: String, time: Double)] = []
        for (i, line) in lines.enumerated() {
            let tokens = line.text.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { continue }
            let next = i + 1 < lines.count ? lines[i + 1].time : line.time + 4
            let dur = min(max(next - line.time, 1.0), 6.0) * 0.9
            for (k, t) in tokens.enumerated() where t.count >= 4 {
                lyric.append((t, line.time + dur * Double(k) / Double(tokens.count)))
            }
        }
        let heard = words.filter { $0.word.count >= 4 }
        let n = min(lyric.count, 1400), m = min(heard.count, 1400)
        guard n >= 8, m >= 8 else { return [] }

        // tablica długości wspólnego podciągu
        var dp = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        let w = m + 1
        for i in 1...n {
            for j in 1...m {
                if similar(lyric[i - 1].word, heard[j - 1].word) {
                    dp[i * w + j] = dp[(i - 1) * w + (j - 1)] + 1
                } else {
                    dp[i * w + j] = max(dp[(i - 1) * w + j], dp[i * w + (j - 1)])
                }
            }
        }
        var out: [(time: Double, delta: Double)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            if similar(lyric[i - 1].word, heard[j - 1].word) && dp[i * w + j] == dp[(i - 1) * w + (j - 1)] + 1 {
                out.append((heard[j - 1].time, lyric[i - 1].time - heard[j - 1].time))
                i -= 1; j -= 1
            } else if dp[(i - 1) * w + j] >= dp[i * w + (j - 1)] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return out.reversed()
    }

    /// Najliczniejsza grupa wartości mieszcząca się w przedziale `width` (mediana grupy i jej liczność).
    private static func densestCluster(_ values: [Double], width: Double) -> (median: Double, count: Int)? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        var bestRange = 0..<1
        var lo = 0
        for hi in sorted.indices {
            while sorted[hi] - sorted[lo] > width { lo += 1 }
            if hi + 1 - lo > bestRange.count { bestRange = lo..<(hi + 1) }
        }
        let group = Array(sorted[bestRange])
        return (group[group.count / 2], group.count)
    }

    // MARK: Authorization / language

    static func authorize() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    // MARK: Helpers

    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map { Character($0) })
    }

    /// Takie samo słowo albo różnica jednej litery (rozpoznawanie mowy często myli końcówki).
    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 5, abs(a.count - b.count) <= 1 else { return false }
        return editDistanceAtMostOne(Array(a), Array(b))
    }

    private static func editDistanceAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if b.count > a.count { j += 1 } else { i += 1; j += 1 }
        }
        edits += (a.count - i) + (b.count - j)
        return edits <= 1
    }

    static func exportClip(file: URL, start: Double, length: Double) async -> URL? {
        let asset = AVURLAsset(url: file)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("align-\(UUID().uuidString).m4a")
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: length, preferredTimescale: 600))
        return await withCheckedContinuation { cont in
            session.exportAsynchronously {
                cont.resume(returning: session.status == .completed ? out : nil)
            }
        }
    }

    // MARK: Zapis mapy czasu

    /// Mapa czasu zapisana na dysku (żeby nie słuchać piosenki za każdym razem).
    struct Stored: Codable {
        var uid: String
        var anchors: [Anchor]
    }
}

enum LyricsWarpStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let folder = base.appendingPathComponent("Lumen/LyricsWarp2", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static func url(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    static func exists(_ id: String) -> Bool { FileManager.default.fileExists(atPath: url(id).path) }

    static func load(_ id: String) -> LyricsAligner.Stored? {
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? JSONDecoder().decode(LyricsAligner.Stored.self, from: data)
    }

    static func save(_ id: String, uid: String, anchors: [LyricsAligner.Anchor]) {
        let stored = LyricsAligner.Stored(uid: uid, anchors: anchors)
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: url(id), options: .atomic) }
    }

    /// Zapis "próbowano, nic nie wyszło / użytkownik zresetował" - bez map czasu.
    static func markTried(_ id: String) { save(id, uid: "", anchors: []) }

    static func remove(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }
}
