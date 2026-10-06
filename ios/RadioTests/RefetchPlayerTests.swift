import XCTest
@testable import Radio

/// The async plumbing around `RefetchMachine`, driven WITHOUT the network.
///
/// `RefetchTests` covers the pure rules; this covers the parts that only exist
/// once the machine is wired into `StreamPlayer`:
/// - the resolve path really receives a PROBE whose url is the source page
///   (a refetch that re-reads the stale url would "succeed" without fetching);
/// - the fresh URL reaches `onRefreshStream` (→ persistence) and the taint
///   path never does — the last known-good url survives;
/// - the liveness probe is consulted exactly when the candidate is not a
///   literal manifest;
/// - the re-entrancy guard and the auto budget behave across real task
///   lifecycles, not just machine calls.
///
/// Both async hooks (`resolve`, `verifyURL`) are injectable vars on
/// StreamPlayer precisely so these paths are testable; `currentStream` is set
/// directly instead of playing a real stream, so no AVPlayer and no KVO
/// failure sink are in the room while the assertions run.
final class RefetchPlayerTests: XCTestCase {

    private let page = "https://example.com/live"
    private let old = "https://cdn.example.com/a/stream.m3u8"
    private let fresh = "https://cdn.example.com/b/stream.m3u8"
    private let proxy = "https://cdn.example.com/proxy.php"

    private func stream(pageUrl: String? = nil) -> Radio.Stream {
        // `Radio.` required: bare `Stream` in type position is ambiguous with
        // Foundation.Stream in this module.
        Radio.Stream(name: "Refetch S", url: old, type: .audio, pageUrl: pageUrl ?? page)
    }

    /// Pump the main run loop until `condition` (the MainActor refresh task is
    /// resumed through the main queue, which the run loop drains). With stubbed
    /// hooks this resolves in microseconds; the timeout only fires if a step
    /// never completes — which is itself the bug.
    @discardableResult
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - The fresh URL reaching (or NOT reaching) persistence

    func testManualRefreshPersistsFreshURLThroughCallback() {
        let player = StreamPlayer()
        var received: Radio.Stream?
        var probeSeen: Radio.Stream?
        var resolveCount = 0
        player.onRefreshStream = { received = $0 }
        player.resolve = { s in
            resolveCount += 1
            if resolveCount == 1 {
                probeSeen = s
                return self.fresh
            }
            // The success replay re-resolves through play(); end it cleanly so
            // no real AVPlayer is built against a stub URL.
            return nil
        }
        player.verifyURL = { _ in
            XCTFail("a literal manifest must not need the liveness probe")
            return false
        }

        let s = stream()
        player.currentStream = s
        XCTAssertTrue(player.refreshFromSource(s, manual: true))
        XCTAssertTrue(player.isRefreshing, "the bar's spinner has nothing to bind to")

        XCTAssertTrue(waitUntil { received != nil }, "onRefreshStream never fired")
        XCTAssertEqual(received?.url, fresh, "the refreshed url must be the fresh one")
        XCTAssertEqual(received?.id, s.id, "refresh must not fork the stream identity")
        XCTAssertEqual(received?.pageUrl, page, "the source page survives the refresh")
        XCTAssertEqual(probeSeen?.url, page,
                       "the resolve path got the stale url, not the source page — a refetch that never fetches")
        XCTAssertTrue(waitUntil { !player.isRefreshing }, "the guard stayed stuck after success")
        player.stop()
    }

    func testTaintedResultNeverReachesPersistenceAndKeepsStatusHonest() {
        let player = StreamPlayer()
        var persisted = false
        player.onRefreshStream = { _ in persisted = true }
        // The resolver's last resort: hand back the page it scraped. The probe
        // DOES run first (the page is not a literal manifest), but its answer
        // cannot rescue a tainted candidate — the taint rule rejects it.
        player.resolve = { _ in self.page }
        player.verifyURL = { _ in true }

        let s = stream()
        player.currentStream = s
        XCTAssertTrue(player.refreshFromSource(s, manual: true))
        XCTAssertTrue(waitUntil { player.statusText == "Refresh failed" })

        XCTAssertFalse(persisted,
                       "a tainted result reached onRefreshStream — pageUrl would overwrite a working url")
        XCTAssertFalse(player.isRefreshing)
        player.stop()
    }

    func testUnverifiedProxyIsRejectedButVerifiedProxyPersists() {
        // Unverified → refused (a dead .php proxy must not clobber a live url).
        let dead = StreamPlayer()
        var deadPersisted = false
        dead.onRefreshStream = { _ in deadPersisted = true }
        dead.resolve = { _ in self.proxy }
        var probedURL: String?
        dead.verifyURL = { probedURL = $0; return false }
        let s = stream()
        dead.currentStream = s
        XCTAssertTrue(dead.refreshFromSource(s, manual: true))
        XCTAssertTrue(waitUntil { dead.statusText == "Refresh failed" })
        XCTAssertFalse(deadPersisted, "an unverified proxy would replace a working url")
        XCTAssertEqual(probedURL, proxy, "the probe must see the candidate it judges")
        dead.stop()

        // Verified → persists through the same callback.
        let alive = StreamPlayer()
        var received: Radio.Stream?
        alive.onRefreshStream = { received = $0 }
        alive.resolve = { s in
            // First call: the refresh probe. Second: the success replay — stop it.
            self.refetchReplayCount += 1
            return self.refetchReplayCount == 1 ? self.proxy : nil
        }
        alive.verifyURL = { _ in true }
        alive.currentStream = s
        XCTAssertTrue(alive.refreshFromSource(s, manual: true))
        XCTAssertTrue(waitUntil { received != nil }, "a verified proxy must persist")
        XCTAssertEqual(received?.url, proxy)
        alive.stop()
    }
    private var refetchReplayCount = 0

    // MARK: - Guard + budget across real tasks

    func testSecondRefreshWhileOneIsInFlightIsRefused() {
        let player = StreamPlayer()
        // Park the first refresh inside resolve with a checked continuation —
        // no sleeps, no flake: the guard is exercised exactly while in flight.
        final class Gate { var resume: (() -> Void)? }
        let gate = Gate()
        player.resolve = { _ in
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                gate.resume = { c.resume(returning: nil) }
            }
        }
        let s = stream()
        player.currentStream = s

        // Start the refresh, then pump until the parked task is ACTUALLY
        // suspended in resolve (its gate is armed) — calling resume before the
        // task body has started would be a no-op and the task never finishes.
        XCTAssertTrue(player.refreshFromSource(s, manual: true))
        XCTAssertTrue(player.isRefreshing)
        XCTAssertTrue(waitUntil { gate.resume != nil }, "the refresh task never reached resolve")
        XCTAssertFalse(player.refreshFromSource(s, manual: false),
                       "a second refresh ran while one was in flight")
        XCTAssertFalse(player.refreshFromSource(s, manual: true),
                       "even a manual tap must not double-fetch")
        XCTAssertEqual(player.statusText, "Re-fetching from source...",
                       "the refusal overwrote the in-flight status")

        gate.resume?()
        XCTAssertTrue(waitUntil { !player.isRefreshing }, "guard stuck after the parked task finished")
        // And the machine is usable again (the guard cleared, budget intact).
        XCTAssertEqual(player.refetch.autoAttempts, 0, "a manual refresh must not charge the budget")
        player.stop()
    }

    func testAutoRefetchIsBoundedAcrossRealAttemptsThenManualStillWorks() {
        let player = StreamPlayer()
        player.resolve = { _ in nil }   // every refetch fails to resolve
        let s = stream()
        player.currentStream = s

        for attempt in 1...3 {
            XCTAssertTrue(player.refreshFromSource(s, manual: false),
                          "auto attempt \(attempt) should be allowed")
            XCTAssertTrue(waitUntil { !player.isRefreshing })
            XCTAssertEqual(player.refetch.autoAttempts, attempt)
        }
        XCTAssertFalse(player.refreshFromSource(s, manual: false),
                       "the auto budget must stop at 3 — a dead stream must not hammer its page")

        // The user still has the lever: manual is unbounded.
        XCTAssertTrue(player.refreshFromSource(s, manual: true))
        XCTAssertTrue(waitUntil { !player.isRefreshing })
        // stop() must cancel the scheduled auto-retry so it cannot leak into a
        // later stream (this line is also the cleanup, deliberately load-bearing).
        player.stop()
        XCTAssertEqual(player.refetch.autoAttempts, 0, "stop() ends the session and its budget")
    }

    func testManualRefreshWithoutPageUrlExplainsItself() {
        let player = StreamPlayer()
        let s = Radio.Stream(name: "No page", url: old, type: .audio, pageUrl: nil)
        player.currentStream = s
        XCTAssertFalse(player.refreshFromSource(s, manual: true))
        XCTAssertEqual(player.statusText, "No source page to refetch from")
        XCTAssertFalse(player.isRefreshing)

        // macOS semantics: an AUTOMATIC attempt on a sourceless stream refuses
        // SILENTLY — the user never asked, so the status line must not change.
        player.statusText = "unchanged"
        XCTAssertFalse(player.refreshFromSource(s, manual: false))
        XCTAssertEqual(player.statusText, "unchanged")
        XCTAssertFalse(player.isRefreshing)
        player.stop()
    }

    func testLateRefreshForASwitchedAwayStreamIsDiscarded() {
        let player = StreamPlayer()
        var received: Radio.Stream?
        player.onRefreshStream = { received = $0 }
        // Resolve parks until released — long enough to switch streams.
        final class Gate { var resume: (() -> Void)? }
        let gate = Gate()
        player.resolve = { _ in
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                gate.resume = { c.resume(returning: self.fresh) }
            }
        }
        let s = stream()
        player.currentStream = s
        XCTAssertTrue(player.refreshFromSource(s, manual: true))
        // Park FIRST (gate armed = the task is genuinely suspended mid-refresh),
        // then switch — otherwise resume?() fires before the continuation
        // exists, the task parks forever, and the test times out (it did).
        XCTAssertTrue(waitUntil { gate.resume != nil }, "the refresh task never reached resolve")

        // The user switches to another stream while the refresh is in flight.
        let other = Radio.Stream(name: "Other", url: "https://other.example.com/x.m3u8", type: .audio, pageUrl: page)
        player.currentStream = other
        gate.resume?()

        XCTAssertTrue(waitUntil { !player.isRefreshing })
        // Give any late continuation a chance to misfire, then assert it did not.
        XCTAssertTrue(waitUntil { player.refetch.isRefreshing == false })
        XCTAssertNil(received,
                     "a finished-late refresh wrote a URL for a stream the user switched away from")
        player.stop()
    }
}
