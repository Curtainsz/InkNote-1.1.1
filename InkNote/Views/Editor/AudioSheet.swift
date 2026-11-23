import SwiftUI

/// Record audio while writing, and replay it later.
struct AudioSheet: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var audio: AudioModel
    let notebookID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    recorderRow
                    if audio.permissionDenied {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Microphone access is switched off for InkNote.")
                                .font(.footnote)
                                .foregroundColor(.red)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                }

                Section("Recordings in this notebook") {
                    let clips = store.notebook(notebookID)?.audio ?? []
                    if clips.isEmpty {
                        Text("No recordings yet.").foregroundColor(.secondary)
                    }
                    ForEach(clips) { clip in
                        clipRow(clip)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { clips[$0].id }
                        for id in ids {
                            if audio.playingID == id { audio.stopPlayback() }
                            store.deleteClip(id, from: notebookID)
                        }
                    }
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var recorderRow: some View {
        Button {
            toggleRecording()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: audio.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 46))
                    .foregroundColor(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(audio.isRecording ? "Recording… tap to stop" : "Start recording")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text(AudioModel.format(audio.elapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func clipRow(_ clip: AudioClip) -> some View {
        HStack(spacing: 12) {
            Button {
                audio.togglePlayback(clip: clip, url: store.audioURL(clip.fileName))
            } label: {
                Image(systemName: audio.playingID == clip.id ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title).font(.subheadline.weight(.semibold))
                Text(AudioModel.format(clip.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func toggleRecording() {
        if audio.isRecording {
            if let clip = audio.stopRecording() {
                store.addClip(clip, to: notebookID)
            }
        } else {
            let dir = store.audioDir
            Task {
                await audio.startRecording(in: dir)
            }
        }
    }
}

/// Shows the text read from handwriting, with copy and insert actions.
struct RecognisedTextSheet: View {
    @Binding var text: String
    let isWorking: Bool
    let onInsert: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isWorking {
                    ProgressView("Reading your handwriting…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if text.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No handwriting found on this page.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $text)
                        .padding(12)
                }
            }
            .navigationTitle("Handwriting to text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .disabled(text.isEmpty || isWorking)
                    Spacer()
                    Button {
                        onInsert()
                    } label: {
                        Label("Insert as text box", systemImage: "text.badge.plus")
                    }
                    .disabled(text.isEmpty || isWorking)
                }
            }
        }
    }
}
