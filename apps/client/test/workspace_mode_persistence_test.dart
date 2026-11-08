import 'package:aterm_client/auth/session_update_notifier_native.dart'
    as native;

import 'dart:async';

import 'package:aterm_client/ui/workspace_mode_settings.dart';

import 'dart:io';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/platform/files_window_launch.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/storage/workspace_mode_store_native.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

class _ModeStore implements WorkspaceModeStore {
  WorkspaceMode? saved;
  bool failRead = false;
  bool failWrite = false;
  int reads = 0;
  final writes = <WorkspaceMode>[];
  @override
  Future<WorkspaceMode?> read() async {
    reads++;
    if (failRead) throw StateError('/private/account/token');
    return saved;
  }

  @override
  Future<void> write(WorkspaceMode mode) async {
    if (failWrite) throw StateError('/private/account/token');
    writes.add(mode);
    saved = mode;
  }
}

class _Controller extends AppController {
  bool closed = false;
  final closeCompleted = Completer<void>();
  @override
  Future<void> closeWorkspace() async {
    closed = true;
    await super.closeWorkspace();
    if (!closeCompleted.isCompleted) closeCompleted.complete();
  }

  _Controller({required super.sodium, required super.database})
    : super(secureStore: ClientSecureStore());
  @override
  Future<void> restoreLastServer() async {}
}

// Native first-start coordination performs real IO outside the test clock.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (!tester.binding.hasScheduledFrame) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late VaultCrypto crypto;
  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
  });
  var serverStarts = 0;
  var localStarts = 0;
  final databases = <ClientDatabase>[];
  final controllers = <_Controller>[];
  setUp(() {
    serverStarts = 0;
    localStarts = 0;
  });
  tearDown(() async {
    for (final db in databases) {
      await db.close();
    }
    databases.clear();
    controllers.clear();
  });
  AtermiusApp app(_ModeStore store, {FilesWindowLaunch? filesLaunch}) =>
      AtermiusApp(
        enableProfileModeSelection: true,
        modeStore: store,
        filesLaunch: filesLaunch,
        crypto: crypto,
        localProfileCatalogInitializer: () async {
          localStarts++;
          return LocalProfileCatalog.forTesting(NativeDatabase.memory());
        },
        serverInitializer: () async {
          serverStarts++;
          final db = ClientDatabase.forTesting(NativeDatabase.memory());
          databases.add(db);
          final controller = _Controller(sodium: sodium, database: db);
          controllers.add(controller);
          return controller;
        },
      );

  test('native mode store persists across independent instances and replaces selection', () async {
    final directory = await Directory.systemTemp.createTemp('workspace-mode-');
    try {
      final first = FileWorkspaceModeStore(directory: () async => directory);
      expect(await first.read(), isNull);
      await first.write(WorkspaceMode.local);
      final second = FileWorkspaceModeStore(directory: () async => directory);
      expect(await second.read(), WorkspaceMode.local);
      await second.write(WorkspaceMode.server);
      expect(await first.read(), WorkspaceMode.server);
      final entries = await directory.list().toList();
      expect(entries, hasLength(1));
      expect(
        await File('${directory.path}/workspace-mode-v1').readAsString(),
        'server',
      );
      await File('${directory.path}/workspace-mode-v1')
          .writeAsString('unknown');
      expect(await first.read(), isNull);
      await File('${directory.path}/workspace-mode-v1').writeAsString('x' * 33);
      expect(await first.read(), isNull);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets(
    'native first launch defaults local and remembers it without chooser',
    (tester) async {
      final store = _ModeStore();
      await tester.pumpWidget(app(store));
      await settle(tester);
      expect(find.text('Choose a workspace'), findsNothing);
      expect(serverStarts, 0);
      expect(localStarts, 1);
      expect(store.saved, WorkspaceMode.local);
      expect(find.text('No local profiles yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('local_profile_exit')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      await tester.pumpWidget(app(store));
      await settle(tester);
      expect(find.text('Choose a workspace'), findsNothing);
      expect(find.text('No local profiles yet'), findsOneWidget);
      expect(localStarts, 2);
      expect(serverStarts, 0);
      expect(store.writes, [WorkspaceMode.local]);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets('saved server mode opens only server backend without chooser', (
    tester,
  ) async {
    final store = _ModeStore()..saved = WorkspaceMode.server;
    await tester.pumpWidget(app(store));
    await settle(tester);
    expect(find.text('Choose a workspace'), findsNothing);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(serverStarts, 1);
    expect(localStarts, 0);
    expect(store.writes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets('file launch selects its backend without changing normal mode', (
    tester,
  ) async {
    final store = _ModeStore()
      ..saved = WorkspaceMode.local
      ..failRead = true;
    await tester.pumpWidget(
      app(
        store,
        filesLaunch: FilesWindowLaunch(
          workspace: FilesWindowWorkspace.cloud,
          scopeId: 'vault',
          hostId: 'host',
          protocol: FilesWindowProtocol.sftp,
          serverNamespace: 'https://example.invalid/tenant',
          accountId: 'account',
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(serverStarts, 1);
    expect(localStarts, 0);
    expect(store.saved, WorkspaceMode.local);
    expect(store.reads, 0);
    expect(store.writes, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets(
    'mode read failure is redacted and retry restores only saved backend',
    (tester) async {
      final store = _ModeStore()
        ..saved = WorkspaceMode.local
        ..failRead = true;
      await tester.pumpWidget(app(store));
      await settle(tester);
      expect(find.byKey(const ValueKey('startup_retry')), findsOneWidget);
      expect(find.textContaining('/private/account/token'), findsNothing);
      expect(serverStarts, 0);
      expect(localStarts, 0);
      store.failRead = false;
      await tester.tap(find.byKey(const ValueKey('startup_retry')));
      await settle(tester);
      expect(store.reads, 2);
      expect(find.text('No local profiles yet'), findsOneWidget);
      expect(serverStarts, 0);
      expect(localStarts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets('Settings switch persists server selection for the next launch', (
    tester,
  ) async {
    final store = _ModeStore()..saved = WorkspaceMode.local;
    await tester.pumpWidget(app(store));
    await settle(tester);
    await tester.tap(find.byTooltip('Host menu · click to open'));
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('local_profile_preferences_toggle')),
    );
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('workspace_mode_switch')));
    await settle(tester);
    expect(store.saved, WorkspaceMode.server);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(serverStarts, 1);
    expect(localStarts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    for (final db in databases) {
      await db.close();
    }
    databases.clear();
    await tester.pumpWidget(app(store));
    await settle(tester);
    expect(find.text('Connect to your server'), findsOneWidget);
    expect(find.text('Choose a workspace'), findsNothing);
    expect(serverStarts, 2);
    expect(localStarts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });
  testWidgets('failed preference write does not enter the selected backend', (
    tester,
  ) async {
    final store = _ModeStore()..failWrite = true;
    await tester.pumpWidget(app(store));
    await settle(tester);
    expect(find.text('Choose a workspace'), findsOneWidget);
    expect(find.text('No local profiles yet'), findsNothing);
    expect(find.textContaining('/private/account/token'), findsNothing);
    expect(store.saved, isNull);
    expect(serverStarts, 0);
    store.failWrite = false;
    await tester.tap(find.byKey(const ValueKey('local_mode_start')));
    await settle(tester);
    expect(store.saved, WorkspaceMode.local);
    expect(find.text('No local profiles yet'), findsOneWidget);
    expect(serverStarts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });
  testWidgets(
    'Settings awaits switch, blocks repeat taps, and redacts errors',
    (tester) async {
      final pending = Completer<void>();
      var switches = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WorkspaceModeScope(
            mode: WorkspaceMode.local,
            busy: false,
            onSwitch: () {
              switches++;
              return pending.future;
            },
            child: const Scaffold(body: ScopedWorkspaceModeSettings()),
          ),
        ),
      );
      final button = find.byKey(const ValueKey('workspace_mode_switch'));
      await tester.tap(button);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      expect(switches, 1);
      pending.completeError(StateError('/private/account/token'));
      await settle(tester);
      expect(find.text("Couldn't switch the workspace mode. Check local storage and try again."), findsOneWidget);
      expect(find.textContaining('/private/account/token'), findsNothing);
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('successful Settings switch closes its dialog', (tester) async {
    var switches = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => WorkspaceModeScope(
          mode: WorkspaceMode.server,
          busy: false,
          onSwitch: () async {
            switches++;
          },
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const Dialog(
                  child: SizedBox(
                    width: 400,
                    child: ScopedWorkspaceModeSettings(),
                  ),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('workspace_mode_switch')));
    await settle(tester);
    expect(switches, 1);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
  });
  testWidgets(
    'server Settings switch stops its controller and persists local backend',
    (tester) async {
      final store = _ModeStore()..saved = WorkspaceMode.server;
      await tester.pumpWidget(app(store));
      await settle(tester);
      await tester.tap(find.byTooltip('Workspace menu'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('workspace_settings')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('workspace_mode_switch')));
      await settle(tester);
      // StreamSubscription.cancel returns Dart's root-zone null future.
      // Let its real microtask run, then flush the widget zone's continuation.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await settle(tester);
      expect(controllers.single.closeCompleted.isCompleted, isTrue);
      expect(store.saved, WorkspaceMode.local);
      expect(controllers.single.closed, isTrue);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('No local profiles yet'), findsOneWidget);
      expect(serverStarts, 1);
      expect(localStarts, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );
  test(
    'native controller close barriers finish without an active workspace',
    () async {
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final controller = AppController(
        sodium: sodium,
        database: db,
        secureStore: ClientSecureStore(),
      );
      await controller.closeWorkspace().timeout(const Duration(seconds: 5));
    },
  );

  test(
    'explicit native notifier cancellation drains before database close',
    () async {
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final controller = AppController(
        sodium: sodium,
        database: db,
        secureStore: ClientSecureStore(),
        sessionUpdateNotifierForTesting: native.createSessionUpdateNotifier(),
      );
      await controller.closeWorkspace().timeout(const Duration(seconds: 5));
    },
  );
}
