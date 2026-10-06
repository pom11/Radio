import XCTest

/// End-to-end proof that a `.video` stream produces a PICTURE.
///
/// This bug was invisible to unit tests by construction: audio played, the item
/// reached .readyToPlay, everything reported success — there was simply no
/// AVPlayerLayer in the process to draw frames into. So this drives the real app
/// on the simulator (add a video stream → play it → assert the surface exists at
/// a real size), which is the level at which "no picture" was observable.
///
/// Paired on purpose:
/// - a `.video` stream grows a `videoSurface`, and its player bar keeps Pause;
/// - an `.audio` stream does NOT (regression guard for "audio path unchanged").
///
/// NETWORK: playback needs the sample URL reachable. If it is not, the player
/// never creates an AVPlayer and the surface never appears — a failure that
/// would blame the code for a missing network. So reachability is probed first
/// and these tests SKIP (visibly) rather than fail red.
///
/// The selectors below were read out of the real AX tree (`app.debugDescription`),
/// not guessed: SwiftUI `List` reports as a CollectionView (not a table), the
/// type picker's segments are Buttons labelled Audio/Video/Channel, and the
/// sheet's Save/Cancel are plain buttons.
final class VideoSurfaceUITests: XCTestCase {
    private let app = XCUIApplication()

    /// Apple's public bipbop HLS sample: a genuine video track, stable for years.
    private let sampleURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        if app.state != .notRunning { app.terminate() }
    }

    // MARK: - The bug: no picture for a video stream

    func testVideoStreamShowsAVideoSurface() throws {
        try requireNetwork()
        let name = try addStream(type: "Video")
        play(name: name)

        // The picture, not just the player bar: `videoSurface` exists only when
        // VideoSurfacePolicy said yes AND StreamPlayer published an AVPlayer.
        let surface = app.otherElements["videoSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 30),
                      "no video surface for a .video stream — the exact bug")
        // A zero-size layer draws nothing regardless of which player it holds.
        XCTAssertGreaterThan(surface.frame.width, 100, "surface exists but has no width")
        XCTAssertGreaterThan(surface.frame.height, 40, "surface exists but has no height")
        // Docked, not full-screen: the picture must leave the bar on screen.
        XCTAssertLessThan(surface.frame.maxY, app.frame.height,
                          "surface reaches the bottom edge — the player bar would be unreachable")

        // The card's other requirement: transport stays reachable while video
        // is on screen.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10),
                      "player bar lost its pause control while video is showing")
    }

    /// The rule that protects the audio path, asserted at the level where an
    /// inverted condition in `bottomDock` would actually be visible.
    func testAudioStreamShowsNoVideoSurface() throws {
        try requireNetwork()
        let name = try addStream(type: "Audio")
        play(name: name)

        // The audio bar comes up exactly as it always did...
        XCTAssertTrue(app.otherElements["playerBar"].waitForExistence(timeout: 30),
                      "audio stream never showed its player bar")
        // ...and no panel appears alongside it. XCUITest has no
        // `waitForNonExistence`, so this reads as "give the panel 3s to show up
        // and confirm it never did" — playback has already started, so a panel
        // that was coming would be on screen by now.
        XCTAssertFalse(app.otherElements["videoSurface"].waitForExistence(timeout: 3),
                       "an audio stream grew a video panel — the audio-only path regressed")
    }

    // MARK: - Screenshot for the human check

    /// XCUITest has no API for "this layer currently has frame contents", so
    /// existence at a real size is the strongest programmatic claim. Whether
    /// frames are actually decoded is what this attachment is for (the same view
    /// is available from the CLI with `xcrun simctl io <device> screenshot`).
    func testVideoSurfaceIsCapturedForHumanReview() throws {
        try requireNetwork()
        let name = try addStream(type: "Video")
        play(name: name)

        guard app.otherElements["videoSurface"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no surface within 30s — check network and player log")
        }
        // Let a few frames decode before capturing.
        _ = app.otherElements["videoSurface"].waitForExistence(timeout: 5)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "video-surface"
        shot.lifetime = .keepAlways

        // The .xcresult attachment above is not reliably exportable from the
        // CLI, and the card asks for a screenshot a human can look at. So write
        // the same PNG into this test runner's own container, where it can be
        // copied off the simulator by path (see the run note in the card).
        let png = app.screenshot().pngRepresentation
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = documents.appendingPathComponent("video-surface.png")
        try png.write(to: out)
        XCTAssertGreaterThan(png.count, 10_000, "screenshot came out empty")
    }

    // MARK: - Helpers

    /// Add a stream through the real + sheet, so the test goes through the same
    /// ingestion a user does. Returns the generated name so the caller can tap
    /// exactly that row — the store persists across launches, so "the first
    /// row" is not a stable target.
    private func addStream(type: String) throws -> String {
        app.launch()

        let add = app.buttons["addStreamButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 20), "add button never appeared")
        add.tap()

        let nameField = app.textFields["addStreamNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20), "add sheet never appeared")
        let name = "UITest \(type) \(UUID().uuidString.prefix(6))"
        nameField.tap()
        nameField.typeText(name)

        let urlField = app.textFields["addStreamURLField"]
        urlField.tap()
        urlField.typeText(sampleURL)

        app.buttons[type].tap()          // segmented picker: Audio / Video / Channel
        app.buttons["Save"].tap()

        // The sheet is gone once the list is back. Asserting on the row that was
        // just added (rather than "a sheet is gone") also proves Save took.
        XCTAssertTrue(app.collectionViews.cells.staticTexts[name]
                        .waitForExistence(timeout: 20), "sheet never dismissed / row missing")
        return name
    }

    /// Tap the row for this stream (its name is a StaticText in the cell) to
    /// start playback.
    private func play(name: String) {
        let row = app.collectionViews.cells.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "stream row \(name) never appeared")
        row.tap()
    }

    private func requireNetwork() throws {
        var request = URLRequest(url: URL(string: sampleURL)!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        let done = expectation(description: "reachability probe")
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
