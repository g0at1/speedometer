import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SystemMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        MenuBarExtra(
            "Speedometer",
            systemImage: "gauge.with.dots.needle.67percent"
        ) {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
