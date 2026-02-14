---
title: Commit Conventions
description: Conventional Commits specification used by awsp
---

# Commit Conventions

This project follows the [Conventional Commits](https://www.conventionalcommits.org/) specification. Commit messages are used to automate versioning and changelog generation via [semantic-release](https://semantic-release.gitbook.io/).

## Format

```text
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

## Commit Types

| Type | Description | Version Bump |
|---|---|---|
| `feat` | A new feature | Minor |
| `fix` | A bug fix | Patch |
| `docs` | Documentation changes only | None |
| `style` | Code style changes (formatting, etc.) | None |
| `refactor` | Code changes that neither fix a bug nor add a feature | None |
| `test` | Adding or updating tests | None |
| `chore` | Changes to build process, dependencies, or tools | None |
| `ci` | Changes to CI/CD configuration | None |
| `revert` | Reverting a previous commit | Patch |

## Breaking Changes

To indicate a breaking change, add `!` after the type/scope or include a `BREAKING CHANGE:` footer:

```bash
# Using ! notation
feat!: remove deprecated --format flag

# Using footer
feat: change default output format

BREAKING CHANGE: Default output is now JSON instead of table
```

Breaking changes trigger a **major** version bump.

## Examples

```bash
# Feature
feat(auth): add OAuth2 authentication

# Bug fix
fix(sso): resolve login loop when token is expired

# Documentation
docs: update README with installation instructions

# Refactor
refactor: simplify profile discovery logic

# CI change
ci: add documentation deployment workflow
```

## Rules

1. **Subject** must start with a lowercase letter
2. Use **imperative mood** ("add feature" not "added feature")
3. **No period** at the end of the subject
4. Keep the subject line **under 72 characters**
5. **Scope** is optional but recommended
6. Separate subject from body with a **blank line**
7. Wrap body at **72 characters**

## How It Drives Releases

When commits are pushed to `main`, semantic-release analyzes the commit messages:

```text
fix: resolve SSO login issue     → Patch release (1.0.0 → 1.0.1)
feat: add JSON output support    → Minor release (1.0.0 → 1.1.0)
feat!: change CLI interface      → Major release (1.0.0 → 2.0.0)
docs: update usage guide         → No release
```

The changelog is automatically generated from commit messages, so clear and descriptive messages directly improve the project's documentation.
