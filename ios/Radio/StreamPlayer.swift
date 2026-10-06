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

    private(set) var avPlayer: AVPlayer?
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

    /// Play a stream, replacing the current one if any. Exactly one stream plays
    /// at a time.
    func play(_ stream: Stream) {
        stop()
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
            play(stream)
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
            // Item was torn down (e.g. after a failure): start from scratch.
            play(stream)
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
        play(streams[index])
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
                    self.statusText = "Failed"
                    self.isPlaying = false
                    // The stream died: take the card away rather than leaving a
                    // paused entry on the Lock Screen for audio that is gone.
                    self.nowPlaying.clear()
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
