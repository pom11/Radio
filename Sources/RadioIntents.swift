import AppIntents

// Shared store used by both the app UI and intents
let sharedStore = StreamStore()

// MARK: - Stream Entity (makes streams selectable in Spotlight)

struct StreamEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Stream")
    static var defaultQuery = StreamEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct StreamEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async -> [StreamEntity] {
        let streams = loadStreams()
        return streams
            .filter { identifiers.contains($0.id.uuidString) }
            .map { StreamEntity(id: $0.id.uuidString, name: $0.name) }
    }

    func suggestedEntities() async -> [StreamEntity] {
        loadStreams().map { StreamEntity(id: $0.id.uuidString, name: $0.name) }
    }

    func entities(matching string: String) async -> [StreamEntity] {
        let lower = string.lowercased()
        return loadStreams()
            .filter { $0.name.lowercased().contains(lower) }
            .map { StreamEntity(id: $0.id.uuidString, name: $0.name) }
    }

    func loadStreams() -> [Stream] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/radio/streams.json")
        guard let data = try? Data(contentsOf: url),
              let streams = try? JSONDecoder().decode([Stream].self, from: data) else { return [] }
        return streams
    }
}

// MARK: - Play Stream

struct PlayStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Stream on Radio"
    static var description = IntentDescription("Stream a saved station on Radio")
    static var openAppWhenRun = true

    @Parameter(title: "Stream")
    var stream: StreamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Stream \(\.$stream)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let found = sharedStore.streams.first(where: { $0.id.uuidString == stream.id }) else {
            return .result(dialog: "Stream not found")
        }
        PlayerManager.shared.play(stream: found)
        return .result(dialog: "Playing \(found.name)")
    }
}

// MARK: - Stop

struct StopRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Radio"
    static var description = IntentDescription("Stop all radio playback")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        PlayerManager.shared.stopAll()
        return .result(dialog: "Radio stopped")
    }
}

struct StopStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Stream"
    static var description = IntentDescription("Stop a specific stream")
    static var openAppWhenRun = false

    @Parameter(title: "Stream")
    var stream: StreamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Stop \(\.$stream)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = PlayerManager.shared
        if let player = manager.players.first(where: { $0.currentStream?.id.uuidString == stream.id }) {
            manager.stop(player: player)
            return .result(dialog: "Stopped \(stream.name)")
        }
        return .result(dialog: "\(stream.name) is not playing")
    }
}

// MARK: - Now Playing

struct NowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing on Radio"
    static var description = IntentDescription("Show what's currently playing")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer,
              player.isPlaying, let stream = player.currentStream else {
            return .result(dialog: "Nothing is playing")
        }
        return .result(dialog: "Playing \(stream.name)")
    }
}

// MARK: - Volume

struct VolumeUpIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Up on Radio"
    static var description = IntentDescription("Increase radio volume")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer else {
            return .result(dialog: "Nothing is playing")
        }
        player.adjustVolume(by: 0.1)
        return .result(dialog: "Volume \(Int(player.volume * 100))%")
    }
}

struct VolumeDownIntent: AppIntent {
    static var title: LocalizedStringResource = "Volume Down on Radio"
    static var description = IntentDescription("Decrease radio volume")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer else {
            return .result(dialog: "Nothing is playing")
        }
        player.adjustVolume(by: -0.1)
        return .result(dialog: "Volume \(Int(player.volume * 100))%")
    }
}

// MARK: - Mute

struct MuteRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute Radio"
    static var description = IntentDescription("Mute radio playback")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer else {
            return .result(dialog: "Nothing is playing")
        }
        if !player.isMuted { player.toggleMute() }
        return .result(dialog: "Radio muted")
    }
}

struct UnmuteRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Unmute Radio"
    static var description = IntentDescription("Unmute radio playback")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer else {
            return .result(dialog: "Nothing is playing")
        }
        if player.isMuted { player.toggleMute() }
        return .result(dialog: "Radio unmuted")
    }
}

// MARK: - Pause / Resume

struct PauseRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Radio"
    static var description = IntentDescription("Pause radio playback")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer, player.isPlaying else {
            return .result(dialog: "Nothing is playing")
        }
        player.togglePlayPause()
        return .result(dialog: "Radio paused")
    }
}

struct ResumeRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Radio"
    static var description = IntentDescription("Resume radio playback")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let player = PlayerManager.shared.activePlayer, !player.isPlaying else {
            return .result(dialog: "Nothing to resume")
        }
        player.togglePlayPause()
        return .result(dialog: "Radio resumed")
    }
}

// MARK: - Solo

struct SoloStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Solo Stream"
    static var description = IntentDescription("Solo a stream — mute all others")
    static var openAppWhenRun = false

    @Parameter(title: "Stream")
    var stream: StreamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Solo \(\.$stream)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = PlayerManager.shared
        if let player = manager.players.first(where: { $0.currentStream?.id.uuidString == stream.id }) {
            manager.toggleSolo(player: player)
            return .result(dialog: "Soloing \(stream.name)")
        }
        return .result(dialog: "\(stream.name) is not playing")
    }
}

// MARK: - Show / Hide Video

struct ShowStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Stream"
    static var description = IntentDescription("Show the video window for a stream")
    static var openAppWhenRun = true

    @Parameter(title: "Stream")
    var stream: StreamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$stream)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = PlayerManager.shared
        if let player = manager.players.first(where: { $0.currentStream?.id.uuidString == stream.id }) {
            manager.showVideo(for: player)
            return .result(dialog: "Showing \(stream.name)")
        }
        return .result(dialog: "\(stream.name) is not playing")
    }
}

struct HideStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Hide Stream"
    static var description = IntentDescription("Hide the video window for a stream")
    static var openAppWhenRun = false

    @Parameter(title: "Stream")
    var stream: StreamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Hide \(\.$stream)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = PlayerManager.shared
        if let player = manager.players.first(where: { $0.currentStream?.id.uuidString == stream.id }) {
            manager.hideVideo(for: player)
            return .result(dialog: "Hidden \(stream.name)")
        }
        return .result(dialog: "\(stream.name) is not playing")
    }
}

// MARK: - Fullscreen

struct FullscreenStreamIntent: AppIntent {
    static var title: LocalizedStringResource = "Fullscreen Stream"
    static var description = IntentDescription("Toggle fullscreen for a stream's video window")
    static var openAppWhenRun = true

    @Parameter(title: "Stream")
    var stream: StreamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Fullscreen \(\.$stream)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = PlayerManager.shared
        if let player = manager.players.first(where: { $0.currentStream?.id.uuidString == stream.id }) {
            manager.toggleFullscreen(for: player)
            return .result(dialog: "Toggled fullscreen for \(stream.name)")
        }
        return .result(dialog: "\(stream.name) is not playing")
    }
}

// MARK: - Shortcuts Provider

struct RadioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayStreamIntent(),
            phrases: [
                "Stream \(\.$stream) on \(.applicationName)",
                "Stream \(\.$stream)",
            ],
            shortTitle: "Stream",
            systemImageName: "radio"
        )
        AppShortcut(
            intent: StopStreamIntent(),
            phrases: [
                "Stop \(\.$stream) on \(.applicationName)",
                "Stop \(\.$stream)",
            ],
            shortTitle: "Stop Stream",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: StopRadioIntent(),
            phrases: [
                "Stop \(.applicationName)",
            ],
            shortTitle: "Stop Radio",
            systemImageName: "stop.circle.fill"
        )
        AppShortcut(
            intent: NowPlayingIntent(),
            phrases: [
                "What's playing on \(.applicationName)",
            ],
            shortTitle: "Now Playing",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: [
                "Volume up on \(.applicationName)",
                "\(.applicationName) louder",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.plus.fill"
        )
        AppShortcut(
            intent: VolumeDownIntent(),
            phrases: [
                "Volume down on \(.applicationName)",
                "\(.applicationName) quieter",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.minus.fill"
        )
        AppShortcut(
            intent: MuteRadioIntent(),
            phrases: [
                "Mute \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: UnmuteRadioIntent(),
            phrases: [
                "Unmute \(.applicationName)",
            ],
            shortTitle: "Unmute",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: PauseRadioIntent(),
            phrases: [
                "Pause \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeRadioIntent(),
            phrases: [
                "Resume \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        // Solo, Show, Hide, Fullscreen intents are available in Shortcuts app
        // but excluded from Siri phrases (Apple limits to 10 App Shortcuts)
    }
}
