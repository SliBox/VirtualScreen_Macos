//
//  WebSocketFrame.swift
//  VirtualDisplayKit
//
//  Minimal RFC 6455 framing used by the built-in browser stream server.
//  Kept dependency-free so the kit stays self-contained.
//

import CryptoKit
import Foundation

/// WebSocket opcodes (RFC 6455 §5.2)
enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

/// A decoded WebSocket frame
struct WebSocketFrame {
    let opcode: WebSocketOpcode
    let payload: Data
    let isFinal: Bool
}

enum WebSocketError: Error {
    case protocolViolation
    case payloadTooLarge
}

// MARK: - Encoding

enum WebSocketEncoder {

    /// Builds the frame header for a server-to-client frame.
    ///
    /// Server frames are never masked, so the header and the payload can be
    /// written as two separate (batched) sends — this avoids copying every
    /// JPEG frame just to prepend 2-10 bytes.
    static func header(opcode: WebSocketOpcode, payloadLength: Int, isFinal: Bool = true) -> Data {
        var header = Data()
        header.reserveCapacity(10)
        header.append((isFinal ? 0x80 : 0x00) | opcode.rawValue)

        if payloadLength < 126 {
            header.append(UInt8(payloadLength))
        } else if payloadLength <= 0xFFFF {
            header.append(126)
            header.append(UInt8((payloadLength >> 8) & 0xFF))
            header.append(UInt8(payloadLength & 0xFF))
        } else {
            header.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((payloadLength >> shift) & 0xFF))
            }
        }

        return header
    }

    /// Builds a complete (header + payload) frame. Use for small control frames.
    static func frame(opcode: WebSocketOpcode, payload: Data, isFinal: Bool = true) -> Data {
        var data = header(opcode: opcode, payloadLength: payload.count, isFinal: isFinal)
        data.append(payload)
        return data
    }

    static func textFrame(_ string: String) -> Data {
        frame(opcode: .text, payload: Data(string.utf8))
    }
}

// MARK: - Decoding

/// Incremental frame decoder for client-to-server traffic.
///
/// Clients only ever send tiny control/ack messages to us, so the buffer stays
/// small and the extra copy on consume is irrelevant.
struct WebSocketFrameDecoder {

    private var buffer = Data()
    private let maxPayloadSize: Int

    init(maxPayloadSize: Int = 1 << 20) {
        self.maxPayloadSize = maxPayloadSize
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete frame, or `nil` when more bytes are needed.
    mutating func next() throws -> WebSocketFrame? {
        let base = buffer.startIndex
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[base]
        let byte1 = buffer[base + 1]

        let isFinal = (byte0 & 0x80) != 0
        guard let opcode = WebSocketOpcode(rawValue: byte0 & 0x0F) else {
            throw WebSocketError.protocolViolation
        }

        let isMasked = (byte1 & 0x80) != 0
        var payloadLength = Int(byte1 & 0x7F)
        var cursor = 2

        if payloadLength == 126 {
            guard buffer.count >= cursor + 2 else { return nil }
            payloadLength = Int(buffer[base + cursor]) << 8 | Int(buffer[base + cursor + 1])
            cursor += 2
        } else if payloadLength == 127 {
            guard buffer.count >= cursor + 8 else { return nil }
            var value = 0
            for offset in 0..<8 {
                value = (value << 8) | Int(buffer[base + cursor + offset])
            }
            payloadLength = value
            cursor += 8
        }

        guard payloadLength <= maxPayloadSize else {
            throw WebSocketError.payloadTooLarge
        }

        var mask: [UInt8] = []
        if isMasked {
            guard buffer.count >= cursor + 4 else { return nil }
            mask = (0..<4).map { buffer[base + cursor + $0] }
            cursor += 4
        }

        guard buffer.count >= cursor + payloadLength else { return nil }

        var payload = Data(buffer[(base + cursor)..<(base + cursor + payloadLength)])
        if isMasked, !mask.isEmpty {
            payload.withUnsafeMutableBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<payloadLength {
                    bytes[index] ^= mask[index % 4]
                }
            }
        }

        buffer.removeSubrange(base..<(base + cursor + payloadLength))
        return WebSocketFrame(opcode: opcode, payload: payload, isFinal: isFinal)
    }
}

// MARK: - Handshake

enum WebSocketHandshake {

    private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Computes the `Sec-WebSocket-Accept` value for a client key.
    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Builds the HTTP 101 upgrade response.
    static func upgradeResponse(clientKey: String) -> Data {
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(acceptKey(for: clientKey))\r
        \r

        """
        return Data(response.utf8)
    }
}
