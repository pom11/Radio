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
            ".mp4", ".mkv", ".webm",
        ]
        if videoPatterns.contains(where: { lower.contains($0) }) {
            return .video
        }
        // The literal-manifest question is asked by the ONE app-wide predicate
        // (see ChannelResolver.isLiteralManifest), not by another
        // `contains(".m3u8")` entry here — a `.php` proxy with `.m3u8` buried in
        // its path or query is not a manifest, and must not be typed as one by
        // import while the play path refuses it (the tvron bug class). It falls
        // through to this function's neutral `.audio` default instead.
        //
        // Deliberately AFTER the audio patterns, as it was before: HLS-audio
        // radio endpoints (`...:8000/live.m3u8`) are the common case in a radio
        // app and must stay `.audio`, or they would get a video panel.
        if ChannelResolver.isLiteralManifest(lower) {
            return .video
        }

        return .audio
    }
}
