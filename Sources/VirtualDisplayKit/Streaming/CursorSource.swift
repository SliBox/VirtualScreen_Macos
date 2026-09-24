//
//  CursorSource.swift
//  VirtualDisplayKit
//
//  Follows the mouse pointer on the streamed display so viewers can draw it
//  themselves. A cursor baked into the frames moves only as fast as frames
//  are encoded, sent and decoded; a few bytes of coordinates arrive ahead of
//  all of that, so the pointer stays smooth even when the picture can't.
//

import AppKit
import Foundation

/// The pointer's appearance, in output pixels.
struct CursorShape: Equatable {
    /// PNG of the cursor, rendered at `renderScale` times its point size so
    /// it stays sharp when a viewer zooms in
    let png: Data

    /// Size and hot spot in output pixels of the stream
    let size: CGSize
    let hotSpot: CGPoint
}

/// Polls the pointer's position and shape and reports changes on `queue`.
///
/// Only ever touched on `queue` (position) and the main queue (shape, which
/// needs AppKit) — which is what makes the unchecked conformance safe.
final class CursorSource: @unchecked Sendable {

    /// Position in output pixels (or `nil` when the pointer is off the
    /// display), and when it was read. Viewers interpolate on these times, so
    /// timer jitter here doesn't turn into uneven motion there.
    var onPosition: ((CGPoint?, CFAbsoluteTime) -> Void)?

    var onShape: ((CursorShape) -> Void)?

    private let displayID: CGDirectDisplayID
    private let outputSize: CGSize
    private let queue: DispatchQueue

    private var positionTimer: DispatchSourceTimer?
    private var shapeTimer: DispatchSourceTimer?

    private var lastPosition: CGPoint?
    private var hasReportedPosition = false

    /// Main queue only
    private var lastShapeImage: Data?

    /// Faster than any display refreshes, so the viewer's own frame rate is
    /// the only limit on how smoothly the pointer moves.
    static let positionRate: Double = 120

    /// Shape changes (arrow, I-beam, hand) are rarer, and reading one
    /// involves AppKit on the main thread.
    static let shapeRate: Double = 20

    /// Cursors are drawn at this multiple of their point size.
    static let renderScale: CGFloat = 2

    init(displayID: CGDirectDisplayID, outputSize: CGSize, queue: DispatchQueue) {
        self.displayID = displayID
        self.outputSize = outputSize
        self.queue = queue
    }

    deinit {
        positionTimer?.cancel()
        shapeTimer?.cancel()
    }

    func start() {
        let position = DispatchSource.makeTimerSource(queue: queue)
        position.schedule(deadline: .now(), repeating: 1 / Self.positionRate, leeway: .milliseconds(1))
        position.setEventHandler { [weak self] in self?.pollPosition() }
        positionTimer = position
        position.resume()

        let shape = DispatchSource.makeTimerSource(queue: .main)
        shape.schedule(deadline: .now(), repeating: 1 / Self.shapeRate)
        shape.setEventHandler { [weak self] in self?.pollShape() }
        shapeTimer = shape
        shape.resume()
    }

    func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        shapeTimer?.cancel()
        shapeTimer = nil
    }

    /// Scale from the display's points to the stream's pixels
    private var pointsToPixels: CGFloat {
        let bounds = CGDisplayBounds(displayID)
        return bounds.width > 0 ? outputSize.width / bounds.width : 1
    }

    // MARK: - Position

    private func pollPosition() {
        // CGEvent reads the location with a top-left origin in global display
        // space, the same space CGDisplayBounds uses — and needs no main thread.
        guard let location = CGEvent(source: nil)?.location else { return }
        let time = CFAbsoluteTimeGetCurrent()
        let position = Self.position(of: location, in: CGDisplayBounds(displayID), outputSize: outputSize)

        guard !hasReportedPosition || position != lastPosition else { return }
        hasReportedPosition = true
        lastPosition = position
        onPosition?(position, time)
    }

    /// Maps a global pointer location onto the stream, or `nil` when the
    /// pointer is on another display.
    static func position(of location: CGPoint, in bounds: CGRect, outputSize: CGSize) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0,
              location.x >= bounds.minX, location.x < bounds.maxX,
              location.y >= bounds.minY, location.y < bounds.maxY else { return nil }
        return CGPoint(
            x: (location.x - bounds.minX) * outputSize.width / bounds.width,
            y: (location.y - bounds.minY) * outputSize.height / bounds.height
        )
    }

    // MARK: - Shape

    private func pollShape() {
        // Deprecated, and documented to return nil on some future macOS; a
        // plain arrow beats no pointer at all.
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image

        // Cursor images are tiny, so comparing their bytes is cheap and
        // catches every change, including ones that keep the same size.
        guard let identity = image.tiffRepresentation, identity != lastShapeImage else { return }
        lastShapeImage = identity

        guard let png = Self.png(of: image) else { return }

        let scale = pointsToPixels
        let shape = CursorShape(
            png: png,
            size: CGSize(width: image.size.width * scale, height: image.size.height * scale),
            hotSpot: CGPoint(x: cursor.hotSpot.x * scale, y: cursor.hotSpot.y * scale)
        )
        queue.async { [weak self] in
            self?.onShape?(shape)
        }
    }

    static func png(of image: NSImage) -> Data? {
        let width = Int((image.size.width * renderScale).rounded())
        let height = Int((image.size.height * renderScale).rounded())
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ) else { return nil }

        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }
}
