import Foundation
import Network
import Security

// MARK: - Połączenie z Chromecastem (protokół Cast v2: TLS + wiadomości protobuf)

/// Jedna sesja z urządzeniem Chromecast / Google TV. Uruchamia na nim domyślny odtwarzacz multimediów
/// i każe mu zagrać adres z serwera w telefonie. Cała praca idzie na własnej kolejce; wyniki wracają przez wywołania zwrotne.
final class CastSession: @unchecked Sendable {
    private static let appID = "CC1AD845"            // Default Media Receiver
    private let queue = DispatchQueue(label: "lumen.cast")
    private let endpoint: NWEndpoint
    private var conn: NWConnection?
    private var heartbeat: DispatchSourceTimer?
    private var requestID = 10
    private var transportID: String?
    private var mediaSessionID: Int?
    private var receiverSessionID: String?
    private var pendingLoad: [String: Any]?
    private var closed = false

    var onStatus: (@Sendable (String) -> Void)?
    var onReady: (@Sendable () -> Void)?
    var onClosed: (@Sendable () -> Void)?

    init(endpoint: NWEndpoint) { self.endpoint = endpoint }

    // MARK: Start / stop

    func start() {
        queue.async { [self] in
            let tls = NWProtocolTLS.Options()
            // Chromecast ma własny, samopodpisany certyfikat - w sieci domowej go akceptujemy.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let c = NWConnection(to: endpoint, using: params)
            conn = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.onStatus?("Łączę z urządzeniem…")
                    self.send(ns: "urn:x-cast:com.google.cast.tp.connection", dst: "receiver-0", json: ["type": "CONNECT"])
                    self.send(ns: "urn:x-cast:com.google.cast.receiver", dst: "receiver-0",
                              json: ["type": "LAUNCH", "appId": CastSession.appID, "requestId": self.nextID()])
                    self.startHeartbeat()
                    self.readLength()
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
                }
            }
            c.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            if let rs = receiverSessionID {
                send(ns: "urn:x-cast:com.google.cast.receiver", dst: "receiver-0",
                     json: ["type": "STOP", "sessionId": rs, "requestId": nextID()])
            }
            // Chwila, żeby polecenie STOP zdążyło wyjść, zanim zamkniemy połączenie.
            queue.asyncAfter(deadline: .now() + 0.4) { [self] in finish() }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        conn?.cancel()
        conn = nil
        onClosed?()
    }

    // MARK: Sterowanie odtwarzaniem

    func load(url: String, contentType: String, title: String, artist: String, live: Bool, position: Double, autoplay: Bool) {
        queue.async { [self] in
            let media: [String: Any] = [
                "contentId": url,
                "streamType": live ? "LIVE" : "BUFFERED",
                "contentType": contentType,
                "metadata": ["metadataType": 3, "title": title, "artist": artist]
            ]
            let msg: [String: Any] = [
                "type": "LOAD", "autoplay": autoplay, "currentTime": max(0, position),
                "media": media
            ]
            if transportID == nil { pendingLoad = msg } else { sendLoad(msg) }
        }
    }

    func setPlaying(_ playing: Bool) {
        queue.async { [self] in
            guard let tid = transportID, let ms = mediaSessionID else { return }
            send(ns: "urn:x-cast:com.google.cast.media", dst: tid,
                 json: ["type": playing ? "PLAY" : "PAUSE", "mediaSessionId": ms, "requestId": nextID()])
        }
    }

    private func sendLoad(_ base: [String: Any]) {
        guard let tid = transportID else { return }
        var msg = base
        msg["requestId"] = nextID()
        msg["sessionId"] = receiverSessionID ?? ""
        mediaSessionID = nil
        send(ns: "urn:x-cast:com.google.cast.media", dst: tid, json: msg)
    }

    // MARK: Wiadomości

    private func nextID() -> Int { requestID += 1; return requestID }

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            self?.send(ns: "urn:x-cast:com.google.cast.tp.heartbeat", dst: "receiver-0", json: ["type": "PING"])
        }
        t.resume()
        heartbeat = t
    }

    private func field(_ number: Int, _ text: String) -> Data {
        let bytes = Array(text.utf8)
        var d = Data([UInt8(number << 3 | 2)])
        var len = bytes.count
        while len >= 0x80 {
            d.append(UInt8(len & 0x7f | 0x80))
            len >>= 7
        }
        d.append(UInt8(len))
        d.append(contentsOf: bytes)
        return d
    }

    private func send(ns: String, dst: String, json: [String: Any]) {
        guard let c = conn,
              let payload = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: payload, encoding: .utf8) else { return }
        var body = Data([0x08, 0x00])                       // protocol_version = CASTV2_1_0
        body.append(field(2, "sender-0"))
        body.append(field(3, dst))
        body.append(field(4, ns))
        body.append(contentsOf: [0x28, 0x00])               // payload_type = STRING
        body.append(field(6, text))
        let n = UInt32(body.count)
        var frame = Data([UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        frame.append(body)
        c.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func readLength() {
        guard let c = conn else { return }
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self = self else { return }
            guard error == nil, let d = data, d.count == 4 else { self.finish(); return }
            let b = [UInt8](d)
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard len > 0, len < 2_000_000 else { self.finish(); return }
            self.readBody(len)
        }
    }

    private func readBody(_ len: Int) {
        guard let c = conn else { return }
        c.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, _, error in
            guard let self = self else { return }
            guard error == nil, let d = data, d.count == len else { self.finish(); return }
            self.handle([UInt8](d))
            self.readLength()
        }
    }

    private func decode(_ bytes: [UInt8]) -> (ns: String, payload: String)? {
        var i = 0
        var ns = ""
        var payload = ""
        func varint() -> Int? {
            var result = 0
            var shift = 0
            while i < bytes.count {
                let b = Int(bytes[i])
                i += 1
                result |= (b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return nil }
            let number = key >> 3
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let len = varint(), i + len <= bytes.count else { return nil }
                let s = String(decoding: bytes[i..<(i + len)], as: UTF8.self)
                i += len
                if number == 4 { ns = s } else if number == 6 { payload = s }
            default:
                return nil
            }
        }
        return (ns, payload)
    }

    private func handle(_ bytes: [UInt8]) {
        guard let msg = decode(bytes),
              let obj = try? JSONSerialization.jsonObject(with: Data(msg.payload.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "PING":
            send(ns: "urn:x-cast:com.google.cast.tp.heartbeat", dst: "receiver-0", json: ["type": "PONG"])
        case "CLOSE":
            finish()
        case "LAUNCH_ERROR":
            onStatus?("Urządzenie nie uruchomiło odtwarzacza.")
        case "RECEIVER_STATUS":
            let status = obj["status"] as? [String: Any]
            let apps = status?["applications"] as? [[String: Any]] ?? []
            guard let app = apps.first(where: { ($0["appId"] as? String) == CastSession.appID }),
                  let tid = app["transportId"] as? String else { return }
            if transportID != tid {
                transportID = tid
                receiverSessionID = app["sessionId"] as? String
                send(ns: "urn:x-cast:com.google.cast.tp.connection", dst: tid, json: ["type": "CONNECT"])
                onReady?()
                if let p = pendingLoad { pendingLoad = nil; sendLoad(p) }
            }
        case "MEDIA_STATUS":
            let list = obj["status"] as? [[String: Any]] ?? []
            if let first = list.first {
                if let id = first["mediaSessionId"] as? Int { mediaSessionID = id }
                if let state = first["playerState"] as? String {
                    if state == "PLAYING" { onStatus?("Gra na urządzeniu") }
                    else if state == "BUFFERING" { onStatus?("Wczytuję na urządzeniu…") }
                }
            }
        case "LOAD_FAILED", "INVALID_REQUEST", "LOAD_CANCELLED":
            onStatus?("Urządzenie nie przyjęło utworu (adres telefonu musi być w tej samej sieci Wi‑Fi).")
        default:
            break
        }
    }
}

// MARK: - Sterownik w aplikacji

/// Łączy odtwarzacz z Chromecastem: telefon cichnie, a urządzenie gra to samo (utwór albo stację) i podąża za pauzą / zmianą utworu.
@MainActor
final class CastController: ObservableObject {
    static let shared = CastController()

    @Published private(set) var deviceName: String? = nil
    @Published private(set) var status = ""

    private var session: CastSession?
    private var timer: Timer?
    private var castedID = ""
    private var lastWants: Bool? = nil
    private var ready = false
    private weak var engine: PlayerEngine?

    var connected: Bool { deviceName != nil }

    func start(_ device: NearbyDevice, engine: PlayerEngine, settings: AppSettings) {
        guard let endpoint = device.endpoint else { return }
        stop()
        self.engine = engine
        deviceName = device.name
        status = "Łączę z urządzeniem…"
        castedID = ""
        lastWants = nil
        ready = false
        // Telewizor pobiera dźwięk z serwera w telefonie, więc musi działać.
        RemoteLyricsBridge.shared.start(engine: engine, settings: settings)

        let s = CastSession(endpoint: endpoint)
        s.onStatus = { [weak self] text in Task { @MainActor in self?.status = text } }
        s.onReady = { [weak self] in Task { @MainActor in self?.ready = true; self?.status = "Połączono. Wysyłam utwór…" } }
        s.onClosed = { [weak self] in Task { @MainActor in self?.didClose() } }
        session = s
        s.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session?.stop()
        session = nil
        if deviceName != nil { engine?.setPhoneMuted(false) }
        deviceName = nil
        status = ""
        ready = false
    }

    private func didClose() {
        guard deviceName != nil else { return }
        timer?.invalidate()
        timer = nil
        session = nil
        engine?.setPhoneMuted(false)
        deviceName = nil
        status = ""
        ready = false
    }

    private func tick() {
        guard ready, let engine = engine, let session = session, let track = engine.currentTrack,
              let media = RemoteLyricsBridge.shared.castMedia() else { return }
        if castedID != track.id {
            castedID = track.id
            lastWants = engine.wantsPlaying
            engine.setPhoneMuted(true)
            let path = media.url.lowercased()
            let type = media.live ? (path.contains(".aac") ? "audio/aac" : "audio/mpeg") : "audio/mp4"
            let song = engine.radioSong
            let title = track.isRadio ? (song?.title ?? track.title) : track.title
            let artist = track.isRadio ? (song?.artist.isEmpty == false ? (song?.artist ?? "") : track.title) : track.artist
            session.load(url: media.url, contentType: type, title: title, artist: artist, live: media.live,
                         position: media.live ? 0 : engine.livePlaybackTime(), autoplay: engine.wantsPlaying)
        } else if lastWants != engine.wantsPlaying {
            lastWants = engine.wantsPlaying
            session.setPlaying(engine.wantsPlaying)
        }
    }
}
