import SwiftUI
import Combine
import CoreSpotlight
import ServiceManagement
import UniformTypeIdentifiers
import os.log

private let log = Logger(subsystem: "ro.pom.radio", category: "app")

@main
struct RadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let playerManager = PlayerManager.shared

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any windows SwiftUI created before we take over
        for window in NSApp.windows where window !== settingsWindow {
            window.orderOut(nil)
        }

        // Set app icon from bundle
        if let resPath = Bundle.main.resourcePath {
            let icnsPath = (resPath as NSString).appendingPathComponent("Radio.icns")
            if let icon = NSImage(contentsOfFile: icnsPath) {
                NSApp.applicationIconImage = icon
            }
        }

        stripMenuBar()
        setupPopover()
        setupStatusItem()
        setupHotKeys()
        registerURLScheme()

        // Auto-update browser extension if installed
        updateExtensionIfNeeded()

        // Register App Shortcuts with Spotlight/Siri
        RadioShortcuts.updateAppShortcutParameters()

        // Check for crash reports from previous sessions
        checkForCrashReports()

        // Check for updates on launch if enabled
        UpdateChecker.checkOnLaunchIfNeeded()

        // Check required CLI dependencies
        checkDependencies()
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let stream = sharedStore.streams.first(where: { $0.id.uuidString == identifier }) else {
            return false
        }
        playerManager.play(stream: stream)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        playerManager.stopAll()
        OutputManager.shared.shutdownAll()
    }

    // MARK: - Dependency Check

    private struct ToolReq {
        let name: String
        let minVersion: String      // semver-ish: "7.0", "2025.01.01", "6.0"
        let versionArgs: [String]   // args to get version output
    }

    private static let requiredTools: [ToolReq] = [
        ToolReq(name: "ffmpeg",     minVersion: "7.0",        versionArgs: ["-version"]),
        ToolReq(name: "yt-dlp",     minVersion: "2025.01.01", versionArgs: ["--version"]),
        ToolReq(name: "streamlink", minVersion: "6.0",        versionArgs: ["--version"]),
    ]

    private func checkDependencies() {
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let fm = FileManager.default

        var missing: [String] = []
        var outdated: [(name: String, installed: String, minimum: String)] = []

        for tool in Self.requiredTools {
            guard let toolPath = searchPaths.first(where: { fm.fileExists(atPath: "\($0)/\(tool.name)") })
                .map({ "\($0)/\(tool.name)" }) else {
                missing.append(tool.name)
                continue
            }

            // Get installed version
            let process = Process()
            process.executableURL = URL(fileURLWithPath: toolPath)
            process.arguments = tool.versionArgs
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard let version = Self.parseVersion(output, tool: tool.name) else { continue }
            if Self.compareVersions(version, tool.minVersion) == .orderedAscending {
                outdated.append((tool.name, version, tool.minVersion))
            }
        }

        guard !missing.isEmpty || !outdated.isEmpty else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            var bullets: [String] = []
            for name in missing {
                bullets.append("• \(name) (not installed)")
            }
            for item in outdated {
                bullets.append("• \(item.name) \(item.installed) → requires \(item.minimum)+")
            }

            let upgradeNames = missing + outdated.map(\.name)
            let installCmd = "brew upgrade \(upgradeNames.joined(separator: " "))"

            let alert = NSAlert()
            alert.messageText = missing.isEmpty ? "Outdated Dependencies" : "Missing Dependencies"
            alert.informativeText = "Radio requires the following tools to work properly:\n\n"
                + bullets.joined(separator: "\n")
                + "\n\nTo fix:\n\n"
                + "1. Open Terminal (or your terminal of choice)\n"
                + "2. Paste the following command and press Return:\n\n"
                + installCmd
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Copy Command & Open Terminal")
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Dismiss")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(installCmd, forType: .string)
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(installCmd, forType: .string)
            default:
                break
            }
        }
    }

    /// Extract version string from tool output.
    /// - ffmpeg: "ffmpeg version 8.1 ..." → "8.1"
    /// - yt-dlp: "2026.03.13" (entire output)
    /// - streamlink: "streamlink 8.2.1" → "8.2.1"
    private static func parseVersion(_ output: String, tool: String) -> String? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        switch tool {
        case "ffmpeg":
            // "ffmpeg version 8.1 Copyright ..."
            // "ffmpeg version N-12345-g..." (git builds — extract N or skip)
            guard let range = line.range(of: "version ") else { return nil }
            let after = String(line[range.upperBound...])
            let version = after.prefix(while: { $0.isNumber || $0 == "." })
            if version.isEmpty || !version.first!.isNumber { return nil }
            return String(version)
        case "yt-dlp":
            // Output is just "2026.03.13\n"
            let version = line.prefix(while: { $0.isNumber || $0 == "." })
            return version.isEmpty ? nil : String(version)
        case "streamlink":
            // "streamlink 8.2.1"
            let parts = line.split(separator: " ")
            return parts.count >= 2 ? String(parts[1]) : nil
        default:
            return nil
        }
    }

    /// Compare dot-separated version strings numerically.
    private static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Crash Detection

    private func checkForCrashReports() {
        let lastCheck = UserDefaults.standard.object(forKey: "lastCrashCheck") as? Date ?? .distantPast
        UserDefaults.standard.set(Date(), forKey: "lastCrashCheck")

        // Look for macOS crash reports for Radio created after our last check
        let crashDirs = [
            NSHomeDirectory() + "/Library/Logs/DiagnosticReports",
            "/Library/Logs/DiagnosticReports",
        ]

        var foundCrash = false
        for dir in crashDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasPrefix("Radio") && (file.hasSuffix(".ips") || file.hasSuffix(".crash")) {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let created = attrs[.creationDate] as? Date,
                      created > lastCheck else { continue }
                foundCrash = true
                break
            }
            if foundCrash { break }
        }

        guard foundCrash else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.showCrashReport()
        }
    }

    private func showCrashReport() {
        let alert = NSAlert()
        alert.messageText = "Radio quit unexpectedly"
        alert.informativeText = "The previous session didn't exit cleanly. You can export recent logs and open a bug report on GitHub."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Report Issue")
        alert.addButton(withTitle: "Export Logs")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Open GitHub issue with pre-filled template
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let body = """
            **Version:** \(version)
            **macOS:** \(os)

            **What happened:**
            Radio quit unexpectedly.

            **Steps to reproduce:**
            1.

            **Logs:**
            <!-- Paste logs from Export Logs below -->
            ```

            ```
            """
            let encoded = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlStr = "https://github.com/pom11/Radio/issues/new?title=Crash+report&body=\(encoded)"
            if let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            exportCrashLogs()
        default:
            break
        }
    }

    private func exportCrashLogs() {
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
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let logText = String(data: data, encoding: .utf8) ?? "No logs found"

            await MainActor.run {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "radio-crash-logs.txt"
                panel.allowedContentTypes = [.plainText]
                if panel.runModal() == .OK, let url = panel.url {
                    try? logText.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePopover()
        return true
    }

    // MARK: - Strip Menu Bar

    private func stripMenuBar() {
        guard let mainMenu = NSApp.mainMenu else { return }

        while mainMenu.items.count > 1 {
            mainMenu.removeItem(at: mainMenu.items.count - 1)
        }

        if let appMenu = mainMenu.items.first?.submenu {
            appMenu.items.removeAll()
            appMenu.addItem(
                withTitle: "Quit Radio",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        }

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
    }

    // MARK: - Popover

    private func setupPopover() {
        let popoverView = MenuBarPopover(
            manager: playerManager,
            store: sharedStore,
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.showSettingsWindow()
            }
        )

        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 600)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: popoverView)

        // Close popover when app loses focus or desktop/space changes
        for name in [NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.popover.performClose(nil) }
                .store(in: &cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.popover.performClose(nil) }
            .store(in: &cancellables)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure popover window can receive key events
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Settings Window

    private func setupSettingsWindow() {
        let view = RadioView(
            manager: playerManager,
            store: sharedStore
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Radio"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 300)
        window.setFrameAutosaveName("RadioSettingsWindow")
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard self != nil else { return }
            NSApp.setActivationPolicy(.accessory)
        }

        settingsWindow = window
    }

    private func showSettingsWindow() {
        if settingsWindow == nil { setupSettingsWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        playerManager.$players
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusButton() }
            .store(in: &cancellables)

        updateStatusButton()
    }

    private func menuBarIcon(playing: Bool = false) -> NSImage? {
        if let resPath = Bundle.main.resourcePath {
            let filename = playing ? "menubar_playing.png" : "menubar.png"
            let path = (resPath as NSString).appendingPathComponent(filename)
            if let img = NSImage(contentsOfFile: path) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        // Fallback to SF Symbol
        let symbolName = playing ? "radio.fill" : "radio"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Radio")
        img?.isTemplate = true
        return img
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let isPlaying = !playerManager.players.isEmpty
        button.image = menuBarIcon(playing: isPlaying)
        button.attributedTitle = NSAttributedString()
    }

    @objc private func statusItemClicked() {
        togglePopover()
    }

    // MARK: - Extension Auto-Update

    private func updateExtensionIfNeeded() {
        let fm = FileManager.default
        guard let resPath = Bundle.main.resourcePath else { return }
        let bundled = (resPath as NSString).appendingPathComponent("extension")
        guard fm.fileExists(atPath: bundled) else { return }

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let installed = support.appendingPathComponent("Radio/extension")
        guard fm.fileExists(atPath: installed.path) else { return }

        // Compare manifest versions
        let bundledManifest = (bundled as NSString).appendingPathComponent("manifest.json")
        let installedManifest = installed.appendingPathComponent("manifest.json").path
        guard let bundledData = fm.contents(atPath: bundledManifest),
              let installedData = fm.contents(atPath: installedManifest),
              let bJSON = try? JSONSerialization.jsonObject(with: bundledData) as? [String: Any],
              let iJSON = try? JSONSerialization.jsonObject(with: installedData) as? [String: Any],
              let bVersion = bJSON["version"] as? String,
              let iVersion = iJSON["version"] as? String else { return }

        if bVersion != iVersion {
            try? fm.removeItem(at: installed)
            try? fm.copyItem(atPath: bundled, toPath: installed.path)
            try? fm.removeItem(at: installed.appendingPathComponent("radio.pem"))
        }
    }

    // MARK: - URL Scheme (radio://add?url=...&name=...)

    private func registerURLScheme() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "radio" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func param(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        switch url.host {
        case "add":
            let streamURL = param("url") ?? ""
            guard !streamURL.isEmpty else { return }
            let name = param("name") ?? ""
            let typeHint = param("type") ?? ""
            let pageUrl = param("pageUrl")

            let streamType = StreamType(rawValue: typeHint) ?? URLResolver.detectType(streamURL)
            let streamName = name.isEmpty ? streamURL : name

            let referer = param("referer")

            if let pageUrl, let idx = sharedStore.indexByPageUrl(pageUrl) {
                sharedStore.streams[idx].url = streamURL
                sharedStore.streams[idx].name = streamName
                sharedStore.streams[idx].type = streamType
                sharedStore.streams[idx].referer = referer
                sharedStore.streams[idx].headers = nil
                sharedStore.save()
            } else {
                let stream = Stream(name: streamName, url: streamURL, type: streamType, pageUrl: pageUrl, referer: referer)
                sharedStore.streams.append(stream)
                sharedStore.save()
            }

            if typeHint.isEmpty {
                Task {
                    if let probe = await URLResolver.probe(streamURL),
                       let probeType = StreamType(rawValue: probe.type),
                       probeType != streamType {
                        await MainActor.run {
                            if let idx = sharedStore.streams.lastIndex(where: { $0.url == streamURL }) {
                                sharedStore.streams[idx].type = probeType
                                if !probe.title.isEmpty && name.isEmpty {
                                    sharedStore.streams[idx].name = probe.title
                                }
                                sharedStore.save()
                            }
                        }
                    }
                }
            }

        case "update":
            let pageUrl = param("pageUrl") ?? ""
            let newURL = param("url") ?? ""
            guard !pageUrl.isEmpty, !newURL.isEmpty else { return }
            guard let idx = sharedStore.indexByPageUrl(pageUrl) else { return }
            sharedStore.streams[idx].url = newURL
            sharedStore.streams[idx].referer = nil
            sharedStore.streams[idx].headers = nil
            sharedStore.save()

        case "meta":
            let pageUrl = param("pageUrl") ?? ""
            guard !pageUrl.isEmpty else { return }
            guard let idx = sharedStore.indexByPageUrl(pageUrl) else { return }
            if let referer = param("referer") {
                sharedStore.streams[idx].referer = referer
            }
            if let header = param("header"), let colonIdx = header.firstIndex(of: ":") {
                let key = String(header[header.startIndex..<colonIdx])
                let value = String(header[header.index(after: colonIdx)...])
                if sharedStore.streams[idx].headers == nil {
                    sharedStore.streams[idx].headers = [:]
                }
                sharedStore.streams[idx].headers?[key] = value
            }
            sharedStore.save()

        case "remove":
            if let pageUrl = param("pageUrl"), let idx = sharedStore.indexByPageUrl(pageUrl) {
                sharedStore.streams.remove(at: idx)
                sharedStore.save()
            } else if let streamURL = param("url") {
                sharedStore.streams.removeAll { $0.url == streamURL }
                sharedStore.save()
            }

        case "play":
            let streamURL = param("url") ?? ""
            guard !streamURL.isEmpty else { return }
            let type = URLResolver.detectType(streamURL)
            let stream = Stream(name: "Quick Play", url: streamURL, type: type)
            playerManager.play(stream: stream)

        default:
            break
        }
    }

    // MARK: - Hot Keys

    private func setupHotKeys() {
        let manager = HotKeyManager.shared

        var registered: [String] = []
        for slot in HotKeyManager.Slot.allCases {
            if let combo = manager.savedCombo(for: slot) {
                manager.register(combo, for: slot)
                registered.append("\(slot.label): \(combo.displayString)")
            }
        }
        if registered.isEmpty {
            log.info("No hotkeys configured")
        } else {
            log.info("Registered \(registered.count) hotkeys: \(registered.joined(separator: ", "))")
        }

        manager.onToggleVideo = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player, player.currentStream != nil else { return }
            pm.toggleVideo(for: player)
        }

        manager.onTogglePopover = { [weak self] in
            self?.togglePopover()
        }

        manager.onPlayPause = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player, player.currentStream != nil else { return }
            if player.isCasting, let device = player.outputDevice as OutputDevice? {
                OutputManager.shared.castPlayPause(device: device)
            } else {
                player.togglePlayPause()
            }
        }

        manager.onVolumeUp = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player else { return }
            if player.isCasting, let device = player.outputDevice as OutputDevice? {
                OutputManager.shared.castVolumeUp(device: device)
            } else {
                if !player.separateControls { player.setSeparateControls(true) }
                player.adjustVolume(by: 0.05)
            }
        }

        manager.onVolumeDown = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player else { return }
            if player.isCasting, let device = player.outputDevice as OutputDevice? {
                OutputManager.shared.castVolumeDown(device: device)
            } else {
                if !player.separateControls { player.setSeparateControls(true) }
                player.adjustVolume(by: -0.05)
            }
        }

        manager.onMuteUnmute = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player else { return }
            player.toggleMute()
        }

        manager.onVideoFloat = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player else { return }
            pm.toggleVideoFloat(for: player)
        }

        manager.onSoloToggle = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player else { return }
            pm.toggleSolo(player: player)
        }

        manager.onCyclePlayer = { [weak self] in
            self?.playerManager.cycleActivePlayer()
        }

        manager.onToggleAllWindows = { [weak self] in
            self?.playerManager.toggleAllVideoWindows()
        }
    }
}
