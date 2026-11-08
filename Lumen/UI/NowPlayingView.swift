import SwiftUI

struct BarSlider: View {
    @Environment(\.accentInk) private var accentInk
    @Environment(\.ink) private var ink
    let value: Double   // 0...1
    var onChanged: (Double) -> Void
    var onEnded: (Double) -> Void = { _ in }
    @State private var dragging = false

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(max(x / max(width, 1), 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(0.25))
                Capsule().fill(accentInk.opacity(0.92))
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(value, 0), 1))))
            }
            .frame(height: dragging ? 12 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        onChanged(fraction(g.location.x, geo.size.width))
                    }
                    .onEnded { g in
                        dragging = false
                        onEnded(fraction(g.location.x, geo.size.width))
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 44)
    }
}

struct ProgressSection: View {
    @Environment(\.ink) private var ink
    @ObservedObject var clock: PlaybackClock
    let seek: (Double) -> Void
    @State private var dragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        let duration = max(clock.duration, 0.01)
        let shown = dragging ? dragValue : min(clock.time, duration)
        VStack(spacing: 2) {
            BarSlider(value: shown / duration, onChanged: { f in
                dragging = true
                dragValue = f * duration
            }, onEnded: { f in
                seek(f * duration)
                dragging = false
            })
            HStack {
                Text(Fmt.time(shown))
                Spacer()
                Text("-" + Fmt.time(max(duration - shown, 0)))
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(ink.opacity(0.6))
        }
    }
}

struct VolumeRow: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var volume: VolumeController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 12)).foregroundStyle(ink.opacity(0.7))
            BarSlider(value: Double(volume.level), onChanged: { f in volume.set(Float(f)) })
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).foregroundStyle(ink.opacity(0.7))
        }
    }
}

struct NowPlayingView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @EnvironmentObject var volume: VolumeController
    @State private var showLyrics = true
    /// Identyfikator piosenki pokazanej w widoku - zmiana (w withAnimation) uruchamia animację przełączenia.
    @State private var shownTrackID: String = ""
    @State private var forward = true
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var showLyricsPicker = false
    @State private var showAudioEditor = false
    @State private var showDevices = false
    @State private var prevTaps = 0
    @State private var nextTaps = 0

    private var isFav: Bool { engine.currentTrack.map { library.isFavorite($0) } ?? false }

    var body: some View {
        ZStack {
            AnimatedBackground(player: true)
            VStack(spacing: 0) {
                Capsule()
                    .fill(ink.opacity(0.35))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                if showLyrics {
                    header
                    LyricsView(lyrics: engine.lyrics)
                        .padding(.top, 6)
                } else {
                    bigArtwork
                }

                ProgressSection(clock: engine.clock, seek: { engine.seek(to: $0) })
                    .padding(.top, 6)
                controls
                VolumeRow().padding(.bottom, 14)
                bottomRow
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
        }
        // Teksty mają być widoczne od razu po wejściu w piosenkę i po zmianie piosenki (bez klikania).
        .onAppear {
            // Wejście w ekran piosenki ma być bez animacji (żadnych wjeżdżających pustych pól).
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                showLyrics = true
                shownTrackID = engine.currentTrack?.id ?? ""
            }
        }
        .onChange(of: engine.currentIndex) { old, new in
            forward = (new ?? 0) >= (old ?? 0)     // kierunek animacji: następna z prawej, poprzednia z lewej
        }
        .onChange(of: engine.currentTrack?.id) { _, new in
            showLyrics = true
            withAnimation(.smooth(duration: 0.55)) { shownTrackID = new ?? "" }
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showDevices) {
            DevicesSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showAudioEditor) {
            AudioEditorSheet()
                .environmentObject(engine)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showLyricsPicker) {
            LyricsPickerSheet()
                .environmentObject(engine)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(tracks: engine.currentTrack.map { [$0] } ?? [])
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    // MARK: Pieces

    /// Okładka i tytuł wjeżdżają z boku (następna piosenka z prawej, poprzednia z lewej) i wygaszają poprzednią.
    private var slide: AnyTransition {
        // Delikatne przesunięcie (nie przez cały ekran) + zanikanie i lekka skala: znacznie spokojniejsze niż wjazd z krawędzi.
        let dx: CGFloat = forward ? 44 : -44
        return .asymmetric(
            insertion: .modifier(active: SlideFade(x: dx, scale: 0.94, opacity: 0), identity: SlideFade(x: 0, scale: 1, opacity: 1)),
            removal: .modifier(active: SlideFade(x: -dx, scale: 0.94, opacity: 0), identity: SlideFade(x: 0, scale: 1, opacity: 1)))
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                ArtworkView(size: 72, radius: 12)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                titleBlock
            }
            .id(shownTrackID)
            .transition(slide)
            Spacer(minLength: 8)
            moreMenu
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(engine.currentTrack?.title ?? "Nic nie gra")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(2)
            Text(engine.currentTrack?.artist ?? "")
                .font(.system(size: 18))
                .foregroundStyle(ink.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var bigArtwork: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ArtworkView(size: 310, radius: 22)
                .modifier(FloatMotion(enabled: engine.isPlaying))
                .scaleEffect(engine.isPlaying ? 1 : 0.86)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.75), value: engine.isPlaying)
                .id(shownTrackID)
                .transition(slide)
            HStack {
                titleBlock
                    .id(shownTrackID)
                    .transition(slide)
                Spacer(minLength: 8)
                moreMenu
            }
            Spacer(minLength: 0)
        }
    }

    private var moreMenu: some View {
        Menu {
            // Krótko: tylko najważniejsze (przewijanie jest na pasku postępu, tłumaczenie w "Tekst piosenki").
            Button { showAddToPlaylist = true } label: { Label("Dodaj do playlisty…", systemImage: "plus") }
            lyricsMenu
            sleepMenu
            Button { showAudioEditor = true } label: { Label("Edytor dźwięku…", systemImage: "slider.horizontal.3") }
            if let t = engine.currentTrack {
                ShareLink(item: t.watchURL) { Label("Udostępnij", systemImage: "square.and.arrow.up") }
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

    /// Wszystko o tekście w jednym podmenu: inna wersja, ręczne przesunięcie, szukanie od nowa.
    private var lyricsMenu: some View {
        Menu {
            Button { showLyricsPicker = true } label: { Label("Inna wersja tekstu…", systemImage: "text.badge.checkmark") }
            Button { engine.adjustLyricsOffset(by: 0.25) } label: { Label("Tekst wcześniej", systemImage: "backward") }
            Button { engine.adjustLyricsOffset(by: -0.25) } label: { Label("Tekst później", systemImage: "forward") }
            Button { settings.data.translateLyrics.toggle() } label: {
                Label(settings.data.translateLyrics ? "Wyłącz tłumaczenie" : "Tłumacz tekst", systemImage: "character.bubble")
            }
        } label: {
            Label("Tekst piosenki", systemImage: "quote.bubble")
        }
    }

    private var sleepActive: Bool { engine.sleepAt != nil || engine.sleepAfterTrack }

    private var sleepTitle: String {
        if let at = engine.sleepAt { return "Wyłącznik czasowy (do \(at.formatted(date: .omitted, time: .shortened)))" }
        if engine.sleepAfterTrack { return "Wyłącznik czasowy (po piosence)" }
        return "Wyłącznik czasowy"
    }

    /// Muzyka sama ścichnie i zatrzyma się po wybranym czasie (np. przy zasypianiu).
    private var sleepMenu: some View {
        Menu {
            if sleepActive {
                Button(role: .destructive) { engine.cancelSleepTimer() } label: { Label("Wyłącz", systemImage: "xmark") }
            }
            ForEach([15, 30, 60], id: \.self) { minutes in
                Button { engine.setSleepTimer(minutes: minutes) } label: { Label("\(minutes) min", systemImage: "timer") }
            }
            Button { engine.setSleepAfterTrack() } label: { Label("Po tej piosence", systemImage: "music.note") }
        } label: {
            Label(sleepTitle, systemImage: sleepActive ? "moon.zzz.fill" : "moon.zzz")
        }
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button {
                prevTaps += 1
                engine.previous()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).foregroundStyle(ink)
                    .symbolEffect(.bounce, value: prevTaps)
                    .frame(width: 70, height: 70)
                    .contentShape(Rectangle())
            }
            Spacer()
            Button { engine.togglePlayPause() } label: {
                ZStack {
                    if engine.wantsPlaying && engine.isBuffering && !engine.isPlaying {
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
            Button { withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() } } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
                    .overlay(Circle().stroke(accentInk.opacity(showLyrics ? 0.8 : 0), lineWidth: 1.5))
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            Spacer()
            Button {
                if let t = engine.currentTrack {
                    library.toggleFavorite(t)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } label: {
                Image(systemName: isFav ? "heart.fill" : "heart")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(isFav ? Color.red : ink)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isFav)
                    .animation(.snappy(duration: 0.3), value: isFav)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button { showDevices = true } label: {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: 52, height: 52)
                    .glass(Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Queue

struct QueueSheet: View {
    @Environment(\.accentInk) private var accentInk
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Button { engine.toggleShuffle() } label: {
                            Label("Losowo", systemImage: "shuffle")
                        }
                        .buttonStyle(.bordered)
                        .tint(engine.shuffle ? settings.readableTint : Color.gray)
                        Button { engine.cycleRepeat() } label: {
                            Label(repeatTitle, systemImage: engine.repeatMode == .one ? "repeat.1" : "repeat")
                        }
                        .buttonStyle(.bordered)
                        .tint(engine.repeatMode == .off ? Color.gray : settings.readableTint)
                    }
                }
                Section("Następne") {
                    ForEach(Array(engine.queue.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track, isCurrent: index == engine.currentIndex, onPlay: { engine.jump(to: index) })
                    }
                    .onDelete { engine.removeFromQueue(at: $0) }
                }
            }
            .navigationTitle("Kolejka")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var repeatTitle: String {
        switch engine.repeatMode {
        case .off: return "Powtarzaj"
        case .all: return "Powtarzaj wszystko"
        case .one: return "Powtarzaj jedną"
        }
    }
}

/// Przycisk lekko się zmniejsza pod palcem i sprężyście wraca (jak w aplikacjach Apple).
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.86

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct SlideFade: ViewModifier {
    var x: CGFloat
    var scale: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.offset(x: x).scaleEffect(scale).opacity(opacity)
    }
}
