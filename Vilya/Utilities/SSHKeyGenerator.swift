import Foundation
import CryptoKit

class SSHKeyGenerator {
    struct KeyPair { let publicKey: String; let privateKey: String; let fingerprint: String }

    static func generateEd25519KeyPair(comment: String = "vilya-iphone") throws -> KeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        return KeyPair(
            publicKey: formatPublicKeySSH(publicKey: publicKey, comment: comment),
            privateKey: formatPrivateKeyPEM(privateKey: privateKey),
            fingerprint: calculateFingerprint(publicKey: publicKey)
        )
    }

    private static func formatPublicKeySSH(publicKey: Curve25519.Signing.PublicKey, comment: String) -> String {
        var keyData = Data()
        let keyType = "ssh-ed25519".data(using: .utf8)!
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(keyType.count).bigEndian) { Array($0) })
        keyData.append(keyType)
        let pubKeyBytes = publicKey.rawRepresentation
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(pubKeyBytes.count).bigEndian) { Array($0) })
        keyData.append(pubKeyBytes)
        return "ssh-ed25519 \(keyData.base64EncodedString()) \(comment)"
    }

    private static func formatPrivateKeyPEM(privateKey: Curve25519.Signing.PrivateKey) -> String {
        let privateKeyBytes = privateKey.rawRepresentation
        let publicKeyBytes = privateKey.publicKey.rawRepresentation
        var keyData = Data()
        keyData.append("openssh-key-v1\0".data(using: .utf8)!)
        appendString(&keyData, "none"); appendString(&keyData, "none"); appendString(&keyData, "")
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(1).bigEndian) { Array($0) })
        var pubSection = Data(); appendString(&pubSection, "ssh-ed25519"); appendBytes(&pubSection, publicKeyBytes)
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(pubSection.count).bigEndian) { Array($0) }); keyData.append(pubSection)
        var privSection = Data()
        let checkBytes = UInt32.random(in: 0...UInt32.max)
        privSection.append(contentsOf: withUnsafeBytes(of: checkBytes.bigEndian) { Array($0) })
        privSection.append(contentsOf: withUnsafeBytes(of: checkBytes.bigEndian) { Array($0) })
        appendString(&privSection, "ssh-ed25519"); appendBytes(&privSection, publicKeyBytes)
        var fullPrivateKey = Data(privateKeyBytes); fullPrivateKey.append(publicKeyBytes); appendBytes(&privSection, fullPrivateKey)
        appendString(&privSection, "vilya-iphone")
        let padding = 8 - (privSection.count % 8); if padding < 8 { for i in 1...padding { privSection.append(UInt8(i)) } }
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(privSection.count).bigEndian) { Array($0) }); keyData.append(privSection)
        let base64Key = keyData.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64Key)\n-----END OPENSSH PRIVATE KEY-----"
    }

    private static func calculateFingerprint(publicKey: Curve25519.Signing.PublicKey) -> String {
        var keyData = Data()
        let keyType = "ssh-ed25519".data(using: .utf8)!
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(keyType.count).bigEndian) { Array($0) }); keyData.append(keyType)
        let pubKeyBytes = publicKey.rawRepresentation
        keyData.append(contentsOf: withUnsafeBytes(of: UInt32(pubKeyBytes.count).bigEndian) { Array($0) }); keyData.append(pubKeyBytes)
        let hash = SHA256.hash(data: keyData)
        return "SHA256:\(Data(hash).base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }

    private static func appendString(_ data: inout Data, _ string: String) {
        let d = string.data(using: .utf8)!
        data.append(contentsOf: withUnsafeBytes(of: UInt32(d.count).bigEndian) { Array($0) }); data.append(d)
    }
    private static func appendBytes(_ data: inout Data, _ bytes: Data) {
        data.append(contentsOf: withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { Array($0) }); data.append(bytes)
    }
}
