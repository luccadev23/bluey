import XCTest
@testable import GooglyShared

final class SpeechTranscriptTests: XCTestCase {
    func testLateResultsUseSpeechTimeRatherThanCallbackTime() {
        var transcript = SpeechTranscript()
        let id = transcript.beginQuestion(at: 10)
        transcript.endQuestion(id, at: 12)
        transcript.append(start: 8, end: 9, text: "background")
        transcript.append(start: 10.2, end: 11.9, text: "where is my mouse")
        transcript.append(start: 12.2, end: 13, text: "later conversation")
        XCTAssertEqual(transcript.question(id)?.text, "where is my mouse")
        XCTAssertEqual(transcript.question(id)?.context, "background")
        XCTAssertNil(transcript.segments.last?.questionID)
    }

    func testAdjacentQuestionsNeverShareWords() {
        var transcript = SpeechTranscript()
        let first = transcript.beginQuestion(at: 1)
        transcript.endQuestion(first, at: 2)
        let second = transcript.beginQuestion(at: 2)
        transcript.endQuestion(second, at: 3)
        transcript.append(start: 1.2, end: 1.9, text: "first")
        transcript.append(start: 2, end: 2.8, text: "second")
        XCTAssertEqual(transcript.question(first)?.text, "first")
        XCTAssertEqual(transcript.question(second)?.text, "second")
        XCTAssertEqual(transcript.question(second)?.context, "")
    }

    func testSilentGestureDoesNotProduceAQuestion() {
        var transcript = SpeechTranscript()
        let id = transcript.beginQuestion(at: 1)
        transcript.endQuestion(id, at: 2)
        transcript.append(start: 1, end: 1.8, text: " \n ")
        XCTAssertNil(transcript.question(id))
    }

    func testStableIDsPreventDuplicateTranscriptOnRecovery() {
        var transcript = SpeechTranscript()
        let id = UUID()
        XCTAssertNotNil(transcript.append(id: id, start: 0, end: 1, text: "hello"))
        XCTAssertNil(transcript.append(id: id, start: 0, end: 1, text: "hello"))
        XCTAssertEqual(transcript.segments.count, 1)
    }

    func testOnlyNewBackgroundIsSentAndContextIsBounded() {
        var transcript = SpeechTranscript()
        transcript.append(start: 0, end: 1, text: "already sent")
        transcript.append(start: 3, end: 4, text: "new background")
        let id = transcript.beginQuestion(at: 5)
        transcript.endQuestion(id, at: 6)
        transcript.append(start: 5, end: 6, text: "question")
        XCTAssertEqual(transcript.question(id, contextAfter: 2)?.context, "new background")
        XCTAssertEqual(transcript.question(id, contextAfter: 2, contextLimit: 4)?.context, "ound")
    }

    func testOldInMemoryContextCanBeTrimmedWithoutChangingCurrentQuestion() {
        var transcript = SpeechTranscript()
        transcript.append(start: 0, end: 1, text: "old")
        let id = transcript.beginQuestion(at: 600)
        transcript.endQuestion(id, at: 602)
        transcript.append(start: 600, end: 602, text: "current")
        transcript.trim(before: 500)
        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.question(id)?.text, "current")
    }
}
