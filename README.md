# VibeWindowManagerIOS

iOS (iPhone / iPad) app for the **remote side** of VibeWindowManager: landscape layout map, window selection, and (planned) push-to-talk audio to the Mac. It is **not** a standalone replacement for the macOS app.

## macOS app (bridge + window control)

Clone **[VibeWindowManager](../VibeWindowManager)** next to this repo if you use the default relative path. On the Mac, open `VibeWindowManager.xcodeproj`.

Protocol and design notes (shared across both codebases) live in the Mac repo:

- [`../VibeWindowManager/docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md`](../VibeWindowManager/docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md)
- [`../VibeWindowManager/docs/CLI.md`](../VibeWindowManager/docs/CLI.md) — what the Mac app can already do with Ghostty and other apps

Implement new **client** behavior here; implement the **server** (Bonjour, WebSocket, STT) in `VibeWindowManager` unless you later extract a small Swift package for shared types.

**Cursor rule:** [`.cursor/rules/vibewindowmanagerios-device.mdc`](.cursor/rules/vibewindowmanagerios-device.mdc) — run and test on a **physical iPhone**; simulator is OK for **compile-only** `build` checks.

**Connect:** The iOS app browses `_vibewm._tcp` automatically and lists nearby Macs on the same LAN; tap one to connect. Manual fallback still works by entering `IP:port` (default port `19842`, path `/bridge` is added automatically). The Mac app must have **Bridge server on**.
