import AVFoundation
import Combine
import os.log

private let log = Logger(subsystem: "ro.pom.radio", category: "player")

final class StreamPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var isMuted = false
    @Published var currentStream: Stream?
    @Published var volume: Float = 0.5
    @Published var separateControls: Bool = true
    @Published var statusText: String = ""
    @Published private(set) var isRefreshing = false
    var avPlayer: AVPlayer?

    let id = UUID()
    @Published var outputDevice: OutputDevice = .macbook
    var proxyPort: Int?
    var proxyPID: Int?
    var proxyActive: Bool = false

    var isCasting: Bool { outputDevice.proto == .chromecast }
    var isLocal: Bool { outputDevice.proto == .local }

    /// Called when a refreshed stream URL is available, so the owner can persist it
    /// (see StreamStore.applyRefreshedURL). Receives a Stream preserving id/name/type/pageUrl
    /// with the freshly resolved url/referer/headers.
    var onRefreshStream: ((Stream) -> Void)?

    // MARK: - Refresh-from-source state

    private static let maxAutoRefreshAttempts = 3
    private static let refreshBackoffBase: TimeInterval = 10

    /// True if a resolved URL is a genuine playable http(s) stream — as opposed
    /// to a resolver fallback that returned the source page itself. Only such a
    /// URL should ever be persisted as a stream's playable url.
    static func isGenuineStreamURL(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
    }

    /// Lightweight liveness probe for a resolved stream URL that isn't a literal
    /// .m3u8/.mpd manifest (e.g. a .php proxy from a rotated server list that
    /// could be dead). Performs a short GET (a HEAD has no body, so it can't
    /// detect the 0-byte dead-proxy case) with a tight timeout so refresh adds
    /// minimal latency; on any error/timeout it returns false and the caller
    /// keeps the existing saved URL ("Refresh failed").
    static func verifyStreamURL(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            // A dead proxy answers 200 with a 0-byte body — not a playable stream.
            // Any non-empty 2xx body is treated as verified (a real HLS proxy
            // serves the manifest body even if it's typed text/html).
            return !data.isEmpty
        } catch {
            return false
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var refreshRetryTask: DispatchWorkItem?
    private var autoRefreshAttempts = 0

    private var previousVolume: Float = 0.5
    private var cancellables = Set<AnyCancellable>()
    private var reconnectTask: DispatchWorkItem?
    private var nudgeTask: DispatchWorkItem?
    private var playTask: Task<Void, Never>?
    private var lastResolveResult: ResolveResult?
    private var volumeSaveTask: DispatchWorkItem?
    private var headerProxy: HeaderProxy?
    private var useHeaderProxyFallback: Bool = false

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        volume = defaults.object(forKey: "playerVolume") as? Float ?? 0.5
        separateControls = defaults.object(forKey: "separateControls") as? Bool ?? true
        previousVolume = volume
    }

    deinit {
        playTask?.cancel()
        refreshTask?.cancel()
        refreshRetryTask?.cancel()
        reconnectTask?.cancel()
        cancellables.removeAll()
        avPlayer?.pause()
    }

    func play(_ stream: Stream) {
        log.info("play() called: \(stream.name) url=\(stream.url) type=\(stream.type.rawValue)")
        stop()
        currentStream = stream
        let savedVolume = UserDefaults.standard.object(forKey: "playerVolume_\(stream.url)") as? Float
        if let saved = savedVolume {
            volume = saved
            previousVolume = saved > 0 ? saved : previousVolume
        }
        isPlaying = true
        statusText = "Connecting..."

        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await URLResolver.resolve(stream.url, type: stream.type, pageUrl: stream.pageUrl)
            guard !Task.isCancelled else { return }

            guard let result else {
                self.statusText = stream.type == .channel ? "Offline" : "Failed"
                self.isPlaying = false
                // The stream URL could not be resolved — if it has a source page, try
                // to refetch a fresh URL from it.
                if stream.pageUrl != nil {
                    _ = self.refreshFromSource(stream, manual: false)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.statusText == "Offline" || self?.statusText == "Failed" {
                        self?.stop()
                    }
                }
                return
            }

            self.lastResolveResult = result
            self.startPlayback(result: result)
        }
    }

    private func startPlayback(result: ResolveResult) {
        // Chromecast: use cast_url (original YouTube URL, DASH manifest, etc.)
        if isCasting {
            // If we have a youtube_id, build a proper watch URL for casting
            let castURL: String
            if let ytId = result.youtube_id, !ytId.isEmpty {
                castURL = "https://www.youtube.com/watch?v=\(ytId)"
            } else {
                castURL = result.cast_url ?? result.url
            }
            var castHeaders: [String: String] = currentStream?.headers ?? [:]
            if let referer = currentStream?.referer {
                castHeaders["Referer"] = referer
            }
            if proxyPort == nil {
                proxyPort = OutputManager.shared.allocateProxyPort()
            }
            OutputManager.shared.castURL(castURL, device: outputDevice, proxyPort: proxyPort!, headers: castHeaders) {
            }
            updateStatusText()
            return
        }

        // Local playback: use resolved URL (HLS preferred)
        guard let url = URL(string: result.url) else {
            statusText = "Invalid URL"
            isPlaying = false
            return
        }

        log.debug("startPlayback url=\(result.url) is_live=\(result.is_live) format=\(result.format)")

        // Build custom headers if needed
        headerProxy?.stop()
        headerProxy = nil
        var playbackURL = url
        var assetOptions: [String: Any] = [:]

        if let stream = currentStream {
            var httpHeaders: [String: String] = stream.headers ?? [:]
            if let referer = stream.referer {
                httpHeaders["Referer"] = referer
            }
            if !httpHeaders.isEmpty {
                let isHLS = result.url.hasSuffix(".m3u8") || result.url.contains(".m3u8?") || result.format == "hls"
                if isHLS || useHeaderProxyFallback {
                    // HLS needs headers on every sub-request (segments, variant playlists).
                    // AVURLAssetHTTPHeaderFieldsKey only covers the initial manifest.
                    let proxy = HeaderProxy(targetURL: url, headers: httpHeaders)
                    if let proxyBase = proxy.start() {
                        let path = url.path
                        let query = url.query.map { "?\($0)" } ?? ""
                        playbackURL = URL(string: proxyBase.absoluteString + path + query) ?? url
                        headerProxy = proxy
                        log.info("Using header proxy for \(url.host() ?? "")")
                    }
                } else {
                    // Non-HLS: native AVURLAsset header injection (zero overhead)
                    assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = httpHeaders
                    log.debug("Using native header injection for \(url.host() ?? "")")
                }
            }
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: playbackURL, options: assetOptions))

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = separateControls ? volume : 1.0
        if isMuted { newPlayer.volume = 0; newPlayer.isMuted = true }

        // Live streams: tune buffer based on stream type
        if result.is_live {
            if headerProxy != nil {
                item.preferredForwardBufferDuration = 30
            } else {
                item.preferredForwardBufferDuration = 5
            }
            newPlayer.automaticallyWaitsToMinimizeStalling = false
        }

        // Route audio to selected output device (AirPlay, Bluetooth, etc.)
        if isLocal && outputDevice.id != "default" {
            newPlayer.audioOutputDeviceUniqueID = outputDevice.id
        }

        avPlayer = newPlayer

        observeStatus(item: item)

        newPlayer.play()

        updateStatusText()
    }

    var onStop: (() -> Void)?

    func stop() {
        playTask?.cancel()
        playTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
        autoRefreshAttempts = 0
        isRefreshing = false
        reconnectTask?.cancel()
        reconnectTask = nil
        nudgeTask?.cancel()
        nudgeTask = nil
        volumeSaveTask?.cancel()
        volumeSaveTask = nil
        cancellables.removeAll()
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil

        headerProxy?.stop()
        headerProxy = nil
        useHeaderProxyFallback = false
        let port = proxyPort
        if isCasting { OutputManager.shared.castStop(device: outputDevice, proxyPort: port) }
        proxyPort = nil

        onStop?()

        currentStream = nil
        isPlaying = false
        lastResolveResult = nil
        statusText = ""
    }

    func toggle(_ stream: Stream) {
        if currentStream?.id == stream.id && isPlaying {
            stop()
        } else {
            play(stream)
        }
    }

    func togglePlayPause() {
        if isPlaying {
            avPlayer?.pause()
            isPlaying = false
        } else {
            avPlayer?.seek(to: .positiveInfinity)
            avPlayer?.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            volume = previousVolume > 0 ? previousVolume : 0.5
            avPlayer?.volume = separateControls ? volume : 1.0
            avPlayer?.isMuted = false
        } else {
            previousVolume = volume > 0 ? volume : previousVolume
            isMuted = true
            volume = 0
            avPlayer?.volume = 0
            avPlayer?.isMuted = true
        }
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        volumeSaveTask?.cancel()
        if let url = currentStream?.url {
            let task = DispatchWorkItem {
                UserDefaults.standard.set(clamped, forKey: "playerVolume_\(url)")
            }
            volumeSaveTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
        }

        if clamped > 0 {
            previousVolume = clamped
            isMuted = false
        } else {
            isMuted = true
        }

        if separateControls {
            avPlayer?.volume = clamped
        }
    }

    func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    func setSeparateControls(_ value: Bool) {
        separateControls = value
        UserDefaults.standard.set(value, forKey: "separateControls")
        if value {
            avPlayer?.volume = isMuted ? 0 : volume
        } else {
            avPlayer?.volume = 1.0
            avPlayer?.isMuted = isMuted
        }
    }

    // MARK: - Refresh from source

    /// Re-fetch a fresh playable URL from the stream's source page (pageUrl).
    /// - `manual`: true for the user-triggered "Refresh" control (unbounded budget);
    ///   false for automatic refetch on playback failure (bounded by `autoRefreshAttempts`).
    /// - Returns true if a refresh was kicked off, false if it cannot run (no pageUrl,
    ///   already refreshing, or auto budget exhausted).
    @discardableResult
    func refreshFromSource(_ stream: Stream, manual: Bool) -> Bool {
        guard stream.pageUrl != nil else {
            if manual {
                statusText = "No source page to refetch from"
                log.info("refreshFromSource: \(stream.name) has no pageUrl; cannot refresh")
            }
            return false
        }
        guard refreshTask == nil && !isRefreshing else {
            log.debug("refreshFromSource: already refreshing \(stream.name)")
            return false
        }

        if !manual {
            guard autoRefreshAttempts < Self.maxAutoRefreshAttempts else {
                statusText = "Auto-refresh exhausted"
                log.info("refreshFromSource: auto budget exhausted for \(stream.name)")
                return false
            }
            autoRefreshAttempts += 1
        }

        let pageUrl = stream.pageUrl!
        let streamType = stream.type

        isRefreshing = true
        statusText = "Re-fetching from source..."

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await URLResolver.resolve(pageUrl, type: streamType)
            self.refreshTask = nil
            self.isRefreshing = false
            guard !Task.isCancelled else { return }

            guard let result else {
                self.statusText = "Refresh failed"
                log.error("refreshFromSource: resolve failed for \(stream.name) from \(pageUrl)")
                if !manual {
                    self.scheduleRefreshRetry(stream)
                }
                return
            }

            // Only persist a genuinely resolved playable URL. The source page
            // itself (pageUrl) is NOT a playable stream: if the resolver fell
            // through and returned the page as the "resolved" URL (its last
            // resort), treat it as a failure — keep the previously working URL
            // and surface "Refresh failed" instead of overwriting it with a dead
            // page URL (that taint was observed in the user's config). For
            // non-literal-manifest URLs (.php proxies from a rotated server
            // list) also require the resolved URL to verify as a live stream,
            // so a dead proxy never clobbers a working saved URL either.
            let literalManifest = result.url.contains(".m3u8") || result.url.contains(".mpd")
            let verified: Bool
            if literalManifest {
                verified = true
            } else {
                verified = await StreamPlayer.verifyStreamURL(result.url)
            }
            guard StreamPlayer.isGenuineStreamURL(result.url),
                  result.url != pageUrl,
                  verified else {
                self.statusText = "Refresh failed"
                log.error("refreshFromSource: \(stream.name) resolved to unverifiable URL \(result.url); keeping existing url")
                if !manual {
                    self.scheduleRefreshRetry(stream)
                }
                return
            }

            // Success: persist the fresh URL (keep referer/headers semantics — the
            // source page is still valid, so its referer is preserved). Restart playback
            // so the refreshed URL actually drives the player.
            var refreshed = stream
            refreshed.url = result.url
            log.info("refreshFromSource: \(stream.name) refreshed → \(result.url)")
            self.onRefreshStream?(refreshed)

            if let current = self.currentStream, current.id == stream.id {
                self.play(refreshed)
            }
        }
        return true
    }

    /// Schedule a retry of an automatic (failed) refresh with exponential-ish backoff.
    private func scheduleRefreshRetry(_ stream: Stream) {
        refreshRetryTask?.cancel()
        let backoff = autoRefreshAttempts > 1
            ? Self.refreshBackoffBase * Double(autoRefreshAttempts)
            : Self.refreshBackoffBase
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshRetryTask = nil
            // Only retry if this stream is still what we're playing.
            guard self.currentStream?.id == stream.id else { return }
            _ = self.refreshFromSource(stream, manual: false)
        }
        refreshRetryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: task)
    }

    /// Route a playback failure: if the stream has a source page, auto-refresh from it;
    /// otherwise fall back to the plain reconnect path.
    private func handlePlaybackFailure() {
        guard let stream = currentStream, stream.pageUrl != nil else {
            reconnect()
            return
        }
        let started = refreshFromSource(stream, manual: false)
        if !started {
            reconnect()
        }
    }

    // MARK: - Status Text

    private func updateStatusText() {
        statusText = currentStream?.name ?? ""
    }

    // MARK: - Auto-reconnect

    private func observeStatus(item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if let p = self.avPlayer, p.rate == 0 {
                        p.rate = 1.0
                        log.debug("forced rate=1.0")
                    }
                case .failed:
                    log.error("item failed: \(item?.error?.localizedDescription ?? "unknown")")
                    // If native headers failed, retry with proxy fallback
                    let hasHeaders = (self.currentStream?.headers != nil || self.currentStream?.referer != nil)
                    if hasHeaders && !self.useHeaderProxyFallback,
                       let result = self.lastResolveResult {
                        self.useHeaderProxyFallback = true
                        self.statusText = "Retrying with proxy..."
                        log.info("Native headers failed, falling back to HeaderProxy")
                        self.cancellables.removeAll()
                        self.avPlayer?.pause()
                        self.avPlayer = nil
                        self.startPlayback(result: result)
                        return
                    }
                    // Hard failure: if the stream has a source page, auto-refresh it;
                    // otherwise just reconnect.
                    self.handlePlaybackFailure()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        avPlayer?.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .paused where self.isPlaying,
                     .waitingToPlayAtSpecifiedRate where self.isPlaying:
                    if self.headerProxy != nil {
                        // Proxied streams on flaky CDNs: nudge rate every 3s to
                        // help AVPlayer resume. Full reconnect only after 30s.
                        self.startNudging()
                        self.scheduleReconnect(delay: 30)
                    } else {
                        let delay: TimeInterval = (status == .paused) ? 8 : 20
                        self.scheduleReconnect(delay: delay)
                    }
                case .playing:
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                    self.nudgeTask?.cancel()
                    self.nudgeTask = nil
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func startNudging() {
        guard nudgeTask == nil else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying else { return }
            self.nudgeTask = nil
            if self.avPlayer?.timeControlStatus != .playing {
                self.avPlayer?.rate = 1.0
                self.startNudging()
            }
        }
        nudgeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: task)
    }

    private func scheduleReconnect(delay: TimeInterval) {
        reconnectTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.isPlaying,
                  self.avPlayer?.timeControlStatus != .playing else { return }
            self.reconnect()
        }
        reconnectTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func reconnect() {
        guard let stream = currentStream else { return }
        playTask?.cancel()
        reconnectTask?.cancel()
        cancellables.removeAll()
        avPlayer?.pause()
        avPlayer = nil

        statusText = "Reconnecting..."

        // Reuse cached resolve result first (avoids expensive yt-dlp call)
        if let cached = lastResolveResult {
            startPlayback(result: cached)
            return
        }

        playTask = Task { @MainActor in
            let result = await URLResolver.resolve(stream.url, type: stream.type, pageUrl: stream.pageUrl)
            guard !Task.isCancelled else { return }
            guard let result else {
                self.statusText = "Stream offline"
                self.isPlaying = false
                // Source page still up? Refetch a fresh URL from it.
                if stream.pageUrl != nil {
                    _ = self.refreshFromSource(stream, manual: false)
                }
                return
            }
            self.lastResolveResult = result
            self.startPlayback(result: result)
        }
    }

}
