import UIKit

/// Downloads YouTube thumbnails, crops them to a square and picks the background colours from them.
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSString, UIImage>()

    /// Okładka z pamięci (bez czekania i bez sieci) - np. dla piosenki, która właśnie odjeżdża w animacji.
    func cached(_ id: String) -> UIImage? { cache.object(forKey: id as NSString) }

    /// Square, center-cropped artwork for a video id (best quality that exists).
    func artwork(for id: String) async -> UIImage? {
        if let hit = cache.object(forKey: id as NSString) { return hit }
        // Zapisana wcześniej na dysku (działa bez internetu).
        let file = ArtworkLoader.diskDir.appendingPathComponent("\(id).jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            cache.setObject(image, forKey: id as NSString)
            return image
        }
        for name in ["maxresdefault", "sddefault", "hqdefault", "mqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name).jpg") else { continue }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data),
                  let square = ArtworkLoader.squareCrop(image) else { continue }
            cache.setObject(square, forKey: id as NSString)
            let stored = ArtworkLoader.downscale(square, maxSide: 720)
            if let jpeg = stored.jpegData(compressionQuality: 0.88) { try? jpeg.write(to: file, options: .atomic) }
            return square
        }
        return nil
    }

    private static var diskDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Lumen/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func squareCrop(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        var content = CGRect(x: 0, y: 0, width: w, height: h)
        if abs(w / h - 4.0 / 3.0) < 0.03 {
            // 4:3 thumbnails are letterboxed 16:9 pictures
            let ch = (w * 9.0 / 16.0).rounded()
            content = CGRect(x: 0, y: ((h - ch) / 2).rounded(), width: w, height: ch)
        }
        let side = min(content.width, content.height)
        let rect = CGRect(x: (content.midX - side / 2).rounded(),
                          y: (content.midY - side / 2).rounded(),
                          width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }

    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Kolory tła z okładki

    private struct Sample {
        var r: CGFloat; var g: CGFloat; var b: CGFloat
        var h: CGFloat; var s: CGFloat; var v: CGFloat
        /// Kolor, nie szarość: liczy się "chroma" (nasycenie × jasność), więc pastelowy róż jest kolorem,
        /// a szum kompresji na szarym / ciemnym obrazku - nie.
        var colorful: Bool { v > 0.16 && s > 0.12 && s * v > 0.07 }
    }

    /// Próbki z siatki n x n (cały obraz, bez kadrowania), wierszami od góry.
    private static func samples(_ image: UIImage, side n: Int = 12) -> [Sample] {
        guard let cg = image.cgImage else { return [] }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let p = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var out: [Sample] = []
        out.reserveCapacity(n * n)
        for i in 0..<(n * n) {
            let r = CGFloat(p[i * 4]) / 255, g = CGFloat(p[i * 4 + 1]) / 255, b = CGFloat(p[i * 4 + 2]) / 255
            var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
            out.append(Sample(r: r, g: g, b: b, h: h, s: sat, v: v))
        }
        return out
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Kolor okładki przygotowany na tło pod biały tekst - tak, żeby dalej wyglądał jak ten z okładki:
    /// - jasne kolory są przyciemniane (żeby biały tekst był czytelny), a w zamian dostają więcej nasycenia:
    ///   jasny róż zostaje różem, a nie robi się szary / biały,
    /// - ciemne szarości zostają szare (niebieskawa szarość nie robi się niebieska),
    /// - czerń jest lekko rozjaśniona, żeby tło nie było martwą plamą.
    /// (Wartości dobrane na prawdziwych okładkach: szarej, kolorowej i jasnoróżowej.)
    private static func toned(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let sat = Double(s), val = Double(v)
        let bright = smoothstep(0.5, 0.95, val)
        // Im jaśniejszy kolor, tym mniejszy odcień wystarczy, żeby był "kolorem" (blady róż); ciemne szarości - nie.
        let low = 0.10 - 0.08 * bright
        let gate = smoothstep(low, low + 0.08, sat)
        let boost = 1.0 + (0.15 + 3.0 * bright) * gate
        let s2 = min(sat * boost, max(sat, 0.85))
        let knee = 0.45
        let v2 = max(val <= knee ? val : knee + (val - knee) * 0.3, 0.10)
        return (Double(h), s2, v2)
    }

    /// Kolory wierzchołków siatki tła (wierszami od góry) i ich średnia jasność.
    /// To po prostu bardzo mocno rozmyta okładka w rozdzielczości siatki: każdy wierzchołek jest średnią kolorów
    /// okładki z jego okolicy (waga Gaussa). Dzięki temu tło ma kolory okładki w tych samych miejscach i w tych
    /// samych proporcjach co okładka - mały kolorowy szczegół nie zalewa ekranu, a szara okładka zostaje szara.
    /// Każdy wierzchołek ma też minimalnie inną jasność (stałą dla piosenki), żeby jednolita okładka nie dawała
    /// martwej, płaskiej plamy.
    static func meshColors(of image: UIImage, columns: Int, rows: Int, seed: Int) -> (colors: [UIColor], brightness: Double) {
        let n = 24
        let px = samples(image, side: n)
        guard px.count == n * n, columns > 1, rows > 1 else { return ([], 0) }
        var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: seed))
        let sigmaX = 0.36 / Double(columns - 1)
        let sigmaY = 0.36 / Double(rows - 1)
        func weights(_ center: Double, _ sigma: Double) -> [Double] {
            (0..<n).map { i in
                let d = (Double(i) + 0.5) / Double(n) - center
                return exp(-(d * d) / (2 * sigma * sigma))
            }
        }
        var colors: [UIColor] = []
        colors.reserveCapacity(columns * rows)
        var light = 0.0
        for row in 0..<rows {
            let wy = weights(Double(row) / Double(rows - 1), sigmaY)
            for col in 0..<columns {
                let wx = weights(Double(col) / Double(columns - 1), sigmaX)
                var r = 0.0, g = 0.0, b = 0.0, sum = 0.0
                for y in 0..<n {
                    for x in 0..<n {
                        let w = wy[y] * wx[x]
                        let p = px[y * n + x]
                        r += Double(p.r) * w
                        g += Double(p.g) * w
                        b += Double(p.b) * w
                        sum += w
                    }
                }
                guard sum > 0 else {
                    colors.append(UIColor(white: 0.2, alpha: 1))
                    light += 0.2
                    continue
                }
                let t = toned(r: r / sum, g: g / sum, b: b / sum)
                let v = min(max(t.v * (1 + 0.08 * Double.random(in: -1...1, using: &rng)), 0), 1)
                let color = UIColor(hue: CGFloat(t.h), saturation: CGFloat(t.s), brightness: CGFloat(v), alpha: 1)
                colors.append(color)
                light += color.luminance
            }
        }
        return (colors, light / Double(colors.count))
    }

    /// Tło, gdy jeszcze nic nie gra: czarno-białe (odcienie szarości, bez żadnego koloru).
    static func idleMeshColors(columns: Int, rows: Int) -> [UIColor] {
        let levels: [CGFloat] = [0.42, 0.32, 0.24, 0.16, 0.09, 0.05]
        var rng = SeededRandom(seed: 0x4C554D454E)
        return (0..<(columns * rows)).map { _ in
            UIColor(white: levels[Int.random(in: 0..<levels.count, using: &rng)], alpha: 1)
        }
    }

    /// Gładki obraz z kolorów siatki (dla iOS 17, gdzie nie ma MeshGradient): każdy wierzchołek to jeden piksel,
    /// całość powiększona z wygładzaniem.
    static func meshImage(_ colors: [UIColor], columns: Int, rows: Int) -> UIImage? {
        guard colors.count == columns * rows, columns > 0, rows > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let tiny = UIGraphicsImageRenderer(size: CGSize(width: columns, height: rows), format: format).image { ctx in
            for r in 0..<rows {
                for c in 0..<columns {
                    colors[r * columns + c].setFill()
                    ctx.fill(CGRect(x: c, y: r, width: 1, height: 1))
                }
            }
        }
        let size = CGSize(width: columns * 24, height: rows * 24)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            tiny.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Kolor "klimatu" piosenki prosto z okładki - ale tylko wtedy, gdy jakiś kolor naprawdę na niej dominuje
    /// (co najmniej 18% obrazka). Mały kolorowy element na szarej okładce (np. niebieskie logo) nie barwi już
    /// aplikacji na niebiesko. Kolor jest rozjaśniony, żeby świecił na ciemnym tle. nil = biały.
    static func vibe(of image: UIImage) -> UIColor? {
        let all = samples(image)
        guard !all.isEmpty else { return nil }
        func distance(_ a: Sample, _ b: Sample) -> CGFloat {
            let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        var groups: [(first: Sample, r: CGFloat, g: CGFloat, b: CGFloat, count: Int)] = []
        for px in all where px.colorful {
            if let i = groups.firstIndex(where: { distance($0.first, px) <= 0.3 }) {
                groups[i].r += px.r; groups[i].g += px.g; groups[i].b += px.b; groups[i].count += 1
            } else {
                groups.append((px, px.r, px.g, px.b, 1))
            }
        }
        guard let top = groups.max(by: { $0.count < $1.count }),
              Double(top.count) / Double(all.count) >= 0.18 else { return nil }
        let n = CGFloat(top.count)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: top.r / n, green: top.g / n, blue: top.b / n, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return UIColor(hue: h, saturation: min(max(s * 1.15, 0.35), 0.8), brightness: max(v, 0.9), alpha: 1)
    }
}

/// Rozmiar siatki tła: 4 kolumny x 6 wierszy wierzchołków (pionowy ekran).
enum Backdrop {
    static let columns = 4
    static let rows = 6
}

/// Prosty generator liczb losowych z ziarnem: ta sama piosenka = zawsze takie samo tło.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
