// @preconcurrency: AVCaptureSession is not Sendable, and the session must be
// touched from a background queue because start/stopRunning block. This is
// the suppression the compiler itself recommends for that pairing.
@preconcurrency import AVFoundation
import os.log

private let log = Logger(subsystem: "ro.pom.radio.ios", category: "qr")

/// Owns the ONE capture session for a scanner screen.
///
/// Why this exists: the session used to live inside the
/// `UIViewControllerRepresentable`, so SwiftUI rebuilding that view created a
/// SECOND `QRScannerViewController` with a SECOND `AVCaptureSession` on the same
/// camera. On-device logs showed it plainly — "session configured (device Back
/// Camera); starting / session running: true" twice — and no metadata callback
/// ever fired: two sessions contend for one device and the loser is interrupted,
/// so the preview looks alive while nothing decodes.
///
/// Exposed as `QRScanSession.shared` and observed by `QRScanView`, so exactly
/// one session exists no matter how many times SwiftUI builds the view or
/// re-evaluates its body. The representable below it only attaches a preview
/// layer and owns nothing.
@MainActor
final class QRScanSession: NSObject, ObservableObject {
    /// PROCESS-WIDE single instance.
    ///
    /// `@StateObject` was NOT enough, and the device log proved it: after the
    /// session was hoisted out of the representable, two "session configured /
    /// session running: true" pairs still appeared. `@StateObject` guarantees
    /// one object per VIEW INSTANCE, but SwiftUI builds `QRScanView` itself
    /// more than once while presenting a `.fullScreenCover`, so each copy made
    /// its own session and the two fought over the camera — the loser is
    /// interrupted, which is why the preview looked alive and no metadata
    /// callback ever fired. There is only ever one scanner screen in this app,
    /// so one session per process removes the contention by construction.
    static let shared = QRScanSession()

    /// Identifies this OBJECT and this BUILD in the log.
    ///
    /// Earned the hard way: two rounds of fixes logged byte-identical text, so
    /// a log showing two sessions could not be told apart from a log taken
    /// against the previous build. The version segment moves whenever this
    /// file's logging changes; the random segment differs per instance, so two
    /// concurrent sessions are now obvious at a glance.
    private let tag: String = "qr/v4/" + String(UUID().uuidString.prefix(4))
    /// Set when no usable session could be built, so the UI can say so instead
    /// of showing a black rectangle.
    @Published private(set) var failed = false

    /// Called at most once with the decoded QR string.
    var onScan: ((String) -> Void)?

    let session = AVCaptureSession()

    /// start/stopRunning block until the camera is (re)configured and must not
    /// run on the main queue.
    private let sessionQueue = DispatchQueue(label: "ro.pom.radio.ios.qr-session")
    private var configured = false
    private var didScan = false

    /// How many scanner views are currently on screen. Needed because the
    /// session is shared: SwiftUI may build two `QRScanView`s for one
    /// presentation, and the first one to disappear must not stop the camera
    /// out from under the one still visible.
    private var viewers = 0

    /// Begin a fresh scan. Resets the one-shot latch, because this object now
    /// outlives a single presentation: after one successful decode `didScan`
    /// would otherwise stay true and the scanner would never read again.
    func beginScanning(onScan: @escaping (String) -> Void) {
        viewers += 1
        self.onScan = onScan
        // Reset the one-shot latch: this object outlives a single presentation,
        // so after one successful decode it would otherwise never read again.
        didScan = false
        log.info("\(self.tag, privacy: .public) beginScanning (viewers \(self.viewers))")
        start()
    }

    /// Counterpart to `beginScanning`. Only the last viewer stops the camera.
    func endScanning() {
        viewers = max(0, viewers - 1)
        log.info("\(self.tag, privacy: .public) endScanning (viewers \(self.viewers))")
        if viewers == 0 { stop() }
    }

    /// Idempotent: safe to call from every `onAppear`.
    func start() {
        guard !failed else { return }
        if !configured {
            guard configure() else {
                failed = true
                return
            }
            configured = true
        }
        guard !didScan else { return }
        let session = self.session
        let tag = self.tag
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
            log.info("\(tag, privacy: .public) session running: \(session.isRunning)")
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    /// Camera interruptions are silent otherwise: another app or a second
    /// session taking the device looks identical to "the code won't scan".
    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
                           object: session, queue: .main) { [tag] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            log.error("\(tag, privacy: .public) session INTERRUPTED, reason \(reason)")
        }
        center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                           object: session, queue: .main) { [tag] _ in
            log.info("\(tag, privacy: .public) interruption ended")
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                           object: session, queue: .main) { [tag] note in
            let err = note.userInfo?[AVCaptureSessionErrorKey]
            log.error("\(tag, privacy: .public) session RUNTIME ERROR: \(String(describing: err))")
        }
    }

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            log.error("no usable video capture device/input")
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            log.error("cannot add camera input")
            return false
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            log.error("cannot add metadata output")
            return false
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // Inside the configuration block, which is the documented requirement
        // (the output must already belong to the session). Never gate this on
        // `availableMetadataObjectTypes` — that list is empty until the
        // connection is live, and gating on it silently skipped setup entirely.
        output.metadataObjectTypes = [.qr]

        configureFocus(device)
        observeInterruptions()
        log.info("\(self.tag, privacy: .public) session configured (device \(device.localizedName, privacy: .public)); starting")
        return true
    }

    /// QR codes are read at arm's length or closer; the default focus range can
    /// hunt straight past them and leave the code permanently soft.
    private func configureFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.unlockForConfiguration()
        } catch {
            log.warning("could not configure focus: \(error.localizedDescription)")
        }
    }
}

extension QRScanSession: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        // Delegate queue is .main, so hop onto the actor without a thread change.
        MainActor.assumeIsolated {
            guard !didScan else { return }
            log.info("\(self.tag, privacy: .public) metadata callback: \(metadataObjects.count) object(s)")

            // Take the first object that actually CARRIES a string: using
            // `first` and bailing when it had no stringValue meant one
            // unreadable code in frame suppressed a good one beside it.
            guard let string = metadataObjects
                .lazy
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .compactMap({ $0.stringValue })
                .first(where: { !$0.isEmpty })
            else { return }

            log.info("\(self.tag, privacy: .public) decoded QR, \(string.count) chars")
            didScan = true
            stop()
            onScan?(string)
        }
    }
}
