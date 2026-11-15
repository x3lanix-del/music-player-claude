import SwiftUI
import AVFAudio

/// Rozpoznawanie piosenki z mikrofonu: nagranie ok. 10 s rozpoznaje `SongID` (Shazam, a w zapasie AudD).
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
                try? await Task.sleep(nanoseconds: (attempt == 0 ? 9 : 11) * 1_000_000_000)
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
        switch await SongID.shared.identify(file: file) {
        case .found(let hit): return .found(title: hit.title, artist: hit.artist)
        case .notFound: return .notFound
        case .failed(let message): return .failed(message)
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
