import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/ssh_port_forwarding_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_port_forward_fakes.dart';

const _loopback = SshPortForwardProfile(
  id: 'loop',
  name: 'Loopback DB',
  type: SshPortForwardType.local,
  bindAddress: '127.0.0.1',
  bindPort: 0,
  destinationAddress: 'db.internal',
  destinationPort: 5432,
);

const _exposed = SshPortForwardProfile(
  id: 'wide',
  name: 'LAN proxy',
  type: SshPortForwardType.dynamic,
  bindAddress: '0.0.0.0',
  bindPort: 0,
  exposeToNetwork: true,
);

class _Harness {
  _Harness(this.profiles, {this.manager});

  List<SshPortForwardProfile>? profiles;
  SshPortForwardManager? manager;
  bool canEdit = true;
  final saves = <List<SshPortForwardProfile>>[];
  final changes = SshPortForwardChangeRelay();

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showSshPortForwardingDialog(
                  context,
                  hostName: 'Edge',
                  profiles: () => profiles,
                  saveProfiles: (next) async {
                    saves.add(next);
                    profiles = next;
                    changes.fire();
                  },
                  manager: () => manager,
                  storageDescription: 'Stored in the encrypted Host.',
                  changes: changes,
                  canEdit: () => canEdit,
                  readOnlyReason: 'Read-only Vault.',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  testWidgets('exposed profiles require confirmation on every start', (
    tester,
  ) async {
    final client = FakeForwardingSshClient();
    final manager = SshPortForwardManager(client);
    final harness = _Harness([_loopback, _exposed], manager: manager);
    await harness.open(tester);
    expect(find.byTooltip('Reachable beyond loopback'), findsOneWidget);
    expect(find.textContaining('SOCKS4/4a/5 CONNECT proxy'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ssh-forward-toggle-wide')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('ssh-forward-exposure-confirm')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('ssh-forward-exposure-cancel')));
    await tester.pumpAndSettle();
    expect(manager.runningCount, 0);

    await tester.tap(find.byKey(const ValueKey('ssh-forward-toggle-wide')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ssh-forward-exposure-accept')));
    await _settle(tester);
    expect(manager.activeProfileIds, ['wide']);
    expect(find.textContaining('Running · 0 active'), findsOneWidget);
    expect(
      sshPortForwardingMenuLabel('SSH port forwarding', manager),
      'SSH port forwarding (1)',
    );

    // Loopback profiles start without a prompt.
    await tester.tap(find.byKey(const ValueKey('ssh-forward-toggle-loop')));
    await _settle(tester);
    expect(manager.runningCount, 2);

    // Losing the SSH transport clears every running badge.
    client.endTransport();
    await _settle(tester);
    expect(manager.runningCount, 0);
    expect(find.textContaining('Running'), findsNothing);
    expect(find.text('Stopped'), findsNWidgets(2));
    expect(
      find.textContaining('Not connected. You can edit profiles now'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('ssh-forward-toggle-loop')),
          )
          .onPressed,
      isNull,
    );
    expect(
      sshPortForwardingMenuLabel('SSH port forwarding', manager),
      'SSH port forwarding',
    );
    await tester.runAsync(manager.closeAll);
  });

  testWidgets('start failures are shown on the profile row', (tester) async {
    final blocker = (await tester.runAsync(
      () => ServerSocket.bind('127.0.0.1', 0),
    ))!;
    final busy = _loopback.copyWith(bindPort: blocker.port);
    final manager = SshPortForwardManager(FakeForwardingSshClient());
    final harness = _Harness([busy], manager: manager);
    await harness.open(tester);
    await tester.tap(find.byKey(const ValueKey('ssh-forward-toggle-loop')));
    await _settle(tester);
    expect(
      find.text(
        'Failed: Port 127.0.0.1:${blocker.port} is already in use on this device.',
      ),
      findsOneWidget,
    );
    expect(manager.runningCount, 0);
    await tester.runAsync(() async {
      await blocker.close();
      await manager.closeAll();
    });
  });

  testWidgets('forwards removed from the Host stay visible until stopped', (
    tester,
  ) async {
    final manager = SshPortForwardManager(FakeForwardingSshClient());
    await tester.runAsync(() => manager.start(_loopback));
    final harness = _Harness(const [], manager: manager);
    await harness.open(tester);
    expect(
      find.byKey(const ValueKey('ssh-forward-orphan-loop')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('ssh-forward-orphan-stop-loop')),
    );
    await _settle(tester);
    expect(manager.runningCount, 0);
    expect(find.byKey(const ValueKey('ssh-forward-orphan-loop')), findsNothing);
    await tester.runAsync(manager.closeAll);
  });

  testWidgets('host outside scope and read-only access disable editing', (
    tester,
  ) async {
    final harness = _Harness(null);
    await harness.open(tester);
    expect(
      find.byKey(const ValueKey('ssh-forward-host-missing')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.byKey(const ValueKey('ssh-forward-add')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    final readOnly = _Harness([_loopback])..canEdit = false;
    await readOnly.open(tester);
    expect(find.text('Read-only Vault.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('ssh-forward-edit-loop')),
          )
          .onPressed,
      isNull,
    );
    expect(readOnly.saves, isEmpty);
  });

  testWidgets('editor rejects listener conflicts with sibling profiles', (
    tester,
  ) async {
    final harness = _Harness([_loopback.copyWith(bindPort: 15432)]);
    await harness.open(tester);
    await tester.tap(find.byKey(const ValueKey('ssh-forward-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ssh-forward-profile-name')),
      'Duplicate',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ssh-forward-bind-address')),
      'localhost',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ssh-forward-bind-port')),
      '15432',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ssh-forward-destination-address')),
      'cache.internal',
    );
    await tester.enterText(
      find.byKey(const ValueKey('ssh-forward-destination-port')),
      '6379',
    );
    await tester.tap(find.byKey(const ValueKey('ssh-forward-profile-save')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Another profile of this Host already uses this listener address and port.',
      ),
      findsOneWidget,
    );
    expect(harness.saves, isEmpty);
  });

  testWidgets('Start stays disabled until a slow stop has finished', (
    tester,
  ) async {
    final platform = _GatedPlatform();
    final manager = SshPortForwardManager(
      FakeForwardingSshClient(),
      platform: platform,
    );
    final harness = _Harness([_loopback], manager: manager);
    await harness.open(tester);
    await tester.tap(find.byKey(const ValueKey('ssh-forward-toggle-loop')));
    await tester.pumpAndSettle();
    expect(manager.runningCount, 1);

    await tester.tap(find.byKey(const ValueKey('ssh-forward-toggle-loop')));
    await tester.pump();
    expect(find.text('Stopping…'), findsOneWidget);
    IconButton toggle() => tester.widget<IconButton>(
      find.byKey(const ValueKey('ssh-forward-toggle-loop')),
    );
    expect(toggle().onPressed, isNull);
    await tester.tap(
      find.byKey(const ValueKey('ssh-forward-toggle-loop')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(platform.starts, 1, reason: 'no restart while stopping');

    platform.release.complete();
    await tester.pumpAndSettle();
    expect(find.text('Stopped'), findsOneWidget);
    expect(toggle().onPressed, isNotNull);
    await manager.closeAll();
  });
}

class _GatedHandle implements SshPortForwardHandle {
  _GatedHandle(this.profileId, this._gate);

  final Completer<void> _gate;
  @override
  final String profileId;
  @override
  bool isClosed = false;
  @override
  int get listeningPort => 40404;
  @override
  int get activeConnections => 0;
  @override
  int get totalConnections => 0;
  @override
  String? get lastConnectionError => null;
  @override
  set onChanged(void Function()? callback) {}

  @override
  Future<void> close() async {
    isClosed = true;
    await _gate.future;
  }
}

class _GatedPlatform implements SshPortForwardPlatform {
  final release = Completer<void>();
  int starts = 0;

  @override
  bool get isSupported => true;
  @override
  String? get unsupportedReason => null;

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) async {
    starts++;
    return _GatedHandle(profile.id, release);
  }
}
