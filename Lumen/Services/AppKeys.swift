import Foundation

/// Klucze API z Info.plist (wstawiane przez project.yml). Gdy podstawienie się nie uda i w polu zostaje
/// "$(NAZWA)" albo pustka, używamy wartości zapasowej, żeby rozpoznawanie piosenek zawsze działało.
enum AppKeys {
    static func plist(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }

    /// Token AudD (rozpoznawanie piosenek z mikrofonu i z radia).
    static var audd: String {
        let v = plist("AudDToken")
        return v.isEmpty ? "19e281b482d6544da573afb8eee719cb" : v
    }
}
