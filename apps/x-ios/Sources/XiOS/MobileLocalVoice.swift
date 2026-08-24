@preconcurrency import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

struct MobileVoiceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

private enum MobileAudioCaptureError: LocalizedError {
    case noInput
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .noInput:
            "No microphone input is available. Check the input route in Settings."
        case .startupTimedOut:
            "The microphone did not respond. Dictation stopped safely; check the input route and try again."
        }
    }
}

/// Owns the complete iPhone audio-session and RemoteIO lifecycle on one queue.
/// AVAudioEngine is intentionally never started, stopped, tapped, or released
/// on SwiftUI's main actor; rapid taps and route notifications therefore
/// cannot race two engine graphs or crash the app while a graph is changing.
private final class MobileAudioCapture: @unchecked Sendable {
    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let continuation: CheckedContinuation<Result<MobileAudioCapture, Error>, Never>

        init(_ continuation: CheckedContinuation<Result<MobileAudioCapture, Error>, Never>) {
            self.continuation = continuation
        }

        var isCompleted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return completed
        }

        @discardableResult
        func finish(_ result: Result<MobileAudioCapture, Error>) -> Bool {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return false
            }
            completed = true
            lock.unlock()
            continuation.resume(returning: result)
            return true
        }
    }

    private static let audioQueue = DispatchQueue(label: "app.openfish.iphone.voice.audio", qos: .userInitiated)

    private let session: AVAudioSession
    private let engine: AVAudioEngine
    private let input: AVAudioInputNode
    private let requestBox: RequestBox

    private init(
        session: AVAudioSession,
        engine: AVAudioEngine,
        input: AVAudioInputNode,
        requestBox: RequestBox
    ) {
        self.session = session
        self.engine = engine
        self.input = input
        self.requestBox = requestBox
    }

    static func start(
        request: SFSpeechAudioBufferRecognitionRequest,
        timeout: Duration = .seconds(6)
    ) async -> Result<MobileAudioCapture, Error> {
        let requestBox = RequestBox(request)
        return await withCheckedContinuation { continuation in
            let gate = CompletionGate(continuation)
            audioQueue.async {
                let session = AVAudioSession.sharedInstance()
                var tappedInput: AVAudioInputNode?
                do {
                    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                    try session.setActive(true, options: .notifyOthersOnDeactivation)
                    guard !gate.isCompleted else {
                        try? session.setActive(false, options: .notifyOthersOnDeactivation)
                        return
                    }
                    guard session.isInputAvailable else { throw MobileAudioCaptureError.noInput }

                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        throw MobileAudioCaptureError.noInput
                    }
                    guard !gate.isCompleted else {
                        try? session.setActive(false, options: .notifyOthersOnDeactivation)
                        return
                    }
                    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak requestBox] buffer, _ in
                        requestBox?.request.append(buffer)
                    }
                    tappedInput = input
                    engine.prepare()
                    try engine.start()

                    let capture = MobileAudioCapture(
                        session: session, engine: engine, input: input, requestBox: requestBox
                    )
                    if !gate.finish(.success(capture)) {
                        capture.stopImmediately(endAudio: true)
                    }
                } catch {
                    tappedInput?.removeTap(onBus: 0)
                    try? session.setActive(false, options: .notifyOthersOnDeactivation)
                    gate.finish(.failure(error))
                }
            }

            let components = timeout.components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                gate.finish(.failure(MobileAudioCaptureError.startupTimedOut))
            }
        }
    }

    func stop() {
        Self.audioQueue.async { [self] in stopImmediately(endAudio: true) }
    }

    /// A media-services reset invalidates the old graph. Retain and release it
    /// on the audio queue without messaging the dead RemoteIO objects.
    func abandonAfterMediaServicesReset() {
        Self.audioQueue.async { [self] in
            _ = engine
            _ = input
            _ = requestBox
        }
    }

    private func stopImmediately(endAudio: Bool) {
        if engine.isRunning { engine.stop() }
        input.removeTap(onBus: 0)
        if endAudio { requestBox.request.endAudio() }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor
final class MobileLocalVoice: NSObject, ObservableObject {
#if DEBUG
    private static let hardwareSmokeLogger = Logger(subsystem: "app.openfish.ios", category: "voice-hardware-smoke")
    private static let hardwareSmokeStateKey = "OpenFish.voice.hardwareSmoke.lastState"
#endif
    let providerID = "apple-local"
    let providerName = "Apple On-Device Speech"
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var errorMessage: String?
    @Published var preferredVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(preferredVoiceIdentifier, forKey: "OpenCodex.iPhone.voice.identifier") }
    }
    @Published var speechRate: Float {
        didSet {
            UserDefaults.standard.set(Double(effectiveSpeechRate), forKey: "OpenCodex.iPhone.voice.rate")
        }
    }

    private var audioCapture: MobileAudioCapture?
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handler: ((String, Bool) -> Void)?
    private var speechFinishedHandler: (() -> Void)?
    private var audioObservers: [NSObjectProtocol] = []
    private var captureGeneration = 0

    private var effectiveSpeechRate: Float { min(max(speechRate, 0.35), 0.62) }

    override init() {
        preferredVoiceIdentifier = UserDefaults.standard.string(forKey: "OpenCodex.iPhone.voice.identifier") ?? ""
        let storedRate = UserDefaults.standard.double(forKey: "OpenCodex.iPhone.voice.rate")
        speechRate = storedRate == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(storedRate)
        super.init()
        synthesizer.delegate = self
        installAudioObservers()
    }

    deinit {
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func installAudioObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]
        audioObservers = names.map { name in
            center.addObserver(forName: name, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
                let action: Int
                if name == AVAudioSession.interruptionNotification {
                    let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    action = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began ? 1 : 0
                } else if name == AVAudioSession.mediaServicesWereResetNotification {
                    action = 2
                } else {
                    let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    // Activating our own `.record` category can publish a
                    // delayed categoryChange after the engine is already
                    // running. Treating that benign notification as device
                    // loss raced teardown against a fresh tap on some phones.
                    action = reason == .categoryChange ? 0 : 3
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if action == 1 {
                        self.errorMessage = "Dictation stopped because iPhone audio was interrupted. Tap the microphone to resume."
                        self.stopListening()
                    } else if action == 2 {
                        self.errorMessage = "iPhone audio services restarted. Tap the microphone to begin again."
                        self.abandonListeningAfterMediaServicesReset()
                    } else if action == 3, self.isListening {
                        self.errorMessage = "The microphone route changed. Dictation stopped safely; tap the microphone to resume."
                        self.stopListening()
                    }
                }
            }
        }
    }

    var availableVoices: [MobileVoiceChoice] {
        let language = Locale.current.language.languageCode?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in language.map { voice.language.hasPrefix($0) } ?? true }
            .map { voice in
                let quality = voice.quality == .premium ? "Premium"
                    : voice.quality == .enhanced ? "Enhanced" : "Standard"
                return MobileVoiceChoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
            }
            .sorted { left, right in
                if left.quality != right.quality {
                    let rank = ["Premium": 0, "Enhanced": 1, "Standard": 2]
                    return rank[left.quality, default: 3] < rank[right.quality, default: 3]
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    func toggle(onTranscript: @escaping (String, Bool) -> Void) async {
        if isStarting {
            stopListening()
            return
        }
        if isListening { stopListening(); return }
        await startListening(onTranscript: onTranscript)
    }

    func startListening(onTranscript: @escaping (String, Bool) -> Void) async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        stopSpeaking()
        stopListening()
        captureGeneration += 1
        let generation = captureGeneration
        errorMessage = nil
#if DEBUG
        if ProcessInfo.processInfo.environment["OPENFISH_FORCE_MICROPHONE_DENIED"] == "1" {
            errorMessage = "Microphone permission is required."
            return
        }
#endif
#if targetEnvironment(simulator)
        // CoreAudio input initialization can abort the Simulator process with
        // an unrecoverable RPC timeout. Keep the production path unchanged and
        // make the unsupported test environment fail visibly instead.
        errorMessage = "Dictation requires a physical iPhone; iPhone Simulator audio input is not supported."
#else
        // An iPhone build can also run directly on Apple-silicon macOS. In
        // that compatibility environment AVAudioEngine.inputNode currently
        // enters the iOS RemoteIO path and may abort the entire process after
        // an audio-server RPC timeout; there is no Swift error to catch. Keep
        // the button safe and explicit instead of touching RemoteIO there.
        if ProcessInfo.processInfo.isiOSAppOnMac {
            errorMessage = "Dictation is not available when the iPhone app runs on a Mac. Use the native OpenFish Mac app for voice input."
            return
        }
        let authorization = await Self.requestSpeechAuthorization()
        guard generation == captureGeneration else { return }
        guard authorization == .authorized else {
            errorMessage = "Speech permission is required."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone permission is required."
            return
        }
        guard generation == captureGeneration else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            errorMessage = "Install on-device speech recognition for this language in iPhone Settings."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request
        handler = onTranscript

        switch await MobileAudioCapture.start(request: request) {
        case .failure(let error):
            self.request = nil
            handler = nil
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        case .success(let capture):
            guard generation == captureGeneration else {
                capture.stop()
                self.request = nil
                handler = nil
                return
            }
            audioCapture = capture
        }
        isListening = true
        task = Self.makeRecognitionTask(recognizer: recognizer, request: request, service: self)
#endif
    }

    nonisolated private static func makeRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        service: MobileLocalVoice
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { [weak service] result, error in
            let update = result.map { ($0.bestTranscription.formattedString, $0.isFinal) }
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard let service, service.task != nil else { return }
                if let update {
                    let (text, isFinal) = update
                    service.handler?(text, isFinal)
                    if isFinal { service.stopListening() }
                } else if let failure {
                    service.errorMessage = failure
                    service.stopListening()
                }
            }
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func stopListening() {
        captureGeneration += 1
        audioCapture?.stop()
        audioCapture = nil
        task?.cancel()
        request = nil
        task = nil
        handler = nil
        isListening = false
    }

#if DEBUG
    /// Exercises the same on-device speech and RemoteIO lifecycle as the UI
    /// without depending on XCTest's physical-device automation channel.
    /// The diagnostic deliberately never prints recognized speech.
    func runPhysicalHardwareSmokeTest(iterations: Int = 5) async {
        recordHardwareSmokeState("started iterations=\(iterations)")
        for iteration in 1...iterations {
            await startListening { _, _ in }
            guard isListening else {
                let reason = (errorMessage ?? "unknown")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                recordHardwareSmokeState("failed iteration=\(iteration) reason=\(reason)", isError: true)
                stopListening()
                return
            }

            recordHardwareSmokeState("microphone-active iteration=\(iteration)")
            try? await Task.sleep(for: .milliseconds(450))
            recordHardwareSmokeState("stop-requested iteration=\(iteration)")
            stopListening()
            recordHardwareSmokeState("stop-returned iteration=\(iteration) listening=\(isListening)")
            try? await Task.sleep(for: .milliseconds(300))
            recordHardwareSmokeState("cooldown-finished iteration=\(iteration) cancelled=\(Task.isCancelled)")
            guard !isListening else {
                recordHardwareSmokeState("failed iteration=\(iteration) reason=stop-incomplete", isError: true)
                return
            }
            recordHardwareSmokeState("stopped iteration=\(iteration)")
        }
        recordHardwareSmokeState("passed iterations=\(iterations)")
    }

    private func recordHardwareSmokeState(_ state: String, isError: Bool = false) {
        UserDefaults.standard.set(state, forKey: Self.hardwareSmokeStateKey)
        if isError {
            Self.hardwareSmokeLogger.error("OPENFISH_VOICE_SELF_TEST state=\(state, privacy: .public)")
        } else {
            Self.hardwareSmokeLogger.notice("OPENFISH_VOICE_SELF_TEST state=\(state, privacy: .public)")
        }
    }
#endif

    /// Once media services reset, touching the previous engine or input node
    /// can itself trip an unrecoverable RemoteIO assertion. Release that graph
    /// without messaging it and recreate everything on the next explicit tap.
    private func abandonListeningAfterMediaServicesReset() {
        captureGeneration += 1
        audioCapture?.abandonAfterMediaServicesReset()
        audioCapture = nil
        task?.cancel()
        request = nil
        task = nil
        handler = nil
        isListening = false
    }

    func speak(_ text: String, onFinished: (() -> Void)? = nil) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        stopListening()
        stopSpeaking()
        speechFinishedHandler = onFinished
        let utterance = AVSpeechUtterance(string: value)
        utterance.rate = effectiveSpeechRate
        let language = Locale.current.language.languageCode?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            language.map { code in voice.language.hasPrefix(code) } ?? true
        }
        utterance.voice = voices.first(where: { $0.identifier == preferredVoiceIdentifier })
            ?? voices.first(where: { $0.quality == .premium })
            ?? voices.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        speechFinishedHandler = nil
        isSpeaking = false
    }
}

extension MobileLocalVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            let finished = self.speechFinishedHandler
            self.speechFinishedHandler = nil
            finished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speechFinishedHandler = nil
            self?.isSpeaking = false
        }
    }
}
