import Foundation
import Network
import os

/// Lightweight local HTTP proxy that injects custom headers into all requests.
/// Uses NWListener (event-driven, no blocking threads) instead of raw sockets.
/// AVPlayer connects to http://127.0.0.1:<port>/path and the proxy forwards
/// to the real server with headers injected.
final class HeaderProxy: @unchecked Sendable {

    private let log = Logger(subsystem: "ro.pom.radio", category: "HeaderProxy")
    private let headers: [String: String]
    private let targetHost: String
    private let targetScheme: String
    private var listener: NWListener?
    private var port: Int = 0
    private let queue = DispatchQueue(label: "ro.pom.radio.headerproxy")
    private let session: URLSession

    // Per-segment URL cache: maps sequence number → segment URL
    // When CDN rotates URLs for same sequence, we rewrite to keep consistency
    private var segmentURLCache: [Int: String] = [:]

    init(targetURL: URL, headers: [String: String]) {
        self.headers = headers
        self.targetHost = targetURL.host ?? ""
        self.targetScheme = targetURL.scheme ?? "https"
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// Start proxy, returns the local base URL or nil on failure.
    func start() -> URL? {
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            listener = try NWListener(using: params, on: .any)
        } catch {
            log.error("Failed to create listener: \(error)")
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: URL?

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = self.listener?.port?.rawValue {
                    self.port = Int(p)
                    result = URL(string: "http://127.0.0.1:\(p)")
                    self.log.debug("HeaderProxy listening on port \(p)")
                }
                semaphore.signal()
            case .failed(let error):
                self.log.error("Listener failed: \(error)")
                semaphore.signal()
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
        semaphore.wait()
        return result
    }

    func stop() {
        listener?.cancel()
        listener = nil
        session.invalidateAndCancel()
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        log.debug("new connection accepted")

        // Read the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                self?.log.debug("connection read failed: \(error?.localizedDescription ?? "no data")")
                connection.cancel()
                return
            }

            guard let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else { connection.cancel(); return }

            let path = String(parts[1])
            self.log.debug("request: \(firstLine, privacy: .public)")
            self.proxyRequest(path: path, connection: connection)
        }
    }

    private func proxyRequest(path: String, connection: NWConnection) {
        let urlString = "\(targetScheme)://\(targetHost)\(path)"
        guard let url = URL(string: urlString) else {
            connection.cancel()
            return
        }

        let isPlaylist = path.contains(".m3u8")
        self.log.debug("proxy \(isPlaylist ? "m3u8" : "seg", privacy: .public) \(path.prefix(80), privacy: .public)")

        // For m3u8 playlists: stabilize segment URLs to prevent -12312 errors
        if isPlaylist {
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                guard let self, let data, let httpResponse = response as? HTTPURLResponse, error == nil else {
                    connection.cancel()
                    return
                }
                let body: Data
                if let text = String(data: data, encoding: .utf8),
                   let seq = self.parseMediaSequence(text) {
                    let stabilized = self.stabilizePlaylist(text, baseSequence: seq)
                    body = Data(stabilized.utf8)
                } else {
                    body = data
                }
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/vnd.apple.mpegurl"
                var header = "HTTP/1.1 \(httpResponse.statusCode) OK\r\n"
                header += "Content-Type: \(contentType)\r\n"
                header += "Content-Length: \(body.count)\r\n"
                header += "Connection: close\r\n"
                header += "\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
            task.resume()
            return
        }

        // Non-playlist: stream through as before
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let delegate = StreamingDelegate(connection: connection)
        let task = session.dataTask(with: request)
        delegate.task = task
        objc_setAssociatedObject(task, &StreamingDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        task.delegate = delegate
        task.resume()
    }

    private func parseMediaSequence(_ text: String) -> Int? {
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let value = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    /// Rewrite segment URLs in the playlist to keep them consistent across refreshes.
    /// If AVPlayer already saw a URL for sequence N, keep using that URL even if
    /// the CDN rotated to a different edge server.
    private func stabilizePlaylist(_ text: String, baseSequence: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        var seqNum = baseSequence
        var replaced = 0
        var newSegs = 0

        for i in 0..<lines.count {
            let line = lines[i]
            // Skip comments/tags
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            // This is a segment URL line
            let url = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cached = segmentURLCache[seqNum] {
                if cached != url {
                    lines[i] = cached
                    replaced += 1
                }
            } else {
                segmentURLCache[seqNum] = url
                newSegs += 1
            }
            seqNum += 1
        }

        // Prune old entries (keep last 30 segments)
        let minKeep = baseSequence - 10
        segmentURLCache = segmentURLCache.filter { $0.key >= minKeep }

        if replaced > 0 {
            log.debug("m3u8 stabilized seq=\(baseSequence): \(replaced) replaced, \(newSegs) new")
        } else {
            log.debug("m3u8 seq=\(baseSequence): \(newSegs) new segments")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Streaming Delegate

/// Forwards URLSession response chunks directly to an NWConnection as they arrive.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate {
    static var key = 0
    let connection: NWConnection
    var headerSent = false
    weak var task: URLSessionDataTask?
    private let log = Logger(subsystem: "ro.pom.radio", category: "HeaderProxy")
    private var startTime: CFAbsoluteTime = 0
    private var totalBytes = 0
    private var chunkCount = 0

    init(connection: NWConnection) {
        self.connection = connection
        self.startTime = CFAbsoluteTimeGetCurrent()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            connection.cancel()
            return
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let ttfb = CFAbsoluteTimeGetCurrent() - startTime
        log.debug("response \(httpResponse.statusCode) \(contentType, privacy: .public) TTFB=\(String(format: "%.0f", ttfb * 1000))ms")

        var header = "HTTP/1.1 \(httpResponse.statusCode) OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        if let cl = httpResponse.value(forHTTPHeaderField: "Content-Length") {
            header += "Content-Length: \(cl)\r\n"
        }
        header += "Connection: close\r\n"
        header += "\r\n"

        headerSent = true
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        totalBytes += data.count
        chunkCount += 1
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        if let error {
            log.warning("request failed after \(String(format: "%.0f", elapsed * 1000))ms: \(error.localizedDescription, privacy: .public)")
        } else {
            log.debug("done \(self.totalBytes) bytes in \(self.chunkCount) chunks, \(String(format: "%.0f", elapsed * 1000))ms")
        }
        connection.cancel()
    }
}
