import Foundation

// =====================================================================================================
// Źródła tekstów z czasem słowo po słowie (port z BitChord) + parsery TTML / enhanced LRC / QRC.
//
// Apple Music TTML (lrc.red, BiniLyrics, BetterLyrics), LyricsPlus (sylaba po sylabie), Unison i SimpMusic.
// Każde źródło zwraca [LyricLine] z `words` (czasy słów/sylab). LyricsService zamienia wynik na tekst
// "enhanced LRC" (A2Writer), który trafia do tego samego cache i parsera co zwykłe teksty.
// =====================================================================================================

// MARK: - Źródła i ustawienia

enum LyricsSourceID: String, CaseIterable, Codable, Identifiable {
    case lrcRed, biniLyrics, betterLyrics, betterLyricsPortato, lyricsPlus, unison, simpMusic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lrcRed: return "lrc.red"
        case .biniLyrics: return "BiniLyrics"
        case .betterLyrics: return "BetterLyrics"
        case .betterLyricsPortato: return "BetterLyrics Portato"
        case .lyricsPlus: return "LyricsPlus"
        case .unison: return "Unison"
        case .simpMusic: return "SimpMusic"
        }
    }

    var detail: String {
        switch self {
        case .lrcRed: return "Czasy Apple Music, sylaba po sylabie"
        case .biniLyrics: return "Te same czasy Apple, dopasowane do nagrania"
        case .betterLyrics: return "Apple Music, słowo po słowie"
        case .betterLyricsPortato: return "Karaoke z QQ Music"
        case .lyricsPlus: return "Sylaba po sylabie, serwery społeczności"
        case .unison: return "Teksty dodane przez słuchaczy"
        case .simpMusic: return "Dopasowanie po filmie (może być zablokowane w Twoim kraju)"
        }
    }

    var enabledByDefault: Bool { self != .simpMusic }
}

/// Zwykłe źródła z czasem linijek (kolejność stała, można je tylko włączać i wyłączać).
enum LyricsLineSource {
    static let all: [(id: String, label: String, detail: String)] = [
        ("lrclib", "LRCLIB", "Całe linijki, zawsze dostępne"),
        ("netease", "NetEase", "Całe linijki, dużo azjatyckich piosenek"),
        ("kugou", "Kugou", "Całe linijki, mocne poza angielskim"),
        ("ovh", "lyrics.ovh", "Sam tekst bez czasów (ostatnia deska ratunku)")
    ]
}

/// Wybór źródeł (kolejność + włączone). Zapisany w UserDefaults, więc czytelny z każdego wątku.
struct LyricsSourcePrefs: Codable, Equatable {
    var order: [LyricsSourceID] = LyricsSourceID.allCases
    var disabled: Set<String> = Set(LyricsSourceID.allCases.filter { !$0.enabledByDefault }.map { $0.rawValue })

    private static let key = "lyricsSourcePrefs.v1"

    /// Wybór źródeł został usunięty z ustawień: zawsze używamy wszystkich, w domyślnej kolejności priorytetu.
    static var current: LyricsSourcePrefs {
        var p = LyricsSourcePrefs()
        p.disabled = []
        return p
    }

    static func load() -> LyricsSourcePrefs {
        guard let data = UserDefaults.standard.data(forKey: key),
              var p = try? JSONDecoder().decode(LyricsSourcePrefs.self, from: data) else { return LyricsSourcePrefs() }
        p.normalize()
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: LyricsSourcePrefs.key) }
    }

    /// Bez duplikatów, a nowe źródła z nowszych wersji dochodzą na koniec.
    mutating func normalize() {
        var seen = Set<LyricsSourceID>()
        var out: [LyricsSourceID] = []
        for s in order where seen.insert(s).inserted { out.append(s) }
        for s in LyricsSourceID.allCases where !seen.contains(s) {
            out.append(s)
            if !s.enabledByDefault { disabled.insert(s.rawValue) }
        }
        order = out
    }

    func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }

    var activeProviders: [LyricsSourceID] { order.filter { isEnabled($0.rawValue) } }

    mutating func setEnabled(_ id: String, _ on: Bool) {
        if on { disabled.remove(id) } else { disabled.insert(id) }
    }

    mutating func move(_ source: LyricsSourceID, by delta: Int) {
        guard let i = order.firstIndex(of: source) else { return }
        let j = i + delta
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
    }
}

/// Model dla ekranu Ustawień.
@MainActor
final class LyricsSourcePrefsStore: ObservableObject {
    @Published var prefs: LyricsSourcePrefs = LyricsSourcePrefs.load() {
        didSet { prefs.save() }
    }
}

// MARK: - Wynik źródła

struct ProviderResult {
    let source: LyricsSourceID
    let lines: [LyricLine]
    var isrc: String? = nil
    var duration: Double? = nil

    var hasWords: Bool { lines.contains { $0.isWordSynced } }
    var hasTiming: Bool { lines.contains { $0.time > 0.001 && !$0.text.isEmpty } }

    /// Odrzuca tekst, który wyraźnie jest innym nagraniem (kończy się długo po końcu filmu).
    func plausible(for videoDuration: Double) -> Bool {
        guard videoDuration > 0 else { return true }
        var last = 0.0
        for line in lines {
            last = max(last, line.time)
            for w in line.words { last = max(last, w.end) }
        }
        return last <= videoDuration + 20
    }
}

extension LyricsCandidate {
    /// Kandydat z wyniku źródła ze słowami: czasy słów trzymamy jako "enhanced LRC" w `syncedLyrics`.
    init(provider r: ProviderResult, title: String, artist: String) {
        let timed = r.hasTiming
        self.init(id: LyricsProviders.stableID("\(r.source.rawValue)|\(title)|\(artist)"),
                  trackName: title,
                  artistName: artist,
                  albumName: nil,
                  duration: r.duration,
                  instrumental: false,
                  plainLyrics: timed ? nil : r.lines.map { $0.text }.joined(separator: "\n"),
                  syncedLyrics: timed ? A2Writer.write(r.lines) : nil,
                  source: r.source.label,
                  wordSynced: r.hasWords)
    }
}

// MARK: - HTTP

enum LyricsHTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 7
        cfg.timeoutIntervalForResource = 12
        cfg.httpAdditionalHeaders = [
            "User-Agent": "MusicPlayer/1.18 (iOS music player)",
            "Accept": "application/json, text/plain, */*"
        ]
        return URLSession(configuration: cfg)
    }()

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Adres z parametrami; pominięte są parametry nil i puste.
    static func url(_ base: String, _ params: [(String, String?)]) -> URL? {
        let query = params.compactMap { item -> String? in
            guard let value = item.1, !value.isEmpty,
                  let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return "\(item.0)=\(encoded)"
        }.joined(separator: "&")
        return URL(string: query.isEmpty ? base : "\(base)?\(query)")
    }

    static func data(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func string(_ url: URL) async -> String? {
        guard let data = await data(url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func json(_ url: URL) async -> Any? {
        guard let data = await data(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

// MARK: - Czyszczenie tytułu (jak w BitChord: zdejmujemy tylko dopiski, nie wersje typu Remix/Live)

enum LyricsQuery {
    private static let credits: [NSRegularExpression] = [
        #"\s*[(\[]\s*(feat|ft|featuring|with)\b[^)\]]*[)\]]"#,
        #"\s+(feat|ft|featuring)\.?\s+.*$"#,
        #"\s*[(\[]\s*(official\s*)?(music\s*)?(video|audio|visuali[sz]er|lyrics?\s*video|lyrics?|m/?v|hd|hq|4k|full\s*song)\s*[)\]]"#,
        #"\s*[(\[]\s*official\s*[)\]]"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func title(_ raw: String) -> String {
        var name = raw
        for re in credits {
            name = re.stringByReplacingMatches(in: name, options: [], range: NSRange(name.startIndex..., in: name), withTemplate: " ")
        }
        let squeezed = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let trimmed = squeezed.trimmingCharacters(in: CharacterSet(charactersIn: " ,-–—"))
        return trimmed.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    static func artist(_ raw: String) -> String {
        var a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasSuffix(" - Topic") { a = String(a.dropLast(8)).trimmingCharacters(in: .whitespaces) }
        return a.isEmpty ? raw : a
    }
}

// MARK: - Pisanie / czytanie "enhanced LRC"

enum A2Writer {
    static func stamp(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        return String(format: "%02d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    /// `[mm:ss.xx]<mm:ss.xx>słowo <mm:ss.xx>słowo <mm:ss.xx>` - pusty znacznik na końcu zamyka ostatnie słowo,
    /// a pusty znacznik w środku (przy przerwie) mówi, kiedy słowo przed nim się skończyło.
    static func write(_ lines: [LyricLine]) -> String {
        lines.map { line -> String in
            var s = "[" + stamp(line.time) + "]"
            if line.words.isEmpty { return s + line.text }
            for (i, run) in line.words.enumerated() {
                s += "<" + stamp(run.start) + ">" + run.text
                let nextStart = i + 1 < line.words.count ? line.words[i + 1].start : nil
                if nextStart == nil || (nextStart ?? 0) - run.end > 0.05 {
                    s += "<" + stamp(max(run.end, run.start)) + ">"
                }
            }
            return s
        }.joined(separator: "\n")
    }
}

// MARK: - Przerwy instrumentalne

enum LyricGaps {
    static let minGap = 7.0

    /// Wstawia pustą linijkę ("• • •") tam, gdzie przerwa między śpiewanymi linijkami jest długa; też na początku.
    static func insert(_ items: [(line: LyricLine, end: Double)]) -> [LyricLine] {
        var out: [LyricLine] = []
        func add(_ time: Double, _ text: String, _ words: [LyricRun]) {
            out.append(LyricLine(id: out.count, time: time, text: text, words: words))
        }
        if let first = items.first, !first.line.text.isEmpty, first.line.time >= minGap { add(0, "", []) }
        for (i, item) in items.enumerated() {
            add(item.line.time, item.line.text, item.line.words)
            guard !item.line.text.isEmpty, i + 1 < items.count else { continue }
            let next = items[i + 1].line
            if !next.text.isEmpty, next.time - item.end >= minGap { add(item.end + 0.5, "", []) }
        }
        return out
    }
}

// MARK: - TTML (Apple Music)

/// Czyta TTML: `<p>` na linijkę, w nim `<span begin end>` na sylabę. Sylaby jednego słowa stoją obok siebie bez spacji,
/// więc granicę słowa wyznacza biały znak. Tłumaczenia i transkrypcje są pomijane, wokale w tle (`x-bg`) dopisane
/// w nawiasie na końcu linijki.
final class TTMLParser: NSObject, XMLParserDelegate {
    private enum Sink { case lead, bg, skip }
    private enum Piece {
        case text(String)
        case timed(String, Double, Double)
    }
    private struct Frame {
        var begin: Double?
        var end: Double?
        var sink: Sink
        var buffer = ""
        var hasTimedChild = false
    }
    private struct Row {
        var time: Double
        var end: Double
        var text: String
        var runs: [LyricRun]
    }

    private var stack: [Frame] = []
    private var inParagraph = false
    private var pBegin: Double?
    private var pEnd: Double?
    private var lead: [Piece] = []
    private var bg: [Piece] = []
    private var plain = ""
    private var rows: [Row] = []

    static func parse(_ ttml: String) -> [LyricLine] {
        guard let data = ttml.data(using: .utf8) else { return [] }
        let delegate = TTMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()   // przy błędzie w środku dokumentu zostają linijki przeczytane do tej pory
        return delegate.finish()
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch TTMLParser.local(elementName) {
        case "p":
            inParagraph = true
            stack = []
            lead = []
            bg = []
            plain = ""
            pBegin = TTMLParser.time(attributeDict["begin"])
            pEnd = TTMLParser.time(attributeDict["end"])
        case "span":
            guard inParagraph else { return }
            let role = (attributeDict["ttm:role"] ?? attributeDict["role"] ?? "").lowercased()
            let parentSink = stack.last?.sink ?? .lead
            var sink = parentSink
            if role == "x-translation" || role == "x-roman" {
                sink = .skip
            } else if role == "x-bg", parentSink != .skip {
                sink = .bg
            }
            // Tekst rodzica sprzed tego spana jest już pewny (rodzic jest kontenerem).
            if let idx = stack.indices.last, !stack[idx].buffer.isEmpty {
                emit(.text(stack[idx].buffer), to: stack[idx].sink)
                stack[idx].buffer = ""
            }
            let begin = TTMLParser.time(attributeDict["begin"])
            let end = TTMLParser.time(attributeDict["end"])
            if begin != nil {
                for i in stack.indices { stack[i].hasTimedChild = true }
            }
            stack.append(Frame(begin: begin, end: end, sink: sink))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inParagraph else { return }
        if let idx = stack.indices.last {
            guard stack[idx].sink != .skip else { return }
            stack[idx].buffer += string
            plain += string
        } else {
            lead.append(.text(string))
            plain += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch TTMLParser.local(elementName) {
        case "span":
            guard inParagraph, let f = stack.popLast() else { return }
            if f.sink == .skip { return }
            if let b = f.begin, let e = f.end, !f.hasTimedChild {
                emit(.timed(f.buffer, b, e), to: f.sink)
            } else if !f.buffer.isEmpty {
                emit(.text(f.buffer), to: f.sink)
            }
        case "p":
            guard inParagraph else { return }
            finishParagraph()
        default:
            break
        }
    }

    // MARK: Budowanie linijek

    private func emit(_ piece: Piece, to sink: Sink) {
        switch sink {
        case .lead: lead.append(piece)
        case .bg: bg.append(piece)
        case .skip: break
        }
    }

    private func finishParagraph() {
        defer {
            inParagraph = false
            stack = []
            lead = []
            bg = []
            plain = ""
        }
        var runs = TTMLParser.merge(lead)
        var backing = TTMLParser.merge(bg)

        if runs.isEmpty && backing.isEmpty {
            // Linijka bez czasów słów: sam znacznik czasu i tekst.
            let text = TTMLParser.collapse(plain)
            guard let begin = pBegin, !text.isEmpty else { return }
            let end = (pEnd ?? begin + 4) > begin ? (pEnd ?? begin + 4) : begin + 4
            rows.append(Row(time: begin, end: end, text: text, runs: []))
            return
        }

        if !backing.isEmpty {
            if !runs.isEmpty { TTMLParser.closeWord(&runs) }
            backing[0].text = "(" + backing[0].text
            let lastIndex = backing.count - 1
            backing[lastIndex].text = backing[lastIndex].text.trimmingCharacters(in: .whitespaces) + ")"
            runs += backing
        }
        let first = runs.map { $0.start }.min() ?? 0
        let time = min(pBegin ?? first, first)
        let end = max(runs.map { $0.end }.max() ?? time, pEnd ?? 0)
        let text = TTMLParser.collapse(runs.map { $0.text }.joined())
        guard !text.isEmpty else { return }
        rows.append(Row(time: time, end: end, text: text, runs: runs))
    }

    private func finish() -> [LyricLine] {
        let sorted = rows.enumerated().sorted { a, b in
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
        }.map { $0.element }
        let items = sorted.map { row -> (line: LyricLine, end: Double) in
            (LyricLine(id: 0, time: row.time, text: row.text, words: row.runs), row.end)
        }
        return LyricGaps.insert(items)
    }

    // MARK: Pomocnicze

    private static func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Kończy ostatnie słowo spacją (jeśli jeszcze jej nie ma).
    private static func closeWord(_ runs: inout [LyricRun]) {
        guard var last = runs.last, let ch = last.text.last, !ch.isWhitespace else { return }
        last.text += " "
        runs[runs.count - 1] = last
    }

    /// Składa kawałki w sylaby/słowa: biały znak (też między spanami) kończy słowo, tekst bez czasu
    /// (interpunkcja) dokleja się do poprzedniego kawałka.
    private static func merge(_ pieces: [Piece]) -> [LyricRun] {
        var runs: [LyricRun] = []
        for piece in pieces {
            switch piece {
            case .text(let t):
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !t.isEmpty { closeWord(&runs) }
                    continue
                }
                guard !runs.isEmpty else { continue }
                if t.first?.isWhitespace == true { closeWord(&runs) }
                runs[runs.count - 1].text += t.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.last?.isWhitespace == true { closeWord(&runs) }
            case .timed(let t, let begin, let end):
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !t.isEmpty { closeWord(&runs) }
                    continue
                }
                if t.first?.isWhitespace == true { closeWord(&runs) }
                var core = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.last?.isWhitespace == true { core += " " }
                runs.append(LyricRun(start: begin, end: max(begin, end), text: core))
            }
        }
        return runs
    }

    /// Czas TTML w sekundach: `27.395`, `1:05.20`, `1:02:03.4`, `12s`, `500ms`.
    static func time(_ value: String?) -> Double? {
        guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasSuffix("ms") {
            guard let v = Double(raw.dropLast(2)) else { return nil }
            return v / 1000
        }
        if raw.hasSuffix("s") { raw.removeLast() }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }
}

// MARK: - QRC / YRC (karaoke: `[start,czas](start,czas)słowo`)

enum KaraokeLRC {
    private static let lineRe = try? NSRegularExpression(pattern: #"^\[(\d{1,8}),(\d{1,8})\](.*)$"#)
    private static let prefixWord = try? NSRegularExpression(pattern: #"\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)([^()]*)"#)
    private static let suffixWord = try? NSRegularExpression(pattern: #"([^()]*)\((\d{1,8}),(\d{1,8})(?:,\d{1,8})?\)"#)
    private static let wordTime = try? NSRegularExpression(pattern: #"\(\d{1,8},\d{1,8}(?:,\d{1,8})?\)"#)
    private static let content = try? NSRegularExpression(pattern: #"LyricContent\s*=\s*"([^"]*)""#, options: [.caseInsensitive])

    private static func groups(_ re: NSRegularExpression?, _ s: String) -> [[String]] {
        guard let re = re else { return [] }
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func lyricContent(_ raw: String) -> String {
        if let g = groups(content, raw).first, g.count > 1 {
            return g[1].replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        return raw
    }

    static func looksLike(_ raw: String) -> Bool {
        for line in lyricContent(raw).components(separatedBy: "\n") {
            guard let g = groups(lineRe, line.trimmingCharacters(in: .whitespaces)).first, g.count > 3 else { continue }
            if !groups(prefixWord, g[3]).isEmpty || !groups(suffixWord, g[3]).isEmpty { return true }
        }
        return false
    }

    static func parse(_ raw: String) -> [LyricLine] {
        var items: [(line: LyricLine, end: Double)] = []
        for source in lyricContent(raw).components(separatedBy: "\n") {
            guard let g = groups(lineRe, source.trimmingCharacters(in: .whitespaces)).first, g.count > 3,
                  let lineStart = Double(g[1]), let lineDuration = Double(g[2]) else { continue }
            let body = g[3]
            let prefixed: [LyricRun] = groups(prefixWord, body).compactMap { w -> LyricRun? in
                guard w.count > 3, let s = Double(w[1]), let d = Double(w[2]) else { return nil }
                return LyricRun(start: s / 1000, end: (s + d) / 1000, text: HTMLEntities.decode(w[3]))
            }
            let suffixed: [LyricRun] = groups(suffixWord, body).compactMap { w -> LyricRun? in
                guard w.count > 3, let s = Double(w[2]), let d = Double(w[3]) else { return nil }
                return LyricRun(start: s / 1000, end: (s + d) / 1000, text: HTMLEntities.decode(w[1]))
            }
            let prefixedLength = prefixed.reduce(0) { $0 + $1.text.count }
            let suffixedLength = suffixed.reduce(0) { $0 + $1.text.count }
            var runs = prefixedLength >= suffixedLength ? prefixed : suffixed
            runs = runs.filter { !$0.text.isEmpty }
            guard !runs.isEmpty else { continue }
            // Brak spacji w całej linijce = autor jej nie zapisał; każdy kawałek jest wtedy osobnym słowem
            // (pismo bez spacji - chiński, japoński, tajski - zostaje sklejone).
            if !runs.contains(where: { $0.text.contains(where: { $0.isWhitespace }) }),
               !runs.allSatisfy({ $0.text.allSatisfy(KaraokeLRC.isUnspacedScript) }) {
                for k in 0..<(runs.count - 1) { runs[k].text += " " }
            }
            let text = HTMLEntities.decode(wordTime?.stringByReplacingMatches(
                in: body, options: [], range: NSRange(body.startIndex..., in: body), withTemplate: "") ?? body)
            let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !clean.isEmpty else { continue }
            let time = min(lineStart / 1000, runs.first?.start ?? lineStart / 1000)
            let end = max((lineStart + lineDuration) / 1000, runs.last?.end ?? 0)
            items.append((LyricLine(id: 0, time: time, text: clean, words: runs), end))
        }
        items.sort { $0.line.time < $1.line.time }
        return LyricGaps.insert(items)
    }

    /// Pismo zapisywane bez spacji między słowami.
    fileprivate static func isUnspacedScript(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(v) || (0x3040...0x30FF).contains(v) || (0x3000...0x303F).contains(v)
            || (0xFF00...0xFFEF).contains(v) || (0x0E00...0x0E7F).contains(v)
            || ch.isPunctuation || ch.isWhitespace
    }
}

// MARK: - Odpowiedzi w różnych "kopertach" (JSON z TTML / LRC w środku)

enum ProviderParse {
    private static let contentKeys = [
        "ttml", "ttmlContent", "lyrics", "lrc", "content", "text",
        "plainLyrics", "syncedLyrics", "line", "lines", "lyric",
        "data", "result", "response"
    ]

    static func parse(_ raw: String) -> [LyricLine]? {
        guard var content = unwrap(raw) else { return nil }
        if content.range(of: "&lt;tt", options: .caseInsensitive) != nil {
            content = content.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
        }
        let lines: [LyricLine]
        if content.range(of: #"<tt(\s|>)"#, options: [.regularExpression, .caseInsensitive]) != nil
            || content.range(of: "http://www.w3.org/ns/ttml", options: .caseInsensitive) != nil {
            lines = TTMLParser.parse(content)
        } else if KaraokeLRC.looksLike(content) {
            lines = KaraokeLRC.parse(content)
        } else if content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            lines = []
        } else {
            let lrc = LRCParser.parse(content)
            lines = lrc.isEmpty ? plain(content) : lrc
        }
        return lines.contains(where: { !$0.text.isEmpty }) ? lines : nil
    }

    /// Sam tekst, bez czasów: każda linijka dostaje czas 0 (aplikacja pokaże go jako zwykły tekst).
    static func plain(_ content: String) -> [LyricLine] {
        let lower = content.lowercased()
        if lower.contains("lyrics not found") || lower.contains("lyric not found") || lower.contains("lyrics unavailable") { return [] }
        var out: [LyricLine] = []
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]"), line.contains(":") { continue }   // [ar:...] itp.
            out.append(LyricLine(id: out.count, time: 0, text: line))
        }
        return out
    }

    static func unwrap(_ raw: String) -> String? {
        var value = raw.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            var rows = value.components(separatedBy: "\n")
            rows.removeFirst()
            if rows.last?.trimmingCharacters(in: .whitespaces) == "```" { rows.removeLast() }
            value = rows.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.isEmpty { return nil }
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return value }
        let extracted = extract(json)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (extracted?.isEmpty ?? true) ? nil : extracted
    }

    private static func extract(_ any: Any) -> String? {
        if any is NSNull { return nil }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = t.first, first == "{" || first == "[",
               let data = t.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data, options: []) {
                return extract(nested)
            }
            return t
        }
        if let arr = any as? [Any] {
            let parts = arr.compactMap { extract($0) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if let obj = any as? [String: Any] {
            if (obj["isError"] as? Bool) == true || (obj["ok"] as? Bool) == false { return nil }
            if let err = obj["error"], !(err is NSNull) {
                if let b = err as? Bool { if b { return nil } }
                else if let s = err as? String { if !s.isEmpty && s != "false" { return nil } }
                else { return nil }
            }
            for key in contentKeys {
                if let v = obj[key], let r = extract(v) { return r }
            }
            if let meta = obj["metadata"], let r = extract(meta) { return r }
            if let words = obj["words"], let r = extract(words) { return r }
            return nil
        }
        return nil
    }
}

// MARK: - Źródła

enum LyricsProviders {
    struct Query {
        let videoId: String
        let title: String
        let artist: String
        let album: String?
        let seconds: Int
    }

    struct BiniHit {
        let isrc: String?
        let lyricsUrl: String?
        let duration: Double?
    }

    /// Stały (między uruchomieniami) numer z napisu - `hashValue` w Swifcie jest losowy.
    static func stableID(_ s: String) -> Int {
        var h: UInt64 = 5381
        for u in s.unicodeScalars { h = (h &* 33) &+ UInt64(u.value) }
        return Int(h % 1_000_000_000)
    }

    // MARK: Wspólne wywołanie

    /// Pyta włączone źródła naraz; odpowiedzi bierze w kolejności ustawionej przez użytkownika. `all == false`:
    /// kończy, gdy źródło o najwyższym priorytecie z czasami słów jest znane (nie czeka na wolniejsze za nim).
    /// `all == true`: czeka na wszystkie (do ok. 9 s) - do wyboru wersji.
    static func lookup(videoId: String, title: String, artist: String, duration: Double,
                       prefs: LyricsSourcePrefs, all: Bool) async -> [ProviderResult] {
        let sequence = prefs.activeProviders
        guard !sequence.isEmpty else { return [] }
        let q = Query(videoId: videoId,
                      title: LyricsQuery.title(title),
                      artist: LyricsQuery.artist(artist),
                      album: nil,
                      seconds: duration > 0 ? Int(duration.rounded()) : 0)

        // Najpierw: które to nagranie (ISRC). Krótko, bo bez tego wszystko i tak działa po nazwie.
        var hit: BiniHit? = nil
        if sequence.contains(.biniLyrics) {
            hit = await withTimeout(2.5) { await biniIdentify(q, isrc: nil) }
        }
        let isrc = hit?.isrc
        let knownHit = hit

        func run(_ source: LyricsSourceID) async -> ProviderResult? {
            var lines: [LyricLine]? = nil
            switch source {
            case .lrcRed:
                lines = await lrcRed(q, isrc: isrc)
            case .biniLyrics:
                if let h = knownHit {
                    lines = await biniLyrics(h)
                } else if let h = await biniIdentify(q, isrc: nil) {
                    lines = await biniLyrics(h)
                }
            case .betterLyrics:
                lines = await betterLyrics(q, portato: false)
            case .betterLyricsPortato:
                lines = await betterLyrics(q, portato: true)
            case .lyricsPlus:
                lines = await lyricsPlus(q, isrc: isrc)
            case .unison:
                lines = await unison(q)
            case .simpMusic:
                lines = await simpMusic(q)
            }
            guard let found = lines, found.contains(where: { !$0.text.isEmpty }) else { return nil }
            return ProviderResult(source: source, lines: found, isrc: isrc, duration: nil)
        }

        return await withTaskGroup(of: (Int, ProviderResult?).self, returning: [ProviderResult].self) { group in
            for (i, source) in sequence.enumerated() {
                group.addTask { (i, await run(source)) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                return (-1, nil)
            }
            var results = [ProviderResult?](repeating: nil, count: sequence.count)
            var finished = [Bool](repeating: false, count: sequence.count)
            var winner: ProviderResult? = nil
            for await (i, result) in group {
                if i < 0 { break }
                finished[i] = true
                results[i] = result
                if all { continue }
                var k = 0
                while k < finished.count && finished[k] {
                    if let r = results[k], r.hasWords { winner = r; break }
                    k += 1
                }
                if winner != nil { break }
            }
            group.cancelAll()
            if let w = winner { return [w] }
            return results.compactMap { $0 }
        }
    }

    private static func withTimeout<T>(_ seconds: Double, _ op: @escaping () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self, returning: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first: T?? = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    // MARK: BetterLyrics (+ Portato)

    static func betterLyrics(_ q: Query, portato: Bool) async -> [LyricLine]? {
        let base = portato ? "https://lyrics-api.boidu.dev/qq/getLyrics" : "https://lyrics-api.boidu.dev/getLyrics"
        guard let url = LyricsHTTP.url(base, [("s", q.title), ("a", q.artist),
                                              ("d", q.seconds > 0 ? String(q.seconds) : nil), ("al", q.album)]),
              let body = await LyricsHTTP.string(url) else { return nil }
        return ProviderParse.parse(body)
    }

    // MARK: BiniLyrics + lrc.red (Apple TTML po ISRC)

    static func biniIdentify(_ q: Query, isrc: String?) async -> BiniHit? {
        let params: [(String, String?)]
        if let isrc = isrc, !isrc.isEmpty {
            params = [("isrc", isrc)]
        } else {
            params = [("track", q.title), ("artist", q.artist), ("album", q.album),
                      ("duration", q.seconds > 0 ? String(q.seconds) : nil)]
        }
        guard let url = LyricsHTTP.url("https://lyrics-api.binimum.org/", params),
              let root = await LyricsHTTP.json(url) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let first = results.first else { return nil }
        return BiniHit(isrc: first["isrc"] as? String,
                       lyricsUrl: first["lyricsUrl"] as? String,
                       duration: (first["duration"] as? NSNumber)?.doubleValue)
    }

    static func biniLyrics(_ hit: BiniHit) async -> [LyricLine]? {
        guard let s = hit.lyricsUrl, !s.isEmpty, let url = URL(string: s),
              let ttml = await LyricsHTTP.string(url) else { return nil }
        let lines = TTMLParser.parse(ttml)
        return lines.isEmpty ? nil : lines
    }

    private static let isrcRegex = try? NSRegularExpression(pattern: #"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#)

    private static func lrcRedURL(_ isrc: String) -> URL? {
        let code = isrc.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let re = isrcRegex,
              re.firstMatch(in: code, options: [], range: NSRange(code.startIndex..., in: code)) != nil else { return nil }
        return URL(string: "https://lrc.red/s/\(code).ttml")
    }

    static func lrcRed(_ q: Query, isrc: String?) async -> [LyricLine]? {
        var tried: String? = nil
        if let isrc = isrc, let url = lrcRedURL(isrc) {
            tried = isrc.uppercased()
            if let ttml = await LyricsHTTP.string(url) {
                let lines = TTMLParser.parse(ttml)
                if !lines.isEmpty { return lines }
            }
        }
        // Bez ISRC (albo gdy go tam nie ma): wyszukiwarka lrc.red i ostrożne dopasowanie.
        guard let search = LyricsHTTP.url("https://lrc.red/search.json", [("q", "\(q.title) \(q.artist)")]),
              let root = await LyricsHTTP.json(search) as? [String: Any],
              let hits = root["hits"] as? [[String: Any]],
              let best = LrcRedMatcher.best(hits, title: q.title, artist: q.artist, seconds: q.seconds),
              let code = best["isrc"] as? String, code.uppercased() != tried,
              let url = lrcRedURL(code),
              let ttml = await LyricsHTTP.string(url) else { return nil }
        let lines = TTMLParser.parse(ttml)
        return lines.isEmpty ? nil : lines
    }

    // MARK: LyricsPlus (sylaba po sylabie, kilka lustrzanych serwerów naraz)

    private static let lyricsPlusMirrors = [
        "https://lyricsplus.prjktla.my.id",
        "https://lyricsplus.atomix.one",
        "https://lyricsplus.binimum.org",
        "https://lyricsplus.prjktla.workers.dev",
        "https://lyricsplus-seven.vercel.app",
        "https://lyrics-plus-backend.vercel.app"
    ]

    static func lyricsPlus(_ q: Query, isrc: String?) async -> [LyricLine]? {
        await withTaskGroup(of: [LyricLine]?.self, returning: [LyricLine]?.self) { group in
            for host in lyricsPlusMirrors {
                group.addTask { await fetchLyricsPlus(host: host, q, isrc: isrc) }
            }
            for await result in group {
                if let lines = result, !lines.isEmpty {
                    group.cancelAll()
                    return lines
                }
            }
            return nil
        }
    }

    private static func fetchLyricsPlus(host: String, _ q: Query, isrc: String?) async -> [LyricLine]? {
        guard let url = LyricsHTTP.url("\(host)/v2/lyrics/get", [
            ("title", q.title), ("artist", q.artist),
            ("duration", q.seconds > 0 ? String(q.seconds) : nil),
            ("album", q.album), ("isrc", isrc)
        ]),
              let root = await LyricsHTTP.json(url) as? [String: Any],
              let rows = root["lyrics"] as? [[String: Any]] else { return nil }

        func seconds(_ any: Any?) -> Double? { (any as? NSNumber).map { $0.doubleValue / 1000 } }

        var items: [(line: LyricLine, end: Double)] = []
        for row in rows {
            guard let start = seconds(row["time"]) else { continue }
            let syllables = (row["syllabus"] as? [[String: Any]]) ?? []
            let runs: [LyricRun] = syllables.compactMap { syl -> LyricRun? in
                guard let text = syl["text"] as? String, let t = seconds(syl["time"]) else { return nil }
                return LyricRun(start: t, end: t + (seconds(syl["duration"]) ?? 0), text: text)
            }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !runs.isEmpty {
                let text = runs.map { $0.text }.joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let time = min(start, runs[0].start)
                let end = max(runs.map { $0.end }.max() ?? time, start + (seconds(row["duration"]) ?? 0))
                items.append((LyricLine(id: 0, time: time, text: text, words: runs), end))
            } else if let text = (row["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                items.append((LyricLine(id: 0, time: start, text: text), start + (seconds(row["duration"]) ?? 4)))
            }
        }
        items.sort { $0.line.time < $1.line.time }
        return items.isEmpty ? nil : LyricGaps.insert(items)
    }

    // MARK: Unison (teksty od słuchaczy)

    static func unison(_ q: Query) async -> [LyricLine]? {
        guard let url = LyricsHTTP.url("https://unison.boidu.dev/lyrics", [
            ("song", q.title), ("artist", q.artist), ("album", q.album),
            ("duration", q.seconds > 0 ? String(q.seconds) : nil)
        ]),
              let root = await LyricsHTTP.json(url) as? [String: Any],
              (root["success"] as? Bool) == true,
              let data = root["data"] as? [String: Any],
              let text = data["lyrics"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let format = (data["format"] as? String)?.lowercased()
        let syncType = (data["syncType"] as? String)?.lowercased()
        let lines: [LyricLine]
        if format == "ttml" {
            lines = TTMLParser.parse(text)
        } else if syncType == "plain" {
            lines = ProviderParse.plain(text)
        } else {
            lines = LRCParser.parse(text)
        }
        return lines.isEmpty ? nil : lines
    }

    // MARK: SimpMusic (po id filmu)

    static func simpMusic(_ q: Query) async -> [LyricLine]? {
        guard YouTubeURL.isVideoID(q.videoId),
              let url = URL(string: "https://api-lyrics.simpmusic.org/v1/\(q.videoId)"),
              let root = await LyricsHTTP.json(url) as? [String: Any],
              (root["success"] as? Bool) == true,
              let tracks = root["data"] as? [[String: Any]] else { return nil }
        let candidates = tracks.filter { t in
            guard q.seconds > 0, let d = (t["duration"] as? NSNumber)?.intValue else { return true }
            return abs(d - q.seconds) <= 10
        }
        let best = candidates.min { a, b in
            let da = abs(((a["duration"] as? NSNumber)?.intValue ?? 0) - q.seconds)
            let db = abs(((b["duration"] as? NSNumber)?.intValue ?? 0) - q.seconds)
            return da < db
        }
        guard let track = best else { return nil }
        if let rich = track["richSyncLyrics"] as? String, !rich.isEmpty {
            let lines = LRCParser.parse(rich)
            if lines.contains(where: { $0.isWordSynced }) { return lines }
        }
        if let synced = track["syncedLyrics"] as? String, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return lines }
        }
        return nil
    }
}

// MARK: - Dopasowanie trafienia z lrc.red (wymagania zamiast punktów: lepszy brak niż zły tekst)

enum LrcRedMatcher {
    private static let versionWords: Set<String> = [
        "live", "remix", "remixed", "mix", "acoustic", "unplugged", "instrumental",
        "karaoke", "cappella", "acapella", "demo", "edit", "version", "cover",
        "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "extended"
    ]
    private static let bracketed = try? NSRegularExpression(pattern: #"[(\[][^)\]]*[)\]]"#)

    private static func normalized(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }

    private static func stripBrackets(_ s: String) -> String {
        guard let re = bracketed else { return s }
        return re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// "Song (Live) - 2011 Remaster" -> "song".
    private static func core(_ title: String) -> String {
        let base = stripBrackets(title).components(separatedBy: " - ").first ?? title
        let n = normalized(base)
        return n.isEmpty ? normalized(title) : n
    }

    /// Słowa w nawiasach i po " - ", które mówią, że to inne nagranie (live, remix…).
    private static func versions(_ title: String) -> Set<String> {
        var extras = ""
        if let re = bracketed {
            let ns = title as NSString
            for m in re.matches(in: title, options: [], range: NSRange(location: 0, length: ns.length)) {
                extras += " " + ns.substring(with: m.range)
            }
        }
        if let r = title.range(of: " - ") { extras += " " + title[r.upperBound...] }
        return Set(normalized(extras).split(separator: " ").map(String.init).filter { versionWords.contains($0) })
    }

    private static func artists(_ artist: String) -> Set<String> {
        var s = artist.lowercased()
        for sep in [" and ", " x ", " with ", " feat. ", " feat ", " ft. ", " ft ", "&", ";", "/"] {
            s = s.replacingOccurrences(of: sep, with: ",")
        }
        return Set(s.split(separator: ",").map { normalized(String($0)) }.filter { !$0.isEmpty })
    }

    static func best(_ hits: [[String: Any]], title: String, artist: String, seconds: Int) -> [String: Any]? {
        let wantedTitle = core(title)
        let wantedVersion = versions(title)
        let wantedArtists = artists(artist)

        func distance(_ hit: [String: Any]) -> Double {
            guard seconds > 0, let d = (hit["duration"] as? NSNumber)?.doubleValue else { return 0 }
            return abs(d - Double(seconds))
        }

        let passing = hits.filter { hit in
            guard let name = hit["title"] as? String, hit["isrc"] is String else { return false }
            if core(name) != wantedTitle || versions(name) != wantedVersion { return false }
            if !wantedArtists.isEmpty {
                let theirs = artists((hit["artist"] as? String) ?? "")
                if theirs.isDisjoint(with: wantedArtists) { return false }
            }
            return distance(hit) <= 3.0
        }
        return passing.min { distance($0) < distance($1) }
    }
}
