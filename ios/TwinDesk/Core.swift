// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// Everything the iPad does, in one place: discovery, the link and the features on it.
// Connects only when asked (Connect, Pair, or the Mac's invite) and to resume a dropped session.
import Foundation
import Combine
import UIKit

protocol Feature {
    func onWelcome(_ host: Host)
    func onClosed()
    func onMessage(_ t: String, _ m: [String: Any]) -> Bool
}

extension Feature {
    func onWelcome(_ host: Host) {}
    func onClosed() {}
    func onMessage(_ t: String, _ m: [String: Any]) -> Bool { false }
}

final class Core: ObservableObject, LinkEvents {
    let store = Store()
    private let main = DispatchQueue.main

    private(set) var discovery: Discovery!
    let link: Link

    @Published var version = 0
    @Published var invite: Found?

    lazy var sync = PairSync(core: self)
    lazy var clip = Clip(core: self)
    lazy var notifs = Notifs(core: self)
    lazy var files = FilesIn(core: self)
    lazy var screen = Screen(core: self)
    lazy var macSound = MacSound(core: self)
    lazy var remote = Remote(core: self)
    private lazy var features: [Feature] = [sync, clip, notifs, files, screen, macSound, remote]

    private var resumeUntil: Int64 = 0
    private var resumeHost: Host?
    private var started = false

    init() {
        link = Link(store: store)
        link.events = self
        discovery = Discovery(
            selfInfo: { [weak self] in
                guard let self else { return [:] }
                return ["id": self.store.deviceId, "name": self.store.deviceName]
            },
            onChange: { [weak self] in self?.changed() },
            onInvite: { [weak self] in self?.onInvite($0) }
        )
        start()
    }

    func start() {
        guard !started else { return }
        started = true
        discovery.start()
    }

    var host: Host? { link.connected ? link.host : nil }

    func changed() {
        version += 1
    }

    func send(_ m: [String: Any]) -> Bool {
        link.send(m)
    }

    func hosts() -> [Host] { store.hosts() }

    func connect(_ h: Host) {
        resumeUntil = 0
        var h = h
        if let seen = discovery.found[h.id], seen.address != h.address || seen.port != h.port {
            h.address = seen.address
            h.port = seen.port
            store.putHost(h)
        }
        link.connect(h)
    }

    func disconnect() {
        resumeUntil = 0
        link.disconnect()
    }

    func switchTo(_ h: Host) {
        disconnect()
        connect(h)
    }

    func pair(_ f: Found) {
        invite = nil
        discovery.clearInvite(f.id)
        link.startPairing(address: f.address, port: f.port, name: f.name)
    }

    func pairAddress(_ address: String) {
        let a = address.trimmingCharacters(in: .whitespaces)
        link.startPairing(address: a, port: Proto.port, name: a)
    }

    func dismissInvite() {
        if let f = invite { discovery.clearInvite(f.id) }
        invite = nil
        changed()
    }

    func forget(_ id: String) {
        if link.host?.id == id { link.disconnect() }
        store.forgetHost(id)
        changed()
    }

    private func onInvite(_ f: Found) {
        if let h = store.hosts().first(where: { $0.id == f.id }) {
            if link.host?.id == h.id && (link.state == "connected" || link.state == "connecting") { return }
            var h = h
            h.address = f.address
            h.port = f.port
            connect(h)
            return
        }
        if link.pair != nil { return }
        invite = f
        changed()
    }

    // MARK: - LinkEvents

    func linkChanged() {
        changed()
    }

    func linkWelcome(_ host: Host) {
        resumeUntil = 0
        var h = host
        if let seen = discovery.found[host.id], host.address == "127.0.0.1" {
            h.address = seen.address
            h.port = seen.port
            store.putHost(h)
            link.updateHost(h)
        }
        for f in features { f.onWelcome(h) }
        changed()
    }

    func linkMessage(_ m: [String: Any]) {
        let t = jstr(m, "t")
        for f in features {
            if f.onMessage(t, m) { return }
        }
    }

    func linkClosed(_ host: Host, code: String?) {
        for f in features { f.onClosed() }
        changed()
        let accidental = code == nil || !["local", Proto.E.released, Proto.E.replaced, Proto.E.badToken, Proto.E.busy, Proto.E.asleep].contains(code!)
        if !accidental || link.state == "failed" { return }
        if resumeUntil == 0 { resumeUntil = Int64(Date().timeIntervalSince1970 * 1000) + Int64(Proto.phoneGraceMs) }
        resumeHost = host
        main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.resume() }
    }

    private func resume() {
        guard let h = resumeHost,
              Int64(Date().timeIntervalSince1970 * 1000) <= resumeUntil,
              !link.connected, link.state != "connecting", link.pair == nil
        else { return }
        let until = resumeUntil
        if let fresh = store.hosts().first(where: { $0.id == h.id }) { connect(fresh) }
        resumeUntil = until
    }

}
