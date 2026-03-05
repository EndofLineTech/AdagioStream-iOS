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
            // Conditional revalidation
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
                    logger.log("HIT (304) \(url.lastPathComponent)", category: .imageCache)
                    return loadFromDisk(fileURL)
                }

                if httpResponse?.statusCode == 200, let img = UIImage(data: data) {
                    logger.log("REVALIDATED \(url.lastPathComponent)", category: .imageCache)
                    saveToDisk(data: data, fileURL: fileURL, key: key, response: httpResponse)
                    return img
                }

                // Unexpected status — fall back to cached
                logger.log("HIT (fallback, status \(httpResponse?.statusCode ?? 0)) \(url.lastPathComponent)", category: .imageCache)
                return loadFromDisk(fileURL)
            } catch {
                // Network error — return cached image (offline-friendly)
                logger.log("HIT (offline) \(url.lastPathComponent)", category: .imageCache)
                return loadFromDisk(fileURL)
            }
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
