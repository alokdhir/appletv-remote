# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Building

```bash
swift build          # debug build
swift build -c release
```

The project requires macOS 13+ and Xcode 26 / Swift 6.

## Architecture

This is a SwiftUI macOS app that discovers and controls Apple TVs on the local network via the **Media Remote Protocol (MRP)**.

### Source files (`Sources/AppleTVRemote/`)

| File | Role |
|------|------|
| `AppleTVRemoteApp.swift` | `@main` SwiftUI entry point; owns `DeviceDiscovery` |
| `AppleTVDevice.swift` | Device model, `ConnectionState`, `RemoteCommand` enums |
| `DeviceDiscovery.swift` | Bonjour browser (`_mediaremotetv._tcp`) using `NWBrowser` |
| `ContentView.swift` | Root split layout (sidebar + detail) |
| `DeviceListView.swift` | Sidebar: discovered device list with refresh |
| `RemoteControlView.swift` | D-pad, playback, volume, now-playing card |
| `Protocol/MRPConnection.swift` | `NWConnection` TCP connection; varint-framed message receive loop |
| `Protocol/MRPMessage.swift` | Hand-encoded protobuf MRP wire messages (no protobuf runtime dependency) |
| `Protocol/CredentialStore.swift` | Pairing credentials persisted as JSON in Application Support |

### Key protocol notes

- Apple TVs advertise `_mediaremotetv._tcp` via Bonjour; port is resolved dynamically
- MRP messages are length-prefixed with a protobuf varint, followed by a protobuf payload
- Pairing uses an SRP-6a exchange; the Apple TV displays a 4-digit PIN
- Reference implementation: [pyatv](https://github.com/postlund/pyatv) (`protocols/mrp/`)

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
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
