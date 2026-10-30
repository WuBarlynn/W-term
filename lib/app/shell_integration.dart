/// Installs OSC 7 directory reporting in the current bash/zsh session. It is
/// not written to shell startup files; a new terminal needs to run it again.
const shellDirectoryIntegrationCommand =
    r'''if [ -n "$BASH_VERSION" ]; then PROMPT_COMMAND='printf "\033]7;file://%s%s\033\\" "$HOSTNAME" "$PWD"'; elif [ -n "$ZSH_VERSION" ]; then precmd() { printf '\033]7;file://%s%s\033\\' "$HOST" "$PWD"; }; else echo "W Term: directory reporting supports bash/zsh only"; fi''';
