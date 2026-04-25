//
//  BridgeWebSocketURLSessionDelegate.swift
//  VibeWindowManagerIOS
//
//  Starts the receive loop only after the HTTP 101 WebSocket upgrade completes.
//  Calling `receive` before the handshake may trigger CFNetwork:
//  "Connection not set before response is received" and NSURLError -1005.
//

import Foundation

@MainActor
protocol BridgeWebSocketEvents: AnyObject {
    func webSocketDidOpen(task: URLSessionWebSocketTask)
    func webSocketConnectFailed(task: URLSessionWebSocketTask, error: Error)
    func webSocketDidCloseCleanly(task: URLSessionWebSocketTask, code: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

@MainActor
final class BridgeWebSocketURLSessionDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    weak var events: BridgeWebSocketEvents?
    private weak var expected: URLSessionWebSocketTask?

    init(events: BridgeWebSocketEvents) {
        self.events = events
    }

    /// Call immediately after `session.webSocketTask(with:)` before `resume()`.
    func attach(task: URLSessionWebSocketTask) {
        self.expected = task
    }

    private func isExpected(_ t: URLSessionTask) -> Bool {
        if let a = expected, a === t { return true }
        return false
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard isExpected(webSocketTask) else { return }
        events?.webSocketDidOpen(task: webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error, isExpected(task) else { return }
        guard let ws = task as? URLSessionWebSocketTask else { return }
        events?.webSocketConnectFailed(task: ws, error: e)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard isExpected(webSocketTask) else { return }
        events?.webSocketDidCloseCleanly(task: webSocketTask, code: closeCode, reason: reason)
    }
}
