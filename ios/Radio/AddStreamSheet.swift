import SwiftUI

/// Manual add/edit sheet for entering a stream by hand (the deep-link and future
/// QR paths also feed the same store).
struct AddStreamSheet: View {
    @ObservedObject var store: StreamStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var type: StreamType = .audio

    var body: some View {
        NavigationStack {
            Form {
                Section("Stream") {
                    TextField("Name (optional)", text: $name)
                    TextField("Stream URL", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
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
                        store.add(name: name.isEmpty ? trimmed : name, url: trimmed, type: type)
                        dismiss()
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
