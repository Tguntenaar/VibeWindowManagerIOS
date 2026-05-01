//
//  MirrorAppPickerGrid.swift
//  VibeWindowManagerIOS
//
//  Shared “pick which Mac app to mirror” grid for the full-screen overlay and for sheets
//  (e.g. RemoteLayoutPanel).
//

import SwiftUI
import UIKit

struct MirrorAppPickerGrid: View {
    let apps: [BridgeMirrorAppEntry]
    let currentBundleId: String?
    let onPick: (String) -> Void
    var style: Style = .formSheet

    /// Dark translucent UI on top of the mirror; standard grouped look inside navigation sheets.
    enum Style: Sendable {
        case formSheet
        case overlayDark
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12, alignment: .top)]
    }

    var body: some View {
        Group {
            if apps.isEmpty {
                emptyText
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, alignment: .center, spacing: 14) {
                        ForEach(apps) { app in
                            Button {
                                onPick(app.bundleId)
                            } label: {
                                VStack(spacing: 8) {
                                    appIconView(app)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    Text(app.name)
                                        .font(.caption)
                                        .foregroundStyle(nameColor)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(minHeight: 32, alignment: .top)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(cellBackground(isSelected: isSelected(app)))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var nameColor: Color {
        switch style {
        case .formSheet: return .primary
        case .overlayDark: return .white
        }
    }

    @ViewBuilder
    private var emptyText: some View {
        switch style {
        case .formSheet:
            Text(
                "No apps listed yet — they load from your Mac. Start an app on the Mac and pull to refresh the connection, or try again in a few seconds."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .overlayDark:
            Text("No apps listed yet — they appear when the Mac bridge sends the app list. Start an app on the Mac if the list is empty.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isSelected(_ app: BridgeMirrorAppEntry) -> Bool {
        guard let c = currentBundleId else { return false }
        return c == app.bundleId
    }

    private func cellBackground(isSelected: Bool) -> Color {
        switch style {
        case .formSheet:
            return isSelected
                ? Color.accentColor.opacity(0.22)
                : Color(.secondarySystemGroupedBackground)
        case .overlayDark:
            return isSelected
                ? Color.accentColor.opacity(0.4)
                : Color.white.opacity(0.1)
        }
    }

    @ViewBuilder
    private func appIconView(_ app: BridgeMirrorAppEntry) -> some View {
        if let b64 = app.iconPNGBase64,
            let data = Data(base64Encoded: b64),
            let ui = UIImage(data: data)
        {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "app.fill")
                .font(.title)
                .foregroundStyle(placeholderIconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(placeholderIconBackground)
                )
        }
    }

    private var placeholderIconColor: Color {
        switch style {
        case .formSheet: return .secondary
        case .overlayDark: return .white.opacity(0.9)
        }
    }

    private var placeholderIconBackground: Color {
        switch style {
        case .formSheet: return Color(.tertiarySystemFill)
        case .overlayDark: return Color.white.opacity(0.12)
        }
    }
}
