import SwiftUI

// MARK: - Dane zakładki Główna

/// Listy „Na czasie” z YouTube (najpopularniejsze teraz teledyski muzyczne). Zapisane na dysku, więc po otwarciu
/// aplikacji są od razu (także bez internetu), a odświeżają się w tle co kilka godzin.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var poland: [Track] = []
    @Published private(set) var world: [Track] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String? = nil
    private var loadedAt: Date? = nil

    private struct Cache: Codable {
        var poland: [Track]
        var world: [Track]
        var date: Date
    }

    private static let cacheKey = "lumen.trending.v1"
    private static let maxAge: TimeInterval = 3 * 3600

    init() {
        if let data = UserDefaults.standard.data(forKey: HomeModel.cacheKey),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            poland = cache.poland
            world = cache.world
            loadedAt = cache.date
        }
    }

    func refresh(api: YouTubeAPI, force: Bool = false) async {
        if !force, let date = loadedAt, Date().timeIntervalSince(date) < HomeModel.maxAge, !poland.isEmpty { return }
        guard api.hasKey else {
            if poland.isEmpty { message = "Lista „Na czasie” wymaga klucza YouTube API." }
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let pl = api.trendingMusic(region: "PL")
            async let us = api.trendingMusic(region: "US")
            let (a, b) = try await (pl, us)
            withAnimation(.easeInOut(duration: 0.3)) {
                poland = a
                world = b
            }
            loadedAt = Date()
            message = nil
            if let data = try? JSONEncoder().encode(Cache(poland: a, world: b, date: Date())) {
                UserDefaults.standard.set(data, forKey: HomeModel.cacheKey)
            }
        } catch {
            // Gdy już coś mamy (z dysku), zostaje - komunikat tylko przy pustej liście.
            if poland.isEmpty { message = error.localizedDescription }
        }
    }
}

// MARK: - Zakładka Główna

struct HomeView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @ObservedObject var model: HomeModel
    @State private var batch: TrackBatch? = nil
    @State private var diceRolls = 0

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Dzień dobry"
        case 12..<18: return "Miłego popołudnia"
        case 18..<23: return "Dobry wieczór"
        default: return "Dobrej nocy"
        }
    }

    private var topPoland: [Track] { Array(model.poland.prefix(20)) }
    private var recent: [Track] { Array(engine.recent.prefix(15)) }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Główna")
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    Text(greeting)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [vibe, ink.opacity(0.65)],
                                                        startPoint: .leading, endPoint: .trailing))
                        .padding(.horizontal, 20)
                        .padding(.top, -10)
                        .animation(.easeInOut(duration: 0.8), value: engine.vibe)

                    surpriseButton
                        .padding(.horizontal, 20)

                    if !recent.isEmpty {
                        section("Ostatnio grane", icon: "clock.arrow.circlepath") { cards(recent) }
                    }
                    section("Na czasie w Polsce", icon: "flame") { ranked(topPoland) }
                    if !model.world.isEmpty {
                        section("Na czasie na świecie", icon: "globe") { cards(model.world) }
                    }
                    Spacer().frame(height: 16)
                }
                .padding(.top, 4)
            }
            .refreshable { await model.refresh(api: settings.api, force: true) }
        }
        .task { await model.refresh(api: settings.api) }
        .onAppear { warm() }
        .onChange(of: model.poland.map { $0.id }) { _, _ in warm() }
        .sheet(item: $batch) { b in
            AddToPlaylistSheet(tracks: b.tracks)
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    /// Kolor grającej piosenki (z okładki), a gdy nic nie gra / okładka szara - zwykły kolor tekstu.
    private var vibe: Color { engine.vibe.map { Color(uiColor: $0) } ?? ink }

    /// Wszystko, z czego da się ułożyć losowy miks: ostatnio grane, ulubione i listy "na czasie" (bez powtórzeń).
    private var mixPool: [Track] {
        let favorites = library.playlist(LibraryStore.favoritesID)?.tracks ?? []
        var seen = Set<String>()
        return (engine.recent + favorites + model.poland + model.world).filter { seen.insert($0.id).inserted }
    }

    /// „Zaskocz mnie”: losowy miks 30 piosenek, kostka się turla, telefon "klika".
    private var surpriseButton: some View {
        Button {
            let pool = mixPool
            guard !pool.isEmpty else {
                toast.show("Najpierw posłuchaj czegoś albo przeciągnij w dół, żeby wczytać listy.")
                return
            }
            diceRolls += 1
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            engine.play(Array(pool.shuffled().prefix(30)), startAt: 0)
            toast.show("Losowy miks: \(Pl.songs(min(pool.count, 30)))")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "dice.fill")
                    .font(.system(size: 22, weight: .bold))
                    .rotationEffect(.degrees(Double(diceRolls) * 360))
                    .animation(.spring(response: 0.6, dampingFraction: 0.55), value: diceRolls)
                    .symbolEffect(.bounce, value: diceRolls)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Zaskocz mnie")
                        .font(.system(size: 17, weight: .bold))
                    Text("Losowy miks z tego, co lubisz i co jest na czasie")
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                LinearGradient(colors: [vibe.opacity(0.35), vibe.opacity(0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
            .animation(.easeInOut(duration: 0.8), value: engine.vibe)
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
    }

    /// Medale dla podium listy "na czasie".
    private func rankColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 1.0, green: 0.8, blue: 0.25)
        case 1: return Color(red: 0.82, green: 0.85, blue: 0.9)
        case 2: return Color(red: 0.86, green: 0.55, blue: 0.3)
        default: return ink.opacity(0.5)
        }
    }

    /// Pierwsze piosenki z list dostają adres strumienia z wyprzedzeniem - po dotknięciu grają od razu.
    private func warm() {
        PlaybackPrewarm.warm(Array(recent.prefix(2)) + Array(topPoland.prefix(3)), limit: 4)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(ink)
                .padding(.horizontal, 20)
            content()
        }
    }

    /// Poziomy pasek okładek (jak w Apple Music).
    private func cards(_ tracks: [Track]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, t in
                    Button {
                        engine.play(tracks, startAt: index)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            TrackThumb(track: t, size: 140, cornerRadius: 16)
                                .overlay(alignment: .bottomTrailing) {
                                    if engine.currentTrack?.id == t.id {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(ink)
                                            .padding(7)
                                            .glass(Circle())
                                            .padding(8)
                                    }
                                }
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                            Text(t.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(t.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(ink.opacity(0.6))
                                .lineLimit(1)
                        }
                        .frame(width: 140, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle(scale: 0.95))
                    .contextMenu {
                        Button { engine.enqueueNext(t) } label: { Label("Odtwórz jako następną", systemImage: "text.insert") }
                        Button { engine.enqueueLast(t) } label: { Label("Dodaj do kolejki", systemImage: "text.append") }
                        Button { batch = TrackBatch(tracks: [t]) } label: { Label("Dodaj do playlisty…", systemImage: "plus") }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    /// Ponumerowana lista (top 20).
    @ViewBuilder private func ranked(_ tracks: [Track]) -> some View {
        if tracks.isEmpty {
            HStack(spacing: 10) {
                if model.loading {
                    ProgressView().tint(accentInk)
                    Text("Wczytuję listę…")
                } else {
                    Image(systemName: "wifi.exclamationmark")
                    Text(model.message ?? "Nie udało się wczytać listy. Przeciągnij w dół, żeby spróbować ponownie.")
                }
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(ink.opacity(0.7))
            .padding(.horizontal, 20)
        } else {
            VStack(spacing: 4) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, t in
                    HStack(spacing: 8) {
                        VStack(spacing: 0) {
                            if index == 0 {
                                Image(systemName: "crown.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(rankColor(0))
                            }
                            Text("\(index + 1)")
                                .font(.system(size: index < 3 ? 18 : 15, weight: .heavy).monospacedDigit())
                                .foregroundStyle(rankColor(index))
                                .shadow(color: index < 3 ? rankColor(index).opacity(0.6) : .clear, radius: 6)
                        }
                        .frame(width: 28)
                        TrackRow(track: t,
                                 isCurrent: engine.currentTrack?.id == t.id,
                                 onPlay: { engine.play(tracks, startAt: index) },
                                 onAddToPlaylist: { batch = TrackBatch(tracks: [t]) })
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
        }
    }
}
