import CarPlay
import Combine
import Foundation
import MediaPlayer
import UIKit

@MainActor
class CarPlayTemplateManager: NSObject, CPNowPlayingTemplateObserver {
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
    private var shuffleCancellable: AnyCancellable?
    private var repeatCancellable: AnyCancellable?
    private var playbackSourceCancellable: AnyCancellable?
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
        super.init()
    }

    func configure() {
        log.log("configure() starting", category: .carplay)
        // j7d.3: register this manager as the CPNowPlayingTemplateObserver so the
        // up-next button tap is delivered via nowPlayingTemplateUpNextButtonTapped(_:).
        // Only one observer can be active at a time; adding again is a no-op.
        CPNowPlayingTemplate.shared.add(self)
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

        providerManager.$carPlaySourceOrder
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

        // 8rg.2: observe playbackSource so the button set switches between
        // library (shuffle/repeat) and radio (favorite/heart/live) when the
        // source type changes.  currentChannel fires for radio→nil transitions
        // but not for nil→library; this covers that gap.
        playbackSourceCancellable = audioPlayer.$playbackSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingButtons()
            }

        // 8rg.2: observe shuffle + repeat so the CarPlay now-playing buttons
        // stay in sync with the player state for library playback.
        shuffleCancellable = audioPlayer.$shuffleEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingButtons()
            }

        repeatCancellable = audioPlayer.$repeatMode
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

        // 8rg.2: branch on playback source so music vs radio each get the
        // right now-playing buttons.  The CPNowPlayingTemplate singleton is
        // shared; we reconfigure it every time the source or relevant state
        // changes (shuffle, repeat, favorite, heart, time-shift).
        switch audioPlayer.playbackSource {
        case .library:
            updateNowPlayingButtonsForLibrary(nowPlaying)
        case .radio, .none:
            updateNowPlayingButtonsForRadio(nowPlaying)
        }
    }

    /// Configures the CPNowPlayingTemplate buttons for library (music) playback.
    ///
    /// Buttons (in order):
    ///   1. `CPNowPlayingShuffleButton` — wired to `toggleShuffle()`.
    ///      `isSelected = shuffleEnabled` so CarPlay renders the highlighted state
    ///      when shuffle is active.
    ///   2. `CPNowPlayingRepeatButton`  — wired to `cycleRepeatMode()`.
    ///      `isSelected = repeatMode != .off` so the button appears highlighted
    ///      whenever any repeat mode is active.  The cycle order is
    ///      `.off → .all → .one → .off`; CarPlay does not distinguish `.all`
    ///      from `.one` visually (it just shows a highlighted repeat icon), which
    ///      matches the single-button paradigm.
    ///
    /// Up Next (j7d.3): `isUpNextButtonEnabled` is set to `true` for library
    /// playback.  Taps are delivered to this manager via
    /// `nowPlayingTemplateUpNextButtonTapped(_:)` (CPNowPlayingTemplateObserver),
    /// which pushes a `CPListTemplate` showing the queue.
    private func updateNowPlayingButtonsForLibrary(_ nowPlaying: CPNowPlayingTemplate) {
        let shuffleButton = CPNowPlayingShuffleButton { [weak self] _ in
            Task { @MainActor in
                self?.audioPlayer.toggleShuffle()
                // updateNowPlayingButtons is driven by the $shuffleEnabled
                // publisher so no explicit call is needed here.
            }
        }
        shuffleButton.isSelected = audioPlayer.shuffleEnabled

        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            Task { @MainActor in
                self?.audioPlayer.cycleRepeatMode()
                // updateNowPlayingButtons is driven by the $repeatMode
                // publisher so no explicit call is needed here.
            }
        }
        // Highlight whenever any repeat mode is active (.all or .one).
        repeatButton.isSelected = audioPlayer.repeatMode != .off

        nowPlaying.updateNowPlayingButtons([shuffleButton, repeatButton])

        // j7d.3: enable the Up Next affordance for library playback.
        nowPlaying.upNextTitle = "Up Next"
        nowPlaying.isUpNextButtonEnabled = true

        log.log("CarPlay NowPlaying (library): shuffle=\(audioPlayer.shuffleEnabled), repeat=\(audioPlayer.repeatMode)", category: .carplay)
    }

    /// Configures the CPNowPlayingTemplate buttons for radio playback.
    ///
    /// This is the existing behavior, extracted verbatim so radio now-playing
    /// is never regressed by the library branch above.
    ///
    /// j7d.3: Up Next is explicitly disabled for radio — radio has no seekable
    /// queue, so the affordance does not apply.
    private func updateNowPlayingButtonsForRadio(_ nowPlaying: CPNowPlayingTemplate) {
        // j7d.3: disable Up Next for radio (no queue to browse).
        nowPlaying.isUpNextButtonEnabled = false
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
        var nowPlayingItem: CPListItem?

        // Now Playing row at top if something is playing
        if audioPlayer.currentChannel != nil {
            let item = CPListItem(text: "Now Playing", detailText: audioPlayer.currentChannel?.name)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushNowPlaying()
                completion()
            }
            items.append(item)
            nowPlayingItem = item
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

        // Navidrome music categories (Artists/Albums/Songs/Playlists) — only
        // when a Subsonic provider is configured. Hoisted to the root (fnv.12)
        // so the deepest browse path (Artists → albums → tracks → NowPlaying)
        // stays within CarPlay's 5-template push limit. Each category is a
        // static item that fetches lazily on tap, so a transient fetch failure
        // can never hide a category the way the old eager-section build could.
        let musicItems = providerManager.subsonicAPI != nil ? makeMusicCategoryItems() : []

        // No Navidrome: preserve the historical single, header-less section so
        // channel-only users see no visual change.
        if musicItems.isEmpty {
            if items.isEmpty {
                let placeholder = CPListItem(text: "No Channels", detailText: "Add an account on your phone")
                placeholder.handler = { _, completion in completion() }
                items.append(placeholder)
            }
            return [CPListSection(items: items)]
        }

        // Navidrome present: split into ordered, labeled sections. Now Playing
        // is pulled out into its own leading section so it stays pinned at the
        // top regardless of the streaming/music order.
        var sections: [CPListSection] = []
        if let firstNowPlaying = nowPlayingItem, items.first === firstNowPlaying {
            items.removeFirst()
            sections.append(CPListSection(items: [firstNowPlaying]))
        }

        let streamingSection = items.isEmpty
            ? nil
            : CPListSection(items: items, header: "Channels", sectionIndexTitle: nil)
        let musicSection = CPListSection(items: musicItems, header: "Music", sectionIndexTitle: nil)

        switch providerManager.carPlaySourceOrder {
        case .streamingFirst:
            if let streamingSection { sections.append(streamingSection) }
            sections.append(musicSection)
        case .navidromeFirst:
            sections.append(musicSection)
            if let streamingSection { sections.append(streamingSection) }
        }
        return sections
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

    /// Builds the four Navidrome category root items (Artists / Albums / Songs
    /// / Playlists). Hoisted to the CarPlay root (fnv.12) instead of nesting
    /// behind a single "Music" entry: removing that intermediate level keeps
    /// the deepest browse path within CarPlay's 5-template push limit while
    /// preserving per-track selection.
    ///
    /// Depth budgets (NowPlaying is a pushed template):
    ///   Artists(1) → artist albums(2) → album tracks(3) → NowPlaying(4)
    ///   Albums(1)  → album tracks(2)  → NowPlaying(3)
    ///   Songs(1)   → NowPlaying(2)
    ///   Playlists(1) → playlist tracks(2) → NowPlaying(3)
    /// Each is counted from the root list (push depth 1) → all ≤ 5.
    private func makeMusicCategoryItems() -> [CPListItem] {
        [
            musicCategoryItem(title: "Artists",   subtitle: "Browse by artist")   { $0.pushArtistsList(api: $1) },
            musicCategoryItem(title: "Albums",    subtitle: "Browse albums")      { $0.pushAlbumsList(api: $1) },
            musicCategoryItem(title: "Songs",     subtitle: "Random songs")       { $0.pushSongsList(api: $1) },
            musicCategoryItem(title: "Playlists", subtitle: "Browse playlists")   { $0.pushPlaylistsList(api: $1) },
        ]
    }

    /// Makes one Navidrome category root item. The Subsonic API is resolved at
    /// tap time (not capture time) so the item survives provider changes, and
    /// the list it pushes fetches lazily — a transient failure shows an empty
    /// list rather than hiding the whole category.
    private func musicCategoryItem(
        title: String,
        subtitle: String,
        action: @escaping (CarPlayTemplateManager, NavidromeAPI) -> Void
    ) -> CPListItem {
        let item = CPListItem(text: title, detailText: subtitle)
        item.accessoryType = .disclosureIndicator
        item.setImage(musicNoteImage())
        item.handler = { [weak self] _, completion in
            guard let self, let api = self.providerManager.subsonicAPI else { completion(); return }
            action(self, api)
            completion()
        }
        return item
    }

    /// Loading-placeholder template shared by the category list pushers.
    private func makeMusicLoadingTemplate(title: String) -> CPListTemplate {
        let loadingItem = CPListItem(text: "Loading…", detailText: nil)
        loadingItem.handler = { _, completion in completion() }
        return CPListTemplate(title: title, sections: [CPListSection(items: [loadingItem])])
    }

    private func pushArtistsList(api: NavidromeAPI) {
        log.log("Music: pushArtistsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Artists")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.fetchArtistItems(api: api)
            template.updateSections([CPListSection(items: items.isEmpty ? [self.emptyMusicItem("No artists")] : items)])
        }
    }

    private func pushAlbumsList(api: NavidromeAPI) {
        log.log("Music: pushAlbumsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Albums")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.fetchAlbumItems(api: api)
            template.updateSections([CPListSection(items: items.isEmpty ? [self.emptyMusicItem("No albums")] : items)])
        }
    }

    private func pushPlaylistsList(api: NavidromeAPI) {
        log.log("Music: pushPlaylistsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Playlists")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.fetchPlaylistItems(api: api)
            template.updateSections([CPListSection(items: items.isEmpty ? [self.emptyMusicItem("No playlists")] : items)])
        }
    }

    private func pushSongsList(api: NavidromeAPI) {
        log.log("Music: pushSongsList", category: .carplay)
        let template = makeMusicLoadingTemplate(title: "Songs")
        interfaceController.pushTemplate(template, animated: true, completion: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let items = await self.fetchSongItems(api: api)
            template.updateSections([CPListSection(items: items.isEmpty ? [self.emptyMusicItem("No songs")] : items)])
        }
    }

    // MARK: Songs (random page → play)

    private func fetchSongItems(api: NavidromeAPI) async -> [CPListItem] {
        do {
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
                    item.setImage(musicNoteImage())
                }
                return item
            }
        } catch {
            log.log("Music: getRandomSongs failed — \(error)", category: .carplay)
            return []
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

    // MARK: - Now Playing Button State Helpers (8rg.2)

    /// Returns whether the CarPlay shuffle button should appear selected (highlighted).
    ///
    /// `true` when shuffle is enabled; `false` otherwise.
    /// Extracted as a static helper so unit tests can verify the mapping
    /// without instantiating a live `CarPlayTemplateManager`.
    nonisolated static func shuffleButtonSelected(shuffleEnabled: Bool) -> Bool {
        shuffleEnabled
    }

    /// Returns whether the CarPlay repeat button should appear selected (highlighted).
    ///
    /// `true` when any repeat mode is active (`.all` or `.one`); `false` when `.off`.
    /// CarPlay's `CPNowPlayingRepeatButton` is a single-tap cycle button — it
    /// does not visually distinguish `.all` from `.one`.  The selection state
    /// simply reflects "something is repeating" vs "nothing is repeating".
    ///
    /// The full cycle driven by `cycleRepeatMode()` is: `.off → .all → .one → .off`.
    nonisolated static func repeatButtonSelected(repeatMode: RepeatMode) -> Bool {
        repeatMode != .off
    }

    // MARK: - Up Next Queue (j7d.3)

    /// Called by CarPlay when the user taps the Up Next button on the
    /// `CPNowPlayingTemplate`.  Only fires when `isUpNextButtonEnabled == true`,
    /// which we set only during library playback.
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
                detail = Self.formatDuration(duration)
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

    /// Returns the detail text that should appear on an Up Next queue row.
    ///
    /// - If the row is the currently-playing track, returns `"Now Playing"`.
    /// - Otherwise, returns the formatted duration string (if available) or `nil`.
    ///
    /// Extracted as a static helper so unit tests can verify the row-label
    /// logic without instantiating a live `CarPlayTemplateManager`.
    nonisolated static func upNextRowDetail(
        index: Int,
        currentIndex: Int?,
        duration: Int?
    ) -> String? {
        if index == currentIndex { return "Now Playing" }
        return duration.map { formatDuration($0) }
    }
}
