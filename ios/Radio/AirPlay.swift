import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Configures the shared audio session so playback routes to AirPlay targets.
///
/// `.playback` category with `.allowAirPlay` option is the correct setup for a
/// media player that should be able to stream to AirPlay speakers/TVs/HomePods.
/// The route picker button (AVRoutePickerView) needs an active session to offer
/// routes, and `.playback` (not `.ambient`) is what lets audio keep playing
/// over external speakers without an app that murders background audio.
enum AudioSessionConfig {
    /// Call once before the player starts, and re-activate on interruption
    /// end. Kept idempotent so repeated calls are cheap.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            // Non-fatal: playback still works over the local speaker even if
            // AirPlay routing is unavailable. Log and keep going.
            print("AudioSessionConfig: failed to configure audio session: \(error)")
        }
    }
}

/// The native system "AirPlay" route picker button, wrapped for SwiftUI.
///
/// Uses AVRoutePickerView (iOS 13+) rather than MPVolumeView so we get the
/// route-picker icon WITHOUT the volume slider. Tapping it presents the system
/// sheet of AirPlay destinations (speakers, TVs, HomePods).
struct AirPlayRoutePickerView: UIViewRepresentable {
    /// Tint applied to the AirPlay glyph.
    var tint: UIColor = .systemBlue

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tint
        picker.activeTintColor = tint
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = tint
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        // Route-picker presentation is entirely system-managed, so the delegate
        // hooks are for future customisation / diagnostics only.
    }
}
