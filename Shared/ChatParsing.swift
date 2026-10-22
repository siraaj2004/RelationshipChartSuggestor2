import Foundation

/// Turns raw OCR observations from successive broadcast frames into a
/// deduplicated, chronologically ordered conversation.
///
/// Sender heuristic (documented, not hidden): in WhatsApp / Messenger / Telegram /
/// Instagram, incoming bubbles hug the left edge and outgoing bubbles the right.
///   midX < 0.42  -> .other
///   midX > 0.58  -> .me
///   in between   -> .unknown, confidence is penalised and a note is attached.
/// Lines in the same frame that are vertically close and on the same side are
/// merged into one bubble. Frames arrive in capture order; within a frame,
/// messages sort top-to-bottom (Vision y is bottom-origin, so larger y = higher).
public enum ChatParser {

    public struct Frame {
        public var observations: [OCRObservation]
        public var capturedAt: Date
        public var sequence: Int
        public init(observations: [OCRObservation], capturedAt: Date, sequence: Int) {
            self.observations = observations; self.capturedAt = capturedAt; self.sequence = sequence
        }
    }

    private static let noise: Set<String> = [
        "online", "typing...", "typing", "last seen today", "last seen yesterday",
        "today", "yesterday", "delivered", "seen", "read", "message", "type a message"
    ]

    public static func parse(frames: [Frame]) -> ConversationContext {
        var bubbles: [ChatMessage] = []
        for frame in frames.sorted(by: { $0.sequence < $1.sequence }) {
            bubbles.append(contentsOf: bubblesInFrame(frame))
        }
        let deduped = deduplicate(bubbles)
        let ordered = deduped.enumerated().map { idx, msg -> ChatMessage in
            var m = msg; m.orderIndex = idx; return m
        }
        let ctx = ConversationContext(messages: ordered, language: .unknown)
        return ConversationContext(messages: ordered,
                                     language: LanguageDetector.detect(context: ctx),
                                     updatedAt: Date())
    }

    static func bubblesInFrame(_ frame: Frame) -> [ChatMessage] {
        // Drop chrome: status bar (top 8%), composer (bottom 10%), known noise strings.
        let usable = frame.observations.filter { obs in
            obs.y > 0.10 && obs.y < 0.92 &&
            !noise.contains(obs.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) &&
            obs.text.trimmingCharacters(in: .whitespaces).count >= 2
        }
        // Top-to-bottom: Vision origin is bottom-left, so sort by descending y.
        let sorted = usable.sorted { $0.y > $1.y }
        var result: [ChatMessage] = []
        var previousObs: OCRObservation?
        for obs in sorted {
            let sender = senderFor(midX: obs.midX)
            // Merge only a tightly-spaced wrapped line of the SAME bubble: the gap
            // between the previous line's bottom and this line's top is tiny, and
            // the lines overlap horizontally. Distinct bubbles are separated by
            // visibly larger gaps, so they are never merged by this test.
            let isWrappedLine: Bool = {
                guard let prev = previousObs, sender == senderFor(midX: prev.midX) else { return false }
                let gap = prev.y - (obs.y + obs.height)
                let overlapsX = obs.x < prev.x + prev.width && prev.x < obs.x + obs.width
                return gap >= -0.005 && gap < 0.025 && overlapsX
            }()
            if var last = result.last, isWrappedLine {
                last.text += " " + obs.text
                last.confidence = min(last.confidence, Double(obs.confidence))
                result[result.count - 1] = last
            } else {
                var notes: [String] = []
                var conf = Double(obs.confidence)
                if sender == .unknown { conf *= 0.6; notes.append("Sender side ambiguous from OCR position") }
                if obs.confidence < 0.5 { notes.append("Low OCR confidence — wording may be inaccurate") }
                result.append(ChatMessage(text: obs.text.trimmingCharacters(in: .whitespacesAndNewlines), sender: sender,
                                            confidence: conf, orderIndex: result.count,
                                            capturedAt: frame.capturedAt, uncertaintyNotes: notes))
            }
            previousObs = obs
        }
        return result
    }

    static func senderFor(midX: Double) -> Sender {
        if midX < 0.42 { return .other }
        if midX > 0.58 { return .me }
        return .unknown
    }

    // MARK: Deduplication across overlapping frames
    /// Same message seen in consecutive scroll frames must appear once.
    /// Match = same sender AND (exact normalised text OR Jaccard token similarity >= 0.85).
    public static func deduplicate(_ messages: [ChatMessage]) -> [ChatMessage] {
        var kept: [ChatMessage] = []
        for msg in messages {
            if let dupIdx = kept.firstIndex(where: { $0.sender == msg.sender && isDuplicate($0.text, msg.text) }) {
                // Keep the higher-confidence reading.
                if msg.confidence > kept[dupIdx].confidence {
                    var better = msg
                    better.orderIndex = kept[dupIdx].orderIndex
                    kept[dupIdx] = better
                }
                continue
            }
            kept.append(msg)
        }
        return kept
    }

    static func isDuplicate(_ a: String, _ b: String) -> Bool {
        let na = normalise(a), nb = normalise(b)
        if na == nb { return true }
        let sa = Set(na.split(separator: " ").map(String.init))
        let sb = Set(nb.split(separator: " ").map(String.init))
        guard !sa.isEmpty, !sb.isEmpty else { return false }
        let jaccard = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        return jaccard >= 0.85
    }

    public static func normalise(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
