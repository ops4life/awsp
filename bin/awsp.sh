# --- awsp: AWS profile switcher (no fzf) ---
# shellcheck shell=sh
# Source this file from your shell (installer will add it to your rc).

AWSP_VERSION="1.2.1"

# Helper to check if profile is SSO-based
_awsp_is_sso_profile() {
  _check_profile="$1"
  _config_file="$HOME/.aws/config"

  [ ! -f "$_config_file" ] && return 1
  [ ! -r "$_config_file" ] && return 1

  # Look for profile section and check for SSO configuration
  _in_section=0
  _section_name=""
  while IFS= read -r line; do
    case "$line" in
      "["*"]")
        # Extract section name
        _section_name="$(echo "$line" | sed 's/\[//;s/\]//')"
        # Remove "profile " prefix if present
        _section_name="$(echo "$_section_name" | sed 's/^profile[[:space:]]*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ "$_section_name" = "$_check_profile" ]; then
          _in_section=1
        else
          _in_section=0
        fi
        ;;
      *)
        if [ "$_in_section" -eq 1 ]; then
          case "$line" in
            sso_start_url*|sso_region*|sso_account_id*|sso_role_name*)
              return 0
              ;;
          esac
        fi
        ;;
    esac
  done < "$_config_file"

  return 1
}

# Helper to disable static credentials for SSO profiles (used by auto-load and awsp function)
_awsp_disable_static_creds_startup() {
  _target_profile="$1"

  # Only disable static credentials if this is an SSO profile
  if ! _awsp_is_sso_profile "$_target_profile"; then
    return 0
  fi

  _creds_file="$HOME/.aws/credentials"

  [ ! -f "$_creds_file" ] && return 0
  [ ! -r "$_creds_file" ] && return 0
  [ ! -w "$_creds_file" ] && return 0

  # Check if profile has static credentials
  _has_static=0
  _in_section=0
  while IFS= read -r line; do
    case "$line" in
      "[$_target_profile]")
        _in_section=1
        ;;
      "["*)
        _in_section=0
        ;;
      *)
        if [ "$_in_section" -eq 1 ]; then
          case "$line" in
            aws_access_key_id*|aws_secret_access_key*|aws_session_token*)
              _has_static=1
              break
              ;;
          esac
        fi
        ;;
    esac
  done < "$_creds_file"

  [ "$_has_static" -eq 0 ] && return 0

  # Create backup
  cp "$_creds_file" "${_creds_file}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

  # Comment out static credentials for this profile
  _tmp_file="${_creds_file}.tmp.$$"
  _in_section=0

  while IFS= read -r line; do
    case "$line" in
      "[$_target_profile]")
        _in_section=1
        echo "$line"
        ;;
      "["*)
        _in_section=0
        echo "$line"
        ;;
      *)
        if [ "$_in_section" -eq 1 ]; then
          case "$line" in
            aws_access_key_id*|aws_secret_access_key*|aws_session_token*)
              # Check if already commented
              case "$line" in
                "#"*) echo "$line" ;;
                *) echo "# $line" ;;
              esac
              ;;
            *) echo "$line" ;;
          esac
        else
          echo "$line"
        fi
        ;;
    esac
  done < "$_creds_file" > "$_tmp_file"

  mv "$_tmp_file" "$_creds_file" 2>/dev/null || rm -f "$_tmp_file"
}

# Hook function to ensure env vars stay unset when using profile-based auth
# This handles cases where hardcoded credentials are set in RC files after awsp loads
_awsp_precmd_hook() {
  # Only unset if we're using profile-based authentication
  if [ -n "${AWS_PROFILE-}" ] && [ -z "${_AWSP_ALLOW_ENV_OVERRIDE-}" ]; then
    # Check if env vars are set (which would override profile)
    if [ -n "${AWS_ACCESS_KEY_ID-}" ] || [ -n "${AWS_SECRET_ACCESS_KEY-}" ]; then
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    fi
  fi
}

# Auto-load saved profile on shell startup (silent)
if [ -f "$HOME/.config/awsp/current_profile" ] && [ -z "${AWS_PROFILE-}" ]; then
  _awsp_saved_profile="$(cat "$HOME/.config/awsp/current_profile" 2>/dev/null || true)"
  if [ -n "$_awsp_saved_profile" ]; then
    # Unset static credentials to avoid conflicts with profile-based auth
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    # Disable static credentials in credentials file
    _awsp_disable_static_creds_startup "$_awsp_saved_profile"
    export AWS_SDK_LOAD_CONFIG=1
    export AWS_PROFILE="$_awsp_saved_profile"
    export AWS_DEFAULT_PROFILE="$_awsp_saved_profile"
  fi
  unset _awsp_saved_profile
fi

# Install prompt hook to keep env vars unset
if [ -n "${ZSH_VERSION-}" ]; then
  # Zsh: add to precmd_functions array
  if ! (echo "${precmd_functions[@]-}" | grep -q "_awsp_precmd_hook" 2>/dev/null); then
    precmd_functions+=(_awsp_precmd_hook)
  fi
  # Also run immediately in case user runs commands before first prompt
  _awsp_precmd_hook
elif [ -n "${BASH_VERSION-}" ]; then
  # Bash: append to PROMPT_COMMAND
  case "${PROMPT_COMMAND-}" in
    *_awsp_precmd_hook*) ;;
    *) PROMPT_COMMAND="_awsp_precmd_hook${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
  esac
  # Also run immediately in case user runs commands before first prompt
  _awsp_precmd_hook
fi

awsp() {
  # Make zsh behave POSIX-y inside this function
  [ -n "${ZSH_VERSION-}" ] && emulate -L sh

  # ---------- defaults & flags ----------
  list_only=0
  show_current=0
  force_login=0
  unset_only=0
  upgrade=0
  verify=auto        # auto|on|off
  quiet=0
  outfmt=table       # table|json
  profile=""

  usage() {
    cat <<'USG'
Usage: awsp [options] [PROFILE]

Switch AWS profile with SSO auto-login (if needed). If PROFILE is omitted,
a numbered list will be shown.

Options:
  -h, --help         Show help and exit
  -V, --version      Show version and exit
  -l, --list         List profiles and exit
  -c, --current      Print current AWS profile and exit
  -u, --unset        Unset AWS profile & static creds and exit
  -U, --upgrade      Upgrade awsp to latest version
  -L, --login        Force "aws sso login" for the selected/current profile
  -v, --verify       Verify identity via STS (default: auto)
      --no-verify    Do not verify identity
      --json         Output STS identity as JSON instead of table
  -q, --quiet        Suppress non-essential output
USG
  }

  # ---------- parse args ----------
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      -V|--version) echo "awsp version $AWSP_VERSION"; return 0 ;;
      -l|--list) list_only=1 ;;
      -c|--current) show_current=1 ;;
      -u|--unset) unset_only=1 ;;
      -U|--upgrade) upgrade=1 ;;
      -L|--login) force_login=1 ;;
      -v|--verify) verify=on ;;
      --no-verify) verify=off ;;
      --json) outfmt=json ;;
      -q|--quiet) quiet=1 ;;
      --) shift; break ;;
      -*) echo "awsp: unknown option: $1" >&2; usage; return 2 ;;
      *)  if [ -z "$profile" ]; then profile="$1"; else
            echo "awsp: only one PROFILE allowed" >&2; return 2
          fi ;;
    esac
    shift
  done

  # ---------- helpers ----------
  _awsp_unset() {
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    # Remove saved profile
    rm -f "$HOME/.config/awsp/current_profile" 2>/dev/null || true
    [ "$quiet" -eq 0 ] && echo "→ AWS env cleared"
  }

  _awsp_is_sso_profile_check() {
    _check_profile="$1"
    _config_file="$HOME/.aws/config"

    [ ! -f "$_config_file" ] && return 1
    [ ! -r "$_config_file" ] && return 1

    # Look for profile section and check for SSO configuration
    _in_section=0
    _section_name=""
    while IFS= read -r line; do
      case "$line" in
        "["*"]")
          # Extract section name
          _section_name="$(echo "$line" | sed 's/\[//;s/\]//')"
          # Remove "profile " prefix if present
          _section_name="$(echo "$_section_name" | sed 's/^profile[[:space:]]*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
          if [ "$_section_name" = "$_check_profile" ]; then
            _in_section=1
          else
            _in_section=0
          fi
          ;;
        *)
          if [ "$_in_section" -eq 1 ]; then
            case "$line" in
              sso_start_url*|sso_region*|sso_account_id*|sso_role_name*)
                return 0
                ;;
            esac
          fi
          ;;
      esac
    done < "$_config_file"

    return 1
  }

  _awsp_disable_static_creds() {
    # Comment out static credentials in ~/.aws/credentials for given profile
    # to prevent conflicts with SSO-based auth
    _target_profile="$1"

    # Only disable static credentials if this is an SSO profile
    if ! _awsp_is_sso_profile_check "$_target_profile"; then
      return 0
    fi

    _creds_file="$HOME/.aws/credentials"

    [ ! -f "$_creds_file" ] && return 0
    [ ! -r "$_creds_file" ] && return 0
    [ ! -w "$_creds_file" ] && return 0

    # Check if profile has static credentials
    _has_static=0
    _in_section=0
    while IFS= read -r line; do
      case "$line" in
        "[$_target_profile]")
          _in_section=1
          ;;
        "["*)
          _in_section=0
          ;;
        *)
          if [ "$_in_section" -eq 1 ]; then
            case "$line" in
              aws_access_key_id*|aws_secret_access_key*|aws_session_token*)
                _has_static=1
                break
                ;;
            esac
          fi
          ;;
      esac
    done < "$_creds_file"

    [ "$_has_static" -eq 0 ] && return 0

    # Create backup
    cp "$_creds_file" "${_creds_file}.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    # Comment out static credentials for this profile
    _tmp_file="${_creds_file}.tmp.$$"
    _in_section=0
    _modified=0

    while IFS= read -r line; do
      case "$line" in
        "[$_target_profile]")
          _in_section=1
          echo "$line"
          ;;
        "["*)
          _in_section=0
          echo "$line"
          ;;
        *)
          if [ "$_in_section" -eq 1 ]; then
            case "$line" in
              aws_access_key_id*|aws_secret_access_key*|aws_session_token*)
                # Check if already commented
                case "$line" in
                  "#"*) echo "$line" ;;
                  *) echo "# $line"; _modified=1 ;;
                esac
                ;;
              *) echo "$line" ;;
            esac
          else
            echo "$line"
          fi
          ;;
      esac
    done < "$_creds_file" > "$_tmp_file"

    if [ "$_modified" -eq 1 ]; then
      mv "$_tmp_file" "$_creds_file" 2>/dev/null || {
        rm -f "$_tmp_file"
        return 1
      }
      [ "$quiet" -eq 0 ] && echo "→ Disabled static credentials in ~/.aws/credentials (backup created)"
      return 0
    else
      rm -f "$_tmp_file"
      return 0
    fi
  }

  _awsp_detect_install_type() {
    # Returns: "git" or "release"
    _script_path="${BASH_SOURCE[0]:-${(%):-%x}}"
    _script_dir="$(cd "$(dirname "$_script_path")" && pwd)"
    _check_dir="$_script_dir"
    _depth=0
    while [ "$_depth" -lt 5 ]; do
      if [ -d "$_check_dir/.git" ]; then
        echo "git"
        return 0
      fi
      _parent="$(dirname "$_check_dir")"
      if [ "$_parent" = "$_check_dir" ]; then break; fi
      _check_dir="$_parent"
      _depth=$((_depth + 1))
    done
    echo "release"
  }

  _awsp_fetch_latest_version() {
    if ! command -v curl >/dev/null 2>&1; then
      echo "Error: curl is required for upgrade feature" >&2
      return 1
    fi

    _api_url="https://api.github.com/repos/duyluann/awsp/releases/latest"
    _response=$(curl -s -f "$_api_url" 2>/dev/null) || {
      echo "Error: Failed to fetch latest version from GitHub" >&2
      return 1
    }

    # Parse JSON (POSIX-compliant)
    _version=$(echo "$_response" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' | sed 's/^v//')
    _body=$(echo "$_response" | sed -n '/"body":/,/"draft":/p' | sed '1d;$d')

    printf '%s\n%s\n' "$_version" "$_body"
  }

  _awsp_version_compare() {
    # Returns: 0 if $1 == $2, 1 if $1 > $2, 2 if $1 < $2
    _v1="$1"
    _v2="$2"

    if [ "$_v1" = "$_v2" ]; then
      return 0
    fi

    _v1_major=$(echo "$_v1" | cut -d. -f1)
    _v1_minor=$(echo "$_v1" | cut -d. -f2)
    _v1_patch=$(echo "$_v1" | cut -d. -f3)

    _v2_major=$(echo "$_v2" | cut -d. -f1)
    _v2_minor=$(echo "$_v2" | cut -d. -f2)
    _v2_patch=$(echo "$_v2" | cut -d. -f3)

    if [ "$_v1_major" -gt "$_v2_major" ]; then return 1; fi
    if [ "$_v1_major" -lt "$_v2_major" ]; then return 2; fi
    if [ "$_v1_minor" -gt "$_v2_minor" ]; then return 1; fi
    if [ "$_v1_minor" -lt "$_v2_minor" ]; then return 2; fi
    if [ "$_v1_patch" -gt "$_v2_patch" ]; then return 1; fi
    if [ "$_v1_patch" -lt "$_v2_patch" ]; then return 2; fi

    return 0
  }

  _awsp_get_installed_version() {
    _file="${1:-$HOME/.config/awsp/awsp.sh}"
    if [ ! -f "$_file" ]; then
      echo "unknown"
      return 1
    fi
    grep '^AWSP_VERSION=' "$_file" | head -1 | sed 's/AWSP_VERSION="\(.*\)"/\1/'
  }

  _awsp_upgrade_git() {
    _install_dir="$1"
    _repo_root="$2"

    echo "→ Detected git installation at $_repo_root"
    echo "→ Running git pull..."

    # Save current directory
    _pwd="$PWD"

    # Navigate to repo and pull
    cd "$_repo_root" || {
      echo "Error: Cannot access repository directory" >&2
      cd "$_pwd"
      return 1
    }

    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
      echo "Warning: You have uncommitted changes in $_repo_root"
      echo "Stash or commit them before upgrading."
      cd "$_pwd"
      return 1
    fi

    # Pull latest changes
    git pull origin main >/dev/null 2>&1 || {
      echo "Error: git pull failed" >&2
      cd "$_pwd"
      return 1
    }

    # Re-run make install
    if [ -f "$_repo_root/Makefile" ]; then
      echo "→ Re-installing from source..."
      make -C "$_repo_root" install >/dev/null 2>&1 || {
        echo "Error: make install failed" >&2
        cd "$_pwd"
        return 1
      }
    fi

    cd "$_pwd"

    # Verify new version
    _new_version=$(_awsp_get_installed_version)
    echo "→ Successfully upgraded to version $_new_version"
    echo "→ Restart your shell or run: . \"$_install_dir/awsp.sh\""

    return 0
  }

  _awsp_upgrade_release() {
    _install_dir="$1"
    _target_version="$2"

    echo "→ Downloading awsp v$_target_version..."

    # Create temporary directory
    _tmp_dir="${TMPDIR:-/tmp}/awsp-upgrade-$$"
    mkdir -p "$_tmp_dir" || {
      echo "Error: Cannot create temporary directory" >&2
      return 1
    }

    # Download tarball
    _tarball_url="https://github.com/duyluann/awsp/archive/refs/tags/v${_target_version}.tar.gz"
    _tarball="$_tmp_dir/awsp.tar.gz"

    if ! curl -L -s -f -o "$_tarball" "$_tarball_url"; then
      echo "Error: Failed to download release tarball" >&2
      rm -rf "$_tmp_dir"
      return 1
    fi

    echo "→ Extracting files..."

    # Extract tarball
    if ! tar -xzf "$_tarball" -C "$_tmp_dir"; then
      echo "Error: Failed to extract tarball" >&2
      rm -rf "$_tmp_dir"
      return 1
    fi

    # Find extracted directory (should be awsp-VERSION)
    _extracted_dir="$_tmp_dir/awsp-${_target_version}"
    if [ ! -d "$_extracted_dir" ]; then
      echo "Error: Unexpected tarball structure" >&2
      rm -rf "$_tmp_dir"
      return 1
    fi

    echo "→ Backing up current installation..."

    # Backup current installation
    _backup_dir="${_install_dir}.backup"
    rm -rf "$_backup_dir"
    cp -a "$_install_dir" "$_backup_dir" || {
      echo "Error: Failed to create backup" >&2
      rm -rf "$_tmp_dir"
      return 1
    }

    echo "→ Installing new version..."

    # Copy new files
    if ! cp -f "$_extracted_dir/bin/awsp.sh" "$_install_dir/awsp.sh"; then
      echo "Error: Failed to install awsp.sh, restoring backup..." >&2
      rm -rf "$_install_dir"
      mv "$_backup_dir" "$_install_dir"
      rm -rf "$_tmp_dir"
      return 1
    fi

    if ! cp -f "$_extracted_dir/completions/awsp.bash" "$_install_dir/completions/awsp.bash"; then
      echo "Warning: Failed to install bash completion" >&2
    fi

    if ! cp -f "$_extracted_dir/completions/_awsp.zsh" "$_install_dir/completions/_awsp.zsh"; then
      echo "Warning: Failed to install zsh completion" >&2
    fi

    # Copy _awsp (zsh completion symlink)
    if ! cp -f "$_extracted_dir/completions/_awsp.zsh" "$_install_dir/completions/_awsp"; then
      echo "Warning: Failed to install zsh completion" >&2
    fi

    # Verify installation
    _new_version=$(_awsp_get_installed_version "$_install_dir/awsp.sh")
    if [ "$_new_version" != "$_target_version" ]; then
      echo "Error: Version mismatch after upgrade (expected $_target_version, got $_new_version)" >&2
      echo "Restoring backup..." >&2
      rm -rf "$_install_dir"
      mv "$_backup_dir" "$_install_dir"
      rm -rf "$_tmp_dir"
      return 1
    fi

    # Clean up
    rm -rf "$_backup_dir" "$_tmp_dir"

    echo "→ Successfully upgraded to version $_target_version"
    echo "→ Restart your shell or run: . \"$_install_dir/awsp.sh\""

    return 0
  }

  _awsp_upgrade() {
    echo "awsp upgrade"
    echo "────────────"

    # Detect installation directory
    _script_path="${BASH_SOURCE[0]:-${(%):-%x}}"
    _install_dir="$(cd "$(dirname "$_script_path")" && pwd)"

    # Show current version
    echo "Current version: $AWSP_VERSION"

    # Detect installation type
    _install_type=$(_awsp_detect_install_type)

    if [ "$_install_type" = "git" ]; then
      echo "Installation type: git"

      # Find git repo root
      _check_dir="$_install_dir"
      _repo_root=""
      _depth=0
      while [ "$_depth" -lt 5 ]; do
        if [ -d "$_check_dir/.git" ]; then
          _repo_root="$_check_dir"
          break
        fi
        _parent="$(dirname "$_check_dir")"
        if [ "$_parent" = "$_check_dir" ]; then break; fi
        _check_dir="$_parent"
        _depth=$((_depth + 1))
      done

      if [ -z "$_repo_root" ]; then
        echo "Error: Could not find git repository root" >&2
        return 1
      fi

      # Check if git is installed
      if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required but not found in PATH" >&2
        return 1
      fi

      # Fetch latest from remote
      echo "→ Checking for updates..."
      _pwd="$PWD"
      cd "$_repo_root" || return 1
      git fetch origin main >/dev/null 2>&1

      _local_commit=$(git rev-parse HEAD 2>/dev/null)
      _remote_commit=$(git rev-parse origin/main 2>/dev/null)

      cd "$_pwd"

      if [ "$_local_commit" = "$_remote_commit" ]; then
        echo "→ Already up to date!"
        return 0
      fi

      echo "→ Updates available"
      echo ""

      # Show confirmation
      printf 'Proceed with upgrade? (y/N): '
      read -r response
      case "$response" in
        y|Y|yes|YES) ;;
        *) echo "Upgrade cancelled."; return 1 ;;
      esac

      _awsp_upgrade_git "$_install_dir" "$_repo_root"

    else
      echo "Installation type: release"

      # Fetch latest version from GitHub
      echo "→ Checking for updates..."

      _fetch_result=$(_awsp_fetch_latest_version)
      if [ $? -ne 0 ]; then
        return 1
      fi

      _latest_version=$(echo "$_fetch_result" | head -1)
      _changelog=$(echo "$_fetch_result" | tail -n +2)

      echo "Latest version:  $_latest_version"
      echo ""

      # Compare versions
      _awsp_version_compare "$AWSP_VERSION" "$_latest_version"
      _cmp=$?

      if [ $_cmp -eq 0 ]; then
        echo "→ Already up to date!"
        return 0
      elif [ $_cmp -eq 1 ]; then
        echo "→ Your version is newer than the latest release!"
        return 0
      fi

      # Show changelog
      echo "What's new in $_latest_version:"
      echo "────────────────────────────────"
      echo "$_changelog"
      echo "────────────────────────────────"
      echo ""

      # Show confirmation
      printf 'Proceed with upgrade? (y/N): '
      read -r response
      case "$response" in
        y|Y|yes|YES) ;;
        *) echo "Upgrade cancelled."; return 1 ;;
      esac

      _awsp_upgrade_release "$_install_dir" "$_latest_version"
    fi
  }

  # Quick actions
  if [ "$show_current" -eq 1 ]; then
    if [ -n "${AWS_PROFILE-}" ]; then echo "$AWS_PROFILE"; else echo "(no AWS_PROFILE set)"; fi
    return 0
  fi

  if [ "$unset_only" -eq 1 ]; then
    _awsp_unset; return 0
  fi

  if [ "$upgrade" -eq 1 ]; then
    _awsp_upgrade
    return $?
  fi

  has_aws=0
  profiles=""

  # ---------- collect profiles ----------
  if command -v aws >/dev/null 2>&1; then
    has_aws=1
    profiles="$(aws configure list-profiles 2>/dev/null | awk 'NF')"
  fi

  if [ -z "$profiles" ]; then
    cfg=""
    [ -r "$HOME/.aws/config" ] && \
      cfg="$(awk '/^\[/{gsub(/\[|\]/,""); n=$0; sub(/^profile[[:space:]]+/,"",n); print n}' "$HOME/.aws/config")"
    cred=""
    [ -r "$HOME/.aws/credentials" ] && \
      cred="$(awk '/^\[/{gsub(/\[|\]/,""); print}' "$HOME/.aws/credentials")"
    profiles="$(printf '%s\n%s\n' "$cfg" "$cred" | awk 'NF' | sort -u)"
  fi

  count=$(printf '%s\n' "$profiles" | awk 'END{print NR+0}')
  if [ "$count" -eq 0 ]; then
    echo "No AWS profiles found. Create one with: aws configure sso"
    return 1
  fi

  if [ "$list_only" -eq 1 ]; then
    printf '%s\n' "$profiles"
    return 0
  fi

  # ---------- choose profile if not provided (numbered list) ----------
  if [ -z "$profile" ]; then
    [ "$quiet" -eq 0 ] && echo "Pick an AWS profile:"
    printf '%s\n' "$profiles" | nl -w2 -s') '
    printf 'Select number: '
    read -r choice
    case "$choice" in
      ''|*[!0-9]*) echo "No selection."; return 1 ;;
    esac
    if [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      profile="$(printf '%s\n' "$profiles" | sed -n "${choice}p")"
    else
      echo "No selection."; return 1
    fi
  fi

  [ -z "$profile" ] && { echo "No selection."; return 1; }

  # ---------- set env (avoid static creds override) ----------
  _awsp_unset
  export AWS_SDK_LOAD_CONFIG=1
  export AWS_PROFILE="$profile"
  export AWS_DEFAULT_PROFILE="$profile"
  [ "$quiet" -eq 0 ] && echo "→ Switched to $AWS_PROFILE"

  # Disable static credentials in credentials file to prevent conflicts with SSO
  _awsp_disable_static_creds "$profile"

  # Save profile for auto-load in future shells (silent)
  if mkdir -p "$HOME/.config/awsp" 2>/dev/null; then
    printf '%s\n' "$profile" > "$HOME/.config/awsp/current_profile" 2>/dev/null || true
  fi

  # ---------- verify / login logic ----------
  if [ "$has_aws" -eq 1 ]; then
    do_verify=0
    case "$verify" in
      on) do_verify=1 ;;
      off) do_verify=0 ;;
      auto) do_verify=1 ;; # default behavior
    esac

    if [ "$force_login" -eq 1 ]; then
      [ "$quiet" -eq 0 ] && echo "Authenticating SSO for $AWS_PROFILE..."
      aws sso login --profile "$AWS_PROFILE" >/dev/null 2>&1 || { echo "SSO login failed."; return 1; }
    fi

    if [ "$do_verify" -eq 1 ]; then
      if ! aws sts get-caller-identity >/dev/null 2>&1; then
        [ "$quiet" -eq 0 ] && echo "Authenticating SSO for $AWS_PROFILE..."
        aws sso login --profile "$AWS_PROFILE" >/dev/null 2>&1 || { echo "SSO login failed."; return 1; }
      fi
      if [ "$outfmt" = "json" ]; then
        aws sts get-caller-identity --output json
      else
        aws sts get-caller-identity --output table
      fi
    fi
  else
    [ "$quiet" -eq 0 ] && echo "Note: aws CLI not found in PATH; env switched but cannot verify."
  fi
}

# --- Optional: load completions if available ---
# bash
if [ -n "${BASH_VERSION-}" ] && [ -f "${HOME}/.config/awsp/completions/awsp.bash" ]; then
  . "${HOME}/.config/awsp/completions/awsp.bash"
fi
# zsh
if [ -n "${ZSH_VERSION-}" ] && [ -f "${HOME}/.config/awsp/completions/_awsp" ]; then
  # Add our completions directory to fpath before initializing completion system
  fpath=("${HOME}/.config/awsp/completions" $fpath)
  autoload -Uz compinit 2>/dev/null || true
  compinit -C 2>/dev/null || true
  # Autoload the completion function (zsh will find _awsp in fpath)
  autoload -Uz _awsp 2>/dev/null || true
  # Register the completion
  compdef _awsp awsp 2>/dev/null || true
fi
