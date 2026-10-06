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
            // Player bar: shown only while a stream is playing. Hosts the
            // AirPlay route-picker button so the user can cast the playing
            // stream to a speaker/TV/HomePod.
            if manager.isPlaying {
                PlayerBar(manager: manager)
            }
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

    private var stream: Stream? { manager.currentStream }
    private var isAirPlaying: Bool { manager.player.isExternalPlayback }

    var body: some View {
        HStack(spacing: 12) {
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
            // Native system AirPlay route-picker button (no volume slider).
            AirPlayRoutePickerView(tint: UIColor.label)
                .frame(width: 32, height: 32)
                .accessibilityLabel("AirPlay")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusLine: String {
        if isAirPlaying {
            return "AirPlaying to external device"
        }
        return "Playing"
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
