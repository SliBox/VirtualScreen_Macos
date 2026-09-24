//
//  VirtualDisplayController.swift
//  VirtualDisplayKit
//
//  High-level controller for managing virtual displays with recording and streaming.
//

import Cocoa
import Combine
import CoreImage
import CoreVideo

/// A high-level controller that manages a virtual display with recording and streaming support
///
/// Use this class when you want simple, all-in-one virtual display functionality.
///
/// Example usage:
/// ```swift
/// let controller = VirtualDisplayController()
///
/// // Create a window that shows the virtual display
/// let window = controller.createPreviewWindow()
/// window.makeKeyAndOrderFront(nil)
///
/// // Start the virtual display
/// controller.start()
///
/// // Record the display
/// try controller.startRecording(to: recordingURL)
///
/// // Or stream the display
/// controller.startStreaming { data, time, isKeyFrame in
///     // Send to your streaming server
/// }
/// ```
@MainActor
public final class VirtualDisplayController: ObservableObject {
    
    // MARK: - Published Properties
    
    /// The underlying virtual display
    @Published public private(set) var virtualDisplay: VirtualDisplay
    
    /// Whether the virtual display is ready
    public var isReady: Bool { virtualDisplay.isReady }
    
    /// Current display resolution
    public var resolution: CGSize { virtualDisplay.resolution }
    
    /// Current display ID
    public var displayID: CGDirectDisplayID? { virtualDisplay.displayID }
    
    /// Last error reported by the virtual display, if any
    ///
    /// Set when the display cannot be created or never comes online; cleared on
    /// the next `start()`.
    @Published public private(set) var displayError: String?

    /// Whether recording is active
    @Published public private(set) var isRecording = false
    
    /// Current recording duration
    @Published public private(set) var recordingDuration: TimeInterval = 0
    
    /// Whether streaming is active
    @Published public private(set) var isStreaming = false
    
    /// Current streaming frame rate
    @Published public private(set) var streamingFrameRate: Double = 0

    /// Whether the display is being served to browsers over the network
    @Published public private(set) var isBrowserStreaming = false

    /// Live statistics for the browser stream
    @Published public private(set) var browserStreamStats = BrowserStreamStats()

    /// URLs other devices can open to watch the display
    @Published public private(set) var browserStreamEndpoints: [BrowserStreamEndpoint] = []

    /// The code a viewer enters to control the Mac, while the browser stream
    /// runs with `allowsControl`; `nil` otherwise
    @Published public private(set) var browserStreamControlPIN: String?

    /// Last error reported by the browser stream server, if any
    @Published public private(set) var browserStreamError: String?

    // MARK: - Recording & Streaming

    private var recorder: DisplayRecorder?
    private var frameOutputStream: FrameOutputStream?
    private var browserStreamServer: BrowserStreamServer?
    private var displayView: VirtualDisplayNSView?
    
    // MARK: - Private Properties
    
    private var cancellables = Set<AnyCancellable>()
    private var previewWindow: NSWindow?
    private var captureRenderer: DisplayStreamRenderer?  // Keep reference for frame capture
    
    // MARK: - Initialization
    
    /// Creates a new controller with the specified configuration
    /// - Parameter configuration: Display configuration (defaults to preset1080p)
    public init(configuration: VirtualDisplayConfiguration = .preset1080p) {
        self.virtualDisplay = VirtualDisplay(configuration: configuration)
        self.virtualDisplay.delegate = self
    }

    /// Creates a new controller for a standard resolution
    /// - Parameters:
    ///   - resolution: The native resolution of the display
    ///   - orientation: Landscape or portrait
    ///   - hiDPI: Render at 2x the resolution (see `VirtualDisplayConfiguration.preset`)
    public convenience init(
        resolution: DisplayResolutionPreset,
        orientation: DisplayOrientation = .landscape,
        hiDPI: Bool = false
    ) {
        self.init(configuration: .preset(resolution, orientation: orientation, hiDPI: hiDPI))
    }

    /// Creates a new controller with a preset configuration
    /// - Parameter preset: The preset to use
    public convenience init(preset: ConfigurationPreset) {
        switch preset {
        case .standard1080p:
            self.init(configuration: .preset1080p)
        case .portrait1080p:
            self.init(configuration: .preset1080pPortrait)
        case .standard2K:
            self.init(configuration: .preset2K)
        case .portrait2K:
            self.init(configuration: .preset2KPortrait)
        case .high4K:
            self.init(configuration: .preset4K)
        case .portrait4K:
            self.init(configuration: .preset4KPortrait)
        }
    }
    
    // MARK: - Lifecycle
    
    /// Starts the virtual display
    public func start() {
        displayError = nil
        virtualDisplay.start()
    }
    
    /// Stops the virtual display and any active recording/streaming
    public func stop() {
        Task {
            if isRecording {
                try? await stopRecording()
            }
        }
        
        if isStreaming {
            stopStreaming()
        }

        if isBrowserStreaming {
            stopBrowserStream()
        }

        captureRenderer?.stopStream()
        captureRenderer = nil
        
        virtualDisplay.stop()
        previewWindow?.close()
        previewWindow = nil
    }
    
    // MARK: - Recording
    
    /// Starts recording the virtual display to a file
    /// - Parameters:
    ///   - url: Output file URL
    ///   - configuration: Recording configuration (defaults to standard)
    public func startRecording(
        to url: URL,
        configuration: RecordingConfiguration = .standard
    ) throws {
        guard !isRecording else { return }
        guard virtualDisplay.isReady else {
            throw DisplayRecorderError.notConfigured
        }
        
        let recorder = DisplayRecorder(configuration: configuration)
        recorder.configure(
            displaySize: virtualDisplay.resolution,
            scaleFactor: virtualDisplay.scaleFactor
        )
        
        // Subscribe to duration updates
        recorder.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)
        
        try recorder.startRecording(to: url)
        
        self.recorder = recorder
        isRecording = true
        
        // Connect frame callback
        setupFrameCallback()
    }
    
    /// Stops the current recording
    @discardableResult
    public func stopRecording() async throws -> URL? {
        guard isRecording, let recorder = recorder else {
            return nil
        }
        
        try await recorder.stopRecording()
        let url = recorder.outputURL
        
        self.recorder = nil
        isRecording = false
        recordingDuration = 0
        
        // Clean up capture renderer if not streaming
        if !isStreaming {
            captureRenderer?.stopStream()
            captureRenderer = nil
        }
        
        return url
    }
    
    // MARK: - Streaming
    
    /// Starts streaming encoded frames
    /// - Parameters:
    ///   - configuration: Stream output configuration
    ///   - onFrame: Callback for each encoded frame
    public func startStreaming(
        configuration: StreamOutputConfiguration = .rtmpStreaming,
        onFrame: @escaping (_ data: Data, _ presentationTime: CMTime, _ isKeyFrame: Bool) -> Void
    ) throws {
        guard !isStreaming else { return }
        guard virtualDisplay.isReady else {
            throw DisplayRecorderError.notConfigured
        }
        
        let stream = FrameOutputStream(configuration: configuration)
        stream.configure(
            displaySize: virtualDisplay.resolution,
            scaleFactor: virtualDisplay.scaleFactor
        )
        
        stream.onEncodedFrame = onFrame
        
        // Subscribe to frame rate updates
        stream.$currentFrameRate
            .receive(on: DispatchQueue.main)
            .assign(to: &$streamingFrameRate)
        
        try stream.start()
        
        self.frameOutputStream = stream
        isStreaming = true
        
        // Connect frame callback
        setupFrameCallback()
    }
    
    /// Stops streaming
    public func stopStreaming() {
        guard isStreaming else { return }
        
        frameOutputStream?.stop()
        frameOutputStream = nil
        isStreaming = false
        streamingFrameRate = 0
        
        // Clean up capture renderer if not recording
        if !isRecording {
            captureRenderer?.stopStream()
            captureRenderer = nil
        }
    }

    // MARK: - Browser Streaming

    /// Serves the virtual display to any browser on the local network
    ///
    /// The returned endpoints are the URLs to open on another device, e.g.
    /// `http://192.168.1.42:8080`. Frames are pushed over a WebSocket at the
    /// configured frame rate; the page is served from the same port.
    ///
    /// - Parameter configuration: Port, target frame rate and image quality
    /// - Returns: One URL per reachable network interface
    @discardableResult
    public func startBrowserStream(
        configuration: BrowserStreamConfiguration = BrowserStreamConfiguration()
    ) throws -> [BrowserStreamEndpoint] {
        guard !isBrowserStreaming else { return browserStreamEndpoints }
        guard virtualDisplay.isReady, let displayID = virtualDisplay.displayID else {
            throw BrowserStreamError.displayNotReady
        }

        let server = BrowserStreamServer(configuration: configuration)

        server.onStats = { [weak self] stats in
            MainActor.assumeIsolated {
                self?.browserStreamStats = stats
            }
        }

        server.onError = { [weak self] message in
            MainActor.assumeIsolated {
                self?.browserStreamError = message
            }
        }

        server.onLog = { message in
            print("[BrowserStream] \(message)")
        }

        // Capture at the display's real pixel size; HiDPI virtual displays
        // report points, which would stream at half resolution.
        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        let pixelSize = pixelWidth > 0 && pixelHeight > 0
            ? CGSize(width: pixelWidth, height: pixelHeight)
            : CGSize(
                width: virtualDisplay.resolution.width * virtualDisplay.scaleFactor,
                height: virtualDisplay.resolution.height * virtualDisplay.scaleFactor
            )

        try server.start(displayID: displayID, pixelSize: pixelSize)

        browserStreamServer = server
        browserStreamControlPIN = server.controlPIN
        browserStreamError = nil
        browserStreamStats = BrowserStreamStats()
        browserStreamEndpoints = NetworkInterfaces.localIPv4Addresses().map {
            BrowserStreamEndpoint(address: $0, port: configuration.port)
        }
        isBrowserStreaming = true

        return browserStreamEndpoints
    }

    /// Stops serving the display to browsers and releases the port
    public func stopBrowserStream() {
        guard isBrowserStreaming else { return }

        browserStreamServer?.stop()
        browserStreamServer = nil
        browserStreamControlPIN = nil
        browserStreamEndpoints = []
        browserStreamStats = BrowserStreamStats()
        isBrowserStreaming = false
    }

    /// Adjusts JPEG quality while the browser stream is running
    /// - Parameter quality: 0.1 (smallest frames) to 1.0 (best looking)
    public func setBrowserStreamQuality(_ quality: Double) {
        browserStreamServer?.updateQuality(quality)
    }

    // MARK: - Preview Window
    
    /// Creates a preview window that shows the virtual display contents
    /// - Parameters:
    ///   - title: Window title
    ///   - initialSize: Initial window size (defaults to 1280x720)
    ///   - minSize: Minimum window size
    /// - Returns: A configured NSWindow
    public func createPreviewWindow(
        title: String = "Virtual Display",
        initialSize: CGSize = CGSize(width: 1280, height: 720),
        minSize: CGSize = CGSize(width: 400, height: 300)
    ) -> NSWindow {
        // Create the view
        let view = VirtualDisplayNSView()
        view.attach(virtualDisplay)
        view.onTap = { [weak self] point in
            self?.virtualDisplay.moveCursor(to: point)
        }
        
        displayView = view
        
        // Create and configure window
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .white
        window.contentMinSize = minSize
        window.contentView = view
        window.center()
        
        // Update aspect ratio when display resolution changes
        virtualDisplay.$resolution
            .receive(on: DispatchQueue.main)
            .sink { [weak window] resolution in
                guard resolution != .zero else { return }
                window?.contentAspectRatio = resolution
            }
            .store(in: &cancellables)
        
        // Highlight window when cursor is in virtual display
        virtualDisplay.$isCursorInside
            .receive(on: DispatchQueue.main)
            .sink { [weak window] isInside in
                if isInside {
                    window?.orderFrontRegardless()
                }
            }
            .store(in: &cancellables)
        
        previewWindow = window
        return window
    }
    
    /// Creates a SwiftUI view for embedding in SwiftUI hierarchies
    /// - Returns: A VirtualDisplayView configured for this controller
    public func makeView() -> VirtualDisplayView {
        VirtualDisplayView(virtualDisplay: virtualDisplay) { [weak self] point in
            self?.virtualDisplay.moveCursor(to: point)
        }
    }
    
    // MARK: - Cursor Control
    
    /// Moves the cursor to a specific point on the virtual display
    /// - Parameter point: The point in display coordinates
    public func moveCursor(to point: CGPoint) {
        virtualDisplay.moveCursor(to: point)
    }
    
    // MARK: - Private Methods
    
    private func setupFrameCallback() {
        guard isRecording || isStreaming else { return }
        guard let displayID = virtualDisplay.displayID else { return }
        
        // Create a dedicated renderer for capturing frames
        let renderer = DisplayStreamRenderer(backend: .cgDisplayStream, showCursor: true)
        renderer.configure(
            displayID: displayID,
            resolution: virtualDisplay.resolution,
            scaleFactor: virtualDisplay.scaleFactor
        )
        
        renderer.onFrameAvailable = { [weak self] surface in
            guard let self = self else { return }
            
            // Send to recorder
            if self.isRecording {
                self.recorder?.appendFrame(from: surface)
            }
            
            // Send to stream
            if self.isStreaming {
                self.frameOutputStream?.processFrame(from: surface)
            }
        }
        
        // Store reference to keep it alive
        self.captureRenderer = renderer
    }

    // MARK: - Manual Capture

    /// Captures a single frame from the virtual display and saves it to a file
    /// - Parameter outputURL: Where to save the captured image (JPEG format)
    /// - Returns: URL of the saved image if successful
    @discardableResult
    public func captureFrame(to outputURL: URL) async throws -> URL? {
        guard isReady, let displayID = virtualDisplay.displayID else {
            throw DisplayRecorderError.notConfigured
        }

        var capturedImage: CGImage?
        let semaphore = DispatchSemaphore(value: 0)

        let renderer = DisplayStreamRenderer(backend: .cgDisplayStream, showCursor: true)
        renderer.configure(
            displayID: displayID,
            resolution: virtualDisplay.resolution,
            scaleFactor: virtualDisplay.scaleFactor
        )

        renderer.onFrameAvailable = { surface in
            // Convert IOSurface to CGImage
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
                semaphore.signal()
                return
            }

            CVPixelBufferLockBaseAddress(buffer, [])
            IOSurfaceLock(surface, .readOnly, nil)

            let srcData = IOSurfaceGetBaseAddress(surface)
            if let dstData = CVPixelBufferGetBaseAddress(buffer) {
                let srcBytesPerRow = IOSurfaceGetBytesPerRow(surface)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

                for y in 0..<height {
                    let srcRow = srcData.advanced(by: y * srcBytesPerRow)
                    let dstRow = dstData.advanced(by: y * dstBytesPerRow)
                    memcpy(dstRow, srcRow, min(srcBytesPerRow, dstBytesPerRow))
                }
            }

            IOSurfaceUnlock(surface, .readOnly, nil)
            CVPixelBufferUnlockBaseAddress(buffer, [])

            let ciImage = CIImage(cvPixelBuffer: buffer)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                capturedImage = cgImage
            }

            semaphore.signal()
        }

        // Wait for first frame with timeout
        _ = semaphore.wait(timeout: .now() + 5.0)
        renderer.stopStream()

        guard let image = capturedImage else {
            print("[VirtualDisplayController] Failed to capture frame")
            return nil
        }

        // Save as JPEG
        guard let tiffData = NSBitmapImageRep(cgImage: image).tiffRepresentation,
              let jpegData = NSBitmapImageRep(data: tiffData)?.representation(using: .jpeg, properties: [:]) else {
            throw DisplayRecorderError.encodingFailed
        }

        try jpegData.write(to: outputURL)
        print("[VirtualDisplayController] Frame captured to: \(outputURL.path)")
        return outputURL
    }
}

// MARK: - Configuration Presets

public extension VirtualDisplayController {
    /// Preset configurations for common use cases
    enum ConfigurationPreset {
        /// Standard 1080p display (1920x1080) - Landscape
        case standard1080p
        
        /// Standard 1080p display (1080x1920) - Portrait
        case portrait1080p
        
        /// 2K display (2560x1440) - Landscape
        case standard2K

        /// 2K display (1440x2560) - Portrait
        case portrait2K

        /// High-resolution 4K display (3840x2160) - Landscape
        case high4K
        
        /// High-resolution 4K display (2160x3840) - Portrait
        case portrait4K
    }
}

// MARK: - VirtualDisplayDelegate

extension VirtualDisplayController: VirtualDisplayDelegate {
    public func virtualDisplay(_ display: VirtualDisplay, didEncounterError error: VirtualDisplayError) {
        displayError = error.localizedDescription
        print("[VirtualDisplayController] Display error: \(error.localizedDescription)")

        // The display is gone - tear down anything that was capturing from it.
        if isBrowserStreaming {
            stopBrowserStream()
        }
        if isStreaming {
            stopStreaming()
        }
        captureRenderer?.stopStream()
        captureRenderer = nil
    }
}
