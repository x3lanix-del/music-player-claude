import SwiftUI
import UIKit

/// App wallpaper: plain black, plain white, a custom colour/photo, or the moving cover background (like Apple Music).
/// `player: true` (Now Playing / radio player) always shows the moving cover, whatever wallpaper is set for the app.
struct AnimatedBackground: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    var isActive: Bool = true
    var player: Bool = false
    /// 5 dominujących kolorów okładki (z nich powstaje siatka tła).
    @State private var dominant: [UIColor] = []
    /// Ziarno losowania układu pól: ta sama piosenka = ten sam układ.
    @State private var seed: Int = 0
    /// Przyciemnienie dobrane do jasności okładki (jasna okładka = mocniej, żeby biały tekst był czytelny).
    @State private var shade: Double = 0.2

    private var key: String {
        "\(player)|\(settings.data.theme.rawValue)|\(engine.currentTrack?.id ?? "-")|\(engine.artwork != nil)"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if player {
                    colorful(size: geo.size)
                } else {
                switch settings.data.theme {
                case .black:
                    Color.black
                case .white:
                    Color.white
                case .blur:
                    colorful(size: geo.size)
                case .color:
                    customColor
                case .image:
                    customImage(size: geo.size)
                }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: key) { await rebuild() }
    }

    private var customColor: some View {
        let a = Color(hex: settings.data.backgroundColorHex)
        let b = Color(hex: settings.data.backgroundColor2Hex)
        return Group {
            if settings.data.backgroundGradient {
                LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
            } else {
                a
            }
        }
    }

    private func customImage(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let img = settings.backgroundImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(settings.data.imageBlur ? 1.15 : 1)   // zasłania jasne brzegi po rozmyciu
                    .blur(radius: settings.data.imageBlur ? settings.data.imageBlurRadius : 0)
                    .clipped()
            }
            Color.black.opacity(settings.data.dim)
        }
    }

    /// Tło jak w repozytorium „Apple Music Background” (i jak w Apple Music): siatka pól w dominujących kolorach
    /// okładki, przykryta bardzo mocnym rozmyciem i przyciemnieniem - efekt matowego szkła.
    private func colorful(size: CGSize) -> some View {
        ZStack {
            Color.black
            if dominant.isEmpty {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            } else {
                ColorGridBackground(colors: dominant, seed: seed, size: size,
                                    speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
                    .transition(.opacity)
            }
            // Jak w repozytorium: czarna warstwa 30% (jaśniejsze okładki trochę więcej, pod biały tekst).
            Color.black.opacity(player ? shade : max(settings.data.dim, shade))
                .animation(.easeInOut(duration: 1.0), value: shade)
        }
    }

    private func rebuild() async {
        guard player || settings.data.theme == .blur, let src = engine.artwork else {
            // Chwila przełączania piosenki (okładka jeszcze się ładuje): zostaje poprzednie tło, bez mignięcia czernią.
            if engine.currentTrack == nil { dominant = [] }
            return
        }
        let newSeed = LyricsProviders.stableID(engine.currentTrack?.id ?? "")
        let result = await Task.detached(priority: .utility) { () -> ([UIColor], Double) in
            let small = ArtworkLoader.downscale(src, maxSide: 160)
            let colors = ArtworkLoader.dominantColors(of: small, max: 5).map { $0.color }
            return (colors, ArtworkLoader.meanBrightness(of: small))
        }.value
        guard !result.0.isEmpty else { return }
        let target = min(max(0.3 + (result.1 - 0.6) * 0.5, 0.3), 0.45)
        withAnimation(.easeInOut(duration: 1.2)) {
            dominant = result.0
            seed = newSeed
            shade = target
        }
    }
}

/// Siatka 5 x 7 pól, każde losowo w jednym z dominujących kolorów okładki (jak w repozytorium
/// „Apple Music Background”), przykryta rozmyciem o sile ok. 90 pt. Żeby tło żyło jak w Apple Music, co kilka
/// sekund kilka pól płynnie zmienia kolor na inny z okładki.
/// Rozmycie liczone jest w 1/8 rozdzielczości (bardzo tanie), a gotowy obraz jest powiększany - i tak ma być miękki.
private struct ColorGridBackground: View {
    let colors: [UIColor]
    let seed: Int
    let size: CGSize
    let speed: Double
    let paused: Bool

    private static let columns = 5
    private static let rows = 7
    private static let downsample: CGFloat = 8
    /// Siatka jest trochę większa niż ekran, żeby brzegi rozmycia były poza ekranem.
    private static let overscan: CGFloat = 1.25
    /// Siła rozmycia na pełnym ekranie (jak `backdrop-filter: blur(90px)` w repozytorium).
    private static let blurStrength: CGFloat = 90

    /// Który kolor (indeks w `colors`) ma każde pole.
    @State private var cells: [Int] = []

    private var palette: [Color] {
        colors.isEmpty ? [Color(white: 0.25)] : colors.map { Color(uiColor: $0) }
    }

    var body: some View {
        let k = ColorGridBackground.downsample
        let w = size.width * ColorGridBackground.overscan / k
        let h = size.height * ColorGridBackground.overscan / k
        let colorsNow = palette
        VStack(spacing: 0) {
            ForEach(0..<ColorGridBackground.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<ColorGridBackground.columns, id: \.self) { col in
                        let i = row * ColorGridBackground.columns + col
                        let pick = cells.indices.contains(i) ? cells[i] : i
                        Rectangle().fill(colorsNow[pick % colorsNow.count])
                    }
                }
            }
        }
        .frame(width: w, height: h)
        .blur(radius: ColorGridBackground.blurStrength / k, opaque: true)
        .drawingGroup()
        .scaleEffect(k)
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { reshuffle() }
        .onChange(of: seed) { _, _ in
            withAnimation(.easeInOut(duration: 1.2)) { reshuffle() }
        }
        .task(id: paused) { await breathe() }
    }

    /// Losowy (ale stały dla piosenki) układ kolorów na polach.
    private func reshuffle() {
        var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: seed))
        let count = max(colors.count, 1)
        cells = (0..<(ColorGridBackground.rows * ColorGridBackground.columns)).map { _ in
            Int.random(in: 0..<count, using: &rng)
        }
    }

    /// Co kilka sekund 3 pola płynnie zmieniają kolor - tło powoli faluje.
    private func breathe() async {
        guard !paused else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(2_400_000_000 / speed))
            if Task.isCancelled || cells.isEmpty { return }
            let count = max(colors.count, 1)
            withAnimation(.easeInOut(duration: 3.0 / speed)) {
                for _ in 0..<3 {
                    let i = Int.random(in: 0..<cells.count)
                    cells[i] = Int.random(in: 0..<count)
                }
            }
        }
    }
}
