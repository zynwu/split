import SwiftUI

struct ContentView: View {
    @Bindable var store: SplitStore
    @State private var displayName: String = ""
    @State private var newGroupName: String = ""
    @State private var isCreatingGroup = false

    var body: some View {
        NavigationStack {
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
                    LabeledContent("Device ID", value: store.deviceID?.rawValue ?? "Not registered")
                        .font(.caption)
                    LabeledContent("API", value: APIConfiguration.baseURL.absoluteString)
                        .font(.caption)
                }

                Section("Groups") {
                    HStack {
                        TextField("New group", text: $newGroupName)
                            .textInputAutocapitalization(.words)
                            .onSubmit(createGroup)

                        Button(isCreatingGroup ? "Adding" : "Add", action: createGroup)
                            .disabled(isCreatingGroup || newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

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
        }
    }

    private func saveDisplayName() {
        store.setLocalDisplayName(displayName)
        displayName = store.displayName
    }

    private func createGroup() {
        let groupName = newGroupName
        isCreatingGroup = true

        Task {
            await store.createGroup(named: groupName)
            newGroupName = ""
            isCreatingGroup = false
        }
    }

    private func deleteGroups(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            store.removeGroup(id: store.groups[index].id)
        }
    }
}

private struct GroupDetailView: View {
    @Bindable var store: SplitStore
    let groupID: GroupID

    private var group: ExpenseGroup? {
        store.groups.first { $0.id == groupID }
    }

    var body: some View {
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
        .navigationTitle(group?.name ?? "Group")
    }

}

#Preview {
    ContentView(store: SplitStore(storageURL: URL.temporaryDirectory.appending(path: "split-preview-state.json")))
}
