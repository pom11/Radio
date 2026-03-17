import SwiftUI
import Combine
import CoreSpotlight
import ServiceManagement
import UniformTypeIdentifiers

@main
struct RadioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — everything is managed by AppDelegate
        Window("_hidden", id: "hidden") { EmptyView().frame(width: 0, height: 0) }
            .defaultSize(width: 0, height: 0)
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private let playerManager = PlayerManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Close any windows SwiftUI may have restored
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "_hidden" || window.title.isEmpty {
                window.close()
            }
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

        for slot in HotKeyManager.Slot.allCases {
            if let combo = manager.savedCombo(for: slot) {
                manager.register(combo, for: slot)
            }
        }

        manager.onToggleVideo = { [weak self] in
            guard let pm = self?.playerManager else { return }
            let player = pm.activePlayer ?? pm.players.first
            guard let player, player.isPlaying else { return }
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
                guard player.separateControls else { return }
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
                guard player.separateControls else { return }
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
