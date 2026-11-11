import SwiftUI

/// Search state lives outside the view so it survives switching tabs.
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Track] = []
    @Published var loading = false
    @Published var message: String? = nil
    @Published var suggestions: [String] = []
}

struct SearchView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @ObservedObject var model: SearchModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @State private var batch: TrackBatch? = nil
    @State private var showImport = false
    @FocusState private var focused: Bool

    private var isLink: Bool { YouTubeURL.parse(model.query) != nil || ExternalImport.detect(model.query) }
    @State private var showRecognize = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Szukaj")
            searchField
                .tourTarget(.searchField)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            if focused, !model.suggestions.isEmpty, !isLink {
                suggestionList
            }

            Button { showRecognize = true } label: {
                Label("Rozpoznaj piosenkę", systemImage: "waveform.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .glass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .tourTarget(.recognize)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if isLink {
                Button { showImport = true } label: {
                    Label("Importuj ten link", systemImage: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .glass(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Group {
            if model.loading {
                ProgressView().tint(accentInk).padding(.top, 40)
                Spacer()
            } else if model.results.isEmpty {
                ScrollView {
                    EmptyHint(icon: "magnifyingglass",
                              title: model.message ?? "Szukaj",
                              message: model.message == nil ? "Wpisz piosenkę lub wykonawcę albo wklej link." : "")
                        .padding(.top, 50)
                }
            } else {
                List {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, t in
                        TrackRow(track: t,
                                 isCurrent: engine.currentTrack?.id == t.id,
                                 onPlay: { engine.play(model.results, startAt: index) },
                                 onAddToPlaylist: { batch = TrackBatch(tracks: [t]) })
                            .listRowBackground(CurrentRowBackground(active: engine.currentTrack?.id == t.id))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Pierwsze wyniki dostają adres strumienia z wyprzedzeniem - po dotknięciu grają od razu.
                .onAppear { PlaybackPrewarm.warm(model.results) }
                .onChange(of: model.results.map { $0.id }) { _, _ in PlaybackPrewarm.warm(model.results) }
            }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .animation(.easeInOut(duration: 0.28), value: model.results.count)
            .animation(.easeInOut(duration: 0.28), value: model.loading)
        }
        .sheet(item: $batch) { b in
            AddToPlaylistSheet(tracks: b.tracks)
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showRecognize) {
            RecognizeSheet()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showImport) {
            ImportView(initialText: model.query)
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(ink.opacity(0.7))
            ZStack(alignment: .leading) {
                TextField("Szukaj", text: $model.query, prompt: Text(""))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .foregroundStyle(ink)
                    .onSubmit { runSearch() }
                // Animacja pisania zamiast zwykłego tekstu podpowiedzi.
                if model.query.isEmpty {
                    TypingPlaceholder(phrases: ["Szukaj piosenek…", "Wpisz wykonawcę…", "Wklej link…"])
                        .transition(.opacity)
                }
            }
            if !model.query.isEmpty {
                Button {
                    // Czyszczenie z animacją: przycisk znika, a wyniki płynnie się wygaszają.
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        model.query = ""
                        model.message = nil
                        model.results = []
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ink.opacity(0.6))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.query.isEmpty)
        .glass(Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .task(id: model.query) { await loadSuggestions(for: model.query) }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.suggestions, id: \.self) { text in
                Button {
                    model.query = text
                    model.suggestions = []
                    runSearch()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(ink.opacity(0.5))
                        Text(text).font(.system(size: 16)).foregroundStyle(ink).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(radius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func loadSuggestions(for text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLink, q.count >= 2 else {
            model.suggestions = []
            return
        }
        // Krótka zwłoka: podpowiedzi dla każdej literki byłyby marnotrawstwem.
        try? await Task.sleep(nanoseconds: 280_000_000)
        if Task.isCancelled { return }
        let found = await YTMusicSearch.suggestions(q)
        if Task.isCancelled { return }
        model.suggestions = found
    }

    private func runSearch() {
        let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if isLink { showImport = true; return }
        model.suggestions = []
        focused = false
        model.loading = true
        model.message = nil
        Task {
            do {
                let found = try await YTMusicSearch.search(q)
                model.results = found
                if found.isEmpty { model.message = "Brak wyników" }
            } catch {
                model.results = []
                model.message = "Wyszukiwanie w YouTube Music nie zadziałało. Sprawdź internet i spróbuj ponownie."
            }
            model.loading = false
        }
    }
}

/// Prosta animacja pisania: tekst podpowiedzi "wpisuje się" literka po literce, chwilę trwa i się wymazuje.
struct TypingPlaceholder: View {
    @Environment(\.ink) private var ink
    let phrases: [String]
    @State private var shown = ""
    @State private var caretOn = true

    var body: some View {
        (Text(shown) + Text("\u{258F}").foregroundColor(caretOn ? ink.opacity(0.6) : .clear))
            .foregroundColor(ink.opacity(0.5))
            .lineLimit(1)
            .allowsHitTesting(false)
            .task { await type() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    caretOn.toggle()
                }
            }
    }

    private func type() async {
        guard !phrases.isEmpty else { return }
        var i = 0
        while !Task.isCancelled {
            let phrase = phrases[i % phrases.count]
            for ch in phrase {
                shown.append(ch)
                try? await Task.sleep(nanoseconds: 70_000_000)
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            while !shown.isEmpty {
                shown.removeLast()
                try? await Task.sleep(nanoseconds: 30_000_000)
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            i += 1
        }
    }
}
