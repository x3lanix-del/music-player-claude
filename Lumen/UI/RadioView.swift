import SwiftUI
import PhotosUI

struct RadioView: View {
    @Environment(\.ink) private var ink
    @Environment(\.accentInk) private var accentInk
    @ObservedObject var store: RadioStore
    var isVisible: Bool
    var openPlayer: () -> Void = {}
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter

    @State private var section = 0          // 0 = stacje, 1 = ulubione
    @State private var query = ""
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @FocusState private var focused: Bool
    @State private var iconTarget: RadioStation? = nil
    @State private var showIconPicker = false
    @State private var pickedItem: PhotosPickerItem? = nil

    private var list: [RadioStation] { section == 0 ? store.stations : store.favorites }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Radio") {
                GlassIconButton(systemName: "plus", size: 40) { showAdd = true }
            }

            if engine.isRadio, engine.currentTrack != nil { nowPlayingCard }

            Picker("", selection: $section) {
                Text("Stacje").tag(0)
                Text("Ulubione").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            if section == 0 { searchField.padding(.horizontal, 20).padding(.bottom, 8) }

            if section == 0 && store.loading {
                ProgressView().tint(accentInk).padding(.top, 40)
                Spacer()
            } else if list.isEmpty {
                ScrollView {
                    EmptyHint(icon: section == 0 ? "dot.radiowaves.left.and.right" : "star",
                              title: section == 0 ? (store.message ?? "Brak stacji") : "Brak ulubionych",
                              message: section == 0
                                ? "Pociągnij, żeby spróbować jeszcze raz."
                                : "Kliknij gwiazdkę przy stacji albo dodaj własną przyciskiem +.")
                        .padding(.top, 50)
                }
                .refreshable { if section == 0 { await store.search(query) } }
            } else {
                List {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, s in
                        row(s, index: index)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing) {
                                if section == 1 {
                                    Button(role: .destructive) { store.toggleFavorite(s) } label: {
                                        Label("Usuń", systemImage: "trash")
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { if section == 0 { await store.search(query) } }
            }
        }
        .task(id: isVisible) {
            if isVisible && store.stations.isEmpty && !store.loading {
                await store.loadPopular()
            }
        }
        .photosPicker(isPresented: $showIconPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item = item, let station = iconTarget else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   RadioIconStore.shared.setCustom(data, for: station.id) {
                    toast.show("Ustawiono własną ikonę stacji")
                } else {
                    toast.show("Nie udało się wczytać zdjęcia")
                }
                pickedItem = nil
                iconTarget = nil
            }
        }
        .alert("Dodaj własną stację", isPresented: $showAdd) {
            TextField("Nazwa", text: $newName)
            TextField("Adres strumienia (https://…)", text: $newURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Dodaj") {
                if store.addCustom(name: newName, urlText: newURL) {
                    section = 1
                    toast.show("Dodano stację")
                } else {
                    toast.show("Nieprawidłowy adres strumienia")
                }
                newName = ""
                newURL = ""
            }
            Button("Anuluj", role: .cancel) { newName = ""; newURL = "" }
        } message: {
            Text("Wklej bezpośredni link do strumienia (mp3, aac albo m3u8).")
        }
    }

    /// Karta na górze: ikona stacji, obok grający utwór. Dotknięcie otwiera ekran radia (z tekstem piosenki).
    private var nowPlayingCard: some View {
        Button(action: openPlayer) {
            HStack(spacing: 12) {
                RadioIcon(station: engine.currentStation, size: 56, radius: 14, active: engine.isPlaying)
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.currentStation?.name ?? engine.currentTrack?.title ?? "Radio")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.65))
                        .lineLimit(1)
                    Text(engine.radioSong?.title ?? "Brak informacji o utworze")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    if let artist = engine.radioSong?.artist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(size: 13))
                            .foregroundStyle(ink.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ink.opacity(0.6))
            }
            .padding(12)
            .contentShape(Rectangle())
            .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(ink.opacity(0.7))
            TextField("Szukaj stacji", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .foregroundStyle(ink)
                .onSubmit { Task { await store.search(query) } }
            if !query.isEmpty {
                Button {
                    query = ""
                    Task { await store.loadPopular() }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(ink.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .glass(Capsule())
    }

    private func row(_ s: RadioStation, index: Int) -> some View {
        let isCurrent = engine.currentTrack?.id == s.track.id
        return HStack(spacing: 8) {
            Button {
                focused = false
                engine.playRadio(list, startAt: index)
            } label: {
                HStack(spacing: 12) {
                    RadioIcon(station: s, size: 52, radius: 12, active: isCurrent && engine.isPlaying)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        // Przy grającej stacji zamiast opisu widać aktualny utwór.
                        HStack(spacing: 4) {
                            if isCurrent, engine.radioSong != nil {
                                Image(systemName: "music.note").font(.system(size: 11, weight: .bold))
                            }
                            Text(isCurrent ? (engine.radioSong?.display ?? (s.detail.isEmpty ? "Na żywo" : s.detail))
                                           : (s.detail.isEmpty ? "Na żywo" : s.detail))
                                .lineLimit(1)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(ink.opacity(isCurrent && engine.radioSong != nil ? 0.9 : 0.65))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { store.toggleFavorite(s) } label: {
                Image(systemName: store.isFavorite(s) ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(store.isFavorite(s) ? accentInk : ink.opacity(0.7))
                    .frame(width: 48, height: 56)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button {
                iconTarget = s
                showIconPicker = true
            } label: { Label("Zmień ikonę", systemImage: "photo") }
            if RadioIconStore.shared.hasCustom(s.id) {
                Button(role: .destructive) {
                    RadioIconStore.shared.removeCustom(for: s.id)
                    toast.show("Przywrócono automatyczną ikonę")
                } label: { Label("Usuń własną ikonę", systemImage: "arrow.uturn.backward") }
            }
            Button { store.toggleFavorite(s) } label: {
                Label(store.isFavorite(s) ? "Usuń z ulubionych" : "Dodaj do ulubionych",
                      systemImage: store.isFavorite(s) ? "star.slash" : "star")
            }
        }
    }
}
