import SwiftUI
import UIKit

/// Very slow drift. The animation is handed to the render server once (repeatForever),
/// so SwiftUI does no work per frame.
private struct SlowDrift: ViewModifier {
    var swayX: CGFloat = 0
    var swayY: CGFloat = 0
    var seconds: Double = 60
    @EnvironmentObject private var settings: AppSettings

    @State private var sx: Double = -1
    @State private var sy: Double = -1

    func body(content: Content) -> some View {
        content
            .offset(x: swayX * CGFloat(sx), y: swayY * CGFloat(sy))
            .onAppear {
                withAnimation(.easeInOut(duration: seconds / max(0.25, settings.data.bgSpeed)).repeatForever(autoreverses: true)) { sx = 1 }
                withAnimation(.easeInOut(duration: seconds * 1.31 / max(0.25, settings.data.bgSpeed)).repeatForever(autoreverses: true)) { sy = 1 }
            }
    }
}

/// App wallpaper: plain black, plain white, a custom colour/photo, or the flowing liquid-glass made from the song cover.
/// `player: true` (Now Playing / radio player) always shows the flowing cover glass, whatever wallpaper is set for the app.
struct AnimatedBackground: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var engine: PlayerEngine
    var isActive: Bool = true
    var player: Bool = false
    @State private var blurred: UIImage? = nil
    @State private var blurVersion = 0

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

    /// Kolory z okładki, mocniej nasycone i jaśniejsze (żeby ruch było widać); gdy jest ich mało, dochodzą ich warianty odcienia.
    private var colors: [Color] {
        var base = Array(engine.palette.prefix(5))
        if base.isEmpty { return [Color(white: 0.5), Color(white: 0.3)] }
        func boosted(_ c: UIColor, hueShift: CGFloat = 0) -> Color {
            var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            guard c.getHue(&h, saturation: &sat, brightness: &br, alpha: &a) else { return Color(uiColor: c) }
            let hue = (h + hueShift).truncatingRemainder(dividingBy: 1)
            // Szarości (mała saturacja) zostają szare, ale jaśniejsze; kolory dostają mocny, czysty odcień.
            // Delikatna korekta, nie przemalowanie: kolory mają zostać rozpoznawalne jako te z okładki.
            let s2 = sat < 0.12 ? sat : min(1, sat * 1.12)
            let b2 = min(1, max(br, 0.4) * 1.05)
            return Color(hue: Double(hue < 0 ? hue + 1 : hue), saturation: Double(s2), brightness: Double(b2))
        }
        var out = base.map { boosted($0) }
        var shift: CGFloat = 0.08
        while out.count < 5 {
            out.append(boosted(base[out.count % base.count], hueShift: shift))
            shift += 0.07
        }
        base.removeAll()
        return out
    }

    private func colorful(size: CGSize) -> some View {
        ZStack {
            Color.black
            if let img = blurred {
                // Rozciągnięte na cały ekran (bez kadrowania do środka), więc widać WSZYSTKIE kolory okładki.
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width * 1.25, height: size.height * 1.25)
                    .modifier(SlowDrift(swayX: size.width * 0.08, swayY: size.height * 0.06, seconds: 40))
                    .opacity(0.5)
                    .id(blurVersion)
                    .transition(.opacity)
            }
            blobs(size: size)
                .id(blurVersion)
                .transition(.opacity)
            Color.black.opacity(player ? min(settings.data.dim, 0.12) : settings.data.dim)
        }
    }

    private func blobs(size: CGSize) -> some View {
        FlowingGlass(colors: colors, speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
            .frame(width: size.width, height: size.height)
    }

    private func rebuild() async {
        guard player || settings.data.theme == .blur, let src = engine.artwork else {
            if engine.artwork == nil { blurred = nil }
            return
        }
        let result = await Task.detached(priority: .utility) { ArtworkLoader.blurred(src, radius: 9, saturation: 1.6) }.value
        // Płynne przejście kolorów (rozmyty obraz i plamy zmieniają się z wygaszaniem, a nie skokiem).
        withAnimation(.easeInOut(duration: 1.3)) {
            blurred = result
            blurVersion += 1
        }
    }
}

/// Płynące tło w stylu liquid glass: duże, miękkie plamy kolorów z okładki i kilka półprzezroczystych,
/// pochylonych tafli szkła, które bardzo wolno dryfują, obracają się i zmieniają kształt.
/// Rysowane jednym Canvasem (30 klatek/s), a gdy ekran jest nieaktywny, animacja stoi.
private struct FlowingGlass: View {
    let colors: [Color]
    let speed: Double
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate * speed
                let big = max(size.width, size.height)

                // 1) Plamy koloru: każda krąży po własnym torze (różne okresy ~20-40 s), rozciąga się i obraca.
                let count = max(8, colors.count + 3)
                for i in 0..<count {
                    let c = colors[i % colors.count]
                    let ph = Double(i) * 1.83
                    let x = size.width * (0.5 + 0.55 * sin(t / (8 + Double(i) * 1.3) + ph))
                    let y = size.height * (0.5 + 0.52 * cos(t / (10 + Double(i) * 1.1) + ph * 1.4))
                    let r = big * (0.50 + 0.18 * sin(t / (6 + Double(i) * 0.9) + ph))
                    let angle = t / (14 + Double(i) * 2) + ph
                    let squash = 0.5 + 0.3 * sin(t / (9 + Double(i)) + ph)
                    var g = ctx
                    g.blendMode = .plusLighter      // nakładające się plamy świecą i mieszają kolory
                    g.translateBy(x: x, y: y)
                    g.rotate(by: .radians(angle))
                    g.scaleBy(x: 1, y: squash)
                    let rect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
                    g.fill(Path(ellipseIn: rect),
                           with: .radialGradient(Gradient(stops: [.init(color: c.opacity(0.85), location: 0), .init(color: c.opacity(0.45), location: 0.5), .init(color: c.opacity(0), location: 1)]),
                                                 center: .zero, startRadius: 0, endRadius: r))
                }

                // 2) Tafle szkła: długie, pochylone pasy jaśniejszego światła, które przesuwają się przez ekran.
                for k in 0..<3 {
                    let ph = Double(k) * 2.4
                    let cx = size.width * (0.5 + 0.55 * sin(t / (38 + Double(k) * 9) + ph))
                    let cy = size.height * (0.5 + 0.30 * cos(t / (47 + Double(k) * 7) + ph))
                    let w = big * (0.30 + 0.10 * sin(t / 23 + ph))
                    var g = ctx
                    g.translateBy(x: cx, y: cy)
                    g.rotate(by: .radians(0.45 + 0.35 * sin(t / (55 + Double(k) * 11) + ph)))
                    let rect = CGRect(x: -w / 2, y: -big, width: w, height: big * 2)
                    g.fill(Path(rect),
                           with: .linearGradient(Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.20), Color.white.opacity(0)]),
                                                 startPoint: CGPoint(x: -w / 2, y: 0), endPoint: CGPoint(x: w / 2, y: 0)))
                }
            }
        }
    }
}
