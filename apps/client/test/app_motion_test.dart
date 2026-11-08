import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/app_motion.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic, parent-owned transport: counts attaches/detaches of the live
/// view and records keystrokes that reach it. No network, no secrets.
class _SyntheticTransport {
  int attaches = 0, detaches = 0;
  final keys = <String>[];
  int get liveViews => attaches - detaches;
}

class _LiveTerminalView extends StatefulWidget {
  const _LiveTerminalView({
    super.key,
    required this.transport,
    required this.focusNode,
  });
  final _SyntheticTransport transport;
  final FocusNode focusNode;
  @override
  State<_LiveTerminalView> createState() => _LiveTerminalViewState();
}

class _LiveTerminalViewState extends State<_LiveTerminalView> {
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.transport.attaches++;
  }

  @override
  void dispose() {
    widget.transport.detaches++;
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent) {
        widget.transport.keys.add(event.logicalKey.keyLabel);
      }
      return KeyEventResult.handled;
    },
    child: ListView.builder(
      key: const ValueKey('live_scroll'),
      controller: scroll,
      itemExtent: 20,
      itemCount: 200,
      itemBuilder: (_, i) => Text('line $i'),
    ),
  );
}

Widget _app(Widget home, {bool disable = false, bool accessible = false}) =>
    MaterialApp(
      theme: buildAppTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disable,
          accessibleNavigation: accessible,
        ),
        child: child!,
      ),
      home: home,
    );

Finder _entranceOf(Finder child) =>
    find.ancestor(of: child, matching: find.byType(MotionEntrance)).first;

double _opacity(WidgetTester tester, Finder entrance) => tester
    .widget<Opacity>(
      find.descendant(of: entrance, matching: find.byType(Opacity)).first,
    )
    .opacity;

Offset _lift(WidgetTester tester, Finder entrance) {
  final t = tester
      .widget<Transform>(
        find.descendant(of: entrance, matching: find.byType(Transform)).first,
      )
      .transform
      .getTranslation();
  return Offset(t.x, t.y);
}

void main() {
  group('page switch (MotionEntrance)', () {
    late _SyntheticTransport transport;
    late FocusNode focus;
    final terminalKey = GlobalKey();

    setUp(() {
      transport = _SyntheticTransport();
      focus = FocusNode(debugLabel: 'terminal');
    });
    tearDown(() => focus.dispose());

    Widget page(String name, {bool disable = false, bool accessible = false}) =>
        _app(
          Scaffold(
            body: MotionEntrance(
              trigger: name,
              child: name == 'terminal'
                  ? _LiveTerminalView(
                      key: terminalKey,
                      transport: transport,
                      focusNode: focus,
                    )
                  : Center(child: Text('page $name')),
            ),
          ),
          disable: disable,
          accessible: accessible,
        );

    testWidgets('incoming page fades + lifts and settles at the final state', (
      tester,
    ) async {
      await tester.pumpWidget(page('hosts'));
      // No startup animation.
      expect(_opacity(tester, _entranceOf(find.text('page hosts'))), 1);
      await tester.pumpWidget(page('groups'));
      await tester.pump(const Duration(milliseconds: 40));
      final entrance = _entranceOf(find.text('page groups'));
      expect(_opacity(tester, entrance), inExclusiveRange(0, 1));
      expect(_lift(tester, entrance).dy, greaterThan(0));
      await tester.pump(MotionDurations.page);
      expect(_opacity(tester, entrance), 1);
      expect(_lift(tester, entrance), Offset.zero);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('rapid interrupted navigation never mounts a live view twice', (
      tester,
    ) async {
      for (final name in [
        'hosts',
        'terminal',
        'hosts',
        'terminal',
        'sftp',
        'terminal',
      ]) {
        await tester.pumpWidget(page(name));
        await tester.pump(const Duration(milliseconds: 30));
        expect(tester.takeException(), isNull);
        expect(transport.liveViews, name == 'terminal' ? 1 : 0);
        expect(
          find.byType(_LiveTerminalView),
          name == 'terminal' ? findsOneWidget : findsNothing,
        );
      }
      await tester.pumpAndSettle();
      expect(_opacity(tester, _entranceOf(find.byKey(terminalKey))), 1);
    });

    testWidgets('keystrokes reach the live view during its entrance', (
      tester,
    ) async {
      await tester.pumpWidget(page('hosts'));
      await tester.pumpWidget(page('terminal'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(focus.hasFocus, isTrue);
      expect(
        _opacity(tester, _entranceOf(find.byKey(terminalKey))),
        lessThan(1),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      expect(transport.keys, ['A', 'B']);
    });

    testWidgets(
      'replaying the entrance keeps the same live State, focus and scroll',
      (tester) async {
        Widget live(Object trigger) => _app(
          Scaffold(
            body: MotionEntrance(
              trigger: trigger,
              child: _LiveTerminalView(
                key: terminalKey,
                transport: transport,
                focusNode: focus,
              ),
            ),
          ),
        );
        await tester.pumpWidget(live(1));
        await tester.pump();
        final state = tester.state(find.byKey(terminalKey));
        state as _LiveTerminalViewState;
        state.scroll.jumpTo(300);
        for (var i = 2; i < 6; i++) {
          await tester.pumpWidget(live(i));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
        expect(identical(tester.state(find.byKey(terminalKey)), state), isTrue);
        expect(transport.attaches, 1);
        expect(transport.detaches, 0);
        expect(focus.hasFocus, isTrue);
        expect(state.scroll.offset, 300);
      },
    );

    testWidgets('pointer hits land on the incoming page from the first frame', (
      tester,
    ) async {
      var taps = 0;
      Widget withButton(String name) => _app(
        Scaffold(
          body: MotionEntrance(
            trigger: name,
            child: Center(
              child: TextButton(
                key: ValueKey(name),
                onPressed: () => taps++,
                child: Text(name),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(withButton('a'));
      await tester.pumpWidget(withButton('b'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('b')));
      expect(taps, 1);
    });

    testWidgets('disableAnimations shows the final state immediately', (
      tester,
    ) async {
      await tester.pumpWidget(page('hosts', disable: true));
      await tester.pumpWidget(page('groups', disable: true));
      final entrance = _entranceOf(find.text('page groups'));
      expect(_opacity(tester, entrance), 1);
      expect(_lift(tester, entrance), Offset.zero);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('screen reader navigation fades without movement and keeps '
        'semantics during the fade', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(page('hosts', accessible: true));
      await tester.pumpWidget(page('groups', accessible: true));
      await tester.pump(const Duration(milliseconds: 20));
      final entrance = _entranceOf(find.text('page groups'));
      expect(_opacity(tester, entrance), lessThan(1));
      expect(_lift(tester, entrance), Offset.zero);
      expect(find.bySemanticsLabel('page groups'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('disposing mid-animation retires the ticker', (tester) async {
      await tester.pumpWidget(page('hosts'));
      await tester.pumpWidget(page('groups'));
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('dialogs', () {
    testWidgets('centre dialog scales in, exit lets taps reach the page, '
        'content is disposed', (tester) async {
      var disposed = false, pageTaps = 0;
      late BuildContext launcher;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) {
                launcher = context;
                return Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    onPressed: () => pageTaps++,
                    child: const Text('page action'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      final result = showAppDialog<String>(
        context: launcher,
        builder: (_) => _DisposeProbe(onDispose: () => disposed = true),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      Finder frameTransform() => find
          .descendant(
            of: find.byType(AppDialogMotionFrame),
            matching: find.byType(Transform),
          )
          .first;
      final scale = tester
          .widget<Transform>(frameTransform())
          .transform
          .entry(0, 0);
      expect(scale, inExclusiveRange(MotionDistances.dialogScale, 1));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Transform>(frameTransform()).transform.entry(0, 0),
        1,
      );
      Navigator.of(tester.element(find.byType(AlertDialog))).pop('done');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      // Still fading out, but no longer intercepting pointers.
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('page action'), warnIfMissed: false);
      expect(pageTaps, 1);
      await tester.pumpAndSettle();
      expect(await result, 'done');
      expect(find.byType(AlertDialog), findsNothing);
      expect(disposed, isTrue);
    });

    testWidgets('reduced motion: dialog opens and closes in one frame', (
      tester,
    ) async {
      late BuildContext launcher;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              launcher = context;
              return const Scaffold();
            },
          ),
          disable: true,
        ),
      );
      showAppDialog<void>(
        context: launcher,
        builder: (_) => const AlertDialog(content: Text('final state')),
      );
      await tester.pump();
      final route = ModalRoute.of(tester.element(find.text('final state')))!;
      expect(route.animation!.value, 1);
      expect(
        find.ancestor(
          of: find.byType(AlertDialog),
          matching: find.byType(AppDialogMotionFrame),
        ),
        findsOneWidget,
      );
      // Same wrapper structure as full motion, but an identity transform.
      expect(
        tester
            .widget<Transform>(
              find
                  .descendant(
                    of: find.byType(AppDialogMotionFrame),
                    matching: find.byType(Transform),
                  )
                  .first,
            )
            .transform
            .isIdentity(),
        isTrue,
      );
      Navigator.of(tester.element(find.text('final state'))).pop();
      await tester.pump();
      await tester.pump();
      expect(find.text('final state'), findsNothing);
    });

    testWidgets('Host editor side sheet slides from the right, fits a narrow '
        'phone with the keyboard open', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.reset);
      late BuildContext launcher;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              launcher = context;
              return const Scaffold();
            },
          ),
        ),
      );
      final result = showHostEditorPanel(
        launcher,
        groups: const <GroupRecord>[],
        hosts: const <HostRecord>[],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final frame = find.byType(AppDialogMotionFrame);
      final dx = tester
          .widget<Transform>(
            find.descendant(of: frame, matching: find.byType(Transform)).first,
          )
          .transform
          .getTranslation()
          .x;
      expect(dx, inExclusiveRange(0, MotionDistances.sheet));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final panel = tester.getRect(
        find
            .descendant(
              of: find.byType(HostEditorPanel),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(panel.right, closeTo(360, .01));
      expect(panel.width, lessThanOrEqualTo(360));
      expect(panel.bottom, lessThanOrEqualTo(640 - 260 + .01));
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(find.byType(HostEditorPanel), findsNothing);
    });
  });

  group('menus, routes, status swaps', () {
    testWidgets('reduced motion: popup menu appears and dismisses instantly', (
      tester,
    ) async {
      String? picked;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => PopupMenuButton<String>(
                popUpAnimationStyle: AppMotion.menuStyle(context),
                onSelected: (value) => picked = value,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'x', child: Text('menu item')),
                ],
              ),
            ),
          ),
          disable: true,
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pump();
      expect(
        ModalRoute.of(tester.element(find.text('menu item')))!.animation!.value,
        1,
      );
      await tester.tap(find.text('menu item'));
      await tester.pump();
      expect(picked, 'x');
      expect(find.text('menu item'), findsNothing);
    });

    testWidgets('menu motion is 160 ms, not the 300 ms default', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: Builder(
              builder: (context) => PopupMenuButton<String>(
                popUpAnimationStyle: AppMotion.menuStyle(context),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'x', child: Text('menu item')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pump();
      await tester.pump(MotionDurations.standard);
      expect(
        ModalRoute.of(tester.element(find.text('menu item')))!.animation!.value,
        1,
      );
    });

    testWidgets('theme route: one 200 ms fade + lift, reduced motion hides a '
        'popped page at once', (tester) async {
      for (final disable in [false, true]) {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(disable),
            navigatorKey: navigator,
            theme: buildAppTheme().copyWith(platform: TargetPlatform.windows),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: disable),
              child: child!,
            ),
            home: const Scaffold(body: Text('first page')),
          ),
        );
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('second page')),
          ),
        );
        await tester.pump();
        await tester.pump(); // first frame is the framework's offstage pass
        if (!disable) {
          await tester.pump(const Duration(milliseconds: 60));
          expect(tester.binding.transientCallbackCount, greaterThan(0));
          await tester.pump(const Duration(milliseconds: 141));
          expect(tester.binding.transientCallbackCount, 0);
        }
        expect(find.text('second page').hitTestable(), findsOneWidget);
        expect(
          ModalRoute.of(tester.element(find.text('second page')))!
              .animation!
              .isCompleted,
          disable ? isFalse : isTrue,
        );
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump();
        if (disable) {
          expect(find.text('second page').hitTestable(), findsNothing);
        }
        await tester.pumpAndSettle();
        expect(find.text('second page'), findsNothing);
        expect(find.text('first page').hitTestable(), findsOneWidget);
      }
    });

    testWidgets('MotionSwitcher outgoing child takes no taps, focus or '
        'semantics', (tester) async {
      var oldTaps = 0;
      final oldFocus = FocusNode();
      addTearDown(oldFocus.dispose);
      Widget state(bool loading) => _app(
        Scaffold(
          body: Center(
            child: MotionSwitcher(
              child: loading
                  ? TextButton(
                      key: const ValueKey('loading'),
                      focusNode: oldFocus,
                      onPressed: () => oldTaps++,
                      child: const Text('retry'),
                    )
                  : const Text('connected', key: ValueKey('done')),
            ),
          ),
        ),
      );
      await tester.pumpWidget(state(true));
      oldFocus.requestFocus();
      await tester.pump();
      expect(oldFocus.hasFocus, isTrue);
      await tester.pumpWidget(state(false));
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('retry'), findsOneWidget); // still fading out
      expect(oldFocus.hasFocus, isFalse);
      await tester.tap(find.text('retry'), warnIfMissed: false);
      expect(oldTaps, 0);
      await tester.pumpAndSettle();
      expect(find.text('retry'), findsNothing);
      expect(find.text('connected'), findsOneWidget);
    });
  });

  group('runtime accessibility changes (no remount)', () {
    // Reduced motion / screen reader can be switched while a dialog, page or
    // live view is open. Only values may change; State, input and focus stay.
    Widget toggling(
      ValueNotifier<(bool, bool)> a11y,
      Widget home, {
      GlobalKey<NavigatorState>? navigator,
    }) => MaterialApp(
      navigatorKey: navigator,
      theme: buildAppTheme().copyWith(platform: TargetPlatform.windows),
      builder: (context, child) => ValueListenableBuilder<(bool, bool)>(
        valueListenable: a11y,
        builder: (context, value, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: value.$1,
            accessibleNavigation: value.$2,
          ),
          child: child!,
        ),
      ),
      home: home,
    );
    const levels = [(true, false), (false, true), (false, false), (true, true)];

    for (final motion in AppDialogMotion.values) {
      testWidgets('dialog ($motion) keeps State, text and focus', (
        tester,
      ) async {
        final a11y = ValueNotifier((false, false));
        addTearDown(a11y.dispose);
        late BuildContext launcher;
        await tester.pumpWidget(
          toggling(
            a11y,
            Builder(
              builder: (context) {
                launcher = context;
                return const Scaffold();
              },
            ),
          ),
        );
        var disposed = false;
        showAppDialog<void>(
          context: launcher,
          motion: motion,
          builder: (_) => _DisposeProbe(onDispose: () => disposed = true),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'unsaved host edit');
        final state = tester.state(find.byType(_DisposeProbe));
        final focus = FocusManager.instance.primaryFocus;
        for (final level in levels) {
          a11y.value = level;
          await tester.pumpAndSettle();
          expect(
            identical(tester.state(find.byType(_DisposeProbe)), state),
            isTrue,
          );
          expect(find.text('unsaved host edit'), findsOneWidget);
          expect(FocusManager.instance.primaryFocus, same(focus));
        }
        expect(disposed, isFalse);
      });
    }

    testWidgets('theme page route keeps State and text', (tester) async {
      final a11y = ValueNotifier((false, false));
      addTearDown(a11y.dispose);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        toggling(a11y, const Scaffold(), navigator: navigator),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: _DisposeProbe(onDispose: () {})),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'unsaved page edit');
      final state = tester.state(find.byType(_DisposeProbe));
      for (final level in levels) {
        a11y.value = level;
        await tester.pumpAndSettle();
        expect(
          identical(tester.state(find.byType(_DisposeProbe)), state),
          isTrue,
        );
        expect(find.text('unsaved page edit'), findsOneWidget);
      }
    });

    testWidgets('page entrance keeps the live view during a toggle '
        'mid-animation', (tester) async {
      final a11y = ValueNotifier((false, false));
      addTearDown(a11y.dispose);
      final transport = _SyntheticTransport();
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final key = GlobalKey();
      Widget page(String name) => toggling(
        a11y,
        Scaffold(
          body: MotionEntrance(
            trigger: name,
            child: _LiveTerminalView(
              key: key,
              transport: transport,
              focusNode: focus,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page('a'));
      await tester.pumpWidget(page('b'));
      await tester.pump(const Duration(milliseconds: 40));
      for (final level in levels) {
        a11y.value = level;
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(transport.attaches, 1);
      expect(transport.detaches, 0);
      expect(focus.hasFocus, isTrue);
      expect(_opacity(tester, _entranceOf(find.byKey(key))), 1);
    });
  });

  group('status transitions', () {
    Widget bar(String status, {bool reduced = false}) => _app(
      Scaffold(
        bottomNavigationBar: WorkspaceStatusBar(
          status: status,
          detail: 'ops@edge.example.test',
          sessionCount: 1,
        ),
      ),
      disable: reduced,
    );

    testWidgets('SSH status cross-fades and settles on the new state', (
      tester,
    ) async {
      await tester.pumpWidget(bar('SSH connecting'));
      await tester.pumpWidget(bar('SSH connected'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('SSH connecting'), findsOneWidget); // fading out
      expect(find.text('SSH connected'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('SSH connecting'), findsNothing);
      expect(find.text('SSH connected'), findsOneWidget);
    });

    testWidgets('reduced motion: SSH status swaps in one frame', (
      tester,
    ) async {
      await tester.pumpWidget(bar('SSH connecting', reduced: true));
      await tester.pumpWidget(bar('SSH disconnected', reduced: true));
      await tester.pump();
      expect(find.text('SSH connecting'), findsNothing);
      expect(find.text('SSH disconnected'), findsOneWidget);
    });
  });

  group('workspace tab strip', () {
    Widget bar(
      List<WorkspaceTab> tabs,
      String selected, {
      ValueChanged<String>? onSelect,
    }) => _app(
      Scaffold(
        body: WorkspaceTabBar(
          tabs: tabs,
          selectedId: selected,
          onSelect: onSelect ?? (_) {},
          onClose: (_) {},
        ),
      ),
    );
    const home = WorkspaceTab(id: 'hosts', title: 'Hosts', isHome: true);
    const a = WorkspaceTab(id: 'a', title: 'alpha', isConnected: true);
    const b = WorkspaceTab(id: 'b', title: 'beta', isConnected: true);

    Finder motionOf(String id) =>
        find.byKey(ValueKey('workspace-tab-motion-$id'));
    double tabOpacity(WidgetTester tester, String id) => _opacity(
      tester,
      find.descendant(of: motionOf(id), matching: find.byType(MotionEntrance)),
    );

    testWidgets('restored tabs appear instantly; a new tab eases in and is '
        'clickable at once', (tester) async {
      String? selected;
      await tester.pumpWidget(bar(const [home, a], 'a'));
      expect(tabOpacity(tester, 'a'), 1);
      await tester.pumpWidget(
        bar(const [home, a, b], 'b', onSelect: (id) => selected = id),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(tabOpacity(tester, 'b'), inExclusiveRange(0, 1));
      expect(tabOpacity(tester, 'a'), 1);
      await tester.tap(find.byKey(const ValueKey('workspace-tab-b')));
      expect(selected, 'b');
      await tester.pumpAndSettle();
      expect(tabOpacity(tester, 'b'), 1);
    });

    testWidgets('closing a tab removes it immediately (no ghost)', (
      tester,
    ) async {
      await tester.pumpWidget(bar(const [home, a, b], 'b'));
      await tester.pumpWidget(bar(const [home, a], 'a'));
      await tester.pump();
      expect(find.byKey(const ValueKey('workspace-tab-b')), findsNothing);
      expect(find.text('beta'), findsNothing);
    });

    testWidgets('selection colour eases and settles on the selected fill', (
      tester,
    ) async {
      await tester.pumpWidget(bar(const [home, a, b], 'a'));
      Color? fill(String id) => tester
          .widget<Material>(find.byKey(ValueKey('workspace-tab-surface-$id')))
          .color;
      final selectedFill = fill('a'), idleFill = fill('b');
      expect(selectedFill, isNot(idleFill));
      await tester.pumpWidget(bar(const [home, a, b], 'b'));
      await tester.pump(const Duration(milliseconds: 40));
      expect(fill('b'), isNot(selectedFill));
      expect(fill('b'), isNot(idleFill));
      await tester.pumpAndSettle();
      expect(fill('b'), selectedFill);
      expect(fill('a'), idleFill);
    });

    testWidgets('reduced motion: selection and new tabs are final at once', (
      tester,
    ) async {
      Widget reduced(List<WorkspaceTab> tabs, String selected) => _app(
        Scaffold(
          body: WorkspaceTabBar(
            tabs: tabs,
            selectedId: selected,
            onSelect: (_) {},
            onClose: (_) {},
          ),
        ),
        disable: true,
      );
      await tester.pumpWidget(reduced(const [home, a], 'a'));
      await tester.pumpWidget(reduced(const [home, a, b], 'b'));
      await tester.pump();
      expect(tabOpacity(tester, 'b'), 1);
      expect(tester.binding.transientCallbackCount, 0);
    });
  });
}

class _DisposeProbe extends StatefulWidget {
  const _DisposeProbe({required this.onDispose});
  final VoidCallback onDispose;
  @override
  State<_DisposeProbe> createState() => _DisposeProbeState();
}

class _DisposeProbeState extends State<_DisposeProbe> {
  final controller = TextEditingController(text: 'synthetic');
  @override
  void dispose() {
    controller.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AlertDialog(content: TextField(controller: controller));
}
