import Foundation

/// Single source of truth shared by the app, keyboard extension and broadcast
/// extension through an App Group. No data leaves this store except through
/// APIClient, and only after the user grants `uploadConsent`.
///
/// Storage: App Group UserDefaults for small JSON payloads (context, suggestions,
/// state). This is deliberate — broadcast/keyboard extensions have tight memory
/// limits and must not depend on a shared database file lock.
public final class SharedStore {
    public static let appGroupID = "group.com.shaik.relationshipaikeyboard"
    public static let shared = SharedStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Key {
        static let context = "conversation_context_v1"
        static let suggestions = "reply_suggestions_v1"
        static let guide = "guide_state_v1"
        static let scanState = "scan_state_v1"
        static let uploadConsent = "upload_consent_v1"
        static let backendAPIKey = "backend_api_key_v1" // app-to-backend key, NOT the Gemini key
        static let backendBaseURL = "backend_base_url_v1"
        static let retentionHours = "retention_hours_v1"
        static let suggestionInputs = "suggestion_inputs_v1"
        static let lastImportedScreenshotID = "last_imported_screenshot_id_v1"
    }

    public init?(suiteName: String = SharedStore.appGroupID) {
        guard let d = UserDefaults(suiteName: suiteName) else { return nil }
        defaults = d
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }
    /// For unit tests with an isolated suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: Conversation
    public func saveContext(_ ctx: ConversationContext) {
        store(ctx, key: Key.context); defaults.set(Date(), forKey: "context_updated_at")
    }
    public func loadContext() -> ConversationContext? {
        guard let ctx: ConversationContext = retrieve(key: Key.context) else { return nil }
        if isExpired(ctx.updatedAt) { return nil }
        return ctx
    }

    // MARK: Suggestions — keyboard reads only these; it never generates text itself.
    public func saveSuggestions(_ s: ReplySuggestions) { store(s, key: Key.suggestions) }
    public func loadSuggestions() -> ReplySuggestions? {
        guard let s: ReplySuggestions = retrieve(key: Key.suggestions), !s.suggestions.isEmpty else { return nil }
        // Stale suggestions (older than 2h or based on a context that no longer exists) are not shown.
        if Date().timeIntervalSince(s.generatedAt) > 2 * 3600 { return nil }
        if loadContext() == nil { return nil }
        return s
    }
    public func clearSuggestions() { defaults.removeObject(forKey: Key.suggestions) }

    // MARK: Guide — keyboard reads this decision banner; it never
    // generates text itself, and on Wait it shows no tappable drafts.
    public func saveGuide(_ g: GuideState) { store(g, key: Key.guide) }
    public func loadGuide() -> GuideState? {
        guard let g: GuideState = retrieve(key: Key.guide),
              g.decision == "send" || g.decision == "wait" else { return nil }
        if Date().timeIntervalSince(g.generatedAt) > 2 * 3600 { return nil }
        if loadContext() == nil { return nil }
        return g
    }
    public func clearGuide() { defaults.removeObject(forKey: Key.guide) }

    // MARK: User's suggestion inputs (days / goal / tone)
    public func saveInputs(_ inputs: SuggestionInputs) { store(inputs, key: Key.suggestionInputs) }
    public func loadInputs() -> SuggestionInputs {
        let saved: SuggestionInputs? = retrieve(key: Key.suggestionInputs)
        return saved ?? SuggestionInputs()
    }

    // MARK: Recent-chat import guard
    /// Local identifier of the last screenshot used by the Recent Chat flow.
    /// Stops the same screenshot being re-imported (and re-generating the
    /// same suggestions) when the user taps the button again without taking
    /// a new screenshot first. The multi-pick import is unaffected.
    public var lastImportedScreenshotID: String? {
        get { defaults.string(forKey: Key.lastImportedScreenshotID) }
        set { defaults.set(newValue, forKey: Key.lastImportedScreenshotID) }
    }

    // MARK: Scan state / consent
    public var scanState: ScanState {
        get { ScanState(rawValue: defaults.string(forKey: Key.scanState) ?? "") ?? .idle }
        set { defaults.set(newValue.rawValue, forKey: Key.scanState) }
    }
    public var uploadConsent: Bool {
        get { defaults.bool(forKey: Key.uploadConsent) }
        set { defaults.set(newValue, forKey: Key.uploadConsent) }
    }

    // MARK: Backend config (no Gemini key ever lives on device)
    public var backendBaseURL: URL? {
        get { defaults.string(forKey: Key.backendBaseURL).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: Key.backendBaseURL) }
    }
    public var backendAPIKey: String? {
        get { defaults.string(forKey: Key.backendAPIKey) }
        set { defaults.set(newValue, forKey: Key.backendAPIKey) }
    }
    /// Hours to keep a scanned conversation. Default 24. 0 = keep until manually deleted.
    public var retentionHours: Int {
        get { defaults.object(forKey: Key.retentionHours) as? Int ?? 24 }
        set { defaults.set(newValue, forKey: Key.retentionHours) }
    }
    private func isExpired(_ date: Date) -> Bool {
        retentionHours > 0 && Date().timeIntervalSince(date) > Double(retentionHours) * 3600
    }

    // MARK: Deletion — wired to the in-app "Delete Conversation" control.
    public func deleteAllConversationData() {
        defaults.removeObject(forKey: Key.context)
        defaults.removeObject(forKey: Key.suggestions)
        defaults.removeObject(forKey: Key.guide)
        defaults.removeObject(forKey: "context_updated_at")
        scanState = .idle
    }

    private func store<T: Codable>(_ value: T, key: String) {
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: key) }
    }
    private func retrieve<T: Codable>(key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }
}
