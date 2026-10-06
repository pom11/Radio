import AVFoundation
import XCTest
@testable import Radio

/// Tests for the video surface — the thing that was missing entirely when
/// "video streams play audio only" was reported.
///
/// The bug had exactly one root cause: AVPlayer only draws a picture into an
/// AVPlayerLayer, and the app never made one. So these assert the two facts
/// that fix it (a view whose layer IS an AVPlayerLayer, pointed at the live
/// player) plus the display rule the card asked for (picture ONLY for
/// `.video`, so an audio stream's UI cannot change).
final class VideoSurfaceTests: XCTestCase {

    // `Radio.` prefix: in the test target a bare `Stream` is ambiguous with
    // Foundation's `Stream` class (see NowPlayingInfoTests for the same note).
    private func stream(_ type: StreamType) -> Radio.Stream {
        Stream(name: "Test", url: "https://example.com/stream.m3u8", type: type)
    }

    // MARK: - The surface really is an AVPlayerLayer

    /// The root cause of the bug: nothing in the app ever handed AVPlayer a
    /// layer to draw into. The host view's backing layer must BE an
    /// AVPlayerLayer, not merely contain one.
    func testHostViewIsBackedByAnAVPlayerLayer() {
        let view = PlayerLayerUIView()
        XCTAssertTrue(view.layer is AVPlayerLayer,
                      "layerClass must be AVPlayerLayer, otherwise no frames are ever rendered")
        XCTAssertNotNil(view.playerLayer as? AVPlayerLayer)
        XCTAssertTrue(view.playerLayer === view.layer,
                      "playerLayer must be the backing layer, not a detached sublayer")
    }

    /// `.resizeAspect` fits the frame without cropping. `.resizeAspectFill`
    /// (what the QR preview uses) would silently cut off the edges of a video
    /// whose aspect ratio differs from the panel's 16:9.
    func testVideoGravityPreservesAspectRatio() {
        let view = PlayerLayerUIView()
        XCTAssertEqual(view.playerLayer.videoGravity, .resizeAspect)
    }

    /// Attaching the player is what makes the picture appear, and the same view
    /// must follow a *new* player when the user switches streams.
    func testPlayerCanBeAttachedAndReplaced() {
        let view = PlayerLayerUIView()
        XCTAssertNil(view.playerLayer.player, "a fresh surface shows no picture")

        let first = AVPlayer()
        view.playerLayer.player = first
        XCTAssertTrue(view.playerLayer.player === first)

        let second = AVPlayer()
        view.playerLayer.player = second
        XCTAssertTrue(view.playerLayer.player === second,
                      "switching streams must repoint the layer, or the panel shows a dead player")

        view.playerLayer.player = nil
        XCTAssertNil(view.playerLayer.player, "stop must take the picture away")
    }

    // MARK: - The display rule: picture only for .video

    /// The card's core "show it ONLY when the playing stream.type == .video"
    /// rule, asserted as a truth table. Every non-video case must be false —
    /// that is what keeps the audio-only path untouched.
    func testOnlyVideoStreamsGetASurface() {
        let video = stream(.video)
        let audio = stream(.audio)
        let channel = stream(.channel)

        XCTAssertTrue(VideoSurfacePolicy.shouldShow(currentStream: video, hasPlayer: true))

        XCTAssertFalse(VideoSurfacePolicy.shouldShow(currentStream: audio, hasPlayer: true),
                       "an audio stream must not grow a black rectangle")
        XCTAssertFalse(VideoSurfacePolicy.shouldShow(currentStream: channel, hasPlayer: true),
                       "channels play in the browser, so an empty panel would be a lie")
        XCTAssertFalse(VideoSurfacePolicy.shouldShow(currentStream: nil, hasPlayer: true),
                       "nothing is playing: no panel")
    }

    /// While a stream is still resolving there is no AVPlayer yet. Showing a
    /// black box during "Connecting..." reads as a broken video; the panel must
    /// wait for a real player.
    func testNoSurfaceBeforeThePlayerExists() {
        XCTAssertFalse(VideoSurfacePolicy.shouldShow(currentStream: stream(.video), hasPlayer: false))
    }

    /// The dock is sized for 16:9 (the dominant shape of these streams);
    /// `.resizeAspect` letterboxes anything else inside it.
    func testDockKeepsA16By9Box() {
        XCTAssertEqual(VideoSurfacePolicy.aspectRatio, 16.0 / 9.0, accuracy: 0.0001)
    }

    // MARK: - The player must be observable

    /// SwiftUI can only re-point the layer if the player is @Published: a plain
    /// stored property would leave the surface attached to the previous
    /// stream's player forever (a frozen frame, or a black panel on stream two).
    @MainActor
    func testPlayerIsPublishedToObservers() {
        let player = StreamPlayer()
        var notifications = 0
        let token = player.objectWillChange.sink { _ in notifications += 1 }

        XCTAssertEqual(notifications, 0, "constructing the player must not fire")
        player.play(Stream(name: "Audio only", url: "https://example.com/a.m3u8", type: .audio))
        XCTAssertGreaterThan(notifications, 0,
                             "play() must notify observers or the panel never appears")
        // Still connecting: no AVPlayer yet, and therefore no picture to show.
        XCTAssertNil(player.avPlayer)
        player.stop()
        withExtendedLifetime(token) {}
    }
}
