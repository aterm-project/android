import 'dart:async';
import 'dart:io';
import 'package:aterm_client/platform/native_coordination.dart';

import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-lock-test-');
    coordinationDirectory = () async => directory;
  });
  tearDown(() async => directory.delete(recursive: true));
  test('serializes trust projection work for the same Vault', () async {
    final lock = createKnownHostDecisionLock();
    const scope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-a',
    );
    final enteredFirst = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = lock.run(scope, () async {
      events.add('first-enter');
      enteredFirst.complete();
      await releaseFirst.future;
      events.add('first-leave');
      return 1;
    });
    await enteredFirst.future;

    final second = lock.run(scope, () async {
      events.add('second-enter');
      return 2;
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-enter']);

    releaseFirst.complete();
    expect(await Future.wait([first, second]), [1, 2]);
    expect(events, ['first-enter', 'first-leave', 'second-enter']);
  });

  test('different Vaults do not block each other', () async {
    final lock = createKnownHostDecisionLock();
    const firstScope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-a',
    );
    const secondScope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-b',
    );
    final releaseFirst = Completer<void>();
    final enteredFirst = Completer<void>();
    var secondEntered = false;

    final first = lock.run(firstScope, () async {
      enteredFirst.complete();
      await releaseFirst.future;
    });
    await enteredFirst.future;
    final second = lock.run(secondScope, () async {
      secondEntered = true;
    });
    await second;
    expect(secondEntered, isTrue);

    releaseFirst.complete();
    await first;
  });

  test('shared SSH authorization readers can run concurrently', () async {
    final lock = createKnownHostDecisionLock();
    const scope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-a',
    );
    final entered = <String>[];
    final release = Completer<void>();
    final firstEntered = Completer<void>();
    final secondEntered = Completer<void>();

    final first = lock.run(scope, () async {
      entered.add('first');
      firstEntered.complete();
      await release.future;
    }, mode: KnownHostDecisionLockMode.shared);
    await firstEntered.future;
    final second = lock.run(scope, () async {
      entered.add('second');
      secondEntered.complete();
      await release.future;
    }, mode: KnownHostDecisionLockMode.shared);

    await secondEntered.future.timeout(const Duration(seconds: 1));
    expect(entered, ['first', 'second']);
    release.complete();
    await Future.wait([first, second]);
  });

  test('exclusive trust update is fair to later shared readers', () async {
    final lock = createKnownHostDecisionLock();
    const scope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-a',
    );
    final events = <String>[];
    final firstReaderEntered = Completer<void>();
    final secondReaderEntered = Completer<void>();
    final releaseReaders = Completer<void>();
    final writerEntered = Completer<void>();
    final releaseWriter = Completer<void>();
    final laterReaderEntered = Completer<void>();

    final firstReader = lock.run(scope, () async {
      events.add('first-reader-enter');
      firstReaderEntered.complete();
      await releaseReaders.future;
    }, mode: KnownHostDecisionLockMode.shared);
    await firstReaderEntered.future;
    final secondReader = lock.run(scope, () async {
      events.add('second-reader-enter');
      secondReaderEntered.complete();
      await releaseReaders.future;
    }, mode: KnownHostDecisionLockMode.shared);
    await secondReaderEntered.future;

    final writer = lock.run(scope, () async {
      events.add('writer-enter');
      writerEntered.complete();
      await releaseWriter.future;
    });
    final laterReader = lock.run(scope, () async {
      events.add('later-reader-enter');
      laterReaderEntered.complete();
    }, mode: KnownHostDecisionLockMode.shared);

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-reader-enter', 'second-reader-enter']);
    releaseReaders.complete();
    await writerEntered.future.timeout(const Duration(seconds: 1));
    expect(events, [
      'first-reader-enter',
      'second-reader-enter',
      'writer-enter',
    ]);

    releaseWriter.complete();
    await laterReaderEntered.future.timeout(const Duration(seconds: 1));
    await Future.wait([firstReader, secondReader, writer, laterReader]);
    expect(events.last, 'later-reader-enter');
  });

  test('cancelled shared reader leaves writer queue usable', () async {
    final lock = createKnownHostDecisionLock();
    const scope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-a',
    );
    final writerEntered = Completer<void>();
    final releaseWriter = Completer<void>();
    final cancelReader = Completer<void>();
    var cancelledReaderActionRan = false;

    final writer = lock.run(scope, () async {
      writerEntered.complete();
      await releaseWriter.future;
    });
    await writerEntered.future;
    final cancelledReader = lock.run(
      scope,
      () async => cancelledReaderActionRan = true,
      mode: KnownHostDecisionLockMode.shared,
      cancel: cancelReader.future,
    );
    cancelReader.complete();
    await expectLater(
      cancelledReader,
      throwsA(isA<KnownHostDecisionCancelledException>()),
    );
    expect(cancelledReaderActionRan, isFalse);

    releaseWriter.complete();
    await writer;
    expect(await lock.run(scope, () async => 'acquired'), 'acquired');
  });

  test('cancelled queued lock request never runs its action', () async {
    final lock = createKnownHostDecisionLock();
    const scope = KnownHostDecisionScope(
      serverSpaceId: 'server-space-a',
      vaultId: 'vault-a',
    );
    final enteredFirst = Completer<void>();
    final releaseFirst = Completer<void>();
    final cancelWaiter = Completer<void>();
    var cancelledActionRan = false;

    final first = lock.run(scope, () async {
      enteredFirst.complete();
      await releaseFirst.future;
    });
    await enteredFirst.future;
    final cancelled = lock.run(
      scope,
      () async => cancelledActionRan = true,
      cancel: cancelWaiter.future,
    );
    cancelWaiter.complete();
    await expectLater(
      cancelled,
      throwsA(isA<KnownHostDecisionCancelledException>()),
    );
    expect(cancelledActionRan, isFalse);

    releaseFirst.complete();
    await first;
    expect(
      await lock.run(scope, () async => 'acquired'),
      'acquired',
      reason: 'a cancelled waiter must release its FIFO queue slot',
    );
  });
}
