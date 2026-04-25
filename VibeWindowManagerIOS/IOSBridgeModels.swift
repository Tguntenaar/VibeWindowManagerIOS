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
    /// Desktop-wide coordinate space (union of every Mac display's layout frame). All rects below
    /// are normalized 0..1 top-left against this.
    var reference: BridgeRect
    /// Per-physical-display rects normalized against `reference`. Optional: older servers omit it;
    /// clients fall back to drawing just the reference outline.
    var screens: [BridgeRect]?
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

struct BridgeTmuxPaneMessage: Codable {
    var type: String
    var seq: UInt64
    var text: String
    var error: String?
    /// True if server clipped (line/byte cap).
    var truncated: Bool
}

struct BridgeMirrorAppEntry: Codable, Equatable, Identifiable {
    var name: String
    var bundleId: String
    var iconPNGBase64: String?

    var id: String { bundleId }
}

struct BridgeMirrorAppListMessage: Codable, Equatable {
    var type: String
    var seq: UInt64
    var apps: [BridgeMirrorAppEntry]
}

struct BridgeWindowStreamMessage: Codable, Equatable {
    var type: String
    var seq: UInt64
    var windowId: String
    var format: String
    var base64: String?
    var error: String?
}
