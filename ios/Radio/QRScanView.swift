import SwiftUI
import AVFoundation

/// Full-screen camera QR scanner, reached from the "Scan QR" toolbar button.
/// Requests camera permission, renders the live preview, and on a successful
/// decode hands the raw `radio://add` string to `onScan`, then dismisses itself
/// so the stream list (with its success banner) is revealed.
struct QRScanView: View {
    /// Called with the decoded QR string (the radio:// deep link) when read.
    var onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var permissionDenied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if permissionDenied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 44))
                    Text("Camera access is required to scan a QR code.")
                        .font(.headline)
                    Text("Enable it in Settings to import streams from the macOS QR export.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Open Settings") {
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(settingsURL)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                QRScannerController { string in
                    onScan(string)
                    dismiss()
                }
                .overlay(alignment: .bottom) {
                    Text("Point the camera at the macOS QR code")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Scan QR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { requestPermission() }
    }

    private func requestPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionDenied = false
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    permissionDenied = !granted
                }
            }
        default:
            permissionDenied = true
        }
    }
}
