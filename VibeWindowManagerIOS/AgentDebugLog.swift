//
//  AgentDebugLog.swift
//  VibeWindowManagerIOS
//
//  Session debug: POST to ingest (Simulator) + print. Physical device: print only.
//

import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum AgentDebugLog {
    private static let ingest = URL(string: "http://127.0.0.1:7366/ingest/ad388fc6-65f2-4832-bb53-b6335324738d")!
    private static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        return URLSession(configuration: c)
    }()

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String] = [:]
    ) {
        let payload: [String: Any] = [
            "sessionId": "155edc",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let s = String(data: body, encoding: .utf8) ?? ""
        #if canImport(UIKit)
        let dev = (UIDevice.current.model + " " + UIDevice.current.systemVersion)
        #else
        let dev = "ios"
        #endif
        print("[AgentDebug] \(s) device=\(dev)")

        var req = URLRequest(url: ingest)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("155edc", forHTTPHeaderField: "X-Debug-Session-Id")
        req.httpBody = body
        session.dataTask(with: req) { _, _, _ in }.resume()
    }
}
