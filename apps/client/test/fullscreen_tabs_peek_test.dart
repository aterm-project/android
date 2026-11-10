import 'package:aterm_client/platform/fullscreen.dart';
import 'package:aterm_client/ui/fullscreen_tabs_peek.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for a terminal/desktop view: counts mounts, taps and viewport
/// sizes so remounts, resizes and click-through are observable.
class _Term extends StatefulWidget {
  const _Term(this.id, {super.key});
  final String id;
  static final inits = <String, int>{};
  static final taps = <String, int>{};
  static final sizes = <String, List<Size>>{};
  static void reset() {
    inits.clear();
    taps.clear();
    sizes.clear();
  }

  @override
  State<_Term> createState() => _TermState();
}

class _TermState extends State<_Term> {
  @override
  void initState() {
    super.initState();
    _Term.inits.update(widget.id, (v) => v + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sizes = _Term.sizes.putIfAbsent(widget.id, () => []);
      if (sizes.isEmpty || sizes.last != constraints.biggest) {
        sizes.add(constraints.biggest);
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () =>
            _Term.taps.update(widget.id, (v) => v + 1, ifAbsent: () => 1),
        child: ColoredBox(
          color: Colors.black,
          child: Center(child: Text('term-${widget.id}')),
        ),
      );
    },
  );
}

class _Harness extends StatefulWidget {
  const _Harness({
    required this.layout,
    required this.closed,
    required this.splits,
  });
  final SessionWorkspaceController layout;
  final List<String> closed;
  final List<(String, Axis)> splits;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final keys = <String, GlobalKey>{};
  late String selected = widget.layout.selectedId!;
  static const titles = {'a': 'alpha', 'b': 'beta', 'c': 'gamma'};

  void select(String id) {
    setState(() => selected = id);
    if (id != 'home') widget.layout.activate(id);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      WorkspaceTabBar(
        tabs: [
          const WorkspaceTab(id: 'home', title: 'Home', isHome: true),
          for (final entry in titles.entries)
            WorkspaceTab(id: entry.key, title: entry.value, isConnected: true),
        ],
        groups: widget.layout.groupedSessionIds,
        groupSelections: widget.layout.retainedGroupSelections,
        selectedId: selected,
        onSelect: select,
        onClose: widget.closed.add,
      ),
      Expanded(
        child: selected == 'home'
            ? const Center(child: Text('home page'))
            : SessionWorkspaceView(
                controller: widget.layout,
                onSelect: (id) => setState(() => selected = id),
                onClose: widget.closed.add,
                onSplit: (id, axis) => widget.splits.add((id, axis)),
                splitTargets: () => titles.keys,
                paneLabel: (id) => titles[id] ?? id,
                terminalBuilder: (_, id) =>
                    _Term(id, key: keys.putIfAbsent(id, GlobalKey.new)),
              ),
      ),
      // Stand-in for a workspace dock (e.g. the shared keybar) below panes.
      GestureDetector(
        key: const ValueKey('test-dock'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _Term.taps.update('dock', (v) => v + 1, ifAbsent: () => 1),
        child: const SizedBox(height: 48, width: double.infinity),
      ),
    ],
  );
}

void main() {
  late FullscreenController fullscreen;
  late FullscreenTabsPeek peek;
  late SessionWorkspaceController layout;
  late List<String> closed;
  late List<(String, Axis)> splits;

  final navBar = find.byKey(const ValueKey('workspace_navigation_bar'));
  final overlay = find.byKey(const ValueKey('fullscreen_tabs_overlay'));
  Finder handle(String id) => find.byKey(ValueKey('pane-handle-$id'));

  setUp(() {
    _Term.reset();
    var native = false;
    fullscreen = FullscreenController(
      supported: true,
      read: () async => native,
      changes: const Stream.empty(),
      apply: (value) async => native = value,
    );
    FullscreenController.debugInstance = fullscreen;
    peek = FullscreenTabsPeek();
    FullscreenTabsPeek.debugInstance = peek;
    // a | b split (b selected) plus a separate tab c.
    layout = SessionWorkspaceController()
      ..activate('a')
      ..split('b', 'a', SessionSplitEdge.right);
    closed = [];
    splits = [];
  });

  tearDown(() {
    peek.hide();
    FullscreenController.debugInstance = null;
    FullscreenTabsPeek.debugInstance = null;
  });

  Future<void> pumpHarness(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: _Harness(layout: layout, closed: closed, splits: splits),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await fullscreen.toggle();
    await tester.pumpAndSettle();
    expect(fullscreen.enabled, isTrue);
    expect(navBar, findsNothing);
    // Entering fullscreen pins the pane actions (exit button) as before;
    // retract them so the handle starts collapsed.
    await tester.tapAt(tester.getCenter(find.text('term-b')));
    await tester.pumpAndSettle();
  }

  Future<void> cleanUp(WidgetTester tester) async {
    peek.hide();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    layout.dispose();
    fullscreen.dispose();
  }

  testWidgets('handle drops the tabs over the pane without resizing, '
      'remounting or leaving fullscreen, then auto-hides', (tester) async {
    await pumpHarness(tester);
    // Offstage panes are skipped: this is the one fullscreen pane.
    final term = find.byType(_Term);
    final fullSize = tester.getSize(term);
    final termState = tester.state(term);
    final sizesBefore = List.of(_Term.sizes['b']!);
    final tapsBefore = _Term.taps['b'] ?? 0;

    await tester.tap(handle('b'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(peek.visible, isTrue);
    expect(overlay, findsOneWidget);
    expect(navBar, findsOneWidget);
    expect(fullscreen.enabled, isTrue);
    // Overlay only: the terminal viewport keeps its size and identity.
    expect(tester.getSize(term), fullSize);
    expect(tester.state(term), same(termState));
    expect(_Term.sizes['b'], sizesBefore);
    expect(_Term.inits, {'a': 1, 'b': 1});
    expect(_Term.taps['b'] ?? 0, tapsBefore);
    // Handle and its Close/Split actions sit just below the dropped strip.
    final barBottom = tester.getRect(navBar).bottom;
    expect(tester.getRect(handle('b')).top, greaterThanOrEqualTo(barBottom));
    for (final key in ['pane-close-b', 'pane-split-b']) {
      final button = find.byKey(ValueKey(key));
      expect(button, findsOneWidget);
      expect(tester.getRect(button).top, greaterThanOrEqualTo(barBottom));
      expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
    }
    expect(
      find.byKey(const ValueKey('workspace_exit_fullscreen')),
      findsOneWidget,
    );

    // Auto-hide after ~4 s of inactivity.
    await tester.pump(const Duration(seconds: 3));
    expect(peek.visible, isTrue);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    expect(overlay, findsNothing);
    expect(navBar, findsNothing);
    expect(find.byKey(const ValueKey('pane-close-b')), findsNothing);
    expect(fullscreen.enabled, isTrue);
    expect(tester.getSize(term), fullSize);
    expect(_Term.inits, {'a': 1, 'b': 1});

    // Handle tap toggles: show, then retract immediately.
    await tester.tap(handle('b'));
    await tester.pump();
    expect(peek.visible, isTrue);
    await tester.tap(handle('b'));
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    await cleanUp(tester);
  });

  testWidgets('outside tap dismisses with no click-through to the terminal', (
    tester,
  ) async {
    await pumpHarness(tester);
    final tapsBefore = _Term.taps['b'] ?? 0;
    await tester.tap(handle('b'));
    await tester.pump();
    expect(peek.visible, isTrue);
    expect(
      find.byKey(const ValueKey('fullscreen-tabs-barrier')),
      findsOneWidget,
    );
    await tester.tapAt(tester.getCenter(find.text('term-b')));
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    expect(navBar, findsNothing);
    expect(_Term.taps['b'] ?? 0, tapsBefore, reason: 'tap must not leak');
    // Taps reach the terminal again once the strip is gone.
    await tester.tapAt(tester.getCenter(find.text('term-b')));
    await tester.pump();
    expect(_Term.taps['b'], tapsBefore + 1);
    expect(fullscreen.enabled, isTrue);

    // Outside the pane (dock below it): dismisses and the tap is consumed.
    final dock = find.byKey(const ValueKey('test-dock'));
    await tester.tap(handle('b'));
    await tester.pump();
    expect(peek.visible, isTrue);
    await tester.tap(dock);
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    expect(_Term.taps['dock'], isNull, reason: 'dismissal tap is consumed');
    await tester.tap(dock);
    await tester.pump();
    expect(_Term.taps['dock'], 1);
    expect(_Term.taps['b'], tapsBefore + 1);

    // A tap on an empty part of the strip is absorbed and keeps it open.
    await tester.tap(handle('b'));
    await tester.pump();
    final bar = tester.getRect(navBar);
    // Right of the last tab: the strip's empty drop gap.
    await tester.tapAt(Offset(600, bar.center.dy));
    await tester.pump();
    expect(peek.visible, isTrue);
    expect(_Term.taps['b'], tapsBefore + 1);
    await cleanUp(tester);
  });

  testWidgets('switching tabs from the strip keeps fullscreen and panes; '
      'menus hold the strip open', (tester) async {
    await pumpHarness(tester);
    final stateA = tester.state(find.byType(_Term, skipOffstage: false).first);
    await tester.tap(handle('b'));
    await tester.pump();

    // Split group menu (long-press) switches to the other pane in place.
    await tester.longPress(find.byKey(const ValueKey('workspace-group-a')));
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsWidgets);
    // An open menu pauses auto-hide.
    await tester.pump(const Duration(seconds: 6));
    expect(peek.visible, isTrue);
    await tester.tap(find.text('alpha').last);
    await tester.pumpAndSettle();
    expect(layout.selectedId, 'a');
    expect(fullscreen.enabled, isTrue);
    expect(peek.visible, isTrue, reason: 'stays up after the choice');
    expect(find.text('term-a'), findsOneWidget);
    expect(find.text('term-b'), findsNothing);
    expect(
      tester.state(find.byType(_Term, skipOffstage: false).first),
      same(stateA),
    );
    expect(_Term.inits, {'a': 1, 'b': 1});
    expect(layout.sessionIds, ['a', 'b']);

    // A plain tab tap switches to another workspace tab, still fullscreen.
    await tester.tap(find.byKey(const ValueKey('workspace-tab-c')));
    await tester.pumpAndSettle();
    expect(layout.selectedId, 'c');
    expect(fullscreen.enabled, isTrue);
    expect(find.text('term-c'), findsOneWidget);
    expect(
      tester.getSize(find.byType(_Term)),
      tester.getSize(find.byType(SessionWorkspaceView)),
    );
    // Back to the split group restores the identical a|b split.
    await tester.tap(find.byKey(const ValueKey('workspace-group-a')));
    await tester.pumpAndSettle();
    expect(layout.sessionIds, ['a', 'b']);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    await fullscreen.toggle();
    await tester.pumpAndSettle();
    final view = tester.getSize(find.byType(SessionWorkspaceView));
    expect(find.text('term-a').hitTestable(), findsOneWidget);
    expect(find.text('term-b').hitTestable(), findsOneWidget);
    expect(
      tester.getSize(find.text('term-a').hitTestable()).width,
      lessThan(view.width),
    );
    await cleanUp(tester);
  });

  testWidgets('a tab drag from the strip splits onto the fullscreen pane and '
      'holds the strip while dragging', (tester) async {
    await pumpHarness(tester);
    await tester.tap(handle('b'));
    await tester.pump();
    final pane = tester.getRect(find.byType(SessionWorkspaceView));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('workspace-tab-c'))),
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveTo(Offset(pane.right - 8, pane.center.dy));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(peek.visible, isTrue, reason: 'no hide mid-drag');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(layout.sessionIds, ['a', 'b', 'c']);
    expect(fullscreen.enabled, isTrue);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    await cleanUp(tester);
  });

  testWidgets('handle Close and Split use the session flows on a small '
      'portrait phone', (tester) async {
    await pumpHarness(tester, size: const Size(360, 740));
    await tester.tap(handle('b'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('pane-close-b')));
    await tester.pump();
    expect(closed, ['b']);

    await tester.tap(find.byKey(const ValueKey('pane-split-b')));
    await tester.pumpAndSettle();
    expect(peek.visible, isTrue, reason: 'menu holds the strip');
    // Only sessions outside this layout are offered as partners.
    expect(find.byKey(const ValueKey('pane-split-with-a')), findsNothing);
    expect(find.byKey(const ValueKey('pane-split-with-c')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pane-split-vertical-b')));
    await tester.pumpAndSettle();
    expect(splits, [('b', Axis.vertical)]);

    await tester.tap(find.byKey(const ValueKey('pane-split-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pane-split-horizontal-b')));
    await tester.pumpAndSettle();
    expect(splits.last, ('b', Axis.horizontal));

    // Explicit partner: portrait places it below, selected and fullscreen.
    await tester.tap(find.byKey(const ValueKey('pane-split-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pane-split-with-c')));
    await tester.pumpAndSettle();
    expect(layout.sessionIds, ['a', 'b', 'c']);
    expect(layout.selectedId, 'c');
    final root = layout.root! as SessionWorkspaceSplit;
    final bc = root.second as SessionWorkspaceSplit;
    expect(bc.axis, Axis.vertical);
    expect(fullscreen.enabled, isTrue);
    expect(find.text('term-c'), findsOneWidget);
    expect(find.text('term-b'), findsNothing);
    expect(_Term.inits['b'], 1);
    expect(tester.takeException(), isNull);
    await cleanUp(tester);
  });

  testWidgets('Home in the strip escapes to the normal bar; Back retracts '
      'the strip before leaving fullscreen', (tester) async {
    await pumpHarness(tester);
    await tester.tap(handle('b'));
    await tester.pump();
    // Back retracts the strip first and stays fullscreen.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(peek.visible, isFalse);
    expect(fullscreen.enabled, isTrue);

    await tester.tap(handle('b'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('workspace-tab-home')));
    await tester.pumpAndSettle();
    expect(find.text('home page'), findsOneWidget);
    expect(overlay, findsNothing);
    expect(peek.visible, isFalse);
    expect(fullscreen.enabled, isTrue);
    // The in-layout bar keeps its Tools menu as the way out.
    expect(navBar, findsOneWidget);
    await tester.tap(find.byTooltip('Tools'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exit fullscreen'));
    await tester.pumpAndSettle();
    expect(fullscreen.enabled, isFalse);
    // Back in the session: the identical split comes back.
    await tester.tap(find.byKey(const ValueKey('workspace-group-a')));
    await tester.pumpAndSettle();
    expect(layout.sessionIds, ['a', 'b']);
    expect(find.text('term-a').hitTestable(), findsOneWidget);
    expect(find.text('term-b').hitTestable(), findsOneWidget);
    await cleanUp(tester);
  });

  test('peek timer pauses while held and blocked', () {
    final controller = FullscreenTabsPeek(autoHide: Duration.zero);
    controller.show();
    expect(controller.debugTimerActive, isTrue);
    controller.pointerDown(1);
    expect(controller.debugTimerActive, isFalse);
    final token = Object();
    controller.block(token);
    controller.pointerUp(1);
    expect(controller.debugTimerActive, isFalse);
    controller.unblock(token);
    expect(controller.debugTimerActive, isTrue);
    controller.hide();
    expect(controller.visible, isFalse);
    expect(controller.debugTimerActive, isFalse);
    controller.dispose();
  });
}
