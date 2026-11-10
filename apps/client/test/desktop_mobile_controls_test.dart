import 'package:aterm_client/desktop/desktop_mobile_controls.dart';
import 'package:aterm_client/desktop/desktop_keyboard_mode.dart';
import 'package:aterm_client/platform/fullscreen.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_touch_input.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends DesktopSession {
  _Session({this.protocol = HostProtocol.rdp}) {
    state = 'connected';
    display.layer(0).resize(1000, 800);
  }
  @override
  final HostProtocol protocol;
  final sent = <List<Object>>[];
  @override
  void send(List<Object> command) => sent.add(command);
  List<List<Object>> get keys => sent.where((e) => e.first == 'key').toList();
}

Future<_Session> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  HostProtocol protocol = HostProtocol.rdp,
  bool safeArea = false,
}) async {
  final session = _Session(protocol: protocol);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      builder: (context, child) => DesktopKeyboardViewport(child: child!),
      home: Scaffold(
        body: safeArea
            ? SafeArea(child: DesktopView(session: session))
            : DesktopView(session: session),
      ),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });
  return session;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
  await tester.pump();
  expect(tester.testTextInput.isVisible, isTrue);
  expect(find.byKey(const ValueKey('desktop_special_keybar')), findsOneWidget);
}

void main() {
  setUp(() {
    final controller = DesktopKeyboardController();
    DesktopKeyboardController.debugInstance = controller;
    addTearDown(() {
      controller.dispose();
      DesktopKeyboardController.debugInstance = null;
    });
  });
  testWidgets('Android three controls share the same draggable edge dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester);
    final dock = find.byKey(const ValueKey('desktop_edge_dock'));
    final menu = find.byTooltip('Remote desktop menu');
    expect(find.descendant(of: dock, matching: menu), findsOneWidget);
    final keyboard = find.byKey(const ValueKey('desktop_keyboard_toggle'));
    final pointer = find.byKey(const ValueKey('desktop_pointer_mode_toggle'));
    expect(tester.getCenter(menu).dx, tester.getCenter(keyboard).dx);
    expect(tester.getCenter(pointer).dx, tester.getCenter(keyboard).dx);
    await tester.drag(dock, const Offset(-340, 170));
    await tester.pumpAndSettle();
    expect(tester.getRect(dock).left, 0);
    expect(tester.getCenter(menu).dx, tester.getCenter(keyboard).dx);
    // Top/bottom edges use a horizontal strip.
    await tester.drag(dock, const Offset(190, -360));
    await tester.pumpAndSettle();
    expect(tester.getRect(dock).top, 0);
    expect(tester.getCenter(menu).dy, tester.getCenter(keyboard).dy);
    expect(tester.getCenter(pointer).dy, tester.getCenter(keyboard).dy);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Send Ctrl+Alt+Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android dock opens and closes actual IME client plus special keys',
    (tester) async {
      final session = await _mount(tester);
      expect(
        find.byKey(const ValueKey('desktop_special_keybar')),
        findsNothing,
      );
      await _open(tester);
      expect(
        session.sent.where((e) => e.first == 'mouse' && e.last == 1),
        isEmpty,
        reason: 'Dock taps must never click the remote desktop',
      );
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop_special_keybar')),
        findsNothing,
      );
      expect(tester.testTextInput.hasAnyClients, isFalse);
    },
  );

  testWidgets(
    'trackpad starts with the same visible local and remote pointer position',
    (tester) async {
      final session = await _mount(tester);
      await tester.tap(
        find.byKey(const ValueKey('desktop_pointer_mode_toggle')),
      );
      await tester.pump();
      expect(session.display.pointer, const Offset(500, 400));
      expect(session.sent.last, ['mouse', 500, 400, 0]);
      expect(
        session.sent.where((p) => p.first == 'mouse' && p.last == 1),
        isEmpty,
      );
    },
  );

  testWidgets(
    'IME preedit stays local; committed CJK, uppercase and emoji send once',
    (tester) async {
      final session = await _mount(tester);
      await _open(tester);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200bzhong',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 1, end: 6),
        ),
      );
      await tester.pump();
      expect(session.keys, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200b中A😀',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pump();
      expect(session.keys, [
        ['key', 0x01004e2d, 1],
        ['key', 0x01004e2d, 0],
        ['key', 0x01000041, 1],
        ['key', 0x01000041, 0],
        ['key', 0x0101f600, 1],
        ['key', 0x0101f600, 0],
      ]);
      expect(tester.testTextInput.editingState!['text'], '\u200b');
    },
  );

  testWidgets(
    'VNC preserves standard Latin-1 keysyms and extends only CJK/emoji',
    (tester) async {
      final session = await _mount(tester, protocol: HostProtocol.vnc);
      await _open(tester);
      tester.testTextInput.enterText('aAé中😀');
      await tester.pump();
      expect(session.keys, [
        for (final code in [97, 65, 233, 0x01004e2d, 0x0101f600]) ...[
          ['key', code, 1],
          ['key', code, 0],
        ],
      ]);
    },
  );
  testWidgets('IME Backspace and newline generate real desktop key strokes', (
    tester,
  ) async {
    final session = await _mount(tester);
    await _open(tester);
    tester.testTextInput.updateEditingValue(TextEditingValue.empty);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(session.keys, [
      ['key', 0xff08, 1],
      ['key', 0xff08, 0],
      ['key', 0xff0d, 1],
      ['key', 0xff0d, 0],
    ]);
  });

  testWidgets('soft Ctrl is one-shot, double tap locks, closing releases it', (
    tester,
  ) async {
    final session = await _mount(tester);
    await _open(tester);
    final ctrl = find.byKey(const ValueKey('desktop_key_65507'));
    await tester.tap(ctrl);
    await tester.pump();
    tester.testTextInput.enterText('\u200bc');
    await tester.pump();
    expect(session.keys, [
      ['key', 0xffe3, 1],
      ['key', 99, 1],
      ['key', 99, 0],
      ['key', 0xffe3, 0],
    ]);
    session.sent.clear();
    await tester.tap(ctrl);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(ctrl);
    await tester.pump();
    tester.testTextInput.enterText('\u200bc');
    await tester.pump();
    tester.testTextInput.enterText('\u200bc');
    await tester.pump();
    expect(session.keys.where((e) => e[1] == 0xffe3), [
      ['key', 0xffe3, 1],
    ]);
    await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
    await tester.pump();
    expect(session.keys.last, ['key', 0xffe3, 0]);
  });

  testWidgets('dock stays on edge when dragged, resized and IME opens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester);
    final dock = find.byKey(const ValueKey('desktop_edge_dock'));
    expect(tester.getRect(dock).right, 390);
    await tester.drag(dock, const Offset(-300, 200));
    await tester.pump();
    expect(tester.getRect(dock).left, 0);
    await _open(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump();
    final rect = tester.getRect(dock);
    expect(rect.left, 0);
    expect(rect.bottom, lessThanOrEqualTo(428));
    expect(
      tester
          .getRect(find.byKey(const ValueKey('desktop_special_keybar')))
          .bottom,
      524,
    );
    expect(tester.takeException(), isNull);
  });

  for (final mode in DesktopKeyboardMode.values) {
    testWidgets('Android $mode keyboard viewport and remote size policy', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await DesktopKeyboardController.instance.select(mode);
      final session = await _mount(tester);
      await tester.pump(const Duration(milliseconds: 300));
      final surface = find.byKey(const ValueKey('desktop_remote_surface'));
      final original = tester.getSize(surface);
      session.sent.clear();
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final requests = session.sent.where((e) => e.first == 'size').toList();
      if (mode == DesktopKeyboardMode.overlay) {
        expect(tester.getSize(surface), original);
        expect(
          requests,
          isEmpty,
          reason: 'IME and special keys must not resize the remote desktop',
        );
      } else {
        expect(tester.getSize(surface).height, original.height - 320 - 96);
        expect(requests.last, ['size', 390, 428]);
      }
      expect(
        tester
            .getRect(find.byKey(const ValueKey('desktop_special_keybar')))
            .bottom,
        524,
      );
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), original);
      expect(DesktopKeyboardController.instance.overlayActive, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final initialBottom in [0.0, 56.0]) {
    testWidgets('overlay retains pre-IME safe area (bottom=$initialBottom)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      if (initialBottom == 0) {
        final fullscreen = FullscreenController(
          supported: true,
          read: () async => true,
          changes: const Stream.empty(),
          apply: (v) async => v,
        )..enabled = true;
        FullscreenController.debugInstance = fullscreen;
        addTearDown(() {
          fullscreen.dispose();
          FullscreenController.debugInstance = null;
        });
      }
      tester.view.viewPadding = FakeViewPadding(bottom: initialBottom);
      tester.view.padding = FakeViewPadding(bottom: initialBottom);
      addTearDown(tester.view.reset);
      final session = await _mount(tester, safeArea: true);
      await tester.pump(const Duration(milliseconds: 300));
      final surface = find.byKey(const ValueKey('desktop_remote_surface'));
      final before = tester.getSize(surface);
      session.sent.clear();
      await _open(tester);
      tester.view.viewPadding = const FakeViewPadding(bottom: 56);
      tester.view.viewInsets = const FakeViewPadding(bottom: 356);
      tester.view.padding = const FakeViewPadding();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), before);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      // Visibility notification precedes Android's closing IME animation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), before);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      tester.view.viewInsets = const FakeViewPadding();
      // IME dismissal can leave the fullscreen navigation bar transiently visible.
      tester.view.padding = const FakeViewPadding(bottom: 56);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), before);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'phone keeps arrows visible and wide key labels scroll; each key has one actionable semantics node',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await _mount(tester);
        await _open(tester);
        for (final code in [65507, 65361, 65362, 65363, 65364]) {
          final rect = tester.getRect(
            find.byKey(ValueKey('desktop_key_$code')),
          );
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(390));
        }
        final ctrl = tester.getSemantics(
          find.byKey(const ValueKey('desktop_key_65507')),
        );
        expect(ctrl.label, 'Ctrl');
        expect(ctrl.value, 'Off');
        expect(ctrl.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        // Ahem/large fonts make word labels wider than Roboto. Keep the
        // 390px case and prove those keys remain reachable without shrinking.
        final delete = find.byKey(const ValueKey('desktop_key_65535'));
        await tester.ensureVisible(delete);
        await tester.pump();
        expect(tester.getRect(delete).right, lessThanOrEqualTo(390));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'two split panes own independent IME clients and release old Ctrl on focus switch',
    (tester) async {
      final a = _Session(), b = _Session();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: DesktopView(session: a)),
                Expanded(child: DesktopView(session: b)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final toggles = find.byKey(const ValueKey('desktop_keyboard_toggle'));
      await tester.tap(toggles.first);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('desktop_key_65507')));
      await tester.pump();
      await tester.tap(toggles.last);
      await tester.pump();
      await tester.pump();
      expect(a.keys.last, ['key', 0xffe3, 0]);
      tester.testTextInput.enterText('\u200bb');
      await tester.pump();
      expect(b.keys, [
        ['key', 0x01000062, 1],
        ['key', 0x01000062, 0],
      ]);
      expect(a.keys.where((e) => e[1] == 0x01000062), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await a.close();
      await b.close();
    },
  );

  testWidgets(
    'desktop platforms preserve physical-keyboard view without mobile dock',
    (tester) async {
      await _mount(tester, platform: TargetPlatform.windows);
      expect(find.byType(DesktopMobileControls), findsNothing);
    },
  );

  testWidgets(
    'disconnection closes keyboard and prevents subsequent IME sends',
    (tester) async {
      final session = await _mount(tester);
      await _open(tester);
      session.state = 'error';
      session.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(
        find.byKey(const ValueKey('desktop_special_keybar')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one dock tap activates an excluded pane before IME input', (
    tester,
  ) async {
    final session = _Session();
    var inactive = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Listener(
              onPointerDown: (_) => setState(() => inactive = false),
              child: ExcludeFocus(
                excluding: inactive,
                child: DesktopView(session: session),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _open(tester);
    await tester.pump();
    tester.testTextInput.enterText('A');
    await tester.pump();
    expect(session.keys, [
      ['key', 0x01000041, 1],
      ['key', 0x01000041, 0],
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('app pause releases soft modifiers and the IME connection', (
    tester,
  ) async {
    final session = await _mount(tester);
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('desktop_key_65507')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(session.keys.last, ['key', 0xffe3, 0]);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  group('relative touchpad', () {
    late Offset point;
    late List<(Offset, int)> events;
    late DesktopTouchInput input;
    void handle(PointerEvent e) =>
        input.handle(e, bounds: const Rect.fromLTWH(0, 0, 500, 500), scale: 2);
    setUp(() {
      point = const Offset(100, 100);
      events = [];
      input = DesktopTouchInput(
        pointer: () => point,
        send: (p, b) {
          point = p;
          events.add((p, b));
        },
      )..trackpad = true;
    });
    tearDown(() => input.dispose());
    test('one-finger motion is relative and sends no pressed button', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerMoveEvent(pointer: 1, position: Offset(320, 340)));
      handle(const PointerUpEvent(pointer: 1, position: Offset(320, 340)));
      expect(point, const Offset(110, 120));
      expect(events.map((e) => e.$2), [0]);
    });
    test('tap clicks current cursor without jumping to touched position', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerUpEvent(pointer: 1, position: Offset(300, 300)));
      expect(events, [
        (const Offset(100, 100), 1),
        (const Offset(100, 100), 0),
      ]);
    });
    test('two fingers tap right-clicks; two fingers move scrolls', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerDownEvent(pointer: 2, position: Offset(320, 300)));
      handle(const PointerUpEvent(pointer: 1));
      handle(const PointerUpEvent(pointer: 2));
      expect(events.map((e) => e.$2), [4, 0]);
      events.clear();
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerDownEvent(pointer: 2, position: Offset(320, 300)));
      handle(const PointerMoveEvent(pointer: 1, position: Offset(300, 345)));
      handle(const PointerUpEvent(pointer: 1));
      handle(const PointerUpEvent(pointer: 2));
      expect(events.map((e) => e.$2), [16, 0]);
    });
    test('second tap and drag holds button; cancel releases and clears it', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerUpEvent(pointer: 1));
      events.clear();
      handle(const PointerDownEvent(pointer: 2, position: Offset(300, 300)));
      handle(const PointerMoveEvent(pointer: 2, position: Offset(330, 300)));
      handle(const PointerCancelEvent(pointer: 2));
      expect(events.map((e) => e.$2), [1, 1, 0]);
      expect(point, const Offset(115, 100));
    });
    testWidgets('stationary long-press right-clicks once', (tester) async {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      handle(const PointerUpEvent(pointer: 1));
      expect(events.map((e) => e.$2), [4, 0]);
    });
  });
}
