#!/bin/bash
# Installs a jet release into Pd's externals folder without compiling and
# without the macOS "cannot be opened" warnings: files fetched by gh/curl in
# the Terminal never get the browser's quarantine flag.
#
#   tools/install-release.sh            newest release (pre-releases included)
#   tools/install-release.sh v0.2.0     a specific one
#
# Uses the GitHub CLI (gh, logged in - needed while the repo is private) and
# falls back to curl for a public repo. Environment variables:
#   PD_EXTERNALS_DIR   where Pd's externals live  (~/Documents/Pd/externals)
#   JET_REPO           owner/name                  (moellenhoff/pd-jet)
set -euo pipefail

REPO="${JET_REPO:-moellenhoff/pd-jet}"
TAG="${1:-}"
ROOT="${PD_EXTERNALS_DIR:-$HOME/Documents/Pd/externals}"
ASSET="jet-macos-arm64.zip"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "jet needs a Mac with Apple Silicon (this is $(uname -s) $(uname -m))." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if [ -z "$TAG" ]; then
    TAG="$(gh release list -R "$REPO" --limit 1 --json tagName --jq '.[0].tagName')"
  fi
  echo "Downloading jet $TAG with gh ..."
  gh release download "$TAG" -R "$REPO" -p "$ASSET" -D "$tmp"
else
  if [ -z "$TAG" ]; then
    TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1" \
           | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$TAG" ] || { echo "Could not find a release of $REPO (private repo? run: gh auth login)." >&2; exit 1; }
  echo "Downloading jet $TAG with curl ..."
  curl -fsSL -o "$tmp/$ASSET" "https://github.com/$REPO/releases/download/$TAG/$ASSET"
fi

unzip -q "$tmp/$ASSET" -d "$tmp"
[ -f "$tmp/jet/jet_win.pd_darwin" ] || { echo "The download does not look like a jet release." >&2; exit 1; }

mkdir -p "$ROOT"
if [ -d "$ROOT/jet" ]; then
  rm -rf "$ROOT/jet.previous"
  mv "$ROOT/jet" "$ROOT/jet.previous"
  echo "The old folder was kept as $ROOT/jet.previous"
fi
mv "$tmp/jet" "$ROOT/jet"
# only matters if a browser was involved somewhere along the way
xattr -dr com.apple.quarantine "$ROOT/jet" 2>/dev/null || true

echo
echo "Installed jet $TAG in $ROOT/jet"
echo "Next: make sure that folder is in Pd's path (Preferences > Path), then quit and restart Pd."
