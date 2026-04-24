# VibeWindowManager (iOS)

**VibeWindowManager** for **iPhone and iPad** is the remote companion to the [macOS VibeWindowManager](https://github.com/Tguntenaar/VibeWindowManager) app. It shows a **live, normalized map of your Mac’s window layout**, lets you **cycle focus and drive actions** supported by the bridge, and is intended to grow with features such as **push-to-talk** audio routing to the Mac. It is **not** a replacement for the Mac app: **Accessibility, layout computation, and the WebSocket server run on the Mac.**

## What you get

- Full-screen **layout mirror** (black background, per-window outlines) when connected.
- **Bridge settings** (gear): discovery, connect, and debug actions in a sheet so the mirror is not covered by setup UI.
- **Three ways to connect** (see below): Tailnet, Bonjour, or manual address.

## Requirements

- **Xcode** with an iOS SDK matching this project’s deployment target (see the Xcode project settings).
- A Mac running **VibeWindowManager** with the **bridge** enabled; see the [macOS README](https://github.com/Tguntenaar/VibeWindowManager#quick-start-bridge--ios).
- On the device: **local network** permission when iOS asks, so Bonjour and LAN WebSockets can work.

## Connect to your Mac (order of attempts)

1. **Tailnet** — Enter your Mac’s **Tailscale MagicDNS** hostname (e.g. `my-mac.tail…ts.net` or the short name). The app opens `ws://<host>:19842/bridge` and falls back to Bonjour after a short wait if no layout arrives. **Tailscale** must run on the iPhone and the Mac, with **MagicDNS** available on the phone.
2. **Bonjour** — Browses `_vibewm._tcp` and lists Macs on the same LAN; tap one to connect.
3. **Manual** — Enter `IP:port` (default port `19842`; the client adds the `/bridge` path).

The Mac app’s bridge UI shows a **Copy** action for the Tailnet hostname when the Tailscale CLI is available. **Tailnet is optional**; same-Wi‑Fi **Bonjour** is enough for many setups.

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
