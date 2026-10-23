import UIKit

/// Custom keyboard: native-style QWERTY (UIKit for exact key geometry and
/// reliable text-document proxy behaviour), AI suggestion bar replacing the
/// predictive bar, dark/light aware.
///
/// Invariants:
/// - Suggestions come ONLY from SharedStore (i.e. from a real scanned context
///   + backend). No context -> the bar shows Scan / Refresh controls and an
///   honest "No scanned chat yet" label, never invented text.
/// - Tapping a suggestion inserts it via textDocumentProxy. Nothing in this
///   file ever triggers a return/send action on the host app's behalf.
final class KeyboardViewController: UIInputViewController {

    private var shifted = false
    private var capsLock = false
    private var showingSymbols = false
    private var suggestionButtons: [UIButton] = []
    private var rowsStack = UIStackView()
    private var suggestionLabel = UILabel()
    private let store = SharedStore.shared

    private let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let symbolRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        reloadSuggestions()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSuggestions()
        if store?.loadSuggestions() == nil { fetchScanFromServer() }
    }
    override func textDidChange(_ textInput: UITextInput?) { super.textDidChange(textInput); updateShiftForSentence() }

    // MARK: Layout
    private func buildLayout() {
        view.backgroundColor = .systemBackground
        let root = UIStackView(); root.axis = .vertical; root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            view.heightAnchor.constraint(equalToConstant: 264)
        ])

        // Suggestion bar
        let bar = UIStackView(); bar.axis = .horizontal; bar.distribution = .fillEqually; bar.spacing = 6
        for i in 0..<3 {
            let b = UIButton(type: .system)
            b.titleLabel?.numberOfLines = 2; b.titleLabel?.font = .systemFont(ofSize: 13)
            b.backgroundColor = .secondarySystemBackground; b.layer.cornerRadius = 8
            b.tag = i; b.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            suggestionButtons.append(b); bar.addArrangedSubview(b)
        }
        root.addArrangedSubview(bar)
        suggestionLabel.font = .systemFont(ofSize: 12); suggestionLabel.textColor = .secondaryLabel
        suggestionLabel.textAlignment = .center; root.addArrangedSubview(suggestionLabel)

        // Utility row: Scan, Refresh, Emoji, Globe
        let util = UIStackView(); util.axis = .horizontal; util.distribution = .fillEqually; util.spacing = 6
        util.addArrangedSubview(makeKey("Scan Chat", action: #selector(scanTapped), font: 12))
        util.addArrangedSubview(makeKey("↻ Refresh", action: #selector(refreshTapped), font: 12))
        util.addArrangedSubview(makeKey("😊", action: #selector(emojiTapped), font: 16))
        let globe = makeKey("🌐", action: nil, font: 16)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        util.addArrangedSubview(globe)
        root.addArrangedSubview(util)

        rowsStack.axis = .vertical; rowsStack.spacing = 6; rowsStack.distribution = .fillEqually
        root.addArrangedSubview(rowsStack)
        buildKeyRows()
    }

    private func buildKeyRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = showingSymbols ? symbolRows : letterRows
        for (rowIndex, row) in rows.enumerated() {
            let stack = UIStackView(); stack.axis = .horizontal; stack.distribution = .fillEqually; stack.spacing = 5
            if rowIndex == 2 && !showingSymbols {
                stack.addArrangedSubview(makeKey(shifted || capsLock ? "⇪" : "⇧", action: #selector(shiftTapped), font: 16))
            }
            if rowIndex == 2 && showingSymbols {
                stack.addArrangedSubview(makeKey("ABC", action: #selector(toggleSymbols), font: 13))
            }
            for ch in row {
                let title = (shifted || capsLock) && !showingSymbols ? String(ch).uppercased() : String(ch)
                let b = makeKey(title, action: #selector(charTapped(_:)), font: 16)
                b.accessibilityLabel = String(ch)
                stack.addArrangedSubview(b)
            }
            if rowIndex == 2 {
                stack.addArrangedSubview(makeKey("⌫", action: #selector(backspaceTapped), font: 16))
            }
            rowsStack.addArrangedSubview(stack)
        }
        // Bottom row: 123/ABC, space, return
        let bottom = UIStackView(); bottom.axis = .horizontal; bottom.spacing = 5
        bottom.addArrangedSubview(makeKey(showingSymbols ? "ABC" : "123", action: #selector(toggleSymbols), font: 13))
        let space = makeKey("space", action: #selector(spaceTapped), font: 13)
        bottom.addArrangedSubview(space)
        bottom.addArrangedSubview(makeKey("return", action: #selector(returnTapped), font: 13))
        // Wider space bar
        space.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: 0.5).isActive = true
        rowsStack.addArrangedSubview(bottom)
    }

    private func makeKey(_ title: String, action: Selector?, font: CGFloat) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal); b.titleLabel?.font = .systemFont(ofSize: font)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .secondarySystemBackground; b.layer.cornerRadius = 5
        if let action { b.addTarget(self, action: action, for: .touchUpInside) }
        return b
    }

    // MARK: Suggestions
    private var lastServerFetch = Date.distantPast
    private var serverFetchInFlight = false

    @objc private func refreshTapped() {
        reloadSuggestions()
        if store?.loadSuggestions() == nil { fetchScanFromServer() }
    }

    /// Server relay: the broadcast extension uploads scanned text to the
    /// backend, which holds context + suggestions at /scan-latest. Fetching
    /// them here makes scan suggestions appear in the keyboard even when iOS
    /// blocks the App Group channel (free-signed installs). Full Access is
    /// required for the request; without it this is a no-op.
    private struct ScanLatestDTO: Codable {
        struct Msg: Codable { let text: String; let sender: String; let confidence: Double }
        let messages: [Msg]; let language: String; let suggestions: [String]
        let based_on_message_count: Int; let updated_at: Double
    }

    func fetchScanFromServer() {
        guard hasFullAccess, let store, !serverFetchInFlight,
              Date().timeIntervalSince(lastServerFetch) >= 10 else { return }
        guard let base = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String,
              let url = URL(string: base)?.appendingPathComponent("scan-latest"),
              let key = Bundle.main.object(forInfoDictionaryKey: "AppAPIKey") as? String,
              !key.isEmpty else { return }
        serverFetchInFlight = true
        lastServerFetch = Date()
        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            defer { DispatchQueue.main.async { self?.serverFetchInFlight = false } }
            guard let self, let data,
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let r = try? JSONDecoder().decode(ScanLatestDTO.self, from: data) else { return }
            let when = Date(timeIntervalSince1970: r.updated_at)
            let messages = r.messages.enumerated().map { index, m in
                ChatMessage(text: m.text, sender: Sender(rawValue: m.sender) ?? .unknown,
                            confidence: m.confidence, orderIndex: index, capturedAt: when)
            }
            let ctx = ConversationContext(messages: messages,
                                          language: DetectedLanguage(rawValue: r.language) ?? .unknown,
                                          updatedAt: when)
            let clean = r.suggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard clean.count == 3 else { return }
            store.saveContext(ctx)
            store.saveSuggestions(ReplySuggestions(suggestions: clean, generatedAt: when,
                                                   basedOnMessageCount: r.based_on_message_count))
            DispatchQueue.main.async { self.reloadSuggestions() }
        }.resume()
    }

    func reloadSuggestions() {
        guard hasFullAccess, let store, let s = store.loadSuggestions() else {
            suggestionButtons.forEach { $0.setTitle("", for: .normal); $0.isEnabled = false }
            suggestionLabel.text = hasFullAccess
                ? "No scanned chat yet — tap Scan Chat"
                : "Enable Full Access for AI suggestions (typing still works)"
            return
        }
        suggestionLabel.text = ""
        for (i, b) in suggestionButtons.enumerated() {
            b.setTitle(s.suggestions[i], for: .normal); b.isEnabled = true
        }
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let store, let s = store.loadSuggestions(),
              suggestionButtons.indices.contains(sender.tag) else { return }
        let text = s.suggestions[sender.tag]
        // Insert a separating space if the field doesn't already end with one,
        // and a trailing space so the user can keep typing. NEVER send.
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        textDocumentProxy.insertText((before.isEmpty || before.hasSuffix(" ") || before.hasSuffix("\n")) ? text : " " + text)
        textDocumentProxy.insertText(" ")
    }

    // MARK: Actions
    @objc private func charTapped(_ sender: UIButton) {
        guard let ch = sender.accessibilityLabel ?? sender.title(for: .normal) else { return }
        let out = (shifted || capsLock) && !showingSymbols ? ch.uppercased() : ch
        textDocumentProxy.insertText(out)
        if shifted && !capsLock { shifted = false; buildKeyRows() }
    }
    @objc private func backspaceTapped() { textDocumentProxy.deleteBackward() }
    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
        if shifted && !capsLock { shifted = false; buildKeyRows() }
    }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") } // newline only; host decides what return means
    @objc private func shiftTapped() {
        // Double-tap within the same state approximates caps lock.
        if shifted && !capsLock { capsLock = true; shifted = true }
        else if capsLock { capsLock = false; shifted = false }
        else { shifted = true }
        buildKeyRows()
    }
    @objc private func toggleSymbols() { showingSymbols.toggle(); buildKeyRows() }
    @objc private func emojiTapped() {
        // iOS gives extensions no emoji-picker API; insert nothing fabricated.
        // Switch to the system emoji keyboard instead — the honest native path.
        advanceToNextInputMode()
    }
    @objc private func scanTapped() {
        // Extensions cannot start ReplayKit or open URLs directly in all contexts;
        // with Full Access we open the host app, which owns the permitted flow.
        let url = URL(string: "relationshipai://scan")!
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication { app.open(url); return }
            responder = r.next
        }
        // Fallback selector-based open (used by keyboard extensions historically).
        let sel = NSSelectorFromString("openURL:")
        if let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication, app.responds(to: sel) {
            _ = app.perform(sel, with: url)
        }
    }
    private func updateShiftForSentence() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        if before.isEmpty || before.hasSuffix(". ") || before.hasSuffix("? ") || before.hasSuffix("! ") || before.hasSuffix("\n") {
            if !shifted && !capsLock { shifted = true; buildKeyRows() }
        }
    }
}
