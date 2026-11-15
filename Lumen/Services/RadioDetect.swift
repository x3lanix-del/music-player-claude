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
