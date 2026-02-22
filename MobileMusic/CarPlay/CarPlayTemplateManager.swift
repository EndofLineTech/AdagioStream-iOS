import CarPlay
import Foundation

@MainActor
class CarPlayTemplateManager {
    let interfaceController: CPInterfaceController
    let audioPlayer: AudioPlayerService

    init(interfaceController: CPInterfaceController, audioPlayer: AudioPlayerService) {
        self.interfaceController = interfaceController
        self.audioPlayer = audioPlayer
    }

    func configure() {
        let favoritesTemplate = buildFavoritesTemplate()
        let categoriesTemplate = buildCategoriesTemplate()
        let nowPlayingTemplate = CPNowPlayingTemplate.shared

        let tabBar = CPTabBarTemplate(templates: [favoritesTemplate, categoriesTemplate, nowPlayingTemplate])
        interfaceController.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    private func buildFavoritesTemplate() -> CPListTemplate {
        let favorites = audioPlayer.channels.filter(\.isFavorite)
        let items = favorites.map { channel in
            let item = CPListItem(text: channel.name, detailText: channel.group)
            item.handler = { [weak self] _, completion in
                self?.audioPlayer.play(channel: channel)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Favorites", sections: [section])
        template.tabImage = UIImage(systemName: "star.fill")
        return template
    }

    private func buildCategoriesTemplate() -> CPListTemplate {
        let groups = Dictionary(grouping: audioPlayer.channels, by: \.group)
        let items = groups.keys.sorted().map { group in
            let count = groups[group]?.count ?? 0
            let item = CPListItem(text: group, detailText: "\(count) channels")
            item.handler = { [weak self] _, completion in
                guard let self, let channels = groups[group] else {
                    completion()
                    return
                }
                let channelTemplate = self.buildChannelList(title: group, channels: channels)
                self.interfaceController.pushTemplate(channelTemplate, animated: true, completion: nil)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Categories", sections: [section])
        template.tabImage = UIImage(systemName: "list.bullet")
        return template
    }

    private func buildChannelList(title: String, channels: [Channel]) -> CPListTemplate {
        let items = channels.map { channel in
            let item = CPListItem(text: channel.name, detailText: nil)
            item.handler = { [weak self] _, completion in
                self?.audioPlayer.play(channel: channel)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        return CPListTemplate(title: title, sections: [section])
    }
}
