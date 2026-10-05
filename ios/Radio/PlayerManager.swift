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
    }

    /// Play a stream, replacing the current one (single-stream requirement).
    @discardableResult
    func play(stream: Stream) -> StreamPlayer {
        // Toggle: tapping the currently-playing stream stops it.
        if let current = player.currentStream, current.id == stream.id, player.isPlaying {
            player.stop()
        } else {
            player.play(stream)
        }
        return player
    }

    func stop() {
        player.stop()
    }
}
