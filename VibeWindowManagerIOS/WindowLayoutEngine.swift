//
//  WindowLayoutEngine.swift
//  VibeWindowManagerIOS
//
//  Pure layout math in AppKit global screen coordinates (origin bottom-left).
//  Kept in sync with the macOS VibeWindowManager copy.
//

import CoreGraphics
import Foundation

enum TileMode: Hashable, Sendable {
    case equalColumns(Int)
    case equalRows(Int)
    case grid(Int)
    case onePlusTwo

    var label: String {
        switch self {
        case .equalColumns(let count):
            return count == 1 ? "Full screen" : "\(count)-way columns"
        case .equalRows(let count):
            return count == 1 ? "Full screen" : "\(count)-way rows"
        case .grid(let count):
            return count == 1 ? "Full screen" : "\(count)-window grid"
        case .onePlusTwo:
            return "1 + 2 split"
        }
    }

    static func suggestedModes(forWindowCount count: Int) -> [TileMode] {
        guard count > 0 else { return [] }
        if count == 1 {
            return [.equalColumns(1)]
        }
        if count == 2 {
            return [.equalColumns(2), .equalRows(2)]
        }

        var modes: [TileMode] = []
        if count == 3 {
            modes.append(.onePlusTwo)
        }
        modes.append(.grid(count))
        modes.append(.equalColumns(count))
        if count <= 4 {
            modes.append(.equalRows(count))
        }
        return modes
    }
}

enum WindowLayoutEngine: Sendable {
    static func slotRects(visibleFrame: CGRect, mode: TileMode, count: Int) -> [CGRect] {
        guard count > 0, visibleFrame.width > 1, visibleFrame.height > 1 else { return [] }
        let vf = visibleFrame

        switch mode {
        case .equalColumns(let requestedCount):
            return equalColumns(visibleFrame: vf, count: min(count, max(1, requestedCount)))

        case .equalRows(let requestedCount):
            return equalRows(visibleFrame: vf, count: min(count, max(1, requestedCount)))

        case .grid(let requestedCount):
            return adaptiveGrid(visibleFrame: vf, count: min(count, max(1, requestedCount)))

        case .onePlusTwo:
            let w = max(0, floor(vf.width / 2.0) - 0.5)
            let h = max(0, floor(vf.height / 2.0) - 0.5)
            let left = CGRect(x: vf.minX, y: vf.minY, width: w, height: vf.height)
            let rt = CGRect(x: vf.minX + w, y: vf.minY + h, width: vf.width - w, height: vf.height - h)
            let rb = CGRect(x: vf.minX + w, y: vf.minY, width: vf.width - w, height: h)
            return [left, rt, rb].prefix(count).map { $0 }
        }
    }

    static func cascadeFrames(visibleFrame: CGRect, count: Int, insetStep: CGFloat, margin: CGFloat) -> [CGRect] {
        let vf = visibleFrame
        guard count > 0 else { return [] }

        let totalInset = max(0, CGFloat(count - 1) * insetStep)
        let width = max(160, vf.width - (margin * 2) - totalInset)
        let height = max(120, vf.height - (margin * 2) - totalInset)

        var result: [CGRect] = []
        for index in 0..<count {
            let offsetMultiplier = CGFloat(count - 1 - index)
            let x = vf.maxX - width - margin - (offsetMultiplier * insetStep)
            let y = vf.maxY - height - margin - (offsetMultiplier * insetStep)
            let rect = clampFrame(
                CGRect(x: x, y: y, width: width, height: height).integral,
                to: vf
            )
            result.append(rect)
        }
        return result
    }

    private static func equalColumns(visibleFrame vf: CGRect, count: Int) -> [CGRect] {
        let widths = partition(total: vf.width, count: count)
        var x = vf.minX
        return widths.map { width in
            defer { x += width }
            return CGRect(x: x, y: vf.minY, width: width, height: vf.height).integral
        }
    }

    private static func equalRows(visibleFrame vf: CGRect, count: Int) -> [CGRect] {
        let heights = partition(total: vf.height, count: count)
        var y = vf.maxY
        return heights.map { height in
            y -= height
            return CGRect(x: vf.minX, y: y, width: vf.width, height: height).integral
        }
    }

    private static func adaptiveGrid(visibleFrame vf: CGRect, count: Int) -> [CGRect] {
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let widths = partition(total: vf.width, count: columns)
        let heights = partition(total: vf.height, count: rows)

        var result: [CGRect] = []
        var y = vf.maxY

        for row in 0..<rows {
            y -= heights[row]
            var x = vf.minX
            for column in 0..<columns {
                guard result.count < count else { return result }
                let rect = CGRect(x: x, y: y, width: widths[column], height: heights[row]).integral
                result.append(rect)
                x += widths[column]
            }
        }

        return result
    }

    private static func partition(total: CGFloat, count: Int) -> [CGFloat] {
        let base = floor(total / CGFloat(count))
        let remainder = total - (base * CGFloat(count))
        return (0..<count).map { index in
            base + (CGFloat(index) < remainder ? 1 : 0)
        }
    }

    private static func clampFrame(_ r: CGRect, to vf: CGRect) -> CGRect {
        var f = r
        if f.width > vf.width { f.size.width = vf.width }
        if f.height > vf.height { f.size.height = vf.height }
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        return f
    }
}

enum CascadeDefaults: Sendable {
    static var insetStep: CGFloat { 30 }
    static var margin: CGFloat { 8 }
}
