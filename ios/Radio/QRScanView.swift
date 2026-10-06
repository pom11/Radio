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

    /// Camera authorization is a THREE-state problem, not a bool.
    ///
    /// This used to be `@State private var permissionDenied = false`, which
    /// meant the scanner was built on the very first render — BEFORE `.onAppear`
    /// had even asked for permission. AVFoundation will happily create and
    /// start a session without authorization, but it delivers no frames: the
    /// user got a black preview that could never decode a code, and granting
    /// access afterwards did not rebuild the session, so it stayed dead until
    /// the screen was left and re-entered. With the screen also having no way
    /// out (see the toolbar below) that was unrecoverable.
    ///
    /// Gating on `.authorized` means the scanner is only created once the
    /// camera can actually produce frames, and flipping to `.authorized`
    /// rebuilds it for free.
    private enum Authorization {
        case undetermined, authorized, denied
    }

    @State private var authorization: Authorization = .undetermined

    /// The PROCESS-WIDE session — deliberately not `@StateObject`.
    ///
    /// `@StateObject` gives one object per view INSTANCE, and the device log
    /// showed SwiftUI building this view twice for one `.fullScreenCover`
    /// presentation: two sessions, one camera, no metadata callbacks. Sharing
    /// one session makes the duplicate harmless.
    @ObservedObject private var scanSession = QRScanSession.shared

    var body: some View {
        // A NavigationStack is REQUIRED here: this view is presented with
        // .fullScreenCover, which provides no navigation bar of its own, so the
        // title and toolbar below previously rendered nowhere — leaving the
        // camera with no Cancel button and no way back except a successful scan.
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityLabel("Close scanner")
                }
            }
        }
        .task { await resolveAuthorization() }
    }

    @ViewBuilder
    private var content: some View {
        switch authorization {
        case .undetermined:
            // Brief, and deliberately not the camera UI: showing a preview
            // before authorization is what produced the dead black screen.
            ProgressView()
                .tint(.white)
        case .denied:
            permissionDeniedView
        case .authorized:
            if scanSession.failed {
                cameraUnavailableView
            } else {
                scanner
            }
        }
    }

    private var scanner: some View {
        QRScannerController(session: scanSession.session)
            .onAppear {
                scanSession.beginScanning { string in
                    onScan(string)
                    dismiss()
                }
            }
            .onDisappear { scanSession.endScanning() }
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

    private var permissionDeniedView: some View {
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
    }

    /// Distinct from the permission case on purpose: a missing/unusable capture
    /// device used to fail silently, which looked identical to a denied
    /// permission and left nothing to act on.
    private var cameraUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
            Text("Camera unavailable")
                .font(.headline)
            Text("This device's camera could not be started. Add the stream manually with the + button instead.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .foregroundStyle(.white)
    }

    private func resolveAuthorization() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = .authorized
        case .notDetermined:
            // Await the prompt, so the scanner below is only built afterwards.
            authorization = await AVCaptureDevice.requestAccess(for: .video)
                ? .authorized : .denied
        default:
            authorization = .denied
        }
    }
}
