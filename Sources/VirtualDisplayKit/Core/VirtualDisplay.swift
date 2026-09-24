//
//  VirtualDisplay.swift
//  VirtualDisplayKit
//
//  Main class for creating and managing virtual displays.
//

import Cocoa
import Combine
import CVirtualDisplayPrivate

/// Delegate protocol for receiving virtual display events
@MainActor
public protocol VirtualDisplayDelegate: AnyObject {
    /// Called when the virtual display is ready to use
    func virtualDisplayDidBecomeReady(_ display: VirtualDisplay)
    
    /// Called when the display resolution changes
    func virtualDisplay(_ display: VirtualDisplay, didChangeResolution resolution: CGSize, scaleFactor: CGFloat)
    
    /// Called when the cursor enters or exits the virtual display
    func virtualDisplay(_ display: VirtualDisplay, cursorDidEnter isInside: Bool)
    
    /// Called when an error occurs
    func virtualDisplay(_ display: VirtualDisplay, didEncounterError error: VirtualDisplayError)
}

/// Default implementations for optional delegate methods
public extension VirtualDisplayDelegate {
    func virtualDisplayDidBecomeReady(_ display: VirtualDisplay) {}
    func virtualDisplay(_ display: VirtualDisplay, didChangeResolution resolution: CGSize, scaleFactor: CGFloat) {}
    func virtualDisplay(_ display: VirtualDisplay, cursorDidEnter isInside: Bool) {}
    func virtualDisplay(_ display: VirtualDisplay, didEncounterError error: VirtualDisplayError) {}
}

/// Errors that can occur during virtual display operations
public enum VirtualDisplayError: Error, LocalizedError {
    case failedToCreate
    case displayNotFound
    case streamingFailed(underlying: Error?)
    case permissionDenied
    case unsupportedConfiguration
    
    public var errorDescription: String? {
        switch self {
        case .failedToCreate:
            return "Failed to create virtual display"
        case .displayNotFound:
            return "Virtual display not found in system displays"
        case .streamingFailed(let underlying):
            if let error = underlying {
                return "Display streaming failed: \(error.localizedDescription)"
            }
            return "Display streaming failed"
        case .permissionDenied:
            return "Screen recording permission denied"
        case .unsupportedConfiguration:
            return "Display configuration not supported"
        }
    }
}

/// Main class for managing a virtual display
@MainActor
public final class VirtualDisplay: ObservableObject {
    
    // MARK: - Published State
    
    /// The CoreGraphics display ID of the virtual display
    @Published public private(set) var displayID: CGDirectDisplayID?
    
    /// Current resolution of the display
    @Published public private(set) var resolution: CGSize = .zero
    
    /// Current scale factor (1.0 for standard, 2.0 for Retina)
    @Published public private(set) var scaleFactor: CGFloat = 1.0
    
    /// Whether the virtual display is ready for use
    @Published public private(set) var isReady = false
    
    /// Whether the cursor is currently within the virtual display
    @Published public private(set) var isCursorInside = false
    
    // MARK: - Configuration
    
    /// The configuration used to create this display
    public let configuration: VirtualDisplayConfiguration
    
    /// Delegate for receiving display events
    public weak var delegate: VirtualDisplayDelegate?
    
    // MARK: - Private Properties
    
    private var virtualDisplay: CGVirtualDisplay?
    /// The configuration actually used, which may carry a recovered serial number
    private var activeConfiguration: VirtualDisplayConfiguration
    private var didRetryWithNewIdentity = false
    private var didApplyPreferredMode = false
    // Using nonisolated(unsafe) to allow cleanup in deinit
    private nonisolated(unsafe) var screenChangeSubscription: AnyCancellable?
    private nonisolated(unsafe) var cursorTrackingSubscription: AnyCancellable?
    private nonisolated(unsafe) var retrySubscription: AnyCancellable?
    private var retryCount = 0
    
    // 10s. Displays normally come online in well under a second; the budget is
    // generous because a busy window server can take longer, but short enough
    // that the identity fallback below still fits in a reasonable wait.
    private static let maxRetries = 100
    private static let retryInterval: TimeInterval = 0.1
    private static let cursorTrackingInterval: TimeInterval = 0.25
    
    // MARK: - Initialization
    
    /// Creates a new virtual display manager with the specified configuration
    /// - Parameter configuration: The display configuration to use
    public init(configuration: VirtualDisplayConfiguration = VirtualDisplayConfiguration()) {
        self.configuration = configuration

        // A previous run may have found this identity unusable and recorded a
        // replacement; start from that instead of failing the same way again.
        var active = configuration
        if let recovered = DisplayIdentityStore.recoveredSerial(for: configuration) {
            active.serialNumber = recovered
        }
        self.activeConfiguration = active
    }
    
    deinit {
        // Clean up subscriptions
        screenChangeSubscription?.cancel()
        cursorTrackingSubscription?.cancel()
        retrySubscription?.cancel()
    }
    
    // MARK: - Public Methods
    
    /// Creates and activates the virtual display
    /// Call this method to start the virtual display. The display will be ready
    /// when `isReady` becomes true or when `virtualDisplayDidBecomeReady` is called.
    public func start() {
        guard virtualDisplay == nil else { return }
        
        // Create descriptor
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = activeConfiguration.name
        // HiDPI modes need a framebuffer twice the mode size; handing CoreGraphics
        // a smaller budget yields a display that is created but never comes online.
        descriptor.maxPixelsWide = activeConfiguration.effectiveMaxWidth
        descriptor.maxPixelsHigh = activeConfiguration.effectiveMaxHeight
        descriptor.sizeInMillimeters = activeConfiguration.physicalSizeMillimeters
        descriptor.vendorID = activeConfiguration.vendorID
        descriptor.productID = activeConfiguration.productID
        descriptor.serialNum = activeConfiguration.serialNumber
        descriptor.terminationHandler = { _, _ in
            print("[VirtualDisplay] Display terminated by the system")
        }
        
        print("[VirtualDisplay] Creating display with config:")
        print("  - Name: \(activeConfiguration.name)")
        print("  - Max size: \(activeConfiguration.maxWidth)x\(activeConfiguration.maxHeight)"
              + " (framebuffer \(activeConfiguration.effectiveMaxWidth)x\(activeConfiguration.effectiveMaxHeight))")
        print("  - HiDPI: \(activeConfiguration.hiDPIEnabled), serial: \(activeConfiguration.serialNumber)")
        print("  - Modes: \(activeConfiguration.displayModes.map { "\($0.width)x\($0.height)@\($0.refreshRate)Hz" })")
        
        // Create the virtual display
        let display = CGVirtualDisplay(descriptor: descriptor)
        virtualDisplay = display
        displayID = display.displayID
        
        print("[VirtualDisplay] Created with displayID: \(display.displayID)")
        print("[VirtualDisplay] Available screens: \(NSScreen.screens.map { "\($0.localizedName): \($0.displayID)" })")

        // A zero display ID means CoreGraphics refused the descriptor outright,
        // which happens when another live display already claims this identity.
        guard display.displayID != 0 else {
            print("[VirtualDisplay] ERROR: CoreGraphics returned display ID 0 - identity already in use")
            tearDown()
            delegate?.virtualDisplay(self, didEncounterError: .failedToCreate)
            return
        }
        
        // Configure settings
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = activeConfiguration.hiDPIEnabled ? 1 : 0
        settings.modes = activeConfiguration.displayModes.map { mode in
            CGVirtualDisplayMode(
                width: UInt(mode.width),
                height: UInt(mode.height),
                refreshRate: mode.refreshRate
            )
        }
        let success = display.apply(settings)
        print("[VirtualDisplay] Applied settings: \(success)")
        if !success {
            print("[VirtualDisplay] ERROR: Settings rejected - check that the modes fit the framebuffer budget")
            tearDown()
            delegate?.virtualDisplay(self, didEncounterError: .unsupportedConfiguration)
            return
        }
        print("[VirtualDisplay] Display modes after apply: \(display.modes ?? [])")
        print("[VirtualDisplay] Display hiDPI: \(display.hiDPI)")
        
        // Observe screen parameter changes
        screenChangeSubscription = NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateScreenConfiguration()
            }
        
        // Start cursor tracking
        startCursorTracking()
        
        // Start retry loop to find the display
        retryCount = 0
        startRetryLoop()
    }
    
    /// Stops and destroys the virtual display
    public func stop() {
        didRetryWithNewIdentity = false
        tearDown()
    }

    /// Releases the CoreGraphics display and resets all state.
    ///
    /// Also used when the display fails to come online: keeping a dead
    /// `CGVirtualDisplay` alive blocks the next `start()`, because it still owns
    /// the display identity the new descriptor asks for.
    private func tearDown() {
        screenChangeSubscription?.cancel()
        screenChangeSubscription = nil
        cursorTrackingSubscription?.cancel()
        cursorTrackingSubscription = nil
        retrySubscription?.cancel()
        retrySubscription = nil
        retryCount = 0

        didApplyPreferredMode = false
        virtualDisplay = nil
        displayID = nil
        resolution = .zero
        scaleFactor = 1.0
        isReady = false
        isCursorInside = false
    }
    
    /// Moves the system cursor to a point on the virtual display
    /// - Parameter point: The point in display coordinates
    public func moveCursor(to point: CGPoint) {
        guard let displayID = displayID else { return }
        CGDisplayMoveCursorToPoint(displayID, point)
    }
    
    /// Returns the NSScreen object for this virtual display, if available
    public var screen: NSScreen? {
        guard let displayID = displayID else { return nil }
        return NSScreen.screen(withDisplayID: displayID)
    }
    
    // MARK: - Private Methods
    
    private func startRetryLoop() {
        retrySubscription = Timer.publish(every: Self.retryInterval, on: .main, in: .common)
            .autoconnect()
            .prefix(Self.maxRetries)
            .sink { [weak self] _ in
                self?.updateScreenConfiguration()
            }
    }
    
    private func startCursorTracking() {
        cursorTrackingSubscription = Timer.publish(every: Self.cursorTrackingInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateCursorLocation()
            }
    }
    
    private func updateScreenConfiguration() {
        guard let displayID = displayID else { return }

        guard let screen = NSScreen.screen(withDisplayID: displayID) else {
            retryCount += 1
            if retryCount % 10 == 0 {
                print("[VirtualDisplay] Retry \(retryCount)/\(Self.maxRetries) - Looking for displayID: \(displayID)")
                print("[VirtualDisplay] Available screens: \(NSScreen.screens.map { "\($0.localizedName): \($0.displayID)" })")
            }
            if retryCount >= Self.maxRetries {
                let totalSeconds = Double(Self.maxRetries) * Self.retryInterval
                print("[VirtualDisplay] ERROR: Display not found after \(Int(totalSeconds * 1000))ms (\(Int(totalSeconds))s)")
                print("[VirtualDisplay] Last available screens: \(NSScreen.screens.map { "\($0.localizedName): \($0.displayID)" })")
                // Release the display before retrying or reporting, so the
                // identity is free again.
                tearDown()

                // macOS can end up with a display identity it refuses to bring
                // online - typically after two displays shared one identity.
                // That state survives app restarts, so try once with a fresh
                // serial number and remember it if it works.
                if !didRetryWithNewIdentity {
                    didRetryWithNewIdentity = true
                    let newSerial = DisplayIdentityStore.makeSerial()
                    print("[VirtualDisplay] Retrying with a new display identity: serial \(newSerial)")
                    activeConfiguration.serialNumber = newSerial
                    start()
                    return
                }

                DisplayIdentityStore.forget(configuration)
                delegate?.virtualDisplay(self, didEncounterError: .displayNotFound)
            }
            return
        }
        
        print("[VirtualDisplay] Found screen: \(screen.localizedName) at \(screen.frame)")
        
        // Found the screen - stop retry loop
        retrySubscription?.cancel()
        retrySubscription = nil

        // macOS restores whatever mode it last used for this display identity,
        // which can be smaller than the one that was asked for.
        if !didApplyPreferredMode {
            didApplyPreferredMode = true
            if applyPreferredMode(displayID: displayID) {
                // `screen.frame` still reports the old mode on this turn of the
                // run loop; publish the new size once it has caught up.
                DispatchQueue.main.async { [weak self] in
                    self?.updateScreenConfiguration()
                }
            }
        }
        
        let newResolution = screen.frame.size
        let newScaleFactor = screen.backingScaleFactor
        
        let resolutionChanged = resolution != newResolution || scaleFactor != newScaleFactor
        let wasReady = isReady
        
        resolution = newResolution
        scaleFactor = newScaleFactor
        isReady = true
        
        if !wasReady {
            if activeConfiguration.serialNumber != configuration.serialNumber {
                DisplayIdentityStore.remember(activeConfiguration.serialNumber, for: configuration)
            }
            delegate?.virtualDisplayDidBecomeReady(self)
        } else if resolutionChanged {
            delegate?.virtualDisplay(self, didChangeResolution: newResolution, scaleFactor: newScaleFactor)
        }
    }
    
    /// Switches the display to the first configured mode if it came up smaller
    @discardableResult
    private func applyPreferredMode(displayID: CGDirectDisplayID) -> Bool {
        guard let preferred = activeConfiguration.displayModes.first else { return false }

        let scale = activeConfiguration.hiDPIEnabled ? 2 : 1
        let targetWidth = preferred.width * scale
        let targetHeight = preferred.height * scale

        let current = CGDisplayCopyDisplayMode(displayID)
        if current?.pixelWidth == targetWidth && current?.pixelHeight == targetHeight { return false }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
              let match = modes.first(where: { $0.pixelWidth == targetWidth && $0.pixelHeight == targetHeight })
        else {
            print("[VirtualDisplay] No \(targetWidth)x\(targetHeight) mode available to switch to")
            return false
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef = configRef else { return false }
        CGConfigureDisplayWithDisplayMode(configRef, displayID, match, nil)
        // For this session only, so the app does not rewrite the user's saved
        // display preferences.
        let result = CGCompleteDisplayConfiguration(configRef, .forSession)
        print("[VirtualDisplay] Switched to \(targetWidth)x\(targetHeight): \(result == .success)")
        return result == .success
    }

    private func updateCursorLocation() {
        guard let displayID = displayID else {
            if isCursorInside {
                isCursorInside = false
                delegate?.virtualDisplay(self, cursorDidEnter: false)
            }
            return
        }
        
        let mouseLocation = NSEvent.mouseLocation
        let screenContainingMouse = NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        }
        
        let newCursorInside = screenContainingMouse?.displayID == displayID
        
        if newCursorInside != isCursorInside {
            isCursorInside = newCursorInside
            delegate?.virtualDisplay(self, cursorDidEnter: newCursorInside)
        }
    }
}

// MARK: - Display Identity Recovery

/// Remembers replacement serial numbers for display identities macOS refuses to
/// bring online.
///
/// The bad state lives in the window server, not in this process, so it outlives
/// the app; without a persisted replacement every launch would have to rediscover
/// it the slow way.
enum DisplayIdentityStore {
    private static let keyPrefix = "VirtualDisplayKit.identity."

    private static func key(for configuration: VirtualDisplayConfiguration) -> String {
        "\(keyPrefix)\(configuration.vendorID).\(configuration.productID).\(configuration.serialNumber)"
    }

    /// A serial that previously worked in place of the configured one
    static func recoveredSerial(for configuration: VirtualDisplayConfiguration) -> UInt32? {
        (UserDefaults.standard.object(forKey: key(for: configuration)) as? NSNumber)?.uint32Value
    }

    static func remember(_ serial: UInt32, for configuration: VirtualDisplayConfiguration) {
        UserDefaults.standard.set(NSNumber(value: serial), forKey: key(for: configuration))
    }

    static func forget(_ configuration: VirtualDisplayConfiguration) {
        UserDefaults.standard.removeObject(forKey: key(for: configuration))
    }

    /// A fresh, non-zero serial number
    static func makeSerial() -> UInt32 {
        UInt32.random(in: 1...UInt32.max)
    }
}
