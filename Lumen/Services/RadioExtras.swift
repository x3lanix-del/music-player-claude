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

struct RadioNowPlayingView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @State private var showDevices = false
    @State private var showLyrics = true

    private var station: RadioStation? { engine.currentStation }
    /// Stacja jeszcze się łączy (nic jeszcze nie zagrało).
    private var connecting: Bool { engine.wantsPlaying && !engine.isPlaying }

    var body: some View {
        ZStack {
            AnimatedBackground(isActive: true, player: true)
            VStack(spacing: 14) {
                Capsule().fill(ink.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)

                header
                songCard
                lyricsArea
                liveBar
                VolumeRow()
                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 14)
        }
        .sheet(isPresented: $showDevices) {
            DevicesSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            RadioIcon(station: station, size: 68, radius: 16, active: engine.isPlaying)
            VStack(alignment: .leading, spacing: 5) {
                Text(station?.name ?? engine.currentTrack?.title ?? "Radio")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(connecting ? Color.orange : Color.red).frame(width: 8, height: 8)
                    Text(connecting ? "Łączenie…" : "NA ŻYWO")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ink.opacity(0.75))
                    if let d = station?.detail, !d.isEmpty {
                        Text("· \(d)")
                            .font(.system(size: 12))
                            .foregroundStyle(ink.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Button { showDevices = true } label: {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 46, height: 46)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            moreMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moreMenu: some View {
        Menu {
            Button { withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() } } label: {
                Label(showLyrics ? "Ukryj tekst" : "Pokaż tekst", systemImage: showLyrics ? "eye.slash" : "quote.bubble")
            }
            Button { engine.redetectRadioSong() } label: { Label("Wykryj utwór ponownie", systemImage: "waveform.badge.magnifyingglass") }
            if engine.radioSong != nil && engine.radioPositionKnown {
                Button { engine.nudgeRadioLyrics(by: 0.5) } label: { Label("Tekst wcześniej (+0,5 s)", systemImage: "arrow.up") }
                Button { engine.nudgeRadioLyrics(by: -0.5) } label: { Label("Tekst później (−0,5 s)", systemImage: "arrow.down") }
            }
            Button { settings.data.translateLyrics.toggle() } label: {
                Label(settings.data.translateLyrics ? "Wyłącz tłumaczenie tekstu" : "Tłumacz tekst", systemImage: "character.bubble")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 46, height: 46)
                .glass(Circle(), interactive: true)
                .contentShape(Circle())
        }
    }

    private var songCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TERAZ GRA")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ink.opacity(0.55))
            if connecting && engine.radioSong == nil {
                HStack(spacing: 10) {
                    ProgressView().tint(accentInk)
                    Text("Łączenie ze stacją…")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.85))
                }
            } else if let s = engine.radioSong {
                Text(s.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                if !s.artist.isEmpty {
                    Text(s.artist)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(ink.opacity(0.75))
                        .lineLimit(1)
                }
            } else if engine.radioDetecting {
                HStack(spacing: 10) {
                    ProgressView().tint(accentInk)
                    Text("Wykrywam utwór…")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.85))
                }
            } else {
                Text("Brak informacji o utworze")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.8))
                Text("Stacja nie podaje tytułów albo leci wstawka (reklama, wiadomości).")
                    .font(.system(size: 13))
                    .foregroundStyle(ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Brak tekstu (albo ukryty / nie wiadomo, co gra): jak przy piosence bez tekstu - duża ikona stacji.
    private var noLyrics: Bool {
        if engine.radioSong == nil || !showLyrics { return true }
        switch engine.lyrics.phase {
        case .notFound, .instrumental, .offline: return true
        default: return false
        }
    }

    @ViewBuilder private var lyricsArea: some View {
        Group {
            if noLyrics {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RadioIcon(station: station, size: 270, radius: 30, active: engine.isPlaying)
                        .shadow(color: .black.opacity(0.35), radius: 22, y: 10)
                        .scaleEffect(engine.isPlaying ? 1 : 0.88)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: engine.isPlaying)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                LyricsView(lyrics: engine.lyrics)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Pasek jak przy piosence, ale pełny i z napisem "NA ŻYWO" (transmisji nie da się przewijać).
    private var liveBar: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.25))
                Capsule().fill(accentInk.opacity(connecting ? 0.4 : 0.92))
            }
            .frame(height: 7)
            HStack(spacing: 6) {
                Circle().fill(connecting ? Color.orange : Color.red).frame(width: 8, height: 8)
                Text(connecting ? "ŁĄCZENIE…" : "NA ŻYWO")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ink.opacity(0.75))
                Spacer()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 36) {
            Button { engine.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ink).frame(width: 64, height: 64).contentShape(Rectangle())
            }
            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.wantsPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(ink)
                    .frame(width: 78, height: 78)
                    .glass(Circle(), interactive: true)
            }
            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ink).frame(width: 64, height: 64).contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}
