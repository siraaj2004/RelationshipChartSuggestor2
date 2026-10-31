import SwiftUI

@main
struct RelationshipApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .onOpenURL { url in model.handleOpenURL(url) }
        }
    }
}

/// App-wide state. The keyboard's "Scan Chat" button opens this app via the
/// `relationshipai://scan` scheme (registered implicitly by the app bundle id
/// convention used in KeyboardViewController) — iOS does not let a keyboard
/// extension start a broadcast itself, so the permitted flow is:
/// keyboard -> host app -> RPSystemBroadcastPickerView -> user authorises.
/// The keyboard's "Select 📸" button (new in 1.10.0) works the same way
/// via `relationshipai://select-message`: it opens this app straight to
/// the Select Message screen. The rectangle is drawn in the app, not
/// over the chat, because a keyboard extension's view is only the
/// keyboard area and cannot cover or read the chat above it.
@MainActor
final class AppModel: ObservableObject {
    @Published var context: ConversationContext?
    @Published var suggestions: ReplySuggestions?
    @Published var analysis: AnalysisResult?
    @Published var scanState: ScanState = .idle
    @Published var errorMessage: String?
    @Published var showScanner = false
    @Published var showSelectMessage = false
    @Published var askAnswer: String?
    @Published var askQuestionText = ""
    @Published var isAsking = false
    @Published var guide: APIClient.GuideResult?
    @Published var isGuiding = false
    /// True when the last generated replies could NOT be published to
    /// the server relay the keyboard reads from. The in-app replies
    /// are still fine; only the keyboard copy may be stale until
    /// a Refresh succeeds.
    @Published var lastRelaySyncFailed = false

    let store: SharedStore = .shared!
    private lazy var api = APIClient(store: store)

    init() { refreshFromStore() }

    func refreshFromStore() {
        context = store.loadContext()
        suggestions = store.loadSuggestions()
        scanState = store.scanState
    }

    func handleOpenURL(_ url: URL) {
        if url.host == "scan" || url.path.contains("scan") { showScanner = true }
        if url.host == "select-message" || url.path.contains("select-message") { showSelectMessage = true }
        refreshFromStore()
    }

    /// Ask a question about the current scanned chat. The answer and
    /// the 3 suggestions replace the current suggestions, so the
    /// keyboard shows the answer's suggestions too.
    func askAboutChat() async {
        errorMessage = nil
        askAnswer = nil
        guard let ctx = context else { errorMessage = APIError.noContext.localizedDescription; return }
        let question = askQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { errorMessage = "Type a question about this chat first."; return }
        isAsking = true
        defer { isAsking = false }
        do {
            let result = try await api.askAboutChat(context: ctx, question: question)
            askAnswer = result.answer
            suggestions = result.suggestions
            lastRelaySyncFailed = !(await api.storeScanToRelay(context: ctx, suggestions: result.suggestions))
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    /// Guide mode (new in 1.12.0): after a scan, get a send/wait
    /// decision + reason + action + 3 drafts, based only on this chat.
    /// Safety rule: SEND drafts replace the current suggestions and
    /// are published to the keyboard, like Ask. WAIT drafts stay in
    /// the app only as "for later" ideas — they are NOT published to
    /// the keyboard, so tapping the keyboard cannot accidentally
    /// send a message the guide said to wait on.
    func guideChat() async {
        errorMessage = nil
        guide = nil
        guard let ctx = context else { errorMessage = APIError.noContext.localizedDescription; return }
        isGuiding = true
        defer { isGuiding = false }
        do {
            let result = try await api.guideChat(context: ctx)
            guide = result
            if result.isSend {
                let s = ReplySuggestions(suggestions: result.drafts, basedOnMessageCount: ctx.messages.count)
                suggestions = s
                lastRelaySyncFailed = !(await api.storeScanToRelay(context: ctx, suggestions: s))
            }
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func generateReplies() async {
        errorMessage = nil
        guard let ctx = context else { errorMessage = APIError.noContext.localizedDescription; return }
        do {
            analysis = try await api.analyze(context: ctx)
            let s = try await api.generateReplies(context: ctx)
            suggestions = s
            // Publish to the relay so the keyboard shows these same suggestions.
            // AWAITED, not fire-and-forget (2026-10-27 fix): the old
            // Task could be killed when the user switched straight back
            // to the chat app, leaving the relay — and the keyboard —
            // on the previous chat's replies. The backend is already
            // awake from the generate call, so this post is fast.
            lastRelaySyncFailed = !(await api.storeScanToRelay(context: ctx, suggestions: s))
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    @Published var scanFetchMessage: String?
    private var didAutoFetchScan = false

    /// Once per app launch, if no conversation is loaded yet, quietly pull any
    /// broadcast-scan results from the server so the user doesn't have to
    /// remember the Fetch button after scanning.
    func autoFetchScanResultsIfNeeded() async {
        guard !didAutoFetchScan, context == nil else { return }
        didAutoFetchScan = true
        _ = try? await api.fetchScanLatest()
        refreshFromStore()
    }

    /// Pull broadcast-scan results from the backend relay (see APIClient).
    func fetchScanResults() async {
        scanFetchMessage = nil
        do {
            let found = try await api.fetchScanLatest()
            refreshFromStore()
            scanFetchMessage = found
                ? "Scan results loaded from your last broadcast scan."
                : "No scan results found yet — start a broadcast scan, scroll the chat, stop the scan, then fetch again."
        } catch {
            scanFetchMessage = "Could not fetch scan results: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    func deleteAllData() {
        store.deleteAllConversationData()
        Task { await api.deleteScanLatest() }
        context = nil; suggestions = nil; analysis = nil; guide = nil; scanState = .idle
    }
}
