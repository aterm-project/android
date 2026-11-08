import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/ui/session_workspace.dart';

void main() {
  for (final width in [640.0, 220.0]) {
    testWidgets(
      'clone the requested pane and retain its split group at $width',
      (tester) async {
        final workspace = SessionWorkspaceController()..activate('a');
        workspace.split('b', 'a', SessionSplitEdge.right);
        workspace.resize(workspace.root as SessionWorkspaceSplit, .37);
        final cloned = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  height: 250,
                  child: SessionWorkspaceView(
                    controller: workspace,
                    terminalBuilder: (_, id) => Text('session-$id'),
                    onUnsplit: workspace.unsplit,
                    onClose: workspace.remove,
                    onDuplicate: (id) {
                      cloned.add(id);
                      workspace.activate('copy-$id');
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        // B was selected. The control belonging to A must duplicate A, not B.
        expect(workspace.selectedId, 'b');
        await tester.tap(find.byKey(const ValueKey('pane-handle-a')));
        await tester.pumpAndSettle();
        if (width < 300) {
          await tester.tap(find.byKey(const ValueKey('pane-actions-a')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Duplicate tab'));
        } else {
          await tester.tap(find.byKey(const ValueKey('pane-duplicate-a')));
        }
        await tester.pumpAndSettle();
        expect(cloned, ['a']);
        expect(workspace.selectedId, 'copy-a');
        expect(workspace.groupFor('a'), ['a', 'b']);
        workspace.activate('b');
        await tester.pumpAndSettle();
        expect((workspace.root as SessionWorkspaceSplit).ratio, .37);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('switching independent tabs retains group topology and ratio', () {
    final c = SessionWorkspaceController()..activate('a');
    c.split('b', 'a', SessionSplitEdge.right);
    c.resize(c.root as SessionWorkspaceSplit, .37);
    c.activate('independent');
    expect(c.groupedSessionIds, [
      ['a', 'b'],
    ]);
    expect(c.sessionIds, ['independent']);
    c.activate('b');
    expect(c.sessionIds, ['a', 'b']);
    expect((c.root as SessionWorkspaceSplit).ratio, .37);
    c.unsplit('b');
    expect(c.sessionIds, ['a']);
    expect(c.selectedId, 'a');
    expect(c.groupedSessionIds, isEmpty);
    c.activate('b');
    expect(c.sessionIds, ['b']);
  });
  test('moving members and restoring overlap produce no duplicated group membership', () {
    final c = SessionWorkspaceController()..activate('a');
    c.split('b', 'a', SessionSplitEdge.right);
    c.split('c', 'b', SessionSplitEdge.bottom);
    c.activate('d');
    c.split('e', 'd', SessionSplitEdge.right);
    c.split('b', 'd', SessionSplitEdge.top);
    expect(c.groupFor('a'), ['a', 'c']);
    expect(c.groupFor('b'), ['b', 'd', 'e']);
    c.restore(
      SessionWorkspaceSplit(
        axis: Axis.vertical,
        first: const SessionWorkspacePane('a'),
        second: const SessionWorkspacePane('e'),
      ),
    );
    final all = c.groupedSessionIds.expand((ids) => ids).toList();
    expect(all.toSet().length, all.length);
    expect(c.groupFor('b'), ['b', 'd']);
    expect(c.groupFor('a'), ['a', 'e']);
    c.remove('a');
    expect(c.sessionIds, ['e']);
    expect(c.selectedId, 'e');
    c.restore(null);
    expect(c.groupedSessionIds, isEmpty);
  });
  for (final axis in Axis.values) {
    testWidgets(
      'dark rounded ${axis.name} divider uses theme accent and keeps resize/state',
      (tester) async {
        const grass = Color(0xffa7ce71);
        final c = SessionWorkspaceController()..activate('a');
        c.split(
          'b',
          'a',
          axis == Axis.horizontal
              ? SessionSplitEdge.right
              : SessionSplitEdge.bottom,
        );
        final created = <String, int>{};
        final disposed = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: grass,
                brightness: Brightness.dark,
              ).copyWith(primary: grass),
            ),
            home: Scaffold(
              body: SessionWorkspaceView(
                controller: c,
                onUnsplit: c.unsplit,
                onClose: c.remove,
                terminalBuilder: (_, id) =>
                    _Probe(id: id, created: created, disposed: disposed),
              ),
            ),
          ),
        );
        final divider = find.byKey(const ValueKey('session-divider'));
        final rect = tester.getRect(divider);
        expect(axis == Axis.horizontal ? rect.width : rect.height, 6);
        final track = tester.widget<AnimatedContainer>(
          find
              .descendant(of: divider, matching: find.byType(AnimatedContainer))
              .first,
        );
        final trackColor = (track.decoration! as BoxDecoration).color!;
        expect(trackColor.computeLuminance(), lessThan(.15));
        expect(trackColor, isNot(Colors.white));
        final grip = find.byKey(const ValueKey('session-divider-grip'));
        BoxDecoration decoration() =>
            tester.widget<AnimatedContainer>(grip).decoration! as BoxDecoration;
        expect(decoration().color, grass.withValues(alpha: .3));
        expect(decoration().borderRadius, BorderRadius.circular(2));
        expect(find.byKey(const ValueKey('pane-handle-a')), findsOneWidget);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(10, 100));
        await mouse.moveTo(rect.center);
        await tester.pumpAndSettle();
        expect(decoration().color, grass.withValues(alpha: .8));
        await mouse.down(rect.center);
        await mouse.moveBy(
          axis == Axis.horizontal ? const Offset(55, 0) : const Offset(0, 55),
        );
        await tester.pump();
        await mouse.up();
        await tester.pumpAndSettle();
        expect((c.root as SessionWorkspaceSplit).ratio, greaterThan(.5));
        expect(created, {'a': 1, 'b': 1});
        expect(disposed, isEmpty);
        await mouse.moveTo(const Offset(10, 100));
        await tester.pumpAndSettle();
        expect(decoration().color, grass.withValues(alpha: .3));
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'hover actions unsplit without closing and preserve surviving element state',
    (tester) async {
      final c = SessionWorkspaceController()..activate('a');
      final closed = <String>[];
      final created = <String, int>{};
      final disposed = <String>[];
      Widget view() => MaterialApp(
        home: Scaffold(
          body: SessionWorkspaceView(
            controller: c,
            paneLabel: (id) => 'Pane $id',
            terminalBuilder: (_, id) =>
                _Probe(id: id, created: created, disposed: disposed),
            onUnsplit: c.unsplit,
            onClose: (id) {
              closed.add(id);
              c.remove(id);
            },
          ),
        ),
      );
      await tester.pumpWidget(view());
      c.split('b', 'a', SessionSplitEdge.right);
      await tester.pump();
      expect(created['a'], 1);
      expect(created['b'], 1);
      expect(find.byKey(const ValueKey('pane-unsplit-a')), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 100));
      await mouse.moveTo(const Offset(10, 10));
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-close-a')), findsNothing);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('pane-handle-a'))),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-unsplit-a')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pane-unsplit-a')));
      await tester.pump();
      expect(closed, isEmpty);
      expect(c.sessionIds, ['b']);
      expect(created['b'], 1);
      expect(disposed, contains('a'));
      expect(disposed, isNot(contains('b')));
      await mouse.removePointer();
    },
  );
  testWidgets(
    'close affects one pane, and hover controls hide away from handle',
    (tester) async {
      final c = SessionWorkspaceController()..activate('a');
      c.split('b', 'a', SessionSplitEdge.right);
      final closed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionWorkspaceView(
              controller: c,
              terminalBuilder: (_, id) => Text(id),
              onUnsplit: c.unsplit,
              onClose: (id) {
                closed.add(id);
                c.remove(id);
              },
            ),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 100));
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('pane-handle-a'))),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-close-a')), findsOneWidget);
      await mouse.moveTo(const Offset(10, 100));
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-close-a')), findsNothing);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('pane-handle-a'))),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pane-close-a')));
      await tester.pump();
      expect(closed, ['a']);
      expect(c.sessionIds, ['b']);
      expect(c.selectedId, 'b');
      await mouse.removePointer();
    },
  );
  testWidgets(
    'centered white handles toggle on touch without intercepting other top taps',
    (tester) async {
      final c = SessionWorkspaceController()..activate('a');
      c.split('b', 'a', SessionSplitEdge.right);
      var terminalTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionWorkspaceView(
              controller: c,
              terminalBuilder: (_, id) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => terminalTaps++,
                child: Text(id),
              ),
              onUnsplit: c.unsplit,
              onClose: c.remove,
            ),
          ),
        ),
      );
      final handle = find.byKey(const ValueKey('pane-handle-a'));
      expect(handle, findsOneWidget);
      final pane = tester.getRect(find.byKey(const ValueKey('session-pane-a')));
      expect(tester.getCenter(handle).dx, closeTo(pane.center.dx, 1));
      expect(tester.getRect(handle).top, closeTo(pane.top, 1));
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(terminalTaps, 1);
      expect(find.byKey(const ValueKey('pane-close-a')), findsNothing);
      await tester.tap(handle);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-close-a')), findsOneWidget);
      expect(terminalTaps, 1);
      await tester.tap(handle);
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-close-a')), findsNothing);
      expect(terminalTaps, 1);
      await tester.tap(handle);
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(terminalTaps, 2);
      expect(find.byKey(const ValueKey('pane-close-a')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('handle tap preserves the focused terminal subtree', (
    tester,
  ) async {
    final c = SessionWorkspaceController()..activate('a');
    c.split('b', 'a', SessionSplitEdge.right);
    final terminalFocus = FocusNode();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionWorkspaceView(
            controller: c,
            terminalBuilder: (_, id) => Focus(
              focusNode: id == 'a' ? terminalFocus : null,
              child: Text(id),
            ),
            onUnsplit: c.unsplit,
            onClose: c.remove,
          ),
        ),
      ),
    );
    terminalFocus.requestFocus();
    await tester.pump();
    expect(terminalFocus.hasPrimaryFocus, true);
    await tester.tap(find.byKey(const ValueKey('pane-handle-a')));
    await tester.pump();
    expect(terminalFocus.hasPrimaryFocus, true);
    expect(find.byKey(const ValueKey('pane-close-a')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    terminalFocus.dispose();
  });
  testWidgets('drag targets keep scope filtering and split edge behavior', (
    tester,
  ) async {
    final c = SessionWorkspaceController()..activate('a');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Draggable<WorkspaceTabDragData>(
                data: WorkspaceTabDragData(tabId: 'b', scope: 'safe'),
                feedback: Text('drag'),
                child: SizedBox(height: 40, child: Text('source')),
              ),
              Expanded(
                child: SessionWorkspaceView(
                  controller: c,
                  dragScope: 'safe',
                  acceptsSession: (id) => {'a', 'b'}.contains(id),
                  terminalBuilder: (_, id) => Center(child: Text('pane-$id')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.dragFrom(
      tester.getCenter(find.text('source')),
      const Offset(100, 200),
    );
    await tester.pumpAndSettle();
    expect(c.sessionIds.toSet(), {'a', 'b'});
    expect(c.groupFor('b'), isNotNull);
  });
  testWidgets(
    'keyboard and touch reveal actions and narrow panes use menu without overflow',
    (tester) async {
      final c = SessionWorkspaceController()..activate('a');
      c.split('b', 'a', SessionSplitEdge.right);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 140,
                height: 180,
                child: SessionWorkspaceView(
                  controller: c,
                  terminalBuilder: (_, id) => Text(id),
                  onUnsplit: c.unsplit,
                  onClose: c.remove,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('pane-handle-a')));
      await tester.pump();
      expect(find.byKey(const ValueKey('pane-actions-a')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pane-actions-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unsplit'));
      await tester.pumpAndSettle();
      expect(c.sessionIds, ['b']);
      expect(tester.takeException(), isNull);
      c.split('a', 'b', SessionSplitEdge.left);
      await tester.pump();
      // Tab gives a pane keyboard focus without intercepting terminal input.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byType(PopupMenuButton<String>), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(find.byType(PopupMenuButton<String>), findsWidgets);
    },
  );
}

class _Probe extends StatefulWidget {
  const _Probe({
    required this.id,
    required this.created,
    required this.disposed,
  });
  final String id;
  final Map<String, int> created;
  final List<String> disposed;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.disposed.add(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.id);
}
