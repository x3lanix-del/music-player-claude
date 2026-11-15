import Foundation
import AVFoundation
import ShazamKit

/// Rozpoznawanie piosenki z nagrania (mikrofon albo próbka strumienia radiowego).
///
/// Kolejność:
/// 1. Shazam - odcisk dźwięku (sygnatura) liczony jest na telefonie i wysyłany do Shazama. Bez tokena i bez limitu.
/// 2. AudD - gdy Shazam nie odpowie: najpierw token z aplikacji, potem bez tokena (darmowa pula AudD),
///    na końcu publiczny token testowy. Token, który AudD odrzucił jako nieprawidłowy, nie jest więcej używany.
actor SongID {
    static let shared = SongID()

    struct Hit: Sendable {
        let title: String
        let artist: String
        /// Miejsce w piosence (s), w którym zaczynało się nagranie - jeśli serwis je podał.
        let offset: Double?
    }

    enum Outcome: Sendable {
        case found(Hit)
        case notFound
        case failed(String)
    }

    /// Tokeny AudD odrzucone jako nieprawidłowe (do zamknięcia aplikacji).
    private var deadTokens = Set<String>()

    /// `allowAudD == false`: tylko droga bez limitu (radio pyta często, a darmowa pula AudD jest mała).
    func identify(file: URL, allowAudD: Bool = true) async -> Outcome {
        if let hit = await SongID.askShazam(file: file) { return .found(hit) }
        guard allowAudD else { return .notFound }

        guard let data = try? Data(contentsOf: file) else { return .failed("Nie udało się odczytać nagrania.") }
        var tokens: [String] = []
        for token in [AppKeys.audd, "", "test"] where !deadTokens.contains(token) && !tokens.contains(token) {
            tokens.append(token)
        }
        var limitReached = false
        var lastError: String? = nil
        for token in tokens {
            switch await SongID.askAudD(token: token, data: data, file: file) {
            case .found(let hit):
                return .found(hit)
            case .notFound:
                return .notFound
            case .rejected(let code):
                // 900 = nieprawidłowy token (nie próbujemy go więcej), 901/902 = limit: następna droga.
                if code == 900 { deadTokens.insert(token) } else { limitReached = true }
            case .failed(let message):
                lastError = message
            }
        }
        if limitReached {
            return .failed("Darmowy limit rozpoznawania na dziś się skończył. Spróbuj jutro.")
        }
        return .failed(lastError ?? "Rozpoznawanie jest chwilowo niedostępne. Spróbuj za chwilę.")
    }

    // MARK: - Shazam

    /// Sygnatura z pierwszych `limit` sekund pliku (liczona lokalnie przez ShazamKit).
    private static func signature(of file: URL, limit: Double) -> SHSignature? {
        guard let audio = try? AVAudioFile(forReading: file) else { return nil }
        let format = audio.processingFormat
        guard format.sampleRate > 0 else { return nil }
        let generator = SHSignatureGenerator()
        let chunk: AVAudioFrameCount = 16_384
        let maxFrames = AVAudioFramePosition(limit * format.sampleRate)
        var done: AVAudioFramePosition = 0
        while done < maxFrames {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), maxFrames - done))
            do { try audio.read(into: buffer, frameCount: want) } catch { break }
            if buffer.frameLength == 0 { break }
            do { try generator.append(buffer, at: nil) } catch { return nil }
            done += AVAudioFramePosition(buffer.frameLength)
        }
        guard Double(done) >= 3 * format.sampleRate else { return nil }
        return generator.signature()
    }

    private static func askShazam(file: URL) async -> Hit? {
        guard let sig = signature(of: file, limit: 10) else { return nil }
        let first = UUID().uuidString.uppercased()
        let second = UUID().uuidString.uppercased()
        let address = "https://amp.shazam.com/discovery/v5/en-US/GB/iphone/-/tag/\(first)/\(second)"
            + "?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&hubv5minorversion=v5.1&hidelb=true&video=v3"
        guard let url = URL(string: address) else { return nil }
        let empty: [String: Any] = [:]
        let body: [String: Any] = [
            "timezone": TimeZone.current.identifier,
            "signature": [
                "uri": "data:audio/vnd.shazam.sig;base64," + sig.dataRepresentation.base64EncodedString(),
                "samplems": Int(sig.duration * 1000)
            ] as [String: Any],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "context": empty,
            "geolocation": empty
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("IPHONE", forHTTPHeaderField: "X-Shazam-Platform")
        request.setValue("14.1.0", forHTTPHeaderField: "X-Shazam-AppVersion")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        request.setValue("Shazam/3685 CFNetwork/1197 Darwin/20.0.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let track = object["track"] as? [String: Any],
              let title = track["title"] as? String, !title.isEmpty else { return nil }
        let matches = object["matches"] as? [[String: Any]]
        let offset = (matches?.first?["offset"] as? NSNumber)?.doubleValue
        return Hit(title: title, artist: (track["subtitle"] as? String) ?? "", offset: offset)
    }

    // MARK: - AudD

    private enum AudDReply {
        case found(Hit)
        case notFound
        /// Odmowa z powodu tokena albo limitu (kod błędu AudD).
        case rejected(Int)
        case failed(String)
    }

    /// "mm:ss" albo "h:mm:ss" -> sekundy.
    static func parseTimecode(_ text: String?) -> Double? {
        guard let text = text, !text.isEmpty else { return nil }
        var total = 0.0
        for part in text.split(separator: ":") {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func askAudD(token: String, data: Data, file: URL) async -> AudDReply {
        guard let url = URL(string: "https://api.audd.io/") else { return .failed("Rozpoznawanie jest chwilowo niedostępne.") }
        let ext = file.pathExtension.lowercased()
        let mime = ext == "mp3" ? "audio/mpeg" : (ext == "aac" ? "audio/aac" : "audio/mp4")
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        if !token.isEmpty {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"api_token\"\r\n\r\n\(token)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (reply, _) = try? await URLSession.shared.data(for: request) else {
            return .failed("Brak internetu albo serwer rozpoznawania nie odpowiada.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            return .failed("Rozpoznawanie nie zadziałało: nieprawidłowa odpowiedź serwera.")
        }
        if (object["status"] as? String) == "error" {
            let error = object["error"] as? [String: Any]
            let code = (error?["error_code"] as? NSNumber)?.intValue ?? 0
            if (900...903).contains(code) { return .rejected(code) }
            let message = (error?["error_message"] as? String) ?? "nieznany błąd"
            return .failed("Rozpoznawanie nie zadziałało: \(message)")
        }
        if let result = object["result"] as? [String: Any], let title = result["title"] as? String, !title.isEmpty {
            return .found(Hit(title: title, artist: (result["artist"] as? String) ?? "",
                              offset: parseTimecode(result["timecode"] as? String)))
        }
        return .notFound
    }
}
