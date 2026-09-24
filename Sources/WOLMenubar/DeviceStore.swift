import Foundation
import SwiftUI

struct Device: Identifiable, Hashable {
    var id: String { mac }
    var name: String
    var mac: String
    var ip: String?
}

enum DeviceStatus: Equatable {
    case unknown, online, offline
    case waking(since: Date)
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status: [String: DeviceStatus] = [:]
    @Published var lastError: String?

    /// Plain text, one device per line: `name|mac|ip` — easy to edit or back up by hand.
    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wol-menubar/devices")

    private var timer: Timer?
    private let wakeTimeout: TimeInterval = 180

    var anyOnline: Bool { status.values.contains(.online) }

    init() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    // MARK: Persistence

    func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { devices = []; return }
        devices = text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let mac = MAC.normalize(f[1]) else { return nil }
            let ip = f.count > 2 && !f[2].isEmpty ? f[2] : nil
            return Device(name: f[0], mac: mac, ip: ip)
        }
    }

    private func save() {
        let text = devices.map { "\($0.name)|\($0.mac)|\($0.ip ?? "")" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: Editing

    func add(name: String, mac: String, ip: String?) {
        guard let mac = MAC.normalize(mac) else { return }
        let clean = name.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = ip?.trimmingCharacters(in: .whitespaces)
        devices.removeAll { $0.mac == mac }
        devices.append(Device(name: clean.isEmpty ? mac : clean, mac: mac, ip: (ip?.isEmpty ?? true) ? nil : ip))
        save()
        Task { await refresh() }
    }

    func remove(_ device: Device) {
        devices.removeAll { $0.mac == device.mac }
        status[device.mac] = nil
        save()
    }

    func contains(mac: String) -> Bool { devices.contains { $0.mac == mac } }

    // MARK: Status

    func refresh() async {
        // Follow DHCP: take the current IP for each MAC from the ARP cache.
        let neighbors = await ARP.neighbors(resolveNames: false)
        var changed = false
        for i in devices.indices {
            if let n = neighbors.first(where: { $0.mac == devices[i].mac }), n.ip != devices[i].ip {
                devices[i].ip = n.ip
                changed = true
            }
        }
        if changed { save() }

        let snapshot = devices
        let results = await withTaskGroup(of: (String, Bool?).self) { group in
            for d in snapshot {
                group.addTask {
                    guard let ip = d.ip else { return (d.mac, nil) }
                    return (d.mac, await Ping.isReachable(ip))
                }
            }
            var r: [String: Bool?] = [:]
            for await (mac, up) in group { r[mac] = up }
            return r
        }
        for (mac, up) in results {
            switch (up, status[mac]) {
            case (true?, _):
                status[mac] = .online
            case (_, .waking(let since)?) where Date().timeIntervalSince(since) < wakeTimeout:
                break  // still booting – keep showing "Waking…"
            case (false?, _):
                status[mac] = .offline
            default:
                status[mac] = .unknown
            }
        }
    }

    func wake(_ device: Device) {
        do {
            try MagicPacket.send(to: device.mac)
            lastError = nil
            status[device.mac] = .waking(since: Date())
        } catch {
            lastError = "Could not send the magic packet. Is this Mac on the local network, and is “Local Network” access allowed in System Settings → Privacy & Security?"
            return
        }
        // Poll more often while it boots.
        Task {
            let start = Date()
            while Date().timeIntervalSince(start) < wakeTimeout {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await refresh()
                if status[device.mac] == .online { break }
            }
            await refresh()
        }
    }
}
