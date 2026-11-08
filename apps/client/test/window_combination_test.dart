import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/ui/window_combinations.dart';
import 'package:aterm_client/ui/session_workspace.dart';

WindowCombination recipe({List<CombinationPane>? panes}) => WindowCombination(
  id: 'recipe-1',
  name: '运维组合',
  panes:
      panes ??
      [
        CombinationPane(kind: 'ssh', hostId: 'host-1'),
        CombinationPane(kind: 'rdp', hostId: 'host-2'),
      ],
  tree: {
    'axis': 'horizontal',
    'ratio': .37,
    'first': {'pane': 0},
    'second': {'pane': 1},
  },
  activePane: 1,
);
void main() {
  test('strict roundtrip includes mixed protocols, remote directory and serial intent only', () {
    final kinds = ['ssh', 'sftp', 'scp', 'rdp', 'vnc', 'console'];
    final value = recipe(
      panes: [
        for (final kind in kinds)
          CombinationPane(
            kind: kind,
            hostId: kind == 'console' ? null : 'host-$kind',
            remotePath: kind == 'sftp' || kind == 'scp' ? '/srv/logs' : null,
            serialPort: kind == 'console' ? '/dev/ttyUSB0' : null,
            baudRate: kind == 'console' ? 115200 : null,
          ),
      ],
    );
    final encoded = WindowCombination.encode([value]);
    final decoded = WindowCombination.decode(encoded).single;
    expect(decoded.panes.map((p) => p.kind), kinds);
    expect(decoded.panes.last.serialPort, '/dev/ttyUSB0');
    expect(decoded.panes[1].remotePath, '/srv/logs');
    expect(encoded, isNot(contains('password')));
    final preference = VaultPreferenceRecord.windowCombinations(value: encoded);
    expect(VaultPreferenceRecord.fromJson(preference.toJson()).value, encoded);
  });
  test('recipe copies tree and panes and rejects unknown fields, refs, depth and oversized data', () {
    final panes = [CombinationPane(kind: 'ssh', hostId: 'host-1')];
    final tree = <String, Object?>{'pane': 0};
    final saved = WindowCombination(
      id: 'recipe',
      name: 'name',
      panes: panes,
      tree: tree,
      activePane: 0,
    );
    panes.clear();
    tree['pane'] = 99;
    expect(saved.panes, hasLength(1));
    expect(saved.tree['pane'], 0);
    expect(() => saved.tree['pane'] = 99, throwsUnsupportedError);
    expect(
      () =>
          WindowCombination.fromJson({...saved.toJson(), 'password': 'secret'}),
      throwsFormatException,
    );
    expect(
      () => WindowCombination(
        id: 'recipe',
        name: 'x',
        panes: saved.panes,
        tree: {'pane': 1},
        activePane: 0,
      ),
      throwsFormatException,
    );
    expect(
      () =>
          CombinationPane(kind: 'scp', hostId: 'host', remotePath: '../../etc'),
      throwsFormatException,
    );
    expect(
      () => CombinationPane(
        kind: 'console',
        serialPort: 'bad\nport',
        baudRate: 9600,
      ),
      throwsFormatException,
    );
    Map<String, Object?> deep = {'pane': 0};
    for (var i = 0; i < 18; i++) {
      deep = {
        'axis': 'horizontal',
        'ratio': .5,
        'first': deep,
        'second': {'pane': 0},
      };
    }
    expect(
      () => WindowCombination(
        id: 'recipe',
        name: 'x',
        panes: saved.panes,
        tree: deep,
        activePane: 0,
      ),
      throwsFormatException,
    );
  });
  test('capture and restore preserve nested ratios, active pane and independent tabs without runtime IDs', () {
    final source = SessionWorkspaceController();
    source.restore(
      SessionWorkspaceSplit(
        axis: Axis.horizontal,
        ratio: .37,
        first: const SessionWorkspacePane('runtime-a'),
        second: SessionWorkspaceSplit(
          axis: Axis.vertical,
          ratio: .61,
          first: const SessionWorkspacePane('runtime-b'),
          second: const SessionWorkspacePane('runtime-c'),
        ),
      ),
      selectedId: 'runtime-c',
    );
    final value = captureWindowCombination(
      id: 'layout',
      name: 'Layout',
      sessionIds: ['runtime-a', 'runtime-b', 'runtime-c', 'runtime-tab'],
      workspace: source,
      describe: (id) =>
          CombinationPane(kind: 'ssh', hostId: 'host-${id.substring(8)}'),
    );
    final encoded = WindowCombination.encode([value]);
    expect(encoded, isNot(contains('runtime')));
    final target = SessionWorkspaceController();
    applyWindowCombination(WindowCombination.decode(encoded).single, target, {
      0: 'new-a',
      1: 'new-b',
      2: 'new-c',
      3: 'new-tab',
    });
    expect(target.selectedId, 'new-c');
    expect((target.root as SessionWorkspaceSplit).ratio, .37);
    expect(
      ((target.root as SessionWorkspaceSplit).second as SessionWorkspaceSplit)
          .ratio,
      .61,
    );
    expect(value.panes, hasLength(4));
    applyWindowCombination(value, target, {0: 'new-a', 2: 'new-c'});
    expect(target.sessionIds, ['new-a', 'new-c']);
    expect(target.selectedId, 'new-c');
    applyWindowCombination(value, target, {3: 'surviving-tab'});
    expect(target.selectedId, 'surviving-tab');
  });
  test('restore preflights missing hosts with zero connections', () async {
    final coordinator = CombinationRestoreCoordinator();
    var opens = 0;
    await expectLater(
      coordinator.restore(
        recipe: recipe(),
        isCurrent: () => true,
        canResolve: (p) => p.hostId != 'host-2',
        open: (p) async {
          opens++;
          return 'live';
        },
      ),
      throwsStateError,
    );
    expect(opens, 0);
    expect(coordinator.busy, false);
  });
  test('scope switch stops restore after awaited action and duplicate clicks do nothing', () async {
    final coordinator = CombinationRestoreCoordinator();
    final pending = Completer<String?>();
    var current = true;
    var opens = 0;
    final first = coordinator.restore(
      recipe: recipe(),
      isCurrent: () => current,
      canResolve: (_) => true,
      open: (_) {
        opens++;
        return pending.future;
      },
    );
    expect(
      await coordinator.restore(
        recipe: recipe(),
        isCurrent: () => current,
        canResolve: (_) => true,
        open: (_) async => 'duplicate',
      ),
      isNull,
    );
    current = false;
    pending.complete('old-scope');
    expect((await first)!.stale, true);
    expect(opens, 1);
    expect(coordinator.busy, false);
  });
  test(
    'restore reports partial failure and revalidates each latest host',
    () async {
      final coordinator = CombinationRestoreCoordinator();
      var changed = false;
      var opens = 0;
      final result = await coordinator.restore(
        recipe: recipe(),
        isCurrent: () => true,
        canResolve: (p) => !changed || p.hostId != 'host-2',
        open: (p) async {
          opens++;
          changed = true;
          return 'live-1';
        },
      );
      expect(result!.sessions, {0: 'live-1'});
      expect(result.failures, 1);
      expect(opens, 1);
      final failure = await coordinator.restore(
        recipe: recipe(),
        isCurrent: () => true,
        canResolve: (_) => true,
        open: (p) async {
          if (p.kind == 'rdp') throw StateError('failure');
          return 'ssh';
        },
      );
      expect(failure!.sessions, {0: 'ssh'});
      expect(failure.failures, 1);
    },
  );
  testWidgets('name dialog survives route exit after submit', (tester) async {
    String? name;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                name = await askWindowCombinationName(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Team layout');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(name, 'Team layout');
    expect(tester.takeException(), isNull);
  });
  testWidgets('homepage chips only connect after an explicit click', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindowCombinationsStrip(
            load: () async => [recipe()],
            open: (_) async {
              opens++;
            },
            remove: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(opens, 0);
    await tester.tap(find.text('运维组合 · 2'));
    await tester.pump();
    expect(opens, 1);
  });
}
