import Foundation

/// Ulubione to zwykła playlista o stałym identyfikatorze, więc działa w niej wszystko, co w innych playlistach
/// (odtwarzanie, pobieranie, kolejność).
extension LibraryStore {
    static let favoritesID = UUID(uuidString: "FA7A0000-0000-4000-8000-000000000001") ?? UUID()

    func isFavorite(_ track: Track) -> Bool {
        playlist(Self.favoritesID)?.tracks.contains(where: { $0.id == track.id }) ?? false
    }

    func toggleFavorite(_ track: Track) {
        if let i = playlists.firstIndex(where: { $0.id == Self.favoritesID }) {
            if let j = playlists[i].tracks.firstIndex(where: { $0.id == track.id }) {
                playlists[i].tracks.remove(at: j)
            } else {
                playlists[i].tracks.insert(track, at: 0)
            }
        } else {
            let p = Playlist(id: Self.favoritesID, name: "Ulubione", tracks: [track])
            playlists.insert(p, at: 0)
        }
    }
}
