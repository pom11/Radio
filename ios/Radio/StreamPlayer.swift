import AVFoundation
import Combine
import os.log

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "player")

/// Minimal single-stream player for the iOS foundation card.
///
/// Rules ported from the macOS StreamPlayer/PlayerManager (identical behavior):
/// - A stream plays via its resolved url (may need referer/headers).
/// - Never play a pageUrl as the playable url — the same `refuseTainted` rule is
///   enforced here at play time, so a source page URL can never be given to AVPlayer.
/// - One stream at a time: playing a new one replaces the current (the store-level
///   PlayerManager enforces this; this player also stops its own prior item).
final class StreamPlayer: NSObject, ObservableObject, NowPlayingCommandDelegate {
    @Published var isPlaying = false
    @Published var currentStream: Stream?
    @Published var statusText: String = ""
    /// True while AVPlayer is routing audio to an external (AirPlay) destination.
    @Published var isExternalPlayback = false
    /// For a `.channel` stream that could not resolve to a playable URL in-app,
    /// this carries the channel's page to hand to "Open in Browser" (Safari).
    /// nil means no open-in-browser is currently being offered. Cleared on stop
    /// and on any successful play.
    @Published var openInBrowserURL: URL?

    /// The live AVPlayer, or nil while connecting / after stop.
    ///
    /// Published because the video surface has to REACT to it: an AVPlayer draws
    /// nothing until an AVPlayerLayer is attached (see VideoSurface.swift), and
    /// the layer must be re-pointed at every new player — a plain `var` would
    /// leave SwiftUI rendering a surface bound to a player that no longer
    /// exists. Assigned only on the main actor (playback start / stop).
    @Published private(set) var avPlayer: AVPlayer?

    /// True while a refetch-from-source is in flight. Mirrors
    /// `refetch.isRefreshing` (the machine owns the rule; this is the
    /// observation surface for the bar's spinner / disabled button), exactly
    /// like macOS `StreamPlayer.isRefreshing`.
    @Published private(set) var isRefreshing = false

    /// Called when a refetch produced a genuinely new playable URL, so the
    /// owner persists it (PlayerManager → StreamStore.applyRefreshedURL).
    /// Receives the stream with id/name/type/pageUrl preserved and the fresh
    /// url — same contract as the macOS `onRefreshStream`.
    var onRefreshStream: ((Stream) -> Void)?

    /// The refetch state machine: re-entrancy guard + auto budget + taint rule.
    /// Pure (no async, no I/O) — the decisions live in RefetchMachine so
    /// RadioTests can drive them; this class only owns the task plumbing.
    let refetch = RefetchMachine()
    private var refreshTask: Task<Void, Never>?
    private var refreshRetryTask: DispatchWorkItem?
    /// Identity counter for refreshTask. A finished/stale task may only clear
    /// the handle if it is still the current one — otherwise a late-finishing
    /// task from a previous stream would orphan a NEWER refresh's handle (and
    /// stop() would lose its ability to cancel it). Bumped on every refresh
    /// start AND every teardown that drops the handle.
    private var refreshEpoch = 0

    /// Liveness probe for a resolved URL that is not a literal manifest. A var
    /// (not a static) so unit tests replace the network with a stub — the
    /// judgement path is then testable end-to-end without internet.
    var verifyURL: (String) async -> Bool = StreamURLProbe.verify

    private var cancellables = Set<AnyCancellable>()
    private var playTask: Task<Void, Never>?
    private var registeredInterruptObserver = false
    /// Lock Screen / Control Center / Dynamic Island presence + the remote
    /// commands those surfaces send back. Created with the player (never
    /// per-stream) because `MPRemoteCommand.target` is a weak reference: the
    /// controller must outlive the commands it registered, and it unregisters
    /// its own targets on deinit. See NowPlaying.swift.
    private let nowPlaying = NowPlayingController()

    override init() {
        super.init()
        nowPlaying.delegate = self
    }

    /// Resolve a Stream to a playable URL string.
    ///
    /// `resolve` is pluggable so a future card can insert full yt-dlp-style
    /// resolution. The default:
    /// - audio / video direct streams → their own url (plays via AVPlayer).
    /// - `.channel` streams → `ChannelResolver.resolvePlayableURL`, a best-effort
    ///   native scrape of the source page for a literal HLS/DASH manifest. Most
    ///   YouTube/Twitch/Kick live channels yield nil here (their streams are
    ///   signed/DRM'd) — the caller then sets `openInBrowserURL` so the UI offers
    ///   "Open in Browser" instead of a dead failure. The `refuseTainted` guard
    ///   still runs on the resolved value: a pageUrl is never played.
    var resolve: (Stream) async -> String? = { stream in
        if stream.type == .channel {
            return await ChannelResolver.resolvePlayableURL(for: stream)
        }
        return stream.url
    }

    deinit {
        playTask?.cancel()
        refreshTask?.cancel()
        refreshRetryTask?.cancel()
        avPlayer?.pause()
        NotificationCenter.default.removeObserver(self)
    }

    /// Observe system audio-session interruptions (phone call, Siri, alarm).
    /// On an ended interruption that should resume, re-activate the session and
    /// resume playback so a stream keeps playing after a call/alarm instead of
    /// dying silently. This is the "re-activate on interruption end" the AirPlay
    /// card promised but never shipped.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let rawValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
        switch type {
        case .began:
            // System is interrupting playback; pause and reflect it.
            avPlayer?.pause()
            isPlaying = false
            publishNowPlaying()
        case .ended:
            let opts = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let shouldResume = opts.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if shouldResume {
                AudioSessionConfig.activate()
                if let stream = currentStream {
                    play(stream)
                } else {
                    avPlayer?.play()
                }
                publishNowPlaying()
            }
        @unknown default:
            break
        }
    }

    /// Play a stream, replacing the current one if any. Exactly one stream
    /// plays at a time.
    ///
    /// `userInitiated` — false by DEFAULT, deliberately. The budget belongs to
    /// one playback *session*: a stream the user just started (row tap, deep
    /// link, remote skip, play-after-failure) gets a full budget, while a
    /// replay triggered by the player itself (a successful refetch restarting
    /// playback) is the same session and must NOT top the budget back up — if
    /// it did, a permanently dead stream would refetch forever. A default of
    /// `true` would make every future internal call site silently launder the
    /// budget; a default of `false` forces each new *user-facing* call site to
    /// opt in explicitly, which is the mistake worth preventing.
    func play(_ stream: Stream, userInitiated: Bool = false) {
        if userInitiated { refetch.reset() }
        teardownPlayback()
        // The old stream is gone: its in-flight/pending refetch must die with
        // it. Bumping the epoch first detaches any still-running task from the
        // handle (see refreshEpoch). Note `stop()` deliberately does NOT reset
        // the budget (see there), so the session's spent attempts survive here.
        refreshEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
        refetch.finish()
        isRefreshing = false
        // Configure the audio session for playback so streams can route to
        // AirPlay destinations. Idempotent and non-fatal on failure.
        AudioSessionConfig.activate()
        // Register the audio-session interruption observer once (not on every play).
        if !registeredInterruptObserver {
            registeredInterruptObserver = true
            observeInterruptions()
        }
        currentStream = stream
        isPlaying = true
        statusText = "Connecting..."
        // Starting a fresh play; clear any stale open-in-browser offer.
        openInBrowserURL = nil

        // Trust guard: never play a pageUrl as the playable url. Skipped for
        // `.channel` streams — for a channel `url` IS the source page by design,
        // and resolving it (not rejecting it up front) is exactly what this card
        // enables. The resolved value is independently taint-checked below, so a
        // page can never actually reach AVPlayer.
        if stream.type != .channel, StreamStore.refuseTainted(stream.url, pageUrl: stream.pageUrl) {
            statusText = stream.type == .channel ? "Offline" : "Failed"
            isPlaying = false
            return
        }

        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard let resolved = await self.resolve(stream) else {
                self.handleResolveFailure(stream)
                return
            }
            guard !Task.isCancelled else { return }
            // Re-check the taint guard on the finally-resolved URL too, so even a
            // resolver that falls back to the source page cannot play it.
            if StreamStore.refuseTainted(resolved, pageUrl: stream.pageUrl) {
                self.handleResolveFailure(stream)
                return
            }
            guard let url = URL(string: resolved) else {
                self.statusText = "Invalid URL"
                self.isPlaying = false
                return
            }
            self.startPlayback(url: url, stream: stream)
        }
    }

    /// Called when a stream's URL could not be resolved to a trusted playable
    /// URL (or the resolved value was tainted). For `.channel` streams this is
    /// the graceful-fallback path: instead of a dead "Failed", expose the
    /// channel's page via `openInBrowserURL` so the UI offers "Open in Browser"
    /// (Safari) — the honest, working way to watch a signed/DRM live stream the
    /// app cannot extract in pure Swift.
    private func handleResolveFailure(_ stream: Stream) {
        statusText = "Failed"
        isPlaying = false
        if stream.type == .channel {
            let page = stream.pageUrl ?? stream.url
            if let url = URL(string: page), StreamStore.refuseTainted(page, pageUrl: nil) == false {
                openInBrowserURL = url
                statusText = "Open in browser"
            }
        }
    }

    private func startPlayback(url: URL, stream: Stream) {
        // Build HTTP headers (referer/headers) for sources that need them.
        var httpHeaders: [String: String] = stream.headers ?? [:]
        if let referer = stream.referer {
            httpHeaders["Referer"] = referer
        }

        var assetOptions: [String: Any] = [:]
        if !httpHeaders.isEmpty {
            // Native AVURLAsset header injection. (A local header proxy for HLS
            // sub-requests is a later card; most direct streams / HLS play fine.)
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = httpHeaders
        }

        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions))
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        // AirPlay support: allow routing to external (AirPlay) destinations.
        // Enabled by default for AVPlayer, but set it explicitly so the contract
        // is obvious to future readers.
        player.allowsExternalPlayback = true
        observeExternalPlayback(player)
        avPlayer = player

        observeStatus(item: item)
        observeRate(player)
        player.play()
        updateStatusText()
        // Publish the Lock Screen / Control Center card. Published here rather
        // than in play() so a stream that fails to resolve (bad URL, tainted
        // resolution, offline channel) never leaves a card for something that
        // is not playing.
        publishNowPlaying()
    }

    func stop() {
        teardownPlayback()
        // The user ended the session: its refetch task, pending retry and
        // spent budget all go with it. A later start is a fresh user action
        // (PlayerManager → play(userInitiated: true)) and gets a fresh budget
        // anyway. Epoch bump first: detaches any in-flight task from the handle.
        refreshEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
        refetch.reset()
        isRefreshing = false
    }

    /// Tear the player down WITHOUT touching the refetch budget — the shared
    /// body of `stop()` (user-initiated) and `play()` (which must replace the
    /// previous stream but keep the session's spent auto attempts alive, so an
    /// internal refetch-replay cannot launder its way back to a full budget).
    private func teardownPlayback() {
        playTask?.cancel()
        playTask = nil
        cancellables.removeAll()
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        currentStream = nil
        isPlaying = false
        isExternalPlayback = false
        openInBrowserURL = nil
        statusText = ""
        // No card for a stream that is not playing — without this the Lock
        // Screen keeps a ghost entry (with a running elapsed time) after stop.
        nowPlaying.clear()
    }

    func toggle(_ stream: Stream) {
        if currentStream?.id == stream.id && isPlaying {
            stop()
        } else {
            play(stream, userInitiated: true)
        }
    }

    // MARK: - Refetch from source (port of macOS refreshFromSource)

    /// Re-fetch a fresh playable URL from the stream's source page.
    ///
    /// The iOS port of macOS `StreamPlayer.refreshFromSource(_:manual:)`
    /// (Sources/StreamPlayer.swift:349). All three rules — can this run, may it
    /// run again, is the result safe to save — live in `RefetchMachine`, so this
    /// method is only the async plumbing around them: run the resolve path,
    /// probe the result, then persist or keep the old URL.
    ///
    /// - `manual`: true for the bar's Refresh button (unbounded budget, as on
    ///   macOS); false for automatic refetch after a playback failure (bounded).
    /// - Returns true if a refresh was started, false if it could not run (no
    ///   source page, one already in flight, or the auto budget is spent).
    @discardableResult
    func refreshFromSource(_ stream: Stream, manual: Bool) -> Bool {
        switch refetch.begin(stream: stream, manual: manual) {
        case .refused(let refusal):
            // Only a manual attempt talks to the user — an automatic one that
            // the budget refused must fail silently, exactly as on macOS.
            if manual {
                switch refusal {
                case .noSourcePage: statusText = "No source page to refetch from"
                case .alreadyRefreshing, .autoBudgetExhausted: break
                }
            }
            log.info("refresh refused (\(String(describing: refusal), privacy: .public)) for \(stream.name, privacy: .public)")
            return false

        case .start:
            break
        }

        isRefreshing = true
        statusText = "Re-fetching from source..."

        let probeStream = RefetchMachine.probe(for: stream)
        refreshEpoch += 1
        let epoch = refreshEpoch
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only the CURRENT task may clear the handle (see refreshEpoch).
                if self.refreshEpoch == epoch { self.refreshTask = nil }
            }

            // The resolve path gets a PROBE whose url is the source page (see
            // RefetchMachine.probe), so it cannot "resolve" by re-reading the
            // stale url it is meant to replace. This is the iOS resolve path —
            // ChannelResolver's native scrape, no yt-dlp and no subprocess.
            let candidate = await self.resolve(probeStream)

            // Judge the candidate only while still responsible for this stream,
            // and after clearing the guard (macOS order): a slow refresh must
            // never write a URL for a stream the user has since switched to.
            let stillCurrent = self.currentStream?.id == stream.id
            self.refetch.finish()
            self.isRefreshing = false
            guard !Task.isCancelled, stillCurrent else { return }

            let verified: Bool
            if RefetchMachine.isLiteralManifest(candidate ?? "") {
                verified = true
            } else if let candidate {
                verified = await self.verifyURL(candidate)
            } else {
                verified = false
            }

            switch self.refetch.outcome(for: candidate, stream: stream, verified: verified) {
            case .persist(let freshURL):
                var refreshed = stream
                refreshed.url = freshURL
                // referer/headers are kept as-is (the source page is unchanged,
                // and the iOS scrape yields no new headers).
                log.info("refreshed \(stream.name, privacy: .public) from source")
                self.onRefreshStream?(refreshed)
                self.play(refreshed)

            case .rejected(let tainted):
                // The resolver fell through to the page (or handed back
                // something unverifiable). The last known-good url WINS — that
                // is the whole point of the guard.
                self.statusText = "Refresh failed"
                log.error("refresh rejected tainted url \(tainted, privacy: .public) for \(stream.name, privacy: .public); keeping existing url")
                if !manual { self.scheduleRefreshRetry(stream) }

            case .failed:
                self.statusText = "Refresh failed"
                log.error("refresh could not resolve \(stream.name, privacy: .public) from its source page")
                if !manual { self.scheduleRefreshRetry(stream) }
            }
        }
        return true
    }

    /// Retry a *failed automatic* refresh after a backoff, as long as this
    /// stream is still the one we are playing. Budget is charged by
    /// `refreshFromSource` on the retry itself, so retries cannot exceed the cap.
    private func scheduleRefreshRetry(_ stream: Stream) {
        refreshRetryTask?.cancel()
        let delay = refetch.retryAfter
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshRetryTask = nil
            guard self.currentStream?.id == stream.id else { return }
            _ = self.refreshFromSource(stream, manual: false)
        }
        refreshRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// Route a playback failure (card requirement: a failed stream must try to
    /// recover instead of dead-ending at "Failed").
    ///
    /// Three outcomes, in the same priority order as macOS `handlePlaybackFailure`:
    /// 1. has a source page → refetch a fresh URL from it (budgeted);
    /// 2. no source page, budget left → retry the URL we already have;
    /// 3. budget spent → give up honestly, and for a channel offer the browser.
    ///
    /// (2) is charged to the SAME budget as (1) and is why this exists: the
    /// failure sink fires again the moment the retried item dies, so an
    /// unbudgeted retry of a dead URL would loop forever.
    private func handlePlaybackFailure() {
        guard let stream = currentStream else { return }
        if RefetchMachine.canRefresh(stream) {
            if refreshFromSource(stream, manual: false) { return }
            // Refused (budget spent or a refresh already in flight): fall
            // through to the honest end state rather than silently doing nothing.
        }
        if refetch.chargeAutoAttempt() {
            log.info("playback failed with no source page; retrying same url (auto attempt \(self.refetch.autoAttempts))")
            statusText = "Reconnecting..."
            play(stream)
            return
        }
        log.error("playback failed and the recovery budget is spent for \(stream.name, privacy: .public)")
        giveUpOnPlayback(stream, reason: "Failed")
    }

    /// The honest end state for a stream that cannot play: no phantom
    /// "Playing", no Lock Screen card, and for a channel the working escape
    /// hatch (Safari) instead of a dead failure.
    private func giveUpOnPlayback(_ stream: Stream, reason: String) {
        statusText = reason
        isPlaying = false
        nowPlaying.clear()
        if stream.type == .channel {
            let page = stream.pageUrl ?? stream.url
            if let url = URL(string: page), !StreamStore.refuseTainted(page, pageUrl: nil) {
                openInBrowserURL = url
                statusText = "Open in browser"
            }
        }
    }

    private func updateStatusText() {
        statusText = currentStream?.name ?? ""
    }

    // MARK: - Now playing (Lock Screen / Control Center / Dynamic Island)

    /// Push the current player state to MPNowPlayingInfoCenter, or clear it when
    /// nothing is playing. Every state change funnels through here (play start,
    /// pause, resume, interruption, stop) so the system's card can never drift
    /// from what the player is actually doing.
    ///
    /// Safe to call at any time, including on a failed play: with no stream, or
    /// a player that is paused AND has never started, the card is cleared rather
    /// than published — that is what keeps a failed/offline stream from
    /// appearing on the Lock Screen at all.
    private func publishNowPlaying() {
        guard let stream = currentStream, let player = avPlayer else {
            nowPlaying.clear()
            return
        }
        // `isPlaying` is our intent flag; the real rate is what the system must
        // see. A stream that has not reached readyToPlay yet reports rate 0 —
        // publish it as paused rather than fabricating a playing state.
        let rate = Double(player.rate)
        nowPlaying.publish(
            stream: stream,
            elapsedSeconds: Self.seconds(player.currentTime()),
            rate: rate,
            durationSeconds: itemDurationSeconds(player)
        )
    }

    /// The playing item's duration in seconds, or nil when there is none / it is
    /// not known yet (live streams). CMTimeGetSeconds yields infinity or NaN for
    /// the indefinite/invalid times a live HLS item reports, which
    /// NowPlayingInfo.dictionary treats as "live".
    private func itemDurationSeconds(_ player: AVPlayer) -> Double? {
        guard let item = player.currentItem, item.status == .readyToPlay else { return nil }
        let seconds = Self.seconds(item.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// CMTime → Double, mapping the invalid/indefinite cases to non-finite
    /// numbers so callers can test them uniformly with `isFinite`.
    private static func seconds(_ time: CMTime) -> Double {
        guard CMTIME_IS_VALID(time), !CMTIME_IS_INDEFINITE(time) else { return .nan }
        return CMTimeGetSeconds(time)
    }

    /// Keep the card anchored to the real rate. The system EXTRAPOLATES the
    /// card's elapsed time from (elapsed, rate) — see
    /// MPNowPlayingInfoCenter.h: updating elapsed "frequently is not required
    /// (or recommended)" — so the card is republished exactly when the rate
    /// changes (pause, resume, a stall, an AirPlay handoff), which is the moment
    /// the extrapolation must be re-based. Publishing on a timer instead would
    /// re-anchor a slightly-stale position every second and make the displayed
    /// time visibly jump.
    private func observeRate(_ player: AVPlayer) {
        player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.publishNowPlaying()
            }
            .store(in: &cancellables)
    }

    // MARK: - Remote commands (Lock Screen / Control Center / headphones / CarPlay)

    // The system's transport buttons drive the SAME paths the in-app UI does, so
    // pause/resume/skip keep every other piece of state (isPlaying, statusText,
    // the player bar) consistent instead of leaving the UI and the card
    // disagreeing.

    /// Control Center's play button. The stream stays loaded while paused, so
    /// this only has to resume it — and if the item was dropped, re-play it.
    @discardableResult
    func nowPlayingResume() -> Bool {
        guard let stream = currentStream else { return false }
        if avPlayer == nil {
            // Item was torn down (e.g. after a failure): the user pressing play
            // again IS a fresh session — they are asking for another go, so it
            // gets a fresh recovery budget.
            play(stream, userInitiated: true)
            return true
        }
        AudioSessionConfig.activate()
        avPlayer?.play()
        isPlaying = true
        updateStatusText()
        publishNowPlaying()
        return true
    }

    @discardableResult
    func nowPlayingPause() -> Bool {
        guard avPlayer != nil, isPlaying else { return false }
        avPlayer?.pause()
        isPlaying = false
        statusText = currentStream?.name ?? ""
        publishNowPlaying()
        return true
    }

    @discardableResult
    func nowPlayingTogglePlayback() -> Bool {
        isPlaying ? nowPlayingPause() : nowPlayingResume()
    }

    /// Next / previous = the next / previous stream in the saved list, wrapping.
    /// This is the honest mapping for a radio app: there is no queue, the saved
    /// list is the dial. Reuses `play(_:)` so it goes through the same resolve +
    /// taint-guard path as tapping a row.
    @discardableResult
    func nowPlayingSkip(forward: Bool) -> Bool {
        guard let current = currentStream else { return false }
        let streams = StreamStore.shared.streams
        guard let index = NowPlayingInfo.nextIndex(current: current.id, in: streams, forward: forward) else {
            return false
        }
        play(streams[index], userInitiated: true)
        return true
    }

    /// Scrubbing is only meaningful for an on-demand item with a real duration;
    /// a live broadcast has no position to move to, so decline it (the system
    /// also hides the scrubber, because the card says IsLiveStream = true).
    @discardableResult
    func nowPlayingSeek(to seconds: Double) -> Bool {
        guard let player = avPlayer, let item = player.currentItem,
              item.status == .readyToPlay,
              let duration = itemDurationSeconds(player), seconds.isFinite,
              seconds >= 0, seconds <= duration else { return false }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        publishNowPlaying()
        return true
    }

    /// Mirror AVPlayer.isExternalPlaybackActive into @Published isExternalPlayback
    /// so the UI can show "AirPlaying to <device>" state.
    ///
    /// AVPlayer is KVO-compliant for this key and AVPlayer inherits NSObject,
    /// so a Combine key-path publisher works directly.
    private func observeExternalPlayback(_ player: AVPlayer) {
        player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isExternalPlayback = active
            }
            .store(in: &cancellables)
    }

    private func observeStatus(item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if let p = self.avPlayer, p.rate == 0 {
                        p.rate = 1.0
                    }
                case .failed:
                    log.error("item failed: \(item.error?.localizedDescription ?? "unknown")")
                    // The stream died: don't dead-end at "Failed" (the iOS gap
                    // this ports from macOS) — try to recover: refetch a fresh
                    // URL from the source page if there is one, else retry the
                    // current URL within the shared auto budget. The "no card
                    // for dead audio" rule is enforced by giveUpOnPlayback, the
                    // honest end state the recovery funnels into when it runs
                    // out of attempts.
                    self.handlePlaybackFailure()
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
