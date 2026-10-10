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
#   AWSP_SKIP_PREFLIGHT=1  skip the environment checks
set -eu

REPO="ops4life/awsp"
PREFIX="${PREFIX:-$HOME/.config/awsp}"

die() { echo "Error: $*" >&2; exit 1; }

# --- preflight begin ---
awsp_preflight() {
  [ "${AWSP_SKIP_PREFLIGHT:-}" = 1 ] && return 0
  pf_fail=0
  pf_ok() { echo "  ✓ $*"; }
  pf_warn() { echo "  ⚠ $*"; }
  pf_err() { echo "  ✗ $*"; pf_fail=1; }
  echo "→ Preflight checks..."
  case "${SHELL:-}" in
    */bash | */zsh) pf_ok "shell: ${SHELL##*/}" ;;
    *) pf_err "unsupported login shell '${SHELL:-unset}'; awsp supports Bash and Zsh" ;;
  esac
  if command -v tar >/dev/null 2>&1; then pf_ok "tar"; else pf_err "tar is required"; fi
  if [ "${AWSP_PREFLIGHT_DOWNLOAD:-}" = 1 ]; then
    if command -v curl >/dev/null 2>&1; then pf_ok "curl"; else pf_err "curl is required"; fi
    if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
      pf_ok "sha256 tool"
    else
      pf_err "sha256sum or shasum is required"
    fi
  fi
  if command -v aws >/dev/null 2>&1; then
    pf_ver="$(aws --version 2>&1 | sed -n 's|^aws-cli/\([0-9]*\).*|\1|p' | head -n 1)"
    if [ "$pf_ver" = 2 ]; then
      pf_ok "AWS CLI v2"
    else
      pf_warn "AWS CLI v${pf_ver:-?} found; SSO features require v2 (https://aws.amazon.com/cli/)"
    fi
  else
    pf_warn "AWS CLI not found; SSO features require AWS CLI v2 (https://aws.amazon.com/cli/)"
  fi
  if [ -f "$HOME/.aws/config" ] || [ -f "$HOME/.aws/credentials" ]; then
    pf_ok "AWS profile files"
  else
    pf_warn "no ~/.aws/config or ~/.aws/credentials yet; add a profile (aws configure sso)"
  fi
  pf_dir="${PREFIX:-$HOME/.config/awsp}"
  while [ ! -d "$pf_dir" ] && [ "$pf_dir" != / ] && [ "$pf_dir" != . ]; do pf_dir="$(dirname "$pf_dir")"; done
  if [ -w "$pf_dir" ]; then pf_ok "install dir writable"; else pf_warn "$pf_dir is not writable; install may fail"; fi
  [ "$pf_fail" = 0 ] || return 1
}
# --- preflight end ---

AWSP_PREFLIGHT_DOWNLOAD=1
[ -z "${AWSP_TARBALL:-}" ] || AWSP_PREFLIGHT_DOWNLOAD=0
export AWSP_PREFLIGHT_DOWNLOAD
awsp_preflight || die "preflight failed (set AWSP_SKIP_PREFLIGHT=1 to bypass)"

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
