import XCTest
@testable import Radio

/// The CarPlay list's Refresh affordance (card t_6f34a116), asserted at the
/// policy level.
///
/// The complaint: "the CarPlay stream list has no Refresh affordance. When a
/// channel's saved stream URL goes dead, the driver can only see a list that
/// plays nothing." The template code itself cannot be driven without a head unit
/// (and the CarPlay entitlement is unapproved, so no CarPlay scene is ever
/// instantiated here), which is exactly why the three decisions the driver can
/// experience — what the selected row says, what Refresh acts on, when the button
/// is live — were pulled out of `CarPlaySceneDelegate` into `CarPlayListPolicy`.
/// Those are pure functions over `CarPlayListState`; this file drives all of them
/// offline, with no player, no CarPlay framework object and no network.
///
/// `Radio.` on `Stream` is required in type position (ambiguous with
/// Foundation.Stream in this test module) — see the note in BrokenLinkRefreshTests.
final class CarPlayRefreshTests: XCTestCase {

    private let page = "https://example.com/live"
    private let manifest = "https://cdn.example.com/a/stream.m3u8"

    private func stream(name: String = "Radio",
                        type: StreamType = .channel,
                        url: String,
                        pageUrl: String? = nil) -> Radio.Stream {
        Radio.Stream(name: name, url: url, type: type, pageUrl: pageUrl)
    }

    private func state(id: UUID? = nil,
                       playing: Bool = false,
                       failed: Bool = false,
                       refreshing: Bool = false) -> CarPlayListState {
        CarPlayListState(currentID: id, isPlaying: playing, isFailed: failed, isRefreshing: refreshing)
    }

    // MARK: - The selected row must LOOK dead

    /// A dead row that looks identical to a healthy row is why the driver never
    /// looked for a Refresh: nothing on screen said the URL was the problem.
    func testFailedSelectedRowSaysNotPlayingAndPointsAtRefresh() {
        let s = stream(url: manifest, pageUrl: page)
        let detail = CarPlayListPolicy.detailText(for: s, state: state(id: s.id, failed: true))
        XCTAssertEqual(detail, "Not playing — use Refresh")
        XCTAssertTrue(detail.lowercased().contains("refresh"),
                      "the row has to name the affordance, or the button is unrelated to the row")
    }

    func testSelectedRowShowsPlayingAndRefreshing() {
        let s = stream(url: manifest, pageUrl: page)
        XCTAssertEqual(CarPlayListPolicy.detailText(for: s, state: state(id: s.id, playing: true)),
                       "Now playing")
        // The in-flight line matters: a refetch takes seconds over the cell
        // network and the driver needs to know the tap registered.
        XCTAssertEqual(CarPlayListPolicy.detailText(for: s, state: state(id: s.id, refreshing: true)),
                       "Refreshing from source…")
    }

    /// The refresh line must win over the failed line — otherwise the row keeps
    /// saying "Not playing" while the fix is in flight and looks like nothing
    /// happened.
    func testRefreshingWinsOverFailed() {
        let s = stream(url: manifest, pageUrl: page)
        let detail = CarPlayListPolicy.detailText(for: s,
                                                  state: state(id: s.id, failed: true, refreshing: true))
        XCTAssertEqual(detail, "Refreshing from source…")
    }

    /// Only the selected row changes. Every other row keeps the stream type it
    /// always showed, so the list cannot imply that nine healthy stations broke.
    func testUnselectedRowsKeepTheirTypeDetail() {
        let selected = stream(name: "Broken", url: manifest, pageUrl: page)
        let other = stream(name: "Fine", type: .audio, url: "https://cdn.example.com/b.mp3")
        let st = state(id: selected.id, failed: true)
        XCTAssertEqual(CarPlayListPolicy.detailText(for: other, state: st), StreamType.audio.rawValue)
        // A failed stream that nobody selected (it was stopped) is not marked up
        // either — the state carries the current selection, not history.
        XCTAssertEqual(CarPlayListPolicy.detailText(for: selected, state: state()),
                       StreamType.channel.rawValue)
    }

    /// A selection that is neither playing nor failed (paused, or still
    /// connecting) must not claim either — an honest "channel" beats a lie.
    func testSelectedButIdleRowFallsBackToType() {
        let s = stream(url: manifest, pageUrl: page)
        XCTAssertEqual(CarPlayListPolicy.detailText(for: s, state: state(id: s.id)),
                       StreamType.channel.rawValue)
    }

    // MARK: - What Refresh acts on

    func testRefreshTargetIsTheSelectedStreamThatCanRefresh() {
        let a = stream(name: "A", url: manifest, pageUrl: page)
        let b = stream(name: "B", url: "https://cdn.example.com/b.mp3", pageUrl: "https://example.com/b")
        let target = CarPlayListPolicy.refreshTarget(in: [a, b], state: state(id: b.id, failed: true))
        XCTAssertEqual(target?.id, b.id, "Refresh must act on the stream the driver last tapped")
    }

    /// A `.channel` with no recorded `pageUrl` is still refreshable (its url IS
    /// the source page — `RefetchMachine.sourcePage`), so CarPlay must offer
    /// Refresh for it. Hand-added channels are the common case for this.
    func testChannelWithoutPageUrlIsStillRefreshableTarget() {
        let s = stream(type: .channel, url: "https://example.com/live")
        XCTAssertNotNil(CarPlayListPolicy.refreshTarget(in: [s], state: state(id: s.id, failed: true)))
    }

    /// Nothing selected → nothing to refresh (the button must be inert, not
    /// silently refresh whichever stream happens to be first).
    func testNoSelectionMeansNoRefreshTarget() {
        let s = stream(url: manifest, pageUrl: page)
        XCTAssertNil(CarPlayListPolicy.refreshTarget(in: [s], state: state()))
        // A selection that no longer exists in the store (deleted on the phone
        // while CarPlay was connected) must also yield nothing.
        XCTAssertNil(CarPlayListPolicy.refreshTarget(in: [s], state: state(id: UUID())))
    }

    /// An `.audio`/`.video` stream with no recorded page has no source to scrape,
    /// so Refresh must not be offered — the same `RefetchMachine.canRefresh` gate
    /// the phone's player bar uses, so the two surfaces can never disagree about
    /// whether Refresh exists.
    func testStreamWithoutSourcePageIsNotARefreshTarget() {
        let s = stream(type: .audio, url: "https://cdn.example.com/a.mp3")
        XCTAssertFalse(RefetchMachine.canRefresh(s), "precondition: the machine itself refuses this")
        XCTAssertNil(CarPlayListPolicy.refreshTarget(in: [s], state: state(id: s.id, failed: true)))
    }

    // MARK: - Button liveness

    func testButtonEnabledOnlyWithATargetAndNoRefreshInFlight() {
        let s = stream(url: manifest, pageUrl: page)
        XCTAssertTrue(CarPlayListPolicy.refreshEnabled(state: state(id: s.id, failed: true), target: s))
        // In flight: disabled, mirroring the bar's spinner. The machine would
        // refuse a second refresh anyway, but the driver must not be able to ask.
        XCTAssertFalse(CarPlayListPolicy.refreshEnabled(state: state(id: s.id, refreshing: true), target: s),
                       "a second tap mid-refresh would only be refused by the machine")
        // No target (nothing selected / no source page): inert rather than absent.
        XCTAssertFalse(CarPlayListPolicy.refreshEnabled(state: state(id: s.id, failed: true), target: nil))
        XCTAssertFalse(CarPlayListPolicy.refreshEnabled(state: state(), target: nil))
    }

    // MARK: - Rebuild dedupe key

    /// Template rebuilds are driven by this value, and `setRootTemplate` resets the
    /// driver's scroll position — so two snapshots that show the same thing must
    /// compare equal or every `statusText` write (bridged by PlayerManager, visible
    /// nowhere in this list) would yank the list to the top.
    func testViewStateEqualityDrivesRebuilds() {
        let a = stream(name: "A", url: manifest, pageUrl: page)
        let b = stream(name: "B", type: .audio, url: "https://cdn.example.com/b.mp3")

        let base = CarPlayListView(streams: [a, b], state: state(id: a.id, playing: true))
        XCTAssertEqual(base, CarPlayListView(streams: [a, b], state: state(id: a.id, playing: true)),
                       "an identical snapshot must not rebuild the template")

        // Every one of these IS visible to the driver, so each must rebuild.
        XCTAssertNotEqual(base, CarPlayListView(streams: [a], state: state(id: a.id, playing: true)),
                          "a stream added/removed on the phone must reach the list")
        XCTAssertNotEqual(base, CarPlayListView(streams: [a, b], state: state(id: a.id, failed: true)))
        XCTAssertNotEqual(base, CarPlayListView(streams: [a, b], state: state(id: a.id, refreshing: true)))
        XCTAssertNotEqual(base, CarPlayListView(streams: [a, b], state: state()))
        // A refresh that rewrote the saved URL changes the stream value itself.
        var refetched = a
        refetched.url = "https://cdn.example.com/c/stream.m3u8"
        XCTAssertNotEqual(base, CarPlayListView(streams: [refetched, b], state: state(id: a.id, playing: true)),
                          "a refreshed URL must repaint the row")
    }

    /// `CarPlayListState.idle` is what the delegate starts from; if it were not
    /// equal to a fresh no-selection snapshot the first sync would be treated as a
    /// change every time (harmless) — but more importantly it documents that the
    /// empty state and the "no player yet" state are the same thing.
    func testIdleStateIsNoSelection() {
        XCTAssertEqual(CarPlayListState.idle, state())
    }
}
