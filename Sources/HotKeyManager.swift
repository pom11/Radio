import AppKit
import Carbon.HIToolbox
import SwiftUI
import os.log

private let log = Logger(subsystem: "ro.pom.radio", category: "hotkeys")

// MARK: - Key Combo model

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier flags

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(Self.keyName(for: keyCode))
        return parts.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    private static let keyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
        0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
        0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R",
        0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=", 0x19: "9",
        0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P",
        0x25: "L", 0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "N", 0x2E: "M",
        0x2F: ".", 0x31: "Space", 0x24: "↩", 0x30: "⇥", 0x33: "⌫",
        0x35: "⎋", 0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9",
        0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    private static func keyName(for code: UInt32) -> String {
        keyNames[code] ?? String(format: "0x%02X", code)
    }
}

// MARK: - Hotkey Slots

extension HotKeyManager {
    enum Slot: UInt32, CaseIterable {
        case video = 1
        case popover = 2
        case playPause = 6
        case volumeUp = 7
        case volumeDown = 8
        case muteUnmute = 9
        case videoFloat = 10
        case soloToggle = 11
        case cyclePlayer = 12
        case toggleAllWindows = 13

        var defaultsKey: String {
            switch self {
            case .video: return "toggleVideoHotKey"
            case .popover: return "togglePopoverHotKey"
            case .playPause: return "playPauseHotKey"
            case .volumeUp: return "volumeUpHotKey"
            case .volumeDown: return "volumeDownHotKey"
            case .muteUnmute: return "muteUnmuteHotKey"
            case .videoFloat: return "videoFloatHotKey"
            case .soloToggle: return "soloToggleHotKey"
            case .cyclePlayer: return "cyclePlayerHotKey"
            case .toggleAllWindows: return "toggleAllWindowsHotKey"
            }
        }

        var defaultCombo: KeyCombo? {
            return nil
        }

        var label: String {
            switch self {
            case .video: return "TOGGLE VIDEO"
            case .popover: return "TOGGLE RADIO"
            case .playPause: return "PLAY / PAUSE"
            case .volumeUp: return "VOLUME UP"
            case .volumeDown: return "VOLUME DOWN"
            case .muteUnmute: return "MUTE / UNMUTE"
            case .videoFloat: return "VIDEO FLOAT"
            case .soloToggle: return "SOLO TOGGLE"
            case .cyclePlayer: return "CYCLE PLAYER"
            case .toggleAllWindows: return "TOGGLE ALL WINDOWS"
            }
        }

        var description: String {
            switch self {
            case .video: return "Show or hide the video window globally"
            case .popover: return "Show or hide the Radio window"
            case .playPause: return "Toggle stream playback"
            case .volumeUp: return "Increase app volume by 5%"
            case .volumeDown: return "Decrease app volume by 5%"
            case .muteUnmute: return "Toggle mute on/off"
            case .videoFloat: return "Toggle video always on top"
            case .soloToggle: return "Toggle solo (mute others) on active player"
            case .cyclePlayer: return "Switch active player to the next stream"
            case .toggleAllWindows: return "Show or hide all video windows at once"
            }
        }

        var category: String {
            switch self {
            case .playPause, .muteUnmute, .soloToggle, .cyclePlayer:
                return "Playback"
            case .volumeUp, .volumeDown:
                return "Volume"
            case .video, .videoFloat, .toggleAllWindows:
                return "Video"
            case .popover:
                return "App"
            }
        }

        static var categories: [(String, [Slot])] {
            let order = ["Playback", "Volume", "Video", "App"]
            let grouped = Dictionary(grouping: allCases, by: \.category)
            return order.compactMap { cat in
                guard let slots = grouped[cat] else { return nil }
                return (cat, slots)
            }
        }
    }
}

// MARK: - Global Hot Key Manager (Carbon API)

final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    var onToggleVideo: (() -> Void)?
    var onTogglePopover: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onMuteUnmute: (() -> Void)?
    var onVideoFloat: (() -> Void)?
    var onSoloToggle: (() -> Void)?
    var onCyclePlayer: (() -> Void)?
    var onToggleAllWindows: (() -> Void)?

    private let hotKeySignature = OSType(0x52444F00) // "RDO\0"

    deinit {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
    }

    func register(_ combo: KeyCombo, for slot: Slot) {
        unregister(slot)
        installHandler()

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: slot.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            log.error("Failed to register hotkey for \(slot.label): OSStatus \(status)")
            return
        }
        if let ref {
            hotKeyRefs[slot] = ref
            log.debug("Registered hotkey \(combo.displayString) for \(slot.label)")
        }
    }

    func unregister(_ slot: Slot) {
        if let ref = hotKeyRefs[slot] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[slot] = nil
        }
    }

    private func installHandler() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event!,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                DispatchQueue.main.async {
                    let mgr = HotKeyManager.shared
                    switch hotKeyID.id {
                    case Slot.video.rawValue:
                        mgr.onToggleVideo?()
                    case Slot.popover.rawValue:
                        mgr.onTogglePopover?()
                    case Slot.playPause.rawValue:
                        mgr.onPlayPause?()
                    case Slot.volumeUp.rawValue:
                        mgr.onVolumeUp?()
                    case Slot.volumeDown.rawValue:
                        mgr.onVolumeDown?()
                    case Slot.muteUnmute.rawValue:
                        mgr.onMuteUnmute?()
                    case Slot.videoFloat.rawValue:
                        mgr.onVideoFloat?()
                    case Slot.soloToggle.rawValue:
                        mgr.onSoloToggle?()
                    case Slot.cyclePlayer.rawValue:
                        mgr.onCyclePlayer?()
                    case Slot.toggleAllWindows.rawValue:
                        mgr.onToggleAllWindows?()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        if status != noErr {
            log.error("Failed to install hotkey event handler: OSStatus \(status)")
        }
    }

    // MARK: - Persistence

    func savedCombo(for slot: Slot) -> KeyCombo? {
        if let data = UserDefaults.standard.data(forKey: slot.defaultsKey) {
            if let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
                return combo
            }
            // Data exists but failed to decode — check if explicitly cleared
            return nil
        }
        return slot.defaultCombo
    }

    func saveCombo(_ combo: KeyCombo?, for slot: Slot) {
        if let combo {
            if let data = try? JSONEncoder().encode(combo) {
                UserDefaults.standard.set(data, forKey: slot.defaultsKey)
            }
            register(combo, for: slot)
        } else {
            UserDefaults.standard.set(Data(), forKey: slot.defaultsKey)
            unregister(slot)
        }
    }
}
