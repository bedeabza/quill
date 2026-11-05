import SwiftUI

/// Transcribing again can upload audio and may be billed, so it asks first,
/// with the engine for this run and the notes that matter.
struct RegenerateSheet: View {
    @Bindable var model: RecordingsModel
    let entry: RecordingEntry
    @Environment(\.dismiss) private var dismiss

    /// A recording without a transcript is transcribed, not regenerated.
    private var again: Bool { entry.hasTranscript }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(again ? "Regenerate Transcript" : "Transcribe Recording")
                    .font(.headline)
                Text(again ? "Transcribe “\(entry.title)” again." : "Transcribe “\(entry.title)”.")
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 18)

            Form {
                Picker("Engine", selection: $model.regenerateEngine) {
                    ForEach(TranscriptionEngineKind.allCases, id: \.self) { engine in
                        Text(engine.choiceTitle).tag(engine)
                    }
                }
                Text("For this run only. Your default engine doesn’t change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                if model.showsCloudOptions {
                    Toggle(isOn: $model.freshCloud) {
                        Text("Request a new ElevenLabs transcript")
                        Text("One aligned recording with echo reduction is sent to ElevenLabs. Matching responses are reused; a new upload may be billed.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.columns)

            if again {
                Label("Previous transcripts are backed up before regeneration.", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(again ? "Regenerate" : "Transcribe") {
                    model.regenerate()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canRegenerate)
            }
            .padding(.top, 20)
        }
        .padding(20)
        .frame(width: 460)
    }
}
