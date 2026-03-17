import SwiftUI

// MARK: - Platform Favicon

struct PlatformIcon: View {
    let platform: StreamPlatform
    var size: CGFloat = 12

    var body: some View {
        if let domain = platform.faviconDomain,
           let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=32") {
            AsyncImage(url: url) { image in
                image.resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } placeholder: {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        } else {
            Image(systemName: "play.tv.fill")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

struct MenuBarPopover: View {
    @ObservedObject var manager: PlayerManager
    @ObservedObject var store: StreamStore
    let onOpenSettings: () -> Void

    @State private var limitMessage: String?

    private var audioStreams: [Stream] { store.audioStreams }
    private var videoStreams: [Stream] { store.videoStreams }
    private var channelStreams: [Stream] { store.channelStreams }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if !manager.players.isEmpty {
                        nowPlayingSection
                        PopoverDivider()
                    }

                    streamsSection

                    if let msg = limitMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 360)
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        VStack(spacing: 6) {
            if manager.multiStreamEnabled {
                HStack {
                    Text("Now Playing (\(manager.players.count)/\(manager.maxStreams))")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
            }

            ForEach(manager.players, id: \.id) { player in
                let isActive = manager.activePlayer?.id == player.id
                let isExpanded = isActive || manager.players.count == 1

                PlayerControlCard(
                    player: player,
                    manager: manager,
                    style: .popover,
                    isExpanded: isExpanded
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isActive && manager.multiStreamEnabled ? Color.accentColor : .clear, lineWidth: 2)
                )
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    manager.markActive(player: player)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Streams

    private var streamsSection: some View {
        VStack(spacing: 0) {
            ForEach(audioStreams) { stream in streamRow(stream) }
            ForEach(videoStreams) { stream in streamRow(stream) }
            ForEach(StreamPlatform.allCases, id: \.rawValue) { platform in
                let channels = channelsFor(platform)
                ForEach(channels) { stream in streamRow(stream) }
            }
        }
    }

    private func channelsFor(_ platform: StreamPlatform) -> [Stream] {
        switch platform {
        case .youtube: return store.youtubeChannels
        case .twitch: return store.twitchChannels
        case .kick: return store.kickChannels
        case .other: return store.otherChannels
        }
    }

    // MARK: - Stream Row

    private var activeURLs: Set<String> {
        Set(manager.players.compactMap { $0.currentStream?.url })
    }

    private func streamRow(_ stream: Stream) -> some View {
        let active = activeURLs.contains(stream.url)

        return Button {
            if active {
                if let p = manager.players.first(where: { $0.currentStream?.url == stream.url }) {
                    manager.stop(player: p)
                }
                limitMessage = nil
            } else {
                if manager.players.count >= manager.maxStreams {
                    limitMessage = "Max \(manager.maxStreams) streams reached"
                } else {
                    limitMessage = nil
                    manager.play(stream: stream)
                }
            }
        } label: {
            HStack(spacing: 8) {
                if stream.type == .channel && stream.platform != .other {
                    PlatformIcon(platform: stream.platform, size: 14)
                        .frame(width: 16)
                        .opacity(active ? 1.0 : 0.6)
                } else {
                    Image(systemName: streamIcon(stream))
                        .foregroundStyle(active ? .green : .secondary)
                        .frame(width: 16)
                        .font(.caption)
                }

                Text(stream.name)
                    .lineLimit(1)

                Spacer()

                if active {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.green)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(active ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private func streamIcon(_ stream: Stream) -> String {
        switch stream.type {
        case .audio: return "radio"
        case .video: return "video.fill"
        case .channel: return "play.tv.fill"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Divider

    struct PopoverDivider: View {
        var body: some View {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}
