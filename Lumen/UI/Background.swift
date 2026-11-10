import SwiftUI
import UIKit

/// App wallpaper: plain black, plain white, a custom colour/photo, or the moving cover background (like Apple Music).
/// `player: true` (Now Playing / radio player) always shows the moving cover, whatever wallpaper is set for the app.
struct AnimatedBackground: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    var isActive: Bool = true
    var player: Bool = false
    @State private var blurred: UIImage? = nil
    /// Kolory siatki tła (dominujące kolory okładki rozłożone na 4x4 pola).
    @State private var mesh: [UIColor] = []
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

    /// Tło jak w Apple Music: siatka dominujących kolorów okładki, płynnie przechodzących w siebie i powoli
    /// falujących (iOS 18+: MeshGradient). Na iOS 17 - obracające się, rozmyte kopie okładki.
    private func colorful(size: CGSize) -> some View {
        ZStack {
            Color.black
            if blurred != nil {
                flow(size: size)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(player ? shade : max(settings.data.dim, shade - 0.05))
                .animation(.easeInOut(duration: 1.0), value: shade)
        }
    }

    @ViewBuilder private func flow(size: CGSize) -> some View {
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            if mesh.isEmpty {
                ArtworkFlow(image: blurred, size: size, speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
            } else {
                MeshFlow(colors: mesh, speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
            }
        } else {
            ArtworkFlow(image: blurred, size: size, speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
        }
        #else
        ArtworkFlow(image: blurred, size: size, speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
        #endif
    }

    private func rebuild() async {
        guard player || settings.data.theme == .blur, let src = engine.artwork else {
            // Chwila przełączania piosenki (okładka jeszcze się ładuje): zostaje poprzednie tło, bez mignięcia czernią.
            if engine.currentTrack == nil { blurred = nil }
            return
        }
        // Jak w Apple Music: warstwy to zwykła (ostra) okładka - rozmycie dzieje się dopiero po złożeniu warstw,
        // więc widać płynące kształty i prawdziwe kolory okładki (bez żadnego "poprawiania" barw).
        let seed = LyricsProviders.stableID(engine.currentTrack?.id ?? "")
        let result = await Task.detached(priority: .utility) { () -> (UIImage, Double, [UIColor]) in
            let small = ArtworkLoader.downscale(src, maxSide: 160)
            return (small, ArtworkLoader.meanBrightness(of: small), ArtworkLoader.meshColors(of: small, seed: seed))
        }.value
        // Jasna okładka dostaje trochę przyciemnienia pod biały tekst, ale tylko tyle, żeby kolor dalej był widać.
        let target = min(max(0.1 + (result.1 - 0.45) * 0.6, 0.1), 0.36)
        withAnimation(.easeInOut(duration: 1.0)) {
            blurred = result.0
            shade = target
            mesh = result.2
        }
    }
}

#if compiler(>=6.0)
/// Tło jak w Apple Music: siatka 4x4 punktów, każdy w jednym z dominujących kolorów okładki (tyle pól, ile koloru
/// jest na okładce), kolory płynnie przechodzą w siebie (MeshGradient). Punkty wewnątrz i na brzegach powoli
/// falują (każdy w swoim tempie), więc plamy kolorów płyną po ekranie; rogi stoją, więc ekran jest zawsze zakryty.
/// Przy zmianie piosenki kolory przechodzą płynnie w nowe. 30 klatek/s, ekran nieaktywny = animacja stoi.
@available(iOS 18.0, *)
private struct MeshFlow: View {
    let colors: [UIColor]
    let speed: Double
    let paused: Bool

    private struct RGBA: Equatable {
        var r: Double, g: Double, b: Double, a: Double
    }

    @State private var from: [RGBA] = []
    @State private var to: [RGBA] = []
    @State private var changedAt = Date.distantPast
    private static let fade = 1.4
    private static let side = 4

    private static func rgba(_ c: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    private static func fit(_ list: [RGBA]) -> [RGBA] {
        let n = side * side
        guard !list.isEmpty else { return Array(repeating: RGBA(r: 0.2, g: 0.2, b: 0.2, a: 1), count: n) }
        return (0..<n).map { list[$0 % list.count] }
    }

    /// Kolory w danej chwili (w trakcie zmiany piosenki: mieszanka starych i nowych).
    private func palette(at date: Date) -> [Color] {
        let target = MeshFlow.fit(to.isEmpty ? colors.map(MeshFlow.rgba) : to)
        var out = target
        if !from.isEmpty {
            let p = min(max(date.timeIntervalSince(changedAt) / MeshFlow.fade, 0), 1)
            if p < 1 {
                let e = p * p * (3 - 2 * p)
                let start = MeshFlow.fit(from)
                out = zip(start, target).map { a, b in
                    RGBA(r: a.r + (b.r - a.r) * e, g: a.g + (b.g - a.g) * e,
                         b: a.b + (b.b - a.b) * e, a: a.a + (b.a - a.a) * e)
                }
            }
        }
        return out.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) }
    }

    /// Położenie punktów siatki w chwili `t` (0...1). Rogi stoją, brzegi suwają się wzdłuż krawędzi, środek faluje.
    private static func points(t: Double) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        let last = side - 1
        for row in 0..<side {
            for col in 0..<side {
                var x = Double(col) / Double(last)
                var y = Double(row) / Double(last)
                let phase = Double(row * side + col) * 1.37
                let innerX = col > 0 && col < last
                let innerY = row > 0 && row < last
                if innerX { x += 0.14 * sin(t / (3.1 + Double(row) * 0.6) + phase) }
                if innerY { y += 0.14 * cos(t / (3.7 + Double(col) * 0.5) + phase * 0.8) }
                out.append(SIMD2<Float>(Float(x), Float(y)))
            }
        }
        return out
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            MeshGradient(width: MeshFlow.side, height: MeshFlow.side,
                         points: MeshFlow.points(t: t),
                         colors: palette(at: tl.date),
                         smoothsColors: true)
                .saturation(1.12)
        }
        .onAppear { to = colors.map(MeshFlow.rgba) }
        .onChange(of: colors) { _, new in
            let now = Date()
            from = palette(at: now).map { MeshFlow.rgba(UIColor($0)) }
            to = new.map(MeshFlow.rgba)
            changedAt = now
        }
    }
}
#endif

/// Ruchome tło z okładki jak w Apple Music: kilka kopii okładki (różne rozmiary, jedna wielka pod spodem) krąży
/// i obraca się w różnych tempach i kierunkach, a dopiero potem całość jest mocno rozmyta i lekko nasycona -
/// kolory i kształty okładki płyną po ekranie.
/// Warstwy składamy i rozmywamy w 1/6 rozdzielczości (rozmycie jest wtedy bardzo tanie), a gotowy obraz
/// powiększamy - i tak ma być miękki. Zmiana piosenki: nowa okładka przenika się ze starą. 30 klatek/s;
/// ekran nieaktywny = animacja stoi.
private struct ArtworkFlow: View {
    let image: UIImage?
    let size: CGSize
    let speed: Double
    let paused: Bool

    @State private var current: UIImage? = nil
    @State private var previous: UIImage? = nil
    @State private var changedAt = Date.distantPast
    private static let fade = 1.2
    /// Ile razy mniejsza jest scena, w której mieszamy i rozmywamy warstwy.
    private static let downsample: CGFloat = 6
    /// Scena jest trochę większa niż ekran, żeby brzegi rozmycia były poza ekranem.
    private static let overscan: CGFloat = 1.3

    private struct Layer {
        let cx: Double, cy: Double      // środek (ułamek szerokości / wysokości ekranu)
        let side: Double                // bok (ułamek wysokości ekranu)
        let orbit: Double               // promień krążenia (ułamek wysokości ekranu)
        let period: Double              // pełny obrót (s)
        let direction: Double           // 1 / -1
        let alpha: Double
        let mirror: Bool
    }

    /// Pierwsza warstwa jest tak duża, że zawsze zakrywa całą scenę; mniejsze nad nią niosą kształty i ruch.
    private static let specs: [Layer] = [
        Layer(cx: 0.50, cy: 0.50, side: 1.70, orbit: 0.00, period: 110, direction: 1, alpha: 1.0, mirror: false),
        Layer(cx: 0.20, cy: 0.22, side: 0.78, orbit: 0.07, period: 34, direction: 1, alpha: 0.9, mirror: false),
        Layer(cx: 0.86, cy: 0.58, side: 0.72, orbit: 0.08, period: 42, direction: -1, alpha: 0.85, mirror: true),
        Layer(cx: 0.32, cy: 0.88, side: 0.66, orbit: 0.06, period: 29, direction: 1, alpha: 0.8, mirror: true),
        Layer(cx: 0.78, cy: 0.12, side: 0.50, orbit: 0.05, period: 24, direction: -1, alpha: 0.75, mirror: false)
    ]

    private struct Placement {
        let x: CGFloat, y: CGFloat, side: CGFloat
        let angle: Double
        let alpha: Double
        let mirror: Bool
    }

    /// Gdzie w chwili `t` stoi każda warstwa - w punktach małej sceny.
    private static func placements(size: CGSize, t: Double) -> [Placement] {
        let w = Double(size.width)
        let h = Double(size.height)
        let k = Double(downsample)
        let pad = Double(overscan - 1) / 2
        return specs.enumerated().map { i, layer in
            let phase = Double(i) * 1.7
            let x = w * layer.cx + h * layer.orbit * cos(t / (layer.period * 0.8) + phase)
            let y = h * layer.cy + h * layer.orbit * sin(t / (layer.period * 1.1) + phase)
            let angle = layer.direction * t * 2 * Double.pi / layer.period + phase
            return Placement(x: CGFloat((x + w * pad) / k), y: CGFloat((y + h * pad) / k),
                             side: CGFloat(h * layer.side / k), angle: angle,
                             alpha: layer.alpha, mirror: layer.mirror)
        }
    }

    var body: some View {
        let k = ArtworkFlow.downsample
        let sceneW = size.width * ArtworkFlow.overscan / k
        let sceneH = size.height * ArtworkFlow.overscan / k
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate * speed
            let p = min(max(tl.date.timeIntervalSince(changedAt) / ArtworkFlow.fade, 0), 1)
            let e = p * p * (3 - 2 * p)
            let spots = ArtworkFlow.placements(size: size, t: t)
            ZStack {
                if let old = previous, e < 1 {
                    stack(old, spots, opacity: 1)
                }
                if let img = current ?? image {
                    stack(img, spots, opacity: previous == nil ? 1 : e)
                }
            }
            .frame(width: sceneW, height: sceneH)
            // Najpierw złożenie, potem mocne rozmycie (opaque: bez ciemnych brzegów) i lekkie nasycenie.
            .blur(radius: 11, opaque: true)
            .saturation(1.3)
            .drawingGroup()
            .scaleEffect(k)
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .onAppear { current = image }
        .onChange(of: image) { _, new in
            guard let new = new, new !== current else { return }
            previous = current
            current = new
            changedAt = Date()
        }
    }

    /// Warstwy jednej okładki.
    private func stack(_ img: UIImage, _ spots: [Placement], opacity: Double) -> some View {
        ZStack {
            ForEach(spots.indices, id: \.self) { i in
                let spot = spots[i]
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: spot.side, height: spot.side)
                    .scaleEffect(x: spot.mirror ? -1 : 1, y: 1)
                    .rotationEffect(.radians(spot.angle))
                    .opacity(spot.alpha * opacity)
                    .position(x: spot.x, y: spot.y)
            }
        }
    }
}
