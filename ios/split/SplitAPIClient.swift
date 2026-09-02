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

struct ServerActor: Decodable, Hashable {
    let id: ActorID
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case actor_uuid
        case display_name
        case name
    }

    init(id: ActorID, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))
        self.displayName = try container.decodeIfPresent(String.self, forKey: .display_name)
            ?? container.decodeIfPresent(String.self, forKey: .name)
    }
}

struct ServerGroup: Decodable {
    let id: GroupID
    let name: String
    let createdAt: Date
    let joinCode: String
    let actorID: ActorID
    let latestEventSequence: Int64
    let actors: [ServerActor]

    private enum CodingKeys: String, CodingKey {
        case uuid
        case name
        case creation_date
        case join_code
        case actor_uuid
        case latest_event_sequence
        case actors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let actorID = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))

        self.id = GroupID(rawValue: try container.decode(String.self, forKey: .uuid))
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decode(Date.self, forKey: .creation_date)
        self.joinCode = try container.decode(String.self, forKey: .join_code)
        self.actorID = actorID
        self.latestEventSequence = try container.decodeIfPresent(Int64.self, forKey: .latest_event_sequence) ?? 0
        self.actors = try container.decodeIfPresent([ServerActor].self, forKey: .actors)
            ?? [ServerActor(id: actorID, displayName: nil)]
    }

    var actorIDs: [ActorID] {
        var ids = actors.map(\.id)
        if !ids.contains(actorID) {
            ids.insert(actorID, at: 0)
        }
        return ids
    }
}

struct GroupBalancesResponse: Decodable, Hashable {
    let groupID: GroupID
    let currentActorID: ActorID
    let asOfSequence: Int64
    let currencyBalances: [CurrencyBalance]

    private enum CodingKeys: String, CodingKey {
        case group_uuid
        case current_actor_uuid
        case as_of_sequence
        case currency_balances
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groupID = GroupID(rawValue: try container.decode(String.self, forKey: .group_uuid))
        self.currentActorID = ActorID(rawValue: try container.decode(String.self, forKey: .current_actor_uuid))
        self.asOfSequence = try container.decode(Int64.self, forKey: .as_of_sequence)
        self.currencyBalances = try container.decode([CurrencyBalance].self, forKey: .currency_balances)
    }
}

struct CurrencyBalance: Decodable, Hashable, Identifiable {
    var id: String { currencyCode }
    let currencyCode: String
    let memberBalances: [BalanceMember]
    let suggestedTransfers: [SuggestedTransfer]

    private enum CodingKeys: String, CodingKey {
        case currency_code
        case member_balances
        case suggested_transfers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.currencyCode = try container.decode(String.self, forKey: .currency_code)
        self.memberBalances = try container.decode([BalanceMember].self, forKey: .member_balances)
        self.suggestedTransfers = try container.decode([SuggestedTransfer].self, forKey: .suggested_transfers)
    }
}

struct BalanceMember: Decodable, Hashable, Identifiable {
    var id: ActorID { actorID }
    let actorID: ActorID
    let displayName: String
    let netMinorUnits: Int64

    private enum CodingKeys: String, CodingKey {
        case actor_uuid
        case display_name
        case net_minor_units
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.actorID = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))
        self.displayName = try container.decodeIfPresent(String.self, forKey: .display_name) ?? ""
        self.netMinorUnits = try container.decode(Int64.self, forKey: .net_minor_units)
    }
}

struct SuggestedTransfer: Decodable, Hashable, Identifiable {
    var id: String { "\(fromActorID.rawValue)-\(toActorID.rawValue)" }
    let fromActorID: ActorID
    let toActorID: ActorID
    let amountMinorUnits: Int64

    private enum CodingKeys: String, CodingKey {
        case from_actor_uuid
        case to_actor_uuid
        case amount_minor_units
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fromActorID = ActorID(rawValue: try container.decode(String.self, forKey: .from_actor_uuid))
        self.toActorID = ActorID(rawValue: try container.decode(String.self, forKey: .to_actor_uuid))
        self.amountMinorUnits = try container.decode(Int64.self, forKey: .amount_minor_units)
    }
}

enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum SplitMethod: String, Codable, Hashable {
    case equal
    case manual
}

struct ExpenseSplit: Codable, Hashable, Identifiable {
    var id: ActorID { actorID }
    let actorID: ActorID
    let amountMinorUnits: Int64?

    private enum CodingKeys: String, CodingKey {
        case actor_uuid
        case amount_minor_units
    }

    init(actorID: ActorID, amountMinorUnits: Int64? = nil) {
        self.actorID = actorID
        self.amountMinorUnits = amountMinorUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.actorID = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))
        self.amountMinorUnits = try container.decodeIfPresent(Int64.self, forKey: .amount_minor_units)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actorID.rawValue, forKey: .actor_uuid)
        try container.encodeIfPresent(amountMinorUnits, forKey: .amount_minor_units)
    }
}

struct ExpensePayload: Codable, Hashable {
    var name: String
    var description: String
    var currencyCode: String
    var totalMinorUnits: Int64
    var payerActorID: ActorID
    var splitMethod: SplitMethod
    var splitConfig: [String: JSONValue]
    var occurredAt: Date
    var splits: [ExpenseSplit]

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case currency_code
        case total_minor_units
        case payer_actor_uuid
        case split_method
        case split_config
        case occurred_at
        case splits
    }

    init(
        name: String,
        description: String,
        currencyCode: String,
        totalMinorUnits: Int64,
        payerActorID: ActorID,
        splitMethod: SplitMethod,
        splitConfig: [String: JSONValue] = [:],
        occurredAt: Date,
        splits: [ExpenseSplit]
    ) {
        self.name = name
        self.description = description
        self.currencyCode = currencyCode
        self.totalMinorUnits = totalMinorUnits
        self.payerActorID = payerActorID
        self.splitMethod = splitMethod
        self.splitConfig = splitConfig
        self.occurredAt = occurredAt
        self.splits = splits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.currencyCode = try container.decode(String.self, forKey: .currency_code)
        self.totalMinorUnits = try container.decode(Int64.self, forKey: .total_minor_units)
        self.payerActorID = ActorID(rawValue: try container.decode(String.self, forKey: .payer_actor_uuid))
        self.splitMethod = try container.decode(SplitMethod.self, forKey: .split_method)
        self.splitConfig = try container.decodeIfPresent([String: JSONValue].self, forKey: .split_config) ?? [:]
        self.occurredAt = try container.decode(Date.self, forKey: .occurred_at)
        self.splits = try container.decode([ExpenseSplit].self, forKey: .splits)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(currencyCode, forKey: .currency_code)
        try container.encode(totalMinorUnits, forKey: .total_minor_units)
        try container.encode(payerActorID.rawValue, forKey: .payer_actor_uuid)
        try container.encode(splitMethod, forKey: .split_method)
        try container.encode(splitConfig, forKey: .split_config)
        try container.encode(occurredAt, forKey: .occurred_at)
        try container.encode(splits, forKey: .splits)
    }
}

struct ServerExpense: Decodable, Identifiable, Hashable {
    let id: ExpenseID
    let groupID: GroupID
    let createdByActorID: ActorID
    let payload: ExpensePayload
    let createdAt: Date
    let updatedAt: Date
    let version: Int64
    let voidedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case uuid
        case group_uuid
        case created_by_actor_uuid
        case payer_actor_uuid
        case name
        case description
        case currency_code
        case total_minor_units
        case split_method
        case split_config
        case occurred_at
        case created_at
        case updated_at
        case version
        case voided_at
        case splits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = ExpenseID(rawValue: try container.decode(String.self, forKey: .uuid))
        self.groupID = GroupID(rawValue: try container.decode(String.self, forKey: .group_uuid))
        self.createdByActorID = ActorID(rawValue: try container.decode(String.self, forKey: .created_by_actor_uuid))
        self.createdAt = try container.decode(Date.self, forKey: .created_at)
        self.updatedAt = try container.decode(Date.self, forKey: .updated_at)
        self.version = try container.decode(Int64.self, forKey: .version)
        self.voidedAt = try container.decodeIfPresent(Date.self, forKey: .voided_at)
        self.payload = ExpensePayload(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            currencyCode: try container.decode(String.self, forKey: .currency_code),
            totalMinorUnits: try container.decode(Int64.self, forKey: .total_minor_units),
            payerActorID: ActorID(rawValue: try container.decode(String.self, forKey: .payer_actor_uuid)),
            splitMethod: try container.decode(SplitMethod.self, forKey: .split_method),
            splitConfig: try container.decodeIfPresent([String: JSONValue].self, forKey: .split_config) ?? [:],
            occurredAt: try container.decode(Date.self, forKey: .occurred_at),
            splits: try container.decode([ExpenseSplit].self, forKey: .splits)
        )
    }
}

struct ExpensesResponse: Decodable {
    let expenses: [ServerExpense]

    private enum CodingKeys: String, CodingKey {
        case expenses
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            self.expenses = try container.decode([ServerExpense].self, forKey: .expenses)
        } else {
            let container = try decoder.singleValueContainer()
            self.expenses = try container.decode([ServerExpense].self)
        }
    }
}

struct ExpenseEventRequest: Codable, Hashable, Identifiable {
    var id: EventID { eventID }
    let eventID: EventID
    let entityType: String
    let entityID: ExpenseID
    let eventType: ExpenseEventType
    let actorID: ActorID
    let eventCreatedAt: Date
    let clientSequence: Int64
    let baseSequence: Int64
    let payloadVersion: Int
    let payload: ExpensePayload

    private enum CodingKeys: String, CodingKey {
        case event_uuid
        case entity_type
        case entity_uuid
        case event_type
        case actor_uuid
        case event_created_at
        case client_sequence
        case base_sequence
        case payload_version
        case payload
    }

    init(
        eventID: EventID,
        entityType: String = "expense",
        entityID: ExpenseID,
        eventType: ExpenseEventType,
        actorID: ActorID,
        eventCreatedAt: Date,
        clientSequence: Int64,
        baseSequence: Int64,
        payloadVersion: Int = 1,
        payload: ExpensePayload
    ) {
        self.eventID = eventID
        self.entityType = entityType
        self.entityID = entityID
        self.eventType = eventType
        self.actorID = actorID
        self.eventCreatedAt = eventCreatedAt
        self.clientSequence = clientSequence
        self.baseSequence = baseSequence
        self.payloadVersion = payloadVersion
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eventID = EventID(rawValue: try container.decode(String.self, forKey: .event_uuid))
        self.entityType = try container.decode(String.self, forKey: .entity_type)
        self.entityID = ExpenseID(rawValue: try container.decode(String.self, forKey: .entity_uuid))
        self.eventType = try container.decode(ExpenseEventType.self, forKey: .event_type)
        self.actorID = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))
        self.eventCreatedAt = try container.decode(Date.self, forKey: .event_created_at)
        self.clientSequence = try container.decode(Int64.self, forKey: .client_sequence)
        self.baseSequence = try container.decode(Int64.self, forKey: .base_sequence)
        self.payloadVersion = try container.decode(Int.self, forKey: .payload_version)
        self.payload = try container.decode(ExpensePayload.self, forKey: .payload)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID.rawValue, forKey: .event_uuid)
        try container.encode(entityType, forKey: .entity_type)
        try container.encode(entityID.rawValue, forKey: .entity_uuid)
        try container.encode(eventType, forKey: .event_type)
        try container.encode(actorID.rawValue, forKey: .actor_uuid)
        try container.encode(eventCreatedAt, forKey: .event_created_at)
        try container.encode(clientSequence, forKey: .client_sequence)
        try container.encode(baseSequence, forKey: .base_sequence)
        try container.encode(payloadVersion, forKey: .payload_version)
        try container.encode(payload, forKey: .payload)
    }
}

enum ExpenseEventType: String, Codable, Hashable {
    case created = "expense.created"
    case updated = "expense.updated"
    case voided = "expense.voided"
}

struct PostEventResponse: Decodable {
    let sequence: Int64?
    let applied: Bool?
    let replayed: Bool?
    let conflict: Bool?
    let expense: ServerExpense?
}

struct PulledExpenseEvent: Decodable, Identifiable, Hashable {
    var id: EventID { eventID }
    let eventID: EventID
    let sequence: Int64

    private enum CodingKeys: String, CodingKey {
        case event_uuid
        case sequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eventID = EventID(rawValue: try container.decode(String.self, forKey: .event_uuid))
        self.sequence = try container.decode(Int64.self, forKey: .sequence)
    }
}

struct GroupEventsResponse: Decodable {
    let events: [PulledExpenseEvent]
    let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case events
        case has_more
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events = try container.decode([PulledExpenseEvent].self, forKey: .events)
        self.hasMore = try container.decode(Bool.self, forKey: .has_more)
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

    func fetchExpenses(groupID: GroupID) async throws -> [ServerExpense] {
        let request = try authorizedRequest(path: "/groups/\(groupID.rawValue)/expenses")
        let response: ExpensesResponse = try await send(request)
        return response.expenses
    }

    func fetchBalances(groupID: GroupID) async throws -> GroupBalancesResponse {
        let request = try authorizedRequest(path: "/groups/\(groupID.rawValue)/balances")
        return try await send(request)
    }

    func postExpenseEvent(groupID: GroupID, event: ExpenseEventRequest) async throws -> PostEventResponse {
        var request = try authorizedRequest(path: "/groups/\(groupID.rawValue)/events", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(event)
        return try await send(request)
    }

    func fetchGroupEvents(groupID: GroupID, after cursor: Int64, limit: Int = 100) async throws -> GroupEventsResponse {
        var components = URLComponents(url: url(for: "/groups/\(groupID.rawValue)/events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "after", value: String(cursor)),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = try authorizedRequest(path: "/groups/\(groupID.rawValue)/events")
        request.url = url
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
