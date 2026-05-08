import Foundation

/// JSON-on-disk persistence service for app data. Files live under
/// `<application support>/Adagio Stream/<filename>`. The path is
/// byte-identical to the pre-extraction iOS implementation; renaming the
/// directory orphans existing user data.
public actor PersistenceService {
    public static let shared = PersistenceService()

    private let baseDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDirectory = appSupport.appendingPathComponent(Constants.appName, isDirectory: true)

        // One-time migration from old "MobileMusic" directory.
        let oldDirectory = appSupport.appendingPathComponent("MobileMusic", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDirectory.path),
           !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try? FileManager.default.moveItem(at: oldDirectory, to: baseDirectory)
        }

        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// JSON-encodes `value` and writes it atomically. Throws on encode or
    /// write failure.
    public func save<T: Codable>(_ value: T, to filename: String) throws {
        let url = baseDirectory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// JSON-decodes the file at `filename`. Throws on read or decode failure.
    public func load<T: Codable>(from filename: String) throws -> T {
        let url = baseDirectory.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Loads `filename` returning `defaultValue` on any error (file missing,
    /// decode failure, etc.). Convenient for first-launch defaults.
    public func loadOrDefault<T: Codable>(from filename: String, default defaultValue: T) -> T {
        (try? load(from: filename) as T) ?? defaultValue
    }

    /// Removes the file at `filename`. Idempotent — missing file is a no-op.
    public func delete(_ filename: String) {
        let url = baseDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// True if a file exists at `filename` inside the base directory.
    public func fileExists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent(filename).path)
    }

    /// Returns the absolute path of the base directory. Public so tests
    /// can verify path stability across launches.
    public func baseDirectoryURL() -> URL {
        baseDirectory
    }
}
