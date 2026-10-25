import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var store: SplitStore
    @State private var displayName: String = ""
    @State private var isActionMenuExpanded = false
    @State private var activeGroupSheet: GroupActionSheet?
    @State private var isQuickMenuPresented = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                List {
                    Section("This Device") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Display name", text: $displayName)
                                .textInputAutocapitalization(.words)
                                .onSubmit(saveDisplayName)

                            Button("Save Display Name", action: saveDisplayName)
                                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    Section("Groups") {
                        if store.groups.isEmpty {
                            Text("No groups yet")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.groups) { group in
                                NavigationLink(value: group.id) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.name)
                                        Text("\(group.actorIDs.count) members")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await store.syncAllGroups()
                }
                .navigationTitle("Split")
                .navigationDestination(for: GroupID.self) { groupID in
                    GroupDetailView(store: store, groupID: groupID)
                }
                .onAppear {
                    displayName = store.displayName
                }
                .onChange(of: store.displayName) { _, updatedName in
                    displayName = updatedName
                }

                GroupActionButton(
                    isExpanded: $isActionMenuExpanded,
                    createGroup: showCreateGroupSheet,
                    joinGroup: showJoinGroupSheet
                )
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .sheet(item: $activeGroupSheet) { sheet in
                switch sheet {
                case .create:
                    CreateGroupSheet { name in
                        await store.createGroup(named: name)
                    }
                    .presentationDetents([.medium])
                case .join:
                    JoinGroupSheet { joinCode in
                        await store.joinGroup(with: joinCode)
                    }
                    .presentationDetents([.medium])
                }
            }
        }
        .overlay {
            ShakeDetector {
                guard !isQuickMenuPresented else { return }
                isQuickMenuPresented = true
            }
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $isQuickMenuPresented) {
            QuickMenuView(store: store) {
                isQuickMenuPresented = false
            }
        }
    }

    private func saveDisplayName() {
        store.setLocalDisplayName(displayName)
        displayName = store.displayName
    }

    private func showCreateGroupSheet() {
        isActionMenuExpanded = false
        activeGroupSheet = .create
    }

    private func showJoinGroupSheet() {
        isActionMenuExpanded = false
        activeGroupSheet = .join
    }

}

private struct ShakeDetector: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeDetectingView {
        let view = ShakeDetectingView()
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeDetectingView, context: Context) {
        uiView.onShake = onShake
    }
}

private final class ShakeDetectingView: UIView {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            onShake?()
        }
    }
}

private struct QuickMenuView: View {
    let store: SplitStore
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AppSettingsView(store: store, onReset: onClose)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("Quick Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

private struct AppSettingsView: View {
    let store: SplitStore
    let onReset: () -> Void
    @AppStorage(DeviceIDStorageKey.deviceID) private var storedDeviceID = ""

    var body: some View {
        List {
            Section("This Device") {
                LabeledContent("Registration", value: store.registrationStatus.label)
                    .font(.caption)
                LabeledContent("Device ID", value: storedDeviceID.isEmpty ? "Not registered" : storedDeviceID)
                    .font(.caption)
                LabeledContent("API", value: APIConfiguration.baseURL.absoluteString)
                    .font(.caption)
            }

            Section("Advanced") {
                NavigationLink {
                    ResetDeviceConfirmationView(store: store, onReset: onReset)
                } label: {
                    Label("Reset This Device", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ResetDeviceConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    let store: SplitStore
    let onReset: () -> Void
    @State private var isResetting = false
    @State private var resetError: String?

    var body: some View {
        List {
            Section {
                Text("This removes the data and credentials saved by Split on this device.")
            }

            Section("Will Be Cleared") {
                Label("Saved groups, expenses, and payments", systemImage: "externaldrive")
                Label("Pending unsynced changes", systemImage: "arrow.triangle.2.circlepath")
                Label("This device's ID and API credentials", systemImage: "key")
            }

            Section("Will Stay on the Server") {
                Text("Shared groups and expenses already synced to the server are not deleted. This device will register again, and you may need to rejoin your groups.")
            }

            Section {
                Button(role: .destructive, action: resetThisDevice) {
                    HStack {
                        Spacer()
                        Text(isResetting ? "Resetting…" : "Reset This Device")
                        Spacer()
                    }
                }
                .disabled(isResetting)
            }
        }
        .navigationTitle("Reset Device")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't Reset This Device", isPresented: Binding(
            get: { resetError != nil },
            set: { if !$0 { resetError = nil } }
        )) {
            Button("OK", role: .cancel) { resetError = nil }
        } message: {
            Text(resetError ?? "Please try again.")
        }
    }

    private func resetThisDevice() {
        isResetting = true
        Task {
            do {
                try await store.resetLocalData()
                isResetting = false
                dismiss()
                onReset()
            } catch {
                isResetting = false
                resetError = error.localizedDescription
            }
        }
    }
}

private enum GroupActionSheet: Identifiable {
    case create
    case join

    var id: String {
        switch self {
        case .create:
            "create"
        case .join:
            "join"
        }
    }
}

private struct GroupActionButton: View {
    @Binding var isExpanded: Bool
    let createGroup: () -> Void
    let joinGroup: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isExpanded {
                VStack(alignment: .trailing, spacing: 10) {
                    Button(action: createGroup) {
                        Label("Create Group", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect()

                    Button(action: joinGroup) {
                        Label("Join Group", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "xmark" : "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(isExpanded ? "Close group actions" : "Open group actions")
        }
    }
}

private struct CreateGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var isCreating = false
    let createGroup: (String) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Name", text: $groupName)
                        .textInputAutocapitalization(.words)
                        .onSubmit(create)
                }
            }
            .navigationTitle("Create Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isCreating)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating" : "Create", action: create)
                        .disabled(isCreating || groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func create() {
        let name = groupName
        isCreating = true

        Task {
            await createGroup(name)
            isCreating = false
            dismiss()
        }
    }
}

private struct JoinGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var joinCode = ""
    @State private var isJoining = false
    let joinGroup: (String) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Join Code") {
                    TextField("Code", text: $joinCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit(join)
                }
            }
            .navigationTitle("Join Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isJoining)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isJoining ? "Joining" : "Join", action: join)
                        .disabled(isJoining || joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func join() {
        guard !isJoining else { return }
        let code = joinCode
        isJoining = true

        Task {
            await joinGroup(code)
            isJoining = false
            dismiss()
        }
    }
}

private struct GroupDetailView: View {
    @Bindable var store: SplitStore
    let groupID: GroupID
    @State private var isGroupActionMenuExpanded = false
    @State private var activeGroupDetailSheet: GroupDetailSheet?
    @State private var isShowingEditGroupName = false
    @State private var selectedTab: GroupDetailTab = .balances

    private var group: ExpenseGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var groupActors: [Actor] {
        guard let group else { return [] }
        return group.actorIDs.compactMap { store.actor(for: $0) }
    }

    private var groupExpenses: [ExpenseRecord] {
        store.expenses(for: groupID)
    }

    private var groupPaymentAuditEvents: [PaymentAuditEntry] {
        store.paymentAuditEvents(for: groupID)
    }

    private var groupAuditEvents: [ExpenseAuditEntry] {
        store.auditEvents(for: groupID)
    }

    private var balanceNotice: BalanceNotice? {
        guard group != nil else { return nil }

        let syncState = store.syncState(for: groupID)
        let pendingCount = store.pendingOperationCount(for: groupID)
        let hasBalanceSnapshot = store.balances(for: groupID) != nil

        if pendingCount > 0 {
            let changeWord = pendingCount == 1 ? "change" : "changes"
            let message = syncState.lastSyncError != nil
                ? "Balances may be out of date. Server sync did not complete; \(pendingCount) offline \(changeWord) are waiting to sync."
                : "Balances may be out of date. \(pendingCount) offline \(changeWord) are waiting to sync."
            return BalanceNotice(message: message, lastSyncedAt: syncState.lastSuccessfulSyncAt)
        }

        if syncState.lastSyncError != nil {
            return BalanceNotice(
                message: "Balances may be out of date. Server sync did not complete.",
                lastSyncedAt: syncState.lastSuccessfulSyncAt
            )
        }

        if !hasBalanceSnapshot {
            return BalanceNotice(
                message: "Balances are unavailable offline. Reconnect to calculate them.",
                lastSyncedAt: nil
            )
        }

        if syncState.lastSuccessfulSyncAt == nil {
            return BalanceNotice(
                message: "Balances may be out of date. Reconnect to verify them.",
                lastSyncedAt: nil
            )
        }

        return nil
    }

    private var activityRows: [GroupActivityRow] {
        let expenseRows = groupAuditEvents.map(GroupActivityRow.expense)
        let paymentRows = groupPaymentAuditEvents.map(GroupActivityRow.payment)
        return (expenseRows + paymentRows).sorted { lhs, rhs in
            if lhs.occurredAt == rhs.occurredAt {
                return lhs.id > rhs.id
            }
            return lhs.occurredAt > rhs.occurredAt
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .balances:
                    balancesList
                case .activity:
                    activityList
                }
            }
            .safeAreaPadding(.bottom, 96)

            if group != nil {
                VStack(spacing: 14) {
                    HStack {
                        Spacer()
                        GroupDetailActionButton(
                            isExpanded: $isGroupActionMenuExpanded,
                            recordPayment: showRecordPaymentSheet,
                            addExpense: showAddExpenseSheet
                        )
                    }

                    GroupDetailTabSlider(selectedTab: $selectedTab)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle(group?.name ?? "Group")
        .toolbar {
            if group != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingEditGroupName = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Edit group name")
                }
            }
        }
        .task(id: groupID) {
            await store.syncGroup(id: groupID)
        }
        .sheet(item: $activeGroupDetailSheet) { sheet in
            if let group {
                switch sheet {
                case .recordPayment:
                    RecordPaymentSheet(group: group, actors: groupActors) { input in
                        await store.createPayment(
                            in: group.id,
                            fromActorID: input.fromActorID,
                            toActorID: input.toActorID,
                            currencyCode: input.currencyCode,
                            amountMinorUnits: input.amountMinorUnits,
                            occurredAt: Date()
                        )
                    }
                    .presentationDetents([.medium])
                case .addExpense:
                    AddExpenseSheet(group: group, actors: groupActors) { input in
                        await store.createExpense(
                            in: group.id,
                            name: input.name,
                            description: "",
                            currencyCode: input.currencyCode,
                            totalMinorUnits: input.totalMinorUnits,
                            payerActorID: input.payerActorID,
                            splitMethod: input.splitMethod,
                            manualSplits: input.manualSplits,
                            occurredAt: Date()
                        )
                    }
                    .presentationDetents([.large])
                }
            }
        }
        .sheet(isPresented: $isShowingEditGroupName) {
            if let group {
                EditGroupNameSheet(group: group) { name in
                    let splitStore = store
                    await splitStore.updateGroupName(in: group.id, to: name)
                }
                .presentationDetents([.medium])
            }
        }

    }

    private var balancesList: some View {
        List {
            if let group {
                Section("Join Code") {
                    Text(group.joinCode)
                        .font(.title2.monospaced())
                        .fontWeight(.semibold)
                }

                Section(balanceNotice == nil ? "Balances" : "Balances*") {
                    if let balanceNotice {
                        BalanceSyncNoticeView(notice: balanceNotice)
                    }

                    if let balances = store.balances(for: groupID), !balances.currencyBalances.isEmpty {
                        ForEach(balances.currencyBalances) { currencyBalance in
                            ForEach(currencyBalance.suggestedTransfers.filter { transfer in
                                transfer.fromActorID == balances.currentActorID || transfer.toActorID == balances.currentActorID
                            }) { transfer in
                                SuggestedTransferRow(
                                    transfer: transfer,
                                    currentActorID: balances.currentActorID,
                                    currencyCode: currencyBalance.currencyCode,
                                    fromName: balanceActorName(
                                        transfer.fromActorID,
                                        currencyBalance: currencyBalance
                                    ),
                                    toName: balanceActorName(
                                        transfer.toActorID,
                                        currencyBalance: currencyBalance
                                    )
                                )
                            }
                        }

                        if !balances.currencyBalances.contains(where: { currencyBalance in
                            currencyBalance.suggestedTransfers.contains { transfer in
                                transfer.fromActorID == balances.currentActorID || transfer.toActorID == balances.currentActorID
                            }
                        }) {
                            Text("You're settled up")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No transfers yet")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Members") {
                    ForEach(group.actorIDs, id: \.self) { actorID in
                        if let actor = store.actor(for: actorID) {
                            NavigationLink {
                                MemberDetailView(store: store, groupID: group.id, actorID: actor.id)
                            } label: {
                                MemberRow(actor: actor)
                            }
                        }
                    }
                }
            } else {
                Text("Group not found")
                    .foregroundStyle(.secondary)
            }
        }
        .refreshable {
            await store.syncGroup(id: groupID)
        }
    }

    private func balanceActorName(_ actorID: ActorID, currencyBalance: CurrencyBalance) -> String {
        if let displayName = store.actor(for: actorID)?.displayName, !displayName.isEmpty {
            return displayName
        }

        if let displayName = currencyBalance.memberBalances.first(where: { $0.actorID == actorID })?.displayName,
           !displayName.isEmpty {
            return displayName
        }

        return actorID.rawValue
    }

    private func showRecordPaymentSheet() {
        isGroupActionMenuExpanded = false
        activeGroupDetailSheet = .recordPayment
    }

    private func showAddExpenseSheet() {
        isGroupActionMenuExpanded = false
        activeGroupDetailSheet = .addExpense
    }

    private var activityList: some View {
        List {
            Section("Activity") {
                if activityRows.isEmpty {
                    Text("No activity yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activityRows) { row in
                        switch row {
                        case .expense(let auditEvent):
                            if store.expense(id: auditEvent.expenseID) != nil {
                                NavigationLink {
                                    ExpenseDetailView(store: store, expenseID: auditEvent.expenseID)
                                } label: {
                                    AuditEventRow(auditEvent: auditEvent, actor: store.actor(for: auditEvent.actorID))
                                }
                            } else {
                                AuditEventRow(auditEvent: auditEvent, actor: store.actor(for: auditEvent.actorID))
                                    .padding(.trailing, 24)
                            }
                        case .payment(let paymentAuditEvent):
                            if store.payment(id: paymentAuditEvent.paymentID) != nil {
                                NavigationLink {
                                    PaymentDetailView(store: store, paymentID: paymentAuditEvent.paymentID)
                                } label: {
                                    PaymentRow(
                                        auditEvent: paymentAuditEvent,
                                        fromActor: store.actor(for: paymentAuditEvent.fromActorID),
                                        toActor: store.actor(for: paymentAuditEvent.toActorID)
                                    )
                                }
                            } else {
                                PaymentRow(
                                    auditEvent: paymentAuditEvent,
                                    fromActor: store.actor(for: paymentAuditEvent.fromActorID),
                                    toActor: store.actor(for: paymentAuditEvent.toActorID)
                                )
                                .padding(.trailing, 24)
                            }
                        }
                    }
                }
            }

        }
        .refreshable {
            await store.syncGroup(id: groupID)
        }
    }
}

private struct BalanceNotice {
    let message: String
    let lastSyncedAt: Date?
}

private struct BalanceSyncNoticeView: View {
    let notice: BalanceNotice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.message)

                if let lastSyncedAt = notice.lastSyncedAt {
                    Text("Last synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened)). Pull to refresh after reconnecting.")
                } else {
                    Text("Pull to refresh after reconnecting.")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .padding(.vertical, 4)
    }
}

private enum GroupActivityRow: Identifiable {
    case expense(ExpenseAuditEntry)
    case payment(PaymentAuditEntry)

    var id: String {
        switch self {
        case .expense(let auditEvent):
            "expense-\(auditEvent.id.rawValue)"
        case .payment(let paymentAuditEvent):
            "payment-\(paymentAuditEvent.id.rawValue)"
        }
    }

    var occurredAt: Date {
        switch self {
        case .expense(let auditEvent):
            auditEvent.eventCreatedAt
        case .payment(let paymentAuditEvent):
            paymentAuditEvent.eventCreatedAt
        }
    }
}

private enum GroupDetailSheet: String, Identifiable {
    case recordPayment
    case addExpense

    var id: String { rawValue }
}

private struct GroupDetailActionButton: View {
    @Binding var isExpanded: Bool
    let recordPayment: () -> Void
    let addExpense: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isExpanded {
                VStack(alignment: .trailing, spacing: 10) {
                    Button(action: recordPayment) {
                        Label("Record Payment", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect()

                    Button(action: addExpense) {
                        Label("Add Expense", systemImage: "receipt")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .glassEffect()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "xmark" : "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(isExpanded ? "Close group actions" : "Open group actions")
        }
    }
}

private enum GroupDetailTab: String, CaseIterable, Identifiable {
    case balances = "Balances"
    case activity = "Activity"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .balances:
            "person.2"
        case .activity:
            "list.bullet.rectangle"
        }
    }
}

private struct GroupDetailTabSlider: View {
    @Binding var selectedTab: GroupDetailTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(GroupDetailTab.allCases) { tab in
                Button {
                    withAnimation(.snappy) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        .background {
                            if selectedTab == tab {
                                Capsule()
                                    .fill(.white.opacity(0.24))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct SuggestedTransferRow: View {
    let transfer: SuggestedTransfer
    let currentActorID: ActorID
    let currencyCode: String
    let fromName: String
    let toName: String

    private var isOutgoing: Bool {
        transfer.fromActorID == currentActorID
    }

    private var counterpartyName: String {
        isOutgoing ? toName : fromName
    }

    private var title: String {
        isOutgoing ? "You owe \(counterpartyName)" : "\(counterpartyName) owes you"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(isOutgoing ? "Suggested payment" : "Suggested reimbursement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(MoneyText.display(transfer.amountMinorUnits, currencyCode: currencyCode))
                .font(.body.monospacedDigit())
                .foregroundStyle(isOutgoing ? .red : .green)
        }
    }
}

private struct MemberRow: View {
    let actor: Actor

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(actor.displayName)
                if actor.isLocal {
                    Text("Local actor for this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if actor.isLocal {
                Image(systemName: "iphone")
                    .foregroundStyle(.secondary)
            }

        }
    }
}

private struct MemberDetailView: View {
    @Bindable var store: SplitStore
    let groupID: GroupID
    let actorID: ActorID
    @State private var isConfirmingCommandeering = false
    @State private var isShowingEditName = false

    private var group: ExpenseGroup? {
        store.groups.first { $0.id == groupID }
    }

    private var actor: Actor? {
        store.actor(for: actorID)
    }

    private var isLocalActor: Bool {
        guard let group else { return false }
        return group.localActorID == actorID
    }

    private var canCommandeer: Bool {
        guard let group else { return false }
        return group.localActorID != actorID
    }

    var body: some View {
        List {
            if let actor {
                Section("Member") {
                    LabeledContent("Name", value: actor.displayName)
                    LabeledContent("Actor ID", value: actor.id.rawValue)
                    if actor.isLocal {
                        LabeledContent("Device", value: "This device")
                    }
                }

                if isLocalActor {
                    Section {
                        Button {
                            isShowingEditName = true
                        } label: {
                            Label("Edit Name", systemImage: "pencil")
                        }
                    }
                }

                if canCommandeer {
                    Section {
                        Button(role: .destructive) {
                            isConfirmingCommandeering = true
                        } label: {
                            Label("Use This Actor", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                }
            } else {
                Text("Member not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(actor?.displayName ?? "Member")
        .sheet(isPresented: $isShowingEditName) {
            if let actor {
                EditActorDisplayNameSheet(actor: actor) { displayName in
                    await store.updateActorDisplayName(in: groupID, actorID: actor.id, to: displayName)
                }
                .presentationDetents([.medium])
            }
        }
        .alert("Use \(actor?.displayName ?? "this actor")?", isPresented: $isConfirmingCommandeering) {
            Button("Use This Actor", role: .destructive) {
                Task {
                    await store.commandeerActor(in: groupID, targetActorID: actorID)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This merges your current actor into this member for the group.")
        }
    }
}

private struct PaymentRow: View {
    let auditEvent: PaymentAuditEntry
    let fromActor: Actor?
    let toActor: Actor?

    private var title: String {
        switch auditEvent.eventType {
        case "payment.created":
            "Created payment"
        case "payment.updated":
            "Updated payment"
        case "payment.voided":
            "Voided payment"
        case "payment.deleted":
            "Deleted payment"
        default:
            "Payment event"
        }
    }

    private var isVoided: Bool {
        auditEvent.eventType == "payment.voided" || auditEvent.eventType == "payment.deleted"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if isVoided {
                    Text("Removed from balances")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(fromActor?.displayName ?? "Unknown") paid \(toActor?.displayName ?? "Unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(isVoided ? " " : MoneyText.display(auditEvent.amountMinorUnits, currencyCode: auditEvent.currencyCode))
                    .font(.body.monospacedDigit())
                    .accessibilityHidden(isVoided)

                if auditEvent.isPending {
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let sequence = auditEvent.sequence {
                    Text("#\(sequence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
    }
}

private struct AuditEventRow: View {
    let auditEvent: ExpenseAuditEntry
    let actor: Actor?

    private var title: String {
        switch auditEvent.eventType {
        case .created:
            "Created \(auditEvent.expenseName)"
        case .updated:
            "Updated \(auditEvent.expenseName)"
        case .voided:
            "Voided \(auditEvent.expenseName)"
        case .deleted:
            "Deleted \(auditEvent.expenseName)"
        }
    }

    private var isVoided: Bool {
        auditEvent.eventType == .voided || auditEvent.eventType == .deleted
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if isVoided {
                    Text("Removed from balances")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(actor?.displayName ?? auditEvent.actorID.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(isVoided ? " " : MoneyText.display(auditEvent.totalMinorUnits, currencyCode: auditEvent.currencyCode))
                    .font(.body.monospacedDigit())
                    .accessibilityHidden(isVoided)

                if auditEvent.isPending {
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let sequence = auditEvent.sequence {
                    Text("#\(sequence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        }
    }
}

private struct EditGroupNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    let group: ExpenseGroup
    let saveName: (String) async -> Void

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(group: ExpenseGroup, saveName: @escaping (String) async -> Void) {
        self.group = group
        self.saveName = saveName
        self._name = State(initialValue: group.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group Name") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .onSubmit(save)
                }
            }
            .navigationTitle("Edit Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await saveName(cleanName)
            isSaving = false
            dismiss()
        }
    }
}

private struct EditActorDisplayNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var isSaving = false

    let actor: Actor
    let saveDisplayName: (String) async -> Void

    private var canSave: Bool {
        !isSaving && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(actor: Actor, saveDisplayName: @escaping (String) async -> Void) {
        self.actor = actor
        self.saveDisplayName = saveDisplayName
        self._displayName = State(initialValue: actor.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display Name") {
                    TextField("Name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .onSubmit(save)
                }
            }
            .navigationTitle("Edit Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await saveDisplayName(cleanName)
            isSaving = false
            dismiss()
        }
    }
}

private struct RecordPaymentInput {
    let fromActorID: ActorID
    let toActorID: ActorID
    let currencyCode: String
    let amountMinorUnits: Int64
}

private struct RecordPaymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var currencyCode = "USD"
    @State private var fromActorRawValue: String
    @State private var toActorRawValue: String
    @State private var isSubmitting = false
    @State private var isConfirmingDelete = false

    let group: ExpenseGroup
    let actors: [Actor]
    let title: String
    let deletePayment: (() async -> Void)?
    let recordPayment: (RecordPaymentInput) async -> Void

    private var selectedFromActorID: ActorID? {
        ActorID(rawValue: fromActorRawValue)
    }

    private var selectedToActorID: ActorID? {
        ActorID(rawValue: toActorRawValue)
    }

    private var amountMinorUnits: Int64? {
        MoneyText.minorUnits(from: amount)
    }

    private var canSubmit: Bool {
        !isSubmitting
            && amountMinorUnits != nil
            && amountMinorUnits != 0
            && selectedFromActorID != nil
            && selectedToActorID != nil
            && selectedFromActorID != selectedToActorID
    }

    init(
        group: ExpenseGroup,
        actors: [Actor],
        payment: PaymentRecord? = nil,
        title: String = "Record Payment",
        deletePayment: (() async -> Void)? = nil,
        recordPayment: @escaping (RecordPaymentInput) async -> Void
    ) {
        self.group = group
        self.actors = actors
        self.title = title
        self.deletePayment = deletePayment
        self.recordPayment = recordPayment

        let fromActorID = payment?.payload.fromActorID ?? group.localActorID
        let toActorID = payment?.payload.toActorID ?? actors.first { $0.id != fromActorID }?.id ?? fromActorID
        self._amount = State(initialValue: payment.map { MoneyText.inputText($0.payload.amountMinorUnits) } ?? "")
        self._currencyCode = State(initialValue: payment?.payload.currencyCode ?? "USD")
        self._fromActorRawValue = State(initialValue: fromActorID.rawValue)
        self._toActorRawValue = State(initialValue: toActorID.rawValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Payment") {
                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)

                    TextField("Currency", text: $currencyCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Members") {
                    Picker("From", selection: $fromActorRawValue) {
                        ForEach(actors) { actor in
                            Text(actor.displayName).tag(actor.id.rawValue)
                        }
                    }

                    Picker("To", selection: $toActorRawValue) {
                        ForEach(actors) { actor in
                            Text(actor.displayName).tag(actor.id.rawValue)
                        }
                    }

                    if selectedFromActorID == selectedToActorID {
                        Text("Choose two different members.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if deletePayment != nil {
                    Section {
                        Button("Delete Payment", role: .destructive) {
                            isConfirmingDelete = true
                        }
                        .disabled(isSubmitting)
                    } footer: {
                        Text("This removes the payment from balances while keeping it in the activity history.")
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Saving" : "Save", action: submit)
                        .disabled(!canSubmit)
                }
            }
            .alert("Delete this payment?", isPresented: $isConfirmingDelete) {
                Button("Delete Payment", role: .destructive) {
                    delete()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action cannot be undone, but the deletion will remain in the activity history.")
            }
        }
    }

    private func delete() {
        guard !isSubmitting, let deletePayment else { return }
        isSubmitting = true

        Task {
            await deletePayment()
            isSubmitting = false
            dismiss()
        }
    }

    private func submit() {
        guard canSubmit,
              let selectedFromActorID,
              let selectedToActorID,
              let amountMinorUnits else { return }
        isSubmitting = true

        let input = RecordPaymentInput(
            fromActorID: selectedFromActorID,
            toActorID: selectedToActorID,
            currencyCode: currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            amountMinorUnits: amountMinorUnits
        )

        Task {
            await recordPayment(input)
            isSubmitting = false
            dismiss()
        }
    }
}

private struct AddExpenseInput {
    let name: String
    let currencyCode: String
    let totalMinorUnits: Int64
    let payerActorID: ActorID
    let splitMethod: SplitMethod
    let manualSplits: [ExpenseSplit]?
}

private struct AddExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount = ""
    @State private var currencyCode = "USD"
    @State private var payerActorRawValue: String
    @State private var splitMethod: SplitMethod = .equal
    @State private var includedActorIDs: Set<ActorID>
    @State private var manualSplitAmounts: [ActorID: String] = [:]
    @State private var isSubmitting = false
    @State private var isConfirmingDelete = false

    let group: ExpenseGroup
    let actors: [Actor]
    let title: String
    let deleteExpense: (() async -> Void)?
    let createExpense: (AddExpenseInput) async -> Void

    private var selectedPayerID: ActorID? {
        ActorID(rawValue: payerActorRawValue)
    }

    private var totalMinorUnits: Int64? {
        MoneyText.minorUnits(from: amount)
    }

    private var manualSplits: [ExpenseSplit]? {
        guard splitMethod == .manual, let totalMinorUnits else { return nil }
        let splits = actors.map { actor in
            if includedActorIDs.contains(actor.id) {
                let amountText = manualSplitAmounts[actor.id] ?? ""
                guard !amountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let amount = MoneyText.minorUnits(from: amountText) else {
                    return ExpenseSplit(actorID: actor.id, amountMinorUnits: nil)
                }
                return ExpenseSplit(actorID: actor.id, amountMinorUnits: amount)
            }

            return ExpenseSplit(actorID: actor.id, amountMinorUnits: 0)
        }

        guard splits.allSatisfy({ $0.amountMinorUnits != nil }) else { return nil }
        let splitTotal = splits.reduce(Int64(0)) { total, split in
            total + (split.amountMinorUnits ?? 0)
        }
        return splitTotal == totalMinorUnits ? splits : nil
    }

    private var canSubmit: Bool {
        let hasValidRequiredFields = !isSubmitting
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && totalMinorUnits != nil
            && selectedPayerID != nil

        if splitMethod == .manual {
            return hasValidRequiredFields && manualSplits != nil
        }

        return hasValidRequiredFields
    }

    init(
        group: ExpenseGroup,
        actors: [Actor],
        expense: ExpenseRecord? = nil,
        title: String = "Add Expense",
        deleteExpense: (() async -> Void)? = nil,
        createExpense: @escaping (AddExpenseInput) async -> Void
    ) {
        self.group = group
        self.actors = actors
        self.title = title
        self.deleteExpense = deleteExpense
        self.createExpense = createExpense
        self._name = State(initialValue: expense?.payload.name ?? "")
        self._amount = State(initialValue: expense.map { MoneyText.inputText($0.payload.totalMinorUnits) } ?? "")
        self._currencyCode = State(initialValue: expense?.payload.currencyCode ?? "USD")
        self._payerActorRawValue = State(initialValue: expense?.payload.payerActorID.rawValue ?? group.localActorID.rawValue)
        self._splitMethod = State(initialValue: expense?.payload.splitMethod ?? .equal)

        let includedActorIDs = expense?.payload.splitMethod == .manual
            ? Set(expense?.payload.splits.filter { ($0.amountMinorUnits ?? 0) != 0 }.map(\.actorID) ?? [])
            : Set(actors.map(\.id))
        self._includedActorIDs = State(initialValue: includedActorIDs)

        let manualSplitAmounts = Dictionary(uniqueKeysWithValues: expense?.payload.splits.compactMap { split -> (ActorID, String)? in
            guard let amount = split.amountMinorUnits, amount != 0 else { return nil }
            return (split.actorID, MoneyText.inputText(amount))
        } ?? [])
        self._manualSplitAmounts = State(initialValue: manualSplitAmounts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Expense") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .onSubmit(submit)

                    TextField("Amount", text: $amount)
                        .keyboardType(.decimalPad)
                }

                Section("Details") {
                    TextField("Currency", text: $currencyCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()

                    Picker("Paid by", selection: $payerActorRawValue) {
                        ForEach(actors) { actor in
                            Text(actor.displayName).tag(actor.id.rawValue)
                        }
                    }

                    Picker("Split", selection: $splitMethod) {
                        Text("Equal").tag(SplitMethod.equal)
                        Text("Manual").tag(SplitMethod.manual)
                    }
                    .pickerStyle(.segmented)
                }

                if splitMethod == .manual {
                    Section("Manual Splits") {
                        ForEach(actors) { actor in
                            ManualSplitRow(
                                actor: actor,
                                isIncluded: includedActorIDs.contains(actor.id),
                                amount: manualSplitAmounts[actor.id] ?? "",
                                toggleIncluded: { toggleActor(actor.id) },
                                updateAmount: { manualSplitAmounts[actor.id] = $0 }
                            )
                        }

                        if let totalMinorUnits, manualSplits == nil {
                            Text("Manual splits must add up to \(MoneyText.display(totalMinorUnits, currencyCode: currencyCode.uppercased())).")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                if deleteExpense != nil {
                    Section {
                        Button("Delete Expense", role: .destructive) {
                            isConfirmingDelete = true
                        }
                        .disabled(isSubmitting)
                    } footer: {
                        Text("This removes the expense from balances while keeping it in the activity history.")
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Saving" : "Save", action: submit)
                        .disabled(!canSubmit)
                }
            }
            .alert("Delete this expense?", isPresented: $isConfirmingDelete) {
                Button("Delete Expense", role: .destructive) {
                    delete()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action cannot be undone, but the deletion will remain in the activity history.")
            }
        }
    }

    private func delete() {
        guard !isSubmitting, let deleteExpense else { return }
        isSubmitting = true

        Task {
            await deleteExpense()
            isSubmitting = false
            dismiss()
        }
    }

    private func submit() {
        guard canSubmit, let totalMinorUnits, let selectedPayerID else { return }
        isSubmitting = true

        let input = AddExpenseInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            currencyCode: currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            totalMinorUnits: totalMinorUnits,
            payerActorID: selectedPayerID,
            splitMethod: splitMethod,
            manualSplits: splitMethod == .manual ? manualSplits : nil
        )

        Task {
            await createExpense(input)
            isSubmitting = false
            dismiss()
        }
    }

    private func toggleActor(_ actorID: ActorID) {
        if includedActorIDs.contains(actorID) {
            includedActorIDs.remove(actorID)
            manualSplitAmounts[actorID] = nil
        } else {
            includedActorIDs.insert(actorID)
        }
    }
}

private struct ManualSplitRow: View {
    let actor: Actor
    let isIncluded: Bool
    let amount: String
    let toggleIncluded: () -> Void
    let updateAmount: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleIncluded) {
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isIncluded ? "Exclude \(actor.displayName)" : "Include \(actor.displayName)")

            Text(actor.displayName)

            Spacer()

            if isIncluded {
                TextField("0.00", text: Binding(get: { amount }, set: updateAmount))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
                    .font(.body.monospacedDigit())
            }
        }
    }
}

private struct PaymentDetailView: View {
    @Bindable var store: SplitStore
    let paymentID: PaymentID
    @State private var isShowingEditPayment = false

    private var payment: PaymentRecord? {
        store.payment(id: paymentID)
    }

    private var group: ExpenseGroup? {
        guard let payment else { return nil }
        return store.groups.first { $0.id == payment.groupID }
    }

    private var groupActors: [Actor] {
        guard let group else { return [] }
        return group.actorIDs.compactMap { store.actor(for: $0) }
    }

    var body: some View {
        List {
            if let payment {
                Section("Payment") {
                    LabeledContent("Amount", value: MoneyText.display(payment.payload.amountMinorUnits, currencyCode: payment.payload.currencyCode))
                    LabeledContent("From", value: store.actor(for: payment.payload.fromActorID)?.displayName ?? payment.payload.fromActorID.rawValue)
                    LabeledContent("To", value: store.actor(for: payment.payload.toActorID)?.displayName ?? payment.payload.toActorID.rawValue)

                    if store.isPaymentPending(id: payment.id) {
                        LabeledContent("Ledger", value: "Pending")
                    } else if payment.version > 0 {
                        LabeledContent("Ledger", value: "#\(payment.version)")
                    }
                }
            } else {
                Text("Payment not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Payment")
        .toolbar {
            if payment != nil && group != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        isShowingEditPayment = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingEditPayment) {
            if let payment, let group {
                RecordPaymentSheet(
                    group: group,
                    actors: groupActors,
                    payment: payment,
                    title: "Edit Payment",
                    deletePayment: {
                        await store.voidPayment(id: payment.id)
                    }
                ) { input in
                    await store.updatePayment(
                        id: payment.id,
                        fromActorID: input.fromActorID,
                        toActorID: input.toActorID,
                        currencyCode: input.currencyCode,
                        amountMinorUnits: input.amountMinorUnits
                    )
                }
                .presentationDetents([.medium])
            }
        }
    }
}

private struct ExpenseDetailView: View {
    @Bindable var store: SplitStore
    let expenseID: ExpenseID
    @State private var isShowingEditExpense = false

    private var expense: ExpenseRecord? {
        store.expense(id: expenseID)
    }

    private var group: ExpenseGroup? {
        guard let expense else { return nil }
        return store.groups.first { $0.id == expense.groupID }
    }

    private var groupActors: [Actor] {
        guard let group else { return [] }
        return group.actorIDs.compactMap { store.actor(for: $0) }
    }

    private var isForeignCurrency: Bool {
        guard let expense else { return false }
        return expense.payload.currencyCode.uppercased() != "USD"
    }

    private var shouldShowUSDSplits: Bool {
        guard let expense else { return false }
        return isForeignCurrency && expense.payload.splitMethod == .manual
    }

    private var includedSplits: [ExpenseSplit] {
        guard let expense else { return [] }
        return expense.payload.splits.filter { split in
            (split.amountMinorUnits ?? 0) != 0 || (shouldShowUSDSplits && (split.usdAmountMinorUnits ?? 0) != 0)
        }
    }

    private var formattedExchangeRate: String? {
        guard let expense,
              isForeignCurrency,
              let exchangeRate = expense.exchangeRateToUSD,
              let decimal = Decimal(string: exchangeRate) else { return nil }

        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        formatter.numberStyle = .decimal
        return formatter.string(from: NSDecimalNumber(decimal: decimal))
    }

    var body: some View {
        List {
            if let expense {
                Section("Expense") {
                    LabeledContent("Name", value: expense.payload.name)
                    LabeledContent("Total", value: MoneyText.display(expense.payload.totalMinorUnits, currencyCode: expense.payload.currencyCode))
                    if isForeignCurrency {
                        if let formattedExchangeRate {
                            LabeledContent("USD Rate", value: formattedExchangeRate)
                        }
                        if let usdTotalMinorUnits = expense.usdTotalMinorUnits {
                            LabeledContent("USD Total", value: MoneyText.display(usdTotalMinorUnits, currencyCode: "USD"))
                        }
                    }
                    LabeledContent("Paid by", value: store.actor(for: expense.payload.payerActorID)?.displayName ?? expense.payload.payerActorID.rawValue)
                }

                Section("Splits") {
                    if includedSplits.isEmpty {
                        Text("No split amounts yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(includedSplits) { split in
                            HStack {
                                Text(store.actor(for: split.actorID)?.displayName ?? split.actorID.rawValue)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    if shouldShowUSDSplits, let usdAmountMinorUnits = split.usdAmountMinorUnits {
                                        Text(MoneyText.display(usdAmountMinorUnits, currencyCode: "USD"))
                                            .font(.body.monospacedDigit())
                                        if let amountMinorUnits = split.amountMinorUnits {
                                            Text(MoneyText.display(amountMinorUnits, currencyCode: expense.payload.currencyCode))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text(MoneyText.display(split.amountMinorUnits ?? 0, currencyCode: expense.payload.currencyCode))
                                            .font(.body.monospacedDigit())
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text("Expense not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(expense?.payload.name ?? "Expense")
        .toolbar {
            if expense != nil && group != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        isShowingEditExpense = true
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingEditExpense) {
            if let expense, let group {
                AddExpenseSheet(
                    group: group,
                    actors: groupActors,
                    expense: expense,
                    title: "Edit Expense",
                    deleteExpense: {
                        await store.voidExpense(id: expense.id)
                    }
                ) { input in
                    await store.updateExpense(
                        id: expense.id,
                        name: input.name,
                        description: "",
                        currencyCode: input.currencyCode,
                        totalMinorUnits: input.totalMinorUnits,
                        payerActorID: input.payerActorID,
                        splitMethod: input.splitMethod,
                        manualSplits: input.manualSplits
                    )
                }
                .presentationDetents([.large])
            }
        }
    }
}

private struct ExpenseRow: View {
    let expense: ExpenseRecord
    let payer: Actor?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(expense.payload.name)
                Text("Paid by \(payer?.displayName ?? "Unknown")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(MoneyText.display(expense.payload.totalMinorUnits, currencyCode: expense.payload.currencyCode))
                .font(.body.monospacedDigit())
        }
    }
}

private enum MoneyText {
    static func minorUnits(from text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutCurrencySymbol = trimmed.hasPrefix("$") ? String(trimmed.dropFirst()) : trimmed
        let parts = withoutCurrencySymbol.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let major = parseDigits(parts.first.map(String.init) ?? "") else { return nil }

        let minorText = parts.count == 2 ? String(parts[1]) : ""
        guard minorText.count <= 2, let minor = parseDigits(minorText.padding(toLength: 2, withPad: "0", startingAt: 0)) else { return nil }

        return major * 100 + minor
    }

    static func display(_ minorUnits: Int64, currencyCode: String) -> String {
        let sign = minorUnits < 0 ? "-" : ""
        let major = abs(minorUnits / 100)
        let minor = abs(minorUnits % 100)
        return "\(currencyCode) \(sign)\(major).\(String(format: "%02lld", minor))"
    }

    static func inputText(_ minorUnits: Int64) -> String {
        let major = minorUnits / 100
        let minor = abs(minorUnits % 100)
        return "\(major).\(String(format: "%02lld", minor))"
    }

    private static func parseDigits(_ text: String) -> Int64? {
        guard !text.isEmpty else { return 0 }
        var result = Int64(0)

        for character in text {
            guard let digit = character.wholeNumberValue else { return nil }
            result = result * 10 + Int64(digit)
        }

        return result
    }
}

#Preview {
    ContentView(store: SplitStore(storageURL: URL.temporaryDirectory.appending(path: "split-preview-state.json")))
}
