import SwiftUI
import AVFoundation

// MARK: - Aktualnie grany utwór w radiu

struct RadioSong: Equatable {
    var artist: String
    var title: String

    var display: String { artist.isEmpty ? title : "\(artist) – \(title)" }

    /// Stabilny identyfikator do zapisu tekstu na dysku (bez znaków specjalnych).
    var cacheID: String {
        var h: UInt64 = 14695981039346656037          // FNV-1a
        for b in "\(artist.lowercased())|\(title.lowercased())".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "radiosong-" + String(h, radix: 16)
    }

    private static func norm(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Luźne porównanie (wielkość liter, znaki specjalne, dopiski typu "(Radio Edit)").
    func matches(_ other: RadioSong) -> Bool {
        let t1 = RadioSong.norm(title), t2 = RadioSong.norm(other.title)
        guard !t1.isEmpty, !t2.isEmpty else { return false }
        let titleOK = t1 == t2 || t1.contains(t2) || t2.contains(t1)
        guard titleOK else { return false }
        let a1 = RadioSong.norm(artist), a2 = RadioSong.norm(other.artist)
        if a1.isEmpty || a2.isEmpty { return true }
        return a1 == a2 || a1.contains(a2) || a2.contains(a1)
    }

    /// "Wykonawca - Tytuł" z metadanych strumienia (ICY StreamTitle). Zwraca nil, gdy to nie wygląda na utwór.
    static func parse(_ raw: String, station: String) -> RadioSong? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard s.count >= 3, s != "-", s.lowercased() != station.lowercased() else { return nil }
        if let r = s.range(of: " - ") {
            let artist = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return RadioSong(artist: artist, title: title) }
        }
        return RadioSong(artist: "", title: s)
    }
}

/// Odbiera metadane strumienia: ICY (mp3/aac) i ID3 (HLS). Wywołuje `onUpdate` na głównym wątku.
final class RadioMetaReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    var onUpdate: ((_ streamTitle: String?, _ artist: String?, _ title: String?) -> Void)?

    func attach(to item: AVPlayerItem) {
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        var stream: String? = nil, artist: String? = nil, title: String? = nil
        for group in groups {
            for item in group.items {
                guard let text = item.stringValue, !text.isEmpty else { continue }
                switch item.identifier {
                case .icyMetadataStreamTitle?: stream = text
                case .id3MetadataLeadPerformer?, .commonIdentifierArtist?: artist = text
                case .id3MetadataTitleDescription?, .commonIdentifierTitle?: title = text
                default: break
                }
            }
        }
        if stream != nil || artist != nil || title != nil { onUpdate?(stream, artist, title) }
    }
}

// MARK: - Ekran odtwarzacza radia

/// Odtwarzacz radia wygląda jak odtwarzacz zwykłej piosenki ze schowanym tekstem: duża ikona stacji, pod nią
/// tytuł (grany utwór albo nazwa stacji), pasek "NA ŻYWO" w miejscu paska postępu i te same przyciski.
/// Radio nie pokazuje tekstu piosenek.
struct RadioNowPlayingView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @State private var showDevices = false
    @State private var prevTaps = 0
    @State private var nextTaps = 0

    private var station: RadioStation? { engine.currentStation }
    /// Stacja jeszcze się łączy (nic jeszcze nie zagrało).
    private var connecting: Bool { engine.wantsPlaying && !engine.isPlaying }
    private var stationName: String { station?.name ?? engine.currentTrack?.title ?? "Radio" }

    /// Grany utwór, a gdy stacja go nie podaje - nazwa stacji.
    private var title: String { engine.radioSong?.title ?? stationName }

    private var subtitle: String {
        if let song = engine.radioSong {
            return song.artist.isEmpty ? stationName : "\(song.artist) · \(stationName)"
        }
        if connecting { return "Łączenie ze stacją…" }
        if engine.radioDetecting { return "Wykrywam utwór…" }
        if let detail = station?.detail, !detail.isEmpty { return detail }
        return "Radio na żywo"
    }

    var body: some View {
        ZStack {
            AnimatedBackground(isActive: true, player: true)
            VStack(spacing: 0) {
                Capsule()
                    .fill(ink.opacity(0.35))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                bigIcon
                liveBar
                    .padding(.top, 6)
                controls
                VolumeRow().padding(.bottom, 14)
                bottomRow
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showDevices) {
            DevicesSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    // MARK: Pieces

    private var bigIcon: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            RadioIcon(station: station, size: 310, radius: 22, active: engine.isPlaying)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .modifier(FloatMotion(enabled: engine.isPlaying))
                .scaleEffect(engine.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: engine.isPlaying)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 18))
                        .foregroundStyle(ink.opacity(0.6))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.3), value: title)
                moreMenu
            }
            Spacer(minLength: 0)
        }
    }

    private var sleepTitle: String {
        if let at = engine.sleepAt { return "Wyłącznik czasowy (do \(at.formatted(date: .omitted, time: .shortened)))" }
        return "Wyłącznik czasowy"
    }

    private var moreMenu: some View {
        Menu {
            Button { engine.redetectRadioSong() } label: {
                Label("Wykryj utwór ponownie", systemImage: "waveform.badge.magnifyingglass")
            }
            Menu {
                if engine.sleepAt != nil {
                    Button(role: .destructive) { engine.cancelSleepTimer() } label: { Label("Wyłącz", systemImage: "xmark") }
                }
                ForEach([15, 30, 60], id: \.self) { minutes in
                    Button { engine.setSleepTimer(minutes: minutes) } label: { Label("\(minutes) min", systemImage: "timer") }
                }
            } label: {
                Label(sleepTitle, systemImage: engine.sleepAt != nil ? "moon.zzz.fill" : "moon.zzz")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 48, height: 48)
                .glass(Circle(), interactive: true)
                .contentShape(Circle())
        }
    }

    /// W miejscu paska postępu: pełny pasek z napisem "NA ŻYWO" (transmisji nie da się przewijać).
    private var liveBar: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.25))
                Capsule().fill(accentInk.opacity(connecting ? 0.4 : 0.92))
            }
            .frame(height: 7)
            .frame(height: 44)
            .animation(.easeInOut(duration: 0.3), value: connecting)
            HStack(spacing: 6) {
                Circle().fill(connecting ? Color.orange : Color.red).frame(width: 8, height: 8)
                Text(connecting ? "ŁĄCZENIE…" : "NA ŻYWO")
                Spacer()
                if engine.radioSong != nil {
                    Text(stationName).lineLimit(1)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink.opacity(0.6))
        }
    }

    /// Te same przyciski co przy piosence (poprzednia / następna = poprzednia / następna stacja).
    private var controls: some View {
        HStack {
            Spacer()
            Button {
                prevTaps += 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                engine.previous()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).foregroundStyle(ink)
                    .symbolEffect(.bounce, value: prevTaps)
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                engine.togglePlayPause()
            } label: {
                ZStack {
                    if connecting && engine.isBuffering {
                        ProgressView().tint(accentInk).scaleEffect(1.4)
                    } else {
                        Image(systemName: engine.wantsPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 50)).foregroundStyle(ink)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 80, height: 80)
                .contentShape(Rectangle())
                .animation(.snappy(duration: 0.25), value: engine.wantsPlaying)
            }
            Spacer()
            Button {
                nextTaps += 1
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                engine.next()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 34)).foregroundStyle(ink)
                    .symbolEffect(.bounce, value: nextTaps)
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .buttonStyle(PressScaleStyle())
        .padding(.vertical, 4)
    }

    private var bottomRow: some View {
        HStack {
            Spacer()
            Button { engine.redetectRadioSong() } label: {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            .accessibilityLabel("Wykryj utwór ponownie")
            Spacer()
            Button { showDevices = true } label: {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            .accessibilityLabel("Głośniki i urządzenia")
            Spacer()
        }
    }
}
