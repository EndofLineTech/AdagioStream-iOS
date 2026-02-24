import Foundation

actor PersistenceService {
    static let shared = PersistenceService()

    private let baseDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDirectory = appSupport.appendingPathComponent(Constants.appName, isDirectory: true)

        // One-time migration from old "MobileMusic" directory
        let oldDirectory = appSupport.appendingPathComponent("MobileMusic", isDirectory: true)
        if FileManager.default.fileExists(atPath: oldDirectory.path),
           !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try? FileManager.default.moveItem(at: oldDirectory, to: baseDirectory)
        }

        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    func save<T: Codable>(_ value: T, to filename: String) throws {
        let url = baseDirectory.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    func load<T: Codable>(from filename: String) throws -> T {
        let url = baseDirectory.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func loadOrDefault<T: Codable>(from filename: String, default defaultValue: T) -> T {
        (try? load(from: filename) as T) ?? defaultValue
    }

    func fileExists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: baseDirectory.appendingPathComponent(filename).path)
    }
}
