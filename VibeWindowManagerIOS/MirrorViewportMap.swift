//
//  MirrorViewportMap.swift
//  VibeWindowManagerIOS
//
//  Fits all mirrored window rects (possibly outside 0…1) into a padded view with uniform scale.
//

import CoreGraphics
import Foundation

struct MirrorViewportMap: Equatable {
    let bboxMinX: CGFloat
    let bboxMinY: CGFloat
    let bboxWidth: CGFloat
    let bboxHeight: CGFloat
    let contentOrigin: CGPoint
    let scale: CGFloat

    /// Outer padding from container edges; content is centered in the remaining rect.
    static func compute(
        windows: [BridgeWindow],
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        outerPadding: CGFloat
    ) -> MirrorViewportMap? {
        guard !windows.isEmpty else { return nil }
        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity
        for w in windows {
            let r = w.rect
            minX = min(minX, CGFloat(r.x))
            minY = min(minY, CGFloat(r.y))
            maxX = max(maxX, CGFloat(r.x + r.width))
            maxY = max(maxY, CGFloat(r.y + r.height))
        }
        let bw = maxX - minX
        let bh = maxY - minY
        guard bw > 1e-6, bh > 1e-6 else { return nil }

        let contentW = max(1, containerWidth - 2 * outerPadding)
        let contentH = max(1, containerHeight - 2 * outerPadding)
        let s = min(contentW / bw, contentH / bh)
        let usedW = bw * s
        let usedH = bh * s
        let originX = outerPadding + (contentW - usedW) / 2
        let originY = outerPadding + (contentH - usedH) / 2

        return MirrorViewportMap(
            bboxMinX: minX,
            bboxMinY: minY,
            bboxWidth: bw,
            bboxHeight: bh,
            contentOrigin: CGPoint(x: originX, y: originY),
            scale: s
        )
    }

    func centerAndSize(for rect: BridgeRect) -> (center: CGPoint, size: CGSize) {
        let cxN = rect.x + rect.width / 2
        let cyN = rect.y + rect.height / 2
        let relX = CGFloat(cxN - bboxMinX) * scale
        let relY = CGFloat(cyN - bboxMinY) * scale
        let center = CGPoint(x: contentOrigin.x + relX, y: contentOrigin.y + relY)
        let size = CGSize(width: CGFloat(rect.width) * scale, height: CGFloat(rect.height) * scale)
        return (center, size)
    }

    /// SwiftUI drag translation (points) → delta in normalized layout coordinates (same as `BridgeRect` x/y).
    func normalizedTranslation(dx: CGFloat, dy: CGFloat) -> (dx: Double, dy: Double) {
        (Double(dx / scale), Double(dy / scale))
    }

    /// Size change in points for bottom-trailing resize → delta in normalized width/height.
    func normalizedSizeDelta(dWidth: CGFloat, dHeight: CGFloat) -> (dWidth: Double, dHeight: Double) {
        (Double(dWidth / scale), Double(dHeight / scale))
    }
}
