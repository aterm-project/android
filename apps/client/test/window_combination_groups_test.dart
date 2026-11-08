import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/window_combinations.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';

SessionWorkspaceController source() {
  final c = SessionWorkspaceController()..activate('runtime-a');
  c.split('runtime-b', 'runtime-a', SessionSplitEdge.right);
  c.resize(c.root as SessionWorkspaceSplit, .31);
  c.split('runtime-c', 'runtime-b', SessionSplitEdge.bottom);
  c.resize(
    (c.root as SessionWorkspaceSplit).second as SessionWorkspaceSplit,
    .63,
  );
  c.activate('runtime-d');
  c.split('runtime-e', 'runtime-d', SessionSplitEdge.bottom);
  c.resize(c.root as SessionWorkspaceSplit, .72);
  c.activate('runtime-solo');
  return c;
}

WindowCombination capture(SessionWorkspaceController c) =>
    captureWindowCombination(
      id: 'layout',
      name: 'All groups',
      sessionIds: [
        'runtime-a',
        'runtime-b',
        'runtime-c',
        'runtime-d',
        'runtime-e',
        'runtime-solo',
      ],
      workspace: c,
      describe: (id) => CombinationPane(
        kind: 'ssh',
        hostId: id.replaceFirst('runtime', 'host'),
      ),
    );
void main() {
  test('v3 preserves every retained nested tree ratio and each active member without runtime IDs', () {
    final c = source(), snapshot = c.retainedGroupSnapshots;
    expect(snapshot, hasLength(2));
    expect(snapshot.map((g) => g.selectedId), ['runtime-c', 'runtime-e']);
    // Consumers cannot mutate the controller through snapshots.
    (snapshot.first.root as SessionWorkspaceSplit).ratio = .5;
    expect(
      (c.retainedGroupSnapshots.first.root as SessionWorkspaceSplit).ratio,
      .31,
    );
    final recipe = capture(c);
    expect(recipe.schemaVersion, 3);
    final encoded = WindowCombination.encode([recipe]);
    expect(encoded, isNot(contains('runtime')));
    final reopened = WindowCombination.decode(encoded).single;
    expect(reopened.groups, hasLength(2));
    final target = SessionWorkspaceController();
    applyWindowCombination(reopened, target, {
      for (var i = 0; i < 6; i++) i: 'new-$i',
    });
    expect(target.selectedId, 'new-5');
    expect(target.groupedSessionIds, [
      ['new-0', 'new-1', 'new-2'],
      ['new-3', 'new-4'],
    ]);
    expect(target.retainedGroupSelections, {
      'new-0': 'new-2',
      'new-3': 'new-4',
    });
    final groups = target.retainedGroupSnapshots;
    expect((groups[0].root as SessionWorkspaceSplit).ratio, .31);
    expect(
      ((groups[0].root as SessionWorkspaceSplit).second
              as SessionWorkspaceSplit)
          .ratio,
      .63,
    );
    expect((groups[1].root as SessionWorkspaceSplit).ratio, .72);
  });
  test(
    'partial failures collapse groups and preserve unrelated live groups',
    () {
      final recipe = capture(source());
      final target = SessionWorkspaceController()..activate('old-a');
      target.split('old-b', 'old-a', SessionSplitEdge.right);
      applyWindowCombination(recipe, target, {
        0: 'a',
        2: 'c',
        4: 'e',
        5: 'solo',
      });
      expect(target.groupFor('old-a'), ['old-a', 'old-b']);
      expect(target.groupFor('a'), ['a', 'c']);
      expect(target.groupFor('e'), isNull);
      expect(target.selectedId, 'solo');
      expect(target.retainedGroupSelections['a'], 'c');
    },
  );
  test('v1 v2 remain readable and v3 rejects overlapping groups/invalid independent associations', () {
    final pane = CombinationPane(kind: 'ssh', hostId: 'host');
    final v1 = WindowCombination(
      id: 'one',
      name: 'one',
      panes: [pane],
      tree: {'pane': 0},
      activePane: 0,
    );
    expect(v1.toJson()['version'], 1);
    final v2 = WindowCombination(
      id: 'two',
      name: 'two',
      panes: [pane],
      tree: {'pane': 0},
      activePane: 0,
      mainPlacement: SavedWindowPlacement(x: 0, y: 0, width: 800, height: 600),
    );
    expect(v2.toJson()['version'], 2);
    expect(
      WindowCombination.decode(WindowCombination.encode([v1, v2]))
          .map((v) => v.schemaVersion),
      [1, 2],
    );
    final recipe = capture(source());
    expect(
      () => WindowCombination(
        id: recipe.id,
        name: recipe.name,
        panes: recipe.panes,
        tree: recipe.tree,
        activePane: recipe.activePane,
        groups: [recipe.groups.first, recipe.groups.first],
      ),
      throwsFormatException,
    );
    expect(
      () => WindowCombination(
        id: 'invalid',
        name: 'invalid',
        panes: [pane],
        tree: {'pane': 0},
        activePane: 0,
        windows: [CombinationWindow(pane: 0, independentFile: true)],
      ),
      throwsFormatException,
    );
    final malformed = recipe.toJson();
    malformed['groups'] = [
      {
        'tree': {'pane': 0},
        'active': 0,
        'capability': 'bad',
      },
    ];
    expect(() => WindowCombination.fromJson(malformed), throwsFormatException);
  });
  testWidgets(
    'clicking restored inactive combined tab selects its saved active member',
    (tester) async {
      final c = SessionWorkspaceController();
      applyWindowCombination(capture(source()), c, {
        for (var i = 0; i < 6; i++) i: 'new-$i',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: c,
              builder: (context, _) => WorkspaceTabBar(
                groups: c.groupedSessionIds,
                groupSelections: c.retainedGroupSelections,
                tabs: [
                  const WorkspaceTab(id: 'hosts', title: 'Home', isHome: true),
                  for (var i = 0; i < 6; i++)
                    WorkspaceTab(id: 'new-$i', title: 'Host $i'),
                ],
                selectedId: c.selectedId!,
                onSelect: c.activate,
                onClose: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('workspace-tab-new-0')));
      await tester.pump();
      expect(c.selectedId, 'new-2');
      await tester.tap(find.byKey(const ValueKey('workspace-tab-new-3')));
      await tester.pump();
      expect(c.selectedId, 'new-4');
    },
  );
}
