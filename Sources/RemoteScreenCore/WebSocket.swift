import CryptoKit
import Foundation

public enum WSOpcode: UInt8 {
    case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
}

public struct WSFrame: Equatable {
    public var fin: Bool
    public var opcode: WSOpcode
    public var payload: [UInt8]
}

public enum WSError: Error, Equatable {
    case unknownOpcode(UInt8)
    case payloadTooLarge(UInt64)
    case unmaskedClientFrame
    case invalidControlFrame
}

/// Minimal RFC 6455 framing for a server endpoint.
public enum WebSocketCodec {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    public static func handshakeResponse(clientKey: String) -> Data {
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey(for: clientKey))\r\n\r\n"
        return Data(head.utf8)
    }

    /// Encodes one frame. Servers send unmasked frames; `mask` exists for tests that emulate a client.
    public static func encode(_ opcode: WSOpcode, _ payload: [UInt8], fin: Bool = true, mask: [UInt8]? = nil) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(payload.count + 14)
        out.append((fin ? 0x80 : 0) | opcode.rawValue)
        let maskBit: UInt8 = mask == nil ? 0 : 0x80
        if payload.count < 126 {
            out.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(maskBit | 126)
            out.append(UInt8(payload.count >> 8))
            out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(maskBit | 127)
            let n = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((n >> UInt64(shift)) & 0xFF)) }
        }
        if let mask {
            out.append(contentsOf: mask)
            for (i, b) in payload.enumerated() { out.append(b ^ mask[i % 4]) }
        } else {
            out.append(contentsOf: payload)
        }
        return out
    }

    /// Decodes one frame from the front of `buffer`, consuming it. Returns nil when more bytes are needed.
    public static func decode(_ buffer: inout [UInt8], maxPayload: Int, requireMask: Bool = true) throws -> WSFrame? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[0], b1 = buffer[1]
        guard let opcode = WSOpcode(rawValue: b0 & 0x0F) else { throw WSError.unknownOpcode(b0 & 0x0F) }
        let fin = b0 & 0x80 != 0
        let masked = b1 & 0x80 != 0
        if requireMask && !masked { throw WSError.unmaskedClientFrame }
        var length = UInt64(b1 & 0x7F)
        var offset = 2
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            offset = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = 0
            for i in 2..<10 { length = length << 8 | UInt64(buffer[i]) }
            offset = 10
        }
        if opcode.rawValue >= 0x8 && (length > 125 || !fin) { throw WSError.invalidControlFrame }
        guard length <= UInt64(maxPayload) else { throw WSError.payloadTooLarge(length) }
        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<offset + 4])
            offset += 4
        }
        let total = offset + Int(length)
        guard buffer.count >= total else { return nil }
        var payload = Array(buffer[offset..<total])
        if masked { for i in payload.indices { payload[i] ^= maskKey[i % 4] } }
        buffer.removeFirst(total)
        return WSFrame(fin: fin, opcode: opcode, payload: payload)
    }
}

/// Reassembles fragmented data messages and surfaces control frames.
public struct WSMessageAssembler {
    public enum Event: Equatable {
        case text(String)
        case binary([UInt8])
        case ping([UInt8])
        case pong
        case close
    }

    private var partialOpcode: WSOpcode?
    private var partial: [UInt8] = []
    let maxMessage: Int

    public init(maxMessage: Int) { self.maxMessage = maxMessage }

    public mutating func accept(_ frame: WSFrame) throws -> Event? {
        switch frame.opcode {
        case .ping: return .ping(frame.payload)
        case .pong: return .pong
        case .close: return .close
        case .text, .binary:
            if frame.fin { return Self.finish(frame.opcode, frame.payload) }
            partialOpcode = frame.opcode
            partial = frame.payload
            return nil
        case .continuation:
            guard let op = partialOpcode else { throw WSError.invalidControlFrame }
            partial.append(contentsOf: frame.payload)
            if partial.count > maxMessage { throw WSError.payloadTooLarge(UInt64(partial.count)) }
            guard frame.fin else { return nil }
            let message = partial
            partialOpcode = nil
            partial = []
            return Self.finish(op, message)
        }
    }

    private static func finish(_ op: WSOpcode, _ bytes: [UInt8]) -> Event {
        op == .text ? .text(String(decoding: bytes, as: UTF8.self)) : .binary(bytes)
    }
}
