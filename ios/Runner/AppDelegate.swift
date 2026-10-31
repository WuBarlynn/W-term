import LocalAuthentication
import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var folderPicker: WTermFolderPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WTermFolders") {
      let picker = WTermFolderPicker()
      folderPicker = picker
      let channel = FlutterMethodChannel(name: "dev.wterm/folders", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in picker.handle(call, result: result) }
    }


    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WTermFonts") {
      let channel = FlutterMethodChannel(name: "dev.wterm/fonts", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "listFamilies" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result(UIFont.familyNames.sorted())
      }
    }

    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "WTermBiometrics") {
      let channel = FlutterMethodChannel(name: "dev.wterm/biometrics", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
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
        switch context.biometryType {
        case .faceID: result("Face ID")
        case .touchID: result("Touch ID")
        default: result(nil)
        }
      }
    }

  }
}

// Security scopes are held only for the current upload batch and its retries.
private final class WTermFolderPicker: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var scopes: [String: URL] = [:]

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "release" {
      if let token = call.arguments as? String, let url = scopes.removeValue(forKey: token) {
        url.stopAccessingSecurityScopedResource()
      }
      result(nil)
      return
    }
    guard call.method == "pick" else { result(FlutterMethodNotImplemented); return }
    guard pending == nil else {
      result(FlutterError(code: "busy", message: "文件夹选择器已打开", details: nil)); return
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow }),
          var presenter = window.rootViewController else {
      result(FlutterError(code: "no_window", message: "无法显示文件夹选择器", details: nil)); return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    pending = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.allowsMultipleSelection = false
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callback = pending
    pending = nil
    callback?(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let callback = pending
    pending = nil
    guard let callback = callback else { return }
    guard let url = urls.first, url.startAccessingSecurityScopedResource() else {
      callback(FlutterError(code: "access_denied", message: "无法获得文件夹访问权限，请重新选择", details: nil)); return
    }
    do {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true && values.isSymbolicLink != true else {
        url.stopAccessingSecurityScopedResource()
        callback(FlutterError(code: "not_directory", message: "请选择普通文件夹", details: nil)); return
      }
      let token = UUID().uuidString
      scopes[token] = url
      callback(["path": url.path, "token": token])
    } catch {
      url.stopAccessingSecurityScopedResource()
      callback(FlutterError(code: "folder_read", message: "无法读取文件夹，请确认已下载到本机", details: nil))
    }
  }

  deinit {
    for url in scopes.values { url.stopAccessingSecurityScopedResource() }
  }
}
