import Foundation
import CryptoKit
import Darwin

// La clé publique vient du ZIP publié précédent, jamais du Keychain.
guard CommandLine.arguments.count == 4,
      let keyBytes = Data(base64Encoded: CommandLine.arguments[1]),
      let signature = Data(base64Encoded: CommandLine.arguments[2]) else {
    fputs("Usage: verify-eddsa PUBLIC_KEY_BASE64 SIGNATURE_BASE64 FILE\n", stderr)
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let content = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let valid = key.isValidSignature(signature, for: content)
    print(valid ? "VALID" : "INVALID")
    exit(valid ? 0 : 1)
} catch {
    fputs("Verification error: \(error)\n", stderr)
    exit(2)
}
