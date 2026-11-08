import UIKit
import CoreImage

/// Downloads YouTube thumbnails, crops them to a square and builds blurred backgrounds.
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private let cache = NSCache<NSString, UIImage>()
    private static let ciContext = CIContext(options: nil)

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

    /// Do 5 wyrazistych, różnych kolorów z okładki (nie średnia, która robi błoto): próbki z siatki 10x10,
    /// odrzucone czerń/biel/szarość, wybór zachłannie po jak największej różnicy, kolory lekko podbite.
    static func palette(from image: UIImage) -> [UIColor] {
        guard let cg = image.cgImage else { return [] }
        let n = 10
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let p = raw.bindMemory(to: UInt8.self, capacity: n * n * 4)

        struct Sample { var r: CGFloat; var g: CGFloat; var b: CGFloat; var h: CGFloat; var s: CGFloat; var v: CGFloat; var score: CGFloat }
        var all: [Sample] = []
        var candidates: [Sample] = []
        var meanR: CGFloat = 0, meanG: CGFloat = 0, meanB: CGFloat = 0, meanS: CGFloat = 0
        for i in 0..<(n * n) {
            let r = CGFloat(p[i * 4]) / 255, g = CGFloat(p[i * 4 + 1]) / 255, b = CGFloat(p[i * 4 + 2]) / 255
            meanR += r; meanG += g; meanB += b
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            meanS += s
            let sample = Sample(r: r, g: g, b: b, h: h, s: s, v: v, score: s * 0.7 + v * 0.3)
            all.append(sample)
            guard v > 0.16, s > 0.22 else { continue }      // czerń i szarości nie robią koloru tła
            candidates.append(sample)
        }
        let k = CGFloat(n * n)
        // Szara/czarno-biała okładka: szum kompresji JPEG czasem barwi pojedyncze piksele (np. na różowo),
        // a przy mało kolorowej okładce te kilka "naładowanych" pikseli potrafi zdominować całą paletę.
        // Średnie nasycenie całego obrazka (nie tylko wybranych próbek) mówi, czy okładka naprawdę ma kolor.
        guard meanS / k > 0.07, candidates.count >= 5 else {
            return grayPalette(from: all.map { $0.v })
        }
        func distance(_ a: Sample, _ b: Sample) -> CGFloat {
            let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        var picked: [Sample] = []
        for s in candidates.sorted(by: { $0.score > $1.score }) {
            if picked.allSatisfy({ distance($0, s) > 0.32 }) { picked.append(s) }
            if picked.count == 5 { break }
        }
        if picked.isEmpty { return grayPalette(from: all.map { $0.v }) }
        return picked.map {
            UIColor(hue: $0.h, saturation: min(1, $0.s * 1.25), brightness: max($0.v, 0.5), alpha: 1)
        }
    }

    /// Paleta odcieni szarości z rozpiętości jasności prawdziwych pikseli okładki (zero sztucznego koloru).
    private static func grayPalette(from values: [CGFloat]) -> [UIColor] {
        let levels = values.sorted()
        guard !levels.isEmpty else { return [UIColor(white: 0.3, alpha: 1)] }
        let picks = [0.15, 0.35, 0.55, 0.75, 0.9].map { levels[min(levels.count - 1, Int(Double(levels.count - 1) * $0))] }
        return picks.map { UIColor(white: max(0.22, min(0.82, $0)), alpha: 1) }
    }
}
