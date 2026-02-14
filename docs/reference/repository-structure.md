---
title: Repository Structure
description: Overview of the awsp repository file structure
---

# Repository Structure

```text
.
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md          # Bug report template
│   │   ├── feature_request.md     # Feature request template
│   │   ├── documentation.md       # Documentation issue template
│   │   ├── issue_template.md      # General issue template
│   │   └── config.yml             # Issue template chooser config
│   ├── workflows/
│   │   ├── release.yaml           # Semantic release automation
│   │   ├── docs-deploy.yaml       # Documentation deployment
│   │   ├── pre-commit-ci.yaml     # Pre-commit hook CI
│   │   ├── pre-commit-auto-update.yaml  # Auto-update hooks
│   │   ├── gitleaks.yaml          # Secret scanning
│   │   ├── codeql.yaml            # Static code analysis
│   │   ├── lint-pr.yaml           # PR title linting
│   │   ├── deps-review.yaml       # Dependency review
│   │   ├── cleanup-caches.yaml    # Cache cleanup
│   │   ├── stale.yaml             # Stale issue management
│   │   ├── automerge.yml          # Dependabot auto-merge
│   │   ├── update-license.yml     # License year update
│   │   └── template-repo-sync.yaml  # Template sync
│   ├── CONTRIBUTING.md            # Contribution guidelines
│   ├── SECURITY.md                # Security policy
│   ├── FUNDING.yml                # Sponsorship config
│   ├── pull_request_template.md   # PR template
│   └── dependabot.yml             # Dependabot config
├── bin/
│   └── awsp.sh                    # Main shell function
├── completions/
│   ├── awsp.bash                  # Bash completion
│   └── _awsp.zsh                  # Zsh completion
├── docs/                          # MkDocs documentation source
│   ├── getting-started/
│   │   ├── quick-start.md
│   │   └── usage.md
│   ├── user-guide/
│   │   ├── contributing.md
│   │   ├── commit-conventions.md
│   │   ├── security.md
│   │   └── workflows.md
│   ├── reference/
│   │   ├── repository-structure.md
│   │   ├── configuration.md
│   │   └── changelog.md
│   ├── stylesheets/
│   │   └── custom.css
│   ├── overrides/                 # MkDocs theme overrides
│   └── index.md                   # Documentation home
├── .editorconfig                  # Editor settings
├── .gitattributes                 # Git file handling
├── .gitignore                     # Git ignore patterns
├── .gitleaks.toml                 # Secret scanning config
├── .pre-commit-config.yaml        # Pre-commit hooks
├── .releaserc.json                # Semantic release config
├── .templatesyncignore            # Template sync ignore
├── .yamllint                      # YAML lint config
├── CHANGELOG.md                   # Version history
├── CLAUDE.md                      # Claude Code guidance
├── CODEOWNERS                     # Code ownership
├── LICENSE                        # MIT License
├── Makefile                       # Install/uninstall
├── README.md                      # Project documentation
├── awsp.png                       # Project logo
├── mkdocs.yml                     # MkDocs configuration
└── requirements.txt               # Python dependencies (MkDocs)
```

## Key Directories

### `bin/`

Contains the main `awsp.sh` shell function. This is the core of the application — a single POSIX-compliant shell function that must be **sourced** (not executed) to modify the parent shell's environment.

### `completions/`

Shell completion scripts for Bash and Zsh. These are installed alongside the main function and provide tab completion for profile names and options.

### `docs/`

MkDocs documentation source files. Built and deployed to GitHub Pages automatically on push to `main`.

### `.github/`

GitHub-specific configuration including issue templates, PR templates, security policy, contributing guidelines, and CI/CD workflows.
