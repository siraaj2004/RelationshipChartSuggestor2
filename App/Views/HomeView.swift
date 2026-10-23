import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationStack {
            List {
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
                Section {
                    Button("Delete all conversation data", role: .destructive) { model.deleteAllData() }
                }
            }
            .navigationTitle("Relationship AI")
            .sheet(isPresented: $model.showScanner) { NavigationStack { ChatScannerView() } }
            .onAppear { model.refreshFromStore() }
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
