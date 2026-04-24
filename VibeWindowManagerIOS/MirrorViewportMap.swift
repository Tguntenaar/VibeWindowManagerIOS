//
//  MirrorViewportMap.swift
//  VibeWindowManagerIOS
//
//  Projects normalized window rects into iPad points with uniform (aspect-correct) scale.
//
//  `reference` is the Mac desktop union (all displays, Stage-Manager-adjusted). Every rect the
//  server sends — windows and per-screen outlines — is normalized 0..1 against that union.
//
//  Server normalizes x,w by reference.width and y,h by reference.height separately. If we fit
//  the bbox in normalized space with a single scalar, we bake that aspect skew into every tile
//  on iPad. Instead we re-enter the Mac's reference-pixel space (multiply by refW/refH) and pick
//  a single scale there — so a square on Mac is a square on iPad. The iPad therefore reserves a
//  subset of its own area (aspect-fit letterbox of the union) and 1 point inside that subset
//  equals `1/scale` reference pixels; drag math inverts exactly that mapping.
//

import CoreGraphics
import Foundation

struct MirrorViewportMap: Equatable {
    /// Bounding box of the Mac desktop union in **reference-pixel space** (i.e. normalized × ref dims).
    /// Always the unit square of `reference` since the server's reference is now the desktop union.
    let bboxMinX: CGFloat
    let bboxMinY: CGFloat
    let bboxWidth: CGFloat
    let bboxHeight: CGFloat
    /// iPad-view origin (points) where the bbox begins.
    let contentOrigin: CGPoint
    /// Reference pixels → iPad points.
    let scale: CGFloat
    /// Mac reference frame size (AppKit points); used to re-enter pixel space.
    let referenceWidth: CGFloat
    let referenceHeight: CGFloat

    /// Outer padding from container edges; content is centered in the remaining rect.
    static func compute(
        windows: [BridgeWindow],
        reference: BridgeRect,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        outerPadding: CGFloat
    ) -> MirrorViewportMap? {
        guard !windows.isEmpty else { return nil }
        let refW = CGFloat(reference.width)
        let refH = CGFloat(reference.height)
        guard refW > 1e-6, refH > 1e-6 else { return nil }

        // The reference is now the Mac desktop union (all displays). Its unit square is the natural
        // outer bound — windows always normalize into it, so we no longer need to expand the bbox
        // to include outliers. Scaling is driven by the full desktop, not by which windows happen
        // to be open. This is what makes drag math a stable "subset of iPad ↔ whole Mac" mapping.
        let minX: CGFloat = 0
        let minY: CGFloat = 0
        let maxX: CGFloat = refW
        let maxY: CGFloat = refH
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
            scale: s,
            referenceWidth: refW,
            referenceHeight: refH
        )
    }

    func centerAndSize(for rect: BridgeRect) -> (center: CGPoint, size: CGSize) {
        let cxPx = (CGFloat(rect.x) + CGFloat(rect.width) / 2) * referenceWidth
        let cyPx = (CGFloat(rect.y) + CGFloat(rect.height) / 2) * referenceHeight
        let center = CGPoint(
            x: contentOrigin.x + (cxPx - bboxMinX) * scale,
            y: contentOrigin.y + (cyPx - bboxMinY) * scale
        )
        let size = CGSize(
            width: CGFloat(rect.width) * referenceWidth * scale,
            height: CGFloat(rect.height) * referenceHeight * scale
        )
        return (center, size)
    }

    /// iPad-point rect outlining the desktop union (the `reference` unit square in pixel space).
    func referenceViewRect() -> CGRect {
        let originX = contentOrigin.x + (0 - bboxMinX) * scale
        let originY = contentOrigin.y + (0 - bboxMinY) * scale
        return CGRect(
            x: originX,
            y: originY,
            width: referenceWidth * scale,
            height: referenceHeight * scale
        )
    }

    /// iPad-point rects for each physical display, using the same pixel-space mapping as
    /// `referenceViewRect` and `centerAndSize`. Input rects are normalized 0..1 against
    /// `reference` (the desktop union).
    func screenViewRects(_ screens: [BridgeRect]) -> [CGRect] {
        screens.map { s in
            let px = CGFloat(s.x) * referenceWidth
            let py = CGFloat(s.y) * referenceHeight
            let pw = CGFloat(s.width) * referenceWidth
            let ph = CGFloat(s.height) * referenceHeight
            return CGRect(
                x: contentOrigin.x + (px - bboxMinX) * scale,
                y: contentOrigin.y + (py - bboxMinY) * scale,
                width: pw * scale,
                height: ph * scale
            )
        }
    }

    /// SwiftUI drag translation (points) → delta in normalized layout coordinates (same axes as `BridgeRect`).
    func normalizedTranslation(dx: CGFloat, dy: CGFloat) -> (dx: Double, dy: Double) {
        let dxPx = dx / scale
        let dyPx = dy / scale
        return (Double(dxPx / referenceWidth), Double(dyPx / referenceHeight))
    }

    /// Size change in points for bottom-trailing resize → delta in normalized width/height.
    func normalizedSizeDelta(dWidth: CGFloat, dHeight: CGFloat) -> (dWidth: Double, dHeight: Double) {
        let dwPx = dWidth / scale
        let dhPx = dHeight / scale
        return (Double(dwPx / referenceWidth), Double(dhPx / referenceHeight))
    }
}
