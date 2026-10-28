// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// What the iPad remembers: its identity, the computers it paired with (hosts) and its settings.
import Foundation
import UIKit

// A paired computer this iPad connects to (it hosts the session).
struct Host: Identifiable, Equatable {
    var id: String
    var name: String
    var os: String
    var address: String
    var port: Int
    var fp: String
    var token: String
    var lastSeen: Int64

    func json() -> [String: Any] {
        ["id": id, "name": name, "os": os, "address": address,
         "port": port, "fp": fp, "token": token, "lastSeen": lastSeen]
    }

    static func from(_ o: [String: Any]) -> Host? {
        guard let id = o["id"] as? String, let fp = o["fp"] as? String, let token = o["token"] as? String
        else { return nil }
        return Host(
            id: id,
            name: jstr(o, "name", 64).isEmpty ? "Mac" : jstr(o, "name", 64),
            os: jstr(o, "os", 16).isEmpty ? "mac" : jstr(o, "os", 16),
            address: jstr(o, "address", 100),
            port: jint(o, "port", Proto.port),
            fp: fp,
            token: token,
            lastSeen: jlong(o, "lastSeen")
        )
    }
}

final class Store {
    private let prefs = UserDefaults.standard

    // Every feature is off on a fresh install until it's turned on; an iPad that had TwinDesk
    // before keeps what it had. Decided once, before anything is saved.
    let was: Bool
    let deviceId: String

    var deviceName: String {
        get {
            (prefs.string(forKey: "deviceName")?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                ?? UIDevice.current.name
        }
        set { prefs.set(newValue.trimmingCharacters(in: .whitespaces).prefix(64).description, forKey: "deviceName") }
    }

    init() {
        if prefs.object(forKey: "was") != nil {
            was = prefs.bool(forKey: "was")
        } else {
            was = prefs.object(forKey: "deviceId") != nil
            prefs.set(was, forKey: "was")
        }
        if let existing = prefs.string(forKey: "deviceId") {
            deviceId = existing
        } else {
            let id = Proto.randomHex(16)
            prefs.set(id, forKey: "deviceId")
            deviceId = id
        }
    }

    func hosts() -> [Host] {
        guard let data = prefs.string(forKey: "hosts").flatMap({ $0.data(using: .utf8) }),
              let a = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return a.compactMap(Host.from)
    }

    func saveHosts(_ list: [Host]) {
        let a = list.map { $0.json() }
        if let data = try? JSONSerialization.data(withJSONObject: a),
           let s = String(data: data, encoding: .utf8) {
            prefs.set(s, forKey: "hosts")
        }
    }

    func putHost(_ h: Host) {
        saveHosts([h] + hosts().filter { $0.id != h.id })
    }

    func forgetHost(_ id: String) {
        saveHosts(hosts().filter { $0.id != id })
    }

    func flag(_ key: String, _ def: Bool) -> Bool {
        if prefs.object(forKey: key) == nil { return def }
        return prefs.bool(forKey: key)
    }

    func setFlag(_ key: String, _ on: Bool) {
        prefs.set(on, forKey: key)
    }

    func prefsString(_ key: String, _ def: String) -> String {
        prefs.string(forKey: key) ?? def
    }

    func setPrefsString(_ key: String, _ v: String) {
        prefs.set(v, forKey: key)
    }

    func prefsSet(_ key: String) -> Set<String> {
        Set(prefs.stringArray(forKey: key) ?? [])
    }

    func setPrefsSet(_ key: String, _ v: Set<String>) {
        prefs.set(Array(v), forKey: key)
    }

    func pairSync(_ hostId: String) -> [String: Any]? {
        prefs.string(forKey: "sync.\(hostId)").flatMap { parseJson($0) }
    }

    func setPairSync(_ hostId: String, _ v: [String: Any]) {
        prefs.set(jsonStr(v), forKey: "sync.\(hostId)")
    }
}
