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
/// Held by `QRScanView` as a `@StateObject`, which is created once per view
/// lifetime, so exactly one session exists no matter how often the body is
/// re-evaluated. The representable below it only attaches a preview layer.
@MainActor
final class QRScanSession: NSObject, ObservableObject {
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
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
            log.info("session running: \(session.isRunning)")
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
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
        log.info("session configured (device \(device.localizedName, privacy: .public)); starting")
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
            log.debug("metadata callback: \(metadataObjects.count) object(s)")

            // Take the first object that actually CARRIES a string: using
            // `first` and bailing when it had no stringValue meant one
            // unreadable code in frame suppressed a good one beside it.
            guard let string = metadataObjects
                .lazy
                .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .compactMap({ $0.stringValue })
                .first(where: { !$0.isEmpty })
            else { return }

            log.info("decoded QR, \(string.count) chars")
            didScan = true
            stop()
            onScan?(string)
        }
    }
}
