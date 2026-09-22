//
//  licensetool
//
//  Mints and inspects Mac ID licence keys. Build:
//
//      swiftc -O -o /usr/local/bin/macid-license tools/licensetool/main.swift
//
//  Usage:
//      macid-license init                 create the signing keypair (once, ever)
//      macid-license pubkey               print the public key to paste into the app
//      macid-license mint [note]          mint one licence key
//      macid-license mint-batch <n>       mint n keys as CSV, for bulk upload to a store
//      macid-license verify <key>         check a key against the public key
//
//  The Ed25519 PRIVATE key lives in the login keychain and never leaves this machine. Only the
//  public key is compiled into the app, so the app can verify keys but cannot mint them — which is
//  the whole point of using a signature rather than a checksum. Anyone who extracts a secret from
//  a shipped binary can mint unlimited keys; with this design there is no such secret to extract.
//
//  Back the private key up. Losing it means you can never mint another key that existing copies
//  will accept, and changing the public key invalidates every licence already sold.
//

import Foundation
import CryptoKit

let service = "com.samuelmittman.macid.licensing"
let account = "ed25519-signing-key"

// MARK: - Keychain

func keychainRead() -> Data? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
}

func keychainWrite(_ data: Data) throws {
    let delete: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(delete as CFDictionary)
    let add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

// MARK: - Key encoding
//
// Crockford Base32: no I, L, O or U, so a key read aloud or retyped can't be garbled into a
// different valid key. Decoding folds the confusable characters back, so a buyer typing O for 0
// still gets in.

let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

func base32Encode(_ data: Data) -> String {
    var out = ""
    var buffer = 0, bits = 0
    for byte in data {
        buffer = (buffer << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            out.append(alphabet[(buffer >> (bits - 5)) & 31])
            bits -= 5
        }
    }
    if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
    return out
}

func base32Decode(_ string: String) -> Data? {
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

/// Groups of 4: `ABCD-EFGH-JKMN-PQRS`. No `MACID-` prefix — it was pure length, and the app strips
/// it anyway if a buyer pastes an older key that has one.
func format(_ raw: String) -> String {
    var groups: [String] = []
    var index = raw.startIndex
    while index < raw.endIndex {
        let end = raw.index(index, offsetBy: 4, limitedBy: raw.endIndex) ?? raw.endIndex
        groups.append(String(raw[index..<end]))
        index = end
    }
    return groups.joined(separator: "-")
}

// MARK: - Secret

let hmacAccount = "hmac-secret"

func loadSecret() -> SymmetricKey {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: hmacAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let raw = item as? Data,
          let secret = Data(base64Encoded: String(decoding: raw, as: UTF8.self)) else {
        FileHandle.standardError.write(Data("No licence secret. Run `macid-license init` first.\n".utf8))
        exit(1)
    }
    return SymmetricKey(data: secret)
}

// MARK: - Licence keys
//
// 4-byte id + 6-byte HMAC tag = 10 bytes = exactly 16 Base32 characters, shown as four groups of
// four. The tag is what makes a key checkable offline; 6 bytes is the smallest that still makes
// guessing one hopeless for anyone who does not already have the secret.
//
// A 32-bit id allows ~4.3 billion licences and is what you look a buyer up by.

let idLength = 4
let tagLength = 6

func tag(forID id: UInt32, secret: SymmetricKey) -> Data {
    var idBytes = Data()
    withUnsafeBytes(of: id.bigEndian) { idBytes.append(contentsOf: $0) }
    return Data(HMAC<SHA256>.authenticationCode(for: idBytes, using: secret)).prefix(tagLength)
}

func mintKey(secret: SymmetricKey) -> (key: String, id: UInt32) {
    // Random rather than sequential: sequential ids would let anyone holding one key guess the
    // ids of every other licence, which matters if the secret ever does leak.
    let id = UInt32.random(in: 1...UInt32.max)
    var idBytes = Data()
    withUnsafeBytes(of: id.bigEndian) { idBytes.append(contentsOf: $0) }
    return (format(base32Encode(idBytes + tag(forID: id, secret: secret))), id)
}

let epoch = DateComponents(calendar: .init(identifier: .gregorian), year: 2020, month: 1, day: 1).date!
func today() -> UInt16 { UInt16(Date().timeIntervalSince(epoch) / 86_400) }
func dayToDate(_ d: UInt16) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    return f.string(from: epoch.addingTimeInterval(Double(d) * 86_400))
}

// MARK: - Commands

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let raw = keychainRead(),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("No signing key. Run `macid-license init` first.\n".utf8))
        exit(1)
    }
    return key
}


func secretExists() -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: hmacAccount,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

func writeSecret(_ base64: String) throws {
    let delete: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: hmacAccount,
    ]
    SecItemDelete(delete as CFDictionary)
    let add: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: hmacAccount,
        kSecValueData as String: Data(base64.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}

func loadSecretRaw() -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: hmacAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let raw = item as? Data else {
        FileHandle.standardError.write(Data("No licence secret. Run `macid-license init` first.\n".utf8))
        exit(1)
    }
    return String(decoding: raw, as: UTF8.self)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {

case "init":
    // Two secrets now: the HMAC secret that short keys use, and the Ed25519 key kept only so keys
    // issued under the old long format still verify.
    var created: [String] = []
    if secretExists() {
        FileHandle.standardError.write(Data("""
            A licence secret already exists. Refusing to overwrite it — doing so would invalidate
            every licence you have already issued. Delete it deliberately if that is really what
            you want:
                security delete-generic-password -s \(service) -a \(hmacAccount)

            """.utf8))
        exit(1)
    }
    var bytes = Data(count: 32)
    _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    try writeSecret(bytes.base64EncodedString())
    created.append("licence secret")

    if keychainRead() == nil {
        try keychainWrite(Curve25519.Signing.PrivateKey().rawRepresentation)
        created.append("legacy signing key")
    }
    print("Created: \(created.joined(separator: ", ")).\n")
    print("Paste this into src/glance/Licensing/LicenseSecret.swift:\n")
    print("    static let raw = \"\(bytes.base64EncodedString())\"\n")
    print("Back it up now — losing it means you can never issue another key that existing copies")
    print("will accept:")
    print("    security find-generic-password -s \(service) -a \(hmacAccount) -w\n")

case "secret":
    // Printed so it can be pasted into LicenseSecret.swift after a fresh checkout.
    print(loadSecretRaw())

case "pubkey":
    print(loadPrivateKey().publicKey.rawRepresentation.base64EncodedString())

case "mint":
    let (licence, id) = mintKey(secret: loadSecret())
    let note = args.dropFirst().joined(separator: " ")
    print(licence)
    FileHandle.standardError.write(Data("id=\(id) issued=\(dayToDate(today()))\(note.isEmpty ? "" : " note=\(note)")\n".utf8))

case "mint-batch":
    guard let count = Int(args.dropFirst().first ?? ""), count > 0, count <= 100_000 else {
        FileHandle.standardError.write(Data("usage: macid-license mint-batch <1-100000>\n".utf8)); exit(1)
    }
    let secret = loadSecret()
    print("license_key,license_id,issued")
    for _ in 0..<count {
        let (licence, id) = mintKey(secret: secret)
        print("\(licence),\(id),\(dayToDate(today()))")
    }

case "verify":
    guard let input = args.dropFirst().first else {
        FileHandle.standardError.write(Data("usage: macid-license verify <key>\n".utf8)); exit(1)
    }
    let stripped = input.uppercased().replacingOccurrences(of: "MACID", with: "")
    guard let blob = base32Decode(stripped) else {
        print("INVALID — not a well-formed key"); exit(1)
    }
    if blob.count == idLength + tagLength {
        let idBytes = blob.prefix(idLength)
        let id = idBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let expected = tag(forID: id, secret: loadSecret())
        if Data(blob.suffix(tagLength)) == expected {
            print("VALID   id=\(id)")
        } else {
            print("INVALID — tag does not match"); exit(1)
        }
    } else if blob.count == 11 + 64 {
        // Old long-format key.
        let body = blob.prefix(11)
        let signature = blob.suffix(from: blob.index(blob.startIndex, offsetBy: 11)).prefix(64)
        if loadPrivateKey().publicKey.isValidSignature(signature, for: body) {
            let idBytes = body[body.index(body.startIndex, offsetBy: 1)..<body.index(body.startIndex, offsetBy: 9)]
            print("VALID   id=\(idBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })  (legacy long key)")
        } else {
            print("INVALID — signature does not verify"); exit(1)
        }
    } else {
        print("INVALID — wrong length"); exit(1)
    }

default:
    print("""
    macid-license — mint and check Mac ID licence keys

        init                 create the licence secret (once, ever)
        secret               print the secret to paste into LicenseSecret.swift
        pubkey               print the legacy public key
        mint [note]          mint one licence key
        mint-batch <n>       mint n keys as CSV, for bulk upload to a store
        verify <key>         check a key
    """)
}
