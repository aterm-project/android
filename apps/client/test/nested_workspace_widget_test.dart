import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _savedWorkspaceId = '22222222-2222-4222-8222-222222222222';
const _hostA = '33333333-3333-4333-8333-333333333333';
const _missingHost = '44444444-4444-4444-8444-444444444444';
const _hostB = '55555555-5555-4555-8555-555555555555';
const _replacementHost = '66666666-6666-4666-8666-666666666666';
const _paneA = '77777777-7777-4777-8777-777777777777';
const _paneMissing = '88888888-8888-4888-8888-888888888888';
const _paneB = '99999999-9999-4999-8999-999999999999';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'saved split Workspace action renames through the dialog and preserves pane order',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          _NestedWorkspaceTestApp(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async => throw StateError(
                    'Renaming a saved Workspace must not connect',
                  ),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.savedWorkspaces
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [
              HostRecord(
                id: _hostA,
                name: 'Build host',
                address: 'build.example.test',
                username: 'builder',
              ),
              HostRecord(
                id: _hostB,
                name: 'Database host',
                address: 'db.example.test',
                username: 'operator',
              ),
            ]);
      app.savedWorkspaces.add(
        WorkspaceRecord.fromSplitHostIds(
          id: _savedWorkspaceId,
          name: 'Release layout before rename',
          hostIds: const [_hostA, _hostB],
          paneIds: const [_paneA, _paneB],
          activeIndex: 1,
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 6000,
        ),
      );

      try {
        await tester.pumpWidget(_shell(app));
        await tester.pumpAndSettle();
        expect(find.text('Release layout before rename'), findsOneWidget);
        expect(find.text('Active Pane 2'), findsOneWidget);
        expect(
          find.text('Pane 1 · Build host · build.example.test:22'),
          findsOneWidget,
        );
        expect(
          find.text('Pane 2 · Database host · db.example.test:22'),
          findsOneWidget,
        );

        final actions = find.byTooltip('Workspace actions');
        expect(actions, findsOneWidget);
        await tester.tap(actions);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Rename').last);
        await tester.pumpAndSettle();

        expect(find.text('Rename workspace'), findsOneWidget);
        final nameInput = find.byKey(const ValueKey('workspace-name-input'));
        expect(
          tester.widget<TextField>(nameInput).controller?.text,
          'Release layout before rename',
        );
        await tester.enterText(nameInput, 'Release layout after rename');
        await tester.tap(find.byKey(const ValueKey('workspace-name-save')));
        await tester.pumpAndSettle();

        expect(find.text('Release layout before rename'), findsNothing);
        expect(find.text('Release layout after rename'), findsOneWidget);
        final renamed = app.savedWorkspaces.single;
        expect(renamed.name, 'Release layout after rename');
        expect(renamed.hostIds, const [_hostA, _hostB]);
        expect(renamed.activeIndex, 1);
        expect(renamed.panes.map((pane) => pane.paneId), const [
          _paneA,
          _paneB,
        ]);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'creates a three-leaf nested split with per-node geometry and active pane',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      var connectorCalls = 0;
      final app =
          _NestedWorkspaceTestApp(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    connectorCalls++;
                    throw StateError('Preview and save must not connect');
                  },
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.savedWorkspaces
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [
              HostRecord(
                id: _hostA,
                name: 'Build host',
                address: 'build.example.test',
                username: 'builder',
              ),
              HostRecord(
                id: _hostB,
                name: 'Database host',
                address: 'db.example.test',
                username: 'operator',
              ),
              HostRecord(
                id: _replacementHost,
                name: 'Ops host',
                address: 'ops.example.test',
                username: 'ops',
              ),
            ]);

      try {
        await tester.pumpWidget(_shell(app));
        await tester.pumpAndSettle();
        final createButton = find.byKey(
          const ValueKey('workspace-create-split'),
        );
        await tester.ensureVisible(createButton);
        await tester.tap(createButton);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('workspace-split-name')),
          'nested build layout',
        );
        await tester.tap(
          find.byKey(const ValueKey('workspace-split-target-pane-0')),
        );
        final addPane = find.byKey(const ValueKey('workspace-split-add-pane'));
        await tester.drag(
          find.byType(SingleChildScrollView).last,
          const Offset(0, -420),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(addPane);
        await tester.pumpAndSettle();
        await tester.tap(addPane);
        await tester.pumpAndSettle();

        expect(find.text('Terminal panes · 3/8'), findsOneWidget);
        final newPaneHost = find.byKey(
          const ValueKey('workspace-split-second-host'),
        );
        await tester.ensureVisible(newPaneHost);
        await tester.pumpAndSettle();
        await tester.tap(newPaneHost);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ops host · ops.example.test:22').last);
        await tester.pumpAndSettle();

        final rootAxis = find.byKey(const ValueKey('workspace-split-axis'));
        await tester.ensureVisible(rootAxis);
        await tester.pumpAndSettle();
        await tester.tap(rootAxis);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stacked (top/bottom)').last);
        await tester.pumpAndSettle();

        final rootRatio = find.byKey(const ValueKey('workspace-split-ratio'));
        await tester.ensureVisible(rootRatio);
        await tester.pumpAndSettle();
        await tester.enterText(rootRatio, '60');
        final innerRatio = find
            .byWidgetPredicate(
              (widget) =>
                  widget is TextFormField &&
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'workspace-split-ratio',
                  ),
            )
            .at(1);
        await tester.ensureVisible(innerRatio);
        await tester.pumpAndSettle();
        await tester.enterText(innerRatio, '40');

        final activePane = find.byKey(
          const ValueKey('workspace-split-active-pane'),
        );
        await tester.ensureVisible(activePane);
        await tester.pumpAndSettle();
        await tester.tap(activePane);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pane 2 · Ops host').last);
        await tester.pumpAndSettle();

        final preview = find.byKey(
          const ValueKey('workspace-split-draft-preview'),
        );
        await tester.ensureVisible(preview);
        await tester.pumpAndSettle();
        final rootPreview = tester.widget<Flex>(
          find.byKey(const ValueKey('workspace-split-flex-vertical')),
        );
        expect(
          rootPreview.children.whereType<Expanded>().map((pane) => pane.flex),
          [6000, 4000],
        );
        final nestedPreview = tester.widget<Flex>(
          find.byKey(
            const ValueKey('workspace-split-nested-1-flex-horizontal'),
          ),
        );
        expect(
          nestedPreview.children.whereType<Expanded>().map((pane) => pane.flex),
          [4000, 6000],
        );
        expect(
          find.descendant(of: preview, matching: find.text('Pane 1')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: preview, matching: find.text('Pane 2')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: preview, matching: find.text('Pane 3')),
          findsOneWidget,
        );
        expect(find.text('Build host'), findsOneWidget);
        expect(find.text('Ops host'), findsOneWidget);
        expect(find.text('Connect'), findsNothing);
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);

        final saveButton = find.byKey(const ValueKey('workspace-split-save'));
        await tester.ensureVisible(saveButton);
        await tester.tap(saveButton);
        await tester.pumpAndSettle();

        final saved = app.savedWorkspace!;
        expect(saved.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
        expect(saved.name, 'nested build layout');
        expect(saved.hostIds, [_hostA, _replacementHost, _hostB]);
        expect(saved.activePaneId, saved.panes[1].paneId);
        expect(saved.panes.map((pane) => pane.paneId).toSet(), hasLength(3));
        final tree = saved.layoutTree!;
        expect(tree.axis, WorkspaceSplitAxis.vertical);
        expect(tree.splitRatioBasisPoints, 6000);
        final nested = tree.first as WorkspaceSplitNode;
        expect(nested.axis, WorkspaceSplitAxis.horizontal);
        expect(nested.splitRatioBasisPoints, 4000);
        expect((nested.first as WorkspaceTerminalNode).hostId, _hostA);
        expect(
          (nested.second as WorkspaceTerminalNode).hostId,
          _replacementHost,
        );
        expect((tree.second as WorkspaceTerminalNode).hostId, _hostB);
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'caps the split creator at eight panes and allows remove then add back',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      var connectorCalls = 0;
      final app =
          _NestedWorkspaceTestApp(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    connectorCalls++;
                    throw StateError('Creating a layout must not connect');
                  },
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.savedWorkspaces
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [
              HostRecord(
                id: _hostA,
                name: 'Build host',
                address: 'build.example.test',
                username: 'builder',
              ),
              HostRecord(
                id: _hostB,
                name: 'Database host',
                address: 'db.example.test',
                username: 'operator',
              ),
              HostRecord(
                id: _replacementHost,
                name: 'Ops host',
                address: 'ops.example.test',
                username: 'ops',
              ),
            ]);

      Future<void> splitPane(int paneIndex) async {
        final target = find.byKey(
          ValueKey('workspace-split-target-pane-$paneIndex'),
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        final addPane = find.byKey(const ValueKey('workspace-split-add-pane'));
        await tester.ensureVisible(addPane);
        await tester.pumpAndSettle();
        await tester.tap(addPane);
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(_shell(app));
        await tester.pumpAndSettle();
        final createButton = find.byKey(
          const ValueKey('workspace-create-split'),
        );
        await tester.ensureVisible(createButton);
        await tester.tap(createButton);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('workspace-split-name')),
          'maximum eight pane layout',
        );

        for (final paneIndex in [1, 3, 1, 4, 3, 7]) {
          await splitPane(paneIndex - 1);
        }

        expect(find.text('Terminal panes · 8/8'), findsOneWidget);
        final addPane = find.byKey(const ValueKey('workspace-split-add-pane'));
        expect(tester.widget<OutlinedButton>(addPane).onPressed, isNull);

        final paneEight = find.byKey(
          const ValueKey('workspace-split-target-pane-7'),
        );
        await tester.ensureVisible(paneEight);
        await tester.pumpAndSettle();
        await tester.tap(paneEight);
        await tester.pumpAndSettle();
        final removeEight = find.byKey(
          const ValueKey('workspace-tree-remove-pane-7'),
        );
        expect(tester.widget<IconButton>(removeEight).onPressed, isNotNull);
        await tester.ensureVisible(removeEight);
        await tester.tap(removeEight);
        await tester.pumpAndSettle();
        expect(find.text('Terminal panes · 7/8'), findsOneWidget);

        await splitPane(6);
        expect(find.text('Terminal panes · 8/8'), findsOneWidget);
        expect(tester.widget<OutlinedButton>(addPane).onPressed, isNull);

        final hostEight = find.byKey(
          const ValueKey('workspace-tree-host-field-7'),
        );
        await tester.ensureVisible(hostEight);
        await tester.pumpAndSettle();
        await tester.tap(hostEight);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Build host · build.example.test:22').last);
        await tester.pumpAndSettle();

        final activePane = find.byKey(
          const ValueKey('workspace-split-active-pane'),
        );
        await tester.ensureVisible(activePane);
        await tester.pumpAndSettle();
        await tester.tap(activePane);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pane 8 · Build host').last);
        await tester.pumpAndSettle();

        final saveButton = find.byKey(const ValueKey('workspace-split-save'));
        await tester.ensureVisible(saveButton);
        await tester.tap(saveButton);
        await tester.pumpAndSettle();

        expect(app.savedWorkspace, isNotNull);
        expect(app.savedWorkspace!.panes, hasLength(8));
        expect(app.savedWorkspace!.hostIds, everyElement(isNotEmpty));
        expect(app.savedWorkspace!.activeIndex, 7);
        expect(app.savedWorkspace!.panes.last.hostId, _hostA);
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'nested saved preview disables only missing leaf, repair preserves tree, and explicit Connect renders the recursive live layout',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final connections = <String, _RecordingConnection>{};
      final app =
          _NestedWorkspaceTestApp(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async {
                    final connection = _RecordingConnection();
                    connections[host.id] = connection;
                    return connection;
                  },
            )
            ..session = AuthSession(
              accountId: 'nested-workspace-account',
              accessToken: 'nested-workspace-access',
              expiresIn: 3600,
              refreshToken: 'nested-workspace-refresh',
              deviceId: identity.deviceId,
              vaults: const [],
            )
            ..identity = identity
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.savedWorkspaces
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..credentials.addAll(const [
              CredentialRecord(
                id: 'nested-credential-a',
                name: 'Build key',
                username: 'builder',
              ),
              CredentialRecord(
                id: 'nested-credential-b',
                name: 'Database key',
                username: 'operator',
              ),
              CredentialRecord(
                id: 'nested-credential-c',
                name: 'Ops key',
                username: 'ops',
              ),
            ])
            ..hosts.addAll(const [
              HostRecord(
                id: _hostA,
                name: 'Build host',
                address: 'build.example.test',
                username: 'builder',
                credentialId: 'nested-credential-a',
              ),
              HostRecord(
                id: _hostB,
                name: 'Database host',
                address: 'db.example.test',
                username: 'operator',
                credentialId: 'nested-credential-b',
              ),
              HostRecord(
                id: _replacementHost,
                name: 'Ops host',
                address: 'ops.example.test',
                username: 'ops',
                credentialId: 'nested-credential-c',
              ),
            ]);
      final workspace = WorkspaceRecord.fromSplitTree(
        id: _savedWorkspaceId,
        name: 'Build plus data',
        activePaneId: _paneMissing,
        layoutTree: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.vertical,
          splitRatioBasisPoints: 6500,
          first: WorkspaceSplitNode(
            axis: WorkspaceSplitAxis.horizontal,
            splitRatioBasisPoints: 4000,
            first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostA),
            second: WorkspaceTerminalNode(
              paneId: _paneMissing,
              hostId: _missingHost,
            ),
          ),
          second: WorkspaceTerminalNode(paneId: _paneB, hostId: _hostB),
        ),
      );
      app.savedWorkspaces.add(workspace);

      try {
        await tester.pumpWidget(_shell(app));
        await tester.pumpAndSettle();
        expect(find.text('Active Pane 2'), findsOneWidget);
        expect(find.text('Split 1 · Stacked · 65/35'), findsOneWidget);
        expect(find.text('Split 2 · Side by side · 40/60'), findsOneWidget);
        expect(find.text('Replace Host'), findsOneWidget);

        final previewButton = find.byKey(
          const ValueKey('workspace-preview-$_savedWorkspaceId'),
        );
        await tester.ensureVisible(previewButton);
        await tester.tap(previewButton);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<Flex>(
                find.byKey(const ValueKey('workspace-split-flex-vertical')),
              )
              .direction,
          Axis.vertical,
        );
        expect(
          tester
              .widget<Flex>(
                find.byKey(
                  const ValueKey('workspace-split-nested-1-flex-horizontal'),
                ),
              )
              .direction,
          Axis.horizontal,
        );

        for (final pane in workspace.panes) {
          final button = tester.widget<OutlinedButton>(
            find.byKey(
              ValueKey('workspace-connect-$_savedWorkspaceId-${pane.paneId}'),
            ),
          );
          expect(button.onPressed != null, pane.hostId != _missingHost);
        }
        expect(app.terminalTabs, isEmpty);
        expect(connections, isEmpty);

        app.showWorkspacePage(WorkspacePage.savedWorkspaces);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Replace Host'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(ValueKey('workspace-host-choice-$_replacementHost')),
        );
        await tester.pumpAndSettle();

        final repaired = app.savedWorkspace!;
        expect(
          repaired.panes.map((pane) => pane.paneId),
          workspace.panes.map((pane) => pane.paneId),
        );
        expect(repaired.activePaneId, workspace.activePaneId);
        expect(repaired.hostIds, [_hostA, _replacementHost, _hostB]);
        expect(repaired.layoutTree!.axis, WorkspaceSplitAxis.vertical);
        expect(repaired.layoutTree!.splitRatioBasisPoints, 6500);
        final repairedInner = repaired.layoutTree!.first as WorkspaceSplitNode;
        expect(repairedInner.axis, WorkspaceSplitAxis.horizontal);
        expect(repairedInner.splitRatioBasisPoints, 4000);
        expect(
          (repairedInner.second as WorkspaceTerminalNode).paneId,
          _paneMissing,
        );

        app.stageWorkspace(_savedWorkspaceId);
        await tester.pumpAndSettle();
        for (final pane in repaired.panes) {
          final connectButton = find.byKey(
            ValueKey('workspace-connect-$_savedWorkspaceId-${pane.paneId}'),
          );
          await tester.ensureVisible(connectButton);
          await tester.tap(connectButton);
          await tester.pumpAndSettle();
        }
        expect(
          connections.keys,
          containsAll([_hostA, _replacementHost, _hostB]),
        );
        expect(find.byType(TerminalView), findsNWidgets(3));
        expect(
          find.byKey(const ValueKey('workspace-live-split-flex-vertical')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey('workspace-live-split-nested-1-flex-horizontal'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<Flex>(
                find.byKey(
                  const ValueKey('workspace-live-split-flex-vertical'),
                ),
              )
              .children
              .whereType<Expanded>()
              .map((pane) => pane.flex),
          [6500, 3500],
        );
        expect(
          tester
              .widget<Flex>(
                find.byKey(
                  const ValueKey(
                    'workspace-live-split-nested-1-flex-horizontal',
                  ),
                ),
              )
              .children
              .whereType<Expanded>()
              .map((pane) => pane.flex),
          [4000, 6000],
        );

        final lastPaneTab = app.workspacePaneTerminalTab(
          _savedWorkspaceId,
          _paneB,
        )!;
        unawaited(app.closeTerminalTab(lastPaneTab.id));
        await tester.pumpAndSettle();
        expect(find.byType(TerminalView), findsNWidgets(2));
        expect(
          find.byKey(const ValueKey('workspace-live-split-flex-vertical')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey(
              'workspace-live-split-connect-$_savedWorkspaceId-$_paneB',
            ),
          ),
          findsOneWidget,
        );
        final disconnectedPaneButton = tester.widget<TextButton>(
          find.byKey(
            const ValueKey(
              'workspace-live-split-connect-$_savedWorkspaceId-$_paneB',
            ),
          ),
        );
        expect(disconnectedPaneButton.onPressed, isNotNull);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'divider controls retain their split identity when an earlier subtree grows',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          _NestedWorkspaceTestApp(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorForTesting:
                  ({
                    required host,
                    required credential,
                    required verifyHostKey,
                  }) async =>
                      throw StateError('Editing the layout must not connect'),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.savedWorkspaces
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [
              HostRecord(
                id: _hostA,
                name: 'Build host',
                address: 'build.example.test',
                username: 'builder',
              ),
              HostRecord(
                id: _hostB,
                name: 'Database host',
                address: 'db.example.test',
                username: 'operator',
              ),
              HostRecord(
                id: _replacementHost,
                name: 'Ops host',
                address: 'ops.example.test',
                username: 'ops',
              ),
            ]);

      Finder ratioFields() => find.byWidgetPredicate(
        (widget) =>
            widget is TextFormField &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'workspace-split-ratio',
            ),
      );
      Finder axisFields() => find.byWidgetPredicate(
        (widget) => widget is DropdownButtonFormField<WorkspaceSplitAxis>,
      );

      Future<void> addPaneAround(int paneIndex) async {
        final target = find.byKey(
          ValueKey('workspace-split-target-pane-$paneIndex'),
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        final addPane = find.byKey(const ValueKey('workspace-split-add-pane'));
        await tester.ensureVisible(addPane);
        await tester.pumpAndSettle();
        await tester.tap(addPane);
        await tester.pumpAndSettle();
      }

      Future<void> setRatio(int index, String value) async {
        final field = ratioFields().at(index);
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, value);
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(_shell(app));
        await tester.pumpAndSettle();
        final createButton = find.byKey(
          const ValueKey('workspace-create-split'),
        );
        await tester.ensureVisible(createButton);
        await tester.tap(createButton);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('workspace-split-name')),
          'stable divider editor',
        );

        // Create a divider in each side of the root. Then give the later
        // sibling a distinct axis and ratio before inserting ahead of it.
        await addPaneAround(0);
        await addPaneAround(2);
        await setRatio(1, '42');
        await setRatio(2, '55');
        final laterAxis = axisFields().at(2);
        await tester.ensureVisible(laterAxis);
        await tester.pumpAndSettle();
        await tester.tap(laterAxis);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stacked (top/bottom)').last);
        await tester.pumpAndSettle();

        // This new divider is inserted before the later sibling in preorder.
        await addPaneAround(0);

        final ratioCount = ratioFields().evaluate().length;
        expect(ratioCount, 4);
        final displayedRatios = <String>[];
        for (var index = 0; index < ratioCount; index++) {
          final field = ratioFields().at(index);
          final editable = find.descendant(
            of: field,
            matching: find.byType(EditableText),
          );
          displayedRatios.add(
            tester.widget<EditableText>(editable).controller.text,
          );
        }
        expect(displayedRatios, ['50', '42', '50', '55']);

        final displayedAxes = <WorkspaceSplitAxis>[];
        final axisCount = axisFields().evaluate().length;
        expect(axisCount, 4);
        for (var index = 0; index < axisCount; index++) {
          final dropdown = find.descendant(
            of: axisFields().at(index),
            matching: find.byType(DropdownButton<WorkspaceSplitAxis>),
          );
          displayedAxes.add(
            tester.widget<DropdownButton<WorkspaceSplitAxis>>(dropdown).value!,
          );
        }
        expect(displayedAxes, [
          WorkspaceSplitAxis.horizontal,
          WorkspaceSplitAxis.horizontal,
          WorkspaceSplitAxis.horizontal,
          WorkspaceSplitAxis.vertical,
        ]);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );
}

Widget _shell(AppController app) => MaterialApp(
  theme: buildAppTheme(),
  home: AnimatedBuilder(
    animation: app,
    builder: (context, _) => AppShell(controller: app),
  ),
);

class _NestedWorkspaceTestApp extends AppController {
  _NestedWorkspaceTestApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required super.sshConnectorForTesting,
  });

  WorkspaceRecord? savedWorkspace;

  @override
  Future<void> saveWorkspaceLayout({
    required String name,
    required WorkspaceLayoutNode layoutTree,
    required String activePaneId,
  }) async {
    final record = WorkspaceRecord.fromSplitTree(
      id: _savedWorkspaceId,
      name: name,
      layoutTree: layoutTree,
      activePaneId: activePaneId,
    );
    savedWorkspace = record;
    savedWorkspaces.add(record);
    notifyListeners();
  }

  @override
  Future<void> replaceWorkspaceHost(
    String workspaceId,
    String paneId,
    String replacementHostId,
  ) async {
    final existing = savedWorkspaces.singleWhere(
      (workspace) => workspace.id == workspaceId,
    );
    final currentTree = existing.layoutTree!;
    WorkspaceLayoutNode replace(WorkspaceLayoutNode node) {
      if (node is WorkspaceTerminalNode) {
        return WorkspaceTerminalNode(
          paneId: node.paneId,
          hostId: node.paneId == paneId ? replacementHostId : node.hostId,
        );
      }
      final split = node as WorkspaceSplitNode;
      return WorkspaceSplitNode(
        axis: split.axis,
        splitRatioBasisPoints: split.splitRatioBasisPoints,
        first: replace(split.first),
        second: replace(split.second),
      );
    }

    final repaired = WorkspaceRecord.fromSplitTree(
      id: existing.id,
      name: existing.name,
      layoutTree: replace(currentTree),
      activePaneId: existing.activePaneId,
      revisionId: existing.revisionId,
    );
    savedWorkspace = repaired;
    final index = savedWorkspaces.indexWhere(
      (workspace) => workspace.id == workspaceId,
    );
    savedWorkspaces[index] = repaired;
    notifyListeners();
  }

  @override
  Future<void> renameWorkspace(String workspaceId, String name) async {
    final index = savedWorkspaces.indexWhere(
      (workspace) => workspace.id == workspaceId,
    );
    final renamed = savedWorkspaces[index].copyWith(name: name);
    savedWorkspaces[index] = renamed;
    savedWorkspace = renamed;
    notifyListeners();
  }
}

class _RecordingConnection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );

  void emit(String text) => _output.add(text);

  @override
  late final portForwards = SshPortForwardManager(
    _FakeSshClient(),
    platform: const _UnsupportedPortForwardPlatform(),
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    await portForwards.closeAll();
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshClient extends Fake implements SSHClient {}

class _UnsupportedPortForwardPlatform implements SshPortForwardPlatform {
  const _UnsupportedPortForwardPlatform();

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => 'Unsupported in this test.';

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => throw UnsupportedError('Port forwarding is not used by this test.');
}
