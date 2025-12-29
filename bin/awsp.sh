# --- awsp: AWS profile switcher (no fzf) ---
# shellcheck shell=sh
# Source this file from your shell (installer will add it to your rc).

# Auto-load saved profile on shell startup (silent)
if [ -f "$HOME/.config/awsp/current_profile" ] && [ -z "${AWS_PROFILE-}" ]; then
  _awsp_saved_profile="$(cat "$HOME/.config/awsp/current_profile" 2>/dev/null || true)"
  if [ -n "$_awsp_saved_profile" ]; then
    export AWS_SDK_LOAD_CONFIG=1
    export AWS_PROFILE="$_awsp_saved_profile"
    export AWS_DEFAULT_PROFILE="$_awsp_saved_profile"
  fi
  unset _awsp_saved_profile
fi

awsp() {
  # Make zsh behave POSIX-y inside this function
  [ -n "${ZSH_VERSION-}" ] && emulate -L sh

  # ---------- defaults & flags ----------
  list_only=0
  show_current=0
  force_login=0
  unset_only=0
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
  -l, --list         List profiles and exit
  -c, --current      Print current AWS profile and exit
  -u, --unset        Unset AWS profile & static creds and exit
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
      -l|--list) list_only=1 ;;
      -c|--current) show_current=1 ;;
      -u|--unset) unset_only=1 ;;
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

  # Quick actions
  if [ "$show_current" -eq 1 ]; then
    if [ -n "${AWS_PROFILE-}" ]; then echo "$AWS_PROFILE"; else echo "(no AWS_PROFILE set)"; fi
    return 0
  fi

  if [ "$unset_only" -eq 1 ]; then
    _awsp_unset; return 0
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
