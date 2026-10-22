import Foundation

/// Canonical local speech, questions, replies and reports. Older sessions may retain remote speaker labels.
struct TranscriptEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case heard, asked, reply, report, transcript }

    var id = UUID()
    var kind: Kind
    var text: String
    var time: Date
    /// The Realtime conversation item this came from, so its transcript can be filled in when it arrives.
    var itemID: String?
    /// Who was talking, for proper transcript lines ("A", "B", … within each five-minute chunk).
    var speaker: String?
    /// Present only for the canonical local transcript. Missing fields keep older sessions decodable.
    var source: String?
    var questionID: UUID?
    var audioStart: Double?
    var audioEnd: Double?
}

/// A recording awaiting archival; a missing purpose denotes legacy audio awaiting local recovery.
struct PendingChunk: Codable, Equatable {
    var index: Int
    var started: Date
    var purpose: String?
    var archived: Bool?
}

/// Everything from one wake-to-sleep session.
struct BlueySession: Codable, Identifiable, Equatable {
    var id = UUID()
    var started: Date
    var ended: Date?
    var entries: [TranscriptEntry] = []
    /// Where the Mac saved this session's meeting notes.
    var notesPath: String?
    var pending: [PendingChunk]?
    var recoveryError: String?

    var questionCount: Int {
        let asked = entries.filter { $0.kind == .asked }
        return Set(asked.compactMap(\.questionID)).count + asked.filter { $0.questionID == nil }.count
    }

    /// A short line for the session list: the first thing you asked, or the first thing you said.
    var summary: String {
        let first = entries.first { $0.kind == .asked && !$0.text.isEmpty }
            ?? displayEntries.first { $0.kind == .transcript || $0.kind == .heard }
        return first?.text ?? "Nothing said yet"
    }

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    /// What to show: the proper transcript where it exists, the rough live lines after it, plus
    /// questions, replies and reports, in time order.
    var displayEntries: [TranscriptEntry] {
        let properUntil = entries.filter { $0.kind == .transcript }.map(\.time).max() ?? .distantPast
        return entries
            .filter { !$0.text.isEmpty && !($0.kind == .heard && $0.source != "apple" && $0.time <= properUntil) }
            .sorted { $0.time < $1.time }
    }

    var transcribing: Int { pending?.filter { $0.purpose != "archive" }.count ?? 0 }
    var archiving: Int { pending?.filter { $0.purpose == "archive" }.count ?? 0 }

    /// Plain text, for sharing.
    var exportText: String {
        let time = DateFormatter()
        time.dateFormat = "h:mm:ss a"
        var lines = ["Bluey session, \(started.formatted(date: .abbreviated, time: .shortened))", ""]
        for entry in displayEntries {
            let who: String
            switch entry.kind {
            case .transcript: who = entry.speaker.map { "Speaker " + $0 } ?? "Speech"
            case .heard: who = "You"
            case .asked: who = "You asked"
            case .reply: who = "Bluey"
            case .report: who = "Research"
            }
            lines.append("[\(time.string(from: entry.time))] \(who): \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }
}
