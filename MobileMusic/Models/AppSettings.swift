import Foundation

struct AppSettings: Codable {
    var bufferDuration: TimeInterval

    init(bufferDuration: TimeInterval = Constants.defaultBufferDuration) {
        self.bufferDuration = bufferDuration
    }

    static let `default` = AppSettings()
}
