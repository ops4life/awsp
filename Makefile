# Makefile for awsp
# - Installs to ~/.config/awsp and adds a source line to common rc files.
# - Uninstall removes ALL traces and edits rc files (no backups, no stubs).

.ONESHELL:
SHELL := /bin/sh

PREFIX ?= $(HOME)/.config/awsp

RC_FILES := \
  $(HOME)/.zshrc \
  $(HOME)/.zprofile \
  $(HOME)/.bashrc \
  $(HOME)/.bash_profile \
  $(HOME)/.profile

SRC_LINE := [ -f "$(PREFIX)/awsp.sh" ] && . "$(PREFIX)/awsp.sh"

.PHONY: install uninstall

install:
	@PREFIX="$(PREFIX)" sh scripts/preflight.sh
	@mkdir -p "$(PREFIX)/completions"
	@cp -f bin/awsp.sh "$(PREFIX)/awsp.sh"
	@cp -f completions/awsp.bash "$(PREFIX)/completions/awsp.bash"
	@cp -f completions/_awsp.zsh "$(PREFIX)/completions/_awsp.zsh"
	@cp -f completions/_awsp.zsh "$(PREFIX)/completions/_awsp"
	@for rc in $(RC_FILES); do \
		touch "$$rc"; \
		grep -Fqs '$(SRC_LINE)' "$$rc" || printf "\n$(SRC_LINE)\n" >> "$$rc"; \
	done
	@echo "Installed to $(PREFIX)."
	@echo "Added source line to: $(RC_FILES)"
	@echo 'Reload your shell or run: . "$(PREFIX)/awsp.sh"'

uninstall:
	@set -eu
	# Build a sed script (portable) to delete any awsp sourcing/completion lines
	TMP="$$(mktemp)"
	cat >"$$TMP" <<'SEDEND'
	/\[ -f ".*\.config\/awsp\/awsp\.sh" \] && \. ".*\.config\/awsp\/awsp\.sh"/d
	/^[[:space:]]*\.[[:space:]]\+\".*\.config\/awsp\/awsp\.sh\"/d
	/^[[:space:]]*source[[:space:]]\+\"\{0,1\}.*\.config\/awsp\/awsp\.sh\"\{0,1\}/d
	/\.config\/awsp\/awsp\.sh/d
	/compdef[[:space:]]\+_awsp[[:space:]]\+awsp/d
	/_awsp\.zsh/d
	/awsp\.bash/d
	SEDEND
	# GNU vs BSD/macOS sed in-place handling (no backups)
	if sed --version >/dev/null 2>&1; then
		for RC in $(RC_FILES); do
			[ -f "$$RC" ] || continue
			sed -i -f "$$TMP" "$$RC" || true
		done
	else
		for RC in $(RC_FILES); do
			[ -f "$$RC" ] || continue
			sed -i "" -f "$$TMP" "$$RC" || true
		done
	fi
	rm -f "$$TMP"
	# Remove install directory entirely (safe even if we're inside it)
	case "$$PWD" in \
		"$(PREFIX)"|"$(PREFIX)/"*) \
			cd "$$HOME" && rm -rf "$(PREFIX)" ;; \
		*) \
			rm -rf "$(PREFIX)" ;; \
	esac
	printf '✓ Fully uninstalled awsp and cleaned rc files: %s\n' "$(RC_FILES)"
