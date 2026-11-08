import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/terminal/shell_integration_hook.dart';

void main() {
  group('ShellIntegrationHook.buildBashCommand', () {
    test('accepts only a canonical 128-bit base64url nonce', () {
      const nonce = 'AAAAAAAAAAAAAAAAAAAAAA';
      expect(
        () => ShellIntegrationHook.buildBashCommand(
          sessionNonce: nonce,
          terminalId: 'tab-1',
        ),
        returnsNormally,
      );

      for (final invalidNonce in [
        '',
        'AAAAAAAAAAAAAAAAAAAAA',
        'AAAAAAAAAAAAAAAAAAAAAAA',
        'AAAAAAAAAAAAAAAAAAAAAB', // Non-zero unused low bits.
        'AAAAAAAAAAAAAAAAAAAAAA=',
        'AAAAAAAAAAAAAAAAAAAAA+',
        'AAAAAAAAAAAAAAAAAAAAA/',
        'AAAAAAAAAAAAAAAAAAAAA;',
      ]) {
        expect(
          () => ShellIntegrationHook.buildBashCommand(
            sessionNonce: invalidNonce,
            terminalId: 'tab-1',
          ),
          throwsArgumentError,
          reason: 'must reject nonce $invalidNonce',
        );
      }
    });

    test(
      'validates the terminal ID grammar and length before interpolation',
      () {
        final longestAllowedId = 'a${List<String>.filled(127, 'x').join()}';
        expect(
          ShellIntegrationHook.buildBashCommand(
            sessionNonce: 'AAAAAAAAAAAAAAAAAAAAAA',
            terminalId: longestAllowedId,
          ),
          contains("__atermius_terminal='$longestAllowedId'"),
        );

        for (final invalidTerminalId in [
          '',
          '-tab',
          '_tab',
          'tab with space',
          'tab;touch /tmp/owned',
          "tab'\$(touch /tmp/owned)",
          'a${List<String>.filled(128, 'x').join()}',
        ]) {
          expect(
            () => ShellIntegrationHook.buildBashCommand(
              sessionNonce: 'AAAAAAAAAAAAAAAAAAAAAA',
              terminalId: invalidTerminalId,
            ),
            throwsArgumentError,
            reason: 'must reject terminal ID $invalidTerminalId',
          );
        }
      },
    );

    test('constructs paired, sequential OSC 777 v1 command records', () {
      final command = ShellIntegrationHook.buildBashCommand(
        sessionNonce: 'AAAAAAAAAAAAAAAAAAAAAA',
        terminalId: 'tab-1',
      );

      expect(command, isNot(contains('\n')));
      expect(command, contains("__atermius_nonce='AAAAAAAAAAAAAAAAAAAAAA'"));
      expect(command, contains("__atermius_terminal='tab-1'"));
      expect(command, contains("__atermius_command_id=0"));
      expect(command, contains('ATERMIUS_SHELL_INTEGRATION=1'));
      expect(
        command.indexOf("__atermius_nonce='AAAAAAAAAAAAAAAAAAAAAA'"),
        lessThan(command.indexOf(r'if [[ ${__atermius_installed:-0} != 1 ]]')),
        reason: 're-pasting must rebind an installed hook without a duplicate',
      );
      expect(
        command,
        contains(
          r"printf '\033]777;atermius;v1;%s;%s;%s;start;%s\007\033]777;atermius;v1;%s;%s;%s;end;%s\007'",
        ),
      );
      expect(
        command,
        contains(r'__atermius_command_id=$((__atermius_command_id + 1))'),
      );
      expect(command, contains(r'"$__at_status" > /dev/tty'));
      expect(command, contains(r'fc -ln -1'));
      expect(
        command,
        contains(r'coproc __atermius_fc_capture { command cat; }'),
      );
      expect(command, contains(r'builtin fc -ln -1 >&"$__at_wfd"'));
      expect(command, contains(r"__at_cmd=${__at_cmd#$'\t '};"));
      expect(command, contains(r"__at_cmd=${__at_cmd%$'\n'};"));
      expect(
        command,
        contains(r'''IFS= read -r -d '' __at_cmd <&"$__at_rfd"'''),
      );
      expect(command, contains(r'wait "$__at_pid" 2>/dev/null'));
      expect(command, isNot(contains(r'$(builtin fc')));
      expect(command, contains('LC_ALL=C'));
      expect(command, contains(r"[$'\001'-$'\010'$'\013'-$'\037'$'\177']"));
      expect(command, contains(r"$'\302'[$'\200'-$'\237']"));
      expect(command, contains(r'(( ${#__at_cmd} > 4096 ))'));
      expect(command, contains(r'command base64'));
      expect(command, contains(r"command tr -d '=\r\n'"));
      expect(command, contains(r"command tr '+/' '-_'"));
      expect(command, contains(r'9007199254740990'));
      expect(command, contains(r'"$__at_status"'));
      expect(command, contains(r'__atermius_last_histcmd'));
    });

    test(
      'keeps setup explicit and non-persistent with opt-out and cleanup hooks',
      () {
        final command = ShellIntegrationHook.buildBashCommand(
          sessionNonce: 'AAAAAAAAAAAAAAAAAAAAAA',
          terminalId: 'tab-1',
        );

        expect(command, contains(r'[[ $- == *i* && -t 0 && -t 1 ]]'));
        expect(
          command,
          contains(r'BASH_VERSINFO[0]*100+BASH_VERSINFO[1]>=401'),
        );
        expect(command, contains('PROMPT_COMMAND=(__atermius_prompt'));
        expect(
          command,
          contains(
            r'PROMPT_COMMAND="__atermius_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"',
          ),
        );
        expect(command, contains('atermius_redact_next()'));
        expect(command, contains('atermius_off()'));
        expect(command, contains('ATERMIUS_SHELL_INTEGRATION=0'));
        expect(
          command,
          contains(r'PROMPT_COMMAND=${PROMPT_COMMAND#__atermius_prompt; }'),
        );
        expect(command, contains('unset __atermius_installed'));
        expect(command, contains(r'__atermius_skip_current=1'));

        for (final forbidden in [
          '.bashrc',
          '.bash_profile',
          '.profile',
          'ssh ',
          'eval ',
          'source ',
          'bash -c',
          '/tmp/',
          'history -w',
        ]) {
          expect(command, isNot(contains(forbidden)), reason: forbidden);
        }
        expect(command, isNot(contains('PROMPT_COMMAND=;')));
        expect(command, isNot(contains('trap ')));
      },
    );

    test(
      'encodes protocol command payloads as canonical unpadded base64url',
      () {
        const sample = 'printf "café"';
        final encoded = base64Url
            .encode(utf8.encode(sample))
            .replaceAll('=', '');
        expect(encoded, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
        final padding = switch (encoded.length % 4) {
          2 => '==',
          3 => '=',
          _ => '',
        };
        expect(base64Url.decode('$encoded$padding'), utf8.encode(sample));

        final command = ShellIntegrationHook.buildBashCommand(
          sessionNonce: 'AAAAAAAAAAAAAAAAAAAAAA',
          terminalId: 'tab-1',
        );
        expect(command, contains(r'''printf '%s' "$__at_cmd"'''));
        expect(command, contains(r'__at_encoded'));
        expect(
          command.indexOf(r'(( ${#__at_cmd} > 4096 ))'),
          lessThan(command.indexOf('command base64')),
        );
        expect(
          command.indexOf('command base64'),
          lessThan(command.indexOf(r"printf '\033]777;atermius;v1;")),
        );
      },
    );
  });
}
