import Foundation
import Combine
import MediaPlayer
import os.log

private let log = Logger(subsystem: "ro.pom.radio", category: "manager")

final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published var players: [StreamPlayer] = []
    @Published var activePlayer: StreamPlayer?
    @Published var soloedPlayer: StreamPlayer?

    @Published var multiStreamEnabled: Bool {
        didSet { UserDefaults.standard.set(multiStreamEnabled, forKey: "multiStreamEnabled") }
    }

    var maxStreams: Int {
        get { UserDefaults.standard.object(forKey: "maxStreams") as? Int ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: "maxStreams") }
    }

    var videoWindows: [UUID: VideoWindow] = [:]
    private var savedMuteStates: [UUID: Bool] = [:]
    private var nowPlayingCancellable: AnyCancellable?

    init() {
        multiStreamEnabled = UserDefaults.standard.object(forKey: "multiStreamEnabled") as? Bool ?? false
        setupRemoteCommands()
    }

    // MARK: - Playback

    @discardableResult
    func play(stream: Stream) -> StreamPlayer? {
        let device = OutputManager.shared.defaultDevice
        log.debug("play: \(stream.name) device=\(device.name) proto=\(device.proto.rawValue)")

        // Toggle: if same URL already playing, stop it
        if let existing = players.first(where: { $0.currentStream?.url == stream.url }) {
            log.debug("play: toggling off \(stream.name)")
            stop(player: existing)
            return nil
        }

        // Single-stream mode: stop all before starting new
        if !multiStreamEnabled {
            stopAll()
        }

        guard multiStreamEnabled || players.isEmpty else {
            log.warning("play: blocked — single-stream mode and player exists")
            return nil
        }
        guard players.count < maxStreams else {
            log.warning("play: blocked — at max streams (\(self.maxStreams))")
            return nil
        }

        let player = StreamPlayer()
        player.outputDevice = device

        // Chromecast takeover: if another player uses the same cast device, take it over
        if device.proto == .chromecast {
            handleChromecastTakeover(for: device, excludingPlayer: player)
        }

        players.append(player)
        markActive(player: player)
        player.play(stream)
        return player
    }

    func stop(player: StreamPlayer) {
        // Handle solo cleanup
        if soloedPlayer?.id == player.id {
            unsolo()
        }
        savedMuteStates.removeValue(forKey: player.id)

        // Close video window
        videoWindows[player.id]?.hide()
        videoWindows.removeValue(forKey: player.id)

        // Stop playback
        player.stop()
        players.removeAll { $0.id == player.id }

        // Update active player
        if activePlayer?.id == player.id {
            activePlayer = players.last
            updateNowPlayingSubscription()
        }
    }

    func stopAll() {
        for player in players {
            videoWindows[player.id]?.hide()
            player.stop()
        }
        players.removeAll()
        videoWindows.removeAll()
        savedMuteStates.removeAll()
        soloedPlayer = nil
        activePlayer = nil
        clearNowPlaying()
    }

    // MARK: - Active Player

    func markActive(player: StreamPlayer) {
        guard players.contains(where: { $0.id == player.id }) else { return }
        activePlayer = player
        updateNowPlayingSubscription()
        videoWindows[player.id]?.flashControls()
    }

    func cycleActivePlayer() {
        guard players.count > 1, let current = activePlayer else { return }
        let currentIndex = players.firstIndex(where: { $0.id == current.id }) ?? 0
        let nextIndex = (currentIndex + 1) % players.count
        markActive(player: players[nextIndex])
    }

    // MARK: - Solo

    func solo(player: StreamPlayer) {
        if soloedPlayer != nil {
            unsolo()
        }

        savedMuteStates.removeAll()
        for p in players where p.id != player.id {
            savedMuteStates[p.id] = p.isMuted
            if !p.isMuted { p.toggleMute() }
        }
        soloedPlayer = player
    }

    func unsolo() {
        guard soloedPlayer != nil else { return }

        for p in players {
            if let wasMuted = savedMuteStates[p.id] {
                if p.isMuted != wasMuted {
                    p.toggleMute()
                }
            }
        }
        savedMuteStates.removeAll()
        soloedPlayer = nil
    }

    func toggleSolo(player: StreamPlayer) {
        if soloedPlayer?.id == player.id {
            unsolo()
        } else {
            solo(player: player)
        }
    }

    // MARK: - Separate Controls (global)

    func setSeparateControlsAll(_ value: Bool) {
        for player in players {
            player.setSeparateControls(value)
        }
    }

    // MARK: - Video Windows

    func toggleVideo(for player: StreamPlayer) {
        if let window = videoWindows[player.id], window.isVisible {
            window.hide()
            videoWindows.removeValue(forKey: player.id)
        } else {
            let window = videoWindows[player.id] ?? VideoWindow()
            window.show(player: player)
            videoWindows[player.id] = window
        }
    }

    func toggleAllVideoWindows() {
        let anyVisible = videoWindows.values.contains { $0.isVisible }
        if anyVisible {
            for (_, window) in videoWindows {
                window.hide()
            }
            videoWindows.removeAll()
        } else {
            for player in players {
                // Only create windows for video/channel streams
                let type = player.currentStream?.type
                guard type == .video || type == .channel else { continue }
                let window = VideoWindow()
                window.show(player: player)
                videoWindows[player.id] = window
            }
        }
    }

    func showVideo(for player: StreamPlayer) {
        let window = videoWindows[player.id] ?? VideoWindow()
        window.show(player: player)
        videoWindows[player.id] = window
    }

    func hideVideo(for player: StreamPlayer) {
        videoWindows[player.id]?.hide()
        videoWindows.removeValue(forKey: player.id)
    }

    func toggleVideoFloat(for player: StreamPlayer) {
        videoWindows[player.id]?.toggleFloating()
    }

    func toggleFullscreen(for player: StreamPlayer) {
        if let window = videoWindows[player.id] {
            window.toggleFullscreen()
        }
    }

    // MARK: - Chromecast Takeover

    func handleChromecastTakeover(for device: OutputDevice, excludingPlayer: StreamPlayer) {
        for p in players where p.id != excludingPlayer.id && p.outputDevice.id == device.id && p.isCasting {
            // Stop the cast session and clean up proxy
            OutputManager.shared.castStop(device: device, proxyPort: p.proxyPort)
            p.proxyPort = nil
            p.outputDevice = .macbook
            if let stream = p.currentStream {
                let isVideo = stream.type == .video
                p.play(stream)
                // Open video window for video streams moved to local playback
                if isVideo {
                    let window = VideoWindow()
                    window.show(player: p)
                    videoWindows[p.id] = window
                }
            }
        }
    }

    func changeOutputDevice(for player: StreamPlayer, to device: OutputDevice) {
        let wasPlaying = player.isPlaying
        let currentStream = player.currentStream

        if player.isCasting {
            OutputManager.shared.castStop(device: player.outputDevice, proxyPort: player.proxyPort)
        }

        if device.proto == .chromecast {
            handleChromecastTakeover(for: device, excludingPlayer: player)
        }

        player.outputDevice = device

        if wasPlaying, let stream = currentStream {
            player.stop()
            player.play(stream)
        }
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let player = self?.activePlayer, player.currentStream != nil else {
                return .noActionableNowPlayingItem
            }
            player.avPlayer?.seek(to: .positiveInfinity)
            player.avPlayer?.play()
            player.isPlaying = true
            self?.updateNowPlayingInfo()
            return .success
        }

        center.pauseCommand.addTarget { [weak self] _ in
            self?.activePlayer?.avPlayer?.pause()
            self?.activePlayer?.isPlaying = false
            self?.updateNowPlayingInfo()
            return .success
        }

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.activePlayer?.togglePlayPause()
            self?.updateNowPlayingInfo()
            return .success
        }

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingSubscription() {
        guard let player = activePlayer else {
            clearNowPlaying()
            nowPlayingCancellable = nil
            return
        }

        nowPlayingCancellable = player.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNowPlayingInfo()
            }
    }

    private func updateNowPlayingInfo() {
        guard let player = activePlayer else { return }
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = player.currentStream?.name ?? "Radio"
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
