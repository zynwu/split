import SwiftUI

struct ContentView: View {
    @Bindable var store: SplitStore
    @State private var displayName: String = ""
    @State private var newGroupName: String = ""

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

                    LabeledContent("Device ID", value: store.deviceID.rawValue)
                        .font(.caption)
                    LabeledContent("Actor ID", value: store.localActorID.rawValue)
                        .font(.caption)
                }

                Section("Groups") {
                    HStack {
                        TextField("New group", text: $newGroupName)
                            .textInputAutocapitalization(.words)
                            .onSubmit(createGroup)

                        Button("Add", action: createGroup)
                            .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                displayName = store.localActor.displayName
            }
        }
    }

    private func saveDisplayName() {
        store.setLocalDisplayName(displayName)
        displayName = store.localActor.displayName
    }

    private func createGroup() {
        store.createGroup(named: newGroupName)
        newGroupName = ""
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
    @State private var actorName: String = ""

    private var group: ExpenseGroup? {
        store.groups.first { $0.id == groupID }
    }

    var body: some View {
        List {
            if let group {
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
                    .onDelete { offsets in
                        removeActors(at: offsets, from: group)
                    }
                }

                Section("Add Member") {
                    HStack {
                        TextField("Display name", text: $actorName)
                            .textInputAutocapitalization(.words)
                            .onSubmit(addActor)

                        Button("Add", action: addActor)
                            .disabled(actorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                Text("Group not found")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(group?.name ?? "Group")
    }

    private func addActor() {
        store.addActor(named: actorName, to: groupID)
        actorName = ""
    }

    private func removeActors(at offsets: IndexSet, from group: ExpenseGroup) {
        for index in offsets.sorted(by: >) {
            store.removeActor(group.actorIDs[index], from: group.id)
        }
    }
}

#Preview {
    ContentView(store: SplitStore(storageURL: URL.temporaryDirectory.appending(path: "split-preview-state.json")))
}
