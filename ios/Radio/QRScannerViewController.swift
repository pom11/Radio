import UIKit
import AVFoundation
import os.log

/// Capture-path logging. "Nothing happens when I point at the QR" is
/// indistinguishable from a dozen causes without this; read it in Console.app
/// with the device attached, subsystem ro.pom.radio.ios, category qr.
private let log = Logger(subsystem: "ro.pom.radio.ios", category: "qr")

/// Camera view controller that runs an AVCaptureSession configured to emit QR
/// metadata. This is the isolation point for the AVCaptureMetadataOutput decode
/// path (DoD): `AVCaptureMetadataObject.stringValue` yields the raw `radio://add`
/// deep-link string, which is forwarded (once) through `onScan`.
///
/// Camera authorization is NOT checked here — `QRScanView` only builds this
/// controller once access is granted. A session created without authorization
/// starts cleanly but never delivers a frame, which is the failure this split
/// exists to prevent.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    /// Called at most once with the decoded QR string when a code is read.
    var onScan: ((String) -> Void)?
    /// Called when no usable capture session could be built.
    var onSetupFailure: (() -> Void)?

    /// start/stopRunning BLOCK until the camera is (re)configured, and Apple
    /// documents that they must not be called on the main queue. They were, so
    /// presenting the scanner hitched the UI.
    private let sessionQueue = DispatchQueue(label: "ro.pom.radio.ios.qr-session")

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Resume on re-entry: the session is stopped on the way out, so without
        // this a second visit to the scanner showed a frozen last frame.
        guard !didScan, let session = captureSession, !session.isRunning else { return }
        sessionQueue.async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the session when the scanner screen is dismissed so the camera
        // indicator and session are released.
        guard let session = captureSession, session.isRunning else { return }
        sessionQueue.async { session.stopRunning() }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            // Previously `return` — a silent black screen with nothing to act on.
            log.error("no usable video capture device/input")
            onSetupFailure?()
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            onSetupFailure?()
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            onSetupFailure?()
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)

        // Set the types INSIDE the configuration block, which is the documented
        // requirement (the output must already belong to the session) and the
        // ordering that works.
        //
        // This was briefly gated on `availableMetadataObjectTypes.contains(.qr)`
        // AFTER commitConfiguration. That list is legitimately empty until the
        // session has a running connection, so the guard could trip on a
        // perfectly good camera and return early — leaving no preview layer, no
        // started session and no object types, i.e. a scanner that silently
        // never decodes anything. Availability is advisory here, never a gate.
        metadataOutput.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        if !metadataOutput.availableMetadataObjectTypes.contains(.qr) {
            log.warning("QR not yet listed in availableMetadataObjectTypes (count \(metadataOutput.availableMetadataObjectTypes.count)); continuing anyway — the list fills in once the connection is live")
        }

        // QR codes are read at arm's length or closer; the default focus range
        // hunts past them and can leave the code permanently soft.
        if device.isAutoFocusRangeRestrictionSupported || device.isFocusModeSupported(.continuousAutoFocus) {
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

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)

        captureSession = session
        previewLayer = preview

        log.info("session configured (device \(device.localizedName, privacy: .public)); starting")
        sessionQueue.async {
            session.startRunning()
            log.info("session running: \(session.isRunning)")
        }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didScan else { return }
        log.debug("metadata callback: \(metadataObjects.count) object(s)")

        // Take the first object that actually CARRIES a string. Using
        // `metadataObjects.first` and bailing when it had no stringValue meant a
        // single unreadable/partial code in the frame suppressed a good one
        // alongside it, and the scanner looked like it was ignoring the QR.
        guard let string = metadataObjects
            .lazy
            .compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .compactMap({ $0.stringValue })
            .first(where: { !$0.isEmpty })
        else { return }

        // Lock to a single decode; stop the session so the screen holds on the
        // decoded link instead of re-firing on the next frame.
        log.info("decoded QR, \(string.count) chars")
        didScan = true
        if let session = captureSession, session.isRunning {
            sessionQueue.async { session.stopRunning() }
        }
        onScan?(string)
    }
}
