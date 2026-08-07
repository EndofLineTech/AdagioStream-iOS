import CarPlay
import Foundation
import UIKit

// beads_mobilemusic-zgi: extracted from CarPlayTemplateManager. Owns the
// Navidrome (Subsonic) music-browse push-navigation stack — Artists/Albums/
// Songs/Playlists lists, artist→albums and album/playlist→tracks drill-down,
// cover art loading, and the library Up Next queue. Re-derived inventory
// (the bead's 2026-07-08 grep predates uxa.4/cpr/iqt, all landed since):
// this type still references zero radio-side stored properties. The only
// things it shares with CarPlayTemplateManager are:
//   - interfaceController / audioPlayer / providerManager — handed in as the
//     same instances the manager holds (already non-private lets there).
//   - pushNowPlaying() — already internal on the manager, but there is no
//     back-reference from this type to the manager, so it is handed in as a
//     closure instead of adding one. Calls read identically to a method call
//     (self.pushNowPlaying()) thanks to the tiny wrapper below.
//   - the current sortPrefixes value — handed in as a closure
//     (sortPrefixesProvider) rather than widening the manager's private
//     `sortPrefixes` var. This dependency was NOT anticipated by the bead's
//     2026-07-08 inventory: uxa.4 (letter-indexed Artists/Playlists lists)
//     landed afterward and made these lists share
//     CarPlayTemplateManager.letterIndexedSections(_:sortPrefixes:) with
//     pushChannelList (radio, stays on the manager).
//   - formatDuration / musicNoteImage / emptyMusicItem / letterIndexedSections
//     — already-internal (or newly-promoted, see CarPlayTemplateManager.swift)
//     static helpers on CarPlayTemplateManager, called by fully-qualified
//     name. No injection needed: Swift lets any file reference another
//     type's internal static members directly.
//
// Same lifecycle as the owning CarPlayTemplateManager: created per CarPlay
// connection (in its init, right after super.init()), released on
// disconnect. Registered directly as the CPNowPlayingTemplateObserver for
// the Up Next button — nowPlayingTemplateUpNextButtonTapped(_:) moved here
// with pushUpNextQueue(), so CarPlayTemplateManager.configure() now calls
// CPNowPlayingTemplate.shared.add(musicBrowser) instead of add(self).
@MainActor
final class CarPlayMusicBrowser: NSObject, CPNowPlayingTemplateObserver {
    let interfaceController: CPInterfaceController
    let audioPlayer: AudioPlayerService
    let providerManager: ProviderManager
    let log = DebugLogger.shared

    private let pushNowPlayingAction: () -> Void
    private let sortPrefixesProvider: () -> [String]

    init(
        interfaceController: CPInterfaceController,
        audioPlayer: AudioPlayerService,
        providerManager: ProviderManager,
        pushNowPlaying: @escaping () -> Void,
        sortPrefixesProvider: @escaping () -> [String]
    ) {
        self.interfaceController = interfaceController
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
        self.pushNowPlayingAction = pushNowPlaying
        self.sortPrefixesProvider = sortPrefixesProvider
        super.init()
    }

    /// Thin wrapper so every moved method body below can call
    /// `self.pushNowPlaying()` / `pushNowPlaying()` unchanged from its
    /// original text in CarPlayTemplateManager.swift.
    private func pushNowPlaying() {
        pushNowPlayingAction()
    }

    // MARK: - Music Library Browse (8rg.1)

    /// Loading-placeholder template shared by the category list pushers.
    private func makeMusicLoadingTemplate(title: String) -> CPListTemplate {
        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        return CPListTemplate(title: title, sections: [CPListSection(items: [loadingItem])])
    }

    func pushArtistsList(api: NavidromeAPI) {
        log.log("Music: pushArtistsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Artists")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.fetchArtistItems(api: api)
                // uxa.4: letter-index — same treatment as pushChannelList,
                // hundreds of unindexed rows is the distraction failure mode
                // the sectionIndexTitle API exists to prevent.
                let sections = entries.isEmpty
                    ? [CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("No artists")])]
                    : CarPlayTemplateManager.letterIndexedSections(entries, sortPrefixes: self.sortPrefixesProvider())
                template.updateSections(sections)
            } catch {
                self.log.log("Music: getArtists failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    func pushAlbumsList(api: NavidromeAPI) {
        log.log("Music: pushAlbumsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Albums")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let items = try await self.fetchAlbumItems(api: api)
                template.updateSections([CPListSection(items: items.isEmpty ? [CarPlayTemplateManager.emptyMusicItem("No albums")] : items)])
            } catch {
                self.log.log("Music: getAlbumList2 failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    func pushPlaylistsList(api: NavidromeAPI) {
        log.log("Music: pushPlaylistsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Playlists")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.fetchPlaylistItems(api: api)
                // uxa.4: letter-index — same treatment as pushChannelList.
                let sections = entries.isEmpty
                    ? [CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("No playlists")])]
                    : CarPlayTemplateManager.letterIndexedSections(entries, sortPrefixes: self.sortPrefixesProvider())
                template.updateSections(sections)
            } catch {
                self.log.log("Music: getPlaylists failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    func pushSongsList(api: NavidromeAPI) {
        log.log("Music: pushSongsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Songs")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let items = try await self.fetchSongItems(api: api)
                template.updateSections([CPListSection(items: items.isEmpty ? [CarPlayTemplateManager.emptyMusicItem("No songs")] : items)])
            } catch {
                self.log.log("Music: getRandomSongs failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    // MARK: Songs (random page → play)

    private func fetchSongItems(api: NavidromeAPI) async throws -> [CPListItem] {
        let songs = try await api.getRandomSongs(size: 100)
        return songs.enumerated().map { (index, track) in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                self.log.log("Music: play random song \(index) \"\(track.title)\"", category: .carplay)
                self.audioPlayer.setQueue(songs, startIndex: index, via: api)
                self.pushNowPlaying()
                completion()
            }
            if let coverArtID = track.coverArt {
                loadMusicCoverArt(id: coverArtID, api: api, into: item)
            } else {
                item.setImage(CarPlayTemplateManager.musicNoteImage())
            }
            return item
        }
    }

    // MARK: Artists

    private func fetchArtistItems(api: NavidromeAPI) async throws -> [(name: String, item: CPListItem)] {
        let artists = try await api.getArtists()
        return artists.map { artist in
            let detail = artist.albumCount > 0 ? "\(artist.albumCount) albums" : nil
            let item = CPListItem(text: artist.name, detailText: detail)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushArtistAlbums(artist: artist, api: api)
                completion()
            }
            if let coverArtID = artist.coverArt {
                loadMusicCoverArt(id: coverArtID, api: api, into: item)
            } else {
                item.setImage(CarPlayTemplateManager.musicNoteImage())
            }
            return (artist.name, item)
        }
    }

    // MARK: Albums (top-level: newest 50)

    private func fetchAlbumItems(api: NavidromeAPI) async throws -> [CPListItem] {
        let albums = try await api.getAlbumList2(type: .newest, size: 50)
        return albums.map { album in
            let item = CPListItem(text: album.title, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushAlbumTracks(album: album, artistName: nil, api: api)
                completion()
            }
            if let coverArtID = album.coverArt {
                loadMusicCoverArt(id: coverArtID, api: api, into: item)
            } else {
                item.setImage(CarPlayTemplateManager.musicNoteImage())
            }
            return item
        }
    }

    // MARK: Playlists

    private func fetchPlaylistItems(api: NavidromeAPI) async throws -> [(name: String, item: CPListItem)] {
        let playlists = try await api.getPlaylists()
        return playlists.map { playlist in
            let detail = playlist.songCount > 0 ? "\(playlist.songCount) tracks" : nil
            let item = CPListItem(text: playlist.name, detailText: detail)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushPlaylistTracks(playlist: playlist, api: api)
                completion()
            }
            if let coverArtID = playlist.coverArt {
                loadMusicCoverArt(id: coverArtID, api: api, into: item)
            } else {
                item.setImage(CarPlayTemplateManager.musicNoteImage())
            }
            return (playlist.name, item)
        }
    }

    // MARK: Artist → Albums

    private func pushArtistAlbums(artist: Artist, api: NavidromeAPI) {
        log.log("Music: pushArtistAlbums artist=\"\(artist.name)\"", category: .carplay)

        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let template = CPListTemplate(title: artist.name, sections: [CPListSection(items: [loadingItem])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, albums) = try await api.getArtist(id: artist.id)
                let items = albums.map { album in
                    let detail = album.year.map { String($0) }
                    let item = CPListItem(text: album.title, detailText: detail)
                    item.accessoryType = .disclosureIndicator
                    item.handler = { [weak self] _, completion in
                        self?.pushAlbumTracks(album: album, artistName: artist.name, api: api)
                        completion()
                    }
                    if let coverArtID = album.coverArt {
                        self.loadMusicCoverArt(id: coverArtID, api: api, into: item)
                    } else {
                        item.setImage(CarPlayTemplateManager.musicNoteImage())
                    }
                    return item
                }
                let section = CPListSection(items: items.isEmpty
                    ? [CarPlayTemplateManager.emptyMusicItem("No albums")]
                    : items)
                template.updateSections([section])
            } catch {
                self.log.log("Music: getArtist failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    // MARK: Album → Tracks → play

    private func pushAlbumTracks(album: Album, artistName: String?, api: NavidromeAPI) {
        log.log("Music: pushAlbumTracks album=\"\(album.title)\"", category: .carplay)

        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let template = CPListTemplate(title: album.title, sections: [CPListSection(items: [loadingItem])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, tracks) = try await api.getAlbum(id: album.id)
                let items = tracks.enumerated().map { (index, track) in
                    let duration = track.duration.map { CarPlayTemplateManager.formatDuration($0) }
                    let item = CPListItem(text: track.title, detailText: duration)
                    item.handler = { [weak self] _, completion in
                        guard let self else { completion(); return }
                        self.log.log("Music: play album \"\(album.title)\" track \(index) \"\(track.title)\"", category: .carplay)
                        self.audioPlayer.setQueue(tracks, startIndex: index, displayArtistName: artistName, via: api)
                        self.pushNowPlaying()
                        completion()
                    }
                    if let coverArtID = track.coverArt {
                        self.loadMusicCoverArt(id: coverArtID, api: api, into: item)
                    } else if let coverArtID = album.coverArt {
                        self.loadMusicCoverArt(id: coverArtID, api: api, into: item)
                    } else {
                        item.setImage(CarPlayTemplateManager.musicNoteImage())
                    }
                    return item
                }
                let section = CPListSection(items: items.isEmpty
                    ? [CarPlayTemplateManager.emptyMusicItem("No tracks")]
                    : items)
                template.updateSections([section])
            } catch {
                self.log.log("Music: getAlbum failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    // MARK: Playlist → Tracks → play

    private func pushPlaylistTracks(playlist: Playlist, api: NavidromeAPI) {
        log.log("Music: pushPlaylistTracks playlist=\"\(playlist.name)\"", category: .carplay)

        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let template = CPListTemplate(title: playlist.name, sections: [CPListSection(items: [loadingItem])])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (_, tracks) = try await api.getPlaylist(id: playlist.id)
                let items = tracks.enumerated().map { (index, track) in
                    let duration = track.duration.map { CarPlayTemplateManager.formatDuration($0) }
                    let item = CPListItem(text: track.title, detailText: duration)
                    item.handler = { [weak self] _, completion in
                        guard let self else { completion(); return }
                        self.log.log("Music: play playlist \"\(playlist.name)\" track \(index) \"\(track.title)\"", category: .carplay)
                        self.audioPlayer.setQueue(tracks, startIndex: index, via: api)
                        self.pushNowPlaying()
                        completion()
                    }
                    if let coverArtID = track.coverArt {
                        self.loadMusicCoverArt(id: coverArtID, api: api, into: item)
                    } else {
                        item.setImage(CarPlayTemplateManager.musicNoteImage())
                    }
                    return item
                }
                let section = CPListSection(items: items.isEmpty
                    ? [CarPlayTemplateManager.emptyMusicItem("No tracks")]
                    : items)
                template.updateSections([section])
            } catch {
                self.log.log("Music: getPlaylist failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [CarPlayTemplateManager.emptyMusicItem("Failed to load")])])
            }
        }
    }

    // MARK: Cover Art

    /// Asynchronously loads cover art via `NavidromeAPI.fetchCoverArtImage` and
    /// sets it on the given `CPListItem` when available.  Falls back to the
    /// music-note placeholder if the fetch fails or returns nil.
    private func loadMusicCoverArt(id: String, api: NavidromeAPI, into item: CPListItem) {
        let size = 40
        Task {
            guard let image = await api.fetchCoverArtImage(id: id, size: size) else {
                // Placeholder already shown; nothing to update
                return
            }
            let targetSize = CGSize(width: CGFloat(size), height: CGFloat(size))
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            let scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            item.setImage(scaled)
        }
    }

    // MARK: - Up Next Queue (j7d.3)

    /// Called by CarPlay when the user taps the Up Next button on the
    /// `CPNowPlayingTemplate`.  Only fires when `isUpNextButtonEnabled == true`,
    /// which CarPlayTemplateManager sets only during library playback.
    ///
    /// Pushes a `CPListTemplate` showing the full queue as a snapshot at the
    /// moment of the tap.  Queue refresh while the list is open is best-effort:
    /// because CarPlay template updates must go through
    /// `CPListTemplate.updateSections`, and a track advance fires
    /// `updateNowPlayingButtons` (not a direct list-refresh path), the queue
    /// list is a snapshot.  This is acceptable: the list closes when the user
    /// taps a row (the jump pops back to Now Playing), and track advances while
    /// the list is open are an edge case that can be addressed in a follow-up.
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        log.log("j7d.3: Up Next tapped", category: .carplay)
        pushUpNextQueue()
    }

    /// Builds and pushes a `CPListTemplate` containing the current library queue.
    ///
    /// - The currently-playing track is indicated with "(Now Playing)" in its
    ///   detail text.
    /// - Tapping any row calls `audioPlayer.playQueueItem(at:)` to jump to that
    ///   track and then pops back to the Now Playing template.
    /// - Radio playback or an empty queue is a safe no-op (guard at the top).
    /// - Cover art per row is omitted for simplicity; the Navidrome API requires
    ///   a size-specific fetch per track, and the queue may be large.  If cover
    ///   art is desired in a follow-up, reuse `loadMusicCoverArt(id:api:into:)`.
    private func pushUpNextQueue() {
        let queue = audioPlayer.currentLibraryQueue
        guard !queue.isEmpty else {
            log.log("j7d.3: Up Next — queue empty or not in library mode, no-op", category: .carplay)
            return
        }
        let currentIndex = audioPlayer.currentQueueIndex

        let items: [CPListItem] = queue.enumerated().map { (index, track) in
            let isPlaying = index == currentIndex
            let detail: String?
            if isPlaying {
                detail = "Now Playing"
            } else if let duration = track.duration {
                detail = CarPlayTemplateManager.formatDuration(duration)
            } else {
                detail = nil
            }
            let item = CPListItem(text: track.title, detailText: detail)
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                self.log.log("j7d.3: Up Next row tapped — jumping to index=\(index) \"\(track.title)\"", category: .carplay)
                self.audioPlayer.playQueueItem(at: index)
                // Return to Now Playing after the jump.
                self.pushNowPlaying()
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Up Next", sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        log.log("j7d.3: Up Next list pushed — \(queue.count) tracks, currentIndex=\(currentIndex.map(String.init) ?? "nil")", category: .carplay)
    }
}
