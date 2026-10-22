import XCTest
@testable import RelationshipAIKeyboard

final class ChatParsingTests: XCTestCase {
    private func obs(_ text: String, x: Double, y: Double, conf: Float = 0.9) -> OCRObservation {
        OCRObservation(text: text, x: x, y: y, width: 0.3, height: 0.03, confidence: conf, capturedAt: Date())
    }

    func testSenderBySide() {
        XCTAssertEqual(ChatParser.senderFor(midX: 0.2), .other)
        XCTAssertEqual(ChatParser.senderFor(midX: 0.8), .me)
        XCTAssertEqual(ChatParser.senderFor(midX: 0.5), .unknown)
    }

    func testDeduplicatesAcrossFrames() {
        let f1 = ChatParser.Frame(observations: [obs("hello how are you", x: 0.05, y: 0.7)], capturedAt: Date(), sequence: 0)
        let f2 = ChatParser.Frame(observations: [obs("Hello how are you", x: 0.05, y: 0.5)], capturedAt: Date().addingTimeInterval(1), sequence: 1)
        let ctx = ChatParser.parse(frames: [f1, f2])
        XCTAssertEqual(ctx.messages.count, 1)
    }

    func testEmptyFramesGiveEmptyContext() {
        XCTAssertTrue(ChatParser.parse(frames: []).messages.isEmpty)
    }

    func testOrderingTopToBottom() {
        let f = ChatParser.Frame(observations: [obs("second line", x: 0.05, y: 0.4), obs("first line", x: 0.05, y: 0.7)], capturedAt: Date(), sequence: 0)
        let ctx = ChatParser.parse(frames: [f])
        XCTAssertEqual(ctx.messages.map(\.text), ["first line", "second line"])
    }
}

final class LanguageDetectionTests: XCTestCase {
    func testRomanTelugu() {
        XCTAssertEqual(LanguageDetector.detect(texts: ["nenu baaga unna, nuvvu ela unnav"]), .romanTelugu)
    }
    func testRomanUrdu() {
        XCTAssertEqual(LanguageDetector.detect(texts: ["tum kahan ho, kya kar rahe ho"]), .romanUrdu)
    }
    func testEnglish() {
        XCTAssertEqual(LanguageDetector.detect(texts: ["what are you doing this weekend"]), .english)
    }
    func testUnknown() {
        XCTAssertEqual(LanguageDetector.detect(texts: ["zxqw plmn"]), .unknown)
    }
}

final class SharedStoreTests: XCTestCase {
    func testNoContextMeansNoSuggestions() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = SharedStore(defaults: suite)
        store.saveSuggestions(ReplySuggestions(suggestions: ["a", "b", "c"], basedOnMessageCount: 1))
        // Suggestions must not surface without a real context behind them.
        XCTAssertNil(store.loadSuggestions())
    }
    func testDeleteRemovesEverything() {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = SharedStore(defaults: suite)
        store.saveContext(ConversationContext(messages: [
            ChatMessage(text: "hi", sender: .other, confidence: 0.9, orderIndex: 0, capturedAt: Date())
        ], language: .english))
        store.deleteAllConversationData()
        XCTAssertNil(store.loadContext())
        XCTAssertNil(store.loadSuggestions())
    }
}
