import AVFoundation
import Combine
import Speech

@MainActor
final class VoiceCaptureService: ObservableObject {
    // High-level state for the capture workflow.
    enum CaptureState: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    // Current capture state for the UI.
    @Published private(set) var state: CaptureState = .idle
    // Live transcript from the speech recognizer.
    @Published private(set) var transcript = ""
    // Whether the user granted microphone + speech permissions.
    @Published private(set) var isAuthorized = false

    private let speechRecognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Requests the required permissions for speech recognition + microphone.
    func requestPermissions() async {
        let speechGranted = await requestSpeechAuthorization()
        let micGranted = await requestMicrophoneAuthorization()
        isAuthorized = speechGranted && micGranted
        if !isAuthorized {
            state = .failed("Microphone or speech permissions denied.")
        }
    }

    // Starts streaming microphone audio into the speech recognizer.
    func startRecording() {
        guard isAuthorized else {
            state = .failed("Permissions not granted.")
            return
        }
        guard state != .recording else { return }

        resetCapture()
        transcript = ""

        do {
            try configureAudioSession()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            state = .recording
            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }

                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.state = .idle
                    }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // Stops recording and asks the recognizer to finish transcription.
    func stopRecording() {
        guard state == .recording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        state = .transcribing
    }

    // Clears any running audio tasks before starting again.
    private func resetCapture() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // Configures the audio session for speech capture.
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // Wraps the speech authorization callback in async/await.
    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // Wraps the microphone permission callback in async/await.
    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
