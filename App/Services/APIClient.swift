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
            // Generous timeouts: a free-tier backend can take ~50s to wake.
            cfg.timeoutIntervalForRequest = 45
            cfg.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Built-in defaults shipped in the app's Info.plist, so the app works out
    /// of the box. Values the user saves in Settings override them.
    public static var defaultBaseURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String).flatMap(URL.init(string:))
    }
    public static var defaultAPIKey: String? {
        let k = Bundle.main.object(forInfoDictionaryKey: "AppAPIKey") as? String
        return (k?.isEmpty == false) ? k : nil
    }
    public var effectiveBaseURL: URL? { store.backendBaseURL ?? Self.defaultBaseURL }
    public var effectiveAPIKey: String? {
        if let k = store.backendAPIKey, !k.isEmpty { return k }
        return Self.defaultAPIKey
    }

    private struct AnalyzeRequest: Codable { let messages: [MessageDTO]; let language_hint: String? }
    private struct GenerateRequest: Codable { let messages: [MessageDTO]; let language_hint: String?; let context: InputsDTO? }
    private struct InputsDTO: Codable { let days_chatting: Int?; let goal: String?; let tone: String? }
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
        let inputs = store.loadInputs()
        let inputsDTO = InputsDTO(days_chatting: inputs.daysChatting, goal: inputs.goal, tone: inputs.tone)
        let data = try await encode(context, path: "generate-replies", body: GenerateRequest(
            messages: context.messages.map(dto), language_hint: context.language.rawValue, context: inputsDTO))
        guard let r = try? JSONDecoder().decode(GenerateResponse.self, from: data) else { throw APIError.decoding }
        let clean = r.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        // Hard rule: anything other than exactly 3 real replies is treated as no suggestions.
        guard clean.count == 3 else { throw APIError.emptySuggestions }
        let out = ReplySuggestions(suggestions: clean, basedOnMessageCount: r.based_on_message_count)
        store.saveSuggestions(out)
        return out
    }

    private struct ScanLatestResponse: Codable {
        let messages: [MessageDTO]; let language: String; let suggestions: [String]
        let based_on_message_count: Int; let updated_at: Double
    }

    /// Fetch the results of a broadcast scan. During the scan, the broadcast
    /// extension uploads extracted text to the backend (/scan-ingest), which
    /// generates suggestions and holds them briefly; this call retrieves them.
    /// It exists because free-signed installs can block the App Group channel.
    /// No uploadConsent check here: the upload already happened only inside a
    /// broadcast the user explicitly started from the consent-gated Scan
    /// screen; this GET just retrieves the user's own scan results.
    public func fetchScanLatest() async throws -> Bool {
        guard let base = effectiveBaseURL, let key = effectiveAPIKey, !key.isEmpty else { throw APIError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent("scan-latest"))
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.decoding }
        if http.statusCode == 404 { return false }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let r = try? JSONDecoder().decode(ScanLatestResponse.self, from: data) else { throw APIError.decoding }
        let when = Date(timeIntervalSince1970: r.updated_at)
        let messages = r.messages.enumerated().map { index, m in
            ChatMessage(text: m.text, sender: Sender(rawValue: m.sender) ?? .unknown,
                        confidence: m.confidence, orderIndex: index, capturedAt: when)
        }
        let ctx = ConversationContext(messages: messages,
                                      language: DetectedLanguage(rawValue: r.language) ?? .unknown,
                                      updatedAt: when)
        store.saveContext(ctx)
        let clean = r.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if clean.count == 3 {
            store.saveSuggestions(ReplySuggestions(suggestions: clean, generatedAt: when,
                                                   basedOnMessageCount: r.based_on_message_count))
        }
        return true
    }

    /// Best-effort: clear the server-held scan relay entry (Delete controls).
    public func deleteScanLatest() async {
        guard let base = effectiveBaseURL, let key = effectiveAPIKey else { return }
        var req = URLRequest(url: base.appendingPathComponent("scan-latest"))
        req.httpMethod = "DELETE"
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        _ = try? await session.data(for: req)
    }

    private func dto(_ m: ChatMessage) -> MessageDTO { MessageDTO(text: m.text, sender: m.sender.rawValue, confidence: m.confidence) }

    private func encode<T: Encodable>(_ context: ConversationContext, path: String, body: T) async throws -> Data {
        guard !context.messages.isEmpty else { throw APIError.noContext }
        guard store.uploadConsent else { throw APIError.consentNotGiven }
        guard let base = effectiveBaseURL, let key = effectiveAPIKey, !key.isEmpty else { throw APIError.notConfigured }
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
