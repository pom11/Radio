import Foundation

// MARK: - CarPlay list state + policy
//
// The CarPlay stream list used to be a frozen snapshot: one row per saved stream,
// tapping played it, and that was the whole vocabulary. When a saved URL went dead
// the driver could see nothing was wrong (the row looked exactly like a working
// row) and had no lever at all — refetch-from-source existed only in the phone's
// player bar, which is invisible behind a steering wheel.
//
// This file holds the *decisions* the CarPlay template renders, as pure functions
// over a small snapshot, for the same reason `PlayerBarPolicy` exists: a rule the
// UI reads inline is a rule no test can see. The snapshot deliberately has no
// AVPlayer, no SwiftUI and no CarPlay types in it, so `RadioTests` can drive every
// state (playing / failed / refreshing / not-selected) without a head unit.

/// The player facts the CarPlay list can show, flattened into one comparable value.
///
/// `Equatable` is load-bearing: the delegate rebuilds the root template only when
/// this changes, so a published field that fires without changing anything the
/// driver can see (a statusText write, for instance) does not yank the CarPlay
/// list back to its scroll top.
struct CarPlayListState: Equatable {
    /// The stream currently loaded in the app's single player, if any.
    var currentID: UUID?
    var isPlaying: Bool
    /// Terminal failure for the current stream (see `StreamPlayer.isFailed`).
    var isFailed: Bool
    /// A refetch-from-source is in flight for the current stream.
    var isRefreshing: Bool

    static let idle = CarPlayListState(currentID: nil,
                                       isPlaying: false,
                                       isFailed: false,
                                       isRefreshing: false)

    /// Read the live app state. Lives here rather than in the scene delegate so
    /// the mapping from player → snapshot is one named thing, not four inline
    /// property reads at the call site.
    static func current(manager: PlayerManager) -> CarPlayListState {
        CarPlayListState(currentID: manager.currentStream?.id,
                         isPlaying: manager.isPlaying,
                         isFailed: manager.isFailed,
                         isRefreshing: manager.player.isRefreshing)
    }
}

/// Everything the root list template renders: the saved streams plus the player
/// facts that colour the selected row. Equatable for the same reason as
/// `CarPlayListState` — it is the dedupe key for template rebuilds.
struct CarPlayListView: Equatable {
    var streams: [Stream]
    var state: CarPlayListState

    /// The live snapshot. Reads the two singletons, so it is the untestable leaf
    /// of this file; every decision built on top of it is pure.
    static var current: CarPlayListView {
        CarPlayListView(streams: StreamStore.shared.streams,
                        state: CarPlayListState.current(manager: PlayerManager.shared))
    }
}

enum CarPlayListPolicy {
    /// The row's detail line — the only per-item status text CarPlay gives us.
    ///
    /// Non-selected rows keep showing the stream type (unchanged behaviour). Only
    /// the *selected* row changes, because that is the row whose fate the driver
    /// is waiting on: a dead channel has to look dead, and it has to say what to
    /// do about it. That sentence is the discoverable half of the Refresh feature
    /// — a nav-bar button nobody connects to the broken row is a button nobody
    /// presses while driving.
    static func detailText(for stream: Stream, state: CarPlayListState) -> String {
        guard state.currentID == stream.id else { return stream.type.rawValue }
        if state.isRefreshing { return "Refreshing from source…" }
        if state.isPlaying { return "Now playing" }
        if state.isFailed { return "Not playing — use Refresh" }
        // Selected but neither playing nor failed (e.g. paused, or connecting
        // without a terminal failure): same line as any other row.
        return stream.type.rawValue
    }

    /// The stream the Refresh button acts on, or nil when Refresh makes no sense.
    ///
    /// The refetch path is per-stream (it re-scrapes *that* stream's source page)
    /// and the app plays exactly one stream, so the button refreshes the stream the
    /// player is holding — which after a failed tap IS the dead channel the driver
    /// is complaining about. `RefetchMachine.canRefresh` is the same gate the
    /// phone's player bar uses, so CarPlay can never offer a Refresh that would
    /// only come back "No source page to refetch from".
    static func refreshTarget(in streams: [Stream], state: CarPlayListState) -> Stream? {
        guard let id = state.currentID,
              let stream = streams.first(where: { $0.id == id }),
              RefetchMachine.canRefresh(stream) else { return nil }
        return stream
    }

    /// Is the navigation-bar Refresh button live right now?
    ///
    /// Disabled (not hidden — the affordance must not move) while nothing is
    /// selected, the selection has no source page, or a refresh is already in
    /// flight. The in-flight term mirrors the bar's `disabled(isRefreshing)`
    /// spinner; the machine would refuse a second refresh anyway, but a driver
    /// should not be able to ask twice.
    static func refreshEnabled(state: CarPlayListState, target: Stream?) -> Bool {
        target != nil && !state.isRefreshing
    }
}
