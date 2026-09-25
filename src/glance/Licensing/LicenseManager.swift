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
    case alreadyActivatedElsewhere
    case activationUnavailable

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "That doesn't look like a Mac ID licence key. It should be 16 characters, like ABCD-EFGH-JKMN-PQRS."
        case .badSignature:
            return "That key isn't valid. Check for a typo, or paste it again from your email."
        case .alreadyActivatedElsewhere:
            return "This key is already activated on another Mac. Each key works on one Mac. Moving to a new Mac? Email \(AboutSettingsPage.supportEmail) and we'll move it for you."
        case .activationUnavailable:
            return "Couldn't reach the activation server. Check your internet connection and try again."
        }
    }
}

@Observable
@MainActor
final class LicenseManager {
    static let shared: LicenseManager = {
        LegacyMigration.migrateIfNeeded()
        return LicenseManager()
    }()

    /// Retained only to keep pre-existing long keys working. New keys are HMAC-based.
    private static let publicKeyBase64 = "IuNM6yWM8lpbEkTqMilwwRdImSb/qqMh1OnRa0hnejk="

    private static let storageKey = "GlanceSettings.licenseKey"
    /// Proof from the fulfilment service that the stored key belongs to THIS Mac. See Activation.swift.
    private static let receiptKey = "MacID.activationReceipt"
    /// When a valid key was first accepted without the service's confirmation (see `activate`).
    private static let pendingSinceKey = "MacID.activationPendingSince"
    /// How long a valid key keeps working while the service can't be reached. Long enough that an
    /// outage on our side never stops a customer; short enough that blocking macid.net isn't a way
    /// to run one key on several Macs.
    static let offlineGrace: TimeInterval = 7 * 86_400

    private(set) var licenseID: UInt64?
    /// Re-derived from the stored key and receipt at launch rather than persisted as a bool, so
    /// flipping a preference can't grant a licence.
    var isLicensed: Bool { licenseID != nil }

    /// A key stored before activation existed, not yet bound to a Mac. Honoured while the service
    /// can't be reached so an existing customer is never locked out by a network hiccup, and dropped
    /// the moment the service says the key belongs to another Mac.
    private(set) var awaitingActivation = false
    /// Set when the stored key was refused because another Mac holds it; shown at the licence gate.
    private(set) var refusedMessage: String?

    /// What actually gates the app: a paid key, or a trial that hasn't run out yet.
    var isEntitled: Bool { isLicensed || TrialManager.shared.isActive }

    private let defaults = UserDefaults.standard

    private init() {
        guard let stored = defaults.string(forKey: Self.storageKey),
              let payload = try? Self.verify(stored) else { return }
        if Activation.receiptIsValid(defaults.string(forKey: Self.receiptKey), for: stored) {
            licenseID = payload.id
        } else {
            // Not confirmed yet: accepted while the service was unreachable, stored before
            // activation existed, or a receipt for a different Mac (the preferences were copied).
            // Counted within the grace period; `completePendingActivation()` settles it.
            awaitingActivation = true
            let since = defaults.object(forKey: Self.pendingSinceKey) as? Date ?? {
                let now = Date()
                defaults.set(now, forKey: Self.pendingSinceKey)
                return now
            }()
            if Date().timeIntervalSince(since) < Self.offlineGrace {
                licenseID = payload.id
            } else {
                refusedMessage = "Mac ID couldn't confirm your licence with macid.net for a week. Connect to the internet, then enter your key again."
            }
        }
    }

    /// Verifies the key offline, then binds it to this Mac with the fulfilment service.
    ///
    /// A key the service says belongs to another Mac is refused and not stored. A genuine key that
    /// can't be confirmed because the service is unreachable is accepted anyway, so a real purchase
    /// works every time; it's confirmed at the next launch, wake or unlock, and has
    /// `offlineGrace` to get there.
    func activate(_ key: String) async throws {
        let payload = try Self.verify(key)
        switch await Activation.activate(key: key) {
        case .activated(let receipt):
            defaults.set(key, forKey: Self.storageKey)
            defaults.set(receipt, forKey: Self.receiptKey)
            defaults.removeObject(forKey: Self.pendingSinceKey)
            licenseID = payload.id
            awaitingActivation = false
            refusedMessage = nil
        case .alreadyActivatedElsewhere:
            throw LicenseError.alreadyActivatedElsewhere
        case .unreachable:
            defaults.set(key, forKey: Self.storageKey)
            defaults.removeObject(forKey: Self.receiptKey)
            if defaults.object(forKey: Self.pendingSinceKey) == nil {
                defaults.set(Date(), forKey: Self.pendingSinceKey)
            }
            licenseID = payload.id
            awaitingActivation = true
            refusedMessage = nil
        }
    }

    /// Confirms a key that hasn't been confirmed yet. Called at launch, wake and unlock; does
    /// nothing once the key is confirmed.
    func completePendingActivation() async {
        guard awaitingActivation, let stored = defaults.string(forKey: Self.storageKey) else { return }
        switch await Activation.activate(key: stored) {
        case .activated(let receipt):
            defaults.set(receipt, forKey: Self.receiptKey)
            defaults.removeObject(forKey: Self.pendingSinceKey)
            licenseID = (try? Self.verify(stored))?.id
            awaitingActivation = false
            refusedMessage = nil
        case .alreadyActivatedElsewhere:
            deactivate()
            refusedMessage = LicenseError.alreadyActivatedElsewhere.errorDescription
        case .unreachable:
            break   // Keep working; try again next launch.
        }
    }

    /// Removes the key from this Mac only. It does NOT free the key for another Mac - otherwise
    /// activate, remove, hand it on would defeat the one-Mac rule. Moving a key is done from the
    /// admin dashboard.
    func deactivate() {
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.receiptKey)
        defaults.removeObject(forKey: Self.pendingSinceKey)
        licenseID = nil
        awaitingActivation = false
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
