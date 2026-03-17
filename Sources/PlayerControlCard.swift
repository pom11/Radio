import SwiftUI

// MARK: - Card Style

enum ControlCardStyle {
    case popover
    case overlay
    case settings
}

// MARK: - Player Control Card

struct PlayerControlCard: View {
    @ObservedObject var player: StreamPlayer
    @ObservedObject var manager: PlayerManager
    @ObservedObject private var output = OutputManager.shared
    let style: ControlCardStyle
    let isExpanded: Bool
    var controlsVisible: Bool = true

    var body: some View {
        VStack(spacing: style == .settings ? 10 : 7) {
            headerRow
            if isExpanded {
                deviceRow
                volumeRow
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: style == .overlay ? 10 : 8))
    }

    // MARK: - Background

    @ViewBuilder
    private var cardBackground: some View {
        switch style {
        case .overlay:
            Rectangle().fill(Color.black)
        case .popover:
            Rectangle().fill(Color.primary.opacity(0.04))
        case .settings:
            EmptyView()
        }
    }

    // MARK: - Row 1: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: player.isPlaying && controlsVisible)
                .foregroundStyle(player.isPlaying ? .green : .secondary)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentStream?.name ?? "")
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(style == .overlay ? .white : .primary)

            }

            Spacer(minLength: 4)

            if !isExpanded {
                Text(player.outputDevice.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            controlButtons
        }
    }

    private var controlButtons: some View {
        HStack(spacing: isExpanded ? 6 : 5) {
            if isExpanded || style != .overlay {
                Button { manager.toggleVideo(for: player) } label: {
                    let visible = manager.videoWindows[player.id]?.isVisible ?? false
                    Image(systemName: visible ? "rectangle.slash" : "rectangle.inset.filled")
                }
                .help("Show or hide stream window")
            }

            Button { playPauseTapped() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .help("Play or pause")

            if manager.multiStreamEnabled {
                Button { manager.toggleSolo(player: player) } label: {
                    Image(systemName: "person.fill")
                        .foregroundStyle(manager.soloedPlayer?.id == player.id ? .orange : buttonColor)
                }
                .help("Solo — mute all other streams")
            }

            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .help("Mute or unmute")

            Button { manager.stop(player: player) } label: {
                Image(systemName: "stop.fill")
            }
            .help("Stop this stream")
        }
        .buttonStyle(.plain)
        .foregroundStyle(buttonColor)
        .font(.caption)
    }

    private var buttonColor: Color {
        style == .overlay ? .white.opacity(0.85) : .secondary
    }

    // MARK: - Row 2: Device

    private var deviceRow: some View {
        HStack(spacing: 6) {
            Image(systemName: deviceIcon)
                .foregroundStyle(style == .overlay ? .white.opacity(0.4) : .secondary)
                .font(.caption2)
                .frame(width: 14)

            Picker("", selection: Binding(
                get: { player.outputDevice },
                set: { device in manager.changeOutputDevice(for: player, to: device) }
            )) {
                ForEach(output.devices) { device in
                    Text(device.label).tag(device)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: .infinity)

            Button { output.scan() } label: {
                if output.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(style == .overlay ? .white.opacity(0.4) : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(output.isScanning)
            .help("Scan for devices")
        }
    }

    private var deviceIcon: String {
        switch player.outputDevice.proto {
        case .local:
            if player.outputDevice.id == "default" { return "laptopcomputer" }
            switch player.outputDevice.model {
            case "AirPlay": return "airplayaudio"
            case "Bluetooth": return "headphones"
            case "USB": return "cable.connector"
            case "Display": return "display"
            default: return "speaker.wave.2"
            }
        case .chromecast:
            return "tv"
        }
    }

    // MARK: - Row 3: Volume

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(style == .overlay ? .white.opacity(0.4) : .secondary)
                .font(.caption2)
                .frame(width: 14)

            if player.isCasting {
                Slider(
                    value: Binding(
                        get: { Double(output.castVolume) },
                        set: { output.castSetVolume(Int($0), device: player.outputDevice) }
                    ),
                    in: 0...100,
                    step: 5
                )
                .controlSize(style == .settings ? .regular : .small)
            } else {
                Slider(
                    value: Binding(
                        get: { Double(player.volume) },
                        set: { player.setVolume(Float($0)) }
                    ),
                    in: 0...1,
                    step: 0.05
                )
                .controlSize(style == .settings ? .regular : .small)
            }

            Text(volumeLabel)
                .font(.caption2)
                .foregroundStyle(style == .overlay ? .white.opacity(0.45) : .secondary)
                .frame(width: 30, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private var volumeLabel: String {
        if player.isCasting {
            return "\(output.castVolume)%"
        } else {
            return "\(Int(player.volume * 100))%"
        }
    }

    // MARK: - Actions

    private func playPauseTapped() {
        if player.isCasting {
            OutputManager.shared.castPlayPause(device: player.outputDevice)
        } else {
            player.togglePlayPause()
        }
    }
}
