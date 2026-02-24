import Foundation

final class EPGParser: NSObject, XMLParserDelegate {
    private var entries: [String: [EPGEntry]] = [:]
    private var currentElement = ""
    private var currentChannelID = ""
    private var currentTitle = ""
    private var currentDescription = ""
    private var currentStart: Date?
    private var currentEnd: Date?
    private var isParsing = false

    private static let xmltvDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func parse(from url: URL) async throws -> [String: [EPGEntry]] {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (downloaded, _) = try await URLSession.shared.data(from: url)
            data = downloaded
        }

        let parser = EPGParser()
        return parser.parse(data: data)
    }

    func parse(data: Data) -> [String: [EPGEntry]] {
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = self
        xmlParser.parse()
        return entries
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName

        if elementName == "programme" {
            currentChannelID = attributeDict["channel"] ?? ""
            currentTitle = ""
            currentDescription = ""
            currentStart = attributeDict["start"].flatMap { Self.xmltvDateFormatter.date(from: $0) }
            currentEnd = attributeDict["stop"].flatMap { Self.xmltvDateFormatter.date(from: $0) }
            isParsing = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isParsing else { return }
        switch currentElement {
        case "title":
            currentTitle += string
        case "desc":
            currentDescription += string
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "programme", isParsing {
            if let start = currentStart, let end = currentEnd {
                let entry = EPGEntry(
                    channelID: currentChannelID,
                    title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: currentDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : currentDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                    start: start,
                    end: end
                )
                entries[currentChannelID, default: []].append(entry)
            }
            isParsing = false
        }
    }
}
