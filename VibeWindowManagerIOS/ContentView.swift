//
//  ContentView.swift
//  VibeWindowManagerIOS
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var bridge = BridgeClient()
    @AppStorage("bridgeHostPort") private var hostPort: String = ""

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let L = bridge.layout, !L.windows.isEmpty {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    ForEach(L.windows) { win in
                        let selected = (win.id == (L.selectedId ?? ""))
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.white, lineWidth: selected ? 3 : 1)
                            )
                            .frame(width: w * win.rect.width, height: h * win.rect.height)
                            .position(
                                x: w * (win.rect.x + win.rect.width / 2),
                                y: h * (win.rect.y + win.rect.height / 2)
                            )
                    }
                }
            } else {
                Text(bridge.status)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(bridge.status)
                    .font(.caption.monospaced())
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                if let currentTarget = bridge.currentTarget {
                    Text("Target: \(currentTarget)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !bridge.lastActionNote.isEmpty {
                    Text(bridge.lastActionNote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Refresh discovery") { bridge.startBrowsing(userInitiated: true) }
                        Button("Auto-connect now") { bridge.autoConnectNow() }
                        Button("Open Settings") { openAppSettings() }
                    }
                    HStack {
                        Text("Auto-connect: \(bridge.isAutoConnectEnabled ? "on" : "off")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Discovered Macs: \(bridge.discoveredServices.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !bridge.discoveredServices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nearby Macs")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(bridge.discoveredServices) { service in
                            Button {
                                hostPort = service.hostPort
                                bridge.connect(discovered: service)
                            } label: {
                                HStack {
                                    Text(service.name)
                                    Spacer()
                                    Text(service.hostPort)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } else {
                    Text("If nothing shows up: make sure the Mac bridge is on, both devices are on the same LAN, and this app has Local Network permission. Use Open Settings if iOS already denied it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Manual connect: on the Mac, start the bridge, then use your Mac’s LAN address with port 19842 (e.g. 192.168.x.x:19842). Check Mac → System Settings → Network, or in Terminal: ipconfig getifaddr en0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                HStack {
                    TextField("Mac host:port", text: $hostPort)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button("Connect") { bridge.connect(hostOrURL: hostPort) }
                    Button("Disconnect") { bridge.disconnect() }
                }
                HStack {
                    Button("Next window") { bridge.sendSelectNext() }
                    Button("Test paste: hi") { bridge.sendPaste("hi from iPhone\n") }
                    Button("STT end (test)") { bridge.sendTranscribeEndTest() }
                }
                if let lastError = bridge.lastError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Connection / discovery error")
                            .font(.caption.weight(.semibold))
                        Text(lastError)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        Button("Clear error") { bridge.clearError() }
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.red.opacity(0.55), lineWidth: 1)
                    )
                }
                if !bridge.transcribeLast.isEmpty || bridge.transcribeError != nil {
                    Text(bridge.transcribeLast + (bridge.transcribeError.map { " (\($0))" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            bridge.startBrowsing()
            bridge.enableAutoConnect()
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

#Preview {
    ContentView()
}
