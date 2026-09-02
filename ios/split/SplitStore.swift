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

struct ExpenseID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static func generate() -> ExpenseID {
        ExpenseID(rawValue: UUID().uuidString)
    }
}

struct EventID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static func generate() -> EventID {
        EventID(rawValue: UUID().uuidString)
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
    var syncCursor: Int64
    var serverLatestEventSequence: Int64
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case joinCode
        case localActorID
        case actorIDs
        case syncCursor
        case serverLatestEventSequence
        case createdAt
    }

    init(
        id: GroupID,
        name: String,
        joinCode: String,
        localActorID: ActorID,
        actorIDs: [ActorID],
        syncCursor: Int64,
        serverLatestEventSequence: Int64,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.joinCode = joinCode
        self.localActorID = localActorID
        self.actorIDs = actorIDs
        self.syncCursor = syncCursor
        self.serverLatestEventSequence = serverLatestEventSequence
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(GroupID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.joinCode = try container.decode(String.self, forKey: .joinCode)
        self.actorIDs = try container.decode([ActorID].self, forKey: .actorIDs)
        self.localActorID = try container.decodeIfPresent(ActorID.self, forKey: .localActorID) ?? actorIDs.first ?? .generate()
        self.syncCursor = try container.decodeIfPresent(Int64.self, forKey: .syncCursor) ?? 0
        self.serverLatestEventSequence = try container.decodeIfPresent(Int64.self, forKey: .serverLatestEventSequence) ?? syncCursor
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct DeviceActorLink: Codable, Hashable {
    let deviceID: DeviceID
    let groupID: GroupID
    let actorID: ActorID
}

struct ExpenseRecord: Codable, Hashable, Identifiable {
    let id: ExpenseID
    let groupID: GroupID
    var createdByActorID: ActorID
    var payload: ExpensePayload
    var createdAt: Date
    var updatedAt: Date
    var version: Int64
    var voidedAt: Date?

    init(
        id: ExpenseID,
        groupID: GroupID,
        createdByActorID: ActorID,
        payload: ExpensePayload,
        createdAt: Date,
        updatedAt: Date,
        version: Int64,
        voidedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.createdByActorID = createdByActorID
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.voidedAt = voidedAt
    }

    init(serverExpense: ServerExpense) {
        self.id = serverExpense.id
        self.groupID = serverExpense.groupID
        self.createdByActorID = serverExpense.createdByActorID
        self.payload = serverExpense.payload
        self.createdAt = serverExpense.createdAt
        self.updatedAt = serverExpense.updatedAt
        self.version = serverExpense.version
        self.voidedAt = serverExpense.voidedAt
    }
}

struct PendingExpenseEvent: Codable, Hashable, Identifiable {
    var id: EventID { event.eventID }
    let groupID: GroupID
    let event: ExpenseEventRequest
}

struct SplitSnapshot: Codable {
    var migratedDeviceID: DeviceID?
    var displayName: String
    var actors: [Actor]
    var groups: [ExpenseGroup]
    var expenses: [ExpenseRecord]
    var pendingEvents: [PendingExpenseEvent]
    var nextClientSequence: Int64

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case displayName
        case actors
        case groups
        case expenses
        case pendingEvents
        case nextClientSequence
    }

    init(
        displayName: String,
        actors: [Actor],
        groups: [ExpenseGroup],
        expenses: [ExpenseRecord],
        pendingEvents: [PendingExpenseEvent],
        nextClientSequence: Int64
    ) {
        self.migratedDeviceID = nil
        self.displayName = displayName
        self.actors = actors
        self.groups = groups
        self.expenses = expenses
        self.pendingEvents = pendingEvents
        self.nextClientSequence = nextClientSequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.migratedDeviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceID)
        self.actors = try container.decode([Actor].self, forKey: .actors)
        self.groups = try container.decode([ExpenseGroup].self, forKey: .groups)
        self.expenses = try container.decodeIfPresent([ExpenseRecord].self, forKey: .expenses) ?? []
        self.pendingEvents = try container.decodeIfPresent([PendingExpenseEvent].self, forKey: .pendingEvents) ?? []
        self.nextClientSequence = try container.decodeIfPresent(Int64.self, forKey: .nextClientSequence) ?? 0

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
        try container.encode(displayName, forKey: .displayName)
        try container.encode(actors, forKey: .actors)
        try container.encode(groups, forKey: .groups)
        try container.encode(expenses, forKey: .expenses)
        try container.encode(pendingEvents, forKey: .pendingEvents)
        try container.encode(nextClientSequence, forKey: .nextClientSequence)
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

enum SplitStoreError: Error, LocalizedError {
    case groupNotFound
    case manualSplitsDoNotMatchTotal
    case missingManualSplitAmount

    var errorDescription: String? {
        switch self {
        case .groupNotFound:
            "Group not found."
        case .manualSplitsDoNotMatchTotal:
            "Manual split amounts must sum exactly to the expense total."
        case .missingManualSplitAmount:
            "Manual splits require an amount for every member."
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
    private(set) var expenses: [ExpenseRecord]
    private(set) var pendingEvents: [PendingExpenseEvent]
    private(set) var registrationStatus: RegistrationStatus = .notStarted

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let authTokenStore: AuthTokenStoring
    @ObservationIgnored private let deviceIDStore: DeviceIDStoring
    @ObservationIgnored private let apiClient: SplitAPIClient
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private var nextClientSequence: Int64
    @ObservationIgnored private var syncingGroupIDs: Set<GroupID> = []

    init(
        storageURL: URL = SplitStore.defaultStorageURL,
        authTokenStore: AuthTokenStoring? = nil,
        deviceIDStore: DeviceIDStoring? = nil,
        apiClient: SplitAPIClient? = nil
    ) {
        let authTokenStore = authTokenStore ?? KeychainAuthTokenStore()
        let deviceIDStore = deviceIDStore ?? UserDefaultsDeviceIDStore()
        self.storageURL = storageURL
        self.authTokenStore = authTokenStore
        self.deviceIDStore = deviceIDStore
        self.apiClient = apiClient ?? SplitAPIClient(tokenProvider: authTokenStore.loadToken)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        let savedDeviceID = deviceIDStore.loadDeviceID()

        if let snapshot = Self.loadSnapshot(from: storageURL, decoder: decoder) {
            let deviceID = savedDeviceID ?? snapshot.migratedDeviceID
            self.deviceID = deviceID
            if let deviceID, savedDeviceID == nil {
                deviceIDStore.saveDeviceID(deviceID)
            }
            self.displayName = snapshot.displayName
            self.actors = snapshot.actors
            self.groups = snapshot.groups
            self.expenses = snapshot.expenses
            self.pendingEvents = snapshot.pendingEvents
            self.nextClientSequence = snapshot.nextClientSequence
            ensureLocalActorsExist()
        } else {
            self.deviceID = savedDeviceID
            self.displayName = "Me"
            self.actors = []
            self.groups = []
            self.expenses = []
            self.pendingEvents = []
            self.nextClientSequence = 0
            persist()
        }
    }

    func prepareForLaunch() async {
        do {
            if try authTokenStore.loadToken() != nil {
                registrationStatus = .registered
                refreshDeviceInBackground()
                refreshGroupsInBackground()
                return
            }

            try await registerDevice()
            refreshDeviceInBackground()
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
            await syncGroup(id: serverGroup.id)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func joinGroup(with joinCode: String) async {
        let cleanCode = joinCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanCode.isEmpty else { return }

        do {
            let serverGroup = try await apiClient.joinGroup(with: cleanCode)
            applyServerGroup(serverGroup)
            await syncGroup(id: serverGroup.id)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func removeGroup(id: GroupID) {
        groups.removeAll { $0.id == id }
        expenses.removeAll { $0.groupID == id }
        pendingEvents.removeAll { $0.groupID == id }
        pruneUnusedActors()
        persist()
    }

    func actor(for actorID: ActorID) -> Actor? {
        actors.first { $0.id == actorID }
    }

    func expenses(for groupID: GroupID) -> [ExpenseRecord] {
        expenses
            .filter { $0.groupID == groupID && $0.voidedAt == nil }
            .sorted { $0.payload.occurredAt > $1.payload.occurredAt }
    }

    func deviceActorLink(for groupID: GroupID) -> DeviceActorLink? {
        guard let deviceID, let group = groups.first(where: { $0.id == groupID }) else { return nil }
        return DeviceActorLink(deviceID: deviceID, groupID: group.id, actorID: group.localActorID)
    }

    func createExpense(
        in groupID: GroupID,
        name: String,
        description: String = "",
        currencyCode: String = "USD",
        totalMinorUnits: Int64,
        payerActorID: ActorID? = nil,
        splitMethod: SplitMethod = .equal,
        manualSplits: [ExpenseSplit]? = nil,
        occurredAt: Date = Date()
    ) async {
        do {
            let event = try makeExpenseEvent(
                groupID: groupID,
                expenseID: .generate(),
                eventType: .created,
                baseSequence: 0,
                name: name,
                description: description,
                currencyCode: currencyCode,
                totalMinorUnits: totalMinorUnits,
                payerActorID: payerActorID,
                splitMethod: splitMethod,
                manualSplits: manualSplits,
                occurredAt: occurredAt
            )
            enqueue(event, groupID: groupID)
            applyLocalExpense(event: event, groupID: groupID)
            await syncGroup(id: groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func syncGroup(id groupID: GroupID) async {
        guard !syncingGroupIDs.contains(groupID) else { return }
        syncingGroupIDs.insert(groupID)
        defer { syncingGroupIDs.remove(groupID) }

        do {
            try await postPendingEvents(for: groupID)
            try await pullRemoteEvents(for: groupID)
            try await refreshExpenses(for: groupID)
            persist()
        } catch {
            registrationStatus = .failed(error.localizedDescription)
            persist()
        }
    }

    private func refreshDeviceInBackground() {
        Task {
            do {
                let deviceID = try await apiClient.fetchDevice()
                applyRegisteredDeviceID(deviceID)
            } catch {
                // Keep showing the locally saved device ID when a background refresh fails.
            }
        }
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

    private func postPendingEvents(for groupID: GroupID) async throws {
        let events = pendingEvents
            .filter { $0.groupID == groupID }
            .sorted { $0.event.clientSequence < $1.event.clientSequence }

        for pendingEvent in events {
            let response = try await apiClient.postExpenseEvent(groupID: groupID, event: pendingEvent.event)
            if let expense = response.expense, response.conflict == true || response.applied == false {
                upsertExpense(ExpenseRecord(serverExpense: expense))
            }
            acknowledgeEvent(id: pendingEvent.event.eventID)
        }
    }

    private func pullRemoteEvents(for groupID: GroupID) async throws {
        while let group = groups.first(where: { $0.id == groupID }) {
            let response = try await apiClient.fetchGroupEvents(groupID: groupID, after: group.syncCursor)
            guard !response.events.isEmpty else { break }

            let maxSequence = response.events.map(\.sequence).max() ?? group.syncCursor
            updateGroup(id: groupID) { group in
                group.syncCursor = max(group.syncCursor, maxSequence)
            }

            let eventIDs = Set(response.events.map(\.eventID))
            pendingEvents.removeAll { $0.groupID == groupID && eventIDs.contains($0.event.eventID) }
            persist()

            if !response.hasMore {
                break
            }
        }
    }

    private func refreshExpenses(for groupID: GroupID) async throws {
        let serverExpenses = try await apiClient.fetchExpenses(groupID: groupID)
        expenses.removeAll { $0.groupID == groupID }
        expenses.append(contentsOf: serverExpenses.map(ExpenseRecord.init(serverExpense:)))
    }

    private func makeExpenseEvent(
        groupID: GroupID,
        expenseID: ExpenseID,
        eventType: ExpenseEventType,
        baseSequence: Int64,
        name: String,
        description: String,
        currencyCode: String,
        totalMinorUnits: Int64,
        payerActorID: ActorID?,
        splitMethod: SplitMethod,
        manualSplits: [ExpenseSplit]?,
        occurredAt: Date
    ) throws -> ExpenseEventRequest {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw SplitStoreError.groupNotFound
        }

        let payerActorID = payerActorID ?? group.localActorID
        let splits: [ExpenseSplit]
        switch splitMethod {
        case .equal:
            splits = group.actorIDs.map { ExpenseSplit(actorID: $0) }
        case .manual:
            guard let manualSplits else { throw SplitStoreError.missingManualSplitAmount }
            guard manualSplits.allSatisfy({ $0.amountMinorUnits != nil }) else { throw SplitStoreError.missingManualSplitAmount }
            let splitTotal = manualSplits.reduce(Int64(0)) { total, split in
                total + (split.amountMinorUnits ?? 0)
            }
            guard splitTotal == totalMinorUnits else { throw SplitStoreError.manualSplitsDoNotMatchTotal }
            splits = manualSplits
        }

        let clientSequence = nextClientSequence
        nextClientSequence += 1
        persist()

        return ExpenseEventRequest(
            eventID: .generate(),
            entityID: expenseID,
            eventType: eventType,
            actorID: group.localActorID,
            eventCreatedAt: Date(),
            clientSequence: clientSequence,
            baseSequence: baseSequence,
            payload: ExpensePayload(
                name: name,
                description: description,
                currencyCode: currencyCode,
                totalMinorUnits: totalMinorUnits,
                payerActorID: payerActorID,
                splitMethod: splitMethod,
                occurredAt: occurredAt,
                splits: splits
            )
        )
    }

    private func enqueue(_ event: ExpenseEventRequest, groupID: GroupID) {
        pendingEvents.append(PendingExpenseEvent(groupID: groupID, event: event))
        persist()
    }

    private func acknowledgeEvent(id eventID: EventID) {
        pendingEvents.removeAll { $0.event.eventID == eventID }
        persist()
    }

    private func applyLocalExpense(event: ExpenseEventRequest, groupID: GroupID) {
        let now = Date()
        let expense = ExpenseRecord(
            id: event.entityID,
            groupID: groupID,
            createdByActorID: event.actorID,
            payload: event.payload,
            createdAt: now,
            updatedAt: now,
            version: event.baseSequence,
            voidedAt: event.eventType == .voided ? event.eventCreatedAt : nil
        )
        upsertExpense(expense)
        persist()
    }

    private func upsertExpense(_ expense: ExpenseRecord) {
        if let index = expenses.firstIndex(where: { $0.id == expense.id }) {
            expenses[index] = expense
        } else {
            expenses.append(expense)
        }
    }

    private func applyServerGroups(_ serverGroups: [ServerGroup]) {
        let serverActorIDs = Set(serverGroups.flatMap(\.actorIDs))
        actors.removeAll { $0.isLocal && !serverActorIDs.contains($0.id) }

        for serverGroup in serverGroups {
            upsertActors(from: serverGroup)
        }

        groups = serverGroups.map { makeExpenseGroup(from: $0, existingGroup: group(id: $0.id)) }
        pruneUnusedActors()
        persist()
    }

    private func applyServerGroup(_ serverGroup: ServerGroup) {
        upsertActors(from: serverGroup)

        let group = makeExpenseGroup(from: serverGroup, existingGroup: self.group(id: serverGroup.id))
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }

        pruneUnusedActors()
        persist()
    }

    private func makeExpenseGroup(from serverGroup: ServerGroup, existingGroup: ExpenseGroup?) -> ExpenseGroup {
        ExpenseGroup(
            id: serverGroup.id,
            name: serverGroup.name,
            joinCode: serverGroup.joinCode,
            localActorID: serverGroup.actorID,
            actorIDs: serverGroup.actorIDs,
            syncCursor: existingGroup?.syncCursor ?? 0,
            serverLatestEventSequence: serverGroup.latestEventSequence,
            createdAt: serverGroup.createdAt
        )
    }

    private func group(id groupID: GroupID) -> ExpenseGroup? {
        groups.first { $0.id == groupID }
    }

    private func updateGroup(id groupID: GroupID, update: (inout ExpenseGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        update(&groups[index])
        persist()
    }

    private func upsertActors(from serverGroup: ServerGroup) {
        for serverActor in serverGroup.actors {
            if serverActor.id == serverGroup.actorID {
                upsertLocalActor(id: serverActor.id)
            } else {
                upsertRemoteActor(id: serverActor.id, displayName: serverActor.displayName)
            }
        }

        if !serverGroup.actors.contains(where: { $0.id == serverGroup.actorID }) {
            upsertLocalActor(id: serverGroup.actorID)
        }
    }

    private func upsertRemoteActor(id actorID: ActorID, displayName: String?) {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.flatMap { $0.isEmpty ? nil : $0 } ?? actorID.rawValue

        if let index = actors.firstIndex(where: { $0.id == actorID }) {
            guard !actors[index].isLocal else { return }
            actors[index].displayName = resolvedName
            actors[index].deviceID = nil
        } else {
            actors.append(Actor(id: actorID, displayName: resolvedName, deviceID: nil, isLocal: false))
        }
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
        deviceIDStore.saveDeviceID(deviceID)
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
        let usedActorIDs = Set(groups.flatMap(\.actorIDs) + expenses.flatMap { $0.payload.splits.map(\.actorID) })
        actors.removeAll { !usedActorIDs.contains($0.id) }
    }

    private func persist() {
        do {
            let directoryURL = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let snapshot = SplitSnapshot(
                displayName: displayName,
                actors: actors,
                groups: groups,
                expenses: expenses,
                pendingEvents: pendingEvents,
                nextClientSequence: nextClientSequence
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist split state: \(error.localizedDescription)")
        }
    }
}
