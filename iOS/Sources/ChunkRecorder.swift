import AVFoundation
import Foundation

/// Records everything the mic hears during a session to small AAC files, five minutes each,
/// so an all-day session never builds one giant file. Archival is independent of local recognition.
final class ChunkRecorder {
    struct Chunk {
        let sessionID: UUID
        let index: Int
        let url: URL
        /// When this chunk started, so its transcript lines get real times.
        let started: Date
        let needsLocalRecovery: Bool
    }

    static let chunkLength: TimeInterval = 300

    /// Called on the main queue each time a chunk is finished.
    var onChunk: ((Chunk) -> Void)?
    var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "googly.recorder")
    private var sessionID: UUID?
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var chunkStarted = Date()
    private var chunkIndex = 0
    private var chunkURL: URL?
    private let bufferLock = NSLock()
    private var pendingBuffers = 0
    private var overloadReported = false
    private var writeFailed = false
    private var recoverCurrentChunk = false

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("audio", isDirectory: true)
    }

    func start(session: UUID) {
        queue.async {
            self.closeChunk()
            self.sessionID = session
            self.chunkIndex = 0
            self.recoverCurrentChunk = false
            self.writeFailed = false
            self.bufferLock.lock(); self.overloadReported = false; self.bufferLock.unlock()
        }
    }

    /// Feeds one buffer from the mic tap (any thread).
    func append(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        guard pendingBuffers < 256 else {
            let report = !overloadReported
            overloadReported = true
            bufferLock.unlock()
            if report { DispatchQueue.main.async { self.onFailure?("Audio recording could not keep up. The local text transcript continues.") } }
            return
        }
        pendingBuffers += 1
        bufferLock.unlock()
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else {
            bufferLock.lock(); pendingBuffers -= 1; bufferLock.unlock()
            return
        }
        queue.async {
            self.write(copy)
            self.bufferLock.lock(); self.pendingBuffers -= 1; self.bufferLock.unlock()
        }
    }

    func finish() {
        queue.async {
            self.closeChunk()
            self.sessionID = nil
        }
    }

    func markForLocalRecovery() {
        queue.async { self.recoverCurrentChunk = true }
    }

    func finishAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.closeChunk()
                self.sessionID = nil
                // onChunk is already queued on main. Its pending-file registration must precede session.end.
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let sessionID, !writeFailed else { return }
        if file != nil, Date().timeIntervalSince(chunkStarted) >= Self.chunkLength { closeChunk() }
        if file == nil || fileFormat != buffer.format {
            closeChunk()
            openChunk(sessionID: sessionID, format: buffer.format)
        }
        do { try file?.write(from: buffer) }
        catch {
            writeFailed = true
            closeChunk()
            DispatchQueue.main.async { self.onFailure?("Audio recording stopped because the file could not be saved. The local text transcript continues.") }
        }
    }

    private func openChunk(sessionID: UUID, format: AVAudioFormat) {
        let folder = Self.folder.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        chunkIndex += 1
        let url = folder.appendingPathComponent(String(format: "chunk-%03d.m4a", chunkIndex))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 48_000,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            writeFailed = true
            DispatchQueue.main.async { self.onFailure?("The audio recording could not be created. The local text transcript continues.") }
        }
        fileFormat = format
        chunkURL = url
        chunkStarted = Date()
    }

    private func closeChunk() {
        guard file != nil, let url = chunkURL, let sessionID else { file = nil; return }
        file = nil  // closing the file finishes writing it
        let chunk = Chunk(sessionID: sessionID, index: chunkIndex, url: url, started: chunkStarted,
                          needsLocalRecovery: recoverCurrentChunk)
        recoverCurrentChunk = false
        chunkURL = nil
        DispatchQueue.main.async { self.onChunk?(chunk) }
    }
}

/// Archives audio on the Mac and synchronizes locally produced text. No remote recognition is allowed here.
@MainActor
enum NotesSync {
    private static var inFlight: Set<String> = []
    private static var recovery: Task<Void, Never>?

    static func chunkURL(_ session: UUID, index: Int) -> URL {
        ChunkRecorder.folder.appendingPathComponent(session.uuidString, isDirectory: true)
            .appendingPathComponent(String(format: "chunk-%03d.m4a", index))
    }

    static func upload(_ session: UUID, index: Int, started: Date, store: SessionStore, link: MacLink) {
        let key = "\(session)-\(index)"
        guard !inFlight.contains(key), inFlight.count < 2, link.connected,
              let saved = store.sessions.first(where: { $0.id == session }),
              saved.pending?.contains(where: { $0.index == index && $0.archived != true }) == true else { return }
        let sessionStarted = saved.started
        let url = chunkURL(session, index: index)
        guard let audio = try? Data(contentsOf: url) else {
            store.recoveryFailed(session, message: "Recording \(index) is missing from this iPhone. Existing text and pending status were preserved.")
            return
        }
        inFlight.insert(key)
        let meta: [String: Any] = ["session": session.uuidString, "index": index,
                                   "started": started.timeIntervalSince1970,
                                   "sessionStarted": sessionStarted.timeIntervalSince1970]
        let metaText = (try? JSONSerialization.data(withJSONObject: meta)).flatMap { String(data: $0, encoding: .utf8) }
        link.request(Packet(command: "archiveAudio", audio: audio.base64EncodedString(), text: metaText)) { reply in
            inFlight.remove(key)
            guard let path = reply?.text, !path.isEmpty else {
                // The Mac couldn't do it right now: try again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    upload(session, index: index, started: started, store: store, link: link)
                }
                return
            }
            store.archived(session, index: index)
            store.setNotesPath(session, path)
            // Legacy audio must remain on the phone until local recovery succeeds.
            if !store.needsLocalRecovery(session, index: index) { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { retryPending(store: store, link: link) }
        }
    }

    static func retryPending(store: SessionStore, link: MacLink) {
        for session in store.sessions {
            for chunk in session.pending ?? [] where chunk.archived != true {
                upload(session.id, index: chunk.index, started: chunk.started, store: store, link: link)
            }
        }
    }

    static func pauseRecovery() async {
        let task = recovery
        recovery = nil
        task?.cancel()
        await task?.value
    }

    static func recoverPending(store: SessionStore, link: MacLink) {
        guard recovery == nil, store.currentID == nil else { return }
        recovery = Task {
            defer { recovery = nil }
            for session in store.sessions {
                for chunk in session.pending ?? [] where chunk.purpose != "archive" {
                    guard !Task.isCancelled, store.currentID == nil else { return }
                    guard #available(iOS 26.0, *) else {
                        store.recoveryFailed(session.id, message: LocalSpeechError.unavailable.localizedDescription)
                        return
                    }
                    do {
                        let url = chunkURL(session.id, index: chunk.index)
                        let spans = try await LocalSpeechRecognition.recognizeFile(url, locale: SpeechSession.locale)
                        try Task.checkCancellation()
                        store.recovered(session.id, index: chunk.index, started: chunk.started, spans: spans)
                        if store.sessions.first(where: { $0.id == session.id })?.pending?.contains(where: { $0.index == chunk.index }) != true {
                            try? FileManager.default.removeItem(at: url)
                        }
                    } catch is CancellationError { return }
                    catch { store.recoveryFailed(session.id, message: "Local recovery failed for recording \(chunk.index). The recording and existing text were preserved.") }
                }
            }
            retryPending(store: store, link: link)
        }
    }

    static func send(_ sessions: [BlueySession], store: SessionStore, link: MacLink) {
        guard link.connected else { store.syncFailed(sessions.map(\.id)); return }
        for session in sessions {
            let entries: [[String: Any]] = session.displayEntries.map { entry in
                var e: [String: Any] = ["id": entry.id.uuidString, "kind": entry.kind.rawValue, "text": entry.text, "time": entry.time.timeIntervalSince1970]
                if let speaker = entry.speaker { e["speaker"] = speaker }
                if let source = entry.source { e["source"] = source }
                if let id = entry.questionID { e["questionID"] = id.uuidString }
                if let start = entry.audioStart { e["audioStart"] = start }
                if let end = entry.audioEnd { e["audioEnd"] = end }
                return e
            }
            var json: [String: Any] = ["id": session.id.uuidString, "started": session.started.timeIntervalSince1970,
                                       "legacyPending": session.transcribing, "entries": entries]
            if let ended = session.ended { json["ended"] = ended.timeIntervalSince1970 }
            guard let data = try? JSONSerialization.data(withJSONObject: json), let text = String(data: data, encoding: .utf8) else { continue }
            link.request(Packet(command: "notes", text: text)) { reply in
                if let path = reply?.text { store.setNotesPath(session.id, path) }
                else { store.syncFailed([session.id], retry: link.connected) }
            }
        }
    }
}
