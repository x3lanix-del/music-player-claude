import SwiftUI
import UIKit

// MARK: - Własne ikony stacji (wybrane przez użytkownika)

/// Własne ikony stacji zapisane na dysku. `revision` rośnie przy każdej zmianie (zawsze z głównego wątku),
/// więc widoki same się odświeżają.
final class RadioIconStore: ObservableObject {
    static let shared = RadioIconStore()
    @Published private(set) var revision = 0

    private let dir: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/RadioCustom", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        dir = folder
    }

    static func fileName(for stationID: String) -> String {
        var h: UInt64 = 14695981039346656037
        for b in stationID.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16) + ".png"
    }

    func customURL(for stationID: String) -> URL {
        dir.appendingPathComponent(RadioIconStore.fileName(for: stationID))
    }

    func hasCustom(_ stationID: String) -> Bool {
        FileManager.default.fileExists(atPath: customURL(for: stationID).path)
    }

    /// Zapisuje wybrane zdjęcie jako ikonę stacji (kwadrat, max 256 px).
    @discardableResult
    func setCustom(_ data: Data, for stationID: String) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        let square = RadioIconStore.squareCrop(image, side: 256)
        guard let png = square.pngData() else { return false }
        do { try png.write(to: customURL(for: stationID), options: .atomic) } catch { return false }
        RadioIconCache.shared.forget(stationID)
        revision += 1
        return true
    }

    func removeCustom(for stationID: String) {
        try? FileManager.default.removeItem(at: customURL(for: stationID))
        RadioIconCache.shared.forget(stationID)
        revision += 1
    }

    private static func squareCrop(_ image: UIImage, side: CGFloat) -> UIImage {
        let w = image.size.width, h = image.size.height
        let m = min(w, h)
        guard m > 0 else { return image }
        let scale = side / m
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: (side - w * scale) / 2, y: (side - h * scale) / 2, width: w * scale, height: h * scale))
        }
    }
}

// MARK: - Automatyczne szukanie logo

/// Ogranicza liczbę jednoczesnych pobrań ikon (długa lista stacji nie zalewa sieci).
private actor IconGate {
    static let shared = IconGate()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if running < 5 { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

/// Logo stacji: własne (z galerii) -> logo z bazy stacji -> ikona strony stacji (kilka serwisów).
/// Wynik trafia do pamięci i na dysk (PNG, więc przezroczystość zostaje), dzięki czemu listy nie lagują.
final class RadioIconCache: @unchecked Sendable {
    static let shared = RadioIconCache()
    private let cache = NSCache<NSString, UIImage>()
    private let dir: URL
    private let lock = NSLock()
    private var failed = Set<String>()

    init() {
        cache.countLimit = 400
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/RadioIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        dir = folder
    }

    private func file(for stationID: String) -> URL {
        dir.appendingPathComponent("v2-" + RadioIconStore.fileName(for: stationID))
    }

    private func customFile(for stationID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Lumen/RadioCustom/" + RadioIconStore.fileName(for: stationID))
    }

    func cached(_ station: RadioStation) -> UIImage? { cache.object(forKey: station.id as NSString) }

    func forget(_ stationID: String) {
        cache.removeObject(forKey: stationID as NSString)
        lock.lock(); failed.remove(stationID); lock.unlock()
    }

    /// Adresy do wypróbowania, od najlepszego.
    static func candidates(for station: RadioStation) -> [URL] {
        var out: [String] = []
        if var icon = station.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty {
            if icon.hasPrefix("//") { icon = "https:" + icon }
            if icon.lowercased().hasPrefix("http://") {
                out.append("https://" + String(icon.dropFirst(7)))     // iOS i tak woli https
            }
            out.append(icon)
        }
        var hosts: [String] = []
        if let home = station.homepage, let h = host(of: home) { hosts.append(h) }
        for h in hosts {
            out.append("https://icons.duckduckgo.com/ip3/\(h).ico")
            out.append("https://t2.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&url=https://\(h)&size=128")
            out.append("https://\(h)/apple-touch-icon.png")
            out.append("https://\(h)/favicon.ico")
        }
        var seen = Set<String>()
        return out.compactMap { URL(string: $0) }.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func host(of text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard var h = URL(string: t)?.host?.lowercased(), h.contains(".") else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    private func fetch(_ url: URL) async -> UIImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              data.count > 120, let image = UIImage(data: data) else { return nil }
        // Zbyt małe obrazki (1x1, ikonki-zaślepki) odrzucamy.
        guard image.size.width >= 24, image.size.height >= 24 else { return nil }
        return image
    }

    /// Znajduje (lub wczytuje z dysku) ikonę stacji. nil = nic nie znaleziono (widać wtedy kafelek z literami).
    func resolve(_ station: RadioStation) async -> UIImage? {
        if let hit = cached(station) { return hit }

        // 1) Własna ikona wybrana przez użytkownika.
        if let data = try? Data(contentsOf: customFile(for: station.id)), let img = UIImage(data: data) {
            cache.setObject(img, forKey: station.id as NSString)
            return img
        }
        // 2) Zapisana wcześniej z internetu.
        let path = file(for: station.id)
        if let data = try? Data(contentsOf: path), let img = UIImage(data: data) {
            cache.setObject(img, forKey: station.id as NSString)
            return img
        }
        lock.lock(); let skip = failed.contains(station.id); lock.unlock()
        if skip { return nil }

        // 3) Szukanie w internecie (z ograniczeniem liczby równoległych pobrań).
        await IconGate.shared.enter()
        var found: UIImage? = nil
        for url in RadioIconCache.candidates(for: station) {
            if Task.isCancelled { break }
            if let img = await fetch(url) { found = img; break }
        }
        await IconGate.shared.leave()

        guard let full = found else {
            if !Task.isCancelled { lock.lock(); failed.insert(station.id); lock.unlock() }
            return nil
        }
        let small = ArtworkLoader.downscale(full, maxSide: 256)
        cache.setObject(small, forKey: station.id as NSString)
        if let png = small.pngData() { try? png.write(to: path, options: .atomic) }
        return small
    }
}

// MARK: - Widok ikony

/// Ikona stacji. Zanim logo się znajdzie (albo gdy go nie ma) widać kolorowy kafelek z literami nazwy,
/// więc każda stacja ma ikonę i nic nie "mruga" szarym polem.
struct RadioIcon: View {
    let station: RadioStation?
    var size: CGFloat = 52
    var radius: CGFloat? = nil
    var active: Bool = false
    @ObservedObject private var store = RadioIconStore.shared
    @State private var image: UIImage?

    init(station: RadioStation?, size: CGFloat = 52, radius: CGFloat? = nil, active: Bool = false) {
        self.station = station
        self.size = size
        self.radius = radius
        self.active = active
        _image = State(initialValue: station.flatMap { RadioIconCache.shared.cached($0) })
    }

    private var taskKey: String {
        "\(station?.id ?? "")|\(station?.icon ?? "")|\(station?.homepage ?? "")|\(store.revision)"
    }

    var body: some View {
        let r = radius ?? size * 0.2
        ZStack {
            if let image {
                RoundedRectangle(cornerRadius: r, style: .continuous).fill(Color.white.opacity(0.95))
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.1)
            } else {
                RadioMonogram(name: station?.name ?? "Radio", size: size)
            }
            if active && image == nil {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .task(id: taskKey) {
            guard let st = station else { image = nil; return }
            if let hit = RadioIconCache.shared.cached(st) { image = hit; return }
            image = nil          // inna stacja w tym samym wierszu: najpierw kafelek z literami, nie cudze logo
            let found = await RadioIconCache.shared.resolve(st)
            if !Task.isCancelled { image = found }
        }
    }
}

/// Kolorowy kafelek z literami nazwy stacji (kolor zależy od nazwy, więc każda stacja ma swój).
struct RadioMonogram: View {
    let name: String
    let size: CGFloat

    static func letters(_ name: String) -> String {
        let skip: Set<String> = ["radio", "fm", "online", "stream", "the", "pl", "www", "live"]
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
            .filter { !skip.contains($0.lowercased()) }
        if words.count >= 2 {
            return (String(words[0].prefix(1)) + String(words[1].prefix(1))).uppercased()
        }
        if let w = words.first { return String(w.prefix(2)).uppercased() }
        return String(name.prefix(2)).uppercased()
    }

    static func color(_ name: String) -> (Color, Color) {
        var h: UInt64 = 14695981039346656037
        for b in name.lowercased().utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let hue = Double(h % 360) / 360.0
        return (Color(hue: hue, saturation: 0.62, brightness: 0.78), Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.52))
    }

    var body: some View {
        let colors = RadioMonogram.color(name)
        ZStack {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(RadioMonogram.letters(name))
                .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
    }
}
