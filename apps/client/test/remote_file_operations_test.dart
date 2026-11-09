import 'package:aterm_client/sftp/remote_file_operations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/memory_remote_fs.dart';

Matcher _opError(RemoteFileOperationError error) =>
    isA<RemoteFileOperationException>().having((e) => e.error, 'error', error);

void main() {
  late MemoryRemoteFs fs;
  late RemoteFileOperations ops;

  setUp(() {
    fs = MemoryRemoteFs()
      ..addDirectory('/srv')
      ..addFile('/srv/a.txt', 'A')
      ..addFile('/srv/b.txt', 'B');
    ops = RemoteFileOperations(fs);
  });

  group('rename / move never replace', () {
    test('collision is refused and both entries keep their bytes', () async {
      await expectLater(
        ops.rename('/srv', 'a.txt', 'b.txt'),
        throwsA(_opError(RemoteFileOperationError.destinationExists)),
      );
      expect(fs.text('/srv/a.txt'), 'A');
      expect(fs.text('/srv/b.txt'), 'B');
      expect(fs.calls.where((c) => c.startsWith('rename')), isEmpty);
    });

    test(
      'destination created after the pre-check is still not replaced',
      () async {
        fs.beforeRename = (_, to) => fs.addFile(to, 'RACE');
        await expectLater(
          ops.rename('/srv', 'a.txt', 'c.txt'),
          throwsA(_opError(RemoteFileOperationError.destinationExists)),
        );
        expect(fs.text('/srv/a.txt'), 'A');
        expect(fs.text('/srv/c.txt'), 'RACE');
        // Nothing was deleted to make room for the rename.
        expect(fs.calls.where((c) => c.startsWith('remove')), isEmpty);
      },
    );

    test('rename succeeds and rejects path-like names', () async {
      expect(await ops.rename('/srv', 'a.txt', ' c.txt '), '/srv/c.txt');
      expect(fs.text('/srv/c.txt'), 'A');
      expect(fs.nodes.containsKey('/srv/a.txt'), isFalse);
      for (final bad in ['../x', 'x/y', '..', 'a\\b', 'bad\nname', '']) {
        await expectLater(
          ops.rename('/srv', 'c.txt', bad),
          throwsA(_opError(RemoteFileOperationError.invalidName)),
        );
      }
      expect(fs.text('/srv/c.txt'), 'A');
    });

    test('folders cannot move into themselves', () async {
      fs
        ..addDirectory('/srv/dir')
        ..addDirectory('/srv/dir/sub');
      await expectLater(
        ops.move('/srv/dir', '/srv/dir/sub', 'dir'),
        throwsA(_opError(RemoteFileOperationError.intoItself)),
      );
      await expectLater(
        ops.move('/srv/dir', '/srv/dir', 'dir'),
        throwsA(_opError(RemoteFileOperationError.intoItself)),
      );
      expect(fs.nodes.containsKey('/srv/dir/sub'), isTrue);
      expect(isSameOrDescendantPath('/srv/dirx', '/srv/dir'), isFalse);
    });
  });

  group('copy', () {
    setUp(() {
      fs
        ..addDirectory('/srv/src')
        ..addFile('/srv/src/one.txt', '1', mode: 0x1ed)
        ..addDirectory('/srv/src/nested')
        ..addFile('/srv/src/nested/two.txt', '2')
        ..addDirectory('/dst');
    });

    test('copies a folder tree with modes and keeps the source', () async {
      final plan = await ops.planCopy('/srv/src');
      expect(plan.fileCount, 2);
      final progress = <double?>[];
      await ops.copy(
        plan,
        '/srv/src',
        '/dst',
        'src',
        cancellation: RemoteFileCancellation(),
        onProgress: (p) => progress.add(p.fraction),
      );
      expect(fs.text('/dst/src/one.txt'), '1');
      expect(fs.nodes['/dst/src/one.txt']!.mode, 0x1ed);
      expect(fs.text('/dst/src/nested/two.txt'), '2');
      expect(fs.text('/srv/src/one.txt'), '1');
      expect(progress.last, 1);
    });

    test(
      'failure rolls back only created entries and leaves the source',
      () async {
        final plan = await ops.planCopy('/srv/src');
        fs.failCopy = (to) => to.endsWith('two.txt');
        await expectLater(
          ops.copy(
            plan,
            '/srv/src',
            '/dst',
            'src',
            cancellation: RemoteFileCancellation(),
          ),
          throwsStateError,
        );
        expect(fs.nodes.keys.where((k) => k.startsWith('/dst/')), isEmpty);
        expect(fs.text('/srv/src/one.txt'), '1');
        expect(fs.text('/srv/src/nested/two.txt'), '2');
      },
    );

    test('rollback never removes foreign content added meanwhile', () async {
      final plan = await ops.planCopy('/srv/src');
      late String foreign;
      fs.failCopy = (to) {
        if (!to.endsWith('two.txt')) return false;
        // Another client drops a file into the (staging) copy root.
        foreign = '${to.substring(0, to.indexOf('/nested'))}/foreign.txt';
        fs.addFile(foreign, 'F');
        return true;
      };
      await expectLater(
        ops.copy(
          plan,
          '/srv/src',
          '/dst',
          'src',
          cancellation: RemoteFileCancellation(),
        ),
        throwsStateError,
      );
      expect(fs.text(foreign), 'F');
      expect(
        fs.nodes.keys.where(
          (k) => k.endsWith('one.txt') && k.startsWith('/dst'),
        ),
        isEmpty,
      );
      expect(
        fs.nodes.containsKey('/dst/src'),
        isFalse,
        reason: 'never published',
      );
    });

    test('existing destination folder is refused, not merged', () async {
      fs
        ..addDirectory('/dst/src')
        ..addFile('/dst/src/one.txt', 'KEEP');
      final plan = await ops.planCopy('/srv/src');
      await expectLater(
        ops.copy(
          plan,
          '/srv/src',
          '/dst',
          'src',
          cancellation: RemoteFileCancellation(),
        ),
        throwsA(_opError(RemoteFileOperationError.destinationExists)),
      );
      expect(fs.text('/dst/src/one.txt'), 'KEEP');
      expect(
        fs.nodes.keys.where((k) => k.contains('.atermius-copy-')),
        isEmpty,
      );
    });

    test(
      'symbolic links block a folder copy instead of being followed',
      () async {
        fs.addLink('/srv/src/escape', '/etc');
        await expectLater(
          ops.planCopy('/srv/src'),
          throwsA(_opError(RemoteFileOperationError.unsupportedEntry)),
        );
        expect(fs.calls.where((c) => c.startsWith('copy')), isEmpty);
      },
    );

    test('tree limits stop planning before any write', () async {
      final small = RemoteFileOperations(
        fs,
        limits: const RemoteFileOperationLimits(maxEntries: 2),
      );
      await expectLater(
        small.planCopy('/srv/src'),
        throwsA(_opError(RemoteFileOperationError.limitExceeded)),
      );
      final shallow = RemoteFileOperations(
        fs,
        limits: const RemoteFileOperationLimits(maxDepth: 1),
      );
      await expectLater(
        shallow.planDelete('/srv/src'),
        throwsA(_opError(RemoteFileOperationError.limitExceeded)),
      );
      expect(fs.calls.where((c) => !c.startsWith('readdir')), isEmpty);
    });

    test('cancellation rolls back and reports cancelled', () async {
      final plan = await ops.planCopy('/srv/src');
      final cancel = RemoteFileCancellation();
      fs.failCopy = (to) {
        cancel.cancel();
        return false;
      };
      await expectLater(
        ops.copy(plan, '/srv/src', '/dst', 'src', cancellation: cancel),
        throwsA(_opError(RemoteFileOperationError.cancelled)),
      );
      expect(fs.nodes.keys.where((k) => k.startsWith('/dst/')), isEmpty);
    });

    test('free "(copy)" names keep the extension', () async {
      expect(await ops.availableName('/srv', 'new.txt'), 'new.txt');
      expect(await ops.availableName('/srv', 'a.txt'), 'a (copy).txt');
      fs.addFile('/srv/a (copy).txt', '');
      expect(await ops.availableName('/srv', 'a.txt'), 'a (copy 2).txt');
      expect(
        await ops.availableName('/srv', 'a.txt', reserved: {'a (copy 2).txt'}),
        'a (copy 3).txt',
      );
    });
  });

  group('delete', () {
    setUp(() {
      fs
        ..addDirectory('/outside')
        ..addFile('/outside/keep.txt', 'K')
        ..addDirectory('/srv/tree')
        ..addFile('/srv/tree/f.txt', 'F')
        ..addDirectory('/srv/tree/sub')
        ..addLink('/srv/tree/sub/link', '/outside');
    });

    test('removes the tree, links as links, never their targets', () async {
      final plan = await ops.planDelete('/srv/tree');
      expect(plan.entries.length, 4);
      await ops.delete(
        plan,
        '/srv/tree',
        cancellation: RemoteFileCancellation(),
      );
      expect(fs.nodes.keys.where((k) => k.startsWith('/srv/tree')), isEmpty);
      expect(fs.text('/outside/keep.txt'), 'K');
    });

    test('content added after confirmation stops the delete', () async {
      final plan = await ops.planDelete('/srv/tree');
      fs.addFile('/srv/tree/sub/new.txt', 'NEW');
      await expectLater(
        ops.delete(plan, '/srv/tree', cancellation: RemoteFileCancellation()),
        throwsA(anything),
      );
      expect(fs.text('/srv/tree/sub/new.txt'), 'NEW');
    });

    test(
      'a folder swapped for a link after planning is not traversed',
      () async {
        final plan = await ops.planDelete('/srv/tree');
        fs.nodes.removeWhere((k, _) => k.startsWith('/srv/tree/sub'));
        fs.addLink('/srv/tree/sub', '/outside');
        await expectLater(
          ops.delete(plan, '/srv/tree', cancellation: RemoteFileCancellation()),
          throwsA(_opError(RemoteFileOperationError.sourceChanged)),
        );
        expect(fs.text('/outside/keep.txt'), 'K');
      },
    );
  });

  group('root review regressions', () {
    setUp(() {
      fs
        ..addDirectory('/outside')
        ..addFile('/outside/two.txt', 'SECRET')
        ..addFile('/outside/a.txt', 'OUTSIDE')
        ..addDirectory('/srv/src')
        ..addFile('/srv/src/one.txt', '1')
        ..addDirectory('/srv/src/nested')
        ..addFile('/srv/src/nested/two.txt', '2')
        ..addDirectory('/dst');
    });

    test('aggregate byte budget counts bytes actually streamed', () async {
      final small = RemoteFileOperations(
        fs,
        limits: const RemoteFileOperationLimits(maxTotalBytes: 5),
      );
      final plan = await small.planCopy('/srv/src');
      expect(plan.totalBytes, 2);
      // The source grows after it was planned and confirmed.
      fs.addFile('/srv/src/nested/two.txt', '0123456789');
      await expectLater(
        small.copy(
          plan,
          '/srv/src',
          '/dst',
          'src',
          cancellation: RemoteFileCancellation(),
        ),
        throwsA(_opError(RemoteFileOperationError.limitExceeded)),
      );
      final copyCalls = fs.calls.where((c) => c.startsWith('copy')).toList();
      expect(copyCalls.length, 2);
      expect(fs.nodes.keys.where((k) => k.startsWith('/dst/')), isEmpty);
      expect(fs.text('/srv/src/nested/two.txt'), '0123456789');
    });

    test(
      'planned source folder swapped for a link is not read through',
      () async {
        final plan = await ops.planCopy('/srv/src');
        fs.replaceWithLink('/srv/src/nested', '/outside');
        await expectLater(
          ops.copy(
            plan,
            '/srv/src',
            '/dst',
            'src',
            cancellation: RemoteFileCancellation(),
          ),
          throwsA(_opError(RemoteFileOperationError.sourceChanged)),
        );
        expect(
          fs.calls.where((c) => c.contains('/srv/src/nested/two.txt')),
          isEmpty,
        );
        expect(fs.nodes.keys.where((k) => k.startsWith('/dst/')), isEmpty);
        expect(fs.text('/outside/two.txt'), 'SECRET');
      },
    );

    test(
      'planned source root swapped for a link stops before any request',
      () async {
        final plan = await ops.planCopy('/srv/src');
        fs.calls.clear();
        fs.replaceWithLink('/srv/src', '/outside');
        await expectLater(
          ops.copy(
            plan,
            '/srv/src',
            '/dst',
            'src',
            cancellation: RemoteFileCancellation(),
          ),
          throwsA(_opError(RemoteFileOperationError.sourceChanged)),
        );
        expect(fs.calls, isEmpty);
      },
    );

    test(
      'created destination folder swapped for a link is not written through',
      () async {
        final plan = await ops.planCopy('/srv/src');
        fs.afterCreateDirectory = (path) {
          if (path.endsWith('/nested')) fs.replaceWithLink(path, '/outside');
        };
        await expectLater(
          ops.copy(
            plan,
            '/srv/src',
            '/dst',
            'src',
            cancellation: RemoteFileCancellation(),
          ),
          throwsA(_opError(RemoteFileOperationError.sourceChanged)),
        );
        expect(fs.text('/outside/two.txt'), 'SECRET');
        expect(fs.nodes.keys.where((k) => k.startsWith('/outside/')).length, 2);
      },
    );

    test(
      'planner stops a huge listing without draining it and closes it',
      () async {
        final batched = MemoryRemoteFs(batchSize: 10)..addDirectory('/big');
        for (var i = 0; i < 100; i++) {
          batched.addFile('/big/f$i', '');
        }
        final bounded = RemoteFileOperations(
          batched,
          limits: const RemoteFileOperationLimits(maxEntries: 15),
        );
        await expectLater(
          bounded.planDelete('/big'),
          throwsA(_opError(RemoteFileOperationError.limitExceeded)),
        );
        expect(batched.directoryBatchesYielded, 2);
        expect(batched.openDirectoryHandles, 0);
      },
    );

    test('planner re-lstats a folder before descending into it', () async {
      fs.afterReadDirectory = (path) {
        if (path == '/srv/src') {
          fs.replaceWithLink('/srv/src/nested', '/outside');
        }
      };
      await expectLater(
        ops.planCopy('/srv/src'),
        throwsA(_opError(RemoteFileOperationError.sourceChanged)),
      );
      expect(fs.calls, isNot(contains('readdir /srv/src/nested')));
      expect(fs.openDirectoryHandles, 0);
    });

    test(
      'delete re-checks the planned root before any child request',
      () async {
        final plan = await ops.planDelete('/srv/src');
        fs.calls.clear();
        fs.replaceWithLink('/srv/src', '/outside');
        await expectLater(
          ops.delete(plan, '/srv/src', cancellation: RemoteFileCancellation()),
          throwsA(_opError(RemoteFileOperationError.sourceChanged)),
        );
        expect(fs.calls.where((c) => !c.startsWith('readdir')), isEmpty);
        expect(fs.text('/outside/two.txt'), 'SECRET');
        expect(fs.text('/outside/a.txt'), 'OUTSIDE');
      },
    );

    test(
      'delete does not trust an ancestor check from earlier in the walk',
      () async {
        fs
          ..addDirectory('/srv/tree')
          ..addDirectory('/srv/tree/sub')
          ..addFile('/srv/tree/sub/a.txt', 'A')
          ..addFile('/srv/tree/sub/b.txt', 'B');
        final plan = await ops.planDelete('/srv/tree');
        var swapped = false;
        fs.afterRemoveFile = (path) {
          if (swapped || !path.startsWith('/srv/tree/sub/')) return;
          swapped = true;
          // After the first child was removed, "sub" becomes a link outside.
          fs.replaceWithLink('/srv/tree/sub', '/outside');
        };
        await expectLater(
          ops.delete(plan, '/srv/tree', cancellation: RemoteFileCancellation()),
          throwsA(_opError(RemoteFileOperationError.sourceChanged)),
        );
        expect(swapped, isTrue);
        expect(fs.text('/outside/a.txt'), 'OUTSIDE');
        expect(fs.text('/outside/two.txt'), 'SECRET');
      },
    );
  });

  test('a closed owner stops further remote requests', () async {
    var open = true;
    final guarded = RemoteFileOperations(
      fs,
      ensureOpen: () {
        if (!open) throw StateError('closed');
      },
    );
    open = false;
    await expectLater(
      guarded.rename('/srv', 'a.txt', 'c.txt'),
      throwsStateError,
    );
    expect(fs.text('/srv/a.txt'), 'A');
    expect(fs.calls, isEmpty);
  });
}
