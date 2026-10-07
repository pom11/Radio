import XCTest
@testable import Radio

/// The user report this covers: "i dont see the refresh stream if the link is
/// broken".
///
/// Refresh lives only in the player bar, so the bar's mount rule IS the
/// affordance's reach rule. The dock mounts the bar when the video surface is
/// up, when `isPlaying`, or when `isFailed` — and before this card `isFailed`
/// was set by exactly ONE path (`giveUpOnPlayback`, reached after the auto
/// recovery budget was spent). The paths where playback *never even started*
/// (resolve returned nothing, resolve fell through to the page, an unparseable
/// url, the taint early-return) set `statusText` and `isPlaying = false` and
/// left `isFailed` false → bar unmounted → the user's broken link had no
/// Refresh anywhere, which is precisely the state that needs it.
///
/// Two layers, because the complaint has two halves:
/// - `PlayerBarPolicy` is the rule the dock and the bar's Refresh gate read,
///   asserted directly (paused audio stays hidden — that behaviour is by
///   design and must not regress);
/// - `StreamPlayer` is asserted at the flag level with a stubbed `resolve`, so
///   each failure path is reached deterministically and offline.
final class BrokenLinkRefreshTests: XCTestCase {

    private let page = "https://example.com/live"
    private let manifest = "https://cdn.example.com/a/stream.m3u8"

    private func stream(type: StreamType = .audio,
                        url: String,
                        pageUrl: String? = nil) -> Radio.Stream {
        // `Radio.` required: bare `Stream` in type position is ambiguous with
        // Foundation.Stream in this module.
        Radio.Stream(name: "Broken", url: url, type: type, pageUrl: pageUrl)
    }

    /// Pump the main run loop until `condition` (the MainActor play task is
    /// resumed through the main queue). With a stubbed resolve this resolves in
    /// microseconds; the timeout only fires if a step never completes.
    @discardableResult
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - The bar's mount rule (pure policy)

    func testBarShowsForPlayingAndForFailedButNotForPaused() {
        // A stream that died must keep the bar (and therefore Refresh) on screen.
        XCTAssertTrue(PlayerBarPolicy.shouldShowBar(isPlaying: true, isFailed: false))
        XCTAssertTrue(PlayerBarPolicy.shouldShowBar(isPlaying: false, isFailed: true),
                      "a dead stream lost the bar — the user's complaint")
        // Paused audio hides the bar BY DESIGN (long-standing behaviour); only a
        // terminal failure forces it back up.
        XCTAssertFalse(PlayerBarPolicy.shouldShowBar(isPlaying: false, isFailed: false),
                       "a paused audio stream must not keep the bar (unchanged behaviour)")
    }

    func testTransportAppearsExactlyWhenTheStreamNeedsRescuing() {
        // Failed → Play (retry with a fresh budget) + Stop (dismiss the bar).
        XCTAssertTrue(PlayerBarPolicy.showsTransport(isPlaying: false, isFailed: true))
        // Audio playing → the bar has always been name + AirPlay + Refresh only.
        XCTAssertFalse(PlayerBarPolicy.showsTransport(isPlaying: true, isFailed: false))
        // A failed stream that somehow still reports playing (a stall) keeps the
        // transport too: Stop must always be reachable on a dead stream.
        XCTAssertTrue(PlayerBarPolicy.showsTransport(isPlaying: true, isFailed: true))
    }

    func testRefreshOfferedOnlyWhenARefreshCouldWork() {
        XCTAssertTrue(PlayerBarPolicy.shouldOfferRefresh(stream(type: .audio, url: manifest, pageUrl: page)))
        // A channel's url IS its page → refreshable even with no explicit pageUrl.
        XCTAssertTrue(PlayerBarPolicy.shouldOfferRefresh(stream(type: .channel, url: page)))
        // An audio stream with no source page has nothing to refetch from: a
        // button here could only ever say "No source page".
        XCTAssertFalse(PlayerBarPolicy.shouldOfferRefresh(stream(type: .audio, url: manifest)))
        XCTAssertFalse(PlayerBarPolicy.shouldOfferRefresh(nil))
    }

    // MARK: - Every terminal failure path must raise the flag

    /// The path the user hit: a channel whose page yields no manifest. Before
    /// the fix this left `isFailed` false, so the bar (with Refresh) was gone.
    func testResolveFailureMarksStreamFailedAndStillOffersRefresh() {
        let player = StreamPlayer()
        player.resolve = { _ in nil }                 // ChannelResolver found nothing
        let channel = stream(type: .channel, url: page)

        player.play(channel, userInitiated: true)
        XCTAssertTrue(waitUntil { player.statusText == "Open in browser" },
                      "resolve failure never reached its honest end state")
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.isFailed,
                      "a broken link that never started playback left the bar (and Refresh) hidden")
        XCTAssertTrue(PlayerBarPolicy.shouldShowBar(isPlaying: player.isPlaying, isFailed: player.isFailed),
                      "dock would still unmount the bar for this stream")
        XCTAssertTrue(PlayerBarPolicy.shouldOfferRefresh(player.currentStream),
                      "the failed bar would name a stream it cannot refresh")
        player.stop()
        XCTAssertFalse(player.isFailed, "stop() clears the failed state")
    }

    /// A resolver that falls through to the page is refused by the taint guard —
    /// same dead end for the user, same requirement to keep the lever visible.
    func testTaintedResolveMarksStreamFailed() {
        let player = StreamPlayer()
        player.resolve = { _ in self.page }           // the page handed back as a stream
        let s = stream(type: .audio, url: self.manifest, pageUrl: self.page)

        player.play(s, userInitiated: true)
        XCTAssertTrue(waitUntil { player.isFailed },
                      "tainted resolve left the stream in a state with no bar")
        XCTAssertEqual(player.statusText, "Failed")
        XCTAssertFalse(player.isPlaying)
        player.stop()
    }

    /// A resolved url that cannot become a `URL` at all is terminal too. The
    /// value must still LOOK like http(s) to get here: a non-http string is
    /// caught earlier by the taint guard (which is also a `failPlayback` path,
    /// asserted by `testTaintedStoredURLEarlyReturnMarksStreamFailed`).
    func testInvalidURLMarksStreamFailed() {
        let player = StreamPlayer()
        player.resolve = { _ in "https://ex ample.com/a.m3u8" }   // space: URL(string:) rejects it
        let s = stream(type: .audio, url: self.manifest, pageUrl: self.page)

        player.play(s, userInitiated: true)
        XCTAssertTrue(waitUntil { player.statusText == "Invalid URL" },
                      "invalid-url path never reached its end state")
        XCTAssertTrue(player.isFailed, "an unplayable url hid the bar with the only lever inside it")
        player.stop()
    }

    /// A stream whose stored url is itself its source page is refused before any
    /// network work; that is a terminal state the user must be able to escape.
    func testTaintedStoredURLEarlyReturnMarksStreamFailed() {
        let player = StreamPlayer()
        player.resolve = { _ in
            XCTFail("a tainted stored url must be refused before resolving")
            return nil
        }
        let s = stream(type: .audio, url: page, pageUrl: page)

        player.play(s, userInitiated: true)
        XCTAssertEqual(player.statusText, "Failed")
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.isFailed, "the taint early-return left no reachable Refresh path")
        player.stop()
    }

    /// A plain retry path must NOT be marked failed: while the recovery budget
    /// is still spending attempts, the player is working, not dead.
    func testRecoveryInProgressIsNotMarkedFailed() {
        let player = StreamPlayer()
        var calls = 0
        player.resolve = { _ in
            calls += 1
            return calls == 1 ? self.manifest : nil
        }
        let s = stream(type: .audio, url: self.manifest)   // no pageUrl → retry same url
        player.currentStream = s
        player.refetch.finish()                            // guard free, budget fresh

        XCTAssertTrue(player.refetch.chargeAutoAttempt())
        // The honest mid-recovery state: not failed yet.
        XCTAssertFalse(player.isFailed)
        player.stop()
    }
}
