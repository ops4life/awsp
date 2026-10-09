#!/bin/sh
# Build release artifacts into ./dist:
#   awsp-<version>.tar.gz         (top-level dir awsp-<version>/)
#   awsp-<version>.tar.gz.sha256
#   awsp-<version>.zip            (+ .sha256; Windows/PowerShell files)
#   awsp_<version>_all.deb
# Usage: scripts/build-release.sh <version>
set -eu

version="${1:?usage: build-release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dist="$root/dist"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rm -rf "$dist"
mkdir -p "$dist"

# --- tarball ---
stage="$work/awsp-$version"
mkdir -p "$stage/bin" "$stage/completions"
cp "$root/bin/awsp.sh" "$stage/bin/"
cp "$root/completions/"* "$stage/completions/"
cp "$root/LICENSE" "$root/README.md" "$stage/"
tar -C "$work" -czf "$dist/awsp-$version.tar.gz" "awsp-$version"
(cd "$dist" && sha256sum "awsp-$version.tar.gz" > "awsp-$version.tar.gz.sha256")

# --- zip (Windows / PowerShell) ---
zstage="$work/zip/awsp-$version"
mkdir -p "$zstage/bin" "$zstage/completions"
cp "$root/bin/awsp.ps1" "$root/bin/awsp-profile.ps1" "$zstage/bin/"
cp "$root/completions/awsp.completion.ps1" "$zstage/completions/"
cp "$root/LICENSE" "$root/README.md" "$zstage/"
(cd "$work/zip" && python3 -m zipfile -c "$dist/awsp-$version.zip" "awsp-$version")
(cd "$dist" && sha256sum "awsp-$version.zip" > "awsp-$version.zip.sha256")

# --- .deb ---
pkg="$work/deb"
install -d "$pkg/DEBIAN" \
  "$pkg/usr/share/awsp" \
  "$pkg/usr/share/bash-completion/completions" \
  "$pkg/usr/share/zsh/vendor-completions" \
  "$pkg/usr/share/doc/awsp"
install -m 0644 "$root/bin/awsp.sh" "$pkg/usr/share/awsp/awsp.sh"
install -m 0644 "$root/completions/awsp.bash" "$pkg/usr/share/bash-completion/completions/awsp"
install -m 0644 "$root/completions/_awsp.zsh" "$pkg/usr/share/zsh/vendor-completions/_awsp"
install -m 0644 "$root/LICENSE" "$pkg/usr/share/doc/awsp/copyright"

cat > "$pkg/DEBIAN/control" <<CTL
Package: awsp
Version: $version
Section: utils
Priority: optional
Architecture: all
Suggests: awscli
Maintainer: ops4life <ops4life@users.noreply.github.com>
Homepage: https://github.com/ops4life/awsp
Description: Lightweight cross-shell AWS profile switcher with SSO auto-login
 awsp is a shell function for Bash and Zsh. It must be sourced from your
 shell rc file to modify the current environment.
CTL

cat > "$pkg/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
  echo "awsp installed. Add this line to ~/.bashrc or ~/.zshrc:"
  echo "  [ -f /usr/share/awsp/awsp.sh ] && . /usr/share/awsp/awsp.sh"
fi
exit 0
POST
chmod 0755 "$pkg/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "$pkg" "$dist/awsp_${version}_all.deb" >/dev/null
echo "Built artifacts in $dist:"
ls -1 "$dist"
