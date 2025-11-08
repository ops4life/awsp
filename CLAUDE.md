# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`awsp` is a lightweight, cross-shell AWS profile switcher with SSO auto-login support. It's implemented as a pure POSIX shell function (not a binary) and works in both Bash and Zsh without external dependencies like `fzf`.

## Core Architecture

### Single-Function Design

The entire application is a single shell function defined in `bin/awsp.sh`. This function:
- Must be **sourced** (not executed) to modify the parent shell's environment variables
- Uses POSIX-compliant shell scripting for maximum portability
- Employs `emulate -L sh` for Zsh to ensure POSIX behavior

### Key Components

1. **Main Function** (`bin/awsp.sh`):
   - Parses command-line arguments and flags
   - Discovers AWS profiles from AWS CLI or by parsing config files
   - Sets environment variables (`AWS_PROFILE`, `AWS_DEFAULT_PROFILE`)
   - Handles SSO authentication via `aws sso login`
   - Verifies identity using `aws sts get-caller-identity`

2. **Shell Completions**:
   - `completions/_awsp.zsh`: Zsh completion using `_arguments`
   - `completions/awsp.bash`: Bash completion using `complete -F`
   - Both dynamically fetch profile names from AWS CLI

3. **Installation** (`Makefile`):
   - Installs to `~/.config/awsp/` (configurable via `PREFIX`)
   - Modifies shell RC files to source the function
   - `uninstall` target removes ALL traces including RC file modifications

## Development Workflow

### Branch Strategy

**Always create a feature branch for new work - never commit directly to `main`.**

```bash
# Create and switch to a feature branch
git checkout -b feature/your-feature-name

# After making changes, push and create a PR
git push -u origin feature/your-feature-name
```

The `main` branch is protected and triggers automated releases via semantic-release on merge.

## Development Commands

### Testing Installation Locally

```bash
# Install to default location (~/.config/awsp)
make install

# Test the function (requires reloading shell or sourcing)
. ~/.config/awsp/awsp.sh
awsp --help
```

### Uninstall

```bash
make uninstall
```

### Testing Without Installation

```bash
# Source the main script directly
. bin/awsp.sh

# Test the function
awsp --list
```

### Linting and Pre-commit

```bash
# Run pre-commit hooks manually
pre-commit run --all-files

# Install pre-commit hooks
pre-commit install
```

Pre-commit checks include:
- Trailing whitespace removal
- End-of-file fixing
- YAML validation
- Gitleaks secret scanning

### Release Process

This project uses semantic-release for automated versioning:
- Follows Conventional Commits specification
- Releases are triggered automatically on push to `main`
- CHANGELOG.md is auto-generated
- See `.releaserc.json` for configuration

## Code Architecture Details

### Profile Discovery Logic

The function attempts profile discovery in this order:
1. Use `aws configure list-profiles` if AWS CLI is available
2. Fallback to parsing `~/.aws/config` for `[profile name]` entries
3. Parse `~/.aws/credentials` for `[name]` entries
4. Combine and deduplicate results

### Environment Variable Management

The function explicitly unsets static credentials to prevent conflicts:
```sh
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

Then sets profile-based variables:
```sh
export AWS_SDK_LOAD_CONFIG=1
export AWS_PROFILE="$profile"
export AWS_DEFAULT_PROFILE="$profile"
```

### SSO Authentication Flow

1. **Auto-detection**: If `aws sts get-caller-identity` fails, assume credentials are expired
2. **Auto-login**: Run `aws sso login --profile $PROFILE` to refresh
3. **Verification**: Re-run `get-caller-identity` to confirm success
4. **Force login**: `-L` flag bypasses detection and always runs SSO login

### Verify Flag Behavior

- `auto` (default): Verify and auto-login if needed
- `on` (`-v`): Always verify identity
- `off` (`--no-verify`): Skip verification entirely

## Shell Compatibility Notes

### POSIX Compliance

The code is intentionally POSIX-compliant to work across shells:
- Avoids bashisms like `[[ ]]`, `==`, `(( ))` arithmetic
- Uses `[ ]` for conditionals
- Uses portable `awk`, `sed`, `grep` patterns

### Zsh Emulation

For Zsh users, the function uses:
```sh
[ -n "${ZSH_VERSION-}" ] && emulate -L sh
```
This ensures POSIX-like behavior for word splitting and glob expansion.

## Completion System Integration

### Zsh Completions

- Installed to `~/.config/awsp/completions/_awsp`
- Added to `fpath` before `compinit`
- Registered with `compdef _awsp awsp`

### Bash Completions

- Installed to `~/.config/awsp/completions/awsp.bash`
- Sourced directly from `bin/awsp.sh`
- Uses `complete -F _awsp_complete awsp`

## Important Constraints

1. **Never execute `bin/awsp.sh` directly** - it must be sourced to modify the parent shell's environment
2. **RC file modifications are automatic** - the Makefile handles adding source lines to common RC files
3. **No external dependencies** - the function works with just shell builtins and common UNIX tools
4. **AWS CLI is optional** - basic profile switching works without it, but SSO features require AWS CLI v2

## Testing Strategy

Since this is a shell function, testing should focus on:

1. **Manual testing** in both Bash and Zsh
2. **Profile discovery** with/without AWS CLI available
3. **SSO login flow** with expired credentials
4. **Completion functionality** in both shells
5. **RC file modification** during install/uninstall

## File Structure

```
.
├── bin/
│   └── awsp.sh          # Main shell function (178 lines)
├── completions/
│   ├── _awsp.zsh        # Zsh completion (28 lines)
│   └── awsp.bash        # Bash completion (17 lines)
├── Makefile             # Installation/uninstallation
├── .pre-commit-config.yaml
├── .releaserc.json      # Semantic release config
└── README.md
```
