# Agent Instructions

This project uses **trekker** for issue tracking. Run `trekker quickstart` for full workflow context.

## Quick Reference

```bash
trekker ready                            # Find available work
trekker task show <id>                   # View task details
trekker task update <id> -s in_progress  # Claim work
trekker task update <id> -s completed    # Complete work
```

- Use `trekker` for ALL task tracking — do NOT use markdown TODO lists
- Persistent knowledge lives under the **Project Memory** epic (`EPIC-1`) as
  completed tasks tagged `memory`. Search with
  `trekker search "<keyword>" --type task`. Add a new one with:
  `trekker task create -t "<short-key>" -d "<insight>" -e EPIC-1 --tags memory -s completed`
- Do NOT use MEMORY.md files

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
