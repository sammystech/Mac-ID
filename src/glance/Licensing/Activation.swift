//
//  Activation.swift
//  Mac ID
//
//  One Mac per licence key.
//
//  A key is still verified offline (LicenseManager.verify), but it only counts once the fulfilment
//  service has bound it to this Mac. The first Mac to present a key gets it; the same Mac presenting it
//  again (a reinstall) is fine; any other Mac is refused until the binding is released from the admin
//  dashboard. That's what stops one purchase being passed around.
//
//  What leaves this Mac, and only at activation: a SHA-256 of the licence key and a SHA-256 of the
//  hardware UUID, plus the app and macOS versions and the Terms of Use version agreed to. Never the key itself, the UUID itself, a name, an
//  email, face data, or anything about the stored password.
//
//  The service answers with a receipt: an HMAC over the key hash and the Mac fingerprint. It's stored
//  locally and checked at every launch, so after activation Mac ID works offline indefinitely, and a
//  receipt copied to another Mac is worthless there.
//

import CryptoKit
import Foundation
import IOKit

nonisolated enum Activation {
    /// macid.net, the product's own domain. nmx.net keeps answering the same path for copies that
    /// shipped before the move, so older versions keep activating.
    static let endpoint = URL(string: "https://macid.net/api/activate")!

    enum Outcome {
        case activated(receipt: String)
        case alreadyActivatedElsewhere
        case unreachable
    }

    /// SHA-256 of this Mac's hardware UUID, salted so the fingerprint is meaningless outside Mac ID.
    /// Stable across app reinstalls and macOS reinstalls on the same hardware.
    static let machineFingerprint: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = (IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? "unknown-mac"
        return sha256Hex("macid-machine-v1|" + uuid)
    }()

    /// The canonical form of a key, so "abcd-efgh…", "ABCD EFGH…", "MACID-ABCD…" and a key retyped with
    /// O for 0 all hash identically. Mirrors the folding in `LicenseManager.base32Decode`.
    static func keyHash(_ key: String) -> String {
        var canonical = key.uppercased().replacingOccurrences(of: "MACID", with: "")
        canonical = String(canonical.compactMap { character -> Character? in
            switch character {
            case "-", " ", "\n", "\r", "\t": return nil
            case "I", "L": return "1"
            case "O": return "0"
            case "U": return "V"
            default: return character
            }
        })
        return sha256Hex(canonical)
    }

    static func expectedReceipt(keyHash: String, machine: String) -> String {
        let secret = SymmetricKey(data: Data(LicenseSecret.receipt.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("macid-activation-v1|\(keyHash)|\(machine)".utf8), using: secret)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func receiptIsValid(_ receipt: String?, for key: String) -> Bool {
        guard let receipt, !receipt.isEmpty else { return false }
        let expected = expectedReceipt(keyHash: keyHash(key), machine: machineFingerprint)
        // Constant-time, same reasoning as the licence tag comparison.
        let a = Array(receipt.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func activate(key: String) async -> Outcome {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let body: [String: String] = [
            "key_hash": keyHash(key),
            "machine": machineFingerprint,
            "version": version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            // The Terms of Use version agreed to on this Mac, so the dashboard can show it per licence.
            "terms": Terms.acceptedVersion ?? "",
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Named explicitly: Cloudflare's bot check in front of the service rejects some generic
        // client identifiers outright (it blocked Python's default with error 1010).
        request.setValue("MacID/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unreachable }
        if http.statusCode == 409 { return .alreadyActivatedElsewhere }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let receipt = json["receipt"] as? String,
              receipt == expectedReceipt(keyHash: keyHash(key), machine: machineFingerprint)
        else { return .unreachable }
        return .activated(receipt: receipt)
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
