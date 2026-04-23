# appletv-remote

SwiftUI macOS app that discovers and controls Apple TVs on the local network via the **Companion** and **Media Remote Protocol (MRP)** protocols.

## Requirements

- macOS 13+
- Xcode 26 / Swift 6
- Apple TV on the same local network

## Building

```bash
swift build          # debug build
swift build -c release
```

## Usage

Launch the app; it discovers Apple TVs via Bonjour (`_companion-link._tcp`). Select a device and pair — the Apple TV will display a PIN. After pairing, the remote control UI becomes active.

The `atv` CLI tool (built alongside the app) provides scriptable control:

```bash
atv list               # list discovered Apple TVs
atv status             # connection state + now-playing
atv pair <name>        # pair with an Apple TV (prompts for PIN)
atv select <name>      # set default device
atv u / d / l / r      # D-pad up / down / left / right
atv click              # D-pad centre
atv pp                 # play/pause
atv menu               # menu / back
atv home               # home button
atv vol+ / vol-        # volume
atv sl / sr / su / sd  # trackpad swipe
atv power              # wake if asleep, sleep if on
atv 3 r                # repeat right × 3
atv --verbose pair <name>  # show all debug output on stderr
```

## Credential Storage

Pairing credentials (Ed25519 long-term key pair + Apple TV public key) are stored as JSON files in:

```
~/Library/Application Support/AppleTVRemote/<device-id>.json        # Companion
~/Library/Application Support/AppleTVRemote/<device-id>.airplay.json # AirPlay
```

**Why not Keychain?** The app is unsigned for local development. macOS requires a provisioning profile and entitlements to access the Keychain from command-line tools — adding that overhead was not worth it for a personal dev tool. The JSON files are `0600`-equivalent (user-only) by default via `NSFileManager`.

**Security note:** The Ed25519 private key (`ltsk`) is stored in plaintext in these files. Anyone with read access to your home directory can extract it. For a production app, migrate to Keychain using `SecItemAdd`/`SecItemCopyMatching` with `kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

To revoke access, delete the credential files or use `atv unpair <device-id>`.

**ATV signature verification** is skipped during pair-verify (Companion M2 and AirPlay M6). A MITM on your LAN could intercept pairing. Relevant if you're paranoid; irrelevant if you're on a home network.

## Architecture

| File | Role |
|------|------|
| `AppleTVRemoteApp.swift` | `@main` entry point; owns `DeviceDiscovery`, `AutoReconnector` |
| `AppleTVDevice.swift` | Device model, `ConnectionState`, `RemoteCommand` enums |
| `DeviceDiscovery.swift` | Bonjour browser using `NWBrowser` |
| `ContentView.swift` | Root split layout (sidebar + detail) |
| `DeviceListView.swift` | Sidebar: device list, auto-connect toggles |
| `RemoteControlView.swift` | D-pad, playback, volume, now-playing card |
| `Protocol/CompanionConnection.swift` | TCP Companion session: pair-setup, pair-verify, OPACK commands |
| `Protocol/CredentialStore.swift` | JSON credential persistence in Application Support |

### Protocol overview

- Apple TVs advertise `_companion-link._tcp` via Bonjour; port is resolved dynamically
- Pairing: SRP-6a (HAP-style) + Ed25519 long-term keys
- Session: ChaCha20-Poly1305 encrypted OPACK frames
- AirPlay MRP tunnel: encrypted RTSP → DataStream → MRP protobuf messages
- Reference: [pyatv](https://github.com/postlund/pyatv)
