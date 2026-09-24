//
//  RemoteInput.swift
//  VirtualDisplayKit
//
//  Turns a viewer's mouse, touch, scroll and keyboard input into real macOS
//  input — confined to the streamed display. The pointer can never be sent
//  past its edges, and keystrokes only go through while the focused window
//  sits on it, so a viewer can't reach anything the Mac's own user is doing
//  on another screen.
//

import AppKit
import Foundation

/// One input event from a viewer. Positions are in stream pixels.
struct RemoteInputEvent: Decodable, Equatable {
    enum Kind: String, Decodable {
        case move, down, up, scroll, key, text
    }

    let t: Kind
    var x: Double?
    var y: Double?
    /// Mouse button: 0 left, 1 middle, 2 right (as in DOM events)
    var b: Int?
    /// Click count, for double and triple clicks
    var n: Int?
    /// Scroll distance in stream pixels, positive meaning "show what is
    /// further down/right" (the DOM's deltaX/deltaY convention)
    var dx: Double?
    var dy: Double?
    /// DOM `KeyboardEvent.code` — the physical key
    var code: String?
    var down: Bool?
    /// Modifiers held: 1 shift, 2 control, 4 option, 8 command
    var m: Int?
    var text: String?
}

/// Why a viewer's input was refused
enum RemoteInputRefusal: Equatable {
    /// Keystrokes would reach a window on another display
    case focusElsewhere
    /// macOS hasn't granted this app permission to post events
    case notPermitted
}

/// Posts viewer input as macOS events, confined to one display.
///
/// Only ever touched on the server's network queue.
final class RemoteInput {

    /// Where events go. Replaceable so tests can watch without taking over
    /// the machine running them.
    var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

    /// Whether the focused window is on the streamed display. Replaceable
    /// for tests.
    var focusIsOnDisplay: () -> Bool

    private let displayID: CGDirectDisplayID
    private let outputSize: CGSize
    private let source = CGEventSource(stateID: .hidSystemState)

    private var pressedButtons: Set<Int> = []
    private var modifiers: CGEventFlags = []
    private var lastPoint: CGPoint?

    init(displayID: CGDirectDisplayID, outputSize: CGSize) {
        self.displayID = displayID
        self.outputSize = outputSize
        self.focusIsOnDisplay = { RemoteInput.focusedWindowIsOnDisplay(displayID) }
    }

    /// Whether macOS lets this process post input events at all.
    static var isPermitted: Bool {
        CGPreflightPostEventAccess()
    }

    /// Shows the system prompt asking for permission, once per launch.
    static func requestPermission() {
        _ = CGRequestPostEventAccess()
    }

    // MARK: - Handling

    /// Posts `event`, or says why it can't be.
    @discardableResult
    func handle(_ event: RemoteInputEvent) -> RemoteInputRefusal? {
        if let m = event.m { modifiers = Self.flags(from: m) }

        switch event.t {
        case .move:
            guard let point = point(of: event) else { return nil }
            let dragged = pressedButtons.min()
            postMouse(dragged.map(Self.draggedType) ?? .mouseMoved, at: point, button: dragged ?? 0)

        case .down:
            guard let point = point(of: event), let button = event.b else { return nil }
            pressedButtons.insert(button)
            postMouse(Self.downType(button), at: point, button: button, clicks: event.n ?? 1)

        case .up:
            guard let button = event.b, pressedButtons.remove(button) != nil else { return nil }
            let point = self.point(of: event) ?? lastPoint ?? displayBounds.center
            postMouse(Self.upType(button), at: point, button: button, clicks: event.n ?? 1)

        case .scroll:
            // Scrolling goes to the window under the pointer, so put the
            // pointer there first — on this display, like everything else.
            if let point = point(of: event), point != lastPoint {
                postMouse(.mouseMoved, at: point, button: 0)
            }
            let scale = pointsPerPixel
            let vertical = Int32((-(event.dy ?? 0) * scale).rounded())
            let horizontal = Int32((-(event.dx ?? 0) * scale).rounded())
            guard vertical != 0 || horizontal != 0,
                  let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                       wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return nil }
            scroll.flags = modifiers
            post(scroll)

        case .key:
            guard let code = event.code, let key = Self.keyCodes[code] else { return nil }
            // Modifiers ride along as flags on every event instead.
            guard !Self.modifierCodes.contains(code) else { return nil }
            guard focusIsOnDisplay() else { return .focusElsewhere }
            guard let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: event.down ?? true) else { return nil }
            keyEvent.flags = modifiers
            post(keyEvent)

        case .text:
            guard let text = event.text, !text.isEmpty else { return nil }
            guard focusIsOnDisplay() else { return .focusElsewhere }
            // Typed as Unicode rather than key codes, so any character works
            // whatever the Mac's keyboard layout — what phone keyboards need.
            for chunk in Self.chunks(of: text) {
                let utf16 = Array(chunk.utf16)
                for isDown in [true, false] {
                    guard let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                    keyEvent.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                    post(keyEvent)
                }
            }
        }
        return nil
    }

    /// Lets go of anything still held, so a viewer that vanishes mid-drag
    /// doesn't leave a button stuck down.
    func releaseAll() {
        for button in pressedButtons {
            postMouse(Self.upType(button), at: lastPoint ?? displayBounds.center, button: button)
        }
        pressedButtons.removeAll()
        modifiers = []
    }

    // MARK: - Confinement

    private var displayBounds: CGRect { CGDisplayBounds(displayID) }

    private var pointsPerPixel: Double {
        outputSize.width > 0 ? displayBounds.width / outputSize.width : 1
    }

    private func point(of event: RemoteInputEvent) -> CGPoint? {
        guard let x = event.x, let y = event.y else { return nil }
        return Self.globalPoint(streamX: x, streamY: y, displayBounds: displayBounds, outputSize: outputSize)
    }

    /// Maps stream pixels to global display points, clamped inside the
    /// display: no input, however malformed, lands on another screen.
    static func globalPoint(streamX: Double, streamY: Double, displayBounds bounds: CGRect, outputSize: CGSize) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0, outputSize.width > 0, outputSize.height > 0,
              streamX.isFinite, streamY.isFinite else { return nil }
        let x = bounds.minX + streamX / outputSize.width * bounds.width
        let y = bounds.minY + streamY / outputSize.height * bounds.height
        // The last whole point inside; maxX itself belongs to the next display.
        return CGPoint(
            x: min(max(x, bounds.minX), bounds.maxX - 1),
            y: min(max(y, bounds.minY), bounds.maxY - 1)
        )
    }

    /// Whether the window that receives keystrokes is on `displayID`.
    ///
    /// That is the frontmost app's frontmost ordinary window; it counts as on
    /// the display when its centre is.
    static func focusedWindowIsOnDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }

        // Listed front to back.
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let raw = window[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { continue }
            return CGDisplayBounds(displayID).contains(CGPoint(x: bounds.midX, y: bounds.midY))
        }
        return false
    }

    // MARK: - Posting

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: Int, clicks: Int = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: CGMouseButton(rawValue: UInt32(max(0, button))) ?? .left) else { return }
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
        }
        event.flags = modifiers
        lastPoint = point
        post(event)
    }

    private static func downType(_ button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseDown
        case 2: return .rightMouseDown
        default: return .otherMouseDown
        }
    }

    private static func upType(_ button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseUp
        case 2: return .rightMouseUp
        default: return .otherMouseUp
        }
    }

    private static func draggedType(_ button: Int) -> CGEventType {
        switch button {
        case 0: return .leftMouseDragged
        case 2: return .rightMouseDragged
        default: return .otherMouseDragged
        }
    }

    static func flags(from bits: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if bits & 1 != 0 { flags.insert(.maskShift) }
        if bits & 2 != 0 { flags.insert(.maskControl) }
        if bits & 4 != 0 { flags.insert(.maskAlternate) }
        if bits & 8 != 0 { flags.insert(.maskCommand) }
        return flags
    }

    /// `keyboardSetUnicodeString` takes at most 20 UTF-16 units per event.
    static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            if current.utf16.count + String(character).utf16.count > 20 {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Key codes

    static let modifierCodes: Set<String> = [
        "ShiftLeft", "ShiftRight", "ControlLeft", "ControlRight",
        "AltLeft", "AltRight", "MetaLeft", "MetaRight",
    ]

    /// DOM `KeyboardEvent.code` to macOS virtual key code. Codes name
    /// physical keys, so shortcuts land on the same keys as on a Mac keyboard.
    static let keyCodes: [String: CGKeyCode] = [
        "KeyA": 0x00, "KeyS": 0x01, "KeyD": 0x02, "KeyF": 0x03, "KeyH": 0x04, "KeyG": 0x05,
        "KeyZ": 0x06, "KeyX": 0x07, "KeyC": 0x08, "KeyV": 0x09, "KeyB": 0x0B, "KeyQ": 0x0C,
        "KeyW": 0x0D, "KeyE": 0x0E, "KeyR": 0x0F, "KeyY": 0x10, "KeyT": 0x11, "KeyO": 0x1F,
        "KeyU": 0x20, "KeyI": 0x22, "KeyP": 0x23, "KeyL": 0x25, "KeyJ": 0x26, "KeyK": 0x28,
        "KeyN": 0x2D, "KeyM": 0x2E,
        "Digit1": 0x12, "Digit2": 0x13, "Digit3": 0x14, "Digit4": 0x15, "Digit5": 0x17,
        "Digit6": 0x16, "Digit7": 0x1A, "Digit8": 0x1C, "Digit9": 0x19, "Digit0": 0x1D,
        "Equal": 0x18, "Minus": 0x1B, "BracketRight": 0x1E, "BracketLeft": 0x21,
        "Quote": 0x27, "Semicolon": 0x29, "Backslash": 0x2A, "Comma": 0x2B, "Slash": 0x2C,
        "Period": 0x2F, "Backquote": 0x32, "IntlBackslash": 0x0A,
        "Enter": 0x24, "Tab": 0x30, "Space": 0x31, "Backspace": 0x33, "Escape": 0x35,
        "CapsLock": 0x39, "Delete": 0x75, "Home": 0x73, "End": 0x77, "PageUp": 0x74, "PageDown": 0x79,
        "ArrowLeft": 0x7B, "ArrowRight": 0x7C, "ArrowDown": 0x7D, "ArrowUp": 0x7E,
        "ShiftLeft": 0x38, "ShiftRight": 0x3C, "ControlLeft": 0x3B, "ControlRight": 0x3E,
        "AltLeft": 0x3A, "AltRight": 0x3D, "MetaLeft": 0x37, "MetaRight": 0x36,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61,
        "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "Numpad0": 0x52, "Numpad1": 0x53, "Numpad2": 0x54, "Numpad3": 0x55, "Numpad4": 0x56,
        "Numpad5": 0x57, "Numpad6": 0x58, "Numpad7": 0x59, "Numpad8": 0x5B, "Numpad9": 0x5C,
        "NumpadDecimal": 0x41, "NumpadMultiply": 0x43, "NumpadAdd": 0x45, "NumpadDivide": 0x4B,
        "NumpadEnter": 0x4C, "NumpadSubtract": 0x4E, "NumpadEqual": 0x51,
    ]
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
