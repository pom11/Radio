import XCTest
@testable import Radio

/// The second half of the report this card answers: "please make sure when
/// importing the stream will also fetch the original url so we can refetch the
/// stream later".
///
/// `pageUrl` decides whether Refresh can ever exist for a stream (see
/// `RefetchMachine.sourcePage`), and the manual add sheet could not set it at
/// all: a stream added by hand was refresh-less for life. These tests pin the
/// two layers of the fix — the *rule* for what to record, and that the value
/// the sheet computes actually lands in `streams.json`.
final class SourcePageCaptureTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-pageurl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> StreamStore {
        StreamStore(fileURL: tempDir.appendingPathComponent("streams-\(UUID().uuidString).json"))
    }

    // MARK: - The rule: when is a pasted url also a source page?

    func testChannelWithoutPageUrlRecordsItsURLAsThePage() {
        // The user's Realitatea case: a YouTube channel page added by hand.
        let page = "https://www.youtube.com/@TuDecizi-s3g"
        XCTAssertEqual(RefetchMachine.recordedPageUrl(url: page, type: .channel), page)
    }

    func testPlayableURLsNeverRecordThemselvesAsThePage() {
        // Guessing a page from a playable url would record a lie, and a pageUrl
        // equal to the url makes the stream read as tainted (the taint guard
        // refuses url == pageUrl). `.audio`/`.video` get nothing recorded.
        XCTAssertNil(RefetchMachine.recordedPageUrl(url: "https://cdn/x/stream.mp3", type: .audio))
        XCTAssertNil(RefetchMachine.recordedPageUrl(url: "https://cdn/x/live.m3u8", type: .video))
    }

    /// The load-bearing exception: a channel whose url IS a literal manifest
    /// must NOT record it as its page. `ChannelResolver` hands that same url
    /// back as the resolved stream, and `StreamPlayer.play` re-checks the
    /// taint guard on the RESOLVED value against `pageUrl` — pageUrl == url
    /// would refuse it and a channel that played would start saying "Failed".
    func testManifestShapedChannelURLIsNotRecordedAsItsOwnPage() {
        let manifest = "https://cdn.example.com/live/stream.m3u8"
        XCTAssertNil(RefetchMachine.recordedPageUrl(url: manifest, type: .channel))

        // And the recorded decision keeps the stream playable end-to-end: the
        // resolver's answer (the direct manifest) is not tainted against a nil
        // pageUrl, whereas it WOULD be against the url-as-page.
        let stream = Radio.Stream(name: "M", url: manifest, type: .channel,
                                  pageUrl: RefetchMachine.recordedPageUrl(url: manifest, type: .channel))
        XCTAssertFalse(StreamStore.refuseTainted(manifest, pageUrl: stream.pageUrl),
                       "a manifest-shaped channel url recorded as its own page would break playback")
    }

    func testRecordedPageUrlMakesTheStreamRefreshable() {
        let page = "https://www.youtube.com/@TuDecizi-s3g"
        let recorded = RefetchMachine.recordedPageUrl(url: page, type: .channel)
        let stream = Radio.Stream(name: "Realitatea", url: page, type: .channel, pageUrl: recorded)
        XCTAssertEqual(stream.pageUrl, page, "the page must be stored, not just inferable")
        XCTAssertTrue(RefetchMachine.canRefresh(stream))
        XCTAssertEqual(RefetchMachine.sourcePage(of: stream), page)
    }

    // MARK: - The sheet's decision (the field + its defaulting)

    /// An explicitly entered page wins over any defaulting, and is trimmed.
    func testEnteredSourcePageIsStoredTrimmed() {
        XCTAssertEqual(AddStreamSheet.resolvedPageUrl(entered: "  https://example.com/live  ",
                                                     streamURL: "https://cdn/x/a.mp3",
                                                     type: .audio),
                       "https://example.com/live")
    }

    /// Whitespace-only entry is "empty": nil, never an empty string (an empty
    /// pageUrl is worse than none — it reads as set and `sourcePage` would
    /// return it, so every refresh would scrape nothing).
    func testWhitespaceOnlySourcePageStoresNothing() {
        XCTAssertNil(AddStreamSheet.resolvedPageUrl(entered: "   \n ",
                                                   streamURL: "https://cdn/x/a.mp3",
                                                   type: .audio))
    }

    func testEmptyFieldDefaultsToTheURLOnlyForPageShapedChannels() {
        XCTAssertEqual(AddStreamSheet.resolvedPageUrl(entered: "",
                                                     streamURL: "https://www.youtube.com/@ch",
                                                     type: .channel),
                       "https://www.youtube.com/@ch")
        XCTAssertNil(AddStreamSheet.resolvedPageUrl(entered: "",
                                                   streamURL: "https://cdn/x/a.mp3",
                                                   type: .audio))
        XCTAssertNil(AddStreamSheet.resolvedPageUrl(entered: "",
                                                   streamURL: "https://cdn/x/live.m3u8",
                                                   type: .video))
    }

    // MARK: - It reaches the saved file

    func testAddPersistsPageUrlThroughSaveReload() throws {
        let fileURL = tempDir.appendingPathComponent("round-trip.json")
        let store = StreamStore(fileURL: fileURL)
        let page = "https://www.youtube.com/@TuDecizi-s3g"

        store.add(name: "Realitatea", url: page, type: .channel,
                  pageUrl: RefetchMachine.recordedPageUrl(url: page, type: .channel))

        // save() is synchronous by design — no sleep, the file is written here.
        let reloaded = StreamStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.streams.count, 1)
        XCTAssertEqual(reloaded.streams[0].pageUrl, page,
                       "the source page did not survive the save — a later launch could not refetch")
        XCTAssertTrue(RefetchMachine.canRefresh(reloaded.streams[0]))
    }

    func testAddWithoutPageUrlStillMeansNoPageUrl() {
        let store = makeStore()
        store.add(name: "Plain", url: "https://cdn/x/a.mp3", type: .audio)
        XCTAssertNil(store.streams[0].pageUrl,
                     "an audio stream must not grow a fabricated source page")
        XCTAssertFalse(RefetchMachine.canRefresh(store.streams[0]))
    }
}
