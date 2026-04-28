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

### Source files (`Sources/AppleTVRemote/`)

| File | Role |
|------|------|
| `AppleTVRemoteApp.swift` | `@main` SwiftUI entry point |
| `CompanionConnection.swift` | App-layer orchestrator: TCP connect/disconnect, WoL, pairing delegation, `@Published` state for SwiftUI |
| `ContentView.swift` | Root split layout (sidebar + detail) |
| `DeviceListView.swift` | Sidebar: discovered device list |
| `RemoteControlView.swift` | D-pad, playback, volume, now-playing card |
| `IPCServer.swift` | Unix socket IPC server for `atv` CLI |
| `AutoReconnector.swift` | Watches for unexpected disconnects and retries |
| `WindowManagement.swift` | NSWindow setup: translucency, focus-fade, hide-on-close |

### Source files (`Sources/AppleTVProtocol/`)

| File | Role |
|------|------|
| `CompanionSession.swift` | Live session: socket I/O, frame dispatch, keepalive, txn/callbacks, all feature send methods. Conforms to `CompanionSessionDelegate` contract |
| `PairingFlow.swift` | Pair-setup (SRP-6a) and pair-verify (ECDH) state machines |
| `EncryptedFrameTransport.swift` | ChaCha20-Poly1305 seal/open for E_OPACK frames |
| `CompanionFrame.swift` | Wire frame encode/decode |
| `OPACK.swift` | OPACK serialization (Apple's binary dict format) |
| `MRPDecoder.swift` | Decodes MRP now-playing protobuf messages |
| `AirPlayTunnel.swift` | AirPlay MRP tunnel for real-time now-playing |
| `CredentialStore.swift` | Pairing credentials persisted as JSON in Application Support |
| `HAPPairing.swift` / `SRPClient.swift` | HAP pairing crypto |
| `RTITextOperations.swift` | RTI binary plist encoder for text input |

### Key protocol notes

- Apple TVs advertise `_companion-link._tcp` via Bonjour; port is resolved dynamically
- Companion protocol uses raw BSD sockets (bypasses NWConnection TCC restrictions on macOS 14+)
- Pairing uses SRP-6a (pair-setup) + ECDH (pair-verify); ATV displays a 4-digit PIN
- Post-pairing frames are ChaCha20-Poly1305 encrypted E_OPACK
- `CompanionSession` is the testable core; `CompanionConnection` is this app's SwiftUI wrapper around it
- Reference implementation: [pyatv](https://github.com/postlund/pyatv) (`pyatv/protocols/companion/`)

## Issue tracking

This project uses **bd (beads)** for all issue tracking. Do NOT create markdown TODO lists.

```bash
bd ready                    # find available work
bd show <id>                # view issue details
bd update <id> --claim      # claim work
bd close <id>               # complete work
bd dolt push                # sync to remote
```

## Shell safety

Always use non-interactive flags to avoid hanging on confirmation prompts:
- `cp -f`, `mv -f`, `rm -f`, `rm -rf`

## Git

**NEVER push to remote unless the user explicitly asks.** Commit freely, but do not run `git push` without a direct instruction to do so.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:b9766037 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- **NEVER push unless the user explicitly says to push** — this overrides all other rules
- Work is complete when committed; pushing is the user's call
<!-- END BEADS INTEGRATION -->
