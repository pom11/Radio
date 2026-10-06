import XCTest
@testable import Radio

/// Refetch-from-source — the decision rules the iOS app previously did not have
/// at all (on `.failed` it just set statusText "Failed" and dead-ended).
///
/// These cover `RefetchMachine`, which is deliberately pure: the budget, the
/// re-entrancy guard and the taint rule are all reachable here with no network
/// and no AVPlayer, which is exactly why the logic was split out of StreamPlayer.
final class RefetchTests: XCTestCase {

    private let page = "https://example.com/live"
    private let good = "https://cdn.example.com/a/stream.mp3"
    private let fresh = "https://cdn.example.com/b/stream.m3u8"

    private func stream(type: StreamType = .audio,
                        url: String,
                        pageUrl: String? = nil) -> Radio.Stream {
        // `Radio.` is not decoration: in the test module a bare `Stream` in type
        // position is ambiguous with Foundation.Stream and does not compile.
        Radio.Stream(name: "S", url: url, type: type, pageUrl: pageUrl)
    }

    // MARK: - Where a refresh can even come from

    func testSourcePagePrefersExplicitPageUrl() {
        XCTAssertEqual(
            RefetchMachine.sourcePage(of: stream(url: good, pageUrl: page)), page)
    }

    func testSourcePageForNonChannelWithoutPageUrlIsNil() {
        // An .audio url IS the stream; scraping it as a page would be nonsense.
        XCTAssertNil(RefetchMachine.sourcePage(of: stream(type: .audio, url: good)))
        XCTAssertNil(RefetchMachine.sourcePage(of: stream(type: .video, url: good)))
        XCTAssertFalse(RefetchMachine.canRefresh(stream(type: .audio, url: good)))
    }

    func testSourcePageForChannelFallsBackToItsURL() {
        // A channel's url is the source page by design (ChannelResolver), so a
        // channel with no pageUrl is still refreshable.
        let channel = stream(type: .channel, url: page)
        XCTAssertEqual(RefetchMachine.sourcePage(of: channel), page)
        XCTAssertTrue(RefetchMachine.canRefresh(channel))
    }

    func testBlankPageUrlIsNotASourcePage() {
        // Whitespace-only pageUrl must not count as "has a source page".
        let s = stream(type: .audio, url: good, pageUrl: "   ")
        XCTAssertNil(RefetchMachine.sourcePage(of: s))
    }

    func testLiteralManifestDetection() {
        XCTAssertTrue(RefetchMachine.isLiteralManifest("https://x/y/stream.m3u8"))
        XCTAssertTrue(RefetchMachine.isLiteralManifest("https://x/y/STREAM.M3U8?token=1"))
        XCTAssertTrue(RefetchMachine.isLiteralManifest("https://x/y/manifest.mpd"))
        XCTAssertFalse(RefetchMachine.isLiteralManifest("https://x/y/proxy.php"))
        XCTAssertFalse(RefetchMachine.isLiteralManifest("https://x/y.m3u8isnotadir/proxy.php"))
    }

    // MARK: - Re-entrancy guard

    func testConcurrentRefreshIsRefusedAndLeavesStateUntouched() {
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)

        XCTAssertEqual(machine.begin(stream: s, manual: true), .start)
        XCTAssertTrue(machine.isRefreshing)

        // Second attempt while in flight: refused, and it must not spend budget.
        XCTAssertEqual(machine.begin(stream: s, manual: false), .refused(.alreadyRefreshing))
        XCTAssertEqual(machine.begin(stream: s, manual: true), .refused(.alreadyRefreshing))
        XCTAssertEqual(machine.autoAttempts, 0, "a refused attempt must not be charged to the budget")

        machine.finish()
        XCTAssertFalse(machine.isRefreshing)
        XCTAssertEqual(machine.begin(stream: s, manual: false), .start, "refreshable again once finished")
    }

    func testManualRefreshDoesNotChargeTheAutoBudget() {
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)

        for _ in 0..<5 {
            XCTAssertEqual(machine.begin(stream: s, manual: true), .start)
            machine.finish()
        }
        XCTAssertEqual(machine.autoAttempts, 0)
        // User taps are unbounded on purpose, and spending them must not block
        // a later automatic refetch.
        XCTAssertEqual(machine.begin(stream: s, manual: false), .start)
    }

    // MARK: - Auto budget

    func testAutoRefetchIsBoundedThenRefuses() {
        let machine = RefetchMachine(maxAutoAttempts: 3)
        let s = stream(url: good, pageUrl: page)

        for attempt in 1...3 {
            XCTAssertEqual(machine.begin(stream: s, manual: false), .start, "attempt \(attempt) should run")
            XCTAssertEqual(machine.autoAttempts, attempt)
            machine.finish()
        }
        XCTAssertEqual(machine.begin(stream: s, manual: false), .refused(.autoBudgetExhausted))
        XCTAssertEqual(machine.autoAttempts, 3, "the refusal is not charged")

        // The whole point of a bounded *auto* budget: a manual tap still works.
        XCTAssertEqual(machine.begin(stream: s, manual: true), .start)
    }

    func testRefusalWithoutSourcePageDoesNotSpinUpTheMachine() {
        let machine = RefetchMachine()
        let s = stream(type: .audio, url: good)   // no pageUrl

        XCTAssertEqual(machine.begin(stream: s, manual: false), .refused(.noSourcePage))
        XCTAssertEqual(machine.begin(stream: s, manual: true), .refused(.noSourcePage))
        XCTAssertFalse(machine.isRefreshing, "a refused refresh must not leave a stuck spinner")
        XCTAssertEqual(machine.autoAttempts, 0)
    }

    func testFreshPlaybackResetsTheBudget() {
        let machine = RefetchMachine(maxAutoAttempts: 1)
        let s = stream(url: good, pageUrl: page)

        XCTAssertEqual(machine.begin(stream: s, manual: false), .start)
        machine.finish()
        XCTAssertEqual(machine.begin(stream: s, manual: false), .refused(.autoBudgetExhausted))

        machine.reset()   // the user started this stream from the list
        XCTAssertEqual(machine.autoAttempts, 0)
        XCTAssertFalse(machine.isRefreshing)
        XCTAssertEqual(machine.begin(stream: s, manual: false), .start)
    }

    func testFinishKeepsTheSpentBudget() {
        // An exhausted budget is not topped back up by a refresh completing —
        // otherwise a permanently dead stream would refetch forever.
        let machine = RefetchMachine(maxAutoAttempts: 1)
        let s = stream(url: good, pageUrl: page)
        XCTAssertEqual(machine.begin(stream: s, manual: false), .start)
        machine.finish()
        XCTAssertEqual(machine.autoAttempts, 1)
    }

    func testRetryBackoffGrowsWithSpentAttempts() {
        let machine = RefetchMachine(maxAutoAttempts: 4, backoffBase: 10)
        let s = stream(url: good, pageUrl: page)
        XCTAssertEqual(machine.retryAfter, 10)          // before any attempt

        machine.begin(stream: s, manual: false); machine.finish()
        XCTAssertEqual(machine.retryAfter, 10)          // 1 attempt spent
        machine.begin(stream: s, manual: false); machine.finish()
        XCTAssertEqual(machine.retryAfter, 20)          // 2 spent
        machine.begin(stream: s, manual: false); machine.finish()
        XCTAssertEqual(machine.retryAfter, 30)          // 3 spent
    }

    // MARK: - Taint guard (the rule that matters)

    func testPageUrlIsNeverAcceptedAsTheRefreshedURL() {
        // The resolver's last resort is to hand back the page it scraped. Saving
        // that would replace a working url with a dead HTML page — the taint
        // that was observed in the user's real config on macOS.
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        XCTAssertEqual(machine.outcome(for: page, stream: s, verified: true), .rejected(page),
                       "pageUrl accepted as a playable url — the taint bug")
    }

    func testChannelPageURLIsRejectedEvenWithoutAnExplicitPageUrl() {
        // For a channel, `url` IS the page. Checking only `stream.pageUrl` here
        // would let the page be written as the playable url.
        let machine = RefetchMachine()
        let channel = stream(type: .channel, url: page)
        XCTAssertEqual(machine.outcome(for: page, stream: channel, verified: true), .rejected(page))
    }

    func testNonHTTPSchemeIsRejected() {
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        for bogus in ["file:///etc/passwd", "javascript:alert(1)", "not a url", "//cdn/x.m3u8"] {
            XCTAssertEqual(machine.outcome(for: bogus, stream: s, verified: true), .rejected(bogus),
                           "non-http(s) value \(bogus) would have been persisted")
        }
    }

    func testEmptyAndNilResolutionAreFailures() {
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        XCTAssertEqual(machine.outcome(for: nil, stream: s, verified: true), .failed)
        XCTAssertEqual(machine.outcome(for: "", stream: s, verified: true), .failed)
        XCTAssertEqual(machine.outcome(for: "   ", stream: s, verified: true), .failed)
    }

    func testLiteralManifestNeedsNoLivenessProbe() {
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        // verified=false is irrelevant for a manifest: it is playable by construction.
        XCTAssertEqual(machine.outcome(for: fresh, stream: s, verified: false), .persist(fresh))
    }

    func testNonManifestRequiresVerification() {
        // A .php proxy from a rotated server list can answer 200 with nothing:
        // an unverified one must not clobber a url that plays.
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        let proxy = "https://cdn.example.com/proxy.php"
        XCTAssertEqual(machine.outcome(for: proxy, stream: s, verified: false), .rejected(proxy))
        XCTAssertEqual(machine.outcome(for: proxy, stream: s, verified: true), .persist(proxy))
    }

    func testWhitespaceIsTrimmedBeforePersisting() {
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        XCTAssertEqual(machine.outcome(for: "  \(fresh)\n", stream: s, verified: false), .persist(fresh))
        // ...and trimming happens BEFORE the page-identity test, so a padded
        // page url is still recognised as the page.
        XCTAssertEqual(machine.outcome(for: "  \(page) ", stream: s, verified: true), .rejected(page))
    }

    func testRefusedOutcomeNeverTouchesRefreshing() {
        // Judge the result AFTER finish(): a rejection must not leave the
        // re-entrancy guard stuck (macOS clears it before judging).
        let machine = RefetchMachine()
        let s = stream(url: good, pageUrl: page)
        XCTAssertEqual(machine.begin(stream: s, manual: true), .start)
        machine.finish()
        _ = machine.outcome(for: page, stream: s, verified: true)
        XCTAssertFalse(machine.isRefreshing)
        XCTAssertEqual(machine.begin(stream: s, manual: true), .start)
    }
}
