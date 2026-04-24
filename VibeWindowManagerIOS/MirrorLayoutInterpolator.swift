//
//  MirrorLayoutInterpolator.swift
//  VibeWindowManagerIOS
//
//  Linear blend between layout keyframes for smoother Mac-driven mirror motion.
//

import Foundation

struct MirrorLayoutInterpolator {
    /// Time to ease from previous displayed rect to the latest server rect after each `seq` change.
    static let blendDuration: TimeInterval = 0.125

    private var appliedSeq: UInt64?
    private var blendStart: Date?
    private var from: [String: BridgeRect] = [:]
    private var target: [String: BridgeRect] = [:]
    private var display: [String: BridgeRect] = [:]

    mutating func reset() {
        appliedSeq = nil
        blendStart = nil
        from.removeAll()
        target.removeAll()
        display.removeAll()
    }

    /// Per-window rects to draw this frame. Visual-only; does not replace server truth for sends.
    mutating func displayByWindowId(
        now: Date,
        layoutSeq: UInt64,
        windows: [BridgeWindow],
        manipulatingWindowId: String?,
        gestureDraft: [String: BridgeRect]
    ) -> [String: BridgeRect] {
        let ids = Set(windows.map(\.id))

        if appliedSeq != layoutSeq {
            appliedSeq = layoutSeq
            blendStart = now
            for w in windows {
                target[w.id] = w.rect
            }
            for w in windows {
                let id = w.id
                let srv = w.rect
                if manipulatingWindowId == id {
                    from[id] = gestureDraft[id] ?? srv
                } else {
                    from[id] = display[id] ?? srv
                }
            }
            target = target.filter { ids.contains($0.key) }
            from = from.filter { ids.contains($0.key) }
            display = display.filter { ids.contains($0.key) }
        }

        guard let start = blendStart else {
            blendStart = now
            for w in windows {
                display[w.id] = w.rect
            }
            return display
        }

        let t = min(1, max(0, now.timeIntervalSince(start) / Self.blendDuration))

        for w in windows {
            let id = w.id
            if manipulatingWindowId == id {
                display[id] = gestureDraft[id] ?? w.rect
                continue
            }
            guard let f = from[id], let tgt = target[id] else {
                display[id] = w.rect
                continue
            }
            display[id] = t >= 1 ? tgt : Self.lerp(f, tgt, t)
        }

        display = display.filter { ids.contains($0.key) }
        return display
    }

    static func lerp(_ a: BridgeRect, _ b: BridgeRect, _ t: Double) -> BridgeRect {
        let u = max(0, min(1, t))
        return BridgeRect(
            x: a.x + (b.x - a.x) * u,
            y: a.y + (b.y - a.y) * u,
            width: a.width + (b.width - a.width) * u,
            height: a.height + (b.height - a.height) * u
        )
    }
}
