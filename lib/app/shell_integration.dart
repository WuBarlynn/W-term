/// Installs OSC 7 directory reporting in the current bash/zsh session. It is
/// not written to shell startup files; a new terminal needs to run it again.
const shellDirectoryIntegrationCommand =
    r'''if [ -n "$BASH_VERSION" ]; then PROMPT_COMMAND='printf "\033]7;file://%s%s\033\\" "$HOSTNAME" "$PWD"'; elif [ -n "$ZSH_VERSION" ]; then precmd() { printf '\033]7;file://%s%s\033\\' "$HOST" "$PWD"; }; else echo "W Term: directory reporting supports bash/zsh only"; fi''';

/// fish uses a prompt event instead of PROMPT_COMMAND/precmd. The command is
/// injected into the current session only; it never edits config.fish.
const fishDirectoryIntegrationCommand =
    r'''function __wterm_osc7 --on-event fish_prompt; printf '\033]7;file://%s%s\033\\' $hostname $PWD; end; __wterm_osc7''';

String shellDirectoryIntegrationCommandFor(String shell) => shell == 'fish'
    ? fishDirectoryIntegrationCommand
    : shellDirectoryIntegrationCommand;
