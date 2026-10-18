import CoreGraphics
@testable import RemoteScreenCore
import XCTest

final class WebSocketCodecTests: XCTestCase {
    func testAcceptKeyMatchesRFC6455Example() {
        XCTAssertEqual(WebSocketCodec.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testMaskedClientFrameRoundTripsAcrossLengthEncodings() throws {
        for size in [0, 5, 125, 126, 300, 65_535, 65_536] {
            let payload = (0..<size).map { UInt8($0 & 0xFF) }
            var buffer = WebSocketCodec.encode(.binary, payload, mask: [1, 2, 3, 4])
            let frame = try XCTUnwrap(WebSocketCodec.decode(&buffer, maxPayload: 1 << 20))
            XCTAssertEqual(frame, WSFrame(fin: true, opcode: .binary, payload: payload))
            XCTAssertTrue(buffer.isEmpty)
        }
    }

    func testIncompleteFrameWaitsForMoreBytes() throws {
        let full = WebSocketCodec.encode(.text, Array("hello".utf8), mask: [9, 9, 9, 9])
        for cut in 0..<full.count {
            var partial = Array(full[..<cut])
            XCTAssertNil(try WebSocketCodec.decode(&partial, maxPayload: 1024))
            XCTAssertEqual(partial.count, cut, "incomplete frames must not be consumed")
        }
    }

    func testRejectsUnmaskedClientFramesAndOversizedPayloads() {
        var unmasked = WebSocketCodec.encode(.text, [1])
        XCTAssertThrowsError(try WebSocketCodec.decode(&unmasked, maxPayload: 10)) { XCTAssertEqual($0 as? WSError, .unmaskedClientFrame) }
        var big = WebSocketCodec.encode(.binary, [UInt8](repeating: 0, count: 200), mask: [0, 0, 0, 0])
        XCTAssertThrowsError(try WebSocketCodec.decode(&big, maxPayload: 100)) { XCTAssertEqual($0 as? WSError, .payloadTooLarge(200)) }
    }

    func testAssemblerJoinsFragmentsAndPassesControlFrames() throws {
        var a = WSMessageAssembler(maxMessage: 100)
        XCTAssertNil(try a.accept(WSFrame(fin: false, opcode: .text, payload: Array("he".utf8))))
        XCTAssertEqual(try a.accept(WSFrame(fin: true, opcode: .ping, payload: [7])), .ping([7]))
        XCTAssertEqual(try a.accept(WSFrame(fin: true, opcode: .continuation, payload: Array("llo".utf8))), .text("hello"))
        XCTAssertThrowsError(try a.accept(WSFrame(fin: true, opcode: .continuation, payload: [])))
    }
}

final class HTTPRequestTests: XCTestCase {
    func testParsesWebSocketUpgradeWithQuery() throws {
        let raw = "GET /ws?token=abc%2Bd HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: k==\r\n\r\nEXTRA"
        let bytes = Array(raw.utf8)
        let len = try XCTUnwrap(HTTPRequest.headLength(in: bytes))
        XCTAssertEqual(String(decoding: bytes[len...], as: UTF8.self), "EXTRA")
        let req = try XCTUnwrap(HTTPRequest.parse(Array(bytes[..<len])))
        XCTAssertEqual(req.path, "/ws")
        XCTAssertEqual(req.query["token"], "abc+d")
        XCTAssertTrue(req.isWebSocketUpgrade)
    }

    func testRejectsMalformedRequestLine() {
        XCTAssertNil(HTTPRequest.parse(Array("NOPE\r\n\r\n".utf8)))
        XCTAssertNil(HTTPRequest.headLength(in: Array("GET / HTTP/1.1\r\n".utf8)))
    }
}

final class ControlTests: XCTestCase {
    func testParsesEachMessageKind() {
        XCTAssertEqual(ControlMessage.parse(#"{"t":"down","x":0.5,"y":0.25}"#), .pointer(phase: .down, x: 0.5, y: 0.25))
        XCTAssertEqual(ControlMessage.parse(#"{"t":"scroll","x":0,"y":1,"dx":0,"dy":-40}"#), .scroll(x: 0, y: 1, dx: 0, dy: -40))
        XCTAssertEqual(ControlMessage.parse(#"{"t":"text","s":"héllo"}"#), .text("héllo"))
        XCTAssertEqual(ControlMessage.parse(#"{"t":"key","code":"KeyA","mods":["command","bogus"]}"#), .key(code: "KeyA", modifiers: [.command]))
        XCTAssertEqual(ControlMessage.parse(#"{"t":"action","name":"appSwitcher"}"#), .action(.appSwitcher))
    }

    func testRejectsMalformedMessages() {
        for bad in [#"{"t":"down","x":"a","y":0}"#, #"{"t":"text","s":""}"#, #"{"t":"action","name":"reboot"}"#, "not json", #"{"x":1}"#] {
            XCTAssertNil(ControlMessage.parse(bad), bad)
        }
    }

    func testGeometryMapsAndClampsIntoWindowFrame() {
        let g = WindowGeometry(frame: CGRect(x: 100, y: 50, width: 300, height: 600))
        XCTAssertEqual(g.point(x: 0, y: 0), CGPoint(x: 100, y: 50))
        XCTAssertEqual(g.point(x: 0.5, y: 0.5), CGPoint(x: 250, y: 350))
        XCTAssertEqual(g.point(x: 2, y: -1), CGPoint(x: 400, y: 50))
    }

    func testDeviceActionShortcutsAreMapped() {
        for action in DeviceAction.allCases {
            XCTAssertNotNil(KeyMap.codes[action.shortcut.code], action.rawValue)
        }
        XCTAssertEqual(KeyMap.codes["KeyA"], 0)
        XCTAssertEqual(KeyMap.codes["Digit1"], 18)
        XCTAssertEqual(KeyMap.flags([.command, .shift]), [.maskCommand, .maskShift])
    }
}

final class LoopbackPolicyTests: XCTestCase {
    func testAllowsOnlyLoopbackHostsOnAnyPort() {
        for ok in ["127.0.0.1:8765", "localhost:9765", "LOCALHOST", "[::1]:8765"] { XCTAssertTrue(LoopbackPolicy.allowsHost(ok), ok) }
        for bad in [nil, "", "evil.example:8765", "127.0.0.1.evil.example", "10.0.0.5:8765"] {
            XCTAssertFalse(LoopbackPolicy.allowsHost(bad), bad ?? "nil")
        }
    }

    func testRejectsCrossSiteWebSocketOrigins() {
        for ok in [nil, "http://127.0.0.1:8765", "http://localhost:9765", "http://[::1]:8765"] {
            XCTAssertTrue(LoopbackPolicy.allowsOrigin(ok), ok ?? "nil")
        }
        for bad in ["https://evil.example", "http://127.0.0.1.evil.example", "null", "file://"] {
            XCTAssertFalse(LoopbackPolicy.allowsOrigin(bad), bad)
        }
    }
}
