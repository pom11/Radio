import SwiftUI
import AppKit
import RadioCore

// Convenience: build the add-link for a saved Stream (Stream lives in the app target).
extension StreamDeepLink {
    static func addLink(for stream: Stream) -> String {
        addLink(
            url: stream.url,
            name: stream.name,
            type: stream.type.rawValue,
            pageUrl: stream.pageUrl,
            referer: stream.referer
        )
    }
}

// MARK: - Share button (NSSharingServicePicker)

/// A real macOS share button implemented as an NSViewRepresentable so the
/// native NSSharingServicePicker can be anchored directly under it. Shares the
/// given [Any] items ("Save to Photos", AirDrop, Copy, Messages, …).
private struct ShareButton: NSViewRepresentable {
    let title: String
    let items: [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setAccessibilityLabel("Share QR code")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    final class Coordinator: NSObject {
        let items: [Any]
        init(items: [Any]) { self.items = items }

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: items)
            // Sender's window is the sheet (or main window) hosting the button.
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

// MARK: - QR export sheet

/// Presents the QR code(s) for a set of streams, each with a native share
/// button. Single stream -> one QR; multiple -> a scrollable list of QRs.
struct QRExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let streams: [Stream]
    @State private var imageCache: [UUID: NSImage] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(streams) { stream in
                        QRCard(stream: stream, image: imageCache[stream.id])
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 420, minHeight: 300)

            Divider()

            HStack {
                Button("Close") { dismiss() }
                Spacer()
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        .navigationTitle(streams.count == 1 ? "Export QR" : "Export \(streams.count) QR codes")
        .onAppear {
            for stream in streams {
                if imageCache[stream.id] == nil,
                   let img = QRCodeGenerator.qrImage(from: StreamDeepLink.addLink(for: stream)) {
                    imageCache[stream.id] = img
                }
            }
        }
    }
}

/// One stream's QR card: a scaled QR image + name + a native share button.
private struct QRCard: View {
    let stream: Stream
    let image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            Text(stream.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)

            Group {
                if let image {
                    // .resizable() is REQUIRED: without it a SwiftUI Image
                    // ignores .frame() for scaling and draws at its native
                    // size (CIQRCodeGenerator at scale 10 is 350-550px), so the
                    // code was clipped by the sheet and could not be decoded at
                    // all. .interpolation(.none) keeps the modules crisp under
                    // nearest-neighbour scaling.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: QRDisplay.side, height: QRDisplay.side)
                } else {
                    ProgressView()
                        .frame(width: QRDisplay.side, height: QRDisplay.side)
                }
            }

            if let image {
                ShareButton(title: "Share…", items: [image])
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
    }
}
