#!/bin/sh
# awsp preflight: checks the environment before install. Blocking problems exit 1;
# everything else only warns. Run by `make install`; install.sh embeds a copy of the
# block between the markers below (tests/install.bats keeps the two in sync).
#   AWSP_PREFLIGHT_DOWNLOAD=1  also require curl (the installer will download a release)
#   AWSP_SKIP_PREFLIGHT=1      skip all checks
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

# Run directly (make install); install.sh sources nothing and calls its own copy.
case "$0" in
  */preflight.sh | preflight.sh) awsp_preflight || exit 1 ;;
esac
