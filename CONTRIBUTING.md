# Contributing

Bug reports, feature requests, and pull requests are welcome.

## Reporting a bug

Open a GitHub issue with:
- macOS version
- Apple TV model and tvOS version
- What you did, what you expected, what happened
- Any relevant output from `atv --verbose` or Console.app filtered to `com.adhir.appletv-remote`

## Building from source

Requires macOS 13+ and Xcode 26 / Swift 6 toolchain.

```bash
swift build       # debug build
swift test        # run tests
swift build -c release
```

The project uses **Swift 6** language mode with strict concurrency checking enabled on all targets.

To install a local build:

```bash
cp -f .build/release/AppleTVRemote /Applications/AppleTVRemote.app/Contents/MacOS/AppleTVRemote
cp -rf .build/release/AppleTVRemote_AppleTVRemote.bundle /Applications/AppleTVRemote.app/Contents/Resources/
cp -f .build/release/atv /usr/local/bin/atv
pkill -x AppleTVRemote
```

If behavior doesn't match your changes, verify the running binary is fresh — stale installs are the most common source of confusion.

## Sending a pull request

- Branch off `main`
- Keep commits focused — one logical change per commit
- Run `swift test` before opening the PR
- For protocol changes, add or update tests in `Tests/AppleTVProtocolTests/`
- Don't bump `BigInt` or other dependencies without a reason

## Code style

Match the surrounding code. No hard rules, but in practice:
- 4-space indentation
- Trailing closures preferred
- `guard` early returns over deeply nested `if`
- Log with `Log.companion.report()` / `.trace()` / `.fail()` — not `print()`

## Architecture notes

The key split: `AppleTVProtocol` is a pure library (no UI, no app dependencies) — keep it that way. App-layer concerns belong in `Sources/AppleTVRemote/`. The protocol reference is [pyatv](https://github.com/postlund/pyatv).
