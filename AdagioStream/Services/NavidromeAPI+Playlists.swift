import Foundation

extension NavidromeAPI {
    // MARK: - Playlist endpoints

    /// Fetches all playlists visible to the authenticated user from `getPlaylists.view`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"playlists":{"playlist":[<playlist>]}}
    /// ```
    /// An absent `"playlist"` array (user has no playlists) returns `[]` without throwing.
    public func getPlaylists() async throws -> [Playlist] {
        let payload = try await fetch("getPlaylists", params: [:], as: GetPlaylistsPayload.self)
        return payload.playlists.playlist
    }

    /// Fetches a single playlist and its tracks from `getPlaylist.view?id=`.
    ///
    /// Subsonic payload structure:
    /// ```json
    /// {"playlist":{<playlist fields>, "entry":[<song>]}}
    /// ```
    /// An absent `"entry"` array (empty playlist) returns `[]` tracks without throwing.
    ///
    /// - Parameter id: The Subsonic playlist ID.
    /// - Returns: The `Playlist` value and its `[Track]` entries.
    public func getPlaylist(id: String) async throws -> (playlist: Playlist, tracks: [Track]) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getPlaylist", params: ["id": id], as: GetPlaylistPayload.self)
        let tracks = payload.playlist.entry.map { $0.toRecord(updatedAt: now) }
        return (payload.playlist.playlistMeta, tracks)
    }

    /// Like `getPlaylist(id:)` but also returns per-track `StarState` keyed by track ID.
    ///
    /// Used by PlaylistDetailView to reflect server-side star state on playlist tracks.
    public func getPlaylistWithStarState(id: String) async throws -> (
        playlist: Playlist,
        tracks: [Track],
        trackStarStates: [String: StarState]
    ) {
        let now = Int(Date().timeIntervalSince1970)
        let payload = try await fetch("getPlaylist", params: ["id": id], as: GetPlaylistPayload.self)
        let tracks = payload.playlist.entry.map { $0.toRecord(updatedAt: now) }
        var trackStarStates: [String: StarState] = [:]
        for dto in payload.playlist.entry {
            trackStarStates[dto.id] = StarState(
                starred: dto.starred,
                userRating: dto.userRating,
                playCount: dto.playCount
            )
        }
        return (payload.playlist.playlistMeta, tracks, trackStarStates)
    }

    // getPlaylists
    private struct GetPlaylistsPayload: Decodable {
        let playlists: PlaylistsWrapper

        struct PlaylistsWrapper: Decodable {
            let playlist: [Playlist]

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                playlist = (try? c.decode([Playlist].self, forKey: .playlist)) ?? []
            }

            enum CodingKeys: String, CodingKey { case playlist }
        }
    }

    // getPlaylist
    private struct GetPlaylistPayload: Decodable {
        let playlist: PlaylistDetail

        struct PlaylistDetail: Decodable {
            let playlistMeta: Playlist
            let entry: [SubsonicTrackDTO]

            init(from decoder: Decoder) throws {
                playlistMeta = try Playlist(from: decoder)
                let c        = try decoder.container(keyedBy: CodingKeys.self)
                entry        = (try? c.decode([SubsonicTrackDTO].self, forKey: .entry)) ?? []
            }

            enum CodingKeys: String, CodingKey { case entry }
        }
    }
}
