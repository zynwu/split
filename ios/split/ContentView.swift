import SwiftUI

struct ContentView: View {
    @Bindable var store: SplitStore
    @AppStorage(DeviceIDStorageKey.deviceID) private var storedDeviceID = ""
    @State private var displayName: String = ""
    @State private var isActionMenuExpanded = false
    @State private var activeGroupSheet: GroupActionSheet?

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

                        LabeledContent("Registration", value: store.registrationStatus.label)
                            .font(.caption)
                        LabeledContent("Device ID", value: storedDeviceID.isEmpty ? "Not registered" : storedDeviceID)
                            .font(.caption)
                        LabeledContent("API", value: APIConfiguration.baseURL.absoluteString)
                            .font(.caption)
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
                            .onDelete(perform: deleteGroups)
                        }
                    }
                }
                .navigationTitle("Split")
                .navigationDestination(for: GroupID.self) { groupID in
                    GroupDetailView(store: store, groupID: groupID)
                }
                .onAppear {
                    displayName = store.displayName
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

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            store.removeGroup(id: store.groups[index].id)
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
    @State private var isShowingAddExpense = false
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

    private var groupAuditEvents: [ExpenseAuditEntry] {
        store.auditEvents(for: groupID)
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
                        Button {
                            isShowingAddExpense = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2.weight(.semibold))
                                .frame(width: 56, height: 56)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Add expense")
                    }

                    GroupDetailTabSlider(selectedTab: $selectedTab)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle(group?.name ?? "Group")
        .task(id: groupID) {
            await store.syncGroup(id: groupID)
        }
        .sheet(isPresented: $isShowingAddExpense) {
            if let group {
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

    private var balancesList: some View {
        List {
            if let group {
                Section("Join Code") {
                    Text(group.joinCode)
                        .font(.title2.monospaced())
                        .fontWeight(.semibold)
                }

                Section("Balances") {
                    if let balances = store.balances(for: groupID), !balances.currencyBalances.isEmpty {
                        ForEach(balances.currencyBalances) { currencyBalance in
                            ForEach(currencyBalance.memberBalances) { memberBalance in
                                BalanceRow(
                                    memberBalance: memberBalance,
                                    currencyCode: currencyBalance.currencyCode,
                                    actor: store.actor(for: memberBalance.actorID)
                                )
                            }
                        }
                    } else {
                        Text("No balances yet")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Members") {
                    ForEach(group.actorIDs, id: \.self) { actorID in
                        if let actor = store.actor(for: actorID) {
                            MemberRow(actor: actor)
                        }
                    }
                }
            } else {
                Text("Group not found")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activityList: some View {
        List {
            Section("Activity") {
                if groupAuditEvents.isEmpty {
                    Text("No activity yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupAuditEvents) { auditEvent in
                        AuditEventRow(auditEvent: auditEvent, actor: store.actor(for: auditEvent.actorID))
                    }
                }
            }

            Section("Expenses") {
                if groupExpenses.isEmpty {
                    Text("No expenses yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupExpenses) { expense in
                        ExpenseRow(expense: expense, payer: store.actor(for: expense.payload.payerActorID))
                    }
                }
            }
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

private struct BalanceRow: View {
    let memberBalance: BalanceMember
    let currencyCode: String
    let actor: Actor?

    private var name: String {
        actor?.displayName.isEmpty == false ? actor?.displayName ?? memberBalance.displayName : memberBalance.displayName
    }

    private var status: String {
        if memberBalance.netMinorUnits > 0 {
            "Gets back"
        } else if memberBalance.netMinorUnits < 0 {
            "Owes"
        } else {
            "Settled"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name.isEmpty ? memberBalance.actorID.rawValue : name)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(MoneyText.display(memberBalance.netMinorUnits, currencyCode: currencyCode))
                .font(.body.monospacedDigit())
                .foregroundStyle(memberBalance.netMinorUnits < 0 ? .red : .primary)
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
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(actor?.displayName ?? auditEvent.actorID.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(MoneyText.display(auditEvent.totalMinorUnits, currencyCode: auditEvent.currencyCode))
                    .font(.body.monospacedDigit())

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

    let group: ExpenseGroup
    let actors: [Actor]
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
        createExpense: @escaping (AddExpenseInput) async -> Void
    ) {
        self.group = group
        self.actors = actors
        self.createExpense = createExpense
        self._payerActorRawValue = State(initialValue: group.localActorID.rawValue)
        self._includedActorIDs = State(initialValue: Set(actors.map(\.id)))
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
            }
            .navigationTitle("Add Expense")
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
        let major = minorUnits / 100
        let minor = abs(minorUnits % 100)
        return "\(currencyCode) \(major).\(String(format: "%02lld", minor))"
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
