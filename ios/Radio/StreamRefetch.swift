import Foundation

/// Pure decision logic for "re-fetch a fresh playable URL from this stream's
/// source page" — the iOS port of macOS `StreamPlayer.refreshFromSource(_:manual:)`.
///
/// Why it is a separate type: the three rules a user can see go wrong are all
/// *decisions*, not I/O —
///   1. the re-entrancy guard (never two refreshes of the same stream at once),
///   2. the auto-refetch budget (a dead stream must not hammer its source page),
///   3. the taint guard (a source page URL, or any unresolved fall-through, must
///      never overwrite a URL that actually plays),
/// and the macOS original hides all three inside an async Task that needs a real
/// resolver and a real network. Kept pure (no URLSession, no AVPlayer), they are
/// covered by `RadioTests/RefetchTests.swift`. StreamPlayer owns the plumbing
/// around this: the resolve task, the retry timer, persistence and replay.
///
/// Semantics mirrored from macOS (Sources/StreamPlayer.swift:349), adapted where
/// iOS differs:
/// - macOS re-resolves through `URLResolver` (yt-dlp/StreamProbe); iOS re-resolves
///   through the existing `ChannelResolver` native scrape — no subprocess on iOS.
/// - For a `.channel` stream the *source page* is `pageUrl` when set, else the
///   `url` itself (a channel's url IS a page by design), so a channel with no
///   pageUrl is still refreshable. For `.audio`/`.video` a source page only
///   exists when `pageUrl` was recorded — same as macOS.
enum RefetchDecision: Equatable {
    /// Go ahead: re-resolve the stream from its source page.
    case start
    /// Cannot run this time, with the reason so the caller can tell the user
    /// the truth (only a manual attempt surfaces a message, as on macOS).
    case refused(RefetchRefusal)
}

enum RefetchRefusal: Equatable {
    /// Nothing to refetch from (no source page recorded).
    case noSourcePage
    /// A refresh is already in flight.
    case alreadyRefreshing
    /// The automatic budget is spent; only a manual tap can refresh now.
    case autoBudgetExhausted
}

/// What to do with the URL a refresh came back with.
enum RefetchOutcome: Equatable {
    /// Genuine, untainted, verified — safe to persist as the stream's url.
    case persist(String)
    /// Looked like a result but is not safe to save (page URL / non-http(s) /
    /// an unverified non-manifest). The caller keeps the last known-good url.
    case rejected(String)
    /// The resolver returned nothing at all.
    case failed
}

/// The state machine: `isRefreshing` + the auto budget + the taint rule.
///
/// Not `@Published` — StreamPlayer mirrors `isRefreshing` into its own
/// published property so the UI re-renders; this type stays a plain, testable
/// object with no observation machinery (see the note in PlayerManager about
/// Combine bridging being the manager's job).
final class RefetchMachine {
    /// How many *automatic* (failure-triggered) refetches one playback is
    /// allowed before the stream has to be refreshed by hand. Same cap as macOS.
    static let defaultMaxAutoAttempts = 3
    /// Seconds between automatic retries, scaled by the attempts already spent.
    static let defaultBackoffBase: TimeInterval = 10

    private(set) var isRefreshing = false
    /// Auto attempts spent since the last user-initiated playback.
    private(set) var autoAttempts = 0

    let maxAutoAttempts: Int
    let backoffBase: TimeInterval

    init(maxAutoAttempts: Int = RefetchMachine.defaultMaxAutoAttempts,
         backoffBase: TimeInterval = RefetchMachine.defaultBackoffBase) {
        self.maxAutoAttempts = maxAutoAttempts
        self.backoffBase = backoffBase
    }

    // MARK: - Source page

    /// The page a fresh URL can be scraped from, or nil when there is none.
    ///
    /// `.channel` is the important case: its `url` IS the source page (see
    /// ChannelResolver), so a channel without an explicit `pageUrl` still has
    /// somewhere to refetch from. For `.audio`/`.video` the url is the stream
    /// itself, so only an explicit `pageUrl` counts.
    static func sourcePage(of stream: Stream) -> String? {
        if let page = stream.pageUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !page.isEmpty {
            return page
        }
        return stream.type == .channel ? stream.url : nil
    }

    /// True if a refresh could even be offered for this stream — drives whether
    /// the UI shows a Refresh control at all.
    static func canRefresh(_ stream: Stream) -> Bool {
        sourcePage(of: stream) != nil
    }

    /// The `pageUrl` to RECORD at import time when the user left the field empty
    /// — the mirror image of `sourcePage`, and deliberately next to it so the
    /// two cannot drift apart.
    ///
    /// `sourcePage` says a `.channel` without a pageUrl is still refreshable via
    /// its `url`. Recording the same value makes that fact explicit in the saved
    /// stream (and gives the macOS export/deep-link update path a `pageUrl` to
    /// match on), so a channel added by hand keeps its source page instead of
    /// relying on the fallback forever.
    ///
    /// The `isLiteralManifest` term is load-bearing, not tidiness. A channel
    /// added as `.../live.m3u8` has a url that IS the stream; recording it as the
    /// pageUrl too would make every resolved value from `ChannelResolver`
    /// (which prefers that direct manifest) compare EQUAL to the pageUrl, so the
    /// post-resolve `refuseTainted` re-check in `StreamPlayer.play` would refuse
    /// it — a channel that used to play would start saying "Failed". Only a
    /// url that is genuinely a *page* (no manifest extension) is recorded.
    ///
    /// `.audio`/`.video` get nil: their url is the stream itself, and guessing a
    /// page from a playable url would record a lie (card rule — no guessing).
    static func recordedPageUrl(url: String, type: StreamType) -> String? {
        guard type == .channel else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLiteralManifest(trimmed) else { return nil }
        return trimmed
    }

    /// A literal HLS/DASH manifest is playable by construction, so it does not
    /// need the extra liveness probe a proxy-style URL does.
    ///
    /// Extension check, not `contains(".m3u8")` (which macOS and
    /// ChannelResolver use): `.../y.m3u8isnotadir/proxy.php` contains the
    /// substring but is a proxy, and this function's only job is to decide
    /// whether it is SAFE TO SKIP that probe — so a false "manifest" is the
    /// dangerous direction. A path segment must actually END in the extension.
    /// When in doubt we answer false and the caller probes, which costs one
    /// GET and can never save a dead URL.
    static func isLiteralManifest(_ candidate: String) -> Bool {
        let lower = candidate.lowercased()
        let path = lower.components(separatedBy: "?").first ?? lower
        return path.split(separator: "/").contains {
            $0.hasSuffix(".m3u8") || $0.hasSuffix(".mpd")
        }
    }

    // MARK: - Transitions

    /// Ask to start a refresh. Mutates state only when it returns `.start`
    /// (a refusal leaves the machine exactly as it was), which is what makes
    /// the guard/budget paths easy to assert on.
    ///
    /// `manual` = the user tapped Refresh (unbounded budget, as on macOS);
    /// `false` = triggered by a playback failure, charged to the auto budget.
    func begin(stream: Stream, manual: Bool) -> RefetchDecision {
        guard Self.sourcePage(of: stream) != nil else { return .refused(.noSourcePage) }
        guard !isRefreshing else { return .refused(.alreadyRefreshing) }
        if !manual {
            guard autoAttempts < maxAutoAttempts else { return .refused(.autoBudgetExhausted) }
            autoAttempts += 1
        }
        isRefreshing = true
        return .start
    }

    /// The refresh is over (whatever the result). Clears the re-entrancy guard;
    /// the budget is deliberately NOT touched — attempts are spent, not refunded.
    func finish() {
        isRefreshing = false
    }

    /// Full stop: new playback begins. The budget belongs to *this* playback, so
    /// a stream the user started from the list gets a fresh one. A replay that a
    /// successful refresh itself triggered must NOT call this (StreamPlayer
    /// skips it), otherwise every refetch would top the budget back up and a
    /// dead stream would refetch forever.
    func reset() {
        isRefreshing = false
        autoAttempts = 0
    }

    /// Charge ONE automatic recovery attempt to the same budget the refetch uses,
    /// for the case where a refresh is impossible: a stream with no source page
    /// cannot be refetched, so its only recovery is a plain retry of the URL it
    /// already has. That retry MUST share the cap — the failure sink fires again
    /// as soon as the retried item dies, so an unbudgeted reconnect would loop
    /// (play → fail → reconnect → play → fail → …) and hammer the CDN forever.
    /// This is where iOS has to differ from macOS: macOS `reconnect()` is
    /// unbudgeted because its failure paths are gated differently (proxy
    /// fallback, nudging, a 30s schedule); on iOS the shared budget is the only
    /// thing standing between a dead stream and a hot loop.
    ///
    /// Returns false (and charges nothing) when the budget is spent.
    func chargeAutoAttempt() -> Bool {
        guard autoAttempts < maxAutoAttempts else { return false }
        autoAttempts += 1
        return true
    }

    // MARK: - Resolve plumbing

    /// The stream shape to hand the resolve path when REFETCHING (as opposed to
    /// playing). Its url is replaced by the source page, so a resolver can
    /// never "refresh" by re-reading the stale url it is supposed to replace,
    /// and its type is forced to `.channel` because on iOS the only page →
    /// playable-URL resolver that exists is the ChannelResolver native scrape
    /// (gated on `.channel`), and a pageUrl-bearing `.audio`/`.video` stream
    /// must route through it to get a fresh URL at all — the same job macOS
    /// URLResolver does there. Everything that makes the result safe (taint
    /// guard, verification) is applied to the outcome, not to this probe.
    static func probe(for stream: Stream) -> Stream {
        guard let page = sourcePage(of: stream) else { return stream }
        return Stream(
            name: stream.name,
            url: page,
            type: .channel,
            pageUrl: page,
            referer: stream.referer,
            headers: stream.headers
        )
    }

    /// Judge the URL a refresh resolved to.
    ///
    /// `verified` is the caller's answer to "does this URL actually serve
    /// content?" for the non-manifest case — passed in, not computed here, so
    /// this stays pure and the network probe stays in StreamPlayer. Manifest
    /// URLs never consult it (a literal .m3u8/.mpd is playable by definition,
    /// and probing a live manifest would download a segment for nothing).
    ///
    /// The taint rule is the whole point of this function, and it is the rule
    /// the iOS app already enforces everywhere else it writes a playable url
    /// (`StreamStore.refuseTainted`, `DeepLinkHandler`, `StreamPlayer.play`):
    /// a source page is NOT a stream, so a refresh that fell through to the
    /// page — or to any non-http(s) value — must never overwrite a url that
    /// plays. The caller keeps the previous url and says "Refresh failed".
    func outcome(for candidate: String?, stream: Stream, verified: Bool) -> RefetchOutcome {
        guard let candidate else { return .failed }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        // Pass the *source page*, not just `pageUrl`: for a channel whose url is
        // itself the page, `pageUrl` is nil and `refuseTainted` alone would let
        // an HTML page be saved as the playable url.
        let page = Self.sourcePage(of: stream)
        if StreamStore.refuseTainted(trimmed, pageUrl: page) {
            // One exception, and only this one: a page that IS a literal
            // manifest (a channel added as, say, `.../live.m3u8`). Then the
            // resolver handing the page back is not a fall-through — the page
            // genuinely is the stream (ChannelResolver treats a direct manifest
            // as playable, and play() plays it). Identity with a NON-manifest
            // page stays tainted: that is the observed bug — HTML saved as url.
            if trimmed == page, Self.isLiteralManifest(page ?? "") {
                return .persist(trimmed)
            }
            return .rejected(trimmed)
        }
        if !Self.isLiteralManifest(trimmed) && !verified {
            return .rejected(trimmed)
        }
        return .persist(trimmed)
    }

    /// How long to wait before retrying a *failed automatic* refresh. Grows
    /// with the attempts already spent (10s, 20s, 30s with the defaults) so a
    /// flaky source page gets less and less traffic, matching macOS.
    var retryAfter: TimeInterval {
        autoAttempts > 1 ? backoffBase * Double(autoAttempts) : backoffBase
    }
}

/// Liveness probe for a resolved URL that is not a literal `.m3u8`/`.mpd`
/// manifest — the check that lets `RefetchMachine.outcome` refuse a dead proxy.
///
/// Ported from macOS `StreamPlayer.verifyStreamURL`: a short GET (a HEAD has no
/// body, so it cannot catch the 0-byte dead-proxy answer) with a tight timeout,
/// and any non-2xx, error, or empty body means "not verified" → the caller keeps
/// the last known-good url.
enum StreamURLProbe {
    static func verify(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            // A dead proxy answers 200 with a 0-byte body — not a playable stream.
            return !data.isEmpty
        } catch {
            return false
        }
    }
}
