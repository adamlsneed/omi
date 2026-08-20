import Flutter
import UIKit

/// Adopts the UIScene lifecycle, which the iOS 26 SDK and later require.
///
/// `FlutterSceneDelegate` owns the window and the `FlutterViewController`, so
/// everything the app delegate used to wire up in `didFinishLaunchingWithOptions`
/// off `window?.rootViewController` now runs here: at launch that window does not
/// exist yet, and the old code force-unwrapped it.
///
/// UIKit also stops delivering `applicationWillEnterForeground(_:)` and
/// `application(_:open:options:)` to the app delegate once a scene delegate is
/// present, so both are forwarded rather than left to silently stop firing.
@objc(SceneDelegate)
class SceneDelegate: FlutterSceneDelegate {
  private var omiAppDelegate: AppDelegate? {
    UIApplication.shared.delegate as? AppDelegate
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      omiAppDelegate?.registerFlutterBridges(with: controller)
    } else {
      NSLog("[Scene] ERROR: no FlutterViewController on connect; native bridges are unregistered")
    }

    // A cold launch opened by a URL delivers it here rather than through
    // launchOptions.
    for context in connectionOptions.urlContexts {
      omiAppDelegate?.handleIncomingURL(context.url)
    }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    // super keeps Flutter forwarding the URL to plugins that handle deep links.
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      omiAppDelegate?.handleIncomingURL(context.url)
    }
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    super.sceneWillEnterForeground(scene)
    omiAppDelegate?.handleWillEnterForeground()
  }
}
