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

    /// Tło z okładki jak w Apple Music: sama okładka, mocno rozmyta, w kilku wielkich warstwach, które powoli
    /// obracają się i krążą - po ekranie płyną prawdziwe kolory i kształty okładki.
    private func colorful(size: CGSize) -> some View {
        ZStack {
            Color.black
            if blurred != nil {
                ArtworkFlow(image: blurred, size: size, speed: max(0.25, settings.data.bgSpeed), paused: !isActive)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.24), Color(white: 0.07)], startPoint: .top, endPoint: .bottom)
            }
            Color.black.opacity(player ? shade : max(settings.data.dim, shade - 0.05))
                .animation(.easeInOut(duration: 1.0), value: shade)
        }
    }

    private func rebuild() async {
        guard player || settings.data.theme == .blur, let src = engine.artwork else {
            // Chwila przełączania piosenki (okładka jeszcze się ładuje): zostaje poprzednie tło, bez mignięcia czernią.
            if engine.currentTrack == nil { blurred = nil }
            return
        }
        // Jak w Apple Music: warstwy to zwykła (ostra) okładka - rozmycie dzieje się dopiero po złożeniu warstw,
        // więc widać płynące kształty i prawdziwe kolory okładki (bez żadnego "poprawiania" barw).
        let result = await Task.detached(priority: .utility) { () -> (UIImage, Double) in
            let small = ArtworkLoader.downscale(src, maxSide: 160)
            return (small, ArtworkLoader.meanBrightness(of: small))
        }.value
        // Jasna okładka dostaje trochę przyciemnienia pod biały tekst, ale tylko tyle, żeby kolor dalej był widać.
        let target = min(max(0.1 + (result.1 - 0.45) * 0.6, 0.1), 0.36)
        withAnimation(.easeInOut(duration: 1.0)) {
            blurred = result.0
            shade = target
        }
    }
}

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
