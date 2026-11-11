import Foundation

struct Track: Identifiable, Codable, Hashable, Sendable {
    var id: String          // YouTube video id
    var title: String
    var artist: String
    var duration: Double    // seconds, 0 if unknown

    /// Stacje radiowe wchodzą do kolejki jako "utwory" o identyfikatorze radio:<id stacji>.
    var isRadio: Bool { id.hasPrefix("radio:") }

    var artworkURL: URL? { isRadio ? nil : URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") }
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)") ?? URL(string: "https://www.youtube.com")! }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var tracks: [Track] = []
    /// Nazwa pliku własnej ikony (w Application Support/Lumen/Covers). nil = okładka pierwszej piosenki.
    var coverFile: String? = nil
}

enum Pl {
    /// Polska odmiana: 1 piosenka, 2-4 piosenki, 5+ piosenek.
    static func songs(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if n == 1 { return "1 piosenka" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) piosenki" }
        return "\(n) piosenek"
    }
}

extension Pl {
    /// Łączny czas: "45 min", "1 godz. 5 min".
    static func length(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) godz." : "\(h) godz. \(m) min"
    }
}

enum Fmt {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let t = Int(seconds.rounded(.down))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Lyrics (LRC)

/// Jeden kawałek linijki z własnym czasem: słowo albo sylaba (np. "e" + "nough"). `text` jest zapisany tak, jak
/// przyszedł ze źródła - spacja na końcu oznacza koniec słowa, jej brak = ciąg dalszy tego samego słowa.
struct LyricRun: Equatable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
    /// Czasy słów/sylab (puste = źródło ma tylko czasy całych linijek).
    var words: [LyricRun] = []

    var isWordSynced: Bool { !words.isEmpty }
}

enum LRCParser {
    /// Parses "[mm:ss.xx] text" lines (multiple time tags, offset tag and word tags supported).
    /// Linijki w formacie "enhanced" (`[mm:ss.xx]<mm:ss.xx>słowo <mm:ss.xx>słowo`) dostają `words` z czasami słów.
    static func parse(_ raw: String) -> [LyricLine] {
        var entries: [(time: Double, text: String, runs: [LyricRun])] = []
        var offset = 0.0
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            var rest = rawLine.trimmingCharacters(in: .whitespaces)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = String(rest[rest.index(after: close)...])
                if let t = parseTimestamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:") {
                    let value = tag.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    if let ms = Double(value) { offset = ms / 1000.0 }
                }
            }
            if times.isEmpty { continue }
            let text = collapse(HTMLEntities.decode(stripWordTags(rest)))
            if isSpam(text) { continue }
            // Czasy słów mają sens tylko przy jednej etykiecie czasu (przy kilku linijka się powtarza).
            let runs = times.count == 1 ? parseRuns(rest) : []
            for t in times { entries.append((t, text, runs)) }
        }
        let ordered = entries.enumerated().sorted { a, b in
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
        }.map { $0.element }
        var lines: [LyricLine] = []
        for (i, e) in ordered.enumerated() {
            var runs = e.runs
            if !runs.isEmpty {
                // Ostatnie słowo bez znacznika końca trwa do następnej linijki (ale nie w nieskończoność).
                let nextLine = i + 1 < ordered.count ? ordered[i + 1].time : e.time + 4
                for k in runs.indices {
                    if runs[k].end < 0 {
                        let last = runs[k].start
                        runs[k].end = max(last + 0.4, min(nextLine, last + 4))
                    }
                    runs[k].start = max(0, runs[k].start - offset)
                    runs[k].end = max(runs[k].start, runs[k].end - offset)
                }
            }
            lines.append(LyricLine(id: i, time: max(0, e.time - offset), text: e.text, words: runs))
        }
        return lines
    }

    /// Wyciąga kawałki `<mm:ss.xx>tekst` z jednej linijki. Koniec kawałka = początek następnego znacznika
    /// (też pustego, który zamyka linijkę). Gdy za ostatnim kawałkiem nie ma znacznika, jego `end` to -1.
    static func parseRuns(_ s: String) -> [LyricRun] {
        guard s.contains("<") else { return [] }
        var marks: [(time: Double, from: String.Index, to: String.Index)] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                let inner = String(s[s.index(after: i)..<close])
                if let t = parseTimestamp(inner) {
                    let after = s.index(after: close)
                    marks.append((t, i, after))
                    i = after
                    continue
                }
            }
            i = s.index(after: i)
        }
        guard !marks.isEmpty else { return [] }
        var runs: [LyricRun] = []
        for (k, m) in marks.enumerated() {
            let textEnd = k + 1 < marks.count ? marks[k + 1].from : s.endIndex
            let raw = HTMLEntities.decode(String(s[m.to..<textEnd]))
            let nextStart = k + 1 < marks.count ? marks[k + 1].time : -1
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Pusty znacznik: kończy poprzednie słowo (spacja) i zamyka linijkę.
                if !raw.isEmpty, var last = runs.last, let ch = last.text.last, !ch.isWhitespace {
                    last.text += " "
                    runs[runs.count - 1] = last
                }
                continue
            }
            runs.append(LyricRun(start: m.time, end: nextStart, text: raw))
        }
        return runs
    }

    /// Reklamowe dopiski generatorów tekstu (np. "Generated by LRCGENERATOR") nie są częścią piosenki.
    static func isSpam(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("lrcgenerator") || t.contains("lrc generator") || t.contains("lrc-generator")
    }

    static func stripSpam(plain: String) -> String {
        plain.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !isSpam($0) }
            .joined(separator: "\n")
    }

    static func parseTimestamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let s = part.replacingOccurrences(of: ",", with: ".")
            guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(s) else { return nil }
            if i == parts.count - 1 { total += v } else { total = (total + v) * 60 }
        }
        return total
    }

    /// Index of the line that is active at `time` (-1 before the first line).
    static func activeIndex(in lines: [LyricLine], at time: Double) -> Int {
        guard let first = lines.first, time >= first.time else { return -1 }
        var lo = 0
        var hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func stripWordTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "<", let close = s[i...].firstIndex(of: ">") {
                let inner = String(s[s.index(after: i)..<close])
                if parseTimestamp(inner) != nil {
                    i = s.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    private static func collapse(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
