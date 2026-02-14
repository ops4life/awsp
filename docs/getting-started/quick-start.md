---
title: Quick Start
description: Install and configure awsp in under a minute
---

# Quick Start

Get up and running with awsp in just a few steps.

## Installation

### Clone and Install

```bash
git clone https://github.com/ops4life/awsp.git
cd awsp

make install
```

This installs awsp into `~/.config/awsp/` and adds a source line to your shell RC file (`.bashrc`, `.zshrc`, etc.).

### Reload Your Shell

After installation, reload your shell to activate awsp:

```bash
# Option 1: Restart your terminal
exec $SHELL

# Option 2: Source the script manually
. "$HOME/.config/awsp/awsp.sh"
```

## Verify Installation

```bash
awsp --version
```

You should see the installed version number printed to the terminal.

## First Use

### List Your Profiles

Make sure you have at least one AWS profile configured:

```bash
awsp --list
```

If no profiles are found, configure one first:

```bash
aws configure sso
```

### Switch to a Profile

```bash
# By name
awsp my-profile

# Or use the interactive picker
awsp
```

### Verify Your Identity

```bash
awsp --verify my-profile
```

This switches to the profile and confirms your AWS identity via STS.

## Uninstall

To completely remove awsp:

```bash
make uninstall
```

This removes all installed files and cleans up shell RC file entries.

## Next Steps

- Read the full [Usage Guide](usage.md) for all available commands and options
- Set up [shell completion](usage.md#shell-completion) for tab-complete support
- Learn about [SSO auto-login](usage.md#sso-auto-login) for seamless authentication
