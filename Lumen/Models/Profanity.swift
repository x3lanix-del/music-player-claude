import Foundation

/// Wykrywanie wulgaryzmów w kilku językach (polski, angielski, niemiecki, hiszpański, francuski, włoski, rosyjski).
/// Słowo jest rozpoznawane po początku (odmiany) albo po dokładnej formie (krótkie słowa, żeby nie łapać
/// niewinnych wyrazów). Służy do cenzury tekstu (ku***) i wyciszania takich słów w nagraniu.
enum Profanity {
    /// Początki słów (po zdjęciu ogonków i małych/dużych liter).
    private static let prefixes: [String] = [
        // polski
        "kurw", "skurw", "jeb", "zajeb", "wyjeb", "pojeb", "rozjeb", "pierdol", "spierd", "wypierd", "pizd",
        "chuj", "huj", "kutas", "fiut", "cipa", "cipk", "dojeb", "odjeb", "najeb",
        "napierd", "odpierd", "popierd", "rozpierd", "zajebi", "skurwysy", "skurwiel",
        // angielski
        "fuck", "motherf", "shit", "bullshit", "bitch", "asshole", "bastard", "cunt", "whore", "slut", "nigg",
        "pussy", "dickhead", "dickhe", "wanker", "wanke", "twat",
        "piss", "prick", "dumbas", "jackas", "asshol", "bolloc", "sonofabitch",
        // niemiecki
        "scheiss", "arschloch", "hurens", "wichs", "ficken", "fickt",
        // hiszpański
        "mierda", "joder", "pendej", "chingad", "cabron", "puta", "putas",
        // francuski
        "merde", "putain", "connard", "connasse", "salope", "encul",
        // włoski
        "cazzo", "merda", "stronz", "vaffan", "puttan",
        // rosyjski
        "бляд", "блят", "хуй", "хуе", "хуя", "пизд", "ебан", "ебат", "ебал", "сукин", "мудак", "пидор", "пидар"
    ]

    /// Dokładne formy (krótkie słowa, które jako początek łapałyby zwykłe wyrazy).
    private static let exact: Set<String> = [
        "ass", "asses", "arse", "dick", "dicks", "dicky", "pricks", "cock", "cocks", "fick", "verga", "pute", "suka", "suki",
        "сука", "суки", "сучка", "бля"
    ]

    /// Wyjątki: zwykłe słowa, które zaczynają się jak wulgaryzm.
    private static let safe: Set<String> = [
        "jebus", "cocktail", "cockpit", "fickle", "pissarro", "prickly", "pricklier"
    ]

    static func isProfane(_ word: String) -> Bool {
        let w = normalize(word)
        guard w.count >= 3 else { return false }
        if exact.contains(w) { return true }
        if safe.contains(w) && !exact.contains(w) { return false }
        return prefixes.contains { w.hasPrefix($0) }
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "l")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
    }

    /// Pozycje wulgarnych słów w tekście (w znakach): początek i długość.
    static func spans(in text: String) -> [(start: Int, length: Int)] {
        var out: [(start: Int, length: Int)] = []
        var current = ""
        var wordStart = 0
        var i = 0
        for ch in text {
            if ch.isLetter {
                if current.isEmpty { wordStart = i }
                current.append(ch)
            } else if !current.isEmpty {
                if isProfane(current) { out.append((wordStart, current.count)) }
                current = ""
            }
            i += 1
        }
        if !current.isEmpty, isProfane(current) { out.append((wordStart, current.count)) }
        return out
    }

    /// "kurwa" -> "ku***", "japierdolę" -> "ja********". Dwie pierwsze litery zostają (jedna w krótkich słowach).
    static func censor(_ text: String) -> String {
        let found = spans(in: text)
        guard !found.isEmpty else { return text }
        var chars = Array(text)
        for s in found {
            let keep = s.length <= 3 ? 1 : 2
            guard s.length > keep else { continue }
            for k in (s.start + keep)..<(s.start + s.length) where k < chars.count { chars[k] = "*" }
        }
        return String(chars)
    }
}
