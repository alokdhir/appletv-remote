# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Communication style

Short sentences. Only necessary words. No preamble, no recap, no filler.

## Git commits

Do NOT add "Assisted-by", "Co-Authored-By", or any attribution lines to commit messages.

## Building

```bash
swift build          # debug build
swift build -c release
swift test           # run tests (AppleTVProtocolTests, AppleTVIPCTests)
```

The project requires macOS 13+ and Xcode 26.

Swift toolchain is 6.x but the language mode is **Swift 5** — Package.swift
uses `swift-tools-version: 5.9`, and `project.yml` sets `SWIFT_VERSION: "5.0"`
so xcodebuild matches. Don't bump to Swift 6 mode without auditing deinits
(AutoReconnector, WindowManagement) and AsyncPublisher sites (IPCServer) —
they trigger strict-concurrency errors only the Swift 6 mode catches.

## Releasing

Distribution is automated. Don't hand-roll codesign/notarization flows.

```bash
# Build signed + notarized DMG (no upload).
scripts/build-dmg.sh

# Full pipeline: tag, build, push, attach to GitHub release.
scripts/release.sh v1.2.0
```

`build-dmg.sh` auto-detects the Developer ID Application identity and the
`appletv-remote-notarization` notarytool keychain profile. First-time setup
(generating the cert, creating an app-specific password, calling
`xcrun notarytool store-credentials`) lives in the script header.

## Install paths

Production binaries (what actually runs for the user):

- App: `/Applications/AppleTVRemote.app/Contents/MacOS/AppleTVRemote`
- CLI: `/usr/local/bin/atv`

`swift build` writes to `.build/{debug,release}/` — it does NOT install.
After building, copy binaries into place and restart the app:

```bash
swift build -c release
cp -f .build/release/AppleTVRemote /Applications/AppleTVRemote.app/Contents/MacOS/AppleTVRemote
cp -rf .build/release/AppleTVRemote_AppleTVRemote.bundle /Applications/AppleTVRemote.app/Contents/Resources/
cp -f .build/release/atv /usr/local/bin/atv
pkill -x AppleTVRemote   # user relaunches from /Applications
```

If a test seems to contradict recent code changes, verify the running binary
is fresh (`ps -o lstart= -p $(pgrep -x AppleTVRemote)` vs. mtime of the app
binary) before debugging further — stale installs are the usual culprit.

## Architecture

This is a SwiftUI macOS app that discovers and controls Apple TVs on the local network via the **Companion protocol** (`_companion-link._tcp`).

### Targets

| Target | Role |
|--------|------|
| `AppleTVRemote` | SwiftUI app |
| `atv` | CLI |
| `AppleTVProtocol` | Core protocol library — testable, no UI dependencies |
| `AppleTVIPC` | IPC wire types shared between app and CLI |
| `AppleTVLogging` | `os.Logger` instances |

**External dependency:** `BigInt` (attaswift/BigInt) — arbitrary-precision integers for SRP-6a big-number math.

### Source files (`Sources/atv/`)

| File | Role |
|------|------|
| `main.swift` | CLI entry point; routes commands over the IPC Unix socket to the running app |
| `Standalone.swift` | `--standalone` mode: connects directly via Companion without the app |

### Source files (`Sources/AppleTVRemote/`)

| File | Role |
|------|------|
| `AppleTVRemoteApp.swift` | `@main` SwiftUI entry point |
| `DeviceDiscovery.swift` | Bonjour browser (`_companion-link._tcp`) using `NWBrowser` |
| `CompanionConnection.swift` | App-layer orchestrator: TCP connect/disconnect, WoL, pairing delegation, `@Published` state for SwiftUI |
| `ContentView.swift` | Root split layout (sidebar + detail) |
| `DeviceListView.swift` | Sidebar: discovered device list |
| `RemoteControlView.swift` | D-pad, playback, volume, now-playing card |
| `AppLauncherView.swift` | App grid with search, keyboard navigation, responsive columns |
| `MenuBarController.swift` | Menu bar status item, popover, right-click menu |
| `AppIconCache.swift` | Fetches and caches app icons from iTunes + bundled system icons |
| `KeyboardNotificationManager.swift` | Manages keyboard-input notifications for Apple TV remote requests |
| `PopoverActivationGuard.swift` | Suppresses the first tap that activates the popover window |
| `VisualEffectBackground.swift` | NSVisualEffectView wrapper for SwiftUI translucency |
| `IPCServer.swift` | Unix socket IPC server for `atv` CLI |
| `AutoReconnector.swift` | Watches for unexpected disconnects and retries |
| `WindowManagement.swift` | NSWindow setup: translucency, focus-fade, hide-on-close |

### Source files (`Sources/AppleTVProtocol/`)

| File | Role |
|------|------|
| `AppleTVDevice.swift` | Device model, `ConnectionState`, `RemoteCommand` enums |
| `CompanionSession.swift` | Live session: socket I/O, frame dispatch, keepalive, txn/callbacks, all feature send methods |
| `CompanionFrame.swift` | Wire frame encode/decode |
| `CompanionPairVerify.swift` | HAP pair-verify over Companion protocol framing |
| `PairingFlow.swift` | Pair-setup (SRP-6a) state machine |
| `EncryptedFrameTransport.swift` | ChaCha20-Poly1305 seal/open for E_OPACK frames |
| `OPACK.swift` | OPACK serialization (Apple's binary dict format) |
| `MRPDecoder.swift` | Decodes MRP now-playing protobuf messages |
| `MRPMessage.swift` | Constructs MRP wire messages (varint-length-prefixed protobuf frames) |
| `MRPDataChannel.swift` | MRP data channel over AirPlay connection |
| `AirPlayTunnel.swift` | AirPlay MRP tunnel for real-time now-playing |
| `AirPlayHTTP.swift` | Minimal HTTP/1.1 client for AirPlay long-lived TCP connections |
| `AirPlayPairing.swift` | AirPlay pair-setup and pair-verify (SRP + TLV8) |
| `AirPlayEventChannel.swift` | AirPlay event channel over established session |
| `EncryptedAirPlayRTSP.swift` | RTSP-over-ChaCha20-Poly1305 transport post pair-verify |
| `HAPPairing.swift` / `SRPClient.swift` | HAP pairing crypto |
| `HAPSession.swift` | Bidirectional ChaCha20-Poly1305 frame codec for AirPlay sockets |
| `TLV8.swift` | HAP TLV8 encoder/decoder |
| `CredentialStore.swift` | Pairing credentials persisted as JSON in Application Support |
| `MACStore.swift` | Persists Apple TV MAC addresses for Wake-on-LAN when device is asleep |
| `WakeOnLAN.swift` | Magic packet broadcast |
| `RTITextOperations.swift` | RTI binary plist encoder for text input |
| `BinaryPlist.swift` | Minimal binary plist (bplist00) writer for NSKeyedArchiver UID references |
| `CryptoUtils.swift` | Shared crypto utilities (Data extensions) |
| `PrimaryInterface.swift` | Resolves the primary network interface for socket binding |

### Key protocol notes

- Apple TVs advertise `_companion-link._tcp` via Bonjour; port is resolved dynamically
- Companion protocol uses raw BSD sockets (bypasses NWConnection TCC restrictions on macOS 14+)
- Pairing uses SRP-6a (pair-setup) + ECDH (pair-verify); ATV displays a 4-digit PIN
- Post-pairing frames are ChaCha20-Poly1305 encrypted E_OPACK
- `CompanionSession` is the testable core; `CompanionConnection` is this app's SwiftUI wrapper around it
- Reference implementation: [pyatv](https://github.com/postlund/pyatv) (`pyatv/protocols/companion/`)

## Issue tracking

This project uses **bd (beads)** for all issue tracking. Do NOT create markdown TODO lists. Run `bd prime` for full workflow context.

```bash
bd ready                    # find available work
bd show <id>                # view issue details
bd update <id> --claim      # claim work atomically
bd close <id>               # complete work
```

- Use `bd` for ALL task tracking — do NOT use markdown TODO lists
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Shell safety

Always use non-interactive flags to avoid hanging on confirmation prompts:
- `cp -f`, `mv -f`, `rm -f`, `rm -rf`

## Git

**NEVER push to remote unless the user explicitly asks.** Commit freely, but do not run `git push` without a direct instruction to do so.
