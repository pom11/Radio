import AppKit
import AVFoundation
import Combine
import SwiftUI

extension Notification.Name {
    static let revealVideoControls = Notification.Name("revealVideoControls")
}

// MARK: - Floating Panel (AppKit — required for window behavior)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    weak var videoWindow: VideoWindow?

    var isInFullscreen: Bool {
        styleMask.contains(.fullScreen)
    }

    override func becomeKey() {
        super.becomeKey()
        NotificationCenter.default.post(name: .revealVideoControls, object: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "w":
            // Cmd+W: stop stream + close window (red button behavior)
            if let hosting = contentView as? NSHostingView<VideoWindowRoot> {
                hosting.rootView.manager.stop(player: hosting.rootView.player)
            }
            return true
        case "m":
            // Cmd+M: close window, stream keeps playing (yellow button behavior)
            videoWindow?.hide()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Escape exits fullscreen
        if event.keyCode == 53 && isInFullscreen {
            toggleFullScreen(nil)
            return
        }
        guard let hosting = contentView as? NSHostingView<VideoWindowRoot> else {
            super.keyDown(with: event)
            return
        }
        let handled = hosting.rootView.handleKeyDown(event)
        if !handled { super.keyDown(with: event) }
    }

    func togglePanelFullscreen() {
        if isInFullscreen {
            toggleFullScreen(nil)
        } else {
            collectionBehavior = [.fullScreenPrimary]
            toggleFullScreen(nil)
        }
    }

    /// Hide native traffic light buttons — we use custom SwiftUI ones
    func hideStandardButtons() {
        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(buttonType)?.isHidden = true
        }
    }

}

// MARK: - AVPlayerLayer wrapper

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct AVPlayerLayerContainer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        nsView.playerLayer.player = player
    }
}

// MARK: - Video Window Root (SwiftUI)

struct VideoWindowRoot: View {
    @ObservedObject var player: StreamPlayer
    @ObservedObject var manager: PlayerManager
    let streamIsVideo: Bool  // true if stream type is video/channel or has video track
    weak var panel: FloatingPanel?

    @State private var showControls = false
    @State private var isHovering = false
    @State private var hideTask: Task<Void, Never>?

    /// Reactive: switches to audio-only when casting, even mid-session
    private var isAudioOnly: Bool {
        if player.isCasting { return true }
        return !streamIsVideo
    }

    var body: some View {
        Group {
            if isAudioOnly {
                // Audio-only / cast: just the card, no black background
                PlayerControlCard(
                    player: player,
                    manager: manager,
                    style: .overlay,
                    isExpanded: true
                )
                .frame(width: 400)
            } else {
                // Video: full player with overlay controls
                ZStack {
                    AVPlayerLayerContainer(player: player.avPlayer)
                        .background(Color.black)

                    // Top bar: traffic lights (left) + title (right)
                    VStack {
                        HStack(spacing: 8) {
                            // Traffic light buttons
                            HStack(spacing: 6) {
                                trafficLight(color: .red) {
                                    manager.stop(player: player)
                                }
                                trafficLight(color: .yellow) {
                                    panel?.videoWindow?.hide()
                                }
                                trafficLight(color: .green) {
                                    panel?.togglePanelFullscreen()
                                }
                            }
                            .padding(.leading, 10)
                            Spacer()
                            Text(titleText)
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.8), radius: 4, y: -1)
                                .lineLimit(1)
                                .padding(.trailing, 14)
                        }
                        .padding(.top, 10)
                        .opacity(showControls ? 1 : 0)
                        .animation(.easeInOut(duration: 0.2), value: showControls)
                        Spacer()
                    }

                    // Controls overlay
                    VStack {
                        Spacer()
                        PlayerControlCard(
                            player: player,
                            manager: manager,
                            style: .overlay,
                            isExpanded: true,
                            controlsVisible: showControls
                        )
                        .frame(maxWidth: 360)
                        .opacity(showControls ? 1 : 0)
                        .animation(.easeInOut(duration: showControls ? 0.2 : 0.3), value: showControls)
                        .padding(.bottom, 14)
                    }
                    .padding(.horizontal, 14)
                }
                .onHover { hovering in
                    isHovering = hovering
                    if hovering {
                        revealControls()
                    } else {
                        scheduleHide()
                    }
                }
                .onAppear {
                    revealControls()
                }
                .onReceive(NotificationCenter.default.publisher(for: .revealVideoControls)) { note in
                    if note.object as? FloatingPanel === panel {
                        revealControls()
                    }
                }
            }
        }
        .background(Color.black)
    }

    private func trafficLight(color: Color, action: @escaping () -> Void) -> some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            .onTapGesture(perform: action)
    }

    private var titleText: String {
        player.currentStream?.name ?? ""
    }

    // MARK: - Hover Control

    /// Check if mouse is actually inside the window (more reliable than cached isHovering)
    private func isMouseInsideWindow() -> Bool {
        guard let window = panel else { return false }
        let mouseLocation = NSEvent.mouseLocation
        return window.frame.contains(mouseLocation)
    }

    func revealControls() {
        hideTask?.cancel()
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !isMouseInsideWindow() {
                    isHovering = false
                    showControls = false
                } else {
                    // Mouse still inside — reschedule
                    scheduleHide()
                }
            }
        }
    }

    // MARK: - Keyboard (called from FloatingPanel.keyDown)

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ":
            if player.isCasting {
                OutputManager.shared.castPlayPause(device: player.outputDevice)
            } else {
                player.togglePlayPause()
            }
            revealControls()
            return true
        case "m":
            player.toggleMute()
            revealControls()
            return true
        case "f":
            if let panel = NSApp.keyWindow as? FloatingPanel {
                if panel.level == .floating {
                    panel.level = .normal
                    panel.isFloatingPanel = false
                } else {
                    panel.level = .floating
                    panel.isFloatingPanel = true
                }
            }
            revealControls()
            return true
        case "\t":
            PlayerManager.shared.cycleActivePlayer()
            revealControls()
            return true
        default:
            if event.keyCode == 126 { // Up arrow
                if player.isCasting {
                    OutputManager.shared.castVolumeUp(device: player.outputDevice)
                } else {
                    guard player.separateControls else { return false }
                    player.adjustVolume(by: 0.05)
                }
                revealControls()
                return true
            } else if event.keyCode == 125 { // Down arrow
                if player.isCasting {
                    OutputManager.shared.castVolumeDown(device: player.outputDevice)
                } else {
                    guard player.separateControls else { return false }
                    player.adjustVolume(by: -0.05)
                }
                revealControls()
                return true
            }
            return false
        }
    }
}

// MARK: - VideoWindow manager

final class VideoWindow: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var cancellable: AnyCancellable?
    weak var lastPlayer: StreamPlayer?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else if let player = lastPlayer {
            show(player: player)
        }
    }

    func show(player: StreamPlayer) {
        let streamIsVideo: Bool
        let type = player.currentStream?.type
        if type == .video || type == .channel {
            streamIsVideo = true
        } else {
            let hasVideo = player.avPlayer?.currentItem?.tracks.contains {
                $0.assetTrack?.mediaType == .video
            } ?? false
            streamIsVideo = hasVideo
        }

        let isAudioOnly = player.isCasting || !streamIsVideo

        lastPlayer = player

        if let panel, panel.isVisible {
            let root = VideoWindowRoot(player: player, manager: PlayerManager.shared, streamIsVideo: streamIsVideo, panel: panel)
            panel.contentView = NSHostingView(rootView: root)
            if let hosting = panel.contentView {
                hosting.wantsLayer = true
                hosting.layer?.cornerRadius = 10
                hosting.layer?.masksToBounds = true
            }
            applyPanelMode(panel, audioOnly: isAudioOnly)
            panel.makeKeyAndOrderFront(nil)
            subscribeToCastingChanges(player, streamIsVideo: streamIsVideo)
            return
        }

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.videoWindow = self
        panel.delegate = self
        panel.hideStandardButtons()

        let root = VideoWindowRoot(player: player, manager: PlayerManager.shared, streamIsVideo: streamIsVideo, panel: panel)
        let hostingView = NSHostingView(rootView: root)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

        applyPanelMode(panel, audioOnly: isAudioOnly)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        subscribeToCastingChanges(player, streamIsVideo: streamIsVideo)
    }

    /// Adjust panel size/constraints when switching between video and audio-only modes
    private func applyPanelMode(_ panel: FloatingPanel, audioOnly: Bool) {
        // Exit fullscreen before switching modes
        if panel.isInFullscreen {
            panel.togglePanelFullscreen()
        }

        if audioOnly {
            panel.aspectRatio = NSSize(width: 0, height: 0)
            panel.styleMask = [.borderless, .nonactivatingPanel]
            panel.minSize = NSSize(width: 280, height: 60)
            if let hosting = panel.contentView as? NSHostingView<VideoWindowRoot> {
                let fittingSize = hosting.fittingSize
                panel.setContentSize(fittingSize)
            }
        } else {
            panel.styleMask = [.borderless, .nonactivatingPanel, .resizable]
            panel.aspectRatio = NSSize(width: 16, height: 9)
            panel.minSize = NSSize(width: 320, height: 180)
            let currentSize = panel.frame.size
            if currentSize.width < 320 || currentSize.height < 180 {
                panel.setContentSize(NSSize(width: 480, height: 270))
            }
        }
    }

    /// Watch for casting state changes and adjust panel mode (without recreating the view)
    private func subscribeToCastingChanges(_ player: StreamPlayer, streamIsVideo: Bool) {
        cancellable = player.$outputDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (_: OutputDevice) in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let isAudioOnly = player.isCasting || !streamIsVideo
                self.applyPanelMode(panel, audioOnly: isAudioOnly)
            }
    }

    var isFloating: Bool {
        panel?.level == .floating
    }

    func toggleFloating() {
        guard let panel else { return }
        if panel.level == .floating {
            panel.level = .normal
            panel.isFloatingPanel = false
        } else {
            panel.level = .floating
            panel.isFloatingPanel = true
        }
    }

    func toggleFullscreen() {
        panel?.togglePanelFullscreen()
    }

    func flashControls() {
        guard let panel else { return }
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        panel?.hideStandardButtons()
        panel?.contentView?.layer?.cornerRadius = 0
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let panel else { return }
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hideStandardButtons()
        panel.contentView?.layer?.cornerRadius = 10
    }

    func hide() {
        cancellable = nil
        if let panel, panel.isInFullscreen {
            panel.togglePanelFullscreen()
        }
        panel?.contentView = nil
        panel?.close()
    }
}
