import AppKit
import AVFoundation
import Speech

/// Hold-to-talk, on-device only. Release finalizes one turn; cancellation invalidates late callbacks.
final class CompanionVoice {
    var onState: ((String, String) -> Void)?
    var onText: ((String, String) -> Void)?
    var onFinal: ((String, String) -> Void)?
    var onError: ((String, String) -> Void)?
    private var captureID: String?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var finalize: DispatchWorkItem?, limit: DispatchWorkItem?
    private var generation = 0, transcript = ""
    private var held = false, tapped = false, finishing = false, authorizing = false
    private let speaker = AVSpeechSynthesizer()
    private lazy var selectedVoice = Self.preferredVoice()
    var active: Bool { held || finishing || authorizing }

    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = Locale.preferredLanguages.first ?? "en-US"
        let fallback = AVSpeechSynthesisVoice(language: language)
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isPersonalVoice) }.sorted {
            if $0.identifier == $1.identifier { return false }
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            if $0.identifier == fallback?.identifier { return true }
            if $1.identifier == fallback?.identifier { return false }
            return $0.identifier < $1.identifier
        }.first ?? fallback
    }

    func speak(_ text: String, enqueue: Bool = false) {
        if !enqueue { speaker.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: String(text.prefix(8000)))
        utterance.voice = selectedVoice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speaker.speak(utterance)
    }
    func silence() { speaker.stopSpeaking(at: .immediate) }

    func start(captureID: String) {
        guard !captureID.isEmpty, captureID.utf16.count <= 128 else { return }
        cancel(); silence(); self.captureID = captureID
        held = true; authorizing = true; transcript = ""; let turn = generation
        onState?(captureID, "permission")
        func microphone() {
            guard self.generation == turn else { return }
            AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async {
                guard self.generation == turn else { return }
                if allowed {
                    self.authorizing = false
                    if self.held { self.listen(turn) } else { self.cancel(); self.onState?(captureID, "ready") }
                } else { self.fail("Enable Microphone access for Andy Barista in System Settings.") }
            } }
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: microphone()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in DispatchQueue.main.async {
                guard self.generation == turn else { return }
                if status == .authorized { microphone() } else { self.fail("Enable Speech Recognition for Andy Barista in System Settings.") }
            } }
        default: fail("Enable Speech Recognition for Andy Barista in System Settings.")
        }
    }

    private func listen(_ turn: Int) {
        guard let captureID = captureID else { return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            fail("On-device speech is unavailable for this language. Enable its dictation language in Keyboard settings, then try again."); return
        }
        recognizer.queue = .main; self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.taskHint = .dictation; request.contextualStrings = ["Andy", "Barista"]
        self.request = request
        let engine = AVAudioEngine(), input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { fail("No microphone is available. Choose an input device in Sound settings."); return }
        self.engine = engine
        // Keep the pre-macOS 27 overload so the source also builds with older supported SDKs.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; tapped = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, self.generation == turn else { return }
            if let result = result {
                self.transcript = result.bestTranscription.formattedString; self.onText?(captureID, self.transcript)
                if result.isFinal && !self.held { self.complete(); return }
            }
            if let error = error, !self.finishing { self.fail("Speech stopped: \(error.localizedDescription)") }
        }
        do { engine.prepare(); try engine.start() }
        catch { fail("Cannot start the microphone: \(error.localizedDescription)"); return }
        onState?(captureID, "listening")
        let stop = DispatchWorkItem { [weak self] in self?.finish() }; limit = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: stop)
    }

    func finish() {
        guard held, let captureID = captureID else { return }
        guard engine != nil else { held = false; if !authorizing { cancel() }; return }
        held = false; finishing = true; stopAudio(); onState?(captureID, "finishing")
        let turn = generation
        let done = DispatchWorkItem { [weak self] in guard let self = self, self.generation == turn else { return }; self.complete() }
        finalize = done; DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
        request?.endAudio()
    }
    private func complete() {
        guard let captureID = captureID else { return }
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        if words.isEmpty { onError?(captureID, "I did not catch that. Start voice and speak again.") }
        else { onFinal?(captureID, words) }
    }
    private func stopAudio() {
        engine?.stop(); if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
    }
    func cancel() {
        let wasActive = active, id = captureID
        generation += 1; captureID = nil; held = false; finishing = false; authorizing = false; limit?.cancel(); finalize?.cancel()
        stopAudio(); task?.cancel(); task = nil; request = nil; recognizer = nil; engine = nil
        if wasActive, let id = id { onState?(id, "idle") }
    }
    private func fail(_ message: String) {
        let id = captureID; cancel()
        if let id = id { onError?(id, message) }
    }
}
