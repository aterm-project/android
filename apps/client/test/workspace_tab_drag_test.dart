import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

void main() {
  test(
    'layout reparenting keeps each live session exactly once and collapses closed panes',
    () {
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
    },
  );
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
}
