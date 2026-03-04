# Companion Xcode

An iOS + macOS companion app that mirrors the Xcode Simulator screen to an iPhone, with full touch forwarding, terminal access, file browsing, and remote build triggering.

## Features

- **Simulator Mirroring** — Live MJPEG stream of the Xcode Simulator on your iPhone
- **Touch Forwarding** — Tap on your iPhone to control the Simulator
- **Terminal Access** — Full xterm.js terminal with TUI support (Claude Code, vim, htop, etc.)
- **Remote Builds** — Trigger `xcodebuild` / `xcrun simctl` from your iPhone
- **Local & Remote** — Works on the same Wi-Fi (Bonjour) or over the internet via WebSocket relay

## Architecture

### SimulatorMirror (iOS app)
- SwiftUI with `@Observable` state management
- Tabs: Simulator, Session (Claude + Terminal), Build, Settings
- MJPEG client for live screen stream
- xterm.js terminal in WKWebView with WebGL renderer

### SimulatorMirrorServer (macOS menu bar app)
- HTTP server on port 8080 — MJPEG stream + touch/action endpoints
- WebSocket terminal server on port 8081 — PTY shell sessions
- ScreenCaptureKit for simulator window capture
- Bonjour service advertising for local discovery

### Relay Server
- Node.js WebSocket relay hosted on Fly.io
- Enables Mac ↔ iPhone communication outside local network
- Alternative Cloudflare Workers implementation included

## Requirements

- **iOS app**: iPhone, iOS 17+
- **macOS server**: Mac with Xcode installed, macOS 14+
- **Xcode 16** for building the project

## Getting Started

1. Open `SimulatorMirror.xcodeproj` in Xcode
2. Build and run **SimulatorMirrorServer** on your Mac
3. Build and run **SimulatorMirror** on your iPhone
4. The iPhone will auto-discover the Mac on the same Wi-Fi via Bonjour
5. For remote access, configure the relay Room ID in Settings

## Development Notes

- New Swift files are auto-included via `PBXFileSystemSynchronizedRootGroup` — no `project.pbxproj` edits needed
- `FrameBuffer` is an `actor` — always `await` its methods
- Terminal `fitAddon.fit()` must be called exactly once — multiple calls cause WebGL rendering artifacts on iOS 3x displays
- Free Apple Developer account — CloudKit/iCloud features are disabled
