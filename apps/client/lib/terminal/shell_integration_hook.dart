import 'dart:convert';

final RegExp _sessionNoncePattern = RegExp(r'^[A-Za-z0-9_-]{22}$');
final RegExp _terminalIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// Builds a one-line, explicitly invoked Bash setup command for OSC 777 v1.
///
/// The returned command only defines in-memory shell functions and prepends
/// one function to `PROMPT_COMMAND`; it does not write shell startup files,
/// create remote files, or execute the command text it observes. Once pasted
/// into an interactive Bash 4.1+ shell, each recorded history line is emitted as a
/// paired start/end event immediately before the next prompt. Existing prompt
/// hooks are retained and run after the Atermius hook.
///
/// `atermius_redact_next` skips itself and the following command. Setting
/// `ATERMIUS_SHELL_INTEGRATION=0` pauses capture while leaving the prompt hook
/// installed; `atermius_off` disables capture and removes the hook from
/// `PROMPT_COMMAND` where its current form permits.
///
/// The nonce and terminal ID are validated before shell interpolation. The
/// nonce must be the canonical unpadded base64url encoding of exactly 128 bits.
class ShellIntegrationHook {
  static String buildBashCommand({
    required String sessionNonce,
    required String terminalId,
  }) {
    if (!_isCanonicalSessionNonce(sessionNonce) ||
        !_terminalIdPattern.hasMatch(terminalId)) {
      throw ArgumentError('Invalid shell-integration session binding.');
    }

    return <String>[
      r'if [[ $- == *i* && -t 0 && -t 1 ]] && (( BASH_VERSINFO[0]*100+BASH_VERSINFO[1]>=401 )); then',
      r"__atermius_nonce='@@NONCE@@';",
      r"__atermius_terminal='@@TERMINAL@@';",
      r'__atermius_enabled=1;',
      r'ATERMIUS_SHELL_INTEGRATION=1;',
      r'__atermius_command_id=0;',
      r'__atermius_last_histcmd=${HISTCMD:-0};',
      r'__atermius_redact_marker=0;',
      r'__atermius_redact_pending=0;',
      r'if [[ ${__atermius_installed:-0} != 1 ]]; then',
      r"""__atermius_prompt() { local __at_status=$? __at_cmd __at_encoded __at_rfd __at_wfd __at_pid __at_histcmd=${HISTCMD:-0} LC_ALL=C; if [[ ${__atermius_skip_current:-0} == 1 ]]; then __atermius_skip_current=0; __atermius_last_histcmd=$__at_histcmd; return "$__at_status"; fi; if [[ ${__atermius_redact_marker:-0} == 1 ]]; then __atermius_redact_marker=0; __atermius_redact_pending=1; __atermius_last_histcmd=$__at_histcmd; return "$__at_status"; fi; if [[ ${__atermius_redact_pending:-0} == 1 ]]; then __atermius_redact_pending=0; __atermius_last_histcmd=$__at_histcmd; return "$__at_status"; fi; if [[ $__at_histcmd == "${__atermius_last_histcmd:-}" ]]; then return "$__at_status"; fi; __atermius_last_histcmd=$__at_histcmd; if [[ ${ATERMIUS_SHELL_INTEGRATION:-1} != 1 || ${__atermius_enabled:-0} != 1 ]]; then return "$__at_status"; fi; coproc __atermius_fc_capture { command cat; }; __at_rfd=${__atermius_fc_capture[0]}; __at_wfd=${__atermius_fc_capture[1]}; __at_pid=$__atermius_fc_capture_PID; builtin fc -ln -1 >&"$__at_wfd" 2>/dev/null; exec {__at_wfd}>&-; IFS= read -r -d '' __at_cmd <&"$__at_rfd" || :; exec {__at_rfd}<&-; wait "$__at_pid" 2>/dev/null || :; unset __atermius_fc_capture __atermius_fc_capture_PID; __at_cmd=${__at_cmd#$'\t '}; __at_cmd=${__at_cmd%$'\n'}; if [[ $__at_cmd == *[$'\001'-$'\010'$'\013'-$'\037'$'\177']* || $__at_cmd == *$'\302'[$'\200'-$'\237']* ]]; then return "$__at_status"; fi; if (( ${#__at_cmd} > 4096 )); then return "$__at_status"; fi; __at_encoded=$(printf '%s' "$__at_cmd" | command base64 2>/dev/null | command tr -d '=\r\n' | command tr '+/' '-_'); if [[ ! $__at_encoded =~ ^[A-Za-z0-9_-]+$ ]]; then return "$__at_status"; fi; if (( __atermius_command_id >= 9007199254740990 )); then __atermius_enabled=0; return "$__at_status"; fi; __atermius_command_id=$((__atermius_command_id + 1)); printf '\033]777;atermius;v1;%s;%s;%s;start;%s\007\033]777;atermius;v1;%s;%s;%s;end;%s\007' "$__atermius_nonce" "$__atermius_terminal" "$__atermius_command_id" "$__at_encoded" "$__atermius_nonce" "$__atermius_terminal" "$__atermius_command_id" "$__at_status" > /dev/tty 2>/dev/null; return "$__at_status"; };""",
      r'atermius_redact_next() { __atermius_redact_marker=1; };',
      r"""atermius_off() { __atermius_enabled=0; ATERMIUS_SHELL_INTEGRATION=0; if [[ ${__atermius_prompt_kind:-} == array && $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then local -a __at_rest=(); local __at_item __at_removed=0; for __at_item in "${PROMPT_COMMAND[@]}"; do if [[ $__at_removed == 0 && $__at_item == __atermius_prompt ]]; then __at_removed=1; else __at_rest+=("$__at_item"); fi; done; PROMPT_COMMAND=("${__at_rest[@]}"); elif [[ ${__atermius_prompt_kind:-} == scalar && $(declare -p PROMPT_COMMAND 2>/dev/null) != 'declare -a'* ]]; then case ${PROMPT_COMMAND-} in __atermius_prompt) PROMPT_COMMAND= ;; "__atermius_prompt; "*) PROMPT_COMMAND=${PROMPT_COMMAND#__atermius_prompt; } ;; esac; fi; unset __atermius_installed __atermius_nonce __atermius_terminal __atermius_command_id __atermius_last_histcmd __atermius_skip_current __atermius_redact_marker __atermius_redact_pending __atermius_prompt_kind; return 0; };""",
      r"""if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then __atermius_prompt_kind=array; PROMPT_COMMAND=(__atermius_prompt "${PROMPT_COMMAND[@]}"); else __atermius_prompt_kind=scalar; PROMPT_COMMAND="__atermius_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"; fi;""",
      r'__atermius_installed=1;',
      r'fi;',
      r'__atermius_skip_current=1;',
      r'fi',
    ].join(' ').replaceAll('@@NONCE@@', sessionNonce).replaceAll('@@TERMINAL@@', terminalId);
  }
}

bool _isCanonicalSessionNonce(String nonce) {
  if (!_sessionNoncePattern.hasMatch(nonce)) return false;
  try {
    final bytes = base64Url.decode('$nonce==');
    return bytes.length == 16 &&
        base64Url.encode(bytes).replaceAll('=', '') == nonce;
  } on FormatException {
    return false;
  }
}
