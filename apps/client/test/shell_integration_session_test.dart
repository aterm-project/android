import 'dart:convert';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/terminal/shell_integration_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShellIntegrationSession', () {
    const nonce = 'AAAAAAAAAAAAAAAAAAAAAA';
    final issuedAt = DateTime.utc(2026, 10, 8, 12);

    test(
      'binds the decoder to one nonce and tab and returns paired commands',
      () {
        final session = ShellIntegrationSession(
          terminalId: 'tab-1',
          sessionNonce: nonce,
          issuedAt: issuedAt,
        );
        const command = r"printf 'safe text'";
        final encodedCommand = _encode(command);

        expect(
          session.accept(
            '777',
            _event(nonce, 'tab-1', 1, 'start', encodedCommand),
            now: issuedAt.add(const Duration(seconds: 1)),
          ),
          isEmpty,
        );
        final completed = session.accept(
          '777',
          _event(nonce, 'tab-1', 1, 'end', '0'),
          now: issuedAt.add(const Duration(seconds: 2)),
        );

        expect(completed, hasLength(1));
        expect(completed.single.command, command);
        expect(completed.single.exitStatus, 0);
        expect(completed.single.commandId, 1);
        expect(session.isActive, isTrue);
      },
    );

    test('does not return an event bound to another session or tab', () {
      final session = ShellIntegrationSession(
        terminalId: 'tab-1',
        sessionNonce: nonce,
        issuedAt: issuedAt,
      );

      expect(
        session.accept(
          '777',
          _event('BBBBBBBBBBBBBBBBBBBBBA', 'tab-1', 1, 'start', _encode('x')),
          now: issuedAt.add(const Duration(seconds: 1)),
        ),
        isEmpty,
      );
      expect(
        session.accept(
          '777',
          _event(nonce, 'another-tab', 1, 'start', _encode('x')),
          now: issuedAt.add(const Duration(seconds: 2)),
        ),
        isEmpty,
      );
      expect(session.isActive, isTrue);
    });

    test(
      'close invalidates future events and drops pending protocol state',
      () {
        final session = ShellIntegrationSession(
          terminalId: 'tab-1',
          sessionNonce: nonce,
          issuedAt: issuedAt,
        );
        session.accept(
          '777',
          _event(nonce, 'tab-1', 1, 'start', _encode('x')),
          now: issuedAt.add(const Duration(seconds: 1)),
        );
        session.close();

        expect(session.isActive, isFalse);
        expect(
          session.accept(
            '777',
            _event(nonce, 'tab-1', 1, 'end', '0'),
            now: issuedAt.add(const Duration(seconds: 2)),
          ),
          isEmpty,
        );
      },
    );

    test('TerminalTabSession collects private OSC only after opt-in', () {
      var notifications = 0;
      final tab = TerminalTabSession(
        id: 'terminal-session-test',
        host: null,
        onShellHistoryChanged: () => notifications++,
      );
      final setupCommand = tab.enableShellIntegration();
      final activeSession = tab.shellIntegration!;
      const command = r"printf 'not executed by the client'";
      final encodedCommand = _encode(command);

      tab.terminal.write(
        '\u001b]777;atermius;v1;${activeSession.sessionNonce};'
        'terminal-session-test;1;start;$encodedCommand\u0007'
        '\u001b]777;atermius;v1;${activeSession.sessionNonce};'
        'terminal-session-test;1;end;7\u0007',
      );

      expect(setupCommand, isNotEmpty);
      expect(tab.shellIntegrationHistory, hasLength(1));
      expect(tab.shellIntegrationHistory.single.command, command);
      expect(tab.shellIntegrationHistory.single.exitStatus, 7);
      expect(tab.terminal.buffer.getText(), isNot(contains(command)));
      expect(notifications, greaterThanOrEqualTo(2));

      tab.disableShellIntegration();
      expect(tab.shellIntegration, isNull);
      expect(tab.shellIntegrationHistory, hasLength(1));
      expect(tab.terminal.onPrivateOSC, isNull);
    });

    test('re-enabling rotates the nonce and rejects prior-hook events', () {
      final tab = TerminalTabSession(id: 'nonce-rotation', host: null);
      tab.enableShellIntegration();
      final oldNonce = tab.shellIntegration!.sessionNonce;
      tab.disableShellIntegration();
      tab.enableShellIntegration();
      final newNonce = tab.shellIntegration!.sessionNonce;
      final payload = _encode('old shell command');

      expect(newNonce, isNot(oldNonce));
      tab.terminal.write(
        '\u001b]777;atermius;v1;$oldNonce;nonce-rotation;1;start;$payload\u0007'
        '\u001b]777;atermius;v1;$oldNonce;nonce-rotation;1;end;0\u0007',
      );
      expect(tab.shellIntegration!.isActive, isTrue);
      expect(tab.shellIntegrationHistory, isEmpty);

      final nextPayload = _encode('new shell command');
      tab.terminal.write(
        '\u001b]777;atermius;v1;$newNonce;nonce-rotation;1;start;$nextPayload\u0007'
        '\u001b]777;atermius;v1;$newNonce;nonce-rotation;1;end;0\u0007',
      );
      expect(tab.shellIntegrationHistory.single.command, 'new shell command');
    });

    test('retains only the newest 500 completed commands per tab', () {
      final tab = TerminalTabSession(id: 'bounded-history', host: null);
      tab.enableShellIntegration();
      final session = tab.shellIntegration!;
      final events = StringBuffer();
      for (var id = 1; id <= 501; id++) {
        final encoded = _encode('command-$id');
        events
          ..write(
            '\u001b]777;atermius;v1;${session.sessionNonce};'
            'bounded-history;$id;start;$encoded\u0007',
          )
          ..write(
            '\u001b]777;atermius;v1;${session.sessionNonce};'
            'bounded-history;$id;end;0\u0007',
          );
      }
      tab.terminal.write(events.toString());

      expect(tab.shellIntegrationHistory, hasLength(500));
      expect(tab.shellIntegrationHistory.first.command, 'command-2');
      expect(tab.shellIntegrationHistory.last.command, 'command-501');
    });
  });
}

List<String> _event(
  String nonce,
  String tabId,
  int commandId,
  String kind,
  String payload,
) => ['atermius', 'v1', nonce, tabId, '$commandId', kind, payload];

String _encode(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');
