import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Only the device-wrapped Secure Enclave key and authenticated ciphertext are
/// persisted. No SecItem / Data Protection Keychain entitlement is needed.
struct BiometricEnvelope: Codable {
  let version: Int
  let wrappedKey: Data
  let peerPublicKey: Data
  let salt: Data
  let ciphertext: Data

  private static let context = Data("dev.wterm.biometric-unlock.v2".utf8)

  private var authenticatedHeader: Data {
    Self.context + Data(SHA256.hash(data: wrappedKey)) + peerPublicKey + salt
  }

  private func wrappingKey(_ secret: SharedSecret) -> SymmetricKey {
    secret.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: salt, sharedInfo: Self.context, outputByteCount: 32)
  }

  static func seal(_ password: String, publicKey: P256.KeyAgreement.PublicKey,
                   wrappedKey: Data) throws -> Self {
    guard !password.isEmpty, password.utf8.count <= 65536 else {
      throw QuickUnlockFailure("快速解锁凭证为空或过长")
    }
    let peer = P256.KeyAgreement.PrivateKey()
    let secret = try peer.sharedSecretFromKeyAgreement(with: publicKey)
    let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let header = Self(version: 2, wrappedKey: wrappedKey,
                      peerPublicKey: peer.publicKey.x963Representation, salt: salt, ciphertext: Data())
    let box = try AES.GCM.seal(Data(password.utf8), using: header.wrappingKey(secret),
                               authenticating: header.authenticatedHeader)
    guard let ciphertext = box.combined else { throw QuickUnlockFailure("无法加密快速解锁凭证") }
    return Self(version: 2, wrappedKey: wrappedKey, peerPublicKey: header.peerPublicKey,
                salt: salt, ciphertext: ciphertext)
  }

  func validate() throws {
    guard version == 2, !wrappedKey.isEmpty, wrappedKey.count <= 16384,
          peerPublicKey.count == 65, salt.count == 32,
          ciphertext.count >= 29, ciphertext.count <= 65564 else {
      throw QuickUnlockFailure("快速解锁记录无效，请使用主密码解锁后重新启用")
    }
  }

  func open(agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> String {
    try validate()
    let secret = try agree(P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey))
    let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
                                    using: wrappingKey(secret), authenticating: authenticatedHeader)
    guard let password = String(data: plaintext, encoding: .utf8), !password.isEmpty else {
      throw QuickUnlockFailure("快速解锁记录无效，请重新启用")
    }
    return password
  }
}

struct QuickUnlockFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

final class MacQuickUnlock {
  private let file: URL

  init(file: URL) { self.file = file }

  static func applicationStore() throws -> MacQuickUnlock {
    let root = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    return MacQuickUnlock(file: root.appendingPathComponent("dev.wterm.wterm", isDirectory: true)
      .appendingPathComponent("biometric-unlock-v2.json"))
  }

  static func makeKey(context: LAContext) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    guard SecureEnclave.isAvailable else {
      throw QuickUnlockFailure("此 Mac 无法使用 Secure Enclave，请使用主密码解锁")
    }
    var error: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error) else {
      throw QuickUnlockFailure("无法建立 Touch ID 保护，请检查系统指纹设置")
    }
    return try SecureEnclave.P256.KeyAgreement.PrivateKey(
      accessControl: access, authenticationContext: context)
  }

  private static func context(_ reason: String) -> LAContext {
    let context = LAContext()
    context.localizedReason = reason
    context.localizedFallbackTitle = ""
    context.touchIDAuthenticationAllowableReuseDuration = 0
    return context
  }

  func enabled() -> Bool { FileManager.default.fileExists(atPath: file.path) }

  func enroll(_ password: String) throws {
    let context = Self.context("启用 W Term 保险库 Touch ID 解锁")
    defer { context.invalidate() }
    let key = try Self.makeKey(context: context)
    let envelope = try BiometricEnvelope.seal(password, publicKey: key.publicKey,
                                              wrappedKey: key.dataRepresentation)
    // Verify the persisted representation can actually decrypt with Touch ID
    // before replacing a previous enrollment. Cancellation preserves it.
    let restored = try SecureEnclave.P256.KeyAgreement.PrivateKey(
      dataRepresentation: envelope.wrappedKey, authenticationContext: context)
    let recovered = try envelope.open { try restored.sharedSecretFromKeyAgreement(with: $0) }
    guard recovered == password else { throw QuickUnlockFailure("Touch ID 凭证验证失败") }
    try save(envelope)
  }

  func read() throws -> String {
    let envelope = try load()
    let context = Self.context("使用 Touch ID 解锁 W Term 保险库")
    defer { context.invalidate() }
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
      dataRepresentation: envelope.wrappedKey, authenticationContext: context)
    return try envelope.open { try key.sharedSecretFromKeyAgreement(with: $0) }
  }

  func disable() throws {
    if enabled() { try FileManager.default.removeItem(at: file) }
  }

  // Internal for isolated envelope/storage tests; production enrollment always
  // reaches this only after successful hardware-backed decryption above.
  func save(_ envelope: BiometricEnvelope) throws {
    try envelope.validate()
    let directory = file.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(envelope).write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var url = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  func load() throws -> BiometricEnvelope {
    guard enabled() else { throw QuickUnlockFailure("请使用主密码解锁后重新启用 Touch ID") }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= 131072 else {
      throw QuickUnlockFailure("快速解锁记录无效，请重新启用")
    }
    let envelope = try JSONDecoder().decode(BiometricEnvelope.self, from: Data(contentsOf: file))
    try envelope.validate()
    return envelope
  }
}
