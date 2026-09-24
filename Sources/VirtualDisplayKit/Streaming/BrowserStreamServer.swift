//
//  BrowserStreamServer.swift
//  VirtualDisplayKit
//
//  Serves the virtual display to any browser on the network: one port hosts
//  both the viewer page (HTTP) and the frame feed (WebSocket).
//

import Foundation
import Network

// MARK: - Configuration

/// Settings for the built-in browser stream server
public struct BrowserStreamConfiguration: Sendable, Equatable {

    /// TCP port for both the viewer page and the WebSocket feed
    public var port: UInt16

    /// Frames per second the server aims to deliver
    public var targetFPS: Int

    /// Floor on frames per second, for when the screen sits still
    ///
    /// A motionless screen produces no frames at all, which is efficient but
    /// looks identical to a stalled stream. Above zero, the server refreshes
    /// one horizontal band of the screen at this rate — roughly a sixth of a
    /// full frame each time — so the viewer keeps receiving and keeps
    /// converging on the truth. Zero turns it off entirely.
    public var minimumFPS: Int

    /// JPEG quality, 0.1 (smallest) to 1.0 (best)
    public var jpegQuality: Double

    /// Output scale relative to the display's native pixel size (0.25–1.0)
    public var scale: Double

    /// Hard cap on output width; larger displays are scaled down to fit.
    /// `nil` streams the display at its native width.
    public var maximumWidth: Int?

    /// Whether viewers see the mouse pointer at all
    public var showCursor: Bool

    /// Draw the pointer in the viewer instead of in the frames.
    ///
    /// The frames are captured without it, and its position and shape are
    /// sent separately — up to 120 times a second, a few bytes each — so the
    /// pointer moves smoothly however slowly the picture updates.
    public var clientSideCursor: Bool

    /// What viewers receive. A browser that can't decode H.264 gets JPEG
    /// regardless, so choosing H.264 never leaves a viewer with nothing.
    public var codec: BrowserStreamCodec

    /// Let viewers control the Mac: mouse, touch, scrolling and keyboard.
    ///
    /// Off by default. Input is confined to the streamed display, and a
    /// viewer must first enter `controlPIN`. Needs the app to be allowed to
    /// control the computer (System Settings › Privacy & Security ›
    /// Accessibility); starting the server asks for it.
    public var allowsControl: Bool

    /// The code viewers enter before they may control the Mac. `nil` picks a
    /// random six-digit code each time the server starts; read the one in use
    /// from `BrowserStreamServer.controlPIN`.
    public var controlPIN: String?

    /// H.264 bitrate in bits per second. `nil` derives it from the output
    /// size, frame rate and `jpegQuality`, and follows quality changes live.
    public var videoBitrate: Int?

    public init(
        port: UInt16 = 8080,
        targetFPS: Int = 30,
        minimumFPS: Int = 2,
        jpegQuality: Double = 0.6,
        scale: Double = 1.0,
        maximumWidth: Int? = nil,
        showCursor: Bool = true,
        clientSideCursor: Bool = true,
        codec: BrowserStreamCodec = .jpeg,
        videoBitrate: Int? = nil,
        allowsControl: Bool = false,
        controlPIN: String? = nil
    ) {
        self.port = port
        self.targetFPS = targetFPS
        self.minimumFPS = minimumFPS
        self.jpegQuality = jpegQuality
        self.scale = scale
        self.maximumWidth = maximumWidth
        self.showCursor = showCursor
        self.clientSideCursor = clientSideCursor
        self.codec = codec
        self.videoBitrate = videoBitrate
        self.allowsControl = allowsControl
        self.controlPIN = controlPIN
    }
}

/// How frames are encoded for viewers
public enum BrowserStreamCodec: String, Sendable, CaseIterable {
    /// JPEG tiles of just what changed. Sharpest text, every browser, and
    /// no frame depends on another — but more bytes whenever much moves.
    case jpeg

    /// Hardware H.264. Far fewer bytes for scrolling and moving windows,
    /// slightly softer coloured text. Decoded with WebCodecs, or Media
    /// Source Extensions where WebCodecs isn't available (plain HTTP).
    case h264
}

/// Live statistics from the browser stream server
public struct BrowserStreamStats: Sendable, Equatable {

    /// Number of connected browsers
    public var clientCount: Int = 0

    /// How many of them receive H.264 rather than JPEG tiles
    public var videoClientCount: Int = 0

    /// Frames encoded per second, measured over the last second
    public var captureFPS: Double = 0

    /// Frames actually delivered per second (per client, averaged)
    public var deliveredFPS: Double = 0

    /// Outbound throughput in bits per second
    public var bitrate: Double = 0

    /// Total frames encoded since the server started
    public var totalFrames: Int = 0

    /// Total bytes pushed to clients since the server started
    public var totalBytesSent: Int = 0

    /// Size of the frames being sent
    public var frameSize: CGSize = .zero

    public init() {}
}

// MARK: - Server

/// Streams a display to browsers over WebSocket, and serves the viewer page.
///
/// One `NWListener` handles both roles: a plain `GET /` gets the HTML viewer,
/// a `GET /ws` with an upgrade header is promoted to a WebSocket and starts
/// receiving JPEG frames.
public final class BrowserStreamServer: @unchecked Sendable {

    // MARK: - Callbacks (delivered on the main queue)

    /// Called roughly once a second with fresh statistics
    public var onStats: (@Sendable (BrowserStreamStats) -> Void)?

    /// Called when the server stops on its own, with a human-readable reason
    public var onError: (@Sendable (String) -> Void)?

    /// Diagnostic log lines
    public var onLog: (@Sendable (String) -> Void)?

    // MARK: - Private state

    /// Serializes listener, client and broadcast state
    private let networkQueue = DispatchQueue(label: "com.virtualdisplaykit.browserstream.network")

    /// Capture + JPEG encoding; kept off the network queue so a slow encode
    /// never delays socket reads
    private let captureQueue = DispatchQueue(
        label: "com.virtualdisplaykit.browserstream.capture",
        qos: .userInteractive
    )

    private var listener: NWListener?
    private var source: ScreenFrameSource?
    private var cursor: CursorSource?

    /// Latest pointer messages, replayed to each viewer as it joins
    private var cursorShapeMessage: String?
    private var cursorPositionMessage = "m"

    /// Zero point for pointer timestamps, which only need to be consistent
    /// within one run
    private let cursorEpoch = CFAbsoluteTimeGetCurrent()
    private var clients: [UUID: Client] = [:]
    private var statsTimer: DispatchSourceTimer?


    private var configuration: BrowserStreamConfiguration
    private var outputSize: CGSize = .zero

    // Counters, reset every stats tick
    private var framesThisTick = 0
    private var deliveriesThisTick = 0
    private var bytesThisTick = 0
    private var totalFrames = 0
    private var totalBytesSent = 0

    /// Bounds on how many frames may be in flight to one viewer.
    ///
    /// Throughput is `framesInFlight / roundTrip`, so a window of one caps a
    /// viewer at `1 / roundTrip` frames per second — fine on loopback, and a
    /// hard 10 fps ceiling over a 100 ms Wi-Fi hop. The window therefore grows
    /// with the round trip actually measured, and stays clamped so latency
    /// never runs away.
    private static let minimumFramesInFlight = 2
    private static let maximumFramesInFlight = 6

    /// Bytes in the tile table per tile: x, y, width, height as UInt16 and the
    /// JPEG's length as UInt32, all big-endian
    static let tileEntrySize = 12

    /// Weight given to each new round-trip sample; low enough that one slow
    /// frame cannot swing the window, high enough to track a changing network.
    private static let roundTripSmoothing: Double = 0.25


    /// If a client stops acknowledging for this long, assume it can't ack and
    /// fall back to socket-level flow control alone
    private static let acknowledgementTimeout: TimeInterval = 2.0

    public private(set) var isRunning = false

    /// The code viewers must enter to take control, while control is allowed
    public private(set) var controlPIN: String?

    private var remoteInput: RemoteInput?

    /// Test hooks: where posted input goes and what counts as focused, so
    /// tests never drive the real pointer. Set before `start`.
    var inputPostOverride: ((CGEvent) -> Void)?
    var focusCheckOverride: (() -> Bool)?

    /// Wrong codes allowed per connection before it is dropped
    private static let maximumPINAttempts = 5

    // MARK: - Init

    public init(configuration: BrowserStreamConfiguration = BrowserStreamConfiguration()) {
        self.configuration = configuration
    }

    deinit {
        listener?.cancel()
        source?.stop()
        statsTimer?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the HTTP/WebSocket listener and begins capturing the display.
    /// - Parameters:
    ///   - displayID: The display to capture
    ///   - pixelSize: Native pixel size of that display
    public func start(displayID: CGDirectDisplayID, pixelSize: CGSize) throws {
        guard !isRunning else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw BrowserStreamError.invalidPort(configuration.port)
        }

        outputSize = Self.outputSize(for: pixelSize, configuration: configuration)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            // Frames are latency-sensitive and already large enough to fill
            // packets, so Nagle only adds delay.
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw BrowserStreamError.listenerFailed(error.localizedDescription)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("Listening on port \(self.configuration.port)")
            case .failed(let error):
                self.report(error: "Server failed: \(error.localizedDescription)")
                self.stop()
            case .cancelled:
                break
            default:
                break
            }
        }

        if configuration.allowsControl {
            let pin = configuration.controlPIN.flatMap { $0.isEmpty ? nil : $0 } ?? Self.randomPIN()
            controlPIN = pin
            if !RemoteInput.isPermitted && inputPostOverride == nil {
                DispatchQueue.main.async { RemoteInput.requestPermission() }
            }
        } else {
            controlPIN = nil
        }

        self.listener = listener
        isRunning = true
        listener.start(queue: networkQueue)

        // Everything below is owned by the network queue, including teardown,
        // so set it up there rather than from the caller's thread.
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.startCapture(displayID: displayID)
            self.startCursor(displayID: displayID)
            self.startRemoteInput(displayID: displayID)
            self.startStatsTimer()
        }
    }

    /// Stops capture, disconnects every client and releases the port.
    public func stop() {
        isRunning = false

        networkQueue.async { [weak self] in
            guard let self else { return }

            self.source?.stop()
            self.source = nil

            self.cursor?.stop()
            self.cursor = nil

            self.remoteInput?.releaseAll()
            self.remoteInput = nil
            self.cursorShapeMessage = nil
            self.cursorPositionMessage = "m"

            self.statsTimer?.cancel()
            self.statsTimer = nil

            for client in self.clients.values {
                client.connection.cancel()
            }
            self.clients.removeAll()

            self.listener?.cancel()
            self.listener = nil

            self.framesThisTick = 0
            self.deliveriesThisTick = 0
            self.bytesThisTick = 0

            self.publish(stats: BrowserStreamStats())
        }
    }

    /// Applies a new JPEG quality without restarting the stream.
    public func updateQuality(_ quality: Double) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            self.configuration.jpegQuality = quality
            self.source?.updateQuality(quality)
        }
    }

    // MARK: - Capture

    private func startCapture(displayID: CGDirectDisplayID) {
        let sourceConfiguration = ScreenFrameSourceConfiguration(
            displayID: displayID,
            outputSize: outputSize,
            targetFPS: configuration.targetFPS,
            minimumFPS: configuration.minimumFPS,
            jpegQuality: configuration.jpegQuality,
            showCursor: configuration.showCursor && !configuration.clientSideCursor,
            videoBitrate: configuration.videoBitrate
        )

        let source = ScreenFrameSource(queue: captureQueue, configuration: sourceConfiguration)

        source.onFrame = { [weak self] frame in
            guard let self else { return }
            self.networkQueue.async {
                self.broadcast(frame)
            }
        }

        source.onVideoFrame = { [weak self] frame in
            guard let self else { return }
            self.networkQueue.async {
                self.broadcast(video: frame)
            }
        }

        source.onError = { [weak self] message in
            self?.report(error: message)
        }

        self.source = source
        source.start()
    }

    // MARK: - Remote control

    static func randomPIN() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    private func startRemoteInput(displayID: CGDirectDisplayID) {
        guard configuration.allowsControl else { return }
        let input = RemoteInput(displayID: displayID, outputSize: outputSize)
        if let inputPostOverride { input.post = inputPostOverride }
        if let focusCheckOverride { input.focusIsOnDisplay = focusCheckOverride }
        remoteInput = input
    }

    /// `A<pin>`: a viewer asking to take control.
    private func authorize(_ pin: String, from client: Client) {
        guard remoteInput != nil, let controlPIN else {
            send(text: #"{"type":"control","granted":false,"reason":"disabled"}"#, to: client)
            return
        }

        guard pin == controlPIN else {
            client.failedPINAttempts += 1
            log("Wrong control PIN from a viewer (\(client.failedPINAttempts)/\(Self.maximumPINAttempts))")
            send(text: #"{"type":"control","granted":false,"reason":"pin"}"#, to: client)
            // Six digits don't survive guessing at network speed.
            if client.failedPINAttempts >= Self.maximumPINAttempts {
                disconnect(client.id)
            }
            return
        }

        guard RemoteInput.isPermitted || inputPostOverride != nil else {
            send(text: #"{"type":"control","granted":false,"reason":"permission"}"#, to: client)
            DispatchQueue.main.async { RemoteInput.requestPermission() }
            return
        }

        client.controlGranted = true
        log("A viewer took control")
        send(text: #"{"type":"control","granted":true}"#, to: client)
    }

    /// `i{json}`: one input event from a viewer that holds control.
    private func handleInput(_ json: Substring, from client: Client) {
        guard client.controlGranted, let remoteInput,
              let event = try? JSONDecoder().decode(RemoteInputEvent.self, from: Data(json.utf8)) else { return }

        if remoteInput.handle(event) == .focusElsewhere {
            // Say why typing does nothing, but not for every keystroke.
            let now = Date().timeIntervalSinceReferenceDate
            if now - client.lastFocusNotice > 2 {
                client.lastFocusNotice = now
                send(text: #"{"type":"control","notice":"focus"}"#, to: client)
            }
        }
    }

    // MARK: - Cursor

    private func startCursor(displayID: CGDirectDisplayID) {
        guard configuration.showCursor, configuration.clientSideCursor else { return }

        // Polled on the network queue: positions go straight out, no hop.
        let cursor = CursorSource(displayID: displayID, outputSize: outputSize, queue: networkQueue)

        cursor.onPosition = { [weak self] position, time in
            guard let self else { return }
            self.cursorPositionMessage = Self.cursorPositionMessage(for: position, at: (time - self.cursorEpoch) * 1000)
            for client in self.clients.values where client.isWebSocket {
                self.send(cursorPosition: self.cursorPositionMessage, to: client)
            }
        }

        cursor.onShape = { [weak self] shape in
            guard let self else { return }
            let message = Self.cursorShapeMessage(for: shape)
            self.cursorShapeMessage = message
            for client in self.clients.values where client.isWebSocket {
                self.send(text: message, to: client)
            }
        }

        self.cursor = cursor
        cursor.start()
    }

    /// `m<x>,<y>,<t>` — output pixels, and the time the position was read in
    /// milliseconds — or a bare `m` when the pointer is on another display.
    static func cursorPositionMessage(for position: CGPoint?, at milliseconds: Double) -> String {
        guard let position else { return "m" }
        return String(format: "m%.1f,%.1f,%.1f", position.x, position.y, milliseconds)
    }

    static func cursorShapeMessage(for shape: CursorShape) -> String {
        """
        {"type":"cursor","image":"data:image/png;base64,\(shape.png.base64EncodedString())","width":\(shape.size.width),"height":\(shape.size.height),"hotX":\(shape.hotSpot.x),"hotY":\(shape.hotSpot.y)}
        """
    }

    /// Sends a pointer position, coalescing: while one is still on its way,
    /// newer positions replace each other instead of queueing, so a slow link
    /// shows where the pointer is rather than replaying where it was.
    private func send(cursorPosition message: String, to client: Client) {
        guard !client.isSendingCursor else {
            client.pendingCursorPosition = message
            return
        }
        client.isSendingCursor = true

        let id = client.id
        client.connection.send(
            content: WebSocketEncoder.textFrame(message),
            completion: .contentProcessed { [weak self] _ in
                guard let self, let client = self.clients[id] else { return }
                client.isSendingCursor = false
                if let next = client.pendingCursorPosition {
                    client.pendingCursorPosition = nil
                    self.send(cursorPosition: next, to: client)
                }
            }
        )
    }

    /// Computes the capture output size: aspect preserved, scaled and capped,
    /// and rounded to even dimensions for encoder friendliness.
    ///
    /// Public so a caller can show what a configuration will actually stream
    /// before starting the server.
    public static func outputSize(for pixelSize: CGSize, configuration: BrowserStreamConfiguration) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 1280, height: 720)
        }

        let scale = min(max(configuration.scale, 0.1), 1.0)
        var width = pixelSize.width * scale
        var height = pixelSize.height * scale

        if let maximumWidth = configuration.maximumWidth {
            let cap = CGFloat(max(320, maximumWidth))
            if width > cap {
                height *= cap / width
                width = cap
            }
        }

        func even(_ value: CGFloat) -> CGFloat {
            max(2, (value / 2).rounded() * 2)
        }

        return CGSize(width: even(width), height: even(height))
    }

    // MARK: - Broadcasting

    private func broadcast(_ frame: EncodedFrame) {
        framesThisTick += 1
        totalFrames += 1

        guard !clients.isEmpty else { return }

        let prefix = Self.wirePrefix(for: frame)
        let now = Date().timeIntervalSinceReferenceDate
        var recovery = CGRect.null

        for client in clients.values where client.isWebSocket && client.codec == .jpeg {
            guard canSend(to: client, now: now) else {
                client.droppedFrames += 1
                // Whatever it just missed leaves a stale patch on its canvas.
                // Fold that region into the next tile rather than resending the
                // whole screen — a full frame here would cost 20x the bytes and
                // make the congestion that caused the drop worse.
                recovery = recovery.union(frame.bounds)
                continue
            }

            // A tile is meaningless to a viewer with nothing correct to paint
            // it onto — a brand new one waits for its full frame instead.
            if client.needsFullFrame && !frame.isFullFrame { continue }

            client.needsFullFrame = false
            send(header: prefix, payloads: frame.tiles.map(\.data), to: client)
        }

        if !recovery.isNull {
            source?.recover(region: recovery)
        }
    }

    /// Sends an H.264 frame to every video viewer.
    ///
    /// Unlike a tile, a video frame depends on the one before it, so a viewer
    /// that misses one can decode nothing until the next keyframe. It is
    /// skipped until then, and a keyframe is requested on its behalf.
    private func broadcast(video frame: EncodedVideoFrame) {
        framesThisTick += 1
        totalFrames += 1

        let prefix = Self.wirePrefix(for: frame)
        let now = Date().timeIntervalSinceReferenceDate
        var needsKeyframe = false

        for client in clients.values where client.isWebSocket && client.codec == .h264 {
            if client.needsKeyframe && !frame.isKeyframe {
                needsKeyframe = true
                continue
            }

            guard canSend(to: client, now: now) else {
                client.droppedFrames += 1
                client.needsKeyframe = true
                needsKeyframe = true
                continue
            }

            client.needsKeyframe = false
            send(header: prefix, payloads: [frame.data], to: client)
        }

        if needsKeyframe {
            source?.requestRecoveryKeyframe()
        }
    }

    /// Bit set in a video frame's flags when it decodes on its own
    static let keyframeFlag: UInt8 = 0x01

    /// Bit set when the avcC decoder configuration follows the timestamp
    static let configurationFlag: UInt8 = 0x02

    /// WebSocket header plus the video frame header: flags, a 32-bit
    /// millisecond timestamp and, on keyframes, the avcC record behind a
    /// 16-bit length. The H.264 data follows.
    static func wirePrefix(for frame: EncodedVideoFrame) -> Data {
        let configuration = frame.configuration.flatMap { $0.count <= Int(UInt16.max) ? $0 : nil }
        var header = Data()

        var flags: UInt8 = 0
        if frame.isKeyframe { flags |= keyframeFlag }
        if configuration != nil { flags |= configurationFlag }
        header.append(flags)
        header.append(contentsOf: [24, 16, 8, 0].map { UInt8((frame.timestamp >> $0) & 0xFF) })

        if let configuration {
            header.append(UInt8(configuration.count >> 8))
            header.append(UInt8(configuration.count & 0xFF))
            header.append(configuration)
        }

        var prefix = WebSocketEncoder.header(opcode: .binary, payloadLength: header.count + frame.data.count)
        prefix.append(header)
        return prefix
    }

    /// WebSocket header plus the tile table: a tile count, then one entry per
    /// tile saying where it belongs and how many JPEG bytes it takes. The JPEGs
    /// follow back to back, in table order.
    static func wirePrefix(for frame: EncodedFrame) -> Data {
        let tiles = frame.tiles.prefix(Int(UInt8.max))
        let tableSize = 1 + tiles.count * tileEntrySize

        var prefix = WebSocketEncoder.header(
            opcode: .binary,
            payloadLength: tableSize + tiles.reduce(0) { $0 + $1.data.count }
        )
        prefix.append(UInt8(tiles.count))

        for tile in tiles {
            for value in [tile.rect.origin.x, tile.rect.origin.y, tile.rect.width, tile.rect.height] {
                let clamped = UInt16(min(max(value, 0), CGFloat(UInt16.max)))
                prefix.append(UInt8(clamped >> 8))
                prefix.append(UInt8(clamped & 0xFF))
            }
            let length = UInt32(tile.data.count)
            prefix.append(contentsOf: [24, 16, 8, 0].map { UInt8((length >> $0) & 0xFF) })
        }

        return prefix
    }

    /// How many frames may be outstanding for a viewer whose round trip is
    /// `roundTrip` seconds.
    ///
    /// Enough to keep the link busy across one round trip, plus the frame
    /// currently being rendered.
    func framesInFlightWindow(forRoundTrip roundTrip: TimeInterval) -> Int {
        guard roundTrip > 0 else { return Self.minimumFramesInFlight }
        let frameInterval = 1.0 / Double(max(1, configuration.targetFPS))
        let needed = Int((roundTrip / frameInterval).rounded(.up)) + 1
        return min(max(needed, Self.minimumFramesInFlight), Self.maximumFramesInFlight)
    }

    /// Drop policy: never let a frame queue up behind one a viewer hasn't
    /// finished with — showing the newest frame beats replaying a backlog.
    private func canSend(to client: Client, now: TimeInterval) -> Bool {
        if client.isSocketBusy { return false }
        guard client.framesInFlight >= framesInFlightWindow(forRoundTrip: client.roundTrip) else { return true }

        // The client may simply not speak our ack protocol; after a grace
        // period fall back to socket-level backpressure alone.
        if now - client.lastAcknowledgement > Self.acknowledgementTimeout {
            client.framesInFlight = 0
            client.unacknowledgedSendTimes.removeAll()
            return true
        }
        return false
    }

    private func send(header: Data, payloads: [Data], to client: Client) {
        client.isSocketBusy = true
        client.framesInFlight += 1
        client.unacknowledgedSendTimes.append(Date().timeIntervalSinceReferenceDate)
        if client.unacknowledgedSendTimes.count > Self.maximumFramesInFlight {
            client.unacknowledgedSendTimes.removeFirst()
        }

        let size = header.count + payloads.reduce(0) { $0 + $1.count }
        deliveriesThisTick += 1
        bytesThisTick += size
        totalBytesSent += size

        let connection = client.connection
        let clientID = client.id

        // Sends inside a batch reach the socket as one write, so the tiles are
        // never copied into one buffer just to sit behind a header.
        connection.batch {
            connection.send(content: header, completion: .contentProcessed { _ in })
            for payload in payloads.dropLast() {
                connection.send(content: payload, completion: .contentProcessed { _ in })
            }
            connection.send(content: payloads.last ?? Data(), completion: .contentProcessed { [weak self] error in
                // Connection callbacks already run on the network queue.
                guard let self, let client = self.clients[clientID] else { return }
                client.isSocketBusy = false
                if error != nil {
                    self.disconnect(clientID)
                }
            })
        }
    }

    private func send(text: String, to client: Client) {
        client.connection.send(
            content: WebSocketEncoder.textFrame(text),
            completion: .contentProcessed { _ in }
        )
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        clients[client.id] = client

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.disconnect(client.id)
            default:
                break
            }
        }

        connection.start(queue: networkQueue)
        receive(on: client)
    }

    private func disconnect(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        if client.controlGranted {
            // Don't leave a button held down by a viewer that's gone.
            remoteInput?.releaseAll()
        }
        if client.isWebSocket {
            updateViewerState()
            log("Viewer disconnected (\(viewerCount) remaining)")
        }
    }

    private var viewerCount: Int {
        clients.values.filter(\.isWebSocket).count
    }

    private var videoViewerCount: Int {
        clients.values.filter { $0.isWebSocket && $0.codec == .h264 }.count
    }

    /// Capture keeps running, but nothing is encoded while nobody is watching,
    /// and each format only while someone is watching in it.
    private func updateViewerState() {
        let video = videoViewerCount
        source?.setViewers(jpeg: viewerCount > video, video: video > 0)
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.handle(incoming: data, from: client)
            }

            if isComplete || error != nil {
                self.disconnect(client.id)
                return
            }

            self.receive(on: client)
        }
    }

    private func handle(incoming data: Data, from client: Client) {
        guard clients[client.id] != nil else { return }

        if client.isWebSocket {
            handleWebSocket(data: data, from: client)
        } else {
            handleHTTP(data: data, from: client)
        }
    }

    // MARK: - HTTP

    private func handleHTTP(data: Data, from client: Client) {
        client.requestBuffer.append(data)

        // Guard against a client that never sends a complete request head.
        guard client.requestBuffer.count < 64 * 1024 else {
            disconnect(client.id)
            return
        }

        guard let request = HTTPRequest(client.requestBuffer) else { return }

        // Anything past the request head belongs to whatever comes next — for
        // an upgrade that's the first WebSocket frames.
        let remainder = Data(client.requestBuffer.dropFirst(request.headLength))
        client.requestBuffer.removeAll(keepingCapacity: false)

        if request.isWebSocketUpgrade, let key = request.headers["sec-websocket-key"] {
            // The server picks the codec; the page only says whether it can
            // decode H.264 at all.
            let canDecodeVideo = request.query["h264"] == "1"
            let codec: BrowserStreamCodec = configuration.codec == .h264 && canDecodeVideo ? .h264 : .jpeg
            if configuration.codec == .h264 && !canDecodeVideo {
                log("Viewer's browser can't decode H.264; sending JPEG")
            }
            upgrade(client, key: key, codec: codec)
            if !remainder.isEmpty {
                handleWebSocket(data: remainder, from: client)
            }
            return
        }

        switch request.path {
        case "/", "/index.html":
            respond(to: client, body: Data(BrowserStreamPage.servedHTML.utf8), contentType: "text/html; charset=utf-8")

        case "/manifest.webmanifest":
            // Added to the home screen, the viewer opens without browser
            // chrome — the only way to get the whole screen on iOS.
            respond(to: client, body: Data(BrowserStreamPage.manifest.utf8), contentType: "application/manifest+json")

        case "/icon.png":
            respond(to: client, body: BrowserStreamPage.icon(), contentType: "image/png")
        case "/health":
            let body = """
            {"status":"ok","fps":\(configuration.targetFPS),"minFps":\(configuration.minimumFPS),"width":\(Int(outputSize.width)),"height":\(Int(outputSize.height)),"clients":\(viewerCount)}
            """
            respond(to: client, body: Data(body.utf8), contentType: "application/json")
        default:
            respond(to: client, status: "404 Not Found", body: Data("Not found".utf8), contentType: "text/plain; charset=utf-8")
        }
    }

    private func respond(to client: Client, status: String = "200 OK", body: Data, contentType: String) {
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """

        var response = Data(head.utf8)
        response.append(body)

        let id = client.id
        client.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.disconnect(id)
        })
    }

    private func upgrade(_ client: Client, key: String, codec: BrowserStreamCodec) {
        client.connection.send(
            content: WebSocketHandshake.upgradeResponse(clientKey: key),
            completion: .contentProcessed { _ in }
        )
        client.isWebSocket = true
        client.codec = codec
        client.lastAcknowledgement = Date().timeIntervalSinceReferenceDate

        log("Viewer connected over \(codec.rawValue) (\(viewerCount) total)")

        let metadata = """
        {"type":"meta","page":"\(BrowserStreamPage.version)","codec":"\(codec.rawValue)","control":\(remoteInput != nil),"width":\(Int(outputSize.width)),"height":\(Int(outputSize.height)),"fps":\(configuration.targetFPS),"quality":\(configuration.jpegQuality)}
        """
        send(text: metadata, to: client)

        if let cursorShapeMessage {
            send(text: cursorShapeMessage, to: client)
            send(cursorPosition: cursorPositionMessage, to: client)
        }

        // A new viewer has nothing to build on — no canvas for tiles, no
        // reference frame for video. A still screen produces no new frames
        // either, so ask for one built from the last captured pixels.
        updateViewerState()
        switch codec {
        case .jpeg:
            client.needsFullFrame = true
            source?.requestFullFrame()
        case .h264:
            client.needsKeyframe = true
            source?.requestKeyframe()
        }
    }

    // MARK: - WebSocket

    private func handleWebSocket(data: Data, from client: Client) {
        client.decoder.append(data)

        while true {
            let frame: WebSocketFrame?
            do {
                frame = try client.decoder.next()
            } catch {
                disconnect(client.id)
                return
            }

            guard let frame else { return }

            switch frame.opcode {
            case .close:
                disconnect(client.id)
                return

            case .ping:
                client.connection.send(
                    content: WebSocketEncoder.frame(opcode: .pong, payload: frame.payload),
                    completion: .contentProcessed { _ in }
                )

            case .text:
                handleControl(String(decoding: frame.payload, as: UTF8.self), from: client)

            case .binary, .pong, .continuation:
                break
            }
        }
    }

    private func handleControl(_ message: String, from client: Client) {
        guard let marker = message.first else { return }

        switch marker {
        case "a":
            // Frame rendered: the viewer is ready for the next one.
            let now = Date().timeIntervalSinceReferenceDate
            client.framesInFlight = max(0, client.framesInFlight - 1)
            client.lastAcknowledgement = now

            // Send-to-ack covers the network both ways plus the time the viewer
            // spent decoding — exactly what the in-flight window has to cover.
            if let sentAt = client.unacknowledgedSendTimes.first {
                client.unacknowledgedSendTimes.removeFirst()
                let sample = now - sentAt
                client.roundTrip = client.roundTrip == 0
                    ? sample
                    : client.roundTrip * (1 - Self.roundTripSmoothing) + sample * Self.roundTripSmoothing
            }

        case "k":
            // The viewer's decoder failed or was reset; it needs a keyframe.
            client.needsKeyframe = true
            source?.requestRecoveryKeyframe()

        case "i":
            handleInput(message.dropFirst(), from: client)

        case "A":
            authorize(String(message.dropFirst()), from: client)

        case "p":
            // Round-trip probe: echo it back untouched so the page can time it.
            send(text: message, to: client)

        default:
            break
        }
    }

    // MARK: - Stats

    private func startStatsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: networkQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.emitStats()
        }
        statsTimer = timer
        timer.resume()
    }

    private func emitStats() {
        let viewers = viewerCount

        var stats = BrowserStreamStats()
        stats.clientCount = viewers
        stats.videoClientCount = videoViewerCount
        stats.captureFPS = Double(framesThisTick)
        stats.deliveredFPS = viewers > 0 ? Double(deliveriesThisTick) / Double(viewers) : 0
        stats.bitrate = Double(bytesThisTick) * 8
        stats.totalFrames = totalFrames
        stats.totalBytesSent = totalBytesSent
        stats.frameSize = outputSize

        framesThisTick = 0
        deliveriesThisTick = 0
        bytesThisTick = 0

        publish(stats: stats)
    }

    private func publish(stats: BrowserStreamStats) {
        guard let onStats else { return }
        DispatchQueue.main.async { onStats(stats) }
    }

    private func report(error message: String) {
        guard let onError else { return }
        DispatchQueue.main.async { onError(message) }
    }

    private func log(_ message: String) {
        guard let onLog else { return }
        DispatchQueue.main.async { onLog(message) }
    }
}

// MARK: - Errors

public enum BrowserStreamError: LocalizedError {
    case invalidPort(UInt16)
    case listenerFailed(String)
    case displayNotReady

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "Port \(port) is not valid. Use a number between 1 and 65535."
        case .listenerFailed(let reason):
            return "Could not open the port: \(reason). It may already be in use."
        case .displayNotReady:
            return "The virtual display is not ready yet."
        }
    }
}

// MARK: - Client


/// Per-connection state. Only ever touched on the server's network queue,
/// which is what makes the unchecked conformance safe.
private final class Client: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection

    var isWebSocket = false
    var requestBuffer = Data()
    var decoder = WebSocketFrameDecoder()

    /// Frames sent but not yet acknowledged as rendered
    var framesInFlight = 0

    /// True while a frame is still being handed to the socket
    var isSocketBusy = false

    var codec: BrowserStreamCodec = .jpeg

    /// Set when this viewer missed a tile and its canvas is out of date
    var needsFullFrame = true

    /// Set when this video viewer can't decode anything until a keyframe
    var needsKeyframe = true

    /// A pointer position is on its way; newer ones wait here, overwriting
    /// each other
    var isSendingCursor = false
    var pendingCursorPosition: String?

    /// Entered the right PIN; its input is posted
    var controlGranted = false
    var failedPINAttempts = 0
    var lastFocusNotice: TimeInterval = 0

    var lastAcknowledgement: TimeInterval = 0
    var droppedFrames = 0

    /// Smoothed send-to-ack time, in seconds. Zero until the first ack.
    var roundTrip: TimeInterval = 0

    /// Send times of frames still waiting for an ack, oldest first
    var unacknowledgedSendTimes: [TimeInterval] = []

    init(connection: NWConnection) {
        self.connection = connection
    }
}

// MARK: - HTTP Request

/// Just enough HTTP to route the viewer page and spot an upgrade request.
private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]

    /// Byte count of the request head, including the blank line that ends it
    let headLength: Int

    var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased() == "websocket"
    }

    /// Returns `nil` while the request head is still incomplete.
    init?(_ data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        headLength = data.distance(from: data.startIndex, to: separator.upperBound)
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        method = String(requestLine[0])
        let target = URLComponents(string: String(requestLine[1]))
        path = target?.path.isEmpty == false ? target!.path : String(requestLine[1].split(separator: "?").first ?? "/")
        query = Dictionary(
            (target?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        var parsed: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed[name] = value
        }
        headers = parsed
    }
}
