import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:aterm_client/platform/process_file_lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('process-lock-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  String dartExecutable() {
    final executable = File(Platform.resolvedExecutable);
    if (executable.uri.pathSegments.last == 'dart') return executable.path;
    final cache = executable.parent.parent.parent.parent;
    return '${cache.path}/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
  }

  Future<Process> worker(String id) => Process.start(dartExecutable(), [
    '--packages=.dart_tool/package_config.json',
    'tool/process_lock_probe.dart',
    directory.path,
    id,
  ]);

  test(
    'OS locks exclude independent processes and release after process exit',
    () async {
      final processes = await Future.wait([
        for (var i = 0; i < 4; i++) worker('$i'),
      ]);
      for (final process in processes) {
        // Drain both pipes so a failed compiler cannot stall the worker.
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        expect(await process.exitCode, 0);
      }
      final events = await File('${directory.path}/events').readAsLines();
      expect(events, hasLength(8));
      for (var i = 0; i < events.length; i += 2) {
        expect(events[i], startsWith('enter '));
        expect(events[i + 1], 'leave ${events[i].split(' ').last}');
      }
      final crashed = await worker('crash');
      expect(await crashed.exitCode, 7);
      final after = await worker('after-crash');
      expect(await after.exitCode, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('cancel waits for another process without running action', () async {
    final process = await worker('holder');
    final log = File('${directory.path}/events');
    while (!await log.exists() || (await log.readAsString()).isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final cancel = Completer<void>();
    final pending = ProcessFileLock(directory).run(
      'probe',
      () async => fail('cancelled action ran'),
      cancel: cancel.future,
    );
    cancel.complete();
    await expectLater(pending, throwsA(isA<ProcessLockCancelled>()));
    expect(await process.exitCode, 0);
    expect(await ProcessFileLock(directory).run('probe', () async => 42), 42);
  });
  test(
    'reader joining during last reader retirement keeps its OS lease',
    () async {
      final lock = ProcessFileLock(directory);
      final enteredFirst = Completer<void>();
      final releaseFirst = Completer<void>();
      final enteredSecond = Completer<void>();
      final releaseSecond = Completer<void>();
      final first = lock.run('probe', () {
        enteredFirst.complete();
        return releaseFirst.future;
      }, shared: true);
      await enteredFirst.future;
      late Future<void> second;
      releaseFirst.complete();
      // The first continuation retires its descriptor, then this reader arrives
      // during the await in retirement cleanup.
      scheduleMicrotask(() {
        second = lock.run('probe', () {
          enteredSecond.complete();
          return releaseSecond.future;
        }, shared: true);
      });
      await enteredSecond.future;
      await first;
      final contender = await worker('contender');
      await contender.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      await Future<void>.delayed(const Duration(milliseconds: 75));
      expect(
        await File('${directory.path}/events').exists(),
        isFalse,
        reason: 'the second reader must retain the cross-process shared lock',
      );
      releaseSecond.complete();
      await second;
      expect(await contender.exitCode, 0);
    },
  );
}
