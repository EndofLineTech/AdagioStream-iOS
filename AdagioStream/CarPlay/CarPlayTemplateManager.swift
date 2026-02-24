import CarPlay
import Combine
import Foundation
import UIKit

@MainActor
class CarPlayTemplateManager {
    let interfaceController: CPInterfaceController
    let audioPlayer: AudioPlayerService
    let providerManager: ProviderManager
    private var cancellable: AnyCancellable?
    private var channelCancellable: AnyCancellable?
    private var rootTemplate: CPListTemplate?
    private var favoritesItem: CPListItem?
    private var hadFavorites = false

    init(interfaceController: CPInterfaceController, audioPlayer: AudioPlayerService, providerManager: ProviderManager) {
        self.interfaceController = interfaceController
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
    }

    func configure() {
        updateNowPlayingButtons()
        setRootTemplate()

        cancellable = providerManager.$channels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let hasFavorites = !self.providerManager.favoriteChannels.isEmpty
                if hasFavorites != self.hadFavorites {
                    // Favorites row added or removed — structural change
                    self.updateRootSections()
                } else if let item = self.favoritesItem, hasFavorites {
                    // Just update the count in place without resetting scroll
                    let count = self.providerManager.favoriteChannels.count
                    item.setDetailText("\(count) channels")
                }
                self.updateNowPlayingButtons()
            }

        channelCancellable = audioPlayer.$currentChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingButtons()
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

        nowPlaying.updateNowPlayingButtons([favButton])
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

        let groups = Dictionary(grouping: providerManager.channels, by: \.group)
        for group in groups.keys.sorted() {
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

        if items.isEmpty {
            let placeholder = CPListItem(text: "No Channels", detailText: "Add a provider on your phone")
            placeholder.handler = { _, completion in completion() }
            items.append(placeholder)
        }

        return [CPListSection(items: items)]
    }

    private func setRootTemplate() {
        let sections = buildRootSections()
        let root = CPListTemplate(title: "Adagio Stream", sections: sections)
        rootTemplate = root
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
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    private func playChannelAndShowNowPlaying(_ channel: Channel) {
        audioPlayer.channels = providerManager.channels
        audioPlayer.play(channel: channel)
        pushNowPlaying()
    }

    private func pushFavorites() {
        let favorites = providerManager.favoriteChannels
        let items = favorites.map { channel in
            let item = CPListItem(text: channel.name, detailText: channel.group)
            item.handler = { [weak self] _, completion in
                self?.playChannelAndShowNowPlaying(channel)
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
            guard let (data, _) = try? await URLSession.shared.data(from: logoURL),
                  let image = UIImage(data: data) else { return }
            let size = CGSize(width: 40, height: 40)
            let renderer = UIGraphicsImageRenderer(size: size)
            let scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            item.setImage(scaled)
        }
    }

    private func pushChannelList(title: String, channels: [Channel]) {
        let grouped = Dictionary(grouping: channels) { channel -> String in
            let first = channel.name.prefix(1).uppercased()
            return first.first?.isLetter == true ? first : "#"
        }
        let sortedKeys = grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }

        let sections = sortedKeys.map { letter in
            let items = grouped[letter]!.map { channel in
                let item = CPListItem(text: channel.name, detailText: nil)
                item.handler = { [weak self] _, completion in
                    self?.playChannelAndShowNowPlaying(channel)
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
