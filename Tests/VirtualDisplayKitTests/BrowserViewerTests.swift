import XCTest
@testable import VirtualDisplayKit

/// Drives the real viewer page in Chrome, emulating a phone-sized viewport.
final class ViewerLayoutTests: XCTestCase {

    private var cdp: URLSessionWebSocketTask!
    private var chrome: Process!
    private var server: BrowserStreamServer!
    private var nextId = 1

    /// Each test gets its own browser, profile and ports: a shared debug port
    /// races the previous instance's shutdown and yields phantom failures.
    private static let instanceCounter = InstanceCounter()
    private var instance = 0
    private var streamPort: UInt16 { UInt16(18250 + instance) }
    private var debugPort: Int { 9225 + instance }
    private var chromeAvailable: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    }

    private let scratch = "/private/tmp/claude-501/-Volumes-MacSiliconExternalDisk-XCode-VirtualDisplayKit-main/a4d360ec-08e4-4106-9554-d18d5ecb228c/scratchpad"

    /// Reads the scale out of the canvas's computed transform matrix.
    private static let scaleProbe = #"(() => { const t = getComputedStyle(document.getElementById('screen')).transform; const m = t.match(/matrix\(([-0-9.e]+)/); return m ? parseFloat(m[1]) : 0; })()"#

    @discardableResult
    private func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = nextId; nextId += 1
        let cmd: [String: Any] = ["id": id, "method": method, "params": params]
        try await cdp.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: cmd), as: UTF8.self)))
        // Chrome interleaves a flood of events with command replies, so wait
        // on a deadline rather than a message count.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            guard case .string(let s) = try await cdp.receive() else { continue }
            guard let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                  j["id"] as? Int == id else { continue }
            return (j["result"] as? [String: Any]) ?? [:]
        }
        XCTFail("no reply to \(method)")
        return [:]
    }

    private func eval(_ expression: String) async throws -> String {
        let r = try await send("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        let value = (r["result"] as? [String: Any])?["value"]
        return value.map { "\($0)" } ?? "nil"
    }

    private func number(_ expression: String) async throws -> Double {
        Double(try await eval(expression)) ?? .nan
    }

    private func scale() async throws -> Double { try await number(Self.scaleProbe) }

    private func rect(_ property: String) async throws -> Double {
        try await number("document.getElementById('screen').getBoundingClientRect().\(property)")
    }

    override func setUp() async throws {
        try XCTSkipUnless(chromeAvailable, "Google Chrome is required to drive the viewer page")
        instance = await Self.instanceCounter.next()

        server = BrowserStreamServer(configuration: BrowserStreamConfiguration(
            port: streamPort, targetFPS: 30, minimumFPS: 2, jpegQuality: 0.6, scale: 1.0, maximumWidth: 1280))
        try server.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        try await Task.sleep(nanoseconds: 700_000_000)

        chrome = Process()
        chrome.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        chrome.arguments = ["--headless=new", "--remote-debugging-port=\(debugPort)",
                            "--user-data-dir=\(scratch)/chrome-viewer-\(instance)", "--no-first-run", "about:blank"]
        chrome.standardOutput = FileHandle.nullDevice
        chrome.standardError = FileHandle.nullDevice
        try chrome.run()

        var target: URL?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 250_000_000)
            var r = URLRequest(url: URL(string: "http://127.0.0.1:\(debugPort)/json/new?http://127.0.0.1:\(streamPort)/")!)
            r.httpMethod = "PUT"
            if let (d, _) = try? await URLSession.shared.data(for: r),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let ws = j["webSocketDebuggerUrl"] as? String { target = URL(string: ws); break }
        }
        cdp = URLSession.shared.webSocketTask(with: try XCTUnwrap(target))
        cdp.resume()

        // A portrait phone: the shape that showed the bug.
        try await send("Emulation.setDeviceMetricsOverride", [
            "width": 390, "height": 844, "deviceScaleFactor": 3, "mobile": true
        ])
        try await Task.sleep(nanoseconds: 4_000_000_000)
    }

    override func tearDown() async throws {
        cdp?.cancel(with: .normalClosure, reason: nil)
        chrome?.terminate()
        chrome?.waitUntilExit()
        server?.stop()
        try? FileManager.default.removeItem(atPath: "\(scratch)/chrome-viewer-\(instance)")
    }

    func testPictureIsCentredInAPhoneViewport() async throws {
        let splash = try await eval("document.getElementById('splash').className")
        XCTAssertTrue(splash.contains("gone"), "a frame should have rendered")

        let viewportHeight = try await number("window.visualViewport ? visualViewport.height : innerHeight")
        let viewportWidth = try await number("window.visualViewport ? visualViewport.width : innerWidth")
        let top = try await rect("top")
        let height = try await rect("height")
        let left = try await rect("left")
        let width = try await rect("width")

        print("VIEWER viewport=\(viewportWidth)x\(viewportHeight) picture=(\(left),\(top)) \(width)x\(height)")

        // The bug: the picture centred against a taller box and slid downwards.
        XCTAssertEqual(top + height / 2, viewportHeight / 2, accuracy: 2, "picture is not vertically centred")
        XCTAssertEqual(left + width / 2, viewportWidth / 2, accuracy: 2, "picture is not horizontally centred")
        XCTAssertGreaterThanOrEqual(top, -1, "picture starts above the visible area")
        XCTAssertLessThanOrEqual(top + height, viewportHeight + 1, "picture runs past the bottom")
        XCTAssertEqual(width, viewportWidth, accuracy: 2, "a 16:9 picture should fill a portrait phone's width")
    }

    func testDoubleTapZoomsInAndFitButtonRestores() async throws {
        let fitted = try await scale()

        _ = try await eval("document.getElementById('stage').dispatchEvent(new MouseEvent('dblclick', {clientX: 195, clientY: 400, bubbles: true, cancelable: true})), 1")
        let zoomed = try await scale()
        print("VIEWER scale fit=\(fitted) afterDoubleTap=\(zoomed)")
        XCTAssertGreaterThan(zoomed, fitted * 2, "double tap should zoom in")

        let fitButton = try await eval("document.getElementById('btnFit').className")
        XCTAssertFalse(fitButton.contains("hidden"), "fit button should appear once zoomed")

        _ = try await eval("document.getElementById('btnFit').click(), 1")
        let restored = try await scale()
        XCTAssertEqual(restored, fitted, accuracy: 0.001, "fit button should restore the fitted scale")
    }

    func testPinchZoomsAndPanCannotDetachThePicture() async throws {
        let fitted = try await scale()

        _ = try await eval("""
        (() => {
          const s = document.getElementById('stage');
          const down = (id, x, y) => s.dispatchEvent(new PointerEvent('pointerdown', {pointerId: id, clientX: x, clientY: y, bubbles: true}));
          const move = (id, x, y) => s.dispatchEvent(new PointerEvent('pointermove', {pointerId: id, clientX: x, clientY: y, bubbles: true}));
          const up = (id) => s.dispatchEvent(new PointerEvent('pointerup', {pointerId: id, bubbles: true}));
          down(1, 150, 400); down(2, 240, 400);
          move(1, 150, 400); move(2, 240, 400);
          move(1, 60, 400);  move(2, 330, 400);
          move(1, 20, 400);  move(2, 370, 400);
          up(1); up(2);
          return 1;
        })()
        """)

        let pinched = try await scale()
        print("VIEWER scale fit=\(fitted) afterPinch=\(pinched)")
        XCTAssertGreaterThan(pinched, fitted * 1.5, "pinch should zoom in")

        // Drag far past the edge; the picture must stay pinned to it.
        _ = try await eval("""
        (() => {
          const s = document.getElementById('stage');
          s.dispatchEvent(new PointerEvent('pointerdown', {pointerId: 3, clientX: 200, clientY: 400, bubbles: true}));
          for (let i = 1; i <= 20; i++) {
            s.dispatchEvent(new PointerEvent('pointermove', {pointerId: 3, clientX: 200 + i * 200, clientY: 400 + i * 200, bubbles: true}));
          }
          s.dispatchEvent(new PointerEvent('pointerup', {pointerId: 3, bubbles: true}));
          return 1;
        })()
        """)

        let left = try await rect("left")
        let width = try await rect("width")
        let viewportWidth = try await number("window.visualViewport ? visualViewport.width : innerWidth")
        print("VIEWER after runaway drag: left=\(left) width=\(width) viewportWidth=\(viewportWidth)")

        XCTAssertLessThanOrEqual(left, 1, "picture was dragged off the left edge")
        XCTAssertGreaterThanOrEqual(left + width, viewportWidth - 1, "picture was dragged off the right edge")
    }

    func testTheMacChoosesTheCodecAndEveryDecoderPaints() async throws {
        // setUp's server keeps the default codec.
        let defaultCodec = try await eval("document.getElementById('mCodec').textContent")
        XCTAssertEqual(defaultCodec, "JPEG", "JPEG unless the Mac is set to H.264")

        let videoPort = streamPort + 200
        let videoServer = BrowserStreamServer(configuration: BrowserStreamConfiguration(
            port: videoPort, targetFPS: 30, minimumFPS: 2, maximumWidth: 1280, codec: .h264))
        try videoServer.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        defer { videoServer.stop() }

        // Decoders are taken away before the page runs, to reach each path
        // the way a browser lacking them would. Injection needs Page events.
        try await send("Page.enable")
        let cases: [(name: String, port: UInt16, hide: String, expectedLabel: String, usesVideoElement: Bool)] = [
            ("webcodecs", videoPort, "", "H.264", false),
            ("mse", videoPort, "delete window.VideoDecoder;", "H.264", true),
            ("no H.264 decoder", videoPort, "delete window.VideoDecoder; delete window.MediaSource; delete window.ManagedMediaSource;", "JPEG", false),
            ("jpeg", streamPort, "", "JPEG", false),
        ]

        for item in cases {
            var scriptID: String?
            if !item.hide.isEmpty {
                let added = try await send("Page.addScriptToEvaluateOnNewDocument", ["source": item.hide])
                scriptID = added["identifier"] as? String
            }
            try await send("Page.navigate", ["url": "http://127.0.0.1:\(item.port)/"])
            try await Task.sleep(nanoseconds: 4_000_000_000)
            if let scriptID { try await send("Page.removeScriptToEvaluateOnNewDocument", ["identifier": scriptID]) }

            let label = try await eval("document.getElementById('mCodec').textContent")
            XCTAssertEqual(label, item.expectedLabel, "\(item.name): wrong codec")

            let splash = try await eval("document.getElementById('splash').className")
            XCTAssertTrue(splash.contains("gone"), "\(item.name): no frame arrived")

            // Sample the picture itself: a decoder that "works" but paints
            // black would pass every other check.
            let brightness = try await number("""
            (() => {
              const video = document.querySelector('video');
              const source = video || document.getElementById('screen');
              const probe = document.createElement('canvas');
              probe.width = 64; probe.height = 36;
              const c = probe.getContext('2d');
              c.drawImage(source, 0, 0, 64, 36);
              const d = c.getImageData(0, 0, 64, 36).data;
              let sum = 0;
              for (let i = 0; i < d.length; i += 4) sum += d[i] + d[i + 1] + d[i + 2];
              return sum / (d.length / 4) / 3;
            })()
            """)
            print("VIEWER \(item.name): \(label), mean brightness \(brightness)")
            XCTAssertGreaterThan(brightness, 2, "\(item.name): the picture is black")

            let video = try await eval("(() => { const v = document.querySelector('video'); return v ? v.videoWidth + 'x' + v.videoHeight : 'none'; })()")
            if item.usesVideoElement {
                XCTAssertEqual(video, "1280x720", "\(item.name): video element is not playing the stream")
            } else {
                XCTAssertEqual(video, "none", "\(item.name): should draw on the canvas")
            }
        }
    }

    func testPointerIsDrawnByTheViewerNotTheFrames() async throws {
        let shape = try await eval("document.getElementById('cursor').style.backgroundImage.slice(0, 27)")
        XCTAssertEqual(shape, "url(\"data:image/png;base64,", "the Mac's cursor image should reach the viewer")

        // Where the pointer really is decides whether the overlay may show.
        let location = CGEvent(source: nil)?.location ?? .zero
        let onStreamedDisplay = CGDisplayBounds(CGMainDisplayID()).contains(location)
        let display = try await eval("document.getElementById('cursor').style.display")
        print("VIEWER cursor: pointer at \(location), overlay display=\(display)")
        XCTAssertEqual(display, onStreamedDisplay ? "block" : "none")

        if onStreamedDisplay {
            // The overlay must land where the pointer is on the picture.
            let expectedX = (location.x - CGDisplayBounds(CGMainDisplayID()).minX) / CGDisplayBounds(CGMainDisplayID()).width
            let overlay = try await number("""
            (() => {
              const c = document.getElementById('cursor').getBoundingClientRect();
              const p = document.getElementById('screen').getBoundingClientRect();
              return (c.left - p.left) / p.width;
            })()
            """)
            XCTAssertEqual(overlay, expectedX, accuracy: 0.03, "overlay is not where the pointer is")
        }
    }

    func testViewerControlsTheMacAfterEnteringThePIN() async throws {
        // A second server with control on; events are recorded, not posted.
        let recorder = EventRecorder()
        let port = streamPort + 100
        let controlServer = BrowserStreamServer(configuration: BrowserStreamConfiguration(
            port: port, targetFPS: 30, minimumFPS: 2, maximumWidth: 1280, allowsControl: true, controlPIN: "424242"))
        controlServer.inputPostOverride = recorder.record
        controlServer.focusCheckOverride = { true }
        try controlServer.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        defer { controlServer.stop() }

        try await send("Page.navigate", ["url": "http://127.0.0.1:\(port)/"])
        try await Task.sleep(nanoseconds: 3_000_000_000)

        let controlButton = try await eval("document.getElementById('btnControl').className")
        XCTAssertFalse(controlButton.contains("hidden"), "the Mac allows control, so offer it")
        _ = try await eval("document.getElementById('btnControl').click(), 1")
        let pinPanel = try await eval("document.getElementById('pinPanel').className")
        XCTAssertFalse(pinPanel.contains("hidden"), "asks for the PIN")
        _ = try await eval("document.getElementById('pinInput').value = '424242', document.getElementById('pinForm').requestSubmit(), 1")
        try await Task.sleep(nanoseconds: 500_000_000)
        let controlState = try await eval("document.getElementById('btnControl').className")
        XCTAssertTrue(controlState.contains("on"), "control should be on")

        // Where on the page a given fraction of the picture is.
        func pagePoint(_ fx: Double, _ fy: Double) async throws -> (Double, Double) {
            let r = try await eval("(() => { const r = document.getElementById('screen').getBoundingClientRect(); return r.left + ',' + r.top + ',' + r.width + ',' + r.height; })()")
                .split(separator: ",").compactMap { Double($0) }
            return (r[0] + r[2] * fx, r[1] + r[3] * fy)
        }
        let display = CGDisplayBounds(CGMainDisplayID())
        func expected(_ fx: Double, _ fy: Double) -> CGPoint {
            CGPoint(x: display.minX + display.width * fx, y: display.minY + display.height * fy)
        }
        func pointer(_ type: String, _ x: Double, _ y: Double, kind: String, id: Int = 1, button: Int = 0) -> String {
            "document.getElementById('stage').dispatchEvent(new PointerEvent('\(type)', {pointerId: \(id), pointerType: '\(kind)', button: \(button), clientX: \(x), clientY: \(y), bubbles: true, cancelable: true}))"
        }

        // Mouse click in the middle of the picture: the middle of the display.
        let (cx, cy) = try await pagePoint(0.5, 0.5)
        _ = try await eval("\(pointer("pointerdown", cx, cy, kind: "mouse")), \(pointer("pointerup", cx, cy, kind: "mouse")), 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        var events = recorder.events
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
        if let down = events.first {
            XCTAssertEqual(down.location.x, expected(0.5, 0.5).x, accuracy: 4)
            XCTAssertEqual(down.location.y, expected(0.5, 0.5).y, accuracy: 4)
        }

        // A finger tap a quarter of the way in clicks there too.
        recorder.clear()
        let (tx, ty) = try await pagePoint(0.25, 0.25)
        _ = try await eval("\(pointer("pointerdown", tx, ty, kind: "touch", id: 5)), \(pointer("pointerup", tx, ty, kind: "touch", id: 5)), 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        events = recorder.events
        XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp], "a tap is a click")
        if let tap = events.first {
            XCTAssertEqual(tap.location.x, expected(0.25, 0.25).x, accuracy: 4)
            XCTAssertEqual(tap.location.y, expected(0.25, 0.25).y, accuracy: 4)
        }

        // Keys go by physical key, with modifiers.
        recorder.clear()
        _ = try await eval("window.dispatchEvent(new KeyboardEvent('keydown', {code: 'KeyV', key: 'v', metaKey: true, bubbles: true})), window.dispatchEvent(new KeyboardEvent('keyup', {code: 'KeyV', key: 'v', metaKey: true, bubbles: true})), 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        events = recorder.events
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(events.first?.keyCode, 0x09)
        XCTAssertEqual(events.first?.flags, .maskCommand)

        // Two fingers moving up together scroll the Mac's content down.
        recorder.clear()
        let (sx, sy) = try await pagePoint(0.5, 0.6)
        var script = "\(pointer("pointerdown", sx - 30, sy, kind: "touch", id: 7)), \(pointer("pointerdown", sx + 30, sy, kind: "touch", id: 8))"
        for step in 1...6 {
            let y = sy - Double(step) * 10
            script += ", \(pointer("pointermove", sx - 30, y, kind: "touch", id: 7)), \(pointer("pointermove", sx + 30, y, kind: "touch", id: 8))"
        }
        script += ", \(pointer("pointerup", sx - 30, sy - 60, kind: "touch", id: 7)), \(pointer("pointerup", sx + 30, sy - 60, kind: "touch", id: 8)), 1"
        _ = try await eval(script)
        try await Task.sleep(nanoseconds: 300_000_000)
        events = recorder.events
        let scrolls = events.filter { $0.type == .scrollWheel }
        print("VIEWER control: scroll events \(scrolls.count), wheel \(scrolls.map(\.wheel)), others \(events.filter { $0.type != .scrollWheel }.map(\.type.rawValue))")
        XCTAssertFalse(scrolls.isEmpty, "two-finger drag should scroll")
        XCTAssertTrue(scrolls.allSatisfy { $0.wheel < 0 }, "fingers moving up show what's further down")
        XCTAssertFalse(events.contains { $0.type == .leftMouseDown }, "a two-finger scroll must not click")
    }

    func testLandscapeStillFits() async throws {
        try await send("Emulation.setDeviceMetricsOverride", [
            "width": 844, "height": 390, "deviceScaleFactor": 3, "mobile": true
        ])
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let viewportHeight = try await number("window.visualViewport ? visualViewport.height : innerHeight")
        let top = try await rect("top")
        let height = try await rect("height")
        print("VIEWER landscape: top=\(top) height=\(height) viewportHeight=\(viewportHeight)")

        XCTAssertEqual(top + height / 2, viewportHeight / 2, accuracy: 2, "picture is not centred after rotation")
        XCTAssertLessThanOrEqual(height, viewportHeight + 1, "picture is taller than the screen")
    }
}


/// Hands out a distinct index to each test case.
private actor InstanceCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
