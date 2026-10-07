import SwiftUI

/// Manual add sheet for entering a stream by hand (the deep-link and QR paths
/// feed the same store).
///
/// The "Source page (for Refresh)" field exists because of the second half of
/// the user's report: "please make sure when importing the stream will also
/// fetch the original url so we can refetch the stream later". Before it, a
/// manually-added stream could *never* be refreshed — `Stream.pageUrl` was
/// unreachable from this sheet, so the field that decides whether Refresh is
/// ever offered (see `RefetchMachine.sourcePage`) was left nil forever. The
/// deep-link/QR path already carried pageUrl; manual add was the gap.
struct AddStreamSheet: View {
    @ObservedObject var store: StreamStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var pageUrl = ""
    @State private var type: StreamType = .audio

    var body: some View {
        NavigationStack {
            Form {
                Section("Stream") {
                    TextField("Name (optional)", text: $name)
                        .accessibilityIdentifier("addStreamNameField")
                    TextField("Stream URL", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("addStreamURLField")
                }
                Section {
                    TextField("Source page (optional)", text: $pageUrl)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("addStreamPageUrlField")
                    // Says what happens when the field is left empty, so the
                    // user is not guessing whether Refresh will exist later.
                    Text(pageUrlHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Source page (for Refresh)")
                }
                Section("Type") {
                    Picker("Type", selection: $type) {
                        Text("Audio").tag(StreamType.audio)
                        Text("Video").tag(StreamType.video)
                        Text("Channel").tag(StreamType.channel)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Add Stream")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.add(name: name.isEmpty ? trimmed : name,
                                  url: trimmed,
                                  type: type,
                                  pageUrl: Self.resolvedPageUrl(entered: pageUrl,
                                                                streamURL: trimmed,
                                                                type: type))
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    /// What to persist as `pageUrl`: the trimmed field, an empty field becoming
    /// nil rather than an empty string; and when the field was left empty, the
    /// url itself for the one case where the url genuinely IS a page (a channel
    /// whose url carries no manifest extension). The defaulting rule is
    /// `RefetchMachine.recordedPageUrl` — the mirror of the `sourcePage` rule the
    /// refetch path uses — rather than a second copy of "when is a url a page".
    ///
    /// `internal` (not private) on purpose: this is the decision the user's
    /// report is about, so the suite asserts on it directly instead of
    /// reconstructing it from the form.
    static func resolvedPageUrl(entered: String, streamURL: String, type: StreamType) -> String? {
        let page = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !page.isEmpty else {
            return RefetchMachine.recordedPageUrl(url: streamURL, type: type)
        }
        return page
    }

    /// Says what happens when the field is left empty, in the two sentences that
    /// are true for every type: an empty field means "use the channel URL" only
    /// for a channel (see `resolvedPageUrl`), and anything else has no default.
    private var pageUrlHint: String {
        "Where a fresh link is scraped from when this stream dies. "
        + (type == .channel
           ? "Leave empty for a channel — its URL is the page."
           : "Leave empty unless the stream needs a page to work.")
    }
}
