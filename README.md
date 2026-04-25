# VibeWindowManager (iOS)

**VibeWindowManager** for **iPhone and iPad** is the remote companion to the [macOS VibeWindowManager](https://github.com/Tguntenaar/VibeWindowManager) app. It shows a **live, normalized map of your Mac’s window layout**, lets you **cycle focus and drive actions** supported by the bridge, and is intended to grow with features such as **push-to-talk** audio routing to the Mac. It is **not** a replacement for the Mac app: **Accessibility, layout computation, and the WebSocket server run on the Mac.**

## What you get

- Full-screen **layout mirror** (black background, per-window outlines) when connected.
- **Bridge settings** (gear): connect and debug actions in a sheet so the mirror is not covered by setup UI.
- **Two ways to connect** (see below): Tailnet hostname or manual `host:port` / `ws://` URL.
- **Tmux buffer** (toolbar text icon when mirroring): read scrollback/visible text from a tmux pane on the Mac (`requestTmuxPane` / `tmuxPane` in the protocol). Configure the **tmux target** on the Mac; see the [macOS README](https://github.com/Tguntenaar/VibeWindowManager#tmux-buffer-on-ipad-optional).

## Requirements

- **Xcode** with an iOS SDK matching this project’s deployment target (see the Xcode project settings).
- A Mac running **VibeWindowManager** with the **bridge** enabled; see the [macOS README](https://github.com/Tguntenaar/VibeWindowManager#quick-start-bridge--ios).
- On the device: **local network** permission when iOS asks, so WebSockets to your Mac (LAN or tailnet addresses) can work.
- The app uses **`ws://` (cleartext)** to your Mac; the target merges `Info-Plist-ATS.plist` with `NSAppTransportSecurity` / `NSAllowsArbitraryLoads` so iOS does not block those URLs. For App Store review, you may need to document this or narrow exceptions later.

## Connect to your Mac

1. **Tailnet** — Enter your Mac’s **Tailscale MagicDNS** hostname (e.g. `my-mac.tail…ts.net`). The app opens `ws://<host>:19842/bridge` (override with `host:port` in the field if needed). **Tailscale** must run on the iPhone and the Mac, with **MagicDNS** resolving the hostname on the phone. A **Connect via Tailnet** attempt times out after a few seconds if no `layout` arrives.
2. **Manual** — Enter `IP:port` (default port `19842` on the Mac; the client adds the `/bridge` path unless you pass a full `ws://` URL). Use your tailnet `100.x.x.x` or LAN `192.168.x.x` as needed.

The Mac app’s bridge UI may show a **Copy** action for the Tailnet hostname when the Tailscale CLI is available.

## Documentation (shared with the Mac repo)

| Doc | Description |
|-----|-------------|
| [macOS `docs/PROTOCOL.md`](https://github.com/Tguntenaar/VibeWindowManager/blob/main/docs/PROTOCOL.md) | WebSocket and JSON message formats |
| [macOS `docs/CLI.md`](https://github.com/Tguntenaar/VibeWindowManager/blob/main/docs/CLI.md) | What the Mac app and `windows` CLI can do today |
| [macOS `docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md`](https://github.com/Tguntenaar/VibeWindowManager/blob/main/docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md) | Rationale: transport, STT location, phases |

**Contributing / layout:** add **iOS** UI and client behavior in this repository; implement **server** and bridge changes in the [macOS project](https://github.com/Tguntenaar/VibeWindowManager). Protocol changes should be documented in `PROTOCOL.md` on the Mac side first.

## Related repository

- **[VibeWindowManager (macOS)](https://github.com/Tguntenaar/VibeWindowManager)** — Window layout engine, bridge server, and CLI.

If you keep both checkouts as sibling folders, local links like `../VibeWindowManager` still work in development.
