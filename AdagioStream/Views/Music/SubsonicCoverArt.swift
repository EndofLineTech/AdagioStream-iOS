// 0xy.2 — Subsonic cover-art view
//
// Renders a Navidrome/Subsonic cover-art image via ImageCacheService using a
// stable cache key (host + coverArtID + size), independent of per-request auth
// salts.  See ImageCacheService.coverArtCacheKey for the key derivation.
//
// Usage:
//   SubsonicCoverArt(api: api, coverArtID: album.coverArt, size: 300,
//                    width: 120, height: 120, cornerRadius: 8)
//
// Placeholder: music note SF Symbol while loading; same symbol on failure (with
// a retry tap target when the load fails).  0xy.3 will use this view for the
// browse-list rows and album/artist detail headers.
//
// Gated #if canImport(UIKit) because ImageCacheService is UIKit-only.
#if canImport(UIKit)
import SwiftUI
import UIKit

/// A SwiftUI view that displays a Subsonic cover-art image through
/// `ImageCacheService`.  It uses a stable cache key derived from the API host,
/// cover-art ID, and size — so the per-request auth salt never busts the cache.
///
/// - Note: Passing a `nil` `coverArtID` renders only the music-note placeholder.
public struct SubsonicCoverArt: View {

    // MARK: - Inputs

    let api: NavidromeAPI
    let coverArtID: String?
    let size: Int?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    // MARK: - State

    @State private var loadedImage: UIImage?
    @State private var hasFailed = false
    @State private var retryID = 0

    // MARK: - Init

    /// - Parameters:
    ///   - api: A configured `NavidromeAPI` instance.  Provides the host for
    ///     stable key derivation and builds the authed fetch URL on miss.
    ///   - coverArtID: The Subsonic `coverArt` identifier, typically from
    ///     `Artist.coverArt`, `Album.coverArt`, or `Track.coverArt`.
    ///     Pass `nil` to show the placeholder only.
    ///   - size: Optional thumbnail pixel size.  Affects the stable cache key
    ///     so that 64-px and 300-px thumbnails of the same item are cached
    ///     separately.
    ///   - width: Layout width.
    ///   - height: Layout height.
    ///   - cornerRadius: Corner radius for the clipping shape.
    public init(
        api: NavidromeAPI,
        coverArtID: String?,
        size: Int? = nil,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.api = api
        self.coverArtID = coverArtID
        self.size = size
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color(.secondarySystemBackground))

            if let uiImage = loadedImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if hasFailed {
                placeholder
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .background(Circle().fill(.black.opacity(0.5)))
                            .padding(4)
                    }
                    .onTapGesture { retryID += 1 }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: taskID) {
            await loadImage()
        }
    }

    // MARK: - Private

    /// A task ID that changes when either the cover-art ID or retry counter
    /// changes, triggering a fresh load.
    private var taskID: String {
        "\(coverArtID ?? "nil"):\(retryID)"
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: min(width, height) * 0.35))
            .foregroundStyle(.secondary)
    }

    private func loadImage() async {
        guard let id = coverArtID, !id.isEmpty else { return }
        hasFailed = false
        loadedImage = nil

        guard let image = await api.fetchCoverArtImage(id: id, size: size) else {
            hasFailed = true
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            loadedImage = image
        }
    }
}

#endif // canImport(UIKit)
