import AVFoundation
import SwiftUI
import UIKit

/// The picture for a `.video` stream.
///
/// Bug this fixes: a video stream played AUDIO ONLY — StreamPlayer was an
/// AVPlayer wrapper with no video output anywhere, so AVPlayer happily decoded
/// the video track and threw the frames away. AVPlayer renders nothing unless
/// something gives it an `AVPlayerLayer` to draw into; this file is that layer.
///
/// Deliberately NOT `VideoPlayer` from AVKit: that control set (scrubber,
/// volume, full-screen chrome) is wrong for a radio app whose transport lives
/// in the player bar, and it would fight the single-stream player for control
/// of the same AVPlayer. A bare layer is the whole requirement.
struct VideoSurface: UIViewRepresentable {
    /// The player to render. nil while connecting / after stop — the view then
    /// shows plain black instead of a stale frame from the previous stream.
    let player: AVPlayer?

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
    /// of any video whose aspect ratio differs from the panel's.
    private func configureLayer() {
        playerLayer.videoGravity = .resizeAspect
        // Opaque black behind the letterbox bars, so the panel never shows the
        // list scrolled behind it through a transparent layer.
        backgroundColor = .black
    }
}

/// Whether the video surface should be on screen.
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

    /// Aspect the panel keeps while the list is visible. 16:9 is the dominant
    /// shape for these streams; `.resizeAspect` letterboxes anything else
    /// inside it rather than cropping.
    static let aspectRatio: CGFloat = 16.0 / 9.0
}
