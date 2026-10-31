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

// OSC 133;D is emitted just before the next prompt. It lets the app finish a
// command notification immediately instead of waiting for output to go idle.
const bashCommandFinishedIntegrationCommand =
    r'''__wterm_done() { printf '\033]133;D;%s\007' "$?"; }; PROMPT_COMMAND="__wterm_done${PROMPT_COMMAND:+; $PROMPT_COMMAND}"''';
const zshCommandFinishedIntegrationCommand =
    r'''autoload -Uz add-zsh-hook; __wterm_done() { printf '\033]133;D;%s\007' "$?"; }; add-zsh-hook precmd __wterm_done''';
const fishCommandFinishedIntegrationCommand =
    r'''function __wterm_done --on-event fish_postexec; printf '\033]133;D;%s\007' $status; end''';

String shellCommandFinishedIntegrationCommandFor(String shell) =>
    switch (shell) {
      'bash' => bashCommandFinishedIntegrationCommand,
      'zsh' => zshCommandFinishedIntegrationCommand,
      'fish' => fishCommandFinishedIntegrationCommand,
      _ => bashCommandFinishedIntegrationCommand,
    };

/// Portable across bash/zsh/fish: ask the current shell to report itself via
/// OSC 9, which the terminal session parses without displaying anything.
const shellProbeCommand = r'''printf '\033]9;shell;%s\007' "$SHELL"''';
