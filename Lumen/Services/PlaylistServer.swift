import Foundation
import UIKit

/// Klient serwera playlist (strona pixel-perfect-snapshot-1131.lovable.app + baza Supabase). Rozmawia z bazą przez funkcje RPC.
enum PlaylistServer {
    static let siteURL = "https://pixel-perfect-snapshot-1131.lovable.app"

    private static var base: String {
        var b = AppKeys.plist("PlaylistsURL")
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }
    private static var key: String { AppKeys.plist("PlaylistsKey") }
    static var configured: Bool { !base.isEmpty && !key.isEmpty }

    struct Published: Codable { var code: String; var editKey: String }

    struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    // MARK: Zapamiętane publikacje (klucze edycji)

    private static let storeKey = "lumen.published.v1"

    private static func loadAll() -> [String: Published] {
        guard let raw = UserDefaults.standard.data(forKey: storeKey),
              let d = try? JSONDecoder().decode([String: Published].self, from: raw) else { return [:] }
        return d
    }

    private static func saveAll(_ d: [String: Published]) {
        if let raw = try? JSONEncoder().encode(d) { UserDefaults.standard.set(raw, forKey: storeKey) }
    }

    static func published(_ id: UUID) -> Published? { loadAll()[id.uuidString] }

    static func webLink(_ code: String) -> String { "\(siteURL)/\(code)" }

    // MARK: Linki

    /// Kod playlisty z linku do strony (…/p/KOD) albo z linku aplikacji (musicplayer://playlist?code=KOD).
    static func code(in text: String) -> String? {
        // Numer playlisty (same cyfry), np. https://music-player-playlists.lovable.app/1
        func take(after marker: String) -> String? {
            guard let r = text.range(of: marker) else { return nil }
            let code = String(text[r.upperBound...].prefix(while: { $0.isASCII && $0.isNumber }))
            return code.isEmpty ? nil : code
        }
        if let c = take(after: "musicplayer://playlist?code=") { return c }
        for host in ["pixel-perfect-snapshot-1131.lovable.app/", "music-player-playlists.lovable.app/"] {
            if let c = take(after: host) { return c }
        }
        return nil
    }

    // MARK: Zapytania

    private static func rpc(_ name: String, _ body: [String: Any]) async throws -> Any {
        guard configured, let url = URL(string: base + "/rest/v1/rpc/" + name) else {
            throw Failure(text: "Serwer playlist nie jest jeszcze skonfigurowany w tej wersji aplikacji.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "apikey")
        // Nowe klucze "sb_publishable_…" nie są JWT - wysyłamy je tylko w apikey. Stary klucz anon (eyJ…) dostaje też Bearer.
        if key.hasPrefix("eyJ") { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw Failure(text: "Brak połączenia z serwerem playlist.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200..<300).contains(status) else {
            let message = ((obj as? [String: Any])?["message"] as? String) ?? "Błąd serwera (\(status))."
            throw Failure(text: message)
        }
        return obj ?? NSNull()
    }

    private static func trackRows(_ p: Playlist) -> [[String: Any]] {
        p.tracks.map { ["id": $0.id, "title": $0.title, "artist": $0.artist, "duration": $0.duration] }
    }

    /// Publikuje playlistę na stronie albo, jeśli była już opublikowana, aktualizuje ją.
    static func publish(_ p: Playlist, isPublic: Bool = true) async throws -> Published {
        if p.tracks.isEmpty { throw Failure(text: "Playlista jest pusta.") }
        if let old = published(p.id) {
            var args: [String: Any] = ["p_code": old.code, "p_edit_key": old.editKey, "p_name": p.name,
                                       "p_tracks": trackRows(p), "p_set_cover": true]
            args["p_cover"] = LibraryStore.coverThumbnailBase64(file: p.coverFile) ?? NSNull()
            let ok = try await rpc("update_playlist", args)
            if (ok as? Bool) == true { return old }
        }
        var args: [String: Any] = ["p_name": p.name, "p_tracks": trackRows(p), "p_public": isPublic]
        if let cover = LibraryStore.coverThumbnailBase64(file: p.coverFile) { args["p_cover"] = cover }
        let r = try await rpc("publish_playlist", args)
        guard let o = r as? [String: Any], let code = o["code"] as? String, let editKey = o["edit_key"] as? String else {
            throw Failure(text: "Serwer zwrócił nieprawidłową odpowiedź.")
        }
        let item = Published(code: code, editKey: editKey)
        var all = loadAll()
        all[p.id.uuidString] = item
        saveAll(all)
        return item
    }

    static func unpublish(_ p: Playlist) async throws {
        guard let old = published(p.id) else { return }
        _ = try await rpc("delete_playlist", ["p_code": old.code, "p_edit_key": old.editKey])
        var all = loadAll()
        all[p.id.uuidString] = nil
        saveAll(all)
    }

    struct Item: Identifiable, Hashable {
        let code: String
        let name: String
        let count: Int
        let preview: [String]
        let views: Int
        /// Ikona playlisty (JPEG), jeśli autor ją ustawił.
        var cover: Data? = nil
        var id: String { code }
    }

    /// Publiczne playlisty (najnowsze na górze), opcjonalnie z wyszukiwaniem po nazwie.
    static func list(query: String, limit: Int = 50) async throws -> [Item] {
        let r = try await rpc("list_playlists", ["p_query": query, "p_limit": limit, "p_offset": 0])
        guard let rows = r as? [[String: Any]] else { return [] }
        return rows.compactMap { o in
            guard let code = o["code"] as? String, let name = o["name"] as? String else { return nil }
            return Item(code: code, name: name, count: (o["count"] as? NSNumber)?.intValue ?? 0,
                        preview: (o["preview"] as? [String]) ?? [], views: (o["views"] as? NSNumber)?.intValue ?? 0,
                        cover: (o["cover"] as? String).flatMap { Data(base64Encoded: $0) })
        }
    }

    static func fetch(code: String) async throws -> (name: String, tracks: [Track], cover: Data?)? {
        let r = try await rpc("get_playlist", ["p_code": code])
        guard let o = r as? [String: Any], let name = o["name"] as? String, let rows = o["tracks"] as? [[String: Any]] else { return nil }
        let tracks: [Track] = rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Track(id: id, title: (row["title"] as? String) ?? "", artist: (row["artist"] as? String) ?? "",
                         duration: (row["duration"] as? NSNumber)?.doubleValue ?? 0)
        }
        let cover = (o["cover"] as? String).flatMap { Data(base64Encoded: $0) }
        return tracks.isEmpty ? nil : (name, tracks, cover)
    }

    // MARK: Skróty dla ekranów

    @MainActor
    static func publishAndCopy(_ p: Playlist, isPublic: Bool = true, toast: ToastCenter) {
        guard configured else { toast.show("Serwer playlist nie jest jeszcze skonfigurowany w tej wersji."); return }
        toast.show("Publikuję na stronie…")
        Task {
            do {
                let r = try await publish(p, isPublic: isPublic)
                UIPasteboard.general.string = webLink(r.code)
                toast.show((isPublic ? "Opublikowano publicznie" : "Opublikowano prywatnie (tylko z linkiem)") + ". Link skopiowany: " + webLink(r.code))
            } catch {
                toast.show(error.localizedDescription)
            }
        }
    }

    /// Udostępnianie: zawsze krótki link. Jeśli playlista nie była jeszcze opublikowana, jest publikowana prywatnie
    /// (widzi ją tylko ten, kto ma link); potem otwiera się zwykłe okno udostępniania iOS.
    @MainActor
    static func share(_ p: Playlist, toast: ToastCenter) {
        guard configured else { toast.show("Serwer playlist nie jest jeszcze skonfigurowany w tej wersji."); return }
        toast.show("Przygotowuję link…")
        Task {
            do {
                let r = try await publish(p, isPublic: false)
                presentShareSheet(URL(string: webLink(r.code)))
            } catch {
                toast.show(error.localizedDescription)
            }
        }
    }

    @MainActor
    private static func presentShareSheet(_ url: URL?) {
        guard let url else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene?.windows.first?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
        top.present(vc, animated: true)
    }

    @MainActor
    static func unpublishWithToast(_ p: Playlist, toast: ToastCenter) {
        Task {
            do {
                try await unpublish(p)
                toast.show("Playlista usunięta ze strony.")
            } catch {
                toast.show(error.localizedDescription)
            }
        }
    }
}
