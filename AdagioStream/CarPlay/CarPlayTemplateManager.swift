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
}
