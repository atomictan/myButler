import Foundation

enum DoubaoRealtimeASRError: Error {
    case notConnected
    case invalidResponse
}

final class DoubaoRealtimeASRClient {
    private let apiKey: String
    private let apiSecret: String
    private let baseURL: URL
    private let sampleRate: Int
    private let channels: Int
    private let session: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    var onTranscript: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    init(
        apiKey: String,
        apiSecret: String,
        baseURL: URL = URL(string: "wss://voice-api.doubao.com/realtime/v1/transcribe")!,
        sampleRate: Int = 16_000,
        channels: Int = 1
    ) {
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.baseURL = baseURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.session = URLSession(configuration: .default)
    }

    func start() async throws {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "api_secret", value: apiSecret),
            URLQueryItem(name: "audio_format", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "channels", value: String(channels))
        ]
        guard let url = components?.url else {
            throw DoubaoRealtimeASRError.invalidResponse
        }

        let task = session.webSocketTask(with: url)
        task.resume()
        socketTask = task

        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func sendAudio(_ data: Data) async throws {
        guard let socketTask else { throw DoubaoRealtimeASRError.notConnected }
        let payload: [String: Any] = [
            "type": "audio_chunk",
            "data": data.base64EncodedString(),
            "is_end": false
        ]
        let message = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: message, as: UTF8.self)
        try await socketTask.send(.string(text))
    }

    func stop() async {
        guard let socketTask else { return }
        let payload: [String: Any] = [
            "type": "audio_chunk",
            "data": "",
            "is_end": true
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let text = String(decoding: data, as: UTF8.self)
            try? await socketTask.send(.string(text))
        }
        receiveTask?.cancel()
        socketTask.cancel(with: .normalClosure, reason: nil)
        receiveTask = nil
        self.socketTask = nil
    }

    private func receiveLoop() async {
        guard let socketTask else { return }
        do {
            while true {
                let message = try await socketTask.receive()
                let data: Data
                switch message {
                case .data(let messageData):
                    data = messageData
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                let type = json["type"] as? String
                if type == "transcript", let payload = json["data"] as? [String: Any] {
                    let transcript = payload["transcript"] as? String ?? ""
                    if !transcript.isEmpty {
                        onTranscript?(transcript)
                    }
                }
            }
        } catch {
            if Task.isCancelled { return }
            onError?(error)
        }
    }
}
