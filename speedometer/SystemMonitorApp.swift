import SwiftUI

@main
struct SystemMonitorApp: App {
    var body: some Scene {
        MenuBarExtra("Monitor", image: "monitorIcon") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
