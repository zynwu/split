import SwiftUI

@main
struct splitApp: App {
    @State private var store = SplitStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .task {
                    await store.prepareForLaunch()
                }
        }
    }
}
