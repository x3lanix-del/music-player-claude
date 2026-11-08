import Foundation

enum ExternalImportError: LocalizedError {
    case unsupported, network, empty
    var errorDescription: String? {
        switch self {
        case .unsupported: return "Nieobsługiwany link. Obsługuję YouTube, YouTube Music, Spotify (playlisty, albumy, piosenki) i Apple Music."
        case .network: return "Nie udało się pobrać playlisty z tego serwisu. Sprawdź, czy jest publiczna."
        case .empty: return "Nie znaleziono piosenek w tej playliście."
        }
    }
}

/// Import playlist z Spotify i Apple Music (publiczne linki). Piosenki są dopasowywane do YouTube.
enum ExternalImport {
    struct Item { let title: String; let artist: String; let duration: Double; var cover: URL? = nil }
    struct Result { let name: String; let tracks: [Track]; let skipped: Int }

    private static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func detect(_ text: String) -> Bool {
        let s = text.lowercased()
        return s.contains("open.spotify.com/") || s.contains("music.apple.com/")
    }

    private static func firstURL(in text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "https?://[^\\s]+", options: .regularExpression) { return URL(string: String(t[r])) }
        return nil
    }

    static func fetch(_ text: String, api: YouTubeAPI, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Result {
        guard let url = firstURL(in: text), let host = url.host?.lowercased() else { throw ExternalImportError.unsupported }
        var name = ""
        var items: [Item] = []
        if host.hasSuffix("spotify.com") {
            (name, items) = try await spotify(url)
        } else if host.hasSuffix("music.apple.com") {
            (name, items) = try await appleMusic(url)
        } else {
            throw ExternalImportError.unsupported
        }
        guard !items.isEmpty else { throw ExternalImportError.empty }

        var found = [Track?](repeating: nil, count: items.count)
        let indexed = Array(items.enumerated())
        var batch = 0
        while batch < indexed.count {
            let part = Array(indexed[batch..<min(batch + 4, indexed.count)])
            let results: [(Int, Track?)] = await withTaskGroup(of: (Int, Track?).self) { group in
                for (i, item) in part {
                    group.addTask { (i, await ExternalImport.match(item, api: api)) }
                }
                var out: [(Int, Track?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (i, t) in results { found[i] = t }
            batch += 4
            progress(min(batch, items.count), items.count)
            if Task.isCancelled { break }
        }
        let tracks = found.compactMap { $0 }
        return Result(name: name, tracks: tracks, skipped: items.count - tracks.count)
    }

    /// Dopasowanie do YouTube Music: szukamy tylko tam, porównujemy okładkę ze Spotify z okładkami wyników;
    /// jeśli żadna nie jest taka sama, bierzemy najtrafniejszy (tytuł + wykonawca + czas) i najwyżej w wynikach.
    static func match(_ item: Item, api: YouTubeAPI) async -> Track? {
        let query = "\(item.artist) \(item.title)".trimmingCharacters(in: .whitespaces)
        if let hits = try? await YTMusicSearch.searchSongs(query), !hits.isEmpty,
           let best = await CoverMatch.pick(item: item, hits: Array(hits.prefix(6))) {
            return Track(id: best.track.id, title: item.title,
                         artist: item.artist.isEmpty ? best.track.artist : item.artist,
                         duration: best.track.duration > 0 ? best.track.duration : item.duration)
        }
        // Awaryjnie (gdy YouTube Music nie odpowiada): zwykłe wyszukiwanie, jak dotąd.
        if let id = await scrapeFirstVideoID(query + " audio") {
            return Track(id: id, title: item.title, artist: item.artist, duration: item.duration)
        }
        if let list = try? await api.search(query + " audio"), let first = list.first {
            return Track(id: first.id, title: item.title, artist: item.artist.isEmpty ? first.artist : item.artist, duration: first.duration)
        }
        return nil
    }

    /// Pierwszy wynik wyszukiwania YouTube (bez limitu API).
    static func scrapeFirstVideoID(_ query: String) async -> String? {
        guard var comps = URLComponents(string: "https://www.youtube.com/results") else { return nil }
        comps.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "sp", value: "EgIQAQ==")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("CONSENT=YES+1; SOCS=CAI", forHTTPHeaderField: "Cookie")
        req.setValue("pl-PL,pl;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8),
              let r = html.range(of: "\"videoRenderer\":\\{\"videoId\":\"[A-Za-z0-9_-]{11}\"", options: .regularExpression) else { return nil }
        let m = String(html[r])
        return String(m.suffix(12).dropLast())
    }

    private static func download(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("pl-PL,pl;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw ExternalImportError.network }
        return html
    }

    private static func findDict(withKey key: String, in node: Any) -> [String: Any]? {
        if let d = node as? [String: Any] {
            if d[key] != nil { return d }
            for v in d.values { if let f = findDict(withKey: key, in: v) { return f } }
        } else if let a = node as? [Any] {
            for v in a { if let f = findDict(withKey: key, in: v) { return f } }
        }
        return nil
    }

    private static func spotify(_ url: URL) async throws -> (String, [Item]) {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let k = parts.firstIndex(of: "track"), k + 1 < parts.count,
           let it = try? await SpotifyClient.shared.track(id: parts[k + 1]) {
            return ("\(it.artist) - \(it.title)", [it])
        }
        if let k = parts.firstIndex(where: { $0 == "playlist" || $0 == "album" }), k + 1 < parts.count,
           let r = try? await SpotifyClient.shared.tracks(kind: parts[k], id: parts[k + 1]), !r.1.isEmpty {
            return r
        }
        guard let k = parts.firstIndex(where: { $0 == "playlist" || $0 == "album" }), k + 1 < parts.count,
              let embed = URL(string: "https://open.spotify.com/embed/\(parts[k])/\(parts[k + 1])") else {
            throw ExternalImportError.unsupported
        }
        let html = try await download(embed)
        guard let open = html.range(of: "<script id=\"__NEXT_DATA__\"[^>]*>", options: .regularExpression),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex),
              let data = String(html[open.upperBound..<close.lowerBound]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { throw ExternalImportError.network }
        guard let entity = findDict(withKey: "trackList", in: root),
              let list = entity["trackList"] as? [[String: Any]] else { throw ExternalImportError.empty }
        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify"
        let items = list.compactMap { d -> Item? in
            guard let title = d["title"] as? String else { return nil }
            let artist = ((d["subtitle"] as? String) ?? "").replacingOccurrences(of: "\u{00a0}", with: " ")
            let ms = (d["duration"] as? Double) ?? 0
            return Item(title: title, artist: artist, duration: ms / 1000)
        }
        return (name, items)
    }

    private static func artistName(_ any: Any?) -> String {
        if let d = any as? [String: Any] { return (d["name"] as? String) ?? "" }
        if let a = any as? [[String: Any]] { return a.compactMap { $0["name"] as? String }.joined(separator: ", ") }
        return ""
    }

    private static func isoDuration(_ s: String?) -> Double {
        guard var rest = s, rest.hasPrefix("PT") else { return 0 }
        rest.removeFirst(2)
        var total = 0.0
        var num = ""
        for ch in rest {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            let v = Double(num) ?? 0
            num = ""
            switch ch { case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: break }
        }
        return total
    }

    private static func appleMusic(_ url: URL) async throws -> (String, [Item]) {
        let html = try await download(url)
        guard let re = try? NSRegularExpression(pattern: "<script[^>]*ld\\+json[^>]*>(.*?)</script>", options: [.dotMatchesLineSeparators]) else {
            throw ExternalImportError.network
        }
        let ns = html as NSString
        var name = "Apple Music"
        var items: [Item] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
            guard let data = ns.substring(with: m.range(at: 1)).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            let candidates: [Any] = (obj as? [Any]) ?? [obj]
            for c in candidates {
                guard let d = c as? [String: Any], let tracks = d["track"] as? [[String: Any]] else { continue }
                if let n = d["name"] as? String { name = n }
                let fallbackArtist = artistName(d["byArtist"])
                for t in tracks {
                    guard let title = t["name"] as? String else { continue }
                    let a = artistName(t["byArtist"])
                    items.append(Item(title: title, artist: a.isEmpty ? fallbackArtist : a, duration: isoDuration(t["duration"] as? String)))
                }
            }
            if !items.isEmpty { break }
        }
        return (name, items)
    }
}
