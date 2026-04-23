//
//  IOSBridgeModels.swift
//  VibeWindowManagerIOS
//
//  Server → client JSON (see Mac docs/PROTOCOL.md).
//

import Foundation

struct BridgeLayoutMessage: Codable, Equatable {
    var type: String
    var seq: UInt64
    var appName: String?
    var bundleId: String?
    var reference: BridgeRect
    var windows: [BridgeWindow]
    var selectedId: String?
}

struct BridgeRect: Codable, Equatable {
    var x, y, width, height: Double
}

struct BridgeWindow: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var zIndex: Int
    var rect: BridgeRect
}

struct BridgeTranscribeResult: Codable {
    var type: String
    var text: String
    var error: String?
}

struct BridgeErrorMessage: Codable {
    var type: String
    var message: String
}
