//
//  ScreenFrameSource.swift
//  VirtualDisplayKit
//
//  Captures a display straight onto a background queue and hands out
//  JPEG-encoded frames, ready to be pushed over a socket.
//
//  The hot path never touches the main thread: ScreenCaptureKit delivers
//  samples on our own capture queue, the GPU does the downscale, and the
//  frame is encoded in place from the sample's IOSurface.
//

import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import ScreenCaptureKit

/// Settings for a single capture + encode pipeline
struct ScreenFrameSourceConfiguration {
    var displayID: CGDirectDisplayID
    /// Output pixel size handed to the capture engine (GPU scaling, free)
    var outputSize: CGSize
    var targetFPS: Int
    /// Floor on emitted frames per second; 0 leaves a still screen silent
    var minimumFPS: Int
    var jpegQuality: Double
    var showCursor: Bool
    /// H.264 bitrate in bits per second; `nil` derives it from size, rate
    /// and quality
    var videoBitrate: Int? = nil
}

/// One JPEG-encoded rectangle of the screen.
struct EncodedTile {
    let data: Data

    /// Where the tile belongs, in output pixels with a top-left origin
    let rect: CGRect
}

/// Everything that changed in one captured frame.
///
/// Most frames are a set of *tiles*: only the rectangles that actually changed
/// since the previous frame. They travel and are painted together, so the
/// viewer never shows half of one frame next to half of another, and a busy
/// socket can never drop one tile while letting its sibling through.
struct EncodedFrame {
    let tiles: [EncodedTile]

    /// True when a single tile covers the whole frame
    let isFullFrame: Bool

    /// The area the frame repaints, for recovery when a viewer misses it
    var bounds: CGRect {
        tiles.reduce(CGRect.null) { $0.union($1.rect) }
    }

    var byteCount: Int {
        tiles.reduce(0) { $0 + $1.data.count }
    }
}

/// Captures a display and emits JPEG frames on the queue it was created with.
final class ScreenFrameSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    // MARK: - Callbacks

    /// Called on the capture queue for every encoded frame.
    var onFrame: ((EncodedFrame) -> Void)?

    /// Called on the capture queue for every H.264 frame.
    var onVideoFrame: ((EncodedVideoFrame) -> Void)?

    /// Called on the capture queue when capture cannot be started or dies.
    var onError: ((String) -> Void)?

    // MARK: - Private state

    private let queue: DispatchQueue
    private let encoder = JPEGFrameEncoder()
    private lazy var videoEncoder: H264FrameEncoder = {
        let encoder = H264FrameEncoder(queue: queue, frameRate: configuration.targetFPS, bitrate: videoBitrate)
        encoder.onFrame = { [weak self] frame in
            guard let self, !self.isStopped, self.hasVideoViewers else { return }
            self.onVideoFrame?(frame)
        }
        return encoder
    }()

    private var configuration: ScreenFrameSourceConfiguration
    private var stream: SCStream?
    private var displayStream: CGDisplayStream?
    private var isStopped = false

    /// Live quality, adjustable while streaming without restarting capture.
    private var quality: Double

    /// Reusable copy of the most recent frame, so a full frame can be produced
    /// on demand even while the screen sits perfectly still and the capture
    /// engine has nothing new to hand us.
    ///
    /// Each capture lands in a fresh buffer from `snapshotPool`: the video
    /// encoder may still be reading the previous one on the GPU, and writing
    /// over it would tear that frame.
    private var snapshot: CVPixelBuffer?
    private var snapshotPool: CVPixelBufferPool?

    private var lastFullFrameTime: CFAbsoluteTime = 0
    private var lastEmitTime: CFAbsoluteTime = 0
    private var lastVideoTime: CFAbsoluteTime = 0

    private var idleTimer: DispatchSourceTimer?
    private var idleBand = 0

    /// Regions a viewer failed to receive, folded into the next tile so it can
    /// catch up without anyone paying for a full-screen resend.
    private var pendingRecovery: CGRect = .null

    /// Encoding is pointless with nobody watching, but the snapshot is still
    /// kept current so the first viewer to arrive gets an instant full frame.
    /// Each format is only produced while someone is watching in it.
    private var hasJPEGViewers = false
    private var hasVideoViewers = false

    private var videoBitrate: Int {
        configuration.videoBitrate ?? H264FrameEncoder.bitrate(
            width: Int(configuration.outputSize.width),
            height: Int(configuration.outputSize.height),
            frameRate: configuration.targetFPS,
            quality: quality
        )
    }

    /// Beyond this fraction of the frame, send everything. Set high on
    /// purpose: a tile covering 80% still beats a full frame, and preferring
    /// full frames too eagerly turns a congested link into a worse one.
    private static let fullFrameAreaThreshold: CGFloat = 0.9

    /// A full frame at least this often — insurance only, since missed tiles
    /// are repaired by folding their region into the next update
    private static let fullFrameInterval: CFAbsoluteTime = 5.0

    /// Upper bound on tiles per frame. Tiles share one message and one ack, so
    /// the remaining cost of each is its JPEG header (~600 bytes) and a
    /// decode call in the viewer — cheap enough for finer cells than before.
    static let maximumTilesPerFrame = 8

    /// Merge two regions when the rectangle around them wastes no more than
    /// this fraction of their combined area.
    private static let mergeWasteTolerance: CGFloat = 0.4

    /// Horizontal bands the screen is refreshed in when idle. Sending a whole
    /// frame at the minimum rate would cost more than the live stream does;
    /// a band costs a sixth of that and still walks the whole screen.
    static let idleRefreshBands = 6

    init(queue: DispatchQueue, configuration: ScreenFrameSourceConfiguration) {
        self.queue = queue
        self.configuration = configuration
        self.quality = configuration.jpegQuality
        super.init()
    }

    // MARK: - Lifecycle

    /// Starts capture. Safe to call once; use `stop()` before reconfiguring.
    func start() {
        isStopped = false
        startIdleRefresh()
        Task { [weak self] in
            await self?.startScreenCaptureKit()
        }
    }

    /// Keeps frames flowing at `minimumFPS` even when nothing on screen moves.
    ///
    /// A still screen produces no captures at all, so without this the stream
    /// simply stops — correct, but indistinguishable from a stall. Each idle
    /// JPEG frame refreshes one horizontal band, so the cost stays bounded and
    /// the viewer converges on the truth even if it ever missed something.
    /// Idle video frames re-encode the still picture: nearly free as P-frames,
    /// and each one sharpens what the last moving frames left blurry.
    private func startIdleRefresh() {
        let floor = configuration.minimumFPS
        guard floor > 0 else { return }

        let interval = 1.0 / Double(floor)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval / 2)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if self.hasJPEGViewers, now - self.lastEmitTime >= interval {
                self.emitIdleBand()
            }
            if self.hasVideoViewers, now - self.lastVideoTime >= interval, let snapshot = self.snapshot {
                self.encodeVideo(snapshot)
            }
        }
        idleTimer = timer
        timer.resume()
    }

    /// The horizontal strip refreshed on idle pass `index`.
    ///
    /// Strips are laid out from the top and clipped at the bottom edge, so
    /// together they cover the frame exactly once per cycle.
    static func idleBand(_ index: Int, in frame: CGRect, bands: Int = idleRefreshBands) -> CGRect {
        let height = (frame.height / CGFloat(bands) / 2).rounded(.up) * 2
        let top = min(CGFloat(index % bands) * height, max(0, frame.height - height))
        return CGRect(x: 0, y: top, width: frame.width, height: min(height, frame.height - top))
    }

    private func emitIdleBand() {
        guard let snapshot else { return }

        let image = CIImage(cvPixelBuffer: snapshot)
        let frame = image.extent
        let band = Self.idleBand(idleBand, in: frame)
        idleBand = (idleBand + 1) % Self.idleRefreshBands

        guard band.height >= 1 else { return }

        let cropped = image.cropped(to: Self.cropRect(for: band, in: frame))
        guard let data = encoder.encode(cropped, quality: quality) else { return }

        lastEmitTime = CFAbsoluteTimeGetCurrent()
        onFrame?(EncodedFrame(tiles: [EncodedTile(data: data, rect: band)], isFullFrame: false))
    }

    func stop() {
        isStopped = true

        idleTimer?.cancel()
        idleTimer = nil

        if let stream {
            self.stream = nil
            Task {
                try? await stream.stopCapture()
            }
        }

        displayStream?.stop()
        displayStream = nil

        queue.async { [weak self] in
            self?.videoEncoder.invalidate()
        }
    }

    /// Updates JPEG quality without interrupting the capture session.
    func updateQuality(_ newQuality: Double) {
        queue.async { [weak self] in
            guard let self else { return }
            self.quality = min(max(newQuality, 0.1), 1.0)
            if self.configuration.videoBitrate == nil {
                self.videoEncoder.setBitrate(self.videoBitrate)
            }
        }
    }

    /// Starts or stops each encoder as viewers come and go.
    func setViewers(jpeg: Bool, video: Bool) {
        queue.async { [weak self] in
            self?.hasJPEGViewers = jpeg
            self?.hasVideoViewers = video
        }
    }

    /// Emits a keyframe right now, built from the last captured pixels — for a
    /// video viewer that just joined, even if the screen never moves again.
    func requestKeyframe() {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.videoEncoder.forceKeyframe()
            if let snapshot = self.snapshot { self.encodeVideo(snapshot) }
        }
    }

    /// Asks for a keyframe soon, for a video viewer that lost a frame and
    /// cannot decode anything until the next one.
    func requestRecoveryKeyframe() {
        queue.async { [weak self] in
            self?.videoEncoder.requestKeyframe()
        }
    }

    private func encodeVideo(_ pixelBuffer: CVPixelBuffer) {
        lastVideoTime = CFAbsoluteTimeGetCurrent()
        videoEncoder.encode(pixelBuffer)
    }

    /// Widens the next tile to cover a region a viewer missed.
    ///
    /// Far cheaper than a full frame: the repair rides along with the update
    /// that was going out anyway.
    func recover(region: CGRect) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingRecovery = self.pendingRecovery.union(region)
        }
    }

    /// Emits a complete frame right now, built from the last captured pixels.
    ///
    /// Needed when a viewer joins: it has nothing to paint tiles onto yet, and
    /// a still screen produces no new frames to wait for.
    func requestFullFrame() {
        queue.async { [weak self] in
            guard let self, !self.isStopped, let snapshot = self.snapshot else { return }
            self.emitFullFrame(CIImage(cvPixelBuffer: snapshot))
        }
    }

    // MARK: - ScreenCaptureKit

    private func startScreenCaptureKit() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

            guard !isStopped else { return }
            guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
                queue.async { [weak self] in
                    guard let self, !self.isStopped else { return }
                    self.startCGDisplayStreamFallback(reason: "display not listed in shareable content")
                }
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = Int(configuration.outputSize.width)
            streamConfiguration.height = Int(configuration.outputSize.height)
            streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfiguration.colorSpaceName = CGColorSpace.sRGB
            streamConfiguration.showsCursor = configuration.showCursor
            // Let the capture engine do the pacing: it simply never delivers
            // more than the target rate, so we burn nothing on dropped frames.
            streamConfiguration.minimumFrameInterval = CMTime(
                value: 1,
                timescale: CMTimeScale(max(1, configuration.targetFPS))
            )
            // Shallow queue keeps latency low; the engine drops frames when we
            // fall behind instead of building up a backlog.
            streamConfiguration.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: streamConfiguration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()

            guard !isStopped else {
                try? await stream.stopCapture()
                return
            }

            self.stream = stream

        } catch {
            let description = "\(error)"
            queue.async { [weak self] in
                guard let self, !self.isStopped else { return }
                if description.contains("-3801") || description.lowercased().contains("declined") {
                    self.onError?("Screen Recording permission denied. Grant it in System Settings › Privacy & Security › Screen Recording.")
                } else {
                    self.startCGDisplayStreamFallback(reason: description)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            self.onError?("Capture stopped: \(error.localizedDescription)")
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopped else { return }

        // Skip idle/blank frames — ScreenCaptureKit signals "nothing changed"
        // this way, and re-sending an identical frame just wastes bandwidth.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Keep a copy so a joining viewer can be sent a full frame even if the
        // screen never changes again.
        updateSnapshot(from: pixelBuffer)

        if hasVideoViewers {
            encodeVideo(pixelBuffer)
        }
        if hasJPEGViewers {
            emit(image: CIImage(cvPixelBuffer: pixelBuffer), dirtyRects: dirtyRects(in: attachments))
        }
    }

    /// The regions ScreenCaptureKit says changed, in output pixels with a
    /// top-left origin.
    private func dirtyRects(in attachments: [[SCStreamFrameInfo: Any]]) -> [CGRect] {
        guard let raw = attachments.first?[.dirtyRects] as? [[String: Any]] else { return [] }
        return raw.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    // MARK: - CGDisplayStream fallback

    private func startCGDisplayStreamFallback(reason: String) {
        guard displayStream == nil else { return }

        let width = Int(configuration.outputSize.width)
        let height = Int(configuration.outputSize.height)
        let minimumFrameTime = 1.0 / Double(max(1, configuration.targetFPS))

        let stream = CGDisplayStream(
            dispatchQueueDisplay: configuration.displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: 1_111_970_369, // 'BGRA'
            properties: [
                CGDisplayStream.showCursor: configuration.showCursor,
                CGDisplayStream.minimumFrameTime: minimumFrameTime,
            ] as CFDictionary,
            queue: queue,
            handler: { [weak self] status, _, surface, _ in
                guard let self, !self.isStopped else { return }
                guard status == .frameComplete, let surface else { return }

                var wrapped: Unmanaged<CVPixelBuffer>?
                CVPixelBufferCreateWithIOSurface(nil, surface, nil, &wrapped)
                if let pixelBuffer = wrapped?.takeRetainedValue() {
                    self.updateSnapshot(from: pixelBuffer)
                    if self.hasVideoViewers { self.encodeVideo(pixelBuffer) }
                }

                // CGDisplayStream reports changed regions differently; the
                // fallback path just sends whole frames.
                if self.hasJPEGViewers { self.emitFullFrame(CIImage(ioSurface: surface)) }
            }
        )

        guard let stream, stream.start() == .success else {
            onError?("Unable to capture display \(configuration.displayID) (\(reason))")
            return
        }

        displayStream = stream
    }

    // MARK: - Encoding

    private func emit(image: CIImage, dirtyRects: [CGRect]) {
        let frame = image.extent
        let now = CFAbsoluteTimeGetCurrent()

        // Periodic full frames keep a viewer honest if anything ever slips.
        guard lastFullFrameTime > 0, now - lastFullFrameTime < Self.fullFrameInterval else {
            emitFullFrame(image)
            return
        }

        var regions = dirtyRects
        if !pendingRecovery.isNull { regions.append(pendingRecovery) }
        pendingRecovery = .null

        let usable = regions
            .map { $0.intersection(frame) }
            .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
            .map { Self.align($0, within: frame) }

        // Nothing moved: the viewer already shows the right pixels.
        guard !usable.isEmpty else { return }

        let tiles = Self.mergeTiles(usable, limit: Self.maximumTilesPerFrame)
        let covered = tiles.reduce(CGFloat.zero) { $0 + $1.width * $1.height }

        guard covered < frame.width * frame.height * Self.fullFrameAreaThreshold else {
            emitFullFrame(image)
            return
        }

        let encoded = tiles.compactMap { tile -> EncodedTile? in
            let cropped = image.cropped(to: Self.cropRect(for: tile, in: frame))
            guard let data = encoder.encode(cropped, quality: quality) else { return nil }
            return EncodedTile(data: data, rect: tile)
        }
        guard !encoded.isEmpty else { return }

        lastEmitTime = now
        onFrame?(EncodedFrame(tiles: encoded, isFullFrame: false))
    }

    /// Groups changed regions into a handful of tiles.
    ///
    /// The bounding box of every change is a trap: a moving cursor in one
    /// corner and a ticking clock in the other span the whole screen while
    /// almost nothing actually changed. Merging is only worth it when the
    /// rectangle it produces is not much bigger than the parts.
    static func mergeTiles(_ rects: [CGRect], limit: Int) -> [CGRect] {
        var tiles = rects
        guard tiles.count > 1 else { return tiles }

        while tiles.count > 1 {
            var best = (first: 0, second: 1, wastedArea: CGFloat.greatestFiniteMagnitude)

            for i in 0..<tiles.count {
                for j in (i + 1)..<tiles.count {
                    let merged = tiles[i].union(tiles[j])
                    let wasted = merged.width * merged.height
                        - tiles[i].width * tiles[i].height
                        - tiles[j].width * tiles[j].height
                    if wasted < best.wastedArea { best = (i, j, wasted) }
                }
            }

            let combinedArea = tiles[best.first].width * tiles[best.first].height
                + tiles[best.second].width * tiles[best.second].height

            // Merge when forced under the tile budget, or when the merge is
            // close to free — each extra tile carries its own JPEG header.
            let overBudget = tiles.count > limit
            let nearlyFree = best.wastedArea <= combinedArea * Self.mergeWasteTolerance
            guard overBudget || nearlyFree else { break }

            let merged = tiles[best.first].union(tiles[best.second])
            tiles.remove(at: best.second)
            tiles.remove(at: best.first)
            tiles.append(merged)
        }

        return tiles
    }

    private func emitFullFrame(_ image: CIImage) {
        guard let data = encoder.encode(image, quality: quality) else { return }
        lastFullFrameTime = CFAbsoluteTimeGetCurrent()
        lastEmitTime = lastFullFrameTime
        pendingRecovery = .null
        onFrame?(
            EncodedFrame(
                tiles: [EncodedTile(data: data, rect: CGRect(origin: .zero, size: image.extent.size))],
                isFullFrame: true
            )
        )
    }

    /// Converts a tile from ScreenCaptureKit's top-left origin into the
    /// bottom-left origin Core Image crops with.
    static func cropRect(for tile: CGRect, in frame: CGRect) -> CGRect {
        CGRect(
            x: tile.origin.x,
            y: frame.height - tile.maxY,
            width: tile.width,
            height: tile.height
        )
    }

    /// Snaps a tile out to even pixel bounds, so chroma subsampling never has
    /// to guess at a half-covered pixel pair.
    static func align(_ rect: CGRect, within frame: CGRect) -> CGRect {
        let minX = max(0, (rect.minX / 2).rounded(.down) * 2)
        let minY = max(0, (rect.minY / 2).rounded(.down) * 2)
        let maxX = min(frame.width, (rect.maxX / 2).rounded(.up) * 2)
        let maxY = min(frame.height, (rect.maxY / 2).rounded(.up) * 2)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Copies the frame into a buffer we own. The pool recycles buffers, so
    /// this costs a copy rather than an allocation per frame.
    private func updateSnapshot(from pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if snapshotPool == nil
            || snapshot.map({ CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) == true {
            snapshotPool = nil
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                [
                    kCVPixelBufferWidthKey: width,
                    kCVPixelBufferHeightKey: height,
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                ] as CFDictionary,
                &snapshotPool
            )
        }

        // The pool hands back a buffer nobody else still holds.
        var created: CVPixelBuffer?
        if let snapshotPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, snapshotPool, &created)
        }
        guard let destination = created else { return }
        snapshot = destination

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let source = CVPixelBufferGetBaseAddress(pixelBuffer),
              let target = CVPixelBufferGetBaseAddress(destination) else { return }

        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let targetStride = CVPixelBufferGetBytesPerRow(destination)

        if sourceStride == targetStride {
            memcpy(target, source, sourceStride * height)
        } else {
            let rowBytes = min(sourceStride, targetStride)
            for row in 0..<height {
                memcpy(target.advanced(by: row * targetStride), source.advanced(by: row * sourceStride), rowBytes)
            }
        }
    }
}

// MARK: - JPEG Encoder

/// GPU-backed JPEG encoder with a reusable Core Image context.
///
/// Creating the `CIContext` once matters a lot: a fresh context per frame
/// would recompile shaders and re-allocate GPU resources every time.
final class JPEGFrameEncoder {

    private let context: CIContext
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    init() {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .highQualityDownsample: false,
        ]
        options[.workingColorSpace] = colorSpace
        options[.outputColorSpace] = colorSpace

        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    func encode(_ image: CIImage, quality: Double) -> Data? {
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }
}
