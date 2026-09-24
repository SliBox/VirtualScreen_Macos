//
//  BrowserStreamThroughputTests.swift
//  VirtualDisplayKit
//
//  Guards the property that a distant viewer still gets a full frame rate.
//
//  Throughput is `framesInFlight / roundTrip`, so a fixed in-flight window
//  silently caps frame rate as latency rises — a bug that is invisible on
//  loopback and obvious on Wi-Fi. These tests put the latency back.
//

import XCTest
@testable import VirtualDisplayKit

final class BrowserStreamThroughputTests: XCTestCase {

    /// Streams to a viewer that takes `ackDelay` to confirm each frame.
    /// Acks are sent off the receive loop, so the delay models round-trip time
    /// rather than a reader that has stopped reading.
    private func framesPerSecond(ackDelay: Duration, port: UInt16, seconds: Double = 3) async throws -> Int {
        let server = BrowserStreamServer(configuration: BrowserStreamConfiguration(
            port: port, targetFPS: 30, jpegQuality: 0.6, scale: 1.0, maximumWidth: 1280))
        try server.start(displayID: CGMainDisplayID(), pixelSize: CGSize(width: 1920, height: 1080))
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 600_000_000)

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        let counter = Counter()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            guard case .data = try await socket.receive() else { continue }
            await counter.record()
            Task {
                try? await Task.sleep(for: ackDelay)
                try? await socket.send(.string("a"))
            }
        }

        return Int(Double(await counter.total()) / seconds)
    }

    private actor Counter {
        private var frames = 0
        func record() { frames += 1 }
        func total() -> Int { frames }
    }

    func testFrameRateSurvivesA150msRoundTrip() async throws {
        let nearby = try await framesPerSecond(ackDelay: .zero, port: 18210)

        // The capture side only emits frames when the screen changes, so a
        // still desktop leaves nothing to compare.
        try XCTSkipIf(nearby < 5, "display too quiet to measure throughput")

        let distant = try await framesPerSecond(ackDelay: .milliseconds(150), port: 18211)

        XCTAssertGreaterThan(
            Double(distant), Double(nearby) * 0.7,
            "a 150ms viewer got \(distant) fps against \(nearby) fps nearby — the in-flight window is not covering the round trip"
        )
    }

    func testWindowGrowsWithMeasuredRoundTrip() {
        let server = BrowserStreamServer(configuration: BrowserStreamConfiguration(targetFPS: 30))

        // 30 fps means a frame every 33ms, so a 100ms round trip needs about
        // four frames in flight just to keep the link busy.
        XCTAssertEqual(server.framesInFlightWindow(forRoundTrip: 0), 2, "conservative until measured")
        XCTAssertEqual(server.framesInFlightWindow(forRoundTrip: 0.010), 2)
        XCTAssertEqual(server.framesInFlightWindow(forRoundTrip: 0.100), 4)
        XCTAssertEqual(server.framesInFlightWindow(forRoundTrip: 5.0), 6, "clamped so latency stays bounded")
    }
}
