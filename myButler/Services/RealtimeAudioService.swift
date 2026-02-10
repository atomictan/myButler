import AVFoundation
import Speech

@MainActor
final class RealtimeAudioService {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let speechRecognizer = SFSpeechRecognizer()
    private var inputFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var isConfigured = false
    private let minSignalThreshold: Int16 = 0
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechAuthorized = false
    private var transcriptionHandler: ((String) -> Void)?

    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func requestSpeechPermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        speechAuthorized = granted
        return granted
    }

    func startCapture(onAudio: @escaping (Data) -> Void, onTranscription: ((String) -> Void)? = nil) throws {
        try configureAudioSession()
        configurePlaybackIfNeeded()
        transcriptionHandler = onTranscription
        startSpeechRecognitionIfNeeded()

        let inputNode = engine.inputNode
        if #available(iOS 13.0, *) {
            try? inputNode.setVoiceProcessingEnabled(true)
        }
        let inputNodeFormat = inputNode.outputFormat(forBus: 0)
        let targetInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )

        inputFormat = inputNodeFormat
        captureFormat = targetInputFormat
        converter = AVAudioConverter(from: inputNodeFormat, to: targetInputFormat!)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNodeFormat) { [weak self] buffer, _ in
            guard let self, let converter, let captureFormat else { return }
            self.recognitionRequest?.append(buffer)

            let frameCapacity = AVAudioFrameCount(captureFormat.sampleRate / 10)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frameCapacity) else {
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let data = self.dataFromPCMBuffer(convertedBuffer) {
                onAudio(data)
            }
        }

        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }
    }

    func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        stopSpeechRecognition()
    }

    func startPlayback() {
        configurePlaybackIfNeeded()
        if !engine.isRunning {
            try? engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    func stopPlayback() {
        playerNode.stop()
    }

    func stopAll() {
        stopCapture()
        stopPlayback()
        engine.stop()
        isConfigured = false
    }

    func playAudioChunk(_ data: Data) {
        guard let playbackFormat else { return }
        guard let buffer = pcmBuffer(from: data, format: playbackFormat) else { return }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func configureAudioSession() throws {
        let useSpeaker = UserDefaults.standard.object(forKey: "voiceSessionUseSpeaker") as? Bool ?? true
        try updateOutputRouting(useSpeaker: useSpeaker)
    }

    func updateOutputRouting(useSpeaker: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.duckOthers, .allowBluetoothHFP]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }
        let mode: AVAudioSession.Mode = useSpeaker ? .videoChat : .voiceChat
        try session.setCategory(
            .playAndRecord,
            mode: mode,
            options: options
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if useSpeaker {
            let outputs = session.currentRoute.outputs
            let hasBluetooth = outputs.contains { output in
                output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP || output.portType == .bluetoothLE
            }
            if !hasBluetooth {
                try session.overrideOutputAudioPort(.speaker)
            }
        } else {
            try session.overrideOutputAudioPort(.none)
        }
    }

    private func startSpeechRecognitionIfNeeded() {
        guard speechAuthorized else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if error != nil {
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            if !text.isEmpty {
                self.transcriptionHandler?(text)
            }
        }
    }

    private func stopSpeechRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        transcriptionHandler = nil
    }

    private func configurePlaybackIfNeeded() {
        guard !isConfigured else { return }
        if engine.attachedNodes.contains(playerNode) == false {
            engine.attach(playerNode)
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )
        playbackFormat = format
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        isConfigured = true
    }

    private func dataFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let channelDataValue = channelData.pointee
        let sampleCount = Int(buffer.frameLength)
        var maxSample: Int16 = 0
        for index in 0..<sampleCount {
            let value = channelDataValue[index]
            let absValue = value == Int16.min ? Int16.max : abs(value)
            if absValue > maxSample {
                maxSample = absValue
            }
        }
        if minSignalThreshold > 0, maxSample < minSignalThreshold {
            return nil
        }
        let data = Data(bytes: channelDataValue, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        return data
    }

    private func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frameCapacity = AVAudioFrameCount(data.count / bytesPerFrame)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        buffer.frameLength = frameCapacity

        if format.commonFormat == .pcmFormatInt16, let channelData = buffer.int16ChannelData {
            let sampleCount = Int(frameCapacity)
            let byteCount = min(data.count, sampleCount * MemoryLayout<Int16>.size)
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                channelData.pointee.update(from: baseAddress.assumingMemoryBound(to: Int16.self), count: byteCount / MemoryLayout<Int16>.size)
            }
        } else if format.commonFormat == .pcmFormatFloat32, let channelData = buffer.floatChannelData {
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                channelData.pointee.update(from: baseAddress.assumingMemoryBound(to: Float.self), count: Int(frameCapacity))
            }
        }

        return buffer
    }
}
