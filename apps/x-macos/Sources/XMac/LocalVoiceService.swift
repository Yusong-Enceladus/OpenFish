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
        let speechAuthorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
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
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
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
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.recognitionTask != nil else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    self.transcriptHandler?(text, result.isFinal)
                    if result.isFinal { self.stopListening() }
                } else if let error {
                    self.errorMessage = error.localizedDescription
                    self.stopListening()
                }
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
