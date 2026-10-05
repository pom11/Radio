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
final class StreamPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var currentStream: Stream?
    @Published var statusText: String = ""
    /// True while AVPlayer is routing audio to an external (AirPlay) destination.
    @Published var isExternalPlayback = false

    private(set) var avPlayer: AVPlayer?
    private var cancellables = Set<AnyCancellable>()
    private var playTask: Task<Void, Never>?
    private var registeredInterruptObserver = false

    /// Resolve a Stream to a playable AVPlayerItem.
    ///
    /// `resolve` is pluggable so a future card can insert full yt-dlp-style
    /// resolution. The default returns the stream's own url — a direct audio/video
    /// stream. The `refuseTainted` guard runs regardless: a pageUrl is never played.
    var resolve: (Stream) async -> String? = { stream in stream.url }

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

        // Trust guard: never play a pageUrl as the playable url.
        if StreamStore.refuseTainted(stream.url, pageUrl: stream.pageUrl) {
            statusText = stream.type == .channel ? "Offline" : "Failed"
            isPlaying = false
            return
        }

        playTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard let resolved = await self.resolve(stream) else {
                self.statusText = "Failed"
                self.isPlaying = false
                return
            }
            guard !Task.isCancelled else { return }
            // Re-check the taint guard on the finally-resolved URL too, so even a
            // resolver that falls back to the source page cannot play it.
            if StreamStore.refuseTainted(resolved, pageUrl: stream.pageUrl) {
                self.statusText = stream.type == .channel ? "Offline" : "Failed"
                self.isPlaying = false
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
        player.play()
        updateStatusText()
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
        statusText = ""
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
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
