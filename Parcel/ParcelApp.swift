import SwiftUI

@main
struct ParcelApp: App {
    @StateObject private var store = ServerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
