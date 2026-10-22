import Foundation

public enum APIError: Error, LocalizedError {
    case noContext, consentNotGiven, notConfigured, http(Int, String), timeout, decoding, emptySuggestions
    public var errorDescription: String? {
        switch self {
        case .noContext: return "No scanned conversation is available. Scan a chat first."
        case .consentNotGiven: return "You have not consented to sending extracted text to the backend."
        case .notConfigured: return "Backend URL or app API key is not configured in Settings."
        case .http(let code, let body): return "Backend error (\(code)): \(body)"
        case .timeout: return "The backend request timed out."
        case .decoding: return "The backend returned an unexpected response."
        case .emptySuggestions: return "The backend returned no suggestions for this context."
        }
    }
}

/// Talks ONLY to your FastAPI backend. The Gemini key never leaves the server.
/// Only extracted message text is sent — never screenshots or video.
public final class APIClient {
    private let store: SharedStore
    private let session: URLSession

    public init(store: SharedStore = .shared!, session: URLSession? = nil) {
        self.store = store
        if let session { self.session = session }
        else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 25
            self.session = URLSession(configuration: cfg)
        }
    }

    private struct AnalyzeRequest: Codable { let messages: [MessageDTO]; let language_hint: String? }
    private struct GenerateRequest: Codable { let messages: [MessageDTO]; let language_hint: String? }
    private struct MessageDTO: Codable { let text: String; let sender: String; let confidence: Double }
    private struct AnalyzeResponse: Codable { let language: String; let tone: String; let topic: String; let latest_incoming_text: String?; let summary: String }
    private struct GenerateResponse: Codable { let suggestions: [String]; let language: String; let based_on_message_count: Int }

    public func analyze(context: ConversationContext) async throws -> AnalysisResult {
        let dto = try await encode(context, path: "analyze-chat", body: AnalyzeRequest(
            messages: context.messages.map(dto), language_hint: context.language.rawValue))
        guard let r = try? JSONDecoder().decode(AnalyzeResponse.self, from: dto) else { throw APIError.decoding }
        return AnalysisResult(language: DetectedLanguage(rawValue: r.language) ?? context.language,
                              tone: ToneLabel(rawValue: r.tone) ?? .unknown, topic: r.topic,
                              latestIncomingText: r.latest_incoming_text, summary: r.summary)
    }

    public func generateReplies(context: ConversationContext) async throws -> ReplySuggestions {
        guard !context.messages.isEmpty else { throw APIError.noContext }
        let data = try await encode(context, path: "generate-replies", body: GenerateRequest(
            messages: context.messages.map(dto), language_hint: context.language.rawValue))
        guard let r = try? JSONDecoder().decode(GenerateResponse.self, from: data) else { throw APIError.decoding }
        let clean = r.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Hard rule: anything other than exactly 3 real replies is treated as no suggestions.
        guard clean.count == 3 else { throw APIError.emptySuggestions }
        let out = ReplySuggestions(suggestions: clean, basedOnMessageCount: r.based_on_message_count)
        store.saveSuggestions(out)
        return out
    }

    private func dto(_ m: ChatMessage) -> MessageDTO { MessageDTO(text: m.text, sender: m.sender.rawValue, confidence: m.confidence) }

    private func encode<T: Encodable>(_ context: ConversationContext, path: String, body: T) async throws -> Data {
        guard !context.messages.isEmpty else { throw APIError.noContext }
        guard store.uploadConsent else { throw APIError.consentNotGiven }
        guard let base = store.backendBaseURL, let key = store.backendAPIKey, !key.isEmpty else { throw APIError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.httpBody = try JSONEncoder().encode(body)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.decoding }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            return data
        } catch let e as URLError where e.code == .timedOut { throw APIError.timeout }
    }
}
