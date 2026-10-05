import Foundation

/// Synchronous type guess from URL patterns (instant, for onChange / deep-link
/// ingestion when no explicit type hint is provided). Ported verbatim from the
/// macOS app's URLResolver.detectType. This foundation card only needs
/// `detectType`; async probe/resolve (StreamProbe) is a later card.
enum URLResolver {
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
}
