---
title: Changelog
description: Version history for awsp
---

# Changelog

The full changelog is automatically maintained by [semantic-release](https://semantic-release.gitbook.io/) and can be found in the repository:

[View CHANGELOG.md on GitHub](https://github.com/ops4life/awsp/blob/main/CHANGELOG.md){ .md-button }

## How Versions Work

awsp follows [Semantic Versioning](https://semver.org/):

- **Major** (`X.0.0`) — Breaking changes to the CLI interface
- **Minor** (`0.X.0`) — New features, backwards compatible
- **Patch** (`0.0.X`) — Bug fixes, backwards compatible

## Checking Your Version

```bash
awsp --version
```

## Upgrading

```bash
awsp --upgrade
```

This automatically detects your installation method (git clone or release download) and upgrades accordingly.

## Release Process

Releases are fully automated:

1. Commits following [Conventional Commits](../user-guide/commit-conventions.md) are pushed to `main`
2. semantic-release analyzes commit messages
3. A new version is determined based on commit types
4. `CHANGELOG.md` is updated
5. `AWSP_VERSION` in `bin/awsp.sh` is bumped
6. A GitHub release is created with auto-generated notes
