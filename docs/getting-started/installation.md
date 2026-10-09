# Installation

| Platform | Method | Command |
|---|---|---|
| macOS / Linux | [Homebrew](https://brew.sh/) | `brew tap ops4life/awsp && brew install awsp` |
| macOS / Linux / WSL | install script | `curl -fsSL https://raw.githubusercontent.com/ops4life/awsp/main/install.sh \| sh` |
| Debian / Ubuntu | `.deb` from [Releases](https://github.com/ops4life/awsp/releases) | `sudo dpkg -i awsp_<version>_all.deb` |
| Any | from source | `git clone https://github.com/ops4life/awsp.git && cd awsp && make install` |

`awsp` is a shell function, so a package can only install the files — your shell
must source them. After installing, add the matching line to `~/.bashrc` / `~/.zshrc`
(the install script and `make install` do this for you):

```bash
# Homebrew
[ -f "$(brew --prefix)/share/awsp/awsp.sh" ] && . "$(brew --prefix)/share/awsp/awsp.sh"
# .deb
[ -f /usr/share/awsp/awsp.sh ] && . /usr/share/awsp/awsp.sh
```

Upgrade with the same tool you installed with (`brew upgrade awsp`, re-run the install
script, or install the newer `.deb`). Windows is supported through WSL or Git Bash only.

<details>
<summary>Plugin managers (zsh)</summary>

```zsh
# zinit
zinit ice pick"bin/awsp.sh"
zinit light ops4life/awsp

# antidote (~/.zsh_plugins.txt)
ops4life/awsp path:bin/awsp.sh kind:source

# oh-my-zsh
git clone https://github.com/ops4life/awsp ~/.oh-my-zsh/custom/plugins/awsp
echo 'source ~/.oh-my-zsh/custom/plugins/awsp/bin/awsp.sh' >> ~/.zshrc
```

</details>
