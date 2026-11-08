import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/platform/file_window_tracking.dart';
import 'package:aterm_client/platform/files_window_launch.dart';
import 'package:aterm_client/platform/window_geometry.dart';
import 'package:aterm_client/platform/window_launch_environment.dart';
import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/window_combinations.dart';

class _RealNetwork extends HttpOverrides {}

SavedWindowPlacement _placement() =>
    SavedWindowPlacement(x: 30, y: 40, width: 900, height: 600);
FilesWindowLaunch _launch({
  String scope = 'profile',
  String host = 'host-a',
  String path = '/srv',
  FilesWindowProtocol protocol = FilesWindowProtocol.sftp,
}) => FilesWindowLaunch(
  workspace: FilesWindowWorkspace.local,
  scopeId: scope,
  hostId: host,
  protocol: protocol,
  initialPath: path,
);

class _Geometry extends WindowGeometry {
  int captures = 0, restores = 0;
  bool succeeds = true;
  Completer<SavedWindowPlacement?>? captureGate;
  @override
  Future<SavedWindowPlacement?> capturePlacement() async {
    captures++;
    return captureGate?.future ?? _placement();
  }

  @override
  Future<bool> restorePlacement(
    SavedWindowPlacement value, {
    bool Function()? isCurrent,
  }) async {
    if (isCurrent?.call() == false) return false;
    restores++;
    return succeeds;
  }
}

void _networkTest(String name, Future<void> Function() body) => test(
  name,
  () => HttpOverrides.runWithHttpOverrides(body, _RealNetwork()),
  timeout: const Timeout(Duration(seconds: 15)),
);
Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('condition timeout');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<WebSocket> _raw(
  FileTrackingLaunch launch, {
  String? origin,
  String? capability,
  String suffix = '',
  String? hostHeader,
}) => WebSocket.connect(
  'ws://127.0.0.1:${launch.port}/file-geometry/${launch.id}$suffix',
  headers: {
    'Origin': origin ?? 'atermius://file-window-geometry',
    'Authorization': 'Bearer ${capability ?? launch.capability}',
    if (hostHeader != null) 'Host': hostHeader,
  },
  protocols: ['atermius-file-geometry-v1'],
  compression: CompressionOptions.compressionOff,
  maxPayloadLength: 16384,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capabilities stay out of argv and unrelated child environments', () {
    final launch = FileTrackingLaunch(
      port: 1234,
      id: 'A' * 22,
      capability: 'B' * 43,
    );
    expect(launch.toArguments().join(' '), isNot(contains(launch.capability)));
    expect(
      detectFileTrackingLaunch(
        launch.toArguments(),
        environment: {fileWindowCapabilityEnvironment: launch.capability},
      )!.id,
      launch.id,
    );
    expect(
      () => detectFileTrackingLaunch(
        [...launch.toArguments(), '--file-geometry-port=1234'],
        environment: {fileWindowCapabilityEnvironment: launch.capability},
      ),
      throwsFormatException,
    );
    expect(
      () => detectFileTrackingLaunch(launch.toArguments(), environment: {}),
      throwsFormatException,
    );
    final clean = windowLaunchEnvironment(
      {
        'PATH': 'safe',
        'ATERMIUS_TERMINAL_WINDOW_CAPABILITY': 'old-terminal',
        'atermius_desktop_window_capability': 'old-desktop',
        fileWindowCapabilityEnvironment: 'old-file',
      },
      capability: {fileWindowCapabilityEnvironment: 'new-file'},
    );
    expect(clean, {
      'PATH': 'safe',
      fileWindowCapabilityEnvironment: 'new-file',
    });
    expect(
      () => FilesWindowLaunch.fromJson({
        ..._launch().toJson(),
        'password': 'bad',
      }),
      throwsFormatException,
    );
  });
  _networkTest('wrong capability Origin Host/query and reuse are rejected without consuming valid receiver', () async {
    final broker = await FileGeometryBroker.bind(expected: _launch());
    try {
      await expectLater(
        _raw(broker.launch, origin: 'https://example.test'),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        _raw(broker.launch, capability: 'X' * 43),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        _raw(broker.launch, suffix: '?q=1'),
        throwsA(isA<WebSocketException>()),
      );
      await expectLater(
        _raw(broker.launch, hostHeader: 'localhost:${broker.launch.port}'),
        throwsA(isA<WebSocketException>()),
      );
      expect(broker.isReady, false);
      final child = await FileWindowTrackingClient.connect(
        broker.launch,
        expected: _launch(),
        geometry: _Geometry(),
      );
      try {
        expect(await broker.ready, true);
        await expectLater(
          _raw(broker.launch),
          throwsA(isA<WebSocketException>()),
        );
      } finally {
        await child.close();
      }
    } finally {
      await broker.close();
    }
  });
  _networkTest('pre-auth has no Host/path snapshot and scoped provider returns current path/geometry', () async {
    final geometry = _Geometry();
    final broker = await FileGeometryBroker.bind(
      expected: _launch(),
      initialPlacement: _placement(),
    );
    final child = await FileWindowTrackingClient.connect(
      broker.launch,
      expected: _launch(),
      geometry: geometry,
    );
    try {
      await broker.ready;
      expect(await broker.handle.initialPlacementApplied, true);
      expect(geometry.restores, 1);
      expect(await broker.snapshot(), isNull);
      expect(geometry.captures, 0);
      var current = _launch(
        path: '/new/current',
        protocol: FilesWindowProtocol.scp,
      );
      final unregister = child.provide(() => current);
      final snapshot = (await broker.snapshot())!;
      expect(snapshot.launch.initialPath, '/new/current');
      expect(snapshot.launch.protocol, FilesWindowProtocol.scp);
      expect(snapshot.placement!.toJson(), _placement().toJson());
      current = _launch(scope: 'other-profile', path: '/private-other-scope');
      expect(await broker.snapshot(), isNull);
      expect(geometry.captures, 1);
      unregister();
      expect(await broker.snapshot(), isNull);
    } finally {
      await broker.close();
      await child.close();
    }
  });
  _networkTest('scope/path change during native bounds lookup discards the entire metadata snapshot', () async {
    final geometry = _Geometry()
      ..captureGate = Completer<SavedWindowPlacement?>();
    final broker = await FileGeometryBroker.bind(expected: _launch());
    final child = await FileWindowTrackingClient.connect(
      broker.launch,
      expected: _launch(),
      geometry: geometry,
    );
    var current = _launch();
    await broker.ready;
    child.provide(() => current);
    try {
      final snapshot = broker.snapshot();
      await _until(() => geometry.captures == 1);
      current = _launch(scope: 'different-profile', path: '/do-not-leak');
      geometry.captureGate!.complete(_placement());
      expect(await snapshot, isNull);
    } finally {
      await broker.close();
      await child.close();
    }
  });
  _networkTest(
    'same-scope lock unlock epoch invalidates a pending geometry snapshot',
    () async {
      final geometry = _Geometry()
        ..captureGate = Completer<SavedWindowPlacement?>();
      final broker = await FileGeometryBroker.bind(expected: _launch());
      final child = await FileWindowTrackingClient.connect(
        broker.launch,
        expected: _launch(),
        geometry: geometry,
      );
      await broker.ready;
      var epoch = 1;
      FilesWindowLaunch? current = _launch();
      child.provide(() => current, scopeEpoch: () => epoch);
      try {
        final pending = broker.snapshot();
        await _until(() => geometry.captures == 1);
        current = null;
        epoch++;
        current = _launch();
        epoch++;
        geometry.captureGate!.complete(_placement());
        expect(await pending, isNull);
      } finally {
        await broker.close();
        await child.close();
      }
    },
  );
  _networkTest('forged cross-scope descriptor revokes metadata only and oversized messages are bounded', () async {
    final broker = await FileGeometryBroker.bind(expected: _launch());
    final raw = await _raw(broker.launch);
    final iterator = StreamIterator(raw);
    await iterator.moveNext();
    raw.add(jsonEncode({'type': 'ready', 'applied': true}));
    expect(await broker.ready, true);
    final pending = broker.snapshot();
    await iterator.moveNext();
    final request = jsonDecode(iterator.current as String)['request'];
    raw.add(
      jsonEncode({
        'type': 'snapshot',
        'request': request,
        'launch': _launch(scope: 'foreign').toJson(),
        'placement': _placement().toJson(),
      }),
    );
    expect(await pending, isNull);
    await broker.closed;
    await iterator.cancel();
    await raw.close();
    final oversized = await FileGeometryBroker.bind(expected: _launch());
    final socket = await _raw(oversized.launch);
    socket.listen((_) {});
    socket.add('X' * 20000);
    await oversized.closed;
    expect(oversized.isReady, false);
    await socket.close();
  });
  _networkTest('parent close and lock revoke tracking but never close independent file connections', () async {
    final children = <FileWindowTrackingClient>[];
    final owner = Object();
    final independentServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final accepted = Completer<Socket>();
    independentServer.listen((socket) {
      accepted.complete(socket);
      socket.listen(socket.add, onError: (_) => socket.destroy());
    });
    final independentConnection = await Socket.connect(
      InternetAddress.loopbackIPv4,
      independentServer.port,
    );
    final echo = Completer<String>();
    independentConnection.listen(
      (data) {
        if (!echo.isCompleted) echo.complete(utf8.decode(data));
      },
      onError: (Object error) {
        if (!echo.isCompleted) echo.completeError(error);
      },
    );
    final manager = TrackedFilesWindows(
      startProcess: (arguments, environment) async {
        final tracking = detectFileTrackingLaunch(
          arguments,
          environment: environment,
        )!;
        expect(
          arguments.join(' '),
          isNot(contains(environment[fileWindowCapabilityEnvironment]!)),
        );
        final child = await FileWindowTrackingClient.connect(
          tracking,
          expected: _launch(),
          geometry: _Geometry(),
        );
        child.provide(() => _launch());
        children.add(child);
      },
    );
    final handle = await manager.open(owner: owner, launch: _launch());
    expect(await handle.ready, true);
    expect(manager.hasWindows(owner), true);
    expect(await manager.capture(Object()), isEmpty);
    expect((await manager.capture(owner)).single.launch.hostId, 'host-a');
    await manager.releaseOwner(owner);
    await _until(() => !children.single.connected);
    expect(manager.hasWindows(owner), false);
    independentConnection.add(utf8.encode('independent-session-still-alive'));
    expect(
      await echo.future.timeout(const Duration(seconds: 2)),
      'independent-session-still-alive',
    );
    await independentConnection.close();
    await (await accepted.future).close();
    await independentServer.close();
    await children.single.close();
    manager.dispose();
  });
  _networkTest(
    'account vault and server changes never expose another scoped descriptor',
    () async {
      FilesWindowLaunch cloud({
        String account = 'account',
        String vault = 'vault',
        String server = 'https://server.example.test',
      }) => FilesWindowLaunch(
        workspace: FilesWindowWorkspace.cloud,
        scopeId: vault,
        accountId: account,
        serverNamespace: server,
        hostId: 'host',
        protocol: FilesWindowProtocol.sftp,
        initialPath: '/scoped',
      );
      var current = cloud();
      final geometry = _Geometry(),
          broker = await FileGeometryBroker.bind(expected: current);
      final child = await FileWindowTrackingClient.connect(
        broker.launch,
        expected: current,
        geometry: geometry,
      );
      await broker.ready;
      child.provide(() => current);
      try {
        expect(await broker.snapshot(), isNotNull);
        for (final foreign in [
          cloud(account: 'foreign-account'),
          cloud(vault: 'foreign-vault'),
          cloud(server: 'https://other.example.test'),
        ]) {
          current = foreign;
          expect(await broker.snapshot(), isNull);
        }
        expect(geometry.captures, 1);
      } finally {
        await broker.close();
        await child.close();
      }
    },
  );
  _networkTest(
    'stale parent cannot replay initial placement after auth/provider startup',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final socketReady = Completer<WebSocket>();
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (_) => 'atermius-file-geometry-v1',
          compression: CompressionOptions.compressionOff,
        );
        socket.listen((_) {});
        socket.add(
          jsonEncode({'type': 'init', 'version': 1, 'placement': null}),
        );
        socketReady.complete(socket);
      });
      final geometry = _Geometry();
      final client = await FileWindowTrackingClient.connect(
        FileTrackingLaunch(
          port: server.port,
          id: 'A' * 22,
          capability: 'B' * 43,
        ),
        expected: _launch(),
        geometry: geometry,
      );
      client.provide(() => _launch(scope: 'new-profile'));
      final socket = await socketReady.future;
      socket.add(
        jsonEncode({
          'type': 'init',
          'version': 1,
          'placement': _placement().toJson(),
        }),
      );
      await _until(() => !client.connected);
      expect(geometry.restores, 0);
      await client.close();
      await socket.close();
      await server.close(force: true);
    },
  );
  _networkTest('file-only capture roundtrips safe intent and explicit restore avoids parent SSH/phantom panes', () async {
    final owner = Object(), geometry = _Geometry();
    final children = <FileWindowTrackingClient>[];
    final manager = TrackedFilesWindows(
      startProcess: (arguments, environment) async {
        final child = await FileWindowTrackingClient.connect(
          detectFileTrackingLaunch(arguments, environment: environment)!,
          expected: _launch(),
          geometry: _Geometry(),
        );
        child.provide(() => _launch(path: '/latest-directory'));
        children.add(child);
      },
    );
    final handle = await manager.open(owner: owner, launch: _launch());
    await handle.ready;
    final workspace = SessionWorkspaceController();
    final recipe = await captureWindowCombinationWithPlacements(
      id: 'layout',
      name: 'Files',
      sessionIds: [],
      workspace: workspace,
      describe: (_) => null,
      owner: owner,
      isCurrent: () => true,
      fileWindows: manager,
      geometry: geometry,
    );
    expect(recipe.schemaVersion, 3);
    expect(recipe.windows.single.independentFile, true);
    expect(recipe.panes.single.remotePath, '/latest-directory');
    final encoded = WindowCombination.encode([recipe]);
    expect(encoded, isNot(contains(handle.id)));
    expect(encoded, isNot(contains('capability')));
    expect(encoded, isNot(contains('account')));
    final reopened = WindowCombination.decode(encoded).single;
    var parentConnections = 0, independentStarts = 0;
    final restored = await CombinationRestoreCoordinator().restore(
      recipe: reopened,
      isCurrent: () => true,
      canResolve: (pane) => pane.hostId == 'host-a',
      independentPane: (index) =>
          reopened.windows.any((w) => w.pane == index && w.independentFile),
      openIndependent: (_, pane) async {
        independentStarts++;
        return true;
      },
      open: (_) async {
        parentConnections++;
        return 'phantom';
      },
    );
    expect(restored!.sessions, isEmpty);
    expect(restored.independentOpened, 1);
    expect(parentConnections, 0);
    expect(independentStarts, 1);
    final failures = await restoreWindowCombinationPlacements(
      recipe: reopened,
      sessions: restored.sessions,
      isCurrent: () => true,
      detach: (_, __, ___) async {
        fail('independent files must not become parent mirrors');
      },
      applyDetached: (_, __) async => false,
      closeDetached: (_) async {},
      geometry: geometry,
    );
    expect(failures, 0);
    expect(geometry.restores, 1);
    await manager.releaseOwner(owner);
    for (final child in children) await child.close();
    manager.dispose();
  });
  _networkTest(
    'pending child startup cannot be silently omitted from a saved window set',
    () async {
      final owner = Object();
      final manager = TrackedFilesWindows(startProcess: (_, __) async {});
      final child = await manager.open(owner: owner, launch: _launch());
      expect(manager.hasWindows(owner), true);
      expect(manager.readyWindowCount(owner), 0);
      final workspace = SessionWorkspaceController()..activate('parent');
      await expectLater(
        captureWindowCombinationWithPlacements(
          id: 'layout',
          name: 'Pending',
          sessionIds: ['parent'],
          workspace: workspace,
          describe: (_) => CombinationPane(kind: 'ssh', hostId: 'parent-host'),
          owner: owner,
          isCurrent: () => true,
          fileWindows: manager,
          geometry: _Geometry(),
        ),
        throwsA(isA<FileWindowCaptureUnavailable>()),
      );
      expect(workspace.sessionIds, ['parent']);
      await manager.releaseOwner(owner);
      expect(await child.ready, false);
      manager.dispose();
    },
  );
  _networkTest('unavailable file metadata fails save without mutating existing split/groups or moving windows', () async {
    late FileWindowTrackingClient child;
    final owner = Object();
    final geometry = _Geometry();
    final manager = TrackedFilesWindows(
      startProcess: (arguments, environment) async {
        child = await FileWindowTrackingClient.connect(
          detectFileTrackingLaunch(arguments, environment: environment)!,
          expected: _launch(),
          geometry: _Geometry(),
        );
      },
    );
    final handle = await manager.open(owner: owner, launch: _launch());
    await handle.ready;
    final workspace = SessionWorkspaceController()..activate('a');
    workspace.split('b', 'a', SessionSplitEdge.right);
    workspace.resize(workspace.root as SessionWorkspaceSplit, .37);
    final root = workspace.root;
    await expectLater(
      captureWindowCombinationWithPlacements(
        id: 'layout',
        name: 'Save',
        sessionIds: ['a', 'b'],
        workspace: workspace,
        describe: (id) => CombinationPane(kind: 'ssh', hostId: id),
        owner: owner,
        isCurrent: () => true,
        fileWindows: manager,
        geometry: geometry,
      ),
      throwsA(isA<FileWindowCaptureUnavailable>()),
    );
    expect(workspace.root, same(root));
    expect((workspace.root as SessionWorkspaceSplit).ratio, .37);
    expect(workspace.selectedId, 'b');
    expect(workspace.groupFor('a'), ['a', 'b']);
    expect(geometry.restores, 0);
    await manager.releaseOwner(owner);
    await child.close();
    manager.dispose();
  });
}
