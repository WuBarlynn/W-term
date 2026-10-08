import LocalAuthentication
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let quickUnlockQueue = DispatchQueue(label: "dev.wterm.quick-unlock", qos: .userInitiated)

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
        DispatchQueue.global(qos: .userInitiated).async {
          let issue = BiometricSigningPolicy.currentIssue()
          DispatchQueue.main.async { result(issue) }
        }
        return
      }
      if ["quickUnlockEnabled", "quickUnlockEnroll", "quickUnlockRead", "quickUnlockDisable"].contains(call.method) {
        self.quickUnlockQueue.async {
          do {
            if call.method == "quickUnlockEnroll" || call.method == "quickUnlockRead",
               let issue = BiometricSigningPolicy.currentIssue() {
              throw QuickUnlockFailure(issue)
            }
            let store = try MacQuickUnlock.applicationStore()
            var value: Any?
            switch call.method {
            case "quickUnlockEnabled": value = store.enabled()
            case "quickUnlockEnroll":
              guard let args = call.arguments as? [String: Any], let password = args["password"] as? String else {
                throw QuickUnlockFailure("缺少快速解锁凭证")
              }
              try store.enroll(password)
            case "quickUnlockRead": value = try store.read()
            default: try store.disable()
            }
            DispatchQueue.main.async { result(value) }
          } catch {
            // Do not return system details that may contain file paths or data.
            let message = (error as? QuickUnlockFailure)?.message ??
              "Touch ID 未完成或凭证已失效，请重试；仍可使用主密码解锁。首次启用请确认系统已录入指纹。"
            DispatchQueue.main.async {
              result(FlutterError(code: "quick_unlock_failed", message: message, details: nil))
            }
          }
        }
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
}
