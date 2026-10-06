import Foundation
import CoreImage
import AppKit

// MARK: - Deep-link builder (primitive — no dependency on the app's Stream model)

/// Builds the `radio://add?...` deep link that the URL-scheme handler in
/// RadioApp.swift (`case "add"`, lines 548-595) understands, so a scanned QR
/// can re-add a saved stream on another device (e.g. the upcoming iOS app)
/// without the browser extension.
///
/// The link carries the PLAYABLE url in `url=` and the source page (if any) in
/// `pageUrl=` — exactly the same split the app already persists, and the same
/// split the handler reads back out. `type` is always included (view-facing
/// value); only non-empty optional params are emitted, matching how the handler
/// treats them.
public enum StreamDeepLink {

    /// Build one add-link from primitive values. `type` is the raw `StreamType`
    /// string ("audio"/"video"/"channel").
    public static func addLink(url: String, name: String, type: String, pageUrl: String?, referer: String?) -> String {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "url", value: url),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "type", value: type),
        ]
        if let pageUrl, !pageUrl.isEmpty {
            items.append(URLQueryItem(name: "pageUrl", value: pageUrl))
        }
        if let referer, !referer.isEmpty {
            items.append(URLQueryItem(name: "referer", value: referer))
        }
        var comps = URLComponents()
        comps.scheme = "radio"
        comps.host = "add"
        comps.queryItems = items
        return comps.string ?? ""
    }
}

// MARK: - QR image generation

/// Renders QR codes via CoreImage CIQRCodeGenerator — no external dependency,
/// no network, no restricted entitlements.
public enum QRCodeGenerator {

    /// Render `string` as a QR image. `scale` is the number of pixels per QR
    /// module (x10 gives a comfortably scannable ~550px image for the short
    /// deep links this app produces). Returns nil only if CoreImage can't
    /// produce the image for the given input.
    public static func qrImage(from string: String, scale: CGFloat = 10) -> NSImage? {
        guard !string.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Display sizing

/// On-screen geometry for a rendered QR, shared by the export sheet and the
/// test that proves a code still decodes at this size.
///
/// This exists because the sheet displayed the image with `.frame(...)` but
/// WITHOUT `.resizable()`. A SwiftUI `Image` is not resizable by default, so the
/// frame did not scale it — the ~350-550px QR drew at native size and was
/// clipped by the sheet. A partially visible QR has no complete finder
/// patterns and cannot be decoded by anything, which is why the iOS scanner
/// ran a healthy session and never reported a single metadata object.
public enum QRDisplay {
    /// Side, in points, of the QR shown on a card. Verified decodable at this
    /// size by `testQRDecodesAtDisplaySize`.
    public static let side: CGFloat = 240
}

// MARK: - Scan-back decoder

/// Decodes the payload of a QR image with CoreImage CIDetector. Used to prove
/// the generated image round-trips (generate -> render -> scan-back).
public enum QRScanner {
    public static func decode(_ image: NSImage) -> String? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        for feature in detector?.features(in: ci) ?? [] {
            if let qr = feature as? CIQRCodeFeature, let message = qr.messageString {
                return message
            }
        }
        return nil
    }
}
