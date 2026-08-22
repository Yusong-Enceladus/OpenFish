@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

struct LocalVoiceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

/// Native, local-only voice provider for the OpenCodex surface.
///
/// Recognition refuses to start unless the current Apple recognizer advertises
/// on-device support. No audio or transcript is sent through DSH or a cloud API.
@MainActor
final class LocalVoiceService: NSObject, ObservableObject {
    let providerID = "apple-local"
    let providerName = "Apple On-Device Speech"
    @Published private(set) var isListening = false
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

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptHandler: ((String, Bool) -> Void)?
    private var speechFinishedHandler: (() -> Void)?

    private var effectiveSpeechRate: Float { min(max(speechRate, 0.35), 0.62) }

    override init() {
        preferredVoiceIdentifier = UserDefaults.standard.string(forKey: "OpenCodex.voice.identifier") ?? ""
        let storedRate = UserDefaults.standard.double(forKey: "OpenCodex.voice.rate")
        speechRate = storedRate == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(storedRate)
        super.init()
        synthesizer.delegate = self
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
        if isListening {
            stopListening()
            return
        }
        await startListening(onTranscript: onTranscript)
    }

    func startListening(onTranscript: @escaping (String, Bool) -> Void) async {
        stopSpeaking()
        stopListening()
        errorMessage = nil
        let speechAuthorization = await Self.requestSpeechAuthorization()
        guard speechAuthorization == .authorized else {
            errorMessage = "Speech recognition permission is required for local dictation."
            return
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
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

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            recognitionRequest = nil
            transcriptHandler = nil
            errorMessage = "No microphone input is available. Check the input device in System Settings."
            return
        }
        input.removeTap(onBus: 0)
        Self.installInputTap(on: input, format: format, request: request)
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            recognitionRequest = nil
            transcriptHandler = nil
            errorMessage = "Could not start the microphone: \(error.localizedDescription)"
            return
        }

        isListening = true
        recognitionTask = Self.makeRecognitionTask(recognizer: recognizer, request: request, service: self)
    }

    nonisolated private static func installInputTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
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
        guard isListening || recognitionRequest != nil || recognitionTask != nil else { return }
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
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
