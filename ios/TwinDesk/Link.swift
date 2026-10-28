// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// The iPad's side of the session: a WSS client with the computer's certificate pinned, pairing as
// the initiator (numeric comparison), hello, liveness. Like android/Link.kt without USB or
// Bluetooth pipes.
import Foundation
import CryptoKit
import UIKit

struct PairState: Equatable {
    var phase: String // connecting | starting | code | waiting | failed
    var address: String
    var port: Int
    var name: String
    var code = ""
    var error = ""
    var wired = false
    var ble = false
}

protocol LinkEvents: AnyObject {
    func linkChanged()
    func linkWelcome(_ host: Host)
    func linkMessage(_ m: [String: Any])
    func linkClosed(_ host: Host, code: String?)
}

final class Link: NSObject, URLSessionWebSocketDelegate {
    weak var events: LinkEvents?
    private let store: Store

    private(set) var state = "idle" // idle | connecting | connected | failed
    private(set) var message = ""
    private(set) var pair: PairState?
    private(set) var host: Host?
    private(set) var rttMs: Int64?
    var connected: Bool { state == "connected" }

    private let exec = DispatchQueue(label: "td-link")
    private var session: URLSession!
    private var ws: URLSessionWebSocketTask?
    private var mode = "" // session | pair
    private var nw = ""
    private var seenFp = ""
    private var lastRx = Date()
    private var pinger: DispatchSourceTimer?
    private var helloTimer: DispatchSourceTimer?
    private var pinFp: String?

    init(store: Store) {
        self.store = store
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 0
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func connect(_ h: Host) {
        exec.async { [weak self] in
            guard let self else { return }
            if let ws = self.ws, self.host?.id == h.id,
               self.state == "connecting" || self.state == "connected" { return }
            self.closeSocket()
            self.pair = nil
            self.host = h
            self.open("session", h.address, h.port, h.fp)
            self.setState("connecting", "")
        }
    }

    func disconnect() {
        exec.async { [weak self] in
            guard let self else { return }
            if self.state == "connected" { self.raw(msg(Proto.T.bye)) }
            self.closeSocket()
            self.setState("idle", "")
        }
    }

    func startPairing(address: String, port: Int, name: String) {
        exec.async { [weak self] in
            guard let self else { return }
            self.closeSocket()
            self.host = nil
            self.pair = PairState(phase: "connecting", address: address, port: port, name: name)
            self.open("pair", address, port, nil)
            DispatchQueue.main.async { self.events?.linkChanged() }
        }
    }

    func confirmCode() {
        exec.async { [weak self] in
            guard let self, var p = self.pair, p.phase == "code", self.mode == "pair" else { return }
            self.raw(msg(Proto.T.pairConfirm))
            p.phase = "waiting"
            self.pair = p
            DispatchQueue.main.async { self.events?.linkChanged() }
        }
    }

    func cancelPairing() {
        exec.async { [weak self] in
            guard let self, let p = self.pair else { return }
            if self.mode == "pair" && p.phase != "failed" { self.raw(msg(Proto.T.pairCancel)) }
            self.pair = nil
            if self.mode == "pair" { self.closeSocket() }
            DispatchQueue.main.async { self.events?.linkChanged() }
        }
    }

    func updateHost(_ h: Host) {
        host = h
    }

    func send(_ m: [String: Any]) -> Bool {
        guard let ws, state == "connected" else { return false }
        ws.send(.string(jsonStr(m))) { _ in }
        return true
    }

    private func open(_ m: String, _ address: String, _ port: Int, _ pin: String?) {
        mode = m
        nw = ""
        seenFp = ""
        pinFp = pin
        let url = URL(string: "wss://\(address):\(port)")!
        ws = session.webSocketTask(with: url)
        ws?.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        guard let w = ws else { return }
        w.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.lastRx = Date()
                if w === self.ws || mode == "pair" || mode == "session" { self.onText(text) }
                self.receiveLoop()
            case .success(.data):
                self.receiveLoop()
            case .failure(let error):
                self.gone(w, error.localizedDescription)
            }
        }
    }

    private func gone(_ w: URLSessionWebSocketTask, _ failure: String?) {
        exec.async { [weak self] in
            guard let self, w === self.ws else { return }
            self.onClose(failure)
        }
    }

    private func onOpen() {
        lastRx = Date()
        if mode == "pair" {
            nw = Proto.randomHex(16)
            var start = msg(Proto.T.pairStart, [
                "v": Proto.version, "id": store.deviceId, "name": store.deviceName,
                "os": Proto.os, "commit": Proto.commitOf(nw),
            ])
            raw(start)
            pair?.phase = "starting"
            DispatchQueue.main.async { self.events?.linkChanged() }
            return
        }
        hello()
    }

    private func hello() {
        guard let h = host else { return }
        raw(msg(Proto.T.hello, [
            "v": Proto.version, "id": store.deviceId, "name": store.deviceName,
            "os": Proto.os, "token": h.token,
        ]))
        helloTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: exec)
        t.schedule(deadline: .now() + .milliseconds(Int(Proto.timeoutMs)))
        t.setEventHandler { [weak self] in
            guard let self, self.state != "connected" else { return }
            self.message = "No answer"
            self.ws?.cancel(with: .goingAway, reason: nil)
        }
        t.resume()
        helloTimer = t
    }

    private func onText(_ text: String) {
        guard let m = parseJson(text) else { return }
        let t = jstr(m, "t")
        lastRx = Date()
        switch t {
        case Proto.T.pairNonce:
            onNonce(m)
        case Proto.T.pairOk:
            onPairOk(m)
        case Proto.T.pairCancel:
            pairFailed("Pairing was cancelled on the computer.")
        case Proto.T.welcome:
            onWelcome(m)
        case Proto.T.error:
            onError(m)
        case Proto.T.ping:
            if state == "connected" { raw(msg(Proto.T.pong, ["ts": m["ts"] ?? NSNull()])) }
        case Proto.T.pong:
            if let ts = m["ts"] as? NSNumber { rttMs = max(0, Int64(Date().timeIntervalSince1970 * 1000) - ts.int64Value) }
        default:
            if state == "connected" { DispatchQueue.main.async { self.events?.linkMessage(m) } }
        }
    }

    private func onNonce(_ m: [String: Any]) {
        guard var p = pair else { return }
        let nonce = jstr(m, "nonce", 256)
        let hexOk = nonce.range(of: "^[0-9a-f]{32,128}$", options: .regularExpression) != nil && nonce.count % 2 == 0
        guard mode == "pair", !nw.isEmpty, hexOk else {
            return pairFailed("The computer sent a bad pairing message.")
        }
        raw(msg(Proto.T.pairReveal, ["nonce": nw]))
        p.phase = "code"
        p.code = Proto.sasCode(fp: seenFp, nwHex: nw, nmHex: nonce)
        pair = p
        DispatchQueue.main.async { self.events?.linkChanged() }
    }

    private func onPairOk(_ m: [String: Any]) {
        guard var p = pair, mode == "pair", p.phase == "waiting" else { return }
        let token = jstr(m, "token", 500)
        let id = jstr(m, "macId", 200)
        guard !token.isEmpty, !id.isEmpty else {
            return pairFailed("The computer sent a bad pairing message.")
        }
        let h = Host(
            id: id,
            name: jstr(m, "macName", 64).isEmpty ? p.name : jstr(m, "macName", 64),
            os: jstr(m, "os").isEmpty ? "mac" : jstr(m, "os"),
            address: p.address,
            port: p.port,
            fp: seenFp,
            token: token,
            lastSeen: Int64(Date().timeIntervalSince1970 * 1000)
        )
        store.putHost(h)
        pair = nil
        mode = "session"
        host = h
        setState("connecting", "")
        hello()
        DispatchQueue.main.async { self.events?.linkChanged() }
    }

    private func onWelcome(_ m: [String: Any]) {
        guard mode == "session", state != "connected", var h = host else { return }
        helloTimer?.cancel()
        let name = jstr(m, "macName", 64)
        if !name.isEmpty { h.name = name }
        h.lastSeen = Int64(Date().timeIntervalSince1970 * 1000)
        store.putHost(h)
        host = h
        rttMs = nil
        setState("connected", "")
        startPinger()
        DispatchQueue.main.async { self.events?.linkWelcome(h) }
    }

    private func startPinger() {
        pinger?.cancel()
        let t = DispatchSource.makeTimerSource(queue: exec)
        t.schedule(deadline: .now() + .milliseconds(Int(Proto.pingMs)), repeating: .milliseconds(Int(Proto.pingMs)))
        t.setEventHandler { [weak self] in
            guard let self, self.state == "connected" else { return }
            let now = Date().timeIntervalSince1970 * 1000
            if Date().timeIntervalSince(self.lastRx) * 1000 > Proto.timeoutMs {
                self.message = "Stopped answering"
                self.ws?.cancel(with: .goingAway, reason: nil)
                return
            }
            self.ws?.send(.string(jsonStr(msg(Proto.T.ping, ["ts": now]))) ) { _ in }
        }
        t.resume()
        pinger = t
    }

    private let pairErrors: [String: String] = [
        Proto.E.pairRefused: "Pairing was refused.",
        Proto.E.pairTimeout: "Pairing timed out.",
        Proto.E.busy: "That computer is busy pairing with another device.",
        Proto.E.versionMismatch: "That computer runs a different TwinDesk version. Update both.",
    ]

    private func onError(_ m: [String: Any]) {
        let code = jstr(m, "code")
        if mode == "pair" { return pairFailed(pairErrors[code] ?? "Pairing failed (\(code)).") }
        switch code {
        case Proto.E.badToken:
            message = "\(host?.name ?? "The computer") forgot this iPad. Pair again."
            if let id = host?.id { store.forgetHost(id) }
        case Proto.E.busy:
            message = jstr(m, "message").isEmpty ? "Busy with another device" : jstr(m, "message")
        case Proto.E.replaced:
            message = jstr(m, "message").isEmpty ? "Another device connected" : jstr(m, "message")
        case Proto.E.released:
            message = "Disconnected from \(host?.name ?? "the computer")"
        case Proto.E.asleep:
            message = "\(host?.name ?? "The computer") is asleep"
        default:
            message = "Closed (\(code))"
        }
    }

    private func pairFailed(_ error: String) {
        guard var p = pair else { return }
        p.phase = "failed"
        p.error = error
        p.code = ""
        pair = p
        closeSocket()
        DispatchQueue.main.async { self.events?.linkChanged() }
    }

    private func onClose(_ failure: String?) {
        pinger?.cancel()
        pinger = nil
        helloTimer?.cancel()
        helloTimer = nil
        ws = nil
        if mode == "pair" {
            if var p = pair, p.phase != "failed" {
                if p.phase == "connecting" {
                    p.error = "Couldn't connect to \(p.address)" + (failure.map { " (\($0))" } ?? "") + "."
                } else {
                    p.error = "The connection closed."
                }
                p.phase = "failed"
                pair = p
                DispatchQueue.main.async { self.events?.linkChanged() }
            }
            return
        }
        let was = state
        if failure == "identity" {
            setState("failed", "\(host?.name ?? "The computer") looks different now. Forget it and pair again.")
        } else {
            if message.isEmpty, let failure { message = failure }
            setState((was == "connected" || was == "connecting") ? "idle" : was, message)
        }
        if let h = host {
            DispatchQueue.main.async { self.events?.linkClosed(h, code: nil) }
        }
    }

    private func closeSocket() {
        pinger?.cancel()
        pinger = nil
        helloTimer?.cancel()
        helloTimer = nil
        let wasConnected = state == "connected"
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        if wasConnected {
            state = "idle"
            if let h = host {
                DispatchQueue.main.async { self.events?.linkClosed(h, code: "local") }
            }
        }
    }

    private func raw(_ m: [String: Any]) {
        ws?.send(.string(jsonStr(m))) { _ in }
    }

    private func setState(_ s: String, _ msg: String) {
        state = s
        message = msg
        DispatchQueue.main.async { self.events?.linkChanged() }
    }

    // Self-signed certificates: the fingerprint is the identity (pinned once paired).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard SecTrustGetCertificateCount(trust) > 0,
              let cert = SecTrustGetCertificateAtIndex(trust, 0) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(cert) as Data
        let fp = Proto.sha256(der).hex
        exec.async { self.seenFp = fp }
        if let pin = pinFp, fp != pin {
            exec.async { self.onClose("identity") }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        exec.async { [weak self] in
            guard let self, webSocketTask === self.ws else { return }
            self.onOpen()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        gone(ws, error?.localizedDescription)
    }
}
