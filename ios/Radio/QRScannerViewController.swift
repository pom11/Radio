import UIKit
import AVFoundation

/// Camera view controller that runs an AVCaptureSession configured to emit QR
/// metadata. This is the isolation point for the AVCaptureMetadataOutput decode
/// path (DoD): `AVCaptureMetadataObject.stringValue` yields the raw `radio://add`
/// deep-link string, which is forwarded (once) through `onScan`.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    /// Called at most once with the decoded QR string when a code is read.
    var onScan: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop the session when the scanner screen is dismissed so the camera
        // indicator and session are released.
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)

        captureSession = session
        previewLayer = preview
        session.startRunning()
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didScan,
              let object = metadataObjects.first,
              let readable = object as? AVMetadataMachineReadableCodeObject,
              let string = readable.stringValue else { return }

        // Lock to a single decode; stop the session so the screen holds on the
        // decoded link instead of re-firing on the next frame.
        didScan = true
        captureSession?.stopRunning()
        onScan?(string)
    }
}
