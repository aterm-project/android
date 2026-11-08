import 'dart:async';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/ssh_forwarding_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_port_forward_fakes.dart';

const _local = SshPortForwardProfile(
  id: 'l1',
  name: 'Postgres',
  type: SshPortForwardType.local,
  bindAddress: '127.0.0.1',
  bindPort: 0,
  destinationAddress: 'db.internal',
  destinationPort: 5432,
);

const _socks = SshPortForwardProfile(
  id: 'd1',
  name: 'SOCKS',
  type: SshPortForwardType.dynamic,
  bindAddress: '127.0.0.1',
  bindPort: 0,
);

const _exposed = SshPortForwardProfile(
  id: 'x1',
  name: 'LAN proxy',
  type: SshPortForwardType.dynamic,
  bindAddress: '0.0.0.0',
  bindPort: 0,
  exposeToNetwork: true,
);

const _alpha = HostRecord(
  id: 'alpha',
  name: 'Alpha',
  address: 'alpha.test',
  username: 'ops',
  portForwardProfiles: [_local, _socks],
);
const _beta = HostRecord(id: 'beta', name: 'Beta', address: 'beta.test');
const _desktop = HostRecord(
  id: 'rdp',
  name: 'Windows desktop',
  address: 'win.test',
  protocol: HostProtocol.rdp,
);

/// In-memory workspace adapter. Saves replace the Host's rule list (like the
/// encrypted Host store) and connects wait for the test to complete them.
class _Source extends ChangeNotifier implements SshForwardingSource {
  _Source(this.hostList);

  Object? scope = 'vault-1';
  List<HostRecord> hostList;
  final sessionList = <SshForwardingSessionInfo>[];
  final saves = <(String, List<SshPortForwardProfile>)>[];
  final connects = <String>[];
  final shown = <String>[];
  Completer<String?>? connectGate;
  bool editable = true;

  void signal() => notifyListeners();

  void addSession(
    String id,
    String hostId,
    SshPortForwardManager manager, {
    SshForwardingSessionPhase phase = SshForwardingSessionPhase.connected,
  }) {
    sessionList.add(
      SshForwardingSessionInfo(
        id: id,
        hostId: hostId,
        label: 'tab $id',
        phase: phase,
        manager: manager,
      ),
    );
    notifyListeners();
  }

  void replaceRules(String hostId, List<SshPortForwardProfile> rules) {
    hostList = [
      for (final host in hostList)
        host.id == hostId ? host.copyWith(portForwardProfiles: rules) : host,
    ];
    notifyListeners();
  }

  @override
  Object? get scopeKey => scope;
  @override
  List<HostRecord> get hosts => hostList;
  @override
  List<SshForwardingSessionInfo> get sessions => List.of(sessionList);
  @override
  bool get canEdit => editable;
  @override
  String? get readOnlyReason => 'Read-only Vault.';
  @override
  String get storageDescription => 'Stored in the encrypted Host.';
  @override
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) async {
    if (scope != this.scope) throw StateError('scope changed');
    final current = hostList.singleWhere((h) => h.id == hostId);
    final next = applySshPortForwardRuleChange(
      current.portForwardProfiles,
      expected: expected,
      replacement: replacement,
    );
    saves.add((hostId, next));
    replaceRules(hostId, next);
  }

  @override
  String describeSaveError(Object error) => 'save failed';
  @override
  Future<String?> connect(HostRecord host) {
    connects.add(host.id);
    return (connectGate = Completer<String?>()).future;
  }

  @override
  void showSession(String sessionId) => shown.add(sessionId);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// Waits for [future] while letting both the real event loop (sockets) and
/// the widget test zone (where the forward's handlers were registered) run.
Future<T> _wait<T>(WidgetTester tester, Future<T> future) async {
  T? value;
  Object? error;
  var done = false;
  future.then(
    (result) {
      value = result;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 15));
  }
  if (!done) fail('timed out waiting in the test');
  if (error != null) throw error!;
  return value as T;
}

Future<SshForwardingController> _open(
  WidgetTester tester,
  _Source source, {
  SshForwardingController? controller,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1100));
  final value = controller ?? SshForwardingController(runtimeSupported: true);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SshForwardingPage(source: source, controller: value),
      ),
    ),
  );
  await tester.pump();
  return value;
}

Finder _key(String key) => find.byKey(ValueKey(key));

IconButton _toggle(WidgetTester tester, String id) =>
    tester.widget<IconButton>(_key('r7fwd-toggle-$id'));

Future<void> _menu(WidgetTester tester, String rule, String action) async {
  await tester.tap(_key('r7fwd-menu-$rule'));
  await tester.pumpAndSettle();
  await tester.tap(_key(action));
  await tester.pumpAndSettle();
}

Future<void> _cleanup(
  WidgetTester tester,
  List<SshPortForwardManager> managers,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _wait(
    tester,
    Future.wait([for (final manager in managers) manager.closeAll()]),
  );
  await tester.binding.setSurfaceSize(null);
}

void main() {
  testWidgets('lists every SSH host rule and edits them through the Host save '
      'path (create, edit, duplicate, delete)', (tester) async {
    final source = _Source([_alpha, _beta, _desktop]);
    await _open(tester, source);

    expect(find.text('SSH Forwarding'), findsOneWidget);
    expect(find.text('2 rules on 1 hosts · 0 running'), findsOneWidget);
    expect(_key('r7fwd-rule-alpha-l1'), findsOneWidget);
    expect(_key('r7fwd-rule-alpha-d1'), findsOneWidget);
    expect(find.textContaining('db.internal:5432'), findsOneWidget);
    // Hosts without rules are listed on request; non-SSH hosts never are.
    expect(_key('r7fwd-host-beta'), findsNothing);
    await tester.tap(_key('r7fwd-show-all'));
    await tester.pump();
    expect(_key('r7fwd-host-beta'), findsOneWidget);
    expect(_key('r7fwd-host-rdp'), findsNothing);
    expect(find.text('Not connected'), findsNWidgets(2));
    // Visiting the page never connects or starts anything.
    expect(source.connects, isEmpty);

    // Create on a chosen host.
    await tester.tap(_key('r7fwd-new-rule'));
    await tester.pumpAndSettle();
    expect(_key('r7fwd-host-picker'), findsOneWidget);
    expect(_key('r7fwd-pick-rdp'), findsNothing);
    await tester.tap(_key('r7fwd-pick-beta'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('ssh-forward-profile-name'), 'Web');
    await tester.enterText(_key('ssh-forward-destination-address'), 'localhost');
    await tester.enterText(_key('ssh-forward-destination-port'), '8080');
    await tester.tap(_key('ssh-forward-profile-save'));
    await tester.pumpAndSettle();
    expect(source.saves.single.$1, 'beta');
    final created = source.saves.single.$2.single;
    expect(created.name, 'Web');
    expect(created.bindAddress, '127.0.0.1');
    expect(created.exposeToNetwork, isFalse);
    expect(_key('r7fwd-rule-beta-${created.id}'), findsOneWidget);

    // Edit keeps the id.
    await _menu(tester, 'alpha-l1', 'r7fwd-edit');
    await tester.enterText(_key('ssh-forward-profile-name'), 'Postgres RO');
    await tester.tap(_key('ssh-forward-profile-save'));
    await tester.pumpAndSettle();
    expect(source.saves.last.$1, 'alpha');
    expect(source.saves.last.$2.map((p) => (p.id, p.name)), [
      ('l1', 'Postgres RO'),
      ('d1', 'SOCKS'),
    ]);

    // Duplicate creates a new rule with a new id.
    await _menu(tester, 'alpha-d1', 'r7fwd-duplicate');
    expect(find.text('Duplicate forwarding rule'), findsOneWidget);
    expect(find.text('SOCKS copy'), findsOneWidget);
    await tester.tap(_key('ssh-forward-profile-save'));
    await tester.pumpAndSettle();
    final afterDuplicate = source.saves.last.$2;
    expect(afterDuplicate, hasLength(3));
    final copy = afterDuplicate.last;
    expect(copy.id, isNot('d1'));
    expect(copy.type, SshPortForwardType.dynamic);
    expect(copy.name, 'SOCKS copy');

    // Delete asks first.
    await _menu(tester, 'alpha-l1', 'r7fwd-delete');
    expect(_key('r7fwd-delete-confirm'), findsOneWidget);
    await tester.tap(_key('r7fwd-delete-accept'));
    await tester.pumpAndSettle();
    expect(source.saves.last.$2.map((p) => p.id), ['d1', copy.id]);
    expect(_key('r7fwd-rule-alpha-l1'), findsNothing);
    expect(source.connects, isEmpty);
    await _cleanup(tester, const []);
  });

  testWidgets('read-only scope can run but not edit rules', (tester) async {
    final source = _Source([_alpha])..editable = false;
    await _open(tester, source);
    expect(find.text('Read-only Vault.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('r7fwd-new-rule')).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<PopupMenuButton<String>>(_key('r7fwd-menu-alpha-l1'))
          .enabled,
      isFalse,
    );
    expect(_toggle(tester, 'alpha-l1').onPressed, isNotNull);
    await _cleanup(tester, const []);
  });

  testWidgets('local -L starts on the connected session, counts real '
      'connections, blocks editing, and stops on transport loss', (
    tester,
  ) async {
    final client = FakeForwardingSshClient();
    final manager = SshPortForwardManager(client);
    final source = _Source([_alpha])..addSession('s1', 'alpha', manager);
    await _open(tester, source);
    expect(find.text('Connected'), findsOneWidget);
    expect(manager.runningCount, 0, reason: 'no auto-start on page visit');

    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await _settle(tester);
    expect(manager.activeProfileIds, ['l1']);
    expect(source.connects, isEmpty);
    final port = manager.activeListeningPort('l1')!;
    expect(find.textContaining('127.0.0.1:$port'), findsOneWidget);

    final socket = (await tester.runAsync(
      () => Socket.connect(InternetAddress.loopbackIPv4, port),
    ))!;
    final channel = await _wait(tester, client.nextChannel());
    echoOnFakeChannel(channel);
    final echoed = Completer<List<int>>();
    socket.listen((data) {
      if (!echoed.isCompleted) echoed.complete(data);
    });
    socket.add([1, 2, 3]);
    expect(await _wait(tester, echoed.future), [1, 2, 3]);
    expect(client.dials, [('db.internal', 5432)]);
    await _settle(tester);
    expect(find.text('Running · 1 active · 1 total'), findsOneWidget);
    expect(find.text('2 rules on 1 hosts · 1 running'), findsOneWidget);

    // Running rules cannot be edited.
    await tester.tap(_key('r7fwd-menu-alpha-l1'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<PopupMenuItem<String>>(_key('r7fwd-edit')).enabled,
      isFalse,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Session link.
    await tester.tap(_key('r7fwd-open-session-alpha'));
    expect(source.shown, ['s1']);

    // Connection loss: listener closed, no stale running badge, and the row
    // offers a new connection instead of the dead session.
    client.endTransport();
    await _settle(tester);
    expect(manager.runningCount, 0);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.textContaining('Running'), findsNothing);
    expect(_toggle(tester, 'alpha-l1').tooltip, 'Connect and start');
    await tester.runAsync(socket.close);
    await _cleanup(tester, [manager]);
  });

  testWidgets('remote -R and dynamic SOCKS -D run over the session', (
    tester,
  ) async {
    final destination = (await tester.runAsync(
      () => ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    final reached = Completer<Socket>();
    destination.listen(reached.complete);
    final remote = SshPortForwardProfile(
      id: 'r1',
      name: 'Reverse',
      type: SshPortForwardType.remote,
      bindAddress: '127.0.0.1',
      bindPort: 9000,
      destinationAddress: '127.0.0.1',
      destinationPort: destination.port,
    );
    final client = FakeForwardingSshClient();
    final manager = SshPortForwardManager(client);
    final source = _Source([
      _alpha.copyWith(portForwardProfiles: [remote, _socks]),
    ])..addSession('s1', 'alpha', manager);
    await _open(tester, source);

    await tester.tap(_key('r7fwd-toggle-alpha-r1'));
    await _settle(tester);
    expect(manager.activeProfileIds, ['r1']);
    expect((client.remoteBindHost, client.remoteBindPort), ('127.0.0.1', 9000));
    final inbound = FakeSshForwardChannel();
    client.remoteForward!.incoming.add(inbound);
    final device = await _wait(tester, reached.future);
    await _settle(tester);
    expect(find.text('Running · 1 active · 1 total'), findsOneWidget);

    await tester.tap(_key('r7fwd-toggle-alpha-d1'));
    await _settle(tester);
    final socksPort = manager.activeListeningPort('d1')!;
    final socks = (await tester.runAsync(
      () => Socket.connect(InternetAddress.loopbackIPv4, socksPort),
    ))!;
    final replies = StreamIterator(socks);
    Future<List<int>> next() async {
      await replies.moveNext();
      return replies.current;
    }

    socks.add([5, 1, 0]);
    expect(await _wait(tester, next()), [5, 0]);
    const name = 'intranet.test';
    socks.add([5, 1, 0, 3, name.length, ...name.codeUnits, 0, 80]);
    final reply = await _wait(tester, next());
    expect(reply.take(2), [5, 0]);
    expect(client.dials.last, (name, 80));
    expect(manager.activeProfileIds.toSet(), {'r1', 'd1'});

    // Stop from the page.
    await tester.tap(_key('r7fwd-toggle-alpha-r1'));
    await _settle(tester);
    expect(manager.activeProfileIds, ['d1']);
    expect(client.remoteCancelCount, 1);
    await tester.runAsync(() async {
      await socks.close();
      device.destroy();
      await destination.close();
    });
    await _cleanup(tester, [manager]);
  });

  testWidgets('connect and start runs only on the session that '
      'authenticated for that host', (tester) async {
    final source = _Source([_alpha, _beta]);
    final controller = await _open(tester, source);
    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await tester.pump();
    expect(source.connects, ['alpha']);
    expect(find.text('Connecting… the rule starts after authentication'),
        findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);

    // An unrelated session of another host appears meanwhile.
    final other = SshPortForwardManager(FakeForwardingSshClient());
    source.addSession('b1', 'beta', other);
    // The new authenticated session of this host.
    final client = FakeForwardingSshClient();
    final fresh = SshPortForwardManager(client);
    source.addSession('a-new', 'alpha', fresh);
    source.connectGate!.complete('a-new');
    await _settle(tester);
    expect(fresh.activeProfileIds, ['l1']);
    expect(other.runningCount, 0);
    expect(controller.selectedSessionId('alpha'), 'a-new');
    expect(find.textContaining('Running · 0 active'), findsOneWidget);
    await _cleanup(tester, [other, fresh]);
  });

  testWidgets('connect and start never starts without an authenticated, '
      'matching, unchanged result', (tester) async {
    final source = _Source([_alpha, _beta]);
    final controller = await _open(tester, source);
    final managers = <SshPortForwardManager>[];

    Future<void> attempt() async {
      await tester.tap(_key('r7fwd-toggle-alpha-l1'));
      await tester.pump();
      expect(controller.isConnecting('alpha', 'l1'), isTrue);
    }

    String note() =>
        tester.widget<Text>(_key('r7fwd-note-alpha-l1')).data ?? '';

    // Cancelled / rejected host key / failed auth.
    await attempt();
    source.connectGate!.complete(null);
    await _settle(tester);
    expect(note(), contains('not completed'));

    // Connect flow threw (e.g. host-key verification failure).
    await attempt();
    source.connectGate!.completeError(StateError('host key rejected'));
    await _settle(tester);
    expect(note(), contains('not completed'));
    expect(find.textContaining('host key rejected'), findsNothing);

    // The returned session belongs to another host.
    await attempt();
    final wrong = SshPortForwardManager(FakeForwardingSshClient());
    managers.add(wrong);
    source.addSession('b1', 'beta', wrong);
    source.connectGate!.complete('b1');
    await _settle(tester);
    expect(wrong.runningCount, 0);
    expect(note(), contains('not completed'));

    // The rule was edited while connecting (revision changed).
    await attempt();
    source.replaceRules('alpha', [_local.copyWith(bindPort: 15432), _socks]);
    final mine = SshPortForwardManager(FakeForwardingSshClient());
    managers.add(mine);
    source.addSession('a1', 'alpha', mine);
    source.connectGate!.complete('a1');
    await _settle(tester);
    expect(mine.runningCount, 0);
    expect(note(), contains('changed or was removed'));
    source.sessionList.clear();
    source.signal();
    await tester.pump();

    // Vault/profile switched while connecting.
    await attempt();
    source.scope = 'vault-2';
    final switched = SshPortForwardManager(FakeForwardingSshClient());
    managers.add(switched);
    source.addSession('a2', 'alpha', switched);
    source.connectGate!.complete('a2');
    await _settle(tester);
    expect(switched.runningCount, 0);
    expect(controller.isConnecting('alpha', 'l1'), isFalse);
    source.sessionList.clear();
    source.signal();
    await tester.pump();

    // User cancelled the pending start; the connection stays a plain session.
    await attempt();
    await tester.tap(_key('r7fwd-cancel-alpha-l1'));
    await tester.pump();
    expect(note(), contains('Start cancelled'));
    final kept = SshPortForwardManager(FakeForwardingSshClient());
    managers.add(kept);
    source.addSession('a3', 'alpha', kept);
    source.connectGate!.complete('a3');
    await _settle(tester);
    expect(kept.runningCount, 0);
    await _cleanup(tester, managers);
  });

  testWidgets('exposed rules confirm before connecting or starting', (
    tester,
  ) async {
    final source = _Source([
      _alpha.copyWith(portForwardProfiles: [_exposed]),
    ]);
    await _open(tester, source);
    await tester.tap(_key('r7fwd-toggle-alpha-x1'));
    await tester.pumpAndSettle();
    expect(_key('ssh-forward-exposure-confirm'), findsOneWidget);
    await tester.tap(_key('ssh-forward-exposure-cancel'));
    await tester.pumpAndSettle();
    expect(source.connects, isEmpty);
    await tester.tap(_key('r7fwd-toggle-alpha-x1'));
    await tester.pumpAndSettle();
    await tester.tap(_key('ssh-forward-exposure-accept'));
    await tester.pump();
    expect(source.connects, ['alpha']);
    source.connectGate!.complete(null);
    await _settle(tester);
    await _cleanup(tester, const []);
  });

  testWidgets('several sessions of one host need an explicit target; other '
      'sessions and orphaned forwards stay visible with Stop', (tester) async {
    final first = SshPortForwardManager(FakeForwardingSshClient());
    final second = SshPortForwardManager(FakeForwardingSshClient());
    final source = _Source([_alpha])
      ..addSession('s1', 'alpha', first)
      ..addSession('s2', 'alpha', second)
      ..addSession(
        's3',
        'alpha',
        SshPortForwardManager(FakeForwardingSshClient()),
        phase: SshForwardingSessionPhase.disconnected,
      );
    final controller = await _open(tester, source);
    expect(find.text('2 sessions'), findsOneWidget);
    expect(_toggle(tester, 'alpha-l1').onPressed, isNull);
    expect(_toggle(tester, 'alpha-l1').tooltip,
        'Choose a session to start rules on');

    await tester.tap(_key('r7fwd-session-select-alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tab s2').last);
    await tester.pumpAndSettle();
    expect(controller.selectedSessionId('alpha'), 's2');
    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await _settle(tester);
    expect(second.activeProfileIds, ['l1']);
    expect(first.runningCount, 0);
    expect(source.connects, isEmpty);

    // Switch the target: the rule still shows (and can stop) on s2.
    controller.selectSession('alpha', 's1');
    await tester.pump();
    expect(_key('r7fwd-other-alpha-l1-s2'), findsOneWidget);
    expect(find.textContaining('On tab s2: Running'), findsOneWidget);
    await tester.tap(_key('r7fwd-other-stop-alpha-l1-s2'));
    await _settle(tester);
    expect(second.runningCount, 0);

    // A forward whose rule was removed (sync/revision) keeps a Stop.
    await tester.runAsync(
      () => first.start(_socks.copyWith(name: 'Old SOCKS')),
    );
    source.replaceRules('alpha', [_local]);
    await _settle(tester);
    expect(_key('r7fwd-orphan-s1-d1'), findsOneWidget);
    await tester.tap(_key('r7fwd-orphan-stop-s1-d1'));
    await _settle(tester);
    expect(first.runningCount, 0);
    expect(_key('r7fwd-orphan-s1-d1'), findsNothing);

    // Forwards of a host that left the scope stay visible too.
    await tester.runAsync(() => second.start(_local));
    source.hostList = const [_beta];
    source.signal();
    await _settle(tester);
    expect(_key('r7fwd-removed-s2'), findsOneWidget);
    await tester.tap(_key('r7fwd-orphan-stop-s2-l1'));
    await _settle(tester);
    expect(second.runningCount, 0);
    await _cleanup(tester, [first, second]);
  });

  testWidgets('a session that is still connecting blocks a second connect', (
    tester,
  ) async {
    final source = _Source([_alpha])
      ..sessionList.add(
        const SshForwardingSessionInfo(
          id: 'c1',
          hostId: 'alpha',
          label: 'tab c1',
          phase: SshForwardingSessionPhase.connecting,
        ),
      );
    await _open(tester, source);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(_toggle(tester, 'alpha-l1').onPressed, isNull);
    expect(_toggle(tester, 'alpha-l1').tooltip,
        'Wait until the session finishes connecting');
    await _cleanup(tester, const []);
  });

  testWidgets('unsupported runtime never opens a connection', (tester) async {
    final source = _Source([_alpha]);
    final controller = await _open(
      tester,
      source,
      controller: SshForwardingController(
        runtimeSupported: false,
        unsupportedReason: 'This browser cannot open TCP listeners.',
      ),
    );
    expect(find.text('This browser cannot open TCP listeners.'), findsOneWidget);
    expect(_key('r7fwd-toggle-alpha-l1'), findsNothing);
    await controller.start(source, 'alpha', 'l1');
    expect(source.connects, isEmpty);
    expect(
      controller.noteOf('alpha', 'l1'),
      'This browser cannot open TCP listeners.',
    );
    await _cleanup(tester, const []);
  });

  testWidgets('scope change drops session choices and pending starts', (
    tester,
  ) async {
    final source = _Source([_alpha]);
    final controller = await _open(tester, source);
    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await tester.pump();
    expect(controller.isConnecting('alpha', 'l1'), isTrue);
    source.scope = 'profile-2';
    source.signal();
    await tester.pump();
    expect(controller.isConnecting('alpha', 'l1'), isFalse);
    final manager = SshPortForwardManager(FakeForwardingSshClient());
    source.addSession('a1', 'alpha', manager);
    source.connectGate!.complete('a1');
    await _settle(tester);
    expect(manager.runningCount, 0);
    await _cleanup(tester, [manager]);
  });

  testWidgets('a save after the scope changed under the open editor is '
      'refused and nothing is written', (tester) async {
    final source = _Source([_alpha]);
    await _open(tester, source);
    await _menu(tester, 'alpha-l1', 'r7fwd-edit');
    source.scope = Object();
    await tester.enterText(_key('ssh-forward-profile-name'), 'Other vault');
    await tester.tap(_key('ssh-forward-profile-save'));
    await tester.pumpAndSettle();
    expect(source.saves, isEmpty);
    expect(_key('r7fwd-error'), findsOneWidget);
    await _cleanup(tester, const []);
  });

  testWidgets('intentional connect and start completes after the page was '
      'left for the terminal', (tester) async {
    final source = _Source([_alpha]);
    final controller = SshForwardingController(
      runtimeSupported: true,
      source: source,
    );
    await _open(tester, source, controller: controller);
    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await tester.pump();
    // The shell shows the new SSH tab; the page is gone.
    await tester.pumpWidget(const SizedBox.shrink());
    final manager = SshPortForwardManager(FakeForwardingSshClient());
    source.addSession('a1', 'alpha', manager);
    source.connectGate!.complete('a1');
    await _settle(tester);
    expect(manager.activeProfileIds, ['l1']);
    controller.dispose();
    await _cleanup(tester, [manager]);
  });

  testWidgets('A -> B -> A scope switch while hidden never starts on the new '
      'scope', (tester) async {
    final scopeA = Object();
    final source = _Source([_alpha])..scope = scopeA;
    final controller = SshForwardingController(
      runtimeSupported: true,
      source: source,
    );
    await _open(tester, source, controller: controller);
    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    // Lock/switch to B and back to A: a new lifetime token for A.
    source.scope = Object();
    source.signal();
    expect(controller.isConnecting('alpha', 'l1'), isFalse);
    source.scope = Object();
    source.signal();
    final manager = SshPortForwardManager(FakeForwardingSshClient());
    source.addSession('a1', 'alpha', manager);
    source.connectGate!.complete('a1');
    await _settle(tester);
    expect(manager.runningCount, 0);

    // Even without any notification, completion re-checks the scope token.
    final silent = SshForwardingController(runtimeSupported: true);
    source.sessionList.clear();
    final pending = silent.start(source, 'alpha', 'l1');
    expect(silent.isConnecting('alpha', 'l1'), isTrue);
    source.scope = Object();
    final other = SshPortForwardManager(FakeForwardingSshClient());
    source.sessionList.add(
      SshForwardingSessionInfo(
        id: 'a2',
        hostId: 'alpha',
        label: 'tab a2',
        phase: SshForwardingSessionPhase.connected,
        manager: other,
      ),
    );
    source.connectGate!.complete('a2');
    await _wait(tester, pending);
    expect(other.runningCount, 0);
    expect(silent.noteOf('alpha', 'l1'), contains('vault or profile changed'));
    silent.dispose();
    controller.dispose();
    await _cleanup(tester, [manager, other]);
  });

  testWidgets('delete confirmation is bound to its scope and exact rule', (
    tester,
  ) async {
    final client = FakeForwardingSshClient();
    final manager = SshPortForwardManager(client);
    final source = _Source([_alpha])..addSession('s1', 'alpha', manager);
    await _open(tester, source);
    await tester.tap(_key('r7fwd-toggle-alpha-l1'));
    await _settle(tester);
    expect(manager.activeProfileIds, ['l1']);

    // Scope flips (e.g. to a cloned Vault with a same-id rule) while the
    // confirmation is open: nothing is stopped or deleted.
    await _menu(tester, 'alpha-l1', 'r7fwd-delete');
    source.scope = Object();
    await tester.tap(_key('r7fwd-delete-accept'));
    await _settle(tester);
    expect(manager.activeProfileIds, ['l1']);
    expect(source.saves, isEmpty);
    expect(find.textContaining('vault or profile changed'), findsOneWidget);

    // Same scope, but the rule was edited elsewhere meanwhile.
    await _menu(tester, 'alpha-d1', 'r7fwd-delete');
    source.replaceRules('alpha', [_local, _socks.copyWith(bindPort: 1080)]);
    await tester.tap(_key('r7fwd-delete-accept'));
    await _settle(tester);
    expect(source.saves, isEmpty);
    expect(
      source.hostList.single.portForwardProfiles.map((p) => p.id),
      ['l1', 'd1'],
    );
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    await _cleanup(tester, [manager]);
  });

  testWidgets('exposure approval never starts a rule that changed while the '
      'confirmation was open', (tester) async {
    final manager = SshPortForwardManager(FakeForwardingSshClient());
    final source = _Source([
      _alpha.copyWith(portForwardProfiles: [_exposed]),
    ])..addSession('s1', 'alpha', manager);
    final controller = await _open(tester, source);
    await tester.tap(_key('r7fwd-toggle-alpha-x1'));
    await tester.pumpAndSettle();
    expect(_key('ssh-forward-exposure-confirm'), findsOneWidget);
    // Another device widens the same rule meanwhile.
    source.replaceRules('alpha', [_exposed.copyWith(bindPort: 1080)]);
    await tester.tap(_key('ssh-forward-exposure-accept'));
    await _settle(tester);
    expect(manager.runningCount, 0);
    expect(controller.noteOf('alpha', 'x1'), contains('changed or was removed'));

    // Scope flip while approving: no start, and no connection either.
    source.sessionList.clear();
    source.signal();
    await tester.pump();
    await tester.tap(_key('r7fwd-toggle-alpha-x1'));
    await tester.pumpAndSettle();
    source.scope = Object();
    await tester.tap(_key('ssh-forward-exposure-accept'));
    await _settle(tester);
    expect(source.connects, isEmpty);
    await _cleanup(tester, [manager]);
  });

  testWidgets('an editor save never overwrites a rule changed while the '
      'editor was open', (tester) async {
    final source = _Source([_alpha]);
    await _open(tester, source);
    await _menu(tester, 'alpha-l1', 'r7fwd-edit');
    source.replaceRules('alpha', [_local.copyWith(name: 'Changed on phone'), _socks]);
    await tester.enterText(_key('ssh-forward-profile-name'), 'Mine');
    await tester.tap(_key('ssh-forward-profile-save'));
    await tester.pumpAndSettle();
    expect(source.saves, isEmpty);
    expect(source.hostList.single.portForwardProfiles.first.name,
        'Changed on phone');
    expect(find.textContaining('changed elsewhere'), findsOneWidget);
    await _cleanup(tester, const []);
  });
}
