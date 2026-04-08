import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    private let appGroupID = "group.com.adagiostream.app"
    private let pendingURLKey = "pendingSharedURLs"

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                        var url: URL?
                        if let sharedURL = data as? URL {
                            url = sharedURL
                        } else if let data = data as? Data {
                            url = URL(dataRepresentation: data, relativeTo: nil)
                        }

                        if let url {
                            self?.saveSharedURL(url)
                        }
                        DispatchQueue.main.async {
                            self?.extensionContext?.completeRequest(returningItems: nil)
                        }
                    }
                    return
                }
            }
        }

        extensionContext?.completeRequest(returningItems: nil)
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    private func saveSharedURL(_ url: URL) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        let name = contentText?.trimmingCharacters(in: .whitespaces) ?? ""
        let entry: [String: String] = [
            "url": url.absoluteString,
            "name": name.isEmpty ? url.host ?? url.absoluteString : name
        ]

        var pending = defaults.array(forKey: pendingURLKey) as? [[String: String]] ?? []
        pending.append(entry)
        defaults.set(pending, forKey: pendingURLKey)
    }
}
