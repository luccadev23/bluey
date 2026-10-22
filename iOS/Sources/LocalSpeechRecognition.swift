import AVFoundation
import Speech

struct RecognizedSpeech {
    let start: Double
    let end: Double
    let text: String
}

enum LocalSpeechError: LocalizedError {
    case unavailable, unsupportedLanguage, audioFormat, overloaded, interrupted, noMicrophone
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Local speech recognition requires iOS 26 and a supported iPhone."
        case .unsupportedLanguage: return "Apple's local speech model is not available for this language."
        case .audioFormat: return "The microphone format could not be used for local speech recognition."
        case .overloaded: return "Local speech recognition could not keep up. Please restart listening."
        case .interrupted: return "Listening was interrupted. Wake Bluey to resume."
        case .noMicrophone: return "Allow microphone access in Settings to talk to Bluey."
        }
    }
}

@MainActor
protocol LocalSpeechRecognizing: AnyObject {
    var onSpeech: (([RecognizedSpeech]) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func prepare(locale: Locale, status: (String) -> Void) async throws
    func sink() -> @Sendable (AVAudioPCMBuffer) -> Void
    func position() -> Double
    func finalizeQuestion() -> Task<Double, Error>
    func finish() async
}

/// Serial, bounded ingestion. No provider or network code can access the microphone buffers.
@available(iOS 26.0, *)
private final class SpeechAudioInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "bluey.local-speech.audio")
    private let lock = NSLock()
    private var pending = 0
    private var closed = false
    private var capturedSeconds = 0.0
    private let format: AVAudioFormat
    private var stream: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var frames: Int64 = 0
    private var origin: Int64 = 0
    private let failure: @Sendable (Error) -> Void

    init(format: AVAudioFormat, stream: AsyncStream<AnalyzerInput>.Continuation, failure: @escaping @Sendable (Error) -> Void) {
        self.format = format; self.stream = stream; self.failure = failure
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard pending < 128 else {
            closed = true; lock.unlock(); failure(LocalSpeechError.overloaded); return
        }
        pending += 1
        capturedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else {
            pending -= 1; lock.unlock()
            failure(LocalSpeechError.audioFormat); return
        }
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                if converter?.inputFormat != copy.format { converter = AVAudioConverter(from: copy.format, to: format) }
                guard let converter,
                      let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(copy.frameLength) * format.sampleRate / copy.format.sampleRate + 256)) else {
                    throw LocalSpeechError.audioFormat
                }
                var supplied = false
                var error: NSError?
                converter.convert(to: output, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return copy
                }
                if let error { throw error }
                guard output.frameLength > 0 else { return }
                let time = CMTime(value: frames - origin, timescale: CMTimeScale(format.sampleRate))
                frames += Int64(output.frameLength)
                if case .dropped = stream.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
                    throw LocalSpeechError.overloaded
                }
            } catch { failure(error) }
        }
        // Publish the buffer to the queue before a gesture can enqueue its cut.
        lock.unlock()
    }

    /// Enqueue the cut synchronously, after submitted buffers and before subsequent capture.
    /// Conversion keeps running; the next stream buffers audio while the old reader drains.
    func rotate(to next: AsyncStream<AnalyzerInput>.Continuation) -> Task<Double, Never> {
        let (markers, marker) = AsyncStream.makeStream(of: Double.self, bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        queue.async { [self] in
            stream.finish()
            stream = next
            origin = frames
            marker.yield(Double(frames) / format.sampleRate)
            marker.finish()
        }
        lock.unlock()
        return Task { for await time in markers { return time }; return 0 }
    }
    func finish() async {
        close()
        await withCheckedContinuation { continuation in
            queue.async { self.stream.finish(); continuation.resume() }
        }
    }
    private func close() { lock.lock(); closed = true; lock.unlock() }
    func position() -> Double { lock.lock(); defer { lock.unlock() }; return capturedSeconds }
}

/// Apple's recognizer is the only transcription backend. Its lifetime is independent of model sockets.
@available(iOS 26.0, *)
@MainActor
final class LocalSpeechRecognition: LocalSpeechRecognizing {
    var onSpeech: (([RecognizedSpeech]) -> Void)?
    var onFailure: ((Error) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var input: SpeechAudioInput?
    private struct RecognitionRun {
        let analyzer: SpeechAnalyzer
        let reader: Task<Void, Error>
        let analysis: Task<CMTime?, Error>
    }
    private var current: Task<RecognitionRun, Error>?
    private var finishing = false
    private var failure: Error?
    private var locale: Locale?
    private var format: AVAudioFormat?

    private static func makeTranscriber(locale: Locale, status: (String) -> Void) async throws -> (SpeechTranscriber, Locale) {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw LocalSpeechError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw LocalSpeechError.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Downloading Apple's speech model…")
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        return (transcriber, supported)
    }

    func prepare(locale: Locale, status: (String) -> Void) async throws {
        let (transcriber, supportedLocale) = try await Self.makeTranscriber(locale: locale, status: status)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw LocalSpeechError.audioFormat }
        self.locale = supportedLocale
        self.format = format
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(128))
        let run = try await startRun(transcriber: transcriber, format: format, stream: stream, offset: 0)
        current = Task { run }
        input = SpeechAudioInput(format: format, stream: continuation) { [weak self] error in
            Task { @MainActor in self?.fail(error) }
        }
    }

    private func startRun(transcriber: SpeechTranscriber, format: AVAudioFormat,
                          stream: AsyncStream<AnalyzerInput>, offset: Double) async throws -> RecognitionRun {
        // Retain the model between finite runs without running two analyzers concurrently.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        let reader = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    self.onSpeech?(Self.spans(from: result).map {
                        RecognizedSpeech(start: $0.start + offset, end: $0.end + offset, text: $0.text)
                    })
                }
            } catch {
                if !Task.isCancelled { self?.fail(error) }
                throw error
            }
        }
        let analysis = Task { [weak self] in
            do { return try await analyzer.analyzeSequence(stream) }
            catch {
                if !Task.isCancelled { self?.fail(error) }
                throw error
            }
        }
        return RecognitionRun(analyzer: analyzer, reader: reader, analysis: analysis)
    }

    private static func spans(from result: SpeechTranscriber.Result) -> [RecognizedSpeech] {
        var words: [RecognizedSpeech] = []
        var prefix = ""
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            if let range = run.audioTimeRange {
                words.append(RecognizedSpeech(start: range.start.seconds, end: range.end.seconds, text: prefix + text))
                prefix = ""
            } else if let last = words.popLast() {
                words.append(RecognizedSpeech(start: last.start, end: last.end, text: last.text + text))
            } else { prefix += text }
        }
        return words.isEmpty ? [RecognizedSpeech(start: result.range.start.seconds, end: result.range.end.seconds,
                                                 text: String(result.text.characters))] : words
    }

    /// Capturing code passes audio here; adapters only ever receive TextQuestion.
    func sink() -> @Sendable (AVAudioPCMBuffer) -> Void {
        let input = self.input
        return { buffer in input?.append(buffer) }
    }
    func position() -> Double { input?.position() ?? 0 }

    func finalizeQuestion() -> Task<Double, Error> {
        guard let previous = current, let input, let locale, let format else {
            return Task { throw LocalSpeechError.interrupted }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(128))
        let marker = input.rotate(to: continuation)
        let completed = Task { () throws -> Double in
            if let failure { throw failure }
            let run = try await previous.value
            try await drain(run)
            if let failure { throw failure }
            return await marker.value
        }
        current = Task { [self] in
            do {
                let offset = try await completed.value
                if let failure { throw failure }
                let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
                return try await startRun(transcriber: transcriber, format: format, stream: stream, offset: offset)
            } catch {
                continuation.finish()
                fail(error)
                throw error
            }
        }
        return completed
    }

    private func drain(_ run: RecognitionRun) async throws {
        do {
            // End-of-stream, rather than a speech timestamp, is the completion barrier.
            // Silence need not produce any result. Await the reader too: publication is not consumption.
            _ = try await run.analysis.value
            try await run.analyzer.finalizeAndFinishThroughEndOfInput()
            try await run.reader.value
        } catch {
            await run.analyzer.cancelAndFinishNow()
            run.reader.cancel()
            run.analysis.cancel()
            throw error
        }
    }

    func finish() async {
        finishing = true
        await input?.finish()
        do {
            if let current {
                let run = try await current.value
                if failure == nil { try await drain(run) }
                else { await run.analyzer.cancelAndFinishNow() }
            }
        } catch { await analyzer?.cancelAndFinishNow() }
        analyzer = nil; input = nil; current = nil
    }

    private func fail(_ error: Error) {
        guard !finishing, failure == nil else { return }
        failure = error
        onFailure?(error)
        Task { await analyzer?.cancelAndFinishNow() }
    }

    /// Recovery uses the very same Apple model, with a finite input stream that can be fully drained.
    /// It is never a remote fallback and runs one file at a time while live capture is idle.
    static func recognizeFile(_ url: URL, locale: Locale) async throws -> [RecognizedSpeech] {
        let (module, _) = try await makeTranscriber(locale: locale, status: { _ in })
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { () throws -> [RecognizedSpeech] in
            var spans: [RecognizedSpeech] = []
            for try await result in module.results {
                spans += Self.spans(from: result)
            }
            return spans
        }
        do {
            return try await withTaskCancellationHandler {
                let last = try await analyzer.analyzeSequence(from: file)
                try Task.checkCancellation()
                if let last { try await analyzer.finalizeAndFinish(through: last) }
                else { await analyzer.cancelAndFinishNow() }
                let spans = try await results.value
                try Task.checkCancellation()
                return spans
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
    }
}
