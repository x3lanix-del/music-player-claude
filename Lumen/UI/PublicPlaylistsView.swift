import SwiftUI

/// Biblioteka playlist: publiczne playlisty opublikowane przez użytkowników aplikacji (z serwera).
struct PublicPlaylistsView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var items: [PlaylistServer.Item] = []
    @State private var loading = false
    @State private var error: String? = nil
    @State private var busyCode: String? = nil
    @State private var detail: PlaylistServer.Item? = nil

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Spróbuj ponownie") { Task { await load() } }
                } else if loading && items.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if items.isEmpty {
                    Text(query.isEmpty ? "Nikt jeszcze nie opublikował playlisty publicznie." : "Brak wyników.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        // Kliknięcie w playlistę otwiera podgląd z listą piosenek.
                        Button { detail = item } label: {
                            HStack(spacing: 12) {
                                cover(item)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                                    Text(Pl.songs(item.count) + " · \(item.views) wyśw.")
                                        .font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                            }
                            .foregroundStyle(.primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        if busyCode == item.code {
                            ProgressView()
                        } else {
                            Button { Task { await play(item) } } label: {
                                Image(systemName: "play.fill").frame(width: 38, height: 38)
                            }
                            .buttonStyle(.borderless)
                            Button { Task { await add(item) } } label: {
                                Image(systemName: "plus.circle").frame(width: 38, height: 38)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Szukaj playlist")
            .onSubmit(of: .search) { Task { await load() } }
            .navigationTitle("Biblioteka playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .navigationDestination(item: $detail) { item in
                PublicPlaylistDetailView(item: item)
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func cover(_ item: PlaylistServer.Item) -> some View {
        if let data = item.cover, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            thumbCover(item)
        }
    }

    private func thumbCover(_ item: PlaylistServer.Item) -> some View {
        AsyncImage(url: item.preview.first.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.25)
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func load() async {
        loading = true
        error = nil
        do { items = try await PlaylistServer.list(query: query) }
        catch let err { error = err.localizedDescription }
        loading = false
    }

    private func add(_ item: PlaylistServer.Item) async {
        busyCode = item.code
        defer { busyCode = nil }
        do {
            guard let r = try await PlaylistServer.fetch(code: item.code) else { toast.show("Nie znaleziono playlisty."); return }
            let p = library.create(name: r.name, tracks: r.tracks, coverData: r.cover)
            DownloadMonitor.shared.enqueue(p.tracks.map { $0.id })
            toast.show("Dodano \"\(p.name)\" do biblioteki. Pobieram piosenki w tle.")
        } catch let err {
            toast.show(err.localizedDescription)
        }
    }

    private func play(_ item: PlaylistServer.Item) async {
        busyCode = item.code
        defer { busyCode = nil }
        do {
            guard let r = try await PlaylistServer.fetch(code: item.code) else { toast.show("Nie znaleziono playlisty."); return }
            engine.play(r.tracks, startAt: 0)
            dismiss()
        } catch let err {
            toast.show(err.localizedDescription)
        }
    }
}

/// Podgląd playlisty z biblioteki: lista piosenek, odtwarzanie od wybranej i dodanie całej playlisty do swojej biblioteki.
struct PublicPlaylistDetailView: View {
    let item: PlaylistServer.Item
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter

    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if failed || tracks.isEmpty {
                Text("Nie udało się wczytać piosenek z tej playlisty.").foregroundStyle(.secondary)
                Button("Spróbuj ponownie") { Task { await load() } }
            } else {
                HStack(spacing: 12) {
                    Button { engine.play(tracks, startAt: 0) } label: {
                        Label("Odtwórz", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { add() } label: {
                        Label("Dodaj do biblioteki", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .listRowSeparator(.hidden)
                ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                    Button { engine.play(tracks, startAt: index) } label: {
                        HStack(spacing: 12) {
                            TrackThumb(track: track, size: 46)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                                Text(track.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        failed = false
        do {
            if let r = try await PlaylistServer.fetch(code: item.code) { tracks = r.tracks } else { failed = true }
        } catch {
            failed = true
        }
        loading = false
    }

    private func add() {
        let p = library.create(name: item.name, tracks: tracks, coverData: item.cover)
        DownloadMonitor.shared.enqueue(p.tracks.map { $0.id })
        toast.show("Dodano \"\(p.name)\" do biblioteki. Pobieram piosenki w tle.")
    }
}
