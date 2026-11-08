import Foundation
import Network
import UIKit
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Adres telefonu w sieci Wi‑Fi

enum LocalNetwork {
    /// Adres IPv4 telefonu w domowej sieci (Wi‑Fi albo hotspot), np. 192.168.0.12.
    static func ipv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: String? = nil
        var fallback: String? = nil
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = pointer {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET),
               (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
               (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                let name = String(cString: ifa.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if name == "en0" { best = ip }
                    else if name.hasPrefix("bridge") || name.hasPrefix("en") { fallback = fallback ?? ip }
                }
            }
            pointer = ifa.ifa_next
        }
        return best ?? fallback
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Mały serwer HTTP w sieci lokalnej

/// Udostępnia w sieci domowej stronę z tekstem i prostymi przyciskami (dla telewizora, komputera, drugiego telefonu).
/// Dane stanu wpisuje `RemoteLyricsBridge`; serwer tylko je podaje.
final class LyricsServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lumen.lyrics.server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var stateData = Data("{}".utf8)
    private var lyricsData = Data("{}".utf8)
    private var coverData: Data?
    private var audioFile: URL?
    private var lastPoll = Date.distantPast
    var onCommand: (@Sendable (String, [String: String]) -> Void)?

    // MARK: Dane do podania

    func set(state: Data) { lock.lock(); stateData = state; lock.unlock() }
    func set(lyrics: Data) { lock.lock(); lyricsData = lyrics; lock.unlock() }
    func set(cover: Data?) { lock.lock(); coverData = cover; lock.unlock() }
    func set(audio: URL?) { lock.lock(); audioFile = audio; lock.unlock() }
    var secondsSincePoll: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastPoll) }

    // MARK: Start / stop

    /// Próbuje portu 8787, a gdy jest zajęty - dowolnego wolnego. `completion` dostaje numer portu (nil = błąd).
    func start(completion: @escaping @Sendable (UInt16?) -> Void) {
        stop()
        launch(preferred: 8787, completion: completion)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func launch(preferred: UInt16?, completion: @escaping @Sendable (UInt16?) -> Void) {
        let l: NWListener
        do {
            if let p = preferred, let port = NWEndpoint.Port(rawValue: p) {
                l = try NWListener(using: .tcp, on: port)
            } else {
                l = try NWListener(using: .tcp)
            }
        } catch {
            if preferred != nil { launch(preferred: nil, completion: completion) } else { completion(nil) }
            return
        }
        var reported = false
        l.stateUpdateHandler = { [weak self, weak l] state in
            switch state {
            case .ready:
                if !reported { reported = true; completion(l?.port?.rawValue) }
            case .failed:
                l?.cancel()
                if !reported {
                    reported = true
                    if preferred != nil { self?.launch(preferred: nil, completion: completion) } else { completion(nil) }
                }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener = l
        l.start(queue: queue)
    }

    // MARK: Połączenia

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                self.route(head: head, conn: conn)
            } else if error != nil || isComplete || buf.count > 32_768 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(head: String, conn: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }
        let target = String(parts[1])
        if parts[0].uppercased() == "OPTIONS" {
            respond(conn, status: "204 No Content", type: "text/plain", body: Data())
            return
        }
        var rangeHeader: String? = nil
        for h in lines.dropFirst() where h.lowercased().hasPrefix("range:") {
            rangeHeader = h.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: "http://x" + target)
        let path = comps?.path ?? "/"
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        switch path {
        case "/", "/index.html":
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(RemoteLyricsPage.html.utf8))
        case "/state":
            lock.lock(); lastPoll = Date(); let d = stateData; lock.unlock()
            respond(conn, status: "200 OK", type: "application/json; charset=utf-8", body: d)
        case "/lyrics":
            lock.lock(); let d = lyricsData; lock.unlock()
            respond(conn, status: "200 OK", type: "application/json; charset=utf-8", body: d)
        case "/cover":
            lock.lock(); let d = coverData; lock.unlock()
            if let d = d { respond(conn, status: "200 OK", type: "image/jpeg", body: d) }
            else { respond(conn, status: "404 Not Found", type: "text/plain", body: Data()) }
        case "/audio":
            serveAudio(conn, range: rangeHeader)
        default:
            if path.hasPrefix("/cmd/") {
                let name = String(path.dropFirst(5))
                onCommand?(name, query)
                respond(conn, status: "200 OK", type: "text/plain", body: Data("ok".utf8))
            } else {
                respond(conn, status: "404 Not Found", type: "text/plain", body: Data())
            }
        }
    }

    private func respond(_ conn: NWConnection, status: String, type: String, body: Data, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Range\r\n"
        head += "Access-Control-Expose-Headers: Content-Range, Accept-Ranges, Content-Length\r\nConnection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveAudio(_ conn: NWConnection, range: String?) {
        lock.lock(); let file = audioFile; lock.unlock()
        guard let url = file,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size > 0 else {
            respond(conn, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        let mime = url.pathExtension.lowercased() == "mp4" ? "video/mp4" : "audio/mp4"
        guard let r = range, r.lowercased().hasPrefix("bytes=") else {
            // Bez Range: pierwszy kawałek jako 200 nie wystarczy przeglądarkom, więc oddajemy cały plik.
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                respond(conn, status: "200 OK", type: mime, body: data, extra: ["Accept-Ranges": "bytes"])
            } else {
                respond(conn, status: "404 Not Found", type: "text/plain", body: Data())
            }
            return
        }
        let spec = r.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        var start = 0
        var end = size - 1
        if let s = spec.first, let sv = Int(s) { start = sv }
        else if spec.count > 1, let tail = Int(spec[1]) { start = max(0, size - tail) }   // "bytes=-500"
        if spec.count > 1, !spec[0].isEmpty, let ev = Int(spec[1]) { end = min(ev, size - 1) }
        guard start < size, start <= end else {
            respond(conn, status: "416 Range Not Satisfiable", type: "text/plain", body: Data(),
                    extra: ["Content-Range": "bytes */\(size)"])
            return
        }
        end = min(end, start + 1_500_000 - 1)
        var chunk = Data()
        if let h = try? FileHandle(forReadingFrom: url) {
            defer { try? h.close() }
            try? h.seek(toOffset: UInt64(start))
            chunk = (try? h.read(upToCount: end - start + 1)) ?? Data()
        }
        guard !chunk.isEmpty else {
            respond(conn, status: "404 Not Found", type: "text/plain", body: Data())
            return
        }
        respond(conn, status: "206 Partial Content", type: mime, body: chunk,
                extra: ["Content-Range": "bytes \(start)-\(start + chunk.count - 1)/\(size)", "Accept-Ranges": "bytes"])
    }
}

// MARK: - Most: aplikacja <-> strona na drugim urządzeniu

/// Co pół sekundy wpisuje do serwera stan odtwarzacza i tekst, a polecenia ze strony (graj, dalej…) przekazuje do odtwarzacza.
@MainActor
final class RemoteLyricsBridge: ObservableObject {
    static let shared = RemoteLyricsBridge()

    @Published private(set) var running = false
    @Published private(set) var address: String? = nil
    @Published private(set) var failed = false

    private let server = LyricsServer()
    private weak var engine: PlayerEngine?
    private weak var settings: AppSettings?
    private var timer: Timer?
    private var lastLyricsKey = ""
    private var lyricsVersion = 0
    private var lastTrackKey = ""
    private var coverVersion = 0
    private var audioLookupID = ""
    private var audioReady = false
    private var lastCoverKey = ""
    private var ensuredID = ""

    func start(engine: PlayerEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        guard !running else { return }
        failed = false
        server.onCommand = { [weak self] name, query in
            Task { @MainActor in self?.handle(command: name, query: query) }
        }
        server.start { [weak self] port in
            Task { @MainActor in
                guard let self = self else { return }
                if let port = port, let ip = LocalNetwork.ipv4() {
                    self.address = "http://\(ip):\(port)"
                    self.running = true
                    self.failed = false
                    self.startTimer()
                } else {
                    self.running = false
                    self.failed = true
                    self.server.stop()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server.stop()
        running = false
        address = nil
        engine?.setPhoneMuted(false)
    }

    /// Adres dźwięku dla urządzenia w sieci (Chromecast): stacja = jej strumień, piosenka = plik z telefonu (gdy już pobrany).
    func castMedia() -> (url: String, live: Bool)? {
        guard let engine = engine, let t = engine.currentTrack else { return nil }
        if t.isRadio { return engine.currentRadioURL.map { ($0.absoluteString, true) } }
        guard audioReady, let base = address else { return nil }
        return (base + "/audio?id=" + t.id, false)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        }
        push()
    }

    private func handle(command: String, query: [String: String]) {
        guard let engine = engine else { return }
        switch command {
        case "toggle": engine.togglePlayPause()
        case "play": if !engine.wantsPlaying { engine.play() }
        case "pause": if engine.wantsPlaying { engine.pause() }
        case "next": engine.next()
        case "prev": engine.previous()
        case "seek": if !engine.isRadio, let t = Double(query["t"] ?? "") { engine.seek(to: max(0, t)) }
        case "mute": engine.setPhoneMuted(query["on"] == "1")
        default: break
        }
    }

    // MARK: Wysyłanie stanu

    private func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

    private func push() {
        guard let engine = engine, let settings = settings else { return }
        // Strona zniknęła (zamknięta karta, wyłączony telewizor) - telefon ma znowu grać głośno.
        if engine.phoneMuted && !CastController.shared.connected && server.secondsSincePoll > 8 { engine.setPhoneMuted(false) }

        let track = engine.currentTrack
        let trackKey = track?.id ?? ""
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            audioReady = false
            audioLookupID = ""
            server.set(audio: nil)
        }
        // Okładka (po zmianie utworu albo gdy dopiero się załadowała).
        let coverKey = "\(trackKey)|\(engine.artwork != nil)"
        if coverKey != lastCoverKey {
            lastCoverKey = coverKey
            coverVersion += 1
            server.set(cover: engine.artwork.flatMap { $0.jpegData(compressionQuality: 0.7) })
        }
        // Plik dźwiękowy do odtwarzania na drugim urządzeniu (tylko pobrane piosenki).
        if let t = track, !t.isRadio, !audioReady, audioLookupID != t.id {
            audioLookupID = t.id
            let id = t.id
            // Piosenka jeszcze nie jest na dysku telefonu: pobierz ją od razu (z pierwszeństwem), żeby drugie urządzenie mogło ją zagrać.
            if ensuredID != id {
                ensuredID = id
                Task.detached(priority: .userInitiated) { _ = await AudioCache.shared.ensure(id, urgent: true) }
            }
            Task { [weak self] in
                let url = await AudioCache.shared.localURL(for: id)
                guard let self = self, self.lastTrackKey == id else { return }
                if let url = url {
                    self.server.set(audio: url)
                    self.audioReady = true
                } else {
                    self.audioLookupID = ""      // jeszcze się pobiera - spróbujemy ponownie
                }
            }
        }

        let lyrics = engine.lyrics
        let key = "\(lyrics.revision)|\(lyrics.offset)|\(lyrics.stretch)|\(settings.data.censorProfanity)|\(engine.radioPositionKnown)|\(engine.isRadio)"
        if key != lastLyricsKey {
            lastLyricsKey = key
            lyricsVersion += 1
            server.set(lyrics: lyricsJSON(engine: engine, settings: settings))
        }

        var audio: Any = NSNull()
        if let t = track {
            if t.isRadio, let u = engine.currentRadioURL { audio = u.absoluteString }
            else if audioReady { audio = "/audio?id=\(t.id)" }
        }
        let radioSong = engine.radioSong
        let isRadioTrack = track?.isRadio == true
        let title: String = isRadioTrack ? (radioSong?.title ?? track?.title ?? "Radio") : (track?.title ?? "Nic nie gra")
        var artist: String = track?.artist ?? ""
        if isRadioTrack { artist = (radioSong?.artist.isEmpty == false ? radioSong?.artist : nil) ?? track?.title ?? "" }
        let state: [String: Any] = [
            "tid": trackKey,
            "title": title,
            "artist": artist,
            "playing": engine.isPlaying,
            "pos": r3(engine.livePlaybackTime()),
            "dur": r3(engine.clock.duration),
            "radio": engine.isRadio,
            "station": engine.currentStation?.name ?? "",
            "lver": lyricsVersion,
            "cv": coverVersion,
            "audio": audio,
            "muted": engine.phoneMuted
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state) { server.set(state: data) }
    }

    private func lyricsJSON(engine: PlayerEngine, settings: AppSettings) -> Data {
        let lyrics = engine.lyrics
        let censor = settings.data.censorProfanity
        var obj: [String: Any]
        switch lyrics.phase {
        case .synced:
            if engine.isRadio && !engine.radioPositionKnown {
                let text = lyrics.lines.map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
                obj = ["kind": "plain", "text": censor ? Profanity.censor(text) : text]
            } else {
                let rows = LyricRow.build(lines: lyrics.lines, censor: censor)
                var out: [[String: Any]] = []
                out.reserveCapacity(rows.count)
                for row in rows {
                    // Linijka po linijce: wszystkie litery zapalają się razem w chwili startu linijki.
                    let t0 = r3(lyrics.playerTime(forLyric: row.time))
                    let n = row.chars.count
                    out.append([
                        "t": t0,
                        "a": row.chars.map { String($0) },
                        "c": [Double](repeating: t0, count: n),
                        "f": [Double](repeating: 0.45, count: n)
                    ])
                }
                obj = ["kind": "synced", "rows": out]
            }
        case .plain:
            obj = ["kind": "plain", "text": censor ? Profanity.censor(lyrics.plainText) : lyrics.plainText]
        case .idle, .loading:
            obj = ["kind": "none", "text": "Szukam tekstu…"]
        case .instrumental:
            obj = ["kind": "none", "text": "Utwór instrumentalny"]
        case .notFound:
            obj = ["kind": "none", "text": "Nie znaleziono tekstu"]
        case .offline:
            obj = ["kind": "none", "text": "Brak internetu"]
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}
