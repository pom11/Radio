import XCTest
import AppKit
import CoreImage
@testable import RadioCore

final class QRExportTests: XCTestCase {

    // MARK: - Deep-link building (byte-compatible with RadioApp handleURL "case add")

    /// Parse a built link exactly like RadioApp.handleURL's `case "add"` does,
    /// so we can assert the payload reads back identically.
    private func parseAddLink(_ link: String) -> (url: String?, name: String?, type: String?, pageUrl: String?, referer: String?) {
        guard let url = URL(string: link), url.scheme == "radio" else {
            return (nil, nil, nil, nil, nil)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func param(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        return (param("url"), param("name"), param("type"), param("pageUrl"), param("referer"))
    }

    func testDeepLinkRoundTripsThroughHandlerParse() {
        let link = StreamDeepLink.addLink(
            url: "https://example.com/live/stream.m3u8?token=abc&x=1",
            name: "My & Favorite / Stream?",
            type: "audio",
            pageUrl: "https://example.com/watch?v=123",
            referer: "https://example.com/page?a=1&b=2"
        )

        XCTAssertTrue(link.hasPrefix("radio://add?"), "link scheme/host: \(link)")

        let parsed = parseAddLink(link)
        XCTAssertEqual(parsed.url, "https://example.com/live/stream.m3u8?token=abc&x=1")
        XCTAssertEqual(parsed.name, "My & Favorite / Stream?")
        XCTAssertEqual(parsed.type, "audio")
        XCTAssertEqual(parsed.pageUrl, "https://example.com/watch?v=123")
        XCTAssertEqual(parsed.referer, "https://example.com/page?a=1&b=2")
    }

    func testDeepLinkOmitsEmptyOptionalParams() {
        let link = StreamDeepLink.addLink(
            url: "https://example.com/stream.mp3",
            name: "Simple",
            type: "video",
            pageUrl: nil,
            referer: ""
        )
        XCTAssertFalse(link.contains("pageUrl"), "pageUrl should be omitted: \(link)")
        XCTAssertFalse(link.contains("referer"), "referer should be omitted: \(link)")

        let parsed = parseAddLink(link)
        XCTAssertEqual(parsed.url, "https://example.com/stream.mp3")
        XCTAssertEqual(parsed.name, "Simple")
        XCTAssertEqual(parsed.type, "video")
        XCTAssertNil(parsed.pageUrl)
        XCTAssertNil(parsed.referer)
    }

    // MARK: - QR generation + scan-back round trip

    func testQRFilterProducesNonNilImage() {
        let link = StreamDeepLink.addLink(
            url: "https://example.com/stream.m3u8",
            name: "Test Stream",
            type: "channel",
            pageUrl: "https://example.com/channel",
            referer: nil
        )
        let image = QRCodeGenerator.qrImage(from: link)
        XCTAssertNotNil(image, "CIQRCodeGenerator should produce a non-nil image")
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
    }

    func testQRScanBackRoundTripsPayload() {
        let link = StreamDeepLink.addLink(
            url: "https://example.com/live/stream.m3u8?token=abc&x=1",
            name: "My & Favorite / Stream?",
            type: "audio",
            pageUrl: "https://example.com/watch?v=123",
            referer: "https://example.com/page?a=1&b=2"
        )
        guard let image = QRCodeGenerator.qrImage(from: link) else {
            return XCTFail("image is nil")
        }
        let decoded = QRScanner.decode(image)
        XCTAssertEqual(decoded, link, "scan-back must reproduce the exact payload")
    }
}
