import 'dart:async';

import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/ui/window_combinations.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

WindowCombination recipe({bool legacy = false}) => WindowCombination(
  id: 'owners',
  name: 'owners',
  panes: [
    CombinationPane(
      kind: 'sftp',
      hostId: 'same',
      ownerPane: legacy ? null : 3,
      remotePath: '/a',
    ),
    CombinationPane(kind: 'ssh', hostId: 'same'),
    CombinationPane(
      kind: 'scp',
      hostId: 'same',
      ownerPane: legacy ? null : 1,
      remotePath: '/b',
    ),
    CombinationPane(kind: 'ssh', hostId: 'same'),
  ],
  tree: {
    'axis': 'horizontal',
    'ratio': .37,
    'first': {'pane': 0},
    'second': {'pane': 3},
  },
  activePane: 3,
);
void main() {
  test('v4 roundtrip retains bounded owner indices and rejects invalid cross-host references', () {
    final reopened = WindowCombination.decode(
      WindowCombination.encode([recipe()]),
    ).single;
    expect(reopened.schemaVersion, 4);
    expect(reopened.panes[0].ownerPane, 3);
    expect(reopened.panes[2].ownerPane, 1);
    for (final owner in [-1, 0, 1, 2, 32]) {
      expect(
        () => WindowCombination(
          id: 'bad',
          name: 'bad',
          panes: [
            CombinationPane(kind: 'sftp', hostId: 'x', ownerPane: owner),
            CombinationPane(kind: 'ssh', hostId: 'other'),
          ],
          tree: {'pane': 0},
          activePane: 0,
        ),
        throwsFormatException,
      );
    }
    expect(
      WindowCombination.decode(WindowCombination.encode([recipe(legacy: true)]))
          .single
          .schemaVersion,
      1,
    );
  });
  test('capture resolves exact runtime source to persistent pane index', () {
    final workspace = SessionWorkspaceController()..activate('file');
    final result = captureWindowCombination(
      id: 'capture',
      name: 'capture',
      sessionIds: ['ssh-a', 'ssh-b', 'file'],
      workspace: workspace,
      describe: (id) =>
          CombinationPane(kind: id == 'file' ? 'sftp' : 'ssh', hostId: 'same'),
      fileOwner: (id) => id == 'file' ? 'ssh-b' : null,
    );
    expect(result.panes[2].ownerPane, 1);
    expect(
      () => captureWindowCombination(
        id: 'bad',
        name: 'bad',
        sessionIds: ['file'],
        workspace: workspace,
        describe: (_) => CombinationPane(kind: 'sftp', hostId: 'same'),
        fileOwner: (_) => 'missing',
      ),
      throwsStateError,
    );
    workspace.dispose();
  });
  test('out-of-order files use exact owners, two connections, unchanged split indices', () async {
    var connections = 0;
    final owners = <String>[];
    final result = await CombinationRestoreCoordinator().restore(
      recipe: recipe(),
      isCurrent: () => true,
      canResolve: (_) => true,
      open: (_) async => 'ssh-${++connections}',
      openAttachedFile: (p, id) async {
        owners.add(id);
        return 'file-${p.kind}';
      },
    );
    expect(connections, 2);
    expect(owners, ['ssh-2', 'ssh-1']);
    expect(result!.failures, 0);
    final workspace = SessionWorkspaceController();
    applyWindowCombination(recipe(), workspace, result.sessions);
    expect(workspace.selectedId, 'ssh-2');
    expect((workspace.root as SessionWorkspaceSplit).ratio, .37);
    expect(workspace.sessionIds.toSet(), {'file-sftp', 'ssh-2'});
    workspace.dispose();
  });
  test(
    'failed explicit owner never falls back to other same-host SSH',
    () async {
      var calls = 0;
      final files = <String>[];
      final result = await CombinationRestoreCoordinator().restore(
        recipe: recipe(),
        isCurrent: () => true,
        canResolve: (_) => true,
        open: (_) async => ++calls == 2 ? null : 'ssh-a',
        openAttachedFile: (p, id) async {
          files.add(p.kind);
          return 'file';
        },
      );
      expect(calls, 2);
      expect(files, ['scp']);
      expect(result!.failures, 2);
      expect(result.sessions.containsKey(0), false);
    },
  );
  test('legacy files reuse only successful owners from this restore', () async {
    var calls = 0;
    final owners = <String>[];
    final result = await CombinationRestoreCoordinator().restore(
      recipe: recipe(legacy: true),
      isCurrent: () => true,
      canResolve: (_) => true,
      open: (_) async => 'new-${++calls}',
      openAttachedFile: (p, id) async {
        owners.add(id);
        return p.kind;
      },
    );
    expect(calls, 2);
    expect(owners, ['new-1', 'new-1']);
    expect(result!.failures, 0);
  });
  test(
    'scope revocation during owner or file await stops remaining work',
    () async {
      for (final revokeInFile in [false, true]) {
        var current = true, calls = 0, fileCalls = 0;
        final pending = Completer<String?>();
        final future = CombinationRestoreCoordinator().restore(
          recipe: recipe(),
          isCurrent: () => current,
          canResolve: (_) => true,
          open: (_) async {
            calls++;
            return revokeInFile ? 'ssh-$calls' : pending.future;
          },
          openAttachedFile: (_, __) {
            fileCalls++;
            return pending.future;
          },
        );
        await Future<void>.delayed(Duration.zero);
        current = false;
        pending.complete('stale');
        expect((await future)!.stale, true);
        expect(calls, revokeInFile ? 2 : 1);
        expect(fileCalls, revokeInFile ? 1 : 0);
      }
    },
  );
}
