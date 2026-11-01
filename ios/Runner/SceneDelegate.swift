import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    if let url = URLContexts.first?.url,
       url.scheme == "wterm",
       url.host == "new-window" {
      let options = UIScene.ActivationRequestOptions()
      options.requestingScene = scene
      UIApplication.shared.requestSceneSessionActivation(
        nil,
        userActivity: nil,
        options: options,
        errorHandler: { _ in }
      )
      return
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
