AppleTVRemote
-------------
Control your Apple TV from your Mac.

INSTALL
  Run install.sh in Terminal:
    ./install.sh

  This copies AppleTVRemote.app to /Applications and
  atv to /usr/local/bin.

USAGE
  Launch AppleTVRemote from /Applications.
  Use 'atv help' from the terminal for CLI reference.

UNINSTALL
  rm -rf /Applications/AppleTVRemote.app
  rm -f /usr/local/bin/atv

  To also remove pairing credentials:
  rm -rf ~/Library/Application\ Support/AppleTVRemote

MORE INFO
  https://github.com/alokdhir/appletv-remote
