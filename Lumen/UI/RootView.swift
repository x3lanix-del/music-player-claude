import SwiftUI

enum AppTab: Hashable { case home, library, radio, search, settings }

extension View {
    func pageVisible(_ visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .animation(.easeInOut(duration: 0.16), value: visible)
    }
}

struct RootView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var volume: VolumeController
    @State private var tab: AppTab = .home
    @State private var showNowPlaying = false
    @State private var showRadioPlayer = false
    @State private var showGuide = false
    @State private var librarySelected: UUID? = nil
    @StateObject private var searchModel = SearchModel()
    @StateObject private var homeModel = HomeModel()
    @StateObject private var radioStore = RadioStore()

    var body: some View {
        ZStack {
            AnimatedBackground(isActive: !showNowPlaying)
            pages
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            HiddenVolumeView(controller: volume)
                .frame(width: 1, height: 1)
                .offset(x: -3000, y: -3000)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .onAppear {
            engine.setPlayback(rate: settings.data.playbackRate, keepPitch: settings.data.keepPitch)
            if !settings.data.guideSeen { showGuide = true }
        }
        .sheet(isPresented: $showGuide, onDismiss: { settings.data.guideSeen = true }) {
            GuideView { showGuide = false }
                .preferredColorScheme(settings.colorScheme)
        }
        .onOpenURL { url in
            let text = url.absoluteString
            if let code = PlaylistServer.code(in: text) {
                Task {
                    if let r = try? await PlaylistServer.fetch(code: code) { addShared(name: r.name, tracks: r.tracks, cover: r.cover) }
                    else { toast.show("Nie udało się pobrać playlisty.") }
                }
            } else if let shared = PlaylistShare.decode(text) {
                addShared(name: shared.name, tracks: shared.tracks, cover: nil)
            }
        }
        .overlay(alignment: .top) { toastView }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: toast.message)
        .sheet(isPresented: $showRadioPlayer) {
            RadioNowPlayingView()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(toast)
                .environmentObject(volume)
                .preferredColorScheme(settings.colorScheme)
                .tint(settings.readableTint)
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(toast)
                .environmentObject(volume)
                .preferredColorScheme(settings.colorScheme)
                .tint(settings.readableTint)
        }
    }

    /// Link do playlisty od znajomego (musicplayer://playlist?d=…) otwarty z wiadomości: od razu trafia do biblioteki.
    private func addShared(name: String, tracks: [Track], cover: Data?) {
        let p = library.create(name: name, tracks: tracks, coverData: cover)
        DownloadMonitor.shared.enqueue(p.tracks.map { $0.id })
        tab = .library
        toast.show("Dodano playlistę \"\(p.name)\" (\(Pl.songs(p.tracks.count))). Pobieram piosenki w tle.")
    }

    /// All pages stay alive and only the active one is visible and touchable.
    /// (Rebuilding a page on every tab switch was what made switching tabs lag.)
    private var pages: some View {
        ZStack {
            HomeView(model: homeModel)
                .pageVisible(tab == .home)
            LibraryRootView(selected: $librarySelected)
                .pageVisible(tab == .library)
            RadioView(store: radioStore, isVisible: tab == .radio, openPlayer: { showRadioPlayer = true })
                .pageVisible(tab == .radio)
            SearchView(model: searchModel)
                .pageVisible(tab == .search)
            SettingsView()
                .pageVisible(tab == .settings)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if engine.currentTrack != nil {
                // Radio ma własny ekran odtwarzacza (stacja, grany utwór, tekst).
                MiniPlayerBar { if engine.isRadio { showRadioPlayer = true } else { showNowPlaying = true } }
            }
            tabBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var tabBar: some View {
        LiquidTabBar(selection: $tab)
    }

    @ViewBuilder
    private var toastView: some View {
        if let message = toast.message {
            Text(message)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glass(Capsule())
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct MiniPlayerBar: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    let open: () -> Void
    @State private var nextTaps = 0

    var body: some View {
        if let t = engine.currentTrack {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    if t.isRadio {
                        RadioIcon(station: engine.currentStation, size: 44, radius: 10, active: engine.isPlaying)
                    } else {
                        ArtworkView(size: 44, radius: 10)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        // Radio: ikona stacji, a obok tytuł grającego utworu (jeśli stacja go podaje).
                        Text(t.isRadio ? (engine.radioSong?.title ?? t.title) : t.title)
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                        Text(t.isRadio
                             ? (engine.radioSong.map { $0.artist.isEmpty ? t.title : "\($0.artist) · \(t.title)" } ?? "Radio · na żywo")
                             : t.artist)
                            .font(.system(size: 12)).foregroundStyle(ink.opacity(0.65)).lineLimit(1)
                    }
                    // Nowa piosenka: tytuł płynnie się przenika (bez wjeżdżania).
                    .id(t.id)
                    .transition(.opacity)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: open)

                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.wantsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ink)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .animation(.snappy(duration: 0.25), value: engine.wantsPlaying)

                Button {
                    nextTaps += 1
                    engine.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ink)
                        .symbolEffect(.bounce, value: nextTaps)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if !t.isRadio {
                    MiniProgress(clock: engine.clock)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 3)
                }
            }
            .glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .animation(.smooth(duration: 0.45), value: t.id)
        }
    }
}

/// Cienki pasek postępu piosenki na dole mini-odtwarzacza (osobny widok, żeby tykanie zegara nie
/// przerysowywało całego paska).
private struct MiniProgress: View {
    @Environment(\.ink) private var ink
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { geo in
            let f = clock.duration > 0 ? min(max(clock.time / clock.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.12))
                Capsule().fill(ink.opacity(0.55))
                    .frame(width: geo.size.width * CGFloat(f))
            }
        }
        .frame(height: 2.5)
        .allowsHitTesting(false)
    }
}

struct ArtworkView: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    var size: CGFloat
    var radius: CGFloat
    /// Okładka tej konkretnej piosenki (np. tej, która odjeżdża w animacji przejścia). nil = piosenka, która gra.
    var track: Track? = nil

    var body: some View {
        let shown = track ?? engine.currentTrack
        Group {
            if let t = shown, let img = image(for: t) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if let t = shown {
                TrackThumb(track: t, size: size)
            } else {
                Rectangle().fill(ink.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Duża okładka: ta z odtwarzacza, gdy należy do tej piosenki, albo od razu z pamięci (bez mignięcia miniaturką).
    private func image(for t: Track) -> UIImage? {
        if engine.artworkTrackID == t.id, let img = engine.artwork { return img }
        if t.isRadio { return engine.currentTrack?.id == t.id ? engine.artwork : nil }
        return ArtworkLoader.shared.cached(t.id)
    }
}
