import AVFoundation
import XCTest
@testable import Radio

/// Tests for the fullscreen + Picture-in-Picture card.
///
/// What is testable without a device: the two user-visible POLICIES (who gets a
/// PiP affordance; how the fullscreen state moves) and the PiP session's
/// published state before AVKit is involved. An actual floating window is
/// XCUITest/device territory (VideoSurfaceUITests) — but the *rule* that closing
/// it ends playback is testable right here, because it is a plain closure the
/// player wires up at init.
final class VideoFullscreenPiPTests: XCTestCase {

    // `Radio.` prefix: in the test target a bare `Stream` is ambiguous with
    // Foundation's `Stream` class (see NowPlayingInfoTests for the same note).
    private func stream(_ type: StreamType) -> Radio.Stream {
        Stream(name: "Test", url: "https://example.com/stream.m3u8", type: type)
    }

    // MARK: - PiP visibility policy

    /// The card's rule "audio-only streams must NOT get a PiP button (nothing
    /// to draw)", as a truth table — same shape and same reasoning as the
    /// surface rule: an affordance that can only fail is worse than none.
    func testOnlyVideoStreamsGetAPiPAffordance() {
        XCTAssertTrue(VideoSurfacePolicy.shouldOfferPiP(currentStream: stream(.video), hasPlayer: true))

        XCTAssertFalse(VideoSurfacePolicy.shouldOfferPiP(currentStream: stream(.audio), hasPlayer: true),
                       "an audio stream has no picture to float — the button must not appear")
        XCTAssertFalse(VideoSurfacePolicy.shouldOfferPiP(currentStream: stream(.channel), hasPlayer: true),
                       "channels mostly play in the browser; there is no layer to float")
        XCTAssertFalse(VideoSurfacePolicy.shouldOfferPiP(currentStream: nil, hasPlayer: true),
                       "nothing is playing: no PiP")
    }

    /// While a video is still resolving there is no AVPlayer and therefore no
    /// AVPlayerLayer anywhere in the process — a PiP session bound to nothing is
    /// a dead button.
    func testNoPiPBeforeThePlayerExists() {
        XCTAssertFalse(VideoSurfacePolicy.shouldOfferPiP(currentStream: stream(.video), hasPlayer: false))
    }

    /// PiP is offered exactly when the picture is shown. If these two rules ever
    /// drift apart, the panel grows a button for a box that isn't there (or
    /// hides PiP while a video plays). Asserted as an invariant, not a copy of
    /// the other truth table.
    func testPiPTrackingTheSurfaceRule() {
        for type in [StreamType.audio, .video, .channel] {
            for hasPlayer in [true, false] {
                let s = stream(type)
                XCTAssertEqual(
                    VideoSurfacePolicy.shouldOfferPiP(currentStream: s, hasPlayer: hasPlayer),
                    VideoSurfacePolicy.shouldShow(currentStream: s, hasPlayer: hasPlayer),
                    "PiP must track the surface for .\(type) / hasPlayer=\(hasPlayer)"
                )
            }
        }
    }

    // MARK: - Fullscreen state machine

    /// The two arrows the user has: expand out of the dock, collapse back into
    /// it. Both idempotent, so a double tap can never wedge the app into a
    /// fullscreen state with no visible exit.
    func testExpandAndCollapseRoundTrip() {
        XCTAssertEqual(VideoSurfaceMode.transition(from: .docked, action: .expand), .fullscreen)
        XCTAssertEqual(VideoSurfaceMode.transition(from: .fullscreen, action: .collapse), .docked)

        XCTAssertEqual(VideoSurfaceMode.transition(from: .fullscreen, action: .expand), .fullscreen,
                       "expand while fullscreen must be a no-op, not an error state")
        XCTAssertEqual(VideoSurfaceMode.transition(from: .docked, action: .collapse), .docked,
                       "collapse while docked must be a no-op")
    }

    /// Stop collapses: a fullscreen overlay that outlives its stream is a black
    /// screen over the app with nothing playing — the ghost-card bug in
    /// fullscreen form. Docked, stop must not invent a mode change.
    func testStopAlwaysLeavesFullscreen() {
        XCTAssertEqual(VideoSurfaceMode.transition(from: .fullscreen, action: .stop), .docked)
        XCTAssertEqual(VideoSurfaceMode.transition(from: .docked, action: .stop), .docked)
    }

    func testModeFlags() {
        XCTAssertTrue(VideoSurfaceMode.fullscreen.isFullscreen)
        XCTAssertFalse(VideoSurfaceMode.docked.isFullscreen)
    }

    /// The overlay's chrome auto-hides, so the state machine — not the chrome —
    /// must guarantee a way out: from fullscreen, both exits are defined and
    /// both land docked.
    func testFullscreenAlwaysHasAnExit() {
        for action in [VideoSurfaceMode.Action.collapse, .stop] {
            XCTAssertEqual(VideoSurfaceMode.transition(from: .fullscreen, action: action), .docked)
        }
    }

    /// Every (mode, action) pair must be defined: an unhandled combination would
    /// have to be a compile error here, and the exhaustive switch in
    /// `transition` is what keeps it that way.
    func testEveryTransitionIsDefined() {
        var seen = 0
        for mode in [VideoSurfaceMode.docked, .fullscreen] {
            for action in [VideoSurfaceMode.Action.expand, .collapse, .stop] {
                let next = VideoSurfaceMode.transition(from: mode, action: action)
                // Docked can only ever become docked or fullscreen — never a
                // third state, because there isn't one.
                XCTAssertTrue(next == .docked || next == .fullscreen)
                seen += 1
            }
        }
        XCTAssertEqual(seen, 6, "3 actions x 2 modes must all be exercised")
    }

    // MARK: - PiP session state before AVKit

    /// A fresh session reports "nothing available": the button reads these flags
    /// to decide whether it does anything. A session claiming canStart=true with
    /// no bound layer is a dead button waiting to happen.
    func testFreshSessionOffersNothing() {
        let session = PiPSession()
        XCTAssertFalse(session.canStart)
        XCTAssertFalse(session.isActive)
    }

    /// `stopSession()` on a session that never bound a layer must not crash and
    /// must leave the flags clean — StreamPlayer calls it on EVERY teardown
    /// (stop, stream switch, audio included), so the no-op path is the common
    /// path and it has to be safe. `start()` with no controller likewise must be
    /// inert rather than a trap.
    func testSessionCallsWithoutABindingAreInert() {
        let session = PiPSession()
        session.stopSession()
        session.unbind()
        session.start()
        XCTAssertFalse(session.canStart)
        XCTAssertFalse(session.isActive)
    }

    // MARK: - Closing the window ends playback (card rule C)

    /// The rule the card spelled out: "PiP stop/close stops playback like Stop
    /// does". `onClose` is exactly what AVKit's restore-user-interface callback
    /// invokes, so driving it here tests the wiring that matters: same path as
    /// the Stop button, so isPlaying / currentStream / the now-playing card all
    /// follow it.
    @MainActor
    func testPiPCloseStopsPlaybackLikeStop() {
        let player = StreamPlayer()
        player.play(stream(.video))
        // A stubbed resolve means no network: playback is "started" in the
        // sense the UI cares about (intent + currentStream set).
        XCTAssertNotNil(player.currentStream)
        XCTAssertTrue(player.isPlaying)

        XCTAssertNotNil(player.pip.onClose, "the player must wire PiP-close to playback stop")
        player.pip.onClose?()

        XCTAssertFalse(player.isPlaying, "closing the floating window left the stream playing")
        XCTAssertNil(player.currentStream, "closing the floating window must end the stream")
    }

    /// The loop guard, testable without AVKit: `stopSession()` is what
    /// `StreamPlayer.teardownPlayback` calls on EVERY teardown (Stop, stream
    /// switch). If it fired `onClose` — which is wired to `stop()` — then stop
    /// would re-enter stop, and worse, a STREAM SWITCH would call stop() on the
    /// stream the user just started. Only the floating window's own close (the
    /// restore callback) may end playback.
    @MainActor
    func testStopSessionDoesNotFireClose() {
        let player = StreamPlayer()
        let realClose = player.pip.onClose   // the wiring this test must not break
        var closes = 0
        player.pip.onClose = { closes += 1 }

        player.pip.stopSession()
        player.pip.unbind()
        XCTAssertEqual(closes, 0,
                       "an app-initiated stop fired the close rule — teardown would re-enter stop()")

        // Restore the player's own wiring and check the user path really does end
        // playback (a spy alone would pass even if the real rule were missing).
        player.pip.onClose = realClose
        player.play(stream(.video))
        player.pip.onClose?()
        XCTAssertFalse(player.isPlaying, "the user-close path must still stop playback")
    }

    /// The session must be the PLAYER's — one floating-window controller for the
    /// app's single stream — and it must survive a stop so a later video can
    /// re-bind it. If the view made its own session, two PiP controllers could
    /// exist at once (docked + fullscreen) and neither would be stopped by
    /// StreamPlayer.teardownPlayback.
    @MainActor
    func testTheSessionIsOwnedByThePlayer() {
        let player = StreamPlayer()
        let session = player.pip
        XCTAssertNotNil(session.onClose)

        player.play(stream(.video))
        player.stop()
        XCTAssertTrue(player.pip === session,
                      "stop must not replace the session — the surface holds it across streams")
    }
}
