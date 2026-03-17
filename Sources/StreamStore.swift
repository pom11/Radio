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

    func indexByPageUrl(_ pageUrl: String) -> Int? {
        streams.firstIndex(where: { $0.pageUrl == pageUrl })
    }
}
