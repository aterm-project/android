import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store_io.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const ro = McpAccessMode.readOnly;
const rw = McpAccessMode.readWrite;
const denied = McpAccessMode.denied;

Map<String, dynamic> rpc(
  String method, {
  Object id = 1,
  Map<String, dynamic> params = const {},
}) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};
Map<String, dynamic> call(
  String name, [
  Map<String, dynamic> args = const {},
  Object id = 1,
]) => rpc('tools/call', id: id, params: {'name': name, 'arguments': args});
Map content(McpReply reply) =>
    (reply.body!['result'] as Map)['structuredContent'] as Map;
String? errorOf(McpReply reply) => content(reply)['error'] as String?;
List<String> ids(Map listing) => [
  for (final row in listing['items'] as List) (row as Map)['id'] as String,
];

void main() {
  group('policy model', () {
    test('codec round-trips and binds the stored value to its scope', () {
      final policy = McpAccessPolicy(
        defaultAccess: denied,
        overrides: {'h1': rw, mcpLocalDeviceHostId: ro},
      );
      final raw = policy.encode('local:p1');
      expect(McpAccessPolicy.decode(raw, 'local:p1'), policy);
      // A file copied into another profile/account/Vault scope is rejected.
      expect(
        () => McpAccessPolicy.decode(raw, 'local:p2'),
        throwsA(isA<McpAccessPolicyFormatException>()),
      );
      for (final bad in [
        '',
        'null',
        '[]',
        '{"version":1,"scope":"local:p1","default":"read_write"}',
        '{"version":2,"scope":"local:p1","default":"denied","hosts":{}}',
        '{"version":1,"scope":"local:p1","default":"admin","hosts":{}}',
        '{"version":1,"scope":"local:p1","default":"denied","hosts":{"h":"all"}}',
        '{"version":1,"scope":"local:p1","default":"denied","hosts":{"":"read_only"}}',
        '{"version":1,"scope":"local:p1","default":"denied","hosts":[]}',
        '{"version":1,"scope":"local:p1","default":"denied","hosts":{},"x":1}',
        'x' * (mcpAccessPolicyMaxStoredBytes + 1),
      ]) {
        expect(
          () => McpAccessPolicy.decode(bad, 'local:p1'),
          throwsA(isA<McpAccessPolicyFormatException>()),
          reason: bad.length > 80 ? 'oversized' : bad,
        );
      }
    });

    test('unattributable sessions are denied whatever the default', () {
      final policy = McpAccessPolicy(defaultAccess: rw);
      expect(policy.effective(null), denied);
      expect(policy.effective('anything'), rw);
      final console = _session('c1', kind: 'console');
      final orphan = _session('o1', kind: 'ssh');
      final spoof = _session('s1', kind: 'ssh', hostId: mcpLocalDeviceHostId);
      expect(console.accessHostId, mcpLocalDeviceHostId);
      expect(orphan.accessHostId, isNull);
      expect(spoof.accessHostId, isNull);
    });

    test('meet is the per-host minimum and reducedBy detects revocation', () {
      final a = McpAccessPolicy(defaultAccess: rw, overrides: {'h1': denied});
      final b = McpAccessPolicy(defaultAccess: ro, overrides: {'h2': rw});
      final m = McpAccessPolicy.meet(a, b);
      expect(m.effective('h1'), denied);
      expect(m.effective('h2'), rw);
      expect(m.effective('other'), ro);
      expect(a.reducedBy(b), isTrue);
      expect(m.reducedBy(a), isFalse);
      expect(b.reducedBy(b.withHost('h2', null)), isTrue);
    });
  });

  group('file store', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('atermius-mcp-policy-');
    });
    tearDown(() => root.delete(recursive: true));

    test(
      'persists per scope without revealing the scope in file names',
      () async {
        final store = FileMcpAccessPolicyStore(directory: () async => root);
        expect(await store.read('cloud:i:s:account-7:vault-9'), isNull);
        final policy = McpAccessPolicy(
          defaultAccess: denied,
          overrides: {'h': rw},
        );
        await store.write('cloud:i:s:account-7:vault-9', policy);
        expect(await store.read('cloud:i:s:account-7:vault-9'), policy);
        expect(await store.read('cloud:i:s:account-7:vault-8'), isNull);
        final names = root
            .listSync(recursive: true)
            .map((e) => e.path.substring(root.path.length))
            .join('\n');
        expect(names, isNot(contains('account-7')));
        expect(names, isNot(contains('vault-9')));
        // Fresh store instance (application restart) reads the same choice.
        expect(
          await FileMcpAccessPolicyStore(directory: () async => root)
              .read('cloud:i:s:account-7:vault-9'),
          policy,
        );
      },
    );

    test('corrupt, swapped or non-file entries fail closed', () async {
      final store = FileMcpAccessPolicyStore(directory: () async => root);
      await store.write('local:a', McpAccessPolicy(defaultAccess: rw));
      await store.write('local:b', McpAccessPolicy(defaultAccess: denied));
      final files = Directory('${root.path}/mcp-access-v1')
          .listSync()
          .whereType<File>()
          .toList();
      expect(files, hasLength(2));
      // Copy b's (denied) file over a's: the embedded scope rejects it.
      final a = files.firstWhere(
        (f) => f.readAsStringSync().contains('"local:a"'),
      );
      final b = files.firstWhere((f) => f != a);
      a.writeAsStringSync(b.readAsStringSync());
      expect(store.read('local:a'), throwsA(isA<Object>()));
      a.writeAsStringSync('{not json');
      expect(store.read('local:a'), throwsA(isA<Object>()));
      a.deleteSync();
      Directory(a.path).createSync();
      expect(store.read('local:a'), throwsA(isA<Object>()));
    });
  });

  group('service policy state', () {
    test(
      'locked/unloaded is denied; unconfigured defaults to read-only',
      () async {
        final f = _Fixture()..scope = null;
        final service = f.service();
        expect(service.permissionsReady, isFalse);
        expect(service.permissionHosts, isEmpty);
        expect(service.effectiveAccessForHost('h-a'), denied);
        expect(service.defaultAccess, denied);
        f.scope = 'local:p1';
        service.workspaceChanged();
        expect(service.permissionsLoading, isTrue);
        expect(service.effectiveAccessForHost('h-a'), denied);
        await f.settle(service);
        expect(service.permissionsReady, isTrue);
        expect(service.defaultAccess, mcpDefaultAccessWhenUnconfigured);
        expect(service.effectiveAccessForHost('h-a'), ro);
        expect(service.permissionHosts.map((h) => h.id), ['h-a', 'h-b', 'h-c']);
        expect(service.localDeviceAccessApplicable, isTrue);
        service.dispose();
      },
    );

    test(
      'choices persist per scope and never leak into another scope',
      () async {
        final f = _Fixture();
        final service = f.service();
        await f.settle(service);
        await service.setDefaultAccess(denied);
        await service.setHostAccess('h-a', rw);
        await service.setHostAccess(mcpLocalDeviceHostId, ro);
        expect(service.effectiveAccessForHost('h-a'), rw);
        expect(service.effectiveAccessForHost('h-b'), denied);
        expect(service.accessOverrideForHost('h-b'), isNull);
        expect(service.accessOverrideForHost('h-a'), rw);

        // Another profile/Vault: its own (unconfigured) policy, not ours.
        f.scope = 'local:p2';
        service.workspaceChanged();
        expect(service.effectiveAccessForHost('h-a'), denied);
        await f.settle(service);
        expect(service.effectiveAccessForHost('h-a'), ro);
        expect(service.effectiveAccessForHost('h-b'), ro);

        // Back, and in a brand-new service (restart): restored from the store.
        f.scope = 'local:p1';
        service.workspaceChanged();
        await f.settle(service);
        expect(service.effectiveAccessForHost('h-a'), rw);
        final restarted = f.service();
        await f.settle(restarted);
        expect(restarted.defaultAccess, denied);
        expect(restarted.effectiveAccessForHost('h-a'), rw);
        expect(restarted.effectiveAccessForHost(mcpLocalDeviceHostId), ro);
        // Inherit again.
        await restarted.setHostAccess('h-a', null);
        expect(restarted.effectiveAccessForHost('h-a'), denied);
        service.dispose();
        restarted.dispose();
      },
    );

    test('unreadable or unavailable store denies everything', () async {
      final f = _Fixture();
      f.store.readError = const McpAccessPolicyStoreUnavailable();
      final service = f.service();
      await f.settle(service);
      expect(service.permissionsError, isTrue);
      expect(service.permissionsReady, isFalse);
      expect(service.effectiveAccessForHost('h-a'), denied);
      expect(service.permissionHosts, isEmpty);
      await expectLater(
        service.setHostAccess('h-a', rw),
        throwsA(isA<McpPermissionsUnavailable>()),
      );
      await expectLater(
        service.start(port: 0),
        throwsA(isA<McpPermissionsUnavailable>()),
      );
      expect(service.running, isFalse);
      f.store.readError = null;
      f.store.raw['local:p1'] = '{garbage';
      await service.reloadPermissions();
      expect(service.permissionsError, isTrue);
      f.store.raw.remove('local:p1');
      await service.reloadPermissions();
      expect(service.permissionsReady, isTrue);
      service.dispose();
    });

    test('restrictions apply before persistence; grants only after', () async {
      final f = _Fixture();
      final service = f.service();
      await f.settle(service);
      await service.setHostAccess('h-a', rw);
      f.store.gate = Completer<void>();
      final revoke = service.setHostAccess('h-a', denied);
      expect(service.effectiveAccessForHost('h-a'), denied);
      expect(service.permissionsSaving, isTrue);
      f.store.gate!.complete();
      await revoke;
      f.store.gate = Completer<void>();
      final grant = service.setHostAccess('h-b', rw);
      // Shown as chosen, but not enforced until saved.
      expect(service.accessOverrideForHost('h-b'), rw);
      expect(service.effectiveAccessForHost('h-b'), ro);
      f.store.gate!.complete();
      await grant;
      expect(service.effectiveAccessForHost('h-b'), rw);

      // A failed save keeps the restriction in force and reports the error.
      f.store.writeError = const FileSystemException('disk full');
      await expectLater(
        service.setDefaultAccess(denied),
        throwsA(isA<FileSystemException>()),
      );
      expect(service.effectiveAccessForHost('h-c'), denied);
      await expectLater(
        service.setHostAccess('h-b', ro),
        throwsA(isA<FileSystemException>()),
      );
      expect(service.effectiveAccessForHost('h-b'), ro);
      f.store.writeError = null;
      await service.setDefaultAccess(ro);
      expect(service.effectiveAccessForHost('h-c'), ro);
      service.dispose();
    });

    test('legacy allowOperations cannot bypass a per-host override', () async {
      final f = _Fixture();
      final service = f.service();
      await f.settle(service);
      await service.setHostAccess('h-b', denied);
      service.setAllowOperations(true);
      await f.settle(service);
      expect(service.allowOperations, isTrue);
      expect(service.effectiveAccessForHost('h-a'), rw);
      expect(service.effectiveAccessForHost('h-b'), denied);
      service.dispose();
    });
  });

  group('real tool dispatch', () {
    late _Fixture f;
    late McpService service;
    late McpProtocol protocol;
    setUp(() async {
      f = _Fixture();
      service = f.service();
      await f.settle(service);
      await service.setDefaultAccess(denied);
      await service.setHostAccess('h-a', rw);
      await service.setHostAccess('h-b', ro);
      await service.setHostAccess(mcpLocalDeviceHostId, denied);
      protocol = McpProtocol(
        workspace: f.workspace,
        validateAccess: () {},
        access: (host) =>
            host == null ? denied : service.effectiveAccessForHost(host),
      );
    });
    tearDown(() => service.dispose());

    test(
      'denied machines are absent from hosts, sessions and counters',
      () async {
        final hosts = content(await protocol.handle(call('hosts_list')));
        expect(ids(hosts), ['h-a', 'h-b']);
        expect(hosts['total'], 2);
        expect(
          [for (final h in hosts['items'] as List) (h as Map)['access']],
          ['read_write', 'read_only'],
        );
        final sessions = content(await protocol.handle(call('sessions_list')));
        // s-c (denied host), console (denied local device) and the
        // unattributable orphan are all hidden.
        expect(ids(sessions), ['s-a', 's-b']);
        expect(sessions['total'], 2);
        final status = content(await protocol.handle(call('workspace_status')));
        expect(status['hosts'], 2);
        expect(status['sessions'], 2);
        expect(status['local_device_access'], 'denied');
        final encoded = jsonEncode([hosts, sessions, status]);
        for (final secret in [
          'h-c',
          's-c',
          'hidden.example',
          'console-1',
          'orphan',
        ]) {
          expect(encoded, isNot(contains(secret)));
        }
      },
    );

    test(
      'direct-ID calls on denied machines look exactly like unknown IDs',
      () async {
        for (final id in ['s-c', 'console-1', 'orphan']) {
          for (final (tool, args) in [
            ('terminal_read', <String, dynamic>{}),
            ('terminal_write', {'text': 'id\n'}),
            ('ssh_exec', {'command': 'id'}),
            ('session_focus', <String, dynamic>{}),
            ('session_close', <String, dynamic>{}),
            ('sftp_list', {'path': '/'}),
            ('sftp_read_text', {'path': '/etc/hosts'}),
            (
              'sftp_write_text',
              {'path': '/tmp/x', 'text': 'x', 'mode': 'create'},
            ),
          ]) {
            final denied = await protocol.handle(
              call(tool, {'session_id': id, ...args}),
            );
            final unknown = await protocol.handle(
              call(tool, {'session_id': 'no-such-session', ...args}),
            );
            expect(content(denied), content(unknown), reason: '$tool $id');
            expect(errorOf(denied), 'session_unavailable');
          }
        }
        final connect = await protocol.handle(
          call('host_connect', {'host_id': 'h-c'}),
        );
        final unknown = await protocol.handle(
          call('host_connect', {'host_id': 'nope'}),
        );
        expect(content(connect), content(unknown));
        expect(
          errorOf(await protocol.handle(call('console_open'))),
          'access_denied',
        );
        for (final s in f.sessions.where(
          (s) => s.id != 's-a' && s.id != 's-b',
        )) {
          expect(s.events, isEmpty, reason: s.id);
        }
        expect(f.connects, isEmpty);
        expect(f.consoleOpens, 0);
      },
    );

    test('read-only allows reads but no connect/focus/close/input/exec/writes', () async {
      final read = await protocol.handle(
        call('terminal_read', {'session_id': 's-b'}),
      );
      expect(content(read)['text'], contains('banner s-b'));
      // Authorized SFTP listing proceeds to the connection (fixture has none).
      final list = await protocol.handle(
        call('sftp_list', {'session_id': 's-b', 'path': '/'}),
      );
      expect(errorOf(list), 'operation_failed');
      expect(f.byId('s-b').connection.clientTouches, 1);
      for (final (tool, args) in [
        ('terminal_write', {'text': 'reboot\n'}),
        ('ssh_exec', {'command': 'reboot'}),
        ('session_focus', <String, dynamic>{}),
        ('session_close', <String, dynamic>{}),
        ('sftp_write_text', {'path': '/tmp/x', 'text': 'x', 'mode': 'create'}),
      ]) {
        final reply = await protocol.handle(
          call(tool, {'session_id': 's-b', ...args}),
        );
        expect(errorOf(reply), 'read_only', reason: tool);
      }
      expect(
        errorOf(
          await protocol.handle(call('host_connect', {'host_id': 'h-b'})),
        ),
        'read_only',
      );
      final s = f.byId('s-b');
      expect(s.events, isEmpty);
      expect(s.connection.commands, isEmpty);
      // The write was refused before any SFTP channel was opened.
      expect(s.connection.clientTouches, 1);
      expect(f.connects, isEmpty);
      // The session's machine comes from the live workspace; a caller cannot
      // name a different host for a session tool.
      final spoof = await protocol.handle(
        call('terminal_write', {
          'session_id': 's-b',
          'host_id': 'h-a',
          'text': 'x',
        }),
      );
      expect(spoof.status, 400);
    });

    test('read-write performs supported actions', () async {
      expect(
        content(
          await protocol.handle(
            call('terminal_write', {'session_id': 's-a', 'text': 'uptime\n'}),
          ),
        )['sent'],
        isTrue,
      );
      expect(
        content(
          await protocol.handle(
            call('ssh_exec', {'session_id': 's-a', 'command': 'id'}),
          ),
        )['stdout'],
        'ok',
      );
      final opened = content(
        await protocol.handle(call('host_connect', {'host_id': 'h-a'})),
      );
      expect((opened['sessions'] as List).single['access'], 'read_write');
      final s = f.byId('s-a');
      expect(s.events, ['input:uptime\n']);
      expect(s.connection.commands, ['id']);
      expect(f.connects, ['h-a']);
      await service.setHostAccess(mcpLocalDeviceHostId, rw);
      final console = content(await protocol.handle(call('console_open')));
      expect((console['sessions'] as List).single['kind'], 'console');
      expect(
        ids(content(await protocol.handle(call('sessions_list')))),
        containsAll(['console-1', 'console-2']),
      );
    });

    test(
      'revocation during a call cancels it and suppresses its result',
      () async {
        final s = f.byId('s-a');
        s.connection.waitForCancellation = true;
        final pending = protocol.handle(
          call('ssh_exec', {'session_id': 's-a', 'command': 'sleep 60'}),
        );
        await Future<void>.delayed(Duration.zero);
        await service.setHostAccess('h-a', ro);
        protocol.revalidate(); // the service does this for its own protocol
        final reply = await pending;
        expect(errorOf(reply), 'access_revoked');
        expect(content(reply), isNot(contains('stdout')));
        expect(s.connection.cancelled, isTrue);

        // host_connect: grant revoked while the app is still connecting.
        await service.setHostAccess('h-a', rw);
        f.connectGate = Completer<void>();
        final connecting = protocol.handle(
          call('host_connect', {'host_id': 'h-a'}, 2),
        );
        await Future<void>.delayed(Duration.zero);
        await service.setHostAccess('h-a', denied);
        f.connectGate!.complete();
        expect(errorOf(await connecting), 'access_revoked');
      },
    );
  });

  group('service over the real loopback listener', () {
    test('filters, enforces and revokes through the live endpoint', () async {
      final f = _Fixture();
      final service = f.service();
      final http = HttpClient();
      try {
        await f.settle(service);
        await service.setDefaultAccess(denied);
        await service.setHostAccess('h-a', rw);
        await service.start(port: 0);
        final config = jsonDecode(service.connectionConfiguration()) as Map;
        final auth =
            config['mcpServers']['atermius']['headers']['Authorization']
                as String;
        Future<Map> post(Map body) async {
          final request = await http.postUrl(service.endpoint!);
          request.headers.contentType = ContentType.json;
          request.headers.set('Accept', 'application/json, text/event-stream');
          request.headers.set('Authorization', auth);
          request.write(jsonEncode(body));
          final response = await request.close();
          return jsonDecode(await utf8.decodeStream(response)) as Map;
        }

        Map structured(Map reply) =>
            reply['result']['structuredContent'] as Map;
        expect(ids(structured(await post(call('sessions_list')))), ['s-a']);
        expect(ids(structured(await post(call('hosts_list')))), ['h-a']);
        expect(
          structured(
            await post(call('terminal_read', {'session_id': 's-b'})),
          )['error'],
          'session_unavailable',
        );

        // Revoke while an exec is in flight over HTTP: the service itself
        // cancels the call and no output is released.
        final s = f.byId('s-a');
        s.connection.waitForCancellation = true;
        final pending = post(
          call('ssh_exec', {'session_id': 's-a', 'command': 'sleep 60'}, 7),
        );
        for (var i = 0; i < 50 && s.connection.commands.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(s.connection.commands, ['sleep 60']);
        await service.setHostAccess('h-a', ro);
        final revoked = structured(await pending);
        expect(revoked['error'], 'access_revoked');
        expect(s.connection.cancelled, isTrue);
        expect(
          structured(
            await post(
              call('terminal_write', {'session_id': 's-a', 'text': 'x'}),
            ),
          )['error'],
          'read_only',
        );
        expect(s.events, isEmpty);

        // Grant takes effect without a new token; lock fences everything.
        await service.setHostAccess('h-b', ro);
        expect(ids(structured(await post(call('sessions_list')))), [
          's-a',
          's-b',
        ]);
        f.scope = null;
        expect(service.permissionHosts, isEmpty);
        expect(service.effectiveAccessForHost('h-a'), denied);
        final locked = await post(call('sessions_list'));
        expect(locked['error'], isNotNull);
      } finally {
        http.close(force: true);
        await service.stop();
        service.dispose();
      }
    });
  });
}

McpSession _session(String id, {required String kind, String? hostId}) =>
    McpSession(
      id: id,
      name: id,
      kind: kind,
      hostId: hostId,
      state: 'connected',
      isAlive: () => true,
      focus: () {},
      close: () async {},
      input: (_) {},
    );

class _GatedStore extends MemoryMcpAccessPolicyStore {
  Completer<void>? gate;
  @override
  Future<void> write(String scope, McpAccessPolicy policy) async {
    final pending = gate;
    if (pending != null) await pending.future;
    return super.write(scope, policy);
  }
}

class _FakeSession {
  _FakeSession(this.id, this.kind, this.hostId) {
    terminal.write('banner $id\r\n');
  }
  final String id, kind;
  final String? hostId;
  final terminal = Terminal(maxLines: 100);
  final connection = _Connection();
  final events = <String>[];
  bool closed = false;
}

class _Fixture {
  String? scope = 'local:p1';
  final store = _GatedStore();
  final connects = <String>[];
  int consoleOpens = 0;
  Completer<void>? connectGate;
  final hosts = [
    const HostRecord(id: 'h-a', name: 'alpha', address: 'alpha.example'),
    const HostRecord(id: 'h-b', name: 'beta', address: 'beta.example'),
    const HostRecord(id: 'h-c', name: 'hidden', address: 'hidden.example'),
  ];
  late final sessions = [
    _FakeSession('s-a', 'ssh', 'h-a'),
    _FakeSession('s-b', 'ssh', 'h-b'),
    _FakeSession('s-c', 'ssh', 'h-c'),
    _FakeSession('console-1', 'console', null),
    _FakeSession('orphan', 'ssh', null),
  ];
  _FakeSession byId(String id) => sessions.firstWhere((s) => s.id == id);

  McpService service() => McpService(policyStore: store)..attach(workspace);

  Future<void> settle(McpService service) async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(service.permissionsLoading, isFalse);
  }

  McpSession _view(_FakeSession s) => McpSession(
    id: s.id,
    name: s.id,
    kind: s.kind,
    hostId: s.hostId,
    state: 'connected',
    isAlive: () => !s.closed,
    focus: () => s.events.add('focus'),
    close: () async {
      s.events.add('close');
      s.closed = true;
    },
    input: (text) => s.events.add('input:$text'),
    terminal: s.terminal,
    connection: s.connection,
  );

  late final workspace = McpWorkspace(
    scope: () => scope,
    describe: () => {'mode': 'fixture', 'hosts': 99, 'sessions': 99},
    hosts: () => hosts,
    sessions: () => sessions.where((s) => !s.closed).map(_view).toList(),
    connect: (host) async {
      connects.add(host.id);
      if (connectGate case final gate?) await gate.future;
      sessions.add(
        _FakeSession('new-${host.id}-${connects.length}', 'ssh', host.id),
      );
    },
    openConsole: () async {
      consoleOpens++;
      if (consoleOpens == 1) consoleOpens++; // console-1 is pre-existing
      sessions.add(_FakeSession('console-$consoleOpens', 'console', null));
    },
    localDeviceSupported: () => true,
  );
}

class _Connection implements SshConnection {
  final commands = <String>[];
  bool waitForCancellation = false, cancelled = false;
  int clientTouches = 0;
  @override
  Future<SshExecResult> executeRemoteCommand(
    String command, {
    required SshExecCancellation cancellation,
    List<int>? stdinData,
    Duration timeout = const Duration(minutes: 2),
    int maxOutputBytes = 65536,
    String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
  }) async {
    commands.add(command);
    if (waitForCancellation) await cancellation.whenCancelled;
    cancelled = cancellation.isCancelled;
    return SshExecResult(
      stdout: 'ok',
      stderr: '',
      exitCode: 0,
      exitSignal: null,
      cancelled: cancellation.isCancelled,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #client) clientTouches++;
    return super.noSuchMethod(invocation);
  }
}
