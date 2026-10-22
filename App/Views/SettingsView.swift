import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var consent = false
    @State private var retention = 24

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Backend URL (https://…)", text: $baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("App API key (not the Gemini key)", text: $apiKey)
                Text("The Gemini key lives only on your server. This key just authenticates this app to your FastAPI backend.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save backend settings") {
                    model.store.backendBaseURL = URL(string: baseURL)
                    model.store.backendAPIKey = apiKey
                }
            }
            Section("Privacy") {
                Toggle("Allow sending extracted chat text to my backend", isOn: $consent)
                    .onChange(of: consent) { _, v in model.store.uploadConsent = v }
                Stepper("Keep scanned data for \(retention) hours (0 = until deleted)", value: $retention, in: 0...168)
                    .onChange(of: retention) { _, v in model.store.retentionHours = v }
                Text("Screenshots and video are never uploaded. Only the OCR text you scanned is sent, and only when you tap Generate Replies.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Delete all conversation data", role: .destructive) { model.deleteAllData() }
            }
        }
        .navigationTitle("Privacy & Settings")
        .onAppear {
            baseURL = model.store.backendBaseURL?.absoluteString ?? ""
            apiKey = model.store.backendAPIKey ?? ""
            consent = model.store.uploadConsent
            retention = model.store.retentionHours
        }
    }
}
