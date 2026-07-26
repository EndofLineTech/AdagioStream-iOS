import Foundation
import UniformTypeIdentifiers

/// Pure, testable check for whether a share-sheet's attachments include a
/// URL (beads_mobilemusic-uxb.6). ShareViewController uses this to gate the
/// Post button (isContentValid()) and to distinguish "saved" from "nothing
/// found" in didSelectPost() before completing the request.
///
/// Kept out of ShareViewController.swift (which depends on Social/UIKit,
/// unavailable to the AdagioStreamTests target) so it's unit-testable; this
/// file is compiled into both the AdagioStream app target and the
/// ShareExtension target via project.yml's shared-file sources (mirrors how
/// Constants.swift is already shared between the two).
enum ShareURLValidation {
    static func hasURLAttachment(in attachments: [NSItemProvider]) -> Bool {
        attachments.contains { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
    }
}
