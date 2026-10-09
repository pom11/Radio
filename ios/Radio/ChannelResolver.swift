import Foundation
import os.log

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "channel-resolver")

/// Best-effort, App-Store-safe channel → playable-URL resolver.
///
/// A `.channel` stream's `url` (and `pageUrl`) is a *source page* (YouTube /
/// Twitch / Kick channel handle, or a TV channel's site) — AVPlayer cannot play
/// a page. On macOS this is solved by the StreamProbe/yt-dlp/streamlink
/// subprocess pipeline; iOS forbids subprocess spawning, so this resolver is
/// the pragmatic native replacement: fetch the channel page and regex-search
/// its HTML for a literal HLS (`.m3u8`) or DASH (`.mpd`) manifest URL.
///
/// This is intentionally a *best-effort* layer, not a guarantee:
/// - Channels whose page literally embeds a `.m3u8`/`.mpd` manifest (many TV /
///   independent streamers) resolve and play in-app through the normal AVPlayer.
/// - YouTube / Twitch / Kick live channels almost never embed a literal
///   manifest — their streams are served from signed, DRM-protected URLs that
///   change per request. Those cannot be extracted reliably in pure Swift, so
///   this returns nil and the caller falls back to the "Open in Browser"
///   affordance (the user watches the live stream in Safari). That is the
///   honest limit, documented in the UI + README.
enum ChannelResolver {

    /// Attempt to derive a directly playable URL for a channel stream from its
    /// source page. Returns nil when no literal manifest can be found (the
    /// caller should offer open-in-browser). Runs on a background URLSession —
    /// callers invoke it from within a StreamPlayer resolve task.
    static func resolvePlayableURL(for stream: Stream) async -> String? {
        // Only meaningful for channel streams.
        guard stream.type == .channel else { return nil }

        // If the stream already points at a direct manifest (e.g. it was added
        // with a concrete .m3u8/.mpd url), prefer it — no fetch needed.
        if let direct = directManifest(stream.url) { return direct }
        if let page = stream.pageUrl, let direct = directManifest(page) { return direct }

        // Otherwise scrape the page for an embedded manifest.
        let page = stream.pageUrl ?? stream.url
        guard let html = await fetchHTML(page) else { return nil }
        return extractManifest(from: html)
    }

    /// THE app-wide answer to "is this URL a literal HLS/DASH manifest
    /// (`.m3u8` / `.mpd`), i.e. already directly playable?"
    ///
    /// This is the ONE predicate for that question — every play / refresh /
    /// import / taint-guard call site must ask it and none may re-derive the
    /// answer from its own string search. It used to be asked two different
    /// ways (`ChannelResolver.directManifest` with `contains`, and
    /// `RefetchMachine.isLiteralManifest` with an extension check), and the two
    /// could disagree: one call site would hand a `.php` proxy to AVPlayer as if
    /// it were a manifest while another refused to refetch the same URL. That
    /// disagreement is the tvron `.php`-proxy class of bugs (macOS t_2a758903)
    /// and the iOS "never persist pageUrl as url" taint guard.
    ///
    /// Extension check, not `contains(".m3u8")`: `.../y.m3u8isnotadir/proxy.php`
    /// contains the substring but is a proxy. A path segment must actually END
    /// in the extension. When in doubt we answer false — the callers treat
    /// "literal manifest" as "safe to skip the liveness probe and to accept
    /// without refetching", so a false positive is the dangerous direction and a
    /// false negative only costs one GET.
    ///
    /// Query (`?`) and fragment (`#`) are dropped before the check so a token
    /// or a player fragment cannot forge or hide the extension: in a URL the
    /// first `?` or `#` always ends the path, so taking the head of that split
    /// is the path (garbage input just yields a short non-manifest string —
    /// the safe direction).
    static func isLiteralManifest(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        let path = lower.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? lower
        return path.split(separator: "/").contains {
            $0.hasSuffix(".m3u8") || $0.hasSuffix(".mpd")
        }
    }

    /// The candidate itself if it is a literal manifest (see
    /// `isLiteralManifest`), else nil — the shape the resolve path wants.
    static func directManifest(_ candidate: String) -> String? {
        isLiteralManifest(candidate) ? candidate : nil
    }

    /// Fetch a page's HTML with a browser-like User-Agent (many sites 4xx a bare
    /// default UA). Returns nil on any failure or on a non-200 response.
    private static func fetchHTML(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        } catch {
            log.debug("channel scrape fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Regex-scan HTML for the first literal `.m3u8` or `.mpd` stream URL.
    /// Ported from the macOS StreamProbe.scrapeStreamURL (no subprocess, so the
    /// yt-dlp / DAI branches are dropped — only the literal-manifest extraction
    /// applies, which is the App-Store-safe part).
    ///
    /// The regex FINDS a candidate; `isLiteralManifest` DECIDES it. A match that
    /// the app-wide predicate would not call a manifest (e.g. a `.php` proxy with
    /// `.m3u8` buried in its query — the tvron bug class) is not handed back as
    /// one: the caller then falls through to open-in-browser / refetch instead of
    /// feeding a proxy to AVPlayer as if it were a playlist.
    static func extractManifest(from html: String) -> String? {
        for pattern in [m3u8Pattern, mpdPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: html) else { continue }
                // Strip any trailing quote/space the loose regex may have captured.
                let raw = String(html[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"\\ "))
                if !raw.isEmpty, isLiteralManifest(raw) { return raw }
            }
        }
        return nil
    }

    /// `https?://` URL ending in `.m3u8` (optionally with query params), bounded
    /// by typical HTML delimiters so we never swallow the surrounding page.
    private static let m3u8Pattern = #"(https?://[^\s"'<>\\)]+\.m3u8[^\s"'<>\\)]*)"#
    private static let mpdPattern = #"(https?://[^\s"'<>\\)]+\.mpd[^\s"'<>\\)]*)"#
}
