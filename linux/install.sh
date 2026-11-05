#!/bin/sh
# install.sh (Linux): fetch the newest Linux build from GitHub Releases (tag linux-vN), install it, restart it.
#   sh install.sh            newest release
#   sh install.sh dist/      a local build instead (after ./build.sh)
# Puts the app in ~/.local/share/mantra_macro/mantra_macro.pyz and the command in ~/.local/bin/macro.
set -e
REPO=markoboskoauroville/MANTRA_MACRO
DEST="$HOME/.local/share/mantra_macro"; BIN="$HOME/.local/bin"
mkdir -p "$HOME/.mantra_macro"
mkdir -p "$DEST" "$BIN"
if [ -n "$1" ]; then
  SRC="$1"
else
  SRC=$(mktemp -d)
  TAG=$(gh release list -R $REPO --limit 50 --json tagName --jq '[.[].tagName | select(startswith("linux-v"))] | sort_by(ltrimstr("linux-v") | tonumber) | last')
  [ -n "$TAG" ] || { echo "no linux-v release yet"; exit 1; }
  gh release download "$TAG" -R $REPO -D "$SRC" --clobber
fi
PYZ=$(ls "$SRC"/*-mantra_macro_linux-v*.pyz | sort -t- -k1,1n | tail -1)
cp "$PYZ" "$DEST/mantra_macro.pyz"
cp "$SRC/macro" "$BIN/macro" && chmod +x "$BIN/macro"
# restart: under the star's user unit when it exists (STAR_SWIFT/linux/install.sh), else on its own, hidden
pid=$(cat "$HOME/.mantra_macro/linux.pid" 2>/dev/null || true)
if systemctl --user cat mantra-macro.service >/dev/null 2>&1; then
  [ -n "$pid" ] && ! systemctl --user is-active -q mantra-macro.service && kill "$pid" 2>/dev/null && sleep 1
  rm -f "$HOME/.mantra_macro/linux.pid"
  systemctl --user restart mantra-macro.service
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HOME/.mantra_macro/linux.pid" ] && break; sleep 0.5; done   # ready for `macro`
  echo "installed $(basename "$PYZ"), running under mantra-macro.service"
else
  [ -n "$pid" ] && kill "$pid" 2>/dev/null && sleep 1
  DISPLAY=${DISPLAY:-:1} nohup python3 "$DEST/mantra_macro.pyz" --hidden >"$HOME/.mantra_macro/linux.log" 2>&1 &
  sleep 1
  echo "installed $(basename "$PYZ"), running (pid $!)"
fi
