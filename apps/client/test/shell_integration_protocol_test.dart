import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/terminal/shell_integration_protocol.dart';
import 'package:xterm/xterm.dart';

const _sessionNonce = 'AAAAAAAAAAAAAAAAAAAAAA';
final _otherSessionNonce = base64Url
    .encode([...List<int>.filled(15, 0), 1])
    .replaceAll('=', '');
const _terminalId = 'tab-1';
final _issuedAt = DateTime.utc(2026, 1, 1);

ShellIntegrationV1Decoder _decoder({
  String sessionNonce = _sessionNonce,
  String terminalId = _terminalId,
  DateTime? issuedAt,
  DateTime? expiresAt,
}) => ShellIntegrationV1Decoder(
  sessionNonce: sessionNonce,
  terminalId: terminalId,
  issuedAt: issuedAt ?? _issuedAt,
  expiresAt: expiresAt ?? _issuedAt.add(const Duration(hours: 10)),
);

String _base64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<String> _startArgs(
  String payload, {
  int commandId = 1,
  String sessionNonce = _sessionNonce,
  String terminalId = _terminalId,
  String version = 'v1',
}) => [
  'atermius',
  version,
  sessionNonce,
  terminalId,
  '$commandId',
  'start',
  payload,
];

List<String> _endArgs(
  String status, {
  int commandId = 1,
  String sessionNonce = _sessionNonce,
  String terminalId = _terminalId,
}) => ['atermius', 'v1', sessionNonce, terminalId, '$commandId', 'end', status];

void main() {
  group('ShellIntegrationV1Decoder', () {
    test('exposes a command only after its matching end/status event', () {
      final decoder = _decoder();
      const command = "printf 'caf\u00e9'";
      final startTime = _issuedAt.add(const Duration(seconds: 1));
      final endTime = _issuedAt.add(const Duration(seconds: 2));

      expect(
        decoder.accept(
          '777',
          _startArgs(_base64Url(utf8.encode(command))),
          now: startTime,
        ),
        ShellIntegrationDecodeResult.commandStarted,
      );
      expect(decoder.takeCompleted(), isEmpty);

      expect(
        decoder.accept('777', _endArgs('7'), now: endTime),
        ShellIntegrationDecodeResult.commandCompleted,
      );
      final completed = decoder.takeCompleted();
      expect(completed, hasLength(1));
      expect(completed.single.commandId, 1);
      expect(completed.single.command, command);
      expect(completed.single.exitStatus, 7);
      expect(completed.single.startedAt, startTime);
      expect(completed.single.completedAt, endTime);
      expect(decoder.takeCompleted(), isEmpty);
      expect(decoder.isClosed, isFalse);
    });

    test('matches the real xterm private OSC callback framing', () {
      final issuedAt = DateTime.now().toUtc();
      final decoder = _decoder(
        issuedAt: issuedAt,
        expiresAt: issuedAt.add(const Duration(hours: 1)),
      );
      final results = <ShellIntegrationDecodeResult>[];
      final terminal = Terminal(
        onPrivateOSC: (code, args) => results.add(decoder.accept(code, args)),
      );
      final encoded = _base64Url(utf8.encode('echo safe'));

      terminal.write(
        '\u001b]777;atermius;v1;$_sessionNonce;$_terminalId;1;start;$encoded\u0007',
      );
      terminal.write(
        '\u001b]777;atermius;v1;$_sessionNonce;$_terminalId;1;end;0\u0007',
      );

      expect(results, [
        ShellIntegrationDecodeResult.commandStarted,
        ShellIntegrationDecodeResult.commandCompleted,
      ]);
      expect(decoder.takeCompleted().single.command, 'echo safe');
    });

    test('ignores OSC codes and namespaces outside this protocol', () {
      final decoder = _decoder();

      expect(
        decoder.accept(
          '0',
          _startArgs(_base64Url(utf8.encode('ignored'))),
          now: _issuedAt,
        ),
        ShellIntegrationDecodeResult.ignored,
      );
      expect(
        decoder.accept('777', const ['other-app', 'v1'], now: _issuedAt),
        ShellIntegrationDecodeResult.ignored,
      );
      expect(
        decoder.accept('777', const [], now: _issuedAt),
        ShellIntegrationDecodeResult.ignored,
      );
      expect(decoder.isClosed, isFalse);
    });

    test('rejects stale session or tab events without affecting this tab', () {
      final decoder = _decoder();
      final encoded = _base64Url(utf8.encode('echo bound'));

      expect(
        decoder.accept(
          '777',
          _startArgs(encoded, sessionNonce: _otherSessionNonce),
          now: _issuedAt,
        ),
        ShellIntegrationDecodeResult.rejected,
      );
      expect(
        decoder.accept(
          '777',
          _startArgs(encoded, terminalId: 'tab-2'),
          now: _issuedAt,
        ),
        ShellIntegrationDecodeResult.rejected,
      );
      expect(decoder.isClosed, isFalse);

      expect(
        decoder.accept('777', _startArgs(encoded), now: _issuedAt),
        ShellIntegrationDecodeResult.commandStarted,
      );
      expect(
        decoder.accept('777', _endArgs('0'), now: _issuedAt),
        ShellIntegrationDecodeResult.commandCompleted,
      );
      expect(decoder.takeCompleted().single.command, 'echo bound');
    });

    test('closes on malformed framing, version, or unknown event kind', () {
      final malformedFrames = <List<String>>[
        const ['atermius'],
        _startArgs(_base64Url(utf8.encode('echo x')), version: 'v2'),
        [..._startArgs(_base64Url(utf8.encode('echo x'))), 'trailing'],
        [
          ..._startArgs(_base64Url(utf8.encode('echo x'))).take(5),
          'progress',
          'payload',
        ],
        [
          ..._startArgs(_base64Url(utf8.encode('echo x'))).take(4),
          '01',
          'start',
          _base64Url(utf8.encode('echo x')),
        ],
        [
          'atermius',
          'v1',
          'not-a-canonical-nonce',
          _terminalId,
          '1',
          'start',
          _base64Url(utf8.encode('echo x')),
        ],
        [
          'atermius',
          'v1',
          _sessionNonce,
          'tab with space',
          '1',
          'start',
          _base64Url(utf8.encode('echo x')),
        ],
        _endArgs('1000'),
      ];

      for (final frame in malformedFrames) {
        final decoder = _decoder();
        expect(
          decoder.accept('777', frame, now: _issuedAt),
          ShellIntegrationDecodeResult.rejected,
        );
        expect(decoder.isClosed, isTrue);
        expect(
          decoder.accept(
            '777',
            _startArgs(_base64Url(utf8.encode('later'))),
            now: _issuedAt,
          ),
          ShellIntegrationDecodeResult.closed,
        );
      }
    });

    test('rejects invalid base64url, UTF-8, and control bytes', () {
      final malformedPayloads = <String>[
        '*',
        'YQ==', // Padding is not part of the canonical wire format.
        'Zh', // Non-canonical low bits for a one-byte payload.
        _base64Url(const [0xff]),
        _base64Url(utf8.encode('echo\u001b[31mred')),
        _base64Url(utf8.encode('echo\u0000bad')),
        _base64Url(List<int>.filled(shellIntegrationMaxCommandBytes + 1, 0x61)),
      ];

      for (final payload in malformedPayloads) {
        final decoder = _decoder();
        expect(
          decoder.accept('777', _startArgs(payload), now: _issuedAt),
          ShellIntegrationDecodeResult.rejected,
        );
        expect(decoder.isClosed, isTrue);
        expect(decoder.takeCompleted(), isEmpty);
      }
    });

    test('rejects invalid exit statuses', () {
      for (final status in ['-1', '256', '01', '2x', '']) {
        final decoder = _decoder();
        expect(
          decoder.accept(
            '777',
            _startArgs(_base64Url(utf8.encode('echo status'))),
            now: _issuedAt,
          ),
          ShellIntegrationDecodeResult.commandStarted,
        );
        expect(
          decoder.accept('777', _endArgs(status), now: _issuedAt),
          ShellIntegrationDecodeResult.rejected,
        );
        expect(decoder.isClosed, isTrue);
        expect(decoder.takeCompleted(), isEmpty);
      }
    });

    test(
      'rejects end-before-start, duplicate, skipped, and mismatched IDs',
      () {
        final cases = <List<List<String>>>[
          [_endArgs('0')],
          [
            _startArgs(_base64Url(utf8.encode('echo once'))),
            _startArgs(_base64Url(utf8.encode('echo twice'))),
          ],
          [_startArgs(_base64Url(utf8.encode('echo skip')), commandId: 2)],
          [
            _startArgs(_base64Url(utf8.encode('echo mismatch'))),
            _endArgs('0', commandId: 2),
          ],
        ];

        for (final frames in cases) {
          final decoder = _decoder();
          for (final frame in frames.take(frames.length - 1)) {
            expect(
              decoder.accept('777', frame, now: _issuedAt),
              ShellIntegrationDecodeResult.commandStarted,
            );
          }
          expect(
            decoder.accept('777', frames.last, now: _issuedAt),
            ShellIntegrationDecodeResult.rejected,
          );
          expect(decoder.isClosed, isTrue);
          expect(decoder.takeCompleted(), isEmpty);
        }
      },
    );

    test('rejects replayed end events and discards queued completions', () {
      final decoder = _decoder();
      final command = _base64Url(utf8.encode('echo replay'));

      expect(
        decoder.accept('777', _startArgs(command), now: _issuedAt),
        ShellIntegrationDecodeResult.commandStarted,
      );
      expect(
        decoder.accept('777', _endArgs('0'), now: _issuedAt),
        ShellIntegrationDecodeResult.commandCompleted,
      );
      expect(
        decoder.accept('777', _endArgs('0'), now: _issuedAt),
        ShellIntegrationDecodeResult.rejected,
      );
      expect(decoder.takeCompleted(), isEmpty);
      expect(decoder.isClosed, isTrue);
    });

    test('bounds the completed queue and fails closed on overflow', () {
      final decoder = _decoder();
      for (
        var commandId = 1;
        commandId <= shellIntegrationCompletedQueueLimit;
        commandId++
      ) {
        final args = _startArgs(
          _base64Url(utf8.encode('echo $commandId')),
          commandId: commandId,
        );
        expect(
          decoder.accept('777', args, now: _issuedAt),
          ShellIntegrationDecodeResult.commandStarted,
        );
        expect(
          decoder.accept(
            '777',
            _endArgs('0', commandId: commandId),
            now: _issuedAt,
          ),
          ShellIntegrationDecodeResult.commandCompleted,
        );
      }
      expect(
        decoder.takeCompleted(),
        hasLength(shellIntegrationCompletedQueueLimit),
      );

      final fullDecoder = _decoder();
      for (
        var commandId = 1;
        commandId <= shellIntegrationCompletedQueueLimit;
        commandId++
      ) {
        expect(
          fullDecoder.accept(
            '777',
            _startArgs(
              _base64Url(utf8.encode('echo $commandId')),
              commandId: commandId,
            ),
            now: _issuedAt,
          ),
          ShellIntegrationDecodeResult.commandStarted,
        );
        expect(
          fullDecoder.accept(
            '777',
            _endArgs('0', commandId: commandId),
            now: _issuedAt,
          ),
          ShellIntegrationDecodeResult.commandCompleted,
        );
      }
      expect(
        fullDecoder.accept(
          '777',
          _startArgs(
            _base64Url(utf8.encode('overflow')),
            commandId: shellIntegrationCompletedQueueLimit + 1,
          ),
          now: _issuedAt,
        ),
        ShellIntegrationDecodeResult.commandStarted,
      );
      expect(
        fullDecoder.accept(
          '777',
          _endArgs('0', commandId: shellIntegrationCompletedQueueLimit + 1),
          now: _issuedAt,
        ),
        ShellIntegrationDecodeResult.rejected,
      );
      expect(fullDecoder.isClosed, isTrue);
      expect(fullDecoder.takeCompleted(), isEmpty);
    });

    test('expires stale pending commands and sessions', () {
      final pendingDecoder = _decoder();
      expect(
        pendingDecoder.accept(
          '777',
          _startArgs(_base64Url(utf8.encode('long command'))),
          now: _issuedAt,
        ),
        ShellIntegrationDecodeResult.commandStarted,
      );
      expect(
        pendingDecoder.accept(
          '777',
          _endArgs('0'),
          now: _issuedAt.add(
            shellIntegrationMaxPendingCommandAge + const Duration(seconds: 1),
          ),
        ),
        ShellIntegrationDecodeResult.closed,
      );
      expect(pendingDecoder.takeCompleted(), isEmpty);

      final expiresAt = _issuedAt.add(const Duration(minutes: 1));
      final expiredSessionDecoder = _decoder(expiresAt: expiresAt);
      expect(
        expiredSessionDecoder.accept(
          '777',
          _startArgs(_base64Url(utf8.encode('too late'))),
          now: expiresAt,
        ),
        ShellIntegrationDecodeResult.closed,
      );
      expect(expiredSessionDecoder.isClosed, isTrue);
    });

    test('rejects clock rollback and invalid session bindings', () {
      final decoder = _decoder();
      expect(
        decoder.accept(
          '777',
          _startArgs(_base64Url(utf8.encode('clock'))),
          now: _issuedAt.add(const Duration(seconds: 1)),
        ),
        ShellIntegrationDecodeResult.commandStarted,
      );
      expect(
        decoder.accept('777', _endArgs('0'), now: _issuedAt),
        ShellIntegrationDecodeResult.closed,
      );

      expect(() => _decoder(sessionNonce: 'not-a-nonce'), throwsArgumentError);
      expect(() => _decoder(terminalId: 'tab;1'), throwsArgumentError);
      expect(
        () => _decoder(
          expiresAt: _issuedAt.add(
            shellIntegrationMaxSessionLifetime + const Duration(seconds: 1),
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}
