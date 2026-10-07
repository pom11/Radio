import AVFoundation
import SwiftUI
import UIKit

/// The picture for a `.video` stream.
///
/// Bug this fixes (first report): a video stream played AUDIO ONLY — StreamPlayer
/// was an AVPlayer wrapper with no video output anywhere, so AVPlayer happily
/// decoded the video track and threw the frames away. AVPlayer renders nothing
/// unless something gives it an `AVPlayerLayer` to draw into; this file is that
/// layer.
///
/// Second report, which this card answers: the panel was hard-locked to a 16:9
/// box above the player bar with no way to expand, and Picture-in-Picture did
/// not exist. The surface therefore also (a) carries an AX identifier so the
/// same type can be the fullscreen picture as well as the docked one, and
/// (b) hands its layer to the player's `PiPSession` — the floating window draws
/// from exactly the layer that is on screen.
///
/// Deliberately NOT `VideoPlayer` from AVKit: that control set (scrubber,
/// volume, full-screen chrome) is wrong for a radio app whose transport lives
/// in the player bar, and it would fight the single-stream player for control
/// of the same AVPlayer. A bare layer is the whole requirement.
struct VideoSurface: UIViewRepresentable {
    /// The player to render. nil while connecting / after stop — the view then
    /// shows plain black instead of a stale frame from the previous stream.
    let player: AVPlayer?

    /// Label announced for the picture, and used by nothing else. Set on the
    /// hosted view (not by the SwiftUI wrapper) so the view stays a single,
    /// identifiable element in the accessibility tree.
    var label: String = "Video"

    /// AX identifier. `videoSurface` for the docked panel (the hook
    /// VideoSurfaceUITests asserts on) and `videoFullscreen` for the edge-to-edge
    /// overlay: one type, two elements a UI test can tell apart and measure.
    var identifier: String = "videoSurface"

    /// The player's PiP session, or nil when PiP is not wanted.
    ///
    /// The surface owns the only AVPlayerLayer the app has, so this is the one
    /// place the session can be pointed at a real picture. `bind` is a no-op for
    /// an unchanged (player, layer) pair, which makes calling it on every update
    /// cheap and idempotent.
    var pip: PiPSession?

    func makeUIView(context: Context) -> PlayerLayerUIView {
        // No configuration here on purpose: the layer and its gravity are set up
        // in PlayerLayerUIView's initialisers, so the invariant holds for any
        // host (and is testable without SwiftUI).
        PlayerLayerUIView()
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        // Re-assigning the same player is a no-op for AVPlayerLayer, so this is
        // safe to call on every view update.
        uiView.playerLayer.player = player
        uiView.accessibilityLabel = label
        uiView.accessibilityIdentifier = identifier
        // Only a surface that actually has a picture is a usable PiP source: a
        // black layer with no player behind it would be refused by the system.
        pip?.bind(player: player, layer: uiView.playerLayer)
    }
}

/// UIView whose backing layer IS the AVPlayerLayer (via `layerClass`), which is
/// the canonical way to host AVPlayer in UIKit without managing a sublayer.
final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    /// Typed access to the backing layer; guaranteed by `layerClass`.
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    /// `.resizeAspect` — fit the frame, letterbox the rest.
    ///
    /// Set here rather than by the caller so no host can forget it: the wrong
    /// gravity (`.resizeAspectFill`, which the QR preview uses) crops the edges
    /// of any video whose aspect ratio differs from the box. It is also what
    /// makes fullscreen free to implement: inside full bounds the same gravity
    /// centres and letterboxes a 4:3 stream instead of stretching it.
    private func configureLayer() {
        playerLayer.videoGravity = .resizeAspect
        // No `allowsPictureInPictureMediaPlayback` here ON PURPOSE: that
        // property is macOS-only — it does not exist on iOS's AVPlayerLayer
        // (iPhoneOS SDK AVPlayerLayer.h has no such member; the build fails
        // with "value of type 'AVPlayerLayer' has no member
        // 'allowsPictureInPictureMediaPlayback'"). On iOS an AVPlayerLayer
        // feeds AVPictureInPictureController with no per-layer switch at all,
        // so the binding in PictureInPicture.swift is the whole requirement.
        // Opaque black behind the letterbox bars, so the panel never shows the
        // list scrolled behind it through a transparent layer.
        backgroundColor = .black
        // The picture must be visible to XCUITest and VoiceOver: an AVPlayerLayer
        // is not an accessibility element by default, so the panel is otherwise
        // invisible to both. `videoSurface` is the hook VideoSurfaceUITests
        // asserts on — stable identifier, never rename it.
        isAccessibilityElement = true
        accessibilityIdentifier = "videoSurface"
        accessibilityLabel = "Video"
    }
}

/// Whether the video surface should be on screen, and what it may offer.
///
/// Pure so the "shown only for .video" rule — the part a user can see wrong —
/// is testable without an AVPlayer or a running app. `.channel` streams are
/// excluded even though a channel is usually video content: the app cannot
/// resolve most of them in-app (see handleResolveFailure / openInBrowserURL),
/// and an empty black rectangle would be worse than no rectangle.
enum VideoSurfacePolicy {
    static func shouldShow(currentStream: Stream?, hasPlayer: Bool) -> Bool {
        guard hasPlayer, let type = currentStream?.type else { return false }
        return type == .video
    }

    /// Whether the picture may offer a Picture-in-Picture control.
    ///
    /// Deliberately the same gate as the surface: PiP floats a *picture*, so an
    /// audio stream must never grow the button — there is nothing to draw. It
    /// gets its own name (and its own test) because "no PiP button" is the
    /// user-visible half of this card's complaint.
    static func shouldOfferPiP(currentStream: Stream?, hasPlayer: Bool) -> Bool {
        shouldShow(currentStream: currentStream, hasPlayer: hasPlayer)
    }

    /// Aspect the panel keeps while the list is visible. 16:9 is the dominant
    /// shape for these streams; `.resizeAspect` letterboxes anything else
    /// inside it rather than cropping.
    static let aspectRatio: CGFloat = 16.0 / 9.0
}

/// Where the picture is drawn: docked above the player bar, or filling the whole
/// screen.
///
/// Fullscreen is edge-to-edge in PORTRAIT on purpose: the app is portrait-locked
/// with UIRequiresFullScreen, so this card never asks the system to rotate — it
/// just uses the full bounds with the safe area ignored. A wide video arrives
/// that way naturally (letterboxed by `.resizeAspect`).
enum VideoSurfaceMode: Equatable {
    case docked
    case fullscreen

    var isFullscreen: Bool { self == .fullscreen }

    /// The transitions the panel's buttons drive.
    ///
    /// `stop` collapses from fullscreen and is a no-op docked: an overlay that
    /// outlives its stream is a black screen over the app with nothing playing —
    /// the ghost-card bug in fullscreen form. `expand` / `collapse` are
    /// idempotent, so a double tap cannot wedge the UI in a state with no exit.
    static func transition(from mode: VideoSurfaceMode, action: Action) -> VideoSurfaceMode {
        switch (mode, action) {
        case (.docked, .expand):
            return .fullscreen
        case (.fullscreen, .collapse), (.fullscreen, .stop):
            return .docked
        case (.docked, .collapse), (.docked, .stop), (.fullscreen, .expand):
            return mode
        }
    }

    enum Action: Equatable {
        case expand
        case collapse
        case stop
    }
}
