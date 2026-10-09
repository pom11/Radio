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
///
/// REFRESH (card t_6f34a116): a saved stream URL goes dead all the time — the
/// driver used to see a list that looked fine and played nothing, because
/// refetch-from-source lived only in the phone's player bar. There are now three
/// affordances, all running the SAME path the in-app bar runs
/// (`StreamPlayer.refreshFromSource(_:manual:)`) and all gated by the same
/// `RefetchMachine.canRefresh` rule:
///   - a trailing navigation-bar button on the root list template;
///   - the same button on the Now Playing template (where a failure is actually
///     visible while driving);
///   - the selected row's detail text, which says "Not playing — use Refresh",
///     so the driver connects the button to the row that broke.
///
/// Why a selection-scoped button rather than a literally per-row control:
/// `CPListItem` in this SDK exposes ONE tap handler plus a display-only accessory
/// (CPListItem.h has no secondary action; `accessoryImage`/`accessoryType` are
/// not tappable), so a row tap cannot mean both "play" and "refresh" — and
/// pushing into a detail screen to refresh one row costs an extra interaction
/// while moving. Selection therefore picks the target (the row you last tapped
/// is the row that just died), and `CarPlayListPolicy` keeps that rule pure and
/// unit-testable instead of inline in the template builder.
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    /// The Refresh glyph, resolved once. `UIImage(systemName:)` is optional and
    /// CarPlay's button images are nonnull, so the nil case degrades to an empty
    /// image (a label-less button) rather than force-unwrapping in a car.
    private static let refreshImage = UIImage(systemName: "arrow.clockwise") ?? UIImage()

    private var interfaceController: CPInterfaceController?
    /// The merged "something the driver can see changed" subscription. Named
    /// `sync…` rather than `store…` because it now watches the store *and* the
    /// player — see `didConnect`.
    private var syncCancellable: AnyCancellable?
    /// Everything the mounted root template shows. Rebuilds happen only when this
    /// changes — see `syncTemplate`.
    private var lastView: CarPlayListView?
    /// The template object currently mounted as root, so a rebuild can tell
    /// "repaint the screen the driver is looking at" from "yank them off it".
    private var mountedRoot: CPTemplate?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        lastView = nil
        mountedRoot = nil
        syncTemplate(force: true)

        // Keep the CarPlay list current. CarPlay templates do NOT observe
        // SwiftUI/Combine state — they are value snapshots handed to the head
        // unit once — so anything the driver must see has to trigger an explicit
        // rebuild here. Two sources, merged into one subscription:
        //   - the saved stream list (streams added/removed/refetched on the phone),
        //   - the player (selection / playing / failed / refreshing), which
        //     PlayerManager.init bridges into manager.objectWillChange.
        // `objectWillChange` fires *before* the mutation lands, so the rebuild
        // reads state on the next main-queue turn (`.receive(on:)`) rather than
        // synchronously — a synchronous read here would render one step stale.
        let storeChanges = StreamStore.shared.$streams.map { _ in () }
        let playerChanges = PlayerManager.shared.objectWillChange.map { _ in () }
        // `Publishers.merge` (not MergeMany) because the two publishers are
        // different concrete types — MergeMany requires one.
        syncCancellable = Publishers.merge(storeChanges.eraseToAnyPublisher(),
                                           playerChanges.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncTemplate()
            }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        syncCancellable?.cancel()
        syncCancellable = nil
        lastView = nil
        mountedRoot = nil
    }

    // MARK: - UI building

    /// Rebuild the root template when — and only when — something the driver can
    /// actually see has changed, and only while the list is on screen.
    ///
    /// Two guards, each fixing a real CarPlay failure mode:
    ///
    /// 1. **Equatable dedupe.** `PlayerManager` bridges *every* `StreamPlayer`
    ///    `@Published` change, including `statusText`, which appears nowhere in
    ///    this list. `setRootTemplate` remounts the list and drops the driver's
    ///    scroll position, so an unconditional rebuild would yank the list to the
    ///    top on a status write.
    /// 2. **Never repaint underneath a pushed template.** Tapping a row pushes Now
    ///    Playing; the resulting `isPlaying` change would otherwise `setRootTemplate`
    ///    and pop the driver straight back out to the list — the bounce Apple's HIG
    ///    exists to prevent. When something deeper is on top the rebuild is simply
    ///    *skipped*, leaving `lastView` stale, so the next change (or popping back,
    ///    see `templateDidAppear`) repaints it.
    private func syncTemplate(force: Bool = false) {
        guard let ic = interfaceController else { return }
        let view = CarPlayListView.current
        if !force, view == lastView { return }
        if let top = ic.topTemplate, let mounted = mountedRoot, top !== mounted {
            return
        }
        lastView = view
        let root = makeRootTemplate(from: view)
        mountedRoot = root
        ic.setRootTemplate(root, animated: false, completion: nil)
    }

    /// Builds the root template: a "Streams" CPListTemplate with one item per
    /// saved stream, plus the navigation-bar Refresh button. Tapping an item plays
    /// it (single-stream AVPlayer) and surfaces the Now Playing template for
    /// play/pause while driving.
    private func makeRootTemplate(from view: CarPlayListView) -> CPTemplate {
        let streams = view.streams
        let state = view.state

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
            let item = CPListItem(text: stream.name,
                                  detailText: CarPlayListPolicy.detailText(for: stream, state: state))
            // CPListItem.handler receives (item, completion); we ignore the
            // item and just play this stream, then satisfy the completion.
            item.handler = { [weak self] _, completion in
                self?.play(stream)
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Streams", sections: [section])
        // The Refresh affordance. Always present, `isEnabled`-gated rather than
        // added/removed, so the control never moves between rebuilds — a button
        // that appears and disappears under a driver's thumb is worse than one
        // that is greyed out.
        let refresh = CPBarButton(image: Self.refreshImage,
                                  handler: { [weak self] _ in
                self?.refreshSelected()
            })
        refresh.isEnabled = CarPlayListPolicy.refreshEnabled(
            state: state,
            target: CarPlayListPolicy.refreshTarget(in: streams, state: state))
        template.trailingNavigationBarButtons = [refresh]
        return template
    }

    /// Play a stream in the app's single AVPlayer and surface Now Playing.
    private func play(_ stream: Stream) {
        PlayerManager.shared.play(stream: stream)
        pushNowPlaying()
    }

    /// The one Refresh entry point for every CarPlay surface: the same manual
    /// refetch the phone's player bar calls, so the re-entrancy guard, the taint
    /// rule and persistence (`onRefreshStream` → `StreamStore.applyRefreshedURL`)
    /// are shared, not duplicated. A successful refetch rewrites
    /// `StreamStore.streams`, which re-fires the merged subscription and rebuilds
    /// the list on the fresh URL — the fix shows itself with no extra wiring.
    private func refreshSelected() {
        let view = CarPlayListView.current
        // Same gate the button's enabled state was computed from — a stale
        // template (or a store edit racing the tap) must not start a refresh the
        // policy would have refused. The player's own refusal text ("No source
        // page to refetch from") is written to statusText, which is a phone
        // surface; silence is the right answer in the car.
        guard let target = CarPlayListPolicy.refreshTarget(in: view.streams, state: view.state) else {
            return
        }
        PlayerManager.shared.player.refreshFromSource(target, manual: true)
        syncTemplate()
    }

    /// Present CPNowPlayingTemplate (singleton) for play/pause while driving.
    /// The play/pause state is reflected automatically by the system from the
    /// active audio session / player; no manual button refresh needed.
    ///
    /// The one custom button is Refresh, and it belongs HERE at least as much as
    /// on the list: after a tap the driver is looking at this template, and this
    /// is the screen where a dead stream is visible. Re-applied on every push
    /// because the template is a singleton and `updateNowPlayingButtons` replaces
    /// the whole array.
    private func pushNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        let refresh = CPNowPlayingImageButton(image: Self.refreshImage) { [weak self] _ in
            self?.refreshSelected()
        }
        nowPlaying.updateNowPlayingButtons([refresh])
        interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
    }
}

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {}

    /// A rebuild deferred while Now Playing was on top (see `syncTemplate`) gets
    /// its chance the moment the list is visible again.
    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        syncTemplate()
    }

    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {}
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {}
}
