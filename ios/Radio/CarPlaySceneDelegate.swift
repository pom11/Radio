import CarPlay
import UIKit
import Combine

/// CarPlay integration for the iOS Radio app (iOS 16+ CarPlay framework).
///
/// CONFIGURATION REQUIRED — the CarPlay audio entitlement is
/// provisioning-profile-bound (the same restricted-entitlement class a
/// non-App-Store Developer-ID build cannot self-sign). To enable CarPlay:
///   1. Enable the CarPlay capability (com.apple.developer.carplay-audio) for
///      the app's App ID in the Apple Developer portal and produce a
///      provisioning profile that carries it.
///   2. The entitlements file `Radio/Radio.entitlements` carries the key
///      (referenced from project.yml as CODE_SIGN_ENTITLEMENTS).
///
/// IMPORTANT: This code is gated purely by the system instantiating the scene.
/// A non-provisioned build never gets a CarPlay scene (no entitlement, no head
/// unit), so this file can be present and compile while the base app still
/// launches normally. The base app is built with CODE_SIGNING_ALLOWED=NO, so it
/// always runs unsigned on the simulator.
///
/// Driver-appropriate: the only UI is a Streams list; tapping a stream starts it
/// in the app's single AVPlayer and surfaces CPNowPlayingTemplate for
/// play/pause. No complex UI while driving.
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var storeCancellable: AnyCancellable?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        let root = makeRootTemplate()
        interfaceController.setRootTemplate(root, animated: true, completion: nil)

        // Keep the CarPlay list current with the phone's stream list: if the
        // user adds/removes streams while CarPlay is connected, rebuild the
        // root template so the driver sees the live set. Without this the list
        // would be frozen at the moment of connection.
        storeCancellable = StreamStore.shared.$streams
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let ic = self.interfaceController else { return }
                ic.setRootTemplate(self.makeRootTemplate(), animated: false, completion: nil)
            }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - UI building

    /// Builds the root template: a "Streams" CPListTemplate with one item per
    /// saved stream. Tapping an item plays it (single-stream AVPlayer) and
    /// surfaces the Now Playing template for play/pause while driving.
    private func makeRootTemplate() -> CPTemplate {
        let store = StreamStore.shared
        let streams = store.streams

        guard !streams.isEmpty else {
            // Empty list with an explanatory detail line.
            let emptyItem = CPListItem(
                text: "No streams saved",
                detailText: "Add streams on your iPhone to see them here."
            )
            emptyItem.isEnabled = false
            let emptySection = CPListSection(items: [emptyItem])
            return CPListTemplate(title: "Streams", sections: [emptySection])
        }

        let items: [CPListItem] = streams.map { stream in
            let item = CPListItem(text: stream.name, detailText: stream.type.rawValue)
            // CPListItem.handler receives (item, completion); we ignore the
            // item and just play this stream, then satisfy the completion.
            item.handler = { [weak self] _, completion in
                self?.play(stream)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        return CPListTemplate(title: "Streams", sections: [section])
    }

    /// Play a stream in the app's single AVPlayer and surface Now Playing.
    private func play(_ stream: Stream) {
        PlayerManager.shared.play(stream: stream)
        pushNowPlaying()
    }

    /// Present CPNowPlayingTemplate (singleton) for play/pause while driving.
    /// The play/pause state is reflected automatically by the system from the
    /// active audio session / player; no manual button refresh needed.
    private func pushNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
    }
}

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {}
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {}
    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {}
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {}
}
