//
//  BridgeClient.swift
//  VibeWindowManagerIOS
//
//  WebSocket client plus Bonjour discovery for the Mac bridge.
//

import Combine
import Foundation

struct DiscoveredBridgeService: Identifiable, Equatable {
    let id: String
    let name: String
    let hostPort: String
}

@MainActor
final class BridgeClient: NSObject, ObservableObject {
    @Published var layout: BridgeLayoutMessage?
    @Published var status: String = "Discovering nearby Macs…"
    /// Last button-driven action, for quick confirmation something ran.
    @Published private(set) var lastActionNote: String = ""
    @Published var lastError: String?
    @Published var transcribeLast: String = ""
    @Published var transcribeError: String?
    @Published var discoveredServices: [DiscoveredBridgeService] = []
    @Published var currentTarget: String?
    @Published private(set) var isAutoConnectEnabled = true
    /// True after the first successful `layout` message; cleared on disconnect or connection loss.
    @Published private(set) var hasActiveLayoutSession = false
    /// Persisted Tailnet hostname (e.g. `my-mac.tailxxxx.ts.net` or short `my-mac`).
    /// When non-empty, auto-connect tries this first and falls back to Bonjour on timeout/failure.
    @Published var preferredTailnetHost: String {
        didSet { UserDefaults.standard.set(preferredTailnetHost, forKey: Self.tailnetHostKey) }
    }
    /// True while we are waiting for the Tailnet attempt to succeed before Bonjour fallback.
    @Published private(set) var isAttemptingTailnet: Bool = false

    private static let tailnetHostKey = "bridgeTailnetHost"
    private static let tailnetFallbackSeconds: UInt64 = 6

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let browser = NetServiceBrowser()
    private var pendingServices: [ObjectIdentifier: NetService] = [:]
    private var resolvedServices: [ObjectIdentifier: DiscoveredBridgeService] = [:]
    private var tailnetFallbackTask: Task<Void, Never>?
    private var autoConnectEnabled = true {
        didSet { isAutoConnectEnabled = autoConnectEnabled }
    }

    override init() {
        self.preferredTailnetHost = UserDefaults.standard.string(forKey: Self.tailnetHostKey) ?? ""
        super.init()
        // #region agent log
        let b = Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices")
        let l = Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription")
        let bStr: String
        if let a = b as? [String] { bStr = a.joined(separator: ",") } else { bStr = String(describing: b) }
        let lStr = (l as? String) != nil ? "set" : "missing"
        AgentDebugLog.log(hypothesisId: "H1", location: "BridgeClient.init", message: "info_plist", data: [
            "NSBonjourServices": bStr,
            "NSLocalNetworkUsage": lStr,
            "tailnetHost": preferredTailnetHost.isEmpty ? "unset" : "set",
        ])
        // #endregion
        browser.delegate = self
        startBrowsing()
    }

    deinit {
        browser.stop()
    }

    /// - Parameters:
    ///   - userInitiated: true when the user tapped "Refresh discovery".
    ///   - forAutoConnect: true from "Auto-connect now" (takes priority over `userInitiated`).
    func startBrowsing(userInitiated: Bool = false, forAutoConnect: Bool = false) {
        browser.stop()
        pendingServices.removeAll()
        resolvedServices.removeAll()
        discoveredServices = []
        lastError = nil
        browser.searchForServices(ofType: "_vibewm._tcp.", inDomain: "local.")
        // #region agent log
        AgentDebugLog.log(hypothesisId: "H2", location: "BridgeClient.startBrowsing", message: "search_started", data: ["type": "_vibewm._tcp."])
        // #endregion
        if forAutoConnect {
            noteAction("Auto-connect: browsing; will use first Mac found")
            status = "Browsing this Wi‑Fi for Mac bridge (Bonjour)…"
        } else if userInitiated {
            noteAction("Refresh: restarted Bonjour browse for _vibewm._tcp")
            status = "Browsing this Wi‑Fi for Mac bridge (Bonjour)…"
        } else if task == nil {
            status = "Discovering nearby Macs…"
        }
    }

    /// `192.168.x.x:19842` or full `ws://host:port/bridge`
    func connect(hostOrURL: String) {
        autoConnectEnabled = false
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
        // #region agent log
        AgentDebugLog.log(hypothesisId: "H4", location: "BridgeClient.connect(hostOrURL:)", message: "ws_url", data: ["url": u.absoluteString])
        // #endregion
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        let s = URLSession(configuration: cfg, delegate: nil, delegateQueue: .main)
        session = s
        let task = s.webSocketTask(with: u)
        self.task = task
        if let host = u.host {
            currentTarget = u.port.map { "\(host):\($0)" } ?? host
        } else {
            currentTarget = t
        }
        status = "Connecting to \(u.host ?? t)…"
        task.resume()
        receiveLoop()
    }

    func disconnect(manual: Bool = true) {
        if manual { autoConnectEnabled = false }
        if manual {
            noteAction("Disconnect")
            cancelTailnetFallback()
            isAttemptingTailnet = false
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        layout = nil
        hasActiveLayoutSession = false
        currentTarget = nil
        status = manual ? "Disconnected" : "Searching for bridge…"
    }

    func connect(discovered service: DiscoveredBridgeService) {
        noteAction("Tapped: \(service.name) at \(service.hostPort)")
        cancelTailnetFallback()
        isAttemptingTailnet = false
        disconnect(manual: false)
        lastError = nil
        let ws = "ws://\(service.hostPort)/bridge"
        // #region agent log
        AgentDebugLog.log(hypothesisId: "H4", location: "BridgeClient.connect(discovered:)", message: "ws_url", data: ["url": ws, "name": service.name])
        // #endregion
        guard let u = URL(string: ws) else {
            status = "Invalid discovered address"
            lastError = status
            return
        }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        let s = URLSession(configuration: cfg, delegate: nil, delegateQueue: .main)
        session = s
        let task = s.webSocketTask(with: u)
        self.task = task
        currentTarget = "\(service.name) (\(service.hostPort))"
        status = "Auto-connecting to \(service.name)…"
        task.resume()
        receiveLoop()
    }

    func enableAutoConnect() {
        autoConnectEnabled = true
        if attemptTailnetIfConfigured() { return }
        maybeAutoConnect()
    }

    func autoConnectNow() {
        autoConnectEnabled = true
        if attemptTailnetIfConfigured() { return }
        startBrowsing(forAutoConnect: true)
        maybeAutoConnect()
    }

    /// If a Tailnet host is configured, start a WS attempt to it with a fallback timer.
    /// Returns true if a Tailnet attempt was started (caller should skip Bonjour kickoff).
    @discardableResult
    func attemptTailnetIfConfigured() -> Bool {
        let host = preferredTailnetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return false }
        connectTailnet(host: host)
        return true
    }

    /// Manual / auto-connect entry for a Tailnet hostname (MagicDNS or short form).
    /// Keeps `autoConnectEnabled` on so Bonjour fallback still runs if this attempt fails.
    func connectTailnet(host: String) {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return }
        cancelTailnetFallback()
        autoConnectEnabled = true
        disconnect(manual: false)
        lastError = nil
        let portPart = h.contains(":") ? h : "\(h):19842"
        let ws = "ws://\(portPart)/bridge"
        guard let u = URL(string: ws) else {
            status = "Invalid Tailnet hostname"
            lastError = status
            return
        }
        // #region agent log
        AgentDebugLog.log(hypothesisId: "H5", location: "BridgeClient.connectTailnet", message: "tailnet_ws", data: ["url": ws])
        // #endregion
        isAttemptingTailnet = true
        noteAction("Tailnet: trying \(h)")
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg, delegate: nil, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: u)
        task = t
        currentTarget = "\(h) (tailnet)"
        status = "Connecting via Tailnet (\(h))…"
        t.resume()
        receiveLoop()
        scheduleTailnetFallback()
    }

    private func scheduleTailnetFallback() {
        tailnetFallbackTask?.cancel()
        tailnetFallbackTask = Task { @MainActor [weak self] in
            let ns = Self.tailnetFallbackSeconds * 1_000_000_000
            try? await Task.sleep(nanoseconds: ns)
            guard let self, !Task.isCancelled else { return }
            guard self.isAttemptingTailnet, !self.hasActiveLayoutSession else { return }
            // #region agent log
            AgentDebugLog.log(hypothesisId: "H5", location: "BridgeClient.scheduleTailnetFallback", message: "tailnet_timeout_fallback", data: ["host": self.preferredTailnetHost])
            // #endregion
            self.noteAction("Tailnet timed out; falling back to Bonjour")
            self.status = "Tailnet attempt timed out; browsing LAN…"
            self.isAttemptingTailnet = false
            self.disconnect(manual: false)
            self.startBrowsing(forAutoConnect: true)
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
                    switch message {
                    case .string(let s):
                        self.handleJSON(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { self.handleJSON(s) }
                    @unknown default:
                        break
                    }
                    if self.task != nil { self.receiveLoop() }
                case .failure(let e):
                    // #region agent log
                    AgentDebugLog.log(
                        hypothesisId: "H4",
                        location: "BridgeClient.receiveLoop",
                        message: "ws_failure",
                        data: ["error": e.localizedDescription, "tailnet": self.isAttemptingTailnet ? "1" : "0"]
                    )
                    // #endregion
                    let wasTailnetAttempt = self.isAttemptingTailnet
                    self.isAttemptingTailnet = false
                    self.cancelTailnetFallback()
                    self.task = nil
                    self.session?.invalidateAndCancel()
                    self.session = nil
                    self.layout = nil
                    self.hasActiveLayoutSession = false
                    self.status = "Connection failed: \(e.localizedDescription)"
                    self.lastError = self.status
                    if self.autoConnectEnabled {
                        if wasTailnetAttempt {
                            self.noteAction("Tailnet failed; falling back to Bonjour")
                            self.startBrowsing(forAutoConnect: true)
                        } else {
                            self.maybeAutoConnect()
                        }
                    }
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
                if isAttemptingTailnet {
                    isAttemptingTailnet = false
                    cancelTailnetFallback()
                }
                status = "Connected"
                lastError = nil
            }
        case "transcribeResult":
            if let r = try? decoder.decode(BridgeTranscribeResult.self, from: data) {
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
        default:
            break
        }
    }

    func sendSelectNext() {
        sendEncodable(ClientSelectNext())
    }

    func sendSelect(windowId: String) {
        sendEncodable(ClientSelect(windowId: windowId))
    }

    func sendSetWindowRect(windowId: String, rect: BridgeRect) {
        sendEncodable(ClientSetWindowRect(windowId: windowId, rect: rect))
    }

    func sendPaste(_ text: String) {
        sendEncodable(ClientPaste(text: text))
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
}

struct ClientSelectNext: Encodable {
    var type: String = "selectNext"
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

struct ClientPaste: Encodable {
    var type: String = "pasteText"
    var text: String
}

struct ClientTranscribe: Encodable {
    var type: String = "transcribe"
    var format: String
    var base64: String
    var end: Bool
}

extension BridgeClient {
    /// Server runs STT on `end` and sends `transcribeResult` (no mic in UI yet; use for API checks).
    func sendTranscribeEndTest() {
        sendEncodable(ClientTranscribe(format: "pcm_s16le_16000", base64: "", end: true))
    }
}

extension BridgeClient: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            // #region agent log
            AgentDebugLog.log(
                hypothesisId: "H2",
                location: "BridgeClient.didFind",
                message: "service_found",
                data: [
                    "name": service.name,
                    "type": service.type,
                ]
            )
            // #endregion
            let key = ObjectIdentifier(service)
            pendingServices[key] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            let key = ObjectIdentifier(service)
            pendingServices.removeValue(forKey: key)
            resolvedServices.removeValue(forKey: key)
            refreshDiscoveredServices()
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            let key = ObjectIdentifier(sender)
            pendingServices[key] = sender
            let hostRaw = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let port = sender.port
            guard let host = hostRaw, !host.isEmpty, port > 0 else {
                // #region agent log
                AgentDebugLog.log(
                    hypothesisId: "H2",
                    location: "BridgeClient.netServiceDidResolve",
                    message: "resolve_incomplete",
                    data: [
                        "host": hostRaw ?? "nil",
                        "port": String(port),
                    ]
                )
                // #endregion
                return
            }
            resolvedServices[key] = DiscoveredBridgeService(
                id: "\(sender.name)-\(host)-\(port)",
                name: sender.name,
                hostPort: "\(host):\(port)"
            )
            // #region agent log
            AgentDebugLog.log(
                hypothesisId: "H2",
                location: "BridgeClient.netServiceDidResolve",
                message: "resolved_ok",
                data: [
                    "hostPort": "\(host):\(port)",
                    "name": sender.name,
                ]
            )
            // #endregion
            refreshDiscoveredServices()
            maybeAutoConnect()
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        Task { @MainActor in
            // #region agent log
            let errBits = errorDict.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            AgentDebugLog.log(
                hypothesisId: "H1",
                location: "BridgeClient.didNotResolve",
                message: "resolve_failed",
                data: [
                    "name": sender.name,
                    "errorDict": errBits,
                ]
            )
            // #endregion
            pendingServices.removeValue(forKey: ObjectIdentifier(sender))
            if discoveredServices.isEmpty, task == nil {
                lastError = "Could not resolve \(sender.name). If no Macs appear, check Local Network permission."
            }
        }
    }

    private func refreshDiscoveredServices() {
        discoveredServices = resolvedServices.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func maybeAutoConnect() {
        guard autoConnectEnabled, task == nil, let first = discoveredServices.first else { return }
        connect(discovered: first)
    }
}
