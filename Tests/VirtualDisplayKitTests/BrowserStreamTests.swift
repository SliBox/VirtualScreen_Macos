//
//  BrowserStreamTests.swift
//  VirtualDisplayKit
//

import AppKit
import XCTest
@testable import VirtualDisplayKit

final class BrowserStreamTests: XCTestCase {

    // MARK: - WebSocket Framing

    func testEncodesShortPayloadHeader() {
        let header = WebSocketEncoder.header(opcode: .binary, payloadLength: 5)

        XCTAssertEqual(header.count, 2)
        XCTAssertEqual(header[0], 0x82) // FIN + binary
        XCTAssertEqual(header[1], 5)    // unmasked, length in-line
    }

    func testEncodesMediumPayloadHeader() {
        let header = WebSocketEncoder.header(opcode: .binary, payloadLength: 40_000)

        XCTAssertEqual(header.count, 4)
        XCTAssertEqual(header[1], 126)
        XCTAssertEqual(Int(header[2]) << 8 | Int(header[3]), 40_000)
    }

    func testEncodesLargePayloadHeader() {
        let length = 200_000
        let header = WebSocketEncoder.header(opcode: .binary, payloadLength: length)

        XCTAssertEqual(header.count, 10)
        XCTAssertEqual(header[1], 127)

        var decoded = 0
        for byte in header[2..<10] { decoded = decoded << 8 | Int(byte) }
        XCTAssertEqual(decoded, length)
    }

    func testDecodesMaskedClientFrame() throws {
        var decoder = WebSocketFrameDecoder()
        decoder.append(maskedClientFrame(opcode: .text, payload: Data("ack".utf8)))

        let frame = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(frame.opcode, .text)
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "ack")
        XCTAssertTrue(frame.isFinal)

        XCTAssertNil(try decoder.next(), "buffer should be drained")
    }

    func testDecodesFramesArrivingAcrossPackets() throws {
        let frame = maskedClientFrame(opcode: .text, payload: Data("hello".utf8))
        var decoder = WebSocketFrameDecoder()

        decoder.append(frame.prefix(3))
        XCTAssertNil(try decoder.next(), "partial frame must not decode")

        decoder.append(frame.dropFirst(3))
        let decoded = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(String(decoding: decoded.payload, as: UTF8.self), "hello")
    }

    func testDecodesBackToBackFrames() throws {
        var decoder = WebSocketFrameDecoder()
        decoder.append(maskedClientFrame(opcode: .text, payload: Data("a".utf8)))
        decoder.append(maskedClientFrame(opcode: .ping, payload: Data()))

        XCTAssertEqual(try decoder.next()?.opcode, .text)
        XCTAssertEqual(try decoder.next()?.opcode, .ping)
        XCTAssertNil(try decoder.next())
    }

    func testRejectsOversizedPayload() {
        var decoder = WebSocketFrameDecoder(maxPayloadSize: 16)
        decoder.append(maskedClientFrame(opcode: .binary, payload: Data(repeating: 0, count: 64)))

        XCTAssertThrowsError(try decoder.next())
    }

    // MARK: - Handshake

    func testHandshakeAcceptKeyMatchesRFC6455Example() {
        // The example key/response pair from RFC 6455 §1.3
        XCTAssertEqual(
            WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    // MARK: - Output Sizing

    func testOutputSizeKeepsAspectRatioWhenCapped() {
        var configuration = BrowserStreamConfiguration()
        configuration.scale = 1.0
        configuration.maximumWidth = 1920

        let size = BrowserStreamServer.outputSize(
            for: CGSize(width: 3840, height: 2160),
            configuration: configuration
        )

        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1080)
    }

    func testOutputSizeStreamsNativeWidthWhenUncapped() {
        var configuration = BrowserStreamConfiguration()
        configuration.scale = 1.0
        configuration.maximumWidth = nil

        let size = BrowserStreamServer.outputSize(
            for: CGSize(width: 3840, height: 2160),
            configuration: configuration
        )

        XCTAssertEqual(size.width, 3840)
        XCTAssertEqual(size.height, 2160)
    }

    func testOutputSizeIsUncappedByDefault() {
        XCTAssertNil(BrowserStreamConfiguration().maximumWidth)

        let size = BrowserStreamServer.outputSize(
            for: CGSize(width: 2560, height: 1440),
            configuration: BrowserStreamConfiguration()
        )

        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 1440)
    }

    func testOutputSizeAppliesScale() {
        var configuration = BrowserStreamConfiguration()
        configuration.scale = 0.5
        configuration.maximumWidth = 4096

        let size = BrowserStreamServer.outputSize(
            for: CGSize(width: 1920, height: 1080),
            configuration: configuration
        )

        XCTAssertEqual(size.width, 960)
        XCTAssertEqual(size.height, 540)
    }

    func testOutputSizeIsAlwaysEven() {
        var configuration = BrowserStreamConfiguration()
        configuration.scale = 0.33
        configuration.maximumWidth = 4096

        let size = BrowserStreamServer.outputSize(
            for: CGSize(width: 1921, height: 1081),
            configuration: configuration
        )

        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
    }

    // MARK: - JPEG Encoding

    func testEncodesPixelBufferToJPEG() throws {
        let encoder = JPEGFrameEncoder()
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))

        let data = try XCTUnwrap(encoder.encode(image, quality: 0.6))

        // JPEG SOI marker
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 640)
        XCTAssertEqual(decoded.height, 360)
    }

    func testLowerQualityProducesSmallerFrames() throws {
        let encoder = JPEGFrameEncoder()

        // Random noise: incompressible enough that the quality setting shows up
        // clearly in the output size.
        let noise = try XCTUnwrap(CIFilter(name: "CIRandomGenerator")?.outputImage)
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))

        let high = try XCTUnwrap(encoder.encode(noise, quality: 0.95))
        let low = try XCTUnwrap(encoder.encode(noise, quality: 0.25))

        XCTAssertLessThan(low.count, high.count, "quality must actually reach the encoder")
    }

    // MARK: - Helpers

    /// Builds a client-to-server frame, which RFC 6455 requires to be masked.
    private func maskedClientFrame(opcode: WebSocketOpcode, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode.rawValue)

        let mask: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]

        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }

        frame.append(contentsOf: mask)
        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }

        return frame
    }
}

// MARK: - Tile Geometry

final class TileGeometryTests: XCTestCase {

    /// A pixel buffer whose four quadrants are distinct solid colours, laid out
    /// with row 0 at the top the way a captured frame is.
    private func makeQuadrantBuffer(side: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let half = side / 2

        for y in 0..<side {
            for x in 0..<side {
                // BGRA: top-left red, top-right green, bottom-left blue, bottom-right white
                let (b, g, r): (UInt8, UInt8, UInt8)
                switch (y < half, x < half) {
                case (true, true):   (b, g, r) = (0, 0, 255)
                case (true, false):  (b, g, r) = (0, 255, 0)
                case (false, true):  (b, g, r) = (255, 0, 0)
                case (false, false): (b, g, r) = (255, 255, 255)
                }
                let offset = y * stride + x * 4
                base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    /// A smooth gradient with a hard-edged block — screen-like enough to give
    /// the video encoder real work.
    private func makeGradientBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary,
            &buffer
        )
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                let inBlock = x > width / 4 && x < width / 2 && y > height / 4 && y < height / 2
                base[offset] = inBlock ? 255 : UInt8(x * 255 / width)
                base[offset + 1] = inBlock ? 255 : UInt8(y * 255 / height)
                base[offset + 2] = inBlock ? 255 : 128
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func centreColour(of jpeg: Data) throws -> (r: Int, g: Int, b: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw the tile scaled down to a single pixel: a solid tile averages to itself.
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testTopLeftTileCropsTheTopLeftOfTheFrame() throws {
        let image = CIImage(cvPixelBuffer: makeQuadrantBuffer(side: 200))
        let frame = image.extent
        let tile = CGRect(x: 0, y: 0, width: 100, height: 100) // top-left, screen coordinates

        let cropped = image.cropped(to: ScreenFrameSource.cropRect(for: tile, in: frame))
        let jpeg = try XCTUnwrap(JPEGFrameEncoder().encode(cropped, quality: 0.95))

        let colour = try centreColour(of: jpeg)
        XCTAssertGreaterThan(colour.r, 200, "top-left quadrant is red")
        XCTAssertLessThan(colour.g, 60)
        XCTAssertLessThan(colour.b, 60)
    }

    func testBottomRightTileCropsTheBottomRightOfTheFrame() throws {
        let image = CIImage(cvPixelBuffer: makeQuadrantBuffer(side: 200))
        let frame = image.extent
        let tile = CGRect(x: 100, y: 100, width: 100, height: 100)

        let cropped = image.cropped(to: ScreenFrameSource.cropRect(for: tile, in: frame))
        let jpeg = try XCTUnwrap(JPEGFrameEncoder().encode(cropped, quality: 0.95))

        let colour = try centreColour(of: jpeg)
        XCTAssertGreaterThan(colour.r, 200, "bottom-right quadrant is white")
        XCTAssertGreaterThan(colour.g, 200)
        XCTAssertGreaterThan(colour.b, 200)
    }

    func testTopRightTileCropsTheTopRightOfTheFrame() throws {
        let image = CIImage(cvPixelBuffer: makeQuadrantBuffer(side: 200))
        let frame = image.extent
        let tile = CGRect(x: 100, y: 0, width: 100, height: 100)

        let cropped = image.cropped(to: ScreenFrameSource.cropRect(for: tile, in: frame))
        let jpeg = try XCTUnwrap(JPEGFrameEncoder().encode(cropped, quality: 0.95))

        let colour = try centreColour(of: jpeg)
        XCTAssertGreaterThan(colour.g, 200, "top-right quadrant is green")
        XCTAssertLessThan(colour.r, 60)
    }

    // MARK: - Tile Merging

    /// The case that motivated tiling: a moving cursor in one corner and a
    /// clock ticking in the other. Their bounding box is the whole screen.
    func testDistantChangesStayApart() {
        let cursor = CGRect(x: 0, y: 0, width: 24, height: 24)
        let clock = CGRect(x: 1240, y: 690, width: 40, height: 30)

        let tiles = ScreenFrameSource.mergeTiles([cursor, clock], limit: 4)

        XCTAssertEqual(tiles.count, 2, "merging these would send the entire screen")
        let area = tiles.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        XCTAssertLessThan(area, 2000, "should stay close to the 1776px actually changed")
    }

    func testOverlappingChangesMerge() {
        let tiles = ScreenFrameSource.mergeTiles([
            CGRect(x: 100, y: 100, width: 200, height: 200),
            CGRect(x: 150, y: 150, width: 200, height: 200),
        ], limit: 4)

        XCTAssertEqual(tiles.count, 1, "overlapping regions cost nothing to merge")
    }

    func testAdjacentChangesMerge() {
        let tiles = ScreenFrameSource.mergeTiles([
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 100, y: 0, width: 100, height: 100),
        ], limit: 4)

        XCTAssertEqual(tiles.count, 1, "touching regions tile perfectly")
        XCTAssertEqual(tiles[0], CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    func testTileCountIsCapped() {
        let scattered = (0..<12).map { index in
            CGRect(x: CGFloat(index) * 100, y: CGFloat(index) * 50, width: 20, height: 20)
        }

        let tiles = ScreenFrameSource.mergeTiles(scattered, limit: 4)

        XCTAssertLessThanOrEqual(tiles.count, 4)
        XCTAssertGreaterThan(tiles.count, 0)
    }

    func testMergingCoversEveryChange() {
        let changes = [
            CGRect(x: 10, y: 10, width: 30, height: 30),
            CGRect(x: 400, y: 300, width: 50, height: 50),
            CGRect(x: 1200, y: 20, width: 40, height: 40),
            CGRect(x: 600, y: 600, width: 60, height: 20),
            CGRect(x: 900, y: 100, width: 25, height: 25),
        ]

        let tiles = ScreenFrameSource.mergeTiles(changes, limit: 3)

        // Nothing may be dropped, or the viewer keeps a stale patch forever.
        for change in changes {
            XCTAssertTrue(
                tiles.contains { $0.contains(change) },
                "\(change) is not covered by any tile"
            )
        }
    }

    // MARK: - Idle Refresh

    func testH264EncoderStartsWithAKeyframeCarryingItsConfiguration() throws {
        let queue = DispatchQueue(label: "test.h264")
        let encoder = H264FrameEncoder(queue: queue, frameRate: 30, bitrate: 4_000_000)
        var frames: [EncodedVideoFrame] = []
        let done = expectation(description: "frames encoded")
        encoder.onFrame = { frame in
            frames.append(frame)
            if frames.count == 3 { done.fulfill() }
        }

        let pixels = try makeGradientBuffer(width: 640, height: 360)
        queue.sync {
            for _ in 0..<3 { encoder.encode(pixels) }
        }
        wait(for: [done], timeout: 5)
        queue.sync { encoder.invalidate() }

        let first = try XCTUnwrap(frames.first)
        XCTAssertTrue(first.isKeyframe)
        let avcC = try XCTUnwrap(first.configuration, "keyframes carry the decoder configuration")
        XCTAssertEqual(avcC.first, 1, "avcC version")
        XCTAssertEqual(avcC[avcC.startIndex + 4] & 0x03, 3, "NAL lengths are 4 bytes")
        // Without this, browsers hold decoded frames back waiting for
        // reordering that never comes.
        XCTAssertEqual(H264ReorderRestriction.declaredReorderFrames(in: avcC), 0, "the SPS must promise no frame reordering")

        // AVCC: the first NAL's length prefix must fit inside the frame.
        let nalLength = first.data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        XCTAssertGreaterThan(nalLength, 0)
        XCTAssertLessThanOrEqual(nalLength + 4, first.data.count)

        XCTAssertFalse(frames[1].isKeyframe, "an unchanged picture needs no second keyframe")
        XCTAssertNil(frames[1].configuration)
        XCTAssertLessThan(frames[0].timestamp, frames[1].timestamp)
    }

    func testVideoWirePrefixCarriesConfigurationOnlyOnKeyframes() {
        let key = EncodedVideoFrame(data: Data([0, 0, 0, 1, 0x65]), isKeyframe: true, configuration: Data([1, 0x64, 0, 0x28]), timestamp: 0x01020304)
        let keyPrefix = BrowserStreamServer.wirePrefix(for: key)
        let keyHeader = Array(keyPrefix.suffix(11))
        XCTAssertEqual(keyHeader, [0x03, 0x01, 0x02, 0x03, 0x04, 0x00, 0x04, 1, 0x64, 0, 0x28])

        let delta = EncodedVideoFrame(data: Data([0, 0, 0, 1, 0x41]), isKeyframe: false, configuration: nil, timestamp: 5)
        let deltaPrefix = BrowserStreamServer.wirePrefix(for: delta)
        XCTAssertEqual(Array(deltaPrefix.suffix(5)), [0x00, 0, 0, 0, 5])
        // Two-byte WebSocket header: payload is the 5-byte header plus data.
        XCTAssertEqual(deltaPrefix.count, 2 + 5)
        XCTAssertEqual(deltaPrefix[deltaPrefix.startIndex + 1], 10)
    }

    func testCursorPositionMapsDisplayPointsToStreamPixels() {
        // A HiDPI display at x=1920 in global space, streamed at 2x its points.
        let bounds = CGRect(x: 1920, y: 0, width: 1440, height: 900)
        let output = CGSize(width: 2880, height: 1800)

        XCTAssertEqual(CursorSource.position(of: CGPoint(x: 1920, y: 0), in: bounds, outputSize: output), .zero)
        XCTAssertEqual(
            CursorSource.position(of: CGPoint(x: 2640, y: 450), in: bounds, outputSize: output),
            CGPoint(x: 1440, y: 900)
        )
        XCTAssertNil(CursorSource.position(of: CGPoint(x: 100, y: 100), in: bounds, outputSize: output), "pointer on another display")
        XCTAssertNil(CursorSource.position(of: CGPoint(x: 3360, y: 10), in: bounds, outputSize: output), "right edge belongs to the next display")
    }

    func testCursorMessagesAreCompactAndParseable() throws {
        XCTAssertEqual(BrowserStreamServer.cursorPositionMessage(for: CGPoint(x: 12.345, y: 678), at: 1500.25), "m12.3,678.0,1500.2")
        XCTAssertEqual(BrowserStreamServer.cursorPositionMessage(for: nil, at: 9), "m")

        let shape = CursorShape(png: Data([1, 2, 3]), size: CGSize(width: 34, height: 44), hotSpot: CGPoint(x: 8, y: 6))
        let message = BrowserStreamServer.cursorShapeMessage(for: shape)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "cursor")
        XCTAssertEqual(parsed["image"] as? String, "data:image/png;base64,AQID")
        XCTAssertEqual(parsed["hotX"] as? Double, 8)
        XCTAssertEqual(parsed["height"] as? Double, 44)
    }

    func testCursorImageRendersAtTwiceItsPointSize() throws {
        let png = try XCTUnwrap(CursorSource.png(of: NSCursor.arrow.image))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(CGFloat(image.width), (NSCursor.arrow.image.size.width * 2).rounded())
    }

    func testWirePrefixDescribesEveryTileOfAFrame() {
        let frame = EncodedFrame(
            tiles: [
                EncodedTile(data: Data(repeating: 1, count: 300), rect: CGRect(x: 10, y: 20, width: 64, height: 32)),
                EncodedTile(data: Data(repeating: 2, count: 70_000), rect: CGRect(x: 1000, y: 500, width: 256, height: 128)),
            ],
            isFullFrame: false
        )

        let prefix = BrowserStreamServer.wirePrefix(for: frame)
        let tableSize = 1 + 2 * BrowserStreamServer.tileEntrySize
        let table = Array(prefix.suffix(tableSize))

        // Length in the WebSocket header covers the table and both JPEGs.
        XCTAssertEqual(prefix.count - tableSize, WebSocketEncoder.header(opcode: .binary, payloadLength: tableSize + 70_300).count)

        XCTAssertEqual(table[0], 2, "one message carries every tile of the frame")
        XCTAssertEqual(Array(table[1..<13]), [0, 10, 0, 20, 0, 64, 0, 32, 0, 0, 0x01, 0x2C])
        XCTAssertEqual(Array(table[13..<25]), [0x03, 0xE8, 0x01, 0xF4, 0x01, 0x00, 0, 128, 0, 0x01, 0x11, 0x70])
    }

    func testIdleBandsCoverTheWholeFrameOncePerCycle() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        var covered = [Bool](repeating: false, count: 720)

        for index in 0..<ScreenFrameSource.idleRefreshBands {
            let band = ScreenFrameSource.idleBand(index, in: frame)
            XCTAssertEqual(band.width, frame.width, "bands span the full width")
            XCTAssertGreaterThan(band.height, 0)
            for row in Int(band.minY)..<Int(band.maxY) { covered[row] = true }
        }

        XCTAssertFalse(covered.contains(false), "every row is refreshed within one cycle")
    }

    func testIdleBandCostsAFractionOfAFullFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let band = ScreenFrameSource.idleBand(0, in: frame)

        let share = (band.width * band.height) / (frame.width * frame.height)
        XCTAssertLessThan(share, 0.2, "an idle refresh should cost far less than a full frame")
    }

    func testIdleBandsStayInsideAnAwkwardFrameHeight() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 601)

        for index in 0..<ScreenFrameSource.idleRefreshBands {
            let band = ScreenFrameSource.idleBand(index, in: frame)
            XCTAssertGreaterThanOrEqual(band.minY, 0)
            XCTAssertLessThanOrEqual(band.maxY, frame.height, "band \(index) runs past the bottom")
        }
    }

    func testCroppedTileKeepsItsSize() throws {
        let image = CIImage(cvPixelBuffer: makeQuadrantBuffer(side: 200))
        let cropped = image.cropped(to: ScreenFrameSource.cropRect(
            for: CGRect(x: 20, y: 30, width: 64, height: 48), in: image.extent
        ))
        XCTAssertEqual(cropped.extent.width, 64)
        XCTAssertEqual(cropped.extent.height, 48)
    }
}
