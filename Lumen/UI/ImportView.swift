import SwiftUI
import UIKit

struct ImportView: View {
    var initialText: String = ""
    var spotify: Bool = false
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss

    enum Phase {
        case idle
        case loading
        case ready(tracks: [Track], skipped: Int)
        case failed(String)
    }

    @State private var text = ""
    @State private var name = ""
    @State private var phase: Phase = .idle
    @State private var batch: TrackBatch? = nil
    @State private var note = ""
    @State private var serverCover: Data? = nil

    var body: some View {
        NavigationStack {
            List {
                Section(spotify ? "Link do playlisty, albumu lub piosenki ze Spotify" : "Link do playlisty lub piosenki") {
                    TextField(spotify ? "https://open.spotify.com/playlist/…" : "Link do playlisty (YouTube albo z Music Player)", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                    HStack {
                        Button("Wklej") {
                            if let s = UIPasteboard.general.string { text = s }
                        }
                        Spacer()
                        Button("Pobierz") { fetch() }
                            .buttonStyle(.bordered)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                switch phase {
                case .idle:
                    EmptyView()
                case .loading:
                    Section { HStack { ProgressView(); Text(note.isEmpty ? "Importuję…" : note).padding(.leading, 8) } }
                case .failed(let message):
                    Section { Text(message).foregroundStyle(.red) }
                case .ready(let tracks, let skipped):
                    readySection(tracks: tracks, skipped: skipped)
                }
            }
            .navigationTitle(spotify ? "Import ze Spotify" : "Import playlisty")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Zamknij") { dismiss() } }
            }
            .onAppear {
                if text.isEmpty && !initialText.isEmpty {
                    text = initialText
                    fetch()
                } else if text.isEmpty, let clip = UIPasteboard.general.string, PlaylistShare.contains(clip) || PlaylistServer.code(in: clip) != nil {
                    text = clip     // skopiowany link do playlisty od znajomego wstawia się sam
                    fetch()
                } else if text.isEmpty && spotify, let clip = UIPasteboard.general.string, clip.contains("open.spotify.com/") {
                    text = clip     // skopiowany link ze Spotify wstawia się sam
                    fetch()
                }
            }
            .sheet(item: $batch) { b in
                AddToPlaylistSheet(tracks: b.tracks)
                    .environmentObject(library)
                    .environmentObject(toast)
                    .preferredColorScheme(settings.colorScheme)
            }
        }
    }

    @ViewBuilder
    private func readySection(tracks: [Track], skipped: Int) -> some View {
        if tracks.count > 1 {
            Section("Playlista") {
                TextField("Nazwa playlisty", text: $name)
                Text(Pl.songs(tracks.count) + (skipped > 0 ? " · pominięto: \(skipped) (prywatne lub usunięte)" : ""))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Zapisz jako playlistę") {
                    let p = library.create(name: name, tracks: tracks, coverData: serverCover)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    DownloadMonitor.shared.enqueue(p.tracks.map { $0.id })
                    toast.show("Zaimportowano \"\(p.name)\" (\(Pl.songs(p.tracks.count))). Pobieram piosenki w tle.")
                    dismiss()
                }
                Button("Odtwórz teraz") {
                    engine.play(tracks, startAt: 0)
                    DownloadMonitor.shared.enqueue(tracks.map { $0.id })
                    dismiss()
                }
            }
        } else if let t = tracks.first {
            Section("Piosenka") {
                HStack(spacing: 12) {
                    TrackThumb(track: t, size: 52)
                    VStack(alignment: .leading) {
                        Text(t.title).lineLimit(2)
                        Text(t.artist).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Dodaj do playlisty…") { batch = TrackBatch(tracks: [t]) }
                Button("Odtwórz teraz") {
                    engine.playNow(t)
                    dismiss()
                }
            }
        }
        Section("Podgląd") {
            ForEach(Array(tracks.prefix(8).enumerated()), id: \.offset) { _, t in
                HStack(spacing: 10) {
                    TrackThumb(track: t, size: 38)
                    Text(t.title).font(.subheadline).lineLimit(1)
                }
            }
            if tracks.count > 8 {
                Text("+ \(tracks.count - 8) więcej").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func fetchExternal() {
        phase = .loading
        note = "Pobieranie listy piosenek…"
        let api = settings.api
        let link = text
        Task {
            do {
                let r = try await ExternalImport.fetch(link, api: api) { done, total in
                    Task { @MainActor in note = "Importuję…" }
                }
                note = ""
                name = r.name
                phase = r.tracks.isEmpty ? .failed("Nie udało się dopasować żadnej piosenki.") : .ready(tracks: r.tracks, skipped: r.skipped)
            } catch let err {
                note = ""
                phase = .failed(err.localizedDescription)
            }
        }
    }

    private func fetchFromServer(_ code: String) {
        phase = .loading
        note = "Pobieram playlistę…"
        Task {
            do {
                if let r = try await PlaylistServer.fetch(code: code) {
                    name = r.name
                    serverCover = r.cover
                    phase = .ready(tracks: r.tracks, skipped: 0)
                } else {
                    phase = .failed("Nie znaleziono playlisty o tym kodzie.")
                }
            } catch let err {
                phase = .failed(err.localizedDescription)
            }
            note = ""
        }
    }

    private func fetch() {
        serverCover = nil
        if let code = PlaylistServer.code(in: text) { fetchFromServer(code); return }
        // Playlista udostępniona z tej aplikacji (link musicplayer://… albo cała wiadomość z listą).
        if PlaylistShare.contains(text) {
            if let shared = PlaylistShare.decode(text) {
                name = shared.name
                phase = .ready(tracks: shared.tracks, skipped: 0)
            } else {
                phase = .failed("Ten link do playlisty jest niepełny. Skopiuj go w całości i spróbuj jeszcze raz.")
            }
            return
        }
        if ExternalImport.detect(text) { fetchExternal(); return }
        guard let link = YouTubeURL.parse(text, allowBareID: true) else {
            phase = .failed("To nie wygląda na link do filmu lub playlisty z YouTube.")
            return
        }
        var playlistID: String? = nil
        var videoID: String? = nil
        switch link {
        case .video(let v):
            videoID = v
        case .playlist(let p):
            playlistID = p
        case .videoInPlaylist(let v, let p):
            // "Mix" playlists (RD…) are generated by YouTube and cannot be read through the API
            if p.hasPrefix("RD") { videoID = v } else { playlistID = p }
        }
        phase = .loading
        let api = settings.api
        Task {
            do {
                if let pid = playlistID {
                    let r = try await api.playlist(id: pid)
                    name = r.title
                    phase = .ready(tracks: r.tracks, skipped: r.skipped)
                } else if let vid = videoID {
                    let t = try await api.video(id: vid)
                    name = t.title
                    phase = .ready(tracks: [t], skipped: 0)
                }
            } catch let err {
                phase = .failed(err.localizedDescription)
            }
        }
    }
}
