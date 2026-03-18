import UIKit
import CryptoKit

actor ImageCacheService {
    static let shared = ImageCacheService()

    private var manifest: Set<String> = []
    private let cacheDir: URL
    private let manifestURL: URL
    private let logger = DebugLogger.shared
    /// In-memory LRU cache to avoid repeated disk I/O.
    private let memoryCache = NSCache<NSString, UIImage>()

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

    func image(for url: URL) async -> UIImage? {
        let key = cacheKey(for: url)
        let nsKey = key as NSString

        // 1. In-memory hit — no disk I/O needed
        if let memImage = memoryCache.object(forKey: nsKey) {
            return memImage
        }

        // 2. Disk hit — the URL is the change detector: same URL = same image.
        //    If a provider changes a logo, the URL changes → cache miss → fresh fetch.
        let fileURL = cacheDir.appendingPathComponent("\(key).dat")
        if manifest.contains(key), let cachedImage = loadFromDisk(fileURL) {
            memoryCache.setObject(cachedImage, forKey: nsKey)
            logger.log("HIT \(url.lastPathComponent)", category: .imageCache)
            return cachedImage
        }

        // 3. Cache miss — fetch and store
        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            guard let img = UIImage(data: data) else {
                logger.log("MISS (invalid data) \(url.lastPathComponent)", category: .imageCache)
                return nil
            }

            logger.log("MISS (fetched) \(url.lastPathComponent)", category: .imageCache)
            memoryCache.setObject(img, forKey: nsKey)
            saveToDisk(data: data, fileURL: fileURL, key: key)
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
