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
    @Published private(set) var storageError: String?

    /// Plain text, one device per line: `name|mac|ip` — easy to edit or back up by hand.
    let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/wol-menubar/devices")

    private var timer: Timer?
    private let wakeTimeout: TimeInterval = 180
    private let discoveryInterval: TimeInterval = 300
    private var lastDiscoveryAt = Date.distantPast
    private var discoveryTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var storageAvailable = true

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
        do {
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            var loaded: [Device] = []
            var seen = Set<String>()
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.isEmpty { continue }
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard (2...3).contains(fields.count), let mac = MAC.normalize(fields[1]),
                      seen.insert(mac).inserted else {
                    throw StorageIssue.invalidLine(index + 1)
                }
                let ip = fields.count == 3 && !fields[2].isEmpty ? fields[2] : nil
                loaded.append(Device(name: fields[0], mac: mac, ip: ip))
            }
            devices = loaded
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o700],
                                      ofItemAtPath: fileURL.deletingLastPathComponent().path)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            storageAvailable = true
            storageError = nil
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                devices = []
                return
            }
            storageAvailable = false
            if case StorageIssue.invalidLine(let line) = error {
                storageError = "Device file has an invalid or duplicate entry on line \(line). Fix it and restart the app; no changes will be saved until then."
            } else {
                storageError = "Could not read the device file: \(error.localizedDescription). No changes will be saved."
            }
        }
    }

    private enum StorageIssue: Error { case invalidLine(Int) }

    @discardableResult
    private func save(_ updated: [Device]) -> Bool {
        guard storageAvailable else { return false }
        let text = updated.map { "\($0.name)|\($0.mac)|\($0.ip ?? "")" }.joined(separator: "\n") + "\n"
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: Data(),
                                         attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            storageError = nil
            return true
        } catch {
            storageError = "Could not save the device file: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Editing

    @discardableResult
    func add(name: String, mac: String, ip: String?) -> Bool {
        guard storageAvailable else { return false }
        guard let mac = MAC.normalize(mac) else { return false }
        let clean = name.replacingOccurrences(of: "|", with: "")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = ip?.trimmingCharacters(in: .whitespaces)
        guard ip?.contains(where: { $0 == "|" || $0.isNewline }) != true else {
            storageError = "The IP address must be on one line and cannot contain '|'."
            return false
        }
        var updated = devices.filter { $0.mac != mac }
        updated.append(Device(name: clean.isEmpty ? mac : clean, mac: mac, ip: (ip?.isEmpty ?? true) ? nil : ip))
        guard save(updated) else { return false }
        refreshGeneration += 1
        devices = updated
        Task { await refresh() }
        return true
    }

    func remove(_ device: Device) {
        let updated = devices.filter { $0.mac != device.mac }
        guard save(updated) else { return }
        refreshGeneration += 1
        devices = updated
        status[device.mac] = nil
    }

    func contains(mac: String) -> Bool { devices.contains { $0.mac == mac } }

    // MARK: Status

    func refresh(allowDiscovery: Bool = false) async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let snapshot = devices
        let results = await probe(snapshot)
        guard generation == refreshGeneration else { return }
        apply(results)

        let wakingNeedsDiscovery = results.contains { result in
            guard result.reachable != true, let current = status[result.mac] else { return false }
            if case .waking = current { return true }
            return false
        }
        guard (allowDiscovery || wakingNeedsDiscovery),
              results.contains(where: { $0.reachable != true }),
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
        var updated = devices
        for result in results {
            guard let index = updated.firstIndex(where: { $0.mac == result.mac }) else { continue }
            if let ip = result.ip, ip != updated[index].ip {
                updated[index].ip = ip
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
        if changed && save(updated) { devices = updated }
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
