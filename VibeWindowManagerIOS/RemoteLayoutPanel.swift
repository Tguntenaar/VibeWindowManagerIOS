//
//  RemoteLayoutPanel.swift
//  VibeWindowManagerIOS
//
//  Remote equivalent of the macOS “Layout” tab: pick display, choose a layout, reorder windows, apply on the Mac.
//

import CoreGraphics
import SwiftUI
import UIKit

struct RemoteLayoutPanel: View {
    @ObservedObject var bridge: BridgeClient
    @Environment(\.dismiss) private var dismiss

    @State private var screenIndex: Int = 0
    @State private var selectedKind: RemoteLayoutKind?
    @State private var windowOrder: [BridgeWindow] = []
    @State private var lastSyncedLayoutSeq: UInt64?
    @State private var cascadeInsetStep: Double = Double(CascadeDefaults.insetStep)
    @State private var showingAppPicker = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Arrange windows")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .onAppear { syncFromLayout() }
        .onChange(of: bridge.layout?.seq) { _, _ in
            syncFromLayout()
        }
        .sheet(isPresented: $showingAppPicker) {
            NavigationStack {
                MirrorAppPickerGrid(
                    apps: bridge.mirrorAppList,
                    currentBundleId: bridge.layout?.bundleId,
                    onPick: { bundleId in
                        bridge.sendSetMirrorAppQuery(bundleId: bundleId)
                        showingAppPicker = false
                    },
                    style: .formSheet
                )
                .navigationTitle("Mirror app")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingAppPicker = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var content: some View {
        if let L = bridge.layout {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetSection(layout: L)
                    displaySection(layout: L)
                    proposalsSection(layout: L)
                    previewSection(layout: L)
                    if let e = bridge.lastError, !e.isEmpty {
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
        } else {
            VStack(spacing: 12) {
                Text("No mirrored windows yet")
                    .font(.headline)
                Text("Connect to your Mac and wait for the layout overlay to show windows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Close") { dismiss() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(Color(.systemGroupedBackground))
        }
    }

    private func syncFromLayout() {
        guard let L = bridge.layout else { return }
        if lastSyncedLayoutSeq != L.seq {
            windowOrder = L.windows
            lastSyncedLayoutSeq = L.seq
        } else {
            let serverIds = Set(L.windows.map(\.id))
            let localIds = Set(windowOrder.map(\.id))
            if serverIds != localIds {
                windowOrder = L.windows
            }
        }
        normalizeSelectedKind(windowCount: windowOrder.count)
    }

    private func normalizeSelectedKind(windowCount: Int) {
        let all = RemoteLayoutKind.availableProposals(windowCount: windowCount)
        guard !all.isEmpty else {
            selectedKind = nil
            return
        }
        if let s = selectedKind, all.contains(s) { return }
        selectedKind = all.first
    }

    // MARK: Sections

    private func targetSection(layout: BridgeLayoutMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Target")
                .font(.headline)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(layout.appName ?? "Unknown")
                        .font(.subheadline.weight(.medium))
                    if let bid = layout.bundleId {
                        Text(bid)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    showingAppPicker = true
                } label: {
                    Label("Choose app", systemImage: "square.grid.3x3.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityLabel("Choose mirror app")
            }
            Text("Switches which Mac app’s windows are mirrored (same as the grid control on the mirror view).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBackground)
    }

    private func displaySection(layout: BridgeLayoutMessage) -> some View {
        let screens = layout.screens ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text("Display")
                .font(.headline)
            if screens.isEmpty {
                Text("The Mac is mirroring a single layout region. Layouts use the full desktop area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                IPadDisplayArrangementMap(
                    screenRects: screens,
                    selectedIndex: $screenIndex
                )
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 150)
                if screenIndex < screens.count {
                    Text("Selected: Display \(screenIndex + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { clampScreenIndex(screens: screens) }
        .onChange(of: screens.count) { _, _ in
            clampScreenIndex(screens: screens)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func clampScreenIndex(screens: [BridgeRect]) {
        guard !screens.isEmpty else { return }
        if screenIndex >= screens.count {
            screenIndex = max(0, screens.count - 1)
        }
    }

    private func proposalsSection(layout: BridgeLayoutMessage) -> some View {
        let props = RemoteLayoutKind.availableProposals(windowCount: windowOrder.count)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Suggested layouts")
                .font(.headline)
            Text(splitSummaryText(layout: layout))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if props.isEmpty {
                Text("No layout suggestions for this state.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100, maximum: 132), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(props, id: \.self) { proposal in
                        RemoteLayoutProposalThumbnail(
                            proposal: proposal,
                            windowCount: max(1, windowOrder.count),
                            isSelected: selectedKind == proposal
                        ) {
                            selectedKind = proposal
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func splitSummaryText(layout: BridgeLayoutMessage) -> String {
        if windowOrder.isEmpty { return "No windows in this layout update." }
        return "\(layout.appName ?? "App"): \(windowOrder.count) window\(windowOrder.count == 1 ? "" : "s") on the Mac."
    }

    private func previewSection(layout: BridgeLayoutMessage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview & apply")
                .font(.headline)
            if let kind = selectedKind, let visible = previewVisibleFrame(layout: layout) {
                let frames = previewGlobalFrames(visible: visible, kind: kind, count: windowOrder.count)
                HStack(alignment: .top, spacing: 16) {
                    IPadLayoutPreviewView(visibleFrame: visible, frames: frames, windows: windowOrder)
                        .frame(minWidth: 280, maxWidth: 400, minHeight: 200, idealHeight: 240)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Window order")
                            .font(.subheadline.weight(.semibold))
                        Text("The top row is the first tile in the preview.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if kind == .cascade {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Cascade offset")
                                    Spacer()
                                    Text("\(Int(cascadeInsetStep)) pt")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $cascadeInsetStep, in: 0...120, step: 1)
                            }
                        }
                        windowOrderList
                        Button {
                            apply(layout: layout, kind: kind)
                        } label: {
                            Label("Apply \(kind.label)", systemImage: "checkmark.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(frames.isEmpty || windowOrder.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Choose a layout above. When the Mac sends window tiles, you can apply tile or cascade on the display you picked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    @ViewBuilder
    private var windowOrderList: some View {
        if windowOrder.isEmpty {
            Text("No windows.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(windowOrder.enumerated()), id: \.element.id) { index, w in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 20, alignment: .trailing)
                            Text(w.title)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                moveWindow(from: index, offset: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .disabled(index == 0)
                            Button {
                                moveWindow(from: index, offset: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .disabled(index == windowOrder.count - 1)
                        }
                        .padding(.vertical, 6)
                        if index < windowOrder.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func moveWindow(from index: Int, offset: Int) {
        let destination = index + offset
        guard windowOrder.indices.contains(index), windowOrder.indices.contains(destination) else { return }
        let moved = windowOrder.remove(at: index)
        windowOrder.insert(moved, at: destination)
    }

    private func previewVisibleFrame(layout: BridgeLayoutMessage) -> CGRect? {
        let ref = layout.reference.cgRect
        guard !ref.isEmpty else { return nil }
        return BridgeLayoutGeometry.visibleAppKitFrame(layout: layout, screenIndex: screenIndex)
    }

    private func previewGlobalFrames(visible: CGRect, kind: RemoteLayoutKind, count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        switch kind {
        case .tile(let mode):
            return WindowLayoutEngine.slotRects(visibleFrame: visible, mode: mode, count: count)
        case .cascade:
            return WindowLayoutEngine.cascadeFrames(
                visibleFrame: visible,
                count: count,
                insetStep: CGFloat(cascadeInsetStep),
                margin: CascadeDefaults.margin
            )
        }
    }

    private func apply(layout: BridgeLayoutMessage, kind: RemoteLayoutKind) {
        BridgeLayoutGeometry.applyRemoteLayout(
            layout: layout,
            screenIndex: screenIndex,
            proposal: kind,
            orderedWindows: windowOrder,
            cascadeInset: CGFloat(cascadeInsetStep)
        ) { id, rect in
            bridge.sendSetWindowRect(windowId: id, rect: rect)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

// MARK: - Display map (normalized BridgeRects, shared reference space)

private struct IPadDisplayArrangementMap: View {
    let screenRects: [BridgeRect]
    @Binding var selectedIndex: Int

    var body: some View {
        Group {
            if screenRects.isEmpty {
                Text("No per-display list from the server.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                let union = Self.unionOfNormalized(screenRects)
                GeometryReader { proxy in
                    let w = max(union.width, 0.0001)
                    let h = max(union.height, 0.0001)
                    let scale = min(proxy.size.width / CGFloat(w), proxy.size.height / CGFloat(h))
                    let contentW = CGFloat(w) * scale
                    let contentH = CGFloat(h) * scale
                    let offsetX = (proxy.size.width - contentW) * 0.5
                    let offsetY = (proxy.size.height - contentH) * 0.5
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.quaternaryLabel).opacity(0.35))
                            .frame(width: contentW, height: contentH)
                            .offset(x: offsetX, y: offsetY)
                        ForEach(screenRects.indices, id: \.self) { index in
                            let r = screenRects[index]
                            let preview = Self.localRect(r: r, union: union)
                            let isSelected = index == selectedIndex
                            Button {
                                selectedIndex = index
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected
                                            ? Color.accentColor.opacity(0.32)
                                            : Color(.secondarySystemGroupedBackground))
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor : Color(.separator).opacity(0.9),
                                            lineWidth: isSelected ? 2.5 : 1
                                        )
                                    Text("Display \(index + 1)")
                                        .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .minimumScaleFactor(0.5)
                                        .padding(4)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: CGFloat(preview.width) * scale, height: CGFloat(preview.height) * scale)
                            .offset(
                                x: offsetX + CGFloat(preview.x - union.x) * scale,
                                y: offsetY + CGFloat(preview.y - union.y) * scale
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear { clamp() }
        .onChange(of: screenRects.count) { _, _ in clamp() }
    }

    private func clamp() {
        guard !screenRects.isEmpty, selectedIndex >= screenRects.count else { return }
        selectedIndex = max(0, screenRects.count - 1)
    }

    private static func unionOfNormalized(_ rs: [BridgeRect]) -> BridgeRect {
        guard let f = rs.first else {
            return BridgeRect(x: 0, y: 0, width: 1, height: 1)
        }
        var minX = f.x, minY = f.y, maxX = f.x + f.width, maxY = f.y + f.height
        for r in rs.dropFirst() {
            minX = min(minX, r.x)
            minY = min(minY, r.y)
            maxX = max(maxX, r.x + r.width)
            maxY = max(maxY, r.y + r.height)
        }
        return BridgeRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `r` and union use top-left normalized coords within `reference` (bridge space).
    private static func localRect(r: BridgeRect, union: BridgeRect) -> BridgeRect {
        BridgeRect(
            x: r.x - union.x,
            y: r.y - union.y,
            width: r.width,
            height: r.height
        )
    }
}

// MARK: - Large preview (AppKit global visible frame, same as Mac `LayoutPreviewView`)

private struct IPadLayoutPreviewView: View {
    let visibleFrame: CGRect
    let frames: [CGRect]
    let windows: [BridgeWindow]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let scale = min(size.width / visibleFrame.width, size.height / visibleFrame.height)
            let previewSize = CGSize(width: visibleFrame.width * scale, height: visibleFrame.height * scale)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: previewSize.width, height: previewSize.height)

                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    let rect = scaledRect(frame, scale: scale)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                Text(windowTitle(at: index))
                                    .font(.caption2)
                                    .lineLimit(2)
                            }
                            .padding(8)
                        }
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func scaledRect(_ frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (frame.minX - visibleFrame.minX) * scale,
            y: (visibleFrame.maxY - frame.maxY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func windowTitle(at index: Int) -> String {
        guard windows.indices.contains(index) else { return "Window \(index + 1)" }
        return windows[index].title
    }
}

// MARK: - Thumbnail (matches mac `LayoutProposalThumbnail` sizing)

private struct RemoteLayoutProposalThumbnail: View {
    let proposal: RemoteLayoutKind
    let windowCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    private static let engineFrameTile = CGRect(x: 0, y: 0, width: 200, height: 200)
    private static let engineFrameCascade = CGRect(x: 0, y: 0, width: 480, height: 360)
    private static let paneGutter: CGFloat = 0.02
    private static let thumbSize: CGFloat = 76

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                let vf = engineVisibleFrame
                let rects = panes
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(.quaternaryLabel).opacity(0.45),
                                    Color(.quaternaryLabel).opacity(0.18),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.75)
                        }
                    ForEach(Array(rects.enumerated()), id: \.offset) { index, frame in
                        let r = toPreviewRect(frame, visibleFrame: vf, into: CGSize(width: Self.thumbSize, height: Self.thumbSize))
                        let cr = min(4, max(2, min(r.width, r.height) * 0.1))
                        let o = 1.0 - Double(index) * 0.1
                        RoundedRectangle(cornerRadius: cr, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.45 * o + 0.1),
                                        Color.accentColor.opacity(0.2 * o + 0.1),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: cr, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 0.8)
                            }
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                .frame(width: Self.thumbSize, height: Self.thumbSize)
                .clipped()

                Text(proposal.label)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.1)
                            : Color(.secondarySystemGroupedBackground).opacity(0.9)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(.separator).opacity(0.5),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var engineVisibleFrame: CGRect {
        switch proposal {
        case .cascade: return Self.engineFrameCascade
        case .tile: return Self.engineFrameTile
        }
    }

    private var panes: [CGRect] {
        let c = max(1, windowCount)
        let vf = engineVisibleFrame
        let raw: [CGRect] = {
            switch proposal {
            case .tile(let mode):
                return WindowLayoutEngine.slotRects(visibleFrame: vf, mode: mode, count: c)
            case .cascade:
                return WindowLayoutEngine.cascadeFrames(
                    visibleFrame: vf,
                    count: c,
                    insetStep: 22,
                    margin: 16
                )
            }
        }()
        if raw.isEmpty { return [vf] }
        return raw.map { r in
            r.insetBy(
                dx: r.width * Self.paneGutter,
                dy: r.height * Self.paneGutter
            )
        }
    }

    private func toPreviewRect(_ frame: CGRect, visibleFrame vf: CGRect, into size: CGSize) -> CGRect {
        let sx = size.width / max(vf.width, 0.0001)
        let sy = size.height / max(vf.height, 0.0001)
        return CGRect(
            x: (frame.minX - vf.minX) * sx,
            y: (vf.maxY - frame.maxY) * sy,
            width: frame.width * sx,
            height: frame.height * sy
        )
    }
}
