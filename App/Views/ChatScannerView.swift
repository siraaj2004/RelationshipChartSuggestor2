import SwiftUI
import ReplayKit

/// ReplayKit flow, as Apple requires it:
/// 1. The user reads the consent explanation and opts in (stored consent).
/// 2. The user taps the system broadcast picker and EXPLICITLY starts the
///    broadcast in iOS's own UI. This app cannot and does not start it silently.
/// 3. The user switches to WhatsApp/Messenger/etc. and scrolls the conversation.
/// 4. The broadcast extension OCRs visible frames and writes parsed context to
///    the App Group. Video itself is never uploaded or stored.
/// 5. The user stops the broadcast from the iOS status indicator / picker.
struct ChatScannerView: View {
    @EnvironmentObject var model: AppModel
    @State private var consent = false
    @State private var pickerShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(statusText, systemImage: statusIcon)
                    .font(.headline)
                    .foregroundStyle(model.scanState == .broadcasting ? .red : .primary)
                Text("""
                Scanning reads only what is visible on screen while the broadcast is running. \
                Extracted text is stored on this device in the app group. Nothing is sent to the \
                backend until you tap Generate Replies and have given upload consent in Settings. \
                Full screen video is never uploaded or saved.
                """).font(.callout).foregroundStyle(.secondary)

                Toggle("I consent to scanning the conversation I choose to show on screen", isOn: $consent)
                    .onChange(of: consent) { _, v in if v { model.scanState = .awaitingConsent } }

                BroadcastPickerView()
                    .frame(width: 56, height: 56)
                    .opacity(consent ? 1 : 0.35)
                    .disabled(!consent)
                Text("Tap the broadcast button above, choose “Chat Scanner”, then open your messaging app and scroll slowly through the conversation. Tap the red recording indicator to stop.")
                    .font(.footnote).foregroundStyle(.secondary)

                if let ctx = model.context, !ctx.messages.isEmpty {
                    Divider()
                    Text("Scanned conversation (\(ctx.messages.count) messages · \(ctx.language.rawValue.replacingOccurrences(of: "_", with: " ")))")
                        .font(.subheadline).bold()
                    ForEach(ctx.messages) { m in
                        HStack(alignment: .top) {
                            Text(m.sender == .me ? "You" : m.sender == .other ? "Them" : "?")
                                .font(.caption).bold().frame(width: 36, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(m.text).font(.callout)
                                if !m.uncertaintyNotes.isEmpty {
                                    Text(m.uncertaintyNotes.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                                if m.confidence < 0.6 {
                                    Text("Confidence \(Int(m.confidence * 100))% — check wording before relying on it")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    Button("Generate Replies") { Task { await model.generateReplies() } }
                        .buttonStyle(.borderedProminent)
                    if let s = model.suggestions {
                        ForEach(s.suggestions, id: \.self) { Text($0).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
                        Text("These now appear in the keyboard's suggestion bar. Tapping one inserts text — it never sends automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Stop Scanning", role: .destructive) { stopBroadcast() }
                Button("Delete Conversation", role: .destructive) { model.deleteAllData() }
                if let e = model.errorMessage { Text(e).foregroundStyle(.red).font(.callout) }
            }.padding()
        }
        .navigationTitle("Scan Chat")
        .onAppear { model.refreshFromStore() }
    }

    private var statusText: String {
        switch model.scanState {
        case .idle: return "Not scanning"
        case .awaitingConsent: return "Ready — start the broadcast when you are"
        case .broadcasting: return "● Broadcasting — your screen is being scanned"
        case .processing: return "Processing captured text…"
        case .ready: return "Conversation ready"
        case .failed: return "Scanning failed"
        case .stopped: return "Scanning stopped"
        }
    }
    private var statusIcon: String { model.scanState == .broadcasting ? "record.circle" : "text.viewfinder" }

    private func stopBroadcast() {
        // The broadcast can only be fully stopped by the user in iOS's UI; we mark
        // our state stopped so the extension discards further frames on its next check.
        model.store.scanState = .stopped
        model.scanState = .stopped
    }
}

/// Wraps RPSystemBroadcastPickerView, pre-selecting our broadcast extension.
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = "com.shaik.relationshipaikeyboard.broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
