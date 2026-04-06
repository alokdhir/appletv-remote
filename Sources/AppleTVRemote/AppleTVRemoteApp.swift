import SwiftUI

@main
struct AppleTVRemoteApp: App {
    @StateObject private var discovery = DeviceDiscovery()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
