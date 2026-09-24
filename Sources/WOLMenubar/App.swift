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
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(store)
        } label: {
            Image(nsImage: StatusIcon.image(online: store.anyOnline))
        }
        .menuBarExtraStyle(.window)

        Window("Add Computer", id: "add") {
            AddDeviceView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar icon: a desktop computer, with a green dot while at least one device is online.
enum StatusIcon {
    static func image(online: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let symbol = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "WOL Menubar")!
            .withSymbolConfiguration(config)!
        guard online else {
            symbol.isTemplate = true  // adapts to light/dark menu bar
            return symbol
        }
        let size = NSSize(width: symbol.size.width + 3, height: max(symbol.size.height, 16))
        let img = NSImage(size: size, flipped: false) { rect in
            // Drawn at display time, so labelColor matches the current menu bar appearance.
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            NSColor.labelColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: 0, y: (rect.height - symbol.size.height) / 2,
                                   width: symbol.size.width, height: symbol.size.height))
            let d: CGFloat = 7
            let dot = NSRect(x: rect.width - d, y: 0.5, width: d, height: d)
            NSColor.clear.set()
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login: \(error)")
        }
    }
}
