import Foundation
import Combine

/// Keeps every session on the phone, as one JSON file in the app's Documents folder.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [BlueySession] = []  // newest first
    @Published private(set) var currentID: UUID?

    private let fileURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sessions.json")
    private var saveWork: DispatchWorkItem?

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([BlueySession].self, from: data) {
            // A session left open by a crash or force-quit is closed at its last line.
            sessions = saved.map { session in
                var session = session
                if session.ended == nil { session.ended = session.entries.last?.time ?? session.started }
                return session
            }
        }
    }

    var current: BlueySession? { sessions.first { $0.id == currentID } }

    func start(id: UUID = UUID(), started: Date = Date()) {
        end()
        let session = BlueySession(id: id, started: started)
        sessions.insert(session, at: 0)
        currentID = session.id
        save()
    }

    func end() {
        guard let id = currentID, let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        currentID = nil
        let session = sessions[index]
        if session.entries.allSatisfy({ $0.text.isEmpty }) && (session.pending?.isEmpty ?? true)
            && Date().timeIntervalSince(session.started) < 20 {
            sessions.remove(at: index)  // a few seconds with nothing said: don't keep it
        } else {
            sessions[index].ended = Date()
            sessions[index].entries.removeAll { $0.text.isEmpty }
            dirty.insert(id)
            scheduleSync()
        }
        save()
    }

    /// Holds a spot for something you said, in the order you said it. The words arrive a moment later.
    func placeholder(itemID: String, asked: Bool) {
        update { session in
            guard !session.entries.contains(where: { $0.itemID == itemID }) else { return }
            session.entries.append(TranscriptEntry(kind: asked ? .asked : .heard, text: "", time: Date(), itemID: itemID))
        }
    }

    func heard(itemID: String, text: String, asked: Bool) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        update { session in
            if let i = session.entries.firstIndex(where: { $0.itemID == itemID }) {
                session.entries[i].text = text
                if asked { session.entries[i].kind = .asked }
            } else if !text.isEmpty {
                session.entries.append(TranscriptEntry(kind: asked ? .asked : .heard, text: text, time: Date(), itemID: itemID))
            }
        }
    }

    func reply(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        update { $0.entries.append(TranscriptEntry(kind: .reply, text: text, time: Date())) }
    }

    func report(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        update { $0.entries.append(TranscriptEntry(kind: .report, text: text, time: Date())) }
    }

    /// A single source of truth, independent of the chosen conversation provider.
    func localSpeech(session id: UUID, segment: SpeechSegment, started: Date) {
        update(id) { session in
            guard !session.entries.contains(where: { $0.id == segment.id }) else { return }
            session.entries.append(TranscriptEntry(id: segment.id, kind: segment.questionID == nil ? .transcript : .asked,
                text: segment.text, time: started.addingTimeInterval(segment.start), source: "apple",
                questionID: segment.questionID, audioStart: segment.start, audioEnd: segment.end))
        }
    }

    // MARK: Audio archival and local recovery of older recordings

    func addPending(_ session: UUID, index: Int, started: Date, needsRecovery: Bool = false) {
        update(session) { s in
            var list = s.pending ?? []
            if !list.contains(where: { $0.index == index }) {
                list.append(PendingChunk(index: index, started: started, purpose: needsRecovery ? "localRecovery" : "archive"))
            }
            s.pending = list
        }
    }

    func archived(_ session: UUID, index: Int) {
        update(session) { s in
            if let i = s.pending?.firstIndex(where: { $0.index == index }) {
                if s.pending?[i].purpose == "archive" { s.pending?.remove(at: i) }
                else { s.pending?[i].archived = true }
            }
        }
        save()  // Persist the archive acknowledgement before the caller removes the phone's file.
    }

    func needsLocalRecovery(_ session: UUID, index: Int) -> Bool {
        sessions.first { $0.id == session }?.pending?.contains { $0.index == index && $0.purpose != "archive" } ?? false
    }

    func recoveryFailed(_ session: UUID, message: String) {
        update(session) { $0.recoveryError = message }
    }

    /// Import old pending recordings using the same local recognizer, without inventing speakers.
    func recovered(_ session: UUID, index: Int, started: Date, spans: [RecognizedSpeech]) {
        update(session) { s in
            guard let i = s.pending?.firstIndex(where: { $0.index == index && $0.purpose != "archive" }) else { return }
            let recoveringLiveCapture = s.pending?[i].purpose == "localRecovery"
            if s.pending?[i].archived == true { s.pending?.remove(at: i) }
            else { s.pending?[i].purpose = "archive" }
            s.recoveryError = nil
            let offset = started.timeIntervalSince(s.started)
            let recordedThrough = recoveringLiveCapture
                ? (s.entries.filter { $0.source == "apple" }.compactMap(\.audioEnd).max() ?? -.infinity)
                : -.infinity
            var groups: [(start: Double, end: Double, text: String)] = []
            for span in spans where offset + span.end > recordedThrough {
                if let last = groups.indices.last, span.start - groups[last].end < 2, groups[last].text.count < 300 {
                    groups[last].text += span.text
                    groups[last].end = span.end
                } else { groups.append((span.start, span.end, span.text)) }
            }
            for group in groups {
                let text = group.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                s.entries.append(TranscriptEntry(kind: .transcript, text: text, time: started.addingTimeInterval(group.start),
                    source: "apple", audioStart: offset + group.start, audioEnd: offset + group.end))
            }
            s.entries.sort { $0.time < $1.time }
        }
        save()
    }

    func syncFailed(_ ids: [UUID], retry: Bool = false) {
        dirty.formUnion(ids)
        if retry { scheduleSync() }
    }

    func setNotesPath(_ session: UUID, _ path: String) {
        guard let i = sessions.firstIndex(where: { $0.id == session }), sessions[i].notesPath != path else { return }
        sessions[i].notesPath = path
        scheduleSave(sync: false)
    }

    /// Recent words from this session, for a fresh connection to pick up where the last one left off.
    func recentText(limit: Int = 6000) -> String? {
        guard let current else { return nil }
        let text = current.displayEntries
            .filter { $0.kind != .report }
            .map { ($0.kind == .reply ? "Bluey: " : "") + $0.text }
            .joined(separator: "\n")
        return text.isEmpty ? nil : String(text.suffix(limit))
    }

    // MARK: Sync to the Mac (it writes the meeting-notes files)

    /// Called with sessions that changed, a few seconds after the changes settle.
    var onSync: (([BlueySession]) -> Void)?
    private var dirty: Set<UUID> = []
    private var syncWork: DispatchWorkItem?

    /// Re-sends recent sessions (after the phone reconnects to the Mac).
    func resyncRecent() {
        let cutoff = Date().addingTimeInterval(-3 * 86_400)
        dirty.formUnion(sessions.filter { $0.started > cutoff }.map(\.id))
        scheduleSync()
    }

    private func scheduleSync() {
        guard syncWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.syncWork = nil
            let changed = self.sessions.filter { self.dirty.contains($0.id) }
            self.dirty = []
            if !changed.isEmpty { self.onSync?(changed) }
        }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    func delete(_ id: UUID) {
        if id == currentID { currentID = nil }
        sessions.removeAll { $0.id == id }
        save()
    }

    private func update(_ change: (inout BlueySession) -> Void) {
        guard let id = currentID else { return }
        update(id, change)
    }

    private func update(_ id: UUID, _ change: (inout BlueySession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[index])
        dirty.insert(id)
        scheduleSync()
        scheduleSave()
    }

    private func scheduleSave(sync: Bool = false) {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func save() {
        saveWork?.cancel()
        saveWork = nil
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
