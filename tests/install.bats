#!/usr/bin/env bats
# Preflight checks for scripts/preflight.sh and the copy embedded in install.sh.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.aws" "$BATS_TEST_TMPDIR/bin"
  : > "$HOME/.aws/config"
  export SHELL=/bin/bash
  export PREFIX="$HOME/.config/awsp"
  # Minimal PATH of symlinks so tests control which tools exist.
  for t in sh sed head dirname tar cat; do ln -s "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"; done
  TOOLS="$BATS_TEST_TMPDIR/bin"
}

# Run a script with only the symlinked tools on PATH (bats itself keeps the real PATH).
pf() { run /usr/bin/env PATH="$TOOLS" "$@"; }

fake_aws() { printf '#!/bin/sh\necho "aws-cli/%s Python/3 Linux"\n' "$1" > "$TOOLS/aws"; chmod +x "$TOOLS/aws"; }

@test "preflight passes with AWS CLI v2 and a profile file" {
  fake_aws 2.15.0
  pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ AWS CLI v2"* ]]
}

@test "preflight only warns when the AWS CLI is missing" {
  pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ AWS CLI not found"* ]]
}

@test "preflight only warns for AWS CLI v1" {
  fake_aws 1.27.0
  pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ AWS CLI v1 found"* ]]
}

@test "preflight only warns when no profile files exist" {
  rm "$HOME/.aws/config"
  pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠ no ~/.aws/config"* ]]
}

@test "preflight fails on an unsupported shell" {
  SHELL=/usr/bin/fish pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ unsupported login shell"* ]]
}

@test "preflight requires curl and a sha256 tool in download mode" {
  AWSP_PREFLIGHT_DOWNLOAD=1 pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"✗ curl is required"* ]]
  [[ "$output" == *"✗ sha256sum or shasum is required"* ]]
}

@test "AWSP_SKIP_PREFLIGHT=1 skips the checks" {
  SHELL=/usr/bin/fish AWSP_SKIP_PREFLIGHT=1 pf sh "$REPO/scripts/preflight.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "install.sh aborts before touching anything when preflight fails" {
  SHELL=/usr/bin/fish pf sh "$REPO/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"preflight failed"* ]]
  [ ! -e "$PREFIX" ]
}

@test "install.sh embeds the same preflight block as scripts/preflight.sh" {
  extract() { sed -n '/^# --- preflight begin ---$/,/^# --- preflight end ---$/p' "$1"; }
  [ -n "$(extract "$REPO/scripts/preflight.sh")" ]
  [ "$(extract "$REPO/scripts/preflight.sh")" = "$(extract "$REPO/install.sh")" ]
}
