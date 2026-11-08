import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var toast: ToastCenter
    @State private var showGuide = false
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var confirmDelete = false
    @State private var confirmLyricsReset = false

    private var rowBackground: Color { ink.opacity(0.09) }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Ustawienia")
            Form {
                helpSection
                backgroundSection
                colorsSection
                lyricsSection
                censorSection
                extrasSection
                storageSection
            }
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showGuide) {
            GuideView { showGuide = false }
                .preferredColorScheme(settings.colorScheme)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    settings.setBackgroundImage(data)
                } else {
                    toast.show("Nie udało się wczytać zdjęcia")
                }
                pickerItem = nil
            }
        }
        .confirmationDialog("Usunąć wszystkie pobrane piosenki?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Usuń wszystkie piosenki", role: .destructive) {
                Task {
                    let n = await AudioCache.shared.removeAll()
                    toast.show(n > 0 ? "Usunięto pobrane piosenki" : "Nie było pobranych piosenek")
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Playlisty zostaną. Piosenki pobiorą się ponownie przy następnym odtworzeniu.")
        }
        .confirmationDialog("Usunąć zapisane teksty piosenek?", isPresented: $confirmLyricsReset, titleVisibility: .visible) {
            Button("Usuń teksty", role: .destructive) {
                Task {
                    await LyricsService.shared.clearCache()
                    LyricsWarpStore.removeAll()
                    if let t = engine.currentTrack, !t.isRadio { engine.refreshLyrics() }
                    toast.show("Teksty pobiorą się od nowa")
                }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Przydaje się, gdy teksty są złe albo przesunięte. Pobiorą się od nowa przy następnym odtworzeniu.")
        }
    }

    // MARK: Sections

    private var helpSection: some View {
        Section {
            Button {
                showGuide = true
            } label: {
                Label("Jak korzystać z aplikacji", systemImage: "questionmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
        } footer: {
            Text("Krótki przewodnik krok po kroku dla początkujących.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(rowBackground)
    }

    private var backgroundSection: some View {
        Section {
            Picker("Tło aplikacji", selection: $settings.data.theme) {
                ForEach(ThemeMode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.menu)

            switch settings.data.theme {
            case .blur:
                dimSlider
            case .color:
                Toggle("Gradient", isOn: $settings.data.backgroundGradient)
                ColorPicker(settings.data.backgroundGradient ? "Kolor na górze" : "Kolor tła",
                            selection: colorBinding(\.backgroundColorHex, fallback: Color(hex: "2B2B6B")),
                            supportsOpacity: false)
                if settings.data.backgroundGradient {
                    ColorPicker("Kolor na dole",
                                selection: colorBinding(\.backgroundColor2Hex, fallback: Color(hex: "07070F")),
                                supportsOpacity: false)
                }
            case .image:
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(settings.backgroundImage == nil ? "Wybierz zdjęcie z galerii" : "Zmień zdjęcie",
                          systemImage: "photo")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if settings.backgroundImage != nil {
                    Toggle("Rozmycie zdjęcia", isOn: $settings.data.imageBlur)
                    if settings.data.imageBlur {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Siła rozmycia").font(.subheadline)
                            Slider(value: $settings.data.imageBlurRadius, in: 2...50)
                        }
                    }
                    dimSlider
                    Button("Usuń zdjęcie", role: .destructive) { settings.removeBackgroundImage() }
                }
            case .black, .white:
                EmptyView()
            }
        } header: {
            Text("Tło")
        } footer: {
            Text(backgroundFooter)
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(rowBackground)
    }

    private var backgroundFooter: String {
        switch settings.data.theme {
        case .blur: return "Kolorowe tło z okładki grającej piosenki, bardzo powoli się porusza. Wyłącz rozmycie, żeby widzieć ostrą okładkę."
        case .color: return "Jednolity kolor albo gradient w wybranych kolorach."
        case .image: return "Własne zdjęcie z galerii, z rozmyciem lub bez."
        case .black: return "Czarne tło."
        case .white: return "Białe tło (cały interfejs przełącza się na jasny)."
        }
    }

    private var dimSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Przyciemnienie").font(.subheadline)
            Slider(value: $settings.data.dim, in: 0...0.8)
        }
    }

    private var colorsSection: some View {
        Section {
            ColorPicker("Kolor tekstów i ikon", selection: colorBinding(\.inkHex, fallback: Color.primary),
                        supportsOpacity: false)
            ColorPicker("Kolor akcentu", selection: colorBinding(\.accentHex, fallback: Color.primary),
                        supportsOpacity: false)
            ColorPicker("Kolor tekstu piosenki", selection: colorBinding(\.lyricsHex, fallback: Color.primary),
                        supportsOpacity: false)
            Button("Przywróć kolory domyślne") { settings.resetColors() }
        } header: {
            Text("Kolory")
        } footer: {
            Text("Domyślnie kolory są automatyczne: biały na ciemnym tle, czarny na jasnym.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(rowBackground)
    }

    private var lyricsSection: some View {
        Section {
            Toggle("Animacja liter (karaoke)", isOn: $settings.data.karaokeLyrics.animation())
            if settings.data.karaokeLyrics {
                Toggle("Fala liter także bez czasów słów", isOn: $settings.data.karaokeLineSync)
            }
            Toggle("Rozmycie dalszych linijek", isOn: $settings.data.blurInactiveLyrics)
            VStack(alignment: .leading) {
                Text("Rozmiar tekstu: \(Int(settings.data.lyricsFontSize))")
                Slider(value: $settings.data.lyricsFontSize, in: 22...46, step: 1)
            }
            Button("Usuń zapisane teksty") { confirmLyricsReset = true }
        } header: {
            Text("Teksty piosenek")
        } footer: {
            Text("Litery zapalają się dokładnie wtedy, gdy są śpiewane (iOS 18 i nowszy). Gdy źródło zna tylko czas całej linijki, czas liter jest szacowany. Tekst możesz przewijać palcem - po chwili sam wraca do śpiewanej linijki. Usunięte teksty pobiorą się od nowa przy następnym odtworzeniu.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(rowBackground)
    }

    private var censorSection: some View {
        Section {
            Toggle("Cenzura przekleństw", isOn: $settings.data.censorProfanity)
        } header: {
            Text("Przekleństwa")
        } footer: {
            Text("W tekstach wulgaryzmy są zastępowane gwiazdkami (np. ku***), a w nagraniu cichną na ułamek sekundy z krótkim sygnałem. Działa w kilku językach. Moment w nagraniu jest szacowany z czasu linijki tekstu, więc bywa niedokładny.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(rowBackground)
    }

    private static let languages: [(code: String, name: String)] = [
        ("pl", "Polski"), ("en", "Angielski"), ("de", "Niemiecki"), ("es", "Hiszpański"), ("fr", "Francuski"),
        ("it", "Włoski"), ("pt", "Portugalski"), ("ru", "Rosyjski"), ("uk", "Ukraiński"), ("tr", "Turecki"),
        ("ja", "Japoński"), ("ko", "Koreański"), ("zh-CN", "Chiński")
    ]

    private var extrasSection: some View {
        Section {
            Toggle("Tłumaczenie tekstu", isOn: $settings.data.translateLyrics)
            Picker("Język tłumaczenia", selection: $settings.data.translateTarget) {
                ForEach(SettingsView.languages, id: \.code) { Text($0.name).tag($0.code) }
            }
            VStack(alignment: .leading) {
                Text("Tempo animacji tła: \(String(format: "%.2f", settings.data.bgSpeed))×")
                Slider(value: $settings.data.bgSpeed, in: 0.5...3, step: 0.25)
            }
        } header: {
            Text("Tłumaczenie i wygląd")
        } footer: {
            Text("Tempo tła zmienia się po ponownym otwarciu ekranu odtwarzacza.")
        }
        .listRowBackground(rowBackground)
    }

    private var storageSection: some View {
        Section {
            Button("Usuń wszystkie pobrane piosenki", role: .destructive) { confirmDelete = true }
        } header: {
            Text("Piosenki")
        } footer: {
            Text("Każda odtworzona piosenka jest pobierana raz i zostaje w telefonie.")
            .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(rowBackground)
    }

    // MARK: Helpers

    private func colorBinding(_ key: WritableKeyPath<SettingsData, String>, fallback: Color) -> Binding<Color> {
        Binding(
            get: {
                let hex = settings.data[keyPath: key]
                return hex.isEmpty ? fallback : Color(hex: hex)
            },
            set: { settings.data[keyPath: key] = $0.hexString }
        )
    }
}
