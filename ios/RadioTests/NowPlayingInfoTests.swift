import MediaPlayer
import XCTest
@testable import Radio

/// Tests for the Lock Screen / Control Center now-playing payload
/// (NowPlayingInfo.dictionary) and for the next/previous stream selection the
/// remote commands use.
///
/// These cover the bug "no now-playing card at all": the card's content is now a
/// pure function of (stream, elapsed, rate, duration), so the parts a user can
/// actually see wrong — the title/artist lines, the play/pause glyph, whether a
/// live stream pretends to be scrubable — are verified without an AVPlayer, an
/// audio session, or a device.
final class NowPlayingInfoTests: XCTestCase {

    // `Radio.` prefix: in the test target a bare `Stream` is ambiguous with
    // Foundation's `Stream` class (inside the app module its own declaration
    // wins, which is why StreamPlayer/StreamStoreTests need no prefix).
    private func stream(_ name: String = "Radio Romania Actualitati", type: StreamType = .audio) -> Radio.Stream {
        Stream(name: name, url: "https://example.com/live.m3u8", type: type)
    }

    /// NSNumber in a now-playing payload bridges cleanly to Double/Bool/Int in
    /// Swift, so tests read the keys through these small accessors.
    private func double(_ info: [String: Any], _ key: String) -> Double? { info[key] as? Double }
    private func boolean(_ info: [String: Any], _ key: String) -> Bool? { info[key] as? Bool }
    private func string(_ info: [String: Any], _ key: String) -> String? { info[key] as? String }
    private func integer(_ info: [String: Any], _ key: String) -> Int? { info[key] as? Int }

    // MARK: - Identity shown on the card

    func testTitleIsStreamNameAndArtistIsRadio() {
        let info = NowPlayingInfo.dictionary(
            stream: stream("Kiss FM"), elapsedSeconds: 12, rate: 1, durationSeconds: nil
        )
        XCTAssertEqual(string(info, MPMediaItemPropertyTitle), "Kiss FM")
        XCTAssertEqual(string(info, MPMediaItemPropertyArtist), NowPlayingInfo.artistName)
        XCTAssertEqual(NowPlayingInfo.artistName, "Radio")
    }

    /// Artwork must be ABSENT (not NSNull) when there is no artwork: the card
    /// for a stream has none, and the system falls back to its own placeholder.
    func testArtworkKeyIsAbsentRatherThanNull() {
        let info = NowPlayingInfo.dictionary(
            stream: stream(), elapsedSeconds: 0, rate: 1, durationSeconds: 300
        )
        XCTAssertFalse(info.keys.contains(MPMediaItemPropertyArtwork))
    }

    // MARK: - Live vs on-demand

    /// A live stream (no usable duration) must say so and must NOT advertise a
    /// duration, or Control Center draws a scrubber that can never be honoured.
    func testLiveStreamHasNoDurationAndNoScrubber() {
        for bogus in [nil, Double.infinity, Double.nan, 0.0, -1.0] {
            let info = NowPlayingInfo.dictionary(
                stream: stream(), elapsedSeconds: 42, rate: 1, durationSeconds: bogus
            )
            XCTAssertEqual(boolean(info, MPNowPlayingInfoPropertyIsLiveStream), true,
                           "an unusable duration must be treated as live")
            XCTAssertEqual(double(info, MPMediaItemPropertyPlaybackDuration), 0,
                           "a live card must not report a duration")
            // The elapsed position still runs on a live card.
            XCTAssertEqual(double(info, MPNowPlayingInfoPropertyElapsedPlaybackTime), 42)
        }
    }

    /// An on-demand item with a real duration is not live and reports it, so the
    /// scrubber shown by the system is a real one.
    func testOnDemandReportsDurationAndIsNotLive() {
        let info = NowPlayingInfo.dictionary(
            stream: stream("Podcast", type: .video), elapsedSeconds: 60, rate: 1, durationSeconds: 1800
        )
        XCTAssertEqual(boolean(info, MPNowPlayingInfoPropertyIsLiveStream), false)
        XCTAssertEqual(double(info, MPMediaItemPropertyPlaybackDuration), 1800)
    }

    // MARK: - Play/pause glyph

    /// The lock-screen button follows the rate: paused must be 0, playing 1.
    /// A paused card that still reported rate 1 would show "playing".
    func testRateDistinguishesPausedFromPlaying() {
        let playing = NowPlayingInfo.dictionary(
            stream: stream(), elapsedSeconds: 5, rate: 1, durationSeconds: nil
        )
        XCTAssertEqual(double(playing, MPNowPlayingInfoPropertyPlaybackRate), 1)

        let paused = NowPlayingInfo.dictionary(
            stream: stream(), elapsedSeconds: 5, rate: 0, durationSeconds: nil
        )
        XCTAssertEqual(double(paused, MPNowPlayingInfoPropertyPlaybackRate), 0)
    }

    /// Even a live stream must report a non-zero rate while playing (the glyph
    /// is derived from it), so the live path can't hardcode 0.
    func testLiveStreamStillReportsPlayingRate() {
        let info = NowPlayingInfo.dictionary(
            stream: stream(), elapsedSeconds: 5, rate: 1, durationSeconds: nil
        )
        XCTAssertEqual(boolean(info, MPNowPlayingInfoPropertyIsLiveStream), true)
        XCTAssertEqual(double(info, MPNowPlayingInfoPropertyPlaybackRate), 1)
    }

    /// Junk values AVPlayer can hand back (NaN elapsed just after loading, a
    /// negative right after a seek, a NaN rate) must never reach the system: a
    /// NaN in the payload makes the whole card fail to render.
    func testNonFiniteInputsAreClampedNotPropagated() {
        let info = NowPlayingInfo.dictionary(
            stream: stream(), elapsedSeconds: .nan, rate: .nan, durationSeconds: .nan
        )
        let elapsed = double(info, MPNowPlayingInfoPropertyElapsedPlaybackTime)
        let rate = double(info, MPNowPlayingInfoPropertyPlaybackRate)
        XCTAssertEqual(elapsed, 0)
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(elapsed?.isFinite, true)
        XCTAssertEqual(rate?.isFinite, true)
    }

    /// A fast-forward rate is still "playing", not paused, and the card keeps a
    /// sane rate rather than passing 2x through as if it were the normal rate.
    func testNonUnitPlayingRateIsReportedAsPlaying() {
        let info = NowPlayingInfo.dictionary(
            stream: stream(), elapsedSeconds: 30, rate: 2, durationSeconds: 120
        )
        XCTAssertEqual(double(info, MPNowPlayingInfoPropertyPlaybackRate), 1)
    }

    /// Video streams report as video media, audio/channel streams as ordinary
    /// music, so surfaces that group or filter by media type treat them right.
    func testMediaTypeFollowsStreamType() {
        let audio = NowPlayingInfo.dictionary(stream: stream(type: .audio), elapsedSeconds: 0, rate: 1, durationSeconds: nil)
        let video = NowPlayingInfo.dictionary(stream: stream(type: .video), elapsedSeconds: 0, rate: 1, durationSeconds: nil)
        let channel = NowPlayingInfo.dictionary(stream: stream(type: .channel), elapsedSeconds: 0, rate: 1, durationSeconds: nil)
        // MPMediaType.rawValue is a UInt mask; the payload boxes it as a number,
        // so compare through Int to keep both sides the same type.
        XCTAssertEqual(integer(audio, MPMediaItemPropertyMediaType), Int(MPMediaType.music.rawValue))
        XCTAssertEqual(integer(video, MPMediaItemPropertyMediaType), Int(MPMediaType.movie.rawValue))
        XCTAssertEqual(integer(channel, MPMediaItemPropertyMediaType), Int(MPMediaType.music.rawValue))
        XCTAssertNotEqual(integer(audio, MPMediaItemPropertyMediaType),
                          integer(video, MPMediaItemPropertyMediaType))
    }

    // MARK: - Through the real system center

    /// End-to-end through MPNowPlayingInfoCenter itself: the payload must be
    /// ACCEPTED by the system (a malformed payload is silently dropped, which
    /// looks identical to "no card" on the Lock Screen), and clear() must take
    /// the card away rather than leaving a ghost entry. This also smoke-tests
    /// NowPlayingController construction, i.e. the remote-command registration.
    func testPublishAndClearRoundTripThroughTheSystemCenter() {
        let controller = NowPlayingController()
        defer { controller.clear() }

        controller.publish(stream: stream("Kiss FM"), elapsedSeconds: 30, rate: 1, durationSeconds: nil)
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertNotNil(info, "the system rejected the payload — no card would show")
        XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, "Kiss FM")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .playing)

        controller.publish(stream: stream("Kiss FM"), elapsedSeconds: 30, rate: 0, durationSeconds: nil)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .paused)

        controller.clear()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo,
                     "a stopped stream must not leave a card behind")
        XCTAssertEqual(MPNowPlayingInfoCenter.default().playbackState, .stopped)
    }

    // MARK: - Next / previous (the dial)

    private var dial: [Radio.Stream] {
        [
            Stream(name: "One", url: "https://example.com/1.mp3"),
            Stream(name: "Two", url: "https://example.com/2.mp3"),
            Stream(name: "Three", url: "https://example.com/3.mp3"),
        ]
    }

    func testNextAndPreviousWalkTheSavedList() {
        let streams = dial
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: streams[0].id, in: streams, forward: true), 1)
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: streams[1].id, in: streams, forward: true), 2)
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: streams[1].id, in: streams, forward: false), 0)
    }

    /// The dial wraps: "next" from the last stream is the first, "previous" from
    /// the first is the last (a radio list has no dead ends).
    func testDialWrapsAtBothEnds() {
        let streams = dial
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: streams[2].id, in: streams, forward: true), 0)
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: streams[0].id, in: streams, forward: false), 2)
    }

    /// Nothing sane to skip to, so nil: the caller then refuses the command
    /// instead of claiming it worked. Empty store, or a current stream that has
    /// since been deleted.
    func testSkipWithoutAValidCurrentStreamIsRefused() {
        let streams = dial
        XCTAssertNil(NowPlayingInfo.nextIndex(current: streams[0].id, in: [], forward: true))
        XCTAssertNil(NowPlayingInfo.nextIndex(current: UUID(), in: streams, forward: true))
        XCTAssertNil(NowPlayingInfo.nextIndex(current: UUID(), in: streams, forward: false))
    }

    /// A single-stream store must not skip to nothing (or crash): it wraps onto
    /// itself.
    func testSingleStreamDialWrapsToItself() {
        let only = dial[0]
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: only.id, in: [only], forward: true), 0)
        XCTAssertEqual(NowPlayingInfo.nextIndex(current: only.id, in: [only], forward: false), 0)
    }
}
