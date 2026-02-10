import Foundation

struct DoubaoRealtimeConfig {
    let baseURL: URL
    let headers: [String: String]
}

enum DoubaoRealtimeClientError: Error {
    case notConnected
    case invalidResponse
}

final class DoubaoRealtimeClient {
    private let config: DoubaoRealtimeConfig
    private let sessionId: String
    private let urlSession: URLSession
    private var socketTask: URLSessionWebSocketTask?
    private var delegate: DoubaoRealtimeWebSocketDelegate?

    init(config: DoubaoRealtimeConfig, sessionId: String = UUID().uuidString) {
        self.config = config
        self.sessionId = sessionId
        self.urlSession = URLSession(configuration: .default)
    }

    func connect() async throws {
        var request = URLRequest(url: config.baseURL)
        config.headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        print("[DoubaoRealtime] Connecting to \(config.baseURL.absoluteString)")

        let delegate = DoubaoRealtimeWebSocketDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        socketTask = socket
        self.delegate = delegate

        try await withTimeout(seconds: 10) {
            print("[DoubaoRealtime] Sending StartConnection")
            try await self.sendStartConnection()
            let response = try await self.receiveResponse()
            print("[DoubaoRealtime] StartConnection response: \(response.messageType)")
        }
    }

    func startSession(requestPayload: [String: Any]) async throws {
        let payload = try encodeJSONPayload(requestPayload)
        print("[DoubaoRealtime] Sending StartSession")
        try await sendRequest(event: 100, payload: payload, includeSession: true)
        let response = try await receiveResponse()
        print("[DoubaoRealtime] StartSession response: \(response.messageType)")
    }

    func sendTextQuery(_ text: String) async throws {
        print("[DoubaoRealtime] Sending text query (\(text.count) chars)")
        let payload = try encodeJSONPayload(["content": text])
        try await sendRequest(event: 501, payload: payload, includeSession: true)
    }

    func sendAudioChunk(_ audioData: Data) async throws {
        guard let socketTask else {
            throw DoubaoRealtimeClientError.notConnected
        }
        if audioData.isEmpty {
            return
        }
        let payload = try Gzip.compress(audioData)
        let header = DoubaoRealtimeProtocol.buildHeader(
            messageType: .clientAudioOnlyRequest,
            messageFlags: DoubaoMessageFlags.msgWithEvent,
            serialization: .none,
            compression: .gzip
        )
        var message = Data()
        message.append(header)
        message.append(contentsOf: eventBytes(200))
        message.append(contentsOf: sessionBytes())
        message.append(contentsOf: uint32Bytes(UInt32(payload.count)))
        message.append(payload)

        try await socketTask.send(.data(message))
    }

    func finishSession() async throws {
        print("[DoubaoRealtime] Sending FinishSession")
        let payload = try encodeJSONPayload([:])
        try await sendRequest(event: 102, payload: payload, includeSession: true)
    }

    func finishConnection() async throws {
        print("[DoubaoRealtime] Sending FinishConnection")
        let payload = try encodeJSONPayload([:])
        try await sendRequest(event: 2, payload: payload, includeSession: false)
        _ = try await receiveResponse()
    }

    func close() async {
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketTask = nil
    }

    func receiveResponse() async throws -> DoubaoResponse {
        guard let socketTask else {
            throw DoubaoRealtimeClientError.notConnected
        }
        let message = try await withTimeout(seconds: 10) {
            try await socketTask.receive()
        }
        switch message {
        case .data(let data):
            let response = try DoubaoRealtimeProtocol.parseResponse(data)
            if response.messageType == .serverAck {
                return response
            }
            print("[DoubaoRealtime] Received message: \(response.messageType), event: \(response.event ?? -1)")
            return response
        case .string:
            throw DoubaoRealtimeClientError.invalidResponse
        @unknown default:
            throw DoubaoRealtimeClientError.invalidResponse
        }
    }

    private func sendStartConnection() async throws {
        let payload = try encodeJSONPayload([:])
        try await sendRequest(event: 1, payload: payload, includeSession: false)
    }

    private func sendRequest(event: Int, payload: Data, includeSession: Bool) async throws {
        guard let socketTask else {
            throw DoubaoRealtimeClientError.notConnected
        }
        let header = DoubaoRealtimeProtocol.buildHeader(
            messageType: .clientFullRequest,
            messageFlags: DoubaoMessageFlags.msgWithEvent,
            serialization: .json,
            compression: .gzip
        )
        var message = Data()
        message.append(header)
        message.append(contentsOf: eventBytes(event))
        if includeSession {
            message.append(contentsOf: sessionBytes())
        }
        message.append(contentsOf: uint32Bytes(UInt32(payload.count)))
        message.append(payload)

        try await socketTask.send(.data(message))
    }

    private func encodeJSONPayload(_ payload: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try Gzip.compress(data)
    }

    private func sessionBytes() -> Data {
        var data = Data()
        let sessionData = Data(sessionId.utf8)
        data.append(contentsOf: uint32Bytes(UInt32(sessionData.count)))
        data.append(sessionData)
        return data
    }

    private func eventBytes(_ value: Int) -> [UInt8] {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Array($0) }
    }

    private func uint32Bytes(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                print("[DoubaoRealtime] Timeout after \(seconds)s")
                throw DoubaoRealtimeClientError.invalidResponse
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

final class DoubaoRealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("Doubao realtime websocket opened")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        print("Doubao realtime websocket closed: \(closeCode) \(reasonText)")
    }
}
