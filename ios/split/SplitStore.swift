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
    var actorIDs: [ActorID]
    let createdAt: Date
}

struct DeviceActorLink: Codable, Hashable {
    let deviceID: DeviceID
    let actorID: ActorID
}

struct SplitSnapshot: Codable {
    var deviceID: DeviceID?
    var localActorID: ActorID
    var actors: [Actor]
    var groups: [ExpenseGroup]

    var deviceActorLink: DeviceActorLink? {
        guard let deviceID else { return nil }
        return DeviceActorLink(deviceID: deviceID, actorID: localActorID)
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
    private(set) var localActorID: ActorID
    private(set) var actors: [Actor]
    private(set) var groups: [ExpenseGroup]
    private(set) var registrationStatus: RegistrationStatus = .notStarted

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let authTokenStore: AuthTokenStoring
    @ObservationIgnored private let apiClient: SplitAPIClient
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder

    var localActor: Actor {
        actors.first { $0.id == localActorID } ?? Actor(id: localActorID, displayName: "Me", deviceID: deviceID, isLocal: true)
    }

    var deviceActorLink: DeviceActorLink? {
        guard let deviceID else { return nil }
        return DeviceActorLink(deviceID: deviceID, actorID: localActorID)
    }

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
            self.localActorID = snapshot.localActorID
            self.actors = snapshot.actors
            self.groups = snapshot.groups
            ensureLocalActorExists()
        } else {
            let actorID = ActorID.generate()
            self.deviceID = nil
            self.localActorID = actorID
            self.actors = [Actor(id: actorID, displayName: "Me", deviceID: nil, isLocal: true)]
            self.groups = []
            persist()
        }
    }

    func prepareForLaunch() async {
        do {
            if try authTokenStore.loadToken() != nil {
                registrationStatus = deviceID == nil ? .failed("Missing saved device ID") : .registered
                return
            }

            registrationStatus = .registering
            let response = try await apiClient.register()
            try authTokenStore.saveToken(response.token)
            applyRegisteredDeviceID(response.deviceID)
            registrationStatus = .registered
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func setLocalDisplayName(_ displayName: String) {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        updateActor(id: localActorID) { actor in
            actor.displayName = cleanName
        }
    }

    func createGroup(named name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        groups.append(ExpenseGroup(id: .generate(), name: cleanName, actorIDs: [localActorID], createdAt: Date()))
        persist()
    }

    func removeGroup(id: GroupID) {
        groups.removeAll { $0.id == id }
        pruneUnusedNonLocalActors()
        persist()
    }

    func actor(for actorID: ActorID) -> Actor? {
        actors.first { $0.id == actorID }
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
        updateActor(id: localActorID) { actor in
            actor.deviceID = deviceID
        }
    }

    private func ensureLocalActorExists() {
        if actors.contains(where: { $0.id == localActorID }) {
            return
        }

        actors.append(Actor(id: localActorID, displayName: "Me", deviceID: deviceID, isLocal: true))
        persist()
    }

    private func updateActor(id: ActorID, update: (inout Actor) -> Void) {
        guard let index = actors.firstIndex(where: { $0.id == id }) else { return }
        update(&actors[index])
        persist()
    }

    private func pruneUnusedNonLocalActors() {
        let usedActorIDs = Set(groups.flatMap(\.actorIDs))
        actors.removeAll { !$0.isLocal && !usedActorIDs.contains($0.id) }
    }

    private func persist() {
        do {
            let directoryURL = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let snapshot = SplitSnapshot(deviceID: deviceID, localActorID: localActorID, actors: actors, groups: groups)
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist split state: \(error.localizedDescription)")
        }
    }
}
