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

    init(interfaceController: CPInterfaceController, audioPlayer: AudioPlayerService, providerManager: ProviderManager) {
        self.interfaceController = interfaceController
        self.audioPlayer = audioPlayer
        self.providerManager = providerManager
    }

    func configure() {
        configureNowPlaying()
        setRootTemplate()

        cancellable = providerManager.$channels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.setRootTemplate()
            }
    }

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared

        let chDownImage = renderSFSymbol("minus.circle.fill", size: CGSize(width: 44, height: 44))
        let chUpImage = renderSFSymbol("plus.circle.fill", size: CGSize(width: 44, height: 44))

        let chDown = CPNowPlayingImageButton(image: chDownImage) { [weak self] _ in
            Task { @MainActor in self?.audioPlayer.playPrevious() }
        }
        let chUp = CPNowPlayingImageButton(image: chUpImage) { [weak self] _ in
            Task { @MainActor in self?.audioPlayer.playNext() }
        }

        nowPlaying.updateNowPlayingButtons([chDown, chUp])
    }

    private func renderSFSymbol(_ name: String, size: CGSize) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: size.height * 0.8, weight: .medium)
        let symbol = UIImage(systemName: name, withConfiguration: config) ?? UIImage()
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            symbol.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func setRootTemplate() {
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
        if !favorites.isEmpty {
            let item = CPListItem(text: "Favorites", detailText: "\(favorites.count) channels")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.pushFavorites()
                completion()
            }
            items.append(item)
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

        let section = CPListSection(items: items)
        let root = CPListTemplate(title: "Adagio Stream", sections: [section])
        interfaceController.setRootTemplate(root, animated: true, completion: nil)
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
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Favorites", sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushChannelList(title: String, channels: [Channel]) {
        let items = channels.map { channel in
            let item = CPListItem(text: channel.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.playChannelAndShowNowPlaying(channel)
                completion()
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: title, sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }
}
