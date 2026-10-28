// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// Discovery on UDP DISCOVERY_PORT, as on the computers: beacons to every broadcast address (we are
// a guest: role 'guest'), answers probes, and keeps the computers nearby. A Mac's invite arrives
// here too. Raw BSD sockets, like the Android DatagramSocket.
import Foundation
import Darwin

struct Found: Identifiable, Equatable {
    let id: String
    let name: String
    let os: String
    let address: String
    let port: Int
    let fp: String
    let lastSeen: Date
    var invited: Bool
}

final class Discovery {
    private let selfInfo: () -> [String: Any]
    private let onChange: () -> Void
    private let onInvite: (Found) -> Void

    private(set) var found: [String: Found] = [:]
    var error = ""
    private var running = false
    private var sock: Int32 = -1
    private let work = DispatchQueue(label: "td-discovery-work")
    private let netQ = DispatchQueue(label: "td-discovery-net")
    private var beaconTimer: DispatchSourceTimer?
    private var receiveSource: DispatchSourceRead?

    init(selfInfo: @escaping () -> [String: Any], onChange: @escaping () -> Void, onInvite: @escaping (Found) -> Void) {
        self.selfInfo = selfInfo
        self.onChange = onChange
        self.onInvite = onInvite
    }

    func start() {
        guard !running else { return }
        running = true
        netQ.async { [weak self] in self?.receiveLoop() }
        let t = DispatchSource.makeTimerSource(queue: netQ)
        t.schedule(deadline: .now(), repeating: .milliseconds(Int(Proto.beaconMs)))
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            self.beacon()
            self.prune()
        }
        t.resume()
        beaconTimer = t
    }

    func stop() {
        running = false
        beaconTimer?.cancel()
        beaconTimer = nil
        receiveSource?.cancel()
        receiveSource = nil
        netQ.async { [weak self] in
            if let self, self.sock >= 0 { close(self.sock); self.sock = -1 }
        }
    }

    func list() -> [Found] {
        found.values.sorted {
            if $0.invited != $1.invited { return $0.invited }
            return $0.name < $1.name
        }
    }

    func clearInvite(_ id: String) {
        work.async { [weak self] in
            guard let self, var f = self.found[id], f.invited else { return }
            f.invited = false
            self.found[id] = f
            DispatchQueue.main.async { self.onChange() }
        }
    }

    private func beaconMsg() -> [String: Any] {
        var m = selfInfo()
        m["t"] = Proto.T.beacon
        m["v"] = Proto.version
        m["os"] = Proto.os
        m["role"] = "guest"
        m["port"] = Proto.port
        m["fp"] = ""
        return m
    }

    func probe(_ address: String? = nil) {
        let me = selfInfo()
        var m: [String: Any] = ["t": Proto.T.probe, "v": Proto.version, "id": me["id"] ?? ""]
        if let address { send(m, address) } else { targets().forEach { send(m, $0) } }
    }

    private func beacon() {
        let m = beaconMsg()
        for t in targets() { send(m, t) }
    }

    private func targets() -> [String] {
        var out: Set<String> = ["255.255.255.255"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return Array(out) }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let maskPtr = p.pointee.ifa_netmask, maskPtr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let n = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            a.sin_addr.s_addr |= ~n.sin_addr.s_addr
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            withUnsafePointer(to: &a.sin_addr) {
                inet_ntop(AF_INET, $0, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            out.insert(String(cString: buf))
        }
        return Array(out)
    }

    private func send(_ m: [String: Any], _ address: String, _ port: Int = Proto.discoveryPort) {
        let s = sock
        guard s >= 0, let data = try? JSONSerialization.data(withJSONObject: m) else { return }
        data.withUnsafeBytes { raw in
            guard let buf = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var dst = sockaddr_in()
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = in_port_t(UInt16(port).bigEndian)
            inet_pton(AF_INET, address, &dst.sin_addr.s_addr)
            _ = withUnsafePointer(to: &dst) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(s, buf, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receiveLoop() {
        while running {
            let s = socket(AF_INET, SOCK_DGRAM, 0)
            guard s >= 0 else { break }
            sock = s
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(Proto.discoveryPort).bigEndian)
            addr.sin_addr.s_addr = INADDR_ANY
            let bindOk = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindOk == 0 else {
                error = "Can't listen"
                close(s)
                sock = -1
                DispatchQueue.main.async { self.onChange() }
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            error = ""
            DispatchQueue.main.async { self.onChange() }
            beacon()
            probe()
            let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: netQ)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                var buf = [UInt8](repeating: 0, count: 4096)
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(s, &buf, buf.count, 0, $0, &len)
                    }
                }
                guard n > 0 else { return }
                var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
                let address = String(cString: ip)
                let text = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                self.work.async { self.handle(text, address) }
            }
            src.setCancelHandler { close(s) }
            src.resume()
            receiveSource = src
            return
        }
    }

    private func handle(_ text: String, _ address: String) {
        guard let m = parseJson(text),
              let v = m["v"] as? Int, v == Proto.version,
              let id = m["id"] as? String, !id.isEmpty, id != selfInfo()["id"] as? String
        else { return }
        let t = jstr(m, "t")
        if t == Proto.T.probe { return send(beaconMsg(), address) }
        if t != Proto.T.beacon && t != Proto.T.invite { return }
        let os = jstr(m, "os").isEmpty ? "mac" : jstr(m, "os")
        if os == Proto.os { return }
        if t == Proto.T.beacon && (m["role"] as? String ?? "host") != "host" { return }
        let old = found[id]
        var f = Found(
            id: id,
            name: jstr(m, "name", 100).isEmpty ? (os == "mac" ? "Mac" : os == "linux" ? "Linux" : "PC") : jstr(m, "name", 100),
            os: os,
            address: address,
            port: {
                let p = jint(m, "port", Proto.port)
                return (1...65535).contains(p) ? p : Proto.port
            }(),
            fp: Proto.normFingerprint(m["fp"] as? String),
            lastSeen: Date(),
            invited: (old?.invited ?? false) || t == Proto.T.invite
        )
        found[id] = f
        let notify = old == nil || old?.name != f.name || old?.address != f.address || old?.invited != f.invited
        let wasInvite = t == Proto.T.invite
        DispatchQueue.main.async {
            if wasInvite { self.onInvite(f) }
            if notify { self.onChange() }
        }
    }

    private func prune() {
        let now = Date()
        let before = found.count
        found = found.filter { now.timeIntervalSince($0.value.lastSeen) * 1000 <= Proto.deviceStaleMs }
        if found.count != before { DispatchQueue.main.async { self.onChange() } }
    }
}
