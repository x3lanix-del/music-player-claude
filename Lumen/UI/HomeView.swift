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
                        .foregroundStyle(ink.opacity(0.65))
                        .padding(.horizontal, 20)
                        .padding(.top, -10)

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
                        Text("\(index + 1)")
                            .font(.system(size: 15, weight: .bold).monospacedDigit())
                            .foregroundStyle(ink.opacity(index < 3 ? 0.9 : 0.5))
                            .frame(width: 26)
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
