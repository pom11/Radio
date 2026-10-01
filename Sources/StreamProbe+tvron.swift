import Foundation
import os.log

// Own private logger, same subsystem/category as StreamProbe.swift's (a second
// file-scope `log` here satisfies the requirement without clashing with the
// private `log`s in the other source files).
private let log = Logger(subsystem: "ro.pom.radio", category: "probe")

// MARK: - tvron.me source-page resolver
//
// tvron.me channel pages contain NO .m3u8/.mpd literal. The live stream is
// reached by following a short iframe chain, every hop a plain HTTP GET (no JS):
//   1. Channel page  -> inline JS contains  embed_player.php?id=<numeric id>
//   2. /embed_player.php?id=<id>  (Referer: channel page) -> var serversData =
//      [{"nr":N,"file":"<base64 server code>"}, ...]  ("sources you can choose from")
//   3. /player.php?id=<id>&f=<base64 server code>  (Referer: embed_player.php;
//      REQUIRED or the server returns 404/302) -> HTML containing a live-stream
//      LITERAL:  file: "https://<cdn>/.../mono.m3u8"  inside a Playerjs config.
// Try server codes in order until one yields a playable m3u8 (or mpd).
// Pure URLSession GETs + NSRegularExpression — stays lightweight, no WebView/JS.

extension StreamProbe {

    /// Fetch a URL's body as text, optionally with a Referer header.
    private static func tvronFetchHTML(_ urlString: String, referer: String?) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            var request = URLRequest(url: url, timeoutInterval: 12)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent")
            if let referer {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                log.debug("tvron GET non-2xx: \(urlString)")
                return nil
            }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? nil
        } catch {
            log.debug("tvron GET failed \(urlString): \(error)")
            return nil
        }
    }

    /// Decode a server "file" code; tolerant of missing base64 padding.
    private static func tvronDecodeBase64(_ value: String) -> String? {
        var b64 = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "")
        let missing = (4 - (b64.count % 4)) % 4
        if missing > 0 { b64 += String(repeating: "=", count: missing) }
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Regex-extract the first playable stream literal (m3u8 or mpd) from HTML.
    private static func tvronExtractStreamURL(_ html: String) -> (url: String, format: String)? {
        let patterns = [
            (regex: #"(https?://[^\s"'<>]+\.m3u8[^\s"'<>]*)"#, format: "hls"),
            (regex: #"(https?://[^\s"'<>]+\.mpd[^\s"'<>]*)"#, format: "dash"),
        ]
        for p in patterns {
            if let matches = try? NSRegularExpression(pattern: p.regex)
                .matches(in: html, range: NSRange(html.startIndex..., in: html)),
               let first = matches.first,
               first.numberOfRanges > 1,
               let range = Range(first.range(at: 1), in: html) {
                let streamURL = String(html[range])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return (streamURL, p.format)
            }
        }
        return nil
    }

    /// Resolve a tvron.me channel page to a playable stream URL by following the
    /// iframe chain described above. Returns nil if no server yields a stream.
    static func tvronResolve(_ pageURL: String) async -> ResolveResult? {
        log.info("tvron: resolving \(pageURL)")

        // tvron.ro and tvron.me are the same site family serving the same
        // channels (verified: https://tvron.ro/ch-hbo 301-redirects to
        // https://tvron.me/ch-hbo). tvron.ro sits behind a Cloudflare bot
        // wall — its embed endpoint returns "Acces Interzis" to plain HTTP
        // ("Nu aveți permisiunea să vizualizați acest conținut direct.") —
        // so we never touch it directly. Instead, rewrite a tvron.ro source
        // page onto tvron.me keeping the same channel slug (ch-hbo -> /ch-hbo,
        // which carries the same embed id) and run the whole chain on .me.
        let effectivePage: String
        if pageURL.contains("tvron.ro") {
            if let u = URL(string: pageURL),
               var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                comps.host = "tvron.me"
                effectivePage = comps.url?.absoluteString ?? pageURL
            } else {
                effectivePage = pageURL
            }
            log.info("tvron: routed \(pageURL) -> \(effectivePage)")
        } else {
            effectivePage = pageURL
        }
        // The .me channel page carries the same embed id as its .ro twin.

        // 1. Channel page -> embed id.
        guard let pageHTML = await tvronFetchHTML(effectivePage, referer: nil) else {
            log.debug("tvron: failed to fetch channel page \(effectivePage)")
            return nil
        }
        let idPattern = #"(?:embed_player|player)\.php\?id=(\d+)"#
        guard let idMatch = try? NSRegularExpression(pattern: idPattern)
            .firstMatch(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML)),
              idMatch.numberOfRanges > 1,
              let idRange = Range(idMatch.range(at: 1), in: pageHTML) else {
            log.debug("tvron: no embed id found in \(pageURL)")
            return nil
        }
        let id = String(pageHTML[idRange])
        log.info("tvron: embed id = \(id)")

        // 2. Embed player -> serversData server codes.
        let embedURL = "https://tvron.me/embed_player.php?id=\(id)"
        guard let embedHTML = await tvronFetchHTML(embedURL, referer: effectivePage) else {
            log.debug("tvron: failed to fetch embed player \(embedURL)")
            return nil
        }
        let serverPattern = #""file"\s*:\s*"([^"]+)""#
        var codes: [String] = []
        if let matches = try? NSRegularExpression(pattern: serverPattern)
            .matches(in: embedHTML, range: NSRange(embedHTML.startIndex..., in: embedHTML)) {
            for m in matches where m.numberOfRanges > 1 {
                if let r = Range(m.range(at: 1), in: embedHTML) {
                    codes.append(String(embedHTML[r]))
                }
            }
        }
        guard !codes.isEmpty else {
            log.debug("tvron: no serversData in \(embedURL)")
            return nil
        }
        log.info("tvron: \(codes.count) server(s): \(codes.map { tvronDecodeBase64($0) ?? $0 })")

        // 3. Try each server code in order until one yields a playable stream.
        for code in codes {
            let playerURL = "https://tvron.me/player.php?id=\(id)&f=\(code)"
            guard let playerHTML = await tvronFetchHTML(playerURL, referer: embedURL) else {
                log.debug("tvron: server \(tvronDecodeBase64(code) ?? code) failed/non-2xx, trying next")
                continue
            }
            guard let hit = tvronExtractStreamURL(playerHTML) else {
                log.debug("tvron: server \(tvronDecodeBase64(code) ?? code) had no stream literal, trying next")
                continue
            }
            log.info("tvron: resolved \(pageURL) -> \(hit.url)")
            return ResolveResult(url: hit.url, cast_url: hit.url,
                                 content_type: hit.format == "hls" ? "application/x-mpegURL" : "application/dash+xml",
                                 is_live: true, format: hit.format,
                                 title: nil, youtube_id: nil)
        }

        log.debug("tvron: no working server found for \(pageURL)")
        return nil
    }
}
