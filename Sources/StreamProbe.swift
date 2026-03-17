import Foundation
import Network
import os.log

private let log = Logger(subsystem: "ro.pom.radio", category: "probe")

// MARK: - StreamProbe

enum StreamProbe {

    // MARK: - URL Pattern Constants

    private static let youtubeVideoPatterns = [
        #"(?:youtube\.com/watch\?.*v=|youtu\.be/)([\w-]{11})"#,
        #"youtube\.com/live/([\w-]{11})"#,
        #"youtube\.com/shorts/([\w-]{11})"#,
    ]

    private static let youtubeChannelPatterns = [
        #"youtube\.com/@[\w.-]+"#,
        #"youtube\.com/channel/[\w-]+"#,
        #"youtube\.com/c/[\w.-]+"#,
        #"youtube\.com/user/[\w.-]+"#,
    ]

    private static let audioHints = [
        ".mp3", ".aac", ".ogg", ".opus", ".flac", ".pls", ".m3u",
        ":8443/", ":8000/", ":8080/", "/stream", "/listen",
    ]

    private static let videoHints = [".mp4", ".mkv", ".webm", ".m3u8", ".mpd"]

    // MARK: - URL Pattern Detection

    static func isYouTube(_ url: String) -> Bool {
        url.contains("youtube.com") || url.contains("youtu.be")
    }

    static func isYouTubeChannel(_ url: String) -> Bool {
        youtubeChannelPatterns.contains { pattern in
            url.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func isLiveChannel(_ url: String) -> Bool {
        if isYouTubeChannel(url) { return true }
        let lower = url.lowercased()
        let notChannel = ["/videos", "/clip", "/directory", "/p/", "/settings", "/category", "/following"]
        // Twitch channel: twitch.tv/username
        if lower.contains("twitch.tv/") {
            return !notChannel.contains(where: { lower.contains($0) })
        }
        // Kick channel: kick.com/username
        if lower.contains("kick.com/") {
            return !notChannel.contains(where: { lower.contains($0) })
        }
        return false
    }

    static func extractYouTubeID(_ url: String) -> String? {
        for pattern in youtubeVideoPatterns {
            if url.range(of: pattern, options: .regularExpression) != nil,
               let capture = try? NSRegularExpression(pattern: pattern)
                .firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
               capture.numberOfRanges > 1,
               let range = Range(capture.range(at: 1), in: url) {
                return String(url[range])
            }
        }
        return nil
    }

    static func guessType(_ url: String) -> String? {
        let lower = url.lowercased()
        if isLiveChannel(url) {
            let notChannel = ["/watch", "/live/", "/video", "/clip"]
            if !notChannel.contains(where: { lower.contains($0) }) {
                return "channel"
            }
        }
        if audioHints.contains(where: { lower.contains($0) }) {
            return "audio"
        }
        if isYouTube(url) {
            return "video"
        }
        if videoHints.contains(where: { lower.contains($0) }) {
            return "video"
        }
        return nil
    }

    static func isDirectStream(_ url: String) -> Bool {
        let lower = url.lowercased()
        return audioHints.contains(where: { lower.contains($0) })
    }

    // MARK: - HTTP Probe (raw TCP, handles ICY protocol)

    static func httpProbe(_ url: String) async -> ProbeResult? {
        guard let comps = URLComponents(string: url),
              let host = comps.host else { return nil }

        let isHTTPS = comps.scheme == "https"
        let port = comps.port ?? (isHTTPS ? 443 : 80)
        var path = comps.path.isEmpty ? "/" : comps.path
        if let query = comps.query { path += "?" + query }

        let request = "GET \(path) HTTP/1.0\r\nHost: \(host)\r\nIcy-MetaData: 1\r\nUser-Agent: Radio/1.0\r\nConnection: close\r\n\r\n"

        return await withCheckedContinuation { cont in
            let params: NWParameters = isHTTPS ? .tls : .tcp
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                          using: params)

            var resumed = false
            let finish: (ProbeResult?) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                cont.resume(returning: result)
            }

            // Timeout after 5 seconds
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                finish(nil)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let data = request.data(using: .utf8)!
                    connection.send(content: data, completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        Self.receiveHeaders(connection: connection, completion: finish)
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func receiveHeaders(connection: NWConnection,
                                        completion: @escaping (ProbeResult?) -> Void) {
        var buffer = Data()

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data { buffer.append(data) }

                if buffer.count > 8192 || isComplete || error != nil ||
                   buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    completion(Self.parseProbeHeaders(buffer))
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    private static func parseProbeHeaders(_ data: Data) -> ProbeResult? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) ??
                String(data: headerData, encoding: .isoLatin1) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let ct = (headers["content-type"] ?? "").lowercased()
        let icyName = headers["icy-name"] ?? ""
        let isICY = firstLine.hasPrefix("ICY ")

        if isICY || headers["icy-metaint"] != nil || ct.hasPrefix("audio/") {
            return ProbeResult(type: "audio", title: icyName, is_live: true)
        }
        if ct.hasPrefix("video/") {
            return ProbeResult(type: "video", title: "", is_live: false)
        }
        if ct.contains("mpegurl") {
            return ProbeResult(type: "video", title: "", is_live: true)
        }
        if ct.contains("dash") || ct.contains("mpd") {
            return ProbeResult(type: "video", title: "", is_live: true)
        }
        return nil
    }

    // MARK: - HTTP Probe returning full resolve info

    private static func httpProbeResolve(_ url: String) async -> (contentType: String, title: String)? {
        guard let comps = URLComponents(string: url),
              let host = comps.host else { return nil }

        let isHTTPS = comps.scheme == "https"
        let port = comps.port ?? (isHTTPS ? 443 : 80)
        var path = comps.path.isEmpty ? "/" : comps.path
        if let query = comps.query { path += "?" + query }

        let request = "GET \(path) HTTP/1.0\r\nHost: \(host)\r\nIcy-MetaData: 1\r\nUser-Agent: Radio/1.0\r\nConnection: close\r\n\r\n"

        return await withCheckedContinuation { cont in
            let params: NWParameters = isHTTPS ? .tls : .tcp
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: UInt16(port))!,
                                          using: params)

            var resumed = false
            let finish: ((contentType: String, title: String)?) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                cont.resume(returning: result)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                finish(nil)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let data = request.data(using: .utf8)!
                    connection.send(content: data, completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        Self.receiveHeadersRaw(connection: connection) { data in
                            guard let data,
                                  let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
                                finish(nil); return
                            }
                            let headerData = data[data.startIndex..<separator.lowerBound]
                            guard let headerText = String(data: headerData, encoding: .utf8) ??
                                    String(data: headerData, encoding: .isoLatin1) else {
                                finish(nil); return
                            }
                            let lines = headerText.components(separatedBy: "\r\n")
                            var headers: [String: String] = [:]
                            for line in lines.dropFirst() {
                                if let ci = line.firstIndex(of: ":") {
                                    let key = line[line.startIndex..<ci].trimmingCharacters(in: .whitespaces).lowercased()
                                    let value = line[line.index(after: ci)...].trimmingCharacters(in: .whitespaces)
                                    headers[key] = value
                                }
                            }
                            let ct = headers["content-type"] ?? ""
                            let title = headers["icy-name"] ?? ""
                            finish((contentType: ct.isEmpty ? "audio/aac" : ct, title: title))
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func receiveHeadersRaw(connection: NWConnection,
                                           completion: @escaping (Data?) -> Void) {
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data { buffer.append(data) }
                if buffer.count > 8192 || isComplete || error != nil ||
                   buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                    completion(buffer)
                    return
                }
                readMore()
            }
        }
        readMore()
    }

    // MARK: - CLI Tool Locator

    private static var toolCache: [String: String] = [:]

    private static func findTool(_ name: String) -> String? {
        if let cached = toolCache[name] { return cached }
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                toolCache[name] = path
                return path
            }
        }
        toolCache[name] = name
        return name
    }

    // MARK: - Process Runner

    private static func runProcess(executable: String, arguments: [String],
                                    timeout: TimeInterval = 30) async -> (stdout: Data, status: Int32)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
                env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                guard (try? process.run()) != nil else {
                    cont.resume(returning: nil)
                    return
                }

                // Timeout
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    if process.isRunning { process.terminate() }
                }
                timer.resume()

                process.waitUntilExit()
                timer.cancel()

                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (stdout: data, status: process.terminationStatus))
            }
        }
    }

    // MARK: - yt-dlp Integration

    static func ytdlpDetect(_ url: String) async -> ProbeResult? {
        guard let ytdlp = findTool("yt-dlp") else {
            log.warning("yt-dlp not found")
            return nil
        }

        guard let result = await runProcess(executable: ytdlp,
                                             arguments: ["--dump-json", "--no-download", url]),
              result.status == 0 else {
            log.debug("yt-dlp detect failed for \(url)")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return nil
        }

        let title = (json["title"] as? String) ?? (json["channel"] as? String) ?? ""
        let isLive = (json["is_live"] as? Bool) ?? false
        let formats = json["formats"] as? [[String: Any]] ?? []

        let hasVideo: Bool
        if formats.isEmpty {
            hasVideo = true
        } else {
            hasVideo = formats.contains { f in
                let vcodec = f["vcodec"] as? String ?? "none"
                return vcodec != "none"
            }
        }

        let stype: String
        if isLiveChannel(url) {
            stype = "channel"
        } else if hasVideo {
            stype = "video"
        } else {
            stype = "audio"
        }

        return ProbeResult(type: stype, title: title, is_live: isLive)
    }

    static func ytdlpResolve(_ url: String, streamType: String = "video") async -> ResolveResult? {
        guard let ytdlp = findTool("yt-dlp") else {
            log.warning("yt-dlp not found")
            return nil
        }

        var resolveURL = url
        if streamType == "channel" && isYouTubeChannel(url) {
            if !url.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("/live") &&
               !url.hasSuffix("/live") {
                resolveURL = url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/live"
            }
        }

        let fmt = streamType == "audio" ? "bestaudio" : "best"
        log.info("yt-dlp resolving: \(resolveURL) fmt=\(fmt)")
        guard let result = await runProcess(executable: ytdlp,
                                             arguments: ["-f", fmt, "--remote-components", "ejs:github", "--dump-json", "--no-download", resolveURL]),
              result.status == 0 else {
            log.error("yt-dlp resolve failed for \(url)")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return nil
        }

        let extractor = ((json["extractor"] as? String) ?? "").lowercased()
        let isYT = extractor.contains("youtube")
        let videoID = isYT ? ((json["id"] as? String) ?? "") : ""
        let isLive = (json["is_live"] as? Bool) ?? false
        let title = (json["title"] as? String) ?? ""
        let formats = json["formats"] as? [[String: Any]] ?? []

        var playableURL = (json["url"] as? String) ?? ""
        var contentType = "video/mp4"
        var fmtName = "http"

        if !formats.isEmpty {
            // Try HLS first
            var foundHLS = false
            for f in formats.reversed() {
                let proto = (f["protocol"] as? String) ?? ""
                if proto == "m3u8_native" || proto == "m3u8" {
                    playableURL = (f["url"] as? String) ?? playableURL
                    contentType = "application/x-mpegURL"
                    fmtName = "hls"
                    foundHLS = true
                    break
                }
            }

            if !foundHLS {
                // Find best matching format
                var best: [String: Any]?
                for f in formats.reversed() {
                    let hasA = ((f["acodec"] as? String) ?? "none") != "none"
                    let hasV = ((f["vcodec"] as? String) ?? "none") != "none"
                    if streamType == "audio" && hasA {
                        best = f; break
                    } else if streamType != "audio" && hasV {
                        best = f; break
                    }
                }
                if best == nil { best = formats.last }

                if let best {
                    playableURL = (best["url"] as? String) ?? playableURL
                    let proto = (best["protocol"] as? String) ?? ""
                    let ext = (best["ext"] as? String) ?? "mp4"
                    if proto.contains("dash") {
                        fmtName = "dash"
                        contentType = "application/dash+xml"
                    } else if ext == "m3u8" {
                        fmtName = "hls"
                        contentType = "application/x-mpegURL"
                    } else {
                        fmtName = "http"
                        contentType = streamType == "audio" ? "audio/\(ext)" : "video/\(ext)"
                    }
                }
            }
        }

        let castURL: String
        if isYT && !videoID.isEmpty {
            castURL = "https://www.youtube.com/watch?v=\(videoID)"
        } else {
            castURL = playableURL
        }

        return ResolveResult(url: playableURL, cast_url: castURL,
                              content_type: contentType, is_live: isLive,
                              format: fmtName, title: title,
                              youtube_id: videoID.isEmpty ? nil : videoID)
    }

    // MARK: - streamlink Integration

    static func streamlinkResolve(_ url: String) async -> ResolveResult? {
        guard let streamlink = findTool("streamlink") else {
            log.debug("streamlink not found")
            return nil
        }

        guard let result = await runProcess(executable: streamlink,
                                             arguments: ["--stream-url", url, "best"]),
              result.status == 0 else {
            log.debug("streamlink resolve failed for \(url)")
            return nil
        }

        let streamURL = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard streamURL.hasPrefix("http") else { return nil }

        let fmt = streamURL.contains(".m3u8") ? "hls" : "http"
        let ct = fmt == "hls" ? "application/x-mpegURL" : "video/mp4"

        return ResolveResult(url: streamURL, cast_url: url,
                              content_type: ct, is_live: true,
                              format: fmt, title: nil,
                              youtube_id: nil)
    }

    // MARK: - Web Scraping

    static func scrapeStreamURL(_ url: String) async -> ResolveResult? {
        guard let requestURL = URL(string: url) else { return nil }

        let html: String
        do {
            var request = URLRequest(url: requestURL, timeoutInterval: 10)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        } catch {
            log.debug("scrape fetch failed: \(error)")
            return nil
        }

        // Extract title
        var title = ""
        if let titleMatch = html.range(of: #"<title[^>]*>([^<]+)</title>"#, options: .regularExpression, range: html.startIndex..<html.endIndex) {
            let titleTag = String(html[titleMatch])
            // Strip the tags
            if let inner = try? NSRegularExpression(pattern: #"<title[^>]*>([^<]+)</title>"#, options: .caseInsensitive)
                .firstMatch(in: titleTag, range: NSRange(titleTag.startIndex..., in: titleTag)),
               inner.numberOfRanges > 1,
               let range = Range(inner.range(at: 1), in: titleTag) {
                title = String(titleTag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Clean up title
        for sep in [" | ", " - ", " :: ", " \u{2014} "] {
            if title.contains(sep) {
                title = title.components(separatedBy: sep).first?.trimmingCharacters(in: .whitespaces) ?? title
                break
            }
        }

        // Look for m3u8 URLs (HLS)
        let m3u8Pattern = #"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#
        if let m3u8Matches = try? NSRegularExpression(pattern: m3u8Pattern)
            .matches(in: html, range: NSRange(html.startIndex..., in: html)),
           let first = m3u8Matches.first,
           let range = Range(first.range(at: 1), in: html) {
            let streamURL = String(html[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            return ResolveResult(url: streamURL, cast_url: streamURL,
                                  content_type: "application/x-mpegURL",
                                  is_live: true, format: "hls", title: title,
                                  youtube_id: nil)
        }

        // Look for mpd URLs (DASH)
        let mpdPattern = #"(https?://[^\s"'<>]+\.mpd[^\s"'<>]*)"#
        if let mpdMatches = try? NSRegularExpression(pattern: mpdPattern)
            .matches(in: html, range: NSRange(html.startIndex..., in: html)),
           let first = mpdMatches.first,
           let range = Range(first.range(at: 1), in: html) {
            let streamURL = String(html[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            return ResolveResult(url: streamURL, cast_url: streamURL,
                                  content_type: "application/dash+xml",
                                  is_live: true, format: "dash", title: title,
                                  youtube_id: nil)
        }

        // Collect DAI asset keys
        var allKeys: [String] = []

        // From DAI event URLs in HTML
        let daiPattern = #"dai\.google\.com/linear/(?:dash|hls)/(?:pa/)?event/([^/\s"']+)"#
        if let daiMatches = try? NSRegularExpression(pattern: daiPattern)
            .matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            for match in daiMatches {
                if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) {
                    allKeys.append(String(html[range]))
                }
            }
        }

        // From assetKey assignments in inline scripts (handles "assetKey": "val" and assetKey = "val")
        let assetKeyPattern = #"assetKey"?\s*[=:]\s*"?([A-Za-z0-9_-]{10,})"#
        if let akMatches = try? NSRegularExpression(pattern: assetKeyPattern)
            .matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            for match in akMatches {
                if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: html) {
                    allKeys.append(String(html[range]))
                }
            }
        }

        // Also look in external JS bundles
        if allKeys.isEmpty {
            let jsPattern = #"<script[^>]+src="([^"]+)""#
            if let jsMatches = try? NSRegularExpression(pattern: jsPattern)
                .matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let comps = URLComponents(string: url), let host = comps.host else { return nil }
                let port = comps.port
                var base = "\(comps.scheme ?? "https")://\(host)"
                if let port, port != 80 && port != 443 { base += ":\(port)" }

                for jsMatch in jsMatches {
                    guard jsMatch.numberOfRanges > 1,
                          let range = Range(jsMatch.range(at: 1), in: html) else { continue }
                    let jsURL = String(html[range])
                    let jsLower = jsURL.lowercased()

                    guard ["main", "bundle", "app", "player"].contains(where: { jsLower.contains($0) }) else { continue }
                    guard !jsLower.contains("googleapis") && !jsLower.contains("google") else { continue }

                    let keys = await fetchDAIKeys(jsURL: jsURL, base: base)
                    allKeys.append(contentsOf: keys)
                    if !allKeys.isEmpty { break }
                }
            }
        }

        // Try each key, pick first that supports HLS
        var seen = Set<String>()
        for assetKey in allKeys {
            guard seen.insert(assetKey).inserted else { continue }
            if let cdnURL = await daiToCDN(assetKey: assetKey) {
                return ResolveResult(url: cdnURL, cast_url: cdnURL,
                                      content_type: "application/x-mpegURL",
                                      is_live: true, format: "hls", title: title,
                                      youtube_id: nil)
            }
        }

        return nil
    }

    // MARK: - DAI Helpers

    private static func fetchDAIKeys(jsURL: String, base: String) async -> [String] {
        var fullURL = jsURL
        if jsURL.hasPrefix("//") {
            fullURL = "https:" + jsURL
        } else if jsURL.hasPrefix("/") {
            fullURL = base + jsURL
        } else if !jsURL.hasPrefix("http") {
            fullURL = base + "/" + jsURL
        }

        guard let url = URL(string: fullURL) else { return [] }

        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (data, _) = try await URLSession.shared.data(for: request)
            let js = String(data: data, encoding: .utf8) ?? ""

            let pattern = #""assetKey"\s*:\s*"([^"]+)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let matches = regex.matches(in: js, range: NSRange(js.startIndex..., in: js))
            return matches.compactMap { match in
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: js) else { return nil }
                return String(js[range])
            }
        } catch {
            log.debug("fetchDAIKeys failed: \(error)")
            return []
        }
    }

    private static func daiToCDN(assetKey: String) async -> String? {
        // Use SSAI endpoint for a fresh session-based HLS URL
        return await daiSSAISession(assetKey: assetKey)
    }

    /// Extract DAI asset key from any dai.google.com URL
    private static func extractDAIAssetKey(_ url: String) -> String? {
        let pattern = #"dai\.google\.com/linear/(?:dash|hls)/(?:pa/)?event/([^/\s"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[range])
    }

    /// Request a fresh HLS session from DAI SSAI endpoint
    private static func daiSSAISession(assetKey: String) async -> String? {
        let endpoint = "https://dai.google.com/ssai/event/\(assetKey)/streams"
        guard let url = URL(string: endpoint) else { return nil }

        do {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = "{}".data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let manifest = json["stream_manifest"] as? String,
                  let format = json["manifest_format"] as? String,
                  format == "hls" else { return nil }
            log.info("DAI SSAI session: \(manifest)")
            return manifest
        } catch {
            log.debug("daiSSAISession failed: \(error)")
            return nil
        }
    }

    static func daiDashToHLS(_ dashURL: String) async -> String? {
        // Extract asset key and get fresh HLS session via SSAI
        if let assetKey = extractDAIAssetKey(dashURL) {
            if let hlsURL = await daiSSAISession(assetKey: assetKey) {
                return hlsURL
            }
        }

        // Fallback: simple path swap (works if session is still alive)
        var hlsURL = dashURL.replacingOccurrences(of: "/dash/", with: "/hls/")
        hlsURL = hlsURL.replacingOccurrences(of: "/manifest.mpd", with: "/master.m3u8")

        guard let url = URL(string: hlsURL) else { return nil }

        do {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("Radio/1.0", forHTTPHeaderField: "User-Agent")
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                return hlsURL
            }
        } catch {
            log.debug("daiDashToHLS failed: \(error)")
        }
        return nil
    }

    // MARK: - Commands

    static func detect(url: String) async -> ProbeResult? {
        let urlType = guessType(url)

        // HTTP probe (catches icecast/shoutcast + direct streams)
        if urlType == "audio" || urlType == nil {
            if let http = await httpProbe(url) {
                return ProbeResult(type: urlType ?? http.type,
                                    title: http.title,
                                    is_live: http.is_live)
            }
        }

        // yt-dlp for YouTube, websites, etc.
        if urlType != "audio" {
            if let yt = await ytdlpDetect(url) {
                if let urlType {
                    return ProbeResult(type: urlType, title: yt.title, is_live: yt.is_live)
                }
                return yt
            }
        }

        // Scrape webpage for embedded stream URLs
        if urlType == nil {
            if let scraped = await scrapeStreamURL(url) {
                return ProbeResult(type: "video",
                                    title: scraped.title ?? "",
                                    is_live: true)
            }
        }

        return ProbeResult(type: urlType ?? "audio", title: "", is_live: false)
    }

    static func resolve(url: String, type: String = "audio", pageUrl: String? = nil) async -> ResolveResult? {
        let lower = url.lowercased()

        // Direct audio streams
        if isDirectStream(url) && type == "audio" {
            let probe = await httpProbeResolve(url)
            let ct = probe?.contentType ?? "audio/aac"
            let title = probe?.title ?? ""
            return ResolveResult(url: url, cast_url: url, content_type: ct,
                                  is_live: true, format: "http", title: title,
                                  youtube_id: nil)
        }

        // Direct HLS
        let pathPart = lower.components(separatedBy: "?").first ?? lower
        if pathPart.contains(".m3u8") {
            return ResolveResult(url: url, cast_url: url,
                                  content_type: "application/x-mpegURL",
                                  is_live: true, format: "hls", title: nil,
                                  youtube_id: nil)
        }

        // Direct DASH
        if pathPart.contains(".mpd") {
            // Google DAI: try converting dash session URL to HLS
            if url.contains("dai.google.com") {
                if let hlsURL = await daiDashToHLS(url) {
                    return ResolveResult(url: hlsURL, cast_url: url,
                                          content_type: "application/x-mpegURL",
                                          is_live: true, format: "hls", title: nil,
                                          youtube_id: nil)
                }
                // SSAI returned DASH — scrape pageUrl for HLS-capable asset keys
                if let pageUrl, let scraped = await scrapeStreamURL(pageUrl) {
                    return scraped
                }
            }

            // Try streamlink to convert to HLS for local playback
            if var sl = await streamlinkResolve(url) {
                sl = ResolveResult(url: sl.url, cast_url: url,
                                    content_type: sl.content_type, is_live: sl.is_live,
                                    format: sl.format, title: sl.title,
                                    youtube_id: sl.youtube_id)
                return sl
            }

            // Fallback: return DASH URL as-is
            return ResolveResult(url: url, cast_url: url,
                                  content_type: "application/dash+xml",
                                  is_live: true, format: "dash", title: nil,
                                  youtube_id: nil)
        }

        // yt-dlp (YouTube, DASH, 1000+ sites)
        if let yt = await ytdlpResolve(url, streamType: type) {
            return yt
        }

        // streamlink (DASH-to-HLS, live TV)
        if let sl = await streamlinkResolve(url) {
            return sl
        }

        // Scrape webpage for embedded stream URLs
        if let scraped = await scrapeStreamURL(url) {
            return scraped
        }

        // Last resort: return as-is
        return ResolveResult(url: url, cast_url: url, content_type: "audio/aac",
                              is_live: true, format: "http", title: nil,
                              youtube_id: nil)
    }
}
