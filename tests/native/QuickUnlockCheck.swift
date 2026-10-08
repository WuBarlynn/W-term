import CryptoKit
import Foundation
import LocalAuthentication
import Security

@main
struct QuickUnlockCheck {
  static func requireFailure(_ label: String, _ body: () throws -> Void) {
    do { try body() } catch { print("PASS \(label)"); return }
    fatalError("Expected failure: \(label)")
  }

  static func main() throws {
    let key = P256.KeyAgreement.PrivateKey()
    let fixture = "test-only-password-密码"
    let envelope = try BiometricEnvelope.seal(fixture, publicKey: key.publicKey, wrappedKey: Data([1, 2, 3]))
    let decoded = try JSONDecoder().decode(BiometricEnvelope.self, from: JSONEncoder().encode(envelope))
    let password = try decoded.open { try key.sharedSecretFromKeyAgreement(with: $0) }
    precondition(password == fixture)
    print("PASS envelope roundtrip")
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as! [String: Any]
    for field in ["wrappedKey", "peerPublicKey", "salt", "ciphertext"] {
      var changed = object
      var data = Data(base64Encoded: object[field] as! String)!
      data[data.count - 1] ^= 1
      changed[field] = data.base64EncodedString()
      let tampered = try JSONDecoder().decode(BiometricEnvelope.self, from: JSONSerialization.data(withJSONObject: changed))
      requireFailure("reject changed \(field)") {
        _ = try tampered.open { try key.sharedSecretFromKeyAgreement(with: $0) }
      }
    }
    var wrongVersion = object
    wrongVersion["version"] = 100
    let unknown = try JSONDecoder().decode(BiometricEnvelope.self, from: JSONSerialization.data(withJSONObject: wrongVersion))
    requireFailure("reject unknown version before authentication") {
      _ = try unknown.open { _ in fatalError("must not reach key operation") }
    }
    requireFailure("wrong key rejected") {
      _ = try envelope.open { try P256.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: $0) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("envelope.json")
    let store = MacQuickUnlock(file: file)
    precondition(!store.enabled())
    try store.save(envelope)
    let reopened = MacQuickUnlock(file: file)
    precondition(reopened.enabled())
    let stored = try reopened.load()
    let reopenedPassword = try stored.open { try key.sharedSecretFromKeyAgreement(with: $0) }
    precondition(reopenedPassword == fixture)
    let content = try Data(contentsOf: file)
    precondition(content.range(of: Data(fixture.utf8)) == nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    precondition((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
    print("PASS persisted envelope, reopen, permissions, no plaintext")
    try store.disable()
    precondition(!reopened.enabled())
    try store.disable()
    requireFailure("removed enrollment cannot load") { _ = try reopened.load() }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 131073).write(to: file)
    requireFailure("oversize record rejected") { _ = try store.load() }

    if CommandLine.arguments.contains("--hardware") {
      // No prompt and no production vault/keychain item: test a throwaway key.
      let context = LAContext()
      context.interactionNotAllowed = true
      defer { context.invalidate() }
      let hardware = try MacQuickUnlock.makeKey(context: context)
      let sealed = try BiometricEnvelope.seal(fixture, publicKey: hardware.publicKey,
                                              wrappedKey: hardware.dataRepresentation)
      let restored = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: sealed.wrappedKey, authenticationContext: context)
      print("PASS hardware key creation and reconstruction without Keychain entitlement")
      do {
        _ = try sealed.open { try restored.sharedSecretFromKeyAgreement(with: $0) }
        fatalError("Hardware decrypted without biometric authorization")
      } catch {
        let error = error as NSError
        // Missing entitlement is not evidence of biometric enforcement.
        precondition(
          (error.domain == LAError.errorDomain && error.code == LAError.notInteractive.rawValue) ||
          (error.domain == NSOSStatusErrorDomain && error.code == Int(errSecInteractionNotAllowed)),
          "Unexpected hardware error: \(error.domain) \(error.code)")
        print("PASS hardware refuses unauthenticated decrypt: \(error.domain) \(error.code)")
      }
    }
  }
}
