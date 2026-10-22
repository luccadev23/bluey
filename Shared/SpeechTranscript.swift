import Foundation

public struct SpeechSegment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let start: Double
    public let end: Double
    public let text: String
    public let questionID: UUID?
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, questionID: UUID? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.questionID = questionID
    }
}

/// Temporal classification is shared by every provider and is independent of callback arrival time.
public struct SpeechQuestionRange: Sendable, Equatable {
    public let id: UUID
    public let start: Double
    public var end: Double
    public init(id: UUID = UUID(), start: Double, end: Double = .infinity) {
        self.id = id; self.start = start; self.end = end
    }
    public func contains(start: Double, end: Double) -> Bool {
        let midpoint = (start + end) / 2
        return midpoint >= self.start && midpoint < self.end
    }
}

public struct SpeechTranscript: Sendable {
    public private(set) var segments: [SpeechSegment] = []
    public private(set) var questions: [SpeechQuestionRange] = []
    public init() {}
    public mutating func beginQuestion(at time: Double) -> UUID {
        let range = SpeechQuestionRange(start: time)
        questions.append(range)
        return range.id
    }
    public mutating func endQuestion(_ id: UUID, at time: Double) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].end = max(time, questions[index].start)
    }
    @discardableResult
    public mutating func append(id: UUID = UUID(), start: Double, end: Double, text: String) -> SpeechSegment? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, end >= start, !segments.contains(where: { $0.id == id }) else { return nil }
        let question = questions.first { $0.contains(start: start, end: end) }
        let segment = SpeechSegment(id: id, start: start, end: end, text: clean, questionID: question?.id)
        segments.append(segment)
        return segment
    }
    public func question(_ id: UUID, contextAfter: Double = 0, contextLimit: Int = 6000) -> TextQuestion? {
        let text = segments.filter { $0.questionID == id }.map(\.text).joined(separator: " ")
        guard !text.isEmpty, let range = questions.first(where: { $0.id == id }) else { return nil }
        let context = segments.filter { $0.questionID == nil && $0.end <= range.start && $0.end > contextAfter }.map(\.text).joined(separator: "\n")
        return TextQuestion(id: id, text: text, context: String(context.suffix(contextLimit)))
    }
    /// The full transcript is persisted elsewhere; retain only recent recognition context in RAM.
    public mutating func trim(before time: Double) {
        segments.removeAll { $0.end < time }
        questions.removeAll { $0.end < time }
    }
}
