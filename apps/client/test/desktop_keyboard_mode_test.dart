import 'dart:io';
import 'dart:async';

import 'package:aterm_client/desktop/desktop_keyboard_mode.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/desktop_keyboard_store.dart';
import 'package:aterm_client/storage/desktop_keyboard_store_native.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

class _ResizeTarget implements DirectDesktopConnection {
  final stream = StreamController<DesktopEvent>();
  final sizes = <List<Object>>[];
  @override
  Stream<DesktopEvent> get events => stream.stream;
  @override
  void send(List<Object> command) {
    if (command.first == 'size') {
      sizes.add(command);
      stream.add(
        DesktopResizeStatus(
          serverResize: true,
          result: DesktopResizeResult.applied,
        ),
      );
    }
  }

  @override
  void paste(String text) {}
  @override
  Future<void> close() async {
    unawaited(stream.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'server resize acknowledgements do not cause a repeated size request loop',
    (tester) async {
      final target = _ResizeTarget();
      final session = DesktopSession(directConnectionForTesting: (_) => target);
      await session.connectLocal(
        HostRecord(
          id: 'resize-owned',
          name: 'Owned',
          address: 'localhost',
          protocol: HostProtocol.vnc,
          manifest: const VncSettings(resolution: VncResolutionMode.fitWindow)
              .applyTo(null),
        ),
      );
      target.stream.add(DesktopReady());
      // This view fixture starts after the first rendered frame; image
      // decoding is covered by desktop_protocol_test.dart.
      session.state = 'connected';
      target.stream.add(DesktopResizeStatus(serverResize: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(
        target.sizes,
        hasLength(1),
        reason: 'An applied reply confirms the existing viewport',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(session.close);
      session.dispose();
    },
  );
  test(
    'overlay default, saved resize, serialized choices and exact owner cleanup',
    () async {
      final controller = DesktopKeyboardController();
      addTearDown(controller.dispose);
      final store = MemoryDesktopKeyboardStore('unknown');
      await controller.load(store);
      expect(controller.mode, DesktopKeyboardMode.overlay);
      final a = Object(), b = Object();
      controller.keyboardVisible(a, true);
      controller.keyboardVisible(b, true);
      controller.keyboardVisible(a, false);
      expect(controller.overlayActive, isTrue);
      final first = controller.select(DesktopKeyboardMode.resize);
      final second = controller.select(DesktopKeyboardMode.overlay);
      await Future.wait([first, second]);
      expect(store.value, 'overlay');
      controller.keyboardVisible(b, false);
      expect(controller.overlayActive, isFalse);
      await controller.select(DesktopKeyboardMode.resize);
      final loaded = DesktopKeyboardController();
      addTearDown(loaded.dispose);
      await loaded.load(store);
      expect(loaded.mode, DesktopKeyboardMode.resize);
    },
  );
  test(
    'device preference file persists independently of the profile',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desktop-keyboard-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FileDesktopKeyboardStore(directory: () async => directory);
      expect(await store.read(), isNull);
      await store.write('resize');
      expect(
        await FileDesktopKeyboardStore(directory: () async => directory).read(),
        'resize',
      );
      await store.write('overlay');
      expect(await store.read(), 'overlay');
      expect(
        await directory.list().length,
        1,
        reason: 'No temporary preference files remain',
      );
    },
  );
  for (final locale in ['en', 'zh', 'ru', 'ja']) {
    group(locale, () {
      useAppLocaleFixture(locale);
      testWidgets('390px settings selects and persists keyboard modes', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = DesktopKeyboardController();
        DesktopKeyboardController.debugInstance = controller;
        addTearDown(() {
          controller.dispose();
          DesktopKeyboardController.debugInstance = null;
        });
        final store = MemoryDesktopKeyboardStore();
        await controller.load(store);
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: EdgeInsets.all(16),
                child: DesktopKeyboardSettings(),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('desktop_keyboard_mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(currentL10n.desktopKeyboardResize).last);
        await tester.pumpAndSettle();
        expect(controller.mode, DesktopKeyboardMode.resize);
        expect(store.value, 'resize');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });
  }
}
