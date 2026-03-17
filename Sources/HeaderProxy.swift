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

        // Read the HTTP request
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
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
            self.proxyRequest(path: path, connection: connection)
        }
    }

    private func proxyRequest(path: String, connection: NWConnection) {
        let urlString = "\(targetScheme)://\(targetHost)\(path)"
        guard let url = URL(string: urlString) else {
            connection.cancel()
            return
        }

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { connection.cancel(); return }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data else {
                connection.cancel()
                return
            }

            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"

            var header = "HTTP/1.1 \(httpResponse.statusCode) OK\r\n"
            header += "Content-Type: \(contentType)\r\n"
            header += "Content-Length: \(data.count)\r\n"
            header += "Connection: close\r\n"
            header += "\r\n"

            let responseData = Data(header.utf8) + data
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        task.resume()
    }
}
