import Foundation
import Combine

/// Owns the player lifecycle. In this iOS foundation card only ONE stream plays
/// at a time: playing a new stream stops the current one, exactly per the user's
/// requirement. The macOS multi-stream PlayerManager is deliberately collapsed to
/// the single-stream case here.
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published var player = StreamPlayer()

    private var cancellables = Set<AnyCancellable>()

    /// True if a stream is currently playing (the single active player).
    var isPlaying: Bool { player.isPlaying }
    /// True when the current stream played and died with its recovery budget
    /// spent — the dock keeps the bar (with Refresh) visible for exactly this.
    var isFailed: Bool { player.isFailed }
    var currentStream: Stream? { player.currentStream }

    /// StreamPlayer's own @Published changes (isPlaying, currentStream,
    /// isExternalPlayback, statusText) must propagate to anything observing the
    /// manager. `@Published var player` only fires on RE-ASSIGNMENT, not on
    /// mutations, so we bridge player.objectWillChange -> manager.objectWillChange
    /// here; otherwise ContentView's safeAreaInset player bar and the StreamRow
    /// playing indicators never re-render when playback starts/stops.
    init() {
        player.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A refetch that produced a fresh URL must reach the saved list, or the
        // fix dies with the process (same wiring as macOS PlayerManager). The
        // player already taint-checked the URL; applyRefreshedURL re-checks at
        // the storage boundary and persists synchronously (StreamStore.save is
        // synchronous by design — keep it).
        player.onRefreshStream = { refreshed in
            _ = StreamStore.shared.applyRefreshedURL(id: refreshed.id, url: refreshed.url)
        }
    }

    /// Play a stream, replacing the current one (single-stream requirement).
    /// Every UI/CarPlay entry point lands here, so this is a user action and
    /// gets a fresh recovery budget (see StreamPlayer.play(userInitiated:)).
    @discardableResult
    func play(stream: Stream) -> StreamPlayer {
        // Toggle: tapping the currently-playing stream stops it.
        if let current = player.currentStream, current.id == stream.id, player.isPlaying {
            player.stop()
        } else {
            player.play(stream, userInitiated: true)
        }
        return player
    }

    func stop() {
        player.stop()
    }
}
