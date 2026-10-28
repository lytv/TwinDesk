// TwinDesk — Copyright (C) 2026 inukaasith. GPL-3.0, see LICENSE.
// The wire protocol from the iPad's side: the same constants and pairing math as
// shared/protocol.js and android/Proto.kt (keep the three in step).
//
// OS is "android" on the wire: computers gate phone features on `os === 'android'`
// (shared/protocol.js). Saying "ios" would hide Screen, Remote, Clipboard and the rest.
import Foundation
import CryptoKit

enum Proto {
    static let version = 1
    static let port = 47800
    static let discoveryPort = 47801
    static let beaconMs = 2000.0
    static let deviceStaleMs = 10000.0
    static let pingMs = 1000.0
    static let timeoutMs = 4000.0
    static let phoneGraceMs = 30000.0
    static let clipMaxBytes = 256 * 1024
    static let clipImageMaxBytes = 10 * 1024 * 1024
    static let clipImagePartBytes = 256 * 1024
    static let fileChunkBytes = 64 * 1024
    static let maxPayload = 16 * 1024 * 1024
    static let os = "android"
    private static let sasLabel = "macshare-sas-v1"

    enum T {
        static let beacon = "beacon"
        static let probe = "probe"
        static let invite = "invite"
        static let pairStart = "pair.start"
        static let pairNonce = "pair.nonce"
        static let pairReveal = "pair.reveal"
        static let pairConfirm = "pair.confirm"
        static let pairOk = "pair.ok"
        static let pairCancel = "pair.cancel"
        static let hello = "hello"
        static let welcome = "welcome"
        static let error = "error"
        static let ping = "ping"
        static let pong = "pong"
        static let bye = "bye"
        static let clip = "clip"
        static let clipPolicy = "clip.policy"
        static let clipImage = "clip.image"
        static let clipImagePart = "clip.image.part"
        static let notif = "notif"
        static let notifPolicy = "notif.policy"
        static let fileOffer = "file.offer"
        static let fileAccept = "file.accept"
        static let fileRefuse = "file.refuse"
        static let fileChunk = "file.chunk"
        static let fileEnd = "file.end"
        static let fileDone = "file.done"
        static let fileCancel = "file.cancel"
        static let filesDone = "files.done"
        static let dragPolicy = "drag.policy"
        static let pairSync = "pair.sync"
        static let remoteHello = "remote.hello"
        static let remoteState = "remote.state"
        static let remoteRelease = "remote.release"
    }

    enum E {
        static let versionMismatch = "version_mismatch"
        static let badToken = "bad_token"
        static let pairRefused = "pair_refused"
        static let pairTimeout = "pair_timeout"
        static let busy = "busy"
        static let replaced = "replaced"
        static let released = "released"
        static let asleep = "asleep"
    }

    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func commitOf(_ nonceHex: String) -> String {
        sha256(Data(hex: nonceHex)).hex
    }

    // The 6-digit code both sides show:
    // sha256(SAS_LABEL || fp bytes || nw bytes || nm bytes), first 4 bytes as uint32 BE, mod 1e6.
    static func sasCode(fp: String?, nwHex: String, nmHex: String) -> String {
        var h = Data(sasLabel.utf8)
        h += Data(hex: normFingerprint(fp))
        h += Data(hex: nwHex)
        h += Data(hex: nmHex)
        let d = sha256(h)
        var n: UInt32 = 0
        for i in 0..<4 { n = (n << 8) | UInt32(d[d.startIndex + i]) }
        return String(format: "%06d", n % 1000000)
    }

    static func normFingerprint(_ fp: String?) -> String {
        (fp ?? "").replacingOccurrences(of: ":", with: "").lowercased()
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        var s = hex
        if s.count % 2 != 0 { s = "0" + s }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            if let b = UInt8(s[i..<next], radix: 16) { bytes.append(b) }
            i = next
        }
        self.init(bytes)
    }
}

// Wire helpers: msg("t", "k": v, …) like the Android JSONObject builders.
func msg(_ t: String, _ fields: [String: Any?] = [:]) -> [String: Any] {
    var o: [String: Any] = ["t": t]
    for (k, v) in fields { o[k] = v ?? NSNull() }
    return o
}

func jsonStr(_ m: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: m)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

func parseJson(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))).flatMap { $0 as? [String: Any] }
}

func jstr(_ m: [String: Any], _ key: String, _ max: Int = 500) -> String {
    let v = (m[key] as? String) ?? ""
    return String(v.prefix(max))
}

func jbool(_ m: [String: Any], _ key: String, _ def: Bool = false) -> Bool {
    (m[key] as? Bool) ?? def
}

func jint(_ m: [String: Any], _ key: String, _ def: Int = 0) -> Int {
    if let n = m[key] as? Int { return n }
    if let n = m[key] as? NSNumber { return n.intValue }
    return def
}

func jlong(_ m: [String: Any], _ key: String, _ def: Int64 = 0) -> Int64 {
    if let n = m[key] as? Int64 { return n }
    if let n = m[key] as? Int { return Int64(n) }
    if let n = m[key] as? NSNumber { return n.int64Value }
    return def
}

func plural(_ n: Int, _ what: String) -> String {
    "\(n) \(what)\(n == 1 ? "" : "s")"
}

func pct(_ a: Int64, _ b: Int64) -> Int {
    b <= 0 ? 100 : min(100, max(0, Int(a * 100 / b)))
}
