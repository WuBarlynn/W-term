import Security
import LocalAuthentication
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1180, height: 760))
    self.minSize = NSSize(width: 620, height: 460)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let biometricChannel = FlutterMethodChannel(
      name: "dev.wterm/biometrics",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    biometricChannel.setMethodCallHandler { call, result in
      if call.method == "keychainAccessIssue" {
        result(Self.keychainAccessIssue())
        return
      }
      if call.method == "buildVersion" {
          let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
          let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
          result("\(version) (\(build))")
          return
        }
        guard call.method == "availableType" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let context = LAContext()
      guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
        result(nil)
        return
      }
      result(context.biometryType == .touchID ? "Touch ID" : nil)
    }


    super.awakeFromNib()
  }
  private static func keychainAccessIssue() -> String? {
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess,
          let code = code,
          SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
          let staticCode = staticCode,
          SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else {
      return "无法读取应用签名。请使用正确签名的 W Term 版本。"
    }
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
    let appID = entitlements["com.apple.application-identifier"] as? String
    let groups = entitlements["keychain-access-groups"] as? [String]
    guard let team = team, !team.isEmpty,
          (appID?.isEmpty == false || groups?.isEmpty == false) else {
      return "当前 App 为临时签名或缺少钥匙串权限，无法启用 Touch ID。请使用 Apple Development 或 Developer ID 证书签名并配置 Keychain 权限。移除 com.apple.quarantine 不能替代签名。"
    }
    return nil
  }

}
