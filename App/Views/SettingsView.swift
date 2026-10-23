import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var consent = false
    @State private var retention = 24
    @State private var backendStatus: String? = nil

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Backend URL (https://…)", text: $baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("App API key (not the Gemini key)", text: $apiKey)
                Text("Your backend is connected by default — the fields below are pre-filled with your server. Change them only if you run your own server. The Gemini key lives only on the server; this app key just authenticates the app to it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save backend settings") {
                    model.store.backendBaseURL = URL(string: baseURL)
                    model.store.backendAPIKey = apiKey
                }
                Button("Check backend connection") { Task { await checkBackend() } }
                if let backendStatus {
                    Text(backendStatus)
                        .font(.caption).foregroundStyle(.secondary)
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
            baseURL = model.store.backendBaseURL?.absoluteString ?? APIClient.defaultBaseURL?.absoluteString ?? ""
            apiKey = model.store.backendAPIKey ?? APIClient.defaultAPIKey ?? ""
            consent = model.store.uploadConsent
            retention = model.store.retentionHours
        }
    }

    /// GET <baseURL>/health — the FastAPI backend answers
    /// {"status": "ok", "gemini_configured": true/false}.
    private func checkBackend() async {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            backendStatus = "Backend URL is not set."
            return
        }
        var request = URLRequest(url: url.appendingPathComponent("health"))
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                backendStatus = "Cannot reach the backend at that URL. Check the address and that the server is running."
                return
            }
            let health = try JSONDecoder().decode(BackendHealth.self, from: data)
            backendStatus = health.gemini_configured
                ? "Backend reachable — Gemini is configured. You're ready to generate replies."
                : "Backend reachable, but the server has no Gemini key configured."
        } catch {
            backendStatus = "Cannot reach the backend at that URL. Check the address and that the server is running."
        }
    }
}

private struct BackendHealth: Decodable {
    let status: String
    let gemini_configured: Bool
}
