import SwiftUI
import AVFoundation

/// SwiftUI bridge that renders the live preview for an EXISTING
/// `QRScanSession`. It deliberately owns no session and no delegate: the
/// session lives in `QRScanView`'s `@StateObject` so that SwiftUI re-evaluating
/// the body cannot create a second one. Two sessions on one camera was the bug
/// that made the scanner look alive while never decoding.
struct QRScannerController: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Re-attach only if SwiftUI handed us a different session object; the
        // layer keeps its own frame via layoutSubviews below.
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    /// A UIView whose backing layer IS the preview layer, so it resizes with
    /// the view instead of needing a manual frame update on every layout pass.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
