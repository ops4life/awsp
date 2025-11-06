# awsp — AWS profile switcher

Tiny cross-shell function to switch AWS profiles (with SSO auto-login if needed).

- Works in **Bash** and **Zsh**.
- No `fzf` dependency — numbered picker when no profile is passed.
- Extras: list profiles, show current, unset env, force login, verify identity (table/json).

## Install (recommended)

```bash
git clone https://github.com/duyluann/awsp.git
cd awsp

make install

# then restart your shell, or run:
. "$HOME/.config/awsp/awsp.sh"
```

This installs into `~/.config/awsp/` and adds a source line to your shell rc file.

After installation, **reload your shell** or source the script manually as shown above.

## Uninstall

```bash
make uninstall
```

Removes all installed files and cleans up shell rc file entries.

## Usage

### Quick Start

Switch to a profile by name:

```bash
awsp my-profile-name
```

Or run without arguments to get an interactive numbered picker:

```bash
awsp
# Pick an AWS profile:
#  1) dev-account
#  2) staging-account
#  3) prod-account
# Select number: 2
```

### Command Reference

```text
awsp [options] [PROFILE]

Options:
  -h, --help         Show help and exit
  -l, --list         List profiles and exit
  -c, --current      Print current AWS profile and exit
  -u, --unset        Unset AWS profile & static creds and exit
  -L, --login        Force "aws sso login" for the selected/current profile
  -v, --verify       Verify identity via STS (default: auto)
      --no-verify    Do not verify identity
      --json         Output STS identity as JSON instead of table
  -q, --quiet        Suppress non-essential output
```

### Examples

List all available profiles:

```bash
awsp -l
```

Switch to a specific profile:

```bash
awsp dev-admin
```

Force SSO login for a profile:

```bash
awsp -L prod
```

Verify identity and show in JSON format:

```bash
awsp -v qa --json
```

Show current profile:

```bash
awsp -c
```

Unset all AWS environment variables:

```bash
awsp -u
```

Quiet mode (minimal output):

```bash
awsp -q prod
```

### Shell Completion

**Zsh**: Tab completion is automatically enabled after installation. Press `<TAB>` after typing `awsp` to complete profile names and options.

```bash
awsp <TAB>           # completes with available profile names
awsp -<TAB>          # completes with available options
```

**Bash**: Tab completion is automatically enabled after installation and works similarly.

### Troubleshooting

**Completion not working?**

For Zsh, verify the completion function is loaded:

```bash
type _awsp
# Should output: _awsp is a shell function from /home/user/.config/awsp/completions/_awsp
```

If completion still doesn't work:

1. Make sure you've reloaded your shell after installation
2. Try sourcing the script manually: `. "$HOME/.config/awsp/awsp.sh"`
3. Check that the completions directory is in your fpath: `echo $fpath | grep awsp`

**No profiles found?**

Make sure you have at least one AWS profile configured:

```bash
aws configure sso
# or manually edit ~/.aws/config and ~/.aws/credentials
```

## Requirements

- AWS CLI v2 (recommended, but will work without it for basic profile switching)
- At least one SSO profile configured: `aws configure sso`

## How It Works

1. **Profile Discovery**: Reads profiles from `aws configure list-profiles` or parses `~/.aws/config` and `~/.aws/credentials`
2. **Environment Setup**: Exports `AWS_PROFILE` and `AWS_DEFAULT_PROFILE`, clears static credentials
3. **SSO Auto-Login**: Automatically runs `aws sso login` if credentials are expired (when AWS CLI is available)
4. **Identity Verification**: Optionally verifies your identity via `aws sts get-caller-identity`

## Sequence Diagram(s)

```mermaid
sequenceDiagram
    actor User
    participant awsp as awsp function
    participant AWS as AWS CLI
    participant Config as Shell RC Files
    
    User->>awsp: awsp [profile]
    alt --current flag
        awsp->>User: Print current AWS_PROFILE
    else --unset flag
        awsp->>Config: Unset credentials
        awsp->>User: Credentials cleared
    else --list flag
        awsp->>AWS: List profiles
        AWS->>awsp: Profile list
        awsp->>User: Print profiles
    else Profile selection
        awsp->>AWS: Query available profiles
        AWS->>awsp: Profile list
        awsp->>User: Interactive selection menu
        User->>awsp: Select profile
        awsp->>Config: Set AWS_PROFILE env
        alt --login flag
            awsp->>AWS: SSO login
            AWS->>awsp: Login complete
        end
        alt --verify flag
            awsp->>AWS: sts get-caller-identity
            AWS->>awsp: Identity info
            awsp->>User: Display identity (table or JSON)
        end
    end
```

## License

This repository is licensed under the MIT License. See the [LICENSE](LICENSE) file for more information.
