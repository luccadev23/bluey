import XCTest
@testable import GooglyShared

final class TextConversationTests: XCTestCase {
    func testOpenAIAddsTextBeforeRequestingAResponse() throws {
        let adapter = OpenAITextConversation()
        let question = TextQuestion(text: "point here", context: "discussing the chart")
        let events = adapter.question(question)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["type"] as? String, "conversation.item.create")
        let item = try XCTUnwrap(events[0]["item"] as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "input_text")
        XCTAssertEqual(content.first?["text"] as? String, question.message)
        XCTAssertLessThanOrEqual((item["id"] as? String ?? "").count, 32)
        XCTAssertEqual(events[1]["type"] as? String, "response.create")
    }

    func testGeminiCompletesOnlyTheQuestionNotBackgroundRestoration() throws {
        let adapter = GeminiTextConversation()
        let restored = try XCTUnwrap(adapter.restoreContext("earlier words").first?["clientContent"] as? [String: Any])
        XCTAssertEqual(restored["turnComplete"] as? Bool, false)
        let request = try XCTUnwrap(adapter.question(TextQuestion(text: "question")).first?["clientContent"] as? [String: Any])
        XCTAssertEqual(request["turnComplete"] as? Bool, true)
    }

    func testNoProviderQuestionContainsMicrophoneAudio() throws {
        let adapters: [any TextConversationAdapter] = [OpenAITextConversation(), GeminiTextConversation()]
        for adapter in adapters {
            let payload = try JSONSerialization.data(withJSONObject: adapter.question(TextQuestion(text: "hello")))
            let json = String(decoding: payload, as: UTF8.self)
            for forbidden in ["input_audio", "activityStart", "activityEnd", "inputAudioTranscription", "audio/pcm", "realtimeInput"] {
                XCTAssertFalse(json.contains(forbidden), forbidden)
            }
        }
    }

    func testProviderInputTranscriptsCannotBecomeCanonicalSpeech() {
        XCTAssertTrue(OpenAITextConversation().events(from: ["type": "conversation.item.input_audio_transcription.completed", "transcript": "remote words"]).isEmpty)
        XCTAssertTrue(GeminiTextConversation().events(from: ["serverContent": ["inputTranscription": ["text": "remote words"]]]).isEmpty)
    }

    func testGeminiFalseTurnCompleteDoesNotFinishTheRequest() {
        XCTAssertTrue(GeminiTextConversation().events(from: ["serverContent": ["turnComplete": false]]).isEmpty)
    }

    func testOutputTranscriptStillSuppliesTheGeminiBubble() {
        let events = GeminiTextConversation().events(from: ["serverContent": ["outputTranscription": ["text": "Here it is."], "turnComplete": true]])
        XCTAssertEqual(events.count, 2)
        guard case .text("Here it is.") = events[0], case .completed = events[1] else { return XCTFail("Missing text/completion") }
    }

    func testOpenAIToolTurnStaysActiveUntilToolResultsAreSubmitted() throws {
        let events = OpenAITextConversation().events(from: ["type": "response.done", "response": ["output": [
            ["type": "function_call", "call_id": "call_1", "name": "look_at_screen", "arguments": "{}"]
        ]]])
        XCTAssertEqual(events.count, 1)
        guard case .tools(let calls) = events[0] else { return XCTFail("Expected tools without a completed turn") }
        XCTAssertEqual(calls.first?.name, "look_at_screen")
        let reply = ConversationToolResult(call: try XCTUnwrap(calls.first), text: "screen", image: nil)
        let wire = OpenAITextConversation().toolResults([reply])
        XCTAssertEqual(wire.first?["type"] as? String, "conversation.item.create")
        XCTAssertEqual(wire.last?["type"] as? String, "response.create")
    }
}
