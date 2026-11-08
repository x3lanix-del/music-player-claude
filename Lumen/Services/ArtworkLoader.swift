import UIKit
import CoreImage

/// Downloads YouTube thumbnails, crops them to a square and builds blurred backgrounds.
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSString, UIImage>()
    private static let ciContext = CIContext(options: nil)

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

    /// Small, pre-blurred, saturated copy used by the animated background.
    static func blurred(_ image: UIImage, radius: Double, saturation: Double = 1.45) -> UIImage? {
        let small = downscale(image, maxSide: 64)
        guard let input = CIImage(image: small) else { return nil }
        let extent = input.extent
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard var out = blur.outputImage?.cropped(to: extent) else { return nil }
        if let color = CIFilter(name: "CIColorControls") {
            color.setValue(out, forKey: kCIInputImageKey)
            color.setValue(saturation, forKey: kCIInputSaturationKey)
            if let o = color.outputImage { out = o }
        }
        guard let cg = ciContext.createCGImage(out, from: extent) else { return nil }
        return UIImage(cgImage: cg)
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
        var colorful: Bool { v > 0.16 && s > 0.22 }
    }

    /// Próbki z siatki 12x12 (cały obraz, bez kadrowania).
    private static func samples(_ image: UIImage) -> [Sample] {
        guard let cg = image.cgImage else { return [] }
        let n = 12
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

    /// Jaka część okładki jest naprawdę kolorowa (0 = szara / czarno-biała, 1 = cała w kolorze).
    static func colorfulness(of image: UIImage) -> Double {
        let all = samples(image)
        guard !all.isEmpty else { return 0 }
        let meanS = all.reduce(0) { $0 + $1.s } / CGFloat(all.count)
        guard meanS > 0.08 else { return 0 }
        return Double(all.filter { $0.colorful }.count) / Double(all.count)
    }

    /// Do 5 kolorów tła, w takich proporcjach, w jakich naprawdę są na okładce:
    /// - szara / czarno-biała okładka = szare tło (szum kompresji JPEG nie robi już różowych plam),
    /// - okładka częściowo szara = część palety szara, część w kolorach okładki,
    /// - kolor, który zajmuje tylko mały kawałek okładki (< 3%), nie trafia do tła,
    /// - kolory są uśrednione z prawdziwych pikseli (bez sztucznego podbijania i wymyślonych odcieni).
    static func palette(from image: UIImage) -> [UIColor] {
        let all = samples(image)
        guard !all.isEmpty else { return [] }
        let k = CGFloat(all.count)
        let colorful = all.filter { $0.colorful }
        let neutral = all.filter { !$0.colorful }
        let share = CGFloat(colorful.count) / k
        let meanS = all.reduce(0) { $0 + $1.s } / k
        guard meanS > 0.08, share >= 0.12 else { return grayPalette(from: neutral.isEmpty ? all : neutral) }

        func distance(_ a: Sample, _ b: Sample) -> CGFloat {
            let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        // Grupy podobnych kolorów: suma składowych (do średniej) i liczba pikseli.
        var groups: [(first: Sample, r: CGFloat, g: CGFloat, b: CGFloat, count: Int)] = []
        for px in colorful.sorted(by: { $0.s * 0.7 + $0.v * 0.3 > $1.s * 0.7 + $1.v * 0.3 }) {
            if let i = groups.firstIndex(where: { distance($0.first, px) <= 0.3 }) {
                groups[i].r += px.r; groups[i].g += px.g; groups[i].b += px.b; groups[i].count += 1
            } else {
                groups.append((px, px.r, px.g, px.b, 1))
            }
        }
        let minCount = max(2, Int((k * 0.03).rounded()))
        let main = groups.filter { $0.count >= minCount }.sorted { $0.count > $1.count }
        guard !main.isEmpty else { return grayPalette(from: neutral.isEmpty ? all : neutral) }

        // Ile miejsc w palecie dostają kolory: tyle, ile okładki jest kolorowe (reszta to jej szarości).
        let slots = min(main.count, max(1, Int((share * 5).rounded())))
        var out: [UIColor] = main.prefix(slots).map { g in
            let n = CGFloat(g.count)
            var h: CGFloat = 0, sat: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: g.r / n, green: g.g / n, blue: g.b / n, alpha: 1).getHue(&h, saturation: &sat, brightness: &v, alpha: &a)
            // Tylko lekka korekta, żeby plamy było widać na ciemnym tle - odcień i nasycenie zostają z okładki.
            return UIColor(hue: h, saturation: min(1, sat * 1.05), brightness: max(v, 0.38), alpha: 1)
        }
        if out.count < 5, share < 0.85, !neutral.isEmpty {
            let grays = grayPalette(from: neutral)
            var i = 0
            while out.count < 5 {
                out.append(grays[i % grays.count])
                i += 1
            }
        }
        return out
    }

    /// Odcienie "szarości" z rozpiętości jasności prawdziwych pikseli okładki. Zostaje tylko taki odcień,
    /// jaki ma średnio cała szara część (np. ciepła szarość), i to mocno stonowany - zero wymyślonego koloru.
    private static func grayPalette(from px: [Sample]) -> [UIColor] {
        guard !px.isEmpty else { return [UIColor(white: 0.3, alpha: 1)] }
        let n = CGFloat(px.count)
        let mr = px.reduce(0) { $0 + $1.r } / n, mg = px.reduce(0) { $0 + $1.g } / n, mb = px.reduce(0) { $0 + $1.b } / n
        var tintH: CGFloat = 0, tintS: CGFloat = 0, tv: CGFloat = 0, ta: CGFloat = 0
        UIColor(red: mr, green: mg, blue: mb, alpha: 1).getHue(&tintH, saturation: &tintS, brightness: &tv, alpha: &ta)
        let tint = tintS < 0.06 ? 0 : min(tintS * 0.8, 0.1)
        let levels = px.map { $0.v }.sorted()
        let picks = [0.15, 0.35, 0.55, 0.75, 0.9].map { levels[min(levels.count - 1, Int(Double(levels.count - 1) * $0))] }
        return picks.map { UIColor(hue: tintH, saturation: tint, brightness: max(0.22, min(0.82, $0)), alpha: 1) }
    }
}
