import XCTest
@testable import Radio

/// The contract for the ONE literal-manifest predicate
/// (`ChannelResolver.isLiteralManifest`), plus the proof that the call sites
/// which used to keep their own copy of the check now agree with it.
///
/// Why this file exists: the app answered "is this URL a literal manifest" two
/// ways — `ChannelResolver.directManifest` used `contains(".m3u8")` /
/// `contains(".mpd")` on the pre-query path, `RefetchMachine.isLiteralManifest`
/// used a per-segment extension check. Whenever the two disagreed, one call
/// site accepted a URL another refused to refetch — the tvron `.php`-proxy bug
/// class (macOS t_2a758903) and the iOS "never persist pageUrl as url" taint
/// guard. The first four tests are the card's required set; the agreement
/// tests after them are what stops a second predicate from growing back.
final class LiteralManifestTests: XCTestCase {

    /// A real HLS manifest, spelled so no audio hint (`/stream`, `radio`, …)
    /// interferes with the detectType assertions below.
    private let m3u8 = "https://cdn.example.com/dash/master.m3u8"
    private let mpd = "https://cdn.example.com/dash/manifest.mpd"
    /// The tvron shape: a server-side proxy. `.m3u8` appears in the URL, the
    /// resource is not a manifest.
    private let php = "https://tvron.example.net/x/proxy.php?u=abc"
    /// A pageUrl that ENDS in `.m3u8` but is really a page/proxy — the taint
    /// case the card singles out.
    private let pageEndingInM3u8 = "https://example.com/embed/live.m3u8"
    private let page = "https://example.com/live"
    private let working = "https://cdn.example.com/a/stream.mp3"

    // MARK: - The predicate itself (the card's four required cases)

    func testLiteralM3u8IsLiteral() {
        XCTAssertTrue(ChannelResolver.isLiteralManifest(m3u8))
        // Case-insensitive, and a token must not hide the extension.
        XCTAssertTrue(ChannelResolver.isLiteralManifest("https://cdn.example.com/LIVE/STREAM.M3U8?token=1"))
    }

    func testLiteralMpdIsLiteral() {
        XCTAssertTrue(ChannelResolver.isLiteralManifest(mpd))
        XCTAssertTrue(ChannelResolver.isLiteralManifest("https://cdn.example.com/manifest.mpd?token=x"))
    }

    func testPHPProxyIsNeverLiteral() {
        XCTAssertFalse(ChannelResolver.isLiteralManifest(php),
                       "a .php proxy treated as a literal manifest skips the liveness probe and goes straight to AVPlayer")
        // The substring trap: `.m3u8` in the path, but no segment ENDS in it.
        XCTAssertFalse(ChannelResolver.isLiteralManifest("https://x/y.m3u8isnotadir/proxy.php"))
        // `.m3u8` buried in the QUERY must not forge a manifest either — the
        // query is dropped before the check, which `contains` could not do.
        XCTAssertFalse(ChannelResolver.isLiteralManifest("https://x/play.php?f=stream.m3u8"))
    }

    func testPageShapedURLsAreNotLiteral() {
        for notManifest in ["https://www.youtube.com/@channel",
                            page,
                            "https://example.com/stream.mp3",
                            "https://example.com/hls/playlist",
                            ""] {
            XCTAssertFalse(ChannelResolver.isLiteralManifest(notManifest), "\(notManifest) is not a manifest")
        }
    }

    // MARK: - The taint guard must WIN over the predicate (card case 4)

    /// A recorded `pageUrl` is a page BY DEFINITION — sites do serve an HTML
    /// page (or a proxy) at a manifest-shaped URL. So identity with an explicit
    /// pageUrl is tainted even though the predicate says "this ends in .m3u8".
    func testPageUrlEndingInM3u8IsStillTainted() {
        let machine = RefetchMachine()
        let s = Radio.Stream(name: "S", url: working, type: .audio, pageUrl: pageEndingInM3u8)
        XCTAssertTrue(ChannelResolver.isLiteralManifest(pageEndingInM3u8),
                      "the predicate alone would call this a manifest — that is exactly the trap")
        XCTAssertEqual(machine.outcome(for: pageEndingInM3u8, stream: s, verified: true),
                       .rejected(pageEndingInM3u8),
                       "the taint guard lost to the predicate: an HTML page would be saved as the playable url")
    }

    /// Same trap on the channel shape, where a `pageUrl` was recorded
    /// deliberately — identity with it stays tainted.
    func testChannelWithExplicitM3u8ShapedPageUrlStaysTainted() {
        let machine = RefetchMachine()
        let s = Radio.Stream(name: "S", url: working, type: .channel, pageUrl: pageEndingInM3u8)
        XCTAssertEqual(machine.outcome(for: pageEndingInM3u8, stream: s, verified: true),
                       .rejected(pageEndingInM3u8))
    }

    /// The narrow exception the other direction: a channel added AS a manifest
    /// (no pageUrl recorded, so the page is *inferred* from its own url) has a
    /// url that genuinely is the stream. Refusing identity there would make
    /// Refresh on such a channel always say "Refresh failed" while it plays
    /// fine — and the exception is decided by the SAME predicate.
    func testChannelInferredFromItsOwnManifestUrlMayPersistIdentity() {
        let machine = RefetchMachine()
        let s = Radio.Stream(name: "S", url: m3u8, type: .channel, pageUrl: nil)
        XCTAssertEqual(RefetchMachine.sourcePage(of: s), m3u8, "the page is inferred from the url")
        XCTAssertNil(RefetchMachine.explicitSourcePage(of: s))
        XCTAssertEqual(machine.outcome(for: m3u8, stream: s, verified: false), .persist(m3u8))
    }

    func testExplicitSourcePageDistinguishesRecordedFromInferred() {
        let recorded = Radio.Stream(name: "S", url: working, type: .audio, pageUrl: page)
        XCTAssertEqual(RefetchMachine.explicitSourcePage(of: recorded), page)
        let inferred = Radio.Stream(name: "S", url: page, type: .channel, pageUrl: nil)
        XCTAssertNil(RefetchMachine.explicitSourcePage(of: inferred),
                     "a page inferred from a channel url carries no promise that it is a page")
        let blank = Radio.Stream(name: "S", url: page, type: .channel, pageUrl: "   ")
        XCTAssertNil(RefetchMachine.explicitSourcePage(of: blank))
    }

    // MARK: - Call-site agreement (what prevents the split from coming back)

    /// `directManifest` is now the predicate's Optional wrapper, not its own
    /// string search — so the resolve shortcut can never disagree with the
    /// judgement path.
    func testDirectManifestIsThePredicateNotASecondCheck() {
        for url in [m3u8, mpd, php, pageEndingInM3u8, "https://x/y.m3u8isnotadir/proxy.php", page] {
            XCTAssertEqual(ChannelResolver.directManifest(url) != nil,
                           ChannelResolver.isLiteralManifest(url),
                           "directManifest disagrees with the predicate for \(url)")
        }
        XCTAssertEqual(ChannelResolver.directManifest(m3u8), m3u8)
        XCTAssertNil(ChannelResolver.directManifest(php))
    }

    /// Import type-guessing asks the same predicate (no `.m3u8`/`.mpd` entry in
    /// `videoPatterns` any more), so a `.php` proxy cannot be typed as a video
    /// by import while the play path refuses it.
    func testDetectTypeAgreesWithThePredicate() {
        XCTAssertEqual(URLResolver.detectType(m3u8), .video)
        XCTAssertEqual(URLResolver.detectType(mpd), .video)
        let proxyType = URLResolver.detectType(php)
        XCTAssertNotEqual(proxyType, .video,
                          "import typed a non-manifest proxy as video — the play path would refuse it")
    }

    /// The page-scraper hands back only URLs the predicate accepts. Before the
    /// unification it returned the FIRST regex hit unjudged, so a proxy whose
    /// query contained `.m3u8` was handed to AVPlayer as a playlist.
    func testScrapeReturnsOnlyPredicateApprovedManifests() {
        let proxy = "https://tvron.example.net/p/play.php?f=playlist.m3u8"
        let html = "<html><body><video src=\"\(proxy)\"></video>"
            + "<a href=\"\(m3u8)\">watch</a></body></html>"
        XCTAssertEqual(ChannelResolver.extractManifest(from: html), m3u8,
                       "the proxy matched the .m3u8 regex first and was returned unjudged")
        // A page whose ONLY manifest-shaped URL is a proxy yields nil — the
        // caller then offers open-in-browser / refetch rather than a dead play.
        XCTAssertNil(ChannelResolver.extractManifest(from: "<html><video src=\"\(proxy)\"></video></html>"))
    }

    /// A manifest-shaped channel url must NOT have that url recorded as its own
    /// pageUrl (the taint guard refuses url == pageUrl, so recording it would
    /// make the stream unrefreshable and, via the post-resolve re-check,
    /// unplayable). A proxy url as a channel url IS recorded: it is a page the
    /// refetch can scrape.
    func testImportRecordsOnlyAPredicateRejectedURLAsItsPage() {
        XCTAssertNil(RefetchMachine.recordedPageUrl(url: m3u8, type: .channel),
                     "a manifest recorded as its own page makes the stream unrefreshable")
        XCTAssertEqual(RefetchMachine.recordedPageUrl(url: page, type: .channel), page)
        XCTAssertEqual(RefetchMachine.recordedPageUrl(url: php, type: .channel), php,
                       "a proxy is not a manifest, so it is a scrapeable page")
    }
}
