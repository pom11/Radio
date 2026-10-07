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

    /// Append a stream, persisting synchronously (see `save`).
    ///
    /// `pageUrl` is the *source page* a later refetch can scrape a fresh URL from
    /// (see `RefetchMachine.sourcePage`) — recorded here so a stream added by hand
    /// is not permanently refresh-less. Empty/whitespace arrives as nil so an
    /// untouched field never saves an empty string as a page.
    func add(name: String, url: String, type: StreamType = .audio, pageUrl: String? = nil) {
        streams.append(Stream(name: name, url: url, type: type, pageUrl: pageUrl))
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

    /// Persist a URL that a refetch-from-source produced (port of the macOS
    /// StreamStore.applyRefreshedURL). The caller (StreamPlayer's refetch) has
    /// already judged the candidate; this re-checks `refuseTainted` at the
    /// storage boundary anyway — defence in depth, because every writer of a
    /// playable url enforces the same rule and a future caller must not be
    /// able to bypass it. On a tainted url the existing one survives untouched.
    ///
    /// Difference from macOS: only `url` is updated. The macOS refetch rotates
    /// referer/headers alongside the URL; the iOS native scrape (ChannelResolver)
    /// yields no new headers, so a refreshed stream keeps the referer/headers it
    /// already has — its source page is unchanged.
    @discardableResult
    func applyRefreshedURL(id: UUID, url: String) -> Stream? {
        guard let idx = streams.firstIndex(where: { $0.id == id }) else { return nil }
        if !Self.refuseTainted(url, pageUrl: streams[idx].pageUrl) {
            streams[idx].url = url
        }
        save()
        return streams[idx]
    }
}
