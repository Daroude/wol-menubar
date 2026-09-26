import SwiftUI
import AppKit

// MARK: - Menu bar panel

struct MenuPanel: View {
    @EnvironmentObject var store: DeviceStore
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Wake on LAN").font(.headline)
                Spacer()
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh status")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if store.devices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No computers yet").foregroundStyle(.secondary)
                    Text("Add one while it is switched on, and it is found automatically.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(store.devices) { DeviceRow(device: $0) }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }

            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if let error = store.storageError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                PanelButton(title: "Add Computer…", icon: "plus") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "add")
                }
                Toggle(isOn: $launchAtLogin) { Text("Launch at Login") }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .onChange(of: launchAtLogin) { updateLaunchAtLogin($0) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                PanelButton(title: "Quit", icon: "xmark.circle") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 300)
        .task { await store.refresh() }
    }

    private func updateLaunchAtLogin(_ requested: Bool) {
        guard requested != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.set(requested)
            launchAtLogin = LaunchAtLogin.isEnabled
            loginError = launchAtLogin == requested ? nil : "Approve Launch at Login in System Settings."
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            loginError = "Could not change Launch at Login: \(error.localizedDescription)"
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var store: DeviceStore
    let device: Device
    @State private var hovering = false

    private var status: DeviceStatus { store.status[device.mac] ?? .unknown }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .waking = status {
                ProgressView().controlSize(.small)
            } else if status != .online {
                WakeButton { store.wake(device) }
            }
            Menu {
                Button("Wake Up") { store.wake(device) }
                Button("Copy MAC Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(device.mac, forType: .string)
                }
                Divider()
                Button("Remove", role: .destructive) { store.remove(device) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var color: Color {
        switch status {
        case .online: return .green
        case .waking: return .orange
        default: return .secondary.opacity(0.5)
        }
    }

    private var subtitle: String {
        let ip = device.ip ?? "no IP known"
        switch status {
        case .online: return "Online · \(ip)"
        case .offline: return "Offline · \(ip)"
        case .waking: return "Waking… · \(ip)"
        case .unknown: return device.ip == nil ? "Status unknown · \(device.mac)" : "Checking… · \(ip)"
        }
    }
}

/// Round, solid power button; brightens and grows slightly on hover.
struct WakeButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
                .brightness(hovering ? 0.08 : 0)
                .scaleEffect(hovering ? 1.08 : 1)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Wake up")
        .accessibilityLabel("Wake up")
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Add window

struct AddDeviceView: View {
    @EnvironmentObject var store: DeviceStore
    enum Mode: String, CaseIterable { case network = "From Network", manual = "Manually" }
    @State private var mode: Mode = .network

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding([.horizontal, .top], 16).padding(.bottom, 10)

            if let error = store.storageError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }

            switch mode {
            case .network: NetworkAddView()
            case .manual: ManualAddView()
            }
        }
        .frame(width: 480, height: 440)
    }
}

private func closeAddWindow() {
    NSApp.windows.first { $0.title == "Add Computer" }?.close()
}

struct NetworkAddView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var entries: [NeighborEntry] = []
    @State private var selection: NeighborEntry.ID?
    @State private var name = ""
    @State private var scanning = false

    private var selected: NeighborEntry? { entries.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The computer has to be switched on to show up here. If it has both Ethernet and Wi-Fi, it is listed twice – pick the **wired** one, Wake-on-LAN rarely works over Wi-Fi.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(entries, selection: $selection) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.shortName ?? "Unknown device").fontWeight(.medium)
                        Text("\(e.ip) · \(e.mac)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.contains(mac: e.mac) {
                        Text("Added").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(e.id)
            }
            .overlay {
                if scanning && entries.isEmpty {
                    ProgressView("Scanning the network…")
                } else if entries.isEmpty {
                    // macOS hides the ARP table from apps without Local Network access.
                    VStack(spacing: 6) {
                        Text("No devices found").font(.headline)
                        Text("Make sure “WOL Menubar” is allowed in System Settings → Privacy & Security → Local Network, then scan again.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }
                    }
                    .padding(30)
                }
            }
            .onChange(of: selection) { _ in name = selected?.shortName ?? "" }

            HStack {
                Button { Task { await scan() } } label: {
                    Label(scanning ? "Scanning…" : "Scan Again", systemImage: "arrow.clockwise")
                }
                .disabled(scanning)
                Spacer()
                TextField("Name", text: $name).frame(width: 150)
                Button("Add") {
                    guard let e = selected else { return }
                    if store.add(name: name, mac: e.mac, ip: e.ip) { closeAddWindow() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding([.horizontal, .bottom], 16)
        .task { await scan() }
    }

    private func scan() async {
        scanning = true
        entries = await ARP.neighbors(resolveNames: false)  // instant list from the ARP cache
        entries = await ARP.neighbors(resolveNames: true)   // then with hostnames
        await ARP.sweep()                                     // then nudge the rest of the subnet
        entries = await ARP.neighbors(resolveNames: true)
        scanning = false
    }
}

struct ManualAddView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var name = ""
    @State private var mac = ""
    @State private var ip = ""

    private var validMAC: String? { MAC.normalize(mac) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use this for a computer that is switched off right now. You find the MAC address of its Ethernet port in its network settings (Linux: `ip link`, Windows: `ipconfig /all`).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("Gaming PC"))
                TextField("MAC address", text: $mac, prompt: Text("aa:bb:cc:dd:ee:ff"))
                if !mac.isEmpty && validMAC == nil {
                    Text("That does not look like a MAC address.").font(.caption).foregroundStyle(.red)
                }
                TextField("IP address", text: $ip, prompt: Text("optional – for the online status"))
            }
            Spacer()
            HStack {
                Spacer()
                Button("Add") {
                    guard let m = validMAC else { return }
                    if store.add(name: name, mac: m, ip: ip) { closeAddWindow() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validMAC == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding([.horizontal, .bottom], 16)
    }
}
