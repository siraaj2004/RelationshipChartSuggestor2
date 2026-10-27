import SwiftUI

/// The user's own hints for shaping suggestions: how long they've been
/// chatting, what they're hoping for, and the tone they want. These tune the
/// replies' direction — the replies themselves still come only from the real
/// scanned/imported conversation.
struct SuggestionInputsView: View {
    @EnvironmentObject var model: AppModel
    @State private var daysText = ""
    @State private var goal = "just_chatting"
    @State private var tone = "auto"
    @State private var preferredLanguage = "auto"

    private let goals: [(code: String, label: String)] = [
        ("just_chatting", "Just chatting"),
        ("get_closer", "Grow closer"),
        ("keep_fun", "Keep it fun & light"),
        ("restart_chat", "Restart a quiet chat"),
        ("say_sorry", "Make up after a disagreement"),
    ]
    private let tones: [(code: String, label: String)] = [
        ("auto", "Auto (match the chat)"),
        ("sweet", "Sweet"),
        ("funny", "Funny"),
        ("bold", "Bold"),
        ("caring", "Caring"),
    ]
    private let languages: [(code: String, label: String)] = [
        ("auto", "Auto detect (from the chat)"),
        ("roman_urdu", "Roman Urdu"),
        ("roman_telugu", "Roman Telugu"),
        ("english", "English"),
        ("mixed_urdu_english", "Mixed Roman Urdu + English"),
        ("mixed_telugu_english", "Mixed Roman Telugu + English"),
    ]

    var body: some View {
        Form {
            Section("How long have you been chatting?") {
                HStack {
                    TextField("Days (e.g. 12)", text: $daysText)
                        .keyboardType(.numberPad)
                    Text("days").foregroundStyle(.secondary)
                }
                Text("Leave empty if you'd rather not say. The AI uses this only to judge how familiar it's natural to sound — new chats stay light, older chats can be warmer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What are you hoping for?") {
                Picker("Your goal", selection: $goal) {
                    ForEach(goals, id: \.code) { Text($0.label).tag($0.code) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Tone you want") {
                Picker("Tone", selection: $tone) {
                    ForEach(tones, id: \.code) { Text($0.label).tag($0.code) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Chat language") {
                Picker("Chat language", selection: $preferredLanguage) {
                    ForEach(languages, id: \.code) { Text($0.label).tag($0.code) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text("Set this if language detection keeps getting your chat wrong — for example, if you always chat in Roman Urdu but short messages get detected as English. When set, suggestions always use this language, and detection is skipped. Auto detect is the default.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("These are hints about YOUR situation. Suggestions are still written only from the real conversation you scanned or imported — the AI never invents shared memories or history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Your inputs")
        .onAppear {
            let inputs = model.store.loadInputs()
            daysText = inputs.daysChatting.map(String.init) ?? ""
            goal = inputs.goal
            tone = inputs.tone
            preferredLanguage = inputs.preferredLanguage
        }
        .onChange(of: daysText) { _, _ in save() }
        .onChange(of: goal) { _, _ in save() }
        .onChange(of: tone) { _, _ in save() }
        .onChange(of: preferredLanguage) { _, _ in save() }
    }

    private func save() {
        let days = Int(daysText.trimmingCharacters(in: .whitespaces))
        model.store.saveInputs(SuggestionInputs(daysChatting: (days ?? 0) > 0 ? days : nil, goal: goal, tone: tone, preferredLanguage: preferredLanguage))
    }
}
