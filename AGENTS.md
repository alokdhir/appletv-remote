# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
```

- Use `bd` for ALL task tracking — do NOT use markdown TODO lists
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Building & Testing

```bash
swift build          # debug build
swift test           # run tests (AppleTVProtocolTests, AppleTVIPCTests)
swift build -c release
```

## Installing a local build

```bash
cp -f .build/release/AppleTVRemote /Applications/AppleTVRemote.app/Contents/MacOS/AppleTVRemote
cp -rf .build/release/AppleTVRemote_AppleTVRemote.bundle /Applications/AppleTVRemote.app/Contents/Resources/
cp -f .build/release/atv /usr/local/bin/atv
pkill -x AppleTVRemote
```

## Git commits

Do NOT add "Assisted-by", "Co-Authored-By", or any attribution lines to commit messages.

**NEVER push to remote unless the user explicitly asks.**

## Shell safety

Always use non-interactive flags to avoid hanging on confirmation prompts:
- `cp -f`, `mv -f`, `rm -f`, `rm -rf`
