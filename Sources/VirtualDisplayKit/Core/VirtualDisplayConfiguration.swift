//
//  VirtualDisplayConfiguration.swift
//  VirtualDisplayKit
//
//  Configuration options for creating virtual displays.
//

import Foundation
import CoreGraphics

/// Configuration for creating a virtual display
public struct VirtualDisplayConfiguration: Sendable {
    
    // MARK: - Display Properties
    
    /// Name shown in Display preferences
    public var name: String
    
    /// Maximum pixel width the display can support
    public var maxWidth: UInt32
    
    /// Maximum pixel height the display can support
    public var maxHeight: UInt32
    
    /// Physical size in millimeters (affects DPI calculations)
    public var physicalSizeMillimeters: CGSize
    
    /// Vendor ID for display identification
    public var vendorID: UInt32
    
    /// Product ID for display identification
    public var productID: UInt32
    
    /// Serial number for display identification
    public var serialNumber: UInt32
    
    /// Whether to enable HiDPI (Retina) modes
    public var hiDPIEnabled: Bool
    
    /// Refresh rate in Hz
    public var refreshRate: CGFloat
    
    /// Available display modes
    public var displayModes: [DisplayMode]
    
    // MARK: - Streaming Options
    
    /// Whether to show the cursor in the stream
    public var showCursor: Bool
    
    /// Preferred streaming backend
    public var streamingBackend: StreamingBackend
    
    // MARK: - Initialization
    
    /// Creates a new configuration with default values suitable for most use cases
    public init(
        name: String = "Virtual Display",
        maxWidth: UInt32 = 3840,
        maxHeight: UInt32 = 2160,
        physicalSizeMillimeters: CGSize = CGSize(width: 600, height: 340),
        vendorID: UInt32 = 0x3456,
        productID: UInt32 = 0x1234,
        serialNumber: UInt32 = 0x0001,
        hiDPIEnabled: Bool = true,
        refreshRate: CGFloat = 60,
        displayModes: [DisplayMode]? = nil,
        showCursor: Bool = true,
        streamingBackend: StreamingBackend = .automatic
    ) {
        self.name = name
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.physicalSizeMillimeters = physicalSizeMillimeters
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
        self.hiDPIEnabled = hiDPIEnabled
        self.refreshRate = refreshRate
        self.displayModes = displayModes ?? Self.defaultDisplayModes(refreshRate: refreshRate)
        self.showCursor = showCursor
        self.streamingBackend = streamingBackend
    }
    
    // MARK: - Derived Values

    /// Pixel width actually handed to CoreGraphics when creating the display.
    ///
    /// With HiDPI enabled every mode is backed by a framebuffer twice its size,
    /// so the descriptor has to allow at least 2x the largest mode. A descriptor
    /// that is too small produces a display that is created successfully but
    /// never comes online - `NSScreen` never lists it.
    public var effectiveMaxWidth: UInt32 {
        max(maxWidth, requiredPixelSize.width)
    }

    /// Pixel height actually handed to CoreGraphics when creating the display.
    ///
    /// See ``effectiveMaxWidth`` for why this can be larger than ``maxHeight``.
    public var effectiveMaxHeight: UInt32 {
        max(maxHeight, requiredPixelSize.height)
    }

    /// The largest framebuffer any of the configured modes needs
    private var requiredPixelSize: (width: UInt32, height: UInt32) {
        let scale: UInt32 = hiDPIEnabled ? 2 : 1
        let widest = displayModes.map { UInt32(max(0, $0.width)) }.max() ?? 0
        let tallest = displayModes.map { UInt32(max(0, $0.height)) }.max() ?? 0
        return (widest * scale, tallest * scale)
    }

    // MARK: - Presets

    /// Builds a configuration for one of the standard resolutions
    ///
    /// The mode list contains every smaller standard resolution as well, so the
    /// display can be resized from System Settings without being recreated, and
    /// the descriptor gets an identity derived from the resolution so macOS does
    /// not try to restore a remembered mode that belongs to a different preset.
    ///
    /// - Parameters:
    ///   - resolution: The native (largest) resolution of the display
    ///   - orientation: Landscape keeps the resolution as-is, portrait swaps the axes
    ///   - refreshRate: Refresh rate reported for every mode
    ///   - hiDPI: When true the resolution is treated as points and backed by a
    ///     framebuffer twice as large in each axis, so "1080p" renders 3840x2160
    ///     pixels. Off by default: the resolution is then pixel-exact, which is
    ///     what recording and streaming want.
    public static func preset(
        _ resolution: DisplayResolutionPreset,
        orientation: DisplayOrientation = .landscape,
        refreshRate: CGFloat = 60,
        hiDPI: Bool = false
    ) -> VirtualDisplayConfiguration {
        let size = resolution.pixelSize(for: orientation)

        // Every standard resolution up to and including the requested one, so the
        // user can pick a smaller mode in System Settings.
        let modes = DisplayResolutionPreset.allCases
            .filter { $0.pixelCount <= resolution.pixelCount }
            .sorted { $0.pixelCount > $1.pixelCount }
            .map { preset -> DisplayMode in
                let modeSize = preset.pixelSize(for: orientation)
                return DisplayMode(width: modeSize.width, height: modeSize.height, refreshRate: refreshRate)
            }

        return VirtualDisplayConfiguration(
            name: "Virtual Display \(resolution.shortName)\(orientation == .portrait ? " Portrait" : "")",
            maxWidth: UInt32(size.width),
            maxHeight: UInt32(size.height),
            physicalSizeMillimeters: Self.physicalSize(forWidth: size.width, height: size.height),
            serialNumber: Self.identity(width: size.width, height: size.height),
            hiDPIEnabled: hiDPI,
            refreshRate: refreshRate,
            displayModes: modes
        )
    }

    /// Configuration preset for 1080p displays
    public static var preset1080p: VirtualDisplayConfiguration {
        preset(.fullHD, orientation: .landscape)
    }

    /// Configuration preset for 1080p portrait displays
    public static var preset1080pPortrait: VirtualDisplayConfiguration {
        preset(.fullHD, orientation: .portrait)
    }

    /// Configuration preset for 2K (1440p) displays
    public static var preset2K: VirtualDisplayConfiguration {
        preset(.qhd2K, orientation: .landscape)
    }

    /// Configuration preset for 2K (1440p) portrait displays
    public static var preset2KPortrait: VirtualDisplayConfiguration {
        preset(.qhd2K, orientation: .portrait)
    }

    /// Configuration preset for 4K displays
    public static var preset4K: VirtualDisplayConfiguration {
        preset(.uhd4K, orientation: .landscape)
    }

    /// Configuration preset for 4K portrait displays
    public static var preset4KPortrait: VirtualDisplayConfiguration {
        preset(.uhd4K, orientation: .portrait)
    }

    // MARK: - Preset Helpers

    /// A plausible panel size for a resolution, keeping the aspect ratio honest
    /// so macOS derives sane DPI values.
    private static func physicalSize(forWidth width: Int, height: Int) -> CGSize {
        // Roughly a 27" panel on its long edge.
        let longEdgeMillimeters: CGFloat = 600
        guard width > 0, height > 0 else {
            return CGSize(width: longEdgeMillimeters, height: longEdgeMillimeters)
        }
        if width >= height {
            return CGSize(
                width: longEdgeMillimeters,
                height: (longEdgeMillimeters * CGFloat(height) / CGFloat(width)).rounded()
            )
        }
        return CGSize(
            width: (longEdgeMillimeters * CGFloat(width) / CGFloat(height)).rounded(),
            height: longEdgeMillimeters
        )
    }

    /// A serial number unique to a resolution.
    ///
    /// macOS remembers the chosen mode per display identity (vendor + product +
    /// serial). Reusing one serial for every preset means a display created for
    /// a small preset can be asked to restore a resolution it does not offer,
    /// after which it never comes online.
    private static func identity(width: Int, height: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: width &* 100_000 &+ height) | 0x0001
    }

    // MARK: - Default Modes
    
    private static func defaultDisplayModes(refreshRate: CGFloat) -> [DisplayMode] {
        [
            // 16:9 aspect ratio
            DisplayMode(width: 3840, height: 2160, refreshRate: refreshRate),
            DisplayMode(width: 2560, height: 1440, refreshRate: refreshRate),
            DisplayMode(width: 1920, height: 1080, refreshRate: refreshRate),
            DisplayMode(width: 1600, height: 900, refreshRate: refreshRate),
            DisplayMode(width: 1366, height: 768, refreshRate: refreshRate),
            DisplayMode(width: 1280, height: 720, refreshRate: refreshRate),
            // 16:10 aspect ratio
            DisplayMode(width: 2560, height: 1600, refreshRate: refreshRate),
            DisplayMode(width: 1920, height: 1200, refreshRate: refreshRate),
            DisplayMode(width: 1680, height: 1050, refreshRate: refreshRate),
            DisplayMode(width: 1440, height: 900, refreshRate: refreshRate),
            DisplayMode(width: 1280, height: 800, refreshRate: refreshRate),
        ]
    }
}

// MARK: - Supporting Types

/// Standard resolutions a virtual display can be created with
public enum DisplayResolutionPreset: String, Sendable, CaseIterable, Identifiable, Hashable {
    /// 1280x720
    case hd720
    /// 1920x1080
    case fullHD
    /// 1920x1200
    case wuxga
    /// 2560x1440
    case qhd2K
    /// 2560x1600
    case wqxga
    /// 3200x1800
    case qhdPlus3K
    /// 3840x2160
    case uhd4K
    /// 5120x2880
    case uhd5K

    public var id: String { rawValue }

    /// Native pixel size in landscape orientation
    public var landscapeSize: (width: Int, height: Int) {
        switch self {
        case .hd720: return (1280, 720)
        case .fullHD: return (1920, 1080)
        case .wuxga: return (1920, 1200)
        case .qhd2K: return (2560, 1440)
        case .wqxga: return (2560, 1600)
        case .qhdPlus3K: return (3200, 1800)
        case .uhd4K: return (3840, 2160)
        case .uhd5K: return (5120, 2880)
        }
    }

    /// Native pixel size for the given orientation
    public func pixelSize(for orientation: DisplayOrientation) -> (width: Int, height: Int) {
        let size = landscapeSize
        switch orientation {
        case .landscape: return size
        case .portrait: return (size.height, size.width)
        }
    }

    /// Total pixels, used to order the presets
    public var pixelCount: Int {
        landscapeSize.width * landscapeSize.height
    }

    /// Short label, e.g. "2K"
    public var shortName: String {
        switch self {
        case .hd720: return "720p"
        case .fullHD: return "1080p"
        case .wuxga: return "1200p"
        case .qhd2K: return "2K"
        case .wqxga: return "2.5K"
        case .qhdPlus3K: return "3K"
        case .uhd4K: return "4K"
        case .uhd5K: return "5K"
        }
    }

    /// Label including the resolution, e.g. "2K - 2560x1440"
    public var displayName: String {
        "\(shortName) - \(landscapeSize.width)x\(landscapeSize.height)"
    }

    /// Presets ordered from smallest to largest
    public static var ordered: [DisplayResolutionPreset] {
        allCases.sorted { $0.pixelCount < $1.pixelCount }
    }
}

/// Orientation of a virtual display
public enum DisplayOrientation: String, Sendable, CaseIterable, Identifiable, Hashable {
    case landscape
    case portrait

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }
}


/// Represents a display mode (resolution + refresh rate)
public struct DisplayMode: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let refreshRate: CGFloat
    
    public init(width: Int, height: Int, refreshRate: CGFloat = 60) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }
    
    public var size: CGSize {
        CGSize(width: width, height: height)
    }
    
    public var aspectRatio: CGFloat {
        guard height > 0 else { return 0 }
        return CGFloat(width) / CGFloat(height)
    }
}

/// Backend options for display streaming
public enum StreamingBackend: Sendable {
    /// Automatically select the best available backend
    case automatic
    
    /// Use ScreenCaptureKit (macOS 12.3+, recommended)
    case screenCaptureKit
    
    /// Use legacy CGDisplayStream (deprecated but wider compatibility)
    case cgDisplayStream
}

/// Display rotation options
public enum DisplayRotation: Int, Sendable, CaseIterable {
    /// No rotation (landscape)
    case none = 0
    
    /// 90 degrees clockwise (portrait, home button on right)
    case clockwise90 = 90
    
    /// 180 degrees (landscape, upside down)
    case upsideDown = 180
    
    /// 270 degrees clockwise / 90 degrees counter-clockwise (portrait, home button on left)
    case counterClockwise90 = 270
    
    /// Rotation angle in radians
    public var radians: CGFloat {
        CGFloat(rawValue) * .pi / 180.0
    }
    
    /// Rotation angle in degrees
    public var degrees: Int {
        rawValue
    }
    
    /// Whether this rotation results in a portrait orientation (width < height)
    public var isPortrait: Bool {
        self == .clockwise90 || self == .counterClockwise90
    }
    
    /// Display name for UI
    public var displayName: String {
        switch self {
        case .none: return "0°"
        case .clockwise90: return "90°"
        case .upsideDown: return "180°"
        case .counterClockwise90: return "270°"
        }
    }
}
