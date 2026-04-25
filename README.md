# Apple TV Remote

A macOS app that discovers and controls Apple TVs on the local network via the **Companion** and **Media Remote Protocol (MRP)** protocols. Includes a full-featured main window with device sidebar and remote control UI, and a scriptable `atv` CLI companion tool.

## Features

- **Menu bar app** — lives in the menu bar; popover remote for quick access
- **Main window** — collapsible device sidebar + remote control pane with D-pad, playback, volume, now-playing
- **App launcher** — browse and launch apps installed on the Apple TV
- **`atv` CLI** — scriptable control from the terminal or shell scripts
- **Auto-reconnect** — reconnects automatically when the Apple TV becomes reachable
- **Keyboard shortcuts** — `A` to open app grid, `R` to return to remote, arrow keys to navigate apps

## Requirements

- macOS 13+
- Xcode 26 / Swift 6
- Apple TV on the same local network

## Building

```bash
# Debug build (fast, for development)
swift build

# Release build (optimised, for daily use)
swift build -c release
```

### Installing after a release build

```bash
cp -f .build/release/AppleTVRemote /Applications/AppleTVRemote.app/Contents/MacOS/AppleTVRemote
cp -rf .build/release/AppleTVRemote_AppleTVRemote.bundle /Applications/AppleTVRemote.app/Contents/Resources/
cp -f .build/release/atv /usr/local/bin/atv
codesign --force --deep --sign - /Applications/AppleTVRemote.app
pkill -x AppleTVRemote   # then relaunch from /Applications
```

> **Note:** Always copy both the binary *and* the `.bundle` — the bundle contains
> bundled app icons and other resources that SwiftUI's `Bundle.module` reads at runtime.

## Pairing

Launch the app, select your Apple TV from the sidebar, and click **Connect**. The Apple TV will display a 4-digit PIN — enter it in the pairing dialog. Credentials are saved automatically.

```bash
# Or pair from the CLI
atv pair "Living Room"
```

## `atv` CLI Reference

```bash
# Discovery & setup
atv list               # list discovered Apple TVs
atv status             # connection state + now-playing
atv pair <name>        # pair with an Apple TV (prompts for PIN)
atv select <name>      # set default device for subsequent commands

# Navigation
atv u / d / l / r      # D-pad up / down / left / right
atv click              # D-pad centre (select)
atv menu               # menu / back
atv home               # home button
atv sl / sr / su / sd  # trackpad swipe left/right/up/down

# Playback & volume
atv pp                 # play/pause
atv vol+ / vol-        # volume up/down
atv power              # wake if asleep, sleep if on

# App launcher
atv apps               # list installed apps
atv launch <bundleID>  # launch an app by bundle ID

# Chaining
atv 3 r                # repeat right × 3
atv r u d              # right, then up, then down

# Standalone mode (no app required — connects directly)
atv --standalone apps
atv --standalone --device "Living Room" l
```

## Credential Storage

Pairing credentials (Ed25519 long-term key pair + Apple TV public key) are stored as JSON in:

```
~/Library/Application Support/AppleTVRemote/<device-id>.json         # Companion
~/Library/Application Support/AppleTVRemote/<device-id>.airplay.json # AirPlay
```

**Security note:** The Ed25519 private key (`ltsk`) is stored in plaintext.

## Architecture

| File | Role |
|------|------|
| `AppleTVRemoteApp.swift` | `@main` entry point; owns `DeviceDiscovery`, `AutoReconnector` |
| `AppleTVDevice.swift` | Device model, `ConnectionState`, `RemoteCommand` enums |
| `DeviceDiscovery.swift` | Bonjour browser (`_companion-link._tcp`) using `NWBrowser` |
| `ContentView.swift` | Root split layout (collapsible sidebar + detail) |
| `DeviceListView.swift` | Sidebar: device list, auto-connect toggles |
| `RemoteControlView.swift` | D-pad, playback, volume, now-playing card, app launcher toggle |
| `AppLauncherView.swift` | App grid with search, keyboard navigation, responsive columns |
| `MenuBarController.swift` | Menu bar status item, popover, right-click menu |
| `AppIconCache.swift` | Fetches and caches app icons from iTunes + bundled system icons |
| `Protocol/CompanionConnection.swift` | TCP Companion session: pair-setup, pair-verify, encrypted OPACK |
| `Protocol/OPACK.swift` | OPACK binary encoder/decoder |
| `Protocol/CredentialStore.swift` | JSON credential persistence |
| `AppleTVIPC/IPCProtocol.swift` | IPC protocol between app and `atv` CLI |

### Protocol overview

- Apple TVs advertise `_companion-link._tcp` via Bonjour; port is resolved dynamically
- Pairing: SRP-6a (HAP-style) + Ed25519 long-term keys, OPACK-framed
- Session: ChaCha20-Poly1305 encrypted OPACK frames over raw TCP
- App launcher: `FetchLaunchableApplicationsEvent` over the established Companion session
- AirPlay MRP tunnel: encrypted RTSP → DataStream → MRP protobuf for now-playing metadata

## Acknowledgements

This project would not have been possible without **[pyatv](https://github.com/postlund/pyatv)** by [Pierre Ståhl](https://github.com/postlund) and contributors.

pyatv is an open-source Python library that reverse-engineered and documented Apple's proprietary Apple TV protocols — including the Companion protocol, OPACK binary format, HAP-style pairing, and the AirPlay MRP tunnel. It served as the primary protocol reference throughout the development of this project.

We are deeply grateful to the pyatv team for their meticulous work documenting undocumented protocols and making that knowledge freely available.

> pyatv is licensed under the MIT License.
> https://github.com/postlund/pyatv
