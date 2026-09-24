//
//  WindowLayerCoordinator.swift
//  VirtualDisplayKit
//
//  Tracks on-screen windows across all running apps and, when an app becomes
//  active (for example when the user clicks one of its windows), raises every
//  window belonging to that app so detached-tab windows, utility windows and
//  other "dependent" windows come to the front together with the clicked one.
//

import AppKit
import ApplicationServices
import Combine

/// A single on-screen window snapshot captured from the window server.
public struct WindowLayerSnapshot: Identifiable, Equatable, Sendable {
    /// The CoreGraphics window id.
    public let id: CGWindowID
    /// Window number reported by the window server.
    public let windowNumber: Int
    /// Process id of the owning application.
    public let ownerPID: pid_t
    /// Localized name of the owning application.
    public let ownerName: String
    /// Window title, if any.
    public let title: String
    /// Window level as reported by `kCGWindowLayer` (0 = normal app window).
    public let layer: Int
    /// Window frame in global screen coordinates.
    public let bounds: CGRect
    /// Index in the front-to-back `CGWindowListCopyWindowInfo` array (0 = frontmost).
    public let listIndex: Int
}

/// All normal on-screen windows belonging to one application, ordered front-to-back.
public struct AppWindowGroup: Identifiable, Equatable, Sendable {
    public let id: pid_t
    public let pid: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let windows: [WindowLayerSnapshot]

    public var windowCount: Int { windows.count }

    /// The group's topmost window (smallest `listIndex`), if any.
    public var frontmostWindow: WindowLayerSnapshot? { windows.first }

    /// Front-to-back position of the group's topmost window.
    public var frontIndex: Int { windows.map(\.listIndex).min() ?? .max }
}

/// Coordinates window layering across applications.
///
/// When tracking is active the coordinator periodically captures the window list
/// and publishes an ordered snapshot. It also observes application activation and
/// raises every window of the newly activated app so that clicking one window
/// brings the app's other (dependent) windows forward as well.
@MainActor
public final class WindowLayerCoordinator: ObservableObject {

    public static let shared = WindowLayerCoordinator()

    // MARK: - Published state

    @Published public private(set) var isTracking = false
    @Published public private(set) var accessibilityTrusted = false
    @Published public private(set) var appGroups: [AppWindowGroup] = []
    @Published public private(set) var frontmostApp: AppWindowGroup?
    @Published public private(set) var lastRaisedAppName: String?
    @Published public private(set) var lastRaisedAt: Date?

    // MARK: - Configuration

    /// How often the window list is refreshed while tracking.
    public var refreshInterval: TimeInterval = 0.5

    /// When `true`, the coordinator ignores windows owned by its own process.
    public var skipOwnProcess = true

    /// When `true`, activation of an app automatically raises all of its windows.
    public var autoRaiseOnActivation = true

    // MARK: - Private

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastRaisedPID: pid_t = -1
    private var lastRaisedTick: UInt64 = 0

    private init() {}

    // MARK: - Lifecycle

    /// Starts tracking window layers and observing application activation.
    public func start() {
        guard !isTracking else { return }
        isTracking = true
        accessibilityTrusted = AXIsProcessTrusted()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract the pid synchronously so we don't send the non-Sendable
            // notification across the actor boundary.
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? -1
            Task { @MainActor [weak self] in
                self?.handleActivation(pid: pid)
            }
        }

        refresh()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stops tracking and releases observers/timers.
    public func stop() {
        guard isTracking else { return }
        isTracking = false
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }

    // MARK: - Refresh

    /// Re-captures the current on-screen window list.
    public func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        let groups = Self.snapshotAppGroups(skipOwnProcess: skipOwnProcess)
        appGroups = groups
        frontmostApp = groups.min { $0.frontIndex < $1.frontIndex }
    }

    // MARK: - Raising

    /// Raises all windows of the current frontmost app (the app the user is working in).
    public func bringFrontmostAppWindowsToFront() {
        guard let app = frontmostApp else { return }
        bringAllWindowsToFront(pid: app.pid)
    }

    /// Raises all windows of the app with the given process id.
    public func bringAllWindowsToFront(pid: pid_t) {
        guard pid > 0 else { return }
        if skipOwnProcess && pid == ProcessInfo.processInfo.processIdentifier { return }

        guard let runningApp = NSRunningApplication(processIdentifier: pid) else { return }
        bringAllWindowsToFront(app: runningApp)
    }

    // MARK: - Private helpers

    private func handleActivation(pid: pid_t) {
        guard autoRaiseOnActivation else {
            refresh()
            return
        }

        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else {
            refresh()
            return
        }

        bringAllWindowsToFront(app: app)
        refresh()
    }

    private func bringAllWindowsToFront(app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        if skipOwnProcess && pid == ProcessInfo.processInfo.processIdentifier { return }

        // Debounce: the activation notification can fire more than once for a
        // single click (and again after we raise the windows). Only re-raise
        // the same app once every 500 ms.
        let now = DispatchTime.now().uptimeNanoseconds
        if pid == lastRaisedPID && now - lastRaisedTick < 500_000_000 { return }
        lastRaisedPID = pid
        lastRaisedTick = now

        if AXIsProcessTrusted(), raiseWindowsViaAccessibility(pid: pid) {
            recordRaised(app: app)
            return
        }

        // Fallback: re-activate the app and ask macOS to bring every window forward.
        // No special permission is required for this path.
        app.activate(options: [.activateAllWindows])
        recordRaised(app: app)
    }

    private func recordRaised(app: NSRunningApplication) {
        lastRaisedAppName = app.localizedName ?? app.bundleIdentifier
        lastRaisedAt = Date()
    }

    /// Raises each window exposed by the Accessibility API. Returns `true` if at
    /// least one window was successfully raised.
    private func raiseWindowsViaAccessibility(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)

        var rawValue: CFTypeRef?
        let copyResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &rawValue)
        guard copyResult == .success,
              let windows = rawValue as? [AXUIElement],
              !windows.isEmpty else {
            return false
        }

        var raisedAny = false
        for window in windows {
            if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
                raisedAny = true
            }
        }
        return raisedAny
    }

    // MARK: - Snapshot

    /// Captures the current on-screen, normal (layer 0) windows and groups them by owner.
    private static func snapshotAppGroups(skipOwnProcess: Bool) -> [AppWindowGroup] {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var windowsByPID: [pid_t: [WindowLayerSnapshot]] = [:]
        var ownerNames: [pid_t: String] = [:]

        for (index, info) in rawList.enumerated() {
            guard let layer = intValue(info, kCGWindowLayer as String),
                  layer == 0 else {
                continue
            }

            guard let windowNumber = intValue(info, kCGWindowNumber as String),
                  let ownerPIDValue = intValue(info, kCGWindowOwnerPID as String) else {
                continue
            }

            let ownerPID = pid_t(ownerPIDValue)
            if skipOwnProcess && ownerPID == ownPID { continue }

            let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? "Unknown"
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let bounds = parseBounds(info[kCGWindowBounds as String])

            let snapshot = WindowLayerSnapshot(
                id: CGWindowID(windowNumber),
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title,
                layer: layer,
                bounds: bounds,
                listIndex: index
            )

            windowsByPID[ownerPID, default: []].append(snapshot)
            ownerNames[ownerPID] = ownerName
        }

        let groups = windowsByPID.map { pid, windows -> AppWindowGroup in
            AppWindowGroup(
                id: pid,
                pid: pid,
                name: ownerNames[pid] ?? "Unknown",
                bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                windows: windows.sorted { $0.listIndex < $1.listIndex }
            )
        }

        return groups.sorted { $0.frontIndex < $1.frontIndex }
    }

    private static func intValue(_ dict: [String: Any], _ key: String) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? NSNumber { return value.intValue }
        return nil
    }

    private static func parseBounds(_ value: Any?) -> CGRect {
        guard let value else { return .zero }
        if let nsDict = value as? NSDictionary {
            return CGRect(dictionaryRepresentation: nsDict as CFDictionary) ?? .zero
        }
        return .zero
    }
}
