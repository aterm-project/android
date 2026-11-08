import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _rootId = '22222222-2222-4222-8222-222222222222';
const _childId = '33333333-3333-4333-8333-333333333333';
const _hostId = '44444444-4444-4444-8444-444444444444';
const _credentialId = '55555555-5555-4555-8555-555555555555';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('creates, edits, reparents, recolors, and deletes Groups', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    try {
      await _pumpGroups(tester, app);

      await tester.tap(find.byKey(const ValueKey('server_group_create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('server_group_name')),
        '  Engineering  ',
      );
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();

      expect(app.groups, hasLength(1));
      expect(app.groups.single.name, 'Engineering');
      expect(find.text('Engineering'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('server_group_create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('server_group_name')),
        'Production',
      );
      await tester.tap(find.byKey(const ValueKey('server_group_parent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Engineering').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();

      final root = app.groups.singleWhere(
        (group) => group.name == 'Engineering',
      );
      final child = app.groups.singleWhere(
        (group) => group.name == 'Production',
      );
      expect(child.parentId, root.id);
      expect(find.textContaining('Inside Engineering'), findsOneWidget);

      await _openGroupAction(tester, 'Production', 'Edit group');
      await tester.enterText(
        find.byKey(const ValueKey('server_group_name')),
        'Production fleet',
      );
      await tester.tap(find.byKey(const ValueKey('server_group_parent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Top-level group').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server_group_color')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#4DB6AC').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();

      final edited = app.groups.singleWhere((group) => group.id == child.id);
      expect(edited.name, 'Production fleet');
      expect(edited.parentId, isNull);
      expect(edited.color, 0x4DB6AC);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(ValueKey('server_group_${child.id}')),
                matching: find.byIcon(Icons.folder_copy_outlined),
              ),
            )
            .color,
        const Color(0xFF4DB6AC),
      );
      expect(find.textContaining('Inside Engineering'), findsNothing);

      await _openGroupAction(tester, 'Production fleet', 'Delete group');
      await tester.pumpAndSettle();
      expect(find.text('Delete group?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('server_group_delete_confirm')),
      );
      await tester.pumpAndSettle();
      expect(app.groups.map((group) => group.name), ['Engineering']);
      expect(find.text('Production fleet'), findsNothing);
      expect(app.savedGroups, hasLength(3));
      expect(app.deletedGroups, [child.id]);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('duplicate sibling names are shown inline before save', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    app.groups.add(const GroupRecord(id: _rootId, name: 'Engineering'));
    try {
      await _pumpGroups(tester, app);
      await tester.tap(find.byKey(const ValueKey('server_group_create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('server_group_name')),
        '  ENGINEERING ',
      );
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('A group with this name already exists under the same parent. Change the name or choose another parent.'), findsOneWidget);
      expect(find.byKey(const ValueKey('server_group_name')), findsOneWidget);
      expect(app.saveCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('synced Group cycle is visible and can be repaired', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    app.groups.addAll(const [
      GroupRecord(id: _rootId, name: 'Cycle Alpha', parentId: _childId),
      GroupRecord(id: _childId, name: 'Cycle Beta', parentId: _rootId),
    ]);
    try {
      await _pumpGroups(tester, app);

      expect(app.groupsNeedingParentRepair, hasLength(2));
      expect(
        find.byKey(const ValueKey('server_group_graph_repair_warning')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Parent relationship needs repair'),
        findsNWidgets(2),
      );

      await tester.tap(
        find.byKey(const ValueKey('server_group_graph_repair_action')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unavailable parent; choose again'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('server_group_parent')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Top-level group').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();

      expect(app.groupsNeedingParentRepair, isEmpty);
      expect(
        find.byKey(const ValueKey('server_group_graph_repair_warning')),
        findsNothing,
      );
      expect(app.savedGroups.single.parentId, isNull);
      expect(find.textContaining('Inside Cycle Alpha'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('save failure keeps the draft and offers a safe retry', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    app.failNextSave = true;
    app.credentials.add(
      const CredentialRecord(
        id: _credentialId,
        name: 'Deployment credential',
        username: 'deploy',
        secret: 'ephemeral-secret',
      ),
    );
    try {
      await _pumpGroups(tester, app);
      await tester.tap(find.byKey(const ValueKey('server_group_create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('server_group_name')),
        'Retry me',
      );
      final defaultCredentialPicker = find.byKey(
        const ValueKey('server_group_default_credential'),
      );
      await tester.ensureVisible(defaultCredentialPicker);
      await tester.tap(defaultCredentialPicker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deployment credential').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('server_group_name')), findsOneWidget);
      expect(find.textContaining('Could not save this group.'), findsOneWidget);
      expect(find.textContaining('private response'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('server_group_name')))
            .controller
            ?.text,
        'Retry me',
      );
      expect(app.groups, isEmpty);
      expect(find.text('Deployment credential'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pumpAndSettle();
      expect(app.groups.single.name, 'Retry me');
      expect(app.groups.single.defaultCredentialId, _credentialId);
      expect(find.byKey(const ValueKey('server_group_name')), findsNothing);
      expect(app.saveCalls, 2);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets(
    'Group default credential can be cleared and is unavailable read-only',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(tester.view.resetPhysicalSize);
      final (app, database) = await _makeController();
      app.groups.add(
        const GroupRecord(
          id: _rootId,
          name: 'Engineering',
          defaultCredentialId: _credentialId,
        ),
      );
      try {
        await _pumpGroups(tester, app);
        await _openGroupAction(tester, 'Engineering', 'Edit group');
        final picker = find.byKey(
          const ValueKey('server_group_default_credential'),
        );
        expect(find.text('Unavailable credential'), findsOneWidget);
        await tester.tap(picker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('No default credential').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('server_group_save')));
        await tester.pumpAndSettle();
        expect(app.groups.single.defaultCredentialId, isNull);
        expect(app.savedGroups.last.defaultCredentialId, isNull);

        app.activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: false,
        );
        await _pumpGroups(tester, app);
        expect(
          find.byKey(const ValueKey('server_group_default_credential')),
          findsNothing,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('server_group_create')),
              )
              .onPressed,
          isNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets('Group name field is disabled while save is in flight', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    final saveGate = Completer<void>();
    app.saveGate = saveGate;
    try {
      await _pumpGroups(tester, app);
      await tester.tap(find.byKey(const ValueKey('server_group_create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('server_group_name')),
        'In flight',
      );
      await tester.tap(find.byKey(const ValueKey('server_group_save')));
      await tester.pump();

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('server_group_name')))
            .enabled,
        isFalse,
      );

      saveGate.complete();
      await tester.pumpAndSettle();
      expect(app.groups.single.name, 'In flight');
      expect(find.byKey(const ValueKey('server_group_name')), findsNothing);
    } finally {
      if (!saveGate.isCompleted) saveGate.complete();
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('referenced Groups cannot be deleted', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController();
    app
      ..groups.addAll(const [
        GroupRecord(id: _rootId, name: 'Root'),
        GroupRecord(id: _childId, name: 'Child', parentId: _rootId),
      ])
      ..hosts.add(
        const HostRecord(
          id: _hostId,
          name: 'Linked host',
          address: 'host.example.test',
          username: 'deploy',
          groupId: _rootId,
        ),
      );
    try {
      await _pumpGroups(tester, app);
      await _openGroupAction(tester, 'Root', 'Delete group');
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Move or unassign 1 host and 1 child group before deleting “Root”.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('server_group_delete_confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(app.deleteCalls, 0);
      await tester.tap(
        find.byKey(const ValueKey('server_group_delete_cancel')),
      );
      await tester.pumpAndSettle();
      expect(app.groups, hasLength(2));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('read-only Vault keeps group actions unavailable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1280, 960);
    addTearDown(tester.view.resetPhysicalSize);
    final (app, database) = await _makeController(canWrite: false);
    app.groups.add(const GroupRecord(id: _rootId, name: 'View only'));
    try {
      await _pumpGroups(tester, app);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('server_group_create')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const ValueKey('server_group_actions_$_rootId')),
            )
            .enabled,
        isFalse,
      );
      expect(find.text('View only'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });
}

Future<void> _pumpGroups(WidgetTester tester, _GroupsController app) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openGroupAction(
  WidgetTester tester,
  String groupName,
  String action,
) async {
  final actions = find.byTooltip('Group actions: $groupName');
  await tester.ensureVisible(actions);
  await tester.pumpAndSettle();
  await tester.tap(actions);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

Future<(_GroupsController, ClientDatabase)> _makeController({
  bool canWrite = true,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _GroupsController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.groups
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  return (app, database);
}

class _GroupsController extends AppController {
  _GroupsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  final List<GroupRecord> savedGroups = [];
  final List<String> deletedGroups = [];
  int saveCalls = 0;
  int deleteCalls = 0;
  bool failNextSave = false;
  Completer<void>? saveGate;

  @override
  Future<void> saveGroup(
    GroupRecord group, {
    bool Function()? isCurrentContext,
  }) async {
    if (isCurrentContext != null && !isCurrentContext())
      throw StateError('Scope changed');
    saveCalls++;
    final validation = validateGroup(group);
    if (validation != null) throw FormatException(validation);
    if (failNextSave) {
      failNextSave = false;
      throw StateError('private response details');
    }
    await saveGate?.future;
    final saved = GroupRecord(
      id: group.id,
      name: group.name.trim(),
      color: group.color,
      parentId: group.parentId,
      defaultCredentialId: group.defaultCredentialId,
      manifest: group.manifest,
    );
    final index = groups.indexWhere((item) => item.id == group.id);
    if (index < 0) {
      groups.add(saved);
    } else {
      groups[index] = saved;
    }
    savedGroups.add(saved);
    notifyListeners();
  }

  @override
  Future<void> deleteGroup(GroupRecord item) async {
    deleteCalls++;
    if (hosts.any((host) => host.groupId == item.id) ||
        groups.any((group) => group.parentId == item.id)) {
      throw const FormatException('Group is still referenced.');
    }
    groups.removeWhere((group) => group.id == item.id);
    deletedGroups.add(item.id);
    notifyListeners();
  }
}
