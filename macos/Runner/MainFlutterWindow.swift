import LocalAuthentication
import Carbon
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let quickUnlockQueue = DispatchQueue(label: "dev.wterm.quick-unlock", qos: .userInitiated)
  private var detachedWindows: [NSWindow] = []
  private var detachedChannels: [FlutterMethodChannel] = []
  private var showHotKeyRef: EventHotKeyRef?
  private var showHotKeyHandler: EventHandlerRef?
  private var previousInputSource: TISInputSource?
  private var fontChannel: FlutterMethodChannel?
  private weak var mainFlutterController: FlutterViewController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1180, height: 760))
    self.minSize = NSSize(width: 620, height: 460)

    RegisterGeneratedPlugins(registry: flutterViewController)
    mainFlutterController = flutterViewController

    let fontChannel = FlutterMethodChannel(
      name: "dev.wterm/fonts",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    fontChannel.setMethodCallHandler { call, result in
      guard call.method == "listFamilies" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(NSFontManager.shared.availableFontFamilies.sorted())
    }
    self.fontChannel = fontChannel

    let biometricChannel = FlutterMethodChannel(
      name: "dev.wterm/biometrics",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    biometricChannel.setMethodCallHandler { call, result in
      if call.method == "openTerminalWindow" {
        guard let args = call.arguments as? [String: Any],
              let payload = args["payload"] as? String else {
          result(false)
          return
        }
        let title = args["title"] as? String ?? "W Term"
        result(self.openDetachedWindow(payload: payload, title: title))
        return
      }
      if call.method == "setAsciiInput" {
        let ascii = (call.arguments as? Bool) ?? false
        DispatchQueue.main.async { self.setAsciiInput(ascii) }
        result(nil)
        return
      }
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


    registerShowHotKey()
    super.awakeFromNib()
  }

  private func setAsciiInput(_ ascii: Bool) {
    if ascii {
      if previousInputSource == nil {
        previousInputSource =
          TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
      }
      if let layout =
        TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
        TISSelectInputSource(layout)
      }
    } else if let previous = previousInputSource {
      TISSelectInputSource(previous)
      previousInputSource = nil
    }
  }

  private func registerShowHotKey() {
    guard showHotKeyRef == nil else { return }
    var hotKeyID = EventHotKeyID(signature: OSType(0x57544552), id: 1)
    let status = RegisterEventHotKey(
      UInt32(kVK_Space), UInt32(cmdKey | shiftKey), hotKeyID,
      GetApplicationEventTarget(), 0, &showHotKeyRef)
    guard status == noErr else {
      showHotKeyRef = nil
      return
    }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, userData -> OSStatus in
        guard let userData else { return noErr }
        DispatchQueue.main.async {
          let window = Unmanaged<MainFlutterWindow>
            .fromOpaque(userData).takeUnretainedValue()
          window.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        return noErr
      },
      1, &eventType, context, &showHotKeyHandler)
  }

  private func openDetachedWindow(payload: String, title: String) -> Bool {
    let project = FlutterDartProject()
    project.dartEntrypointArguments = ["--wterm-detached", payload]
    let controller = FlutterViewController(project: project)
    RegisterGeneratedPlugins(registry: controller)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
      styleMask: [.titled, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = title
    window.contentViewController = controller
    window.minSize = NSSize(width: 520, height: 360)
    window.isReleasedWhenClosed = false
    window.center()

    let channel = FlutterMethodChannel(
      name: "dev.wterm/detached-window",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self, weak window] call, result in
      if call.method == "close" {
        DispatchQueue.main.async { window?.close() }
        result(nil)
      } else if call.method == "returnToMain" {
        guard let args = call.arguments as? [String: Any],
              let payload = args["payload"] as? String,
              let main = self?.mainFlutterController else {
          result(false)
          return
        }
        let mainChannel = FlutterMethodChannel(
          name: "dev.wterm/biometrics",
          binaryMessenger: main.engine.binaryMessenger)
        mainChannel.invokeMethod("attachTerminalWindow", arguments: ["payload": payload]) { value in
          let accepted = (value as? Bool) ?? false
          if accepted {
            DispatchQueue.main.async { window?.close() }
          }
          result(accepted)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    detachedWindows.append(window)
    detachedChannels.append(channel)
    window.makeKeyAndOrderFront(nil)
    return true
  }

  /// Closing the last window keeps the process and SSH sessions alive. The
  /// Dock icon (applicationShouldHandleReopen) brings the same window back.
  override func close() {
    orderOut(nil)
  }
}
