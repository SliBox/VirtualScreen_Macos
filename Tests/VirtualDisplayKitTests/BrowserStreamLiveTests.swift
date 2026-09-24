//
//  BrowserStreamLiveTests.swift
//  VirtualDisplayKit
//
//  End-to-end checks against a running server, driven by Foundation's own
//  HTTP and WebSocket clients. Capture itself needs Screen Recording
//  permission, which a test binary doesn't have — so these cover the serving
//  side: routing, the upgrade handshake and the control protocol.
//

import XCTest
@testable import VirtualDisplayKit

final class BrowserStreamLiveTests: XCTestCase {

    func testServesViewerPage() async throws {
        // Each test binds its own port: `stop()` tears down asynchronously, so
        // reusing one port across tests would race on the listening socket.
        let port: UInt16 = 18123
        let server = try await startServer(on: port)
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: url("/", port: port))
        let http = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), "text/html; charset=utf-8")

        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.contains("<canvas"))
        XCTAssertTrue(html.contains("createImageBitmap"), "frames are decoded off the main thread")
        XCTAssertTrue(html.contains("drawImage"), "tiles are painted onto a persistent canvas")
    }

    func testServesHealthAndRejectsUnknownPaths() async throws {
        let port: UInt16 = 18124
        let server = try await startServer(on: port)
        defer { server.stop() }

        let (health, healthResponse) = try await URLSession.shared.data(from: url("/health", port: port))
        XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: health, as: UTF8.self).contains("\"status\":\"ok\""))

        let (_, missing) = try await URLSession.shared.data(from: url("/does-not-exist", port: port))
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
    }

    func testServesHomeScreenWebAppAssets() async throws {
        let port: UInt16 = 18126
        let server = try await startServer(on: port)
        defer { server.stop() }

        let (manifest, manifestResponse) = try await URLSession.shared.data(from: url("/manifest.webmanifest", port: port))
        XCTAssertEqual((manifestResponse as? HTTPURLResponse)?.statusCode, 200)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        XCTAssertEqual(parsed["display"] as? String, "fullscreen", "installed viewers should get the whole screen")
        XCTAssertEqual(parsed["background_color"] as? String, "#000000")

        let (icon, iconResponse) = try await URLSession.shared.data(from: url("/icon.png", port: port))
        XCTAssertEqual((iconResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(Array(icon.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "icon must be a PNG")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(icon as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
    }

    func testViewerPageLinksTheWebApp() async throws {
        let port: UInt16 = 18127
        let server = try await startServer(on: port)
        defer { server.stop() }

        let (data, _) = try await URLSession.shared.data(from: url("/", port: port))
        let html = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(html.contains("rel=\"manifest\""))
        XCTAssertTrue(html.contains("apple-mobile-web-app-capable"))
        XCTAssertTrue(html.contains("visualViewport"), "layout must follow the visible viewport, not innerHeight")
    }

    func testUpgradesToWebSocketAndSpeaksControlProtocol() async throws {
        let port: UInt16 = 18125
        let server = try await startServer(on: port)
        defer { server.stop() }

        let socket = URLSession.shared.webSocketTask(with: url("/ws", port: port, scheme: "ws"))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        // The server introduces the stream before sending any frames.
        let metadata = try await nextTextMessage(from: socket)
        XCTAssertTrue(metadata.contains("\"type\":\"meta\""))
        XCTAssertTrue(metadata.contains("\"fps\":30"))
        XCTAssertTrue(metadata.contains("\"width\":1920"))

        // Latency probes come back untouched so the page can time the round trip.
        try await socket.send(.string("p42.5"))
        let echo = try await nextTextMessage(from: socket)
        XCTAssertEqual(echo, "p42.5")
    }

    func testStalePagesCanTellTheyAreStale() async throws {
        let port: UInt16 = 18128
        let server = try await startServer(on: port)
        defer { server.stop() }

        // The page carries its own version...
        let (data, _) = try await URLSession.shared.data(from: url("/", port: port))
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(html.contains("__PAGE_VERSION__"), "the version must be stamped in before serving")
        XCTAssertTrue(html.contains("const pageVersion = '\(BrowserStreamPage.version)'"))

        // ...and the server announces the one it would serve now, so a page
        // left open across an app update reloads instead of silently running
        // an old script against a new protocol.
        let socket = URLSession.shared.webSocketTask(with: url("/ws", port: port, scheme: "ws"))
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let metadata = try await nextTextMessage(from: socket)
        XCTAssertTrue(metadata.contains("\"page\":\"\(BrowserStreamPage.version)\""))
    }

    // MARK: - Helpers

    /// Returns the next text message, stepping over any frames and pointer
    /// updates pushed in the meantime.
    private func nextTextMessage(
        from socket: URLSessionWebSocketTask,
        maximumFrames: Int = 200
    ) async throws -> String {
        for _ in 0..<maximumFrames {
            switch try await socket.receive() {
            case .string(let text):
                // Pointer updates stream alongside everything else.
                if text.hasPrefix("m") || text.contains("\"type\":\"cursor\"") { continue }
                return text
            case .data(let frame):
                // Anything binary is a frame: a tile table, then JPEGs.
                let count = Int(frame[frame.startIndex])
                XCTAssertGreaterThan(count, 0)
                let firstJPEG = frame.startIndex + 1 + count * BrowserStreamServer.tileEntrySize
                XCTAssertEqual(Array(frame[firstJPEG..<firstJPEG + 2]), [0xFF, 0xD8])
            @unknown default:
                continue
            }
        }
        XCTFail("no text message arrived")
        return ""
    }

    private func startServer(on port: UInt16) async throws -> BrowserStreamServer {
        let server = BrowserStreamServer(
            configuration: BrowserStreamConfiguration(port: port, targetFPS: 30)
        )
        try server.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        try await Task.sleep(nanoseconds: 300_000_000)
        return server
    }

    private func url(_ path: String, port: UInt16, scheme: String = "http") -> URL {
        URL(string: "\(scheme)://127.0.0.1:\(port)\(path)")!
    }
}
