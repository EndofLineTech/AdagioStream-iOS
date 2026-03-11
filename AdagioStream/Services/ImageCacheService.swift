import UIKit
import CryptoKit

actor ImageCacheService {
    static let shared = ImageCacheService()

    private struct ManifestEntry: Codable {
        var etag: String?
        var lastModified: String?
        var cachedAt: Date
    }

    private var manifest: [String: ManifestEntry] = [:]
    private let cacheDir: URL
    private let manifestURL: URL
    private let logger = DebugLogger.shared
    /// Skip revalidation for images cached within this window.
    private let freshnessTTL: TimeInterval = 3600 // 1 hour

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = appSupport.appendingPathComponent("AdagioStream/image-cache", isDirectory: true)
        manifestURL = cacheDir.appendingPathComponent("image-cache-manifest.json")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = (try? JSONDecoder().decode([String: ManifestEntry].self, from: data)) ?? [:]
        }
    }

    func image(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        let fileURL = cacheDir.appendingPathComponent("\(key).dat")
        let hasCached = FileManager.default.fileExists(atPath: fileURL.path)
        let entry = manifest[key]

        if hasCached {
            // Always return cached image immediately
            let cachedImage = loadFromDisk(fileURL)

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
            saveToDisk(data: data, fileURL: fileURL, key: key, response: httpResponse)
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
                saveToDisk(data: data, fileURL: fileURL, key: key, response: httpResponse)
            }
        } catch {
            logger.log("REVALIDATE failed \(url.lastPathComponent): \(error.localizedDescription)", category: .imageCache)
        }
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

    private func saveToDisk(data: Data, fileURL: URL, key: String, response: HTTPURLResponse?) {
        try? data.write(to: fileURL)
        manifest[key] = ManifestEntry(
            etag: response?.value(forHTTPHeaderField: "Etag"),
            lastModified: response?.value(forHTTPHeaderField: "Last-Modified"),
            cachedAt: Date()
        )
        saveManifest()
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        manifest = (try? JSONDecoder().decode([String: ManifestEntry].self, from: data)) ?? [:]
    }

    private func saveManifest() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: manifestURL)
    }
}
