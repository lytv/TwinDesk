// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// Notifications from the computer here (iPadOS cannot host a notification listener like Android's
// NotifListener: computer -> iPad only). Files from the computer into the app's Documents.
// The Remote page: a WebView hosting remote.html, same as android/Remote.kt.
import Foundation
import UIKit
import UserNotifications
import Combine
import WebKit
import CryptoKit

final class Notifs: Feature {
    private unowned let core: Core
    @Published private(set) var peerAccepts = false
    @Published private(set) var shown = 0

    init(core: Core) {
        self.core = core
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendPolicy() {
        core.send(msg(Proto.T.notifPolicy, ["accept": core.sync.get("notifs", "in")]))
    }

    func onWelcome(_ host: Host) {
        peerAccepts = false
        sendPolicy()
    }

    func onClosed() {
        peerAccepts = false
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case Proto.T.notifPolicy:
            peerAccepts = jbool(m, "accept")
        case Proto.T.notif:
            guard core.sync.get("notifs", "in") else { return true }
            let app = {
                let a = jstr(m, "appName", 80)
                return a.isEmpty ? jstr(m, "app", 80) : a
            }()
            let title = jstr(m, "title", 300)
            let sub = jstr(m, "subtitle", 200)
            let body = jstr(m, "body", 1000)
            let text = [sub, body].filter { !$0.isEmpty }.joined(separator: "\n")
            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? app : title
            content.body = text.isEmpty ? "Notification" : text
            content.subtitle = app
            content.sound = .default
            let req = UNNotificationRequest(identifier: jstr(m, "id", 200), content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
            shown += 1
        default:
            return false
        }
        core.changed()
        return true
    }
}

// Files from the computer into Documents/TwinDesk (the Files app shows the whole sandbox).
final class FilesIn: Feature {
    private unowned let core: Core
    @Published var recent: [String] = []
    @Published var receiving: [(name: String, got: Int64, bytes: Int64)] = []

    private let io = DispatchQueue(label: "td-files-in")
    private var incoming: [String: Incoming] = [:]
    private var batches: [String: Batch] = [:]

    private final class Incoming {
        let id: String
        let batch: String
        let name: String
        let rel: String
        let size: Int64
        let url: URL
        var handle: FileHandle?
        var got: Int64 = 0
        var seq = 0
        var hasher = SHA256()
        init(id: String, batch: String, name: String, rel: String, size: Int64, url: URL) {
            self.id = id; self.batch = batch; self.name = name
            self.rel = rel; self.size = size; self.url = url
        }
    }

    private final class Batch {
        let id: String
        let kind: String
        let count: Int
        let bytes: Int64
        var done = 0
        var ok = true
        var got: Int64 = 0
        var tops: [String] = []
        init(id: String, kind: String, count: Int, bytes: Int64) {
            self.id = id; self.kind = kind; self.count = count; self.bytes = bytes
        }
    }

    init(core: Core) { self.core = core }

    var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TwinDesk", isDirectory: true)
    }

    func onWelcome(_ host: Host) {
        core.send(msg(Proto.T.dragPolicy, ["accept": true]))
    }

    func onClosed() {
        io.async {
            for f in self.incoming.values { self.abort(f.id, "disconnected") }
            self.incoming.removeAll()
            self.batches.removeAll()
            DispatchQueue.main.async { self.receiving = [] }
        }
    }

    private func refuse(_ id: String, _ why: String) {
        core.send(msg(Proto.T.fileRefuse, ["id": id, "why": why]))
    }

    private func cleanSegment(_ s: String) -> String {
        var n = s.map { ch -> Character in
            if ch == "\0" || ch == "/" || ch == ":" || ch == "\\" || (ch.asciiValue ?? 0) < 0x20 { return "_" }
            return ch
        }
        var out = String(n).trimmingCharacters(in: .whitespaces)
        if out.isEmpty || out == "." || out == ".." { out = "file" }
        return String(out.prefix(200))
    }

    private func offer(_ m: [String: Any]) {
        let id = jstr(m, "id")
        if id.isEmpty || incoming[id] != nil { return }
        let drop = jstr(m, "drop", 20)
        if drop != "send" && drop != "paste" && drop != "drag" { return refuse(id, "not_allowed") }
        let size = jlong(m, "size", -1)
        if size < 0 || size > 4 * 1024 * 1024 * 1024 { return refuse(id, "too_big") }
        let batchId = (drop == "drag" ? jstr(m, "drag") : jstr(m, "batch")).isEmpty ? id : (drop == "drag" ? jstr(m, "drag") : jstr(m, "batch"))
        var rel = (jstr(m, "rel").isEmpty ? jstr(m, "name") : jstr(m, "rel"))
            .split(separator: "/").map { cleanSegment(String($0)) }.filter { !$0.isEmpty }
        if rel.isEmpty { return refuse(id, "bad_name") }
        if batches[batchId] == nil {
            if drop != "send" && drop != "drag" { return refuse(id, "not_expected") }
            let b = Batch(id: batchId, kind: drop, count: max(1, jint(m, "count", 1)), bytes: jlong(m, "bytes", size))
            b.tops = [rel[0]]
            batches[batchId] = b
        } else if let b = batches[batchId], !b.tops.contains(rel[0]) {
            b.tops.append(rel[0])
        }
        guard let name = rel.last else { return refuse(id, "bad_name") }
        do {
            let dir = documents.appendingPathComponent(rel.dropLast().joined(separator: "/"), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var i = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent("\(base) \(i)\(ext.isEmpty ? "" : ".\(ext)")")
                    i += 1
                }
            }
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let inc = Incoming(id: id, batch: batchId, name: name, rel: rel.joined(separator: "/"), size: size, url: dest)
            inc.handle = try FileHandle(forWritingTo: dest)
            incoming[id] = inc
            core.send(msg(Proto.T.fileAccept, ["id": id]))
        } catch {
            refuse(id, "not_allowed")
            if let b = batches[batchId] { fileFinished(b, false) }
        }
    }

    private func chunk(_ m: [String: Any]) {
        let id = jstr(m, "id")
        guard let f = incoming[id], let data = Data(base64Encoded: jstr(m, "data", Int.max)) else { return }
        if jint(m, "seq") != f.seq || f.got + Int64(data.count) > f.size {
            abort(f.id, "out of order")
            return
        }
        f.seq += 1
        do {
            try f.handle?.write(contentsOf: data)
            f.hasher.update(data: data)
            f.got += Int64(data.count)
            if let b = batches[f.batch] {
                b.got += Int64(data.count)
                DispatchQueue.main.async {
                    self.receiving = self.batches.values.map { ($0.tops.first ?? $0.id, $0.got, $0.bytes) }
                    self.core.changed()
                }
            }
        } catch {
            abort(f.id, "write failed")
        }
    }

    private func end(_ m: [String: Any]) {
        let id = jstr(m, "id")
        guard let f = incoming.removeValue(forKey: id) else { return }
        let batch = batches[f.batch]
        let digest = Data(f.hasher.finalize()).hex
        try? f.handle?.close()
        f.handle = nil
        let ok = f.got == f.size && digest == jstr(m, "sha256", 128)
        if !ok {
            try? FileManager.default.removeItem(at: f.url)
            core.send(msg(Proto.T.fileDone, ["id": f.id, "ok": false, "error": "checksum"]))
            if let b = batch { fileFinished(b, false) }
            return
        }
        core.send(msg(Proto.T.fileDone, [
            "id": f.id, "ok": true,
            "path": "Documents/TwinDesk/\(f.rel)",
        ]))
        if let b = batch { fileFinished(b, true) }
    }

    private func abort(_ id: String, _ why: String) {
        guard let f = incoming.removeValue(forKey: id) else { return }
        try? f.handle?.close()
        try? FileManager.default.removeItem(at: f.url)
        core.send(msg(Proto.T.fileCancel, ["id": id]))
        if let b = batches[f.batch] { fileFinished(b, false) }
    }

    private func fileFinished(_ b: Batch, _ ok: Bool) {
        b.done += 1
        if !ok { b.ok = false }
        if b.done < b.count { return }
        batches.removeValue(forKey: b.id)
        core.send(msg(Proto.T.filesDone, [
            "batch": b.id, "ok": b.ok, "where": "Documents/TwinDesk", "files": b.done,
        ]))
        let from = core.host?.name ?? "your computer"
        let what = b.tops.count == 1 ? b.tops[0] : plural(b.tops.count, "item")
        DispatchQueue.main.async {
            self.recent.insert("\(b.ok ? "Received" : "Some of") \(what) from \(from)", at: 0)
            if self.recent.count > 20 { self.recent.removeLast(self.recent.count - 20) }
            self.receiving = self.batches.values.map { ($0.tops.first ?? $0.id, $0.got, $0.bytes) }
            self.core.changed()
        }
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        switch t {
        case Proto.T.fileOffer: io.async { self.offer(m) }
        case Proto.T.fileChunk: io.async { self.chunk(m) }
        case Proto.T.fileEnd: io.async { self.end(m) }
        case Proto.T.fileCancel:
            io.async { self.abort(jstr(m, "id"), "cancelled") }
        case Proto.T.fileAccept, Proto.T.fileRefuse, Proto.T.fileDone, Proto.T.filesDone, Proto.T.dragPolicy:
            break
        case "drag.start":
            let id = jstr(m, "drag")
            if !id.isEmpty {
                if jint(m, "files", 0) == 0 {
                    core.send(msg("drag.end", ["drag": id, "result": "dropped", "where": "Documents/TwinDesk"]))
                }
            }
        default:
            return false
        }
        return true
    }
}

// This device as the computer's remote (the Remote page): touchpad and keyboard in a WebView.
final class Remote: Feature {
    private unowned let core: Core
    @Published private(set) var allowed: Bool?
    @Published private(set) var why = ""
    @Published private(set) var active = false
    private var host: WebHost?
    private var mode = "pad"

    init(core: Core) { self.core = core }

    var speed: Float {
        get { Float(core.store.prefsString("remote.speed", "1.0"))?.clamped(to: 0.3...3) ?? 1 }
        set {
            core.store.setPrefsString("remote.speed", String(format: "%.2f", newValue))
            push()
        }
    }

    var tapClick: Bool {
        get { core.store.flag("remote.tapClick", true) }
        set {
            core.store.setFlag("remote.tapClick", newValue)
            push()
        }
    }

    func opts() -> [String: Any] {
        msg("opts", [
            "mode": mode,
            "name": core.host?.name ?? "the computer",
            "me": core.store.deviceName,
            "connected": core.host != nil,
            "os": core.host?.os ?? "",
            "ble": false,
            "speed": Double(speed),
            "tap": tapClick,
            "smooth": core.store.flag("remote.smooth", true),
            "pad": [String: String](),
            "bt": false,
            "btName": "",
            "controls": [[Any]](),
            "keys": [[Any]](),
        ])
    }

    private func push() {
        host?.post(opts())
        core.screen.repost()
        core.changed()
    }

    private func hello() {
        if core.link.connected { core.send(msg(Proto.T.remoteHello)) }
    }

    func attach(_ h: WebHost, mode: String) {
        host = h
        self.mode = mode
        active = true
        h.post(opts())
        if let allowed { h.post(msg(Proto.T.remoteState, ["allowed": allowed])) }
        hello()
        core.changed()
    }

    func detach(_ h: WebHost) {
        if host !== h { return }
        host = nil
        active = false
        if core.link.connected { core.send(msg(Proto.T.remoteRelease)) }
        core.changed()
    }

    func onWelcome(_ host: Host) {
        allowed = nil
        self.host?.post(opts())
        if active { hello() }
    }

    func onClosed() {
        allowed = nil
        host?.post(opts())
    }

    func onMessage(_ t: String, _ m: [String: Any]) -> Bool {
        if t != Proto.T.remoteState { return false }
        allowed = jbool(m, "allowed", false)
        why = jstr(m, "why")
        host?.post(m)
        core.changed()
        return true
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
