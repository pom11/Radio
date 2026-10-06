import XCTest

/// The manual refetch affordance, driven in the real app.
///
/// The unit suites (RefetchTests / RefetchPlayerTests) own the rules; these
/// prove the two things only the UI can show:
/// - a stream with a source page gets a Refresh button in the bar, and using
///   it does not break the stream that is playing;
/// - a stream WITHOUT one does not grow a button that could only refuse —
///   and when playback dies for good, the bar STAYS (honest "Failed" line,
///   Play/Stop, per the recovery budget) instead of vanishing with the user's
///   only lever inside it.
///
/// Selectors reuse what VideoSurfaceUITests read out of the real AX tree:
/// List reports as a CollectionView, rows need scrolling before they are
/// hittable, and the store persists across launches (so streams are found by
/// their unique generated name, never by position).
final class RefetchUITests: XCTestCase {
    private let app = XCUIApplication()

    /// Apple's public bipbop HLS sample — a real, stable manifest.
    private let sampleURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"

    /// A URL that cannot possibly answer: nothing listens on 127.0.0.1:1, so
    /// AVPlayerItem fails FAST and deterministically — this is how the test
    /// reaches the budget-exhausted "Failed" state with no flaky dependency.
    private let deadURL = "http://127.0.0.1:1/dead.m3u8"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if app.state != .notRunning { app.terminate() }
    }

    // MARK: - The affordance exists where it can work

    func testChannelStreamBarOffersRefreshAndUsingItKeepsPlaying() throws {
        try requireNetwork()
        // A channel whose url IS a literal manifest: ChannelResolver accepts
        // it directly (no scrape), so it plays, and its source page exists —
        // exactly the state where Refresh is both offered and useful.
        let name = try addStream(type: "Channel")
        play(name: name)

        XCTAssertTrue(app.otherElements["playerBar"].waitForExistence(timeout: 30),
                      "channel stream never showed its player bar")
        // Queried by its AX LABEL, which the second run proved is exposed
        // (the tap landed). The identifier `refreshStreamButton` is NOT
        // exposed for this button: unlike `addStreamButton` (a toolbar item,
        // where SwiftUI does surface identifiers), a plain bar button whose
        // label switches between Image and ProgressView surfaces only the
        // accessibilityLabel — same as the Pause/Stop buttons this harness
        // already taps by label. The identifier stays in the view for
        // future hooks; the test does not depend on it.
        let refresh = app.buttons["Refresh"]
        if !refresh.waitForExistence(timeout: 10) {
            let bar = app.otherElements["playerBar"]
            XCTFail("no Refresh affordance in the bar for a stream that has a "
                  + "source page. Bar AX subtree:\n"
                  + (bar.exists ? bar.debugDescription : "<bar gone>"))
        }
        refresh.tap()
        // A manual refresh re-plays the (re-resolved) stream. The strongest
        // non-network assertion: the bar and its controls are still there —
        // the tap must not stop, blank, or crash the running stream.
        XCTAssertTrue(app.otherElements["playerBar"].waitForExistence(timeout: 30),
                      "the bar vanished after a manual refresh")
        // After the refresh completes the label is "Refresh" again (a failed
        // re-resolve ends in "Refresh failed" WITHOUT the bar disappearing —
        // either way the affordance must still be there for another try).
        let again = app.buttons["Refresh"]
        XCTAssertTrue(again.waitForExistence(timeout: 20) || app.buttons["Refreshing"].exists,
                      "Refresh disappeared after use")
    }

    // MARK: - The affordance survives (and is honest about) a dead stream
    //
    // (The "no Refresh without a source page" half of the canRefresh rule is
    // asserted in testFailedStreamBarStaysWithoutRefresh, which is the one
    // test here that reliably gets a bar up without needing the network.)

    func testFailedStreamBarStaysWithoutRefresh() {
        // Offline and deterministic: connection-refused fails AVPlayerItem
        // immediately, so the auto budget (3 retries of the same URL — no
        // pageUrl means no refetch) burns through and giveUpOnPlayback lands.
        let name = try! addStream(type: "Audio", url: deadURL)
        app.launch()
        play(name: name)

        // The failed bar must STAY up (isFailed keeps the dock showing it) —
        // the old app hid everything on failure, taking Refresh with it.
        let bar = app.otherElements["playerBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 60),
                      "the bar disappeared on a dead stream — the user is left with no lever")
        // Generous wait: the bar first shows "Reconnecting..." while the auto
        // budget burns (3 real play→fail cycles against a refused socket, each
        // up to a few seconds of AVAsset loading); "Failed" is the END state.
        let failedLine = bar.staticTexts["Failed"]
        XCTAssertTrue(failedLine.waitForExistence(timeout: 60),
                      "the failed bar never said Failed. Bar subtree:\n"
                    + (bar.exists ? bar.debugDescription : "<bar gone>"))
        // Transport present in this mode: Play = retry with a fresh budget,
        // Stop = clear it. (Stop is also how the test cleans up.)
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10),
                      "failed bar lacks Stop — the user could not dismiss it")
        // And NO Refresh: an audio stream with no source page has nothing to
        // refetch from. If the button appeared here it would be a dead end.
        // Queried by LABEL (the identifier is not exposed on bar buttons —
        // see testChannelStreamBarOffersRefreshAndUsingItKeepsPlaying); an
        // id-based negative here would pass vacuously and prove nothing.
        XCTAssertFalse(app.buttons["Refresh"].exists,
                       "Refresh offered for a stream with no source page")
        XCTAssertFalse(app.buttons["Refreshing"].exists,
                       "a Refresh spinner for a stream that cannot refresh")

        app.buttons["Stop"].tap()
        XCTAssertFalse(app.otherElements["playerBar"].waitForExistence(timeout: 5),
                       "stop left the failed bar on screen")
    }

    // MARK: - Helpers (same shape as VideoSurfaceUITests, plus a url argument)

    private func addStream(type: String, url: String? = nil) throws -> String {
        app.launch()

        let add = app.buttons["addStreamButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "add button never appeared")
        add.tap()

        let nameField = app.textFields["addStreamNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "add sheet never appeared")
        let name = "RefetchUITest \(type) \(UUID().uuidString.prefix(6))"
        nameField.tap()
        nameField.typeText(name)

        let urlField = app.textFields["addStreamURLField"]
        urlField.tap()
        urlField.typeText(url ?? sampleURL)

        app.buttons[type].tap()          // segmented picker: Audio / Video / Channel
        app.buttons["Save"].tap()

        XCTAssertFalse(app.textFields["addStreamURLField"].waitForExistence(timeout: 5),
                       "sheet never dismissed")
        return name
    }

    /// Scroll until the row is hittable, then tap (the list only renders
    /// visible cells and the store persists across launches).
    private func play(name: String) {
        let collection = app.collectionViews.firstMatch
        let row = collection.cells.staticTexts[name]
        for _ in 0..<20 {
            if row.isHittable {
                row.tap()
                return
            }
            collection.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "stream row \(name) never scrolled into view")
    }

    private func requireNetwork() throws {
        var request = URLRequest(url: URL(string: sampleURL)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let done = XCTestExpectation(description: "reachability probe")
        var reachable = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        if !reachable {
            throw XCTSkip("sample stream host unreachable — cannot exercise playback")
        }
    }
}
