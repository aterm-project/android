import 'dart:async';

import 'package:aterm_client/sync/auto_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'syncs on unlock, debounces edits and reacts to foreground resume',
    () async {
      var unlocked = true;
      var calls = 0;
      final coordinator = AutoSyncCoordinator(
        isEnabled: () => unlocked,
        synchronize: () async => calls++,
        debounce: const Duration(milliseconds: 15),
        interval: const Duration(hours: 1),
      );

      coordinator.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(calls, 1);

      coordinator.scheduleEdit();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      coordinator.scheduleEdit();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(calls, 2);

      await coordinator.foregroundResumed();
      expect(calls, 3);
      unlocked = false;
      await coordinator.foregroundResumed();
      expect(calls, 3);
      coordinator.stop();
    },
  );

  test('contains background failures and permits a later retry', () async {
    var calls = 0;
    final coordinator = AutoSyncCoordinator(
      isEnabled: () => true,
      synchronize: () async {
        calls++;
        if (calls == 1) throw StateError('offline');
      },
      interval: const Duration(hours: 1),
    );

    coordinator.start();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, 1);
    await coordinator.foregroundResumed();
    expect(calls, 2);
    coordinator.stop();
  });

  test('coalesces sync hints received while one sync is in flight', () async {
    var calls = 0;
    final firstSync = Completer<void>();
    final secondSync = Completer<void>();
    final coordinator = AutoSyncCoordinator(
      isEnabled: () => true,
      synchronize: () async {
        calls++;
        if (calls == 1) await firstSync.future;
        if (calls == 2) await secondSync.future;
      },
      interval: const Duration(hours: 1),
    );

    coordinator.start();
    await _waitFor(() => calls == 1);
    await coordinator.hintReceived();
    await coordinator.hintReceived();
    await coordinator.hintReceived();
    firstSync.complete();
    await _waitFor(() => calls == 2);
    expect(calls, 2);
    secondSync.complete();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(calls, 2);
    coordinator.stop();
  });

  test('does not drop a debounced edit while sync is in flight', () async {
    var calls = 0;
    final firstSync = Completer<void>();
    final secondSync = Completer<void>();
    final coordinator = AutoSyncCoordinator(
      isEnabled: () => true,
      synchronize: () async {
        calls++;
        if (calls == 1) await firstSync.future;
        if (calls == 2) await secondSync.future;
      },
      debounce: const Duration(milliseconds: 5),
      interval: const Duration(hours: 1),
    );

    coordinator.start();
    try {
      await _waitFor(() => calls == 1);
      coordinator.scheduleEdit();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(calls, 1);

      firstSync.complete();
      await _waitFor(() => calls == 2);
      expect(calls, 2);

      secondSync.complete();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(calls, 2);
    } finally {
      if (!firstSync.isCompleted) firstSync.complete();
      if (!secondSync.isCompleted) secondSync.complete();
      coordinator.stop();
    }
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(predicate(), isTrue);
}
