import Foundation

public enum Sender: String, Codable, Equatable {
    case me, other, unknown
}

public enum DetectedLanguage: String, Codable, Equatable, CaseIterable {
    case english
    case romanTelugu = "roman_telugu"
    case romanUrdu = "roman_urdu"
    case mixedTeluguEnglish = "mixed_telugu_english"
    case mixedUrduEnglish = "mixed_urdu_english"
    case unknown
}

public enum ToneLabel: String, Codable, Equatable {
    case casual, friendly, romantic, serious, sensitive, humorous, unknown
}

/// One OCR-recognised line/block before parsing.
public struct OCRObservation: Codable, Equatable {
    public var text: String
    /// Normalised Vision bounding box (origin bottom-left, 0...1).
    public var x: Double; public var y: Double
    public var width: Double; public var height: Double
    public var confidence: Float
    public var capturedAt: Date
    public init(text: String, x: Double, y: Double, width: Double, height: Double, confidence: Float, capturedAt: Date = Date()) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
        self.confidence = confidence; self.capturedAt = capturedAt
    }
    public var midX: Double { x + width / 2 }
}

public struct ChatMessage: Codable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var sender: Sender
    /// 0...1. Low when OCR is weak, bubble side is ambiguous, or ordering is inferred.
    public var confidence: Double
    public var orderIndex: Int
    public var capturedAt: Date
    public var uncertaintyNotes: [String]
    public init(id: UUID = UUID(), text: String, sender: Sender, confidence: Double, orderIndex: Int, capturedAt: Date, uncertaintyNotes: [String] = []) {
        self.id = id; self.text = text; self.sender = sender; self.confidence = confidence
        self.orderIndex = orderIndex; self.capturedAt = capturedAt; self.uncertaintyNotes = uncertaintyNotes
    }
}

public struct ConversationContext: Codable, Equatable {
    public var messages: [ChatMessage]
    public var language: DetectedLanguage
    public var updatedAt: Date
    public var sourceAppHint: String?
    public init(messages: [ChatMessage], language: DetectedLanguage, updatedAt: Date = Date(), sourceAppHint: String? = nil) {
        self.messages = messages; self.language = language; self.updatedAt = updatedAt; self.sourceAppHint = sourceAppHint
    }
    public var isEmpty: Bool { messages.isEmpty }
    public var latestIncoming: ChatMessage? { messages.last(where: { $0.sender == .other }) ?? messages.last }
}

public struct AnalysisResult: Codable, Equatable {
    public var language: DetectedLanguage
    public var tone: ToneLabel
    public var topic: String
    public var latestIncomingText: String?
    public var summary: String
}

public struct ReplySuggestions: Codable, Equatable {
    /// Invariant enforced in init & in the keyboard: exactly 0 or 3 suggestions.
    /// 0 means "no real context / backend unavailable" — never invent filler.
    public var suggestions: [String]
    public var generatedAt: Date
    public var basedOnMessageCount: Int
    public init(suggestions: [String], generatedAt: Date = Date(), basedOnMessageCount: Int) {
        precondition(suggestions.isEmpty || suggestions.count == 3, "Must be 0 or 3 suggestions")
        self.suggestions = suggestions; self.generatedAt = generatedAt; self.basedOnMessageCount = basedOnMessageCount
    }
}

public enum ScanState: String, Codable, Equatable {
    case idle, awaitingConsent, broadcasting, processing, ready, failed, stopped
}

/// Hints the user gives about their own situation, used to tune suggestion
/// tone/direction. They are never conversation history and never a source of
/// invented facts — the backend prompt says so explicitly.
public struct SuggestionInputs: Codable, Equatable {
    /// How long the user has been chatting with this person. nil = not provided.
    public var daysChatting: Int?
    /// just_chatting | get_closer | keep_fun | restart_chat | say_sorry
    public var goal: String
    /// auto | sweet | funny | bold | caring
    public var tone: String
    /// Chat language preference (2026-10-27): auto = detect from the
    /// chat, otherwise this overrides detection entirely — the most
    /// reliable fix when detection keeps getting a short/chatty
    /// conversation wrong. Values are DetectedLanguage raw values,
    /// or "auto".
    public var preferredLanguage: String
    public init(daysChatting: Int? = nil, goal: String = "just_chatting", tone: String = "auto", preferredLanguage: String = "auto") {
        self.daysChatting = daysChatting; self.goal = goal; self.tone = tone; self.preferredLanguage = preferredLanguage
    }
    // Backward-compatible decoding: inputs saved before the language
    // preference existed have no preferredLanguage key — default it
    // to "auto" instead of dropping the whole saved inputs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daysChatting = try c.decodeIfPresent(Int.self, forKey: .daysChatting)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? "just_chatting"
        tone = try c.decodeIfPresent(String.self, forKey: .tone) ?? "auto"
        preferredLanguage = try c.decodeIfPresent(String.self, forKey: .preferredLanguage) ?? "auto"
    }
}
