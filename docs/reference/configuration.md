---
title: Configuration
description: Configuration files and settings reference for awsp
---

# Configuration

Reference for all configuration files used by awsp.

## AWS Configuration

awsp reads AWS profiles from standard AWS configuration files.

### `~/.aws/config`

The primary AWS configuration file. Profiles are defined as sections:

```ini
[default]
region = us-east-1

[profile dev-admin]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_account_id = 123456789012
sso_role_name = AdministratorAccess
region = us-east-1

[profile staging]
sso_start_url = https://my-sso-portal.awsapps.com/start
sso_region = us-east-1
sso_account_id = 987654321098
sso_role_name = ReadOnlyAccess
region = us-west-2
```

### `~/.aws/credentials`

Optional static credentials file:

```ini
[default]
aws_access_key_id = AKIA...
aws_secret_access_key = ...

[dev-static]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

!!! note
    awsp automatically comments out static credentials when switching to an SSO profile to prevent conflicts.

## awsp Configuration

### Installation Directory

Default: `~/.config/awsp/`

```text
~/.config/awsp/
├── awsp.sh                # Main function (sourced by shell RC)
├── current_profile        # Last selected profile name
└── completions/
    ├── _awsp              # Zsh completion
    └── awsp.bash          # Bash completion
```

### `current_profile`

A plain text file containing the name of the last selected AWS profile. Read on shell startup to automatically restore the previous profile.

## Makefile Options

The installation can be customized via the `PREFIX` variable:

```bash
# Default installation
make install

# Custom installation directory
make install PREFIX=~/.local/share/awsp
```

## Pre-commit Configuration

### `.pre-commit-config.yaml`

Defines the pre-commit hooks used in the development workflow:

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml

  - repo: https://github.com/gitleaks/gitleaks
    hooks:
      - id: gitleaks

  - repo: local
    hooks:
      - id: mkdocs-build
        name: mkdocs build
        entry: mkdocs build --strict
        language: system
        pass_filenames: false
        files: (docs/|mkdocs\.yml)
```

## Semantic Release

### `.releaserc.json`

Controls the automated release process:

- **Branches**: Releases from `main` and `master`
- **Plugins**:
    - `commit-analyzer` — Determines version bumps from commit messages
    - `release-notes-generator` — Generates release notes
    - `exec` — Updates `AWSP_VERSION` in `bin/awsp.sh`
    - `github` — Creates GitHub releases
    - `changelog` — Maintains `CHANGELOG.md`
    - `git` — Commits version changes

## EditorConfig

### `.editorconfig`

Ensures consistent code style across editors:

| Setting | Value |
|---|---|
| Indent style | Spaces |
| Indent size | 2 |
| End of line | LF |
| Charset | UTF-8 |
| Trim trailing whitespace | Yes |
| Insert final newline | Yes |

## Gitleaks

### `.gitleaks.toml`

Secret scanning configuration with allowlists for:

- Documentation files (`*.md`, `CHANGELOG.md`, `LICENSE`)
- Common false positives (example AWS keys, test tokens)
