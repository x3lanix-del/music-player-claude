import SwiftUI

/// Miniatury piosenek: pamięć (żeby listy nie lagowały) ORAZ dysk. Każda miniatura raz pobrana zostaje na stałe,
/// więc wszystkie okładki widać też bez internetu i po restarcie aplikacji.
///
/// Dwa rozmiary:
/// - mała (kwadrat 180 px, do wierszy list) - z miniatury mqdefault,
/// - duża (kwadrat do 360 px, do kafelków i dużych okładek) - z sddefault / hqdefault.
/// (Wcześniej wszędzie była jedna miniatura o wysokości ok. 100 px, więc duże kafelki były rozmazane.)
final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSURL, UIImage>()
    private let largeCache = NSCache<NSString, UIImage>()
    private let dir: URL
    private let lock = NSLock()
    private var fetching = Set<String>()

    init() {
        cache.countLimit = 400
        largeCache.countLimit = 90
        largeCache.totalCostLimit = 48 * 1024 * 1024
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var folder = base.appendingPathComponent("Lumen/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        dir = folder
    }

    /// Identyfikator filmu z adresu miniatury (.../vi/<id>/mqdefault.jpg) albo bezpieczna nazwa z całego adresu.
    private func name(for url: URL) -> String {
        let parts = url.pathComponents
        if let i = parts.firstIndex(of: "vi"), i + 1 < parts.count { return parts[i + 1] }
        let safe = Data(url.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return String(safe.prefix(80))
    }

    /// Plik małej miniatury. Od 1.37 jest ostrzejsza (kwadrat 180 px, plik "<id>@2.jpg"); starsze, mniejsze
    /// pliki "<id>.jpg" zostają jako zapas, dopóki nowa się nie pobierze.
    private func fileURL(for url: URL, legacy: Bool = false) -> URL {
        dir.appendingPathComponent(name(for: url) + (legacy ? ".jpg" : "@2.jpg"))
    }

    func hasOnDisk(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: fileURL(for: url).path) }

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let hit = image(for: url) { return hit }
        let file = fileURL(for: url)
        if let data = try? Data(contentsOf: file), let disk = UIImage(data: data) {
            cache.setObject(disk, forKey: url as NSURL)
            return disk
        }
        // Stara (mniejsza) miniatura z dysku: pokazujemy ją od razu, a ostrzejszą dociągamy w tle na następny raz.
        let old = fileURL(for: url, legacy: true)
        if let data = try? Data(contentsOf: old), let disk = UIImage(data: data) {
            cache.setObject(disk, forKey: url as NSURL)
            let key = "up:" + url.absoluteString
            if begin(key) {
                Task.detached(priority: .utility) { [self] in
                    _ = await download(url)
                    end(key)
                }
            }
            return disk
        }
        return await download(url)
    }

    /// Pobiera miniaturę, wycina kwadrat ze środka (okładka), zapisuje w pamięci i na dysku.
    private func download(_ url: URL) async -> UIImage? {
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode ?? 200 == 200,
              let full = UIImage(data: data) else { return nil }
        let small = ArtworkLoader.downscale(ArtworkLoader.squareCrop(full) ?? full, maxSide: 180)
        cache.setObject(small, forKey: url as NSURL)
        if let jpeg = small.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: fileURL(for: url), options: .atomic)
            try? FileManager.default.removeItem(at: fileURL(for: url, legacy: true))
        }
        return small
    }

    // MARK: Duże okładki (kafelki na Głównej, góra playlisty)

    func largeImage(for id: String) -> UIImage? { largeCache.object(forKey: id as NSString) }

    private func keepLarge(_ image: UIImage, id: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale) * 4
        largeCache.setObject(image, forKey: id as NSString, cost: cost)
    }

    /// Ostra, kwadratowa okładka piosenki: sddefault (640x480), a gdy jej nie ma - hqdefault (480x360).
    func loadLarge(_ id: String) async -> UIImage? {
        if let hit = largeImage(for: id) { return hit }
        let file = dir.appendingPathComponent("\(id)@L.jpg")
        if let data = try? Data(contentsOf: file), let disk = UIImage(data: data) {
            keepLarge(disk, id: id)
            return disk
        }
        for quality in ["sddefault", "hqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(quality).jpg"),
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let full = UIImage(data: data),
                  let square = ArtworkLoader.squareCrop(full) else { continue }
            let image = ArtworkLoader.downscale(square, maxSide: 360)
            keepLarge(image, id: id)
            if let jpeg = image.jpegData(compressionQuality: 0.85) { try? jpeg.write(to: file, options: .atomic) }
            return image
        }
        return nil
    }

    /// Pobiera w tle miniatury wszystkich podanych piosenek, które nie są jeszcze zapisane na dysku.
    func prefetch(_ tracks: [Track]) {
        let urls = tracks.compactMap { $0.artworkURL }.filter { !hasOnDisk($0) }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) { [self] in
            for url in urls {
                let key = url.absoluteString
                guard begin(key) else { continue }
                _ = await load(url)
                end(key)
            }
        }
    }

    private func begin(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return fetching.insert(key).inserted
    }

    private func end(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        fetching.remove(key)
    }
}

struct TrackThumb: View {
    @Environment(\.ink) private var ink
    let track: Track
    var size: CGFloat = 52
    var cornerRadius: CGFloat? = nil
    @State private var image: UIImage?

    /// Duże kafelki (od 80 pt) dostają ostrzejszą okładkę; małe wiersze list - zwykłą miniaturę.
    private var wantsLarge: Bool { size >= 80 && !track.isRadio }

    init(track: Track, size: CGFloat = 52, cornerRadius: CGFloat? = nil) {
        self.track = track
        self.size = size
        self.cornerRadius = cornerRadius
        var ready = track.artworkURL.flatMap { ThumbCache.shared.image(for: $0) }
        if size >= 80, !track.isRadio, let sharp = ThumbCache.shared.largeImage(for: track.id) { ready = sharp }
        _image = State(initialValue: ready)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(ink.opacity(0.12))
                .overlay(Image(systemName: "music.note").foregroundStyle(ink.opacity(0.5)))
            if let image = image {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.2, style: .continuous))
        .task(id: track.id) {
            guard let url = track.artworkURL else { image = nil; return }
            if wantsLarge, let sharp = ThumbCache.shared.largeImage(for: track.id) {
                image = sharp
                return
            }
            // Najpierw to, co jest od ręki (mała miniatura), potem - dla dużych kafelków - ostra okładka.
            if let hit = ThumbCache.shared.image(for: url) {
                image = hit
            } else {
                image = nil
                image = await ThumbCache.shared.load(url)
            }
            if wantsLarge, let sharp = await ThumbCache.shared.loadLarge(track.id) {
                image = sharp
            }
        }
    }
}

struct TrackRow: View {
    @Environment(\.ink) private var ink
    @EnvironmentObject var engine: PlayerEngine
    @EnvironmentObject var settings: AppSettings
    let track: Track
    var isCurrent: Bool = false
    let onPlay: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil

    private var subtitle: String {
        track.duration > 0 ? "\(track.artist) · \(Fmt.time(track.duration))" : track.artist
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    TrackThumb(track: track)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if isCurrent {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ink)
                            }
                            Text(track.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(ink)
                                .lineLimit(1)
                        }
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(ink.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button { engine.enqueueNext(track) } label: { Label("Odtwórz jako następną", systemImage: "text.insert") }
                Button { engine.enqueueLast(track) } label: { Label("Dodaj do kolejki", systemImage: "text.append") }
                if let add = onAddToPlaylist {
                    Button(action: add) { Label("Dodaj do playlisty…", systemImage: "plus") }
                }
                Link(destination: track.watchURL) { Label("Otwórz w YouTube", systemImage: "arrow.up.right.square") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(ink.opacity(0.8))
                    .frame(width: 48, height: 56)
                    .contentShape(Rectangle())
            }
        }
    }
}

struct AddToPlaylistSheet: View {
    let tracks: [Track]
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var toast: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var done = false

    /// Animowane potwierdzenie (haptyka + wyskakujący "ptaszek"), potem zamknięcie okna.
    private func finish(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { done = true }
        toast.show(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { dismiss() }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Nowa playlista") {
                    HStack {
                        TextField("Nazwa playlisty", text: $newName)
                        Button("Utwórz") {
                            let p = library.create(name: newName, tracks: tracks)
                            finish("Dodano do \(p.name)")
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section("Twoje playlisty") {
                    if library.playlists.isEmpty {
                        Text("Brak playlist").foregroundStyle(.secondary)
                    }
                    ForEach(library.playlists) { p in
                        Button {
                            let n = library.add(tracks, to: p.id)
                            finish(n > 0 ? "Dodano do \(p.name)" : "Już jest w \(p.name)")
                        } label: {
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text("\(p.tracks.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dodaj do playlisty")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Gotowe") { dismiss() } }
            }
            .disabled(done)
            .overlay {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: done)
                        .padding(28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct EmptyHint: View {
    @Environment(\.ink) private var ink
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40, weight: .semibold)).foregroundStyle(ink.opacity(0.7))
            Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(ink)
            Text(message).font(.system(size: 14)).multilineTextAlignment(.center)
                .foregroundStyle(ink.opacity(0.65))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
