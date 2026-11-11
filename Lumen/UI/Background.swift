import SwiftUI
import UIKit

/// App wallpaper: plain black, plain white, a custom colour/photo, or the flowing cover colours (like Apple Music).
/// `player: true` (Now Playing / radio player) always shows the cover colours, whatever wallpaper is set for the app.
struct AnimatedBackground: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    var isActive: Bool = true
    var player: Bool = false

    /// Siatka tła: 4 kolumny x 6 wierszy wierzchołków (pionowy ekran).
    static let columns = 4
    static let rows = 6
    /// Tło, gdy nic jeszcze nie gra.
    private static let idle = ArtworkLoader.idleMeshColors(columns: columns, rows: rows)

    /// Kolory wierzchołków siatki z okładki grającej piosenki (puste = jeszcze nic nie grało).
    @State private var mesh: [UIColor] = []
    /// Gładki obraz z tych kolorów - tylko dla iOS 17 (bez MeshGradient).
    @State private var still: UIImage? = nil
    /// Przyciemnienie dobrane do jasności tła (jaśniejsze tło = trochę mocniej, żeby biały tekst był czytelny).
    @State private var shade: Double = 0.1

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

    /// Tło jak w Apple Music: kolory okładki (w tych samych miejscach i proporcjach co na okładce) płynnie
    /// przechodzą w siebie i powoli płyną po ekranie.
    private func colorful(size: CGSize) -> some View {
        ZStack {
            Color.black
            flow(size: size)
            Color.black.opacity(player ? shade : max(settings.data.dim, shade))
                .animation(.easeInOut(duration: 1.0), value: shade)
        }
    }

    @ViewBuilder private func flow(size: CGSize) -> some View {
        let colors = mesh.isEmpty ? AnimatedBackground.idle : mesh
        let speed = max(0.25, settings.data.bgSpeed)
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            ArtworkMesh(colors: colors, columns: AnimatedBackground.columns, rows: AnimatedBackground.rows,
                        size: size, speed: speed, paused: !isActive)
        } else {
            ArtworkStill(image: still, colors: colors, size: size, speed: speed, paused: !isActive)
        }
        #else
        ArtworkStill(image: still, colors: colors, size: size, speed: speed, paused: !isActive)
        #endif
    }

    private func rebuild() async {
        guard player || settings.data.theme == .blur, let src = engine.artwork else {
            // Chwila przełączania piosenki (okładka jeszcze się ładuje): zostaje poprzednie tło, bez mignięcia.
            if engine.currentTrack == nil {
                mesh = []
                still = nil
            }
            return
        }
        let seed = LyricsProviders.stableID(engine.currentTrack?.id ?? "")
        var needsStill = true
        if #available(iOS 18.0, *) { needsStill = false }
        let wantsStill = needsStill
        let columns = AnimatedBackground.columns
        let rows = AnimatedBackground.rows
        let result = await Task.detached(priority: .utility) { () -> ([UIColor], Double, UIImage?) in
            let field = ArtworkLoader.meshColors(of: src, columns: columns, rows: rows, seed: seed)
            let image = wantsStill ? ArtworkLoader.meshImage(field.colors, columns: columns, rows: rows) : nil
            return (field.colors, field.brightness, image)
        }.value
        guard result.0.count == columns * rows else { return }
        // Kolory są już przyciemnione pod biały tekst; jaśniejsze tło dostaje jeszcze trochę cienia.
        let target = min(max(0.06 + (result.1 - 0.35) * 0.9, 0.06), 0.3)
        withAnimation(.easeInOut(duration: 1.0)) {
            mesh = result.0
            still = result.2
            shade = target
        }
    }
}

#if compiler(>=6.0)
/// Płynące tło z kolorów okładki (iOS 18+). Siatka wierzchołków - każdy ma kolor okładki ze swojej okolicy -
/// rysowana systemowym MeshGradient, więc kolory przechodzą w siebie idealnie gładko (bez żadnego rozmywania).
/// Wierzchołki powoli krążą (każdy w swoim tempie), przez co plamy kolorów płyną i mieszają się jak w Apple Music.
/// Siatka jest większa niż ekran i lekko się kołysze, więc nieruchomych rogów i brzegów nie widać.
/// Zmiana piosenki: kolory płynnie przechodzą w nowe. 30 klatek/s; nieaktywny ekran = animacja stoi.
@available(iOS 18.0, *)
private struct ArtworkMesh: View {
    let colors: [UIColor]
    let columns: Int
    let rows: Int
    let size: CGSize
    let speed: Double
    let paused: Bool

    private struct RGB: Equatable {
        var r: Double, g: Double, b: Double
    }

    @State private var from: [RGB] = []
    @State private var to: [RGB] = []
    @State private var changedAt = Date.distantPast
    private static let fade = 1.4
    private static let overscan: CGFloat = 1.3

    private static func rgb(_ c: UIColor) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(r: Double(r), g: Double(g), b: Double(b))
    }

    /// Dokładnie tyle kolorów, ile wierzchołków (MeshGradient tego wymaga).
    private func fit(_ list: [RGB]) -> [RGB] {
        let n = columns * rows
        guard !list.isEmpty else { return Array(repeating: RGB(r: 0.1, g: 0.1, b: 0.12), count: n) }
        return (0..<n).map { list[$0 % list.count] }
    }

    /// Kolory w danej chwili (w trakcie zmiany piosenki: mieszanka starych i nowych).
    private func blend(at date: Date) -> [RGB] {
        let target = fit(to.isEmpty ? colors.map(ArtworkMesh.rgb) : to)
        guard !from.isEmpty else { return target }
        let p = min(max(date.timeIntervalSince(changedAt) / ArtworkMesh.fade, 0), 1)
        if p >= 1 { return target }
        let e = p * p * (3 - 2 * p)
        return zip(fit(from), target).map { a, b in
            RGB(r: a.r + (b.r - a.r) * e, g: a.g + (b.g - a.g) * e, b: a.b + (b.b - a.b) * e)
        }
    }

    /// Położenie wierzchołków w chwili `t` (0...1). Rogi stoją, wierzchołki na brzegach suwają się wzdłuż brzegu,
    /// pozostałe krążą. Ruch to najwyżej 40% odstępu, więc sąsiedzi nigdy się nie mijają (siatka się nie zawija).
    private static func points(columns: Int, rows: Int, t: Double) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(columns * rows)
        let lastC = columns - 1
        let lastR = rows - 1
        let ax = 0.4 / Double(lastC)
        let ay = 0.4 / Double(lastR)
        for r in 0..<rows {
            for c in 0..<columns {
                var x = Double(c) / Double(lastC)
                var y = Double(r) / Double(lastR)
                let k = Double(r * columns + c)
                let p1 = k * 1.618
                let p2 = k * 2.399
                if c > 0 && c < lastC {
                    x += ax * (0.65 * sin(t / (1.4 + 0.17 * Double(r)) + p1) + 0.35 * sin(t / 3.1 + p2))
                }
                if r > 0 && r < lastR {
                    y += ay * (0.65 * cos(t / (1.7 + 0.21 * Double(c)) + p2) + 0.35 * sin(t / 3.7 + p1))
                }
                out.append(SIMD2<Float>(Float(x), Float(y)))
            }
        }
        return out
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            MeshGradient(width: columns, height: rows,
                         points: ArtworkMesh.points(columns: columns, rows: rows, t: t),
                         colors: blend(at: tl.date).map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: 1) },
                         background: .black,
                         smoothsColors: true,
                         colorSpace: .perceptual)
                .frame(width: size.width * ArtworkMesh.overscan, height: size.height * ArtworkMesh.overscan)
                .rotationEffect(.degrees(4 * sin(t / 23)))
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { to = colors.map(ArtworkMesh.rgb) }
        .onChange(of: colors) { _, new in
            let now = Date()
            from = blend(at: now)
            to = new.map(ArtworkMesh.rgb)
            changedAt = now
        }
    }
}
#endif

/// Tło dla iOS 17 (bez MeshGradient): gotowy, gładki obraz z kolorów siatki, który powoli się kołysze i "oddycha".
private struct ArtworkStill: View {
    let image: UIImage?
    let colors: [UIColor]
    let size: CGSize
    let speed: Double
    let paused: Bool

    @State private var fallback: UIImage? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            if let shown = image ?? fallback {
                Image(uiImage: shown)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width * 1.5, height: size.height * 1.5)
                    .rotationEffect(.degrees(8 * sin(t / 11)))
                    .scaleEffect(1 + 0.06 * sin(t / 7))
                    .offset(x: size.width * 0.06 * sin(t / 9), y: size.height * 0.05 * cos(t / 13))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: colors) {
            // Obraz z kolorów startowych (gdy nic nie gra) albo gdy gotowego jeszcze nie ma.
            fallback = ArtworkLoader.meshImage(colors, columns: AnimatedBackground.columns, rows: AnimatedBackground.rows)
        }
    }
}
