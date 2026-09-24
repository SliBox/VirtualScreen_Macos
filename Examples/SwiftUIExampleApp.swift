//
//  SwiftUIExampleApp.swift
//  VirtualDisplayKit Examples
//
//  Example SwiftUI application demonstrating VirtualDisplayKit usage.
//  Copy this into a new Xcode project to test.
//

import SwiftUI
import VirtualDisplayKit
import Combine

// MARK: - App Entry Point

/// Example: Basic SwiftUI App with Virtual Display
///
/// To use this example:
/// 1. Create a new macOS SwiftUI app in Xcode
/// 2. Add VirtualDisplayKit as a local package dependency
/// 3. Replace the App file content with this code
///
@main
struct VirtualDisplayExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ExampleContentView()
        }
    }
}

// MARK: - Content View

struct ExampleContentView: View {
    @StateObject private var viewModel = ExampleViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Virtual Display Preview
            ZStack {
                Color(NSColor.controlBackgroundColor)
                
                if viewModel.isDisplayActive {
                    if viewModel.isReady {
                        VirtualDisplayView(
                            virtualDisplay: viewModel.controller.virtualDisplay,
                            highlightWhenCursorInside: true
                        ) { point in
                            viewModel.controller.moveCursor(to: point)
                        }
                        .padding()
                    } else {
                        ProgressView("Waiting for display...")
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "display")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Click Start to create a virtual display")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Divider()
            
            // Footer with status
            footerView
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    private var headerView: some View {
        HStack {
            Text("Virtual Display")
                .font(.headline)

            Spacer()

            // Preset picker
            Picker("Preset", selection: $viewModel.selectedPreset) {
                Text("1080p").tag(VirtualDisplayController.ConfigurationPreset.standard1080p)
                Text("1080p Portrait").tag(VirtualDisplayController.ConfigurationPreset.portrait1080p)
                Text("2K").tag(VirtualDisplayController.ConfigurationPreset.standard2K)
                Text("2K Portrait").tag(VirtualDisplayController.ConfigurationPreset.portrait2K)
                Text("4K").tag(VirtualDisplayController.ConfigurationPreset.high4K)
                Text("4K Portrait").tag(VirtualDisplayController.ConfigurationPreset.portrait4K)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 400)
            .disabled(viewModel.isDisplayActive)

            Spacer()

            // Capture button
            if viewModel.isDisplayActive && viewModel.isReady {
                Button("Capture") {
                    viewModel.captureFrame()
                }
                .buttonStyle(.bordered)
            }

            // Start/Stop button
            Button(viewModel.isDisplayActive ? "Stop" : "Start") {
                viewModel.toggleDisplay()
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isDisplayActive ? .red : .green)
        }
        .padding()
    }
    
    private var footerView: some View {
        HStack {
            // State indicator
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            
            Text(stateText)
                .font(.caption)
            
            Spacer()
            
            if viewModel.isReady {
                Text("\(Int(viewModel.resolution.width))×\(Int(viewModel.resolution.height))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if viewModel.isCursorInside {
                Label("Cursor in display", systemImage: "cursorarrow")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .padding()
    }
    
    private var stateColor: Color {
        if !viewModel.isDisplayActive {
            return .gray
        } else if viewModel.isReady {
            return .green
        } else {
            return .orange
        }
    }
    
    private var stateText: String {
        if !viewModel.isDisplayActive {
            return "Inactive"
        } else if viewModel.isReady {
            return "Ready"
        } else {
            return "Starting..."
        }
    }
}

// MARK: - View Model

@MainActor
class ExampleViewModel: ObservableObject {
    @Published var isDisplayActive = false
    @Published var isReady = false
    @Published var resolution: CGSize = .zero
    @Published var isCursorInside = false
    @Published var selectedPreset: VirtualDisplayController.ConfigurationPreset = .standard1080p
    
    private(set) var controller: VirtualDisplayController!
    
    init() {
        controller = VirtualDisplayController(preset: selectedPreset)
        setupObservers()
    }
    
    private func setupObservers() {
        // Observe display state changes
        controller.virtualDisplay.$isReady
            .receive(on: DispatchQueue.main)
            .assign(to: &$isReady)
        
        controller.virtualDisplay.$resolution
            .receive(on: DispatchQueue.main)
            .assign(to: &$resolution)
        
        controller.virtualDisplay.$isCursorInside
            .receive(on: DispatchQueue.main)
            .assign(to: &$isCursorInside)
    }
    
    func toggleDisplay() {
        if isDisplayActive {
            controller.stop()
            isDisplayActive = false
        } else {
            // Recreate controller with selected preset
            controller = VirtualDisplayController(preset: selectedPreset)
            setupObservers()
            controller.start()
            isDisplayActive = true
        }
    }

    func captureFrame() {
        Task {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let filename = "VirtualDisplay_\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)).jpg"
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = downloadsURL.appendingPathComponent(filename)

            do {
                if let url = try await controller.captureFrame(to: fileURL) {
                    print("✅ Frame captured to: \(url.path)")
                    NSWorkspace.shared.open(url)
                }
            } catch {
                print("❌ Capture failed: \(error)")
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ExampleContentView()
}
