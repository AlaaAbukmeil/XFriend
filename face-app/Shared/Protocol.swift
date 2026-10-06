import Foundation

/// Face <-> brain wire protocol. Mirrors brain/protocol.py; see docs/protocol.md.
/// Frame: [u8 type][u32 big-endian length][payload]
enum MsgType: UInt8 {
    case hello = 0x01
    case micAudio = 0x02
    case touch = 0x03
    case cameraFrame = 0x04
    case ttsAudio = 0x10
    case mood = 0x11
    case state = 0x12
    case stop = 0x13
    case requestFrame = 0x14
}

enum ProtocolConstants {
    static let headerSize = 5
    static let maxPayload = 4 * 1024 * 1024
    static let micSampleRate = 16_000.0
    static let ttsSampleRate = 24_000.0
    static let micChunkBytes = 640  // 20 ms of 16 kHz Int16 mono
}

struct ProtocolError: Error {
    let message: String
}

struct Frame {
    let rawType: UInt8
    let payload: Data

    var type: MsgType? { MsgType(rawValue: rawType) }

    func json() -> [String: Any] {
        guard !payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return [:] }
        return obj
    }

    static func encode(_ type: MsgType, _ payload: Data = Data()) -> Data {
        var out = Data(capacity: ProtocolConstants.headerSize + payload.count)
        out.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func encodeJSON(_ type: MsgType, _ obj: [String: Any]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return encode(type, payload)
    }
}

/// Incremental decoder for TCP byte streams that arrive in arbitrary chunks.
struct FrameDecoder {
    private var buffer = Data()

    mutating func feed(_ data: Data) throws -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        while buffer.count >= ProtocolConstants.headerSize {
            let s = buffer.startIndex
            let type = buffer[s]
            let length = Int(buffer[s + 1]) << 24 | Int(buffer[s + 2]) << 16 | Int(buffer[s + 3]) << 8 | Int(buffer[s + 4])
            guard length <= ProtocolConstants.maxPayload else {
                throw ProtocolError(message: "payload too large: \(length)")
            }
            let end = s + ProtocolConstants.headerSize + length
            guard buffer.endIndex >= end else { break }
            frames.append(Frame(rawType: type, payload: buffer.subdata(in: (s + ProtocolConstants.headerSize)..<end)))
            buffer = buffer.subdata(in: end..<buffer.endIndex)
        }
        return frames
    }
}
