#!/bin/bash
# One step from a Mac with Homebrew to /Applications/Courtside.app:
#   1. check Homebrew (https://brew.sh; it also installs the Xcode Command Line Tools and git)
#   2. the Brewfile (ffmpeg)
#   3. scripts/build-mac-app.sh (downloads Node into the app), then the app is copied to
#      /Applications and opened. The Mac itself needs no Node.
# Safe to re-run: it skips what's there, upgrades ffmpeg, bundles the newest Node of the .nvmrc
# line, and replaces the app.
#
# From a clone:     ./scripts/install-mac.sh
# Without a clone:  curl -fsSL https://raw.githubusercontent.com/ismaytur/courtside/main/scripts/install-mac.sh | bash
set -euo pipefail

REPO_URL="https://github.com/ismaytur/courtside"
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
SELF="${BASH_SOURCE[0]:-}"  # empty under `curl | bash`
TMP=""
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

load_brew() {
  command -v brew >/dev/null && return 0
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -x "$b" ] && { eval "$("$b" shellenv)"; return 0; }
  done
  return 1
}

# Everything runs from main, so under `curl | bash` the whole script is read before any
# command (brew, git…) can consume the rest of it from stdin.
main() {
  [ "$(uname -s)" = Darwin ] || die "this installer is for macOS"

  # ---- 1. Homebrew -------------------------------------------------------------
  load_brew || die "Homebrew is required. Install it from https://brew.sh, then run this again."

  # Homebrew already existing doesn't guarantee the Command Line Tools (swiftc, codesign, iconutil).
  if ! xcrun --find swiftc >/dev/null 2>&1; then
    step "Installing the Xcode Command Line Tools"
    xcode-select --install || true
    die "finish the Command Line Tools installer that just opened, then run this again"
  fi

  # ---- 2. Source -----------------------------------------------------------------
  # Use the clone this script is in; under `curl | bash` there is none, so make a temporary one.
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  SRC=""
  if [ -n "$SELF" ] && [ -f "$SELF" ]; then
    SRC="$(cd "$(dirname "$SELF")/.." && pwd)"
  fi
  if [ -z "$SRC" ] || [ ! -f "$SRC/mac/Courtside.swift" ]; then
    step "Downloading Courtside"
    git clone --quiet --depth 1 "$REPO_URL" "$TMP/courtside"
    SRC="$TMP/courtside"
  fi

  # ---- 3. Tools ------------------------------------------------------------------
  step "Installing ffmpeg (brew bundle)"
  brew bundle --file="$SRC/Brewfile"
  # The build records where ffmpeg lives; make sure it finds Homebrew's.
  export PATH="$(brew --prefix)/bin:$PATH"

  # ---- 4. Build and install ----------------------------------------------------------
  step "Building Courtside.app"
  APP_OUT="$TMP/Courtside.app" bash "$SRC/scripts/build-mac-app.sh"

  DEST_DIR=/Applications
  [ -w "$DEST_DIR" ] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
  DEST="$DEST_DIR/Courtside.app"
  if pgrep -xq Courtside; then
    step "Quitting the running Courtside"
    osascript -e 'quit app "Courtside"' || true
    for _ in $(seq 20); do pgrep -xq Courtside || break; sleep 0.5; done
  fi
  step "Installing to $DEST"
  rm -rf "$DEST"
  ditto "$TMP/Courtside.app" "$DEST"

  open "$DEST"
  printf '\n\033[32mDone.\033[0m Courtside is in %s and updates itself from GitHub.\n' "$DEST_DIR"
  echo "Run this again after changes to mac/, the build script or .nvmrc, or to update Node."
}

main "$@"
