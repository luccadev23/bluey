import XCTest
@testable import GooglyShared

final class SessionMigrationTests: XCTestCase {
    func testOldSessionsAndPendingFilesRemainDecodable() throws {
        let id = UUID().uuidString
        let entry = UUID().uuidString
        let json = """
        {"id":"\(id)","started":0,"entries":[{"id":"\(entry)","kind":"transcript","text":"older transcript","time":1,"speaker":"A"}],"pending":[{"index":1,"started":0}]}
        """
        let session = try JSONDecoder().decode(BlueySession.self, from: Data(json.utf8))
        XCTAssertEqual(session.entries.first?.speaker, "A")
        XCTAssertNil(session.entries.first?.source)
        XCTAssertEqual(session.transcribing, 1)
        XCTAssertEqual(session.archiving, 0)
        XCTAssertNil(session.pending?.first?.purpose)
    }

    func testLocalQuestionSegmentsCountAsOneQuestionAndRemainVisible() {
        let question = UUID()
        var session = BlueySession(started: Date())
        session.entries = [
            TranscriptEntry(kind: .asked, text: "first part", time: Date(timeIntervalSince1970: 1), source: "apple", questionID: question),
            TranscriptEntry(kind: .asked, text: "second part", time: Date(timeIntervalSince1970: 2), source: "apple", questionID: question),
            TranscriptEntry(kind: .transcript, text: "background", time: Date(timeIntervalSince1970: 3), source: "apple")
        ]
        XCTAssertEqual(session.questionCount, 1)
        XCTAssertEqual(session.displayEntries.count, 3)
        XCTAssertFalse(session.exportText.contains("Speaker ?"))
    }

    func testArchivalAndLegacyRecoveryAreDifferentQueues() {
        var session = BlueySession(started: Date())
        session.pending = [PendingChunk(index: 1, started: Date()), PendingChunk(index: 2, started: Date(), purpose: "archive")]
        XCTAssertEqual(session.transcribing, 1)
        XCTAssertEqual(session.archiving, 1)
        XCTAssertEqual(try JSONDecoder().decode(BlueySession.self, from: JSONEncoder().encode(session)), session)
    }
}
