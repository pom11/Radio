import Foundation
import os

/// Native Swift implementation of the YouTube Lounge API for Chromecast.
/// Replaces the casttube Python dependency.
enum YouTubeLoungeAPI {

    private static let log = Logger(subsystem: "ro.pom.radio", category: "YouTubeLounge")

    private static let baseURL = "https://www.youtube.com/"
    private static let loungeTokenURL = baseURL + "api/lounge/pairing/get_lounge_token_batch"
    private static let bindURL = baseURL + "api/lounge/bc/bind"

    private static let headers: [String: String] = [
        "Origin": baseURL,
        "Content-Type": "application/x-www-form-urlencoded",
    ]

    /// Play a YouTube video on a Chromecast identified by screenId.
    static func playVideo(videoId: String, screenId: String) async throws {
        let loungeToken = try await getLoungeToken(screenId: screenId)
        let (sid, gsessionId) = try await bindSession(loungeToken: loungeToken)
        try await setPlaylist(videoId: videoId, loungeToken: loungeToken, sid: sid, gsessionId: gsessionId)
        log.info("Playing \(videoId) via Lounge API")
    }

    // MARK: - Private

    private static func getLoungeToken(screenId: String) async throws -> String {
        let body = "screen_ids=\(screenId)"
        let data = try await post(url: loungeTokenURL, body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screens = json["screens"] as? [[String: Any]],
              let first = screens.first,
              let token = first["loungeToken"] as? String else {
            throw URLError(.badServerResponse)
        }
        return token
    }

    private static func bindSession(loungeToken: String) async throws -> (sid: String, gsessionId: String) {
        let bindData = "device=REMOTE_CONTROL&id=aaaaaaaaaaaaaaaaaaaaaaaaaa&name=Radio&mdx-version=3&pairing_type=cast&app=android-phone-13.14.55"
        let params = "RID=0&VER=8&CVER=1"
        let url = bindURL + "?" + params

        let data = try await post(url: url, body: bindData, extraHeaders: [
            "X-YouTube-LoungeId-Token": loungeToken,
        ])

        let content = String(data: data, encoding: .utf8) ?? ""

        guard let sidValue = extractGroup(from: content, pattern: #""c","([^"]+)""#) else {
            throw URLError(.cannotParseResponse)
        }

        guard let gsessionValue = extractGroup(from: content, pattern: #""S","([^"]+)"\]"#) else {
            throw URLError(.cannotParseResponse)
        }

        return (sidValue, gsessionValue)
    }

    private static func setPlaylist(videoId: String, loungeToken: String, sid: String, gsessionId: String) async throws {
        let params = "SID=\(sid)&gsessionid=\(gsessionId)&RID=1&VER=8&CVER=1"
        let url = bindURL + "?" + params

        let body = "count=1&req0__sc=setPlaylist&req0_videoId=\(videoId)&req0_currentTime=0&req0_currentIndex=-1&req0_audioOnly=false&req0_listId="

        _ = try await post(url: url, body: body, extraHeaders: [
            "X-YouTube-LoungeId-Token": loungeToken,
        ])
    }

    private static func post(url: String, body: String, extraHeaders: [String: String] = [:]) async throws -> Data {
        guard let requestURL = URL(string: url) else { throw URLError(.badURL) }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...399).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func extractGroup(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}
