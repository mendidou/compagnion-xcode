# SimulatorMirror

iOS + macOS companion app that mirrors the Xcode Simulator screen to an iPhone, with full touch forwarding, terminal access, file browsing, and remote build triggering.

## Project Structure

Two Xcode targets in one project (Xcode 16, `PBXFileSystemSynchronizedRootGroup` — new files auto-included, no need to edit `project.pbxproj`):

### SimulatorMirror (iOS app — iPhone)
- **Bundle ID**: `SimulatorMirror.SimulatorMirror`
- **Tabs**: Simulator (MJPEG viewer + touch), Session (Claude web + Terminal), Build, Settings
- **Architecture**: `@Observable` + `@Environment` for state sharing (no ObservableObject/Combine)
- **Key classes**:
  - `AppSettings` — `@Observable`, stores server IP/port, SSH config, relay settings
  - `RelayManager` — `@Observable @MainActor`, manages iOS WebSocket relay connection
  - `TerminalSessionManager` — `@Observable`, manages terminal sessions
  - `TerminalViewController` — UIKit VC hosting WKWebView with xterm.js terminal
  - `MJPEGClient` — streams JPEG frames from Mac server

### SimulatorMirrorServer (macOS menu bar app)
- **Bundle ID**: `SimulatorMirror.SimulatorMirrorServer`
- **Architecture**: `StatusBarController` manages menu bar, starts/stops services
- **Key classes**:
  - `HTTPServer` — Network.framework `NWListener` on port 8080 (MJPEG stream, touch/actions endpoints)
  - `TerminalServer` — WebSocket on port 8081, spawns PTY shell sessions
  - `ScreenCaptureManager` — ScreenCaptureKit, captures simulator window
  - `FrameBuffer` — `actor`, `makeStream()` returns `(AsyncStream<Data>, UUID)`
  - `RelayClient` — outbound WebSocket to relay server for remote access
  - `BuildManager` — runs `xcrun simctl` / `xcodebuild` for remote builds

### relay-server/ (Node.js — Fly.io)
- WebSocket relay for Mac↔iOS when not on same network
- Deployed at `wss://simulatormirror-relay.fly.dev` (Frankfurt)
- Redeploy: `cd relay-server && fly deploy`

### relay-worker/ (Cloudflare Workers + Durable Objects)
- Alternative relay implementation (production-grade)

## Key Technical Details

### Terminal (xterm.js in WKWebView)
- **Renderer**: WebGL (`@xterm/addon-webgl`) with `customGlyphs` — draws box-drawing chars at exact cell widths, fixing TUI alignment on iOS
- **Font scaling**: auto-calculates font size (7–14px) to guarantee 80 columns minimum
- **Keyboard handling**: Native `keyboardLayoutGuide` resizes WKWebView; terminal sized to 55% of viewport height so content is never hidden behind keyboard
- **CRITICAL**: `fitAddon.fit()` must be called exactly ONCE on page load. Multiple calls cause WebGL subpixel line artifacts on iOS 3x displays. `fitTerminal()` is intentionally a no-op.
- **Accessory bar**: Native UIView with terminal keys (esc, ctrl toggle, tab, arrows, ^C, ^D, ^Z, ^L, |, ~, -, /)
- **Server PTY**: Sets `TERM=xterm-256color` and `COLORTERM=truecolor` for full TUI support

### Relay Protocol
- **WebSocket**: `wss://<host>/ws?room=<uuid>&role=<mac|ios>`
- **Binary messages**: Raw JPEG frames (Mac → relay → iOS)
- **Text messages**: JSON for HTTP proxy requests/responses and WebSocket tunnel control
- **Pairing**: Manual — Mac "Copy Room ID" → paste into iOS Settings "Room ID"
- **Local mode guard**: Relay doesn't attempt connection when local Bonjour server is discovered

### Networking
- **Bonjour**: `_simulatormirror._tcp` for local discovery
- **Local MJPEG**: `http://<ip>:8080/stream`
- **Both local and relay run in parallel**: `useRelay` activates only when local delivers no frames

## Pitfalls & Gotchas

### Terminal — DO NOT:
- Call `fitAddon.fit()` more than once — causes white horizontal lines on iOS 3x (WebGL canvas resize artifacts). `fitTerminal()` is a no-op on purpose.
- Add HTML-side keyboard handling (`visualViewport`, `position: fixed`, shift-up) — conflicts with native `keyboardLayoutGuide`. Let Swift handle keyboard.
- Use the DOM renderer for TUI apps — box-drawing characters render at wrong widths. WebGL with `customGlyphs` is required.
- Use `unicode11` addon — causes character width mismatch.
- Resize the terminal after initial fit — any `term.resize()` or repeated `fit()` triggers lines.

### Terminal — DO:
- Pre-calculate font size with DOM measurement before creating Terminal
- Size the terminal container to ~55% of viewport height before fitting (keyboard-safe)
- Keep `fitTerminal()` as a no-op in terminal.html
- Set `TERM=xterm-256color` and `COLORTERM=truecolor` in the server PTY environment

### Relay — DO NOT:
- Set `RelayManager.isConnected = true` before first successful receive
- Auto-start relay when local Bonjour server is discovered
- Let `RelayClient` retry indefinitely — cap at 3 consecutive failures

### General:
- `PBXFileSystemSynchronizedRootGroup` means new Swift files are auto-included — no pbxproj edits needed
- `FrameBuffer` is an actor — always `await` its methods
- `RelayManager` is `@MainActor` — UI updates are safe but call from main thread
- `CloudKitPublisher.swift` / `CloudKitDiscovery.swift` exist but are dead code (free dev account limitation)

## Development Notes

- **Team**: `HV66MCNZGJ` (free Apple Developer account)
- **No iCloud/CloudKit**: Free account doesn't support it. `CloudKitPublisher.swift` and `CloudKitDiscovery.swift` exist on disk but are NOT called
- **SourceKit errors**: When analyzing iOS files outside the iOS target context, SourceKit may report false positives
- **FrameBuffer**: Is an `actor` — access with `await`
- **RelayManager.frameStream**: Single-consumer `AsyncStream` — cancel old Task before starting new one
