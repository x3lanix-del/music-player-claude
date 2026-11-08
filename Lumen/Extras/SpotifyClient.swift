import Foundation

/// Spotify Web API (przepływ Client Credentials: bez logowania, tylko publiczne dane).
/// Kształt zapytań wzorowany na SpotifyKit. Klucze są wbudowane w aplikację (project.yml).
actor SpotifyClient {
    static let shared = SpotifyClient()

    private var token: String?
    private var expires = Date.distantPast

    private var credentials: (String, String)? {
        let id = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""
        let secret = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientSecret") as? String ?? ""
        return id.isEmpty || secret.isEmpty || id.hasPrefix("$(") ? nil : (id, secret)
    }

    private func accessToken() async throws -> String {
        if let t = token, expires > Date().addingTimeInterval(30) { return t }
        guard let (id, secret) = credentials, let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw ExternalImportError.unsupported
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["access_token"] as? String else { throw ExternalImportError.network }
        token = t
        expires = Date().addingTimeInterval((obj["expires_in"] as? Double) ?? 3600)
        return t
    }

    private func get(_ urlString: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw ExternalImportError.network }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ExternalImportError.network }
        return obj
    }

    private static func item(_ t: [String: Any]) -> ExternalImport.Item? {
        guard let title = t["name"] as? String else { return nil }
        let artists = (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
        var cover: URL? = nil
        if let album = t["album"] as? [String: Any], let imgs = album["images"] as? [[String: Any]] {
            // Środkowy rozmiar (~300 px) wystarcza do porównania, a jest lekki.
            let pick = imgs.count > 1 ? imgs[imgs.count / 2] : imgs.first
            if let u = pick?["url"] as? String { cover = URL(string: u) }
        }
        return ExternalImport.Item(title: title, artist: artists, duration: ((t["duration_ms"] as? Double) ?? 0) / 1000, cover: cover)
    }

    /// Wszystkie piosenki playlisty ("playlist") albo albumu ("album") - z paginacją.
    func tracks(kind: String, id: String) async throws -> (String, [ExternalImport.Item]) {
        let clean = id.split(separator: "?").first.map(String.init) ?? id
        let meta = try await get("https://api.spotify.com/v1/\(kind)s/\(clean)?fields=name")
        let name = (meta["name"] as? String) ?? "Spotify"
        var items: [ExternalImport.Item] = []
        var next: String? = "https://api.spotify.com/v1/\(kind)s/\(clean)/tracks?limit=50"
        while let url = next, items.count < 1000 {
            let page = try await get(url)
            for entry in (page["items"] as? [[String: Any]]) ?? [] {
                let t = (entry["track"] as? [String: Any]) ?? entry
                if let it = SpotifyClient.item(t) { items.append(it) }
            }
            next = page["next"] as? String
        }
        return (name, items)
    }

    /// Pojedyncza piosenka ze Spotify (link open.spotify.com/track/...).
    func track(id: String) async throws -> ExternalImport.Item? {
        let clean = id.split(separator: "?").first.map(String.init) ?? id
        return SpotifyClient.item(try await get("https://api.spotify.com/v1/tracks/\(clean)"))
    }

    /// Wyszukiwanie piosenek w Spotify (nazwa + wykonawca + czas).
    func search(_ query: String, limit: Int = 20) async throws -> [ExternalImport.Item] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let obj = try await get("https://api.spotify.com/v1/search?type=track&limit=\(limit)&q=\(q)")
        let list = ((obj["tracks"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return list.compactMap(SpotifyClient.item)
    }
}
