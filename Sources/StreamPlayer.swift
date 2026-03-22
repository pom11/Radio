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
    var avPlayer: AVPlayer?

    let id = UUID()
    @Published var outputDevice: OutputDevice = .macbook
    var proxyPort: Int?
    var proxyPID: Int?
    var proxyActive: Bool = false

    var isCasting: Bool { outputDevice.proto == .chromecast }
    var isLocal: Bool { outputDevice.proto == .local }

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

        playTask = Task { @MainActor in
            let result = await URLResolver.resolve(stream.url, type: stream.type, pageUrl: stream.pageUrl)
            guard !Task.isCancelled else { return }

            guard let result else {
                statusText = stream.type == .channel ? "Offline" : "Failed"
                isPlaying = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    if self?.statusText == "Offline" || self?.statusText == "Failed" {
                        self?.stop()
                    }
                }
                return
            }

            lastResolveResult = result
            startPlayback(result: result)
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
                    self.reconnect()
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
                statusText = "Stream offline"
                isPlaying = false
                return
            }
            lastResolveResult = result
            startPlayback(result: result)
        }
    }

}
