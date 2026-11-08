import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Słowo usłyszane w nagraniu (rozpoznawanie mowy Apple, na urządzeniu) wraz z czasem w całym utworze.
struct HeardWord: Codable, Equatable {
    var word: String
    var time: Double
    var dur: Double
}

/// Nasłuchuje CAŁEGO pobranego utworu (kawałkami po ~45 s) i zapisuje wynik na dysku, więc każda piosenka
/// jest słuchana tylko raz. Z tego korzystają: (1) cenzura przekleństw - także w piosenkach BEZ tekstu,
/// (2) dopasowanie tempa i czasu tekstu do nagrania.
enum SongTranscript {
    private static let chunkLength = 45.0
    private static let step = 40.0
    private static let trim = 2.5       // brzegi kawałków są mniej wiarygodne - kawałki zachodzą na siebie
    private static let parallel = 3

    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }()

    static func removeCache(id: String) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix("\(id)-") { try? FileManager.default.removeItem(at: f) }
    }

    /// Słowa z całego utworu dla danego języka (np. "pl-PL"). nil = nie udało się nasłuchać.
    static func words(id: String, file: URL, duration: Double, locale: String) async -> [HeardWord]? {
        let cacheURL = dir.appendingPathComponent("\(id)-\(locale).json")
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode([HeardWord].self, from: data) {
            return cached
        }
        guard await LyricsAligner.authorize() else { return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else { return nil }

        var total = duration
        if total < 5 {
            let secs = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
            total = secs.isFinite ? secs : 0
        }
        guard total > 5 else { return nil }

        var starts: [Double] = []
        var s = 0.0
        while s < total - 3 { starts.append(s); s += step }

        var collected: [(index: Int, words: [HeardWord])] = []
        var failures = 0
        var i = 0
        while i < starts.count {
            if Task.isCancelled { return nil }
            let batch = Array(starts.indices[i..<min(i + parallel, starts.count)])
            let results: [(Int, [HeardWord]?)] = await withTaskGroup(of: (Int, [HeardWord]?).self) { group in
                for idx in batch {
                    let start = starts[idx]
                    let length = min(chunkLength, total - start)
                    let isFirst = idx == 0
                    let isLast = idx == starts.count - 1
                    group.addTask {
                        let w = await listen(file: file, start: start, length: length, recognizer: recognizer)
                        guard let heard = w else { return (idx, nil) }
                        let lo = start + (isFirst ? 0 : trim)
                        let hi = start + length - (isLast ? 0 : trim)
                        return (idx, heard.filter { $0.time >= lo && $0.time < hi })
                    }
                }
                var out: [(Int, [HeardWord]?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (idx, w) in results {
                if let w = w { collected.append((idx, w)) } else { failures += 1 }
            }
            i += parallel
        }
        if Task.isCancelled { return nil }
        guard failures < starts.count else { return nil }

        let all = collected.sorted { $0.index < $1.index }.flatMap { $0.words }.sorted { $0.time < $1.time }
        // Zapisujemy tylko kompletny wynik - przy błędach spróbujemy ponownie następnym razem.
        if failures == 0, let data = try? JSONEncoder().encode(all) { try? data.write(to: cacheURL, options: .atomic) }
        return all
    }

    // MARK: Listening

    private static func listen(file: URL, start: Double, length: Double, recognizer: SFSpeechRecognizer) async -> [HeardWord]? {
        guard length > 1.5 else { return [] }
        guard let clip = await LyricsAligner.exportClip(file: file, start: start, length: length) else { return nil }
        defer { try? FileManager.default.removeItem(at: clip) }
        guard let raw = await recognize(url: clip, recognizer: recognizer) else { return nil }
        return raw.map { HeardWord(word: $0.word, time: start + $0.time, dur: $0.dur) }
    }

    private final class Once {
        var done = false
        var task: SFSpeechRecognitionTask?
    }

    /// Słowa rozpoznane w klipie (czas względem początku klipu). Pusty wynik = brak mowy w tym fragmencie.
    private static func recognize(url: URL, recognizer: SFSpeechRecognizer) async -> [(word: String, time: Double, dur: Double)]? {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let box = Once()
        return await withCheckedContinuation { cont in
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if box.done { return }
                if let result = result, result.isFinal {
                    box.done = true
                    let words = result.bestTranscription.segments.map { (word: $0.substring, time: $0.timestamp, dur: $0.duration) }
                    box.task = nil
                    cont.resume(returning: words)
                } else if let error = error {
                    box.done = true
                    box.task = nil
                    // 1110 = "No speech detected" - fragment instrumentalny, to nie jest błąd.
                    cont.resume(returning: (error as NSError).code == 1110 ? [] : nil)
                }
            }
        }
    }

    // MARK: Language

    /// Kod języka dla rozpoznawania mowy na podstawie tekstu piosenki.
    static func localeID(forText text: String) -> String {
        let detector = NLLanguageRecognizer()
        detector.processString(text)
        let code = detector.dominantLanguage?.rawValue ?? "en"
        let map = ["pl": "pl-PL", "en": "en-US", "es": "es-ES", "de": "de-DE", "fr": "fr-FR", "it": "it-IT",
                   "pt": "pt-BR", "ru": "ru-RU", "uk": "uk-UA", "nl": "nl-NL", "sv": "sv-SE", "tr": "tr-TR"]
        let id = map[code] ?? code
        if SFSpeechRecognizer(locale: Locale(identifier: id)) != nil { return id }
        return "en-US"
    }
}

/// Dokładne czasy wulgarnych słów w nagraniu - działa dla KAŻDEJ piosenki, także gdy nie ma żadnego tekstu.
enum ProfanityScanner {
    static func windows(id: String, file: URL, duration: Double, textSample: String) async -> [(start: Double, end: Double)] {
        // Znamy tekst = znamy język. Bez tekstu sprawdzamy polski i angielski.
        let locales = textSample.count > 20 ? [SongTranscript.localeID(forText: textSample)] : ["pl-PL", "en-US"]
        var raw: [(start: Double, end: Double)] = []
        for loc in locales {
            if Task.isCancelled { return [] }
            guard let words = await SongTranscript.words(id: id, file: file, duration: duration, locale: loc) else { continue }
            for w in words where isProfane(w.word) {
                let len = min(max(w.dur, 0.35), 1.6)
                raw.append((w.time - 0.15, w.time + len + 0.25))
            }
        }
        return merge(raw)
    }

    /// Rozpoznawanie mowy czasem samo zasłania przekleństwa gwiazdkami ("f***") - to też wyciszamy.
    private static func isProfane(_ word: String) -> Bool {
        if word.contains("*") { return word.filter { $0.isLetter }.count >= 1 }
        return Profanity.isProfane(word)
    }

    private static func merge(_ list: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        var out: [(start: Double, end: Double)] = []
        for w in list.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, w.start <= last.end + 0.05 {
                out[out.count - 1].end = max(last.end, w.end)
            } else {
                out.append(w)
            }
        }
        return out
    }
}
