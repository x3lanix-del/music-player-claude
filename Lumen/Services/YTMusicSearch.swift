import Foundation

/// Wyszukiwanie w YouTube Music (port z BitChord): bez klucza API i bez dziennego limitu, a wyniki mają czysty
/// tytuł i wykonawcę (dzięki temu teksty trafiają dużo częściej niż przy tytułach typu "Artist - Song (Official Video)").
enum YTMusicSearch {
    enum Filter {
        case songs, videos
        var params: String {
            switch self {
            case .songs: return "EgWKAQIIAWoKEAkQChAFEAMQBA=="
            case .videos: return "EgWKAQIQAWoKEAkQChAFEAMQBA=="
            }
        }
    }

    private static let base = "https://music.youtube.com/youtubei/v1"
    private static let clientVersion = "1.20250101.01.00"
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    // MARK: Publiczne

    /// Wynik z okładką (do porównywania z okładką ze Spotify).
    struct Hit { let track: Track; let thumb: URL? }

    /// Tylko piosenki YouTube Music, w kolejności trafności (najpopularniejsze/najtrafniejsze pierwsze), z okładkami.
    static func searchSongs(_ query: String) async throws -> [Hit] {
        let root = try await post("search", ["query": query, "params": Filter.songs.params])
        return parseHits(root)
    }

    /// Piosenki z YouTube Music, a po nich (bez powtórek) teledyski/filmy.
    static func search(_ query: String) async throws -> [Track] {
        async let songs: [Track] = fetch(query, filter: .songs)
        async let videos: [Track]? = try? await fetch(query, filter: .videos)
        let first = try await songs
        let second: [Track] = await videos ?? []
        var seen = Set(first.map { $0.id })
        var out = first
        for t in second where seen.insert(t.id).inserted { out.append(t) }
        return out
    }

    /// Podpowiedzi (jak pole wyszukiwania w YouTube Music) - tylko teksty zapytań.
    static func suggestions(_ input: String) async -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let root = try? await post("music/get_search_suggestions", ["input": trimmed]) else { return [] }
        var out: [String] = []
        for renderer in collect(root, key: "searchSuggestionRenderer") {
            var text: String? = nil
            if let nav = renderer["navigationEndpoint"] as? [String: Any],
               let search = nav["searchEndpoint"] as? [String: Any],
               let q = search["query"] as? String, !q.isEmpty {
                text = q
            } else if let t = renderer["suggestion"] as? [String: Any] {
                text = runs(t)
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        return Array(out.prefix(6))
    }

    // MARK: Zapytania

    private static func fetch(_ query: String, filter: Filter) async throws -> [Track] {
        let root = try await post("search", ["query": query, "params": filter.params])
        return parseTracks(root)
    }

    private static func post(_ endpoint: String, _ extras: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(base)/\(endpoint)?prettyPrint=false&hl=pl") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
        req.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("pl-PL,pl;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        var body: [String: Any] = [
            "context": [
                "client": ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "pl", "gl": "PL"],
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true]
            ]
        ]
        for (k, v) in extras { body[k] = v }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }

    // MARK: Parsowanie

    private static let typeWords: Set<String> = [
        "song", "video", "album", "single", "ep", "artist", "playlist", "piosenka", "teledysk", "film", "utwór"
    ]
    private static let durationRegex = try? NSRegularExpression(pattern: #"^\d{1,2}(:\d{2}){1,2}$"#)
    private static let tallyRegex = try? NSRegularExpression(
        pattern: #"^[\d.,\s]+[KMBkmb]?\s*(views|plays|wyświetle\w*|odtworze\w*|subscribers|subskrypcj\w*|mln|tys\.?)"#,
        options: [.caseInsensitive])

    private static func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re = re else { return false }
        return re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func parseTracks(_ root: [String: Any]) -> [Track] { parseHits(root).map { $0.track } }

    private static func thumbnail(_ row: [String: Any]) -> URL? {
        var node: Any? = row
        for key in ["thumbnail", "musicThumbnailRenderer", "thumbnail"] { node = (node as? [String: Any])?[key] }
        guard let list = (node as? [String: Any])?["thumbnails"] as? [[String: Any]],
              let raw = list.last?["url"] as? String else { return nil }
        return URL(string: raw)
    }

    private static func parseHits(_ root: [String: Any]) -> [Hit] {
        var out: [Hit] = []
        var seen = Set<String>()
        for row in collect(root, key: "musicResponsiveListItemRenderer") {
            // Albumy, artyści i playlisty prowadzą do strony (browseEndpoint), piosenki nie.
            if let nav = row["navigationEndpoint"] as? [String: Any], nav["browseEndpoint"] != nil { continue }
            guard let videoId = extractVideoID(row), YouTubeURL.isVideoID(videoId), seen.insert(videoId).inserted else { continue }

            let columns = row["flexColumns"] as? [[String: Any]] ?? []
            func columnRuns(_ i: Int) -> [[String: Any]] {
                guard columns.indices.contains(i),
                      let renderer = columns[i]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                      let text = renderer["text"] as? [String: Any] else { return [] }
                return text["runs"] as? [[String: Any]] ?? []
            }
            let title = columnRuns(0).compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { continue }

            let subtitle = columnRuns(1).compactMap { $0["text"] as? String }.joined()
            let parts = subtitle.components(separatedBy: " • ")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let artist = parts.first {
                !matches(durationRegex, $0) && !typeWords.contains($0.lowercased()) && !matches(tallyRegex, $0)
            } ?? ""
            var seconds = 0.0
            if let d = parts.last, matches(durationRegex, d) { seconds = parseDuration(d) }
            if seconds == 0, let fixed = row["fixedColumns"] as? [[String: Any]] {
                for col in fixed {
                    if let r = col["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any],
                       let t = r["text"] as? [String: Any] {
                        let s = runs(t)
                        if matches(durationRegex, s) { seconds = parseDuration(s); break }
                    }
                }
            }
            out.append(Hit(track: Track(id: videoId, title: title, artist: TitleCleaner.cleanChannel(artist), duration: seconds),
                           thumb: thumbnail(row)))
        }
        return out
    }

    private static func extractVideoID(_ row: [String: Any]) -> String? {
        if let item = row["playlistItemData"] as? [String: Any], let id = item["videoId"] as? String { return id }
        let path: [String] = ["overlay", "musicItemThumbnailOverlayRenderer", "content", "musicPlayButtonRenderer",
                              "playNavigationEndpoint", "watchEndpoint"]
        var node: Any? = row
        for key in path { node = (node as? [String: Any])?[key] }
        return (node as? [String: Any])?["videoId"] as? String
    }

    private static func parseDuration(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func runs(_ text: [String: Any]) -> String {
        if let simple = text["simpleText"] as? String { return simple }
        return (text["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    /// Wszystkie obiekty o podanej nazwie w całej odpowiedzi (jak `collectRenderers` w BitChord).
    private static func collect(_ node: Any, key: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let dict = node as? [String: Any] {
            for (k, v) in dict {
                if k == key, let found = v as? [String: Any] { out.append(found) }
                out += collect(v, key: key)
            }
        } else if let array = node as? [Any] {
            for v in array { out += collect(v, key: key) }
        }
        return out
    }
}
