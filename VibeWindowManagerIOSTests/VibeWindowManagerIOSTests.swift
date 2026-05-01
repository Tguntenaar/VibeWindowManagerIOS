//
//  VibeWindowManagerIOSTests.swift
//  VibeWindowManagerIOSTests
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import VibeWindowManagerIOS

struct VibeWindowManagerIOSTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    @Test func mirrorLayoutInterpolatorLerpEndpoints() {
        let a = BridgeRect(x: 0, y: 0, width: 1, height: 1)
        let b = BridgeRect(x: 10, y: 20, width: 2, height: 3)
        let z = MirrorLayoutInterpolator.lerp(a, b, 0)
        #expect(abs(z.x - a.x) < 1e-9 && abs(z.y - a.y) < 1e-9)
        let o = MirrorLayoutInterpolator.lerp(a, b, 1)
        #expect(abs(o.x - b.x) < 1e-9 && abs(o.y - b.y) < 1e-9)
        let m = MirrorLayoutInterpolator.lerp(a, b, 0.5)
        #expect(abs(m.x - 5) < 1e-9 && abs(m.y - 10) < 1e-9)
        #expect(abs(m.width - 1.5) < 1e-9 && abs(m.height - 2) < 1e-9)
    }

    /// A square Mac window must render as a square on iPad despite ref.width != ref.height.
    @Test func mirrorViewportMapPreservesSquareAspect() throws {
        // 800×800 (points) window inside a 1440×900 Mac reference → wN ≠ hN,
        // but iPad tile size must be square.
        let ref = BridgeRect(x: 0, y: 0, width: 1440, height: 900)
        let win = BridgeWindow(
            id: "a",
            title: "A",
            zIndex: 0,
            rect: BridgeRect(x: 800.0 / 1440.0 * 0 + 0.1, y: 0.1, width: 800.0 / 1440.0, height: 800.0 / 900.0)
        )
        let map = try #require(
            MirrorViewportMap.compute(
                windows: [win],
                reference: ref,
                containerWidth: 1000,
                containerHeight: 700,
                outerPadding: 20
            )
        )
        let (_, size) = map.centerAndSize(for: win.rect)
        #expect(abs(size.width - size.height) < 1e-6, "square on mac must be square on ipad")
    }

    /// Old ignore-reference math distorted squares; this guards against regressing.
    @Test func mirrorViewportMapReferenceOutlineMatchesRefAspect() throws {
        let ref = BridgeRect(x: 0, y: 0, width: 1600, height: 1000) // 1.6 aspect
        let win = BridgeWindow(
            id: "a",
            title: "A",
            zIndex: 0,
            rect: BridgeRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        )
        let map = try #require(
            MirrorViewportMap.compute(
                windows: [win],
                reference: ref,
                containerWidth: 1000,
                containerHeight: 800,
                outerPadding: 0
            )
        )
        let outline = map.referenceViewRect()
        #expect(abs((outline.width / outline.height) - 1.6) < 1e-6)
    }

    /// Two displays expressed as union-normalized rects: iPad outlines should preserve each
    /// screen's aspect ratio and its position inside the union frame.
    @Test func mirrorViewportMapScreenViewRectsRenderEachDisplay() throws {
        // Same geometry as Mac-side twoScreenUnionNormalizeDenormalizeRoundTrip:
        // union 3360x1080, main 1440x900 (top-left corner inside union at y=180/1080),
        // external 1920x1080 flush against union top-right.
        let ref = BridgeRect(x: 0, y: 0, width: 3360, height: 1080)
        let mainScreen = BridgeRect(x: 0, y: 180.0 / 1080.0, width: 1440.0 / 3360.0, height: 900.0 / 1080.0)
        let extScreen = BridgeRect(x: 1440.0 / 3360.0, y: 0, width: 1920.0 / 3360.0, height: 1)
        // Windows are unused in the viewport bbox now, but compute still requires a non-empty list.
        let win = BridgeWindow(
            id: "a",
            title: "A",
            zIndex: 0,
            rect: BridgeRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        )
        let map = try #require(
            MirrorViewportMap.compute(
                windows: [win],
                reference: ref,
                containerWidth: 1000,
                containerHeight: 700,
                outerPadding: 20
            )
        )
        let outline = map.referenceViewRect()
        let rects = map.screenViewRects([mainScreen, extScreen])
        #expect(rects.count == 2)

        // Aspect ratios match (main 1440/900 = 1.6, external 1920/1080 ≈ 1.777).
        #expect(abs((rects[0].width / rects[0].height) - (1440.0 / 900.0)) < 1e-5)
        #expect(abs((rects[1].width / rects[1].height) - (1920.0 / 1080.0)) < 1e-5)

        // Main screen sits inside the union outline (not flush with top because external is taller).
        #expect(rects[0].minX >= outline.minX - 0.5)
        #expect(rects[0].minY > outline.minY + 0.5)
        #expect(rects[0].maxY <= outline.maxY + 0.5)

        // External screen flush with union top, right side reaches union right edge.
        #expect(abs(rects[1].minY - outline.minY) < 0.5)
        #expect(abs(rects[1].maxX - outline.maxX) < 0.5)

        // Main's right edge meets external's left edge (no overlap, no gap in pixel space).
        #expect(abs(rects[0].maxX - rects[1].minX) < 0.5)
    }

    /// Drag math invariant: for a given (dx, dy) in iPad points, the returned normalized delta
    /// depends only on the viewport's `scale` and `reference` dims — not on where the dragged
    /// window currently sits within the union. Moves across displays behave identically.
    @Test func mirrorViewportMapNormalizedTranslationIsPositionInvariant() throws {
        let ref = BridgeRect(x: 0, y: 0, width: 3360, height: 1080)
        let winLeft = BridgeWindow(
            id: "L",
            title: "L",
            zIndex: 0,
            rect: BridgeRect(x: 0.05, y: 0.05, width: 0.2, height: 0.3)
        )
        let winRight = BridgeWindow(
            id: "R",
            title: "R",
            zIndex: 0,
            rect: BridgeRect(x: 0.75, y: 0.1, width: 0.2, height: 0.3) // on the external half
        )
        let mapLeft = try #require(
            MirrorViewportMap.compute(
                windows: [winLeft],
                reference: ref,
                containerWidth: 1000,
                containerHeight: 700,
                outerPadding: 20
            )
        )
        let mapRight = try #require(
            MirrorViewportMap.compute(
                windows: [winRight],
                reference: ref,
                containerWidth: 1000,
                containerHeight: 700,
                outerPadding: 20
            )
        )
        let dLeft = mapLeft.normalizedTranslation(dx: 120, dy: -40)
        let dRight = mapRight.normalizedTranslation(dx: 120, dy: -40)
        #expect(abs(dLeft.dx - dRight.dx) < 1e-12)
        #expect(abs(dLeft.dy - dRight.dy) < 1e-12)
        // Sanity: 120 iPad points → some fraction of the full desktop width.
        #expect(dLeft.dx > 0 && dLeft.dx < 1)
    }

    @Test func streamClickCalibrationAppliesAndClamps() {
        let d = UserDefaults.standard
        let kx = StreamClickCalibration.offsetNXKey
        let ky = StreamClickCalibration.offsetNYKey
        d.removeObject(forKey: kx)
        d.removeObject(forKey: ky)
        defer {
            d.removeObject(forKey: kx)
            d.removeObject(forKey: ky)
        }
        d.set(0.1, forKey: kx)
        d.set(-0.05, forKey: ky)
        let a = StreamClickCalibration.applyToNormalized(nx: 0.4, ny: 0.5)
        #expect(abs(a.nx - 0.5) < 1e-9)
        #expect(abs(a.ny - 0.45) < 1e-9)
        let b = StreamClickCalibration.applyToNormalized(nx: 0.99, ny: 0.02)
        #expect(abs(b.nx - 1) < 1e-9)
        #expect(b.ny == 0)
    }
}
