import Foundation
import Darwin

// MARK: - MAC addresses

enum MAC {
    /// Normalises "B0-F2-8-F5-CF-ED", "b0f208f5cfed" or "b0:f2:8:f5:cf:ed" to "b0:f2:08:f5:cf:ed".
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: ":")
        if s.count == 12, !s.contains(":") {
            s = stride(from: 0, to: 12, by: 2).map { i -> String in
                let a = s.index(s.startIndex, offsetBy: i)
                return String(s[a..<s.index(a, offsetBy: 2)])
            }.joined(separator: ":")
        }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var out: [String] = []
        for p in parts {
            guard (1...2).contains(p.count), let v = UInt8(p, radix: 16) else { return nil }
            out.append(String(format: "%02x", v))
        }
        return out.joined(separator: ":")
    }

    static func bytes(_ mac: String) -> [UInt8]? {
        guard let n = normalize(mac) else { return nil }
        return n.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }
}

// MARK: - Interfaces

struct IPv4Interface {
    let name: String
    let address: UInt32    // host byte order
    let netmask: UInt32
    let broadcast: UInt32

    var hostCount: Int { Int(~netmask) - 1 }
}

enum Interfaces {
    /// Active, non-loopback IPv4 interfaces that support broadcast.
    static func ipv4() -> [IPv4Interface] {
        var result: [IPv4Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var cur = head
        while let ifa = cur?.pointee {
            defer { cur = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append(IPv4Interface(name: String(cString: ifa.ifa_name), address: a, netmask: m, broadcast: a | ~m))
        }
        return result
    }

    static func ownAddresses() -> Set<String> { Set(ipv4().map { format($0.address) }) }

    static func format(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xff).\(ip >> 16 & 0xff).\(ip >> 8 & 0xff).\(ip & 0xff)"
    }
}

// MARK: - UDP

enum UDP {
    enum Failure: Error { case socket, nothingSent }

    /// Sends one datagram to each (address, port) pair. Returns the number of successful sends.
    @discardableResult
    static func send(_ payload: [UInt8], to targets: [(String, UInt16)], broadcast: Bool) throws -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.socket }
        defer { close(fd) }
        var on: Int32 = 1
        if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var sent = 0
        for (host, port) in targets {
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &sa.sin_addr) == 1 else { continue }
            let n = payload.withUnsafeBytes { buf in
                withUnsafePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if n >= 0 { sent += 1 }
        }
        return sent
    }
}

enum MagicPacket {
    /// Sends the magic packet to every interface's broadcast address and 255.255.255.255, ports 9 and 7.
    static func send(to mac: String) throws {
        guard let bytes = MAC.bytes(mac) else { return }
        let packet = [UInt8](repeating: 0xff, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
        let addresses = Set(Interfaces.ipv4().map { Interfaces.format($0.broadcast) } + ["255.255.255.255"])
        let targets = addresses.flatMap { a in [(a, UInt16(9)), (a, UInt16(7))] }
        if try UDP.send(packet, to: targets, broadcast: true) == 0 { throw UDP.Failure.nothingSent }
    }
}

// MARK: - Shell helpers (ping, arp)

enum Shell {
    static func run(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return (-1, "") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

enum Ping {
    static func isReachable(_ ip: String) async -> Bool {
        await Shell.run("/sbin/ping", ["-c", "1", "-t", "1", "-q", ip]).status == 0
    }
}

struct NeighborEntry: Identifiable, Hashable {
    var id: String { mac }
    let hostname: String?
    let ip: String
    let mac: String

    var shortName: String? { hostname?.split(separator: ".").first.map(String.init) }
}

enum ARP {
    /// Devices the Mac has recently seen on the LAN, read straight from the kernel's ARP table.
    /// (Needs the "Local Network" permission – without it macOS returns EPERM / an empty table.)
    static func neighbors(resolveNames: Bool) async -> [NeighborEntry] {
        let own = Interfaces.ownAddresses()
        var seen = Set<String>()
        var result: [NeighborEntry] = []
        for (ip, mac) in table().entries where !own.contains(ip) && !seen.contains(mac) {
            guard mac != "ff:ff:ff:ff:ff:ff", mac != "00:00:00:00:00:00",
                  !mac.hasPrefix("01:00:5e"), !mac.hasPrefix("33:33") else { continue }
            seen.insert(mac)
            result.append(NeighborEntry(hostname: nil, ip: ip, mac: mac))
        }
        if resolveNames {
            let names = await Hostnames.resolve(result.map(\.ip), timeout: 1.5)
            result = result.map { NeighborEntry(hostname: names[$0.ip], ip: $0.ip, mac: $0.mac) }
        }
        return result.sorted { ipSortKey($0.ip) < ipSortKey($1.ip) }
    }

    /// Raw ARP table via sysctl(NET_RT_FLAGS, RTF_LLINFO); `error` is the errno if the read failed.
    static func table() -> (entries: [(ip: String, mac: String)], error: Int32) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_LLINFO]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return ([], errno) }
        guard len > 0 else { return ([], 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return ([], errno) }
        var out: [(String, String)] = []
        buf.withUnsafeBytes { raw in
            let hdr = MemoryLayout<rt_msghdr>.size
            var off = 0
            while off + hdr <= len {
                let msglen = Int(raw.load(fromByteOffset: off, as: UInt16.self))
                guard msglen > 0 else { break }
                // rt_msghdr is followed by sockaddr_in (destination) and sockaddr_dl (link address)
                let sin = raw.baseAddress!.advanced(by: off + hdr).assumingMemoryBound(to: sockaddr_in.self).pointee
                let sinLen = Int(sin.sin_len)
                let dlOff = off + hdr + (sinLen > 0 ? (sinLen + 3) & ~3 : 4)
                if sin.sin_family == UInt8(AF_INET), dlOff + 8 <= off + msglen {
                    let dl = raw.baseAddress!.advanced(by: dlOff).assumingMemoryBound(to: sockaddr_dl.self).pointee
                    let macStart = dlOff + 8 + Int(dl.sdl_nlen)
                    if dl.sdl_alen == 6, macStart + 6 <= off + msglen {
                        let mac = (0..<6).map { String(format: "%02x", raw[macStart + $0]) }.joined(separator: ":")
                        out.append((Interfaces.format(UInt32(bigEndian: sin.sin_addr.s_addr)), mac))
                    }
                }
                off += msglen
            }
        }
        return (out, 0)
    }

    /// Nudges every host of the local subnets (up to /22) with a tiny UDP datagram so they land in
    /// the ARP cache, even if the Mac has not talked to them yet.
    static func sweep() async {
        await Task.detached {
            for iface in Interfaces.ipv4() where iface.hostCount > 0 && iface.hostCount <= 1022 {
                let network = iface.address & iface.netmask
                let targets = (1...UInt32(iface.hostCount))
                    .map { network + $0 }
                    .filter { $0 != iface.address }
                    .map { (Interfaces.format($0), UInt16(9)) }
                _ = try? UDP.send([0], to: targets, broadcast: false)
            }
        }.value
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    static func ipSortKey(_ ip: String) -> UInt32 {
        ip.split(separator: ".").reduce(UInt32(0)) { $0 << 8 | (UInt32($1) ?? 0) }
    }
}

enum Hostnames {
    /// Reverse-resolves all IPs in parallel; whatever has not answered within `timeout` stays unnamed.
    static func resolve(_ ips: [String], timeout: TimeInterval) async -> [String: String] {
        final class Box: @unchecked Sendable {
            private var names: [String: String] = [:]
            private let lock = NSLock()
            func set(_ ip: String, _ name: String) { lock.lock(); names[ip] = name; lock.unlock() }
            func snapshot() -> [String: String] { lock.lock(); defer { lock.unlock() }; return names }
        }
        let box = Box()
        let group = DispatchGroup()
        for ip in ips {
            group.enter()
            // getnameinfo blocks, so it runs on GCD threads rather than Swift's cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let name = lookup(ip) else { return }
                box.set(ip, name)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = group.wait(timeout: .now() + timeout)
                c.resume()
            }
        }
        return box.snapshot()
    }

    private static func lookup(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return rc == 0 ? String(cString: host) : nil
    }
}

enum SelfTest {
    static func run(reportTo path: String) async {
        var lines: [String] = []
        let ifaces = Interfaces.ipv4()
        lines.append("interfaces: " + ifaces.map { "\($0.name) \(Interfaces.format($0.address)) bcast \(Interfaces.format($0.broadcast))" }.joined(separator: ", "))
        let t = ARP.table()
        lines.append("arp table via sysctl: \(t.entries.count) entries, errno \(t.error) (\(String(cString: strerror(t.error))))")
        errno = 0
        let probe = (try? UDP.send([0], to: [(Interfaces.format((ifaces.first?.address ?? 0) & (ifaces.first?.netmask ?? 0) + 1), 9)], broadcast: false)) ?? -1
        lines.append("unicast probe to gateway: sent \(probe), errno \(errno) (\(String(cString: strerror(errno))))")
        await ARP.sweep()
        let n = await ARP.neighbors(resolveNames: true)
        lines.append("neighbors after sweep: \(n.count)")
        lines += n.prefix(40).map { "  \($0.shortName ?? "-") \($0.ip) \($0.mac)" }
        lines.append("ping gateway: \(await Ping.isReachable(Interfaces.format(((ifaces.first?.address ?? 0) & (ifaces.first?.netmask ?? 0)) + 1)))")
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
