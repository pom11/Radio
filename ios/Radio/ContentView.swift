import SwiftUI

/// Basic stream list UI. Each row taps into the single shared player — playing a
/// new stream replaces the current one (exactly one playing at a time).
struct ContentView: View {
    @ObservedObject var store: StreamStore
    @ObservedObject var manager: PlayerManager
    @State private var showAddSheet = false
    @State private var showScanner = false
    @State private var bannerText: String?
    @State private var bannerFailed = false
    /// Non-nil presents an SFSafariViewController over that URL — the "Open in
    /// Browser" fallback for a channel the app can't play in-app.
    @State private var safariURL: URL?
    /// Tracks the player's current open-in-browser offer so we can prompt.
    @State private var offeredOpenInBrowser: URL?

    var body: some View {
        NavigationStack {
            List {
                if store.streams.isEmpty {
                    // iOS 16-compatible empty state (ContentUnavailableView is iOS 17+)
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No Streams")
                            .font(.headline)
                        Text("Add one via a radio:// link, or tap + to enter it manually.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(store.streams) { stream in
                        StreamRow(stream: stream, manager: manager) {
                            openInBrowser(stream)
                        }
                        .onTapGesture {
                            manager.play(stream: stream)
                        }
                    }
                    .onDelete { indexSet in
                        let toDelete = indexSet.compactMap { store.streams.indices.contains($0) ? store.streams[$0] : nil }
                        for s in toDelete { store.delete(s) }
                    }
                }
            }
            .navigationTitle("Radio")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    // Stable hook for the UI test that drives add → play →
                    // picture; never localize or rename it.
                    .accessibilityIdentifier("addStreamButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .accessibilityLabel("Scan QR")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddStreamSheet(store: store)
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScanView { scanned in
                    handleScanned(scanned)
                }
            }
            .overlay(alignment: .top) {
                if let bannerText {
                    HStack(spacing: 8) {
                        Image(systemName: bannerFailed ? "xmark.circle" : "checkmark.circle")
                        Text(bannerText)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        // Auto-dismiss the banner after a moment.
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation { self.bannerText = nil }
                        }
                    }
                }
            }
            .animation(.default, value: bannerText)
        }
        .safeAreaInset(edge: .bottom) {
            bottomDock
        }
        // "Open in Browser" fallback: present the channel page in Safari.
        .sheet(isPresented: .init(get: {
            safariURL != nil
        }, set: { showing in
            if !showing { safariURL = nil }
        })) {
            if let safariURL {
                SafariView(url: safariURL)
            }
        }
        // When a channel can't resolve to a playable URL in-app, the player sets
        // openInBrowserURL — prompt the user with a clear "Open in Browser"
        // affordance instead of leaving them with a dead "Failed".
        .onChange(of: manager.player.openInBrowserURL) {
            let newURL = manager.player.openInBrowserURL
            guard let newURL else { offeredOpenInBrowser = nil; return }
            // Only prompt once per URL (dismissing then tapping again re-offs it).
            if offeredOpenInBrowser == nil {
                offeredOpenInBrowser = newURL
            }
        }
        .alert("This channel can\u{2019}t play in-app", isPresented: .init(get: {
            offeredOpenInBrowser != nil
        }, set: { showing in
            if !showing { offeredOpenInBrowser = nil }
        })) {
            Button("Open in Browser") {
                safariURL = offeredOpenInBrowser
                offeredOpenInBrowser = nil
            }
            Button("Cancel", role: .cancel) {
                offeredOpenInBrowser = nil
            }
        } message: {
            Text("The stream couldn\u{2019}t be resolved to a playable URL. Open its page in Safari to watch the live stream (note: playback stays in the browser, not in the app).")
        }
    }

    /// Bottom of the screen: the picture (only for a `.video` stream) docked
    /// directly above the player bar, so transport stays reachable while a
    /// video plays (card requirement — and the panel can cover the row that
    /// started playback, so the bar itself carries Pause AND Stop in that mode).
    /// For an `.audio` stream this is exactly the player bar it always was; the
    /// video branch cannot be entered without `stream.type == .video`.
    ///
    /// Docked rather than a modal sheet: a sheet would cover the list, so the
    /// user could not switch to another stream without dismissing the video
    /// first.
    @ViewBuilder
    private var bottomDock: some View {
        VStack(spacing: 0) {
            if VideoSurfacePolicy.shouldShow(
                currentStream: manager.currentStream,
                hasPlayer: manager.player.avPlayer != nil
            ) {
                VideoPanel(manager: manager)
                PlayerBar(manager: manager, showsTransport: true)
            } else if manager.isPlaying {
                PlayerBar(manager: manager)
            } else if manager.isFailed {
                // The stream played and died for good (recovery budget spent).
                // The bar MUST stay here: this is the one state where the user
                // needs it most — it carries the honest "Failed" line, a Play
                // that retries from scratch with a fresh budget, Stop to clear
                // it, and the Refresh button when the stream has a source page.
                // (`isPlaying` alone can't express this: a paused stream is
                // also not playing, and the audio bar has always hidden itself
                // on pause — this keeps that behaviour byte-identical.)
                PlayerBar(manager: manager, showsTransport: true)
            }
        }
    }

    /// Hand the user off to Safari for a channel they can't play in-app.
    /// Prefers the channel's explicit `pageUrl`, falling back to its url.
    private func openInBrowser(_ stream: Stream) {
        guard let url = browserURL(for: stream) else { return }
        safariURL = url
    }

    /// The URL to open for a stream's "Open in Browser" affordance: `pageUrl`
    /// if set, else the stream url — but only if it's a real http(s) page.
    private func browserURL(for stream: Stream) -> URL? {
        let page = stream.pageUrl ?? stream.url
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return URL(string: trimmed)
    }

    /// Ingest a decoded QR string the same way any radio://add deep link is
    /// handled, then surface a truthful banner. Reuses DeepLinkHandler (trust
    /// guard + update/append semantics), so scanning is indistinguishable
    /// from receiving the deep link via onOpenURL.
    private func handleScanned(_ raw: String) {
        let outcome = DeepLinkHandler(store: store).handle(string: raw)
        switch outcome {
        case .added:
            bannerText = "Stream added"
            bannerFailed = false
        case .updated:
            bannerText = "Stream updated"
            bannerFailed = false
        case .ignored:
            bannerText = "Not a valid radio:// link"
            bannerFailed = true
        }
    }
}

/// Bottom bar with the currently-playing stream, the native AirPlay route
/// picker, and an "AirPlaying" indicator when routing externally.
private struct PlayerBar: View {
    @ObservedObject var manager: PlayerManager
    /// Whether to show the transport controls (play/pause + stop). True only
    /// while the video panel is on screen: the audio-only bar has always been
    /// name + AirPlay only (stop lived on the row), and this card's rule is that
    /// pause AND stop stay reachable *while video is shown*. Keeping the flag
    /// off for `.audio` means the audio bar is literally unchanged.
    var showsTransport: Bool = false

    private var stream: Stream? { manager.currentStream }
    private var isAirPlaying: Bool { manager.player.isExternalPlayback }

    var body: some View {
        HStack(spacing: 12) {
            if showsTransport {
                // The docked picture covers part of the list, so the row that
                // started playback may be scrolled out from under the panel —
                // stop therefore has to live HERE, not only on the row. Both
                // buttons go through the same paths the Lock Screen uses
                // (NowPlayingCommandDelegate / PlayerManager.stop), so pause and
                // stop keep isPlaying, statusText and the now-playing card in
                // step instead of only changing the picture.
                Button {
                    manager.player.nowPlayingTogglePlayback()
                } label: {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel(manager.isPlaying ? "Pause" : "Play")

                Button {
                    manager.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Stop")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stream?.name ?? "")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // Manual refetch-from-source (port of the macOS Refresh button in
            // PlayerControlCard). Shown only when a refresh is even possible —
            // the machine's `canRefresh` rule, so the bar never offers a button
            // that would just refuse. Taps are deliberately unbounded (the
            // budget only caps *automatic* refetches); while one is in flight
            // the button is a spinner, mirroring macOS.
            if let stream, RefetchMachine.canRefresh(stream) {
                Button {
                    manager.player.refreshFromSource(stream, manual: true)
                } label: {
                    if manager.player.isRefreshing {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .frame(width: 32, height: 32)
                    }
                }
                .disabled(manager.player.isRefreshing)
                .accessibilityLabel(manager.player.isRefreshing ? "Refreshing" : "Refresh")
                // Stable hook for RefetchUITests — never rename it.
                .accessibilityIdentifier("refreshStreamButton")
            }
            // Native system AirPlay route-picker button (no volume slider).
            AirPlayRoutePickerView(tint: UIColor.label)
                .frame(width: 32, height: 32)
                .accessibilityLabel("AirPlay")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        // Stable hook: the audio-path test asserts THIS is up (playback really
        // started) while no video panel is — a bar it can see rather than an
        // internal flag.
        .accessibilityIdentifier("playerBar")
    }

    private var statusLine: String {
        if isAirPlaying {
            return "AirPlaying to external device"
        }
        // The failed bar must tell the truth, not "Playing": the stream is gone
        // and statusText carries the real state ("Failed", "Open in browser").
        if manager.player.isFailed {
            return manager.player.statusText
        }
        // A manual refetch in flight is visible here too, next to the spinner.
        if manager.player.isRefreshing {
            return manager.player.statusText
        }
        return "Playing"
    }
}

/// The docked picture for a `.video` stream.
///
/// Size: 16:9 (`VideoSurfacePolicy.aspectRatio`) full-bleed width. AVPlayerLayer
/// with `.resizeAspect` letterboxes anything else inside that box rather than
/// cropping it, which is what you want for a mix of stream aspect ratios.
///
/// The surface is re-pointed at `manager.player.avPlayer` on every update, so a
/// new stream swaps the picture and a stop takes it away (player becomes nil →
/// plain black, never a frozen frame of the stream that just ended).
private struct VideoPanel: View {
    @ObservedObject var manager: PlayerManager

    var body: some View {
        VideoSurface(player: manager.player.avPlayer,
                     label: "Video for \(manager.currentStream?.name ?? "stream")")
            .aspectRatio(VideoSurfacePolicy.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
    }
}

struct StreamRow: View {
    let stream: Stream
    @ObservedObject var manager: PlayerManager
    /// Called when the user chooses "Open in Browser" from the context menu.
    /// Only offered for `.channel` streams (which may not resolve in-app).
    var onOpenInBrowser: () -> Void

    private var isCurrent: Bool { manager.currentStream?.id == stream.id }
    private var isPlaying: Bool { isCurrent && manager.isPlaying }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stream.name)
                    .font(.body)
                    .lineLimit(1)
                Text(stream.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.tint)
            } else if isCurrent {
                Image(systemName: "pause.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // Channels can't always be played in-app (YouTube/Twitch/Kick streams
        // are signed/DRM'd). Always offer long-press → "Open in Browser" so the
        // user has an escape hatch regardless of whether resolution succeeded.
        .contextMenu {
            if stream.type == .channel, let page = browserPage, !page.isEmpty {
                Button {
                    onOpenInBrowser()
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
        }
    }

    /// The page this stream should open in the browser for `pageUrl ?? url`.
    private var browserPage: String? {
        let page = stream.pageUrl ?? stream.url
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return trimmed
    }
}
