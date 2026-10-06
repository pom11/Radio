import UIKit
import AVFoundation

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
        session.commitConfiguration()

        // Must come AFTER the output is attached and the configuration is
        // committed: availableMetadataObjectTypes is empty until the output has
        // a connection, and assigning an unsupported type raises.
        guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
            onSetupFailure?()
            return
        }
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)

        captureSession = session
        previewLayer = preview

        sessionQueue.async { session.startRunning() }
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didScan else { return }

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
        didScan = true
        if let session = captureSession, session.isRunning {
            sessionQueue.async { session.stopRunning() }
        }
        onScan?(string)
    }
}
