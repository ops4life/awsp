---
title: Workflows
description: GitHub Actions workflows used in awsp
---

# GitHub Actions Workflows

awsp uses several GitHub Actions workflows for CI/CD, security, and automation.

## Workflow Overview

| Workflow | Trigger | Purpose |
|---|---|---|
| [Release](#release) | Push to `main` | Automated versioning and release |
| [Documentation](#documentation-deployment) | Push to `main` (docs changes) | Deploy documentation to GitHub Pages |
| [Pre-commit CI](#pre-commit-ci) | Pull requests | Run pre-commit hooks |
| [Pre-commit Auto-update](#pre-commit-auto-update) | Scheduled (weekly) | Update pre-commit hook versions |
| [Gitleaks](#gitleaks) | Push, PR | Secret scanning |
| [CodeQL](#codeql) | Push, PR, scheduled | Static code analysis |
| [Lint PR](#lint-pr) | Pull requests | Validate PR title format |
| [Dependency Review](#dependency-review) | Pull requests | Check for vulnerable dependencies |
| [Stale](#stale) | Scheduled | Close stale issues and PRs |
| [Cleanup Caches](#cleanup-caches) | PR close | Clean up GitHub Actions caches |
| [Auto-merge](#auto-merge) | Pull requests | Auto-merge Dependabot PRs |
| [Update License](#update-license) | Yearly | Update copyright year |

## Release

**File**: `.github/workflows/release.yaml`

Runs [semantic-release](https://semantic-release.gitbook.io/) to:

- Analyze commit messages since last release
- Determine the next version number
- Update `AWSP_VERSION` in `bin/awsp.sh`
- Generate release notes and update `CHANGELOG.md`
- Create a GitHub release with assets
- Commit version bump changes back to `main`

Triggered on push to `main` or manual dispatch.

## Documentation Deployment

**File**: `.github/workflows/docs-deploy.yaml`

Builds and deploys the MkDocs documentation site to GitHub Pages:

- Installs Python and MkDocs dependencies
- Auto-configures repository URLs for the current fork/instance
- Builds the documentation with `mkdocs build --strict`
- Deploys to GitHub Pages

Triggered on push to `main` when documentation files change, or manual dispatch.

## Pre-commit CI

**File**: `.github/workflows/pre-commit-ci.yaml`

Runs all pre-commit hooks on pull requests to ensure code quality:

- Trailing whitespace removal
- End-of-file fixing
- YAML validation
- Gitleaks secret scanning

## Pre-commit Auto-update

**File**: `.github/workflows/pre-commit-auto-update.yaml`

Runs weekly to check for updates to pre-commit hook versions and creates a PR if updates are available.

## Gitleaks

**File**: `.github/workflows/gitleaks.yaml`

Scans for secrets and sensitive information in commits using [Gitleaks](https://gitleaks.io/).

## CodeQL

**File**: `.github/workflows/codeql.yaml`

GitHub's semantic code analysis engine. Scans for security vulnerabilities and coding errors.

## Lint PR

**File**: `.github/workflows/lint-pr.yaml`

Validates that pull request titles follow the [Conventional Commits](commit-conventions.md) specification, which is required for the automated release process.

## Dependency Review

**File**: `.github/workflows/deps-review.yaml`

Runs on pull requests to check for:

- Known vulnerabilities in dependencies
- License compliance issues
- Supply chain risks

## Stale

**File**: `.github/workflows/stale.yaml`

Automatically labels and closes issues and pull requests that have been inactive for a configured period.

## Cleanup Caches

**File**: `.github/workflows/cleanup-caches.yaml`

Cleans up GitHub Actions caches when pull requests are closed to free up storage.

## Auto-merge

**File**: `.github/workflows/automerge.yml`

Automatically merges Dependabot pull requests after CI checks pass, keeping dependencies up to date with minimal manual intervention.

## Update License

**File**: `.github/workflows/update-license.yml`

Runs yearly to update the copyright year in the LICENSE file.
