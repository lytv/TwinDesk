// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// The computer's screen and sound on the iPad. WKWebView answers the Mac's WebRTC offers with the
// same pages as Android (assets/web): viewer.html for the screen, audio.html for the sound.
// WebHost carries messages between the link and a page via window.TD / window.tdRecv.
import Foundation
import UIKit
import WebKit
import Combine

final class WebHost: NSObject, ObservableObject, WKScriptMessageHandler {
    let view: WKWebView
    private let core: Core
    private var ready = false
    private var queue: [[String: Any]] = []
    private let onEvent: (String, [String: Any]?) -> Void

    init(page: String, core: Core, onEvent: @escaping (String, [String: Any]?) -> Void = { _, _ in }) {
        self.core = core
        self.onEvent = onEvent
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = content
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        content.add(self, name: "TD")
        // xcodegen may flatten the web/ folder into the bundle root; try both.
        let url = Bundle.main.url(forResource: page, withExtension: nil, subdirectory: "web")
            ?? Bundle.main.url(forResource: page, withExtension: nil)
        if let url {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    // The JS shim: window.TD posts to native; the Android @JavascriptInterface shape is kept so the
    // shared pages run unchanged.
    private static let bridgeJS = """
    window.TD = {
      send: (json) => window.webkit.messageHandlers.TD.postMessage({method: 'send', json: String(json)}),
      ready: () => window.webkit.messageHandlers.TD.postMessage({method: 'ready'}),
      playing: (w, h) => window.webkit.messageHandlers.TD.postMessage({method: 'playing', w: w|0, h: h|0}),
      haptic: () => window.webkit.messageHandlers.TD.postMessage({method: 'haptic'}),
      tick: () => window.webkit.messageHandlers.TD.postMessage({method: 'tick'}),
      event: (name) => window.webkit.messageHandlers.TD.postMessage({method: 'event', name: String(name)}),
      setPad: (id, code) => window.webkit.messageHandlers.TD.postMessage({method: 'setPad', id: String(id), code: String(code)}),
      pad: (b, lx, ly, rx, ry, lt, rt) => window.webkit.messageHandlers.TD.postMessage({method: 'pad', b: b|0, lx: +lx, ly: +ly, rx: +rx, ry: +ry, lt: +lt, rt: +rt}),
    };
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else { return }
        switch method {
        case "send":
            if let json = body["json"] as? String, let m = parseJson(json) {
                core.send(m)
            }
        case "ready":
            ready = true
            let q = queue
            queue.removeAll()
            q.forEach { deliver($0) }
            onEvent("ready", nil)
        case "playing":
            onEvent("playing", ["w": body["w"] as? Int ?? 0, "h": body["h"] as? Int ?? 0])
        case "haptic":
            let g = UIImpactFeedbackGenerator(style: .heavy)
            g.impactOccurred()
        case "tick":
            let g = UIImpactFeedbackGenerator(style: .light)
            g.impactOccurred()
        case "event":
            onEvent(jstr(body, "name"), nil)
        case "setPad":
            // Remote controls are not used from the iPad gamepad in this port; ignore silently.
            break
        case "pad":
            break
        default:
            break
        }
    }

    func post(_ m: [String: Any]) {
        if ready { deliver(m) } else { queue.append(m) }
    }

    private func deliver(_ m: [String: Any]) {
        let js = "window.tdRecv && window.tdRecv(\(jsonStr(m)));"
        DispatchQueue.main.async { self.view.evaluateJavaScript(js, completionHandler: nil) }
    }

    func destroy() {
        ready = false
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }
}

// The computer's screen: what it shares (screen.state), Start/Stop and Mirror/Extend (screen.ctl),
// and the viewer page while the Viewer sheet is open (screen.policy tells the Mac to stream).
final class Screen: Feature {
    private unowned let core: Core
    @Published private(set) var state: [String: Any]?
    @Published private(set) var inputOn = true
    @Published private(set) var viewing = false
    @Published private(set) var size: (Int, Int)?
    private var host: WebHost?
    private var lastInfo: [String: Any]?
    private var wantStart = false
    private var startedByUs = false

    var sharing: Bool { jbool(state ?? [:], "on") }
    var mode: String { jstr(state ?? [:], "mode") }
    var remoteAllowed: Bool { state == nil || jbool(state ?? [:], "remote", true) }

    init(core: Core) { self.core = core }

    var sharingBinding: Bool { sharing }
    var modes: [String] {
        guard let a = state?["modes"] as? [Any] else { return ["extend", "mirror"] }
        return a.compactMap { $0 as? String }
    }

    func attach(_ h: WebHost, w: Int, hpx: Int) {
        host = h
        viewing = true
        h.post(opts())
        if let lastInfo { h.post(lastInfo) }
        if let state { h.post(state) }
        policy(w, hpx)
    }

    private func policy(_ w: Int, _ hpx: Int) {
        core.send(msg("screen.policy", ["accept": true, "width": w, "height": hpx]))
        if state == nil { wantStart = true } else { startIfNeeded() }
        core.changed()
    }

    private func startIfNeeded() {
        wantStart = false
        guard viewing, !sharing, remoteAllowed else { return }
        startedByUs = true
        control(share: true, mode: pickMode())
    }

    private func pickMode() -> String {
        modes.contains("mirror") ? "mirror" : (modes.first ?? "mirror")
    }

    func detach(_ h: WebHost) {
        if host !== h { return }
        host = nil
        viewing = false
        size = nil
        wantStart = false
        if core.link.connected {
            core.send(msg("screen.policy", ["accept": false]))
            if startedByUs && sharing { control(share: false) }
        }
        startedByUs = false
        core.changed()
    }

    func opts() -> [String: Any] {
        msg("opts", [
            "sound": core.store.flag("screen.sound", false),
            "pacing": core.store.flag("screen.smooth", false) ? "smooth" : "fast",
            "name": core.host?.name ?? "the computer",
            "touch": core.store.flag("screen.touchpad", true) ? "pad" : "direct",
            "speed": Double(core.remote.speed),
            "tap": core.remote.tapClick,
            "pen": core.store.flag("screen.pen", true),
        ])
    }

    func repost() { host?.post(opts()) }

    func setOpt(_ key: String, _ on: Bool) {
        core.store.setFlag(key, on)
        host?.post(opts())
        core.changed()
    }

    func playing(_ w: Int, _ h: Int) {
        size = (w, h)
        core.changed()
    }

    func control(share: Bool? = nil, mode: String? = nil, close: Bool = false) {
        var m: [String: Any] = ["t": "screen.ctl"]
        if let share { m["share"] = share }
        if let mode { m["mode"] = mode }
        if close { m["close"] = true }
        if share == false { startedByUs = false }
        core.send(m)
    }

    func keyboard(_ on: Bool) {
        host?.post(msg("keyboard", ["on": on]))
        DispatchQueue.main.async {
            if on { self.host?.view.becomeFirstResponder() }
            else { self.host?.view.resignFirstResponder() }
        }
    }

    func end() {
        if core.link.connected && sharing { control(share: false, close: true) }
    }

    func pick(_ mode: String) {
        control(share: true, mode: mode)
    }

    func onWelcome(_ host: Host) {}
    func onClosed() {
        state = nil
        lastInfo = nil
        startedByUs = false
        host?.post(msg("stream.stop"))
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case "screen.state":
            state = m
            host?.post(m)
            if wantStart { startIfNeeded() }
            core.changed()
            return true
        case "stream.input":
            inputOn = jbool(m, "on", true)
            core.changed()
            return true
        case "stream.info":
            lastInfo = m
            host?.post(m)
            return true
        case "rtc.offer", "rtc.ice", "stream.stop":
            host?.post(m)
            return true
        default:
            return false
        }
    }
}

// The Mac's sound here (audio m2w): a page in a WebView with no window answers its offers.
final class MacSound: Feature {
    private unowned let core: Core
    private var host: WebHost?
    @Published private(set) var playing = false

    init(core: Core) { self.core = core }

    func sendPolicy() {
        core.send(msg("audio.policy", ["accept": core.sync.get("audio", "in")]))
        if !core.sync.get("audio", "in") { stop() }
    }

    func onWelcome(_ host: Host) { sendPolicy() }
    func onClosed() { stop() }

    private func stop() {
        host?.destroy()
        host = nil
        if playing { playing = false; core.changed() }
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        guard t.hasPrefix("audio."), jstr(m, "dir") == "m2w" else { return false }
        switch t {
        case "audio.offer":
            guard core.sync.get("audio", "in") else { return true }
            let h = host ?? WebHost(page: "audio.html", core: core)
            host = h
            h.post(m)
            playing = true
            core.changed()
            return true
        case "audio.stop":
            stop()
            return true
        default:
            host?.post(m)
            return true
        }
    }
}
