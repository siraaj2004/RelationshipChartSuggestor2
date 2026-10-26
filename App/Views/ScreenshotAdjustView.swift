import SwiftUI
import UIKit

/// Screenshot Adjustor (new in 1.8.0) — adjust the screenshot BEFORE
/// suggestions are generated, so the reply is based on the right chat
/// and the right, current messages.
///
/// The user adjusts three things, in plain words:
///  1. Top trim — slide away the status bar / chat header / any other
///     chat showing above. Start around 15% if the header is in shot.
///  2. Bottom trim — slide away the keyboard and the message composer.
///     Start around 20% if the keyboard was open when you screenshotted.
///  3. Keep only — how many of the newest messages to use. "Last 6" is
///     the default: enough for context, but old topics at the top of
///     a long screenshot can no longer drag the reply off-topic.
///
/// The preview updates live as the sliders move, so what you see is
/// what will be read. Tapping "Generate from adjusted screenshot"
/// hands the cropped image + the keep-count back to ImportChatView,
/// which runs the exact same on-device OCR + clear-old-suggestions +
/// generate flow as "Use latest screenshot" — just on cleaner input.
/// The screenshot itself never leaves this phone.
struct ScreenshotAdjustView: View {
    let original: UIImage
    /// Called with the cropped image and the number of newest messages to keep (nil = all).
    let onConfirm: (UIImage, Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var topTrim: Double = 0.15
    @State private var bottomTrim: Double = 0.20
    @State private var keepSelection = 1  // index into keepOptions
    private let keepOptions: [(label: String, count: Int?)] = [
        ("Last 4 messages", 4),
        ("Last 6 messages", 6),
        ("Last 10 messages", 10),
        ("All messages in screenshot", nil),
    ]

    private var preview: UIImage? {
        ScreenshotCropper.croppedUIImage(from: original,
                                         topFraction: CGFloat(topTrim),
                                         bottomFraction: CGFloat(bottomTrim))
    }

    var body: some View {
        Form {
            Section("Adjust — what will be read") {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("Trim too much — move a slider back so some chat is left in the picture.")
                        .font(.caption).foregroundStyle(.red)
                }
                Text("Keep only the chat bubbles in the picture. Cut off the top bar, any other chat, and the keyboard at the bottom — those are the words that make suggestions go wrong.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("1 · Trim the top") {
                Slider(value: $topTrim, in: 0...0.4, step: 0.05)
                Text("Top trim: \(Int(topTrim * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("2 · Trim the bottom") {
                Slider(value: $bottomTrim, in: 0...0.4, step: 0.05)
                Text("Bottom trim: \(Int(bottomTrim * 100))% — use more if the keyboard was open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("3 · Keep only the newest messages") {
                Picker("Keep", selection: $keepSelection) {
                    ForEach(keepOptions.indices, id: \.self) { index in
                        Text(keepOptions[index].label).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                Text("Old messages at the top of a long screenshot can pull the reply back to an old topic. Last 6 is a good default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Generate from adjusted screenshot") {
                    if let preview {
                        onConfirm(preview, keepOptions[keepSelection].count)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(preview == nil)
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .navigationTitle("Adjust screenshot")
    }
}
