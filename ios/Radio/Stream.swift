import Foundation

enum StreamType: String, Codable {
    case audio
    case video
    case channel
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
}
