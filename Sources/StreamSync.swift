import Foundation
import os.log

/// Coordinates iCloud Key-Value synchronization of the saved stream list.
///
/// Lightweight by design: the entire `[Stream]` list is serialized to JSON and
/// stored under a single key in `NSUbiquitousKeyValueStore` (iCloud key-value
/// storage). No CloudKit container, no network daemon, no per-stream granular
/// API.
///
/// Semantics:
///   * Local `streams.json` is the source of truth for local edits — every
///     mutation goes through `StreamStore.save()`, which calls
///     `StreamSync.storeDidSave(streams:)` to push the full list to iCloud.
///   * Turn ON: one-time merge of the remote copy into local (union by stream
///     id; for a stream present in both, the LOCAL version wins so the first
///     connect never clobbers an existing local library), then push the merged
///     list back up.
///   * Turn OFF: stop observing and stop writing to iCloud. The remote copy is
///     deliberately NOT deleted (other devices keep it); the local list stays
///     the local list.
///   * Live remote changes (`didChangeExternallyNotification`): union-merge the
///     remote copy into local; for a stream present in both, the REMOTE version
///     wins so renames and URL refreshes from another device propagate. This is
///     effectively last-writer-wins per stream id, which matches the task's
///     "last-writer-wins per store is acceptable" note and fulfils the
///     requirement that a refresh on one device updates that stream's URL on all
///     devices.
///   * Deletes are not tombstoned: a stream kept by either side survives the
///     union, so it only disappears from iCloud when both devices stop holding
///     it (exactly like toggle-OFF). Documented, acceptable limitation.
///
/// The sync-enabled flag is persisted in UserDefaults (NOT in streams.json), so
/// turning sync off is a pure preference and never touches the stream list.
final class StreamSync {

    static let shared = StreamSync()

    // UserDefaults key for the on/off flag (never stored in streams.json).
    private let syncEnabledDefaultsKey = "radio.icloudSyncEnabled"
    // NSUbiquitousKeyValueStore key holding the serialized [Stream] list.
    private let storeKey = "radio.streams"

    private let kv = NSUbiquitousKeyValueStore.default
    private let log = Logger(subsystem: "ro.pom.radio", category: "StreamSync")

    /// Whether iCloud sync is currently ON. Source of truth: UserDefaults.
    private(set) var isEnabled: Bool

    /// Token returned by `addObserver(forName:...)` for the block-based observer.
    /// We must hold and remove it via `removeObserver(_:)` when sync is turned
    /// off — the class-based `removeObserver(_:name:object:)` does NOT remove a
    /// block-based observer, so we can't rely on that form.
    private var observerToken: NSObjectProtocol?

    /// Guard against a push->pull->push loop: when we apply a remotely-originated
    /// merge we flip this on so the resulting `StreamStore.save()` does not
    /// immediately push the just-pulled data straight back to iCloud.
    private var applyingRemoteChange = false

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: syncEnabledDefaultsKey)
        if isEnabled {
            startObserving()
        }
    }

    // MARK: - Toggle (Settings UI)

    /// Turn iCloud sync on or off. Persists the flag in UserDefaults.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: syncEnabledDefaultsKey)

        if enabled {
            startObserving()
            // Give iCloud a chance to deliver any locally-cached remote state.
            kv.synchronize()
            // One-time merge of the remote copy into local (local wins for
            // same-id conflicts), then persist + push the merged union so this
            // device durably holds the combined list and iCloud reflects it.
            applyRemote(remoteWinsForConflictingID: false)
            sharedStore.save()
            log.info("iCloud stream sync enabled: merged remote into local and pushed \(self.kv.dictionaryRepresentation.count, privacy: .public) key(s)")
        } else {
            stopObserving()
            log.info("iCloud stream sync disabled: stopped writing to iCloud; local list unchanged")
        }
    }

    // MARK: - Hook from StreamStore.save()

    /// Called by `StreamStore.save()` on every local mutation. If sync is ON,
    /// serializes the current list into iCloud. No-op when sync is off or when
    /// the change originated from a remote pull (avoid push-back).
    func storeDidSave(streams: [Stream]) {
        guard isEnabled, !applyingRemoteChange else { return }
        setList(streams)
        kv.synchronize()
        log.info("pushed \(streams.count, privacy: .public) streams to iCloud (\(self.storeKey, privacy: .public))")
    }

    // MARK: - Observation

    private func startObserving() {
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv,
            queue: .main
        ) { [weak self] note in
            self?.handleExternalChange(note)
        }
    }

    private func stopObserving() {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
            self.observerToken = nil
        }
    }

    private func handleExternalChange(_ note: Notification) {
        log.info("didChangeExternallyNotification fired")
        let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
        guard changedKeys.contains(storeKey) else {
            log.info("external iCloud change did not touch the streams key; ignoring")
            return
        }
        applyingRemoteChange = true
        applyRemote(remoteWinsForConflictingID: true)
        // Persist the merged union locally (the resulting save() will not push,
        // because applyingRemoteChange is true).
        sharedStore.save()
        applyingRemoteChange = false
        log.info("merged remote stream changes into local list (\(sharedStore.streams.count, privacy: .public) streams)")
    }

    // MARK: - Serialization / merge

    private func setList(_ streams: [Stream]) {
        guard let data = try? JSONEncoder().encode(streams) else {
            log.error("failed to serialize stream list for iCloud")
            return
        }
        kv.set(data, forKey: storeKey)
    }

    private func readRemoteList() -> [Stream]? {
        guard let data = kv.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Stream].self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Pure union-merge of `local` and `remote` stream lists by stream id.
    /// `remoteWins` selects the winner when a stream id exists in both lists
    /// (toggle-ON merge uses local-wins; live remote changes use remote-wins).
    /// Streams unique to either side are always retained, so concurrent
    /// additions on two devices both survive. Local ordering is preserved and
    /// remote-only streams are appended at the end. Exposed as `static` so the
    /// merge semantics can be unit-tested in isolation.
    static func mergeStreams(local: [Stream], remote: [Stream], remoteWins: Bool) -> [Stream] {
        let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var consumedRemote = Set<UUID>()
        var merged: [Stream] = []
        // Walk local in order; replace in place when remote wins for a same-id.
        for localStream in local {
            if let remoteStream = remoteByID[localStream.id], remoteWins {
                merged.append(remoteStream)
                consumedRemote.insert(remoteStream.id)
            } else {
                merged.append(localStream)
            }
        }
        // Append any remote-only streams (new streams from another device).
        for remoteStream in remote {
            if !consumedRemote.contains(remoteStream.id),
               !merged.contains(where: { $0.id == remoteStream.id }) {
                merged.append(remoteStream)
            }
        }
        return merged
    }

    /// Union-merge the remote copy into the local store by stream id. `remoteWins`
    /// selects which side wins when a stream id exists in both (ON = local wins;
    /// live remote change = remote wins). Streams unique to either side are always
    /// retained, so concurrent additions on two devices both survive. Must be
    /// called with `applyingRemoteChange` already set appropriately by the caller.
    private func applyRemote(remoteWinsForConflictingID: Bool) {
        guard let remote = readRemoteList() else {
            log.info("no remote copy yet; nothing to merge")
            return
        }
        sharedStore.streams = Self.mergeStreams(
            local: sharedStore.streams,
            remote: remote,
            remoteWins: remoteWinsForConflictingID
        )
    }
}
