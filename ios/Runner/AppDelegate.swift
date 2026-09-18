import LocalAuthentication
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

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
