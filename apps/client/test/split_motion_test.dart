import 'package:aterm_client/ui/app_motion.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Live extends StatefulWidget {
  const _Live({required this.id, required this.attaches});
  final String id;
  final Map<String, int> attaches;
  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  @override
  void initState() {
    super.initState();
    widget.attaches.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => Text('live ${widget.id}');
}

void main() {
  Widget view(
    SessionWorkspaceController c,
    Map<String, int> attaches, {
    bool reduced = false,
  }) => MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(
      body: SessionWorkspaceView(
        controller: c,
        terminalBuilder: (_, id) => _Live(id: id, attaches: attaches),
        onUnsplit: c.unsplit,
        onClose: c.remove,
      ),
    ),
  );

  double controlsOpacity(WidgetTester tester, String id) => tester
      .widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(ValueKey('pane-close-$id')),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  for (final reduced in [false, true]) {
    testWidgets('pane controls ease in, are tappable at once, live panes keep '
        'their State (reduced=$reduced)', (tester) async {
      final c = SessionWorkspaceController()..activate('a');
      c.split('b', 'a', SessionSplitEdge.right);
      final attaches = <String, int>{};
      await tester.pumpWidget(view(c, attaches, reduced: reduced));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 100));
      // R4: controls are revealed from the pane's small centred handle.
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('pane-handle-a'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        controlsOpacity(tester, 'a'),
        reduced ? 1 : inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester, 'a'), 1);
      // Selecting the other pane eases the border; no pane is recreated.
      c.activate('b');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(attaches, {'a': 1, 'b': 1});
      await tester.tap(find.byKey(const ValueKey('pane-close-a')));
      await tester.pump();
      expect(c.sessionIds, ['b']);
      expect(attaches['b'], 1);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      await mouse.removePointer();
    });
  }

  testWidgets('split drop preview fades in and glides between edges', (
    tester,
  ) async {
    final c = SessionWorkspaceController()..activate('a');
    final attaches = <String, int>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Draggable<WorkspaceTabDragData>(
                data: WorkspaceTabDragData(tabId: 'b', scope: 'workspace'),
                feedback: SizedBox(width: 10, height: 10),
                child: SizedBox(width: 80, height: 40, child: Text('drag b')),
              ),
              Expanded(
                child: SessionWorkspaceView(
                  controller: c,
                  terminalBuilder: (_, id) => _Live(id: id, attaches: attaches),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final pane = tester.getRect(find.text('live a'));
    final drag = await tester.startGesture(
      tester.getCenter(find.text('drag b')),
    );
    await drag.moveTo(pane.centerLeft + const Offset(20, 0));
    await tester.pump();
    await drag.moveTo(pane.centerLeft + const Offset(24, 0));
    await tester.pump();
    final preview = find.ancestor(
      of: find.text('Drop to split'),
      matching: find.byType(MotionEntrance),
    );
    expect(preview, findsOneWidget);
    await tester.pumpAndSettle();
    await drag.moveTo(pane.centerRight - const Offset(24, 0));
    await tester.pump(const Duration(milliseconds: 40));
    final mid = tester.getRect(find.text('Drop to split')).center.dx;
    await tester.pumpAndSettle();
    final end = tester.getRect(find.text('Drop to split')).center.dx;
    expect(mid, lessThan(end)); // glides, not jumps
    await drag.up();
    await tester.pumpAndSettle();
    expect(c.sessionIds.toSet(), {'a', 'b'});
    expect(attaches['a'], 1);
    expect(find.text('Drop to split'), findsNothing);
  });
}
