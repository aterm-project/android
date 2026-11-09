import 'dart:async';

import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'interrupted SSH/Telnet waits five seconds and retries one flight at a time',
    (tester) async {
      var attempts = 0;
      final flight = Completer<void>();
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => true,
        reconnect: () {
          attempts++;
          return flight.future;
        },
      );
      addTearDown(recovery.dispose);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(milliseconds: 4999));
      expect(attempts, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(attempts, 1);
      await recovery.retry();
      await tester.pump(const Duration(seconds: 20));
      expect(attempts, 1);
      flight.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 2);
      recovery.update(connected: true);
      await tester.pump(const Duration(seconds: 10));
      expect(attempts, 2);
    },
  );

  testWidgets('manual restore cancels pending retry and retains success', (
    tester,
  ) async {
    var attempts = 0;
    late SessionRecovery recovery;
    recovery = SessionRecovery(
      automatic: true,
      isCurrent: () => true,
      reconnect: () async {
        attempts++;
        recovery.update(connected: true);
      },
    );
    addTearDown(recovery.dispose);
    recovery.update(connected: true);
    recovery.update(connected: false);
    await recovery.retry();
    expect(recovery.interrupted, false);
    await tester.pump(const Duration(seconds: 10));
    expect(attempts, 1);
  });

  testWidgets(
    'closed, locked or switched owner cannot reconnect from its timer',
    (tester) async {
      var current = true, attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => current,
        reconnect: () async {
          attempts++;
        },
      );
      recovery.update(connected: true);
      recovery.update(connected: false);
      current = false;
      await tester.pump(const Duration(seconds: 5));
      await recovery.retry();
      expect(attempts, 0);
      recovery.dispose();
      await tester.pump(const Duration(seconds: 10));
      expect(attempts, 0);
    },
  );

  testWidgets(
    'first failure is manual and rejected trust blocks automatic prompts',
    (tester) async {
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => true,
        reconnect: () async {
          attempts++;
        },
      );
      addTearDown(recovery.dispose);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 10));
      expect(attempts, 0);
      await recovery.retry();
      expect(attempts, 1);
      recovery.update(connected: true);
      recovery.update(connected: false);
      recovery.blockAutomatic();
      await tester.pump(const Duration(seconds: 10));
      expect(attempts, 1);
    },
  );
}
