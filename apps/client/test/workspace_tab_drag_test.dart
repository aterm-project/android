import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _tabs = [
  WorkspaceTab(id: 'home', title: 'Hosts', isHome: true),
  WorkspaceTab(id: 'a', title: 'alpha', isConnected: true),
  WorkspaceTab(id: 'b', title: 'beta'),
];
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(12, 0));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

final _android = ThemeData(platform: TargetPlatform.android);

/// A real finger drag: leaves touch slop well before the long-press timeout.
Future<void> _touchDrag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  Offset lift = const Offset(0, 30),
  bool lifted = true,
}) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.touch,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveBy(lift);
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  expect(_dragInFlight, lifted ? findsOneWidget : findsNothing);
  await gesture.up();
  await tester.pumpAndSettle();
}

/// The lifted tab's placeholder, present only while a tab drag is in flight.
final _dragInFlight = find.byWidgetPredicate(
  (widget) => widget is Opacity && widget.opacity == .35,
);

/// A stationary finger held past the long-press timeout, then lifted.
Future<void> _touchLongPress(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at, kind: PointerDeviceKind.touch);
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.up();
  await tester.pumpAndSettle();
}

List<String> _menuLabels(WidgetTester tester) => [
  for (final item in tester.widgetList<PopupMenuEntry<Object?>>(
    find.byWidgetPredicate((widget) => widget is PopupMenuItem),
  ))
    for (final text in tester.widgetList<Text>(
      find.descendant(of: find.byWidget(item), matching: find.byType(Text)),
    ))
      text.data ?? '',
];

Future<void> _dismissMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(2, 590));
  await tester.pumpAndSettle();
}

Future<SessionWorkspaceController> _mobileWorkspace(WidgetTester tester) async {
  final layout = SessionWorkspaceController()..activate('b');
  addTearDown(layout.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: _android,
      home: Scaffold(
        body: Column(
          children: [
            WorkspaceTabBar(
              tabs: _tabs,
              selectedId: 'b',
              onSelect: (_) {},
              onClose: (_) {},
              onReorder: (_, _) {},
            ),
            Expanded(
              child: SessionWorkspaceView(
                controller: layout,
                terminalBuilder: (_, id) =>
                    ColoredBox(color: Colors.black, child: Text('live:$id')),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return layout;
}

void main() {
  for (final grouped in [false, true]) {
    testWidgets(
      'Android long-press disconnect keeps close separate (grouped=$grouped)',
      (tester) async {
        final disconnected = <String>[], closed = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: _android,
            home: Scaffold(
              body: WorkspaceTabBar(
                tabs: const [
                  WorkspaceTab(
                    id: 'a',
                    title: 'alpha',
                    isConnected: true,
                    canDisconnect: true,
                  ),
                  WorkspaceTab(
                    id: 'b',
                    title: 'beta',
                    isConnected: true,
                    canDisconnect: true,
                  ),
                ],
                groups: grouped
                    ? const [
                        ['a', 'b'],
                      ]
                    : const [],
                selectedId: grouped ? 'b' : 'a',
                onSelect: (_) {},
                onClose: closed.add,
                onDisconnect: disconnected.add,
              ),
            ),
          ),
        );
        await _touchLongPress(
          tester,
          tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        );
        expect(find.text('Disconnect'), findsOneWidget);
        await tester.tap(find.text('Disconnect'));
        await tester.pumpAndSettle();
        expect(disconnected, [grouped ? 'b' : 'a']);
        expect(closed, isEmpty);
      },
    );
  }
  testWidgets(
    'Android grouped tab drags its selected member to change split axis at 390px',
    (tester) async {
      tester.view.physicalSize = const Size(390, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final layout = SessionWorkspaceController()
        ..activate('b')
        ..split('a', 'b', SessionSplitEdge.right);
      addTearDown(layout.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: ListenableBuilder(
              listenable: layout,
              builder: (context, _) => Column(
                children: [
                  WorkspaceTabBar(
                    tabs: _tabs,
                    selectedId: layout.selectedId!,
                    groups: layout.groupedSessionIds,
                    groupSelections: layout.retainedGroupSelections,
                    onSelect: (_) {},
                    onClose: (_) {},
                  ),
                  Expanded(
                    child: SessionWorkspaceView(
                      controller: layout,
                      terminalBuilder: (_, id) => ColoredBox(
                        color: Colors.black,
                        child: Text('live:$id'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final target = tester.getRect(find.text('live:b'));
      await _touchDrag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-b'))),
        Offset(target.center.dx, target.top + 10),
      );
      expect((layout.root! as SessionWorkspaceSplit).axis, Axis.vertical);
      expect(layout.sessionIds, ['a', 'b']);
      expect(tester.takeException(), isNull);
    },
  );
  test('layout reparenting keeps each live session exactly once and collapses closed panes', () {
    final layout = SessionWorkspaceController()..activate('a');
    layout.split('b', 'a', SessionSplitEdge.right);
    layout.split('c', 'b', SessionSplitEdge.bottom);
    expect(layout.sessionIds, ['a', 'b', 'c']);
    layout.split('a', 'c', SessionSplitEdge.top);
    expect(layout.sessionIds.toSet(), {'a', 'b', 'c'});
    expect(layout.sessionIds, hasLength(3));
    layout.remove('c');
    layout.remove('b');
    expect(layout.root, isA<SessionWorkspacePane>());
    expect(layout.sessionIds, ['a']);
    layout.dispose();
  });
  testWidgets('mouse drag reorders SSH tabs while Home stays pinned', (
    tester,
  ) async {
    String? dragged, before;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: WorkspaceTabBar(
            tabs: _tabs,
            selectedId: 'a',
            onSelect: (_) {},
            onClose: (_) {},
            onReorder: (id, target) {
              dragged = id;
              before = target;
            },
          ),
        ),
      ),
    );
    await _drag(
      tester,
      tester.getCenter(find.byKey(const ValueKey('workspace-tab-b'))),
      tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
    );
    expect(dragged, 'b');
    expect(before, 'a');
    final home = find.byKey(const ValueKey('workspace-tab-home'));
    expect(
      find.ancestor(
        of: home,
        matching: find.byType(Draggable<WorkspaceTabDragData>),
      ),
      findsNothing,
    );
  });
  testWidgets(
    'right-click exposes properties, split actions and closes only other SSH tabs',
    (tester) async {
      final closed = <String>[];
      String? properties;
      Widget app() => MaterialApp(
        home: Scaffold(
          body: WorkspaceTabBar(
            tabs: _tabs,
            selectedId: 'a',
            onSelect: (_) {},
            onClose: closed.add,
            onProperties: (id) => properties = id,
            onSplit: (_, _) {},
          ),
        ),
      );
      await tester.pumpWidget(app());
      Future<void> menu() async {
        await tester.tap(
          find.text('alpha'),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
      }

      await menu();
      expect(find.text('Split left/right'), findsOneWidget);
      expect(find.text('Split top/bottom'), findsOneWidget);
      await tester.tap(find.text('Properties'));
      await tester.pumpAndSettle();
      expect(properties, 'a');
      await menu();
      await tester.tap(find.text('Close other tabs'));
      await tester.pumpAndSettle();
      expect(closed, ['b']);
    },
  );
  testWidgets(
    'dropping a tab on the terminal edge creates real side-by-side panes',
    (tester) async {
      final layout = SessionWorkspaceController()..activate('b');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Column(
              children: [
                WorkspaceTabBar(
                  tabs: _tabs,
                  selectedId: 'b',
                  onSelect: (_) {},
                  onClose: (_) {},
                  onReorder: (_, _) {},
                ),
                Expanded(
                  child: SessionWorkspaceView(
                    controller: layout,
                    terminalBuilder: (context, id) => ColoredBox(
                      color: Colors.black,
                      child: Center(child: Text('terminal:$id')),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
      await _drag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        Offset(pane.left + 20, pane.center.dy),
      );
      expect(layout.root, isA<SessionWorkspaceSplit>());
      expect((layout.root as SessionWorkspaceSplit).axis, Axis.horizontal);
      expect(layout.sessionIds, ['a', 'b']);
      expect(find.text('terminal:a'), findsOneWidget);
      expect(find.text('terminal:b'), findsOneWidget);
      final divider = find.byWidgetPredicate(
        (widget) =>
            widget is MouseRegion &&
            widget.cursor == SystemMouseCursors.resizeColumn,
      );
      await tester.drag(divider, const Offset(100, 0));
      await tester.pumpAndSettle();
      expect((layout.root as SessionWorkspaceSplit).ratio, greaterThan(.55));
      layout.dispose();
    },
  );
  testWidgets(
    'dragging outside the application requests a live window detach',
    (tester) async {
      String? detached;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: WorkspaceTabBar(
                tabs: _tabs,
                selectedId: 'a',
                onSelect: (_) {},
                onClose: (_) {},
                supportsNewWindow: true,
                onDetach: (id) => detached = id,
              ),
            ),
          ),
        ),
      );
      await _drag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        const Offset(300, -80),
      );
      expect(detached, 'a');
    },
  );
  testWidgets(
    'session closed during a drag cannot become an orphan split pane',
    (tester) async {
      var sourceAlive = true;
      final layout = SessionWorkspaceController()..activate('b');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: Column(
              children: [
                WorkspaceTabBar(
                  tabs: _tabs,
                  selectedId: 'b',
                  onSelect: (_) {},
                  onClose: (_) {},
                  onReorder: (_, _) {},
                ),
                Expanded(
                  child: SessionWorkspaceView(
                    controller: layout,
                    acceptsSession: (id) => id == 'b' || sourceAlive,
                    terminalBuilder: (context, id) => Text('terminal:$id'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump();
      await gesture.moveTo(Offset(pane.left + 20, pane.center.dy));
      await tester.pump();
      sourceAlive = false;
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layout.sessionIds, ['b']);
      expect(layout.root, isA<SessionWorkspacePane>());
      layout.dispose();
    },
  );
  testWidgets(
    'right-click menu remains anchored when a window caption offsets the Navigator',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => Column(
            children: [
              const SizedBox(height: 34),
              Expanded(child: child!),
            ],
          ),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: WorkspaceTabBar(
                tabs: _tabs,
                selectedId: 'a',
                onSelect: (_) {},
                onClose: (_) {},
              ),
            ),
          ),
        ),
      );
      final position = tester.getCenter(find.text('alpha'));
      await tester.tapAt(
        position,
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final firstItem = find.ancestor(
        of: find.text('Close tab'),
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      );
      // showMenu contributes its normal 8px list padding, not a second caption.
      expect(tester.getTopLeft(firstItem).dy - position.dy, closeTo(8, 1));
    },
  );

  group('Android touch', () {
    testWidgets(
      'stationary long-press opens the same tab menu as right-click, with haptics',
      (tester) async {
        final haptics = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method.startsWith('HapticFeedback')) haptics.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final selected = <String>[];
        String? properties, dragged;
        await tester.pumpWidget(
          MaterialApp(
            theme: _android,
            home: Scaffold(
              body: WorkspaceTabBar(
                tabs: _tabs,
                selectedId: 'b',
                onSelect: selected.add,
                onClose: (_) {},
                onProperties: (id) => properties = id,
                onDuplicate: (_) {},
                onSplit: (_, _) {},
                onReorder: (id, _) => dragged = id,
              ),
            ),
          ),
        );
        await tester.tap(
          find.text('alpha'),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final rightClick = _menuLabels(tester);
        expect(rightClick, contains('Split left/right'));
        await _dismissMenu(tester);
        selected.clear();

        await _touchLongPress(tester, tester.getCenter(find.text('alpha')));
        expect(_menuLabels(tester), rightClick);
        expect(haptics, isNotEmpty);
        // The menu targets the pressed tab exactly like right-click does.
        expect(selected, ['a']);
        expect(dragged, isNull);
        await tester.tap(find.text('Properties'));
        await tester.pumpAndSettle();
        expect(properties, 'a');
      },
    );

    testWidgets('screen-reader long-press reaches the same tab menu', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      String? properties;
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: WorkspaceTabBar(
              tabs: _tabs,
              selectedId: 'b',
              onSelect: (_) {},
              onClose: (_) {},
              onProperties: (id) => properties = id,
            ),
          ),
        ),
      );
      tester.semantics.longPress(
        find.semantics.byLabel(RegExp(r'^alpha terminal tab')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Close tab'), findsOneWidget);
      await tester.tap(find.text('Properties'));
      await tester.pumpAndSettle();
      expect(properties, 'a');
      handle.dispose();
    });

    testWidgets('long-press on a split group opens the split-group menu', (
      tester,
    ) async {
      String? unsplit;
      final closed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: WorkspaceTabBar(
              tabs: _tabs,
              groups: const [
                ['a', 'b'],
              ],
              selectedId: 'b',
              onSelect: (_) {},
              onClose: closed.add,
              onUnsplit: (id) => unsplit = id,
              onReorder: (_, _) {},
            ),
          ),
        ),
      );
      final group = find.byKey(const ValueKey('workspace-group-a'));
      expect(group, findsOneWidget);
      await tester.tap(
        find.text('alpha +1'),
        buttons: kSecondaryMouseButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final rightClick = _menuLabels(tester);
      expect(rightClick, contains('Close this split group'));
      await _dismissMenu(tester);

      await _touchLongPress(tester, tester.getCenter(find.text('alpha +1')));
      expect(_menuLabels(tester), rightClick);
      await tester.tap(find.text('Unsplit current pane'));
      await tester.pumpAndSettle();
      expect(unsplit, 'b');
      await _touchLongPress(tester, tester.getCenter(find.text('alpha +1')));
      await tester.tap(find.text('Close this split group'));
      await tester.pumpAndSettle();
      expect(closed, ['a', 'b']);
    });

    testWidgets(
      'tap selects, close button closes and Home stays pinned without a menu',
      (tester) async {
        final selected = <String>[], closed = <String>[];
        String? dragged;
        await tester.pumpWidget(
          MaterialApp(
            theme: _android,
            home: Scaffold(
              body: WorkspaceTabBar(
                tabs: _tabs,
                selectedId: 'a',
                onSelect: selected.add,
                onClose: closed.add,
                onReorder: (id, _) => dragged = id,
              ),
            ),
          ),
        );
        await tester.tap(find.text('beta'));
        await tester.pumpAndSettle();
        expect(selected, ['b']);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('workspace-tab-b')),
            matching: find.byIcon(Icons.close),
          ),
        );
        await tester.pumpAndSettle();
        expect(closed, ['b']);
        expect(
          find.byWidgetPredicate((widget) => widget is PopupMenuItem),
          findsNothing,
        );

        final home = find.byKey(const ValueKey('workspace-tab-home'));
        expect(
          find.ancestor(
            of: home,
            matching: find.byWidgetPredicate((widget) => widget is Draggable),
          ),
          findsNothing,
        );
        await _touchLongPress(tester, tester.getCenter(home));
        expect(
          find.byWidgetPredicate((widget) => widget is PopupMenuItem),
          findsNothing,
        );
        // A finger dragged from Home moves nothing.
        await _touchDrag(
          tester,
          tester.getCenter(home),
          tester.getCenter(find.text('beta')),
          lift: const Offset(30, 0),
          lifted: false,
        );
        expect(dragged, isNull);
        await tester.tap(home);
        await tester.pumpAndSettle();
        expect(selected.last, 'home');
      },
    );

    testWidgets('finger drag reorders immediately, without a long-press', (
      tester,
    ) async {
      final moves = <(String, String?)>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: WorkspaceTabBar(
              tabs: _tabs,
              selectedId: 'a',
              onSelect: (_) {},
              onClose: (_) {},
              onReorder: (id, before) => moves.add((id, before)),
            ),
          ),
        ),
      );
      await _touchDrag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-b'))),
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        lift: const Offset(-30, 0),
      );
      expect(moves, [('b', 'a')]);
      // Dropping on the empty strip after the last tab appends.
      final strip = tester.getRect(
        find.byKey(const ValueKey('workspace_navigation_bar')),
      );
      final b = tester.getRect(find.byKey(const ValueKey('workspace-tab-b')));
      await _touchDrag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        Offset(b.right + 40, strip.center.dy),
        lift: const Offset(30, 0),
      );
      expect(moves.last, ('a', null));
      expect(
        find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        findsNothing,
      );
    });

    for (final (edge, axis, sourceFirst) in [
      (SessionSplitEdge.left, Axis.horizontal, true),
      (SessionSplitEdge.right, Axis.horizontal, false),
      (SessionSplitEdge.top, Axis.vertical, true),
      (SessionSplitEdge.bottom, Axis.vertical, false),
    ]) {
      testWidgets(
        'finger drag to the ${edge.name} pane edge creates a real split',
        (tester) async {
          final layout = SessionWorkspaceController()..activate('b');
          addTearDown(layout.dispose);
          final selected = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              theme: _android,
              home: Scaffold(
                body: Column(
                  children: [
                    WorkspaceTabBar(
                      tabs: _tabs,
                      selectedId: 'b',
                      onSelect: (_) {},
                      onClose: (_) {},
                      onReorder: (_, _) {},
                    ),
                    Expanded(
                      child: SessionWorkspaceView(
                        controller: layout,
                        onSelect: selected.add,
                        terminalBuilder: (context, id) => ColoredBox(
                          color: Colors.black,
                          child: Center(child: Text('terminal:$id')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          final pane = tester.getRect(
            find.byKey(const ValueKey('session-pane-b')),
          );
          final target = switch (edge) {
            SessionSplitEdge.left => Offset(pane.left + 12, pane.center.dy),
            SessionSplitEdge.right => Offset(pane.right - 12, pane.center.dy),
            SessionSplitEdge.top => Offset(pane.center.dx, pane.top + 12),
            SessionSplitEdge.bottom => Offset(pane.center.dx, pane.bottom - 12),
          };
          await _touchDrag(
            tester,
            tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
            target,
          );
          final root = layout.root;
          expect(root, isA<SessionWorkspaceSplit>());
          root as SessionWorkspaceSplit;
          expect(root.axis, axis);
          expect(
            (sourceFirst ? root.first : root.second),
            isA<SessionWorkspacePane>().having(
              (pane) => pane.sessionId,
              'sessionId',
              'a',
            ),
          );
          // The live session is moved, never duplicated.
          expect(layout.sessionIds.toList()..sort(), ['a', 'b']);
          expect(find.text('terminal:a'), findsOneWidget);
          expect(find.text('terminal:b'), findsOneWidget);
          expect(selected, ['a']);
          expect(
            find.byWidgetPredicate((widget) => widget is PopupMenuItem),
            findsNothing,
          );
        },
      );
    }

    testWidgets(
      'overflowing strip: swipe scrolls, pull-down lifts, edge auto-scrolls',
      (tester) async {
        final moves = <(String, String?)>[];
        final many = [
          const WorkspaceTab(id: 'home', title: 'Hosts', isHome: true),
          for (var i = 0; i < 8; i++) WorkspaceTab(id: 't$i', title: 'tab $i'),
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: _android,
            home: Scaffold(
              body: WorkspaceTabBar(
                tabs: many,
                selectedId: 't0',
                onSelect: (_) {},
                onClose: (_) {},
                onReorder: (id, before) => moves.add((id, before)),
              ),
            ),
          ),
        );
        final position = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byType(WorkspaceTabBar),
                matching: find.byType(Scrollable),
              ),
            )
            .position;
        expect(position.maxScrollExtent, greaterThan(0));

        // A horizontal finger swipe over a tab scrolls the strip.
        final swipe = await tester.startGesture(
          tester.getCenter(find.text('tab 1')),
          kind: PointerDeviceKind.touch,
        );
        for (var i = 0; i < 6; i++) {
          await swipe.moveBy(const Offset(-40, 0));
          await tester.pump();
        }
        expect(_dragInFlight, findsNothing);
        await swipe.up();
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(100));
        expect(moves, isEmpty);

        // Pulled down first, the tab lifts and reorders onto a visible tab.
        position.jumpTo(0);
        await tester.pump();
        await _touchDrag(
          tester,
          tester.getCenter(find.byKey(const ValueKey('workspace-tab-t2'))),
          tester.getCenter(find.byKey(const ValueKey('workspace-tab-t0'))),
        );
        expect(moves, [('t2', 't0')]);

        // Held at the strip's right end, the lifted tab reveals hidden tabs.
        final strip = tester.getRect(
          find.descendant(
            of: find.byType(WorkspaceTabBar),
            matching: find.byType(Scrollable),
          ),
        );
        final carry = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('workspace-tab-t1'))),
          kind: PointerDeviceKind.touch,
        );
        await carry.moveBy(const Offset(0, 30));
        await tester.pump();
        for (var i = 0; i < 40; i++) {
          await carry.moveTo(
            Offset(strip.right - 8 - (i.isEven ? 0 : 1), strip.center.dy),
          );
          await tester.pump();
        }
        expect(position.pixels, greaterThan(200));
        expect(_dragInFlight, findsOneWidget);
        await carry.up();
        await tester.pumpAndSettle();
        expect(moves.length, 2);
        expect(moves.last.$1, 't1');
      },
    );

    testWidgets('a tab closed mid-gesture is never reordered or split', (
      tester,
    ) async {
      var sourceAlive = true;
      final moves = <(String, String?)>[];
      final layout = SessionWorkspaceController()..activate('b');
      addTearDown(layout.dispose);
      late StateSetter setBar;
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: Column(
              children: [
                StatefulBuilder(
                  builder: (context, setState) {
                    setBar = setState;
                    return WorkspaceTabBar(
                      tabs: [
                        for (final tab in _tabs)
                          if (tab.id != 'a' || sourceAlive) tab,
                      ],
                      selectedId: 'b',
                      onSelect: (_) {},
                      onClose: (_) {},
                      onReorder: (id, before) => moves.add((id, before)),
                    );
                  },
                ),
                Expanded(
                  child: SessionWorkspaceView(
                    controller: layout,
                    acceptsSession: (id) => id == 'b' || sourceAlive,
                    terminalBuilder: (context, id) => Text('terminal:$id'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      Future<void> closeDuring(Offset target) async {
        sourceAlive = true;
        setBar(() {});
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
          kind: PointerDeviceKind.touch,
        );
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        await gesture.moveTo(target);
        await tester.pump();
        expect(_dragInFlight, findsOneWidget);
        setBar(() => sourceAlive = false);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
      }

      await closeDuring(
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-b'))),
      );
      expect(moves, isEmpty);
      final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
      await closeDuring(Offset(pane.left + 12, pane.center.dy));
      expect(layout.sessionIds, ['b']);
      expect(layout.root, isA<SessionWorkspacePane>());
    });

    testWidgets('a drag from another scope is rejected by panes and strip', (
      tester,
    ) async {
      final moves = <String>[];
      final layout = SessionWorkspaceController()..activate('b');
      addTearDown(layout.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: Column(
              children: [
                WorkspaceTabBar(
                  tabs: _tabs,
                  selectedId: 'b',
                  dragScope: 'other-window',
                  onSelect: (_) {},
                  onClose: (_) {},
                  onReorder: (id, _) => moves.add(id),
                ),
                Expanded(
                  child: SessionWorkspaceView(
                    controller: layout,
                    terminalBuilder: (context, id) => Text('terminal:$id'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
      await _touchDrag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        Offset(pane.left + 12, pane.center.dy),
      );
      expect(layout.sessionIds, ['b']);
      expect(moves, isEmpty);
    });

    testWidgets('an unaccepted finger drag inside the window never detaches', (
      tester,
    ) async {
      String? detached;
      await tester.pumpWidget(
        MaterialApp(
          theme: _android,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: WorkspaceTabBar(
                tabs: _tabs,
                selectedId: 'a',
                onSelect: (_) {},
                onClose: (_) {},
                supportsNewWindow: true,
                onDetach: (id) => detached = id,
              ),
            ),
          ),
        ),
      );
      await _touchDrag(
        tester,
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        const Offset(790, 590),
      );
      expect(detached, isNull);
    });
  });

  testWidgets('desktop mouse press-and-hold still opens no menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: WorkspaceTabBar(
            tabs: _tabs,
            selectedId: 'a',
            onSelect: (_) {},
            onClose: (_) {},
            onReorder: (_, _) {},
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('alpha')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Draggable && widget is! LongPressDraggable,
      ),
      findsNWidgets(2),
    );
  });
  testWidgets('touch safe centre drop leaves layout and live sessions intact', (
    tester,
  ) async {
    final layout = await _mobileWorkspace(tester);
    final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
    await _touchDrag(
      tester,
      tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
      pane.center,
    );
    expect(layout.root, isA<SessionWorkspacePane>());
    expect(layout.sessionIds, ['b']);
    expect(find.text('live:b'), findsOneWidget);
  });

  testWidgets('touch corner jitter retains highlighted split direction', (
    tester,
  ) async {
    final layout = await _mobileWorkspace(tester);
    final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(
      pane.topLeft + Offset(pane.width * .08, pane.height * .50),
    );
    await tester.pump();
    await gesture.moveTo(
      pane.topLeft + Offset(pane.width * .09, pane.height * .10),
    );
    await tester.pump();
    await gesture.moveTo(
      pane.topLeft + Offset(pane.width * .11, pane.height * .10),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      layout.root,
      isA<SessionWorkspaceSplit>().having(
        (v) => v.axis,
        'axis',
        Axis.horizontal,
      ),
    );
    expect(layout.sessionIds, ['a', 'b']);
  });

  testWidgets(
    'touch diagonal pull lifts overflowing tabs before horizontal scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final layout = await _mobileWorkspace(tester);
      final pane = tester.getRect(find.byKey(const ValueKey('session-pane-b')));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('workspace-tab-a'))),
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(18, 17));
      await tester.pump();
      expect(_dragInFlight, findsOneWidget);
      await gesture.moveTo(Offset(pane.left + 12, pane.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layout.root, isA<SessionWorkspaceSplit>());
      expect(layout.sessionIds, ['a', 'b']);
    },
  );
}
