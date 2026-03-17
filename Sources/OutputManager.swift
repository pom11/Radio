import Foundation
import Combine
import CoreAudio
import os

// MARK: - Output Device Model

enum OutputProtocol: String {
    case local      // CoreAudio device (built-in, AirPlay, Bluetooth)
    case chromecast // Google Cast via CastController
}

struct OutputDevice: Identifiable, Hashable {
    let id: String          // CoreAudio UID or Chromecast IP
    let name: String
    let model: String       // "Built-in", "AirPlay", "Chromecast", etc.
    let proto: OutputProtocol

    var label: String {
        if id == "default" { return name }
        if proto == .chromecast { return "\(name) (Cast)" }
        if model == "AirPlay" { return "\(name) (AirPlay)" }
        return name
    }

    static let macbook = OutputDevice(
        id: "default",
        name: "This MacBook",
        model: "Built-in Output",
        proto: .local
    )
}

// MARK: - Output Manager

final class OutputManager: ObservableObject {
    static let shared = OutputManager()

    @Published var devices: [OutputDevice] = [.macbook]
    @Published var defaultDevice: OutputDevice = .macbook
    @Published var isScanning = false
    @Published var castVolume: Int = 50

    private let castController = CastController.shared
    private var proxies: [Int: CastProxy] = [:]

    var isLocal: Bool { defaultDevice.proto == .local && defaultDevice.id == "default" }
    var isCasting: Bool { defaultDevice.proto == .chromecast }

    // MARK: - Device Discovery

    func scan() {
        guard !isScanning else { return }
        isScanning = true

        let currentID = defaultDevice.id

        Task.detached {
            async let audioDevices = self.discoverAudioOutputs()
            async let chromecastDevices = self.castController.discoverDevices(timeout: 5)

            let audio = await audioDevices
            let chromecasts = await chromecastDevices

            var all: [OutputDevice] = [.macbook]
            all.append(contentsOf: audio)

            // Convert CastDevice to OutputDevice
            for cc in chromecasts {
                all.append(OutputDevice(
                    id: cc.ip,
                    name: cc.name,
                    model: cc.model,
                    proto: .chromecast
                ))
            }

            await MainActor.run {
                self.devices = all
                if let existing = all.first(where: { $0.id == currentID }) {
                    self.defaultDevice = existing
                } else {
                    self.defaultDevice = .macbook
                }
                self.isScanning = false
            }
        }
    }

    private func discoverAudioOutputs() -> [OutputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        var results: [OutputDevice] = []
        for deviceID in deviceIDs {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
            if streamSize == 0 { continue }

            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uid)
            let uidStr = uid as String

            if uidStr.contains("BuiltInSpeaker") || uidStr.contains("BuiltInMicrophone") { continue }

            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &name)
            let nameStr = name as String

            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport)

            let model: String
            switch transport {
            case kAudioDeviceTransportTypeAirPlay: model = "AirPlay"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: model = "Bluetooth"
            case kAudioDeviceTransportTypeUSB: model = "USB"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: model = "Display"
            case kAudioDeviceTransportTypeAggregate: model = "Aggregate"
            case kAudioDeviceTransportTypeVirtual: model = "Virtual"
            default: model = "Audio"
            }

            if model == "Virtual" || model == "Aggregate" { continue }

            results.append(OutputDevice(id: uidStr, name: nameStr, model: model, proto: .local))
        }
        return results
    }

    // MARK: - HLS Proxy (per-stream)

    func allocateProxyPort() -> Int {
        CastProxy.allocatePort()
    }

    func startProxy(hlsURL: String, port: Int, headers: [String: String] = [:], completion: @escaping (String?, Int?) -> Void) {
        stopProxy(port: port)

        Task.detached {
            let proxy = CastProxy()
            if let proxyURL = await proxy.start(hlsURL: hlsURL, port: port, headers: headers) {
                await MainActor.run {
                    self.proxies[port] = proxy
                    completion(proxyURL, port)
                }
            } else {
                await MainActor.run {
                    completion(nil, nil)
                }
            }
        }
    }

    func stopProxy(port: Int) {
        if let proxy = proxies.removeValue(forKey: port) {
            proxy.stop()
        }
    }

    // MARK: - Device-parameterized Chromecast Controls

    func castURL(_ url: String, device: OutputDevice, proxyPort: Int, headers: [String: String] = [:], proxyReady: @escaping () -> Void) {
        guard device.proto == .chromecast else { return }
        let lower = url.lowercased()

        // Auto-proxy HLS streams — Chromecast has limited native HLS support
        if lower.contains(".m3u8") || lower.contains("mpegurl") {
            startProxy(hlsURL: url, port: proxyPort, headers: headers) { [weak self] proxyURL, _ in
                guard let self else {
                    proxyReady()
                    return
                }
                let castDevice = self.makeCastDevice(from: device)
                let castURL = proxyURL ?? url
                let streamType = proxyURL != nil ? "LIVE" : nil
                Task {
                    do {
                        try await self.castController.cast(url: castURL, to: castDevice, streamType: streamType)
                    } catch {
                        Logger(subsystem: "ro.pom.radio", category: "OutputManager").error("Cast proxy failed: \(error)")
                    }
                    await MainActor.run { proxyReady() }
                }
            }
            return
        }

        let castDevice = makeCastDevice(from: device)

        // Check if it's a YouTube URL
        if CastController.isYouTubeURL(url) {
            if let videoId = CastController.extractYouTubeVideoId(url) {
                Task { [weak self] in
                    do {
                        try await self?.castController.castYouTube(videoId: videoId, to: castDevice)
                    } catch {
                        Logger(subsystem: "ro.pom.radio", category: "OutputManager").error("castYouTube failed: \(error)")
                    }
                }
                return
            }
        }

        Task {
            do {
                try await castController.cast(url: url, to: castDevice)
            } catch {
                Logger(subsystem: "ro.pom.radio", category: "OutputManager").error("Cast failed: \(error)")
            }
        }
    }

    func castStop(device: OutputDevice, proxyPort: Int?) {
        guard device.proto == .chromecast else { return }
        if let port = proxyPort {
            stopProxy(port: port)
        }
        let castDevice = makeCastDevice(from: device)
        Task {
            try? await castController.stop(device: castDevice)
        }
    }

    /// Synchronously stops all active cast sessions and proxies. Blocks until done.
    func shutdownAll() {
        // Stop all proxies (proxy.stop() handles port release internally)
        for (_, proxy) in proxies {
            proxy.stop()
        }
        proxies.removeAll()

        // Stop all cast connections — detached to avoid main actor deadlock
        let sem = DispatchSemaphore(value: 0)
        let controller = castController
        Task.detached {
            await controller.disconnectAll()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
    }

    func castPlayPause(device: OutputDevice) {
        guard device.proto == .chromecast else { return }
        let castDevice = makeCastDevice(from: device)
        Task {
            try? await castController.playPause(device: castDevice)
        }
    }

    func castVolumeUp(device: OutputDevice) {
        guard device.proto == .chromecast else { return }
        castVolume = min(100, castVolume + 10)
        let castDevice = makeCastDevice(from: device)
        Task {
            try? await castController.setVolume(Float(castVolume) / 100.0, device: castDevice)
        }
    }

    func castVolumeDown(device: OutputDevice) {
        guard device.proto == .chromecast else { return }
        castVolume = max(0, castVolume - 10)
        let castDevice = makeCastDevice(from: device)
        Task {
            try? await castController.setVolume(Float(castVolume) / 100.0, device: castDevice)
        }
    }

    func castSetVolume(_ volume: Int, device: OutputDevice) {
        guard device.proto == .chromecast else { return }
        castVolume = volume
        let castDevice = makeCastDevice(from: device)
        Task {
            try? await castController.setVolume(Float(volume) / 100.0, device: castDevice)
        }
    }

    // MARK: - Helpers

    private func makeCastDevice(from device: OutputDevice) -> CastDevice {
        CastDevice(name: device.name, ip: device.id, port: 8009, model: device.model)
    }
}
