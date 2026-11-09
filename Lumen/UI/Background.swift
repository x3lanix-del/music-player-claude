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
        // Nasycenie zależy od tego, ile koloru naprawdę jest na okładce: szara zostaje szara, kolorowa jest żywa.
        let result = await Task.detached(priority: .utility) { () -> (UIImage?, Double) in
            let colorful = ArtworkLoader.colorfulness(of: src)
            let image = ArtworkLoader.blurred(src, radius: 9, saturation: colorful < 0.12 ? 0.3 : 1.05 + 0.5 * colorful,
                                              maxSide: 120)
            let light = image.map { ArtworkLoader.meanBrightness(of: $0) } ?? 0.4
            return (image, light)
        }.value
        guard let image = result.0 else { return }
        // Jasna okładka (np. biała / różowa) dostaje mocniejsze przyciemnienie, ciemna prawie żadnego.
        let target = min(max(0.14 + (result.1 - 0.4) * 0.75, 0.14), 0.55)
        withAnimation(.easeInOut(duration: 1.0)) {
            blurred = image
            shade = target
        }
    }
}

/// Ruchome tło z okładki. Trzy wielkie kopie rozmytej okładki (jedna odbita lustrzanie) obracają się w różnych
/// kierunkach i tempach, krążąc wokół różnych punktów ekranu - nakładają się półprzezroczyście, więc kolory okładki
/// mieszają się i płyną. Każda warstwa zawsze zakrywa cały ekran (żadnych krawędzi). Zmiana piosenki: nowa okładka
/// przenika się ze starą. Warstwy to zwykłe obrazki z obrotem (składa je karta graficzna), 30 klatek/s;
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

    private struct Layer {
        let cx: Double, cy: Double      // środek orbity (ułamek ekranu)
        let orbit: Double               // promień orbity (ułamek szerokości)
        let period: Double              // pełny obrót (s)
        let direction: Double           // 1 / -1
        let alpha: Double
        let mirror: Bool
    }

    private static let specs: [Layer] = [
        Layer(cx: 0.5, cy: 0.5, orbit: 0.05, period: 95, direction: 1, alpha: 1.0, mirror: false),
        Layer(cx: 0.28, cy: 0.32, orbit: 0.14, period: 66, direction: -1, alpha: 0.58, mirror: true),
        Layer(cx: 0.72, cy: 0.72, orbit: 0.14, period: 51, direction: 1, alpha: 0.46, mirror: false)
    ]

    private struct Placement {
        let x: CGFloat, y: CGFloat, side: CGFloat
        let angle: Double
        let alpha: Double
        let mirror: Bool
    }

    /// Gdzie w chwili `t` stoi każda warstwa.
    private static func placements(size: CGSize, t: Double) -> [Placement] {
        let w = Double(size.width)
        let h = Double(size.height)
        let halfDiagonal = (w * w + h * h).squareRoot() / 2
        return specs.enumerated().map { i, layer in
            let phase = Double(i) * 2.1
            let cx = w * layer.cx + w * layer.orbit * cos(t / (layer.period * 0.7) + phase)
            let cy = h * layer.cy + h * layer.orbit * 0.6 * sin(t / (layer.period * 0.9) + phase)
            let dx = cx - w / 2
            let dy = cy - h / 2
            let distance = (dx * dx + dy * dy).squareRoot()
            // Obrócony kwadrat zakrywa koło o promieniu połowy boku - więc bok sięga dalej niż najdalszy róg ekranu.
            let breathing = 1 + 0.05 * sin(t / 23 + phase)
            let side = 2 * (halfDiagonal + distance) * 1.08 * breathing
            let angle = layer.direction * t * 2 * Double.pi / layer.period + phase
            return Placement(x: CGFloat(cx), y: CGFloat(cy), side: CGFloat(side), angle: angle,
                             alpha: layer.alpha, mirror: layer.mirror)
        }
    }

    var body: some View {
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
            .frame(width: size.width, height: size.height)
        }
        .onAppear { current = image }
        .onChange(of: image) { _, new in
            guard let new = new, new !== current else { return }
            previous = current
            current = new
            changedAt = Date()
        }
    }

    /// Trzy warstwy jednej okładki (bez wspólnego bufora - każda warstwa to tylko obrócony obrazek).
    private func stack(_ img: UIImage, _ spots: [Placement], opacity: Double) -> some View {
        ZStack {
            ForEach(spots.indices, id: \.self) { i in
                let spot = spots[i]
                Image(uiImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: spot.side, height: spot.side)
                    .scaleEffect(x: spot.mirror ? -1 : 1, y: 1)
                    .rotationEffect(.radians(spot.angle))
                    .opacity(spot.alpha * opacity)
                    .position(x: spot.x, y: spot.y)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
