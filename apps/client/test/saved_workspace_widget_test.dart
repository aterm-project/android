import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _workspaceId = '22222222-2222-4222-8222-222222222222';
const _presentHostId = '33333333-3333-4333-8333-333333333333';
const _missingHostId = '44444444-4444-4444-8444-444444444444';
const _secondHostId = '55555555-5555-4555-8555-555555555555';
const _createdSplitId = '66666666-6666-4666-8666-666666666666';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'preview stays disconnected and a deleted Host remains a missing reference',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      var connectorCalls = 0;
      final app =
          AppController(
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
                    throw StateError('connector must not run during preview');
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
            ..hosts.add(
              const HostRecord(
                id: _presentHostId,
                name: 'Visible host',
                address: 'visible.example.test',
                username: 'tester',
              ),
            )
            ..savedWorkspaces.add(
              WorkspaceRecord.fromHostIds(
                id: _workspaceId,
                name: 'Staging layout',
                hostIds: const [_presentHostId, _missingHostId],
                activeIndex: 1,
              ),
            );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Missing Host'), findsOneWidget);
        expect(find.text('Replace Host'), findsOneWidget);
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);

        final previewButton = find.byKey(
          const ValueKey('workspace-preview-$_workspaceId'),
        );
        await tester.ensureVisible(previewButton);
        await tester.pumpAndSettle();
        await tester.tap(previewButton);
        await tester.pumpAndSettle();

        expect(app.page, WorkspacePage.terminal);
        expect(app.activeSavedWorkspaceId, _workspaceId);
        expect(find.text('Staging layout'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('workspace-clear-staged')),
          findsOneWidget,
        );
        final workspace = app.savedWorkspaces.single;
        final presentPane = workspace.panes.firstWhere(
          (pane) => pane.hostId == _presentHostId,
        );
        final missingPane = workspace.panes.firstWhere(
          (pane) => pane.hostId == _missingHostId,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(
                  ValueKey(
                    'workspace-connect-$_workspaceId-${presentPane.paneId}',
                  ),
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(
                  ValueKey(
                    'workspace-connect-$_workspaceId-${missingPane.paneId}',
                  ),
                ),
              )
              .onPressed,
          isNull,
        );

        app.hosts.clear();
        app.notifyListeners();
        await tester.pump();
        expect(find.textContaining('Missing Host'), findsWidgets);
        expect(app.terminalTabs, isEmpty);
        expect(connectorCalls, 0);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'split creation preserves lowercase names and Host order without connecting',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      var connectorCalls = 0;
      const workspaceName = 'workspace-split-regression';
      final app =
          _SplitWorkspaceTestApp(
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
                    throw StateError('Connect must remain an explicit action');
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
                id: _presentHostId,
                name: 'Build host',
                address: 'build.example.test',
                username: 'builder',
              ),
              HostRecord(
                id: _secondHostId,
                name: 'Database host',
                address: 'db.example.test',
                username: 'operator',
              ),
            ]);

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final createButton = find.byKey(
          const ValueKey('workspace-create-split'),
        );
        await tester.ensureVisible(createButton);
        await tester.pumpAndSettle();
        await tester.tap(createButton);
        await tester.pumpAndSettle();

        expect(find.text('Create split Workspace'), findsNWidgets(2));
        void expectNameRetained() {
          final field = tester.widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('workspace-split-name')),
              matching: find.byType(EditableText),
            ),
          );
          expect(field.textCapitalization, TextCapitalization.none);
          expect(field.controller.text, workspaceName);
        }

        await tester.enterText(
          find.byKey(const ValueKey('workspace-split-name')),
          workspaceName,
        );
        expectNameRetained();

        await tester.tap(
          find.byKey(const ValueKey('workspace-split-first-host')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Database host · db.example.test:22').last);
        await tester.pumpAndSettle();
        expectNameRetained();
        await tester.tap(
          find.byKey(const ValueKey('workspace-split-second-host')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Build host · build.example.test:22').last);
        await tester.pumpAndSettle();
        expectNameRetained();

        await tester.ensureVisible(
          find.byKey(const ValueKey('workspace-split-axis')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace-split-axis')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Stacked (top/bottom)').last);
        await tester.pumpAndSettle();
        expectNameRetained();
        final splitRatio = find.byKey(const ValueKey('workspace-split-ratio'));
        await tester.ensureVisible(splitRatio);
        await tester.pumpAndSettle();
        await tester.enterText(splitRatio, '60');
        await tester.pump();
        expectNameRetained();

        final draftPreview = tester.widget<Flex>(
          find.byKey(const ValueKey('workspace-split-flex-vertical')),
        );
        expect(draftPreview.direction, Axis.vertical);
        expect(
          draftPreview.children.whereType<Expanded>().map((pane) => pane.flex),
          [6000, 4000],
        );
        expect(find.textContaining('Pane 1 · 60%'), findsOneWidget);
        expect(find.textContaining('Pane 2 · 40%'), findsOneWidget);
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);

        await tester.tap(find.byKey(const ValueKey('workspace-split-save')));
        await tester.pumpAndSettle();

        final saved = app.savedSplitWorkspace!;
        expect(saved.name, workspaceName);
        expect(saved.hostIds, [_secondHostId, _presentHostId]);
        expect(saved.splitAxis, WorkspaceSplitAxis.vertical);
        expect(saved.splitRatioBasisPoints, 6000);
        expect(saved.schemaVersion, workspaceNestedSplitLayoutSchemaVersion);
        final savedTree = saved.layoutTree!;
        expect(savedTree.axis, WorkspaceSplitAxis.vertical);
        expect(savedTree.splitRatioBasisPoints, 6000);
        expect(savedTree.first, isA<WorkspaceTerminalNode>());
        expect(savedTree.second, isA<WorkspaceTerminalNode>());
        expect(find.text('Split · 60/40'), findsOneWidget);
        expect(find.text('Stacked'), findsOneWidget);
        expect(find.text('Split 1 · Stacked · 60/40'), findsOneWidget);
        expect(find.text('Active Pane 1'), findsOneWidget);
        expect(connectorCalls, 0);
        expect(app.terminalTabs, isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'saved split preview renders both directions and disables missing Host',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      var connectorCalls = 0;
      final app =
          AppController(
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
                    throw StateError('Connect must remain an explicit action');
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
                id: _presentHostId,
                name: 'Visible host',
                address: 'visible.example.test',
                username: 'tester',
              ),
              HostRecord(
                id: _secondHostId,
                name: 'Standby host',
                address: 'standby.example.test',
                username: 'operator',
              ),
            ])
            ..savedWorkspaces.addAll([
              WorkspaceRecord.fromSplitHostIds(
                id: _workspaceId,
                name: 'Horizontal pair',
                hostIds: const [_presentHostId, _missingHostId],
                axis: WorkspaceSplitAxis.horizontal,
                splitRatioBasisPoints: 6500,
              ),
              WorkspaceRecord.fromSplitHostIds(
                id: _createdSplitId,
                name: 'Vertical pair',
                hostIds: const [_secondHostId, _presentHostId],
                axis: WorkspaceSplitAxis.vertical,
                splitRatioBasisPoints: 4000,
              ),
            ]);

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Horizontal pair'), findsOneWidget);
        expect(find.text('Vertical pair'), findsOneWidget);

        final layouts = <(String, WorkspaceSplitAxis, Axis)>[
          (_workspaceId, WorkspaceSplitAxis.horizontal, Axis.horizontal),
          (_createdSplitId, WorkspaceSplitAxis.vertical, Axis.vertical),
        ];
        for (var layoutIndex = 0; layoutIndex < layouts.length; layoutIndex++) {
          final (workspaceId, axis, direction) = layouts[layoutIndex];
          final previewButton = find.byKey(
            ValueKey('workspace-preview-$workspaceId'),
          );
          await tester.ensureVisible(previewButton);
          await tester.pumpAndSettle();
          await tester.tap(previewButton);
          await tester.pumpAndSettle();

          final preview = tester.widget<Flex>(
            find.byKey(ValueKey('workspace-split-flex-${axis.name}')),
          );
          expect(preview.direction, direction);
          final directionAndRatio = axis == WorkspaceSplitAxis.horizontal
              ? 'Side by side · 65/35'
              : 'Stacked · 40/60';
          expect(
            find.textContaining('Disconnected · $directionAndRatio'),
            findsOneWidget,
          );
          expect(
            find.textContaining('Connect panes explicitly'),
            findsOneWidget,
          );
          expect(find.textContaining('Pane 1'), findsOneWidget);
          expect(find.textContaining('Pane 2'), findsOneWidget);
          expect(app.terminalTabs, isEmpty);
          expect(connectorCalls, 0);

          final record = app.savedWorkspaces.singleWhere(
            (workspace) => workspace.id == workspaceId,
          );
          for (final (paneIndex, pane) in record.panes.indexed) {
            final button = tester.widget<OutlinedButton>(
              find.byKey(
                ValueKey('workspace-connect-$workspaceId-${pane.paneId}'),
              ),
            );
            final hostExists = app.hosts.any((host) => host.id == pane.hostId);
            expect(button.onPressed != null, hostExists);
            expect(
              find.textContaining(
                hostExists
                    ? app.hosts
                          .firstWhere((host) => host.id == pane.hostId)
                          .name
                    : 'Missing Host',
              ),
              findsWidgets,
              reason: 'pane ${paneIndex + 1} keeps its ordered Host reference',
            );
          }
          if (layoutIndex + 1 < layouts.length) {
            app.showWorkspacePage(WorkspacePage.savedWorkspaces);
            await tester.pumpAndSettle();
          }
        }
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );
}

class _SplitWorkspaceTestApp extends AppController {
  _SplitWorkspaceTestApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required super.sshConnectorForTesting,
  });

  WorkspaceRecord? savedSplitWorkspace;

  @override
  Future<void> saveWorkspaceLayout({
    required String name,
    required WorkspaceLayoutNode layoutTree,
    required String activePaneId,
  }) async {
    final workspace = WorkspaceRecord.fromSplitTree(
      id: _createdSplitId,
      name: name,
      layoutTree: layoutTree,
      activePaneId: activePaneId,
    );
    savedSplitWorkspace = workspace;
    savedWorkspaces.add(workspace);
    notifyListeners();
  }
}
