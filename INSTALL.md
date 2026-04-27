# Installing AppleTVRemote

## What the installer does

`install.sh` places two things on your Mac:

| What | Where | Purpose |
|------|-------|---------|
| `AppleTVRemote.app` | `/Applications/` | The menu bar + main window app |
| `atv` | `/usr/local/bin/atv` | Command-line control tool |

If AppleTVRemote is already running it will be stopped first. You can relaunch it from `/Applications` after the install completes.

The `atv` binary is copied to `/usr/local/bin`. If that directory doesn't exist (uncommon on modern macOS) the script will create it with `sudo`. You may be prompted for your password in that case.

## How to install

1. Open the DMG
2. Open a Terminal window
3. `cd` to the mounted DMG volume, or drag the DMG folder to Terminal to get the path
4. Run:

```bash
./install.sh
```

## How to uninstall

```bash
rm -rf /Applications/AppleTVRemote.app
rm -f /usr/local/bin/atv
```

Pairing credentials are stored separately and are not removed by uninstalling the app:

```bash
rm -rf ~/Library/Application\ Support/AppleTVRemote
```

## First launch

On first launch macOS may show a security prompt. If it does:

- Right-click (or Control-click) `AppleTVRemote.app` in `/Applications`
- Choose **Open**
- Click **Open** in the dialog

You only need to do this once.

> **Note:** Signed and notarized releases open without any prompts. The above only applies to unsigned builds.
