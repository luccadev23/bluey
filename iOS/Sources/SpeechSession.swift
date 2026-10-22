import AVFoundation
import Foundation

/// Owns microphone, recognition, recording and temporal question boundaries for every conversation provider.
@MainActor
final class SpeechSession {
    var onStarted: ((UUID, Date) -> Void)?
    var onSegment: ((UUID, SpeechSegment, Date) -> Void)?
    var onQuestion: ((TextQuestion) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onEnded: (() -> Void)?
    let recorder = ChunkRecorder()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var playbackConfigured = false
    private var pendingBuffers = 0
    private(set) var level = 0.0
    var volume: Double {
        get { UserDefaults.standard.object(forKey: "volume") as? Double ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "volume"); player.volume = Float(newValue) }
    }
    private var recognizer: (any LocalSpeechRecognizing)?
    private var transcript = SpeechTranscript()
    private var sessionID: UUID?
    private var started = Date()
    private var questionID: UUID?
    private var pendingFinalizations = 0
    private var contextThrough = 0.0
    private var operations: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var stopping = false
    private var tapInstalled = false

    func start() async throws {
        guard #available(iOS 26.0, *) else { throw LocalSpeechError.unavailable }
        guard await AVAudioApplication.requestRecordPermission() else { throw LocalSpeechError.noMicrophone }
        try Task.checkCancellation()
        let generation = UUID()
        self.generation = generation
        stopping = false
        transcript = SpeechTranscript()
        pendingFinalizations = 0
        contextThrough = 0
        let recognizer = LocalSpeechRecognition()
        self.recognizer = recognizer
        recognizer.onSpeech = { [weak self] spans in self?.receive(spans, generation: generation) }
        recognizer.onFailure = { [weak self] error in
            guard let self, self.generation == generation, !self.stopping else { return }
            self.recorder.markForLocalRecovery()
            self.onFailure?(error)
        }
        try await recognizer.prepare(locale: Self.locale) {
            self.onStatus?($0)
        }
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try audio.setActive(true)
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        if !playbackConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            player.installTap(onBus: 0, bufferSize: 1024, format: playFormat) { [weak self] buffer, _ in
                guard let samples = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                let rms = Double(sqrt(sum / Float(max(buffer.frameLength, 1))))
                Task { @MainActor in self?.level = min(1, rms * 5) }
            }
            playbackConfigured = true
        }
        player.volume = Float(volume)
        let format = input.outputFormat(forBus: 0)
        let sink = recognizer.sink()
        let recorder = self.recorder
        recorder.onFailure = { [weak self] message in self?.onStatus?(message) }
        sessionID = UUID()
        started = Date()
        onStarted?(sessionID!, started)
        recorder.start(session: sessionID!)
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { buffer, _ in
            recorder.append(buffer)
            sink(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        observers = [
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: audio, queue: .main) { [weak self] note in
                if note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                    Task { @MainActor in self?.onFailure?(LocalSpeechError.interrupted) }
                }
            },
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.stopping, self.sessionID != nil else { return }
                    self.onFailure?(LocalSpeechError.interrupted)
                }
            }
        ]
    }

    func beginQuestion() {
        guard let recognizer, sessionID != nil, !stopping else { return }
        guard questionID == nil, pendingFinalizations < 8 else {
            onStatus?("Please wait for the pending questions to finish.")
            return
        }
        pendingFinalizations += 1
        // Mark the gesture synchronously, even while a previous finalization is still queued.
        questionID = transcript.beginQuestion(at: recognizer.position())
    }

    @discardableResult
    func endQuestion() -> Bool {
        guard let recognizer, sessionID != nil, !stopping, let id = questionID else { return false }
        transcript.endQuestion(id, at: recognizer.position())
        questionID = nil
        // Cut the input now, even if a previous question is still being finalized.
        let finalization = recognizer.finalizeQuestion()
        let previous = operations
        let generation = self.generation
        operations = Task { [weak self] in
            await previous?.value
            guard let self, generation == self.generation, !self.stopping else { return }
            defer { self.pendingFinalizations = max(0, self.pendingFinalizations - 1) }
            let clock = ContinuousClock.now
            do {
                let time = try await finalization.value
                guard generation == self.generation, !self.stopping else { return }
                if let question = self.transcript.question(id, contextAfter: self.contextThrough) {
                    self.onQuestion?(question)
                    self.contextThrough = time
                }
                else { self.onStatus?("No speech recognized. Hold the screen and try again.") }
                NSLog("Bluey: local question finalized in %@", String(describing: clock.duration(to: .now)))
                self.transcript.trim(before: max(0, time - 600))
            } catch { self.onFailure?(error) }
        }
        return true
    }

    func stop() async {
        guard !stopping else { return }
        stopping = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        player.stop()
        engine.stop()
        pendingBuffers = 0; level = 0
        await operations?.value
        // Keep the session ID until the final result reader and recorder have drained.
        await recognizer?.finish()
        await recorder.finishAndWait()
        recognizer = nil
        sessionID = nil; questionID = nil; operations = nil
        pendingFinalizations = 0
        generation = UUID()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        onEnded?()
    }

    static var locale: Locale {
        let selected = UserDefaults.standard.string(forKey: "speechLocale") ?? ""
        return Locale(identifier: selected.isEmpty ? (Locale.preferredLanguages.first ?? "pt-BR") : selected)
    }

    private func receive(_ spans: [RecognizedSpeech], generation: UUID) {
        guard self.generation == generation, let sessionID else { return }
        // Coalesce adjacent words within the same gesture, retaining the original audio times.
        var groups: [(start: Double, end: Double, text: String, question: UUID?)] = []
        for span in spans {
            let question = transcript.questions.first { $0.contains(start: span.start, end: span.end) }?.id
            if let last = groups.indices.last, groups[last].question == question {
                groups[last].end = span.end
                groups[last].text += span.text
            } else { groups.append((span.start, span.end, span.text, question)) }
        }
        for group in groups {
            if let segment = transcript.append(start: group.start, end: group.end, text: group.text) {
                onSegment?(sessionID, segment, started)
            }
        }
    }
    /// A tiny cartoon chirp: a few soft, round, bell-like notes from a happy pentatonic scale,
    /// each with a little upward "boop" at the start, like a small creature humming.
    func chirp(syllables: Int) {
        guard playbackConfigured, sessionID != nil else { return }
        let rate = playFormat.sampleRate
        // C major pentatonic, two octaves up high (C6…E7), so it always sounds sweet together.
        let scale = [1046.5, 1174.7, 1318.5, 1568.0, 1760.0, 2093.0, 2349.3, 2637.0]
        var index = Int.random(in: 1...3)
        var samples: [Float] = []
        for i in 0..<syllables {
            if i > 0 { index = min(max(index + [-1, 1, 1, 2].randomElement()!, 0), scale.count - 1) }
            let note = scale[index] * 0.5  // drop an octave: rounder, less piercing
            let duration = i == syllables - 1 ? 0.13 : Double.random(in: 0.07...0.09)
            let count = Int(duration * rate)
            var phase = 0.0
            for n in 0..<count {
                let time = Double(n) / rate
                let t = Double(n) / Double(count)
                // Scoops up into the note over the first 25 ms, with a gentle wobble on the last one.
                let scoop = 1 - 0.18 * exp(-time / 0.012)
                let wobble = i == syllables - 1 ? 1 + 0.012 * sin(time * 2 * .pi * 18) : 1
                phase += 2 * .pi * note * scoop * wobble / rate
                let attack = min(1, time / 0.006)
                let envelope = attack * exp(-t * 3.2) * (1 - pow(t, 6))
                let wave = sin(phase) + 0.12 * sin(2 * phase)
                samples.append(Float(wave * envelope * 0.26))
            }
            samples += [Float](repeating: 0, count: Int(rate * 0.028))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        pendingBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 { self.level = 0 }
            }
        }
    }

}
