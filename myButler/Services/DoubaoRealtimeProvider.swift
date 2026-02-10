import Foundation

struct DoubaoRealtimeSessionConfiguration {
    let connectConfig: DoubaoRealtimeConfig
    let startSessionRequest: [String: Any]
}

final class DoubaoRealtimeProvider: RealtimeSessionProvider {
    private let configuration: DoubaoRealtimeSessionConfiguration
    private let client: DoubaoRealtimeClient
    private var receiveTask: Task<Void, Never>?
    private let eventStream: AsyncStream<RealtimeSessionEvent>
    private let eventContinuation: AsyncStream<RealtimeSessionEvent>.Continuation

    var events: AsyncStream<RealtimeSessionEvent> {
        eventStream
    }

    init(configuration: DoubaoRealtimeSessionConfiguration) {
        self.configuration = configuration
        self.client = DoubaoRealtimeClient(config: configuration.connectConfig)

        var continuation: AsyncStream<RealtimeSessionEvent>.Continuation!
        self.eventStream = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation
    }

    func startSession() async throws {
        try await client.connect()
        emit(.connected)
        try await client.startSession(requestPayload: configuration.startSessionRequest)
        startReceiving()
    }

    func stopSession() async {
        receiveTask?.cancel()
        receiveTask = nil
        try? await client.finishSession()
        try? await client.finishConnection()
        await client.close()
        emit(.disconnected)
    }

    func sendAudio(_ data: Data) async throws {
        try await client.sendAudioChunk(data)
    }

    func sendText(_ text: String) async throws {
        try await client.sendTextQuery(text)
    }

    private func startReceiving() {
        receiveTask?.cancel()
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let response = try await client.receiveResponse()
                    handle(response)
                } catch is CancellationError {
                    break
                } catch DoubaoRealtimeClientError.invalidResponse {
                    continue
                } catch {
                    emit(.error(error.localizedDescription))
                    break
                }
            }
        }
    }

    private func handle(_ response: DoubaoResponse) {
        if response.messageType == .serverAck, !response.payload.isEmpty {
            emit(.audio(response.payload))
            return
        }

        if let payload = response.payloadJSON {
            print("[DoubaoRealtime] Payload: \(payload)")
            if let content = payload["content"] as? String {
                emit(.text(content))
            }
            emit(.payload(payload))
        }
    }

    private func emit(_ event: RealtimeSessionEvent) {
        eventContinuation.yield(event)
    }
}
