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

  test(
    'user gate blocks every trigger and enabling resumes the schedule',
    () async {
      var calls = 0;
      final coordinator = AutoSyncCoordinator(
        isEnabled: () => true,
        synchronize: () async => calls++,
        debounce: const Duration(milliseconds: 5),
        interval: const Duration(milliseconds: 20),
        initialUserEnabled: false,
      );
      try {
        coordinator.start();
        coordinator.scheduleEdit();
        await coordinator.foregroundResumed();
        await coordinator.hintReceived();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(calls, 0);

        // Enabling inside a started lifecycle runs a catch-up pass and resumes
        // the periodic schedule.
        coordinator.setUserEnabled(true);
        await _waitFor(() => calls >= 2);

        coordinator.setUserEnabled(false);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final afterDisable = calls;
        coordinator.scheduleEdit();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(calls, afterDisable);
      } finally {
        coordinator.stop();
      }
    },
  );

  test(
    'disabling cancels a pending debounce and a coalesced follow-up',
    () async {
      var calls = 0;
      final firstSync = Completer<void>();
      final coordinator = AutoSyncCoordinator(
        isEnabled: () => true,
        synchronize: () async {
          calls++;
          if (calls == 1) await firstSync.future;
        },
        debounce: const Duration(milliseconds: 5),
        interval: const Duration(hours: 1),
      );
      try {
        coordinator.start();
        await _waitFor(() => calls == 1);
        await coordinator.hintReceived();
        coordinator.scheduleEdit();
        coordinator.setUserEnabled(false);
        firstSync.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(calls, 1);
      } finally {
        if (!firstSync.isCompleted) firstSync.complete();
        coordinator.stop();
      }
    },
  );

  test(
    'a toggle never restarts a coordinator stopped by the lifecycle',
    () async {
      var calls = 0;
      final coordinator = AutoSyncCoordinator(
        isEnabled: () => true,
        synchronize: () async => calls++,
        interval: const Duration(hours: 1),
        initialUserEnabled: false,
      );
      coordinator.start();
      coordinator.stop();
      coordinator.setUserEnabled(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 0);
      coordinator.start();
      await _waitFor(() => calls == 1);
      coordinator.stop();
    },
  );
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(predicate(), isTrue);
}
