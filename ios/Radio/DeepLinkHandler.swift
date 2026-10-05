import Foundation
import os.log

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "deeplink")

/// Outcome of ingesting a radio:// link, so callers (e.g. the QR scanner UI)
/// can show a truthful message.
enum DeepLinkOutcome: Equatable {
    /// A brand-new stream was appended.
    case added
    /// An existing stream (matched by pageUrl) was updated in place.
    case updated
    /// The URL was not a handled radio:// URL (or carried no usable url).
    case ignored
}

/// Handles the `radio://` URL scheme. This is the ingestion path for the camera
/// QR card; here we implement the `add` host, ported from the macOS app's
/// handleURL("add") logic including the refuseTainted trust guard so a dead
/// source page URL can never be persisted as a playable url.
///
/// Supported form: `radio://add?url=...&name=...&type=...&pageUrl=...&referer=...`
struct DeepLinkHandler {
    let store: StreamStore

    /// Handle a radio:// URL. Returns the outcome.
    @discardableResult
    func handle(_ url: URL) -> DeepLinkOutcome {
        guard url.scheme == "radio" else { return .ignored }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func param(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        switch url.host {
        case "add":
            return handleAdd(
                streamURL: param("url") ?? "",
                name: param("name") ?? "",
                typeHint: param("type") ?? "",
                pageUrl: param("pageUrl"),
                referer: param("referer")
            )
        default:
            return .ignored
        }
    }

    /// Ingest a raw deep-link string as decoded from a QR code
    /// (AVCaptureMetadataObject.stringValue). Constructs a URL and routes it
    /// through the same `handle(_:)` path as an onOpenURL deep link — so the
    /// camera scanner is literally just feeding the deep-link ingestion.
    @discardableResult
    func handle(string raw: String) -> DeepLinkOutcome {
        guard let url = URL(string: raw) else { return .ignored }
        return handle(url)
    }

    /// Port of the macOS handleURL "add" case, preserving its trust-guard behavior:
    /// if a stream with the same pageUrl already exists, update it (but never push a
    /// tainted URL as the playable url); otherwise append a new stream.
    private func handleAdd(streamURL: String, name: String, typeHint: String, pageUrl: String?, referer: String?) -> DeepLinkOutcome {
        guard !streamURL.isEmpty else { return .ignored }

        let streamType = StreamType(rawValue: typeHint) ?? URLResolver.detectType(streamURL)
        let streamName = name.isEmpty ? streamURL : name

        if let pageUrl, let idx = store.indexByPageUrl(pageUrl) {
            // Guard against the source page URL (or a non-http(s) value) being
            // pushed as the playable url — same trust rule as in-app refresh.
            if !StreamStore.refuseTainted(streamURL, pageUrl: store.streams[idx].pageUrl) {
                store.streams[idx].url = streamURL
            }
            store.streams[idx].name = streamName
            store.streams[idx].type = streamType
            store.streams[idx].referer = referer
            store.streams[idx].headers = nil
            store.save()
            log.info("radio://add updated existing stream (pageUrl \(pageUrl))")
            return .updated
        } else {
            let stream = Stream(name: streamName, url: streamURL, type: streamType, pageUrl: pageUrl, referer: referer)
            store.streams.append(stream)
            store.save()
            log.info("radio://add appended new stream \(streamName)")
            return .added
        }
    }
}
