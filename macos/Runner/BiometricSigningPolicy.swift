import Foundation
import Security

/// Signature eligibility only. Keychain still enforces the biometric ACL and
/// platform entitlements independently; an accepted signature cannot bypass it.
enum BiometricSigningPolicy {
  private static let noFlags = SecCSFlags(rawValue: 0)

  static func currentIssue() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf(noFlags, &code) == errSecSuccess,
          let code = code,
          SecCodeCopyStaticCode(code, noFlags, &staticCode) == errSecSuccess,
          let staticCode = staticCode else {
      return "无法读取当前应用签名，不能使用 Touch ID。仍可使用主密码解锁。"
    }
    if let issue = issue(for: staticCode, expectedIdentifier: "dev.wterm.wterm") {
      return issue
    }
    guard SecCodeCheckValidity(code, noFlags, nil) == errSecSuccess else {
      return "当前运行的应用签名校验失败，不能使用 Touch ID。请重新构建签名版本。"
    }
    return nil
  }

  static func issue(for code: SecStaticCode, expectedIdentifier: String) -> String? {
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
          let dict = info as? [String: Any],
          let signatureFlags = dict[kSecCodeInfoFlags as String] as? NSNumber else {
      return "应用未签名或无法读取签名，不能使用 Touch ID。请使用证书签名版本。"
    }
    // CS_ADHOC (Security/CSCommon.h). A certificate chain is also mandatory.
    guard signatureFlags.uint32Value & 0x0002 == 0,
          let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
          !certificates.isEmpty else {
      return "临时签名（ad-hoc）不能使用 Touch ID。请使用 Apple Development、Developer ID 或稳定的自签名证书。"
    }
    guard dict[kSecCodeInfoIdentifier as String] as? String == expectedIdentifier,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
      return "应用标识或签名完整性校验失败，不能使用 Touch ID。请重新构建签名版本。"
    }

    return nil
  }
}
