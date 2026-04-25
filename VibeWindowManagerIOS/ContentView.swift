//
//  ContentView.swift
//  VibeWindowManagerIOS
//

import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var bridge = BridgeClient()
    @AppStorage("bridgeHostPort") private var hostPort: String = ""
    @State private var showingBridgeSettings = false
    @State private var showingTmuxPane = false

    /// Local preview rects during drag/resize; cleared when server sends a new `layout.seq` (unless manipulating).
    @State private var gestureDraft: [String: BridgeRect] = [:]
    /// While non-nil, layout pushes must not wipe `gestureDraft` (fixes jitter from ~5–10 Hz Mac updates).
    @State private var manipulatingWindowId: String?
    /// Frozen viewport captured at drag/resize start so scale stays constant — pixel-for-pixel drag.
    @State private var frozenMap: MirrorViewportMap?
    /// Snapshot of server windows at drag start — source of truth for non-dragged tiles + swap origins.
    @State private var frozenWindows: [BridgeWindow]?
    /// Proposed swap target under the dragged window.
    @State private var swapTargetId: String?
    /// Dragged window's original rect (also becomes the swap target's destination on release).
    @State private var originalARect: BridgeRect?
    /// Throttle gate for live `setWindowRect` stream.
    @State private var lastSentAt: Date?
    @State private var lastSentRect: BridgeRect?

    /// Persists interpolation state across `TimelineView` ticks (class so mutations don’t replace `@State` identity).
    @State private var mirrorSmootherBox = MirrorLayoutSmootherBox()

    @StateObject private var holdToSpeak = HoldToSpeakRecorder()

    private static let liveSendIntervalIdle: TimeInterval = 1.0 / 30.0
    private static let liveSendIntervalActive: TimeInterval = 1.0 / 60.0
    private static let swapMinOverlapFraction: Double = 0.05
    /// When false, dragging A over B does nothing extra; B stays put.
    private static let swapOnOverlapEnabled: Bool = false

    /// Full-screen remote mirror: hide the inline control stack so it cannot leave a transparent
    /// lower band (outlines would show through) or sit on top of window rects.
    private var isMirroring: Bool {
        if let l = bridge.layout, !l.windows.isEmpty { return true }
        return bridge.hasActiveLayoutSession
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let L = bridge.layout, !L.windows.isEmpty {
                windowOverlay(layout: L)
                    .zIndex(0)
            } else {
                Color.clear
                    .zIndex(0)
            }

            if isMirroring {
                VStack(alignment: .center, spacing: 0) {
                    mirrorTranscribeStatusBanner
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(2)
                .allowsHitTesting(false)
                HStack {
                    Spacer()
                    HStack(spacing: 0) {
                        Button {
                            showingTmuxPane = true
                        } label: {
                            Image(systemName: "text.alignleft")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(12)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Tmux buffer")
                        Button {
                            showingBridgeSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(12)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Bridge settings")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(3)
                HStack {
                    Spacer()
                    MirrorGlobalMicButton(
                        isRecording: holdToSpeak.isRunning,
                        hasSelectedWindow: (bridge.layout?.selectedId).map { !$0.isEmpty } ?? false,
                        onRecordDown: {
                            guard let sid = bridge.layout?.selectedId, !sid.isEmpty else { return }
                            bridge.clearTranscribePreview()
                            holdToSpeak.start(bridge: bridge)
                        },
                        onRecordUp: { holdToSpeak.stop() }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding([.trailing, .bottom])
                .zIndex(3)
            } else {
                BridgeConnectionView(bridge: bridge, hostPort: $hostPort, openAppSettings: openAppSettings)
                    .preferredColorScheme(.dark)
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $showingBridgeSettings) {
            NavigationStack {
                BridgeConnectionView(bridge: bridge, hostPort: $hostPort, openAppSettings: openAppSettings)
                    .navigationTitle("Bridge")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingBridgeSettings = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showingTmuxPane) {
            tmuxPaneSheet
        }
    }

    @ViewBuilder
    private func windowOverlay(layout L: BridgeLayoutMessage) -> some View {
        // Always render inside a single `TimelineView` branch so SwiftUI keeps one stable view
        // identity for the gesture-bearing tiles. A previous `if frozenMap != nil { ... } else { TimelineView ... }`
        // swap re-mounted the subtree on the first `beginMove` (because `frozenMap` flipped the
        // branch), which orphaned the active `DragGesture` and killed the first drag every time.
        // When `frozenMap != nil` the interpolator path inside `mirrorOverlayContent` is skipped,
        // so the timeline tick is effectively free during drags.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            mirrorOverlayContent(layout: L, animationNow: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onChange(of: L.seq) { _, _ in
            if manipulatingWindowId == nil {
                gestureDraft.removeAll()
            }
        }
        .onChange(of: bridge.hasActiveLayoutSession) { _, active in
            if !active {
                mirrorSmootherBox.interpolator.reset()
            }
        }
    }

    @ViewBuilder
    private func mirrorOverlayContent(layout L: BridgeLayoutMessage, animationNow: Date) -> some View {
        GeometryReader { proxy in
            let outerPad = max(14, min(proxy.size.width, proxy.size.height) * 0.02)
            let frozen = frozenMap != nil
            let source = frozenWindows ?? L.windows
            let sorted = source.sorted { $0.zIndex < $1.zIndex }
            let displayById: [String: BridgeRect]? = frozen
                ? nil
                : mirrorSmootherBox.interpolator.displayByWindowId(
                    now: animationNow,
                    layoutSeq: L.seq,
                    windows: L.windows,
                    manipulatingWindowId: manipulatingWindowId,
                    gestureDraft: gestureDraft
                )
            let vmap: MirrorViewportMap? = {
                if let fm = frozenMap { return fm }
                let merged: [BridgeWindow] = L.windows.map { w in
                    let r = displayById?[w.id] ?? w.rect
                    return BridgeWindow(
                        id: w.id,
                        title: w.title,
                        zIndex: w.zIndex,
                        rect: gestureDraft[w.id] ?? r
                    )
                }
                return MirrorViewportMap.compute(
                    windows: merged,
                    reference: L.reference,
                    containerWidth: proxy.size.width,
                    containerHeight: proxy.size.height,
                    outerPadding: outerPad
                )
            }()
            if let vmap {
                let refRect = vmap.referenceViewRect()
                Rectangle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    .frame(width: refRect.width, height: refRect.height)
                    .position(x: refRect.midX, y: refRect.midY)
                    .allowsHitTesting(false)
                let screenRects = vmap.screenViewRects(L.screens ?? [])
                ForEach(Array(screenRects.enumerated()), id: \.offset) { _, sr in
                    Rectangle()
                        .stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                        .frame(width: sr.width, height: sr.height)
                        .position(x: sr.midX, y: sr.midY)
                        .allowsHitTesting(false)
                }
                ForEach(sorted) { win in
                    let isGhost = (win.id == swapTargetId) && (originalARect != nil)
                    let effRect: BridgeRect = {
                        if let draft = gestureDraft[win.id] { return draft }
                        if isGhost, let orig = originalARect { return orig }
                        if frozen { return win.rect }
                        return displayById?[win.id] ?? win.rect
                    }()
                    WindowMirrorOverlayTile(
                        windowId: win.id,
                        effectiveRect: effRect,
                        isGhost: isGhost,
                        selected: win.id == (L.selectedId ?? ""),
                        map: vmap,
                        focusedTmux: (win.id == (L.selectedId ?? ""))
                            ? (text: bridge.tmuxPaneText, error: bridge.tmuxPaneError)
                            : nil,
                        onTap: { bridge.sendSelect(windowId: win.id) },
                        onMoveBegin: { beginMove(windowId: win.id, map: vmap, source: source) },
                        onMoveChange: { dx, dy in moveChange(windowId: win.id, dxPt: dx, dyPt: dy) },
                        onMoveEnd: { endMove(windowId: win.id) },
                        onResizeBegin: { beginResize(windowId: win.id, map: vmap, source: source) },
                        onResizeChange: { dw, dh in resizeChange(windowId: win.id, dwPt: dw, dhPt: dh) },
                        onResizeEnd: { endResize(windowId: win.id) }
                    )
                    .zIndex(Double(win.zIndex))
                }
            }
        }
    }

    // MARK: - Drag / resize flow

    private func beginMove(windowId: String, map: MirrorViewportMap, source: [BridgeWindow]) {
        manipulatingWindowId = windowId
        frozenMap = map
        frozenWindows = source
        originalARect = source.first(where: { $0.id == windowId })?.rect
        swapTargetId = nil
        lastSentAt = nil
        lastSentRect = nil
    }

    private func moveChange(windowId: String, dxPt: CGFloat, dyPt: CGFloat) {
        guard let m = frozenMap, let base = originalARect else { return }
        // 1:1 mapping between the iPad "Mac subset" and the real Mac desktop: finger travel in
        // points ÷ scale ÷ referenceWidth = normalized delta. No gain multiplier — the represented
        // subset on the iPad IS the coordinate space, so anything other than 1x makes the window
        // run away from the finger.
        let (dxN, dyN) = m.normalizedTranslation(dx: dxPt, dy: dyPt)
        let newRect = BridgeRect(
            x: base.x + dxN,
            y: base.y + dyN,
            width: base.width,
            height: base.height
        )
        gestureDraft[windowId] = newRect
        if Self.swapOnOverlapEnabled, let src = frozenWindows {
            swapTargetId = bestSwapTarget(for: newRect, draggedId: windowId, others: src)
        } else {
            swapTargetId = nil
        }
        throttledSend(windowId: windowId, rect: newRect)
    }

    private func endMove(windowId: String) {
        let finalRect = gestureDraft[windowId]
        let swapId = Self.swapOnOverlapEnabled ? swapTargetId : nil
        let swapDest = originalARect

        if let r = finalRect {
            bridge.sendSetWindowRect(windowId: windowId, rect: r)
        }
        if let sid = swapId, let orig = swapDest, sid != windowId {
            bridge.sendSetWindowRect(windowId: sid, rect: orig)
        }

        resetManipulationState(windowId: windowId)
    }

    private func beginResize(windowId: String, map: MirrorViewportMap, source: [BridgeWindow]) {
        manipulatingWindowId = windowId
        frozenMap = map
        frozenWindows = source
        originalARect = source.first(where: { $0.id == windowId })?.rect
        swapTargetId = nil
        lastSentAt = nil
        lastSentRect = nil
    }

    private func resizeChange(windowId: String, dwPt: CGFloat, dhPt: CGFloat) {
        guard let m = frozenMap, let base = originalARect else { return }
        let d = m.normalizedSizeDelta(dWidth: dwPt, dHeight: dhPt)
        let nw = max(MirrorGestureConstants.minNormWidth, base.width + d.dWidth)
        let nh = max(MirrorGestureConstants.minNormHeight, base.height + d.dHeight)
        let newRect = BridgeRect(x: base.x, y: base.y, width: nw, height: nh)
        gestureDraft[windowId] = newRect
        throttledSend(windowId: windowId, rect: newRect)
    }

    private func endResize(windowId: String) {
        if let r = gestureDraft[windowId] {
            bridge.sendSetWindowRect(windowId: windowId, rect: r)
        }
        resetManipulationState(windowId: windowId)
    }

    private func resetManipulationState(windowId: String) {
        frozenMap = nil
        frozenWindows = nil
        originalARect = nil
        swapTargetId = nil
        if manipulatingWindowId == windowId { manipulatingWindowId = nil }
        gestureDraft.removeValue(forKey: windowId)
        lastSentAt = nil
        lastSentRect = nil
        mirrorSmootherBox.interpolator.reset()
    }

    private func throttledSend(windowId: String, rect: BridgeRect) {
        let now = Date()
        let minInterval = manipulatingWindowId == nil
            ? Self.liveSendIntervalIdle
            : Self.liveSendIntervalActive
        if let last = lastSentAt, now.timeIntervalSince(last) < minInterval { return }
        if let prev = lastSentRect, Self.rectsEqual(prev, rect) { return }
        lastSentAt = now
        lastSentRect = rect
        bridge.sendSetWindowRect(windowId: windowId, rect: rect)
    }

    private func bestSwapTarget(
        for aRect: BridgeRect,
        draggedId: String,
        others: [BridgeWindow]
    ) -> String? {
        let aArea = aRect.width * aRect.height
        guard aArea > 0 else { return nil }
        var best: (id: String, area: Double)?
        for w in others where w.id != draggedId {
            let ol = Self.areaOverlap(aRect, w.rect)
            if ol <= 0 { continue }
            if (best?.area ?? 0) < ol { best = (w.id, ol) }
        }
        guard let b = best else { return nil }
        return (b.area / aArea) >= Self.swapMinOverlapFraction ? b.id : nil
    }

    private static func areaOverlap(_ a: BridgeRect, _ b: BridgeRect) -> Double {
        let x = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let y = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        return x * y
    }

    private static func rectsEqual(_ a: BridgeRect, _ b: BridgeRect) -> Bool {
        abs(a.x - b.x) < 1e-6
            && abs(a.y - b.y) < 1e-6
            && abs(a.width - b.width) < 1e-6
            && abs(a.height - b.height) < 1e-6
    }

    private var tmuxPaneSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Refresh") {
                        bridge.sendRequestTmuxPane()
                    }
                    .buttonStyle(.bordered)
                    Toggle("Auto (2s)", isOn: Binding(
                        get: { bridge.isTmuxAutoRefreshEnabled },
                        set: { bridge.setTmuxAutoRefresh($0) }
                    ))
                    if bridge.isTmuxAutoLoopRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                if let e = bridge.tmuxPaneError, !e.isEmpty {
                    Text(e)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if bridge.tmuxPaneTruncated {
                    Text("Output truncated (line/byte cap on Mac).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("seq \(bridge.tmuxPaneSeq)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        if !bridge.tmuxPaneText.isEmpty {
                            Text(bridge.tmuxPaneText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                                .textSelection(.enabled)
                        } else if let e = bridge.tmuxPaneError, !e.isEmpty {
                            Text("No pane text returned. See the error above.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(tmuxEmptyStateHint)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Required so multiline text expands the scrollable content size (otherwise height ~0).
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                }
                .scrollIndicators(.visible, axes: .vertical)
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(UIColor.systemBackground))
            .navigationTitle("tmux buffer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingTmuxPane = false }
                }
            }
            .onAppear {
                bridge.sendRequestTmuxPane()
            }
        }
    }

    private var tmuxEmptyStateHint: String {
        "Tap Refresh — set the tmux target on the Mac, and run your shell inside tmux (see Mac README)."
    }

    /// Shown in mirror mode only (the settings `bridgeControlPanel` is hidden in full mirror).
    @ViewBuilder
    private var mirrorTranscribeStatusBanner: some View {
        if holdToSpeak.isRunning
            || bridge.transcribeInFlight
            || !bridge.transcribeLast.isEmpty
            || !(bridge.transcribeError?.isEmpty ?? true)
        {
            VStack(alignment: .leading, spacing: 8) {
                if holdToSpeak.isRunning {
                    if !holdToSpeak.liveTranscript.isEmpty {
                        Text(holdToSpeak.liveTranscript)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        Text("Listening…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Text("On-device live preview. The Mac still runs Whisper and pastes after you release.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                if bridge.transcribeInFlight {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.white)
                        Text("Transcribing on Mac…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !holdToSpeak.isRunning, !bridge.transcribeInFlight, let err = bridge.transcribeError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color(red: 1, green: 0.4, blue: 0.42))
                } else if !holdToSpeak.isRunning, !bridge.transcribeInFlight, !bridge.transcribeLast.isEmpty {
                    Text(bridge.transcribeLast)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 560)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    private func openAppSettings() {
#if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
#endif
    }
}

private final class MirrorLayoutSmootherBox {
    var interpolator = MirrorLayoutInterpolator()
}

// MARK: - Mirror tile (tap / long-press move / corner resize)

enum MirrorGestureConstants {
    static let minNormWidth: Double = 0.04
    static let minNormHeight: Double = 0.04
    static let handleSize: CGFloat = 26
    /// Full-screen mirror record control (hold-to-speak); not tied to resize handle size.
    static let globalMicButtonSize: CGFloat = handleSize * 5
    /// Finger travel before a move gesture fires — leaves room for `onTapGesture` to win on taps.
    static let moveMinDistance: CGFloat = 6
    /// Inset from tile edges for the in-tile tmux readout, leaving the resize handle (bottom-trailing) clear.
    static let tmuxReadoutHandleMargin: CGFloat = 10
}

/// Live tmux readout for the one **focused** window tile (matches `selectedId` on the Mac).
/// One-finger move is implemented by `TwoFingerScrollTextView`’s back `UIPan`; 2-finger scroll is the `UITextView`.
private struct TmuxTileReadout: View {
    var text: String
    var error: String?
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var onMoveBegin: () -> Void
    var onMoveChange: (CGFloat, CGFloat) -> Void
    var onMoveEnd: () -> Void

    private var displayText: String {
        if text.isEmpty {
            "No buffer yet — use the side menu: Refresh or Auto (2s)."
        } else {
            text
        }
    }

    private var tmuxTextUIColor: UIColor {
        if text.isEmpty { UIColor(white: 1, alpha: 0.45) }
        else { UIColor(red: 0.75, green: 0.95, blue: 0.8, alpha: 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = error, !e.isEmpty {
                Text(e)
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .allowsHitTesting(false)
            }
            TwoFingerScrollTextView(
                text: displayText,
                textColor: tmuxTextUIColor,
                font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                scrollToBottomOnTextChange: true,
                onMoveBegin: onMoveBegin,
                onMoveChange: onMoveChange,
                onMoveEnd: onMoveEnd
            )
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(6)
        .frame(width: maxWidth, height: maxHeight, alignment: .topLeading)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Full-screen hold-to-speak: targets the Mac window already selected in the layout (tap a tile first).
private struct MirrorGlobalMicButton: View {
    let isRecording: Bool
    let hasSelectedWindow: Bool
    var onRecordDown: () -> Void
    var onRecordUp: () -> Void

    @State private var isHoldOnMic = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isRecording ? Color.red.opacity(0.7) : Color.cyan.opacity(0.4))
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .font(.system(size: 12 * 5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .opacity(hasSelectedWindow ? 1 : 0.35)
        .frame(width: MirrorGestureConstants.globalMicButtonSize, height: MirrorGestureConstants.globalMicButtonSize)
        .contentShape(Circle())
        .accessibilityLabel("Hold to speak to selected window")
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { _ in
                    guard hasSelectedWindow else { return }
                    if !isHoldOnMic {
                        isHoldOnMic = true
                        onRecordDown()
                    }
                }
                .onEnded { _ in
                    if isHoldOnMic {
                        isHoldOnMic = false
                        onRecordUp()
                    }
                }
        )
    }
}

private struct WindowMirrorOverlayTile: View {
    let windowId: String
    let effectiveRect: BridgeRect
    /// `true` when this tile is the *proposed swap destination* (B at A's original rect).
    let isGhost: Bool
    let selected: Bool
    let map: MirrorViewportMap
    /// Tmux text/error only for the Mac **focused** window (`selectedId`); `nil` on other tiles.
    let focusedTmux: (text: String, error: String?)?
    var onTap: () -> Void
    var onMoveBegin: () -> Void
    var onMoveChange: (CGFloat, CGFloat) -> Void
    var onMoveEnd: () -> Void
    var onResizeBegin: () -> Void
    var onResizeChange: (CGFloat, CGFloat) -> Void
    var onResizeEnd: () -> Void

    @State private var didBeginMove = false
    @State private var didBeginResize = false

    var body: some View {
        let (center, size) = map.centerAndSize(for: effectiveRect)
        let baseFill: Double = selected ? 0.36 : 0.10
        let fillOpacity: Double = isGhost ? 0.18 : baseFill
        let strokeStyle: StrokeStyle = isGhost
            ? StrokeStyle(lineWidth: 2, dash: [6, 4])
            : StrokeStyle(lineWidth: selected ? 2.5 : 1)
        let strokeColor: Color = isGhost
            ? Color.white.opacity(0.9)
            : Color.white.opacity(selected ? 1 : 0.75)

        let tileFace = RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(fillOpacity))
            .overlay(alignment: .topLeading) {
                if let ft = focusedTmux, !isGhost {
                    let m = MirrorGestureConstants.handleSize + MirrorGestureConstants.tmuxReadoutHandleMargin
                    TmuxTileReadout(
                        text: ft.text,
                        error: ft.error,
                        maxWidth: size.width - m,
                        maxHeight: size.height - m,
                        onMoveBegin: onMoveBegin,
                        onMoveChange: onMoveChange,
                        onMoveEnd: onMoveEnd
                    )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(strokeColor, style: strokeStyle)
            )
            .overlay(alignment: .bottomTrailing) {
                if !isGhost {
                    resizeHandle
                        .frame(width: MirrorGestureConstants.handleSize, height: MirrorGestureConstants.handleSize)
                        .contentShape(Circle())
                        .highPriorityGesture(resizeGesture)
                        .padding(4)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                if !isGhost { onTap() }
            }
        // `TwoFingerScrollTextView` implements 1-finger move over the readout; avoid a second `moveGesture` (double `moveChange`).
        Group {
            if focusedTmux == nil {
                tileFace.gesture(moveGesture)
            } else {
                tileFace
            }
        }
        .position(center)
        .allowsHitTesting(!isGhost)
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.white.opacity(0.55))
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
    }

    // Gestures run in `.global` so `translation` is measured in stable iPad-screen coordinates.
    // With `.local` the tile's own `.position(center)` moves the gesture's coordinate space each
    // frame, which makes `translation` drift back toward zero as the tile catches up to the finger
    // and causes the "drag stalls after a few cm" / "two tiles flying apart" glitches.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: MirrorGestureConstants.moveMinDistance, coordinateSpace: .global)
            .onChanged { drag in
                if !didBeginMove {
                    didBeginMove = true
                    onMoveBegin()
                }
                onMoveChange(drag.translation.width, drag.translation.height)
            }
            .onEnded { _ in
                if didBeginMove {
                    didBeginMove = false
                    onMoveEnd()
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { v in
                if !didBeginResize {
                    didBeginResize = true
                    onResizeBegin()
                }
                onResizeChange(v.translation.width, v.translation.height)
            }
            .onEnded { _ in
                if didBeginResize {
                    didBeginResize = false
                    onResizeEnd()
                }
            }
    }
}

#Preview {
    ContentView()
}
