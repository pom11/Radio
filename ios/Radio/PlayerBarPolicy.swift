import Foundation

/// The reach rule for the player bar — and therefore for the Refresh affordance.
///
/// The card this lives on came from the user report "i dont see the refresh
/// stream if the link is broken". The Refresh button lives only in the bar
/// (ContentView's `PlayerBar`), so *whether the bar is mounted* is the whole
/// difference between a broken link offering a way out and offering nothing.
/// That decision used to be three boolean checks written inline in the dock's
/// `@ViewBuilder`, where no test could see it — this type is that same rule as
/// a pure function, and the dock reads it verbatim.
///
/// Deliberately knows nothing about SwiftUI, AVPlayer or streams: the dock
/// supplies the flags. Keeping it this small is what lets the failure-state
/// policy (the part a user can experience wrong) be asserted exhaustively
/// without an app, a player, or the network — see
/// `RadioTests/BrokenLinkRefreshTests.swift`.
enum PlayerBarPolicy {
    /// Should the bottom dock mount the player bar at all?
    ///
    /// - `isPlaying` — the ordinary case: something is playing (or connecting).
    /// - `isFailed` — a terminal failure for the current stream. This is the
    ///   half that was missing: without it the bar unmounts the moment playback
    ///   dies, taking the honest "Failed"/"Open in browser" line, the retry, and
    ///   the Refresh button off screen exactly when the user needs them.
    ///
    /// A PAUSED audio stream satisfies neither, so it keeps hiding the bar —
    /// long-standing behaviour this must not regress.
    ///
    /// The video case is *additive* at the call site: the dock mounts panel +
    /// bar whenever a video surface is on screen, which is a strictly stronger
    /// condition than this (it also implies a current stream). See
    /// `ContentView.bottomDock`.
    static func shouldShowBar(isPlaying: Bool, isFailed: Bool) -> Bool {
        isPlaying || isFailed
    }

    /// Should the bar carry Play/Pause + Stop?
    ///
    /// True only while the stream needs rescuing or the picture is on screen:
    /// a failed stream needs Play (retry with a fresh budget) and Stop (dismiss
    /// the bar), and the docked video panel needs transport because the panel
    /// can cover the list row that started playback. A plain playing audio bar
    /// has always been name + AirPlay + Refresh only — stop lives on the row.
    static func showsTransport(isPlaying: Bool, isFailed: Bool) -> Bool {
        isFailed
    }

    /// Should the bar offer Refresh for this stream?
    ///
    /// Exactly `RefetchMachine.canRefresh` — the bar never grows a button that
    /// could only refuse with "No source page to refetch from". Named here so
    /// the rule the button renders under is the rule the tests assert on.
    static func shouldOfferRefresh(_ stream: Stream?) -> Bool {
        guard let stream else { return false }
        return RefetchMachine.canRefresh(stream)
    }
}
