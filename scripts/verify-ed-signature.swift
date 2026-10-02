// Verifies a Sparkle EdDSA signature over a file against a base64 Ed25519 public key.
// Usage: swift scripts/verify-ed-signature.swift <file> <base64-public-key> <base64-signature>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: verify-ed-signature <file> <public-key-b64> <signature-b64>\n".utf8))
    exit(2)
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard let file = FileManager.default.contents(atPath: args[1]) else { fail("cannot read \(args[1])") }
guard let keyData = Data(base64Encoded: args[2]), keyData.count == 32 else { fail("public key is not 32 base64 bytes") }
guard let sig = Data(base64Encoded: args[3]), sig.count == 64 else { fail("signature is not 64 base64 bytes") }
guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { fail("invalid public key") }
guard key.isValidSignature(sig, for: file) else { fail("EdDSA signature does NOT match the embedded public key") }
print("EdDSA signature verified")
