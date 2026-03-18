import UIKit
import CryptoKit

actor ImageCacheService {
    static let shared = ImageCacheService()

    private struct ManifestEntry: Codable {
        var etag: String?
        var lastModified: String?
        var cachedAt: Date
        var immutable: Bool?
    }

    private var manifest: [String: ManifestEntry] = [:]
    private let cacheDir: URL
    private let manifestURL: URL
    private let logger = DebugLogger.shared
    /// Skip revalidation for non-immutable images cached within this window.
    private let freshnessTTL: TimeInterval = 86400 // 24 hours
    /// In-memory LRU cache to avoid repeated disk I/O.
    private let memoryCache = NSCache<NSString, UIImage>()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("AdagioStream/image-cache", isDirectory: true)
        manifestURL = cacheDir.appendingPathComponent("image-cache-manifest.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = (try? decoder.decode([String: ManifestEntry].self, from: data)) ?? [:]
        }
        memoryCache.countLimit = 200
    }

    func image(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        let nsKey = key as NSString

        // 1. Check in-memory cache first
        if let memImage = memoryCache.object(forKey: nsKey) {
            return memImage
        }

        let fileURL = cacheDir.appendingPathComponent("\(key).dat")
        let hasCached = FileManager.default.fileExists(atPath: fileURL.path)
        let entry = manifest[key]

        if hasCached {
            let cachedImage = loadFromDisk(fileURL)
            if let cachedImage { memoryCache.setObject(cachedImage, forKey: nsKey) }

            // Content-addressed URLs (e.g. Spotify CDN) are immutable —
            // if the content changes, the URL changes. Never revalidate.
            if entry?.immutable == true || isImmutableURL(url) {
                if entry?.immutable != true {
                    manifest[key]?.immutable = true
                    saveManifest()
                }
                logger.log("HIT (immutable) \(url.lastPathComponent)", category: .imageCache)
                return cachedImage
            }

            // Skip revalidation if cached recently
            if let cachedAt = entry?.cachedAt, Date().timeIntervalSince(cachedAt) < freshnessTTL {
                logger.log("HIT (fresh) \(url.lastPathComponent)", category: .imageCache)
                return cachedImage
            }

            // Revalidate in background — don't block the caller
            logger.log("HIT (stale, revalidating) \(url.lastPathComponent)", category: .imageCache)
            Task { [entry] in
                await revalidate(url: url, key: key, fileURL: fileURL, entry: entry)
            }
            return cachedImage
        }

        // No cache — fresh fetch
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let httpResponse = response as? HTTPURLResponse

            guard let img = UIImage(data: data) else {
                logger.log("MISS (invalid data) \(url.lastPathComponent)", category: .imageCache)
                return nil
            }

            logger.log("MISS (fetched) \(url.lastPathComponent)", category: .imageCache)
            memoryCache.setObject(img, forKey: nsKey)
            saveToDisk(data: data, fileURL: fileURL, key: key, response: httpResponse, immutable: isImmutableURL(url))
            return img
        } catch {
            logger.log("MISS (error) \(url.lastPathComponent): \(error.localizedDescription)", category: .imageCache)
            return nil
        }
    }

    /// Background revalidation — updates the cache without blocking the UI.
    private func revalidate(url: URL, key: String, fileURL: URL, entry: ManifestEntry?) async {
        var request = URLRequest(url: url)
        if let etag = entry?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = entry?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            if httpResponse?.statusCode == 304 {
                // Still valid — just refresh the timestamp
                logger.log("REVALIDATED (304) \(url.lastPathComponent)", category: .imageCache)
                manifest[key]?.cachedAt = Date()
                saveManifest()
            } else if httpResponse?.statusCode == 200 {
                logger.log("REVALIDATED (updated) \(url.lastPathComponent)", category: .imageCache)
                saveToDisk(data: data, fileURL: fileURL, key: key, response: httpResponse, immutable: false)
                // Update in-memory cache too
                if let img = UIImage(data: data) {
                    memoryCache.setObject(img, forKey: key as NSString)
                }
            }
        } catch {
            logger.log("REVALIDATE failed \(url.lastPathComponent): \(error.localizedDescription)", category: .imageCache)
        }
    }

    // MARK: - Private

    /// Spotify CDN URLs are content-addressed: the hash in the path IS
    /// the content identifier.  If the artwork changes, a new URL is issued.
    /// These never need revalidation.
    private func isImmutableURL(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return host.contains("scdn.co") || host.contains("spotifycdn.com")
    }

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadFromDisk(_ fileURL: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    private func saveToDisk(data: Data, fileURL: URL, key: String, response: HTTPURLResponse?, immutable: Bool) {
        try? data.write(to: fileURL)
        manifest[key] = ManifestEntry(
            etag: response?.value(forHTTPHeaderField: "Etag"),
            lastModified: response?.value(forHTTPHeaderField: "Last-Modified"),
            cachedAt: Date(),
            immutable: immutable
        )
        saveManifest()
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        manifest = (try? decoder.decode([String: ManifestEntry].self, from: data)) ?? [:]
    }

    private func saveManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL)
    }
}
