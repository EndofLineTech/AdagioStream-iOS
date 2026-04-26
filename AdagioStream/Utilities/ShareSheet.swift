import SwiftUI
import UIKit

/// SwiftUI bridge for `UIActivityViewController`. iOS-only — `UIKit` and
/// `UIActivityViewController` are not available on tvOS.
///
/// Was previously colocated with cross-platform extensions in
/// `Utilities/Extensions.swift`; split out during Phase 0 (bgc.5) when the
/// extensions moved to `AdagioStreamCore`.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
