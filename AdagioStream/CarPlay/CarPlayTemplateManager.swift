import CarPlay
import Combine
import Foundation
import MediaPlayer
import UIKit

@MainActor
class CarPlayTemplateManager {
    let interfaceController: CPInterfaceController
    let audioPlayer: AudioPlayerService
    let providerManager: ProviderManager
    let customPlaylistManager = CustomPlaylistManager.shared
    private let log = DebugLogger.shared
    let savedSongsManager = SavedSongsManager.shared
    private var cancellable: AnyCancellable?
    private var playlistCancellable: AnyCancellable?
    private var channelCancellable: AnyCancellable?
    private var timeShiftCancellable: AnyCancellable?
    private var trackCancellable: AnyCancellable?
    private var feedTracksCancellable: AnyCancellable?
    private var espnCancellable: AnyCancellable?
    private var epgCancellable: AnyCancellable?
    private var groupSortCancellables = Set<AnyCancellable>()
    private var rootTemplate: CPListTemplate?
    private var favoritesItem: CPListItem?
    private var hadFavorites = false
    private var hadChannels = false
    /// Maps CPListItem identity to channel ID for live detail text updates.
    private var itemChannelMap: [ObjectIdentifier: String] = [:]
    private var sortPrefixes: [String] = AppSettings.default.sortPrefixes
    private var startupStreamID: String?
    private var hasAttemptedStartupStream = false
    private var providerRecoveryAttempts = 0
    private let maxProviderRecoveryAttempts = 2
    /// Separate counter for the "providers list still empty" reschedule path
    /// so a slow keychain/disk read doesn't burn through the load-retry budget
    /// before we've even seen the provider list materialize.
    private var emptyProviderListChecks = 0
    private let maxEmptyProviderListChecks = 1

    init(interfaceController: CPInterfaceController, audioPlayer: AudioPlayerService, providerManager: ProviderManager) {
        self.interfaceController = interfaceController
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
    }

    func configure() {
        log.log("configure() starting", category: .carplay)
        Task {
            let settings: AppSettings = await PersistenceService.shared.loadOrDefault(
                from: Constants.StorageKeys.settings, default: .default
            )
            sortPrefixes = settings.sortPrefixes
            startupStreamID = settings.startupStreamID
            log.log("Settings loaded: startupStream=\(settings.startupStreamID ?? "none")", category: .carplay)
        }
        updateNowPlayingButtons()
        setRootTemplate()

        cancellable = providerManager.$channels
            .combineLatest(providerManager.$enabledGroups, providerManager.$favoriteGroupOrder)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                let hasChannels = !self.providerManager.visibleChannels.isEmpty
                let hasFavorites = !self.providerManager.favoriteChannels.isEmpty
                if hasChannels != self.hadChannels || hasFavorites != self.hadFavorites {
                    self.hadChannels = hasChannels
                    self.updateRootSections()
                } else if let item = self.favoritesItem, hasFavorites {
                    let count = self.providerManager.favoriteChannels.count
                    item.setDetailText("\(count) channels")
                }
                self.updateNowPlayingButtons()
                self.attemptStartupStream()
            }

        providerManager.$groupSortOrder
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRootSections()
            }
            .store(in: &groupSortCancellables)

        channelCancellable = audioPlayer.$currentChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingButtons()
            }

        timeShiftCancellable = audioPlayer.timeShiftBuffer.$isTimeShifted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingButtons()
            }

        trackCancellable = SXMMetadataService.shared.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingButtons()
            }

        feedTracksCancellable = SXMMetadataService.shared.$feedTracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshChannelListDetailText()
            }

        espnCancellable = ESPNScoreService.shared.$gamesByChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshChannelListDetailText()
            }

        epgCancellable = providerManager.$epgData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshChannelListDetailText()
            }

        playlistCancellable = customPlaylistManager.$playlists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateRootSections()
            }

        scheduleProviderRecoveryCheck(after: 15)
    }

    /// Detect cold-launch provider load failures (XC's three sequential
    /// network calls are most prone to this). After a short delay, if any
    /// enabled provider has zero channels in `channelCountByProvider`,
    /// trigger another `loadChannels()` attempt. Bounded to
    /// `maxProviderRecoveryAttempts` so a genuinely-broken provider
    /// doesn't loop forever.
    private func scheduleProviderRecoveryCheck(after delay: TimeInterval) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }

            let allProviders = self.providerManager.providers
            let enabled = allProviders.filter(\.isEnabled)

            // Distinguish "no providers in memory yet" from "all loaded, all
            // happy".  Before pid.3, both states took the early-success
            // branch — an empty `enabled` produces an empty `missing`,
            // which means "no missing" — and we silently declared success
            // while a slow keychain/disk read was still hydrating the
            // provider list.  Reschedule once at +30s so the recovery
            // doesn't fire its 'no retry needed' log against a list that
            // hasn't materialized.
            if allProviders.isEmpty {
                if self.emptyProviderListChecks < self.maxEmptyProviderListChecks {
                    self.emptyProviderListChecks += 1
                    log.log(
                        "Provider recovery: provider list still empty (check \(self.emptyProviderListChecks)/\(self.maxEmptyProviderListChecks)) — rescheduling at +30s",
                        category: .carplay
                    )
                    self.scheduleProviderRecoveryCheck(after: 30)
                } else {
                    log.log(
                        "Provider recovery: provider list still empty after \(self.emptyProviderListChecks) checks — giving up (no persisted providers?)",
                        category: .carplay
                    )
                }
                return
            }

            let counts = self.providerManager.channelCountByProvider
            let missing = enabled.filter { (counts[$0.id] ?? 0) == 0 }
            guard !missing.isEmpty else {
                log.log(
                    "Provider recovery: all \(enabled.count) enabled providers loaded — no retry needed",
                    category: .carplay
                )
                return
            }

            guard self.providerRecoveryAttempts < self.maxProviderRecoveryAttempts else {
                log.log(
                    "Provider recovery: \(missing.count) provider(s) still empty after \(self.providerRecoveryAttempts) attempts — giving up",
                    category: .carplay
                )
                return
            }

            self.providerRecoveryAttempts += 1
            let names = missing.map(\.name).joined(separator: ", ")
            log.log(
                "Provider recovery (attempt \(self.providerRecoveryAttempts)/\(self.maxProviderRecoveryAttempts)): \(missing.count) empty — [\(names)] — refreshing",
                category: .carplay
            )
            await self.providerManager.loadChannels()
            self.scheduleProviderRecoveryCheck(after: 30)
        }
    }

    private func attemptStartupStream() {
        guard !hasAttemptedStartupStream,
              let streamID = startupStreamID,
              audioPlayer.currentChannel == nil,
              !providerManager.visibleChannels.isEmpty else { return }
        hasAttemptedStartupStream = true
        if let channel = providerManager.visibleChannels.first(where: { $0.id == streamID }) {
            log.log("Auto-playing startup channel: \"\(channel.name)\"", category: .carplay)
            // Play in background without navigating to Now Playing —
            // keeps the user on the channel list so they can quickly switch
            audioPlayer.channels = providerManager.visibleChannels
            audioPlayer.play(channel: channel)
            updateRootSections()

            // Re-publish metadata after a delay for head units that need it
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard self?.audioPlayer.currentChannel?.id == channel.id else { return }
                self?.audioPlayer.refreshNowPlayingInfo()
            }
        }
    }

    private func updateNowPlayingButtons() {
        let nowPlaying = CPNowPlayingTemplate.shared
        let buttonSize = CGSize(width: 44, height: 44)

        let isFavorite = providerManager.channels
            .first(where: { $0.id == audioPlayer.currentChannel?.id })?.isFavorite ?? false
        let favImage = renderSFSymbol(isFavorite ? "star.fill" : "star", size: buttonSize)
        let favButton = CPNowPlayingImageButton(image: favImage) { [weak self] _ in
            Task { @MainActor in
                guard let self, let channel = self.audioPlayer.currentChannel else { return }
                await self.providerManager.toggleFavorite(channel)
                self.updateNowPlayingButtons()
            }
        }

        var buttons: [CPNowPlayingButton] = [favButton]

        if let currentTrack = SXMMetadataService.shared.currentTrack {
            let isLoved = savedSongsManager.isSaved(trackID: currentTrack.id)
            let heartImage = renderSFSymbol(isLoved ? "heart.fill" : "heart", size: buttonSize)
            let heartButton = CPNowPlayingImageButton(image: heartImage) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.savedSongsManager.toggleSave(track: currentTrack, channel: self.audioPlayer.currentChannel)
                    self.updateNowPlayingButtons()
                }
            }
            buttons.append(heartButton)
        }

        if audioPlayer.timeShiftBuffer.isTimeShifted {
            let liveImage = renderSFSymbol("forward.end.fill", size: buttonSize)
            let liveButton = CPNowPlayingImageButton(image: liveImage) { [weak self] _ in
                Task { @MainActor in
                    self?.audioPlayer.skipToLive()
                }
            }
            buttons.insert(liveButton, at: 0)
        }

        nowPlaying.updateNowPlayingButtons(buttons)
    }

    private func renderSFSymbol(_ name: String, size: CGSize) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size.height * 0.8, weight: .medium)
        let symbol = UIImage(systemName: name, withConfiguration: config) ?? UIImage()
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            symbol.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func buildRootSections() -> [CPListSection] {
        var items: [CPListItem] = []

        // Now Playing row at top if something is playing
        if audioPlayer.currentChannel != nil {
            let nowPlayingItem = CPListItem(text: "Now Playing", detailText: audioPlayer.currentChannel?.name)
            nowPlayingItem.accessoryType = .disclosureIndicator
            nowPlayingItem.handler = { [weak self] _, completion in
                self?.pushNowPlaying()
                completion()
            }
            items.append(nowPlayingItem)
        }

        let favorites = providerManager.favoriteChannels
        hadFavorites = !favorites.isEmpty
        if !favorites.isEmpty {
            let item = CPListItem(text: "Favorites", detailText: "\(favorites.count) channels")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushFavorites()
                completion()
            }
            favoritesItem = item
            items.append(item)
        } else {
            favoritesItem = nil
        }

        let visibleChannels = providerManager.visibleChannels
        let groups = Dictionary(grouping: visibleChannels, by: \.group)
        let favOrder = providerManager.favoriteGroupOrder
        let grpSort = providerManager.groupSortOrder
        var groupFirstIndex: [String: Int] = [:]
        for (index, channel) in visibleChannels.enumerated() where groupFirstIndex[channel.group] == nil {
            groupFirstIndex[channel.group] = index
        }
        let sortedGroupKeys = groups.keys.sorted { a, b in
            let aFav = favOrder.firstIndex(of: a)
            let bFav = favOrder.firstIndex(of: b)
            switch (aFav, bFav) {
            case let (.some(ai), .some(bi)): return ai < bi
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                switch grpSort {
                case .providerOrder:
                    return (groupFirstIndex[a] ?? Int.max) < (groupFirstIndex[b] ?? Int.max)
                case .natural:
                    return a.localizedStandardCompare(b) == .orderedAscending
                case .alphabetical:
                    return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
                }
            }
        }
        for group in sortedGroupKeys {
            let count = groups[group]?.count ?? 0
            let item = CPListItem(text: group, detailText: "\(count) channels")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self, let channels = groups[group] else {
                    completion()
                    return
                }
                self.pushChannelList(title: group, channels: channels)
                completion()
            }
            items.append(item)
        }

        for playlist in customPlaylistManager.playlists {
            let entryCount = playlist.groups.flatMap(\.entries).count
            let item = CPListItem(text: playlist.name, detailText: "\(entryCount) channels")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushCustomPlaylist(playlist)
                completion()
            }
            items.append(item)
        }

        // Music library entry — only when a Subsonic provider is configured.
        if providerManager.subsonicAPI != nil {
            items.append(makeMusicRootItem())
        }

        if items.isEmpty {
            let placeholder = CPListItem(text: "No Channels", detailText: "Add an account on your phone")
            placeholder.handler = { _, completion in completion() }
            items.append(placeholder)
        }

        return [CPListSection(items: items)]
    }

    private func setRootTemplate() {
        let sections = buildRootSections()
        let root = CPListTemplate(title: "Adagio Stream", sections: sections)
        rootTemplate = root
        log.log("setRootTemplate: \(sections.flatMap(\.items).count) items", category: .carplay)
        interfaceController.setRootTemplate(root, animated: true, completion: nil)
    }

    private func updateRootSections() {
        let sections = buildRootSections()
        if let root = rootTemplate {
            root.updateSections(sections)
        } else {
            setRootTemplate()
        }
    }

    private func pushNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        let context = nowPlayingContext()
        if interfaceController.topTemplate is CPNowPlayingTemplate {
            log.log("pushNowPlaying: already on top, refreshing info — \(context)", category: .carplay)
            audioPlayer.refreshNowPlayingInfo()
            return
        }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            log.log("pushNowPlaying: popping back to existing template — \(context)", category: .carplay)
            interfaceController.pop(to: nowPlaying, animated: true) { [weak self] _, _ in
                Task { @MainActor in self?.audioPlayer.refreshNowPlayingInfo() }
            }
        } else {
            log.log("pushNowPlaying: pushing new template — \(context)", category: .carplay)
            interfaceController.pushTemplate(nowPlaying, animated: true) { [weak self] _, _ in
                Task { @MainActor in self?.audioPlayer.refreshNowPlayingInfo() }
            }
        }
    }

    /// Snapshot of MPNowPlayingInfoCenter at the moment a CPNowPlayingTemplate
    /// push is initiated.  The template itself draws from
    /// MPNowPlayingInfoCenter.default(), so if the values here are nil at
    /// push time the user sees a blank Now-Playing surface even though the
    /// SXM matcher may set them moments later.  Logged to diagnose the
    /// cold-launch metadata gap (bd 651.1).
    private func nowPlayingContext() -> String {
        let channelName = audioPlayer.currentChannel?.name ?? "nil"
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let title = info?[MPMediaItemPropertyTitle] as? String ?? "nil"
        let artist = info?[MPMediaItemPropertyArtist] as? String ?? "nil"
        let hasArtwork = info?[MPMediaItemPropertyArtwork] != nil
        return "channel=\"\(channelName)\", MPNowPlayingInfo: title=\"\(title)\", artist=\"\(artist)\", hasArtwork=\(hasArtwork)"
    }

    private func playChannelAndShowNowPlaying(_ channel: Channel, within channels: [Channel]) {
        log.log("CarPlay selected channel: \"\(channel.name)\" from \(channels.count) channels", category: .carplay)
        audioPlayer.channels = channels
        audioPlayer.play(channel: channel)
        pushNowPlaying()

        // Re-publish now playing info at several delays.  Some CarPlay head
        // units don't pick up metadata set before the app becomes "now
        // playing"; the cold-launch path additionally races the audio
        // session activation against the first MPNowPlayingInfoCenter
        // write, so a single 1 s refresh can miss the late SXM track
        // resolve.  Ladder: 1 s catches warm path, 3 s catches the typical
        // SXM matcher hop, 5 s catches CarPlay head units that don't
        // observe MPNowPlayingInfoCenter until well after push.  Each
        // refresh logs a NowPlaying snapshot via updateNowPlayingInfo so
        // bd 651.1 has visible per-attempt evidence.
        let refreshDelays: [TimeInterval] = [1.0, 3.0, 5.0]
        for delay in refreshDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.audioPlayer.currentChannel?.id == channel.id else { return }
                self.log.log("CarPlay refresh attempt: t+\(delay)s for \"\(channel.name)\"", category: .carplay)
                self.audioPlayer.refreshNowPlayingInfo()
            }
        }
    }

    private func trackDetailText(for channel: Channel) -> String? {
        if let track = SXMMetadataService.shared.feedTracks[channel.id] {
            return "\(track.artistDisplay) — \(track.title)"
        }
        if let game = ESPNScoreService.shared.gamesByChannel[channel.id] {
            return game.displayText
        }
        if let epgID = channel.epgChannelID,
           let program = providerManager.epgData[epgID]?.first(where: \.isCurrentlyAiring) {
            return program.title
        }
        return nil
    }

    private func pushFavorites() {
        let favorites = providerManager.favoriteChannels
        let items = favorites.map { channel in
            let item = CPListItem(text: channel.name, detailText: trackDetailText(for: channel) ?? channel.group)
            itemChannelMap[ObjectIdentifier(item)] = channel.id
            item.handler = { [weak self] _, completion in
                self?.playChannelAndShowNowPlaying(channel, within: favorites)
                completion()
            }
            loadChannelIcon(for: channel, into: item)
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Favorites", sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func loadChannelIcon(for channel: Channel, into item: CPListItem) {
        guard let logoURL = channel.logoURL else { return }
        Task {
            guard let image = await ImageCacheService.shared.image(for: logoURL) else { return }
            let size = CGSize(width: 40, height: 40)
            let renderer = UIGraphicsImageRenderer(size: size)
            let scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            item.setImage(scaled)
        }
    }

    private func sortableName(_ name: String) -> String {
        for prefix in sortPrefixes {
            if name.hasPrefix(prefix) {
                return String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return name
    }

    private func refreshChannelListDetailText() {
        for template in interfaceController.templates {
            guard let list = template as? CPListTemplate else { continue }
            for section in list.sections {
                for case let item as CPListItem in section.items {
                    guard let channelID = itemChannelMap[ObjectIdentifier(item)] else { continue }
                    let newDetail = trackDetailTextByID(channelID)
                    if let newDetail, item.detailText != newDetail {
                        item.setDetailText(newDetail)
                    }
                }
            }
        }
    }

    private func trackDetailTextByID(_ channelID: String) -> String? {
        if let track = SXMMetadataService.shared.feedTracks[channelID] {
            return "\(track.artistDisplay) — \(track.title)"
        }
        if let game = ESPNScoreService.shared.gamesByChannel[channelID] {
            return game.displayText
        }
        if let channel = providerManager.channels.first(where: { $0.id == channelID }),
           let epgID = channel.epgChannelID,
           let program = providerManager.epgData[epgID]?.first(where: \.isCurrentlyAiring) {
            return program.title
        }
        return nil
    }

    private func pushCustomPlaylist(_ playlist: CustomPlaylist) {
        let allChannels = playlist.groups.flatMap(\.entries).map(\.asChannel)

        // If only one group, skip straight to the channel list
        if playlist.groups.count == 1, let group = playlist.groups.first {
            pushChannelList(title: group.name, channels: group.entries.map(\.asChannel))
            return
        }

        let items = playlist.groups.map { group in
            let channels = group.entries.map(\.asChannel)
            let item = CPListItem(text: group.name, detailText: "\(channels.count) channels")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushChannelList(title: group.name, channels: channels)
                completion()
            }
            return item
        }

        // Add "Play All" at top if there are multiple groups
        if allChannels.count > 1 {
            let playAll = CPListItem(text: "Play All", detailText: "\(allChannels.count) channels")
            playAll.handler = { [weak self] _, completion in
                self?.pushChannelList(title: playlist.name, channels: allChannels)
                completion()
            }
            let section = CPListSection(items: [playAll] + items)
            let template = CPListTemplate(title: playlist.name, sections: [section])
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        } else {
            let section = CPListSection(items: items)
            let template = CPListTemplate(title: playlist.name, sections: [section])
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
    }

    private func pushChannelList(title: String, channels: [Channel]) {
        let grouped = Dictionary(grouping: channels) { channel -> String in
            let first = sortableName(channel.name).prefix(1).uppercased()
            return first.first?.isLetter == true ? first : "#"
        }
        let sortedKeys = grouped.keys.sorted { a, b in
            if a == "#" { return true }
            if b == "#" { return false }
            return a < b
        }

        let sections = sortedKeys.map { letter in
            let items = grouped[letter]!.map { channel in
                let item = CPListItem(text: channel.name, detailText: trackDetailText(for: channel))
                itemChannelMap[ObjectIdentifier(item)] = channel.id
                item.handler = { [weak self] _, completion in
                    self?.playChannelAndShowNowPlaying(channel, within: channels)
                    completion()
                }
                loadChannelIcon(for: channel, into: item)
                return item
            }
            return CPListSection(items: items, header: letter, sectionIndexTitle: letter)
        }

        let template = CPListTemplate(title: title, sections: sections)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Music Library Browse (8rg.1)

    /// Adds a "Music" entry to the root item list when a Subsonic provider is configured.
    /// Called from `buildRootSections()` only when `providerManager.subsonicAPI != nil`.
    private func makeMusicRootItem() -> CPListItem {
        let item = CPListItem(text: "Music", detailText: "Navidrome library")
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.pushMusicBrowse()
            completion()
        }
        return item
    }

    /// Pushes the Music browse template: a single CPListTemplate with three
    /// sections (Artists / Albums / Playlists) so we don't consume an extra
    /// level of template-stack depth for a bare category menu.
    ///
    /// Depth budget:
    ///   Root (1) → Music (2) → Artist/Album/Playlist list (3)
    ///   → Album tracks (4) → tap = play + NowPlaying singleton (5)
    ///   Total push depth ≤ 5 (CarPlay limit).
    private func pushMusicBrowse() {
        guard let api = providerManager.subsonicAPI else { return }
        log.log("Music: pushMusicBrowse", category: .carplay)

        // Build a loading placeholder — sections will be updated once async fetches return.
        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        let loadingSection = CPListSection(items: [loadingItem])
        let template = CPListTemplate(title: "Music", sections: [loadingSection])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            async let artistsResult   = self.fetchArtistItems(api: api)
            async let albumsResult    = self.fetchAlbumItems(api: api)
            async let playlistsResult = self.fetchPlaylistItems(api: api)

            let (artistItems, albumItems, playlistItems) = await (artistsResult, albumsResult, playlistsResult)

            var sections: [CPListSection] = []
            if !artistItems.isEmpty {
                sections.append(CPListSection(items: artistItems, header: "Artists", sectionIndexTitle: nil))
            }
            if !albumItems.isEmpty {
                sections.append(CPListSection(items: albumItems, header: "Albums", sectionIndexTitle: nil))
            }
            if !playlistItems.isEmpty {
                sections.append(CPListSection(items: playlistItems, header: "Playlists", sectionIndexTitle: nil))
            }
            if sections.isEmpty {
                let empty = CPListItem(text: "No music found", detailText: "Add music to your Navidrome library")
                empty.handler = { _, c in c() }
                sections = [CPListSection(items: [empty])]
            }
            template.updateSections(sections)
        }
    }

    // MARK: Artists

    private func fetchArtistItems(api: NavidromeAPI) async -> [CPListItem] {
        do {
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
                    item.setImage(musicNoteImage())
                }
                return item
            }
        } catch {
            log.log("Music: getArtists failed — \(error)", category: .carplay)
            return []
        }
    }

    // MARK: Albums (top-level: newest 50)

    private func fetchAlbumItems(api: NavidromeAPI) async -> [CPListItem] {
        do {
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
                    item.setImage(musicNoteImage())
                }
                return item
            }
        } catch {
            log.log("Music: getAlbumList2 failed — \(error)", category: .carplay)
            return []
        }
    }

    // MARK: Playlists

    private func fetchPlaylistItems(api: NavidromeAPI) async -> [CPListItem] {
        do {
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
                    item.setImage(musicNoteImage())
                }
                return item
            }
        } catch {
            log.log("Music: getPlaylists failed — \(error)", category: .carplay)
            return []
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
                        item.setImage(self.musicNoteImage())
                    }
                    return item
                }
                let section = CPListSection(items: items.isEmpty
                    ? [self.emptyMusicItem("No albums")]
                    : items)
                template.updateSections([section])
            } catch {
                self.log.log("Music: getArtist failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [self.emptyMusicItem("Failed to load")])])
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
                    let duration = track.duration.map { Self.formatDuration($0) }
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
                        item.setImage(self.musicNoteImage())
                    }
                    return item
                }
                let section = CPListSection(items: items.isEmpty
                    ? [self.emptyMusicItem("No tracks")]
                    : items)
                template.updateSections([section])
            } catch {
                self.log.log("Music: getAlbum failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [self.emptyMusicItem("Failed to load")])])
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
                    let duration = track.duration.map { Self.formatDuration($0) }
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
                        item.setImage(self.musicNoteImage())
                    }
                    return item
                }
                let section = CPListSection(items: items.isEmpty
                    ? [self.emptyMusicItem("No tracks")]
                    : items)
                template.updateSections([section])
            } catch {
                self.log.log("Music: getPlaylist failed — \(error)", category: .carplay)
                template.updateSections([CPListSection(items: [self.emptyMusicItem("Failed to load")])])
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

    /// A small music note SF Symbol used as a placeholder for music library items
    /// that have no cover art ID.
    private func musicNoteImage() -> UIImage {
        let size = CGSize(width: 40, height: 40)
        return renderSFSymbol("music.note", size: size)
    }

    /// A non-tappable placeholder item for empty or failed list states.
    private func emptyMusicItem(_ text: String) -> CPListItem {
        let item = CPListItem(text: text, detailText: nil)
        item.handler = { _, completion in completion() }
        return item
    }

    // MARK: Duration Formatting

    /// Formats a track duration in seconds as `m:ss` or `h:mm:ss`.
    nonisolated static func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
