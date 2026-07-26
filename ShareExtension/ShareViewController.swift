import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {

    private let appGroupID = Constants.AppGroup.identifier
    private let pendingURLKey = Constants.AppGroup.pendingSharedURLsKey

    /// beads_mobilemusic-uxb.6: attachments from every input item, flattened.
    /// Both isContentValid() and didSelectPost() need this same set.
    private var allAttachments: [NSItemProvider] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return [] }
        return items.flatMap { $0.attachments ?? [] }
    }

    override func isContentValid() -> Bool {
        ShareURLValidation.hasURLAttachment(in: allAttachments)
    }

    override func didSelectPost() {
        guard let provider = allAttachments.first(
            where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        ) else {
            showNothingFoundAlert()
            return
        }

        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
            var url: URL?
            if let sharedURL = data as? URL {
                url = sharedURL
            } else if let data = data as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            }

            DispatchQueue.main.async {
                if let url {
                    self?.saveSharedURL(url)
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    // Conformed to the URL UTI but failed to load as one —
                    // surface it instead of silently completing (uxb.6).
                    self?.showNothingFoundAlert()
                }
            }
        }
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    /// beads_mobilemusic-uxb.6: visible feedback when nothing shareable was
    /// found, instead of completing the request silently either way.
    private func showNothingFoundAlert() {
        let alert = UIAlertController(
            title: "Nothing to Save",
            message: "Couldn't find a link in what you shared.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        present(alert, animated: true)
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
