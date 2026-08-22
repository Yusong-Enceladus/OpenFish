@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

struct MobileVoiceChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

@MainActor
final class MobileLocalVoice: NSObject, ObservableObject {
    let providerID = "apple-local"
    let providerName = "Apple On-Device Speech"
    @Published private(set) var isListening = false
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

    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var handler: ((String, Bool) -> Void)?
    private var speechFinishedHandler: (() -> Void)?
    private var hasInputTap = false

    private var effectiveSpeechRate: Float { min(max(speechRate, 0.35), 0.62) }

    override init() {
        preferredVoiceIdentifier = UserDefaults.standard.string(forKey: "OpenCodex.iPhone.voice.identifier") ?? ""
        let storedRate = UserDefaults.standard.double(forKey: "OpenCodex.iPhone.voice.rate")
        speechRate = storedRate == 0 ? AVSpeechUtteranceDefaultSpeechRate : Float(storedRate)
        super.init()
        synthesizer.delegate = self
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
        if isListening { stopListening(); return }
        await startListening(onTranscript: onTranscript)
    }

    func startListening(onTranscript: @escaping (String, Bool) -> Void) async {
        stopSpeaking()
        stopListening()
        errorMessage = nil
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else {
            errorMessage = "Speech permission is required."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone permission is required."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            errorMessage = "Install on-device speech recognition for this language in iPhone Settings."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            request.taskHint = .dictation
            self.request = request
            handler = onTranscript
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            hasInputTap = true
            engine.prepare()
            try engine.start()
            isListening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.task != nil else { return }
                    if let result {
                        self.handler?(result.bestTranscription.formattedString, result.isFinal)
                        if result.isFinal { self.stopListening() }
                    } else if let error {
                        self.errorMessage = error.localizedDescription
                        self.stopListening()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            stopListening()
        }
    }

    func stopListening() {
        if engine.isRunning { engine.stop() }
        if hasInputTap {
            engine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        handler = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
