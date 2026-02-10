import Foundation
import zlib

enum GzipError: Error {
    case compressionFailed
    case decompressionFailed
}

enum Gzip {
    static func compress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        var status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw GzipError.compressionFailed
        }

        var compressed = Data()
        let bufferSize = 16_384
        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw GzipError.compressionFailed
            }
            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                stream.next_out = outputBuffer.withUnsafeMutableBytes { rawBuffer in
                    rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                }
                stream.avail_out = uInt(bufferSize)

                status = deflate(&stream, Z_FINISH)
                if status != Z_OK && status != Z_STREAM_END {
                    throw GzipError.compressionFailed
                }

                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 {
                    compressed.append(outputBuffer, count: produced)
                }
            } while status == Z_OK
        }

        deflateEnd(&stream)

        guard status == Z_STREAM_END else {
            throw GzipError.compressionFailed
        }

        return compressed
    }

    static func decompress(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        var status = inflateInit2_(
            &stream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw GzipError.decompressionFailed
        }

        var decompressed = Data()
        let bufferSize = 16_384
        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw GzipError.decompressionFailed
            }
            stream.next_in = UnsafeMutablePointer(mutating: baseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                stream.next_out = outputBuffer.withUnsafeMutableBytes { rawBuffer in
                    rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                }
                stream.avail_out = uInt(bufferSize)

                status = inflate(&stream, Z_NO_FLUSH)
                if status != Z_OK && status != Z_STREAM_END {
                    throw GzipError.decompressionFailed
                }

                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 {
                    decompressed.append(outputBuffer, count: produced)
                }
            } while status == Z_OK
        }

        inflateEnd(&stream)

        guard status == Z_STREAM_END else {
            throw GzipError.decompressionFailed
        }

        return decompressed
    }
}
