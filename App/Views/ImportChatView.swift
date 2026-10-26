import SwiftUI
import PhotosUI
import UIKit

/// Manual import for when a live broadcast scan is not practical:
/// (a) screenshots of the conversation, OCR'd on-device with the same
///     Vision + ChatParser pipeline the broadcast extension uses, or
/// (b) chat text pasted directly.
/// Either way the parsed context is written to the App Group via
/// `saveContext` — exactly like a broadcast scan — so Generate Replies
/// and the keyboard pick it up unchanged. Screenshots are processed
/// locally and never leave the device.
struct ImportChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pastedText = ""
    @State private var isProcessing = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section("Recent chat — fastest") {
                Text("New chat came? 1) Take a screenshot of it in your chat app. 2) Come back here. 3) Tap the button below. It uses only your latest screenshot, replaces the old suggestions, and generates new ones — no browsing for the photo.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use latest screenshot → Generate replies") {
                    Task { await importLatestScreenshot() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)
                Text("The screenshot itself never leaves this phone — it is read on-device, and only the extracted chat text can go to the backend, and only if you turned consent ON.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("From screenshots") {
                Text("Pick up to 10 screenshots of the conversation, in order. Text is recognised on this device — the screenshots themselves are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    Label("Choose screenshots", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(isProcessing)
            }
            Section("Paste chat text") {
                TextEditor(text: $pastedText)
                    .frame(minHeight: 140)
                Button("Use pasted text") { importPastedText() }
                    .disabled(isProcessing || pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if isProcessing {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading screenshots…")
                    }
                }
            }
            if let statusMessage {
                Section {
                    Text(statusMessage)
                }
            }
            if model.context != nil {
                Section("Suggestions") {
                    if !model.store.uploadConsent {
                        Text("One switch first: turn ON “Allow sending extracted chat text to my backend” in Privacy & backend settings — that's the consent the AI needs before it can write replies.")
                            .font(.caption).foregroundStyle(.secondary)
                        NavigationLink("Open Privacy & backend settings", destination: SettingsView())
                    }
                    Button("Generate Replies") { Task { await model.generateReplies() } }
                        .buttonStyle(.borderedProminent)
                    if let s = model.suggestions {
                        ForEach(s.suggestions, id: \.self) { suggestion in
                            Text(suggestion)
                                .contentShape(Rectangle())
                                .onTapGesture { UIPasteboard.general.string = suggestion }
                        }
                        Text("Tap a suggestion to copy it, then paste it into your chat app.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let e = model.errorMessage {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Import Chat")
        .onChange(of: photoItems) { _, items in
            Task { await importScreenshots(items) }
        }
    }

    // MARK: Recent chat -> latest screenshot -> new suggestions

    /// One-tap path for a chat that just arrived. The user screenshots it
    /// (iOS gives no other way for an app to see another app's new chat),
    /// this reads that one latest screenshot, and — with consent ON — it
    /// generates replies immediately, so there is no second tap.
    /// The old suggestions are cleared first, so the keyboard can never
    /// keep showing the previous chat's replies after a new import.
    private func importLatestScreenshot() async {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }
        do {
            let recent = try await RecentScreenshotImporter.fetchLatest()
            if let last = model.store.lastImportedScreenshotID, last == recent.assetID {
                statusMessage = "That screenshot was already used. Take a new screenshot of the new chat first, then tap again — otherwise you would just get the same suggestions again."
                return
            }
            guard let cgImage = recent.image.cgImage else {
                statusMessage = "The latest screenshot could not be read. Try “Choose screenshots” and pick it manually."
                return
            }
            let when = recent.creationDate ?? Date()
            let observations = OCRService.recognise(cgImage: cgImage)
            let ctx = ChatParser.parse(frames: [
                ChatParser.Frame(observations: observations, capturedAt: when, sequence: 0)
            ])
            guard !ctx.messages.isEmpty else {
                statusMessage = "No chat text was found in the latest screenshot. Take a clearer screenshot of the conversation (the messages, not just the chat list) and try again."
                return
            }
            model.store.clearSuggestions()
            model.store.lastImportedScreenshotID = recent.assetID
            model.store.saveContext(ctx)
            model.refreshFromStore()
            let time = DateFormatter.localizedString(from: when, dateStyle: .none, timeStyle: .short)
            let language = LanguageDetector.detect(context: ctx).rawValue.replacingOccurrences(of: "_", with: " ")
            if !model.store.uploadConsent {
                statusMessage = "Imported \(ctx.messages.count) messages from your latest screenshot (\(time)) · Language: \(language). Turn ON “Allow sending extracted chat text to my backend” in Privacy & backend settings, then tap Generate Replies below."
                return
            }
            statusMessage = "Latest screenshot (\(time)) · \(ctx.messages.count) messages · Generating replies…"
            await model.generateReplies()
            if let e = model.errorMessage {
                // Let the user retry the same screenshot: it was imported
                // but no new suggestions were produced from it yet.
                model.store.lastImportedScreenshotID = nil
                statusMessage = "Imported \(ctx.messages.count) messages from your latest screenshot (\(time)), but replies failed: \(e)"
            } else {
                statusMessage = "Done — latest screenshot (\(time)) · \(ctx.messages.count) messages · 3 new suggestions ready. Open your chat, switch to the Relationship AI keyboard, and tap a suggestion to insert it. It never sends by itself."
            }
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Screenshots -> OCR -> ChatParser

    private func importScreenshots(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isProcessing = true
        statusMessage = nil
        let capturedAt = Date()
        var frames: [ChatParser.Frame] = []
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else { continue }
            let observations = OCRService.recognise(cgImage: cgImage)
            frames.append(ChatParser.Frame(observations: observations, capturedAt: capturedAt, sequence: index))
        }
        let ctx = ChatParser.parse(frames: frames)
        finishImport(ctx)
        photoItems = []
        isProcessing = false
    }

    // MARK: Pasted text -> one message per line

    private func importPastedText() {
        let lines = pastedText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let capturedAt = Date()
        let messages = lines.enumerated().map { index, line in
            ChatMessage(text: line, sender: .unknown, confidence: 1.0, orderIndex: index, capturedAt: capturedAt)
        }
        let ctx = ConversationContext(messages: messages,
                                      language: LanguageDetector.detect(texts: lines))
        finishImport(ctx)
    }

    // MARK: Shared save + result state

    private func finishImport(_ ctx: ConversationContext) {
        if ctx.messages.isEmpty {
            statusMessage = "No chat text was found in those screenshots. Try clearer screenshots of the conversation."
        } else {
            model.store.saveContext(ctx)
            model.refreshFromStore()
            let language = LanguageDetector.detect(context: ctx)
            statusMessage = "Imported \(ctx.messages.count) messages · Language: \(language.rawValue.replacingOccurrences(of: "_", with: " "))\nNow tap Generate Replies below."
        }
    }
}
