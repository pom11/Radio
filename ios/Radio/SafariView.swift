import SwiftUI
import SafariServices

/// Thin SwiftUI wrapper around `SFSafariViewController` so the app can present
/// a channel's source page (the "Open in Browser" fallback for streams that
/// can't resolve to a playable URL in-app) without leaving the app.
///
/// SFSafariViewController is chosen over a hand-rolled WKWebView because it is
/// the system-recommended, lightweight way to open a web page in your app's
/// context: users get Safari's cookie/sign-in state (so YouTube/Twitch/Kick
/// live streams render), it's memory-friendly, and we don't re-implement a
/// browser. Present it via `.sheet` or `.fullScreenCover`.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // URL is fixed for the lifetime of a presented sheet.
    }
}
