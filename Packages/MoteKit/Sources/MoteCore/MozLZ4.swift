import Compression
import Foundation

/// Firefox's compressed JSON files (`.jsonlz4`, `.mozlz4`, `.baklz4`): the
/// magic `mozLz40\0`, the decompressed size as a 32-bit little-endian
/// number, then a single raw LZ4 block.
public enum MozLZ4 {
    public enum Failure: Error, Equatable {
        /// Not one of these files.
        case notMozLZ4
        /// The block doesn't decompress to the size the header gives.
        case corrupt
    }

    private static let magic = Data("mozLz40\0".utf8)
    /// More than any session file; a header saying more is damaged.
    private static let largest = 512 << 20

    public static func decode(_ file: Data) throws -> Data {
        let file = Data(file)
        guard file.count >= 12, file.prefix(8) == magic else { throw Failure.notMozLZ4 }
        let size = file[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard size > 0, size <= largest else { throw Failure.corrupt }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { target in
            file.withUnsafeBytes { source in
                compression_decode_buffer(
                    target.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress! + 12, file.count - 12, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == size else { throw Failure.corrupt }
        return out
    }

    /// The same format, for tests and fixtures: one LZ4 sequence of nothing
    /// but literals, which any LZ4 reader takes. Apple's encoder gives up on
    /// some small inputs, and fixtures don't need to be small.
    public static func encode(_ data: Data) -> Data {
        var block = Data()
        let count = data.count
        // The literal length: 15 in the token, then 255s and the rest.
        block.append(UInt8(min(count, 15) << 4))
        if count >= 15 {
            var rest = count - 15
            while rest >= 255 {
                block.append(255)
                rest -= 255
            }
            block.append(UInt8(rest))
        }
        block.append(Data(data))
        let size = UInt32(count)
        return magic + Data((0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) }) + block
    }
}
