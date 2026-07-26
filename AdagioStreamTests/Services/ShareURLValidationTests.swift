import XCTest
import UniformTypeIdentifiers
@testable import AdagioStream

/// beads_mobilemusic-uxb.6: ShareExtension can't be exercised directly from
/// AdagioStreamTests (separate target, Social/UIKit-dependent), so the pure
/// UTI-matching decision lives in ShareURLValidation and is covered here.
final class ShareURLValidationTests: XCTestCase {

    func testNoAttachmentsIsInvalid() {
        XCTAssertFalse(ShareURLValidation.hasURLAttachment(in: []))
    }

    func testURLAttachmentIsValid() {
        let provider = NSItemProvider(item: URL(string: "https://example.com")! as NSURL, typeIdentifier: UTType.url.identifier)
        XCTAssertTrue(ShareURLValidation.hasURLAttachment(in: [provider]))
    }

    func testPlainTextOnlyAttachmentIsInvalid() {
        let provider = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
        XCTAssertFalse(ShareURLValidation.hasURLAttachment(in: [provider]))
    }

    func testImageOnlyAttachmentIsInvalid() {
        let provider = NSItemProvider(item: Data() as NSData, typeIdentifier: UTType.image.identifier)
        XCTAssertFalse(ShareURLValidation.hasURLAttachment(in: [provider]))
    }

    func testURLAmongOtherAttachmentsIsValid() {
        let text = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
        let url = NSItemProvider(item: URL(string: "https://example.com")! as NSURL, typeIdentifier: UTType.url.identifier)
        XCTAssertTrue(ShareURLValidation.hasURLAttachment(in: [text, url]))
    }
}
