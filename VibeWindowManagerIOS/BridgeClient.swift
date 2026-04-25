//
//  BridgeClient.swift
//  VibeWindowManagerIOS
//
//  WebSocket client to the Mac bridge (Tailnet hostname or host:port).
//

import Combine
import Foundation

@MainActor
final class BridgeClient: ObservableObject {
    @Published var layout: BridgeLayoutMessage?
    /// Running apps the Mac can mirror (from `mirrorAppList`); use to switch target from the iPad.
    @Published var mirrorAppList: [BridgeMirrorAppEntry] = []
    @Published var mirrorAppListSeq: UInt64 = 0
    /// Per-window live JPEG (Mac `screencapture` + downscale) when the client has enabled the stream.
    @Published var windowStreamJpegById: [String: Data] = [:]
    @Published var windowStreamErrorById: [String: String] = [:]
    @Published private(set) var windowStreamToMacIsOn: Bool = false
    @Published var status: String = "Not connected"
    /// Last button-driven action, for quick confirmation something ran.
    @Published private(set) var lastActionNote: String = ""
    @Published var lastError: String?
    @Published var transcribeLast: String = ""
    @Published var transcribeError: String?
    /// Set when `transcribe` is sent with `end: true` until a `transcribeResult` arrives.
    @Published var transcribeInFlight: Bool = false
    @Published var tmuxPaneText: String = ""
    @Published var tmuxPaneError: String?
    @Published var tmuxPaneSeq: UInt64 = 0
    @Published var tmuxPaneTruncated: Bool = false
    /// When true, refresh tmux text every 2s while connected.
    @Published var isTmuxAutoRefreshEnabled: Bool = false {
        didSet { UserDefaults.standard.set(isTmuxAutoRefreshEnabled, forKey: Self.tmuxAutoRefreshKey) }
    }
    @Published private(set) var isTmuxAutoLoopRunning: Bool = false
    @Published var currentTarget: String?
    /// True after the first successful `layout` message; cleared on disconnect or connection loss.
    @Published private(set) var hasActiveLayoutSession = false
    /// Persisted Tailnet hostname (e.g. `my-mac.tailxxxx.ts.net` or short `my-mac`) for the Connect via Tailnet field.
    @Published var preferredTailnetHost: String {
        didSet { UserDefaults.standard.set(preferredTailnetHost, forKey: Self.tailnetHostKey) }
    }
    /// True while a Tailnet WebSocket attempt is in progress (for UI).
    @Published private(set) var isAttemptingTailnet: Bool = false

    private static let tailnetHostKey = "bridgeTailnetHost"
    private static let tailnetFallbackSeconds: UInt64 = 6
    private static let tmuxAutoRefreshKey = "vibeTmuxAutoRefresh"
    private static let tmuxLineRequest: Int = 400

    private var task: URLSessionWebSocketTask?
    private var tmuxAutoRefreshTask: Task<Void, Never>?
    private var session: URLSession?
    /// Retained so the session’s delegate is stable; do not call `receive` until `urlSession(_:webSocketTask:didOpenWithProtocol:)` (see `BridgeWebSocketURLSessionDelegate.swift`).
    private var socketDelegate: BridgeWebSocketURLSessionDelegate?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var tailnetFallbackTask: Task<Void, Never>?
    /// Parameters for the active connect attempt (used for one silent retry on transient -1005 / handshake loss).
    private var lastConnectParams: StoredWebSocketParams?
    /// One auto-retry per user connect; reset on each `connect` / `connectTailnet` and after a successful `layout`.
    private var connectAutoRetriesLeft = 0
    private var retryConnectionTask: Task<Void, Never>?

    init() {
        self.preferredTailnetHost = UserDefaults.standard.string(forKey: Self.tailnetHostKey) ?? ""
        self.isTmuxAutoRefreshEnabled = UserDefaults.standard.object(forKey: Self.tmuxAutoRefreshKey) as? Bool ?? false
    }

    /// `192.168.x.x:19842` or full `ws://host:port/bridge`
    func connect(hostOrURL: String) {
        connectAutoRetriesLeft = 1
        cancelPendingAutoRetry()
        cancelTailnetFallback()
        isAttemptingTailnet = false
        disconnect(manual: false)
        lastError = nil
        let t = hostOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            status = "Enter your Mac’s IP, e.g. 192.168.1.5:19842"
            lastError = status
            noteAction("Connect: need host:port in the field")
            return
        }
        noteAction("Connect: trying \(t)")
        let ws: String
        if t.lowercased().hasPrefix("ws://") {
            ws = t
        } else {
            let base = t.hasPrefix("//") ? String(t.dropFirst(2)) : t
            ws = "ws://\(base)/bridge"
        }
        guard let u = URL(string: ws) else {
            status = "Invalid address"
            lastError = status
            return
        }
        status = "Connecting to \(u.host ?? t)…"
        startWebSocketConnection(url: u, displayHost: u.host, displayFallback: t, useTailnetTimeouts: false)
    }

    func disconnect(manual: Bool = true) {
        if manual {
            noteAction("Disconnect")
            cancelTailnetFallback()
            isAttemptingTailnet = false
        }
        cancelPendingAutoRetry()
        connectAutoRetriesLeft = 0
        lastConnectParams = nil
        stopTmuxAutoRefreshLoop()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        socketDelegate = nil
        session?.invalidateAndCancel()
        session = nil
        layout = nil
        mirrorAppList = []
        mirrorAppListSeq = 0
        windowStreamJpegById = [:]
        windowStreamErrorById = [:]
        windowStreamToMacIsOn = false
        hasActiveLayoutSession = false
        currentTarget = nil
        tmuxPaneText = ""
        tmuxPaneError = nil
        tmuxPaneTruncated = false
        transcribeInFlight = false
        transcribeLast = ""
        transcribeError = nil
        status = manual ? "Disconnected" : "Not connected"
    }

    /// Manual connect using a Tailnet hostname (MagicDNS or short form). On timeout, connection is reset with a message.
    func connectTailnet(host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        connectAutoRetriesLeft = 1
        cancelPendingAutoRetry()
        cancelTailnetFallback()
        disconnect(manual: false)
        lastError = nil
        let portPart = h.contains(":") ? h : "\(h):19842"
        let ws = "ws://\(portPart)/bridge"
        guard let u = URL(string: ws) else {
            status = "Invalid Tailnet hostname"
            lastError = status
            return
        }
        isAttemptingTailnet = true
        noteAction("Tailnet: trying \(h)")
        currentTarget = "\(h) (tailnet)"
        status = "Connecting via Tailnet (\(h))…"
        startWebSocketConnection(
            url: u,
            displayHost: u.host,
            displayFallback: h,
            useTailnetTimeouts: true,
            tailnetTargetLabel: "\(h) (tailnet)"
        )
        scheduleTailnetFallback()
    }

    private static func makeWebSocketConfiguration(requestTimeout: TimeInterval) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = 604_800
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpAdditionalHeaders = nil
        // Do not set httpAdditionalHeaders — can break the WebSocket upgrade on iOS.
        return c
    }

    /// Configures a session with delegate, then `resume()`; `receive` starts only in `webSocketDidOpen`.
    private func startWebSocketConnection(
        url: URL,
        displayHost: String?,
        displayFallback: String,
        useTailnetTimeouts: Bool,
        tailnetTargetLabel: String? = nil
    ) {
        lastConnectParams = StoredWebSocketParams(
            url: url,
            displayHost: displayHost,
            displayFallback: displayFallback,
            useTailnetTimeouts: useTailnetTimeouts,
            tailnetTargetLabel: tailnetTargetLabel
        )
        let requestTimeout: TimeInterval = useTailnetTimeouts ? 60 : 45
        let del = BridgeWebSocketURLSessionDelegate(events: self)
        socketDelegate = del
        let cfg = Self.makeWebSocketConfiguration(requestTimeout: requestTimeout)
        let s = URLSession(configuration: cfg, delegate: del, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: url)
        del.attach(task: t)
        self.task = t
        if let label = tailnetTargetLabel {
            currentTarget = label
        } else if !useTailnetTimeouts {
            if let host = displayHost {
                currentTarget = url.port.map { "\(host):\($0)" } ?? host
            } else {
                currentTarget = displayFallback
            }
        }
        // Defer `resume()` one turn so URLSession, delegate, and task are stable before the
        // WebSocket upgrade — avoids first-tap races where the first attempt fails and the second works.
        let taskToStart = t
        DispatchQueue.main.async { [weak self] in
            guard let self, self.task === taskToStart else { return }
            taskToStart.resume()
        }
    }

    private func cancelPendingAutoRetry() {
        retryConnectionTask?.cancel()
        retryConnectionTask = nil
    }

    private static func nsErrorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var n: NSError? = error as NSError
        for _ in 0 ..< 8 {
            guard let e = n else { break }
            chain.append(e)
            n = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    private static func isTransientURLErrorCode(_ code: Int) -> Bool {
        switch code {
        case NSURLErrorNetworkConnectionLost, // -1005
             NSURLErrorTimedOut, // -1001
             NSURLErrorCannotConnectToHost, // -1004
             NSURLErrorCannotFindHost, // -1003
             NSURLErrorDNSLookupFailed, // -1006
             NSURLErrorResourceUnavailable, // -1008
             NSURLErrorNotConnectedToInternet, // -1009 (path not ready; retry can succeed)
             NSURLErrorDataNotAllowed: // -1020
            return true
        default:
            return false
        }
    }

    /// Transient if any layer in the chain is a matching `NSURLErrorDomain` code (CFNetwork often wraps the URL error).
    private static func isTransientConnectError(_ error: Error) -> Bool {
        for n in nsErrorChain(error) {
            if n.domain == NSURLErrorDomain, isTransientURLErrorCode(n.code) { return true }
        }
        return false
    }

    /// Drops the socket only (no error UI). Used before an automatic retry.
    private func tearDownSocketOnlyForRetry() {
        stopTmuxAutoRefreshLoop()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        socketDelegate = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// Returns `true` if a retry was scheduled (caller should not show final error).
    private func attemptAutoRetryIfPossible(_ error: Error) -> Bool {
        guard connectAutoRetriesLeft > 0,
            lastConnectParams != nil,
            Self.isTransientConnectError(error)
        else { return false }
        connectAutoRetriesLeft -= 1
        noteAction("Transient error; retrying once…")
        if isAttemptingTailnet, let h = lastConnectParams?.tailnetTargetLabel {
            status = "Reconnecting to \(h)…"
        } else {
            status = "Reconnecting…"
        }
        tearDownSocketOnlyForRetry()
        retryConnectionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let p = self.lastConnectParams else { return }
            self.startWebSocketConnection(
                url: p.url,
                displayHost: p.displayHost,
                displayFallback: p.displayFallback,
                useTailnetTimeouts: p.useTailnetTimeouts,
                tailnetTargetLabel: p.tailnetTargetLabel
            )
        }
        return true
    }

    private func scheduleTailnetFallback() {
        tailnetFallbackTask?.cancel()
        tailnetFallbackTask = Task { @MainActor [weak self] in
            let ns = Self.tailnetFallbackSeconds * 1_000_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            guard self.isAttemptingTailnet, !self.hasActiveLayoutSession else { return }
            self.noteAction("Tailnet connection timed out")
            self.isAttemptingTailnet = false
            self.status = "Tailnet connection timed out — check MagicDNS, Tailscale on both devices, and port 19842 on the Mac."
            self.lastError = self.status
            self.disconnect(manual: false)
        }
    }

    private func cancelTailnetFallback() {
        tailnetFallbackTask?.cancel()
        tailnetFallbackTask = nil
    }

    func clearError() {
        lastError = nil
        transcribeError = nil
    }

    /// Clears last transcript lines when the user starts a new hold-to-speak (mirror banner).
    func clearTranscribePreview() {
        transcribeLast = ""
        transcribeError = nil
    }

    private static let actionTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    private func noteAction(_ message: String) {
        let stamp = Self.actionTime.string(from: Date())
        lastActionNote = "\(stamp) — \(message)"
    }

    private func receiveLoop() {
        guard let t = task else { return }
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    guard self.task === t else { return }
                    switch message {
                    case .string(let s):
                        self.handleJSON(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { self.handleJSON(s) }
                    @unknown default:
                        break
                    }
                    guard self.task === t else { return }
                    if self.task != nil { self.receiveLoop() }
                case .failure(let e):
                    // Ignore cancellations/errors for a WebSocket that was already replaced (fixes first-tap race).
                    guard self.task === t else { return }
                    if !self.hasActiveLayoutSession, self.attemptAutoRetryIfPossible(e) { return }
                    self.tearDownFromSocketFailure(e)
                }
            }
        }
    }

    private func handleJSON(_ s: String) {
        let data = Data(s.utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let t = obj["type"] as? String
        else { return }
        switch t {
        case "layout":
            if let m = try? decoder.decode(BridgeLayoutMessage.self, from: data) {
                layout = m
                hasActiveLayoutSession = true
                connectAutoRetriesLeft = 0
                if isAttemptingTailnet {
                    isAttemptingTailnet = false
                    cancelTailnetFallback()
                }
                status = "Connected"
                lastError = nil
                if isTmuxAutoRefreshEnabled, tmuxAutoRefreshTask == nil {
                    startTmuxAutoRefreshLoop()
                }
            }
        case "tmuxPane":
            if let p = try? decoder.decode(BridgeTmuxPaneMessage.self, from: data) {
                tmuxPaneSeq = p.seq
                tmuxPaneText = p.text
                tmuxPaneTruncated = p.truncated
                if let e = p.error, !e.isEmpty {
                    tmuxPaneError = p.error
                } else {
                    tmuxPaneError = nil
                }
            }
        case "transcribeResult":
            if let r = try? decoder.decode(BridgeTranscribeResult.self, from: data) {
                transcribeInFlight = false
                transcribeLast = r.text
                transcribeError = r.error
            }
        case "error":
            if let e = try? decoder.decode(BridgeErrorMessage.self, from: data) {
                status = e.message
                lastError = e.message
            }
        case "pong", "serverHello":
            break
        case "mirrorAppList":
            if let m = try? decoder.decode(BridgeMirrorAppListMessage.self, from: data) {
                mirrorAppListSeq = m.seq
                mirrorAppList = m.apps
            }
        case "windowStream":
            if let m = try? decoder.decode(BridgeWindowStreamMessage.self, from: data) {
                if let b64 = m.base64, let raw = Data(base64Encoded: b64) {
                    windowStreamJpegById[m.windowId] = raw
                    windowStreamErrorById[m.windowId] = nil
                } else if let e = m.error, !e.isEmpty {
                    windowStreamJpegById.removeValue(forKey: m.windowId)
                    windowStreamErrorById[m.windowId] = e
                }
            }
        default:
            break
        }
    }

    func sendSelect(windowId: String) {
        sendEncodable(ClientSelect(windowId: windowId))
    }

    /// Switch which Mac app is mirrored (same as the “Mirror app” row on the Mac). Uses `bundleId` from `mirrorAppList`.
    func sendSetMirrorAppQuery(bundleId: String) {
        let id = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        sendEncodable(ClientSetMirrorAppQuery(bundleId: id))
        noteAction("Mirror app: \(id)")
    }

    /// Tells the Mac to start/stop per-window JPEG screen capture. Turn off in “tmux text” tile mode to save CPU.
    func setWindowStreamToMacEnabled(_ enabled: Bool) {
        windowStreamToMacIsOn = enabled
        if !enabled {
            windowStreamJpegById = [:]
            windowStreamErrorById = [:]
        }
        sendEncodable(ClientSetWindowStreamEnabled(enabled: enabled))
    }

    func sendSetWindowRect(windowId: String, rect: BridgeRect) {
        sendEncodable(ClientSetWindowRect(windowId: windowId, rect: rect))
    }

    /// Ask the Mac to run `tmux capture-pane` and return text (see PROTOCOL / Mac tmux target field).
    func sendRequestTmuxPane(lines: Int? = nil) {
        let n = lines ?? Self.tmuxLineRequest
        sendEncodable(ClientRequestTmuxPane(lines: n))
    }

    /// Toggle persisted auto-refresh (every 2s) for tmux pane text.
    func setTmuxAutoRefresh(_ enabled: Bool) {
        isTmuxAutoRefreshEnabled = enabled
        if enabled {
            startTmuxAutoRefreshLoop()
        } else {
            stopTmuxAutoRefreshLoop()
        }
    }

    private func startTmuxAutoRefreshLoop() {
        guard isTmuxAutoRefreshEnabled, task != nil else { return }
        stopTmuxAutoRefreshLoop()
        isTmuxAutoLoopRunning = true
        tmuxAutoRefreshTask = Task { @MainActor in
            defer { self.isTmuxAutoLoopRunning = false }
            while !Task.isCancelled, self.isTmuxAutoRefreshEnabled, self.task != nil {
                self.sendRequestTmuxPane(lines: Self.tmuxLineRequest)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopTmuxAutoRefreshLoop() {
        tmuxAutoRefreshTask?.cancel()
        tmuxAutoRefreshTask = nil
        isTmuxAutoLoopRunning = false
    }

    private func sendEncodable<T: Encodable>(_ v: T) {
        guard let d = try? encoder.encode(v), let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { [weak self] err in
            if let e = err {
                Task { @MainActor in
                    guard let self else { return }
                    self.status = e.localizedDescription
                    self.lastError = e.localizedDescription
                }
            }
        }
    }

    /// Clears the socket after any failure; idempotent if `task` is already `nil` (e.g. duplicate delegate + receive).
    fileprivate func tearDownFromSocketFailure(_ e: Error) {
        if task == nil { return }
        let wasTailnetAttempt = isAttemptingTailnet
        isAttemptingTailnet = false
        connectAutoRetriesLeft = 0
        lastConnectParams = nil
        cancelPendingAutoRetry()
        cancelTailnetFallback()
        stopTmuxAutoRefreshLoop()
        task = nil
        socketDelegate = nil
        session?.invalidateAndCancel()
        session = nil
        layout = nil
        mirrorAppList = []
        mirrorAppListSeq = 0
        windowStreamJpegById = [:]
        windowStreamErrorById = [:]
        windowStreamToMacIsOn = false
        hasActiveLayoutSession = false
        tmuxPaneText = ""
        tmuxPaneError = nil
        tmuxPaneTruncated = false
        transcribeInFlight = false
        status = "Connection failed: \((e as NSError).localizedDescription)"
        lastError = status
        if wasTailnetAttempt {
            noteAction("Tailnet failed — verify hostname, Tailscale, and Mac bridge on 19842")
        }
    }
}

private struct StoredWebSocketParams {
    let url: URL
    let displayHost: String?
    let displayFallback: String
    let useTailnetTimeouts: Bool
    let tailnetTargetLabel: String?
}

extension BridgeClient: BridgeWebSocketEvents {
    func webSocketDidOpen(task: URLSessionWebSocketTask) {
        guard self.task === task else { return }
        receiveLoop()
    }

    func webSocketConnectFailed(task: URLSessionWebSocketTask, error: Error) {
        guard self.task === task else { return }
        if attemptAutoRetryIfPossible(error) { return }
        tearDownFromSocketFailure(error)
    }

    func webSocketDidCloseCleanly(
        task: URLSessionWebSocketTask,
        code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard self.task === task else { return }
        let r = (reason.flatMap { String(data: $0, encoding: .utf8) }).map { ": \($0)" } ?? ""
        let err = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: [NSLocalizedDescriptionKey: "WebSocket closed (code \(code.rawValue))\(r)"]
        )
        tearDownFromSocketFailure(err)
    }
}

struct ClientSelect: Encodable {
    var type: String = "select"
    var windowId: String
}

struct ClientSetWindowRect: Encodable {
    var type: String = "setWindowRect"
    var windowId: String
    var rect: BridgeRect
}

struct ClientTranscribe: Encodable {
    var type: String = "transcribe"
    var format: String
    var base64: String
    var end: Bool
}

struct ClientTranscribeLive: Encodable {
    var type: String = "transcribeLive"
    var text: String
}

struct ClientRequestTmuxPane: Encodable {
    var type: String = "requestTmuxPane"
    var lines: Int?
}

struct ClientSetMirrorAppQuery: Encodable {
    var type: String = "setMirrorAppQuery"
    var bundleId: String
}

struct ClientSetWindowStreamEnabled: Encodable {
    var type: String = "setWindowStreamEnabled"
    var enabled: Bool
}

extension BridgeClient {
    /// On-device SFSpeech partials → Mac `transcribeLive` (backspace+paste replace). Throttle on the caller.
    func sendTranscribeLive(text: String) {
        sendEncodable(ClientTranscribeLive(text: text))
    }

    /// Stream PCM to the Mac (`format` = `pcm_s16le_16000`). With `end: true`, the server finalizes
    /// STT, pastes, and returns `transcribeResult` (see docs/PROTOCOL.md).
    func sendTranscribeChunk(base64: String, end: Bool) {
        if end { transcribeInFlight = true }
        sendEncodable(ClientTranscribe(format: "pcm_s16le_16000", base64: base64, end: end))
    }
}
