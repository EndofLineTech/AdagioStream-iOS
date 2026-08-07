// UIActivityViewController is iOS-only — gate so the file is symbol-absent
// on tvOS when sources are shared. tvOS will not surface share affordances.
#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI bridge for `UIActivityViewController`.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
