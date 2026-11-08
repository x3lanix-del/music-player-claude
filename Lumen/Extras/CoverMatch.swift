import UIKit

/// Wybór właściwego wyniku YouTube Music dla piosenki ze Spotify: najpierw porównanie okładek (odcisk 8x8),
/// potem punktacja tytuł/wykonawca/czas. Gdy okładki się nie zgadzają, wygrywa najtrafniejszy i najwyżej w wynikach.
enum CoverMatch {
    static func pick(item: ExternalImport.Item, hits: [YTMusicSearch.Hit]) async -> YTMusicSearch.Hit? {
        guard !hits.isEmpty else { return nil }
        var spotifyHash: UInt64? = nil
        if let cover = item.cover { spotifyHash = await hash(of: cover) }

        var scored: [(score: Double, hit: YTMusicSearch.Hit)] = []
        for (rank, hit) in hits.enumerated() {
            var score = 0.0
            let titleSim = TitleCleaner.similarity(hit.track.title, item.title)
            let artistSim = item.artist.isEmpty ? 0.5 : TitleCleaner.similarity(hit.track.artist, item.artist)
            score += titleSim * 40 + artistSim * 25
            if item.duration > 0, hit.track.duration > 0 {
                let diff = abs(item.duration - hit.track.duration)
                score += diff <= 3 ? 20 : max(-20, 20 - diff * 2)
            }
            score -= Double(rank) * 1.5      // wyższa pozycja w YouTube Music = popularniejsze i trafniejsze
            if let sh = spotifyHash, let thumb = hit.thumb, let hh = await hash(of: thumb) {
                let dist = (sh ^ hh).nonzeroBitCount
                if dist <= 8 { score += 60 }          // ta sama okładka
                else if dist <= 14 { score += 20 }    // bardzo podobna (inne kadrowanie)
            }
            scored.append((score, hit))
        }
        return scored.max(by: { $0.score < $1.score })?.hit
    }

    private static func hash(of url: URL) async -> UInt64? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req), let image = UIImage(data: data)?.cgImage else { return nil }
        return averageHash(image)
    }

    /// Odcisk 8x8 w skali szarości (średnia jasność); odporny na różny rozmiar i kompresję.
    private static func averageHash(_ image: CGImage) -> UInt64? {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var h: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) >= mean { h |= (1 << UInt64(i)) }
        return h
    }
}
