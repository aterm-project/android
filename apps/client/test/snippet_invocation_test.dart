import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/snippet_invocation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SnippetRecord compatibility and structured DTO', () {
    test('old script DTOs still parse and serialize without new fields', () {
      final snippet = SnippetRecord.fromJson({
        'id': 'old-snippet',
        'type': 'snippet',
        'title': 'Legacy',
        'body': 'echo old',
        'shell_kind': 'bash',
      });

      expect(snippet.executionMode, SnippetExecutionMode.script);
      expect(snippet.body, 'echo old');
      expect(snippet.arguments, isEmpty);
      expect(snippet.parameters, isEmpty);
      expect(snippet.toJson(), isNot(contains('execution_mode')));
      expect(snippet.toJson(), isNot(contains('arguments')));
      expect(snippet.toJson(), isNot(contains('parameters')));
    });

    test('structured DTO round-trips only the credential reference ID', () {
      final snippet = SnippetRecord(
        id: 'structured',
        title: 'Search',
        body: '',
        executionMode: SnippetExecutionMode.bashCommand,
        program: 'grep',
        parameters: const [
          SnippetParameter.text(name: 'pattern'),
          SnippetParameter.credential(
            name: 'token',
            credentialId: 'credential-reference-id',
          ),
        ],
        arguments: const [
          SnippetArgument.literal('-e'),
          SnippetArgument.reference('pattern'),
          SnippetArgument.reference('token'),
        ],
      );

      final encoded = jsonEncode(snippet.toJson());
      expect(encoded, contains('credential-reference-id'));
      expect(encoded, isNot(contains('credential-secret-value')));
      final parsed = SnippetRecord.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(parsed.executionMode, SnippetExecutionMode.bashCommand);
      expect(parsed.parameters.last.credentialId, 'credential-reference-id');
      expect(
        parsed.arguments.map((item) => item.toJson()).toList(),
        snippet.arguments.map((item) => item.toJson()).toList(),
      );
    });

    test('rejects secret-shaped or unknown parameter and argv fields', () {
      expect(
        () => SnippetParameter.fromJson({
          'name': 'token',
          'type': 'credentialSecret',
          'credential_id': 'credential-id',
          'default': 'do-not-store',
        }),
        throwsFormatException,
      );
      expect(
        () => SnippetParameter.fromJson({
          'name': 'token',
          'type': 'credentialSecret',
          'credential_id': 'credential-id',
          'secret': 'do-not-store',
        }),
        throwsFormatException,
      );
      expect(
        () => SnippetArgument.fromJson({
          'kind': 'literal',
          'value': 'arg',
          'expression': 'not-a-literal',
        }),
        throwsFormatException,
      );
    });
  });

  group('Bash structured snippet validation and quoting', () {
    test('preview renders bidi and invisible controls explicitly', () {
      const body =
          'echo safe\u202ehidden\u200b\u2028\u2029\u034f\ufe0f\u{e0100}';
      final preview = previewSnippetInvocation(
        const SnippetRecord(
          id: 'hidden-text',
          title: 'Visible preview',
          body: body,
        ),
      );

      expect(preview.command, body);
      expect(
        formatSnippetPreviewText(preview.command),
        'echo safe\\u{202e}hidden\\u{200b}\\u{2028}\\u{2029}\\u{34f}\\u{fe0f}\\u{e0100}',
      );
    });

    test(
      'quotes program and each argv word, including apostrophes and empty text',
      () {
        final snippet = _command(
          arguments: const [
            SnippetArgument.literal(''),
            SnippetArgument.literal("it's safe"),
            SnippetArgument.reference('input'),
          ],
          parameters: const [SnippetParameter.text(name: 'input')],
        );

        expect(
          buildSnippetCommand(snippet, values: const {'input': 'two words'}),
          "'tool path' '' 'it'\\''s safe' 'two words'",
        );
      },
    );

    test('metacharacters in text stay inside one quoted argv word', () {
      const attack = "x'; touch /tmp/should-not-run; echo '";
      final command = buildSnippetCommand(
        _command(
          arguments: const [SnippetArgument.reference('input')],
          parameters: const [SnippetParameter.text(name: 'input')],
        ),
        values: const {'input': attack},
      );

      expect(
        command,
        "'tool path' 'x'\\''; touch /tmp/should-not-run; echo '\\'''",
      );
    });

    test('exec request safely wraps the Bash payload as one login-shell word', () {
      const attack = "x'; touch /tmp/not-run; echo '";
      final request = buildBashExecRequest(
        _command(
          arguments: const [SnippetArgument.reference('input')],
          parameters: const [SnippetParameter.text(name: 'input')],
        ),
        values: const {'input': attack},
      );
      final payload = buildSnippetCommand(
        _command(
          arguments: const [SnippetArgument.reference('input')],
          parameters: const [SnippetParameter.text(name: 'input')],
        ),
        values: const {'input': attack},
      );
      final outerQuotedPayload = "'${payload.replaceAll("'", "'\\''")}'";

      expect(
        request,
        startsWith(
          'bash_path=; if [ -x /bin/bash ]; then bash_path=/bin/bash;',
        ),
      );
      expect(
        request,
        contains('elif [ -x /usr/bin/bash ]; then bash_path=/usr/bin/bash;'),
      );
      expect(
        request,
        contains(
          'elif [ -x /usr/local/bin/bash ]; then bash_path=/usr/local/bin/bash;',
        ),
      );
      expect(
        request,
        contains(
          r'else bash_path=$(command -v bash 2>/dev/null); fi; if [ -n "$bash_path" ] && [ -x "$bash_path" ]; then exec "$bash_path" -c ',
        ),
      );
      expect(request, contains(outerQuotedPayload));
      expect(request.split(outerQuotedPayload), hasLength(2));
      expect(
        request,
        endsWith(
          "else printf '%s\\n' '__ATERMIUS_BASH_UNAVAILABLE__' >&2; exit 127; fi",
        ),
      );
    });

    test(
      'Credential values stay out of the command string and arrive as literal argv data',
      () async {
        if (!Platform.isLinux || !File('/bin/sh').existsSync()) return;
        final directory = await Directory.systemTemp.createTemp(
          'atermius-snippet-secret-',
        );
        try {
          final injectionTarget = File('${directory.path}/injected');
          final secret = "literal ' ; touch ${injectionTarget.path} ; echo '";
          final snippet = _command(
            program: 'printf',
            arguments: const [
              SnippetArgument.literal('%s\\n'),
              SnippetArgument.reference('token'),
            ],
            parameters: const [
              SnippetParameter.credential(
                name: 'token',
                credentialId: 'password-credential',
              ),
            ],
          );
          final preview = previewSnippetInvocation(
            snippet,
            credentialParametersAvailable: const {'token'},
          );
          final request = buildBashExecRequest(
            snippet,
            credentialSecrets: {'token': secret},
          );
          final stdin = buildSnippetCredentialInput(
            snippet,
            credentialSecrets: {'token': secret},
          );

          expect(preview.canExecute, isTrue);
          expect(preview.command, contains('Credential secret hidden: token'));
          expect(preview.command, isNot(contains(secret)));
          expect(request, contains('IFS= read -r ATERMIUS_SNIPPET_SECRET_0'));
          expect(request, isNot(contains(secret)));
          expect(String.fromCharCodes(stdin), '$secret\n');

          final process = await Process.start('/bin/sh', ['-c', request]);
          process.stdin.add(stdin);
          await process.stdin.close();
          stdin.fillRange(0, stdin.length, 0);
          final output = await process.stdout.transform(utf8.decoder).join();
          final errors = await process.stderr.transform(utf8.decoder).join();
          final exitCode = await process.exitCode;
          expect(exitCode, 0, reason: 'shell wrapper failed');
          expect(errors, isEmpty);
          expect(output, '$secret\n');
          expect(await injectionTarget.exists(), isFalse);
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );

    test(
      'unused Credential parameters do not shift the referenced secret stdin slot',
      () async {
        if (!Platform.isLinux || !File('/bin/sh').existsSync()) return;
        const secret = 'referenced-secret';
        final snippet = _command(
          program: 'printf',
          arguments: const [
            SnippetArgument.literal('%s\\n'),
            SnippetArgument.reference('used'),
          ],
          parameters: const [
            SnippetParameter.credential(
              name: 'unused',
              credentialId: 'unused-credential',
            ),
            SnippetParameter.credential(
              name: 'used',
              credentialId: 'used-credential',
            ),
          ],
        );
        final request = buildBashExecRequest(
          snippet,
          credentialSecrets: const {'used': secret},
        );
        final stdin = buildSnippetCredentialInput(
          snippet,
          credentialSecrets: const {'used': secret},
        );
        try {
          expect(String.fromCharCodes(stdin), '$secret\n');
          expect(request, contains('ATERMIUS_SNIPPET_SECRET_0'));
          expect(request, isNot(contains('ATERMIUS_SNIPPET_SECRET_1')));

          final process = await Process.start('/bin/sh', ['-c', request]);
          process.stdin.add(stdin);
          await process.stdin.close();
          final output = await process.stdout.transform(utf8.decoder).join();
          final errors = await process.stderr.transform(utf8.decoder).join();
          final exitCode = await process.exitCode;
          expect(exitCode, 0, reason: 'shell wrapper failed');
          expect(errors, isEmpty);
          expect(output, '$secret\n');
        } finally {
          stdin.fillRange(0, stdin.length, 0);
        }
      },
    );

    test(
      'absolute Bash lookup works with a restricted login-shell PATH',
      () async {
        if (!Platform.isLinux ||
            !File('/bin/sh').existsSync() ||
            !(File('/bin/bash').existsSync() ||
                File('/usr/bin/bash').existsSync() ||
                File('/usr/local/bin/bash').existsSync())) {
          return;
        }

        final directory = await Directory.systemTemp.createTemp(
          'atermius-bash-path-',
        );
        try {
          final invocations = File('${directory.path}/invocations');
          final injectionTarget = File('${directory.path}/injected');
          final text = '\$(touch ${injectionTarget.path})_literal';
          final script = "printf '%s\\n' \"\$1\" >> '${invocations.path}'";
          final snippet = _command(
            program: '/bin/sh',
            arguments: [
              const SnippetArgument.literal('-c'),
              SnippetArgument.literal(script),
              const SnippetArgument.literal('snippet'),
              const SnippetArgument.reference('payload'),
            ],
            parameters: const [SnippetParameter.text(name: 'payload')],
          );
          final request = buildBashExecRequest(
            snippet,
            values: {'payload': text},
          );

          final result = await Process.run(
            '/bin/sh',
            ['-c', request],
            environment: const {'PATH': ''},
            runInShell: false,
          );

          final stderr = result.stderr.toString();
          if (result.exitCode != 0) {
            final lower = stderr.toLowerCase();
            print(
              'Restricted PATH Bash execution safe diagnostic ${jsonEncode({'exitCode': result.exitCode, 'stdoutLength': result.stdout.toString().length, 'stderrLength': stderr.length, 'availabilityMarker': stderr.split(RegExp(r'\r?\n')).contains('__ATERMIUS_BASH_UNAVAILABLE__'), 'noSuchFile': lower.contains('no such file'), 'commandNotFound': lower.contains('not found'), 'syntaxError': lower.contains('syntax error'), 'unexpectedEnd': lower.contains('unexpected end'), 'permissionDenied': lower.contains('permission denied'), 'badSubstitution': lower.contains('bad substitution')})}',
            );
          }
          expect(
            stderr
                .split(RegExp(r'\r?\n'))
                .contains('__ATERMIUS_BASH_UNAVAILABLE__'),
            isFalse,
          );
          expect(stderr.length, 0);
          expect(result.exitCode, 0);
          expect(await invocations.readAsLines(), [text]);
          expect(await injectionTarget.exists(), isFalse);
        } finally {
          await directory.delete(recursive: true);
        }
      },
    );

    test('Bash availability marker can be unique to an execution', () {
      const marker = '__ATERMIUS_BASH_UNAVAILABLE_test-nonce__';
      final request = buildBashExecRequest(
        _command(),
        bashUnavailableMarker: marker,
      );

      expect(
        request,
        endsWith("else printf '%s\\n' '$marker' >&2; exit 127; fi"),
      );
      expect(
        () => buildBashExecRequest(
          _command(),
          bashUnavailableMarker: 'user supplied text',
        ),
        throwsFormatException,
      );
    });

    test(
      'structured text-only previews are executable, even when shell-looking',
      () {
        final preview = previewSnippetInvocation(
          _command(
            arguments: const [SnippetArgument.reference('input')],
            parameters: const [SnippetParameter.text(name: 'input')],
          ),
          values: const {'input': r'$(id)'},
        );

        expect(preview.canExecute, isTrue);
        expect(preview.blockedReason, isNull);
        expect(preview.command, "'tool path' '\$(id)'");
      },
    );

    test('rejects invalid and duplicate names and undefined references', () {
      expect(
        () => validateSnippetDefinition(
          _command(arguments: const [SnippetArgument.reference('missing')]),
        ),
        throwsFormatException,
      );
      expect(
        () => validateSnippetDefinition(
          _command(
            parameters: const [
              SnippetParameter.text(name: 'same'),
              SnippetParameter.text(name: 'same'),
            ],
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => validateSnippetDefinition(
          _command(
            parameters: const [SnippetParameter.text(name: 'not-valid')],
          ),
        ),
        throwsFormatException,
      );
    });

    test(
      'template and shell-looking text stays literal in explicitly typed values',
      () {
        for (final literal in [
          '{{unknown}}',
          '{{{nested}}}',
          r'$HOME',
          r'$(id)',
          '`id`',
        ]) {
          expect(
            buildSnippetCommand(
              _command(arguments: [SnippetArgument.literal(literal)]),
            ),
            "'tool path' '$literal'",
          );
        }
      },
    );

    test('rejects control characters in definitions and entered text', () {
      for (final invalid in [
        'nul\u0000x',
        'line\rbreak',
        'line\nbreak',
        'tab\tvalue',
      ]) {
        expect(
          () => validateSnippetDefinition(
            _command(arguments: [SnippetArgument.literal(invalid)]),
          ),
          throwsFormatException,
        );
        expect(
          () => buildSnippetCommand(
            _command(
              arguments: const [SnippetArgument.reference('input')],
              parameters: const [SnippetParameter.text(name: 'input')],
            ),
            values: {'input': invalid},
          ),
          throwsFormatException,
        );
      }
    });

    test('requires supplied text and rejects unrecognized value names', () {
      final snippet = _command(
        arguments: const [SnippetArgument.reference('input')],
        parameters: const [SnippetParameter.text(name: 'input')],
      );
      expect(() => buildSnippetCommand(snippet), throwsFormatException);
      for (final literal in [r'${HOME}', r'$HOME', r'$(id)', '`id`']) {
        final command = buildSnippetCommand(
          snippet,
          values: {'input': literal},
        );
        expect(
          command,
          "'tool path' '$literal'",
          reason: 'text parameters are literal argv data, not expressions',
        );
      }
      expect(
        () => buildSnippetCommand(snippet, values: const {'other': 'value'}),
        throwsFormatException,
      );
    });

    test(
      'plain command builder refuses secret references without SSH context',
      () {
        final snippet = _command(
          arguments: const [SnippetArgument.reference('secret')],
          parameters: const [
            SnippetParameter.credential(
              name: 'secret',
              credentialId: 'credential-id-only',
            ),
          ],
        );
        final preview = previewSnippetInvocation(snippet);

        expect(preview.hasCredentialReference, isTrue);
        expect(preview.canExecute, isFalse);
        expect(preview.command, contains('Credential secret hidden'));
        expect(preview.command, isNot(contains('actual-password')));
        expect(
          () => buildSnippetCommand(snippet),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('confirmed SSH exec channel'),
            ),
          ),
        );
      },
    );

    test(
      'rejects non-Bash structured snippets and expression-shaped arguments',
      () {
        expect(
          () => validateSnippetDefinition(_command(shell: 'powershell')),
          throwsFormatException,
        );
        expect(
          () => SnippetArgument.fromJson({'kind': 'expression', 'value': 'id'}),
          throwsFormatException,
        );
      },
    );
  });
}

SnippetRecord _command({
  String shell = 'bash',
  String program = 'tool path',
  List<SnippetArgument> arguments = const [],
  List<SnippetParameter> parameters = const [],
}) => SnippetRecord(
  id: 'snippet-id',
  title: 'Test command',
  body: '',
  shell: shell,
  executionMode: SnippetExecutionMode.bashCommand,
  program: program,
  arguments: arguments,
  parameters: parameters,
);
