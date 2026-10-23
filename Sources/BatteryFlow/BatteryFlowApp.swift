import SwiftUI
import AppKit

@main
struct BatteryFlowApp: App {
    @StateObject private var power = PowerManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16.5, weight: .semibold)
        let img = NSImage(systemSymbolName: "bolt.shield.fill", accessibilityDescription: "BatteryFlow")?.withSymbolConfiguration(config) ?? NSImage()
        img.isTemplate = true
        return img
    }
}
