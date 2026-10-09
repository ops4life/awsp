#!/bin/sh
# Point the Homebrew tap formula at a released awsp version.
# Usage: HOMEBREW_TAP_TOKEN=... scripts/bump-tap.sh <version>
set -eu

version="${1:?usage: bump-tap.sh <version>}"
: "${HOMEBREW_TAP_TOKEN:?HOMEBREW_TAP_TOKEN is not set}"

url="https://github.com/ops4life/awsp/archive/refs/tags/v${version}.tar.gz"
sha="$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone -q "https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/ops4life/homebrew-awsp.git" "$work/tap"
cd "$work/tap"
sed -i -E "s|^  url .*|  url \"${url}\"|; s|^  sha256 .*|  sha256 \"${sha}\"|" Formula/awsp.rb

if git diff --quiet; then
  echo "Tap already at ${version}; nothing to do."
  exit 0
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git commit -qam "awsp ${version}"
git push -q
echo "Tap bumped to ${version}."
