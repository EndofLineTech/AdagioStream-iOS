import Foundation

struct XtreamCodesAPI {
    let host: URL
    let username: String
    let password: String

    enum APIError: Error, LocalizedError {
        case invalidURL
        case authenticationFailed
        case networkError(Error)
        case decodingError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL"
            case .authenticationFailed: return "Authentication failed"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            case .decodingError(let e): return "Data error: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - API Responses

    struct AuthResponse: Codable {
        let userInfo: UserInfo?
        let serverInfo: ServerInfo?

        enum CodingKeys: String, CodingKey {
            case userInfo = "user_info"
            case serverInfo = "server_info"
        }

        struct UserInfo: Codable {
            let username: String?
            let status: String?
            let auth: Int?
        }

        struct ServerInfo: Codable {
            let url: String?
            let port: String?
        }
    }

    struct Category: Codable, Identifiable {
        let categoryID: String
        let categoryName: String

        var id: String { categoryID }

        enum CodingKeys: String, CodingKey {
            case categoryID = "category_id"
            case categoryName = "category_name"
        }
    }

    struct LiveStream: Codable {
        let streamID: Int
        let name: String?
        let streamIcon: String?
        let epgChannelID: String?
        let categoryID: String?

        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case name
            case streamIcon = "stream_icon"
            case epgChannelID = "epg_channel_id"
            case categoryID = "category_id"
        }
    }

    struct EPGListing: Codable {
        let title: String?
        let description: String?
        let start: String?
        let end: String?

        enum CodingKeys: String, CodingKey {
            case title
            case description
            case start
            case end
        }
    }

    struct ShortEPGResponse: Codable {
        let epgListings: [EPGListing]?

        enum CodingKeys: String, CodingKey {
            case epgListings = "epg_listings"
        }
    }

    // MARK: - API Calls

    func authenticate() async throws -> AuthResponse {
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "") else {
            throw APIError.invalidURL
        }
        let response: AuthResponse = try await fetch(url)
        guard response.userInfo?.auth == 1 || response.userInfo?.status == "Active" else {
            throw APIError.authenticationFailed
        }
        return response
    }

    func getLiveCategories() async throws -> [Category] {
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "get_live_categories") else {
            throw APIError.invalidURL
        }
        return try await fetch(url)
    }

    func getLiveStreams(categoryID: String? = nil) async throws -> [LiveStream] {
        var params: [String: String] = [:]
        if let categoryID {
            params["category_id"] = categoryID
        }
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "get_live_streams", params: params) else {
            throw APIError.invalidURL
        }
        return try await fetch(url)
    }

    func getShortEPG(streamID: Int) async throws -> [EPGListing] {
        guard let url = host.xtreamCodesURL(username: username, password: password, action: "get_short_epg", params: ["stream_id": String(streamID)]) else {
            throw APIError.invalidURL
        }
        let response: ShortEPGResponse = try await fetch(url)
        return response.epgListings ?? []
    }

    func streamURL(for streamID: Int, extension ext: String = Constants.XtreamCodes.defaultStreamExtension) -> URL? {
        var components = URLComponents(url: host, resolvingAgainstBaseURL: false)
        components?.path = "\(Constants.XtreamCodes.livePath)/\(username)/\(password)/\(streamID).\(ext)"
        return components?.url
    }

    // MARK: - Conversion

    func convertToChannels(streams: [LiveStream], categories: [Category]) -> [Channel] {
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

    private func fetch<T: Codable>(_ url: URL) async throws -> T {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        } catch {
            throw APIError.networkError(error)
        }
    }
}
