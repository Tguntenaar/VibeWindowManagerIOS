//
//  BridgeLayoutGeometry.swift
//  VibeWindowManagerIOS
//
//  Converts between AppKit global frames and bridge-normalized rects (match macOS LayoutMirrorService).
//

import CoreGraphics
import Foundation

extension BridgeRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

enum BridgeLayoutGeometry {
    /// Normalized 0…1 top-left, same as the Mac’s `LayoutMirrorService.normalize`.
    static func normalize(frame: CGRect, to ref: CGRect) -> BridgeRect? {
        let w = frame.width
        let h = frame.height
        guard w > 0, h > 0 else { return nil }
        let nx = (frame.minX - ref.minX) / ref.width
        let ny = (ref.maxY - frame.maxY) / ref.height
        let nw = w / ref.width
        let nh = h / ref.height
        return BridgeRect(x: nx, y: ny, width: nw, height: nh)
    }

    /// Inverse of `normalize` (Mac: `LayoutMirrorService.denormalize`).
    static func denormalize(bridgeRect: BridgeRect, to ref: CGRect) -> CGRect {
        let nw = CGFloat(bridgeRect.width)
        let nh = CGFloat(bridgeRect.height)
        let w = nw * ref.width
        let h = nh * ref.height
        let minX = ref.minX + CGFloat(bridgeRect.x) * ref.width
        let maxY = ref.maxY - CGFloat(bridgeRect.y) * ref.height
        let minY = maxY - h
        return CGRect(x: minX, y: minY, width: w, height: h)
    }

    /// Layout area for a chosen display, in AppKit global coordinates (Mac `ScreenGeometry.layoutFrame` space).
    static func visibleAppKitFrame(layout: BridgeLayoutMessage, screenIndex: Int) -> CGRect {
        let ref = layout.reference.cgRect
        if let screens = layout.screens, !screens.isEmpty {
            let idx = min(max(0, screenIndex), screens.count - 1)
            return denormalize(bridgeRect: screens[idx], to: ref)
        }
        return ref
    }

    static func applyRemoteLayout(
        layout: BridgeLayoutMessage,
        screenIndex: Int,
        proposal: RemoteLayoutKind,
        orderedWindows: [BridgeWindow],
        cascadeInset: CGFloat,
        sendRect: (String, BridgeRect) -> Void
    ) {
        let ref = layout.reference.cgRect
        guard !ref.isEmpty, ref.width > 0, ref.height > 0 else { return }
        let visible = visibleAppKitFrame(layout: layout, screenIndex: screenIndex)
        let count = orderedWindows.count
        guard count > 0 else { return }

        let globalFrames: [CGRect] = {
            switch proposal {
            case .tile(let mode):
                return WindowLayoutEngine.slotRects(visibleFrame: visible, mode: mode, count: count)
            case .cascade:
                return WindowLayoutEngine.cascadeFrames(
                    visibleFrame: visible,
                    count: count,
                    insetStep: cascadeInset,
                    margin: CascadeDefaults.margin
                )
            }
        }()

        let n = min(orderedWindows.count, globalFrames.count)
        for i in 0..<n {
            if let r = BridgeLayoutGeometry.normalize(frame: globalFrames[i], to: ref) {
                sendRect(orderedWindows[i].id, r)
            }
        }
    }
}

enum RemoteLayoutKind: Hashable {
    case tile(TileMode)
    case cascade

    var label: String {
        switch self {
        case .tile(let mode):
            return mode.label
        case .cascade:
            return "Cascade"
        }
    }

    static func availableProposals(windowCount: Int) -> [RemoteLayoutKind] {
        let tileProposals = TileMode.suggestedModes(forWindowCount: windowCount).map(RemoteLayoutKind.tile)
        return windowCount == 0 ? tileProposals : tileProposals + [.cascade]
    }
}
