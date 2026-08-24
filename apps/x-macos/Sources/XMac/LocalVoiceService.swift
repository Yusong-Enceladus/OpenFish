@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

struct LocalVoiceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

private enum LocalAudioCaptureError: LocalizedError {
    case noInput
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .noInput:
            "No microphone input is available. Check the input device in System Settings."
        case .startupTimedOut:
            "The microphone did not respond. Dictation stopped safely; check the input device and try again."
        }
    }
}

/// AVAudioEngine can block synchronously while macOS reconnects an input device.
/// Keep every engine operation on one private queue so a broken audio service
/// cannot freeze SwiftUI's main actor or race a new start against an old stop.
private final class LocalAudioCapture: @unchecked Sendable {
    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let continuation: CheckedContinuation<Result<LocalAudioCapture, Error>, Never>

        init(_ continuation: CheckedContinuation<Result<LocalAudioCapture, Error>, Never>) {
            self.continuation = continuation
        }

        @discardableResult
        func finish(_ result: Result<LocalAudioCapture, Error>) -> Bool {
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

    private static let audioQueue = DispatchQueue(label: "app.openfish.voice.audio", qos: .userInitiated)

    private let engine: AVAudioEngine
    private let input: AVAudioInputNode
    // The input tap intentionally captures the box weakly so teardown cannot
    // form a retain cycle. The capture owns it for exactly the tap lifetime.
    private let requestBox: RequestBox

    private init(engine: AVAudioEngine, input: AVAudioInputNode, requestBox: RequestBox) {
        self.engine = engine
        self.input = input
        self.requestBox = requestBox
    }

    static func start(
        request: SFSpeechAudioBufferRecognitionRequest,
        timeout: Duration = .seconds(5)
    ) async -> Result<LocalAudioCapture, Error> {
        let requestBox = RequestBox(request)
        return await withCheckedContinuation { continuation in
            let gate = CompletionGate(continuation)
            audioQueue.async {
                var tappedInput: AVAudioInputNode?
                do {
                    let engine = AVAudioEngine()
                    let input = engine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else {
                        gate.finish(.failure(LocalAudioCaptureError.noInput))
                        return
                    }
                    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak requestBox] buffer, _ in
                        requestBox?.request.append(buffer)
                    }
                    tappedInput = input
                    engine.prepare()
                    try engine.start()
                    let capture = LocalAudioCapture(engine: engine, input: input, requestBox: requestBox)
                    if !gate.finish(.success(capture)) {
                        capture.stopImmediately()
                    }
                } catch {
                    tappedInput?.removeTap(onBus: 0)
                    gate.finish(.failure(error))
                }
            }

            let timeoutSeconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1_000_000_000_000_000_000
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) {
                gate.finish(.failure(LocalAudioCaptureError.startupTimedOut))
            }
        }
    }

    func stop() {
        Self.audioQueue.async { [self] in stopImmediately() }
    }

    private func stopImmediately() {
        if engine.isRunning { engine.stop() }
        input.removeTap(onBus: 0)
    }
}

/// Native, local-only voice provider for the OpenCodex surface.
///
/// Recognition refuses to start unless the current Apple recognizer advertises
/// on-device support. Audio never reaches the Host or Harness; only finalized
/// text is submitted after the user confirms it.
@MainActor
final class LocalVoiceService: NSObject, ObservableObject {
    let providerID = "apple-local"
    let providerName = "Apple On-Device Speech"
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var partialTranscript = ""
    @Published private(set) var errorMessage: String?
    @Published var preferredVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(preferredVoiceIdentifier, forKey: "OpenCodex.voice.identifier") }
    }
    @Published var speechRate: Float {
        didSet {
            UserDefaults.standard.set(Double(effectiveSpeechRate), forKey: "OpenCodex.voice.rate")
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var audioCapture: LocalAudioCapture?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptHandler: ((String, Bool) -> Void)?
    private var speechFinishedHandler: (() -> Void)?
    private var audioObservers: [NSObjectProtocol] = []
    private var captureGeneration = 0

    private var effectiveSpeechRate: Float { min(max(speechRate, 0.35), 0.62) }

    override init() {
        preferredVoiceIdentifier = UserDefaults.standard.string(forKey: "OpenCodex.voice.identifier") ?? ""
        let storedRate = UserDefaults.standard.double(forKey: "OpenCodex.voice.rate")
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
        audioObservers = [Notification.Name.AVAudioEngineConfigurationChange].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isListening else { return }
                    self.errorMessage = "The microphone configuration changed. Dictation stopped safely; tap the microphone to resume."
                    self.stopListening()
                }
            }
        }
    }

    var availableVoices: [LocalVoiceChoice] {
        let language = Locale.current.language.languageCode?.identifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in language.map { voice.language.hasPrefix($0) } ?? true }
            .map { voice in
                let quality = voice.quality == .premium ? "Premium"
                    : voice.quality == .enhanced ? "Enhanced" : "Standard"
                return LocalVoiceChoice(id: voice.identifier, name: voice.name, language: voice.language, quality: quality)
            }
            .sorted { left, right in
                if left.quality != right.quality {
                    let rank = ["Premium": 0, "Enhanced": 1, "Standard": 2]
                    return rank[left.quality, default: 3] < rank[right.quality, default: 3]
                }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    func toggleListening(onTranscript: @escaping (String, Bool) -> Void) async {
        if isStarting {
            stopListening()
            return
        }
        if isListening {
            stopListening()
            return
        }
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
        let speechAuthorization = await Self.requestSpeechAuthorization()
        guard generation == captureGeneration else { return }
        guard speechAuthorization == .authorized else {
            errorMessage = "Speech recognition permission is required for local dictation."
            return
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == captureGeneration else { return }
        guard microphoneAllowed else {
            errorMessage = "Microphone permission is required for local dictation."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            errorMessage = "The local speech recognizer is unavailable for this language."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device speech recognition is not installed for this language."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        recognitionRequest = request
        transcriptHandler = onTranscript
        partialTranscript = ""

        switch await LocalAudioCapture.start(request: request) {
        case .failure(let error):
            recognitionRequest = nil
            transcriptHandler = nil
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        case .success(let capture):
            guard generation == captureGeneration else {
                capture.stop()
                recognitionRequest = nil
                transcriptHandler = nil
                return
            }
            audioCapture = capture
        }

        isListening = true
        recognitionTask = Self.makeRecognitionTask(recognizer: recognizer, request: request, service: self)
    }

    nonisolated private static func makeRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        service: LocalVoiceService
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { [weak service] result, error in
            let update = result.map { ($0.bestTranscription.formattedString, $0.isFinal) }
            let failure = error?.localizedDescription
            Task { @MainActor [weak service] in
                guard let self = service else { return }
                guard self.recognitionTask != nil else { return }
                if let update {
                    let (text, isFinal) = update
                    self.partialTranscript = text
                    self.transcriptHandler?(text, isFinal)
                    if isFinal { self.stopListening() }
                } else if let failure {
                    self.errorMessage = failure
                    self.stopListening()
                }
            }
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                // TCC may invoke this callback on a background queue. Keep the
                // callback nonisolated; the suspended caller resumes on MainActor.
                continuation.resume(returning: status)
            }
        }
    }

    func stopListening() {
        captureGeneration += 1
        guard isListening || recognitionRequest != nil || recognitionTask != nil else { return }
        audioCapture?.stop()
        audioCapture = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        transcriptHandler = nil
        isListening = false
    }

    func speak(_ text: String, onFinished: (() -> Void)? = nil) {
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }
        stopSpeaking()
        speechFinishedHandler = onFinished
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.rate = effectiveSpeechRate
        utterance.pitchMultiplier = 1
        let language = Locale.current.language.languageCode?.identifier
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            language.map { voice.language.hasPrefix($0) } ?? true
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

extension LocalVoiceService: AVSpeechSynthesizerDelegate {
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
