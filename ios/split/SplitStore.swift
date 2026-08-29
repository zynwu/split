import Foundation
import Observation

struct DeviceID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }
}

struct ActorID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static func generate() -> ActorID {
        ActorID(rawValue: UUID().uuidString)
    }
}

struct GroupID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static func generate() -> GroupID {
        GroupID(rawValue: UUID().uuidString)
    }
}

struct Actor: Codable, Hashable, Identifiable {
    let id: ActorID
    var displayName: String
    var deviceID: DeviceID?
    let isLocal: Bool
}

struct ExpenseGroup: Codable, Hashable, Identifiable {
    let id: GroupID
    var name: String
    var joinCode: String
    var localActorID: ActorID
    var actorIDs: [ActorID]
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case joinCode
        case localActorID
        case actorIDs
        case createdAt
    }

    init(id: GroupID, name: String, joinCode: String, localActorID: ActorID, actorIDs: [ActorID], createdAt: Date) {
        self.id = id
        self.name = name
        self.joinCode = joinCode
        self.localActorID = localActorID
        self.actorIDs = actorIDs
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(GroupID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.joinCode = try container.decode(String.self, forKey: .joinCode)
        self.actorIDs = try container.decode([ActorID].self, forKey: .actorIDs)
        self.localActorID = try container.decodeIfPresent(ActorID.self, forKey: .localActorID) ?? actorIDs.first ?? .generate()
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct DeviceActorLink: Codable, Hashable {
    let deviceID: DeviceID
    let groupID: GroupID
    let actorID: ActorID
}

struct SplitSnapshot: Codable {
    var deviceID: DeviceID?
    var displayName: String
    var actors: [Actor]
    var groups: [ExpenseGroup]

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case localActorID
        case displayName
        case actors
        case groups
    }

    init(deviceID: DeviceID?, displayName: String, actors: [Actor], groups: [ExpenseGroup]) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.actors = actors
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceID)
        self.actors = try container.decode([Actor].self, forKey: .actors)
        self.groups = try container.decode([ExpenseGroup].self, forKey: .groups)

        if let displayName = try container.decodeIfPresent(String.self, forKey: .displayName) {
            self.displayName = displayName
        } else if let localActor = actors.first(where: { $0.isLocal }) {
            self.displayName = localActor.displayName
        } else {
            self.displayName = "Me"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(actors, forKey: .actors)
        try container.encode(groups, forKey: .groups)
    }
}

enum RegistrationStatus: Equatable {
    case notStarted
    case registering
    case registered
    case failed(String)

    var label: String {
        switch self {
        case .notStarted:
            "Not started"
        case .registering:
            "Registering"
        case .registered:
            "Registered"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
}

@MainActor
@Observable
final class SplitStore {
    private(set) var deviceID: DeviceID?
    private(set) var displayName: String
    private(set) var actors: [Actor]
    private(set) var groups: [ExpenseGroup]
    private(set) var registrationStatus: RegistrationStatus = .notStarted

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let authTokenStore: AuthTokenStoring
    @ObservationIgnored private let apiClient: SplitAPIClient
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder

    init(
        storageURL: URL = SplitStore.defaultStorageURL,
        authTokenStore: AuthTokenStoring? = nil,
        apiClient: SplitAPIClient? = nil
    ) {
        let authTokenStore = authTokenStore ?? KeychainAuthTokenStore()
        self.storageURL = storageURL
        self.authTokenStore = authTokenStore
        self.apiClient = apiClient ?? SplitAPIClient(tokenProvider: authTokenStore.loadToken)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        if let snapshot = Self.loadSnapshot(from: storageURL, decoder: decoder) {
            self.deviceID = snapshot.deviceID
            self.displayName = snapshot.displayName
            self.actors = snapshot.actors
            self.groups = snapshot.groups
            ensureLocalActorsExist()
        } else {
            self.deviceID = nil
            self.displayName = "Me"
            self.actors = []
            self.groups = []
            persist()
        }
    }

    func prepareForLaunch() async {
        do {
            if try authTokenStore.loadToken() != nil {
                registrationStatus = .registered
                refreshGroupsInBackground()
                return
            }

            try await registerDevice()
            refreshGroupsInBackground()
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    private func registerDevice() async throws {
        registrationStatus = .registering
        let response = try await apiClient.register()
        try authTokenStore.saveToken(response.token)
        applyRegisteredDeviceID(response.deviceID)
        registrationStatus = .registered
    }

    func setLocalDisplayName(_ displayName: String) {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        self.displayName = cleanName
        for index in actors.indices where actors[index].isLocal {
            actors[index].displayName = cleanName
        }
        persist()
    }

    func createGroup(named name: String) async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }

        do {
            let serverGroup = try await apiClient.createGroup(named: cleanName)
            applyServerGroup(serverGroup)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func removeGroup(id: GroupID) {
        groups.removeAll { $0.id == id }
        pruneUnusedActors()
        persist()
    }

    func actor(for actorID: ActorID) -> Actor? {
        actors.first { $0.id == actorID }
    }

    func deviceActorLink(for groupID: GroupID) -> DeviceActorLink? {
        guard let deviceID, let group = groups.first(where: { $0.id == groupID }) else { return nil }
        return DeviceActorLink(deviceID: deviceID, groupID: group.id, actorID: group.localActorID)
    }

    private func refreshGroupsInBackground() {
        Task {
            do {
                let serverGroups = try await apiClient.fetchGroups()
                applyServerGroups(serverGroups)
            } catch {
                // Keep showing local groups when a background refresh fails.
            }
        }
    }

    private func applyServerGroups(_ serverGroups: [ServerGroup]) {
        let serverActorIDs = Set(serverGroups.map(\.actorID))
        actors.removeAll { $0.isLocal && !serverActorIDs.contains($0.id) }

        for serverGroup in serverGroups {
            upsertLocalActor(id: serverGroup.actorID)
        }

        groups = serverGroups.map(makeExpenseGroup)
        pruneUnusedActors()
        persist()
    }

    private func applyServerGroup(_ serverGroup: ServerGroup) {
        upsertLocalActor(id: serverGroup.actorID)

        let group = makeExpenseGroup(from: serverGroup)
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }

        pruneUnusedActors()
        persist()
    }

    private func makeExpenseGroup(from serverGroup: ServerGroup) -> ExpenseGroup {
        ExpenseGroup(
            id: serverGroup.id,
            name: serverGroup.name,
            joinCode: serverGroup.joinCode,
            localActorID: serverGroup.actorID,
            actorIDs: [serverGroup.actorID],
            createdAt: serverGroup.createdAt
        )
    }

    nonisolated private static var defaultStorageURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appending(path: "split", directoryHint: .isDirectory).appending(path: "local-state.json")
    }

    private static func loadSnapshot(from url: URL, decoder: JSONDecoder) -> SplitSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SplitSnapshot.self, from: data)
    }

    private func applyRegisteredDeviceID(_ deviceID: DeviceID) {
        self.deviceID = deviceID
        for index in actors.indices where actors[index].isLocal {
            actors[index].deviceID = deviceID
        }
        persist()
    }

    private func ensureLocalActorsExist() {
        for group in groups {
            upsertLocalActor(id: group.localActorID)
        }
        pruneUnusedActors()
        persist()
    }

    private func upsertLocalActor(id actorID: ActorID) {
        if let index = actors.firstIndex(where: { $0.id == actorID }) {
            actors[index].displayName = displayName
            actors[index].deviceID = deviceID
        } else {
            actors.append(Actor(id: actorID, displayName: displayName, deviceID: deviceID, isLocal: true))
        }
    }

    private func pruneUnusedActors() {
        let usedActorIDs = Set(groups.flatMap(\.actorIDs))
        actors.removeAll { !usedActorIDs.contains($0.id) }
    }

    private func persist() {
        do {
            let directoryURL = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let snapshot = SplitSnapshot(deviceID: deviceID, displayName: displayName, actors: actors, groups: groups)
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist split state: \(error.localizedDescription)")
        }
    }
}
