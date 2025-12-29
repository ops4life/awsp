# bash completion for awsp
_awsp_complete() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  case "$prev" in
    -h|--help|-V|--version|-l|--list|-c|--current|-u|--unset|-U|--upgrade|-L|--login|-v|--verify|--no-verify|--json|-q|--quiet) return 0 ;;
  esac
  if command -v aws >/dev/null 2>&1; then
    mapfile -t COMPREPLY < <(compgen -W "$(aws configure list-profiles 2>/dev/null)" -- "$cur")
  else
    COMPREPLY=()
  fi
}
complete -F _awsp_complete awsp
