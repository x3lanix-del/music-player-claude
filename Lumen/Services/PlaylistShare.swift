import Foundation
import UIKit

/// Udostępnianie playlist bez żadnego serwera: cała playlista (nazwa i piosenki) jest spakowana w link
/// `musicplayer://playlist?d=…`. Kto ma aplikację, otwiera link albo wkleja go w Importuj z linku i dostaje tę samą playlistę.
enum PlaylistShare {
    static let scheme = "musicplayer"
    private static let prefix = "\(scheme)://playlist?d="

    private struct Payload: Codable {
        var v: Int
        var n: String
        var t: [[String]]       // [id, tytuł, wykonawca, sekundy]
    }

    // MARK: Kodowanie

    private static func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func unb64(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    static func code(for playlist: Playlist) -> String {
        let rows = playlist.tracks.map { [$0.id, $0.title, $0.artist, String(Int($0.duration.rounded()))] }
        let payload = Payload(v: 1, n: playlist.name, t: rows)
        guard let json = try? JSONEncoder().encode(payload) else { return "" }
        if let packed = try? (json as NSData).compressed(using: .zlib) {
            return "z" + b64(packed as Data)
        }
        return "r" + b64(json)
    }

    static func link(for playlist: Playlist) -> String { prefix + code(for: playlist) }

    /// Tekst do wysłania: czytelna lista piosenek i na końcu link do otwarcia w aplikacji.
    static func message(for playlist: Playlist, webLink: String? = nil) -> String {
        var lines = ["Playlista „\(playlist.name)” (\(Pl.songs(playlist.tracks.count)))", ""]
        for (i, t) in playlist.tracks.prefix(25).enumerated() {
            lines.append("\(i + 1). " + (t.artist.isEmpty ? t.title : "\(t.artist) – \(t.title)"))
        }
        if playlist.tracks.count > 25 { lines.append("… i \(playlist.tracks.count - 25) więcej") }
        lines.append("")
        lines.append("Otwórz w aplikacji Music Player albo skopiuj cały ten tekst i wklej w Biblioteka → + → Importuj z linku:")
        lines.append(webLink ?? link(for: playlist))
        return lines.joined(separator: "\n")
    }

    // MARK: Odczyt

    static func contains(_ text: String) -> Bool { text.contains(prefix) }

    /// Znajduje w tekście (sam link albo cała wiadomość) kod playlisty i zwraca nazwę z piosenkami.
    static func decode(_ text: String) -> (name: String, tracks: [Track])? {
        guard let r = text.range(of: prefix) else { return nil }
        let rest = text[r.upperBound...]
        let code = String(rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }))
        guard let kind = code.first, let raw = unb64(String(code.dropFirst())) else { return nil }
        let json: Data
        if kind == "z" {
            guard let unpacked = try? (raw as NSData).decompressed(using: .zlib) else { return nil }
            json = unpacked as Data
        } else {
            json = raw
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: json), payload.v == 1 else { return nil }
        let tracks: [Track] = payload.t.compactMap { row in
            guard row.count >= 2, !row[0].isEmpty else { return nil }
            return Track(id: row[0], title: row[1], artist: row.count > 2 ? row[2] : "",
                         duration: row.count > 3 ? (Double(row[3]) ?? 0) : 0)
        }
        return tracks.isEmpty ? nil : (payload.n, tracks)
    }
}
