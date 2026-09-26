import SwiftUI
import AppKit
import ServiceManagement

@main
struct WOLMenubarApp: App {
    @StateObject private var store = DeviceStore()

    init() {
        // Diagnostics: `open -a "WOL Menubar" --env WOL_SELFTEST=/path/report.txt`
        // runs a network scan with the app's own permissions, writes a report and quits.
        if let path = ProcessInfo.processInfo.environment["WOL_SELFTEST"] {
            Task { await SelfTest.run(reportTo: path); exit(0) }
        }
        NotchGuard.placeDefault()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(store)
        } label: {
            Image(nsImage: StatusIcon.image())
        }
        .menuBarExtraStyle(.window)

        Window("Add Computer", id: "add") {
            AddDeviceView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar icon: a desktop computer. Online status is shown in the panel, not here.
enum StatusIcon {
    static func image() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "WOL Menubar")!
            .withSymbolConfiguration(config)!
        symbol.isTemplate = true  // adapts to light/dark menu bar
        return symbol
    }
}

/// macOS inserts a new menu bar item at the far left of the status area. On a MacBook with a notch
/// and a busy menu bar, that is behind the notch, so the icon is invisible. On first launch this
/// places the item right of the notch, next to the other icons. Once the user moves it (⌘-drag),
/// AppKit stores the new position under the same key and it is kept.
enum NotchGuard {
    /// AppKit's own key: the item's distance from the right screen edge.
    private static let positionKey = "NSStatusItem Preferred Position Item-0"

    static func placeDefault() {
        guard UserDefaults.standard.object(forKey: positionKey) == nil,
              let screen = NSScreen.screens.first, screen.safeAreaInsets.top > 0,
              let rightOfNotch = screen.auxiliaryTopRightArea, rightOfNotch.width > 0 else { return }
        UserDefaults.standard.set((rightOfNotch.width * 0.4).rounded(), forKey: positionKey)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
