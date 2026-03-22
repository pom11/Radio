import Foundation
import Network
import os

// MARK: - Models

struct CastDevice: Identifiable, Hashable {
    var id: String { ip }
    let name: String
    let ip: String
    let port: UInt16
    let model: String
}

struct CastStatus {
    let playerState: String   // PLAYING, PAUSED, IDLE, BUFFERING
    let volumeLevel: Int      // 0-100
}

// MARK: - Protobuf Encoding/Decoding

/// Minimal hand-rolled protobuf for CastMessage.
private enum CastProtobuf {

    // MARK: Varint

    static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var result = Data()
        while v > 0x7F {
            result.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }

    static func decodeVarint(from data: Data, offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: Field encoding

    static func encodeTag(fieldNumber: Int, wireType: Int) -> Data {
        encodeVarint(UInt64(fieldNumber << 3 | wireType))
    }

    static func encodeVarintField(_ fieldNumber: Int, value: UInt64) -> Data {
        var d = encodeTag(fieldNumber: fieldNumber, wireType: 0)
        d.append(encodeVarint(value))
        return d
    }

    static func encodeLengthDelimited(_ fieldNumber: Int, data: Data) -> Data {
        var d = encodeTag(fieldNumber: fieldNumber, wireType: 2)
        d.append(encodeVarint(UInt64(data.count)))
        d.append(data)
        return d
    }

    static func encodeStringField(_ fieldNumber: Int, value: String) -> Data {
        encodeLengthDelimited(fieldNumber, data: Data(value.utf8))
    }

    // MARK: CastMessage encode

    static func encodeCastMessage(
        sourceId: String,
        destinationId: String,
        namespace: String,
        payload: String
    ) -> Data {
        var msg = Data()
        // field 1: protocol_version = 0 (CASTV2_1_0)
        msg.append(encodeVarintField(1, value: 0))
        // field 2: source_id
        msg.append(encodeStringField(2, value: sourceId))
        // field 3: destination_id
        msg.append(encodeStringField(3, value: destinationId))
        // field 4: namespace
        msg.append(encodeStringField(4, value: namespace))
        // field 5: payload_type = 0 (STRING)
        msg.append(encodeVarintField(5, value: 0))
        // field 6: payload_utf8
        msg.append(encodeStringField(6, value: payload))
        return msg
    }

    // MARK: CastMessage decode

    struct DecodedCastMessage {
        var sourceId: String = ""
        var destinationId: String = ""
        var namespace: String = ""
        var payloadUTF8: String = ""
    }

    static func decodeCastMessage(data: Data) -> DecodedCastMessage? {
        var msg = DecodedCastMessage()
        var offset = 0
        while offset < data.count {
            guard let tag = decodeVarint(from: data, offset: &offset) else { return nil }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch wireType {
            case 0: // varint
                guard decodeVarint(from: data, offset: &offset) != nil else { return nil }
            case 2: // length-delimited
                guard let length = decodeVarint(from: data, offset: &offset) else { return nil }
                let len = Int(length)
                guard offset + len <= data.count else { return nil }
                let fieldData = data[offset ..< offset + len]
                offset += len
                let str = String(data: fieldData, encoding: .utf8) ?? ""
                switch fieldNumber {
                case 2: msg.sourceId = str
                case 3: msg.destinationId = str
                case 4: msg.namespace = str
                case 6: msg.payloadUTF8 = str
                default: break
                }
            case 5: // 32-bit
                guard offset + 4 <= data.count else { return nil }
                offset += 4
            case 1: // 64-bit
                guard offset + 8 <= data.count else { return nil }
                offset += 8
            default:
                return nil
            }
        }
        return msg
    }
}

// MARK: - Cast Connection

/// Manages a single TLS connection to a Chromecast device.
private final class CastConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let logger = Logger(subsystem: "ro.pom.radio", category: "CastConnection")
    private var heartbeatTimer: DispatchSourceTimer?
    private let readQueue = DispatchQueue(label: "ro.pom.radio.cast.read")
    private var requestId: Int = 0
    private var transportId: String?
    private var mediaSessionId: Int?
    private var receivedMessages: [CastProtobuf.DecodedCastMessage] = []
    private let lock = NSLock()
    private var isConnected = false

    init(host: String, port: UInt16) {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completionHandler in completionHandler(true) },
            readQueue
        )
        let params = NWParameters(tls: tlsOptions)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
    }

    deinit {
        disconnect()
    }

    // MARK: Connect / Disconnect

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !resumed {
                        resumed = true
                        self.lock.lock()
                        self.isConnected = true
                        self.lock.unlock()
                        cont.resume()
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: error)
                    }
                case .cancelled:
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: CastError.connectionFailed)
                    }
                case .waiting(let error):
                    if !resumed {
                        resumed = true
                        self.connection.cancel()
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            connection.start(queue: readQueue)

            // Timeout: if connection doesn't resolve in 10 seconds, fail
            readQueue.asyncAfter(deadline: .now() + 10) {
                if !resumed {
                    resumed = true
                    self.connection.cancel()
                    cont.resume(throwing: CastError.connectionFailed)
                }
            }
        }

        logger.debug("TLS connected, sending CONNECT")

        // Send initial CONNECT
        sendMessage(
            namespace: Namespace.connection,
            destination: "receiver-0",
            payload: #"{"type":"CONNECT"}"#
        )

        // Start heartbeat
        startHeartbeat()

        // Start reading messages
        startReading()
        logger.debug("Read loop started")
    }

    func disconnect() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        lock.lock()
        isConnected = false
        lock.unlock()
        connection.cancel()
    }

    // MARK: Namespaces

    private enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
        static let youtube = "urn:x-cast:com.google.youtube.mdx"
    }

    // MARK: Low-level send/receive

    private func sendMessage(namespace: String, destination: String, payload: String) {
        let msgData = CastProtobuf.encodeCastMessage(
            sourceId: "sender-0",
            destinationId: destination,
            namespace: namespace,
            payload: payload
        )
        // Frame: 4-byte big-endian length + message
        var length = UInt32(msgData.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(msgData)

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.logger.error("Send error (\(namespace, privacy: .public) → \(destination, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    private func startReading() {
        guard isConnected else { return }
        // Read 4-byte length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, let data, data.count == 4 else {
                if let error {
                    self?.logger.debug("Read header error: \(error.localizedDescription)")
                }
                return
            }
            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.readMessageBody(length: Int(length))
        }
    }

    private func readMessageBody(length: Int) {
        guard length > 0, length < 1_000_000 else {
            startReading()
            return
        }
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let msg = CastProtobuf.decodeCastMessage(data: data) {
                self.handleMessage(msg)
            }
            self.startReading()
        }
    }

    private func handleMessage(_ msg: CastProtobuf.DecodedCastMessage) {
        logger.debug("Received: ns=\(msg.namespace) from=\(msg.sourceId)")

        // Respond to PINGs
        if msg.namespace == Namespace.heartbeat, msg.payloadUTF8.contains("\"PING\"") {
            sendMessage(
                namespace: Namespace.heartbeat,
                destination: msg.sourceId,
                payload: #"{"type":"PONG"}"#
            )
            return
        }

        // Store message for waiters (cap at 50 to prevent unbounded growth)
        lock.lock()
        receivedMessages.append(msg)
        if receivedMessages.count > 50 {
            receivedMessages.removeFirst(receivedMessages.count - 50)
        }
        lock.unlock()
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: readQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.sendMessage(
                namespace: Namespace.heartbeat,
                destination: "receiver-0",
                payload: #"{"type":"PING"}"#
            )
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // MARK: Wait for message

    private func waitForMessage(
        namespace: String? = nil,
        containingType type: String? = nil,
        containing substring: String? = nil,
        timeout: TimeInterval = 10
    ) async -> CastProtobuf.DecodedCastMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let idx = receivedMessages.firstIndex(where: { msg in
                if let ns = namespace, msg.namespace != ns { return false }
                if let t = type, !msg.payloadUTF8.contains("\"\(t)\"") { return false }
                if let s = substring, !msg.payloadUTF8.contains(s) { return false }
                return true
            }) {
                let msg = receivedMessages.remove(at: idx)
                lock.unlock()
                return msg
            }
            lock.unlock()
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        return nil
    }

    // MARK: Next request ID

    private func nextRequestId() -> Int {
        lock.lock()
        requestId += 1
        let rid = requestId
        lock.unlock()
        return rid
    }

    // MARK: High-level commands

    func launchApp(appId: String) async throws -> String {
        let rid = nextRequestId()
        let payload = #"{"type":"LAUNCH","appId":"\#(appId)","requestId":\#(rid)}"#
        sendMessage(namespace: Namespace.receiver, destination: "receiver-0", payload: payload)

        // Wait for RECEIVER_STATUS that has applications (skip idle status broadcasts)
        guard let msg = await waitForMessage(namespace: Namespace.receiver, containingType: "RECEIVER_STATUS", containing: "\"applications\"", timeout: 15) else {
            logger.error("launchApp: no RECEIVER_STATUS within 15s")
            throw CastError.launchFailed
        }

        // Parse transport ID from JSON
        guard let jsonData = msg.payloadUTF8.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let apps = status["applications"] as? [[String: Any]],
              let app = apps.first,
              let tid = app["transportId"] as? String
        else {
            logger.error("launchApp: RECEIVER_STATUS missing transportId")
            throw CastError.launchFailed
        }

        transportId = tid

        // Connect to the transport
        sendMessage(
            namespace: Namespace.connection,
            destination: tid,
            payload: #"{"type":"CONNECT"}"#
        )

        // Small delay for connection to establish
        try? await Task.sleep(nanoseconds: 500_000_000)
        return tid
    }

    func loadMedia(url: String, contentType: String, streamType: String) async throws {
        let tid = try await ensureMediaReceiver()
        let rid = nextRequestId()
        let payload = #"{"type":"LOAD","requestId":\#(rid),"media":{"contentId":"\#(url)","contentType":"\#(contentType)","streamType":"\#(streamType)"},"autoplay":true}"#
        logger.debug("LOAD \(contentType) \(streamType) → \(tid)")
        sendMessage(namespace: Namespace.media, destination: tid, payload: payload)

        // Wait for media status to get session ID
        if let msg = await waitForMessage(namespace: Namespace.media, containingType: "MEDIA_STATUS", timeout: 10) {
            parseMediaSessionId(from: msg.payloadUTF8)
        }
    }

    func castYouTubeVideo(videoId: String) async throws {
        let tid = try await launchApp(appId: "233637DE")
        let payload = #"{"type":"flingVideo","data":{"currentTime":0,"videoId":"\#(videoId)"}}"#
        sendMessage(namespace: Namespace.youtube, destination: tid, payload: payload)
    }

    func getYouTubeScreenId() async throws -> String {
        let tid = try await launchApp(appId: "233637DE")
        sendMessage(namespace: Namespace.youtube, destination: tid,
                    payload: #"{"type":"getMdxSessionStatus"}"#)

        if let msg = await waitForMessage(namespace: Namespace.youtube, containingType: "mdxSessionStatus", timeout: 10),
           let data = msg.payloadUTF8.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessionData = json["data"] as? [String: Any],
           let screenId = sessionData["screenId"] as? String {
            return screenId
        }
        throw CastError.timeout
    }

    func playPause() async throws {
        let tid = try await ensureMediaReceiver()

        // Request current status
        let statusRid = nextRequestId()
        sendMessage(
            namespace: Namespace.media,
            destination: tid,
            payload: #"{"type":"GET_STATUS","requestId":\#(statusRid)}"#
        )

        if let msg = await waitForMessage(namespace: Namespace.media, containingType: "MEDIA_STATUS", timeout: 5) {
            parseMediaSessionId(from: msg.payloadUTF8)

            if msg.payloadUTF8.contains("\"PLAYING\"") {
                let rid = nextRequestId()
                let msid = mediaSessionId ?? 1
                sendMessage(
                    namespace: Namespace.media,
                    destination: tid,
                    payload: #"{"type":"PAUSE","requestId":\#(rid),"mediaSessionId":\#(msid)}"#
                )
            } else {
                let rid = nextRequestId()
                let msid = mediaSessionId ?? 1
                sendMessage(
                    namespace: Namespace.media,
                    destination: tid,
                    payload: #"{"type":"PLAY","requestId":\#(rid),"mediaSessionId":\#(msid)}"#
                )
            }
        }
    }

    func stop() async throws {
        // Try to stop media
        if let tid = transportId {
            let rid = nextRequestId()
            let msid = mediaSessionId ?? 1
            sendMessage(
                namespace: Namespace.media,
                destination: tid,
                payload: #"{"type":"STOP","requestId":\#(rid),"mediaSessionId":\#(msid)}"#
            )
        }

        // Also stop the receiver app
        let rid = nextRequestId()
        sendMessage(
            namespace: Namespace.receiver,
            destination: "receiver-0",
            payload: #"{"type":"STOP","requestId":\#(rid)}"#
        )
    }

    func setVolume(_ level: Float) {
        let rid = nextRequestId()
        let clamped = max(0, min(1, level))
        let payload = #"{"type":"SET_VOLUME","volume":{"level":\#(clamped)},"requestId":\#(rid)}"#
        sendMessage(namespace: Namespace.receiver, destination: "receiver-0", payload: payload)
    }

    func getStatus() async -> CastStatus {
        // Get receiver status for volume
        let rRid = nextRequestId()
        sendMessage(
            namespace: Namespace.receiver,
            destination: "receiver-0",
            payload: #"{"type":"GET_STATUS","requestId":\#(rRid)}"#
        )

        var volumeLevel = 50
        var playerState = "IDLE"

        if let rMsg = await waitForMessage(namespace: Namespace.receiver, containingType: "RECEIVER_STATUS", timeout: 5) {
            if let jsonData = rMsg.payloadUTF8.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let status = json["status"] as? [String: Any],
               let volume = status["volume"] as? [String: Any],
               let level = volume["level"] as? Double {
                volumeLevel = Int(level * 100)
            }
        }

        // Get media status if we have a transport
        if let tid = transportId {
            let mRid = nextRequestId()
            sendMessage(
                namespace: Namespace.media,
                destination: tid,
                payload: #"{"type":"GET_STATUS","requestId":\#(mRid)}"#
            )
            if let mMsg = await waitForMessage(namespace: Namespace.media, containingType: "MEDIA_STATUS", timeout: 5) {
                if let jsonData = mMsg.payloadUTF8.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let statuses = json["status"] as? [[String: Any]],
                   let first = statuses.first,
                   let state = first["playerState"] as? String {
                    playerState = state
                }
            }
        }

        return CastStatus(playerState: playerState, volumeLevel: volumeLevel)
    }

    // MARK: Helpers

    private func ensureMediaReceiver() async throws -> String {
        if let tid = transportId {
            return tid
        }
        return try await launchApp(appId: "CC1AD845")
    }

    private func parseMediaSessionId(from payload: String) {
        guard let jsonData = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let statuses = json["status"] as? [[String: Any]],
              let first = statuses.first,
              let msid = first["mediaSessionId"] as? Int
        else { return }
        lock.lock()
        mediaSessionId = msid
        lock.unlock()
    }
}

// MARK: - Cast Errors

enum CastError: LocalizedError {
    case connectionFailed
    case launchFailed
    case noDeviceFound
    case invalidURL
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to connect to Chromecast"
        case .launchFailed: return "Failed to launch app on Chromecast"
        case .noDeviceFound: return "No Chromecast device found"
        case .invalidURL: return "Invalid cast URL"
        case .timeout: return "Chromecast response timed out"
        }
    }
}

// MARK: - CastController

final class CastController: @unchecked Sendable {
    static let shared = CastController()

    private let logger = Logger(subsystem: "ro.pom.radio", category: "CastController")
    private var connections: [String: CastConnection] = [:]  // keyed by device IP
    private var pendingConnections: [String: Task<CastConnection, Error>] = [:]
    private let lock = NSLock()

    // MARK: - Content Type Detection

    static func detectContentType(_ url: String) -> String {
        let lower = url.lowercased()
        if lower.contains(".mp3") || lower.contains("/mp3") { return "audio/mpeg" }
        if lower.contains(".ogg") || lower.contains("/ogg") { return "audio/ogg" }
        if lower.contains(".flac") { return "audio/flac" }
        if lower.contains(".m3u8") { return "application/x-mpegURL" }
        if lower.contains(".mp4") { return "video/mp4" }
        if lower.contains(".webm") { return "video/webm" }
        return "audio/aac"
    }

    // MARK: - YouTube Helpers

    private static let youtubeVideoPatterns = [
        #"(?:youtube\.com/watch\?.*v=|youtu\.be/)([\w-]{11})"#,
        #"youtube\.com/live/([\w-]{11})"#,
        #"youtube\.com/shorts/([\w-]{11})"#,
    ]

    static func extractYouTubeVideoId(_ url: String) -> String? {
        for pattern in youtubeVideoPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               let range = Range(match.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }

    static func isYouTubeURL(_ url: String) -> Bool {
        url.contains("youtube.com") || url.contains("youtu.be")
    }

    // MARK: - Discovery

    func discoverDevices(timeout: TimeInterval = 5) async -> [CastDevice] {
        await withCheckedContinuation { continuation in
            var discovered: [CastDevice] = []
            var resolveConns: [NWConnection] = []
            let lock = NSLock()
            let browser = NWBrowser(for: .bonjour(type: "_googlecast._tcp.", domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "ro.pom.radio.cast.discovery")

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        let params = NWParameters.tcp
                        let resolveConn = NWConnection(to: result.endpoint, using: params)
                        lock.lock()
                        resolveConns.append(resolveConn)
                        lock.unlock()
                        resolveConn.stateUpdateHandler = { state in
                            if case .ready = state {
                                if let path = resolveConn.currentPath,
                                   let endpoint = path.remoteEndpoint,
                                   case .hostPort(let host, let port) = endpoint {
                                    var ip = ""
                                    switch host {
                                    case .ipv4(let addr):
                                        ip = "\(addr)"
                                    case .ipv6(let addr):
                                        ip = "\(addr)"
                                    case .name(let hostname, _):
                                        ip = hostname
                                    @unknown default:
                                        break
                                    }
                                    var deviceName = name
                                    var model = "Chromecast"
                                    if case .bonjour(let txtRecord) = result.metadata {
                                        if let fn = txtRecordLookup(txtRecord, key: "fn") {
                                            deviceName = fn
                                        }
                                        if let md = txtRecordLookup(txtRecord, key: "md") {
                                            model = md
                                        }
                                    }
                                    let device = CastDevice(
                                        name: deviceName,
                                        ip: ip,
                                        port: port.rawValue,
                                        model: model
                                    )
                                    lock.lock()
                                    if !discovered.contains(where: { $0.ip == device.ip }) {
                                        discovered.append(device)
                                    }
                                    lock.unlock()
                                }
                                resolveConn.cancel()
                            } else if case .failed = state {
                                resolveConn.cancel()
                            }
                        }
                        resolveConn.start(queue: queue)
                    }
                }
            }

            browser.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                // Cancel any resolve connections still in progress
                lock.lock()
                let pending = resolveConns
                let result = discovered
                lock.unlock()
                for conn in pending { conn.cancel() }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Connection Management

    private func getConnection(for device: CastDevice) async throws -> CastConnection {
        lock.lock()
        // Return existing live connection
        if let existing = connections[device.ip] {
            lock.unlock()
            return existing
        }
        // If another caller is already connecting, await that same task
        if let pending = pendingConnections[device.ip] {
            lock.unlock()
            return try await pending.value
        }
        // Create a single connection task that all concurrent callers will share
        let task = Task<CastConnection, Error> {
            let conn = CastConnection(host: device.ip, port: device.port)
            try await conn.connect()
            self.lock.lock()
            self.connections[device.ip] = conn
            self.pendingConnections.removeValue(forKey: device.ip)
            self.lock.unlock()
            self.logger.debug("Connected to \(device.name) at \(device.ip):\(device.port)")
            return conn
        }
        pendingConnections[device.ip] = task
        lock.unlock()

        do {
            return try await task.value
        } catch {
            lock.lock()
            pendingConnections.removeValue(forKey: device.ip)
            lock.unlock()
            throw error
        }
    }

    private func removeConnection(for device: CastDevice) {
        lock.lock()
        let conn = connections.removeValue(forKey: device.ip)
        lock.unlock()
        conn?.disconnect()
    }

    // MARK: - Public API

    func cast(url: String, to device: CastDevice, contentType: String? = nil, streamType: String? = nil) async throws {
        let ct = contentType ?? CastController.detectContentType(url)
        let st: String
        if let streamType {
            st = streamType
        } else if ct.hasPrefix("audio/") || ct == "application/x-mpegURL" {
            st = "LIVE"
        } else {
            st = "BUFFERED"
        }

        // Retry up to 3 times — Chromecast may not respond after rapid reconnection
        var lastError: Error?
        for attempt in 1...3 {
            do {
                removeConnection(for: device)
                if attempt > 1 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                let conn = try await getConnection(for: device)
                try await conn.loadMedia(url: url, contentType: ct, streamType: st)
                logger.debug("Casting [\(ct), \(st)] to \(device.name)")
                return
            } catch {
                lastError = error
                logger.warning("cast attempt \(attempt) failed: \(error)")
            }
        }
        throw lastError ?? CastError.launchFailed
    }

    func castYouTube(videoId: String, to device: CastDevice) async throws {
        // Retry up to 3 times — first launch may fail if YouTube app is cold
        var lastError: Error?
        for attempt in 1...3 {
            do {
                if attempt > 1 {
                    removeConnection(for: device)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                let conn = try await getConnection(for: device)
                let screenId = try await conn.getYouTubeScreenId()
                logger.debug("YouTube screenId: \(screenId) (attempt \(attempt))")

                // Brief pause for YouTube Lounge API to initialize
                try await Task.sleep(nanoseconds: 500_000_000)

                try await YouTubeLoungeAPI.playVideo(videoId: videoId, screenId: screenId)
                logger.debug("YouTube (Lounge) [\(videoId)] -> \(device.name)")
                return
            } catch {
                lastError = error
                logger.warning("castYouTube attempt \(attempt) failed: \(error)")
            }
        }
        throw lastError ?? CastError.launchFailed
    }

    func playPause(device: CastDevice) async throws {
        let conn = try await getConnection(for: device)
        try await conn.playPause()
    }

    func stop(device: CastDevice) async throws {
        let conn = try await getConnection(for: device)
        try await conn.stop()
        removeConnection(for: device)
    }

    func setVolume(_ level: Float, device: CastDevice) async throws {
        let conn = try await getConnection(for: device)
        conn.setVolume(level)
    }

    func getStatus(device: CastDevice) async throws -> CastStatus {
        let conn = try await getConnection(for: device)
        return await conn.getStatus()
    }

    /// Stop all active connections. Used during app shutdown.
    func disconnectAll() async {
        lock.lock()
        let allConnections = connections
        connections.removeAll()
        pendingConnections.removeAll()
        lock.unlock()

        for (_, conn) in allConnections {
            try? await conn.stop()
            conn.disconnect()
        }
    }
}

// MARK: - TXT Record Helper

/// Look up a key in a Bonjour TXT record.
private func txtRecordLookup(_ record: NWTXTRecord, key: String) -> String? {
    record[key]
}
