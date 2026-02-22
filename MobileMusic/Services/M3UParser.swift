import Foundation

struct M3UParser {
    enum ParseError: Error, LocalizedError {
        case invalidFormat
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidFormat: return "Invalid M3U format"
            case .networkError(let error): return "Network error: \(error.localizedDescription)"
            }
        }
    }

    static func parse(from url: URL) async throws -> [Channel] {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (downloaded, _) = try await URLSession.shared.data(from: url)
            data = downloaded
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw ParseError.invalidFormat
        }

        return parse(content: content)
    }

    static func parse(content: String) -> [Channel] {
        let lines = content.components(separatedBy: .newlines)
        var channels: [Channel] = []

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                let info = line

                // Find the next non-empty, non-comment line for the URL
                i += 1
                while i < lines.count {
                    let urlLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if !urlLine.isEmpty && !urlLine.hasPrefix("#") {
                        if let streamURL = URL(string: urlLine) {
                            let channel = parseChannel(from: info, streamURL: streamURL)
                            channels.append(channel)
                        }
                        break
                    }
                    i += 1
                }
            }
            i += 1
        }

        return channels
    }

    private static func parseChannel(from extinf: String, streamURL: URL) -> Channel {
        let tvgID = extinf.extractAttribute("tvg-id")
        let tvgName = extinf.extractAttribute("tvg-name")
        let tvgLogo = extinf.extractAttribute("tvg-logo")
        let groupTitle = extinf.extractAttribute("group-title")

        // Channel name is after the last comma in the EXTINF line
        let displayName: String
        if let commaRange = extinf.range(of: ",", options: .backwards) {
            displayName = String(extinf[commaRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            displayName = tvgName ?? "Unknown Channel"
        }

        let logoURL: URL? = tvgLogo.flatMap { URL(string: $0) }

        return Channel(
            id: tvgID ?? UUID().uuidString,
            name: displayName,
            streamURL: streamURL,
            logoURL: logoURL,
            group: groupTitle ?? "Uncategorized",
            epgChannelID: tvgID
        )
    }
}
