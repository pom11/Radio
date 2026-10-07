import AVFoundation
import AVKit
import Combine
import os.log
import UIKit

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "pip")

/// Picture-in-Picture for the video stream: the small floating window that keeps
/// playing while the user is elsewhere in the app, or outside the app entirely.
///
/// What was missing (user report: "cant make the video fullscreen nor picture in
/// picture the small floating window"): the app never touched
/// `AVPictureInPictureController` at all, so iOS had no reason to offer a
/// floating window. PiP for an `AVPlayerLayer` needs **no entitlement and no new
/// background mode** — the app already has `UIBackgroundModes: audio`, and on iOS
/// an AVPlayerLayer feeds the controller with no per-layer switch (the
/// `allowsPictureInPictureMediaPlayback` property the card suggested is
/// macOS-only; see the note in VideoSurface.configureLayer). Nothing here is
/// configured beyond public AVKit API.
///
/// Shape: the session is owned by StreamPlayer (so "the floating window was
/// closed" can stop playback through the same path the Stop button uses), but it
/// is *bound* by the video surface, because the surface owns the AVPlayerLayer
/// the window draws from. `bind(player:layer:)` is idempotent for an unchanged
/// pair, so calling it from every SwiftUI update is cheap.
///
/// Call on the main thread (like StreamPlayer's other state mutation): the
/// callers are SwiftUI view updates and AVKit's delegate callbacks, both main.
final class PiPSession: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    /// True while the floating window is on screen.
    @Published private(set) var isActive = false
    /// True when the system would start a session right now (a ready video
    /// track, PiP supported, not already active). The button uses it to decide
    /// whether it does anything — see `VideoPanel`.
    @Published private(set) var canStart = false

    /// The floating window was closed by the USER (its X, or a tap that brings
    /// the app back). StreamPlayer wires this to `stop()` — card rule C: closing
    /// PiP ends playback exactly like Stop does, so a stream cannot quietly keep
    /// playing with no surface and no controls anywhere.
    ///
    /// Deliberately not wired to `pictureInPictureControllerDidStopPictureInPicture`:
    /// the session also stops on paths that already end playback themselves
    /// (`stop()`, stream switch), and calling back into `stop()` from those
    /// would be a loop that only "works" by accident.
    var onClose: (() -> Void)?

    /// Whether this device/OS can do PiP at all. When false every affordance is
    /// hidden rather than dead: a button that refuses is worse than none.
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private var controller: AVPictureInPictureController?
    /// The pair currently bound, kept so a repeat `bind` (every SwiftUI redraw)
    /// is a no-op instead of a session re-creation — recreating mid-playback
    /// would tear the floating window down.
    private weak var boundPlayer: AVPlayer?
    private weak var boundLayer: AVPlayerLayer?
    private var possibleObservation: AnyCancellable?

    deinit {
        controller?.delegate = nil
    }

    /// Point the session at the picture that is actually on screen.
    ///
    /// Called by `VideoSurface.updateUIView`. On a stream switch StreamPlayer has
    /// already stopped the previous session (teardownPlayback), so this normally
    /// creates the controller; the `contentSource` swap path covers the case
    /// where the surface survived and only the player changed.
    func bind(player: AVPlayer?, layer: AVPlayerLayer) {
        guard let player, Self.isSupported else { return }
        if controller != nil, boundPlayer === player, boundLayer === layer {
            refreshPossible()
            return
        }
        boundPlayer = player
        boundLayer = layer

        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
        if let controller {
            // Re-point an existing session. Apple allows this while active as
            // long as the new layer is ready for display — ours is: it is the
            // layer currently drawing on screen.
            controller.contentSource = source
        } else {
            let created = AVPictureInPictureController(contentSource: source)
            created.delegate = self
            controller = created
            observePossible(created)
        }
        // The second half of the fix: backgrounding the app while a video plays
        // floats it into the PiP window without the user pressing anything.
        // `canStartPictureInPictureAutomaticallyFromInline` applies to the
        // controller's current item, so it is re-armed on every re-point.
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
        refreshPossible()
    }

    /// The panel's PiP button.
    func start() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    /// End the floating window WITHOUT implying anything about playback.
    /// `teardownPlayback` calls this before the layer disappears, so a stream
    /// switch or Stop never leaves a window drawing from a dead player.
    func stopSession() {
        guard let controller else { return }
        if controller.isPictureInPictureActive || controller.isPictureInPictureSuspended {
            controller.stopPictureInPicture()
        }
        isActive = false
        refreshPossible()
    }

    /// Drop the binding when the surface goes away, so a later playback does not
    /// inherit a session pointed at a layer that is no longer mounted.
    func unbind() {
        boundPlayer = nil
        boundLayer = nil
    }

    // MARK: - State plumbing

    private func observePossible(_ controller: AVPictureInPictureController) {
        // Combine's KVO publisher, the same technique StreamPlayer uses for
        // `rate` and `isExternalPlaybackActive`.
        possibleObservation = controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPossible() }
    }

    private func refreshPossible() {
        let possible = controller?.isPictureInPicturePossible ?? false
        if canStart != possible { canStart = possible }
        let active = controller?.isPictureInPictureActive ?? false
        if isActive != active { isActive = active }
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.info("PiP started")
        onMain { [weak self] in self?.refreshPossible() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        log.info("PiP stopped")
        onMain { [weak self] in self?.refreshPossible() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        onMain { [weak self] in
            log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
            self?.refreshPossible()
        }
    }

    /// The system is about to stop the window and is asking the app to show its
    /// UI. Two jobs, in this order:
    ///
    /// 1. end the stream (card rule C — closing the floating window stops
    ///    playback exactly like Stop does);
    /// 2. answer the restore request with `true`. There is nothing to restore:
    ///    the video is inline in the app's single window (no modal player
    ///    screen, no separate detail view), so the UI the user lands on is
    ///    already the right one. iOS also has no public "bring my app forward"
    ///    call — the system performs the foreground switch itself — so claiming
    ///    otherwise here would be fiction, not a fix.
    ///
    /// `stop()` in step 1 stops the session too, which is what the system is
    /// already doing here — idempotent, not a loop.
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        onMain { [weak self] in self?.onClose?() }
        completionHandler(true)
    }

    /// AVKit documents these callbacks on the main thread, but every piece of
    /// state behind them is `@Published` and read by SwiftUI, so main-thread
    /// delivery is enforced rather than trusted (and a same-thread call stays
    /// synchronous, so the button state never lags a frame behind a tap).
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}
