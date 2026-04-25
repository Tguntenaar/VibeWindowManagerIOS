//
//  BridgeConnectionView.swift
//  VibeWindowManagerIOS
//
//  Pre-connection: connect to the Mac bridge (Tailnet or host:port).
//

import SwiftUI

/// Polished first-run and settings-sheet UI for bridge connection.
struct BridgeConnectionView: View {
    @ObservedObject var bridge: BridgeClient
    @Binding var hostPort: String
    var openAppSettings: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ConnectionBackdrop()
                .ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 28)

                statusPill
                    .padding(.bottom, 20)

                if !bridge.lastActionNote.isEmpty {
                    Text(bridge.lastActionNote)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.bottom, 12)
                }

                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Tailscale", systemImage: "network")
                    tailnetCard
                }
                .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Direct", systemImage: "cable.connector")
                    directCard
                }
                .padding(.bottom, 20)

                tipRow
                    .padding(.bottom, 8)

                Text("When connected: tap a window to focus on the Mac; drag to move, corner handle to resize.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.32))
                    .padding(.bottom, 4)

                settingsRow

                if let lastError = bridge.lastError {
                    errorBanner(lastError)
                        .padding(.top, 16)
                }

                if !bridge.transcribeLast.isEmpty || bridge.transcribeError != nil {
                    Text(bridge.transcribeLast + (bridge.transcribeError.map { " (\($0))" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 12)
                }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.2, green: 0.45, blue: 0.95).opacity(0.35),
                                Color(red: 0.5, green: 0.25, blue: 0.9).opacity(0.25),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    }
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 26, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.92))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("VibeWindowManager")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Mirror your Mac’s window layout. Start the bridge on the Mac, then connect.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Status

    private var statusPill: some View {
        HStack(spacing: 10) {
            if bridge.isAttemptingTailnet {
                ProgressView()
                    .tint(.white.opacity(0.85))
                    .scaleEffect(0.9)
            } else {
                statusDot
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.status)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let target = bridge.currentTarget {
                    Text(target)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(bridgeStatusColor)
            .frame(width: 8, height: 8)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            }
    }

    private var bridgeStatusColor: Color {
        if bridge.hasActiveLayoutSession { return Color(red: 0.2, green: 0.85, blue: 0.45) }
        if bridge.currentTarget != nil { return Color.orange.opacity(0.9) }
        return Color.white.opacity(0.35)
    }

    // MARK: - Sections

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            .labelStyle(.titleAndIcon)
    }

    private var tailnetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MagicDNS name or short hostname (port 19842 if omitted)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            ThemedTextField(placeholder: "e.g. laptop.tailxxxx.ts.net", text: $bridge.preferredTailnetHost)
            Button {
                bridge.connectTailnet(host: bridge.preferredTailnetHost)
            } label: {
                Text("Connect via Tailscale")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(bridge.preferredTailnetHost.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(bridge.preferredTailnetHost.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(16)
        .cardBackground()
    }

    private var directCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tailnet 100.x or LAN 192.168.x — always include :19842 if not default")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            ThemedTextField(placeholder: "192.168.1.5:19842 or ws://…", text: $hostPort)
            HStack(spacing: 12) {
                Button {
                    bridge.connect(hostOrURL: hostPort)
                } label: {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    bridge.disconnect()
                } label: {
                    Text("Disconnect")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .cardBackground()
    }

    private var tipRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.caption)
                .foregroundStyle(Color(red: 0.95, green: 0.8, blue: 0.35).opacity(0.85))
            Text("On the Mac: start the bridge in VibeWindowManager (port 19842, path /bridge). Use Tailscale on both devices for MagicDNS.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var settingsRow: some View {
        Button {
            openAppSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                Text("iOS app settings (local network, etc.)")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                Text("Connection error")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
            Button("Dismiss") { bridge.clearError() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.9, green: 0.2, blue: 0.15).opacity(0.12))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        }
    }
}

// MARK: - Themed text field

private struct ThemedTextField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
    }
}

// MARK: - Card chrome

private extension View {
    func cardBackground() -> some View {
        background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
    }
}

// MARK: - Button styles

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.25, green: 0.55, blue: 1),
                                Color(red: 0.35, green: 0.4, blue: 0.95),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(configuration.isPressed ? 0.85 : 1)
            }
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.85))
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
            }
    }
}

// MARK: - Backdrop (full-bleed behind scroll content)

private struct ConnectionBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.1),
                    Color(red: 0.01, green: 0.02, blue: 0.05),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [
                    Color(red: 0.2, green: 0.35, blue: 0.85).opacity(0.14),
                    Color.clear,
                    Color(red: 0.55, green: 0.2, blue: 0.75).opacity(0.1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.3, green: 0.55, blue: 1).opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
        }
    }
}
