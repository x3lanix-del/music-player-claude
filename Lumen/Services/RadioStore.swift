import Foundation

/// Stacja radiowa. Lista popularnych stacji pochodzi z otwartej bazy radio-browser.info,
/// własne stacje (ulubione) zapisują się w telefonie.
struct RadioStation: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var url: String
    var detail: String = ""
    /// Adres logo stacji (favicon z bazy radio-browser). Opcjonalny, więc stare ulubione nadal się wczytują.
    var icon: String? = nil
    /// Strona stacji - z niej, gdy brak logo, bierzemy ikonę witryny.
    var homepage: String? = nil

    /// Stacja widziana przez odtwarzacz jak "utwór" (czas 0 = transmisja na żywo).
    var track: Track {
        Track(id: "radio:\(id)", title: name, artist: detail.isEmpty ? "Radio" : detail, duration: 0)
    }
}

@MainActor
final class RadioStore: ObservableObject {
    @Published private(set) var stations: [RadioStation] = []
    @Published var favorites: [RadioStation] = [] {
        didSet { saveFavorites() }
    }
    @Published private(set) var loading = false
    @Published private(set) var message: String? = nil

    private static let favoritesKey = "lumen.radio.favorites.v1"
    private static let hosts = ["all", "de1", "de2", "fr1", "nl1", "at1", "fi1", "us1"]

    init() {
        if let raw = UserDefaults.standard.data(forKey: RadioStore.favoritesKey),
           let list = try? JSONDecoder().decode([RadioStation].self, from: raw) {
            favorites = list
        }
    }

    // MARK: Favorites

    func isFavorite(_ s: RadioStation) -> Bool { favorites.contains { $0.id == s.id } }

    func toggleFavorite(_ s: RadioStation) {
        if let i = favorites.firstIndex(where: { $0.id == s.id }) {
            favorites.remove(at: i)
        } else {
            favorites.append(s)
        }
    }

    /// Własna stacja z adresu strumienia. Zwraca false, gdy adres jest nieprawidłowy.
    @discardableResult
    func addCustom(name: String, urlText: String) -> Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let station = RadioStation(id: "custom-\(UUID().uuidString)",
                                   name: title.isEmpty ? (url.host ?? "Stacja") : title,
                                   url: trimmed,
                                   detail: "Własna stacja")
        favorites.append(station)
        return true
    }

    private func saveFavorites() {
        if let raw = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(raw, forKey: RadioStore.favoritesKey)
        }
    }

    // MARK: Network

    private struct APIStation: Decodable {
        let stationuuid: String?
        let name: String?
        let url: String?
        let url_resolved: String?
        let tags: String?
        let codec: String?
        let countrycode: String?
        let favicon: String?
        let homepage: String?
    }

    /// Kod kraju telefonu (region systemowy), do dopasowania popularnych stacji. "PL", gdy nieznany.
    private var deviceCountryCode: String {
        if #available(iOS 16, *), let code = Locale.current.region?.identifier, !code.isEmpty { return code }
        return Locale.current.regionCode ?? "PL"
    }

    /// Popularne stacje z kraju telefonu.
    func loadPopular() async {
        await fetch(path: "/json/stations/search?countrycode=\(deviceCountryCode)&hidebroken=true&order=clickcount&reverse=true&limit=100")
    }

    /// Szukanie po nazwie (cały świat, od najpopularniejszych).
    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { await loadPopular(); return }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        await fetch(path: "/json/stations/search?name=\(encoded)&hidebroken=true&order=clickcount&reverse=true&limit=100")
    }

    /// Pyta wszystkie serwery radio-browser naraz - wygrywa pierwszy, który odpowie poprawnie
    /// (wcześniej szły po kolei, a jeden martwy serwer blokował resztę na 8 s).
    nonisolated private static func download(path: String) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            for host in hosts {
                group.addTask {
                    guard let url = URL(string: "https://\(host).api.radio-browser.info\(path)") else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 10
                    request.setValue("MusicPlayer/1.28", forHTTPHeaderField: "User-Agent")
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          (try? JSONDecoder().decode([APIStation].self, from: data)) != nil else { return nil }
                    return data
                }
            }
            for await data in group {
                if let d = data { group.cancelAll(); return d }
            }
            return nil
        }
    }

    private func fetch(path: String) async {
        loading = true
        message = nil
        defer { loading = false }

        let cacheKey = "lumen.radio.cache." + String(path.hashValue)
        var data = await RadioStore.download(path: path)
        if let fresh = data {
            UserDefaults.standard.set(fresh, forKey: cacheKey)      // zapas na gorszy zasięg
        } else {
            data = UserDefaults.standard.data(forKey: cacheKey)
        }
        guard let data = data, let list = try? JSONDecoder().decode([APIStation].self, from: data) else {
            message = "Nie udało się pobrać listy stacji. Sprawdź internet i pociągnij listę w dół, żeby spróbować jeszcze raz."
            return
        }

        var seen = Set<String>()
        var result: [RadioStation] = []
        for s in list {
            let stream = (s.url_resolved?.isEmpty == false ? s.url_resolved : s.url) ?? ""
            guard let id = s.stationuuid, !stream.isEmpty,
                  let name = s.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  // AVPlayer nie gra formatu Ogg
                  (s.codec ?? "").uppercased() != "OGG",
                  seen.insert(name.lowercased()).inserted else { continue }
            let tags = (s.tags ?? "").split(separator: ",").prefix(2)
                .map { $0.trimmingCharacters(in: .whitespaces).capitalized }
                .filter { !$0.isEmpty }
            var parts = tags
            if let cc = s.countrycode, !cc.isEmpty { parts.append(cc) }
            let icon = s.favicon?.trimmingCharacters(in: .whitespacesAndNewlines)
            let home = s.homepage?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(RadioStation(id: id, name: name, url: stream, detail: parts.joined(separator: " · "),
                                       icon: (icon?.isEmpty == false) ? icon : nil,
                                       homepage: (home?.isEmpty == false) ? home : nil))
        }
        stations = result
        if result.isEmpty { message = "Nie znaleziono stacji." }
    }
}
