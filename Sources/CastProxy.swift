import Foundation
import Network
import os

/// Native Swift replacement for `cast_proxy.py`.
///
/// Runs an in-process HTTP server (via Network.framework) that remuxes HLS
/// streams into fragmented MP4 using ffmpeg, suitable for Chromecast playback.
final class CastProxy: @unchecked Sendable {

    // MARK: - Shared Port Allocator

    private static let portLock = NSLock()
    private static var usedPorts: Set<Int> = []
    private static var nextPort: Int = 9723

    static func allocatePort() -> Int {
        portLock.lock()
        defer { portLock.unlock() }
        while usedPorts.contains(nextPort) {
            nextPort += 1
        }
        let port = nextPort
        usedPorts.insert(port)
        nextPort += 1
        return port
    }

    static func releasePort(_ port: Int) {
        portLock.lock()
        defer { portLock.unlock() }
        usedPorts.remove(port)
    }

    // MARK: - Instance Properties

    private let logger = Logger(subsystem: "ro.pom.radio", category: "CastProxy")
    private let lock = NSLock()

    private var listener: NWListener?
    private var hlsURL: String = ""
    private var httpHeaders: [String: String] = [:]
    private var port: Int = 0
    private var ffmpegProcesses: [Process] = []
    private let listenerQueue = DispatchQueue(label: "ro.pom.radio.castproxy")

    // MARK: - ffmpeg Discovery

    private static let ffmpegPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }()

    // MARK: - Local IP

    private func getLocalIP() -> String {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return "127.0.0.1" }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(80).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &addr.sin_addr)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return "127.0.0.1" }

        var localAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &localAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &len)
            }
        }
        guard nameResult == 0 else { return "127.0.0.1" }

        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var inAddr = localAddr.sin_addr
        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    // MARK: - Lifecycle

    /// Start the proxy server and wait for it to be ready.
    func start(hlsURL: String, port: Int = 9723, headers: [String: String] = [:]) async -> String? {
        stop()

        self.hlsURL = hlsURL
        self.httpHeaders = headers
        self.port = port

        let localIP = getLocalIP()
        let proxyURL = "http://\(localIP):\(port)/stream.mp4"

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            logger.error("Invalid port \(port)")
            return nil
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let newListener = try NWListener(using: params, on: nwPort)

            // Wait for the listener to actually be ready before returning the URL
            let ready: Bool = await withCheckedContinuation { cont in
                var resumed = false
                newListener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.logger.debug("Proxy listening on port \(port)")
                        if !resumed {
                            resumed = true
                            cont.resume(returning: true)
                        }
                    case .failed(let error):
                        self?.logger.error("Listener failed: \(error)")
                        if !resumed {
                            resumed = true
                            cont.resume(returning: false)
                        }
                    case .cancelled:
                        if !resumed {
                            resumed = true
                            cont.resume(returning: false)
                        }
                    default:
                        break
                    }
                }

                newListener.newConnectionHandler = { [weak self] connection in
                    self?.handleConnection(connection)
                }

                newListener.start(queue: self.listenerQueue)

                // Timeout after 5 seconds
                self.listenerQueue.asyncAfter(deadline: .now() + 5) {
                    if !resumed {
                        resumed = true
                        cont.resume(returning: false)
                    }
                }
            }

            guard ready else {
                newListener.cancel()
                return nil
            }

            lock.lock()
            self.listener = newListener
            lock.unlock()

            logger.debug("Proxy started: \(proxyURL, privacy: .public)")
            return proxyURL
        } catch {
            logger.error("Failed to create listener: \(error)")
            return nil
        }
    }

    func stop() {
        lock.lock()
        let currentListener = listener
        listener = nil
        let processes = ffmpegProcesses
        ffmpegProcesses.removeAll()
        let currentPort = port
        lock.unlock()

        currentListener?.cancel()

        for proc in processes {
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
        }

        if currentPort != 0 {
            CastProxy.releasePort(currentPort)
        }

        if currentListener != nil {
            logger.debug("Proxy stopped on port \(currentPort)")
        }
    }

    deinit {
        stop()
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let connQueue = DispatchQueue(label: "ro.pom.radio.castproxy.conn.\(arc4random())")
        connection.start(queue: connQueue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            self.routeRequest(request, connection: connection)
        }
    }

    private func routeRequest(_ request: String, connection: NWConnection) {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            send404(connection)
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", parts[1] == "/stream.mp4" else {
            send404(connection)
            return
        }

        serveStream(connection)
    }

    // MARK: - Streaming

    private func serveStream(_ connection: NWConnection) {
        serveStreamAttempt(connection: connection, attempt: 1)
    }

    private func serveStreamAttempt(connection: NWConnection, attempt: Int) {
        guard let path = CastProxy.ffmpegPath else {
            logger.error("ffmpeg not found — Chromecast proxy requires ffmpeg")
            send502(connection)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var args = [
            "-reconnect", "1",
            "-reconnect_streamed", "1",
            "-reconnect_delay_max", "3",
            "-user_agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        ]
        if !httpHeaders.isEmpty {
            let headerString = httpHeaders.map { "\($0.key): \($0.value)\r\n" }.joined()
            args += ["-headers", headerString]
        }
        // Disable strict extension checks — pirate IPTV streams use
        // non-standard segment URLs (.htm, auth tokens, no extension)
        args += ["-extension_picky", "0"]
        args += [
            "-i", hlsURL,
            "-c", "copy",
            "-bsf:a", "aac_adtstoasc",
            "-f", "mp4",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-loglevel", "error",
            "pipe:1",
        ]
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch ffmpeg: \(error)")
            send502(connection)
            return
        }

        trackProcess(process)

        // Stream on a background thread (blocking reads from ffmpeg)
        let maxAttempts = 3
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fileHandle = stdout.fileHandleForReading

            let initData = fileHandle.readData(ofLength: 65536)
            if initData.isEmpty {
                let errData = stderr.fileHandleForReading.readData(ofLength: 4096)
                let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
                self.logger.error("ffmpeg produced no output (attempt \(attempt)/\(maxAttempts)): \(errMsg, privacy: .public)")
                process.terminate()
                process.waitUntilExit()
                self.untrackProcess(process)

                if attempt < maxAttempts {
                    self.logger.info("Retrying ffmpeg (attempt \(attempt + 1)/\(maxAttempts))...")
                    Thread.sleep(forTimeInterval: 1)
                    self.serveStreamAttempt(connection: connection, attempt: attempt + 1)
                } else {
                    self.send502(connection)
                }
                return
            }

            self.streamFromInit(initData: initData, fileHandle: fileHandle, process: process, connection: connection)
        }
    }

    private func streamFromInit(initData: Data, fileHandle: FileHandle, process: Process, connection: NWConnection) {
        // Send HTTP response header + init segment
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        let headerData = Data(header.utf8)

        let sem = DispatchSemaphore(value: 0)
        var failed = false
        connection.send(content: headerData + initData, completion: .contentProcessed { error in
            if error != nil { failed = true }
            sem.signal()
        })
        sem.wait()
        if failed {
            process.terminate()
            untrackProcess(process)
            connection.cancel()
            return
        }

        // Continue streaming chunks
        while process.isRunning {
            let chunk = fileHandle.readData(ofLength: 65536)
            if chunk.isEmpty { break }

            let sendSem = DispatchSemaphore(value: 0)
            var sendError: NWError?

            connection.send(content: chunk, completion: .contentProcessed { error in
                sendError = error
                sendSem.signal()
            })

            sendSem.wait()

            if sendError != nil {
                logger.debug("Client disconnected, terminating ffmpeg")
                break
            }
        }

        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        untrackProcess(process)
        connection.cancel()
    }

    // MARK: - HTTP Responses

    private func send404(_ connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send502(_ connection: NWConnection) {
        let body = "ffmpeg produced no output"
        let response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Process Tracking

    private func trackProcess(_ process: Process) {
        lock.lock()
        ffmpegProcesses.append(process)
        lock.unlock()
    }

    private func untrackProcess(_ process: Process) {
        lock.lock()
        ffmpegProcesses.removeAll { $0 === process }
        lock.unlock()
    }
}
