import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/attachments/host_attachment_service.dart';
import 'package:aterm_client/domain/ansible_inventory_metadata.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('editing a host preserves and updates tags', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final inventoryMetadata = AnsibleInventoryImportMetadata(
      sourceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      sourceLabel: 'Production inventory',
      entryKey: 'Production edge',
      baseline: AnsibleInventoryImportedValues(
        name: 'Production edge',
        address: 'edge.example.test',
        port: 22,
        username: 'deploy',
        tags: const ['production', 'api'],
      ),
      state: AnsibleInventoryEntryState.stale,
    );
    final originalManifest = <String, Object?>{
      'extension_version': 1,
      'object_refs': ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'],
      'ansible_inventory_v1': inventoryMetadata.toJson(),
    };
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..hosts.add(
            HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Production edge',
              address: 'edge.example.test',
              username: 'deploy',
              tags: ['production', 'api'],
              authKind: AuthKind.privateKey,
              color: 3,
              isFavorite: true,
              manifest: originalManifest,
            ),
          );

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final editButton = await _hostAction(
        tester,
        controller.hosts.single.id,
        'edit',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Inventory entry stale'), findsOneWidget);
      final attachmentsButton = await _hostAction(
        tester,
        controller.hosts.single.id,
        'attachments',
      );
      expect(attachmentsButton, findsOneWidget);
      await tester.ensureVisible(attachmentsButton);
      await tester.tap(attachmentsButton);
      await tester.pumpAndSettle();
      expect(find.text('No attachments saved for this host.'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await _hostAction(tester, controller.hosts.last.id, 'edit');
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      final tagsField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Tags',
      );
      expect(
        tester.widget<TextField>(tagsField).controller?.text,
        'production, api',
      );

      await tester.enterText(tagsField, 'production, operations, , OPERATIONS');
      await tester.pump();
      await tester.ensureVisible(find.text('Edit private key'));
      await tester.tap(find.text('Edit private key'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('host_editor_private_key')),
        'test-private-key',
      );
      await _fillPasswordIfEmpty(tester);
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();

      final saved = controller.savedHost;
      expect(saved, isNotNull);
      expect(saved!.tags, ['production', 'operations']);
      expect(saved.authKind, AuthKind.privateKey);
      expect(saved.color, 3);
      expect(saved.isFavorite, isTrue);
      expect(saved.manifest, originalManifest);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets(
    'Host group filter distinguishes same-named nested groups by identity',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const alphaRootId = '11111111-1111-4111-8111-111111111111';
      const betaRootId = '22222222-2222-4222-8222-222222222222';
      const alphaGroupId = '33333333-3333-4333-8333-333333333333';
      const betaGroupId = '44444444-4444-4444-8444-444444444444';
      final controller =
          _HostEditController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.hosts
            ..activeVault = const VaultDescriptor(
              id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..groups.addAll(const [
              GroupRecord(id: alphaRootId, name: 'Alpha'),
              GroupRecord(id: betaRootId, name: 'Beta'),
              GroupRecord(
                id: alphaGroupId,
                name: 'Production',
                parentId: alphaRootId,
              ),
              GroupRecord(
                id: betaGroupId,
                name: 'Production',
                parentId: betaRootId,
              ),
            ])
            ..hosts.addAll(const [
              HostRecord(
                id: '55555555-5555-4555-8555-555555555555',
                name: 'Alpha production host',
                address: 'alpha.example.test',
                username: 'deploy',
                groupId: alphaGroupId,
              ),
              HostRecord(
                id: '66666666-6666-4666-8666-666666666666',
                name: 'Beta production host',
                address: 'beta.example.test',
                username: 'deploy',
                groupId: betaGroupId,
              ),
            ]);

      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Alpha production host'), findsOneWidget);
        expect(find.text('Beta production host'), findsOneWidget);
        final alphaGroupTag = find.byKey(
          const ValueKey('host-group-tag-55555555-5555-4555-8555-555555555555'),
        );
        final betaGroupTag = find.byKey(
          const ValueKey('host-group-tag-66666666-6666-4666-8666-666666666666'),
        );
        expect(alphaGroupTag, findsOneWidget);
        expect(betaGroupTag, findsOneWidget);
        expect(tester.getSemantics(alphaGroupTag).label, 'Group: Production');
        expect(
          tester.getSemantics(alphaGroupTag).identifier,
          'ssh-host-group-55555555-5555-4555-8555-555555555555',
        );
        expect(tester.getSemantics(betaGroupTag).label, 'Group: Production');
        expect(
          tester.getSemantics(betaGroupTag).identifier,
          'ssh-host-group-66666666-6666-4666-8666-666666666666',
        );
        expect(
          tester
              .getSemantics(
                find.bySemanticsIdentifier(
                  'ssh-host-55555555-5555-4555-8555-555555555555',
                ),
              )
              .label,
          contains('; Group: Production'),
        );

        await tester.tap(
          find.byKey(const ValueKey('workspace_host_search_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Filter by group'));
        await tester.pumpAndSettle();
        expect(find.text('Alpha / Production'), findsOneWidget);
        expect(find.text('Beta / Production'), findsOneWidget);
        await tester.tap(find.text('Alpha / Production'));
        await tester.pumpAndSettle();

        final palette = find.byKey(const ValueKey('host_search_palette'));
        expect(
          find.descendant(
            of: palette,
            matching: find.byKey(
              const ValueKey(
                'host-search-result-55555555-5555-4555-8555-555555555555',
              ),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: palette,
            matching: find.byKey(
              const ValueKey(
                'host-search-result-66666666-6666-4666-8666-666666666666',
              ),
            ),
          ),
          findsNothing,
        );
        expect(find.text('Alpha / Production'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
        controller.dispose();
        await database.close();
      }
    },
  );

  testWidgets('invalid Jump Host routes offer a repair editor', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    const host = HostRecord(
      id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      name: 'Broken route target',
      address: 'target.example.test',
      username: 'deploy',
      jumpHostId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    );
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..hosts.add(host);

    try {
      expect(controller.jumpHostRouteIssues[host.id], contains('no longer exists'));
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final repairButton = await _hostAction(tester, host.id, 'edit');
      expect(repairButton, findsOneWidget);
      await tester.ensureVisible(repairButton);
      await tester.tap(repairButton);
      await tester.pumpAndSettle();
      expect(find.text('Save encrypted host'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets(
    'Hosts page surfaces missing Group refs and opens the affected editor',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      const host = HostRecord(
        id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        name: 'Orphaned Host',
        address: 'edge.example.test',
        username: 'deploy',
        groupId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      );
      final controller =
          _HostEditController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.hosts
            ..activeVault = const VaultDescriptor(
              id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.add(host);
      controller.groupReferenceIssuesForTesting[host.id] =
          'Host references unavailable Group ${host.groupId}.';
      expect(controller.hostsNeedingGroupRepair, [host]);
      expect(controller.hostGroupReferenceIssues, contains(host.id));

      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Your server fleet'), findsNothing);
        expect(find.text('Orphaned Host'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('host_group_reference_repair_warning')),
          findsOneWidget,
        );
        expect(find.textContaining('1 Host references'), findsOneWidget);
        expect(find.text('Unavailable group'), findsOneWidget);
        expect(
          find.byTooltip(controller.hostGroupReferenceIssues[host.id]!),
          findsOneWidget,
        );
        final unavailableGroupTag = find.byKey(
          const ValueKey(
            'host-group-unavailable-cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          ),
        );
        expect(unavailableGroupTag, findsOneWidget);
        expect(
          tester.getSemantics(unavailableGroupTag).identifier,
          'ssh-host-group-unavailable-cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        );
        expect(
          tester.getSemantics(unavailableGroupTag).label,
          contains('Unavailable group'),
        );

        final repairButton = find.byKey(
          const ValueKey('host_group_reference_repair_action'),
        );
        await tester.ensureVisible(repairButton);
        await tester.tap(repairButton);
        await tester.pumpAndSettle();

        expect(find.text('Unavailable group'), findsNWidgets(2));
        expect(
          find.textContaining('Choose No group to clear it.'),
          findsOneWidget,
        );
        final groupPicker = find.byKey(const ValueKey('host_editor_group'));
        await tester.ensureVisible(groupPicker);
        await tester.tap(groupPicker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('No group').last);
        await tester.pumpAndSettle();
        await _fillPasswordIfEmpty(tester);
        await tester.tap(find.text('Save encrypted host'));
        await tester.pumpAndSettle();

        expect(controller.savedHost?.id, host.id);
        expect(controller.savedHost?.groupId, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
        controller.dispose();
        await database.close();
      }
    },
  );

  testWidgets('a Host with a missing Group can be unassigned in the editor', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sync
          ..unavailableRecordCount = 1
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..hosts.add(
            const HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Orphaned Host',
              address: 'edge.example.test',
              username: 'deploy',
              groupId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            ),
          );

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('or decoded as a supported record'),
        findsOneWidget,
      );
      controller
        ..page = WorkspacePage.hosts
        ..notifyListeners();
      await tester.pumpAndSettle();
      final editButton = await _hostAction(
        tester,
        controller.hosts.single.id,
        'edit',
      );
      await tester.ensureVisible(editButton);
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      expect(find.text('Unavailable group'), findsOneWidget);
      expect(
        find.textContaining('Choose No group to clear it.'),
        findsOneWidget,
      );
      final groupPicker = find.byKey(const ValueKey('host_editor_group'));
      await tester.ensureVisible(groupPicker);
      await tester.tap(groupPicker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('No group').last);
      await tester.pumpAndSettle();
      await _fillPasswordIfEmpty(tester);
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();

      expect(controller.savedHost?.groupId, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Host editor offers bounded acyclic Jump Host routes', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..hosts.addAll(const [
            HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Bastion',
              address: 'bastion.example.test',
              username: 'relay',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000001',
              name: 'Boundary hop 1',
              address: 'boundary-1.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000002',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000002',
              name: 'Boundary hop 2',
              address: 'boundary-2.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000003',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000003',
              name: 'Boundary hop 3',
              address: 'boundary-3.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000004',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000004',
              name: 'Boundary hop 4',
              address: 'boundary-4.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000005',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000005',
              name: 'Boundary hop 5',
              address: 'boundary-5.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000006',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000006',
              name: 'Boundary hop 6',
              address: 'boundary-6.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000007',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000007',
              name: 'Boundary hop 7',
              address: 'boundary-7.example.test',
              username: 'relay',
              jumpHostId: '81000000-0000-4000-8000-000000000008',
            ),
            HostRecord(
              id: '81000000-0000-4000-8000-000000000008',
              name: 'Boundary hop 8',
              address: 'boundary-8.example.test',
              username: 'relay',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000001',
              name: 'Over-depth hop 1',
              address: 'over-depth-1.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000002',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000002',
              name: 'Over-depth hop 2',
              address: 'over-depth-2.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000003',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000003',
              name: 'Over-depth hop 3',
              address: 'over-depth-3.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000004',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000004',
              name: 'Over-depth hop 4',
              address: 'over-depth-4.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000005',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000005',
              name: 'Over-depth hop 5',
              address: 'over-depth-5.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000006',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000006',
              name: 'Over-depth hop 6',
              address: 'over-depth-6.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000007',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000007',
              name: 'Over-depth hop 7',
              address: 'over-depth-7.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000008',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000008',
              name: 'Over-depth hop 8',
              address: 'over-depth-8.example.test',
              username: 'relay',
              jumpHostId: '82000000-0000-4000-8000-000000000009',
            ),
            HostRecord(
              id: '82000000-0000-4000-8000-000000000009',
              name: 'Over-depth hop 9',
              address: 'over-depth-9.example.test',
              username: 'relay',
            ),
            HostRecord(
              id: '83000000-0000-4000-8000-000000000001',
              name: 'Cycle A',
              address: 'cycle-a.example.test',
              username: 'relay',
              jumpHostId: '83000000-0000-4000-8000-000000000002',
            ),
            HostRecord(
              id: '83000000-0000-4000-8000-000000000002',
              name: 'Cycle B',
              address: 'cycle-b.example.test',
              username: 'relay',
              jumpHostId: '83000000-0000-4000-8000-000000000001',
            ),
            HostRecord(
              id: '84000000-0000-4000-8000-000000000001',
              name: 'Missing route',
              address: 'missing-route.example.test',
              username: 'relay',
              jumpHostId: '84000000-0000-4000-8000-000000000002',
            ),
            HostRecord(
              id: '84000000-0000-4000-8000-000000000003',
              name: 'Self route',
              address: 'self-route.example.test',
              username: 'relay',
              jumpHostId: '84000000-0000-4000-8000-000000000003',
            ),
            HostRecord(
              id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              name: 'Target',
              address: 'target.example.test',
              username: 'deploy',
            ),
          ]);

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final editButton = await _hostAction(
        tester,
        controller.hosts.last.id,
        'edit',
      );
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();
      final jumpPicker = find.byKey(const ValueKey('host_editor_jump_host'));
      await tester.ensureVisible(jumpPicker);
      await tester.tap(jumpPicker);
      await tester.pumpAndSettle();
      expect(
        find.text('Boundary hop 1 · boundary-1.example.test:22'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsIdentifier(
          'ssh-jump-host-option-81000000-0000-4000-8000-000000000001',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Over-depth hop 1 · over-depth-1.example.test:22'),
        findsNothing,
      );
      expect(find.text('Cycle A · cycle-a.example.test:22'), findsNothing);
      expect(
        find.text('Missing route · missing-route.example.test:22'),
        findsNothing,
      );
      expect(
        find.text('Self route · self-route.example.test:22'),
        findsNothing,
      );
      await tester.tap(
        find.text('Boundary hop 1 · boundary-1.example.test:22').last,
      );
      await tester.pumpAndSettle();
      await _fillPasswordIfEmpty(tester);
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();

      expect(
        controller.savedHost?.jumpHostId,
        '81000000-0000-4000-8000-000000000001',
      );
      expect(
        find.bySemanticsIdentifier(
          'ssh-host-dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        ),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets(
    'Host editor visibly repairs and clears an unavailable Jump Host',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final controller =
          _HostEditController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.hosts
            ..activeVault = const VaultDescriptor(
              id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.add(
              const HostRecord(
                id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
                name: 'Target',
                address: 'target.example.test',
                username: 'deploy',
                jumpHostId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              ),
            );

      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final editButton = await _hostAction(
          tester,
          controller.hosts.single.id,
          'edit',
        );
        await tester.ensureVisible(editButton);
        await tester.pumpAndSettle();
        await tester.tap(editButton);
        await tester.pumpAndSettle();
        expect(find.text('Unavailable Jump Host'), findsOneWidget);
        expect(find.textContaining('Choose Direct connection'), findsOneWidget);
        final jumpPicker = find.byKey(const ValueKey('host_editor_jump_host'));
        await tester.ensureVisible(jumpPicker);
        await tester.tap(jumpPicker);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Direct connection').last);
        await tester.pumpAndSettle();
        await _fillPasswordIfEmpty(tester);
        await tester.tap(find.text('Save encrypted host'));
        await tester.pumpAndSettle();

        expect(controller.savedHost?.jumpHostId, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
        controller.dispose();
        await database.close();
      }
    },
  );

  testWidgets('read-only Vault disables Host editing', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'viewer',
            activeKeyEpoch: '1',
            membershipVersion: '1',
            canWrite: false,
          )
          ..hosts.addAll(const [
            HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Bastion',
              address: 'bastion.example.test',
              username: 'relay',
            ),
            HostRecord(
              id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
              name: 'Target',
              address: 'target.example.test',
              username: 'deploy',
            ),
          ]);

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final edit = await _hostAction(tester, controller.hosts.first.id, 'edit');
      expect(tester.widget<PopupMenuItem<String>>(edit).enabled, isFalse);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(find.text('Save encrypted host'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Host editor keeps a valid Keychain reference on save (R7)', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..credentials.add(
            const CredentialRecord(
              id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              name: 'Deployment credential',
              username: 'deploy',
              secret: 'ephemeral-secret',
            ),
          )
          ..hosts.add(
            const HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Credential-linked Host',
              address: 'edge.example.test',
              username: 'deploy',
              credentialId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            ),
          );

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final editButton = await _hostAction(
        tester,
        controller.hosts.single.id,
        'edit',
      );
      await tester.ensureVisible(editButton);
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      expect(find.text('Edit host'), findsOneWidget);
      // R7: the shared Keychain secret is not copied into Host fields and an
      // unrelated save never relinks the Host (explicit selector instead).
      expect(find.byKey(const ValueKey('host_editor_password')), findsNothing);
      expect(find.text('ephemeral-secret'), findsNothing);
      expect(
        find.byKey(const ValueKey('host_editor_sign_in_source')),
        findsOneWidget,
      );
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();
      expect(controller.savedHost?.login, isNull);
      expect(
        controller.savedHost?.credentialId,
        'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      );
      expect(controller.credentials.single.secret, 'ephemeral-secret');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Host editor replaces a stale override with Host login', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..credentials.add(
            const CredentialRecord(
              id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              name: 'Deployment credential',
              username: 'deploy',
              secret: 'ephemeral-secret',
            ),
          )
          ..groups.add(
            const GroupRecord(
              id: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
              name: 'Operations',
              defaultCredentialId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            ),
          )
          ..hosts.add(
            const HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Inherited Host',
              address: 'edge.example.test',
              username: 'deploy',
              groupId: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
              credentialId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            ),
          );

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final editButton = await _hostAction(
        tester,
        controller.hosts.single.id,
        'edit',
      );
      await tester.ensureVisible(editButton);
      await tester.tap(editButton);
      await tester.pumpAndSettle();
      // R7: replacing the (stale) reference is an explicit choice.
      final source = find.byKey(const ValueKey('host_editor_sign_in_source'));
      await tester.ensureVisible(source);
      await tester.tap(source);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('own sign-in').last);
      await tester.pumpAndSettle();
      final password = find.byKey(const ValueKey('host_editor_password'));
      await tester.ensureVisible(password);
      await tester.enterText(password, 'replacement-host-password');
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();
      expect(controller.savedHost?.credentialId, isNull);
      expect(
        controller.savedHost?.groupId,
        'ffffffff-ffff-4fff-8fff-ffffffffffff',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('confirmed Host deletion removes its UI entry', (tester) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..hosts.add(
            const HostRecord(
              id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              name: 'Disposable edge',
              address: 'edge.example.test',
              username: 'deploy',
            ),
          );

    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Disposable edge'), findsOneWidget);
      final deleteAction = await _hostAction(
        tester,
        controller.hosts.single.id,
        'delete',
      );
      await tester.tap(deleteAction);
      await tester.pumpAndSettle();
      expect(find.text('Delete this item?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(controller.deletedHostIds, [
        'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      ]);
      expect(find.text('Disposable edge'), findsNothing);
      expect(find.text('No hosts saved yet'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('host_connect_cccccccc-cccc-4ccc-8ccc-cccccccccccc'),
        ),
        findsNothing,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
    }
  });

  testWidgets('Hosts page header actions fit a narrow mobile viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final controller =
        _HostEditController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );

    try {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('host_import_openssh_config')),
        findsNothing,
      );
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Add host'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cloud_new_ssh')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('host_import_openssh_config')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('cloud_add_group')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      controller.dispose();
      await database.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

class _HostEditController extends AppController {
  _HostEditController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  HostRecord? savedHost;
  final List<String> deletedHostIds = [];
  final Map<String, String> groupReferenceIssuesForTesting = {};

  @override
  Map<String, String> get hostGroupReferenceIssues =>
      Map.unmodifiable(groupReferenceIssuesForTesting);

  @override
  List<HostRecord> get hostsNeedingGroupRepair => List.unmodifiable(
    hosts.where((host) => groupReferenceIssuesForTesting.containsKey(host.id)),
  );

  @override
  List<HostAttachmentSummary> hostAttachments(String hostId) => const [];

  @override
  Future<void> saveHost(HostRecord host) async {
    savedHost = host;
  }

  @override
  Future<void> saveHostFromEditor({
    required HostRecord original,
    required HostRecord edited,
  }) async {
    savedHost = edited;
  }

  @override
  Future<void> deleteHost(HostRecord host) async {
    deletedHostIds.add(host.id);
    hosts.removeWhere((item) => item.id == host.id);
    notifyListeners();
  }
}

Future<void> _fillPasswordIfEmpty(WidgetTester tester) async {
  final finder = find.byKey(const ValueKey('host_editor_password'));
  if (finder.evaluate().isNotEmpty &&
      tester.widget<TextField>(finder).controller!.text.isEmpty) {
    await tester.ensureVisible(finder);
    await tester.enterText(finder, 'host-editor-test-password');
  }
}

Future<Finder> _hostAction(
  WidgetTester tester,
  String hostId,
  String action,
) async {
  final card = find.byKey(ValueKey('host_connect_$hostId'));
  await tester.ensureVisible(card);
  await tester.tap(
    find.descendant(
      of: find.bySemanticsIdentifier('ssh-host-$hostId'),
      matching: find.byType(WorkspaceOverflowMenu),
    ),
  );
  await tester.pumpAndSettle();
  return find.byKey(ValueKey('host-$action-$hostId'));
}
