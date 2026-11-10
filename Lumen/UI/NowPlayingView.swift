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
    /// Piosenka pokazana w nagłówku - zmiana (w withAnimation) uruchamia animację przełączenia. Odjeżdżająca
    /// piosenka zachowuje swój tytuł i okładkę do końca animacji.
    @State private var shownTrack: Track? = nil
    @State private var shownIndex = 0
    @State private var forward = true
    @State private var showQueue = false
    @State private var showAddToPlaylist = false
    @State private var showLyricsPicker = false
    @State private var showAudioEditor = false
    @State private var showDevices = false
    @State private var prevTaps = 0
    @State private var nextTaps = 0
    @State private var likeBursts = 0

    private var isFav: Bool { engine.currentTrack.map { library.isFavorite($0) } ?? false }

    /// Kolor "klimatu" piosenki z okładki (szara okładka = zwykły kolor tekstu).
    private var vibe: Color { engine.vibe.map { Color(uiColor: $0) } ?? ink }
    /// Własny kolor akcentu z Ustawień ma pierwszeństwo przed kolorem z okładki.
    private var progressTint: Color { settings.data.accentHex.isEmpty ? vibe : accentInk }

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
                    .environment(\.accentInk, progressTint)
                    .animation(.easeInOut(duration: 0.8), value: engine.vibe)
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
                shownTrack = engine.currentTrack
                shownIndex = engine.currentIndex ?? 0
            }
        }
        .onChange(of: engine.currentTrack?.id) { _, _ in
            showLyrics = true
            // Kierunek liczony tu (a nie w osobnym onChange), żeby zawsze był gotowy przed startem animacji:
            // następna z prawej, poprzednia z lewej.
            let index = engine.currentIndex ?? 0
            forward = index >= shownIndex
            shownIndex = index
            withAnimation(.smooth(duration: 0.4)) { shownTrack = engine.currentTrack }
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
        let dx: CGFloat = forward ? 30 : -30
        return .asymmetric(
            insertion: .modifier(active: SlideFade(x: dx, scale: 0.97, opacity: 0), identity: SlideFade(x: 0, scale: 1, opacity: 1)),
            removal: .modifier(active: SlideFade(x: -dx, scale: 0.97, opacity: 0), identity: SlideFade(x: 0, scale: 1, opacity: 1)))
    }

    private var shownID: String { shownTrack?.id ?? "" }

    private var header: some View {
        HStack(spacing: 14) {
            // ZStack: stara i nowa piosenka nakładają się w tym samym miejscu. (W HStack/VStack stały obok siebie
            // przez cały czas animacji, więc wszystko skakało.)
            ZStack(alignment: .leading) {
                HStack(spacing: 14) {
                    ArtworkView(size: 72, radius: 12, track: shownTrack)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        .shadow(color: vibe.opacity(engine.vibe == nil ? 0 : 0.5), radius: 16)
                    titleBlock(shownTrack)
                }
                .id(shownID)
                .transition(slide)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            moreMenu
        }
    }

    private func titleBlock(_ track: Track?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(track?.title ?? "Nic nie gra")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(2)
            Text(track?.artist ?? "")
                .font(.system(size: 18))
                .foregroundStyle(ink.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var bigArtwork: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ZStack {
                ArtworkView(size: 310, radius: 22, track: shownTrack)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    // Poświata w kolorze okładki - jakby okładka świeciła.
                    .shadow(color: vibe.opacity(engine.vibe == nil ? 0 : 0.55), radius: 40)
                    .id(shownID)
                    .transition(slide)
            }
            .modifier(FloatMotion(enabled: engine.isPlaying))
            .scaleEffect(engine.isPlaying ? 1 : 0.86)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: engine.isPlaying)
            HStack {
                ZStack(alignment: .leading) {
                    titleBlock(shownTrack)
                        .id(shownID)
                        .transition(slide)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    // Miękko pulsująca poświata w kolorze okładki, gdy muzyka gra.
                    PlayPulse(color: vibe, active: engine.isPlaying)
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
                    let liking = !library.isFavorite(t)
                    library.toggleFavorite(t)
                    if liking {
                        // Polubienie: serduszka wylatują w górę + "udało się" pod palcem.
                        likeBursts += 1
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
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
                    .overlay { HeartBurst(trigger: likeBursts) }
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

/// Miękka, oddychająca poświata pod przyciskiem play (w kolorze okładki), widoczna tylko gdy muzyka gra.
struct PlayPulse: View {
    let color: Color
    let active: Bool
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.4), color.opacity(0)],
                                 center: .center, startRadius: 6, endRadius: 56))
            .frame(width: 112, height: 112)
            .scaleEffect(active ? (breathe ? 1.12 : 0.9) : 0.6)
            .opacity(active ? 1 : 0)
            .animation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true), value: breathe)
            .animation(.easeOut(duration: 0.45), value: active)
            .onAppear { breathe = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Wybuch serduszek przy polubieniu piosenki: kilka serc wylatuje w górę i znika.
struct HeartBurst: View {
    let trigger: Int

    struct Particle: Identifiable {
        let id = UUID()
        let dx: CGFloat
        let rise: CGFloat
        let size: CGFloat
        let spin: Double
        let delay: Double
    }

    @State private var particles: [Particle] = []

    var body: some View {
        ZStack {
            ForEach(particles) { p in
                HeartParticle(p: p)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            particles = (0..<9).map { _ in
                Particle(dx: CGFloat.random(in: -44...44), rise: CGFloat.random(in: 55...120),
                         size: CGFloat.random(in: 9...19), spin: Double.random(in: -35...35),
                         delay: Double.random(in: 0...0.12))
            }
        }
    }
}

private struct HeartParticle: View {
    let p: HeartBurst.Particle
    @State private var flying = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: p.size, weight: .bold))
            .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.5), Color.red],
                                            startPoint: .top, endPoint: .bottom))
            .rotationEffect(.degrees(flying ? p.spin : 0))
            .scaleEffect(flying ? 1 : 0.3)
            .offset(x: flying ? p.dx : 0, y: flying ? -p.rise : 0)
            .opacity(flying ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.95).delay(p.delay)) { flying = true }
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
