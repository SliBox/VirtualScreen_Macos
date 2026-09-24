# VirtualDisplayKit

[![Fork of DeskPad](https://img.shields.io/badge/fork_of-Stengo%2FDeskPad-blue)](https://github.com/Stengo/DeskPad)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9+-orange.svg)](https://swift.org)
[![macOS 13+](https://img.shields.io/badge/macOS-13+-blue.svg)]()

> **A Swift Package derived from [Stengo/DeskPad](https://github.com/Stengo/DeskPad).**
> DeskPad pioneered the use of `CGVirtualDisplay` for on-screen virtual display
> creation on macOS. VirtualDisplayKit extends that foundation into a modular,
> reusable Swift Package with video recording, RTMP-ready streaming output,
> and SwiftUI/AppKit view integrations. See [ATTRIBUTION.md](ATTRIBUTION.md)
> for a full breakdown of what is derived and what is original.

> [!WARNING]
> **This library uses Apple's private `CGVirtualDisplay` API.** Private APIs
> are not officially supported by Apple and may change between macOS versions.
> Apps using this library are **not suitable for App Store submission** without
> understanding and accepting the risk of rejection. This is intended for
> internal tools, development utilities, digital signage systems, and
> direct-distribution applications. See [SECURITY.md](SECURITY.md) for more.

A modular Swift Package for creating and managing virtual displays on macOS, with built-in support for recording and streaming. Designed for easy integration into existing applications, particularly useful for digital signage, remote desktop testing, streaming, and multi-monitor development scenarios.

## Features

- 🖥️ **Virtual Display Creation**: Create virtual displays that appear as real monitors to macOS
- 📺 **Live Display Streaming**: Stream virtual display content to your app using modern APIs
- 🎥 **Recording**: Record virtual display content to H.264/HEVC video files
- 📡 **Streaming Output**: Get encoded frames for RTMP/HLS streaming integration
- 🌐 **Browser Streaming**: Serve the display to any device on the network — one port, viewer page included
- 🎨 **SwiftUI & AppKit Support**: Native views for both UI frameworks
- ⚙️ **Highly Configurable**: Customize resolution, refresh rate, HiDPI support, and more
- 🚀 **Modern Swift**: Built with Swift Concurrency, Combine, and modern best practices
- 📦 **Swift Package Manager**: Easy integration as a dependency

## Requirements

- macOS 13.0+
- Xcode 15.0+
- Swift 5.9+

## Installation

### Swift Package Manager

Add VirtualDisplayKit to your project by adding it as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(path: "../VirtualDisplayKit")
    // Or from a git repository:
    // .package(url: "https://github.com/yourusername/VirtualDisplayKit.git", from: "1.0.0")
]
```

Then add it to your target:

```swift
.target(
    name: "YourApp",
    dependencies: ["VirtualDisplayKit"]
)
```

### Xcode Project

1. In Xcode, go to **File → Add Package Dependencies...**
2. Enter the package URL or path
3. Select your target and click **Add Package**

## Demo Application

A full-featured demo application is included in `VirtualDisplayDemo.xcodeproj`. Open it in Xcode to see all features in action:

- Virtual display creation with preset configurations
- Live preview with cursor tracking
- Recording to MP4/MOV files
- Streaming output with frame statistics

To run the demo:
1. Open `VirtualDisplayDemo.xcodeproj` in Xcode
2. Build and run (⌘R)

## Quick Start

### Simple Usage with VirtualDisplayController

The easiest way to use VirtualDisplayKit:

```swift
import VirtualDisplayKit

// Create a controller
let controller = VirtualDisplayController(preset: .standard1080p)

// Start the virtual display
controller.start()

// Create and show a preview window
let window = controller.createPreviewWindow()
window.makeKeyAndOrderFront(nil)

// When done, stop the display
controller.stop()
```

### SwiftUI Integration

```swift
import SwiftUI
import VirtualDisplayKit

struct ContentView: View {
    @StateObject private var virtualDisplay = VirtualDisplay(
        configuration: VirtualDisplayConfiguration(
            name: "My Display",
            maxWidth: 1920,
            maxHeight: 1080
        )
    )
    
    var body: some View {
        VStack {
            VirtualDisplayView(virtualDisplay: virtualDisplay) { point in
                // Handle tap - move cursor to that point
                virtualDisplay.moveCursor(to: point)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            HStack {
                Button("Start") {
                    virtualDisplay.start()
                }
                .disabled(virtualDisplay.isReady)
                
                Button("Stop") {
                    virtualDisplay.stop()
                }
                .disabled(!virtualDisplay.isReady)
            }
        }
        .padding()
    }
}
```

### Recording

Record virtual display content to video files:

```swift
let controller = VirtualDisplayController(preset: .standard1080p)
controller.start()

// Start recording with high quality settings
let outputURL = URL(fileURLWithPath: "/path/to/recording.mp4")
try controller.startRecording(to: outputURL, configuration: .highQuality)

// Later, stop recording
let finalURL = try await controller.stopRecording()
print("Recording saved to: \(finalURL)")
```

Available recording configurations:
- `.standard` - 30fps, 5Mbps H.264
- `.highQuality` - 60fps, 10Mbps H.264
- `.hevcHighEfficiency` - 30fps, 4Mbps HEVC

### Streaming

Get encoded frames for streaming to external services (Twitch, YouTube, custom RTMP):

```swift
let controller = VirtualDisplayController(preset: .standard1080p)
controller.start()

// Start streaming with RTMP-optimized settings
try controller.startStreaming(configuration: .rtmpStreaming) { data, presentationTime, isKeyFrame in
    // Send encoded H.264 data to your streaming server
    // data: Annex B formatted NAL units
    // presentationTime: CMTime for synchronization
    // isKeyFrame: true for I-frames
    
    yourRTMPClient.sendVideoFrame(data, timestamp: presentationTime, isKeyframe: isKeyFrame)
}

// Stop streaming
controller.stopStreaming()
```

Available streaming configurations:
- `.rtmpStreaming` - Optimized for Twitch/YouTube (4.5Mbps, 30fps)
- `.highQuality` - High quality streaming (8Mbps, 60fps)
- `.realtime` - Low latency for real-time apps (3Mbps, 1s keyframes)

### Browser Streaming

Serve the virtual display to any browser on your network. One port hosts both the
viewer page and the frame feed, so there is nothing to install on the other device:

```swift
let controller = VirtualDisplayController(preset: .standard1080p)
controller.start()

// Wait until controller.isReady, then:
let endpoints = try controller.startBrowserStream(
    configuration: BrowserStreamConfiguration(
        port: 8080,
        targetFPS: 30,
        minimumFPS: 2,       // floor for when the screen sits still; 0 = off
        jpegQuality: 0.6,
        scale: 1.0,          // fraction of the display's native pixel size
        maximumWidth: 1920   // cap for 4K displays
    )
)

for endpoint in endpoints {
    print("\(endpoint.interfaceName): \(endpoint.url)")  // Wi-Fi: http://192.168.1.42:8080
}

// Quality can change while the stream is live
controller.setBrowserStreamQuality(0.45)

controller.stopBrowserStream()
```

Open the printed URL on a phone, tablet or another Mac and the display fills the
screen. The page reconnects on its own and shows resolution, frame rate,
bitrate and latency in an auto-hiding overlay.

**Viewing**

| | Desktop | Touch |
|---|---|---|
| Zoom | scroll, or double-click | pinch, or double-tap |
| Pan | drag | drag |
| Fit to screen | `0` or `R`, or the button | the button |
| Fullscreen | `F`, or the button | the button |
| Hide the overlay | `H`, or the button | the button |

Zoom and pan are applied as a CSS transform, so they cost a compositor matrix
rather than a redraw, and never touch the decode path. Past 1:1 the picture
switches to nearest-neighbour so you see real pixels instead of a blur. Add
`?hud=0` to start with the overlay hidden — handy for signage.

**On phones**

The layout follows `visualViewport` rather than `window.innerHeight`, and a
fixed `#app` box is sized and offset from it on every viewport change. Mobile
browsers keep the layout viewport extended behind their collapsible toolbars, so
a picture centred against `innerHeight` slides below the visible area.

Safari has no fullscreen API for ordinary elements, so its toolbars sit over the
picture permanently — on an iPhone 16 in landscape they take 83 of 393 CSS
pixels, a fifth of the screen. The viewer is therefore also a home-screen web
app: **Share → Add to Home Screen**, then open it from the icon and it runs
without browser chrome. The page serves its own `manifest.webmanifest` and
icon, and points this out once on iOS Safari.

Live statistics are published on the controller:

```swift
controller.$browserStreamStats
    .sink { stats in
        print("\(stats.clientCount) viewers · \(stats.captureFPS) fps encoded"
            + " · \(stats.deliveredFPS) delivered · \(stats.bitrate / 1e6) Mbps"
            + " · \(stats.roundTripMilliseconds) ms round trip")
    }

`captureFPS` counts frames encoded, `deliveredFPS` counts frames each viewer
actually received. Both drop to zero when the screen is not changing — that is
the point, not a fault. `roundTripMilliseconds` measures send to painted-and-
confirmed, so it covers the network both ways plus the viewer's decode.
```

**How it is kept fast**

Only the parts of the screen that changed are sent. ScreenCaptureKit reports the
dirty regions of each frame; the server encodes a JPEG of each region, prefixed
with eight bytes of geometry, and the page paints them onto a persistent canvas.

Sending the *bounding box* of the changes is a trap worth avoiding: a cursor
moving in one corner and a clock ticking in the other span the whole screen
while almost nothing actually changed — measured at one point as 2% of pixels
inside a box covering 84%. Regions are therefore merged only when the rectangle
around them is not much bigger than the parts, up to a small tile budget.

Measured on a busy desktop, against sending a full frame per change:

| | Full frames | Bounding box | Separate tiles |
|---|---|---|---|
| Bandwidth | 19.1 Mbps | 4.2 Mbps | **1.8 Mbps** |
| Median frame | 140 KB | 7.4 KB | **2.1 KB** |

The rest:

- ScreenCaptureKit paces capture to the target frame rate and scales on the GPU,
  so no frame is ever encoded just to be thrown away
- Frames the system reports as unchanged are never encoded, and nothing is
  encoded at all while no viewer is connected
- A completely still screen produces no frames, which is efficient but looks
  identical to a stalled stream. `minimumFPS` puts a floor under that by
  refreshing one horizontal band of the screen at that rate — roughly a sixth
  of a frame each time — so the viewer keeps receiving and converges on the
  truth even if it ever missed something. Set it to `0` to stay silent
- Capture, JPEG encoding and socket writes all run off the main thread
- The WebSocket header and the JPEG payload are written as one batched socket
  write, so frames are never copied to prepend a header
- Nagle's algorithm is disabled, and the number of frames in flight per viewer
  is sized to that viewer's measured round trip. Throughput is
  `framesInFlight / roundTrip`, so a fixed window silently caps frame rate as
  latency rises — a viewer 100 ms away needs about four 30 fps frames in flight
  just to sustain 30 fps
- A viewer that misses a tile has that region folded into the *next* update
  rather than triggering a full-screen resend, which would make the congestion
  that caused the miss worse
- The page decodes off the main thread with `createImageBitmap` and draws to a
  `desynchronized` canvas, skipping a compositor round trip

**Sandboxed apps** need the `com.apple.security.network.server` entitlement.

### Advanced: Direct Frame Access

For custom processing, access raw frames directly:

```swift
let renderer = DisplayStreamRenderer(backend: .cgDisplayStream, showCursor: true)
renderer.configure(displayID: displayID, resolution: resolution, scaleFactor: scaleFactor)

// Get IOSurface frames
renderer.onFrameAvailable = { surface in
    // Use IOSurface for Metal/OpenGL rendering
}

// Get CVPixelBuffer frames (for VideoToolbox, Core Image, etc.)
renderer.onPixelBufferAvailable = { pixelBuffer in
    // Process with Core Image, VideoToolbox, etc.
}
```

## Configuration Options

### VirtualDisplayConfiguration

```swift
let configuration = VirtualDisplayConfiguration(
    name: "My Virtual Display",       // Display name shown in System Preferences
    maxWidth: 3840,                    // Maximum width in pixels
    maxHeight: 2160,                   // Maximum height in pixels
    physicalSizeMillimeters: CGSize(width: 600, height: 340), // Physical size for DPI
    vendorID: 0x3456,                  // Vendor ID for identification
    productID: 0x1234,                 // Product ID for identification
    serialNumber: 0x0001,              // Serial number
    hiDPIEnabled: true,                // Enable Retina/HiDPI modes
    refreshRate: 60,                   // Refresh rate in Hz
    displayModes: [                    // Available resolution modes
        DisplayMode(width: 1920, height: 1080, refreshRate: 60),
        DisplayMode(width: 1280, height: 720, refreshRate: 60),
    ],
    showCursor: true,                  // Show cursor in stream
    streamingBackend: .automatic       // Streaming technology to use
)
```

### Configuration Presets

```swift
// Any standard resolution, landscape or portrait:
// 720p, 1080p, 1200p, 2K (2560x1440), 2.5K (2560x1600), 3K (3200x1800),
// 4K (3840x2160), 5K (5120x2880)
let config = VirtualDisplayConfiguration.preset(.qhd2K, orientation: .landscape)
let controller = VirtualDisplayController(resolution: .uhd4K, orientation: .portrait)

// Named shorthands
let config1 = VirtualDisplayConfiguration.preset1080p
let config2 = VirtualDisplayConfiguration.preset2K
let config3 = VirtualDisplayConfiguration.preset4K

// Digital signage (includes portrait modes)
let config4 = VirtualDisplayConfiguration.presetSignage
```

## Architecture

```
VirtualDisplayKit/
├── Package.swift                 # SPM package definition
├── Sources/
│   ├── CVirtualDisplayPrivate/   # C headers for private APIs
│   │   └── include/
│   │       └── CGVirtualDisplayPrivate.h
│   └── VirtualDisplayKit/
│       ├── Core/
│       │   ├── VirtualDisplay.swift           # Main display manager
│       │   ├── VirtualDisplayConfiguration.swift
│       │   ├── DisplayStreamRenderer.swift    # Stream rendering
│       │   ├── DisplayRecorder.swift          # Video recording
│       │   └── FrameOutputStream.swift        # Streaming output
│       ├── Streaming/
│       │   ├── BrowserStreamServer.swift      # HTTP + WebSocket server
│       │   ├── ScreenFrameSource.swift        # Capture + JPEG encoding
│       │   ├── BrowserStreamPage.swift        # Embedded viewer page
│       │   ├── WebSocketFrame.swift           # RFC 6455 framing
│       │   └── NetworkInterfaces.swift        # LAN address discovery
│       ├── Views/
│       │   ├── VirtualDisplayView.swift       # SwiftUI view
│       │   └── VirtualDisplayNSView.swift     # AppKit view
│       ├── VirtualDisplayController.swift     # High-level controller
│       └── VirtualDisplayKit.swift            # Public exports
├── Tests/
│   └── VirtualDisplayKitTests/
├── VirtualDisplayDemo/           # Demo app source
└── VirtualDisplayDemo.xcodeproj  # Demo app project
```

## Use Cases

### Digital Signage Testing

Test your digital signage content without needing physical displays:

```swift
let controller = VirtualDisplayController(preset: .signage)
controller.start()

// Your signage app will see this as a real display
// Record a demo video
try controller.startRecording(to: demoURL, configuration: .highQuality)
```

### Multi-Monitor Development

Develop and test multi-monitor features on a single-screen machine:

```swift
// Create multiple virtual displays
let display1 = VirtualDisplay(configuration: VirtualDisplayConfiguration(name: "Virtual 1"))
let display2 = VirtualDisplay(configuration: VirtualDisplayConfiguration(name: "Virtual 2"))

display1.start()
display2.start()
```

### Streaming Integration

Integrate with OBS, streaming services, or custom solutions:

```swift
let stream = FrameOutputStream(configuration: .rtmpStreaming)
stream.configure(displaySize: resolution, scaleFactor: 2.0)

stream.onEncodedFrame = { data, time, isKeyFrame in
    // Send to RTMP server
    rtmpClient.publish(data: data, timestamp: time.seconds)
}

try stream.start()
```

## Important Notes

### Private API Usage

This library uses Apple's private `CGVirtualDisplay` API to create virtual displays. While this API has been stable for several years and is used by popular apps like BetterDisplay, be aware that:

- Private APIs are not officially supported by Apple
- They may change between macOS versions
- Apps using private APIs may face additional scrutiny for App Store submission

### Permissions

Your app will need screen recording permission to stream display content. This is handled automatically by macOS when using ScreenCaptureKit or CGDisplayStream.

### Known Limitations

- Virtual displays persist until the creating application terminates
- ScreenCaptureKit has some known issues with multiple virtual displays (we default to CGDisplayStream)
- HiDPI modes require appropriate configuration to work correctly

## License

MIT License - See LICENSE file for details.

## Credits

This project is a fork of and derivative work based on **[DeskPad](https://github.com/Stengo/DeskPad)** by [Bastian Andelefski](https://github.com/Stengo), licensed under MIT. DeskPad pioneered the use of `CGVirtualDisplay` for on-screen virtual display creation on macOS, and that approach is preserved at the core of VirtualDisplayKit.

See [ATTRIBUTION.md](ATTRIBUTION.md) for a complete breakdown of what is derived from DeskPad versus what is original to this project.
