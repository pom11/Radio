import SwiftUI
import AVFoundation

/// SwiftUI bridge to the camera QR scanner. Wraps `QRScannerViewController` and
/// forwards the decoded `radio://` string to `onScan`. This keeps all
/// AVFoundation wiring inside the UIKit layer so the SwiftUI screen stays thin
/// and testable.
struct QRScannerController: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // The session's metadata output delegate holds a strong ref to the vc;
        // no per-frame updates needed.
    }
}
