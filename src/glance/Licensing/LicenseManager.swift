//
//  LicenseManager.swift
//  Mac ID
//
//  Offline licence verification.
//
//  Keys are short — 16 characters, `XXXX-XXXX-XXXX-XXXX` — and that length is the whole design
//  constraint. A key carries its own proof of validity (nothing is looked up over the network), so
//  the proof has to fit in the key. An Ed25519 signature is 64 bytes and produced 145-character
//  keys, which is miserable to read off an email and retype. A truncated HMAC fits in 6.
//
//  The cost is explicit: HMAC is symmetric, so the secret that verifies a key is also the secret
//  that mints one, and it ships inside this binary. Anyone who pulls it out can issue their own
//  keys. That is a real downgrade from signatures, taken deliberately in exchange for a key a
//  person can actually type. It is not hidden by obscurity of the algorithm — only by the secret
//  not being in the public repo.
//
//  What no offline scheme can do, signatures included, is stop someone patching the check out of a
//  binary they already have. That was already true. See LicenseSecret.swift.
//
//  Keys issued under the old 145-character signature format still verify, so nothing already sold
//  stops working.
//

import Foundation
import CryptoKit
import Observation

enum LicenseError: LocalizedError {
    case malformed
    case badSignature

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "That doesn't look like a Mac ID licence key. It should be 16 characters, like ABCD-EFGH-JKMN-PQRS."
        case .badSignature:
            return "That key isn't valid. Check for a typo, or paste it again from your email."
        }
    }
}

@Observable
@MainActor
final class LicenseManager {
    static let shared = LicenseManager()

    /// Retained only to keep pre-existing long keys working. New keys are HMAC-based.
    private static let publicKeyBase64 = "IuNM6yWM8lpbEkTqMilwwRdImSb/qqMh1OnRa0hnejk="

    private static let storageKey = "GlanceSettings.licenseKey"

    private(set) var licenseID: UInt64?
    /// Re-derived from the stored key at launch rather than persisted as a bool, so flipping a
    /// preference can't grant a licence.
    var isLicensed: Bool { licenseID != nil }

    /// What actually gates the app: a paid key, or a trial still inside its 3 days.
    var isEntitled: Bool { isLicensed || TrialManager.shared.isActive }

    private let defaults = UserDefaults.standard

    private init() {
        if let stored = defaults.string(forKey: Self.storageKey),
           let payload = try? Self.verify(stored) {
            licenseID = payload.id
        }
    }

    /// Verifies and, on success, stores the key.
    func activate(_ key: String) throws {
        let payload = try Self.verify(key)
        defaults.set(key, forKey: Self.storageKey)
        licenseID = payload.id
    }

    func deactivate() {
        defaults.removeObject(forKey: Self.storageKey)
        licenseID = nil
    }

    // MARK: - Verification

    struct Payload {
        let id: UInt64
    }

    /// Pure and `static` so it can be exercised without touching stored state.
    static func verify(_ key: String) throws -> Payload {
        let stripped = key.uppercased().replacingOccurrences(of: "MACID", with: "")
        guard let blob = base32Decode(stripped) else { throw LicenseError.malformed }

        switch blob.count {
        case shortKeyLength:
            return try verifyShort(blob)
        case legacyPayloadLength + legacySignatureLength:
            return try verifyLegacy(blob)
        default:
            throw LicenseError.malformed
        }
    }

    // MARK: Short keys (current)

    /// 4-byte big-endian id + 6-byte HMAC tag = 10 bytes = exactly 16 Base32 characters.
    private static let shortIDLength = 4
    private static let shortTagLength = 6
    private static let shortKeyLength = shortIDLength + shortTagLength

    private static func verifyShort(_ blob: Data) throws -> Payload {
        let idBytes = blob.prefix(shortIDLength)
        let tag = Data(blob.suffix(shortTagLength))

        guard let secret = Data(base64Encoded: LicenseSecret.raw) else {
            throw LicenseError.badSignature
        }
        let expected = Data(
            HMAC<SHA256>.authenticationCode(for: Data(idBytes), using: SymmetricKey(data: secret))
        ).prefix(shortTagLength)

        // Constant-time: `==` on Data short-circuits at the first differing byte, which leaks how
        // much of a guessed tag was right and turns forgery into a per-byte search.
        guard constantTimeEquals(tag, Data(expected)) else { throw LicenseError.badSignature }

        return Payload(id: idBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    private static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    // MARK: Legacy signature keys

    private static let legacyPayloadLength = 11
    private static let legacySignatureLength = 64

    private static func verifyLegacy(_ blob: Data) throws -> Payload {
        let body = blob.prefix(legacyPayloadLength)
        let signature = blob.suffix(legacySignatureLength)

        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              publicKey.isValidSignature(signature, for: body) else {
            throw LicenseError.badSignature
        }
        guard body.count == legacyPayloadLength, body[body.startIndex] == 1 else {
            throw LicenseError.malformed
        }
        let idBytes = body[body.index(body.startIndex, offsetBy: 1)..<body.index(body.startIndex, offsetBy: 9)]
        return Payload(id: idBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
    }

    // MARK: - Crockford Base32
    //
    // No I, L, O or U in the alphabet, and decoding folds those characters back onto the digits
    // they resemble — so a buyer who retypes O for 0 or l for 1 still gets in rather than being
    // told their valid key is invalid.

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func base32Decode(_ string: String) -> Data? {
        var buffer = 0, bits = 0
        var out = Data()
        for character in string.uppercased() where !"- \n\r\t".contains(character) {
            let folded: Character
            switch character {
            case "I", "L": folded = "1"
            case "O": folded = "0"
            case "U": folded = "V"
            default: folded = character
            }
            guard let value = alphabet.firstIndex(of: folded) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }
}
