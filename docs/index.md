---
title: Home
description: awsp — Lightweight, cross-shell AWS profile switcher with SSO auto-login support
---

# awsp — AWS Profile Switcher

<p align="center">
  <img src="https://raw.githubusercontent.com/username/github-repo-template/main/awsp.png" alt="awsp logo" width="200" />
</p>

**awsp** is a lightweight, cross-shell AWS profile switcher with SSO auto-login support. It's implemented as a pure POSIX shell function and works in both Bash and Zsh without external dependencies like `fzf`.

---

## Key Features

- :material-console: **Cross-shell support** — Works in both Bash and Zsh
- :material-package-variant-closed: **Zero dependencies** — No `fzf` or other external tools required
- :material-format-list-numbered: **Interactive picker** — Numbered profile selection when no argument is passed
- :material-key: **SSO auto-login** — Automatically authenticates when credentials expire
- :material-content-save: **Profile persistence** — Remembers your last selected profile across sessions
- :material-tab: **Tab completion** — Dynamic completion for both shells
- :material-arrow-up-bold: **Self-upgrade** — Built-in upgrade command

## Quick Example

```bash
# Switch to a profile by name
awsp my-profile

# Or pick from an interactive list
awsp
# Pick an AWS profile:
#  1) dev-account
#  2) staging-account
#  3) prod-account
# Select number: 2
```

## Requirements

- **Bash** or **Zsh** shell
- **AWS CLI v2** (recommended for SSO features, optional for basic profile switching)
- At least one AWS profile configured

## Getting Started

Ready to get started? Head over to the [Quick Start](getting-started/quick-start.md) guide to install and configure awsp in under a minute.

## Links

- [Source Code](https://github.com/username/github-repo-template)
- [Issue Tracker](https://github.com/username/github-repo-template/issues)
- [Changelog](reference/changelog.md)
