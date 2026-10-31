import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section("Recent chat — screenshot → suggestions") {
                    Text("New chat came? Screenshot it in your chat app, come back here, and tap below — it uses only your latest screenshot and replaces the old suggestions.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink("Recent chat: use latest screenshot", destination: ImportChatView())
                }
                Section("Get started") {
                    NavigationLink("1 · Import chat (screenshots or text)", destination: ImportChatView())
                    NavigationLink("2 · Your inputs (days · goal · tone)", destination: SuggestionInputsView())
                    NavigationLink("3 · Scan a chat (live broadcast)", destination: ChatScannerView())
                    NavigationLink("4 · Privacy & backend settings", destination: SettingsView())
                    NavigationLink("5 · Enable the keyboard", destination: KeyboardSetupView())
                }
                Section("Setup status") {
                    HStack {
                        Text("Backend")
                        Spacer()
                        Text(APIClient.defaultBaseURL != nil ? "Connected ✓" : "Not set")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Sending consent")
                        Spacer()
                        Text(model.store.uploadConsent ? "On ✓" : "Off — turn on in Settings")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Conversation")
                        Spacer()
                        Text(model.context.map { "\($0.messages.count) messages" } ?? "None yet")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Current conversation") {
                    if let ctx = model.context, !ctx.messages.isEmpty {
                        Text("\(ctx.messages.count) scanned messages")
                        Text("Language: \(ctx.language.rawValue.replacingOccurrences(of: "_", with: " "))")
                        if let a = model.analysis { Text("Tone: \(a.tone.rawValue) · Topic: \(a.topic)") }
                        Button("Refresh from scanner") { model.refreshFromStore() }
                        Button("Generate Replies") { Task { await model.generateReplies() } }
                    } else {
                        Text("No conversation yet. Suggestions stay empty until a real chat is imported or scanned — the app never shows invented replies.")
                            .foregroundStyle(.secondary)
                        Text("Most reliable on this install: Import Chat with screenshots of the conversation. It reads the chat inside the app itself.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Fetch broadcast scan results") { Task { await model.fetchScanResults() } }
                        if let m = model.scanFetchMessage {
                            Text(m).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let s = model.suggestions {
                    Section("AI suggestions — tap one to copy it") {
                        ForEach(s.suggestions, id: \.self) { suggestion in
                            Text(suggestion)
                                .contentShape(Rectangle())
                                .onTapGesture { UIPasteboard.general.string = suggestion }
                        }
                    }
                }
                if model.context != nil {
                    Section("Guide — should I message now?") {
                        Text("After a scan, tap Get Guide. It reads only this scanned chat and tells you: message now or wait, why, and what to do next — plus 3 draft ideas in the chat's language. Nothing is sent by itself. If it says Wait, the drafts are for later only and are NOT sent to the keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let ctx = model.context, let last = ctx.messages.last {
                            Text("Accuracy check — this guide will be based on \(ctx.messages.count) messages. Last message (\(last.sender.rawValue)): “\(last.text)”")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("If that last message is NOT her latest message, do NOT trust the guide yet — import a new screenshot of the latest chat first, then Get Guide again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(model.isGuiding ? "Getting guide…" : "Get Guide") {
                            Task { await model.guideChat() }
                        }.disabled(model.isGuiding)
                        if let g = model.guide {
                            Text(g.isSend ? "✅ Message now" : "⏳ Wait — don't message now")
                                .font(.headline)
                            Text("Based on \(g.basedOnMessageCount) messages from this scanned chat only.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Why: \(g.reason)")
                            Text("Do this: \(g.action)")
                            Text(g.isSend ? "Drafts — tap one to copy it, or use it from the keyboard:" : "Drafts for later — do NOT send these now, keep them for when she replies or after a gap. Tap one to copy it:")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(g.drafts, id: \.self) { draft in
                                Text(draft)
                                    .contentShape(Rectangle())
                                    .onTapGesture { UIPasteboard.general.string = draft }
                            }
                        }
                        if let e = model.errorMessage {
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Section("Ask about this chat") {
                        Text("After a screenshot or scan, ask a question about this chat — for example, what does she mean by the last message, or how should I reply to it? You get a short answer based only on this chat, plus 3 suggestions that follow from it. Tap a suggestion to copy it, or use it from the keyboard.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Ask about this chat…", text: $model.askQuestionText)
                            .textFieldStyle(.roundedBorder)
                        Button(model.isAsking ? "Asking…" : "Ask") {
                            Task { await model.askAboutChat() }
                        }.disabled(model.isAsking || model.askQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let answer = model.askAnswer {
                            Text(answer)
                        }
                        if let e = model.errorMessage {
                            Text(e).font(.caption).foregroundStyle(.red)
                        }
                        if model.lastRelaySyncFailed {
                            Text("Answer is ready here, but the keyboard copy may be delayed — tap ↻ Refresh on the keyboard.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Delete all conversation data", role: .destructive) { model.deleteAllData() }
                }
            }
            .navigationTitle("Relationship AI")
            .sheet(isPresented: $model.showScanner) { NavigationStack { ChatScannerView() } }
            .sheet(isPresented: $model.showSelectMessage) { NavigationStack { ImportChatView(autoOpenSelect: true) } }
            .onAppear {
            model.refreshFromStore()
            Task { await model.autoFetchScanResultsIfNeeded() }
        }
        }
    }
}

struct KeyboardSetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enable the keyboard").font(.title2).bold()
                Text("""
                1. Open iOS Settings → General → Keyboard → Keyboards → Add New Keyboard → Relationship AI Keyboard.
                2. Tap it and turn on “Allow Full Access” if you want AI suggestions.
                3. In WhatsApp, Instagram, Messenger or Telegram, tap the globe key to switch to it.

                About Full Access: iOS keyboards are sandboxed. Full Access is what lets this keyboard read the App-Group suggestions created from a chat you scanned, and reach your backend. Without it the keyboard still types normally, but the suggestion bar stays empty. The keyboard never logs keystrokes, never sends a message on its own, and inserts text only when you tap a suggestion or a key.
                """)
                Button("Open iOS Settings") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }.buttonStyle(.borderedProminent)
            }.padding()
        }.navigationTitle("Keyboard setup")
    }
}
