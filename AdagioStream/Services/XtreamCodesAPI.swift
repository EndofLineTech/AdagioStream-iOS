import Foundation

public struct XtreamCodesAPI {
    public let host: URL
    public let username: String
    public let password: String

    public init(host: URL, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }

    public enum APIError: Error, LocalizedError {
        case invalidURL
        case authenticationFailed
        case networkError(Error)
        case decodingError(Error)
        case serverError(statusCode: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL"
            case .authenticationFailed: return "Authentication failed"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .decodingError(let e): return "Data error: \(e.localizedDescription)"
            case .serverError(let code): return "Server error (HTTP \(code))"
            }
        }
    }

    // MARK: - API Responses

    public struct AuthResponse: Codable {
        let userInfo: UserInfo?
        let serverInfo: ServerInfo?

        enum CodingKeys: String, CodingKey {
            case userInfo = "user_info"
            case serverInfo = "server_info"
        }

        public struct UserInfo: Codable {
            let username: String?
            let status: String?
            let auth: Int?
            let allowedOutputFormats: [String]?

            enum CodingKeys: String, CodingKey {
                case username, status, auth
                case allowedOutputFormats = "allowed_output_formats"
            }
        }

        public struct ServerInfo: Codable {
            let url: String?
            let port: String?
        }
    }

    public struct Category: Codable, Identifiable {
        public let categoryID: String
        public let categoryName: String

        public var id: String { categoryID }

        public init(categoryID: String, categoryName: String) {
            self.categoryID = categoryID
            self.categoryName = categoryName
        }

        enum CodingKeys: String, CodingKey {
            case categoryID = "category_id"
            case categoryName = "category_name"
        }
    }

    public struct LiveStream: Codable {
        public let streamID: Int
        public let name: String?
        public let streamIcon: String?
        public let epgChannelID: String?
        public let categoryID: String?

        public init(
            streamID: Int,
            name: String?,
            streamIcon: String?,
            epgChannelID: String?,
            categoryID: String?
        ) {
            self.streamID = streamID
            self.name = name
            self.streamIcon = streamIcon
            self.epgChannelID = epgChannelID
            self.categoryID = categoryID
        }

        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case name
            case streamIcon = "stream_icon"
            case epgChannelID = "epg_channel_id"
            case categoryID = "category_id"
        }
    }

    // MARK: - API Calls

    public func authenticate() async throws -> AuthResponse {
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "") else {
            throw APIError.invalidURL
        }
        let response: AuthResponse = try await fetch(url)
        guard response.userInfo?.auth == 1 || response.userInfo?.status == "Active" else {
            throw APIError.authenticationFailed
        }
        return response
    }

    public func getLiveCategories() async throws -> [Category] {
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "get_live_categories") else {
            throw APIError.invalidURL
        }
        return try await fetch(url)
    }

    public func getLiveStreams(categoryID: String? = nil) async throws -> [LiveStream] {
        var params: [String: String] = [:]
        if let categoryID {
            params["category_id"] = categoryID
        }
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "get_live_streams", params: params) else {
            throw APIError.invalidURL
        }
        return try await fetch(url)
    }

    /// Full XMLTV EPG URL exposed by most Xtream Codes panels.
    public var xmltvURL: URL? {
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
        components?.path = "/xmltv.php"
        components?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        return components?.url
    }

    public var streamExtension: String = Constants.XtreamCodes.defaultStreamExtension

    public mutating func applyAuthFormats(_ response: AuthResponse) {
        if let formats = response.userInfo?.allowedOutputFormats, let first = formats.first {
            streamExtension = first
        }
    }

    public func streamURL(for streamID: Int, extension ext: String? = nil) -> URL? {
        let ext = ext ?? streamExtension
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
        components?.path = "\(Constants.XtreamCodes.livePath)/\(username)/\(password)/\(streamID).\(ext)"
        return components?.url
    }

    // MARK: - Conversion

    public func convertToChannels(streams: [LiveStream], categories: [Category]) -> [Channel] {
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.categoryID, $0.categoryName) })

        return streams.compactMap { stream in
            guard let url = streamURL(for: stream.streamID) else { return nil }
            return Channel(
                id: String(stream.streamID),
                name: stream.name ?? "Unknown",
                streamURL: url,
                logoURL: stream.streamIcon.flatMap { URL(string: $0) },
                group: stream.categoryID.flatMap { categoryMap[$0] } ?? "Uncategorized",
                epgChannelID: stream.epgChannelID
            )
        }
    }

    // MARK: - Private

    private func fetch<T: Codable>(_ url: URL, attempt: Int = 1) async throws -> T {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                // Retry once on server errors (5xx)
                if attempt == 1, (500...599).contains(httpResponse.statusCode) {
                    try? await Task.sleep(for: .seconds(2))
                    return try await fetch(url, attempt: 2)
                }
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch let error as APIError {
            throw error
        } catch let error as DecodingError {
            // Retry once on decoding errors (server may have returned transient garbage)
            if attempt == 1 {
                try? await Task.sleep(for: .seconds(2))
                return try await fetch(url, attempt: 2)
            }
            throw APIError.decodingError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }
}
