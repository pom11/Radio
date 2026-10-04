import Foundation
import CoreSpotlight

enum StreamType: String, Codable {
    case audio
    case video
    case channel
}

enum StreamPlatform: String, CaseIterable {
    case youtube
    case twitch
    case kick
    case other

    var label: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitch: return "Twitch"
        case .kick: return "Kick"
        case .other: return "Channels"
        }
    }

    var faviconDomain: String? {
        switch self {
        case .youtube: return "youtube.com"
        case .twitch: return "twitch.tv"
        case .kick: return "kick.com"
        case .other: return nil
        }
    }
}

struct Stream: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var url: String
    var type: StreamType
    var pageUrl: String?
    var referer: String?
    var headers: [String: String]?

    init(id: UUID = UUID(), name: String, url: String, type: StreamType = .audio, pageUrl: String? = nil, referer: String? = nil, headers: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.type = type
        self.pageUrl = pageUrl
        self.referer = referer
        self.headers = headers
    }

    // Backward-compatible decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        type = try container.decodeIfPresent(StreamType.self, forKey: .type) ?? .audio
        pageUrl = try container.decodeIfPresent(String.self, forKey: .pageUrl)
        referer = try container.decodeIfPresent(String.self, forKey: .referer)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
    }

    var platform: StreamPlatform {
        let lower = url.lowercased()
        if lower.contains("youtube.com") || lower.contains("youtu.be") { return .youtube }
        if lower.contains("twitch.tv") { return .twitch }
        if lower.contains("kick.com") { return .kick }
        return .other
    }
}

final class StreamStore: ObservableObject {
    @Published var streams: [Stream] = [] {
        didSet {
            audioStreams = streams.filter { $0.type == .audio }
            videoStreams = streams.filter { $0.type == .video }
            channelStreams = streams.filter { $0.type == .channel }
            youtubeChannels = channelStreams.filter { $0.platform == .youtube }
            twitchChannels = channelStreams.filter { $0.platform == .twitch }
            kickChannels = channelStreams.filter { $0.platform == .kick }
            otherChannels = channelStreams.filter { $0.platform == .other }
        }
    }
    private(set) var audioStreams: [Stream] = []
    private(set) var videoStreams: [Stream] = []
    private(set) var channelStreams: [Stream] = []
    private(set) var youtubeChannels: [Stream] = []
    private(set) var twitchChannels: [Stream] = []
    private(set) var kickChannels: [Stream] = []
    private(set) var otherChannels: [Stream] = []

    private let fileURL: URL

    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/radio")
        fileURL = configDir.appendingPathComponent("streams.json")

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Stream].self, from: data) else { return }
        streams = decoded
        StreamStore.indexForSpotlight(decoded)
    }

    func save() {
        let snapshot = streams
        let url = fileURL
        Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url)
            Self.indexForSpotlight(snapshot)
        }
    }

    // MARK: - Spotlight

    static let spotlightDomain = "ro.pom.radio.streams"

    static func indexForSpotlight(_ streams: [Stream]) {
        let items = streams.map { stream -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = stream.name
            attrs.contentDescription = "Play \(stream.name) on Radio"
            let typeLabel: String
            switch stream.type {
            case .audio: typeLabel = "Audio Stream"
            case .video: typeLabel = "Video Stream"
            case .channel: typeLabel = "Channel"
            }
            attrs.keywords = ["radio", "stream", stream.name, typeLabel]
            return CSSearchableItem(
                uniqueIdentifier: stream.id.uuidString,
                domainIdentifier: spotlightDomain,
                attributeSet: attrs
            )
        }

        CSSearchableIndex.default().deleteSearchableItems(
            withDomainIdentifiers: [spotlightDomain]
        ) { _ in
            CSSearchableIndex.default().indexSearchableItems(items)
        }
    }

    func add(name: String, url: String, type: StreamType = .audio) {
        streams.append(Stream(name: name, url: url, type: type))
        save()
    }

    func delete(_ stream: Stream) {
        streams.removeAll { $0.id == stream.id }
        save()
    }

    /// True if a candidate URL is "tainted" and must NOT be persisted as a stream's
    /// playable url: either it is not a genuine http(s) URL (a resolver last-resort
    /// fallback), or it equals the stream's own source page (pageUrl) — the exact
    /// dead-page scenario where a source page URL would silently replace a working
    /// stream URL. Every path that writes ``streams[idx].url`` must go through this
    /// guard so the extension add/update handlers and the in-app refresh enforce the
    /// same rule.
    static func refuseTainted(_ candidate: String, pageUrl: String?) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return true }
        if let pageUrl {
            return trimmed == pageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return false
    }

    /// Update a stream's playable URL/referer/headers after a successful source-page refetch.
    /// Preserves id/name/type/pageUrl. Returns the updated stream, or nil if not found.
    ///
    /// Guard: the source page (pageUrl) is NOT a playable URL. If the caller passes a
    /// URL equal to the stream's own pageUrl (or a non-http(s) value — a resolver
    /// last-resort fallback), we refuse to overwrite the existing playable URL, so a
    /// dead page URL can never silently replace a working stream URL. Referer/headers
    /// are still updated in that case (they describe the source, not the playable URL).
    @discardableResult
    func applyRefreshedURL(id: UUID, url: String, referer: String?, headers: [String: String]?) -> Stream? {
        guard let idx = streams.firstIndex(where: { $0.id == id }) else { return nil }
        if !Self.refuseTainted(url, pageUrl: streams[idx].pageUrl) {
            streams[idx].url = url
        }
        streams[idx].referer = referer
        streams[idx].headers = headers
        save()
        return streams[idx]
    }

    func indexByPageUrl(_ pageUrl: String) -> Int? {
        streams.firstIndex(where: { $0.pageUrl == pageUrl })
    }
}
