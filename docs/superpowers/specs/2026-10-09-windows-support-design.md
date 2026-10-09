# Native Windows (PowerShell) support — design

## Goal

Let Windows users install and use `awsp` from native PowerShell (Windows PowerShell 5.1 and
PowerShell 7+), with feature parity to the Bash/Zsh function, installable via a one-line script,
Chocolatey, and winget. Today Windows works only through WSL or Git Bash.

## Non-goals

- cmd.exe support.
- Any change to `bin/awsp.sh` behavior.
- Scoop packaging (possible follow-up).

## Components

### 1. `bin/awsp.ps1` — the function
- Defines `awsp` (a function, dot-sourced so it can set `$env:*` in the caller's session).
- Same version constant as the shell script; same flags, hand-parsed from `$args`:
  `-h -V -l -c -u -a -r -m -L -v --no-verify --json -q -U --`, plus an optional profile name.
  No PowerShell-style named parameters (keeps parity and docs identical).
- Behavior mirrors `awsp.sh`: profile discovery (`aws configure list-profiles`, fallback to parsing
  `~/.aws/config` and `~/.aws/credentials`), numbered picker, sets `AWS_PROFILE`,
  `AWS_DEFAULT_PROFILE`, `AWS_SDK_LOAD_CONFIG`, unsets static credential env vars, SSO detection
  and auto-login, `sts get-caller-identity` verification (table/json), static-credential disabling
  for SSO profiles, add/remove/modify via an INI reader/writer for `~/.aws/config`.
- `-U` (self-upgrade): last priority. On Windows it prints the right upgrade command for the
  detected install method (choco / winget / script) rather than replacing files in place.
- Home dir from `$HOME`/`$env:USERPROFILE`; paths via `Join-Path`.

### 2. `completions/awsp.completion.ps1`
`Register-ArgumentCompleter -CommandName awsp` completing flags and profile names (from
`aws configure list-profiles`, falling back to config parsing). Dot-sourced by `awsp.ps1`.

### 3. `install.ps1` — script install
`irm https://raw.githubusercontent.com/ops4life/awsp/main/install.ps1 | iex`
- Env/params: `AWSP_VERSION`, `PREFIX` (default `%USERPROFILE%\.config\awsp`), `AWSP_ARCHIVE`
  (local zip for testing), `-Uninstall`.
- Downloads `awsp-<version>.zip` + `.sha256` from the GitHub release, verifies SHA256
  (`Get-FileHash`), extracts, copies files, appends an idempotent dot-source line to `$PROFILE`
  (creating it if needed). Uninstall removes the files and the line.
- Warns if `aws` is not on PATH.

### 4. Packaging
Packages install files only and tell the user to source them, matching the Homebrew/deb model
(the function must live in the user's own session).

- **Chocolatey** (`packaging/chocolatey/`): `awsp.nuspec`, `tools/chocolateyInstall.ps1` (downloads
  the release zip, verifies checksum, extracts to the package `tools` dir, prints the dot-source
  line; install also offers to add it to `$PROFILE.AllUsersAllHosts` only when the user passes
  `--params "/Profile"`), `tools/chocolateyUninstall.ps1`.
- **winget** (`packaging/winget/`): manifest templates (version / installer / locale). Installer
  type is an Inno Setup `.exe` (`awsp-<version>-setup.exe`) built in CI on `windows-latest` from
  `packaging/windows/awsp.iss`; it copies files to `%LOCALAPPDATA%\Programs\awsp`, adds the
  dot-source line to the user's PowerShell profile, and registers an uninstaller that removes it.
  (winget's `zip`/`portable` types only support executables, so a plain script zip does not fit.)
- **Release artifacts** (`scripts/build-release.sh` + `release.yaml`): add
  `awsp-<version>.zip` (+ `.sha256`, containing `bin/awsp.ps1`, `completions/`, `LICENSE`,
  `README.md`) and the setup `.exe` (+ `.sha256`). The nupkg is built from the nuspec.
  The tarball and `.deb` are unchanged.
- **Publishing automation**, mirroring `scripts/bump-tap.sh`:
  - `scripts/bump-choco.ps1` — `choco pack` + `choco push` using secret `CHOCO_API_KEY`.
  - `scripts/bump-winget.ps1` — `wingetcreate update ... --submit` using secret
    `WINGET_PKGS_TOKEN` (PR to `microsoft/winget-pkgs`).
  - Both run in `release.yaml` after artifacts upload, and are also `workflow_dispatch`-able in a
    new `bump-windows-packages.yaml` (like `bump-tap.yaml`). Missing secret → step skipped with a
    notice, not a failure.
- **One-time manual steps (not automated, need the maintainer):** create the Chocolatey account /
  API key and pass first-package moderation; submit the first winget-pkgs PR; add the two repo
  secrets. Nothing is published externally without the maintainer doing this.

### 5. Tests & CI
- `tests/awsp.Tests.ps1` (Pester 5): mirrors `awsp.bats` cases against fixtures in `tests/fixtures`
  with a fake `aws` (`.cmd`/`.ps1` stub on PATH) — switching, list, current, unset, JSON output,
  SSO detection, add/remove/modify, missing-profile errors.
- `test.yaml`: new `pester` job on `windows-latest` (Pester + PSScriptAnalyzer lint) and a
  smoke test that runs `install.ps1` with `AWSP_ARCHIVE`, then uninstalls.
- Packaging check job: `choco pack` on windows and Inno build produce artifacts.
- Pre-commit: no change needed (gitleaks covers `.ps1`).

### 6. Docs
README install table: add Windows rows (script, Chocolatey, winget) and replace the
"Windows is supported through WSL or Git Bash only" sentence (WSL/Git Bash still work via the
existing install). Mirror in `docs/getting-started/installation.md`. Update `CLAUDE.md`
architecture/file-structure sections to mention the PowerShell implementation.

## Risks / open items
- Dual implementation drift: mitigated by identical flag list and shared test cases; a CI check
  asserts both usage texts list the same flags.
- Signing: unsigned `.ps1`/`.exe` may trigger SmartScreen/ExecutionPolicy prompts; documented
  (`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`). Code signing is out of scope.
- winget/choco review latency means the first release can't be installed from those channels
  immediately; the script install is available at once.

## Delivery order (one PR each, feature branches, Conventional Commits)
1. `awsp.ps1` + completion + Pester tests + Windows CI job.
2. `install.ps1` + zip release artifact + docs.
3. Chocolatey and winget packaging + publish automation.
