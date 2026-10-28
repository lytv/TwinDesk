// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// Clipboard text and pictures both ways, and the two-way switches shared with the computer.
import Foundation
import UIKit
import Combine

final class Clip: Feature {
    private unowned let core: Core
    @Published private(set) var peerAccepts = false
    @Published private(set) var peerImages = false
    @Published private(set) var lastIn: String?
    @Published private(set) var lastOut: String?
    @Published var history: [Item] = []

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let dir: String
        let text: String
    }

    private let pics = DispatchQueue(label: "td-clip-pic")
    private var inPic: PicIn?
    private var outId = ""

    private final class PicIn {
        let id: String
        let w: Int
        let h: Int
        let bytes: Int
        let parts: Int
        let shot: Bool
        let at: Date
        var buf = Data()
        var got = 0
        init(id: String, w: Int, h: Int, bytes: Int, parts: Int, shot: Bool) {
            self.id = id; self.w = w; self.h = h; self.bytes = bytes
            self.parts = parts; self.shot = shot; self.at = Date()
            buf.reserveCapacity(bytes)
        }
    }

    init(core: Core) {
        self.core = core
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipChanged),
            name: UIPasteboard.changedNotification, object: nil
        )
    }

    @objc private func clipChanged() {
        guard core.sync.get("clipboard", "out") else { return }
        sendCurrent(false)
    }

    var picturesOn: Bool { core.store.flag("clip.images", core.store.was) }

    func setPictures(_ v: Bool) {
        core.store.setFlag("clip.images", v)
        sendPolicy()
        core.changed()
    }

    var canSendPictures: Bool {
        picturesOn && peerImages && core.sync.get("clipboard", "out") && core.link.connected
    }

    func sendPolicy() {
        let accept = core.sync.get("clipboard", "in")
        core.send(msg(Proto.T.clipPolicy, ["accept": accept, "images": accept && picturesOn]))
    }

    func onWelcome(_ host: Host) {
        peerAccepts = false
        peerImages = false
        sendPolicy()
    }

    func onClosed() {
        peerAccepts = false
        peerImages = false
        outId = ""
        pics.async { self.inPic = nil }
    }

    func sendCurrent(_ force: Bool) -> Bool {
        let pb = UIPasteboard.general
        if let text = pb.string, !text.isEmpty {
            return sendText(text, force: force)
        }
        // Pictures: only when Pictures is on both ways (UIPasteboard images as PNG).
        if canSendPictures, let img = pb.image,
           let png = pngData(of: img), png.count <= Proto.clipImageMaxBytes {
            let w = Int(img.size.width * img.scale)
            let h = Int(img.size.height * img.scale)
            pics.async { [weak self] in self?.sendPicture(Png(bytes: png, w: w, h: h), shot: false) }
            return true
        }
        return false
    }

    func sendText(_ text: String, force: Bool = true) -> Bool {
        guard core.link.connected, !text.isEmpty else { return false }
        if !force, text == lastOut || text == lastIn { return false }
        guard text.utf8.count <= Proto.clipMaxBytes else { return false }
        if !force, !peerAccepts { return false }
        outId = ""
        lastOut = text
        remember(Item(dir: "out", text: text))
        core.send(msg(Proto.T.clip, ["text": text]))
        core.changed()
        return true
    }

    struct Png {
        let bytes: Data
        let w: Int
        let h: Int
    }

    func sendPicture(_ p: Png, shot: Bool) -> Bool {
        guard canSendPictures, p.bytes.count <= Proto.clipImageMaxBytes else { return false }
        let id = Proto.randomHex(8)
        outId = id
        let part = Proto.clipImagePartBytes
        let parts = (p.bytes.count + part - 1) / part
        var head = msg(Proto.T.clipImage, [
            "id": id, "w": p.w, "h": p.h, "bytes": p.bytes.count, "parts": parts,
        ])
        if shot { head["shot"] = true }
        core.send(head)
        for i in 0..<parts {
            guard outId == id, canSendPictures else { return false }
            let from = i * part
            let to = min(part, p.bytes.count - from)
            let chunk = p.bytes.subdata(in: from..<(from + to))
            core.send(msg(Proto.T.clipImagePart, [
                "id": id, "i": i, "data": chunk.base64EncodedString(),
            ]))
        }
        if outId == id { outId = "" }
        remember(Item(dir: "out", text: "\(shot ? "Screenshot" : "Picture") · \(p.w) × \(p.h)"))
        core.changed()
        return true
    }

    private func receiveText(_ text: String) {
        lastIn = text
        remember(Item(dir: "in", text: text))
        UIPasteboard.general.string = text
        core.changed()
    }

    func copyAgain(_ item: Item) {
        UIPasteboard.general.string = item.text
    }

    private func remember(_ item: Item) {
        DispatchQueue.main.async {
            self.history.removeAll { $0.text == item.text }
            self.history.insert(item, at: 0)
            if self.history.count > 20 { self.history.removeLast(self.history.count - 20) }
            self.core.changed()
        }
    }

    private func header(_ m: [String: Any]) {
        inPic = nil
        let id = jstr(m, "id", 128)
        if id.isEmpty || id.count > 128 { return }
        let w = min(65535, max(0, jint(m, "w")))
        let h = min(65535, max(0, jint(m, "h")))
        let shot = jbool(m, "shot")
        let inline = jstr(m, "png", Int.max)
        if !inline.isEmpty {
            if let png = Data(base64Encoded: inline), png.count <= Proto.clipImageMaxBytes, isPng(png) {
                receivePicture(png, w, h, shot)
            }
            return
        }
        let bytes = jint(m, "bytes")
        let parts = jint(m, "parts")
        guard bytes >= 9, bytes <= Proto.clipImageMaxBytes,
              parts == (bytes + Proto.clipImagePartBytes - 1) / Proto.clipImagePartBytes
        else { return }
        inPic = PicIn(id: id, w: w, h: h, bytes: bytes, parts: parts, shot: shot)
    }

    private func part(_ m: [String: Any]) {
        guard let c = inPic, jstr(m, "id") == c.id else { return }
        let data = jstr(m, "data", Int.max)
        let i = jint(m, "i", -1)
        let maxPartLen = (Proto.clipImagePartBytes * 4 + 2) / 3 + 8
        guard i == c.got, !data.isEmpty, data.count <= maxPartLen, Date().timeIntervalSince(c.at) < 60,
              let b = Data(base64Encoded: data), c.buf.count + b.count <= c.bytes,
              c.got + 1 >= c.parts || b.count == Proto.clipImagePartBytes
        else {
            inPic = nil
            return
        }
        c.buf.append(b)
        c.got += 1
        if c.got < c.parts { return }
        inPic = nil
        let png = c.buf
        if png.count == c.bytes, isPng(png) { receivePicture(png, c.w, c.h, c.shot) }
    }

    private func receivePicture(_ png: Data, _ w: Int, _ h: Int, _ shot: Bool) {
        guard core.sync.get("clipboard", "in"), picturesOn else { return }
        outId = ""
        DispatchQueue.main.async {
            UIPasteboard.general.image = UIImage(data: png)
        }
        let size = w > 0 && h > 0 ? "\(w) × \(h)" : "\(png.count / 1024) KB"
        remember(Item(dir: "in", text: "\(shot ? "Screenshot" : "Picture") · \(size)"))
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func isPng(_ b: Data) -> Bool {
        guard b.count > 8 else { return false }
        return zip(pngSignature, b.prefix(8)).allSatisfy { $0 == $1 }
    }

    private func pngData(of image: UIImage) -> Data? {
        image.pngData()
    }

    private func isPng(_ b: Data) -> Bool { Self.isPng(b) }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case Proto.T.clipPolicy:
            peerAccepts = jbool(m, "accept")
            peerImages = jbool(m, "images")
        case Proto.T.clip:
            outId = ""
            pics.async { self.inPic = nil }
            let text = jstr(m, "text", Proto.clipMaxBytes)
            if core.sync.get("clipboard", "in"), !text.isEmpty, text.utf8.count <= Proto.clipMaxBytes {
                receiveText(text)
            }
        case Proto.T.clipImage:
            pics.async { self.header(m) }
        case Proto.T.clipImagePart:
            pics.async { self.part(m) }
        default:
            return false
        }
        core.changed()
        return true
    }
}

// Two-way switches shared with the computer, remembered per pair (mac/pairsync.js).
final class PairSync: Feature {
    private unowned let core: Core

    private let keys: [String: (out: String, in: String)] = [
        "clipboard": ("clip.send", "clip.receive"),
        "notifs": ("notifs.send", "notifs.receive"),
        "audio": ("audio.send", "audio.receive"),
        "cursor": ("cursor.out", "cursor.in"),
    ]

    private let valueDefaults: [String: String]

    init(core: Core) {
        self.core = core
        valueDefaults = [
            "keyboard": String(core.store.was),
            "speed": "1",
            "reverseScroll": "false",
            "gestures": "true",
            "pace": "fast",
            "ble": "true",
        ]
    }

    func value(_ key: String) -> String {
        core.store.prefsString("value.\(key)", valueDefaults[key] ?? "")
    }

    func setValue(_ key: String, _ v: Any) {
        core.store.setPrefsString("value.\(key)", "\(v)")
        core.send(msg(Proto.T.pairSync, ["key": key, "value": v]))
        core.changed()
    }

    private func adoptValue(_ key: String, _ v: Any?) {
        guard valueDefaults[key] != nil, v != nil, !(v is NSNull) else { return }
        core.store.setPrefsString("value.\(key)", "\(v!)")
    }

    func get(_ feature: String, _ dir: String) -> Bool {
        guard let k = keys[feature] else { return false }
        let def = core.store.was && feature != "audio" && !(feature == "cursor" && dir == "out")
        return core.store.flag(dir == "out" ? k.out : k.in, def)
    }

    func set(_ feature: String, _ dir: String, _ on: Bool) {
        apply(feature, dir, on)
        core.send(msg(Proto.T.pairSync, ["feature": feature, "dir": dir, "on": on]))
        remember()
    }

    private func apply(_ feature: String, _ dir: String, _ on: Bool) {
        guard let k = keys[feature] else { return }
        let key = dir == "out" ? k.out : k.in
        if get(feature, dir) == on { return }
        core.store.setFlag(key, on)
        switch feature {
        case "clipboard": core.clip.sendPolicy()
        case "notifs": core.notifs.sendPolicy()
        case "audio": core.macSound.sendPolicy()
        default: break
        }
        core.changed()
    }

    func onWelcome(_ host: Host) {
        guard let saved = core.store.pairSync(host.id) else { return }
        for f in keys.keys {
            guard let v = saved[f] as? [String: Any] else { continue }
            if v["out"] != nil { apply(f, "out", jbool(v, "out")) }
            if v["in"] != nil { apply(f, "in", jbool(v, "in")) }
        }
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        if t != Proto.T.pairSync { return false }
        if m["key"] != nil {
            adoptValue(jstr(m, "key", 64), m["value"])
            core.changed()
            return true
        }
        if let all = m["all"] as? [String: Any] {
            if let vals = all["values"] as? [String: Any] {
                for (k, v) in vals { adoptValue(k, v) }
            }
            for f in keys.keys {
                if let v = all[f] as? [String: Any] {
                    apply(f, "out", jbool(v, "in"))
                    apply(f, "in", jbool(v, "out"))
                }
            }
        } else if keys[jstr(m, "feature")] != nil {
            let dir = jstr(m, "dir")
            if dir == "out" || dir == "in" {
                apply(jstr(m, "feature"), dir == "out" ? "in" : "out", jbool(m, "on"))
            }
        }
        remember()
        return true
    }

    private func remember() {
        guard let h = core.host else { return }
        var o: [String: Any] = [:]
        for f in keys.keys {
            o[f] = ["out": get(f, "out"), "in": get(f, "in")]
        }
        core.store.setPairSync(h.id, o)
    }
}
