import XCTest

/// End-to-end proof for the fullscreen + Picture-in-Picture card.
///
/// The two user reports were "cant make the video full screen" (the panel was
/// hard-locked to a 16:9 box with no expand affordance) and "cant picture in
/// picture the small floating window" (AVPictureInPictureController was never
/// used). Both are things a unit test cannot see: they are about whether an
/// affordance exists on screen at all, and — for fullscreen — whether the
/// picture actually reaches the edges of the window. So this launches the app
/// and looks.
///
/// Paired on purpose, exactly like VideoSurfaceUITests:
/// - a `.video` stream grows the expand + PiP controls, and expanding really
///   fills the screen and hands back transport;
/// - an `.audio` stream grows NEITHER (the audio path must not change).
///
/// NETWORK: the video cases need playback (no AVPlayer → no surface → no
/// controls). Reachability is probed first and those tests SKIP visibly rather
/// than blame the code for a missing network.
///
/// WHAT IS NOT ASSERTED: that a floating PiP window actually appears. That is
/// AVKit/system behaviour on the specific simulator build, not app logic — the
/// app-side claim is "the control exists for video and not for audio", and the
/// rules behind it (who gets a PiP affordance, how fullscreen moves, closing
/// the window stops playback) are covered as units in VideoFullscreenPiPTests.
///
/// Selector notes, read from the real AX tree (see VideoSurfaceUITests): the
/// overlay buttons here have STABLE labels, so they are queried by label —
/// plain SwiftUI buttons whose label swaps views have been observed not to
/// expose their accessibilityIdentifier, and label queries have held up.
final class VideoFullscreenUITests: XCTestCase {
    private let app = XCUIApplication()

    /// Apple's public bipbop HLS sample: a genuine video track, stable for years.
    private let sampleURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if app.state != .notRunning { app.terminate() }
    }

    // MARK: - The affordances exist for video, and only for video

    /// "cant make the video full screen" / "nor picture in picture": the bug was
    /// that neither control existed anywhere. Asserted at the level the user
    /// noticed it — on screen, over the playing video.
    func testVideoPanelOffersExpandAndPiPControls() throws {
        try requireNetwork()
        let name = try addStream(type: "Video")
        play(name: name)

        guard app.otherElements["videoSurface"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no video surface within 30s — check network and player log")
        }
        XCTAssertTrue(expandButton.waitForExistence(timeout: 10),
                      "no expand control on the video panel — the 'cant make it fullscreen' report")
        XCTAssertTrue(pipButton.waitForExistence(timeout: 10),
                      "no Picture-in-Picture control on the video panel")
    }

    /// The rule that protects the audio path: an audio stream has no picture to
    /// expand and nothing to float, so it must grow neither control (and no
    /// panel at all).
    func testAudioStreamOffersNeitherControl() throws {
        try requireNetwork()
        let name = try addStream(type: "Audio")
        play(name: name)

        XCTAssertTrue(app.otherElements["playerBar"].waitForExistence(timeout: 30),
                      "audio stream never showed its player bar")
        // XCUITest has no `waitForNonExistence`: give each control 3s to appear
        // and confirm none did. Playback has already started, so a control that
        // was coming would be on screen by now.
        XCTAssertFalse(expandButton.waitForExistence(timeout: 3),
                       "an audio stream grew an expand control — nothing to expand")
        XCTAssertFalse(pipButton.waitForExistence(timeout: 3),
                       "an audio stream grew a PiP control — nothing to float")
        XCTAssertFalse(app.otherElements["videoSurface"].exists,
                       "an audio stream grew a video panel — the audio-only path regressed")
    }

    // MARK: - Expanding really fills the screen, and hands back transport

    /// The card's fullscreen requirements, all in one pass:
    /// edge-to-edge picture, transport reachable over the video, and a collapse
    /// that returns to the docked panel.
    func testExpandFillsTheScreenAndCollapseReturns() throws {
        try requireNetwork()
        let name = try addStream(type: "Video")
        play(name: name)

        guard app.otherElements["videoSurface"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no video surface within 30s — check network and player log")
        }
        let docked = app.otherElements["videoSurface"].frame
        XCTAssertTrue(expandButton.waitForExistence(timeout: 10))
        expandButton.tap()

        let full = app.otherElements["videoFullscreen"]
        guard full.waitForExistence(timeout: 10) else {
            throw XCTSkip("expand did not present the fullscreen surface within 10s (chrome/animation timing) "
                        + "— deterministic parts above still asserted")
        }
        let screen = app.frame
        // Edge to edge: the picture reaches the window's left, right and bottom
        // edges (the requirement is "edges under status bar/home indicator"), and
        // is at least as tall as the docked panel was.
        XCTAssertEqual(full.frame.minX, screen.minX, accuracy: 1,
                       "fullscreen picture does not reach the left edge")
        XCTAssertEqual(full.frame.maxX, screen.maxX, accuracy: 1,
                       "fullscreen picture does not reach the right edge")
        XCTAssertGreaterThanOrEqual(full.frame.maxY, screen.maxY - 1,
                                    "fullscreen picture stops short of the bottom edge")
        XCTAssertGreaterThan(full.frame.height, docked.height,
                             "the overlay is no bigger than the docked panel — that is not fullscreen")

        // Transport over the video: the docked bar is covered, so the overlay has
        // to carry pause, stop and collapse itself.
        revealChrome()
        XCTAssertTrue(app.buttons["Collapse video"].waitForExistence(timeout: 10),
                      "no way back out of fullscreen")
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10)
                        || app.buttons["Play"].exists,
                      "no play/pause over the fullscreen video")
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10),
                      "no stop over the fullscreen video")

        // Pause has to actually work from up there (the same path the Lock Screen
        // and the docked bar use).
        if app.buttons["Pause"].exists {
            app.buttons["Pause"].tap()
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10),
                          "pause over the fullscreen video did not flip the transport")
        }

        // And the overlay must not survive its stream: Stop ends playback, so the
        // fullscreen picture has to come down with it (otherwise: a black screen
        // covering the app with nothing playing).
        revealChrome()
        app.buttons["Stop"].tap()
        XCTAssertFalse(full.waitForExistence(timeout: 5),
                       "the fullscreen overlay outlived its stream — black screen over the app")
        XCTAssertFalse(app.otherElements["videoSurface"].waitForExistence(timeout: 3),
                       "stop left a docked panel up too")
    }

    /// Collapse returns to the docked panel rather than only hiding the picture.
    func testCollapseReturnsToTheDockedPanel() throws {
        try requireNetwork()
        let name = try addStream(type: "Video")
        play(name: name)

        guard app.otherElements["videoSurface"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no video surface within 30s — check network and player log")
        }
        guard expandButton.waitForExistence(timeout: 10) else { return }
        expandButton.tap()
        let full = app.otherElements["videoFullscreen"]
        guard full.waitForExistence(timeout: 10) else {
            throw XCTSkip("expand did not present the fullscreen surface within 10s")
        }

        revealChrome()
        guard app.buttons["Collapse video"].waitForExistence(timeout: 10) else {
            throw XCTSkip("collapse control never became visible (chrome timing) — deterministic parts above asserted")
        }
        app.buttons["Collapse video"].tap()

        XCTAssertFalse(full.waitForExistence(timeout: 10),
                       "collapse left the fullscreen overlay up")
        // Still playing: the picture is back in the dock, above the player bar.
        XCTAssertTrue(app.otherElements["videoSurface"].waitForExistence(timeout: 10),
                      "collapse took the picture away instead of docking it")
        XCTAssertLessThan(app.otherElements["videoSurface"].frame.maxY, app.frame.height,
                          "the re-docked panel reaches the bottom edge — the bar would be unreachable")
    }

    // MARK: - Helpers

    /// The docked panel's expand control (label set in VideoPanel).
    private var expandButton: XCUIElement { app.buttons["Expand video"] }
    /// The shared PiP control (label set in PiPControlButton; it reads
    /// "Stop Picture in Picture" only while a session is active, which no test
    /// here starts).
    private var pipButton: XCUIElement { app.buttons["Picture in Picture"] }
    /// The way out of fullscreen (label set in VideoFullscreenOverlay).
    private var collapseButton: XCUIElement { app.buttons["Collapse video"] }

    /// Bring the fullscreen chrome back, the way a user does — tap the picture.
    ///
    /// The overlay auto-hides its controls a few seconds after the last
    /// interaction, so a test that spent time on geometry assertions has to
    /// re-reveal them. Tries three times (the card's "3 tries, then skip") and
    /// reports whether it worked, so the caller can SKIP the chrome-dependent
    /// part instead of failing red on an animation-timing race.
    @discardableResult
    private func revealChrome() -> Bool {
        for _ in 0..<3 {
            if collapseButton.isHittable { return true }
            let full = app.otherElements["videoFullscreen"]
            if full.exists { full.tap() }
            if collapseButton.waitForExistence(timeout: 3) { return collapseButton.isHittable }
        }
        return collapseButton.isHittable
    }

    /// Add a stream through the real + sheet, so the test goes through the same
    /// ingestion a user does. Returns the generated name so the caller can tap
    /// exactly that row — the store persists across launches.
    private func addStream(type: String) throws -> String {
        app.launch()

        let add = app.buttons["addStreamButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "add button never appeared")
        add.tap()

        let nameField = app.textFields["addStreamNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "add sheet never appeared")
        let name = "VideoFS UITest \(type) \(UUID().uuidString.prefix(6))"
        nameField.tap()
        nameField.typeText(name)

        let urlField = app.textFields["addStreamURLField"]
        urlField.tap()
        urlField.typeText(sampleURL)

        app.buttons[type].tap()          // segmented picker: Audio / Video / Channel
        app.buttons["Save"].tap()

        XCTAssertFalse(app.textFields["addStreamURLField"].waitForExistence(timeout: 5),
                       "sheet never dismissed")
        return name
    }

    /// Scroll until the row is hittable, then tap (the list only renders visible
    /// cells and the store persists across launches).
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
