import Foundation
import GooglyShared

/// Archives recordings and writes the canonical transcript produced locally on the iPhone.
enum MeetingNotes {
    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bluey Notes", isDirectory: true)
    }

    // MARK: Folders

    /// The session's folder, made the first time it's needed.
    static func folder(session: String, started: Date) -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        writeReadmeIfNeeded()
        let tag = String(session.prefix(8)).lowercased()
        if let existing = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.hasSuffix(tag) }) {
            return existing
        }
        let name = DateFormatter.folderName.string(from: started) + " " + tag
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        return url
    }

    private static func writeReadmeIfNeeded() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # Bluey Notes

        Meeting notes recorded by Riley's Bluey app (the blueberry on the iPhone). One folder per listening \
        session, named by start time.

        In each session folder:
        - `notes.md`: the local transcript with timestamps, plus Riley's questions to Bluey, \
        Bluey's replies and any research reports, in time order. Start here.
        - `session.json`: the same data, structured.
        - `audio/`: the raw recording, as five-minute AAC chunks.

        New sessions use Apple speech recognition on the iPhone and have no speaker attribution. \
        Older sessions may retain speaker letters and preliminary lines from their original recognizer.
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Archival only: this operation never invokes a speech or conversation API.
    static func archive(audio: Data, session: String, index: Int, sessionStarted: Date) throws -> URL {
        guard UUID(uuidString: session) != nil, index > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        let folder = folder(session: session, started: sessionStarted)
        let audioURL = folder.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        try audio.write(to: audioURL.appendingPathComponent(String(format: "chunk-%03d.m4a", index)), options: .atomic)
        return folder
    }

    // MARK: Notes files

    /// Writes session.json and notes.md from the phone's copy of the session. Returns the folder.
    @discardableResult
    static func write(session json: [String: Any]) -> URL? {
        guard let id = json["id"] as? String, UUID(uuidString: id) != nil,
              let startedAt = json["started"] as? Double else { return nil }
        let started = Date(timeIntervalSince1970: startedAt)
        let folder = folder(session: id, started: started)
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("session.json"), options: .atomic)
            try markdown(json, started: started).write(to: folder.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        } catch { return nil }
        return folder
    }

    private static func markdown(_ json: [String: Any], started: Date) -> String {
        let ended = (json["ended"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let entries = json["entries"] as? [[String: Any]] ?? []
        let pending = json["legacyPending"] as? Int ?? 0
        let day = DateFormatter()
        day.dateStyle = .full
        day.timeStyle = .short
        let clock = DateFormatter()
        clock.dateFormat = "h:mm:ss a"

        var out = ["# Bluey session: \(day.string(from: started))", ""]
        if let ended {
            let minutes = Int(ended.timeIntervalSince(started) / 60)
            out.append("Ended \(clock.string(from: ended)) (\(minutes / 60)h \(minutes % 60)m).")
        } else {
            out.append("Still recording.")
        }
        if pending > 0 { out.append("\(pending) older recording chunk(s) await local recovery. No cloud transcription will be used.") }
        let questions = entries.filter { $0["kind"] as? String == "asked" }
        let asked = Set(questions.compactMap { $0["questionID"] as? String }).count + questions.filter { $0["questionID"] == nil }.count
        if asked > 0 { out.append("Riley asked Bluey \(asked) question(s); they're marked inline below.") }
        out += ["", "## Transcript", ""]

        for entry in entries {
            let text = (entry["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let time = (entry["time"] as? Double).map { clock.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            switch entry["kind"] as? String {
            case "transcript":
                if let speaker = entry["speaker"] as? String { out.append("**[\(time)] Speaker \(speaker):** \(text)") }
                else { out.append("[\(time)] \(text)") }
            case "heard":
                out.append("[\(time)] (live) \(text)")
            case "asked":
                out.append("> **[\(time)] Riley asked Bluey:** \(text)")
            case "reply":
                out.append("> **Bluey:** \(text)")
            case "report":
                let quoted = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
                out.append("> **Research report:**\n" + quoted)
            default:
                out.append("[\(time)] \(text)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let folderName: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()
}
