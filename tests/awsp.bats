#!/usr/bin/env bats
# Test suite for bin/awsp.sh
#
# Uses a mocked `aws` CLI (tests/fixtures/bin/aws) and an isolated HOME per
# test so nothing here touches the real ~/.aws or ~/.config/awsp.

setup() {
  ORIG_HOME="$HOME"
  ORIG_PATH="$PATH"

  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  mkdir -p "$HOME/.aws" "$HOME/.config"

  AWSP_SH="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/awsp.sh"
  FIXTURES_BIN="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/bin"

  MOCK_AWS_LOG="$HOME/aws-calls.log"
  export MOCK_AWS_LOG
  unset MOCK_AWS_PROFILES MOCK_AWS_STS_FAIL MOCK_AWS_SSO_LOGIN_EXIT MOCK_AWS_CONFIGURE_EXIT
}

teardown() {
  export HOME="$ORIG_HOME"
  export PATH="$ORIG_PATH"
  rm -rf "$TEST_HOME"
}

# Source awsp with the mocked aws CLI on PATH.
_with_mock_aws() {
  PATH="$FIXTURES_BIN:$ORIG_PATH"
}

# Source awsp without any aws CLI available.
_without_aws() {
  _stripped="$(mktemp -d)"
  for d in $(printf '%s' "$ORIG_PATH" | tr ':' '\n'); do
    [ -x "$d/aws" ] && continue
    _stripped="$_stripped:$d"
  done
  PATH="$_stripped"
}

write_config_profile() {
  # write_config_profile NAME [sso]
  {
    echo "[profile $1]"
    if [ "${2-}" = "sso" ]; then
      echo "sso_start_url = https://example.awsapps.com/start"
      echo "sso_region = us-east-1"
      echo "sso_account_id = 123456789012"
      echo "sso_role_name = Admin"
    else
      echo "region = us-east-1"
    fi
  } >> "$HOME/.aws/config"
}

write_creds_profile() {
  # write_creds_profile NAME
  {
    echo "[$1]"
    echo "aws_access_key_id = AKIAFAKE"
    echo "aws_secret_access_key = fakesecret"
  } >> "$HOME/.aws/credentials"
}

# ---------- basic flags ----------

@test "--version prints the version" {
  _with_mock_aws
  source "$AWSP_SH"
  run awsp --version
  [ "$status" -eq 0 ]
  [[ "$output" == "awsp version "* ]]
}

@test "--help prints usage including the --add flag" {
  _with_mock_aws
  source "$AWSP_SH"
  run awsp --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"-a, --add"* ]]
}

@test "unknown option returns exit code 2" {
  _with_mock_aws
  source "$AWSP_SH"
  run awsp --bogus
  [ "$status" -eq 2 ]
}

@test "more than one positional profile is rejected" {
  _with_mock_aws
  source "$AWSP_SH"
  run awsp foo bar
  [ "$status" -eq 2 ]
  [[ "$output" == *"only one PROFILE allowed"* ]]
}

@test "no profiles found reports an error" {
  _with_mock_aws
  source "$AWSP_SH"
  run awsp --list
  [ "$status" -eq 1 ]
  [[ "$output" == *"No AWS profiles found"* ]]
}

# ---------- profile discovery / --list ----------

@test "--list uses aws configure list-profiles when aws CLI is present" {
  _with_mock_aws
  MOCK_AWS_PROFILES=$'dev\nprod'
  export MOCK_AWS_PROFILES
  source "$AWSP_SH"
  run awsp --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev"* ]]
  [[ "$output" == *"prod"* ]]
}

@test "--list falls back to parsing config/credentials files without aws CLI" {
  _without_aws
  write_config_profile "dev"
  write_creds_profile "legacy"
  source "$AWSP_SH"
  run awsp --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"dev"* ]]
  [[ "$output" == *"legacy"* ]]
}

# ---------- switching / --current / --unset ----------

@test "--current reports no profile set initially" {
  _with_mock_aws
  source "$AWSP_SH"
  run awsp --current
  [ "$status" -eq 0 ]
  [[ "$output" == *"no AWS_PROFILE set"* ]]
}

@test "switching to a named profile sets env vars and persists it" {
  _with_mock_aws
  MOCK_AWS_PROFILES="dev"
  export MOCK_AWS_PROFILES
  source "$AWSP_SH"
  run awsp dev --no-verify --quiet
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/awsp/current_profile")" = "dev" ]
}

@test "--unset clears env vars and removes the persisted profile" {
  _with_mock_aws
  MOCK_AWS_PROFILES="dev"
  export MOCK_AWS_PROFILES
  source "$AWSP_SH"
  awsp dev --no-verify --quiet
  run awsp --unset
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.config/awsp/current_profile" ]
}

@test "numbered-list selection switches to the chosen profile" {
  _with_mock_aws
  MOCK_AWS_PROFILES=$'dev\nprod'
  export MOCK_AWS_PROFILES
  source "$AWSP_SH"
  run bash -c "source '$AWSP_SH' >/dev/null; printf '2\n' | awsp --no-verify --quiet"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/awsp/current_profile")" = "prod" ]
}

# ---------- verify / login flow ----------

@test "--no-verify skips STS verification" {
  _with_mock_aws
  MOCK_AWS_PROFILES="dev"
  MOCK_AWS_STS_FAIL=1
  export MOCK_AWS_PROFILES MOCK_AWS_STS_FAIL
  source "$AWSP_SH"
  run awsp dev --no-verify --quiet
  [ "$status" -eq 0 ]
  ! grep -q "^sts " "$MOCK_AWS_LOG" 2>/dev/null
}

@test "verify auto-logs in via SSO when STS identity check fails" {
  _with_mock_aws
  MOCK_AWS_PROFILES="dev"
  MOCK_AWS_STS_FAIL=1
  export MOCK_AWS_PROFILES MOCK_AWS_STS_FAIL
  source "$AWSP_SH"
  run awsp dev --quiet
  [ "$status" -eq 0 ]
  grep -q "^sso login" "$MOCK_AWS_LOG"
}

@test "--json outputs STS identity as JSON" {
  _with_mock_aws
  MOCK_AWS_PROFILES="dev"
  export MOCK_AWS_PROFILES
  source "$AWSP_SH"
  run awsp dev --quiet --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Account"'* ]]
}

# ---------- -a / --add ----------

@test "--add requires the aws CLI" {
  _without_aws
  source "$AWSP_SH"
  run awsp --add
  [ "$status" -eq 1 ]
  [[ "$output" == *"aws CLI is required"* ]]
}

@test "--add re-prompts on an empty profile name" {
  _with_mock_aws
  source "$AWSP_SH"
  run bash -c "source '$AWSP_SH' >/dev/null; printf '\ndev\n1\n1\n' | awsp --add --no-verify --quiet"
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/awsp/current_profile")" = "dev" ]
}

@test "--add with SSO browser option calls aws configure sso without --use-device-code" {
  _with_mock_aws
  source "$AWSP_SH"
  run bash -c "source '$AWSP_SH' >/dev/null; printf 'dev\n1\n1\n' | awsp --add --no-verify --quiet"
  [ "$status" -eq 0 ]
  grep -q "^configure sso --profile dev$" "$MOCK_AWS_LOG"
  [ "$(cat "$HOME/.config/awsp/current_profile")" = "dev" ]
}

@test "--add with SSO device-code option passes --use-device-code" {
  _with_mock_aws
  source "$AWSP_SH"
  run bash -c "source '$AWSP_SH' >/dev/null; printf 'dev\n1\n2\n' | awsp --add --no-verify --quiet"
  [ "$status" -eq 0 ]
  grep -q -- "--use-device-code" "$MOCK_AWS_LOG"
}

@test "--add with static credentials option calls aws configure" {
  _with_mock_aws
  source "$AWSP_SH"
  run bash -c "source '$AWSP_SH' >/dev/null; printf 'dev\n2\n' | awsp --add --no-verify --quiet"
  [ "$status" -eq 0 ]
  grep -q "^configure --profile dev$" "$MOCK_AWS_LOG"
  [ "$(cat "$HOME/.config/awsp/current_profile")" = "dev" ]
}

@test "--add with an invalid profile-type selection fails" {
  _with_mock_aws
  source "$AWSP_SH"
  run bash -c "source '$AWSP_SH' >/dev/null; printf 'dev\n9\n' | awsp --add --no-verify --quiet"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid selection"* ]]
}

# ---------- internal helpers (top-level functions) ----------

@test "_awsp_is_sso_profile detects an SSO profile" {
  _with_mock_aws
  write_config_profile "dev" "sso"
  source "$AWSP_SH"
  run _awsp_is_sso_profile "dev"
  [ "$status" -eq 0 ]
}

@test "_awsp_is_sso_profile rejects a non-SSO profile" {
  _with_mock_aws
  write_config_profile "dev"
  source "$AWSP_SH"
  run _awsp_is_sso_profile "dev"
  [ "$status" -eq 1 ]
}

@test "_awsp_disable_static_creds_startup comments out static creds for SSO profiles" {
  _with_mock_aws
  write_config_profile "dev" "sso"
  write_creds_profile "dev"
  source "$AWSP_SH"
  _awsp_disable_static_creds_startup "dev"
  grep -q "^# aws_access_key_id" "$HOME/.aws/credentials"
}

@test "auto-load restores a previously saved profile on shell startup" {
  _with_mock_aws
  mkdir -p "$HOME/.config/awsp"
  printf 'dev\n' > "$HOME/.config/awsp/current_profile"
  source "$AWSP_SH"
  [ "$AWS_PROFILE" = "dev" ]
  [ "$AWS_DEFAULT_PROFILE" = "dev" ]
}
