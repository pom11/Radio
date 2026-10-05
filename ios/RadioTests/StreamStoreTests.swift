import XCTest
@testable import Radio

final class StreamStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// DEFINITION OF DONE: StreamStore persists/round-trips a stream
    /// (save → reload → equal).
    func testSaveReloadRoundTrip() throws {
        let fileURL = tempDir.appendingPathComponent("streams.json")

        let store = StreamStore(fileURL: fileURL)
        let stream = Stream(
            name: "Test FM",
            url: "https://example.com/stream.mp3",
            type: .audio,
            pageUrl: "https://example.com/",
            referer: "https://example.com/",
            headers: ["User-Agent": "Radio-iOS"]
        )
        store.streams.append(stream)
        store.save()

        // Give the detached save task a moment to write.
        let expectation = expectation(description: "save flushes")
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        // Reload into a fresh store bound to the same file.
        let reloaded = StreamStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.streams.count, 1)
        XCTAssertEqual(reloaded.streams[0], stream)
    }

    func testDetectType() {
        XCTAssertEqual(URLResolver.detectType("https://example.com/stream.mp3"), .audio)
        XCTAssertEqual(URLResolver.detectType("https://example.com/hls/live.m3u8"), .video)
        XCTAssertEqual(URLResolver.detectType("https://www.youtube.com/@channel"), .channel)
        XCTAssertEqual(URLResolver.detectType("https://www.youtube.com/watch?v=abc"), .video)
        XCTAssertEqual(URLResolver.detectType("http://icecast.local:8000/live"), .audio)
    }

    func testRefuseTainted() {
        // A pageUrl must never be accepted as a playable url, and neither may a
        // non-http(s) value.
        XCTAssertTrue(StreamStore.refuseTainted("https://example.com/", pageUrl: "https://example.com/"))
        XCTAssertTrue(StreamStore.refuseTainted("not a url", pageUrl: nil))
        XCTAssertFalse(StreamStore.refuseTainted("https://example.com/stream.mp3", pageUrl: "https://example.com/"))
        XCTAssertFalse(StreamStore.refuseTainted("https://example.com/stream.mp3", pageUrl: nil))
    }

    // MARK: - QR import (t_795847ff)
    //
    // These cover the DoD "string→stream→store" path: a decoded
    // AVCaptureMetadataObject.stringValue (the radio://add deep link produced by
    // the macOS QR export) is ingested through DeepLinkHandler.handle(string:),
    // the exact call the camera scanner makes.

    private func makeStore() -> StreamStore {
        StreamStore(fileURL: tempDir.appendingPathComponent("qr-streams-\\(UUID().uuidString).json"))
    }

    /// A freshly scanned QR adds the stream to the store (append semantics).
    func testQRIngestAppendsStream() {
        let store = makeStore()
        let handler = DeepLinkHandler(store: store)

        // This is byte-for-byte the deep-link form encoded into the macOS QR.
        let qr = "radio://add?url=https%3A%2F%2Fexample.com%2Fstream.mp3&name=Example%20FM&type=audio&pageUrl=https%3A%2F%2Fexample.com%2F&referer=https%3A%2F%2Fexample.com%2F"

        XCTAssertEqual(handler.handle(string: qr), .added)
        XCTAssertEqual(store.streams.count, 1)
        XCTAssertEqual(store.streams[0].name, "Example FM")
        XCTAssertEqual(store.streams[0].url, "https://example.com/stream.mp3")
        XCTAssertEqual(store.streams[0].type, .audio)
        XCTAssertEqual(store.streams[0].pageUrl, "https://example.com/")
    }

    /// Re-scanning the same stream's QR updates it instead of duplicating
    /// (the "update" semantics reused from the deep-link path).
    func testQRIngestUpdatesExistingPageUrl() {
        let store = makeStore()
        let handler = DeepLinkHandler(store: store)
        let qr = "radio://add?url=https%3A%2F%2Fexample.com%2Fstream.mp3&name=Example%20FM&type=audio&pageUrl=https%3A%2F%2Fexample.com%2F"

        XCTAssertEqual(handler.handle(string: qr), .added)
        XCTAssertEqual(store.streams.count, 1)

        // Same pageUrl but a changed playable url + name → updates in place.
        let qr2 = "radio://add?url=https%3A%2F%2Fexample.com%2Fnew.mp3&name=Renamed&type=audio&pageUrl=https%3A%2F%2Fexample.com%2F"
        XCTAssertEqual(handler.handle(string: qr2), .updated)
        XCTAssertEqual(store.streams.count, 1, "re-scan must not duplicate")
        XCTAssertEqual(store.streams[0].name, "Renamed")
        XCTAssertEqual(store.streams[0].url, "https://example.com/new.mp3")
    }

    /// A non-radio:// QR (or garbage) is rejected and mutates nothing.
    func testQRIngestRejectsNonRadio() {
        let store = makeStore()
        let handler = DeepLinkHandler(store: store)

        XCTAssertEqual(handler.handle(string: "https://example.com/notradio"), .ignored)
        XCTAssertEqual(handler.handle(string: "complete garbage"), .ignored)
        XCTAssertEqual(store.streams.count, 0)
    }
}
