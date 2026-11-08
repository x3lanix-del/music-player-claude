import Foundation

/// Tłumaczenie tekstu piosenki (bezpłatny punkt końcowy tłumacza, bez klucza). Wynik jest w pamięci do zamknięcia aplikacji.
actor LyricsTranslator {
    static let shared = LyricsTranslator()

    private var cache: [String: [String]] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    /// Zwraca tłumaczenia w tej samej kolejności co `lines` (puste linijki zostają puste) albo nil przy błędzie.
    func translate(_ lines: [String], to lang: String, key: String) async -> [String]? {
        let ck = "\(key)|\(lang)|\(lines.count)"
        if let hit = cache[ck] { return hit }
        let indices = lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !indices.isEmpty else { return nil }
        var result = [String](repeating: "", count: lines.count)

        // 1) cały tekst jednym zapytaniem (szybko)
        let joined = indices.map { lines[$0] }.joined(separator: "\n")
        if let whole = await request(joined, lang: lang) {
            let parts = whole.components(separatedBy: "\n")
            if parts.count == indices.count {
                for (k, i) in indices.enumerated() {
                    result[i] = parts[k].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                cache[ck] = result
                return result
            }
        }

        // 2) gdy liczba linijek się nie zgadza: linijka po linijce, po 5 naraz
        var okCount = 0
        var start = 0
        while start < indices.count {
            if Task.isCancelled { return nil }
            let slice = Array(indices[start..<min(start + 5, indices.count)])
            start += 5
            let got: [(Int, String?)] = await withTaskGroup(of: (Int, String?).self) { group in
                for i in slice {
                    let text = lines[i]
                    group.addTask { (i, await self.request(text, lang: lang)) }
                }
                var out: [(Int, String?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (i, t) in got {
                if let t = t {
                    result[i] = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    okCount += 1
                }
            }
        }
        guard okCount > 0 else { return nil }
        cache[ck] = result
        return result
    }

    nonisolated private func request(_ text: String, lang: String) async -> String? {
        guard let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(lang)&dt=t") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?;")
        let enc = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        req.httpBody = "q=\(enc)".data(using: .utf8)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = json.first as? [Any] else { return nil }
        var out = ""
        for seg in segments {
            if let arr = seg as? [Any], let s = arr.first as? String { out += s }
        }
        return out.isEmpty ? nil : out
    }
}
