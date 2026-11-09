import 'dart:async';
import 'dart:io';

import 'package:aterm_client/platform/file_drop_region.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two regions in an IndexedStack: index 0 is visible, index 1 is hidden but
/// still receives desktop_drop's broadcast (its bounds contain the point).
Widget _app({required Widget visible, required Widget hidden}) => MaterialApp(
  home: Scaffold(body: IndexedStack(index: 0, children: [visible, hidden])),
);

FileDropRegion _region(Future<void> Function(FileDropResult) onDrop) =>
    FileDropRegion(
      maxFiles: 64,
      onDrop: onDrop,
      child: const SizedBox.expand(),
    );

Future<void> _send(String method, Object? arguments) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );

Future<void> _enter(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(IndexedStack));
  await _send('entered', [center.dx, center.dy]);
  await tester.pump();
}

Future<void> _drop(WidgetTester tester, List<String> paths) async {
  await _enter(tester);
  await _send('performOperation', paths);
}

void main() {
  late List<String> released;

  setUp(() => released = []);

  testWidgets('hidden regions never release a drop the visible one is using', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugDroppedFileRelease = released.add;
    final probe = Completer<bool>();
    debugDroppedFileProbe = (_) => probe.future;
    final uploadDone = Completer<void>();
    var visibleCalls = 0;
    var hiddenCalls = 0;
    try {
      await tester.pumpWidget(
        _app(
          visible: _region((_) {
            visibleCalls++;
            return uploadDone.future;
          }),
          hidden: _region((_) async => hiddenCalls++),
        ),
      );
      await _drop(tester, ['/drop/a', '/drop/b']);
      await tester.pump();
      // Both regions got the broadcast; the visible one is inspecting.
      expect(released, isEmpty, reason: 'inspection still running');
      probe.complete(false);
      await tester.pump();
      await tester.pump();
      expect(visibleCalls, 1);
      expect(hiddenCalls, 0);
      expect(released, isEmpty, reason: 'onDrop future still running');
      uploadDone.complete();
      await tester.pump();
      await tester.pump();
      expect(released, ['/drop/a', '/drop/b'], reason: 'released once, after');
      await tester.pump(const Duration(seconds: 1));
      expect(released.length, 2, reason: 'exactly once');
    } finally {
      debugDroppedFileRelease = null;
      debugDroppedFileProbe = null;
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the accepted region reads bytes asynchronously before release', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugDroppedFileRelease = released.add;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('atermius-lease-'),
    ))!;
    final file = File('${directory.path}/data.bin');
    await tester.runAsync(() => file.writeAsBytes(List.filled(300000, 7)));
    final readBytes = <int>[];
    var releasedDuringRead = -1;
    final done = Completer<void>();
    try {
      await tester.pumpWidget(
        _app(
          visible: _region((result) async {
            for (final source in result.files) {
              await for (final chunk in source.open()) {
                readBytes.add(chunk.length);
                await Future<void>.delayed(const Duration(milliseconds: 1));
              }
            }
            releasedDuringRead = released.length;
            done.complete();
          }),
          hidden: _region((_) async => fail('hidden region must not consume')),
        ),
      );
      await _enter(tester);
      await _send('performOperation', [file.path]);
      // The plugin handler runs in the test zone: alternate real IO time with
      // fake-clock frames until the consumer finished reading.
      for (var i = 0; i < 200 && !done.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(done.isCompleted, isTrue);
      await tester.pump();
      expect(readBytes.fold<int>(0, (a, b) => a + b), 300000);
      expect(releasedDuringRead, 0, reason: 'nothing released while reading');
      expect(released, [file.path], reason: 'released once after completion');
    } finally {
      debugDroppedFileRelease = null;
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });

  testWidgets('a drop no region accepts is still released exactly once', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugDroppedFileRelease = released.add;
    var hiddenCalls = 0;
    try {
      await tester.pumpWidget(
        _app(
          visible: const SizedBox.expand(),
          hidden: _region((_) async => hiddenCalls++),
        ),
      );
      await _drop(tester, ['/drop/x', '/drop/y', '/drop/z']);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(hiddenCalls, 0);
      expect(released, ['/drop/x', '/drop/y', '/drop/z']);
    } finally {
      debugDroppedFileRelease = null;
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an over-limit drop is reported once, then released once', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    debugDroppedFileRelease = released.add;
    var probes = 0;
    debugDroppedFileProbe = (_) async {
      probes++;
      return true;
    };
    final results = <FileDropResult>[];
    try {
      await tester.pumpWidget(
        _app(
          visible: _region((result) async => results.add(result)),
          hidden: _region((result) async => results.add(result)),
        ),
      );
      final paths = [for (var i = 0; i < 65; i++) '/drop/$i'];
      await _drop(tester, paths);
      await tester.pump();
      await tester.pump();
      expect(results.single.tooMany, isTrue);
      expect(probes, 0);
      expect(released, paths);
    } finally {
      debugDroppedFileRelease = null;
      debugDroppedFileProbe = null;
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
    }
  });
}
