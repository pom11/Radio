import Foundation
import os.log

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "store")

/// Persistence-backed store of saved streams. Ported from the macOS Radio app's
/// StreamStore, with the storage location changed from `~/.config/radio` to the
/// app's Documents directory (the iOS sandbox cannot write to ~/.config).
final class StreamStore: ObservableObject {
    @Published var streams: [Stream] = [] {
        didSet {
            audioStreams = streams.filter { $0.type == .audio }
            videoStreams = streams.filter { $0.type == .video }
            channelStreams = streams.filter { $0.type == .channel }
        }
    }
    private(set) var audioStreams: [Stream] = []
    private(set) var videoStreams: [Stream] = []
    private(set) var channelStreams: [Stream] = []

    static let shared = StreamStore()

    /// Documents directory of the app sandbox. The stream list lives here as
    /// `streams.json` (same JSON schema as the macOS app).
    let fileURL: URL

    init(fileURL: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? documents.appendingPathComponent("streams.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Stream].self, from: data) else { return }
        streams = decoded
    }

    func save() {
        // Write synchronously: the stream list is tiny (~KB) and this removes a
        // real data-loss race where two rapid detaches could write out of order,
        // leaving an older (stale) list on disk. A blocking write on the main
        // thread is fine at this scale and far safer than a detached write.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(streams) else { return }
        try? data.write(to: fileURL)
    }

    func add(name: String, url: String, type: StreamType = .audio) {
        streams.append(Stream(name: name, url: url, type: type))
        save()
    }

    func delete(_ stream: Stream) {
        streams.removeAll { $0.id == stream.id }
        save()
    }

    /// True if a candidate URL is "tainted" and must NOT be persisted as a
    /// stream's playable url: either it is not a genuine http(s) URL (a resolver
    /// last-resort fallback), or it equals the stream's own source page (pageUrl).
    /// Every path that writes a stream's playable url via the radio:// deep link
    /// must go through this guard — identical to StreamStore.refuseTainted in the
    /// macOS app.
    static func refuseTainted(_ candidate: String, pageUrl: String?) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return true }
        if let pageUrl {
            return trimmed == pageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return false
    }

    func indexByPageUrl(_ pageUrl: String) -> Int? {
        streams.firstIndex(where: { $0.pageUrl == pageUrl })
    }
}
