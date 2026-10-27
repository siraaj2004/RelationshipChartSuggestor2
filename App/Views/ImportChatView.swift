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
    /// When true (keyboard "Select 📸" deep link), the Select Message
    /// screen opens automatically once, so the user does not have to
    /// hunt for the button after jumping from the keyboard.
    let autoOpenSelect: Bool
    init(autoOpenSelect: Bool = false) { self.autoOpenSelect = autoOpenSelect }
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pastedText = ""
    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var adjustImage: UIImage?
    @State private var adjustAssetID: String?
    @State private var selectImage: UIImage?
    @State private var didAutoOpenSelect = false

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
                Button("Adjust screenshot → More accurate replies") {
                    Task { await openAdjustor() }
                }
                .disabled(isProcessing)
                Text("Adjustor (new in 1.8.0): trim the top bar / keyboard off the screenshot and keep only the last few messages, so the reply is based on the current chat — not on old topics or stray words from the screen.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Select a message 📸 → Reply to just that message") {
                    Task { await openSelectMessage() }
                }
                .disabled(isProcessing)
                Text("Select Message (new in 1.9.0): your latest screenshot opens, you drag a rectangle around ONE particular message, and only that message is read and answered — in Roman Urdu, Roman Telugu, or English, whichever that message is in.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .sheet(isPresented: Binding(
            get: { adjustImage != nil },
            set: { if !$0 { adjustImage = nil } }
        )) {
            if let adjustImage {
                NavigationStack {
                    ScreenshotAdjustView(original: adjustImage) { cropped, keepLast in
                        Task { await importAdjustedScreenshot(cropped, keepLast: keepLast) }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { selectImage != nil },
            set: { if !$0 { selectImage = nil } }
        )) {
            if let selectImage {
                NavigationStack {
                    MessageSelectView(original: selectImage) { rect in
                        Task { await importSelectedMessage(rect) }
                    }
                }
            }
        }
        .onAppear {
            // Keyboard deep-link only, and only once: re-appearing
            // after the Select sheet closes must NOT re-open it.
            if autoOpenSelect && !didAutoOpenSelect {
                didAutoOpenSelect = true
                Task { await openSelectMessage() }
            }
        }
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

    // MARK: Screenshot Adjustor -> cropped screenshot -> new suggestions

    /// Opens the Adjustor with the latest screenshot. The same-screenshot
    /// guard applies here too: adjusting the same screenshot you already
    /// used, without a new screenshot, would just regenerate the same
    /// replies — so it says so instead.
    private func openAdjustor() async {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }
        do {
            let recent = try await RecentScreenshotImporter.fetchLatest()
            if let last = model.store.lastImportedScreenshotID, last == recent.assetID {
                statusMessage = "That screenshot was already used. Take a new screenshot of the new chat first, then adjust it — otherwise you would just get the same suggestions again."
                return
            }
            adjustAssetID = recent.assetID
            adjustImage = recent.image
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Same import + generate flow as the one-tap path, but on the
    /// user-adjusted (cropped) image, and keeping only the newest
    /// `keepLast` messages when one was chosen. Old suggestions are
    /// cleared first, exactly as in the one-tap path.
    private func importAdjustedScreenshot(_ cropped: UIImage, keepLast: Int?) async {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }
        guard let cgImage = cropped.cgImage else {
            statusMessage = "The adjusted screenshot could not be read. Try again from the latest screenshot."
            return
        }
        let observations = OCRService.recognise(cgImage: cgImage)
        var ctx = ChatParser.parse(frames: [
            ChatParser.Frame(observations: observations, capturedAt: Date(), sequence: 0)
        ])
        if let keepLast, ctx.messages.count > keepLast {
            let kept = Array(ctx.messages.suffix(keepLast))
            ctx = ConversationContext(messages: kept,
                                      language: LanguageDetector.detect(context: ctx),
                                      updatedAt: Date())
        }
        guard !ctx.messages.isEmpty else {
            statusMessage = "No chat text was found in the adjusted area. Trim less — keep the chat bubbles in the picture — and try again."
            return
        }
        model.store.clearSuggestions()
        if let assetID = adjustAssetID {
            model.store.lastImportedScreenshotID = assetID
        }
        model.store.saveContext(ctx)
        model.refreshFromStore()
        let language = LanguageDetector.detect(context: ctx).rawValue.replacingOccurrences(of: "_", with: " ")
        if !model.store.uploadConsent {
            statusMessage = "Adjusted screenshot · \(ctx.messages.count) messages kept · Language: \(language). Turn ON “Allow sending extracted chat text to my backend” in Privacy & backend settings, then tap Generate Replies below."
            return
        }
        statusMessage = "Adjusted screenshot · \(ctx.messages.count) messages kept · Generating replies…"
        await model.generateReplies()
        if let e = model.errorMessage {
            model.store.lastImportedScreenshotID = nil
            statusMessage = "Adjusted screenshot · \(ctx.messages.count) messages kept, but replies failed: \(e)"
        } else {
            statusMessage = "Done — adjusted screenshot · \(ctx.messages.count) messages kept · 3 new suggestions ready. Open your chat, switch to the Relationship AI keyboard, and tap a suggestion to insert it. It never sends by itself."
        }
    }

    // MARK: Select Message -> one rectangle -> reply to that message

    /// Opens Select Message with the latest screenshot. Deliberately
    /// no same-screenshot guard here: selecting a DIFFERENT message
    /// from the same screenshot is the whole point, so re-opening
    /// the same screenshot with a new rectangle must always work.
    private func openSelectMessage() async {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }
        do {
            let recent = try await RecentScreenshotImporter.fetchLatest()
            selectImage = recent.image
        } catch {
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// OCRs ONLY the user-drawn rectangle, then generates replies to
    /// that one message. The rectangle's sender is judged from its
    /// centre in the full screenshot (left = them, right = you),
    /// because a cropped bubble on its own would always look centred.
    /// Old suggestions are cleared first, exactly as in the other
    /// Recent flows, so the keyboard shows this message's replies.
    /// The selected message's language (Roman Urdu / Roman Telugu /
    /// English) is detected from its own text, and the 3 replies
    /// come back in that language.
    private func importSelectedMessage(_ rect: CGRect) async {
        guard !isProcessing else { return }
        isProcessing = true
        statusMessage = nil
        defer { isProcessing = false }
        guard let original = selectImage,
              let cgImage = ScreenshotCropper.croppedCGImage(from: original, rect: rect) else {
            statusMessage = "That selection could not be read. Drag a slightly bigger box around the message and try again."
            return
        }
        let observations = OCRService.recognise(cgImage: cgImage)
        // Top-to-bottom, as the message reads. Vision y is bottom-origin.
        let lines = observations.sorted { $0.y > $1.y }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            statusMessage = "No text was found inside that box. Drag the box so it covers the whole message bubble and try again."
            return
        }
        let text = lines.joined(separator: " ")
        let sender = ScreenshotCropper.senderForSelection(midX: rect.midX)
        let message = ChatMessage(text: text, sender: sender, confidence: 1.0,
                                  orderIndex: 0, capturedAt: Date())
        // Language fallback (2026-10-27): one short message often has
        // no marker words at all, so detection alone would say
        // unknown/English even for a Roman chat. Keep the previous
        // chat's language when this message alone says unknown —
        // the message itself is still the only reply context.
        let detected = LanguageDetector.detect(texts: lines)
        let language = detected == .unknown ? (model.context?.language ?? .unknown) : detected
        let ctx = ConversationContext(messages: [message], language: language)
        model.store.clearSuggestions()
        model.store.saveContext(ctx)
        model.refreshFromStore()
        let language = ctx.language.rawValue.replacingOccurrences(of: "_", with: " ")
        if !model.store.uploadConsent {
            statusMessage = "Selected message · Language: \(language). Turn ON “Allow sending extracted chat text to my backend” in Privacy & backend settings, then tap Generate Replies below — the suggestion will be in that language, and tapping it copies it for your keyboard."
            return
        }
        statusMessage = "Selected message · Language: \(language) · Generating replies…"
        await model.generateReplies()
        if let e = model.errorMessage {
            statusMessage = "Selected message · Language: \(language), but replies failed: \(e)"
        } else if model.lastRelaySyncFailed {
            statusMessage = "Done — 3 new suggestions ready for that one message (\(language)) in this app, but they could not be sent to the keyboard yet. Open your chat, switch to the Relationship AI keyboard, and tap ↻ Refresh — if they still show the old chat, come back here and tap Generate Replies again. It never sends by itself."
        } else {
            statusMessage = "Done — 3 new suggestions ready for that one message (\(language)). Tap a suggestion below to copy it, or open your chat, switch to the Relationship AI keyboard, and tap a suggestion to insert it. It never sends by itself."
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
