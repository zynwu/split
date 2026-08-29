import Foundation

struct RegisterResponse: Decodable {
    let deviceID: DeviceID
    let token: String

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case deviceId
        case device_id
        case token
        case auth_token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let token = try container.decodeIfPresent(String.self, forKey: .auth_token) {
            self.token = token
        } else {
            self.token = try container.decode(String.self, forKey: .token)
        }

        if let deviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceID) {
            self.deviceID = deviceID
        } else if let deviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceId) {
            self.deviceID = deviceID
        } else {
            self.deviceID = try container.decode(DeviceID.self, forKey: .device_id)
        }
    }
}

struct DeviceResponse: Decodable {
    let deviceID: DeviceID

    private enum CodingKeys: String, CodingKey {
        case device_id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = DeviceID(rawValue: try container.decode(String.self, forKey: .device_id))
    }
}

struct GroupsResponse: Decodable {
    let groups: [ServerGroup]
}

struct CreateGroupRequest: Encodable {
    let name: String
}

struct JoinGroupRequest: Encodable {
    let join_code: String
}

struct ServerGroup: Decodable {
    let id: GroupID
    let name: String
    let createdAt: Date
    let joinCode: String
    let actorID: ActorID

    private enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case creation_date
        case join_code
        case actor_uuid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = GroupID(rawValue: try container.decode(String.self, forKey: .uuid))
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .creation_date)
        self.joinCode = try container.decode(String.self, forKey: .join_code)
        self.actorID = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))
    }
}

struct SplitAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: () throws -> String?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: URL = APIConfiguration.baseURL,
        session: URLSession = .shared,
        tokenProvider: @escaping () throws -> String?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func register() async throws -> RegisterResponse {
        var request = URLRequest(url: url(for: "/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await send(request)
    }

    func fetchDevice() async throws -> DeviceID {
        let request = try authorizedRequest(path: "/device")
        let response: DeviceResponse = try await send(request)
        return response.deviceID
    }

    func fetchGroups() async throws -> [ServerGroup] {
        let request = try authorizedRequest(path: "/groups")
        let response: GroupsResponse = try await send(request)
        return response.groups
    }

    func createGroup(named name: String) async throws -> ServerGroup {
        var request = try authorizedRequest(path: "/groups", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(CreateGroupRequest(name: name))
        return try await send(request)
    }

    func joinGroup(with joinCode: String) async throws -> ServerGroup {
        var request = try authorizedRequest(path: "/groups/join", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(JoinGroupRequest(join_code: joinCode))
        return try await send(request)
    }

    func authorizedRequest(path: String, method: String = "GET") throws -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let token = try tokenProvider() else {
            throw APIClientError.missingAuthToken
        }

        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func url(for path: String) -> URL {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return baseURL.appending(path: cleanPath)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw APIError(statusCode: httpResponse.statusCode, responseBody: String(data: data, encoding: .utf8))
        }
    }
}

enum APIClientError: Error, LocalizedError {
    case missingAuthToken

    var errorDescription: String? {
        switch self {
        case .missingAuthToken:
            "Missing auth token. Register the device before making authenticated API calls."
        }
    }
}

struct APIError: Error, LocalizedError {
    let statusCode: Int
    let responseBody: String?

    var errorDescription: String? {
        if let responseBody, !responseBody.isEmpty {
            return "API request failed with status \(statusCode): \(responseBody)"
        }

        return "API request failed with status \(statusCode)"
    }
}
