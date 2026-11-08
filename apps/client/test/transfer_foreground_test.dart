import 'dart:async';

import 'package:aterm_client/platform/transfer_foreground.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('atermius/transfer_foreground_test');
  const guard = TransferForegroundGuard(channel: channel, enabled: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall) handler;

  setUp(() {
    calls = [];
    handler = (_) async => true;
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'other platforms invoke the picker synchronously without a channel',
    () async {
      const bypass = TransferForegroundGuard(channel: channel, enabled: false);
      var opened = false;
      final result = bypass.run('download', () {
        opened = true;
        return Future.value('saved');
      });
      expect(opened, isTrue);
      expect(await result, 'saved');
      expect(calls, isEmpty);
    },
  );

  test('picker waits for foreground ACK and releases its own lease', () async {
    final ack = Completer<bool>();
    handler = (call) async => call.method == 'acquire' ? ack.future : null;
    var opened = false;
    final result = guard.run('upload', () async {
      opened = true;
      return 'selected';
    });
    await Future<void>.delayed(Duration.zero);
    expect(opened, isFalse);
    expect(calls.single.method, 'acquire');
    ack.complete(true);
    expect(await result, 'selected');
    expect(calls.map((c) => c.method), ['acquire', 'release']);
    expect(calls.first.arguments['leaseId'], calls.last.arguments['leaseId']);
    expect((calls.first.arguments as Map).keys.toSet(), {
      'leaseId',
      'operation',
    });
  });

  test('rejected acquire releases ID and does not open the picker', () async {
    handler = (_) async => false;
    var opened = false;
    await expectLater(
      guard.run('upload', () async {
        opened = true;
      }),
      throwsStateError,
    );
    expect(opened, isFalse);
    expect(calls.map((c) => c.method), ['acquire', 'release']);
  });

  test(
    'platform acquire exception still releases without opening picker',
    () async {
      handler = (call) async {
        if (call.method == 'acquire') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      };
      var opened = false;
      await expectLater(
        guard.run('upload', () async {
          opened = true;
        }),
        throwsA(isA<PlatformException>()),
      );
      expect(opened, isFalse);
      expect(calls.map((c) => c.method), ['acquire', 'release']);
    },
  );

  test('native picker cancellation retains null and releases', () async {
    expect(await guard.run<String?>('download', () async => null), isNull);
    expect(calls.map((c) => c.method), ['acquire', 'release']);
  });

  test('picker failure releases and preserves the original error', () async {
    final error = StateError('picker failed');
    await expectLater(
      guard.run<void>('upload', () async => throw error),
      throwsA(same(error)),
    );
    expect(calls.map((c) => c.method), ['acquire', 'release']);
  });

  test(
    'release failure cannot turn a successful native save into failure',
    () async {
      handler = (call) async {
        if (call.method == 'release') throw PlatformException(code: 'disposed');
        return true;
      };
      expect(await guard.run('download', () async => 'saved'), 'saved');
    },
  );

  test(
    'concurrent pickers use distinct leases and release independently',
    () async {
      final first = Completer<String>();
      final second = Completer<String>();
      final a = guard.run('upload', () => first.future);
      final b = guard.run('download', () => second.future);
      await Future<void>.delayed(Duration.zero);
      final ids = calls
          .where((c) => c.method == 'acquire')
          .map((c) => c.arguments['leaseId'])
          .toList();
      expect(ids.toSet(), hasLength(2));
      first.complete('a');
      expect(await a, 'a');
      expect(
        calls.where((c) => c.method == 'release').single.arguments['leaseId'],
        ids.first,
      );
      second.complete('b');
      expect(await b, 'b');
      expect(calls.last.arguments['leaseId'], ids.last);
    },
  );

  testWidgets('keeps lease renewed during picker and stops after completion', (
    tester,
  ) async {
    final selected = Completer<String>();
    final result = guard.run('upload', () => selected.future);
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(calls.map((c) => c.method), ['acquire', 'renew']);
    selected.complete('ok');
    await tester.pump();
    expect(await result, 'ok');
    await tester.pump(const Duration(minutes: 2));
    expect(calls.map((c) => c.method), ['acquire', 'renew', 'release']);
  });

  testWidgets('timed out ACK releases ID and late success never opens picker', (
    tester,
  ) async {
    final ack = Completer<bool>();
    handler = (call) async => call.method == 'acquire' ? ack.future : null;
    var opened = false;
    final result = guard.run('upload', () async {
      opened = true;
    });
    final expectation = expectLater(result, throwsA(isA<TimeoutException>()));
    await tester.pump(const Duration(seconds: 11));
    await expectation;
    expect(calls.map((c) => c.method), ['acquire', 'release']);
    ack.complete(true);
    await tester.pump();
    expect(opened, isFalse);
  });
}
