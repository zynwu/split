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

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List {
                if let group {
                    Section("Join Code") {
                        Text(group.joinCode)
                            .font(.title2.monospaced())
                            .fontWeight(.semibold)
                    }

                    Section("Your Actor") {
                        LabeledContent("Actor ID", value: group.localActorID.rawValue)
                            .font(.caption)
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

                    Section("Members") {
                        ForEach(group.actorIDs, id: \.self) { actorID in
                            if let actor = store.actor(for: actorID) {
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
                    }
                } else {
                    Text("Group not found")
                        .foregroundStyle(.secondary)
                }
            }

            if group != nil {
                Button {
                    isShowingAddExpense = true
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 56)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .accessibilityLabel("Add expense")
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
                        splitMethod: .equal,
                        occurredAt: Date()
                    )
                }
                .presentationDetents([.large])
            }
        }
    }
}

private struct AddExpenseInput {
    let name: String
    let currencyCode: String
    let totalMinorUnits: Int64
    let payerActorID: ActorID
}

private struct AddExpenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount = ""
    @State private var currencyCode = "USD"
    @State private var payerActorRawValue: String
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

    private var canSubmit: Bool {
        !isSubmitting
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && totalMinorUnits != nil
            && selectedPayerID != nil
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
            payerActorID: selectedPayerID
        )

        Task {
            await createExpense(input)
            isSubmitting = false
            dismiss()
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
