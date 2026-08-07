// ImageCacheService is gated `#if canImport(UIKit)` per Phase 0 G3. UIKit
// is available on iOS and tvOS, so the service is symbol-present on both
// app targets, and absent on the macOS dev-host where `swift build`
// happens to run.
#if canImport(UIKit)
import UIKit
import CryptoKit

/// Disk- and memory-cached image fetcher used for channel logos and album
/// artwork. Stable URLs are persisted to `AdagioStream/image-cache`;
/// ephemeral URLs (track artwork that rotates) live in memory only.
public actor ImageCacheService {
    public static let shared = ImageCacheService()

    private var manifest: Set<String> = []
    private let cacheDir: URL
    private let manifestURL: URL
    private let logger = DebugLogger.shared
    /// In-memory LRU cache to avoid repeated disk I/O.
    private let memoryCache = NSCache<NSString, UIImage>()
    /// Bumped by `clearAll()` so in-flight fetches suspended at an await don't
    /// resurrect a pre-clear `diskImage` via the offline fallback (actor
    /// reentrancy race). (bead beads_mobilemusic-7dy)
    private var clearGeneration = 0

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("AdagioStream/image-cache", isDirectory: true)
        manifestURL = cacheDir.appendingPathComponent("image-cache-manifest.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
        }
        memoryCache.countLimit = 200
    }

    /// Persistent cache (disk + memory) for stable images like channel logos.
    public func image(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        let nsKey = key as NSString

        // 1. In-memory hit — no disk I/O needed.
        // ponytail: NSCache hits bypass the 24h TTL for the process lifetime —
        // acceptable ceiling: the bug fixed was cross-launch permanence, and
        // NSCache evicts under memory pressure anyway.
        if let memImage = memoryCache.object(forKey: nsKey) {
            return memImage
        }

        // 2. Disk lookup — the URL is NOT a change detector: Dispatcharr serves
        //    channel logos at stable URLs (/api/channels/logos/<id>/cache/), so
        //    the image behind a URL can change while the URL stays the same.
        //    A disk hit is only trusted while fresh (24h TTL); stale entries
        //    are refetched, with the disk copy kept as an offline fallback.
        //    (bead beads_mobilemusic-7dy)
        let fileURL = cacheDir.appendingPathComponent("\(key).dat")
        let diskImage: UIImage? = manifest.contains(key) ? loadFromDisk(fileURL) : nil

        if let diskImage, Self.isFresh(modifiedAt: modificationDate(of: fileURL)) {
            memoryCache.setObject(diskImage, forKey: nsKey)
            logger.log("HIT \(url.lastPathComponent)", category: .imageCache)
            return diskImage
        }

        // 3. Cache miss or stale — fetch and overwrite (saveToDisk refreshes mtime).
        // The actor suspends at the await below; if clearAll() runs during that
        // suspension, the captured diskImage is stale and must not be re-inserted
        // by the fallback paths — the generation check guards that.
        let generation = clearGeneration
        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let img = UIImage(data: data) else {
                logger.log("MISS (invalid data) \(url.lastPathComponent)", category: .imageCache)
                return offlineFallback(diskImage, nsKey: nsKey, url: url, generation: generation)
            }

            logger.log(diskImage == nil
                ? "MISS (fetched) \(url.lastPathComponent)"
                : "STALE (refreshed) \(url.lastPathComponent)", category: .imageCache)
            memoryCache.setObject(img, forKey: nsKey)
            saveToDisk(data: data, fileURL: fileURL, key: key)
            return img
        } catch {
            logger.log("MISS (error) \(url.lastPathComponent): \(error.localizedDescription)", category: .imageCache)
            return offlineFallback(diskImage, nsKey: nsKey, url: url, generation: generation)
        }
    }

    /// Wipes the entire image cache: memory, manifest, and the on-disk
    /// directory (which contains the manifest file). Backs the
    /// "Clear Image Cache" advanced setting. (bead beads_mobilemusic-7dy)
    public func clearAll() {
        clearGeneration += 1
        memoryCache.removeAllObjects()
        manifest.removeAll()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        logger.log("Cleared image cache (user-initiated)", category: .imageCache)
    }

    /// Memory-only cache for ephemeral images like album art that rotate frequently.
    /// Avoids unbounded disk growth from track artwork that won't be viewed again.
    public func ephemeralImage(for url: URL) async -> UIImage? {
        let nsKey = cacheKey(for: url) as NSString

        if let memImage = memoryCache.object(forKey: nsKey) {
            return memImage
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let img = UIImage(data: data) else { return nil }
            memoryCache.setObject(img, forKey: nsKey)
            return img
        } catch {
            logger.log("MISS (error) \(url.lastPathComponent)", category: .imageCache)
            return nil
        }
    }

    // MARK: - Subsonic cover-art caching (0xy.2)
    //
    // Subsonic `getCoverArt` URLs include per-request auth parameters
    // (u / t / s / c / v / f).  The salt `s` is regenerated for every call,
    // so the token `t = MD5(password + salt)` also changes — meaning the same
    // cover-art ID produces a different URL each time.  If we keyed the cache
    // by the full authed URL, every view render would be a cache miss.
    //
    // The fix: key by a STABLE string derived from the server origin, cover-art
    // ID, and requested size — not the authed URL.  The authed URL is built once
    // on a cache miss and used only for the network fetch; the key is what drives
    // all subsequent lookups.

    /// Computes the stable cache key for a Subsonic cover-art request.
    ///
    /// The key is `SHA256("coverart:<host>:<coverArtID>:<size>")` where `size`
    /// is the pixel dimension or `"full"` when no size is requested.  This is
    /// independent of per-request auth params (u/t/s) so the same image always
    /// hits the cache regardless of which salt was used to build the fetch URL.
    ///
    /// - Parameters:
    ///   - host: The server origin (scheme + host + port), e.g.
    ///     `"https://music.example.com"`.
    ///   - coverArtID: The Subsonic `coverArt` field value.
    ///   - size: Optional thumbnail pixel size.
    /// - Returns: A 64-character lowercase hex SHA-256 digest.
    public static func coverArtCacheKey(host: String, coverArtID: String, size: Int?) -> String {
        let sizeToken = size.map { String($0) } ?? "full"
        let input = "coverart:\(host):\(coverArtID):\(sizeToken)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Disk- and memory-cached image for Subsonic cover art.
    ///
    /// Uses a stable cache key (host + coverArtID + size) so the cache hits
    /// regardless of the per-request auth salt embedded in `fetchURL`.
    ///
    /// - Parameters:
    ///   - stableKey: The key returned by `coverArtCacheKey(host:coverArtID:size:)`.
    ///   - fetchURL: The fully-authed `getCoverArt.view` URL used only on a
    ///     cache miss to fetch the image from the server.
    /// - Returns: The cached or freshly-fetched image, or `nil` on failure.
    public func coverArtImage(stableKey: String, fetchURL: URL) async -> UIImage? {
        let nsKey = stableKey as NSString

        // 1. In-memory hit
        if let memImage = memoryCache.object(forKey: nsKey) {
            logger.log("HIT (coverArt) \(stableKey.prefix(8))…", category: .imageCache)
            return memImage
        }

        // 2. Disk hit
        let fileURL = cacheDir.appendingPathComponent("\(stableKey).dat")
        if manifest.contains(stableKey), let cachedImage = loadFromDisk(fileURL) {
            memoryCache.setObject(cachedImage, forKey: nsKey)
            logger.log("HIT (coverArt disk) \(stableKey.prefix(8))…", category: .imageCache)
            return cachedImage
        }

        // 3. Cache miss — fetch with the authed URL; store under the stable key
        do {
            let (data, _) = try await URLSession.shared.data(from: fetchURL)
            guard let img = UIImage(data: data) else {
                logger.log("MISS (coverArt invalid data) \(stableKey.prefix(8))…", category: .imageCache)
                return nil
            }
            logger.log("MISS (coverArt fetched) \(stableKey.prefix(8))…", category: .imageCache)
            memoryCache.setObject(img, forKey: nsKey)
            saveToDisk(data: data, fileURL: fileURL, key: stableKey)
            return img
        } catch {
            logger.log("MISS (coverArt error) \(stableKey.prefix(8))…: \(error.localizedDescription)", category: .imageCache)
            return nil
        }
    }

    // MARK: - Staleness (bead beads_mobilemusic-7dy)

    /// How long a disk-cached stable-URL image is trusted before revalidation.
    static let freshnessTTL: TimeInterval = 24 * 60 * 60

    /// Pure freshness decision, extracted for testability.
    /// A missing modification date counts as stale.
    static func isFresh(modifiedAt: Date?, now: Date = Date(), ttl: TimeInterval = freshnessTTL) -> Bool {
        guard let modifiedAt else { return false }
        return now.timeIntervalSince(modifiedAt) < ttl
    }

    private func modificationDate(of fileURL: URL) -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// A stale logo beats a blank one: when a refetch fails, serve the disk copy.
    /// `generation` was captured before the fetch await; a mismatch means
    /// clearAll() ran mid-fetch and the disk copy must not be resurrected.
    private func offlineFallback(_ diskImage: UIImage?, nsKey: NSString, url: URL, generation: Int) -> UIImage? {
        guard let diskImage, generation == clearGeneration else { return nil }
        memoryCache.setObject(diskImage, forKey: nsKey)
        logger.log("STALE (offline fallback) \(url.lastPathComponent)", category: .imageCache)
        return diskImage
    }

    // MARK: - Private

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadFromDisk(_ fileURL: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    private func saveToDisk(data: Data, fileURL: URL, key: String) {
        try? data.write(to: fileURL)
        manifest.insert(key)
        saveManifest()
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL)
    }
}

#endif // canImport(UIKit)
