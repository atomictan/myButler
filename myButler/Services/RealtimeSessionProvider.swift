import Foundation

enum RealtimeSessionEvent {
    case connected
    case disconnected
    case audio(Data)
    case text(String)
    case payload([String: Any])
    case error(String)
}

protocol RealtimeSessionProvider {
    var events: AsyncStream<RealtimeSessionEvent> { get }

    func startSession() async throws
    func stopSession() async
    func sendAudio(_ data: Data) async throws
    func sendText(_ text: String) async throws
}
