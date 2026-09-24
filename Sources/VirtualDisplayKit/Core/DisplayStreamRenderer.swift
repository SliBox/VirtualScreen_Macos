//
//  DisplayStreamRenderer.swift
//  VirtualDisplayKit
//
//  Renders a display stream to a CALayer-backed view.
//

import Cocoa
import CoreVideo
import ScreenCaptureKit

/// A view that renders a display stream using the appropriate backend
@MainActor
public final class DisplayStreamRenderer: NSView {

    /// Logs a line for every captured frame.
    ///
    /// Off by default: at 60 Hz this runs on the main thread often enough to
    /// visibly slow down the app (and anything streaming alongside it).
    public nonisolated(unsafe) static var logsEveryFrame = false

    // MARK: - Properties

    // Using nonisolated(unsafe) to allow cleanup in deinit
    private nonisolated(unsafe) var displayStream: CGDisplayStream?
    private nonisolated(unsafe) var scStream: SCStream?
    private nonisolated(unsafe) var streamOutput: SCStreamOutputHandler?

    private var currentDisplayID: CGDirectDisplayID?
    private var currentResolution: CGSize = .zero
    private var currentScaleFactor: CGFloat = 1.0

    private let backend: StreamingBackend
    private let showCursor: Bool
    private var scPermissionDenied = false
    
    /// Called when a new frame is available (IOSurface)
    public var onFrameAvailable: ((IOSurface) -> Void)?
    
    /// Called when a new frame is available (CVPixelBuffer) - useful for recording/streaming
    public var onPixelBufferAvailable: ((CVPixelBuffer) -> Void)?
    
    /// Current display resolution
    public var displayResolution: CGSize { currentResolution }
    
    /// Current scale factor
    public var displayScaleFactor: CGFloat { currentScaleFactor }
    
    // MARK: - Constants
    
    private enum Constants {
        /// BGRA pixel format as 32-bit integer ('BGRA')
        static let bgraPixelFormat: Int32 = 1_111_970_369
    }
    
    // MARK: - Initialization
    
    /// Creates a new display stream renderer
    /// - Parameters:
    ///   - frame: Initial frame rectangle
    ///   - backend: Which streaming backend to use
    ///   - showCursor: Whether to show the cursor in the stream
    public init(frame frameRect: NSRect = .zero, backend: StreamingBackend = .automatic, showCursor: Bool = true) {
        self.backend = backend
        self.showCursor = showCursor
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        // Stop display stream (C API, safe to call)
        displayStream?.stop()
    }
    
    // MARK: - Public Methods
    
    /// Configures and starts streaming from the specified display
    /// - Parameters:
    ///   - displayID: The display to stream
    ///   - resolution: The display resolution
    ///   - scaleFactor: The display scale factor
    public func configure(displayID: CGDirectDisplayID, resolution: CGSize, scaleFactor: CGFloat) {
        // Skip if already configured with same parameters
        if displayID == currentDisplayID,
           resolution == currentResolution,
           scaleFactor == currentScaleFactor,
           (displayStream != nil || scStream != nil) {
            return
        }

        // Stop existing stream
        stopStream()

        // Store current configuration
        currentDisplayID = displayID
        currentResolution = resolution
        currentScaleFactor = scaleFactor

        // Start appropriate stream based on backend preference
        let effectiveBackend = resolveBackend()

        switch effectiveBackend {
        case .screenCaptureKit:
            startScreenCaptureKitStream(displayID: displayID, resolution: resolution, scaleFactor: scaleFactor)
        case .cgDisplayStream, .automatic:
            startCGDisplayStream(displayID: displayID, resolution: resolution, scaleFactor: scaleFactor)
        }
    }
    
    /// Stops the current display stream
    public func stopStream() {
        displayStream?.stop()
        displayStream = nil

        if let stream = scStream {
            Task {
                try? await stream.stopCapture()
            }
        }
        scStream = nil
        streamOutput = nil
        scPermissionDenied = false
    }
    
    /// Converts a point in view coordinates to display coordinates
    /// - Parameter viewPoint: Point in view coordinates (origin bottom-left)
    /// - Returns: Point in display coordinates (origin top-left), or nil if not configured
    public func convertToDisplayCoordinates(_ viewPoint: NSPoint) -> NSPoint? {
        guard currentResolution != .zero else { return nil }
        
        let normalizedX = viewPoint.x / bounds.width
        // Flip Y coordinate (view origin is bottom-left, display origin is top-left)
        let normalizedY = (bounds.height - viewPoint.y) / bounds.height
        
        return NSPoint(
            x: normalizedX * currentResolution.width,
            y: normalizedY * currentResolution.height
        )
    }
    
    // MARK: - Private Methods
    
    private func resolveBackend() -> StreamingBackend {
        switch backend {
        case .automatic:
            // Use ScreenCaptureKit for virtual displays (CGDisplayStream doesn't support them)
            return .screenCaptureKit
        case .screenCaptureKit:
            return .screenCaptureKit
        case .cgDisplayStream:
            return .cgDisplayStream
        }
    }
    
    private func startCGDisplayStream(displayID: CGDirectDisplayID, resolution: CGSize, scaleFactor: CGFloat) {
        // For virtual displays, don't multiply by scaleFactor to avoid exceeding display capabilities
        let outputWidth = Int(resolution.width)
        let outputHeight = Int(resolution.height)

        print("[DisplayStreamRenderer] CGDisplayStream: Starting stream for display \(displayID) at \(outputWidth)x\(outputHeight) (scaleFactor: \(scaleFactor))")

        // Verify display is valid
        guard CGDisplayIsOnline(displayID) != 0 else {
            print("[DisplayStreamRenderer] CGDisplayStream: Display \(displayID) is offline")
            return
        }

        let stream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pixelFormat: Constants.bgraPixelFormat,
            properties: [
                CGDisplayStream.showCursor: showCursor,
            ] as CFDictionary,
            queue: .main,
            handler: { [weak self] _, _, frameSurface, _ in
                guard let surface = frameSurface else {
                    // Only log this once per second to avoid spam
                    return
                }
                if Self.logsEveryFrame {
                    print("[DisplayStreamRenderer] CGDisplayStream: Frame received (\(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface)))")
                }
                self?.handleFrame(surface: surface)
            }
        )

        if let stream = stream {
            print("[DisplayStreamRenderer] CGDisplayStream: Stream created successfully")
            displayStream = stream
            let status = stream.start()
            print("[DisplayStreamRenderer] CGDisplayStream: Stream start status = \(status)")
        } else {
            print("[DisplayStreamRenderer] CGDisplayStream: Failed to create stream for display \(displayID)")
        }
    }
    
    private func startScreenCaptureKitStream(displayID: CGDirectDisplayID, resolution: CGSize, scaleFactor: CGFloat) {
        Task {
            do {
                // Get available content
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                // Find our display
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    print("[DisplayStreamRenderer] ScreenCaptureKit: Display \(displayID) not found in shareable content. Falling back to CGDisplayStream.")
                    // Fall back to CGDisplayStream
                    startCGDisplayStream(displayID: displayID, resolution: resolution, scaleFactor: scaleFactor)
                    return
                }

                print("[DisplayStreamRenderer] ScreenCaptureKit: Starting stream for display \(displayID)")

                // Create filter for the display
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

                // Configure stream. Use the display's PIXEL dimensions (not points):
                // virtual displays are often HiDPI (2x), and capturing at point size
                // yields only a partial (e.g. top half) frame.
                let configuration = SCStreamConfiguration()
                let pixelWidth = CGDisplayPixelsWide(displayID)
                let pixelHeight = CGDisplayPixelsHigh(displayID)
                let fallbackScale = max(scaleFactor, 1.0)
                configuration.width = pixelWidth > 0 ? Int(pixelWidth) : max(1, Int(resolution.width * fallbackScale))
                configuration.height = pixelHeight > 0 ? Int(pixelHeight) : max(1, Int(resolution.height * fallbackScale))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.showsCursor = showCursor
                configuration.pixelFormat = kCVPixelFormatType_32BGRA

                // Create stream
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

                // Create output handler
                let output = SCStreamOutputHandler { [weak self] surface, pixelBuffer in
                    Task { @MainActor [weak self] in
                        self?.handleFrame(surface: surface, pixelBuffer: pixelBuffer)
                    }
                }
                streamOutput = output

                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                try await stream.startCapture()

                print("[DisplayStreamRenderer] ScreenCaptureKit: Stream started successfully")
                scStream = stream

            } catch {
                let errorDesc = "\(error)"
                if errorDesc.contains("-3801") || errorDesc.contains("declined") {
                    print("[DisplayStreamRenderer] ScreenCaptureKit: Permission denied (-3801)")
                    print("[DisplayStreamRenderer] ⚠️ User must grant Screen Recording permission:")
                    print("[DisplayStreamRenderer]    System Settings > Privacy & Security > Screen Recording")
                    print("[DisplayStreamRenderer]    Then add this app to the allowed list")
                    // Don't fall back - CGDisplayStream doesn't support virtual displays
                } else {
                    print("[DisplayStreamRenderer] ScreenCaptureKit: Error starting stream - \(error). Trying CGDisplayStream.")
                    // Fall back to CGDisplayStream for other errors
                    Task { @MainActor [weak self] in
                        self?.startCGDisplayStream(displayID: displayID, resolution: resolution, scaleFactor: scaleFactor)
                    }
                }
            }
        }
    }
    
    private func handleFrame(surface: IOSurface, pixelBuffer: CVPixelBuffer? = nil) {
        if Self.logsEveryFrame {
            print("[DisplayStreamRenderer] Frame received: \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface))")
        }

        // Update display
        layer?.contents = surface

        // Notify callbacks
        onFrameAvailable?(surface)

        // Create pixel buffer from surface if not provided and callback exists
        if let callback = onPixelBufferAvailable {
            if let buffer = pixelBuffer {
                callback(buffer)
            } else if let buffer = createPixelBuffer(from: surface) {
                callback(buffer)
            }
        }
    }
    
    private func createPixelBuffer(from surface: IOSurface) -> CVPixelBuffer? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        // Lock and copy data
        CVPixelBufferLockBaseAddress(buffer, [])
        IOSurfaceLock(surface, .readOnly, nil)
        
        let srcData = IOSurfaceGetBaseAddress(surface)
        let dstData = CVPixelBufferGetBaseAddress(buffer)
        let srcBytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        
        if let dst = dstData {
            for y in 0..<height {
                let srcRow = srcData.advanced(by: y * srcBytesPerRow)
                let dstRow = dst.advanced(by: y * dstBytesPerRow)
                memcpy(dstRow, srcRow, min(srcBytesPerRow, dstBytesPerRow))
            }
        }
        
        IOSurfaceUnlock(surface, .readOnly, nil)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        return buffer
    }
}

// MARK: - SCStream Output Handler

private final class SCStreamOutputHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: (IOSurface, CVPixelBuffer?) -> Void
    
    init(handler: @escaping (IOSurface, CVPixelBuffer?) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else { return }
        handler(surface, imageBuffer)
    }
}
