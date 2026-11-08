import Foundation

// MARK: - Próbka strumienia radiowego

/// Pobiera kilka sekund strumienia stacji (surowe bajty mp3/aac) do rozpoznania utworu.
enum StreamClipCapture {
    struct Clip {
        let data: Data
        let fileName: String
        let mime: String
    }

    static func capture(url: URL, seconds: Double, maxBytes: Int) async -> Clip? {
        let path = url.path.lowercased()
        // Listy odtwarzania (HLS, pls, m3u) nie są surowym dźwiękiem.
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") || path.hasSuffix(".pls") || path.hasSuffix(".asx") { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("MusicPlayer/1.22", forHTTPHeaderField: "User-Agent")
        // Bez nagłówka Icy-MetaData strumień jest czystym dźwiękiem (bez wstawek z tytułami).
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if type.contains("mpegurl") || type.contains("text/") || type.contains("html") || type.contains("ogg") { return nil }

            var ext = "mp3"
            var mime = "audio/mpeg"
            if type.contains("aac") { ext = "aac"; mime = "audio/aac" }

            var data = Data()
            data.reserveCapacity(maxBytes)
            let started = Date()
            var n = 0
            for try await b in bytes {
                data.append(b)
                n += 1
                if n % 4096 == 0 {
                    if Task.isCancelled { return nil }
                    if data.count >= maxBytes || Date().timeIntervalSince(started) >= seconds { break }
                }
                if data.count >= maxBytes { break }
            }
            guard data.count > 40_000 else { return nil }
            return Clip(data: data, fileName: "radio.\(ext)", mime: mime)
        } catch {
            return nil
        }
    }
}

// MARK: - AudD

/// Rozpoznawanie utworu przez AudD. Odpowiedź zawiera też miejsce w piosence (timecode), z którego
/// liczymy pozycję, żeby tekst mógł się animować także w radiu.
enum AudDClient {
    struct Hit {
        let title: String
        let artist: String
        let timecode: Double
    }

    private static var token: String { AppKeys.audd }

    /// "mm:ss" albo "h:mm:ss" -> sekundy.
    static func parseTimecode(_ text: String?) -> Double {
        guard let text = text else { return 0 }
        var total = 0.0
        for part in text.split(separator: ":") {
            guard let v = Double(part.trimmingCharacters(in: .whitespaces)) else { return 0 }
            total = total * 60 + v
        }
        return total
    }

    static func recognize(data: Data, fileName: String, mime: String = "audio/mpeg") async -> Hit? {
        guard !token.isEmpty, let url = URL(string: "https://api.audd.io/") else { return nil }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"api_token\"\r\n\r\n\(token)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (resp, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              (obj["status"] as? String) != "error",
              let r = obj["result"] as? [String: Any],
              let title = r["title"] as? String, !title.isEmpty else { return nil }
        return Hit(title: title, artist: (r["artist"] as? String) ?? "", timecode: parseTimecode(r["timecode"] as? String))
    }
}
