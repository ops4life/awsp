---
title: Contributing
description: How to contribute to awsp
---

# Contributing

Thank you for your interest in contributing to awsp! This guide walks you through the process.

## Getting Started

### 1. Fork the Repository

Click the "Fork" button at the top right of the [repository page](https://github.com/ops4life/awsp).

### 2. Clone Your Fork

```bash
git clone https://github.com/YOUR-USERNAME/awsp.git
cd awsp
```

### 3. Add Upstream Remote

```bash
git remote add upstream https://github.com/ops4life/awsp.git
```

## Development Setup

### Install Pre-commit Hooks

Pre-commit hooks are **required** for all contributions:

```bash
pre-commit install
```

Verify the installation:

```bash
pre-commit run --all-files
```

### Create a Feature Branch

```bash
git checkout -b feat/your-feature-name
```

!!! warning "Never commit directly to `main`"
    The `main` branch is protected and triggers automated releases via semantic-release. Always work on a feature branch.

## Contribution Workflow

### 1. Keep Your Fork Updated

```bash
git fetch upstream
git checkout main
git merge upstream/main
```

### 2. Make Your Changes

- Write clear, concise code
- Follow existing code patterns
- Follow [POSIX shell compliance](#shell-coding-guidelines)
- Update documentation as needed

### 3. Test Your Changes

```bash
# Run pre-commit hooks
pre-commit run --all-files

# Source and test the function
. bin/awsp.sh
awsp --help
awsp --list
```

Test in both Bash and Zsh if possible.

### 4. Commit Your Changes

Follow the [Commit Conventions](commit-conventions.md):

```bash
git commit -m "feat: add new feature description"
```

### 5. Push and Create a Pull Request

```bash
git push origin feat/your-feature-name
```

Then open a Pull Request on GitHub.

## Pull Request Requirements

- [ ] Title follows [Conventional Commits](commit-conventions.md) format
- [ ] Description clearly explains the changes
- [ ] Related issues are linked (e.g., `fixes #123`)
- [ ] All CI checks pass
- [ ] Pre-commit hooks pass locally
- [ ] Changes tested in both Bash and Zsh (if applicable)

## Shell Coding Guidelines

awsp is intentionally POSIX-compliant. When contributing shell code:

| Do | Don't |
|---|---|
| `[ ]` for conditionals | `[[ ]]` (bashism) |
| `=` for string comparison | `==` (bashism) |
| `$(command)` for substitution | `` `command` `` (deprecated) |
| Portable `awk`, `sed`, `grep` | GNU-specific extensions |

### Zsh Compatibility

The function uses `emulate -L sh` for Zsh users, ensuring POSIX-like behavior. Test that your changes work under this emulation.

## Code Style

- **Indentation**: 2 spaces
- **Line Endings**: LF (Unix-style)
- **Charset**: UTF-8
- **Trailing Whitespace**: Removed automatically by pre-commit
- **Final Newline**: Required

## Questions?

- **Questions**: Open a [Discussion](https://github.com/ops4life/awsp/discussions)
- **Bug Reports**: Open an [Issue](https://github.com/ops4life/awsp/issues/new?template=bug_report.md)
- **Feature Requests**: Open an [Issue](https://github.com/ops4life/awsp/issues/new?template=feature_request.md)
