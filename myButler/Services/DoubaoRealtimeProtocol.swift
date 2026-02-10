import Foundation

enum DoubaoMessageType: UInt8 {
    case clientFullRequest = 0b0001
    case clientAudioOnlyRequest = 0b0010
    case serverFullResponse = 0b1001
    case serverAck = 0b1011
    case serverError = 0b1111
}

enum DoubaoSerialization: UInt8 {
    case none = 0b0000
    case json = 0b0001
}

enum DoubaoCompression: UInt8 {
    case none = 0b0000
    case gzip = 0b0001
}

enum DoubaoMessageFlags {
    static let negSequence: UInt8 = 0b0010
    static let msgWithEvent: UInt8 = 0b0100
}

struct DoubaoResponse {
    let messageType: DoubaoMessageType
    let event: Int?
    let sessionId: String?
    let payload: Data
    let payloadJSON: [String: Any]?
}

enum DoubaoProtocolError: Error {
    case invalidMessage
    case unsupportedPayload
}

enum DoubaoRealtimeProtocol {
    static let protocolVersion: UInt8 = 0b0001
    static let defaultHeaderSize: UInt8 = 0b0001

    static func buildHeader(
        messageType: DoubaoMessageType,
        messageFlags: UInt8,
        serialization: DoubaoSerialization,
        compression: DoubaoCompression
    ) -> Data {
        var header = Data(capacity: 4)
        header.append((protocolVersion << 4) | defaultHeaderSize)
        header.append((messageType.rawValue << 4) | messageFlags)
        header.append((serialization.rawValue << 4) | compression.rawValue)
        header.append(0)
        return header
    }

    static func parseResponse(_ data: Data) throws -> DoubaoResponse {
        guard data.count >= 4 else {
            throw DoubaoProtocolError.invalidMessage
        }

        let headerSize = Int(data[0] & 0x0f)
        let messageTypeRaw = data[1] >> 4
        let messageFlags = data[1] & 0x0f
        let serializationRaw = data[2] >> 4
        let compressionRaw = data[2] & 0x0f

        guard let messageType = DoubaoMessageType(rawValue: messageTypeRaw) else {
            throw DoubaoProtocolError.invalidMessage
        }

        let serialization = DoubaoSerialization(rawValue: serializationRaw) ?? .none
        let compression = DoubaoCompression(rawValue: compressionRaw) ?? .none

        var index = headerSize * 4
        if data.count < index {
            throw DoubaoProtocolError.invalidMessage
        }

        var event: Int?
        if messageFlags & DoubaoMessageFlags.msgWithEvent > 0 {
            guard data.count >= index + 4 else { throw DoubaoProtocolError.invalidMessage }
            event = Int(readUInt32(data, offset: index))
            index += 4
        }

        var sessionId: String?
        if messageType == .serverFullResponse || messageType == .serverAck {
            guard data.count >= index + 4 else { throw DoubaoProtocolError.invalidMessage }
            let sessionIdSize = Int(readInt32(data, offset: index))
            index += 4
            if sessionIdSize > 0 {
                guard data.count >= index + sessionIdSize else { throw DoubaoProtocolError.invalidMessage }
                let sessionIdData = data.subdata(in: index..<(index + sessionIdSize))
                sessionId = String(data: sessionIdData, encoding: .utf8)
                index += sessionIdSize
            }

            guard data.count >= index + 4 else { throw DoubaoProtocolError.invalidMessage }
            let payloadSize = Int(readUInt32(data, offset: index))
            index += 4
            guard data.count >= index + payloadSize else { throw DoubaoProtocolError.invalidMessage }
            let payloadData = data.subdata(in: index..<(index + payloadSize))
            let decodedPayload = try decodePayload(payloadData, serialization: serialization, compression: compression)
            return DoubaoResponse(
                messageType: messageType,
                event: event,
                sessionId: sessionId,
                payload: decodedPayload.data,
                payloadJSON: decodedPayload.json
            )
        }

        if messageType == .serverError {
            guard data.count >= index + 8 else { throw DoubaoProtocolError.invalidMessage }
            let payloadSize = Int(readUInt32(data, offset: index + 4))
            index += 8
            guard data.count >= index + payloadSize else { throw DoubaoProtocolError.invalidMessage }
            let payloadData = data.subdata(in: index..<(index + payloadSize))
            let decodedPayload = try decodePayload(payloadData, serialization: serialization, compression: compression)
            return DoubaoResponse(
                messageType: messageType,
                event: event,
                sessionId: nil,
                payload: decodedPayload.data,
                payloadJSON: decodedPayload.json
            )
        }

        throw DoubaoProtocolError.unsupportedPayload
    }

    private static func decodePayload(
        _ payload: Data,
        serialization: DoubaoSerialization,
        compression: DoubaoCompression
    ) throws -> (data: Data, json: [String: Any]?) {
        let decompressed: Data
        switch compression {
        case .none:
            decompressed = payload
        case .gzip:
            decompressed = try Gzip.decompress(payload)
        }

        switch serialization {
        case .none:
            return (decompressed, nil)
        case .json:
            let json = try JSONSerialization.jsonObject(with: decompressed, options: [])
            return (decompressed, json as? [String: Any])
        }
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let slice = data.subdata(in: offset..<(offset + 4))
        return slice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    private static func readInt32(_ data: Data, offset: Int) -> Int32 {
        let slice = data.subdata(in: offset..<(offset + 4))
        return Int32(bitPattern: readUInt32(slice, offset: 0))
    }
}
