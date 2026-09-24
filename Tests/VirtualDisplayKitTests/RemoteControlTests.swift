//
//  RemoteControlTests.swift
//  VirtualDisplayKit
//
//  Viewer input becoming macOS input. Nothing here reaches the real event
//  system: every test swaps in a recorder, so running them never moves the
//  pointer or types into whatever is on screen.
//

import XCTest
@testable import VirtualDisplayKit

/// A posted event, reduced to what the tests check.
struct RecordedEvent: Equatable {
    let type: CGEventType
    let location: CGPoint
    var keyCode: Int64 = 0
    var clicks: Int64 = 0
    var wheel: Int64 = 0
    var flags: CGEventFlags = []

    init(_ event: CGEvent) {
        type = event.type
        location = event.location
        keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        clicks = event.getIntegerValueField(.mouseEventClickState)
        wheel = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        flags = event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RecordedEvent] = []
    func record(_ event: CGEvent) { lock.lock(); recorded.append(RecordedEvent(event)); lock.unlock() }
    var events: [RecordedEvent] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded.removeAll(); lock.unlock() }
}

final class RemoteInputTests: XCTestCase {

    private let display = CGMainDisplayID()
    private var bounds: CGRect { CGDisplayBounds(display) }
    /// A stream at half the display's width, like a capped output size
    private var output: CGSize { CGSize(width: bounds.width / 2, height: bounds.height / 2) }

    private func makeInput(focused: Bool = true) -> (RemoteInput, EventRecorder) {
        let recorder = EventRecorder()
        let input = RemoteInput(displayID: display, outputSize: output)
        input.post = recorder.record
        input.focusIsOnDisplay = { focused }
        return (input, recorder)
    }

    func testStreamPixelsMapOntoTheDisplayAndNeverPastIt() {
        let b = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let out = CGSize(width: 720, height: 450)

        XCTAssertEqual(RemoteInput.globalPoint(streamX: 360, streamY: 225, displayBounds: b, outputSize: out),
                       CGPoint(x: 2640, y: 450))
        // However far outside a viewer points, input stays on this display.
        XCTAssertEqual(RemoteInput.globalPoint(streamX: -5000, streamY: -5000, displayBounds: b, outputSize: out),
                       CGPoint(x: 1920, y: 0))
        XCTAssertEqual(RemoteInput.globalPoint(streamX: 99999, streamY: 99999, displayBounds: b, outputSize: out),
                       CGPoint(x: 3359, y: 899))
        XCTAssertNil(RemoteInput.globalPoint(streamX: .nan, streamY: 1, displayBounds: b, outputSize: out))
    }

    func testClickDragAndDoubleClick() {
        let (input, recorder) = makeInput()
        input.handle(RemoteInputEvent(t: .down, x: 10, y: 20, b: 0, n: 1))
        input.handle(RemoteInputEvent(t: .move, x: 50, y: 60))
        input.handle(RemoteInputEvent(t: .up, x: 50, y: 60, b: 0, n: 1))
        input.handle(RemoteInputEvent(t: .down, x: 50, y: 60, b: 0, n: 2))
        input.handle(RemoteInputEvent(t: .up, x: 50, y: 60, b: 0, n: 2))

        let events = recorder.events
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        // Stream is half size: pixel (10, 20) is display point (20, 40).
        XCTAssertEqual(events[0].location, CGPoint(x: bounds.minX + 20, y: bounds.minY + 40))
        XCTAssertEqual(events[3].clicks, 2, "a double click must say so")
    }

    func testRightClickAndMovesWithoutButtons() {
        let (input, recorder) = makeInput()
        input.handle(RemoteInputEvent(t: .move, x: 1, y: 1))
        input.handle(RemoteInputEvent(t: .down, x: 1, y: 1, b: 2, n: 1))
        input.handle(RemoteInputEvent(t: .up, x: 1, y: 1, b: 2, n: 1))
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved, .rightMouseDown, .rightMouseUp])
    }

    func testKeysCarryModifiersAndNeedFocusOnThisDisplay() {
        let (input, recorder) = makeInput(focused: true)
        input.handle(RemoteInputEvent(t: .key, code: "KeyC", down: true, m: 8))
        input.handle(RemoteInputEvent(t: .key, code: "KeyC", down: false, m: 8))
        XCTAssertEqual(recorder.events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(recorder.events.first?.keyCode, 0x08)
        XCTAssertEqual(recorder.events.first?.flags, .maskCommand, "⌘C, not C")

        let (blocked, blockedRecorder) = makeInput(focused: false)
        XCTAssertEqual(blocked.handle(RemoteInputEvent(t: .key, code: "KeyA", down: true)), .focusElsewhere)
        XCTAssertEqual(blocked.handle(RemoteInputEvent(t: .text, text: "hello")), .focusElsewhere)
        XCTAssertTrue(blockedRecorder.events.isEmpty, "nothing may be typed into a window on another display")
    }

    func testTextIsTypedAsUnicodeInChunks() {
        let (input, recorder) = makeInput()
        input.handle(RemoteInputEvent(t: .text, text: "Tiếng Việt có dấu, dài hơn hai mươi ký tự"))
        XCTAssertEqual(RemoteInput.chunks(of: "Tiếng Việt có dấu, dài hơn hai mươi ký tự").joined(), "Tiếng Việt có dấu, dài hơn hai mươi ký tự")
        XCTAssertEqual(recorder.events.count, RemoteInput.chunks(of: "Tiếng Việt có dấu, dài hơn hai mươi ký tự").count * 2)
    }

    func testScrollMovesThePointerThereFirst() {
        let (input, recorder) = makeInput()
        input.handle(RemoteInputEvent(t: .scroll, x: 100, y: 100, dx: 0, dy: 40))
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved, .scrollWheel])
        XCTAssertLessThan(recorder.events[1].wheel, 0, "a positive DOM deltaY shows what's further down")
    }

    func testReleaseAllLetsGoOfHeldButtons() {
        let (input, recorder) = makeInput()
        input.handle(RemoteInputEvent(t: .down, x: 5, y: 5, b: 0, n: 1))
        input.releaseAll()
        XCTAssertEqual(recorder.events.map(\.type), [.leftMouseDown, .leftMouseUp])
    }
}

final class RemoteControlServerTests: XCTestCase {

    func testInputNeedsTheRightPIN() async throws {
        let recorder = EventRecorder()
        let server = BrowserStreamServer(configuration: BrowserStreamConfiguration(
            port: 18140, targetFPS: 30, allowsControl: true, controlPIN: "424242"))
        server.inputPostOverride = recorder.record
        server.focusCheckOverride = { true }
        try server.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        defer { server.stop() }
        XCTAssertEqual(server.controlPIN, "424242")
        try await Task.sleep(nanoseconds: 300_000_000)

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18140/ws")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let meta = try await nextMessage(from: socket, containing: "\"type\":\"meta\"")
        XCTAssertTrue(meta.contains("\"control\":true"))

        let move = #"i{"t":"move","x":10,"y":10}"#
        try await socket.send(.string(move))
        try await socket.send(.string("A000000"))
        let refused = try await nextMessage(from: socket, containing: "\"type\":\"control\"")
        XCTAssertTrue(refused.contains("\"reason\":\"pin\""))
        try await socket.send(.string(move))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(recorder.events.isEmpty, "no input before the right PIN")

        try await socket.send(.string("A424242"))
        let granted = try await nextMessage(from: socket, containing: "\"type\":\"control\"")
        XCTAssertTrue(granted.contains("\"granted\":true"))
        try await socket.send(.string(move))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved])
    }

    func testGuessingThePINGetsTheViewerDisconnected() async throws {
        let server = BrowserStreamServer(configuration: BrowserStreamConfiguration(
            port: 18141, targetFPS: 30, allowsControl: true, controlPIN: "424242"))
        server.inputPostOverride = { _ in }
        try server.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18141/ws")!)
        socket.resume()
        for guess in 0..<5 { try await socket.send(.string("A\(guess)")) }
        try await Task.sleep(nanoseconds: 500_000_000)

        var closed = false
        do {
            for _ in 0..<200 { _ = try await socket.receive() }
        } catch {
            closed = true
        }
        XCTAssertTrue(closed, "five wrong PINs should end the connection")
    }

    func testControlIsOffUnlessAskedFor() async throws {
        let server = BrowserStreamServer(configuration: BrowserStreamConfiguration(port: 18142, targetFPS: 30))
        try server.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        defer { server.stop() }
        XCTAssertNil(server.controlPIN)
        try await Task.sleep(nanoseconds: 300_000_000)

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:18142/ws")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let meta = try await nextMessage(from: socket, containing: "\"type\":\"meta\"")
        XCTAssertTrue(meta.contains("\"control\":false"))
        try await socket.send(.string("A123456"))
        let reply = try await nextMessage(from: socket, containing: "\"type\":\"control\"")
        XCTAssertTrue(reply.contains("\"reason\":\"disabled\""))
    }

    private func nextMessage(from socket: URLSessionWebSocketTask, containing marker: String) async throws -> String {
        for _ in 0..<300 {
            if case .string(let text) = try await socket.receive(), text.contains(marker) { return text }
        }
        XCTFail("no message containing \(marker)")
        return ""
    }
}
