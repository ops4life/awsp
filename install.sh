#!/bin/sh
# awsp installer: downloads a release tarball (no git clone needed), verifies
# its checksum, installs to ~/.config/awsp and adds a source line to rc files.
#
#   curl -fsSL https://raw.githubusercontent.com/ops4life/awsp/main/install.sh | sh
#
# Environment:
#   AWSP_VERSION  version to install, e.g. 1.6.0 (default: latest release)
#   PREFIX        install dir (default: ~/.config/awsp)
#   AWSP_TARBALL  local tarball to install instead of downloading (testing)
set -eu

REPO="ops4life/awsp"
PREFIX="${PREFIX:-$HOME/.config/awsp}"

die() { echo "Error: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -n "${AWSP_TARBALL:-}" ]; then
  tarball="$AWSP_TARBALL"
else
  command -v curl >/dev/null 2>&1 || die "curl is required"
  version="${AWSP_VERSION:-}"
  if [ -z "$version" ]; then
    # /releases/latest redirects to /releases/tag/vX.Y.Z
    url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" ||
      die "could not determine latest version"
    version="${url##*/v}"
  fi
  version="${version#v}"
  name="awsp-$version.tar.gz"
  base="https://github.com/$REPO/releases/download/v$version"
  echo "→ Downloading awsp v$version..."
  curl -fsSL -o "$tmp/$name" "$base/$name" || die "download failed: $base/$name"
  curl -fsSL -o "$tmp/$name.sha256" "$base/$name.sha256" || die "checksum download failed"
  echo "→ Verifying checksum..."
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$tmp" && sha256sum -c "$name.sha256" >/dev/null) || die "checksum mismatch"
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$tmp" && shasum -a 256 -c "$name.sha256" >/dev/null) || die "checksum mismatch"
  else
    die "sha256sum or shasum is required"
  fi
  tarball="$tmp/$name"
fi

tar -xzf "$tarball" -C "$tmp" || die "failed to extract tarball"
src="$(find "$tmp" -maxdepth 1 -type d -name 'awsp-*' | head -n 1)"
[ -f "$src/bin/awsp.sh" ] || die "unexpected tarball layout"

command -v aws >/dev/null 2>&1 ||
  echo "⚠ AWS CLI not found in PATH; SSO features require AWS CLI v2 (https://aws.amazon.com/cli/)."

mkdir -p "$PREFIX/completions"
cp -f "$src/bin/awsp.sh" "$PREFIX/awsp.sh"
cp -f "$src/completions/awsp.bash" "$PREFIX/completions/awsp.bash"
cp -f "$src/completions/_awsp.zsh" "$PREFIX/completions/_awsp.zsh"
cp -f "$src/completions/_awsp.zsh" "$PREFIX/completions/_awsp"

src_line="[ -f \"$PREFIX/awsp.sh\" ] && . \"$PREFIX/awsp.sh\""
# Only touch rc files that exist; create the one for the login shell if none do.
rcs=""
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$rc" ] && rcs="$rcs $rc"
done
if [ -z "$rcs" ]; then
  case "${SHELL:-}" in
    */zsh) rcs="$HOME/.zshrc" ;;
    *) rcs="$HOME/.bashrc" ;;
  esac
  touch "$rcs"
fi
for rc in $rcs; do
  grep -Fqs "$src_line" "$rc" || printf '\n%s\n' "$src_line" >> "$rc"
done

echo "✓ Installed to $PREFIX"
echo "  Source line added to:$rcs"
echo "  Reload your shell or run: . \"$PREFIX/awsp.sh\""
