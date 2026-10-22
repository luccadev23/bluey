import Foundation
import Combine

/// Coordinates text conversations. SpeechSession is the single, provider-independent owner of recognition.
@MainActor
final class LiveVoice: NSObject, ObservableObject {
    enum State: Equatable { case asleep, waking, listening, asking, thinking, speaking }
    @Published private(set) var state: State = .asleep
    @Published private(set) var statusMessage: String?
    static let model = "gpt-realtime-2.1"
    var requestToken: ((@escaping (String?) -> Void) -> Void)?
    var runTool: ((String, String, @escaping (String, String?) -> Void) -> Void)?
    var onCaption: ((String, Bool) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onSessionStart: ((UUID, Date) -> Void)?
    var onSessionEnd: (() -> Void)?
    var onLocalSpeech: ((UUID, SpeechSegment, Date) -> Void)?
    var onReply: ((String) -> Void)?
    var onReport: ((String) -> Void)?
    var resumeContext: (() -> String?)?

    private let speech = SpeechSession()
    var recorder: ChunkRecorder { speech.recorder }
    private var wantAwake = false
    private var localReady = false
    private var ending = false
    private var wakeAfterEnding = false
    private var holding = false
    private var startup: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var sendChain: Task<Void, Never>?
    private var adapter: any TextConversationAdapter = VoiceProvider.openai.textConversation
    private var conversationReady = false
    private var requestingToken = false
    private var generation = UUID()
    private var pendingQuestions: [TextQuestion] = []
    private var activeQuestion: UUID?
    private var responseActive = false
    private var toolsRunning = 0
    private var sleepAfterReply = false
    private var resumeHandle: String?
    private var resumed = false
    private var transcript = ""
    private var chirpedThisResponse = false
    var level: Double { speech.level }
    var volume: Double {
        get { speech.volume }
        set { speech.volume = newValue }
    }

    override init() {
        super.init()
        speech.onStarted = { [weak self] id, date in self?.onSessionStart?(id, date) }
        speech.onSegment = { [weak self] id, segment, date in self?.onLocalSpeech?(id, segment, date) }
        speech.onQuestion = { [weak self] question in self?.enqueue(question) }
        speech.onStatus = { [weak self] message in
            self?.statusMessage = message
            if self?.state == .thinking, self?.activeQuestion == nil { self?.setState(.listening) }
        }
        speech.onFailure = { [weak self] error in
            self?.statusMessage = error.localizedDescription
            self?.onCaption?(error.localizedDescription, true)
            self?.sleep()
        }
        speech.onEnded = { [weak self] in self?.onSessionEnd?() }
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new; onStateChange?(new)
    }
    func toggle() {
        if ending { wakeAfterEnding.toggle(); return }
        wantAwake ? sleep() : wake()
    }
    func wake() {
        if ending { wakeAfterEnding = true; return }
        guard !wantAwake else { return }
        wantAwake = true
        statusMessage = "Preparing local speech recognition…"
        generation = UUID()
        let generation = self.generation
        setState(.waking)
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                await NotesSync.pauseRecovery()
                try await self.speech.start()
                try Task.checkCancellation()
                guard self.wantAwake, self.generation == generation else { return }
                self.localReady = true
                self.statusMessage = nil
                self.setState(self.holding ? .asking : .listening)
                if self.holding { self.speech.beginQuestion() }
                self.requestConnection()
            } catch {
                guard self.generation == generation else { return }
                self.statusMessage = error.localizedDescription
                self.onCaption?(error.localizedDescription, true)
                self.sleep()
            }
        }
    }

    func sleep() {
        if ending { wakeAfterEnding = false; return }
        guard wantAwake || localReady else { return }
        ending = true
        wantAwake = false
        holding = false
        generation = UUID()
        startup?.cancel(); retry?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil; conversationReady = false; requestingToken = false
        pendingQuestions = []; activeQuestion = nil; responseActive = false; toolsRunning = 0
        resumeHandle = nil; sleepAfterReply = false; localReady = false
        setState(.asleep)
        Task { [weak self] in
            guard let self else { return }
            await self.startup?.value
            await self.speech.stop()
            self.ending = false
            if self.wakeAfterEnding {
                self.wakeAfterEnding = false
                self.wake()
            }
        }
    }

    func beginAsk() {
        guard !ending else { return }
        holding = true
        NSLog("Bluey: hold began")
        onCaption?("", true)
        if !wantAwake { wake(); return }
        guard localReady else { return }
        speech.beginQuestion()
        setState(.asking)
    }
    func endAsk() {
        guard holding else { return }
        holding = false
        NSLog("Bluey: hold released")
        guard localReady else {
            statusMessage = "Wait until listening is ready, then hold to ask again."
            return
        }
        setState(.thinking)
        if !speech.endQuestion() { setState(.listening) }
    }
    func sayHi() {
        guard wantAwake else { wake(); return }
        enqueue(TextQuestion(text: "Reply with a quick, cheerful hi in under eight words."))
    }

    private func enqueue(_ question: TextQuestion) {
        guard wantAwake else { return }
        guard pendingQuestions.count < 8 else {
            statusMessage = "There are too many pending questions. Please wait for the reply."
            return
        }
        pendingQuestions.append(question)
        dispatchNextQuestion()
    }
    private func dispatchNextQuestion() {
        guard wantAwake, conversationReady, activeQuestion == nil, !responseActive, toolsRunning == 0,
              !pendingQuestions.isEmpty else { return }
        let question = pendingQuestions.removeFirst()
        activeQuestion = question.id
        responseActive = true
        transcript = ""; chirpedThisResponse = false
        statusMessage = nil
        setState(.thinking)
        NSLog("Bluey: sending consolidated text question")
        adapter.question(question).forEach(send)
    }

    private func requestConnection(attempt: Int = 0) {
        guard wantAwake, socket == nil, !requestingToken, let requestToken else { return }
        requestingToken = true
        let generation = self.generation
        requestToken { [weak self] token in
            Task { @MainActor in
                guard let self, self.wantAwake, self.generation == generation else { return }
                self.requestingToken = false
                if let token { self.connect(token) }
                else {
                    self.statusMessage = "Listening locally. Waiting for the Mac and conversation service…"
                    self.retry = Task {
                        try? await Task.sleep(for: .seconds(min(30, 2 + Double(attempt) * 3)))
                        guard !Task.isCancelled else { return }
                        self.requestConnection(attempt: attempt + 1)
                    }
                }
            }
        }
    }

    private func connect(_ payload: String) {
        if payload.hasPrefix("{") {
            guard let bundle = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  bundle["provider"] as? String == "gemini", bundle["token"] is String, bundle["setup"] is [String: Any] else {
                statusMessage = "This conversation provider is not supported by this app version. Listening continues locally."
                return
            }
        }
        var request: URLRequest
        var setup: [String: Any]?
        if let bundle = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
           bundle["provider"] as? String == "gemini", let token = bundle["token"] as? String,
           let value = bundle["setup"] as? [String: Any] {
            var parts = URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained")!
            parts.queryItems = [URLQueryItem(name: "access_token", value: token)]
            request = URLRequest(url: parts.url!)
            adapter = VoiceProvider.gemini.textConversation
            setup = value
            resumed = resumeHandle != nil
            if let resumeHandle { setup?["sessionResumption"] = ["handle": resumeHandle] }
        } else {
            request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.model)")!)
            request.setValue("Bearer \(payload)", forHTTPHeaderField: "Authorization")
            adapter = VoiceProvider.openai.textConversation
            resumed = false
        }
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        conversationReady = false
        sendChain = nil
        socket.resume()
        receive(on: socket)
        if let setup { send(["setup": setup]) }
    }

    private func connectionLost(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        socket.cancel(with: .goingAway, reason: nil)
        self.socket = nil; conversationReady = false
        if activeQuestion != nil {
            statusMessage = "Connection lost. The last question was not repeated; listening continues locally."
            onCaption?(statusMessage!, true)
        }
        // An uncertain request may have executed a tool: never replay it automatically.
        activeQuestion = nil; responseActive = false; toolsRunning = 0
        transcript = ""; chirpedThisResponse = false
        guard wantAwake else { return }
        setState(holding ? .asking : .listening)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.requestConnection()
        }
    }

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        let previous = sendChain
        sendChain = Task { [weak self] in
            await previous?.value
            guard let self, self.socket === socket else { return }
            do { try await socket.send(.string(text)) }
            catch { self.connectionLost(socket) }
        }
    }
    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = nil
                    }
                    if let data, let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.handle(self.adapter.events(from: event))
                    }
                    self.receive(on: socket)
                case .failure: self.connectionLost(socket)
                }
            }
        }
    }

    private func handle(_ events: [ConversationEvent]) {
        for event in events {
            switch event {
            case .ready:
                guard !conversationReady else { continue }
                conversationReady = true
                NSLog("Bluey: text conversation ready")
                if !resumed, let context = resumeContext?() { adapter.restoreContext(context).forEach(send) }
                dispatchNextQuestion()
            case .started:
                responseActive = true
                transcript = ""; chirpedThisResponse = false
            case .text(let text):
                transcript += text
                if !chirpedThisResponse, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    NSLog("Bluey: first reply text")
                    chirpedThisResponse = true
                    setState(.speaking)
                    speech.chirp(syllables: 4)
                }
                onCaption?(transcript, false)
            case .completed, .interrupted:
                NSLog("Bluey: conversation turn finished")
                if !transcript.isEmpty { onCaption?(transcript, true); onReply?(transcript) }
                transcript = ""; chirpedThisResponse = false
                responseActive = toolsRunning > 0
                if toolsRunning == 0 { activeQuestion = nil }
            case .tools(let calls): runTools(calls)
            case .resumeHandle(let handle): resumeHandle = handle
            case .failed:
                statusMessage = "The conversation service could not complete this request. Listening continues locally."
                onCaption?(statusMessage!, true)
                resumeHandle = nil
                if let socket { connectionLost(socket) }
            }
        }
        finishIfQuiet()
    }

    private func runTools(_ calls: [ConversationToolCall]) {
        guard let socket else { return }
        if !transcript.isEmpty {
            onCaption?(transcript, true); onReply?(transcript)
            transcript = ""; chirpedThisResponse = false
        }
        toolsRunning += 1
        responseActive = true
        Task { [weak self] in
            guard let self else { return }
            var results: [ConversationToolResult] = []
            for call in calls {
                guard self.socket === socket else { return }
                NSLog("Bluey: tool request started")
                if call.name == "go_to_sleep" { self.sleepAfterReply = true }
                let result: (String, String?) = await withCheckedContinuation { continuation in
                    if let runTool = self.runTool {
                        runTool(call.name, call.arguments) { continuation.resume(returning: ($0, $1)) }
                    } else { continuation.resume(returning: ("The Mac is not connected.", nil)) }
                }
                guard self.socket === socket else { return }
                if call.name == "web_research", let range = result.0.range(of: "\n---REPORT---\n") {
                    self.onReport?(String(result.0[range.upperBound...]))
                }
                results.append(ConversationToolResult(call: call, text: result.0, image: result.1))
            }
            self.toolsRunning = max(0, self.toolsRunning - 1)
            self.responseActive = true
            self.adapter.toolResults(results).forEach(self.send)
        }
    }

    private func finishIfQuiet() {
        guard !responseActive, toolsRunning == 0 else { return }
        if sleepAfterReply { sleep(); return }
        dispatchNextQuestion()
        if activeQuestion == nil, localReady { setState(holding ? .asking : .listening) }
    }


}
