import SwiftUI

@main
struct RadioApp: App {
    @UIApplicationDelegateAdaptor(RadioAppDelegate.self) private var appDelegate
    @StateObject private var store = StreamStore.shared
    @StateObject private var manager = PlayerManager.shared
    @State private var deepLinkHandler: DeepLinkHandler?

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, manager: manager)
                .onOpenURL { url in
                    // iOS equivalent of the macOS NSAppleEventManager URL handler:
                    // handle radio://add deep links on receipt.
                    if deepLinkHandler == nil {
                        deepLinkHandler = DeepLinkHandler(store: store)
                    }
                    deepLinkHandler?.handle(url)
                }
        }
    }
}
