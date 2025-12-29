# zsh completion for awsp
_awsp() {
  local -a profiles
  if (( $+commands[aws] )); then
    profiles=("${(@f)$(aws configure list-profiles 2>/dev/null)}")
  else
    profiles=()
  fi
  _arguments \
    '-h[show help]' \
    '--help[show help]' \
    '-V[show version]' \
    '--version[show version]' \
    '-l[list profiles]' \
    '--list[list profiles]' \
    '-c[current profile]' \
    '--current[current profile]' \
    '-u[unset env]' \
    '--unset[unset env]' \
    '-U[upgrade awsp]' \
    '--upgrade[upgrade awsp]' \
    '-L[force sso login]' \
    '--login[force sso login]' \
    '-v[verify via STS]' \
    '--verify[verify via STS]' \
    '--no-verify[disable verify]' \
    '--json[output json]' \
    '-q[quiet]' \
    '--quiet[quiet]' \
    '1:profile:(( ${profiles[*]} ))'
}
