import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Sidebar Sections

enum SidebarSection: String, CaseIterable, Identifiable {
    case nowPlaying = "Now Playing"
    case streams = "Streams"
    case output = "Output"
    case general = "General"
    case hotkeys = "Hotkeys"
    case extensions = "Extensions"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .nowPlaying: return "waveform"
        case .streams: return "radio"
        case .output: return "speaker.wave.2"
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
        case .extensions: return "puzzlepiece.extension"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Main Radio View

struct RadioView: View {
    @ObservedObject var manager: PlayerManager
    @ObservedObject var store: StreamStore

    @State private var selectedSection: SidebarSection = .nowPlaying
    @State private var showAddSheet = false
    @State private var showQuickPlaySheet = false
    @State private var editingStream: Stream?

    var body: some View {
        NavigationSplitView {
            sidebarContent
        } detail: {
            detailContent
        }
        .sheet(isPresented: $showAddSheet) {
            AddStreamSheet(store: store)
        }
        .sheet(isPresented: $showQuickPlaySheet) {
            QuickPlaySheet(manager: manager)
        }
        .sheet(item: $editingStream) { stream in
            EditStreamSheet(store: store, stream: stream)
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        List(SidebarSection.allCases, selection: $selectedSection) { section in
            sidebarRow(section)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                }
                .help("Add a new stream to your library")

                Button { showQuickPlaySheet = true } label: {
                    Image(systemName: "play.fill")
                }
                .help("Quick play a URL without saving it")

                if !manager.players.isEmpty {
                    Button { manager.stopAll() } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop all playing streams")
                }
            }
        }
    }

    private func sidebarRow(_ section: SidebarSection) -> some View {
        Label {
            HStack {
                Text(section.rawValue)
                if section == .nowPlaying && !manager.players.isEmpty {
                    Spacer()
                    Text("\(manager.players.count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green, in: Capsule())
                }
            }
        } icon: {
            Image(systemName: section.icon)
        }
        .tag(section)
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection {
        case .nowPlaying:
            NowPlayingDetail(manager: manager)
        case .streams:
            StreamsDetail(manager: manager, store: store, editingStream: $editingStream)
        case .output:
            OutputDetail()
        case .general:
            GeneralDetail(manager: manager, store: store)
        case .hotkeys:
            HotkeysDetail()
        case .extensions:
            ExtensionsDetail()
        case .about:
            AboutDetail()
        }
    }
}

// MARK: - Now Playing Detail

struct NowPlayingDetail: View {
    @ObservedObject var manager: PlayerManager

    var body: some View {
        Group {
            if manager.players.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Playing", systemImage: "waveform")
                } description: {
                    Text("Select a stream to start playback.")
                }
            } else {
                Form {
                    if manager.multiStreamEnabled {
                        Section {
                            Text("Active streams with independent controls. Click a card to make it the active target for hotkeys.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("Now Playing (\(manager.players.count)/\(manager.maxStreams))")
                        }
                    }

                    ForEach(manager.players, id: \.id) { player in
                        let isActive = manager.activePlayer?.id == player.id
                        let isExpanded = isActive || manager.players.count == 1

                        Section {
                            PlayerControlCard(
                                player: player,
                                manager: manager,
                                style: .settings,
                                isExpanded: isExpanded
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                manager.markActive(player: player)
                            }
                            .overlay(alignment: .leading) {
                                if isActive && manager.multiStreamEnabled {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.accentColor)
                                        .frame(width: 3)
                                        .offset(x: -16)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Now Playing")
    }
}

// MARK: - Streams Detail

struct StreamsDetail: View {
    @ObservedObject var manager: PlayerManager
    @ObservedObject var store: StreamStore
    @Binding var editingStream: Stream?

    private var audioStreams: [Stream] { store.audioStreams }
    private var videoStreams: [Stream] { store.videoStreams }
    private var channelStreams: [Stream] { store.channelStreams }

    var body: some View {
        Form {
            Section {
                Text("Click a stream to start or stop playback. Right-click for more options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !audioStreams.isEmpty {
                Section {
                    ForEach(audioStreams) { stream in
                        streamRow(stream)
                    }
                } header: {
                    Label("Audio", systemImage: "radio")
                }
            }

            if !videoStreams.isEmpty {
                Section {
                    ForEach(videoStreams) { stream in
                        streamRow(stream)
                    }
                } header: {
                    Label("Video", systemImage: "video.fill")
                }
            }

            ForEach(StreamPlatform.allCases, id: \.rawValue) { platform in
                let channels = channelsFor(platform)
                if !channels.isEmpty {
                    Section {
                        ForEach(channels) { stream in
                            streamRow(stream)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            PlatformIcon(platform: platform, size: 14)
                            Text(platform.label)
                        }
                    }
                }
            }

            if store.streams.isEmpty {
                ContentUnavailableView {
                    Label("No Streams", systemImage: "radio")
                } description: {
                    Text("Add streams using the + button in the sidebar or edit ~/.config/radio/streams.json directly.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Streams")
    }

    private func channelsFor(_ platform: StreamPlatform) -> [Stream] {
        switch platform {
        case .youtube: return store.youtubeChannels
        case .twitch: return store.twitchChannels
        case .kick: return store.kickChannels
        case .other: return store.otherChannels
        }
    }

    private var activeURLs: Set<String> {
        Set(manager.players.compactMap { $0.currentStream?.url })
    }

    private func streamRow(_ stream: Stream) -> some View {
        let active = activeURLs.contains(stream.url)

        return HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(stream.name)
                    .fontWeight(active ? .medium : .regular)
                if stream.pageUrl != nil {
                    Text("Refetchable via extension")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if active {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if active {
                if let p = manager.players.first(where: { $0.currentStream?.url == stream.url }) {
                    manager.stop(player: p)
                }
            } else {
                manager.play(stream: stream)
            }
        }
        .contextMenu {
            Button("Play") { manager.play(stream: stream) }
            if active {
                Button("Stop") {
                    if let p = manager.players.first(where: { $0.currentStream?.url == stream.url }) {
                        manager.stop(player: p)
                    }
                }
            }
            Divider()
            Button("Edit...") { editingStream = stream }
            Button("Delete", role: .destructive) {
                if let p = manager.players.first(where: { $0.currentStream?.url == stream.url }) {
                    manager.stop(player: p)
                }
                store.delete(stream)
            }
        }
    }
}

// MARK: - Output Detail

struct OutputDetail: View {
    @StateObject private var output = OutputManager.shared

    var body: some View {
        Form {
            Section {
                Text("Select the default output device for new streams. Each playing stream can also have its own output device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(output.devices) { device in
                    deviceRow(device)
                }
            } header: {
                Text("Devices")
            }

            Section {
                LabeledContent {
                    if output.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Scan") { output.scan() }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Network Devices")
                        Text("Scan for Chromecast and AirPlay devices on your network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            }
        }
        .formStyle(.grouped)
        .navigationTitle("Output")
    }

    private func deviceRow(_ device: OutputDevice) -> some View {
        let isSelected = output.defaultDevice == device

        return LabeledContent {
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(device.name)
                    Text(device.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: deviceIcon(device))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            output.defaultDevice = device
        }
    }

    private func deviceIcon(_ device: OutputDevice) -> String {
        switch device.proto {
        case .local:
            if device.id == "default" { return "laptopcomputer" }
            switch device.model {
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
}

// MARK: - General Detail

struct GeneralDetail: View {
    @ObservedObject var manager: PlayerManager
    @ObservedObject var store: StreamStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isCollectingLogs = false
    @State private var logStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { manager.multiStreamEnabled },
                    set: { manager.multiStreamEnabled = $0 }
                )) {
                    VStack(alignment: .leading) {
                        Text("Multi-Stream")
                        Text("Play multiple streams simultaneously with independent controls")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if manager.multiStreamEnabled {
                    Stepper(value: Binding(
                        get: { manager.maxStreams },
                        set: { manager.maxStreams = $0 }
                    ), in: 2...8) {
                        VStack(alignment: .leading) {
                            Text("Max Streams: \(manager.maxStreams)")
                            Text("Maximum number of streams that can play at once")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: Binding(
                    get: { manager.activePlayer?.separateControls ?? true },
                    set: { manager.setSeparateControlsAll($0) }
                )) {
                    VStack(alignment: .leading) {
                        Text("Separate Volume Control")
                        Text("Use the app's own volume slider instead of the system volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Playback")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { v in
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = v
                        } catch { launchAtLogin = !v }
                    }
                )) {
                    VStack(alignment: .leading) {
                        Text("Launch at Login")
                        Text("Automatically start Radio when you log in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button("Reload") { store.load() }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Streams Config")
                        Text("Reload streams from ~/.config/radio/streams.json")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("System")
            }

            Section {
                LabeledContent {
                    if isCollectingLogs {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Export Logs") { exportLogs() }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Diagnostics")
                        Text("Collect recent Radio logs and save to a file for bug reports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let logStatus {
                    Text(logStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Support")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func exportLogs() {
        isCollectingLogs = true
        logStatus = nil

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show", "--last", "1h",
                "--predicate", "subsystem == \"ro.pom.radio\"",
                "--style", "compact", "--info", "--debug"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else {
                await MainActor.run {
                    isCollectingLogs = false
                    logStatus = "Failed to collect logs"
                }
                return
            }
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let logText = String(data: data, encoding: .utf8) ?? "No logs found"

            await MainActor.run {
                isCollectingLogs = false

                let panel = NSSavePanel()
                panel.nameFieldStringValue = "radio-logs.txt"
                panel.allowedContentTypes = [.plainText]
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try logText.write(to: url, atomically: true, encoding: .utf8)
                        logStatus = "Saved \(logText.count / 1024)KB of logs"
                    } catch {
                        logStatus = "Failed to save: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

// MARK: - Hotkeys Detail

struct HotkeysDetail: View {
    var body: some View {
        Form {
            Section {
                Text("Global hotkeys work even when Radio is in the background. Click a shortcut field and press your desired key combination to set it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(HotKeyManager.Slot.categories, id: \.0) { category, slots in
                Section {
                    ForEach(slots, id: \.rawValue) { slot in
                        LabeledContent {
                            InlineShortcutRecorder(slot: slot)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(slot.label)
                                Text(slot.description)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text(category)
                }
            }

            Section {
                LabeledContent {
                    Button("Clear All") {
                        for slot in HotKeyManager.Slot.allCases {
                            HotKeyManager.shared.saveCombo(nil, for: slot)
                        }
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Reset")
                        Text("Remove all hotkey assignments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Hotkeys")
    }
}

// MARK: - Extensions Detail

struct ExtensionsDetail: View {
    @State private var extensionInstalled: Set<String> = []

    var body: some View {
        Form {
            Section {
                Text("Browser extensions let you detect and add streams from any webpage. Click the extension icon on a page with audio/video to capture its stream URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(DetectedBrowser.installed(), id: \.name) { browser in
                    LabeledContent {
                        if extensionInstalled.contains(browser.name) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.green)
                        } else {
                            Button("Install") {
                                installExtension(for: browser)
                                extensionInstalled.insert(browser.name)
                            }
                        }
                    } label: {
                        Label(browser.name, systemImage: browser.icon)
                    }
                }
            } header: {
                Text("Detected Browsers")
            } footer: {
                if !extensionInstalled.isEmpty {
                    Text("Chrome: enable Developer Mode, click Load Unpacked, select the opened folder.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Extensions")
    }

    // MARK: - Extension Install

    private func extensionSourcePath() -> String {
        if let resPath = Bundle.main.resourcePath {
            let bundled = (resPath as NSString).appendingPathComponent("extension")
            if FileManager.default.fileExists(atPath: bundled) { return bundled }
        }
        // Development fallback: extension/ in working directory
        return (FileManager.default.currentDirectoryPath as NSString)
            .appendingPathComponent("extension")
    }

    private func radioSupportDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Radio")
    }

    private func installExtension(for browser: DetectedBrowser) {
        let fm = FileManager.default
        let srcPath = extensionSourcePath()
        let supportDir = radioSupportDir()
        let installedExt = supportDir.appendingPathComponent("extension")

        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: installedExt)
        try? fm.copyItem(atPath: srcPath, toPath: installedExt.path)
        try? fm.removeItem(at: installedExt.appendingPathComponent("radio.pem"))

        switch browser.kind {
        case .chromium(let appName, _):
            installChromium(appName: appName, extensionDir: installedExt)
        case .safari:
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = [
                    "safari-web-extension-converter", installedExt.path,
                    "--app-name", "Radio Extension",
                    "--bundle-identifier", "ro.pom.radio.extension",
                    "--no-prompt",
                ]
                try? process.run()
                process.waitUntilExit()
            }
        case .firefox:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Firefox", "about:debugging#/runtime/this-firefox"]
            try? process.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSWorkspace.shared.selectFile(
                    installedExt.appendingPathComponent("manifest.json").path,
                    inFileViewerRootedAtPath: installedExt.path
                )
            }
        }
    }

    private func installChromium(appName: String, extensionDir: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, "chrome://extensions"]
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: extensionDir.path)
        }
    }
}

// MARK: - About Detail

struct AboutDetail: View {
    @State private var updateStatus: String?
    @State private var autoCheckEnabled = UserDefaults.standard.object(forKey: "autoCheckForUpdates") as? Bool ?? true

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var extensionVersion: String {
        guard let resPath = Bundle.main.resourcePath else { return "?" }
        let manifest = (resPath as NSString).appendingPathComponent("extension/manifest.json")
        guard let data = FileManager.default.contents(atPath: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else { return "?" }
        return version
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("App Version", value: "v\(appVersion)")
                LabeledContent("Build", value: buildNumber)
                LabeledContent("Extension Version", value: extensionVersion)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "?")
            } header: {
                Text("Version")
            }

            Section {
                LabeledContent("GitHub") {
                    Link("pom11/Radio", destination: URL(string: "https://github.com/pom11/Radio")!)
                }
                LabeledContent("Homebrew") {
                    Text("pom11/tap/radio")
                        .textSelection(.enabled)
                }
                LabeledContent("License", value: "MIT")
            } header: {
                Text("Project")
            }

            Section {
                Toggle("Check for updates on launch", isOn: $autoCheckEnabled)
                    .onChange(of: autoCheckEnabled) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "autoCheckForUpdates")
                    }
                HStack {
                    Button {
                        UpdateChecker.check { status in
                            updateStatus = status
                        }
                    } label: {
                        Text("Check Now")
                    }
                    Spacer()
                    if let status = updateStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Run `brew upgrade --cask radio` to update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .onAppear {
            if let cached = UpdateChecker.lastStatus {
                updateStatus = cached
            }
        }
    }
}

// MARK: - Update Checker

enum UpdateChecker {
    static var lastStatus: String?

    static func check(completion: ((String) -> Void)? = nil) {
        completion?("Checking...")
        Task {
            do {
                let url = URL(string: "https://api.github.com/repos/pom11/Radio/releases/latest")!
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tag = json["tag_name"] as? String {
                    let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    let status: String
                    if latest == appVersion {
                        status = "Up to date"
                    } else {
                        status = "v\(latest) available"
                    }
                    lastStatus = status
                    UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                    await MainActor.run { completion?(status) }
                }
            } catch {
                await MainActor.run { completion?("Check failed") }
            }
        }
    }

    static func checkOnLaunchIfNeeded() {
        guard UserDefaults.standard.object(forKey: "autoCheckForUpdates") as? Bool ?? true else { return }
        check()
    }
}

// MARK: - Add Stream Sheet

struct AddStreamSheet: View {
    @ObservedObject var store: StreamStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var type: StreamType = .audio
    @State private var isProbing = false
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $url)
                    .onChange(of: url) { _, newValue in
                        type = URLResolver.detectType(newValue)
                        probeURL(newValue)
                    }
                Picker("Type", selection: $type) {
                    Label("Audio", systemImage: "radio").tag(StreamType.audio)
                    Label("Video", systemImage: "video.fill").tag(StreamType.video)
                    Label("Channel", systemImage: "play.tv.fill").tag(StreamType.channel)
                }

                if isProbing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Detecting stream...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    store.add(name: name, url: url, type: type)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || url.isEmpty)
            }
            .padding()
        }
        .frame(width: 360)
    }

    private func probeURL(_ urlString: String) {
        probeTask?.cancel()
        guard !urlString.isEmpty,
              urlString.contains(".") || urlString.contains(":")
        else { return }

        probeTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            isProbing = true
            defer { isProbing = false }

            if let result = await URLResolver.probe(urlString) {
                guard !Task.isCancelled else { return }
                if let probeType = StreamType(rawValue: result.type) {
                    type = probeType
                }
                if name.isEmpty && !result.title.isEmpty {
                    name = result.title
                }
            }
        }
    }
}

// MARK: - Quick Play Sheet

struct QuickPlaySheet: View {
    @ObservedObject var manager: PlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var type: StreamType = .audio
    @State private var detectedName = ""
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("URL", text: $url)
                    .onChange(of: url) { _, newValue in
                        type = URLResolver.detectType(newValue)
                        probeTask?.cancel()
                        guard !newValue.isEmpty else { return }
                        probeTask = Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            guard !Task.isCancelled else { return }
                            if let result = await URLResolver.probe(newValue) {
                                guard !Task.isCancelled else { return }
                                if let t = StreamType(rawValue: result.type) { type = t }
                                detectedName = result.title
                            }
                        }
                    }
                Picker("Type", selection: $type) {
                    Label("Audio", systemImage: "radio").tag(StreamType.audio)
                    Label("Video", systemImage: "video.fill").tag(StreamType.video)
                    Label("Channel", systemImage: "play.tv.fill").tag(StreamType.channel)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Play") {
                    let name = detectedName.isEmpty ? "Quick Play" : detectedName
                    let stream = Stream(name: name, url: url, type: type)
                    manager.play(stream: stream)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(url.isEmpty)
            }
            .padding()
        }
        .frame(width: 360)
    }
}

// MARK: - Edit Stream Sheet

struct EditStreamSheet: View {
    @ObservedObject var store: StreamStore
    @Environment(\.dismiss) private var dismiss

    let stream: Stream
    @State private var name: String
    @State private var url: String
    @State private var type: StreamType

    init(store: StreamStore, stream: Stream) {
        self.store = store
        self.stream = stream
        _name = State(initialValue: stream.name)
        _url = State(initialValue: stream.url)
        _type = State(initialValue: stream.type)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $url)
                Picker("Type", selection: $type) {
                    Label("Audio", systemImage: "radio").tag(StreamType.audio)
                    Label("Video", systemImage: "video.fill").tag(StreamType.video)
                    Label("Channel", systemImage: "play.tv.fill").tag(StreamType.channel)
                }

                if let pageUrl = stream.pageUrl {
                    LabeledContent("Source Page") {
                        Text(pageUrl)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let referer = stream.referer {
                    LabeledContent("Referer") {
                        Text(referer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let headers = stream.headers, !headers.isEmpty {
                    LabeledContent("Headers") {
                        VStack(alignment: .trailing) {
                            ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                Text("\(key): \(value)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if let i = store.streams.firstIndex(where: { $0.id == stream.id }) {
                        store.streams[i].name = name
                        store.streams[i].url = url
                        store.streams[i].type = type
                        store.save()
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || url.isEmpty)
            }
            .padding()
        }
        .frame(width: 360)
    }
}

// MARK: - Inline Shortcut Recorder

struct InlineShortcutRecorder: View {
    let slot: HotKeyManager.Slot
    @State private var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    init(slot: HotKeyManager.Slot) {
        self.slot = slot
        _combo = State(initialValue: HotKeyManager.shared.savedCombo(for: slot))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isRecording { stopRecording() } else { startRecording() }
            } label: {
                Text(isRecording ? "Press shortcut..." : (combo?.displayString ?? "Not Set"))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(combo == nil && !isRecording ? .secondary : .primary)
            }

            if combo != nil && !isRecording {
                Button {
                    combo = nil
                    HotKeyManager.shared.saveCombo(nil, for: slot)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else {
                if event.keyCode == 53 { stopRecording() }
                return nil
            }
            combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            HotKeyManager.shared.saveCombo(combo, for: slot)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - Browser Detection

struct DetectedBrowser {
    let name: String
    let icon: String
    let kind: Kind

    enum Kind {
        case chromium(appName: String, externalExtDir: String)
        case firefox
        case safari
    }

    private static let all: [(String, String, String, Kind)] = [
        ("Google Chrome", "Google Chrome", "globe",
         .chromium(appName: "Google Chrome",
                   externalExtDir: "Google/Chrome/External Extensions")),
        ("Brave Browser", "Brave Browser", "globe",
         .chromium(appName: "Brave Browser",
                   externalExtDir: "BraveSoftware/Brave-Browser/External Extensions")),
        ("Microsoft Edge", "Microsoft Edge", "globe",
         .chromium(appName: "Microsoft Edge",
                   externalExtDir: "Microsoft Edge/External Extensions")),
        ("Arc", "Arc", "globe",
         .chromium(appName: "Arc",
                   externalExtDir: "Arc/User Data/External Extensions")),
        ("Vivaldi", "Vivaldi", "globe",
         .chromium(appName: "Vivaldi",
                   externalExtDir: "Vivaldi/External Extensions")),
        ("Firefox", "Firefox", "flame", .firefox),
        ("Safari", "Safari", "safari", .safari),
    ]

    static func installed() -> [DetectedBrowser] {
        let fm = FileManager.default
        return all.compactMap { (appDir, name, icon, kind) in
            let path = "/Applications/\(appDir).app"
            guard fm.fileExists(atPath: path) else { return nil }
            return DetectedBrowser(name: name, icon: icon, kind: kind)
        }
    }
}
