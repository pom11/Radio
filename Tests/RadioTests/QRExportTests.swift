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

    // MARK: - Display size (regression: the sheet showed a CLIPPED code)

    /// A QR must still decode after being scaled to the size it is DISPLAYED
    /// at, and must NOT be relied on when cropped.
    ///
    /// The export sheet rendered the image with `.frame(...)` and no
    /// `.resizable()`, so the ~350-550px code drew at native size and was
    /// clipped by the 460pt sheet. Measured: a correctly scaled code decodes at
    /// 200/240/300pt, while the same code cropped to 200pt does NOT decode at
    /// all — which is why the iOS scanner reported a running session and zero
    /// metadata objects. This pins both halves.
    func testQRDecodesAtDisplaySize() throws {
        let link = StreamDeepLink.addLink(
            url: "https://stream.example.com/live/station128.aac?token=abc123",
            name: "Radio România Actualități",
            type: "audio",
            pageUrl: "https://www.example.com/live/",
            referer: nil)
        let native = try XCTUnwrap(QRCodeGenerator.qrImage(from: link))
        XCTAssertEqual(QRScanner.decode(native), link, "native-size QR must decode")

        let shown = Self.redraw(native, side: QRDisplay.side)
        XCTAssertEqual(QRScanner.decode(shown), link,
                       "QR must survive scaling to its on-screen size (\(QRDisplay.side)pt)")
    }

    func testCroppedQRDoesNotDecode() throws {
        // Guards the DIAGNOSIS, not the fix: if a cropped code ever became
        // decodable this test failing would tell us the reasoning above no
        // longer holds.
        let link = StreamDeepLink.addLink(
            url: "https://stream.example.com/live/station128.aac?token=abc123",
            name: "Radio România Actualități",
            type: "audio",
            pageUrl: "https://www.example.com/live/",
            referer: nil)
        let native = try XCTUnwrap(QRCodeGenerator.qrImage(from: link))
        let clipped = Self.crop(native, side: QRDisplay.side)
        XCTAssertNil(QRScanner.decode(clipped),
                     "a clipped QR is not decodable — that was the bug")
    }

    /// Scale by redrawing, as SwiftUI does for a `.resizable()` image.
    private static func redraw(_ image: NSImage, side: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        out.unlockFocus()
        return out
    }

    /// Clip to `side`, as a non-resizable image in a smaller frame ends up.
    private static func crop(_ image: NSImage, side: CGFloat) -> NSImage {
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.draw(in: NSRect(x: 0, y: image.size.height - side,
                              width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }
}
