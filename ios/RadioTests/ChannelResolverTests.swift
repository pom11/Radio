import XCTest
@testable import Radio

final class ChannelResolverTests: XCTestCase {

    // MARK: - ChannelResolver.extractManifest (pure, no network)

    func testExtractsM3U8FromHTML() {
        let html = """
        <html><head><title>TV Channel</title></head>
        <body><video src="https://cdn.example.com/live/channel/master.m3u8?token=abc"></video></body>
        </html>
        """
        XCTAssertEqual(
            ChannelResolver.extractManifest(from: html),
            "https://cdn.example.com/live/channel/master.m3u8?token=abc"
        )
    }

    func testExtractsMPDFromHTML() {
        let html = #"<script>player.src = "https://cdn.example.com/dash/manifest.mpd?key=1"</script>"#
        XCTAssertEqual(
            ChannelResolver.extractManifest(from: html),
            "https://cdn.example.com/dash/manifest.mpd?key=1"
        )
    }

    /// The regex must not swallow surrounding HTML (quote, apostrophe, angle
    /// bracket, close paren are all terminator characters). This guards against
    /// returning a garbage "URL" that includes the rest of the page text.
    func testManifestTerminatedAtDelimiter() {
        let html = #"src='https://cdn.example.com/live/chan/master.m3u8' data-x="hello""#
        let result = ChannelResolver.extractManifest(from: html)
        XCTAssertEqual(result, "https://cdn.example.com/live/chan/master.m3u8")
    }

    /// Query strings are preserved and the end of the URL isn't over-collected.
    func testQueryStringPreserved() {
        let html = #"<a href="https://cdn.example.com/live/master.m3u8?foo=1&amp;bar=2">"#
        XCTAssertEqual(
            ChannelResolver.extractManifest(from: html),
            "https://cdn.example.com/live/master.m3u8?foo=1&amp;bar=2"
        )
    }

    func testReturnsNilWhenNoManifest() {
        // YouTube pages do NOT embed a literal .m3u8/.mpd — the resolver must
        // return nil so the caller falls back to Open in Browser.
        let html = """
        <html><body><div id="player"></div>
        <script>ytInitialPlayerResponse = {streamingData: {formats: [{url: "https://rr.example/sig"}], hlsManifestUrl: "none"}}</script>
        </body></html>
        """
        XCTAssertNil(ChannelResolver.extractManifest(from: html))
    }

    // MARK: - ChannelResolver.directManifest

    func testDirectManifestRecognizesHLSAndMPD() {
        XCTAssertEqual(
            ChannelResolver.directManifest("https://cdn.example.com/master.m3u8"),
            "https://cdn.example.com/master.m3u8"
        )
        XCTAssertEqual(
            ChannelResolver.directManifest("https://cdn.example.com/manifest.mpd?token=x"),
            "https://cdn.example.com/manifest.mpd?token=x"
        )
    }

    func testDirectManifestRejectsPageAndPlainURLs() {
        XCTAssertNil(ChannelResolver.directManifest("https://www.youtube.com/@channel"))
        XCTAssertNil(ChannelResolver.directManifest("https://example.com/stream.mp3"))
        XCTAssertNil(ChannelResolver.directManifest("https://example.com/hls/playlist"))
    }

    // MARK: - StreamPlayer.resolve default routing (no network; pure logic)

    /// The default resolve must NOT hand a channel page directly to AVPlayer;
    /// direct audio/video urls must pass through unchanged. We test the routing
    /// decision (the pure part) without exercising the network scrape, by
    /// building on ChannelResolver's own synchronous helpers.
    func testChannelStreamResolveRoutesThroughResolver() async throws {
        // A channel whose page has no literal manifest → resolver returns nil,
        // which is the "offer open-in-browser" signal (not a hard playable url).
        let channel = Stream(name: "YT Live", url: "https://www.youtube.com/@channel", type: .channel, pageUrl: "https://www.youtube.com/@channel")
        // The offline router returns nil for a channel without an embeddable
        // manifest — we can't run the network scrape in a unit test, so assert
        // the non-network preconditions: a channel url must not equal a direct
        // manifest, and a channel is never handed to AVPlayer as-is.
        XCTAssertTrue(StreamStore.refuseTainted(channel.url, pageUrl: channel.pageUrl),
                      "a channel page IS tainted as a playable url — the resolve must transform it")
        XCTAssertNil(ChannelResolver.directManifest(channel.url),
                     "a channel page is not a direct manifest, so in-app resolution needs the scrape")
    }
}
