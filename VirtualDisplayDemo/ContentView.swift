//
//  ContentView.swift
//  VirtualDisplayDemo
//
//  Main content view for the demo application.
//

import SwiftUI
import VirtualDisplayKit
import Combine
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    
    var body: some View {
        HSplitView {
            // Left panel - Display preview
            displayPanel
                .frame(minWidth: 500)
            
            // Right panel - Controls
            controlPanel
                .frame(width: 320)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Display Panel
    
    private var displayPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                
                Text("Virtual Display")
                    .font(.title2.bold())
                
                Spacer()
                
                statusIndicator
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // Display content
            ZStack {
                if viewModel.isDisplayActive {
                    if viewModel.isDisplayReady {
                        VirtualDisplayView(
                            virtualDisplay: viewModel.controller.virtualDisplay,
                            highlightWhenCursorInside: true
                        ) { point in
                            viewModel.controller.moveCursor(to: point)
                        }
                        .padding()
                    } else {
                        // Waiting for display to be ready
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Waiting for virtual display...")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    placeholderView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
            
            Divider()
            
            // Info bar
            infoBar
        }
    }
    
    private var statusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
    
    private var statusColor: Color {
        if !viewModel.isDisplayActive {
            return .gray
        } else if viewModel.isDisplayReady {
            return .green
        } else {
            return .orange
        }
    }
    
    private var statusText: String {
        if !viewModel.isDisplayActive {
            return "Inactive"
        } else if viewModel.isDisplayReady {
            return "Active"
        } else {
            return "Starting..."
        }
    }
    
    private var placeholderView: some View {
        VStack(spacing: 20) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("No Virtual Display")
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text("Click \"Start Display\" to create a virtual display")
                .font(.callout)
                .foregroundColor(.secondary.opacity(0.8))
            
            Button("Start Display") {
                viewModel.toggleDisplay()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
    
    private var infoBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                infoItem(icon: "rectangle.dashed", title: "Resolution", value: viewModel.resolutionText)
                
                Divider().frame(height: 20)
                
                infoItem(icon: "scalemass", title: "Scale", value: viewModel.scaleText)
                
                Divider().frame(height: 20)
                
                infoItem(icon: "rectangle.portrait.arrowtriangle.2.outward", title: "Orientation", value: viewModel.orientationText)
                
                Divider().frame(height: 20)
                
                infoItem(icon: "cursorarrow", title: "Cursor Inside", value: viewModel.cursorInsideText)
                
                Spacer()
                
                if viewModel.isRecording {
                    recordingIndicator
                }
                
                if viewModel.isStreaming {
                    streamingIndicator
                }
            }
            
            if viewModel.isDisplayActive {
                HStack(spacing: 4) {
                    Image(systemName: "keyboard")
                        .font(.caption2)
                    Text("Press")
                    Text("⌃⌥⌘ Space")
                        .fontWeight(.medium)
                    Text("to return cursor to primary screen")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private func infoItem(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }
    
    private var recordingIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(viewModel.recordingPulse ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.5).repeatForever(), value: viewModel.recordingPulse)
            
            Text("REC")
                .font(.caption.bold())
                .foregroundColor(.red)
            
            Text(viewModel.recordingDurationText)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.red.opacity(0.1)))
    }
    
    private var streamingIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundColor(.green)
                .font(.caption)
            
            Text("LIVE")
                .font(.caption.bold())
                .foregroundColor(.green)
            
            Text("\(Int(viewModel.streamingFrameRate)) fps")
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.green.opacity(0.1)))
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Display Controls
                controlSection(title: "Display", icon: "display") {
                    displayControls
                }
                
                Divider()
                
                // Recording Controls
                controlSection(title: "Recording", icon: "record.circle") {
                    recordingControls
                }
                
                Divider()

                // Browser Streaming
                controlSection(title: "Browser Stream", icon: "globe") {
                    browserStreamControls
                }

                Divider()

                // Streaming Controls
                controlSection(title: "Streaming", icon: "antenna.radiowaves.left.and.right") {
                    streamingControls
                }

                Divider()

                // Window Layers
                controlSection(title: "Window Layers", icon: "square.3.layers.3d") {
                    windowLayerControls
                }

                Spacer()
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private func controlSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }
            
            content()
        }
    }
    
    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Resolution")
                    .font(.subheadline)
                Spacer()
                Text(viewModel.selectedResolutionSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Picker("Resolution", selection: $viewModel.selectedResolution) {
                ForEach(DisplayResolutionPreset.ordered) { resolution in
                    Text(resolution.displayName).tag(resolution)
                }
            }
            .labelsHidden()
            .disabled(viewModel.isDisplayActive)

            Picker("Orientation", selection: $viewModel.selectedOrientation) {
                ForEach(DisplayOrientation.allCases) { orientation in
                    Text(orientation.displayName).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(viewModel.isDisplayActive)

            Toggle("HiDPI (Retina) - renders at 2x, 4x the pixels", isOn: $viewModel.hiDPIEnabled)
                .font(.caption)
                .disabled(viewModel.isDisplayActive)

            if let error = viewModel.displayError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button(action: viewModel.toggleDisplay) {
                    HStack {
                        Image(systemName: viewModel.isDisplayActive ? "stop.fill" : "play.fill")
                        Text(viewModel.isDisplayActive ? "Stop Display" : "Start Display")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isDisplayActive ? .red : .green)
                .controlSize(.large)

                if viewModel.isDisplayActive && viewModel.isDisplayReady {
                    Button(action: viewModel.captureFrame) {
                        Image(systemName: "camera")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Capture frame to Downloads")
                }
            }
        }
    }
    
    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quality")
                    .font(.subheadline)
                Spacer()
            }
            
            HStack(spacing: 8) {
                qualityButton("Standard", quality: .standard)
                qualityButton("High", quality: .high)
                qualityButton("HEVC", quality: .hevc)
            }
            .disabled(viewModel.isRecording)
            
            Button(action: viewModel.toggleRecording) {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(viewModel.isRecording ? "Stop Recording" : "Start Recording")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRecording ? .red : .orange)
            .controlSize(.large)
            .disabled(!viewModel.isDisplayReady)
            
            if let lastRecordingURL = viewModel.lastRecordingURL {
                HStack {
                    Image(systemName: "film")
                        .foregroundColor(.secondary)
                    
                    Text(lastRecordingURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
    }
    
    private func qualityButton(_ title: String, quality: RecordingQuality) -> some View {
        Button(title) {
            Task { @MainActor in
                viewModel.recordingQuality = quality
            }
        }
        .buttonStyle(.bordered)
        .tint(viewModel.recordingQuality == quality ? .accentColor : .secondary)
    }
    
    // MARK: - Browser Stream

    private var browserStreamControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Port + frame rate
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("8080", text: $viewModel.streamPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 90)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("FPS Target")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $viewModel.streamFPS) {
                        ForEach([15, 24, 30, 45, 60], id: \.self) { fps in
                            Text("\(fps)").tag(fps)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("FPS Min")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $viewModel.streamMinFPS) {
                        Text("Off").tag(0)
                        ForEach([1, 2, 5, 10], id: \.self) { fps in
                            Text("\(fps)").tag(fps)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
            .disabled(viewModel.isBrowserStreaming)

            Text(viewModel.streamMinFPS == 0
                 ? "A still screen sends nothing at all — encoded fps drops to 0 by design."
                 : "A still screen refreshes one band at \(viewModel.streamMinFPS) fps, about a sixth of a frame each time.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Codec
            VStack(alignment: .leading, spacing: 4) {
                Text("Codec")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $viewModel.streamCodec) {
                    Text("JPEG").tag(BrowserStreamCodec.jpeg)
                    Text("H.264").tag(BrowserStreamCodec.h264)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(viewModel.streamCodec == .jpeg
                     ? "Sharpest text, works in every browser; more data when a lot moves."
                     : "Much less data when scrolling or moving windows. Browsers that can't decode it get JPEG.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(viewModel.isBrowserStreaming)

            // Quality
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quality")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(viewModel.streamQuality * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Slider(value: $viewModel.streamQuality, in: 0.2...0.95, step: 0.05)
                    .onChange(of: viewModel.streamQuality) { newValue in
                        viewModel.applyStreamQuality(newValue)
                    }
            }

            // Resolution scale
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Resolution")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(viewModel.streamOutputSizeText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Picker("", selection: $viewModel.streamScale) {
                    Text("Full").tag(1.0)
                    Text("75%").tag(0.75)
                    Text("50%").tag(0.5)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Picker("", selection: $viewModel.streamMaxWidth) {
                    Text("Native").tag(0)
                    Text("≤4K").tag(3840)
                    Text("≤2K").tag(2560)
                    Text("≤1080p").tag(1920)
                    Text("≤720p").tag(1280)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            .disabled(viewModel.isBrowserStreaming)

            Toggle("Allow viewers to control the Mac", isOn: $viewModel.streamAllowsControl)
                .disabled(viewModel.isBrowserStreaming)
                .help("Mouse, touch, scrolling and keyboard from the browser, limited to this virtual display. Viewers need the PIN shown below.")

            Button(action: viewModel.toggleBrowserStream) {
                HStack {
                    Image(systemName: viewModel.isBrowserStreaming ? "stop.circle.fill" : "globe.badge.chevron.backward")
                    Text(viewModel.isBrowserStreaming ? "Stop Server" : "Start Server")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isBrowserStreaming ? .red : .blue)
            .controlSize(.large)
            .disabled(!viewModel.isDisplayReady)

            if let error = viewModel.browserStreamError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if viewModel.isBrowserStreaming {
                browserStreamEndpointList
                if let pin = viewModel.browserStreamControlPIN {
                    HStack {
                        Image(systemName: "lock.fill")
                        Text("Control PIN")
                        Spacer()
                        Text(pin)
                            .font(.system(.title3, design: .monospaced).bold())
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                    .help("A viewer enters this in the browser to control the Mac. It changes every time the server starts.")
                }
                browserStreamStatsView
            } else {
                Text("Serves a full-screen viewer page and pushes frames over WebSocket. Open the URL on any device on the same network.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var browserStreamEndpointList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open on another device")
                .font(.caption)
                .foregroundColor(.secondary)

            if viewModel.browserStreamEndpoints.isEmpty {
                Text("No network interfaces found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(viewModel.browserStreamEndpoints) { endpoint in
                HStack(spacing: 6) {
                    Image(systemName: endpoint.address.isPrivateLAN ? "wifi" : "network")
                        .font(.caption)
                        .foregroundColor(endpoint.address.isPrivateLAN ? .green : .secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(endpoint.url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(endpoint.interfaceName)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 4)

                    Button {
                        viewModel.copy(endpoint.url)
                    } label: {
                        Image(systemName: viewModel.copiedURL == endpoint.url ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy URL")

                    Button {
                        if let url = URL(string: endpoint.url) {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
        }
    }

    private var browserStreamStatsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            statRow("Viewers", "\(viewModel.browserStreamStats.clientCount)")
            statRow("  on H.264", "\(viewModel.browserStreamStats.videoClientCount)")
            statRow("Encoded", "\(Int(viewModel.browserStreamStats.captureFPS)) fps")
            statRow("Delivered", "\(Int(viewModel.browserStreamStats.deliveredFPS)) fps")
            statRow("Bitrate", viewModel.browserStreamBitrateText)
            statRow("Frame size", viewModel.browserStreamSizeText)
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    private var streamingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Format")
                    .font(.subheadline)
                Spacer()
            }
            
            HStack(spacing: 8) {
                formatButton("H.264", format: .h264)
                formatButton("HEVC", format: .hevc)
                formatButton("Raw", format: .raw)
            }
            .disabled(viewModel.isStreaming)
            
            Button(action: viewModel.toggleStreaming) {
                HStack {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
                    Text(viewModel.isStreaming ? "Stop Streaming" : "Start Streaming")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isStreaming ? .red : .purple)
            .controlSize(.large)
            .disabled(!viewModel.isDisplayReady)
            
            if viewModel.isStreaming {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Frames:")
                        Spacer()
                        Text("\(viewModel.streamingFrameCount)")
                            .font(.system(.body, design: .monospaced))
                    }
                    
                    HStack {
                        Text("Data:")
                        Spacer()
                        Text(viewModel.streamingDataText)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            
            Text("Streaming outputs encoded frames for integration with RTMP servers, OBS, or custom streaming solutions.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private func formatButton(_ title: String, format: StreamingFormat) -> some View {
        Button(title) {
            Task { @MainActor in
                viewModel.streamingFormat = format
            }
        }
        .buttonStyle(.bordered)
        .tint(viewModel.streamingFormat == format ? .accentColor : .secondary)
    }

    // MARK: - Window Layers

    private var windowLayerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Track & raise all windows", isOn: Binding(
                get: { viewModel.isTrackingWindowLayers },
                set: { _ in viewModel.toggleWindowLayerTracking() }
            ))
            .toggleStyle(.switch)

            if !viewModel.windowLayerAccessibilityTrusted {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Accessibility access recommended", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)

                    Text("Without it, raising falls back to app activation. Grant access for precise per-window control.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Accessibility Settings") {
                        viewModel.openAccessibilitySettings()
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            }

            HStack {
                Text("Frontmost app")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(viewModel.frontmostAppName ?? "—")
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(viewModel.frontmostAppWindowCount) windows")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Tracked apps")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(viewModel.trackedAppCount)")
                    .font(.system(.caption, design: .monospaced))
            }

            Button(action: viewModel.bringFrontmostAppWindowsToFront) {
                HStack {
                    Image(systemName: "rectangle.stack.badge.plus")
                    Text("Raise Frontmost App's Windows")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!viewModel.isTrackingWindowLayers || viewModel.frontmostAppName == nil)

            if let name = viewModel.lastRaisedAppName {
                Text("Last raised: \(name)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - View Model

@MainActor
class ContentViewModel: ObservableObject {
    // Display state
    @Published var isDisplayActive = false
    @Published var isDisplayReady = false
    @Published var selectedResolution: DisplayResolutionPreset = .fullHD
    @Published var selectedOrientation: DisplayOrientation = .landscape
    @Published var hiDPIEnabled = false
    @Published var displayError: String?
    @Published var displayResolution: CGSize = .zero
    @Published var displayScaleFactor: CGFloat = 1.0
    @Published var isCursorInside = false
    
    // Recording state
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingQuality: RecordingQuality = .standard
    @Published var recordingPulse = false
    @Published var lastRecordingURL: URL?
    
    // Streaming state
    @Published var isStreaming = false
    @Published var streamingFrameRate: Double = 0
    @Published var streamingFormat: StreamingFormat = .h264
    @Published var streamingFrameCount: Int64 = 0
    @Published var streamingBytesOutput: Int64 = 0

    // Browser stream state
    @Published var streamPort: String = BrowserStreamDefaults.port {
        didSet { BrowserStreamDefaults.port = streamPort }
    }
    @Published var streamFPS: Int = BrowserStreamDefaults.fps {
        didSet { BrowserStreamDefaults.fps = streamFPS }
    }
    @Published var streamMinFPS: Int = BrowserStreamDefaults.minFPS {
        didSet { BrowserStreamDefaults.minFPS = streamMinFPS }
    }
    @Published var streamQuality: Double = BrowserStreamDefaults.quality {
        didSet { BrowserStreamDefaults.quality = streamQuality }
    }
    @Published var streamScale: Double = BrowserStreamDefaults.scale {
        didSet { BrowserStreamDefaults.scale = streamScale }
    }
    /// Cap on the streamed width in pixels; 0 streams the display's native width
    @Published var streamMaxWidth: Int = BrowserStreamDefaults.maxWidth {
        didSet { BrowserStreamDefaults.maxWidth = streamMaxWidth }
    }
    @Published var isBrowserStreaming = false
    @Published var browserStreamStats = BrowserStreamStats()
    @Published var browserStreamEndpoints: [BrowserStreamEndpoint] = []
    @Published var browserStreamControlPIN: String?
    @Published var streamCodec: BrowserStreamCodec = BrowserStreamDefaults.codec {
        didSet { BrowserStreamDefaults.codec = streamCodec }
    }
    @Published var streamAllowsControl: Bool = BrowserStreamDefaults.allowsControl {
        didSet { BrowserStreamDefaults.allowsControl = streamAllowsControl }
    }
    @Published var browserStreamError: String?
    @Published var copiedURL: String?

    // Window layer tracking state
    @Published var isTrackingWindowLayers = false
    @Published var windowLayerAccessibilityTrusted = false
    @Published var frontmostAppName: String?
    @Published var frontmostAppWindowCount = 0
    @Published var trackedAppCount = 0
    @Published var lastRaisedAppName: String?

    private(set) var controller: VirtualDisplayController!
    private var cancellables = Set<AnyCancellable>()
    private var windowLayerCancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var globalHotkeyMonitor: Any?
    private nonisolated(unsafe) var localHotkeyMonitor: Any?
    
    init() {
        setupController()
        setupGlobalHotkey()
        observeWindowLayers()
    }
    
    deinit {
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupGlobalHotkey() {
        // Handler for the hotkey
        let hotkeyHandler: (NSEvent) -> Void = { [weak self] event in
            // Check for Ctrl + Cmd + Option + Space
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCtrlCmdOption = flags.contains([.control, .command, .option]) && !flags.contains(.shift)
            let isSpace = event.keyCode == 49 // Space key
            
            if isCtrlCmdOption && isSpace {
                print("[Hotkey] ⌃⌥⌘Space detected!")
                Task { @MainActor in
                    self?.returnCursorToPrimaryScreen()
                }
            }
        }
        
        // Global monitor for when other apps are focused (requires Accessibility permission)
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: hotkeyHandler)
        
        // Local monitor for when this app is focused
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            hotkeyHandler(event)
            return event
        }
        
        print("[Hotkey] Global hotkey monitor set up. Press ⌃⌥⌘Space to return cursor to primary screen.")
        print("[Hotkey] Note: Global monitoring requires Accessibility permission in System Settings.")
    }
    
    func returnCursorToPrimaryScreen() {
        guard let primaryScreen = NSScreen.screens.first else {
            print("[Hotkey] No primary screen found")
            return
        }
        
        // Get the frame of the primary screen
        let frame = primaryScreen.frame
        print("[Hotkey] Primary screen frame: \(frame)")
        
        // For CGWarpMouseCursorPosition, coordinates are in global display coordinates
        // The primary display's origin is at (0,0) in the top-left
        // We want the center of the primary display
        let centerX = frame.origin.x + frame.width / 2
        
        // NSScreen uses bottom-left origin, CGWarpMouseCursorPosition uses top-left
        // For the primary screen (which contains the menu bar), we need to convert
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let centerY = mainScreenHeight - (frame.origin.y + frame.height / 2)
        
        let centerPoint = CGPoint(x: centerX, y: centerY)
        print("[Hotkey] Moving cursor to: \(centerPoint)")
        
        let result = CGWarpMouseCursorPosition(centerPoint)
        print("[Hotkey] CGWarpMouseCursorPosition result: \(result)")
        
        // Also associate the mouse with the point to avoid "jumping back" behavior
        CGAssociateMouseAndMouseCursorPosition(1)
    }
    
    private func setupController() {
        controller = VirtualDisplayController(
            resolution: selectedResolution,
            orientation: selectedOrientation,
            hiDPI: hiDPIEnabled
        )
        observeController()
    }

    /// The resolution that will be used the next time the display starts
    var selectedResolutionSummary: String {
        let size = selectedResolution.pixelSize(for: selectedOrientation)
        guard hiDPIEnabled else { return "\(size.width)x\(size.height)" }
        return "\(size.width)x\(size.height) @2x = \(size.width * 2)x\(size.height * 2) px"
    }
    
    private func observeController() {
        cancellables.removeAll()
        
        // Observe virtual display state - use sink to avoid publishing during view updates
        controller.virtualDisplay.$isReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isDisplayReady = value
            }
            .store(in: &cancellables)
        
        controller.virtualDisplay.$resolution
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.displayResolution = value
            }
            .store(in: &cancellables)
        
        controller.virtualDisplay.$scaleFactor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.displayScaleFactor = value
            }
            .store(in: &cancellables)
        
        controller.virtualDisplay.$isCursorInside
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isCursorInside = value
            }
            .store(in: &cancellables)
        
        // Observe controller state
        controller.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isRecording = value
            }
            .store(in: &cancellables)
        
        controller.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.recordingDuration = value
            }
            .store(in: &cancellables)
        
        controller.$isStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isStreaming = value
            }
            .store(in: &cancellables)
        
        controller.$streamingFrameRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.streamingFrameRate = value
            }
            .store(in: &cancellables)

        controller.$isBrowserStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isBrowserStreaming = value
            }
            .store(in: &cancellables)

        controller.$browserStreamStats
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.browserStreamStats = value
            }
            .store(in: &cancellables)

        controller.$browserStreamEndpoints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.browserStreamEndpoints = value
            }
            .store(in: &cancellables)

        controller.$browserStreamControlPIN
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.browserStreamControlPIN = value
            }
            .store(in: &cancellables)

        controller.$browserStreamError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.browserStreamError = value
            }
            .store(in: &cancellables)

        // A display that never comes online leaves the UI stuck in "active";
        // reset it so the user can fix the settings and start again.
        controller.$displayError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                self.displayError = value
                if value != nil {
                    self.isDisplayActive = false
                    self.isDisplayReady = false
                }
            }
            .store(in: &cancellables)
    }

    private func observeWindowLayers() {
        let coordinator = WindowLayerCoordinator.shared

        coordinator.$isTracking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isTrackingWindowLayers = value }
            .store(in: &windowLayerCancellables)

        coordinator.$accessibilityTrusted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.windowLayerAccessibilityTrusted = value }
            .store(in: &windowLayerCancellables)

        coordinator.$frontmostApp
            .receive(on: DispatchQueue.main)
            .sink { [weak self] app in
                self?.frontmostAppName = app?.name
                self?.frontmostAppWindowCount = app?.windowCount ?? 0
            }
            .store(in: &windowLayerCancellables)

        coordinator.$appGroups
            .receive(on: DispatchQueue.main)
            .sink { [weak self] groups in self?.trackedAppCount = groups.count }
            .store(in: &windowLayerCancellables)

        coordinator.$lastRaisedAppName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in self?.lastRaisedAppName = name }
            .store(in: &windowLayerCancellables)

        // Sync initial values
        isTrackingWindowLayers = coordinator.isTracking
        windowLayerAccessibilityTrusted = coordinator.accessibilityTrusted
        frontmostAppName = coordinator.frontmostApp?.name
        frontmostAppWindowCount = coordinator.frontmostApp?.windowCount ?? 0
        trackedAppCount = coordinator.appGroups.count
        lastRaisedAppName = coordinator.lastRaisedAppName
    }

    func toggleWindowLayerTracking() {
        let coordinator = WindowLayerCoordinator.shared
        if coordinator.isTracking {
            coordinator.stop()
        } else {
            coordinator.start()
        }
    }

    func bringFrontmostAppWindowsToFront() {
        WindowLayerCoordinator.shared.bringFrontmostAppWindowsToFront()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Computed Properties
    
    var resolutionText: String {
        guard displayResolution != .zero else { return "—" }
        return "\(Int(displayResolution.width))×\(Int(displayResolution.height))"
    }
    
    var scaleText: String {
        guard displayScaleFactor > 0 else { return "—" }
        return "\(Int(displayScaleFactor))x"
    }
    
    var orientationText: String {
        guard displayResolution != .zero else { return "—" }
        return displayResolution.width > displayResolution.height ? "Landscape" : "Portrait"
    }
    
    var cursorInsideText: String {
        isCursorInside ? "Yes" : "No"
    }
    
    var recordingDurationText: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var streamingDataText: String {
        ByteCountFormatter.string(fromByteCount: streamingBytesOutput, countStyle: .file)
    }

    var browserStreamBitrateText: String {
        let bitrate = browserStreamStats.bitrate
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", bitrate / 1_000_000)
        }
        return String(format: "%.0f kbps", bitrate / 1_000)
    }

    /// What the stream will send, given the display size and the two limits
    var streamOutputSizeText: String {
        let display = displayResolution == .zero
            ? CGSize(
                width: CGFloat(selectedResolution.pixelSize(for: selectedOrientation).width),
                height: CGFloat(selectedResolution.pixelSize(for: selectedOrientation).height)
              )
            : CGSize(
                width: displayResolution.width * displayScaleFactor,
                height: displayResolution.height * displayScaleFactor
              )

        var configuration = BrowserStreamConfiguration()
        configuration.scale = streamScale
        configuration.maximumWidth = streamMaxWidth > 0 ? streamMaxWidth : nil
        let size = BrowserStreamServer.outputSize(for: display, configuration: configuration)
        return "\(Int(size.width))×\(Int(size.height))"
    }

    var browserStreamSizeText: String {
        let size = browserStreamStats.frameSize
        guard size != .zero else { return "—" }
        return "\(Int(size.width))×\(Int(size.height))"
    }

    // MARK: - Actions
    
    func toggleDisplay() {
        if isDisplayActive {
            // Stop everything
            Task {
                if isRecording {
                    _ = try? await controller.stopRecording()
                }
                if isStreaming {
                    controller.stopStreaming()
                }
            }
            controller.stop()
            isDisplayActive = false
            isDisplayReady = false
        } else {
            // Release the previous display before creating a new one - two
            // CGVirtualDisplays with the same identity cannot coexist, and the
            // stale one would keep the new display from coming online.
            controller.stop()

            displayError = nil
            setupController()
            controller.start()
            isDisplayActive = true
            recordingPulse = true
        }
    }
    
    func toggleRecording() {
        if isRecording {
            Task {
                if let url = try? await controller.stopRecording() {
                    lastRecordingURL = url
                }
            }
        } else {
            // Show save panel to let user choose location
            let savePanel = NSSavePanel()
            savePanel.title = "Save Recording"
            savePanel.nameFieldLabel = "File Name:"
            savePanel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            
            // Generate default filename with timestamp
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "VirtualDisplay_\(dateFormatter.string(from: Date()))"
            savePanel.nameFieldStringValue = filename
            
            // Set allowed file types based on quality
            savePanel.allowedContentTypes = [.mpeg4Movie]
            savePanel.canCreateDirectories = true
            
            // Show the panel
            let response = savePanel.runModal()
            
            guard response == .OK, let outputURL = savePanel.url else {
                return
            }
            
            do {
                let config: RecordingConfiguration
                switch recordingQuality {
                case .standard:
                    config = .standard
                case .high:
                    config = .highQuality
                case .hevc:
                    config = .hevcHighEfficiency
                }
                
                try controller.startRecording(to: outputURL, configuration: config)
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
    
    func toggleStreaming() {
        if isStreaming {
            controller.stopStreaming()
            streamingFrameCount = 0
            streamingBytesOutput = 0
        } else {
            let config: StreamOutputConfiguration
            switch streamingFormat {
            case .h264:
                config = .rtmpStreaming
            case .hevc:
                config = StreamOutputConfiguration(format: .hevcAnnexB, bitrate: 4_000_000)
            case .raw:
                config = StreamOutputConfiguration(format: .rawPixelBuffer)
            }

            streamingFrameCount = 0
            streamingBytesOutput = 0

            do {
                try controller.startStreaming(configuration: config) { [weak self] data, time, isKeyFrame in
                    Task { @MainActor in
                        self?.streamingFrameCount += 1
                        self?.streamingBytesOutput += Int64(data.count)
                    }
                }
            } catch {
                print("Failed to start streaming: \(error)")
            }
        }
    }

    // MARK: - Browser Stream

    func toggleBrowserStream() {
        if isBrowserStreaming {
            controller.stopBrowserStream()
            return
        }

        guard let port = UInt16(streamPort.trimmingCharacters(in: .whitespaces)), port >= 1024 else {
            browserStreamError = "Enter a port between 1024 and 65535."
            return
        }

        browserStreamError = nil

        let configuration = BrowserStreamConfiguration(
            port: port,
            targetFPS: streamFPS,
            minimumFPS: streamMinFPS,
            jpegQuality: streamQuality,
            scale: streamScale,
            maximumWidth: streamMaxWidth > 0 ? streamMaxWidth : nil,
            showCursor: true,
            codec: streamCodec,
            allowsControl: streamAllowsControl
        )

        do {
            try controller.startBrowserStream(configuration: configuration)
        } catch {
            browserStreamError = error.localizedDescription
        }
    }

    func applyStreamQuality(_ quality: Double) {
        guard isBrowserStreaming else { return }
        controller.setBrowserStreamQuality(quality)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedURL = text

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedURL == text { copiedURL = nil }
        }
    }

    func captureFrame() {
        Task {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let filename = "VirtualDisplay_\(dateFormatter.string(from: Date())).jpg"
            let fileURL = downloadsURL.appendingPathComponent(filename)

            do {
                if let url = try await controller.captureFrame(to: fileURL) {
                    print("✅ Frame captured to: \(url.path)")
                    NSWorkspace.shared.open(url)
                } else {
                    print("❌ Capture returned no URL")
                }
            } catch {
                print("❌ Capture failed: \(error)")
            }
        }
    }
}

// MARK: - Supporting Types

enum RecordingQuality: String, CaseIterable {
    case standard
    case high
    case hevc
}

enum StreamingFormat: String, CaseIterable {
    case h264
    case hevc
    case raw
}

/// Persisted browser-stream settings, so a port survives app restarts
enum BrowserStreamDefaults {
    private static let defaults = UserDefaults.standard

    static var port: String {
        get { defaults.string(forKey: "browserStreamPort") ?? "8080" }
        set { defaults.set(newValue, forKey: "browserStreamPort") }
    }

    static var fps: Int {
        get {
            let stored = defaults.integer(forKey: "browserStreamFPS")
            return stored > 0 ? stored : 30
        }
        set { defaults.set(newValue, forKey: "browserStreamFPS") }
    }

    static var minFPS: Int {
        get {
            guard defaults.object(forKey: "browserStreamMinFPS") != nil else { return 2 }
            return defaults.integer(forKey: "browserStreamMinFPS")
        }
        set { defaults.set(newValue, forKey: "browserStreamMinFPS") }
    }

    static var quality: Double {
        get {
            let stored = defaults.double(forKey: "browserStreamQuality")
            return stored > 0 ? stored : 0.6
        }
        set { defaults.set(newValue, forKey: "browserStreamQuality") }
    }

    static var maxWidth: Int {
        get { defaults.integer(forKey: "browserStreamMaxWidth") }
        set { defaults.set(newValue, forKey: "browserStreamMaxWidth") }
    }

    static var scale: Double {
        get {
            let stored = defaults.double(forKey: "browserStreamScale")
            return stored > 0 ? stored : 1.0
        }
        set { defaults.set(newValue, forKey: "browserStreamScale") }
    }

    static var codec: BrowserStreamCodec {
        get { defaults.string(forKey: "browserStreamCodec").flatMap(BrowserStreamCodec.init(rawValue:)) ?? .jpeg }
        set { defaults.set(newValue.rawValue, forKey: "browserStreamCodec") }
    }

    static var allowsControl: Bool {
        get { defaults.bool(forKey: "browserStreamAllowsControl") }
        set { defaults.set(newValue, forKey: "browserStreamAllowsControl") }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
