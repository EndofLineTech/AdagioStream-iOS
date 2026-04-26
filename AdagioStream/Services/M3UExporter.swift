import AdagioStreamCore
import Foundation

struct M3UExporter {
    static func export(_ playlist: CustomPlaylist) -> String {
        var lines = ["#EXTM3U"]

        for group in playlist.groups {
            for entry in group.entries {
                var extinf = "#EXTINF:-1"
                if let logoURL = entry.logoURL {
                    extinf += " tvg-logo=\"\(logoURL.absoluteString)\""
                }
                extinf += " group-title=\"\(group.name)\",\(entry.name)"
                lines.append(extinf)
                lines.append(entry.streamURL.absoluteString)
            }
        }

        return lines.joined(separator: "\n")
    }

    static func exportToFile(_ playlist: CustomPlaylist) throws -> URL {
        let content = export(playlist)
        let sanitized = playlist.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(sanitized).m3u"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
