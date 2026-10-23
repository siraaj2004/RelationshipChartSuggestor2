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
@MainActor
final class AppModel: ObservableObject {
    @Published var context: ConversationContext?
    @Published var suggestions: ReplySuggestions?
    @Published var analysis: AnalysisResult?
    @Published var scanState: ScanState = .idle
    @Published var errorMessage: String?
    @Published var showScanner = false

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
        refreshFromStore()
    }

    func generateReplies() async {
        errorMessage = nil
        guard let ctx = context else { errorMessage = APIError.noContext.localizedDescription; return }
        do {
            analysis = try await api.analyze(context: ctx)
            suggestions = try await api.generateReplies(context: ctx)
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    func deleteAllData() {
        store.deleteAllConversationData()
        context = nil; suggestions = nil; analysis = nil; scanState = .idle
    }
}
