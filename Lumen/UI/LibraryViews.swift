import SwiftUI
import PhotosUI

struct TrackBatch: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

struct ScreenHeader<Trailing: View>: View {
    @Environment(\.ink) private var ink
    let title: String
    let back: (() -> Void)?
    let trailing: Trailing

    init(_ title: String, back: (() -> Void)? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.back = back
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let back = back {
                GlassIconButton(systemName: "chevron.left", size: 40, action: back)
            }
            Text(title)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String, back: (() -> Void)? = nil) {
        self.init(title, back: back) { EmptyView() }
    }
}

// MARK: - Library root

struct LibraryRootView: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @Binding var selected: UUID?
    @State private var showImport = false
    @State private var showNew = false
    @State private var importSpotify = false
    @State private var newName = ""
    @State private var renameTarget: UUID? = nil
    @State private var renameName = ""
    @State private var showRename = false
    @State private var showPublic = false
    @State private var showPublish = false
    @State private var publishTarget: Playlist? = nil
    @State private var coverTarget: UUID? = nil
    @State private var showCoverPicker = false
    @State private var coverItem: PhotosPickerItem? = nil

    var body: some View {
        ZStack {
            if let id = selected {
                PlaylistDetailView(playlistID: id) {
                    withAnimation(.easeInOut(duration: 0.25)) { selected = nil }
                }
                .transition(.move(edge: .trailing))
            } else {
                home.transition(.opacity)
            }
        }
        .sheet(isPresented: $showImport) {
            ImportView(spotify: importSpotify)
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showPublic) {
            PublicPlaylistsView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(engine)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
        .confirmationDialog("Opublikować playlistę?", isPresented: $showPublish, titleVisibility: .visible, presenting: publishTarget) { pl in
            Button("Publicznie - widoczna w bibliotece playlist") { PlaylistServer.publishAndCopy(pl, isPublic: true, toast: toast) }
            Button("Prywatnie - tylko dla osób z linkiem") { PlaylistServer.publishAndCopy(pl, isPublic: false, toast: toast) }
            Button("Anuluj", role: .cancel) {}
        } message: { _ in
            Text("Dostaniesz link do skopiowania i wysłania.")
        }
        .photosPicker(isPresented: $showCoverPicker, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            guard let item = item, let id = coverTarget else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), library.setCover(id, imageData: data) {
                    toast.show("Zmieniono ikonę playlisty")
                } else {
                    toast.show("Nie udało się wczytać zdjęcia")
                }
                coverItem = nil
            }
        }
        .alert("Nowa playlista", isPresented: $showNew) {
            TextField("Nazwa", text: $newName)
            Button("Utwórz") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { library.create(name: newName) }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                newName = ""
            }
            Button("Anuluj", role: .cancel) { newName = "" }
        }
        .alert("Zmień nazwę playlisty", isPresented: $showRename) {
            TextField("Nazwa", text: $renameName)
            Button("Zapisz") {
                if let id = renameTarget { library.rename(id, to: renameName) }
            }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private var home: some View {
        VStack(spacing: 0) {
            ScreenHeader("Biblioteka") {
                Menu {
                    Button { showNew = true } label: { Label("Nowa playlista", systemImage: "plus") }
                    Button { showPublic = true } label: { Label("Biblioteka playlist", systemImage: "globe") }
                    Button { importSpotify = false; showImport = true } label: { Label("Importuj z linku", systemImage: "square.and.arrow.down") }
                    Button { importSpotify = true; showImport = true } label: { Label("Importuj ze Spotify", systemImage: "arrow.down.circle") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(ink)
                        .frame(width: 48, height: 48)
                        .glass(Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .tourTarget(.libraryAdd)
            }
            if library.playlists.isEmpty {
                ScrollView {
                    EmptyHint(icon: "music.note.list", title: "Brak playlist",
                              message: "Kliknij +, aby utworzyć playlistę albo zaimportować ją z linku do playlisty.")
                        .padding(.top, 60)
                }
            } else {
                List {
                    ForEach(library.playlists) { p in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { selected = p.id }
                        } label: {
                            PlaylistRow(playlist: p)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .contextMenu {
                            Button { PlaylistServer.share(p, toast: toast) } label: {
                                Label("Udostępnij link", systemImage: "square.and.arrow.up")
                            }
                            Button { PlaylistServer.publishAndCopy(p, isPublic: false, toast: toast) } label: {
                                Label("Kopiuj link", systemImage: "link")
                            }
                            if PlaylistServer.published(p.id) == nil {
                                Button { publishTarget = p; showPublish = true } label: { Label("Opublikuj…", systemImage: "globe") }
                            } else {
                                Button { PlaylistServer.publishAndCopy(p, toast: toast) } label: { Label("Zaktualizuj na stronie", systemImage: "arrow.triangle.2.circlepath") }
                            }
                            Button {
                                renameTarget = p.id
                                renameName = p.name
                                showRename = true
                            } label: { Label("Zmień nazwę", systemImage: "pencil") }
                            Button {
                                coverTarget = p.id
                                showCoverPicker = true
                            } label: { Label("Zmień ikonę", systemImage: "photo") }
                            if p.coverFile != nil {
                                Button { library.removeCover(p.id) } label: { Label("Usuń własną ikonę", systemImage: "photo.badge.minus") }
                            }
                            Button(role: .destructive) { library.delete(id: p.id) } label: { Label("Usuń", systemImage: "trash") }
                        }
                    }
                    .onDelete { library.delete(at: $0) }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: library.playlists.map { $0.id })
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct PlaylistRow: View {
    @Environment(\.ink) private var ink
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 14) {
            PlaylistCover(playlist: playlist, size: 62, radius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                Text("\(Pl.songs(playlist.tracks.count))").font(.system(size: 14)).foregroundStyle(ink.opacity(0.6))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(ink.opacity(0.4))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Okładka playlisty: własne zdjęcie, okładka jedynej piosenki albo mozaika 2x2 z okładek pierwszych czterech.
struct PlaylistCover: View {
    @Environment(\.ink) private var ink
    let playlist: Playlist
    var size: CGFloat = 62
    var radius: CGFloat = 12

    var body: some View {
        Group {
            if let cover = playlist.coverFile,
               let img = UIImage(contentsOfFile: LibraryStore.coversDir.appendingPathComponent(cover).path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else if playlist.tracks.count == 1, let first = playlist.tracks.first {
                TrackThumb(track: first, size: size, cornerRadius: 0)
            } else if playlist.tracks.count > 1 {
                mosaic
            } else {
                Rectangle()
                    .fill(ink.opacity(0.12))
                    .overlay(Image(systemName: "music.note.list")
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.6)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var mosaic: some View {
        let tracks = Array(playlist.tracks.prefix(4))
        let cell = (size - 1) / 2
        return VStack(spacing: 1) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 1) {
                    ForEach(0..<2, id: \.self) { col in
                        let i = row * 2 + col
                        if i < tracks.count {
                            TrackThumb(track: tracks[i], size: cell, cornerRadius: 0)
                        } else {
                            Rectangle().fill(ink.opacity(0.12)).frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    @Environment(\.ink) private var ink
    let playlistID: UUID
    let back: () -> Void
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var toast: ToastCenter
    @State private var editMode: EditMode = .inactive
    @State private var batch: TrackBatch? = nil
    @State private var showCoverPicker = false
    @State private var coverItem: PhotosPickerItem? = nil
    @State private var showPublish = false
    @State private var publishTarget: Playlist? = nil

    var body: some View {
        if let p = library.playlist(playlistID) {
            content(p)
                .confirmationDialog("Opublikować playlistę?", isPresented: $showPublish, titleVisibility: .visible, presenting: publishTarget) { pl in
                    Button("Publicznie - widoczna w bibliotece playlist") { PlaylistServer.publishAndCopy(pl, isPublic: true, toast: toast) }
                    Button("Prywatnie - tylko dla osób z linkiem") { PlaylistServer.publishAndCopy(pl, isPublic: false, toast: toast) }
                    Button("Anuluj", role: .cancel) {}
                } message: { _ in
                    Text("Dostaniesz link do skopiowania i wysłania.")
                }
        } else {
            Color.clear.onAppear(perform: back)
        }
    }

    private func content(_ p: Playlist) -> some View {
        VStack(spacing: 0) {
            // Nazwa jest pod dużą okładką (jak w Apple Music), więc na górze zostaje tylko "wstecz" i przyciski.
            ScreenHeader("", back: back) {
                HStack(spacing: 0) {
                    Menu {
                        if PlaylistServer.published(p.id) == nil {
                            Button { publishTarget = p; showPublish = true } label: { Label("Opublikuj…", systemImage: "globe") }
                        } else {
                            Button { PlaylistServer.publishAndCopy(p, toast: toast) } label: { Label("Zaktualizuj na stronie", systemImage: "arrow.triangle.2.circlepath") }
                        }
                        Button { PlaylistServer.publishAndCopy(p, isPublic: false, toast: toast) } label: {
                            Label("Kopiuj link", systemImage: "link")
                        }
                        if PlaylistServer.published(p.id) != nil {
                            Button(role: .destructive) { PlaylistServer.unpublishWithToast(p, toast: toast) } label: {
                                Label("Usuń ze strony", systemImage: "xmark.icloud")
                            }
                        }
                        Button { showCoverPicker = true } label: { Label("Zmień ikonę playlisty", systemImage: "photo") }
                        if p.coverFile != nil {
                            Button { library.removeCover(p.id) } label: { Label("Usuń własną ikonę", systemImage: "photo.badge.minus") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Button { PlaylistServer.share(p, toast: toast) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Image(systemName: editMode.isEditing ? "checkmark" : "pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ink)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(editMode.isEditing ? "Gotowe" : "Edytuj")
                }
            }
            if p.tracks.isEmpty {
                ScrollView {
                    hero(p)
                    EmptyHint(icon: "music.note", title: "Pusta playlista",
                              message: "Użyj zakładki Szukaj i menu ••• przy piosence, aby dodać ją tutaj.")
                        .padding(.top, 16)
                }
            } else {
                List {
                    hero(p)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                    ForEach(Array(p.tracks.enumerated()), id: \.element.id) { index, t in
                        TrackRow(track: t,
                                 isCurrent: engine.currentTrack?.id == t.id,
                                 onPlay: { engine.play(p.tracks, startAt: index) },
                                 onAddToPlaylist: { batch = TrackBatch(tracks: [t]) })
                            .listRowBackground(CurrentRowBackground(active: engine.currentTrack?.id == t.id))
                            .listRowSeparator(.hidden)
                    }
                    .onDelete { library.remove(at: $0, from: p.id) }
                    .onMove { library.move(from: $0, to: $1, in: p.id) }
                }
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: p.tracks.map { $0.id })
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
                // Pierwsze niepobrane piosenki dostają adres strumienia z wyprzedzeniem (start bez czekania).
                .onAppear { PlaybackPrewarm.warm(p.tracks) }
            }
        }
        .photosPicker(isPresented: $showCoverPicker, selection: $coverItem, matching: .images)
        .onChange(of: coverItem) { _, item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), library.setCover(playlistID, imageData: data) {
                    toast.show("Zmieniono ikonę playlisty")
                } else {
                    toast.show("Nie udało się wczytać zdjęcia")
                }
                coverItem = nil
            }
        }
        .sheet(item: $batch) { b in
            AddToPlaylistSheet(tracks: b.tracks)
                .environmentObject(library)
                .environmentObject(toast)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    /// Góra playlisty jak w Apple Music: duża okładka, nazwa, liczba piosenek i łączny czas, przyciski.
    private func hero(_ p: Playlist) -> some View {
        VStack(spacing: 16) {
            PlaylistCover(playlist: p, size: 196, radius: 24)
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            VStack(spacing: 4) {
                Text(p.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(summary(p))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ink.opacity(0.6))
            }
            HStack(spacing: 12) {
                actionButton("Odtwórz", "play.fill", prominent: true) { engine.play(p.tracks, startAt: 0) }
                actionButton("Losowo", "shuffle", prominent: false) { engine.play(p.tracks, startAt: 0, shuffled: true) }
            }
            .opacity(p.tracks.isEmpty ? 0.4 : 1)
            .disabled(p.tracks.isEmpty)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    /// "3 piosenki · 6 min" (czas tylko wtedy, gdy znamy długość piosenek).
    private func summary(_ p: Playlist) -> String {
        let total = p.tracks.reduce(0.0) { $0 + max($1.duration, 0) }
        guard total >= 60 else { return Pl.songs(p.tracks.count) }
        return "\(Pl.songs(p.tracks.count)) · \(Pl.length(total))"
    }

    /// Główny przycisk ("Odtwórz") jest wypełniony kolorem tekstu, drugi to szkło.
    private func actionButton(_ title: String, _ icon: String, prominent: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if prominent {
                Label(title, systemImage: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(ink, in: Capsule())
            } else {
                Label(title, systemImage: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .glass(Capsule(), interactive: true)
            }
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
    }
}

/// Delikatne podświetlenie wiersza piosenki, która teraz gra.
struct CurrentRowBackground: View {
    @Environment(\.ink) private var ink
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(ink.opacity(active ? 0.1 : 0))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .animation(.easeInOut(duration: 0.25), value: active)
    }
}
