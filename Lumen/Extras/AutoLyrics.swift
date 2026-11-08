import Foundation
import NaturalLanguage

/// Teksty zrobione ze słuchu (rozpoznawanie mowy na urządzeniu), gdy w internecie nie ma tekstu z czasami.
/// 1) Jest tekst bez czasów -> czasy każdej linijki są ustawiane po tym, co słychać w nagraniu.
/// 2) Nie ma żadnego tekstu -> tekst jest budowany z usłyszanych słów (mogą być błędy).
enum AutoLyrics {
    static func build(track: Track, file: URL, duration: Double, plain: String) async -> LyricsCandidate? {
        var locales: [String] = []
        let sample = plain.isEmpty ? "\(track.title) \(track.artist)" : plain
        locales.append(SongTranscript.localeID(forText: sample))
        for l in ["en-US", "pl-PL"] where !locales.contains(l) { locales.append(l) }

        var best: [HeardWord] = []
        for loc in locales.prefix(plain.isEmpty ? 2 : 1) {
            guard let w = await SongTranscript.words(id: track.id, file: file, duration: duration, locale: loc) else { continue }
            if w.count > best.count { best = w }
            if w.count >= 40 { break }
        }
        guard best.count >= 12 else { return nil }
        best.sort { $0.time < $1.time }

        let lrc: String?
        if plain.isEmpty {
            lrc = lrcFromHeard(best)
        } else {
            lrc = lrcFromPlain(plain, heard: best)
        }
        guard let synced = lrc, !LRCParser.parse(synced).isEmpty else { return nil }
        var hash = 7
        for u in track.id.unicodeScalars { hash = (hash &* 31 &+ Int(u.value)) % 1_000_000_007 }
        return LyricsCandidate(id: hash, trackName: track.title, artistName: track.artist, albumName: nil,
                               duration: duration > 0 ? duration : nil, instrumental: false,
                               plainLyrics: plain.isEmpty ? nil : plain, syncedLyrics: synced, source: "Auto")
    }

    // MARK: Z usłyszanych słów

    private static func lrcFromHeard(_ words: [HeardWord]) -> String? {
        var out: [String] = []
        var line: [String] = []
        var lineStart = 0.0
        var lastEnd = 0.0
        func flush() {
            guard !line.isEmpty else { return }
            var text = line.joined(separator: " ")
            text = text.prefix(1).uppercased() + text.dropFirst()
            out.append("\(stamp(lineStart))\(text)")
            line = []
        }
        for w in words {
            let word = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.isEmpty { continue }
            if line.isEmpty { lineStart = w.time }
            else if w.time - lastEnd > 0.7 || line.count >= 9 { flush(); lineStart = w.time }
            line.append(word)
            lastEnd = w.time + w.dur
        }
        flush()
        return out.count >= 3 ? out.joined(separator: "\n") : nil
    }

    // MARK: Tekst bez czasów + nagranie

    private static func lrcFromPlain(_ plain: String, heard: [HeardWord]) -> String? {
        let lines = plain.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }
        guard lines.count >= 3 else { return nil }
        let heardNorm = heard.map { normalize($0.word) }
        var times = [Double?](repeating: nil, count: lines.count)
        var pointer = 0
        var matched = 0
        for (i, line) in lines.enumerated() {
            let tokens = line.split(separator: " ").map { normalize(String($0)) }.filter { !$0.isEmpty }
            guard !tokens.isEmpty else { continue }
            let k = min(3, tokens.count)
            let need = max(1, k - 1)
            var j = pointer
            let limit = min(pointer + 500, heardNorm.count - k)
            while j <= limit {
                var hits = 0
                for t in 0..<k where similar(heardNorm[j + t], tokens[t]) { hits += 1 }
                if hits >= need && similar(heardNorm[j], tokens[0]) || hits == k {
                    times[i] = heard[j].time
                    pointer = j + 1
                    matched += 1
                    break
                }
                j += 1
            }
        }
        guard Double(matched) / Double(lines.count) >= 0.35 else { return nil }

        // Luki: równomiernie między znanymi czasami.
        let known = times.enumerated().compactMap { (i, t) in t.map { (i, $0) } }
        guard let first = known.first, let last = known.last else { return nil }
        var filled = [Double](repeating: 0, count: lines.count)
        for i in 0..<lines.count {
            if let t = times[i] { filled[i] = t; continue }
            if i < first.0 { filled[i] = max(0, first.1 - 2.5 * Double(first.0 - i)); continue }
            if i > last.0 { filled[i] = last.1 + 3.0 * Double(i - last.0); continue }
            let prev = known.last(where: { $0.0 < i }) ?? first
            let next = known.first(where: { $0.0 > i }) ?? last
            let f = Double(i - prev.0) / Double(max(1, next.0 - prev.0))
            filled[i] = prev.1 + (next.1 - prev.1) * f
        }
        // Czasy mają rosnąć.
        for i in 1..<filled.count where filled[i] <= filled[i - 1] { filled[i] = filled[i - 1] + 0.05 }
        return lines.enumerated().map { "\(stamp(filled[$0.offset]))\($0.element)" }.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func stamp(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "[%02d:%05.2f]", Int(s) / 60, s - Double(Int(s) / 60 * 60))
    }

    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        guard a.count > 4, b.count > 4, abs(a.count - b.count) <= 1 else { return false }
        let x = Array(a), y = Array(b)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count { return Array(x[(i + 1)...]) == Array(y[(i + 1)...]) }
        return x.count > y.count ? Array(x[(i + 1)...]) == Array(y[i...]) : Array(y[(i + 1)...]) == Array(x[i...])
    }
}
