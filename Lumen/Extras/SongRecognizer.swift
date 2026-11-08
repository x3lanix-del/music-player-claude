import SwiftUI
import AVFAudio

/// Rozpoznawanie piosenki z mikrofonu: nagranie ~10 s wysyłane do AudD (nie wymaga płatnego konta Apple).
@MainActor
final class SongRecognizer: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case found(title: String, artist: String)
        case notFound
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var recorder: AVAudioRecorder?
    private var task: Task<Void, Never>?
    private var cancelled = false
    /// Numer bieżącej próby nagrywania (1 albo 2), do podpisu na ekranie.
    @Published private(set) var attempt = 1

    private var token: String { AppKeys.audd }

    func start(pausing engine: PlayerEngine) {
        guard task == nil else { return }
        cancelled = false
        attempt = 1
        if engine.isPlaying { engine.pause() }
        state = .listening
        task = Task { [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard let self = self else { return }
            guard granted else {
                self.finish(.failed("Brak zgody na mikrofon. Włącz ją w Ustawieniach iOS."))
                return
            }
            guard !self.token.isEmpty else {
                self.finish(.failed("Brak tokena AudD w aplikacji."))
                return
            }
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try? audio.setActive(true)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("recognize.m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            // Do dwóch prób (jak w Shazamie): gdy pierwsze nagranie nic nie da, nagrywamy jeszcze raz.
            var result: State = .notFound
            for attempt in 0..<2 {
                try? FileManager.default.removeItem(at: file)
                guard let rec = try? AVAudioRecorder(url: file, settings: settings), rec.record() else {
                    self.finish(.failed("Nie udało się włączyć mikrofonu."))
                    return
                }
                self.recorder = rec
                self.attempt = attempt + 1
                try? await Task.sleep(nanoseconds: (attempt == 0 ? 9 : 12) * 1_000_000_000)
                rec.stop()
                self.recorder = nil
                if self.cancelled || Task.isCancelled { return }
                result = await self.send(file: file)
                if self.cancelled { return }
                if case .notFound = result { continue }
                break
            }
            self.finish(result)
        }
    }

    private func send(file: URL) async -> State {
        guard let audio = try? Data(contentsOf: file), let url = URL(string: "https://api.audd.io/") else {
            return .failed("Nie udało się odczytać nagrania.")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("api_token", token)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recognize.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Rozpoznawanie nie zadziałało: nieprawidłowa odpowiedź.")
            }
            if (obj["status"] as? String) == "error" {
                let err = obj["error"] as? [String: Any]
                let code = (err?["error_code"] as? Int) ?? 0
                let msg = (err?["error_message"] as? String) ?? "nieznany błąd"
                switch code {
                case 901: return .failed("Wyczerpany dzienny limit rozpoznawania (AudD). Spróbuj jutro albo podaj własny token.")
                case 900: return .failed("Nieprawidłowy token AudD.")
                default: return .failed("Rozpoznawanie nie zadziałało: \(msg)")
                }
            }
            if let r = obj["result"] as? [String: Any], let title = r["title"] as? String {
                return .found(title: title, artist: (r["artist"] as? String) ?? "")
            }
            return .notFound
        } catch {
            return .failed("Rozpoznawanie nie zadziałało: \(error.localizedDescription)")
        }
    }

    func cancel() {
        cancelled = true
        recorder?.stop()
        recorder = nil
        task?.cancel()
        finish(.idle)
    }

    private func finish(_ newState: State) {
        recorder = nil
        task = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        state = newState
    }
}

struct RecognizeSheet: View {
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @StateObject private var rec = SongRecognizer()
    @State private var busy = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                content
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .navigationTitle("Rozpoznaj piosenkę")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Zamknij") { rec.cancel(); dismiss() }
                }
            }
        }
        .onAppear { rec.start(pausing: engine) }
        .onDisappear { rec.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch rec.state {
        case .idle:
            Image(systemName: "waveform.circle.fill").font(.system(size: 84))
            Button("Słuchaj") { rec.start(pausing: engine) }.buttonStyle(RecognizeButtonStyle(prominent: true))
        case .listening:
            ProgressView().scaleEffect(1.8).padding(.bottom, 8)
            Text("Słucham…").font(.title3.weight(.semibold))
            Text(rec.attempt > 1 ? "Próbuję jeszcze raz - zbliż telefon do źródła dźwięku." : "Zbliż telefon do źródła dźwięku. Nagrywam ok. 10 s.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Anuluj") { rec.cancel() }.buttonStyle(RecognizeButtonStyle(prominent: false))
        case .found(let title, let artist):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            if !artist.isEmpty { Text(artist).foregroundStyle(.secondary) }
            Button(busy ? "Szukam…" : "Odtwórz") { Task { await play(title: title, artist: artist) } }
                .buttonStyle(RecognizeButtonStyle(prominent: true))
                .disabled(busy)
            Button("Słuchaj ponownie") { rec.start(pausing: engine) }.buttonStyle(RecognizeButtonStyle(prominent: false))
        case .notFound:
            Image(systemName: "questionmark.circle").font(.system(size: 64)).foregroundStyle(.secondary)
            Text("Nie rozpoznano piosenki.")
            Button("Spróbuj ponownie") { rec.start(pausing: engine) }.buttonStyle(RecognizeButtonStyle(prominent: true))
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle").font(.system(size: 54)).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("Spróbuj ponownie") { rec.start(pausing: engine) }.buttonStyle(RecognizeButtonStyle(prominent: false))
        }
    }

    private func play(title: String, artist: String) async {
        busy = true
        let q = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        var track: Track? = nil
        if let id = await ExternalImport.scrapeFirstVideoID(q + " audio") {
            track = Track(id: id, title: title, artist: artist, duration: 0)
        } else if let r = try? await settings.api.search(q), let first = r.first {
            track = first
        }
        busy = false
        if let t = track {
            engine.playNow(t)
            dismiss()
        } else {
            toast.show("Nie znaleziono tej piosenki.")
        }
    }
}

/// Przyciski z czytelnym tekstem niezależnie od koloru akcentu (przy białym akcencie systemowe były całe białe).
struct RecognizeButtonStyle: ButtonStyle {
    @Environment(\.ink) private var ink
    @Environment(\.isEnabled) private var enabled
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 24)
            .frame(minHeight: 46)
            .background(ink.opacity(prominent ? 0.28 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(ink.opacity(prominent ? 0.45 : 0.25), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}
