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
    private let discoveryInterval: TimeInterval = 300
    private var lastDiscoveryAt = Date.distantPast
    private var discoveryTask: Task<Void, Never>?
    private var refreshGeneration = 0

    private struct Probe {
        let mac: String
        let ip: String?
        let reachable: Bool?
    }

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
        refreshGeneration += 1
        devices.removeAll { $0.mac == mac }
        devices.append(Device(name: clean.isEmpty ? mac : clean, mac: mac, ip: (ip?.isEmpty ?? true) ? nil : ip))
        save()
        Task { await refresh() }
    }

    func remove(_ device: Device) {
        refreshGeneration += 1
        devices.removeAll { $0.mac == device.mac }
        status[device.mac] = nil
        save()
    }

    func contains(mac: String) -> Bool { devices.contains { $0.mac == mac } }

    // MARK: Status

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshot = devices
        let results = await probe(snapshot)
        guard generation == refreshGeneration else { return }
        apply(results)

        guard results.contains(where: { $0.reachable != true }),
              Date().timeIntervalSince(lastDiscoveryAt) >= discoveryInterval else { return }
        await discover()
        guard generation == refreshGeneration else { return }
        let updated = await probe(devices)
        guard generation == refreshGeneration else { return }
        apply(updated)
    }

    private func discover() async {
        if let discoveryTask {
            await discoveryTask.value
            return
        }
        let task = Task { await ARP.sweep() }
        discoveryTask = task
        await task.value
        discoveryTask = nil
        lastDiscoveryAt = Date()
    }

    private func probe(_ snapshot: [Device]) async -> [Probe] {
        let observed = Dictionary(grouping: ARP.table().entries, by: { $0.mac })
        return await withTaskGroup(of: Probe.self) { group in
            for device in snapshot {
                let observedIPs = observed[device.mac, default: []].map { $0.ip }
                var seen = Set<String>()
                let candidates = ([device.ip].compactMap { $0 } + observedIPs)
                    .filter { seen.insert($0).inserted }
                group.addTask {
                    for ip in candidates where await Ping.isReachable(ip) {
                        // An old DHCP address may now answer for a different computer.
                        let entries = ARP.table().entries.filter { $0.ip == ip }
                        if entries.isEmpty || entries.contains(where: { $0.mac == device.mac }) {
                            return Probe(mac: device.mac, ip: ip, reachable: true)
                        }
                    }
                    let ip = observedIPs.count == 1 ? observedIPs[0] : device.ip
                    return Probe(mac: device.mac, ip: ip, reachable: candidates.isEmpty ? nil : false)
                }
            }
            var results: [Probe] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private func apply(_ results: [Probe]) {
        var changed = false
        for result in results {
            guard let index = devices.firstIndex(where: { $0.mac == result.mac }) else { continue }
            if let ip = result.ip, ip != devices[index].ip {
                devices[index].ip = ip
                changed = true
            }
            switch (result.reachable, status[result.mac]) {
            case (true?, _):
                status[result.mac] = .online
            case (_, .waking(let since)?) where Date().timeIntervalSince(since) < wakeTimeout:
                break  // still booting – keep showing "Waking…"
            case (false?, _):
                status[result.mac] = .offline
            default:
                status[result.mac] = .unknown
            }
        }
        if changed { save() }
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
