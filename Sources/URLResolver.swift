import Foundation

// MARK: - Probe Results

struct ProbeResult: Decodable {
    let type: String
    let title: String
    let is_live: Bool
}

struct ResolveResult: Decodable {
    let url: String
    let cast_url: String?
    let content_type: String
    let is_live: Bool
    let format: String
    let title: String?
    let youtube_id: String?
}

// MARK: - URL Resolver

enum URLResolver {

    /// Synchronous type guess from URL patterns (instant, for onChange).
    static func detectType(_ url: String) -> StreamType {
        let lower = url.lowercased()

        let channelPatterns = [
            "youtube.com/@", "youtube.com/channel/", "youtube.com/c/",
            "twitch.tv/", "kick.com/",
        ]
        let notChannel = ["/watch", "/live/", "/video", "/clip", "/directory", "/category"]
        if channelPatterns.contains(where: { lower.contains($0) })
            && !notChannel.contains(where: { lower.contains($0) }) {
            return .channel
        }

        let audioPatterns = [
            ".mp3", ".aac", ".ogg", ".opus", ".flac", ".pls",
            ":8443/", ":8000/", ":8080/", "/stream", "/listen",
            "radio", "icecast", "shoutcast",
        ]
        if audioPatterns.contains(where: { lower.contains($0) }) {
            return .audio
        }

        let videoPatterns = [
            "youtube.com/watch", "youtube.com/live", "youtu.be/",
            "vimeo.com/", "dailymotion.com/",
            ".mp4", ".mkv", ".webm", ".m3u8", ".mpd",
        ]
        if videoPatterns.contains(where: { lower.contains($0) }) {
            return .video
        }

        return .audio
    }

    /// Async probe for type + title (native Swift).
    static func probe(_ url: String) async -> ProbeResult? {
        await StreamProbe.detect(url: url)
    }

    /// Full resolution to playable URL (native Swift).
    static func resolve(_ url: String, type: StreamType, pageUrl: String? = nil) async -> ResolveResult? {
        await StreamProbe.resolve(url: url, type: type.rawValue, pageUrl: pageUrl)
    }
}
