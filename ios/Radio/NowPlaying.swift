import AVFoundation
import Foundation
import MediaPlayer
import os.log

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "nowplaying")

/// Pure, system-free builder for the Lock Screen / Control Center / Dynamic
/// Island now-playing payload, plus the next/previous stream selection used by
/// the remote commands.
///
/// Deliberately a plain enum of static functions taking and returning plain
/// values (no MPNowPlayingInfoCenter, no AVPlayer): the whole shape of the
/// now-playing card — which stream is named, what the rate says while paused,
/// whether a live stream advertises a scrubber — is then unit-testable without
/// an audio session, a player, or a device.
enum NowPlayingInfo {
    /// The artist line. Streams have no reliable artist metadata, so the app
    /// name is the honest value (and keeps the card from showing a blank line).
    static let artistName = "Radio"

    /// The `MPMediaType` mask for the card (MediaPlayer's type mask, not a
    /// per-item enum). A radio/`.channel` stream reports as music — the mask the
    /// system surfaces for ordinary audio playback — and a `.video` stream as
    /// movie, so surfaces that group or filter by media type treat it correctly.
    static func mediaTypeMask(for type: StreamType) -> MPMediaType {
        type == .video ? .movie : .music
    }

    /// Build the `MPNowPlayingInfoCenter.nowPlayingInfo` dictionary.
    ///
    /// - `durationSeconds`: the item's duration, or nil when it is unknown —
    ///   which is the normal case for a live radio/HLS stream. A live stream is
    ///   published with `IsLiveStream = true` and duration 0 so the system does
    ///   NOT draw a scrubber that could never be honoured (seeking a live
    ///   broadcast is meaningless); the elapsed time still runs.
    /// - `rate`: the actual AVPlayer rate (0 paused, 1 playing). It is passed
    ///   through for live streams too — the play/pause glyph on the lock screen
    ///   is derived from it, so a paused live stream must report 0.
    static func dictionary(
        stream: Stream,
        elapsedSeconds: Double,
        rate: Double,
        durationSeconds: Double?
    ) -> [String: Any] {
        // A duration is usable only if we have one and it is a positive, finite
        // number. AVPlayer hands back .indefinite / .invalid for live streams,
        // which CMTimeGetSeconds turns into infinity / NaN.
        let duration = durationSeconds ?? 0
        let live = !(duration.isFinite && duration > 0)

        // Clamp the junk values AVPlayer can hand back (NaN on an unlinked
        // item, negative right after a seek) into something the system accepts.
        let elapsed = (elapsedSeconds.isFinite && elapsedSeconds > 0) ? elapsedSeconds : 0
        let clampedRate = (rate.isFinite && rate > 0) ? 1.0 : 0.0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: stream.name,
            MPMediaItemPropertyArtist: artistName,
            MPMediaItemPropertyMediaType: Int(mediaTypeMask(for: stream.type).rawValue),
            MPMediaItemPropertyPlaybackDuration: live ? 0.0 : duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: clampedRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: live,
        ]
        // Artwork is intentionally absent: a stream has no artwork we can fetch
        // in-app, and omitting the key (rather than sending NSNull) is what the
        // system expects — it then falls back to its own placeholder.
        return info
    }

    /// Index of the stream that "next track" / "previous track" should select,
    /// wrapping around the end of the saved list (a radio list is a dial, not a
    /// queue: it has no dead ends). nil when the current stream is not (or no
    /// longer) in the list, so the caller can refuse the command honestly.
    static func nextIndex(current: UUID, in streams: [Stream], forward: Bool) -> Int? {
        guard !streams.isEmpty,
              let index = streams.firstIndex(where: { $0.id == current }) else { return nil }
        let count = streams.count
        return forward ? (index + 1) % count : (index - 1 + count) % count
    }
}

/// The player-side hooks the system's remote commands drive. StreamPlayer
/// implements this; the controller holds it weakly (player owns controller).
///
/// Each returns whether the action was actually performed: an MPCommandHandler
/// must answer `.success` only when it really did something, so a command aimed
/// at nothing (play with no stream loaded) is reported as a failure instead of
/// the system believing playback started.
protocol NowPlayingCommandDelegate: AnyObject {
    /// Resume (or start) the current stream — Control Center's play button.
    /// Returns false when there is nothing loaded to resume.
    @discardableResult
    func nowPlayingResume() -> Bool
    /// Pause the current stream, keeping it loaded. False if nothing is playing.
    @discardableResult
    func nowPlayingPause() -> Bool
    /// Toggle between the two. Always handled: with nothing loaded it resumes.
    @discardableResult
    func nowPlayingTogglePlayback() -> Bool
    /// Play the next / previous saved stream. False when there is nothing to
    /// skip to (empty store, or the current stream is no longer in it).
    @discardableResult
    func nowPlayingSkip(forward: Bool) -> Bool
    /// Seek to an absolute position in seconds. False for a live stream (or when
    /// nothing is loaded) — there is no position to move to.
    @discardableResult
    func nowPlayingSeek(to seconds: Double) -> Bool
}

/// The system-facing half of the player: publishes the now-playing card and
/// translates the remote commands Lock Screen / Control Center / Dynamic Island
/// / CarPlay send back into player actions.
///
/// Why this exists at all: the app had `.playback` + `UIBackgroundModes audio`,
/// so audio kept playing in the background, but with zero
/// `MPNowPlayingInfoCenter` usage the system had nothing to display — no card
/// in Lock Screen or Control Center at all, and no way to control the stream
/// from there.
///
/// Owned by (and lives exactly as long as) its StreamPlayer. That matters:
/// `MPRemoteCommand.target` is a WEAK reference, so the object registered as a
/// target must outlive the commands, and each instance removes its own targets
/// on deinit so a second player can never stack duplicate handlers.
final class NowPlayingController {
    weak var delegate: NowPlayingCommandDelegate?

    private let center = MPRemoteCommandCenter.shared()
    /// (command, opaque target token) pairs returned by `addTargetWithHandler`.
    /// The token is what `removeTarget(_:)` expects — the block-based API does
    /// not register `self` as the target — so keeping the tokens is what makes
    /// teardown possible (and keeps the blocks alive while registered).
    private var registered: [(MPRemoteCommand, Any)] = []

    init() {
        registerCommands()
    }

    deinit {
        for (command, token) in registered {
            command.removeTarget(token)
        }
        registered.removeAll()
    }

    /// Register one handler and remember its token so deinit can undo it.
    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let token = command.addTarget(handler: handler)
        registered.append((command, token))
    }

    // MARK: - Now-playing card

    /// Publish (or refresh) the now-playing card for the current stream.
    func publish(stream: Stream, elapsedSeconds: Double, rate: Double, durationSeconds: Double?) {
        let playing = rate > 0
        let info = NowPlayingInfo.dictionary(
            stream: stream,
            elapsedSeconds: elapsedSeconds,
            rate: rate,
            durationSeconds: durationSeconds
        )
        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = info
        // Also set the explicit playback state: CarPlay's now-playing template
        // (and a few other surfaces) read this rather than deriving it from the
        // rate. Same call site, so the two can never disagree.
        nowPlaying.playbackState = playing ? .playing : .paused
    }

    /// Remove the card entirely. Called on stop so a stream that is no longer
    /// playing does not leave a ghost card (and a live-looking elapsed time)
    /// on the Lock Screen.
    func clear() {
        let nowPlaying = MPNowPlayingInfoCenter.default()
        nowPlaying.nowPlayingInfo = nil
        nowPlaying.playbackState = .stopped
    }

    // MARK: - Remote commands

    /// Wire the system's transport controls to the delegate. Registered once per
    /// controller (i.e. once per player) and torn down in deinit.
    ///
    /// Apple delivers these handlers on the main thread, so they may touch the
    /// player and the store directly.
    private func registerCommands() {
        // Play / pause / toggle — the controls the card was missing entirely.
        register(center.playCommand) { [weak self] _ in
            guard let delegate = self?.delegate else { return .commandFailed }
            return delegate.nowPlayingResume() ? .success : .commandFailed
        }

        register(center.pauseCommand) { [weak self] _ in
            guard let delegate = self?.delegate else { return .commandFailed }
            return delegate.nowPlayingPause() ? .success : .commandFailed
        }

        register(center.togglePlayPauseCommand) { [weak self] _ in
            guard let delegate = self?.delegate else { return .commandFailed }
            return delegate.nowPlayingTogglePlayback() ? .success : .commandFailed
        }

        // Next / previous — mapped to the next/previous SAVED stream (the store
        // list, wrapping). A radio app has no queue, so the dial is the only
        // sensible meaning for these buttons.
        register(center.nextTrackCommand) { [weak self] _ in
            guard let delegate = self?.delegate else { return .commandFailed }
            return delegate.nowPlayingSkip(forward: true) ? .success : .commandFailed
        }

        register(center.previousTrackCommand) { [weak self] _ in
            guard let delegate = self?.delegate else { return .commandFailed }
            return delegate.nowPlayingSkip(forward: false) ? .success : .commandFailed
        }

        // Scrubbing. The handler declines for live streams (nothing to seek);
        // the system also hides the scrubber for those, because the published
        // info says IsLiveStream = true.
        register(center.changePlaybackPositionCommand) { [weak self] event in
            guard let delegate = self?.delegate,
                  let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            return delegate.nowPlayingSeek(to: position) ? .success : .commandFailed
        }

        log.debug("remote commands registered")
    }
}
