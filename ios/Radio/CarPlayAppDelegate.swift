import UIKit
import CarPlay

/// UIApplicationDelegate that connects the CarPlay scene when the system asks
/// for it, keeping the SwiftUI `WindowGroup` (the phone scene) untouched.
///
/// Two ways to tell the system about a CarPlay scene:
///   1. The Info.plist UIApplicationSceneManifest declarative approach, or
///   2. Returning a UISceneConfiguration from
///      `application(_:configurationForConnecting:options:)`.
///
/// We use (2) here so the CarPlay scene is described purely in code and the
/// phone's SwiftUI WindowGroup (auto-generated scene manifest) is left
/// completely alone — the safest path for "base app must still launch without
/// CarPlay". This delegate only ever provides a CarPlay config for a CarPlay
/// connection; a non-provisioned / non-CarPlay launch never instantiates
/// CarPlaySceneDelegate at all.
final class RadioAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == UISceneSession.Role.carTemplateApplication {
            // CarPlay connection → hand it to the CarPlay scene delegate.
            let config = UISceneConfiguration(
                name: "CarPlay",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        // Everything else: preserve the SwiftUI WindowGroup default scene.
        // Apple's SwiftUI template names the auto-generated configuration
        // "Default Configuration" — returning it keeps the phone scene intact.
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }
}
