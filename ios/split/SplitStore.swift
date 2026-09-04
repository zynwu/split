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

struct PaymentID: RawRepresentable, Codable, Hashable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    static func generate() -> PaymentID {
        PaymentID(rawValue: UUID().uuidString)
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
    var metadataVersion: Int64

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case deviceID
        case isLocal
        case metadataVersion
    }

    init(
        id: ActorID,
        displayName: String,
        deviceID: DeviceID?,
        isLocal: Bool,
        metadataVersion: Int64 = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.deviceID = deviceID
        self.isLocal = isLocal
        self.metadataVersion = metadataVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ActorID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.deviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceID)
        self.isLocal = try container.decode(Bool.self, forKey: .isLocal)
        self.metadataVersion = try container.decodeIfPresent(Int64.self, forKey: .metadataVersion) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encode(isLocal, forKey: .isLocal)
        try container.encode(metadataVersion, forKey: .metadataVersion)
    }
}

struct ExpenseGroup: Codable, Hashable, Identifiable {
    let id: GroupID
    var name: String
    var joinCode: String
    var localActorID: ActorID
    var actorIDs: [ActorID]
    var syncCursor: Int64
    var serverLatestEventSequence: Int64
    var metadataVersion: Int64
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case joinCode
        case localActorID
        case actorIDs
        case syncCursor
        case serverLatestEventSequence
        case metadataVersion
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
        metadataVersion: Int64 = 0,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.joinCode = joinCode
        self.localActorID = localActorID
        self.actorIDs = actorIDs
        self.syncCursor = syncCursor
        self.serverLatestEventSequence = serverLatestEventSequence
        self.metadataVersion = metadataVersion
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
        self.metadataVersion = try container.decodeIfPresent(Int64.self, forKey: .metadataVersion) ?? 0
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct DeviceActorLink: Codable, Hashable {
    let deviceID: DeviceID
    let groupID: GroupID
    let actorID: ActorID
}

private struct StoredExpenseSplit: Codable, Hashable {
    let actorID: ActorID
    let amountMinorUnits: Int64?
    let usdAmountMinorUnits: Int64?

    private enum CodingKeys: String, CodingKey {
        case actor_uuid
        case amount_minor_units
        case usd_amount_minor_units
    }

    nonisolated init(_ split: ExpenseSplit) {
        self.actorID = split.actorID
        self.amountMinorUnits = split.amountMinorUnits
        self.usdAmountMinorUnits = split.usdAmountMinorUnits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.actorID = ActorID(rawValue: try container.decode(String.self, forKey: .actor_uuid))
        self.amountMinorUnits = try container.decodeIfPresent(Int64.self, forKey: .amount_minor_units)
        self.usdAmountMinorUnits = try container.decodeIfPresent(Int64.self, forKey: .usd_amount_minor_units)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actorID.rawValue, forKey: .actor_uuid)
        try container.encodeIfPresent(amountMinorUnits, forKey: .amount_minor_units)
        try container.encodeIfPresent(usdAmountMinorUnits, forKey: .usd_amount_minor_units)
    }

    var expenseSplit: ExpenseSplit {
        ExpenseSplit(
            actorID: actorID,
            amountMinorUnits: amountMinorUnits,
            usdAmountMinorUnits: usdAmountMinorUnits
        )
    }
}

private struct StoredExpensePayload: Codable, Hashable {
    let name: String
    let description: String
    let currencyCode: String
    let totalMinorUnits: Int64
    let payerActorID: ActorID
    let splitMethod: SplitMethod
    let splitConfig: [String: JSONValue]
    let occurredAt: Date
    let splits: [StoredExpenseSplit]

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

    init(_ payload: ExpensePayload) {
        self.name = payload.name
        self.description = payload.description
        self.currencyCode = payload.currencyCode
        self.totalMinorUnits = payload.totalMinorUnits
        self.payerActorID = payload.payerActorID
        self.splitMethod = payload.splitMethod
        self.splitConfig = payload.splitConfig
        self.occurredAt = payload.occurredAt
        self.splits = payload.splits.map(StoredExpenseSplit.init)
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
        self.splits = try container.decode([StoredExpenseSplit].self, forKey: .splits)
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

    var expensePayload: ExpensePayload {
        ExpensePayload(
            name: name,
            description: description,
            currencyCode: currencyCode,
            totalMinorUnits: totalMinorUnits,
            payerActorID: payerActorID,
            splitMethod: splitMethod,
            splitConfig: splitConfig,
            occurredAt: occurredAt,
            splits: splits.map(\.expenseSplit)
        )
    }
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
    // These values are locked by the server when the event is accepted. They
    // remain optional for pending local events and older snapshots.
    var exchangeRateToUSD: String?
    var usdTotalMinorUnits: Int64?
    var rateSnapshotDate: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case groupID
        case createdByActorID
        case payload
        case createdAt
        case updatedAt
        case version
        case voidedAt
        case exchangeRateToUSD
        case usdTotalMinorUnits
        case rateSnapshotDate
    }

    init(
        id: ExpenseID,
        groupID: GroupID,
        createdByActorID: ActorID,
        payload: ExpensePayload,
        createdAt: Date,
        updatedAt: Date,
        version: Int64,
        voidedAt: Date? = nil,
        exchangeRateToUSD: String? = nil,
        usdTotalMinorUnits: Int64? = nil,
        rateSnapshotDate: String? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.createdByActorID = createdByActorID
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.voidedAt = voidedAt
        self.exchangeRateToUSD = exchangeRateToUSD
        self.usdTotalMinorUnits = usdTotalMinorUnits
        self.rateSnapshotDate = rateSnapshotDate
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
        self.exchangeRateToUSD = serverExpense.exchangeRateToUSD
        self.usdTotalMinorUnits = serverExpense.usdTotalMinorUnits
        self.rateSnapshotDate = serverExpense.rateSnapshotDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ExpenseID.self, forKey: .id)
        self.groupID = try container.decode(GroupID.self, forKey: .groupID)
        self.createdByActorID = try container.decode(ActorID.self, forKey: .createdByActorID)
        self.payload = try container.decode(StoredExpensePayload.self, forKey: .payload).expensePayload
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.version = try container.decode(Int64.self, forKey: .version)
        self.voidedAt = try container.decodeIfPresent(Date.self, forKey: .voidedAt)
        self.exchangeRateToUSD = try container.decodeIfPresent(String.self, forKey: .exchangeRateToUSD)
        self.usdTotalMinorUnits = try container.decodeIfPresent(Int64.self, forKey: .usdTotalMinorUnits)
        self.rateSnapshotDate = try container.decodeIfPresent(String.self, forKey: .rateSnapshotDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(createdByActorID, forKey: .createdByActorID)
        try container.encode(StoredExpensePayload(payload), forKey: .payload)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(voidedAt, forKey: .voidedAt)
        try container.encodeIfPresent(exchangeRateToUSD, forKey: .exchangeRateToUSD)
        try container.encodeIfPresent(usdTotalMinorUnits, forKey: .usdTotalMinorUnits)
        try container.encodeIfPresent(rateSnapshotDate, forKey: .rateSnapshotDate)
    }
}

struct PaymentRecord: Codable, Hashable, Identifiable {
    let id: PaymentID
    let groupID: GroupID
    var createdByActorID: ActorID
    var payload: PaymentPayload
    var createdAt: Date
    var updatedAt: Date
    var version: Int64
    var voidedAt: Date?
    // These values are locked by the server when the event is accepted. They
    // remain optional for pending local events and older snapshots.
    var exchangeRateToUSD: String?
    var usdAmountMinorUnits: Int64?
    var rateSnapshotDate: String?

    init(
        id: PaymentID,
        groupID: GroupID,
        createdByActorID: ActorID,
        payload: PaymentPayload,
        createdAt: Date,
        updatedAt: Date,
        version: Int64,
        voidedAt: Date? = nil,
        exchangeRateToUSD: String? = nil,
        usdAmountMinorUnits: Int64? = nil,
        rateSnapshotDate: String? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.createdByActorID = createdByActorID
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
        self.voidedAt = voidedAt
        self.exchangeRateToUSD = exchangeRateToUSD
        self.usdAmountMinorUnits = usdAmountMinorUnits
        self.rateSnapshotDate = rateSnapshotDate
    }

    init(serverPayment: ServerPayment) {
        self.id = serverPayment.id
        self.groupID = serverPayment.groupID
        self.createdByActorID = serverPayment.createdByActorID
        self.payload = serverPayment.payload
        self.createdAt = serverPayment.createdAt
        self.updatedAt = serverPayment.updatedAt
        self.version = serverPayment.version
        self.voidedAt = serverPayment.voidedAt
        self.exchangeRateToUSD = serverPayment.exchangeRateToUSD
        self.usdAmountMinorUnits = serverPayment.usdAmountMinorUnits
        self.rateSnapshotDate = serverPayment.rateSnapshotDate
    }
}

struct PendingSyncOperation: Codable, Hashable, Identifiable {
    var id: EventID { event.eventID }
    let groupID: GroupID
    let event: LedgerEventRequest
}

// Kept only to migrate state files created before the generic outbox existed.
private struct PendingExpenseEvent: Codable, Hashable, Identifiable {
    var id: EventID { event.eventID }
    let groupID: GroupID
    let event: ExpenseEventRequest
}

struct ExpenseAuditEntry: Codable, Hashable, Identifiable {
    let id: EventID
    let groupID: GroupID
    var sequence: Int64?
    let eventType: ExpenseEventType
    let actorID: ActorID
    let expenseID: ExpenseID
    let expenseName: String
    let totalMinorUnits: Int64
    let currencyCode: String
    let exchangeRateToUSD: String?
    let usdTotalMinorUnits: Int64?
    let rateSnapshotDate: String?
    let eventCreatedAt: Date
    var isPending: Bool

    init?(
        groupID: GroupID,
        event: LedgerEventRequest,
        sequence: Int64? = nil,
        isPending: Bool,
        fallbackExpense: ExpenseRecord? = nil
    ) {
        guard event.entityType == "expense",
              let eventType = ExpenseEventType(rawValue: event.eventType) else { return nil }

        let payload = event.expensePayload()
        let isVoidEvent = eventType == .voided || eventType == .deleted
        guard isVoidEvent || payload != nil else { return nil }
        let resolvedPayload = payload ?? fallbackExpense?.payload

        let expenseID = ExpenseID(rawValue: event.entityID)
        self.id = event.eventID
        self.groupID = groupID
        self.sequence = sequence
        self.eventType = eventType
        self.actorID = event.actorID
        self.expenseID = expenseID
        self.expenseName = resolvedPayload?.name ?? "Expense"
        self.totalMinorUnits = resolvedPayload?.totalMinorUnits ?? 0
        self.currencyCode = resolvedPayload?.currencyCode ?? "USD"
        self.exchangeRateToUSD = fallbackExpense?.exchangeRateToUSD
        self.usdTotalMinorUnits = fallbackExpense?.usdTotalMinorUnits
        self.rateSnapshotDate = fallbackExpense?.rateSnapshotDate
        self.eventCreatedAt = event.eventCreatedAt
        self.isPending = isPending
    }

    init?(
        groupID: GroupID,
        pulledEvent: PulledLedgerEvent,
        fallbackExpense: ExpenseRecord? = nil
    ) {
        guard pulledEvent.entityType == "expense",
              let eventType = pulledEvent.eventType.flatMap(ExpenseEventType.init(rawValue:)),
              let actorID = pulledEvent.actorID,
              let expenseID = pulledEvent.entityID.flatMap(ExpenseID.init(rawValue:)),
              let eventCreatedAt = pulledEvent.eventCreatedAt else { return nil }

        let payload = pulledEvent.payload.flatMap { try? $0.decode(ExpensePayload.self) }
        let isVoidEvent = eventType == .voided || eventType == .deleted
        guard isVoidEvent || payload != nil else { return nil }
        let resolvedPayload = payload ?? fallbackExpense?.payload

        self.id = pulledEvent.eventID
        self.groupID = groupID
        self.sequence = pulledEvent.sequence
        self.eventType = eventType
        self.actorID = actorID
        self.expenseID = expenseID
        self.expenseName = resolvedPayload?.name ?? "Expense"
        self.totalMinorUnits = resolvedPayload?.totalMinorUnits ?? 0
        self.currencyCode = resolvedPayload?.currencyCode ?? "USD"
        self.exchangeRateToUSD = pulledEvent.exchangeRateToUSD ?? fallbackExpense?.exchangeRateToUSD
        self.usdTotalMinorUnits = pulledEvent.usdAmountMinorUnits ?? fallbackExpense?.usdTotalMinorUnits
        self.rateSnapshotDate = pulledEvent.rateSnapshotDate ?? fallbackExpense?.rateSnapshotDate
        self.eventCreatedAt = eventCreatedAt
        self.isPending = false
    }

    init(groupID: GroupID, expense: ExpenseRecord) {
        self.id = EventID(rawValue: "expense-\(expense.id.rawValue)-created")
        self.groupID = groupID
        self.sequence = expense.version > 0 ? expense.version : nil
        self.eventType = .created
        self.actorID = expense.createdByActorID
        self.expenseID = expense.id
        self.expenseName = expense.payload.name
        self.totalMinorUnits = expense.payload.totalMinorUnits
        self.currencyCode = expense.payload.currencyCode
        self.exchangeRateToUSD = expense.exchangeRateToUSD
        self.usdTotalMinorUnits = expense.usdTotalMinorUnits
        self.rateSnapshotDate = expense.rateSnapshotDate
        self.eventCreatedAt = expense.createdAt
        self.isPending = false
    }
}

struct PaymentAuditEntry: Codable, Hashable, Identifiable {
    let id: EventID
    let groupID: GroupID
    var sequence: Int64?
    let eventType: String
    let actorID: ActorID
    let paymentID: PaymentID
    let fromActorID: ActorID
    let toActorID: ActorID
    let amountMinorUnits: Int64
    let currencyCode: String
    let exchangeRateToUSD: String?
    let usdAmountMinorUnits: Int64?
    let rateSnapshotDate: String?
    let eventCreatedAt: Date
    var isPending: Bool

    init?(
        groupID: GroupID,
        event: LedgerEventRequest,
        sequence: Int64? = nil,
        isPending: Bool,
        fallbackPayment: PaymentRecord? = nil
    ) {
        guard event.entityType == "payment" else { return nil }

        let payload = event.paymentPayload()
        let isVoidEvent = event.eventType == "payment.voided" || event.eventType == "payment.deleted"
        guard isVoidEvent || payload != nil else { return nil }
        let resolvedPayload = payload ?? fallbackPayment?.payload ?? PaymentPayload(
            fromActorID: event.actorID,
            toActorID: event.actorID,
            currencyCode: "USD",
            amountMinorUnits: 0,
            occurredAt: event.eventCreatedAt
        )

        self.id = event.eventID
        self.groupID = groupID
        self.sequence = sequence
        self.eventType = event.eventType
        self.actorID = event.actorID
        self.paymentID = PaymentID(rawValue: event.entityID)
        self.fromActorID = resolvedPayload.fromActorID
        self.toActorID = resolvedPayload.toActorID
        self.amountMinorUnits = resolvedPayload.amountMinorUnits
        self.currencyCode = resolvedPayload.currencyCode
        self.exchangeRateToUSD = fallbackPayment?.exchangeRateToUSD
        self.usdAmountMinorUnits = fallbackPayment?.usdAmountMinorUnits
        self.rateSnapshotDate = fallbackPayment?.rateSnapshotDate
        self.eventCreatedAt = event.eventCreatedAt
        self.isPending = isPending
    }

    init?(
        groupID: GroupID,
        pulledEvent: PulledLedgerEvent,
        fallbackPayment: PaymentRecord? = nil
    ) {
        guard pulledEvent.entityType == "payment",
              let eventType = pulledEvent.eventType,
              let actorID = pulledEvent.actorID,
              let paymentID = pulledEvent.entityID.map(PaymentID.init(rawValue:)),
              let eventCreatedAt = pulledEvent.eventCreatedAt else { return nil }

        let payload = pulledEvent.payload.flatMap { try? $0.decode(PaymentPayload.self) }
        let isVoidEvent = eventType == "payment.voided" || eventType == "payment.deleted"
        guard isVoidEvent || payload != nil else { return nil }
        let resolvedPayload = payload ?? fallbackPayment?.payload ?? PaymentPayload(
            fromActorID: actorID,
            toActorID: actorID,
            currencyCode: "USD",
            amountMinorUnits: 0,
            occurredAt: eventCreatedAt
        )

        self.id = pulledEvent.eventID
        self.groupID = groupID
        self.sequence = pulledEvent.sequence
        self.eventType = eventType
        self.actorID = actorID
        self.paymentID = paymentID
        self.fromActorID = resolvedPayload.fromActorID
        self.toActorID = resolvedPayload.toActorID
        self.amountMinorUnits = resolvedPayload.amountMinorUnits
        self.currencyCode = resolvedPayload.currencyCode
        self.exchangeRateToUSD = pulledEvent.exchangeRateToUSD ?? fallbackPayment?.exchangeRateToUSD
        self.usdAmountMinorUnits = pulledEvent.usdAmountMinorUnits ?? fallbackPayment?.usdAmountMinorUnits
        self.rateSnapshotDate = pulledEvent.rateSnapshotDate ?? fallbackPayment?.rateSnapshotDate
        self.eventCreatedAt = eventCreatedAt
        self.isPending = false
    }

    init(groupID: GroupID, payment: PaymentRecord) {
        self.id = EventID(rawValue: "payment-\(payment.id.rawValue)-created")
        self.groupID = groupID
        self.sequence = payment.version > 0 ? payment.version : nil
        self.eventType = "payment.created"
        self.actorID = payment.createdByActorID
        self.paymentID = payment.id
        self.fromActorID = payment.payload.fromActorID
        self.toActorID = payment.payload.toActorID
        self.amountMinorUnits = payment.payload.amountMinorUnits
        self.currencyCode = payment.payload.currencyCode
        self.exchangeRateToUSD = payment.exchangeRateToUSD
        self.usdAmountMinorUnits = payment.usdAmountMinorUnits
        self.rateSnapshotDate = payment.rateSnapshotDate
        self.eventCreatedAt = payment.createdAt
        self.isPending = false
    }
}

struct GroupSyncState: Codable, Hashable {
    var lastSuccessfulSyncAt: Date?
    var lastSyncError: String?

    init(lastSuccessfulSyncAt: Date? = nil, lastSyncError: String? = nil) {
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.lastSyncError = lastSyncError
    }
}

struct SplitSnapshot: Codable {
    var migratedDeviceID: DeviceID?
    var displayName: String
    var actors: [Actor]
    var groups: [ExpenseGroup]
    var expenses: [ExpenseRecord]
    var payments: [PaymentRecord]
    var pendingOperations: [PendingSyncOperation]
    var auditEvents: [ExpenseAuditEntry]
    var paymentAuditEvents: [PaymentAuditEntry]
    var groupBalances: [GroupID: GroupBalancesResponse]
    var groupSyncStates: [GroupID: GroupSyncState]
    var nextClientSequence: Int64

    private enum CodingKeys: String, CodingKey {
        case deviceID
        case displayName
        case actors
        case groups
        case expenses
        case payments
        case pendingOperations
        case pendingEvents
        case auditEvents
        case paymentAuditEvents
        case groupBalances
        case groupSyncStates
        case nextClientSequence
    }

    init(
        displayName: String,
        actors: [Actor],
        groups: [ExpenseGroup],
        expenses: [ExpenseRecord],
        payments: [PaymentRecord],
        pendingOperations: [PendingSyncOperation],
        auditEvents: [ExpenseAuditEntry],
        paymentAuditEvents: [PaymentAuditEntry],
        groupBalances: [GroupID: GroupBalancesResponse],
        groupSyncStates: [GroupID: GroupSyncState],
        nextClientSequence: Int64
    ) {
        self.migratedDeviceID = nil
        self.displayName = displayName
        self.actors = actors
        self.groups = groups
        self.expenses = expenses
        self.payments = payments
        self.pendingOperations = pendingOperations
        self.auditEvents = auditEvents
        self.paymentAuditEvents = paymentAuditEvents
        self.groupBalances = groupBalances
        self.groupSyncStates = groupSyncStates
        self.nextClientSequence = nextClientSequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.migratedDeviceID = try container.decodeIfPresent(DeviceID.self, forKey: .deviceID)
        self.actors = try container.decode([Actor].self, forKey: .actors)
        self.groups = try container.decode([ExpenseGroup].self, forKey: .groups)
        self.expenses = try container.decodeIfPresent([ExpenseRecord].self, forKey: .expenses) ?? []
        self.payments = try container.decodeIfPresent([PaymentRecord].self, forKey: .payments) ?? []
        if let pendingOperations = try container.decodeIfPresent([PendingSyncOperation].self, forKey: .pendingOperations) {
            self.pendingOperations = pendingOperations
        } else {
            let legacyEvents = try container.decodeIfPresent([PendingExpenseEvent].self, forKey: .pendingEvents) ?? []
            self.pendingOperations = try legacyEvents.map { legacyEvent in
                PendingSyncOperation(
                    groupID: legacyEvent.groupID,
                    event: try LedgerEventRequest(expenseEvent: legacyEvent.event)
                )
            }
        }
        self.auditEvents = try container.decodeIfPresent([ExpenseAuditEntry].self, forKey: .auditEvents)
            ?? self.pendingOperations.compactMap { ExpenseAuditEntry(groupID: $0.groupID, event: $0.event, isPending: true) }
        self.paymentAuditEvents = try container.decodeIfPresent([PaymentAuditEntry].self, forKey: .paymentAuditEvents)
            ?? self.pendingOperations.compactMap { PaymentAuditEntry(groupID: $0.groupID, event: $0.event, isPending: true) }
        self.groupBalances = try container.decodeIfPresent([GroupID: GroupBalancesResponse].self, forKey: .groupBalances) ?? [:]
        self.groupSyncStates = try container.decodeIfPresent([GroupID: GroupSyncState].self, forKey: .groupSyncStates) ?? [:]
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
        try container.encode(payments, forKey: .payments)
        try container.encode(pendingOperations, forKey: .pendingOperations)
        try container.encode(auditEvents, forKey: .auditEvents)
        try container.encode(paymentAuditEvents, forKey: .paymentAuditEvents)
        try container.encode(groupBalances, forKey: .groupBalances)
        try container.encode(groupSyncStates, forKey: .groupSyncStates)
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
    private(set) var payments: [PaymentRecord]
    private(set) var pendingOperations: [PendingSyncOperation]
    private(set) var auditEvents: [ExpenseAuditEntry]
    private(set) var paymentAuditEvents: [PaymentAuditEntry]
    private(set) var groupBalances: [GroupID: GroupBalancesResponse]
    private(set) var groupSyncStates: [GroupID: GroupSyncState]
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
            self.payments = snapshot.payments
            self.pendingOperations = snapshot.pendingOperations
            self.auditEvents = snapshot.auditEvents
            self.paymentAuditEvents = snapshot.paymentAuditEvents
            self.groupBalances = snapshot.groupBalances
            self.groupSyncStates = snapshot.groupSyncStates
            self.nextClientSequence = snapshot.nextClientSequence
            self.auditEvents = deduplicatedAuditEvents(auditEvents)
            ensureLocalActorsExist()
        } else {
            self.deviceID = savedDeviceID
            self.displayName = "Me"
            self.actors = []
            self.groups = []
            self.expenses = []
            self.payments = []
            self.pendingOperations = []
            self.auditEvents = []
            self.paymentAuditEvents = []
            self.groupBalances = [:]
            self.groupSyncStates = [:]
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
            let serverGroup = try await apiClient.createGroup(named: cleanName, displayName: displayName)
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
            let serverGroup = try await apiClient.joinGroup(with: cleanCode, displayName: displayName)
            applyServerGroup(serverGroup)
            await syncGroup(id: serverGroup.id)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func updateActorDisplayName(in groupID: GroupID, actorID: ActorID, to displayName: String) async {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        guard let group = groups.first(where: { $0.id == groupID }), group.actorIDs.contains(actorID) else { return }

        do {
            let event = try makeActorDisplayNameEvent(
                groupID: groupID,
                actorID: actorID,
                displayName: cleanName,
                baseSequence: actors.first(where: { $0.id == actorID })?.metadataVersion ?? 0
            )
            enqueue(event, groupID: groupID)
            applyLocalActorDisplayName(actorID: actorID, displayName: cleanName)
            await syncGroup(id: groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func updateGroupName(in groupID: GroupID, to name: String) async {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        guard let group = groups.first(where: { $0.id == groupID }) else { return }

        do {
            let event = try makeGroupNameEvent(
                groupID: groupID,
                name: cleanName,
                baseSequence: group.metadataVersion
            )
            enqueue(event, groupID: groupID)
            applyLocalGroupName(groupID: groupID, name: cleanName)
            await syncGroup(id: groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func commandeerActor(in groupID: GroupID, targetActorID: ActorID) async {
        guard let group = groups.first(where: { $0.id == groupID }),
              group.actorIDs.contains(targetActorID),
              group.localActorID != targetActorID else { return }

        do {
            let response = try await apiClient.commandeerActor(
                groupID: groupID,
                targetActorID: targetActorID,
                eventID: .generate(),
                eventCreatedAt: Date(),
                clientSequence: allocateClientSequence()
            )

            if let targetActor = response.targetActor {
                upsertActor(targetActor, isLocal: true)
            }
            await syncGroup(id: groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func removeGroup(id: GroupID) {
        groups.removeAll { $0.id == id }
        expenses.removeAll { $0.groupID == id }
        payments.removeAll { $0.groupID == id }
        pendingOperations.removeAll { $0.groupID == id }
        auditEvents.removeAll { $0.groupID == id }
        paymentAuditEvents.removeAll { $0.groupID == id }
        groupBalances[id] = nil
        groupSyncStates[id] = nil
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

    func expense(id expenseID: ExpenseID) -> ExpenseRecord? {
        expenses.first { $0.id == expenseID && $0.voidedAt == nil }
    }

    func payments(for groupID: GroupID) -> [PaymentRecord] {
        payments
            .filter { $0.groupID == groupID && $0.voidedAt == nil }
            .sorted { $0.payload.occurredAt > $1.payload.occurredAt }
    }

    func payment(id paymentID: PaymentID) -> PaymentRecord? {
        payments.first { $0.id == paymentID && $0.voidedAt == nil }
    }

    func isPaymentPending(id paymentID: PaymentID) -> Bool {
        pendingOperations.contains { operation in
            operation.event.entityType == "payment" && operation.event.entityID == paymentID.rawValue
        }
    }

    func balances(for groupID: GroupID) -> GroupBalancesResponse? {
        groupBalances[groupID]
    }

    func syncState(for groupID: GroupID) -> GroupSyncState {
        groupSyncStates[groupID] ?? GroupSyncState()
    }

    func pendingOperationCount(for groupID: GroupID) -> Int {
        pendingOperations.count { $0.groupID == groupID }
    }

    func paymentAuditEvents(for groupID: GroupID) -> [PaymentAuditEntry] {
        let storedEntries = deduplicatedPaymentAuditEvents(paymentAuditEvents.filter { $0.groupID == groupID })
        let paymentIDsWithCreatedEvents = Set(storedEntries.filter { $0.eventType == "payment.created" }.map(\.paymentID))
        let fallbackEntries = payments
            .filter { $0.groupID == groupID && !paymentIDsWithCreatedEvents.contains($0.id) }
            .map { PaymentAuditEntry(groupID: groupID, payment: $0) }

        return deduplicatedPaymentAuditEvents(storedEntries + fallbackEntries)
            .sorted { lhs, rhs in
                if lhs.eventCreatedAt == rhs.eventCreatedAt {
                    return lhs.id.rawValue > rhs.id.rawValue
                }
                return lhs.eventCreatedAt > rhs.eventCreatedAt
            }
    }

    func auditEvents(for groupID: GroupID) -> [ExpenseAuditEntry] {
        let storedEntries = deduplicatedAuditEvents(auditEvents.filter { $0.groupID == groupID })
        let expenseIDsWithCreatedEvents = Set(storedEntries.filter { $0.eventType == .created }.map(\.expenseID))
        let fallbackEntries = expenses
            .filter { $0.groupID == groupID && !expenseIDsWithCreatedEvents.contains($0.id) }
            .map { ExpenseAuditEntry(groupID: groupID, expense: $0) }

        return deduplicatedAuditEvents(storedEntries + fallbackEntries)
            .sorted { lhs, rhs in
                if lhs.eventCreatedAt == rhs.eventCreatedAt {
                    return lhs.id.rawValue > rhs.id.rawValue
                }
                return lhs.eventCreatedAt > rhs.eventCreatedAt
            }
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

    func updateExpense(
        id expenseID: ExpenseID,
        name: String,
        description: String = "",
        currencyCode: String = "USD",
        totalMinorUnits: Int64,
        payerActorID: ActorID,
        splitMethod: SplitMethod,
        manualSplits: [ExpenseSplit]?
    ) async {
        do {
            guard let expense = expense(id: expenseID) else { throw SplitStoreError.groupNotFound }
            let event = try makeExpenseEvent(
                groupID: expense.groupID,
                expenseID: expense.id,
                eventType: .updated,
                baseSequence: expense.version,
                name: name,
                description: description,
                currencyCode: currencyCode,
                totalMinorUnits: totalMinorUnits,
                payerActorID: payerActorID,
                splitMethod: splitMethod,
                manualSplits: manualSplits,
                occurredAt: expense.payload.occurredAt
            )

            enqueue(event, groupID: expense.groupID)
            applyLocalExpense(event: event, groupID: expense.groupID)
            await syncGroup(id: expense.groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func voidExpense(id expenseID: ExpenseID) async {
        do {
            guard let expense = expense(id: expenseID) else { throw SplitStoreError.groupNotFound }
            let event = try makeVoidEvent(
                groupID: expense.groupID,
                entityType: "expense",
                entityID: expense.id.rawValue,
                eventType: "expense.voided",
                baseSequence: expense.version
            )

            enqueue(event, groupID: expense.groupID)
            applyLocalExpense(event: event, groupID: expense.groupID)
            await syncGroup(id: expense.groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func createPayment(
        in groupID: GroupID,
        fromActorID: ActorID,
        toActorID: ActorID,
        currencyCode: String = "USD",
        amountMinorUnits: Int64,
        occurredAt: Date = Date()
    ) async {
        do {
            let event = try makePaymentEvent(
                groupID: groupID,
                paymentID: .generate(),
                eventType: "payment.created",
                baseSequence: 0,
                fromActorID: fromActorID,
                toActorID: toActorID,
                currencyCode: currencyCode,
                amountMinorUnits: amountMinorUnits,
                occurredAt: occurredAt
            )
            enqueue(event, groupID: groupID)
            applyLocalPayment(event: event, groupID: groupID)
            await syncGroup(id: groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func updatePayment(
        id paymentID: PaymentID,
        fromActorID: ActorID,
        toActorID: ActorID,
        currencyCode: String = "USD",
        amountMinorUnits: Int64
    ) async {
        do {
            guard let payment = payment(id: paymentID) else { throw SplitStoreError.groupNotFound }
            let event = try makePaymentEvent(
                groupID: payment.groupID,
                paymentID: payment.id,
                eventType: "payment.updated",
                baseSequence: payment.version,
                fromActorID: fromActorID,
                toActorID: toActorID,
                currencyCode: currencyCode,
                amountMinorUnits: amountMinorUnits,
                occurredAt: payment.payload.occurredAt
            )
            enqueue(event, groupID: payment.groupID)
            applyLocalPayment(event: event, groupID: payment.groupID)
            await syncGroup(id: payment.groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func voidPayment(id paymentID: PaymentID) async {
        do {
            guard let payment = payment(id: paymentID) else { throw SplitStoreError.groupNotFound }
            let event = try makeVoidEvent(
                groupID: payment.groupID,
                entityType: "payment",
                entityID: payment.id.rawValue,
                eventType: "payment.voided",
                baseSequence: payment.version
            )

            enqueue(event, groupID: payment.groupID)
            applyLocalPayment(event: event, groupID: payment.groupID)
            await syncGroup(id: payment.groupID)
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func syncGroup(id groupID: GroupID) async {
        guard !syncingGroupIDs.contains(groupID) else { return }
        syncingGroupIDs.insert(groupID)
        defer { syncingGroupIDs.remove(groupID) }

        do {
            try await postPendingOperations(for: groupID)
            try await fetchGroups()
            try await refreshExpenses(for: groupID)
            try await refreshPayments(for: groupID)
            try await pullRemoteEvents(for: groupID)
            try await refreshAuditEvents(for: groupID)
            try await refreshBalances(for: groupID)
            groupSyncStates[groupID] = GroupSyncState(lastSuccessfulSyncAt: Date())
            persist()
        } catch {
            registrationStatus = .failed(error.localizedDescription)
            var state = groupSyncStates[groupID] ?? GroupSyncState()
            state.lastSyncError = error.localizedDescription
            groupSyncStates[groupID] = state
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
            await syncAllGroups()
        }
    }

    func refreshGroups() async {
        do {
            try await fetchGroups()
        } catch {
            registrationStatus = .failed(error.localizedDescription)
        }
    }

    func syncAllGroups() async {
        if groups.isEmpty {
            await refreshGroups()
        }

        var syncedGroupIDs = Set<GroupID>()
        while true {
            let groupIDs = groups.map(\.id).filter { !syncedGroupIDs.contains($0) }
            guard !groupIDs.isEmpty else { break }

            for groupID in groupIDs {
                await syncGroup(id: groupID)
                syncedGroupIDs.insert(groupID)
            }
        }
    }

    private func fetchGroups() async throws {
        let serverGroups = try await apiClient.fetchGroups()
        applyServerGroups(serverGroups)
    }

    private func postPendingOperations(for groupID: GroupID) async throws {
        let operations = pendingOperations
            .filter { $0.groupID == groupID }
            .sorted { $0.event.clientSequence < $1.event.clientSequence }

        for operation in operations {
            let response = try await apiClient.postLedgerEvent(groupID: groupID, event: operation.event)
            applyCanonicalState(response, for: operation.event, groupID: groupID)
            acknowledgeOperation(id: operation.event.eventID, sequence: response.sequence)
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

            for event in response.events {
                let expenseID = event.entityID.map(ExpenseID.init(rawValue:))
                let paymentID = event.entityID.map(PaymentID.init(rawValue:))
                if let auditEntry = ExpenseAuditEntry(
                    groupID: groupID,
                    pulledEvent: event,
                    fallbackExpense: expenseID.flatMap { expenseID in expenses.first { $0.id == expenseID } }
                ) {
                    upsertAuditEntry(auditEntry)
                }
                if let paymentAuditEntry = PaymentAuditEntry(
                    groupID: groupID,
                    pulledEvent: event,
                    fallbackPayment: paymentID.flatMap { paymentID in payments.first { $0.id == paymentID } }
                ) {
                    upsertPaymentAuditEntry(paymentAuditEntry)
                }
            }

            let eventIDs = Set(response.events.map(\.eventID))
            pendingOperations.removeAll { $0.groupID == groupID && eventIDs.contains($0.event.eventID) }
            for eventID in eventIDs {
                acknowledgeOperation(id: eventID, sequence: response.events.first { $0.eventID == eventID }?.sequence)
            }
            persist()

            if !response.hasMore {
                break
            }
        }
    }

    private func refreshAuditEvents(for groupID: GroupID) async throws {
        var cursor = Int64(0)
        var refreshedEntries: [ExpenseAuditEntry] = []
        var refreshedPaymentEntries: [PaymentAuditEntry] = []

        while true {
            let response = try await apiClient.fetchGroupEvents(groupID: groupID, after: cursor)
            let entries = response.events.compactMap { event in
                let expenseID = event.entityID.map(ExpenseID.init(rawValue:))
                return ExpenseAuditEntry(
                    groupID: groupID,
                    pulledEvent: event,
                    fallbackExpense: expenseID.flatMap { expenseID in expenses.first { $0.id == expenseID } }
                )
            }
            let paymentEntries = response.events.compactMap { event in
                let paymentID = event.entityID.map(PaymentID.init(rawValue:))
                return PaymentAuditEntry(
                    groupID: groupID,
                    pulledEvent: event,
                    fallbackPayment: paymentID.flatMap { paymentID in payments.first { $0.id == paymentID } }
                )
            }
            refreshedEntries.append(contentsOf: entries)
            refreshedPaymentEntries.append(contentsOf: paymentEntries)

            guard let maxSequence = response.events.map(\.sequence).max() else { break }
            cursor = maxSequence

            if !response.hasMore {
                break
            }
        }

        let pendingEntries = auditEvents.filter { $0.groupID == groupID && $0.isPending }
        let pendingPaymentEntries = paymentAuditEvents.filter { $0.groupID == groupID && $0.isPending }

        if !refreshedEntries.isEmpty {
            auditEvents.removeAll { $0.groupID == groupID }
            auditEvents.append(contentsOf: deduplicatedAuditEvents(refreshedEntries + pendingEntries))
        }

        if !refreshedPaymentEntries.isEmpty {
            paymentAuditEvents.removeAll { $0.groupID == groupID }
            paymentAuditEvents.append(contentsOf: deduplicatedPaymentAuditEvents(refreshedPaymentEntries + pendingPaymentEntries))
        }

        persist()
    }

    private func refreshExpenses(for groupID: GroupID) async throws {
        let serverExpenses = try await apiClient.fetchExpenses(groupID: groupID)
        expenses.removeAll { $0.groupID == groupID }
        expenses.append(contentsOf: serverExpenses.map(ExpenseRecord.init(serverExpense:)))
    }

    private func refreshPayments(for groupID: GroupID) async throws {
        let serverPayments = try await apiClient.fetchPayments(groupID: groupID)
        payments.removeAll { $0.groupID == groupID }
        payments.append(contentsOf: serverPayments.map(PaymentRecord.init(serverPayment:)))
    }

    private func refreshBalances(for groupID: GroupID) async throws {
        let balances = try await apiClient.fetchBalances(groupID: groupID)
        groupBalances[groupID] = balances
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
    ) throws -> LedgerEventRequest {
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

        let payload = ExpensePayload(
            name: name,
            description: description,
            currencyCode: currencyCode,
            totalMinorUnits: totalMinorUnits,
            payerActorID: payerActorID,
            splitMethod: splitMethod,
            occurredAt: occurredAt,
            splits: splits
        )

        return LedgerEventRequest(
            eventID: .generate(),
            entityType: "expense",
            entityID: expenseID.rawValue,
            eventType: eventType.rawValue,
            actorID: group.localActorID,
            eventCreatedAt: Date(),
            clientSequence: allocateClientSequence(),
            baseSequence: baseSequence,
            payload: try JSONValue.fromEncodable(payload)
        )
    }

    private func makePaymentEvent(
        groupID: GroupID,
        paymentID: PaymentID,
        eventType: String,
        baseSequence: Int64,
        fromActorID: ActorID,
        toActorID: ActorID,
        currencyCode: String,
        amountMinorUnits: Int64,
        occurredAt: Date
    ) throws -> LedgerEventRequest {
        guard let group = groups.first(where: { $0.id == groupID }),
              group.actorIDs.contains(fromActorID),
              group.actorIDs.contains(toActorID),
              fromActorID != toActorID else {
            throw SplitStoreError.groupNotFound
        }

        let payload = PaymentPayload(
            fromActorID: fromActorID,
            toActorID: toActorID,
            currencyCode: currencyCode,
            amountMinorUnits: amountMinorUnits,
            occurredAt: occurredAt
        )

        return LedgerEventRequest(
            eventID: .generate(),
            entityType: "payment",
            entityID: paymentID.rawValue,
            eventType: eventType,
            actorID: group.localActorID,
            eventCreatedAt: Date(),
            clientSequence: allocateClientSequence(),
            baseSequence: baseSequence,
            payload: try JSONValue.fromEncodable(payload)
        )
    }

    private func makeVoidEvent(
        groupID: GroupID,
        entityType: String,
        entityID: String,
        eventType: String,
        baseSequence: Int64
    ) throws -> LedgerEventRequest {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw SplitStoreError.groupNotFound
        }

        return LedgerEventRequest(
            eventID: .generate(),
            entityType: entityType,
            entityID: entityID,
            eventType: eventType,
            actorID: group.localActorID,
            eventCreatedAt: Date(),
            clientSequence: allocateClientSequence(),
            baseSequence: baseSequence,
            payload: .object([:])
        )
    }

    private func makeGroupNameEvent(groupID: GroupID, name: String, baseSequence: Int64) throws -> LedgerEventRequest {
        guard let group = groups.first(where: { $0.id == groupID }) else {
            throw SplitStoreError.groupNotFound
        }

        return LedgerEventRequest(
            eventID: .generate(),
            entityType: "group",
            entityID: groupID.rawValue,
            eventType: "group.name_updated",
            actorID: group.localActorID,
            eventCreatedAt: Date(),
            clientSequence: allocateClientSequence(),
            baseSequence: baseSequence,
            payload: .object(["name": .string(name)])
        )
    }

    private func makeActorDisplayNameEvent(
        groupID: GroupID,
        actorID: ActorID,
        displayName: String,
        baseSequence: Int64
    ) throws -> LedgerEventRequest {
        guard let group = groups.first(where: { $0.id == groupID }), group.actorIDs.contains(actorID) else {
            throw SplitStoreError.groupNotFound
        }

        return LedgerEventRequest(
            eventID: .generate(),
            entityType: "actor",
            entityID: actorID.rawValue,
            eventType: "actor.display_name_updated",
            actorID: group.localActorID,
            eventCreatedAt: Date(),
            clientSequence: allocateClientSequence(),
            baseSequence: baseSequence,
            payload: .object(["display_name": .string(displayName)])
        )
    }

    private func allocateClientSequence() -> Int64 {
        let sequence = nextClientSequence
        nextClientSequence += 1
        persist()
        return sequence
    }

    private func enqueue(_ event: LedgerEventRequest, groupID: GroupID) {
        pendingOperations.append(PendingSyncOperation(groupID: groupID, event: event))
        let expenseID = event.entityType == "expense" ? ExpenseID(rawValue: event.entityID) : nil
        let paymentID = event.entityType == "payment" ? PaymentID(rawValue: event.entityID) : nil
        if let auditEntry = ExpenseAuditEntry(
            groupID: groupID,
            event: event,
            isPending: true,
            fallbackExpense: expenseID.flatMap { expenseID in expenses.first { $0.id == expenseID } }
        ) {
            upsertAuditEntry(auditEntry)
        }
        if let paymentAuditEntry = PaymentAuditEntry(
            groupID: groupID,
            event: event,
            isPending: true,
            fallbackPayment: paymentID.flatMap { paymentID in payments.first { $0.id == paymentID } }
        ) {
            upsertPaymentAuditEntry(paymentAuditEntry)
        }
        persist()
    }

    private func acknowledgeOperation(id eventID: EventID, sequence: Int64?) {
        pendingOperations.removeAll { $0.event.eventID == eventID }
        if let index = auditEvents.firstIndex(where: { $0.id == eventID }) {
            auditEvents[index].isPending = false
            auditEvents[index].sequence = sequence ?? auditEvents[index].sequence
        }
        if let index = paymentAuditEvents.firstIndex(where: { $0.id == eventID }) {
            paymentAuditEvents[index].isPending = false
            paymentAuditEvents[index].sequence = sequence ?? paymentAuditEvents[index].sequence
        }
        persist()
    }

    private func upsertAuditEntry(_ auditEntry: ExpenseAuditEntry) {
        if let index = auditEvents.firstIndex(where: { $0.id == auditEntry.id }) {
            auditEvents[index] = mergedAuditEntry(existing: auditEvents[index], incoming: auditEntry)
        } else {
            auditEvents.append(auditEntry)
        }
    }

    private func deduplicatedAuditEvents(_ entries: [ExpenseAuditEntry]) -> [ExpenseAuditEntry] {
        var entriesByID: [EventID: ExpenseAuditEntry] = [:]
        for entry in entries {
            if let existingEntry = entriesByID[entry.id] {
                entriesByID[entry.id] = mergedAuditEntry(existing: existingEntry, incoming: entry)
            } else {
                entriesByID[entry.id] = entry
            }
        }
        return Array(entriesByID.values)
    }

    private func upsertPaymentAuditEntry(_ auditEntry: PaymentAuditEntry) {
        if let index = paymentAuditEvents.firstIndex(where: { $0.id == auditEntry.id }) {
            paymentAuditEvents[index] = mergedPaymentAuditEntry(existing: paymentAuditEvents[index], incoming: auditEntry)
        } else {
            paymentAuditEvents.append(auditEntry)
        }
    }

    private func deduplicatedPaymentAuditEvents(_ entries: [PaymentAuditEntry]) -> [PaymentAuditEntry] {
        var entriesByID: [EventID: PaymentAuditEntry] = [:]
        for entry in entries {
            if let existingEntry = entriesByID[entry.id] {
                entriesByID[entry.id] = mergedPaymentAuditEntry(existing: existingEntry, incoming: entry)
            } else {
                entriesByID[entry.id] = entry
            }
        }
        return Array(entriesByID.values)
    }

    private func mergedAuditEntry(existing: ExpenseAuditEntry, incoming: ExpenseAuditEntry) -> ExpenseAuditEntry {
        var merged = incoming.isPending && !existing.isPending ? existing : incoming
        merged.sequence = incoming.sequence ?? existing.sequence
        merged.isPending = existing.isPending && incoming.isPending
        return merged
    }

    private func mergedPaymentAuditEntry(existing: PaymentAuditEntry, incoming: PaymentAuditEntry) -> PaymentAuditEntry {
        var merged = incoming.isPending && !existing.isPending ? existing : incoming
        merged.sequence = incoming.sequence ?? existing.sequence
        merged.isPending = existing.isPending && incoming.isPending
        return merged
    }

    private func applyLocalExpense(event: LedgerEventRequest, groupID: GroupID) {
        guard let eventType = ExpenseEventType(rawValue: event.eventType) else { return }

        let expenseID = ExpenseID(rawValue: event.entityID)
        if eventType == .voided || eventType == .deleted {
            guard let index = expenses.firstIndex(where: { $0.id == expenseID }) else { return }
            expenses[index].updatedAt = event.eventCreatedAt
            expenses[index].version = max(expenses[index].version, event.baseSequence)
            expenses[index].voidedAt = event.eventCreatedAt
            persist()
            return
        }

        guard let payload = event.expensePayload() else { return }
        let now = Date()
        let existingCreatedAt = expenses.first(where: { $0.id == expenseID })?.createdAt ?? now
        let expense = ExpenseRecord(
            id: expenseID,
            groupID: groupID,
            createdByActorID: event.actorID,
            payload: payload,
            createdAt: existingCreatedAt,
            updatedAt: now,
            version: event.baseSequence,
            voidedAt: eventType == .voided || eventType == .deleted ? event.eventCreatedAt : nil
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

    private func applyLocalPayment(event: LedgerEventRequest, groupID: GroupID) {
        let paymentID = PaymentID(rawValue: event.entityID)
        if event.eventType == "payment.voided" || event.eventType == "payment.deleted" {
            guard let index = payments.firstIndex(where: { $0.id == paymentID }) else { return }
            payments[index].updatedAt = event.eventCreatedAt
            payments[index].version = max(payments[index].version, event.baseSequence)
            payments[index].voidedAt = event.eventCreatedAt
            persist()
            return
        }

        guard let payload = event.paymentPayload() else { return }
        let now = Date()
        let existingCreatedAt = payments.first(where: { $0.id == paymentID })?.createdAt ?? now
        let payment = PaymentRecord(
            id: paymentID,
            groupID: groupID,
            createdByActorID: event.actorID,
            payload: payload,
            createdAt: existingCreatedAt,
            updatedAt: now,
            version: event.baseSequence,
            voidedAt: event.eventType == "payment.voided" || event.eventType == "payment.deleted" ? event.eventCreatedAt : nil
        )
        upsertPayment(payment)
        persist()
    }

    private func upsertPayment(_ payment: PaymentRecord) {
        if let index = payments.firstIndex(where: { $0.id == payment.id }) {
            payments[index] = payment
        } else {
            payments.append(payment)
        }
    }

    private func applyLocalGroupName(groupID: GroupID, name: String) {
        updateGroup(id: groupID) { group in
            group.name = name
        }
    }

    private func applyLocalActorDisplayName(actorID: ActorID, displayName: String) {
        guard let index = actors.firstIndex(where: { $0.id == actorID }) else { return }
        actors[index].displayName = displayName
        if actors[index].isLocal {
            self.displayName = displayName
        }
        persist()
    }

    private func applyCanonicalState(_ response: PostEventResponse, for event: LedgerEventRequest, groupID: GroupID) {
        if let pulledEvent = response.event {
            let expenseID = pulledEvent.entityID.map(ExpenseID.init(rawValue:))
            let paymentID = pulledEvent.entityID.map(PaymentID.init(rawValue:))
            if let auditEntry = ExpenseAuditEntry(
                groupID: groupID,
                pulledEvent: pulledEvent,
                fallbackExpense: expenseID.flatMap { expenseID in expenses.first { $0.id == expenseID } }
            ) {
                upsertAuditEntry(auditEntry)
            }
            if let paymentAuditEntry = PaymentAuditEntry(
                groupID: groupID,
                pulledEvent: pulledEvent,
                fallbackPayment: paymentID.flatMap { paymentID in payments.first { $0.id == paymentID } }
            ) {
                upsertPaymentAuditEntry(paymentAuditEntry)
            }
        }

        if let serverExpense = response.expense {
            upsertExpense(ExpenseRecord(serverExpense: serverExpense))
        }

        if let serverPayment = response.payment {
            upsertPayment(PaymentRecord(serverPayment: serverPayment))
        }

        if let serverGroup = response.group,
           let index = groups.firstIndex(where: { $0.id == serverGroup.id }) {
            groups[index].name = serverGroup.name
            groups[index].serverLatestEventSequence = max(
                groups[index].serverLatestEventSequence,
                serverGroup.latestEventSequence
            )
            groups[index].metadataVersion = serverGroup.metadataVersion
        }

        if let serverActor = response.actor,
           let group = groups.first(where: { $0.id == groupID }) {
            upsertActor(serverActor, isLocal: serverActor.id == group.localActorID)
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
            metadataVersion: serverGroup.metadataVersion,
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
                upsertLocalActor(
                    id: serverActor.id,
                    serverDisplayName: serverActor.displayName,
                    metadataVersion: serverActor.metadataVersion
                )
            } else {
                upsertRemoteActor(
                    id: serverActor.id,
                    displayName: serverActor.displayName,
                    metadataVersion: serverActor.metadataVersion
                )
            }
        }

        if !serverGroup.actors.contains(where: { $0.id == serverGroup.actorID }) {
            upsertLocalActor(id: serverGroup.actorID)
        }
    }

    private func upsertActor(_ serverActor: ServerActor, isLocal: Bool) {
        if isLocal {
            upsertLocalActor(
                id: serverActor.id,
                serverDisplayName: serverActor.displayName,
                metadataVersion: serverActor.metadataVersion
            )
        } else {
            upsertRemoteActor(
                id: serverActor.id,
                displayName: serverActor.displayName,
                metadataVersion: serverActor.metadataVersion
            )
        }
    }

    private func upsertRemoteActor(id actorID: ActorID, displayName: String?, metadataVersion: Int64? = nil) {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.flatMap { $0.isEmpty ? nil : $0 } ?? actorID.rawValue

        if let index = actors.firstIndex(where: { $0.id == actorID }) {
            guard !actors[index].isLocal else { return }
            actors[index].displayName = resolvedName
            actors[index].deviceID = nil
            if let metadataVersion {
                actors[index].metadataVersion = metadataVersion
            }
        } else {
            actors.append(Actor(
                id: actorID,
                displayName: resolvedName,
                deviceID: nil,
                isLocal: false,
                metadataVersion: metadataVersion ?? 0
            ))
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

    private func upsertLocalActor(
        id actorID: ActorID,
        serverDisplayName: String? = nil,
        metadataVersion: Int64? = nil
    ) {
        let serverName = serverDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = serverName.flatMap { $0.isEmpty ? nil : $0 } ?? displayName

        if let index = actors.firstIndex(where: { $0.id == actorID }) {
            actors[index].displayName = resolvedName
            actors[index].deviceID = deviceID
            if let metadataVersion {
                actors[index].metadataVersion = metadataVersion
            }
        } else {
            actors.append(Actor(
                id: actorID,
                displayName: resolvedName,
                deviceID: deviceID,
                isLocal: true,
                metadataVersion: metadataVersion ?? 0
            ))
        }
    }

    private func pruneUnusedActors() {
        let usedActorIDs = Set(groups.flatMap(\.actorIDs) + expenses.flatMap { $0.payload.splits.map(\.actorID) })
        actors.removeAll { !usedActorIDs.contains($0.id) }
    }

    private func persist() {
        auditEvents = deduplicatedAuditEvents(auditEvents)
        paymentAuditEvents = deduplicatedPaymentAuditEvents(paymentAuditEvents)

        do {
            let directoryURL = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let snapshot = SplitSnapshot(
                displayName: displayName,
                actors: actors,
                groups: groups,
                expenses: expenses,
                payments: payments,
                pendingOperations: pendingOperations,
                auditEvents: auditEvents,
                paymentAuditEvents: paymentAuditEvents,
                groupBalances: groupBalances,
                groupSyncStates: groupSyncStates,
                nextClientSequence: nextClientSequence
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to persist split state: \(error.localizedDescription)")
        }
    }
}
