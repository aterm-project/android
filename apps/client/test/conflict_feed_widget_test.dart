import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
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
const _conflictId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _branchRevision = '44444444-4444-4444-8444-444444444444';
const _headRevision = '55555555-5555-4555-8555-555555555555';
const _deviceId = '66666666-6666-4666-8666-666666666666';
const _generation = '77777777-7777-4777-8777-777777777777';

ConflictFeedReviewItem _item({
  String conflictId = _conflictId,
  String recordId = _recordId,
  bool verified = true,
  bool resolved = false,
  bool headCommitted = true,
  bool headExists = true,
  bool headDeleted = false,
  String? resolutionState,
  String? operation = 'update',
  String? keyEpoch = '2',
}) => ConflictFeedReviewItem(
  conflictId: conflictId,
  recordId: recordId,
  seq: '17',
  createdAt: '2026-09-27T18:00:00Z',
  serverGeneration: _generation,
  partitionId: 'partition-1',
  baseRevisionId: _headRevision,
  branchRevisionId: _branchRevision,
  branchDeviceId: verified ? _deviceId : null,
  branchOperation: operation,
  keyEpoch: keyEpoch,
  membershipVersion: '3',
  currentHeadRevisionId: _headRevision,
  currentHeadExists: headExists,
  currentHeadDeleted: headDeleted,
  currentHeadCommitted: headCommitted,
  isVerified: verified,
  verificationError: verified ? null : 'Conflict branch cannot be verified.',
  isResolved: resolved,
  resolutionState: resolutionState,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'badge counts a server conflict shared with a local branch once',
    () async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..openConflicts = [
              {'conflict_id': _conflictId, 'record_id': _recordId},
            ]
            ..feedConflictItems = [_item()];
      try {
        expect(app.unresolvedConflictCount, 1);
      } finally {
        app.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'local conflict card shows verified feed operation and head status only',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.sync
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '2',
              membershipVersion: '3',
            )
            ..openConflicts = [
              {
                'conflict_id': _conflictId,
                'record_id': _recordId,
                'kind': 'delete_edit',
                'branch_envelope': {
                  'header': {
                    'revision_id': _branchRevision,
                    'operation': 'update',
                  },
                },
                'remote_envelope': {
                  'header': {
                    'revision_id': _headRevision,
                    'operation': 'delete',
                  },
                },
              },
            ]
            ..feedConflictItems = [_item(headDeleted: true)];

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();

        await tester.ensureVisible(find.text('Branch actions'));
        await tester.pump();
        expect(find.text('delete edit'), findsOneWidget);
        expect(find.text('Branch actions'), findsOneWidget);
        expect(find.text('Change'), findsOneWidget);
        expect(find.text('Current server version'), findsOneWidget);
        expect(find.text('Deleted'), findsOneWidget);
        expect(find.text('No pending cross-device branches'), findsOneWidget);
        expect(find.text('Keep this device version'), findsOneWidget);
        expect(find.text('Use synced version'), findsOneWidget);

        app
          ..feedConflictItems = [
            _item(
              verified: false,
              operation: 'untrusted operation',
              headDeleted: true,
            ),
          ]
          ..notifyListeners();
        await tester.pump();

        expect(find.text("The cross-device branch isn't verified yet; action and server version details are hidden."), findsOneWidget);
        expect(find.text('Branch actions'), findsNothing);
        expect(find.text('Current server version'), findsNothing);
        expect(find.text('untrusted operation'), findsNothing);
        expect(find.text('Deleted'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('redacted local draft is visible and exposes no push action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sync
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '2',
            membershipVersion: '3',
          )
          ..openConflicts = [
            {
              'conflict_id': _conflictId,
              'record_id': _recordId,
              'kind': 'record_redacted',
              'state': 'redacted_draft',
              'branch_envelope': {
                'header': {'record_id': _recordId},
                'ciphertext': 'encrypted-local-draft',
              },
              'remote_envelope': const {},
              'redaction_proof': {'redaction_id': 'proof-identifier'},
            },
          ];

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pump();

      expect(find.text('redacted draft'), findsOneWidget);
      expect(find.textContaining('The server provided a signed cleanup receipt for this record. Pending local changes were isolated as a read-only draft; to avoid recreating the cleaned record, the draft can\'t be kept, merged or uploaded here.'), findsOneWidget);
      expect(find.text('Redaction proof  proof-identifier'), findsOneWidget);
      expect(find.text('Keep this device version'), findsNothing);
      expect(find.text('Use synced version'), findsNothing);
      expect(find.text('Adopt this branch'), findsNothing);
      expect(find.text('Keep current version'), findsNothing);
      expect(find.text('Re-sign and sync'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'verified inbox branch exposes guarded choices and confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.sync
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '2',
              membershipVersion: '3',
            )
            ..feedConflictItems = [_item()];

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();

        expect(find.text('Cross-device conflict inbox'), findsOneWidget);
        await tester.ensureVisible(find.text('Source device'));
        await tester.pump();
        expect(find.text('Source device'), findsOneWidget);
        expect(find.text('66666666…66666'), findsOneWidget);
        final adopt = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Adopt this branch'),
            matching: find.byType(OutlinedButton),
          ),
        );
        final retain = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Keep current version'),
            matching: find.byType(OutlinedButton),
          ),
        );
        expect(adopt.onPressed, isNotNull);
        expect(retain.onPressed, isNotNull);

        await tester.ensureVisible(find.text('Adopt this branch'));
        await tester.pump();
        await tester.tap(find.text('Adopt this branch'));
        await tester.pumpAndSettle();
        expect(find.text('Adopt the verified device branch?'), findsOneWidget);
        expect(find.text('Re-sign and sync'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'local branch paired with feed item can retain the committed head',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.sync
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '2',
              membershipVersion: '3',
            )
            ..savedWorkspaces.add(
              WorkspaceRecord.fromHostIds(
                name: 'Conflict layout',
                hostIds: const ['99999999-9999-4999-8999-999999999999'],
                id: _recordId,
              ),
            )
            ..openConflicts = [
              {
                'conflict_id': _conflictId,
                'record_id': _recordId,
                'kind': 'concurrent_edit',
                'branch_envelope': {
                  'header': {
                    'revision_id': _branchRevision,
                    'operation': 'update',
                  },
                },
                'remote_envelope': {
                  'header': {
                    'revision_id': _headRevision,
                    'operation': 'update',
                  },
                },
              },
            ]
            ..feedConflictItems = [_item()];

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();

        final retain = find.byKey(
          const ValueKey('retain-current-feed-conflict-$_conflictId'),
        );
        await tester.ensureVisible(retain);
        await tester.pump();
        expect(find.text('Cross-device conflict inbox'), findsOneWidget);
        expect(find.text('Adopt this branch'), findsOneWidget);
        expect(find.text('Keep current version'), findsOneWidget);
        expect(tester.widget<OutlinedButton>(retain).onPressed, isNotNull);

        final adopt = find.byKey(
          const ValueKey('adopt-feed-conflict-$_conflictId'),
        );
        expect(tester.widget<OutlinedButton>(adopt).onPressed, isNotNull);
        await tester.ensureVisible(adopt);
        await tester.tap(adopt);
        await tester.pumpAndSettle();
        expect(find.text('Adopt the verified device branch?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.tap(retain);
        await tester.pumpAndSettle();
        expect(find.text('Keep the current committed version?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        app
          ..feedConflictItems = [
            _item(recordId: '88888888-8888-4888-8888-888888888888'),
          ]
          ..notifyListeners();
        await tester.pump();
        expect(retain, findsNothing);
        expect(adopt, findsNothing);

        app
          ..feedConflictItems = [_item()]
          ..notifyListeners();
        await tester.pump();

        app
          ..feedConflictItems = [_item(resolutionState: 'pending')]
          ..notifyListeners();
        await tester.pump();
        expect(tester.widget<OutlinedButton>(retain).onPressed, isNull);
        expect(tester.widget<OutlinedButton>(adopt).onPressed, isNull);
        expect(
          tester
              .widget<OutlinedButton>(
                find.ancestor(
                  of: find.text('Keep this device version'),
                  matching: find.byType(OutlinedButton),
                ),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(
                  const ValueKey('workspace-conflict-copy-$_conflictId'),
                ),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.ancestor(
                  of: find.text('Use synced version'),
                  matching: find.byType(FilledButton),
                ),
              )
              .onPressed,
          isNull,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets(
    'unverified, pending, and uncommitted states disable unsafe actions',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.sync
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '2',
              membershipVersion: '3',
            )
            ..feedConflictItems = [
              _item(
                verified: false,
                operation: 'untrusted operation',
                keyEpoch: '999999999999999999999999',
              ),
            ];

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pump();

        await tester.ensureVisible(find.text('Adopt this branch'));
        await tester.pump();
        expect(find.text('Branch not verified yet; kept read-only'), findsOneWidget);
        expect(find.text('untrusted operation'), findsNothing);
        expect(find.text('999999999999999999999999'), findsNothing);
        var adopt = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Adopt this branch'),
            matching: find.byType(OutlinedButton),
          ),
        );
        var retain = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Keep current version'),
            matching: find.byType(OutlinedButton),
          ),
        );
        expect(adopt.onPressed, isNull);
        expect(retain.onPressed, isNull);

        app
          ..feedConflictItems = [_item(resolutionState: 'pending')]
          ..notifyListeners();
        await tester.pump();
        expect(find.text('Waiting for this device to sync the selected version'), findsOneWidget);
        adopt = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Adopt this branch'),
            matching: find.byType(OutlinedButton),
          ),
        );
        expect(adopt.onPressed, isNull);

        app
          ..feedConflictItems = [_item(headCommitted: false)]
          ..notifyListeners();
        await tester.pump();
        retain = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Keep current version'),
            matching: find.byType(OutlinedButton),
          ),
        );
        expect(retain.onPressed, isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('adoption failures are explained and the action can be retried', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _FailingConflictAppController(sodium, database)
      ..stage = ClientStage.workspace
      ..page = WorkspacePage.sync
      ..activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '2',
        membershipVersion: '3',
      )
      ..feedConflictItems = [_item()];

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Adopt this branch'));
      await tester.pump();
      await tester.tap(find.text('Adopt this branch'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Re-sign and sync'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't adopt the branch"), findsOneWidget);
      expect(find.textContaining('服务器暂时拒绝该分支。'), findsOneWidget);
      final adopt = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Adopt this branch'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(adopt.onPressed, isNotNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets('resolved inbox events stay available as read-only history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.sync
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '2',
            membershipVersion: '3',
          )
          ..feedConflictItems = [
            _item(resolved: true, resolutionState: 'resolved'),
          ];

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Processed branches · 1'));
      await tester.pump();
      expect(find.text('Processed branches · 1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('conflict-feed-$_conflictId')),
        findsNothing,
      );

      await tester.tap(find.text('Processed branches · 1'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conflict-feed-$_conflictId')),
        findsOneWidget,
      );
      expect(find.text('Resolved'), findsNWidgets(2));
      expect(find.text('Adopt this branch'), findsOneWidget);
      final adopt = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Adopt this branch'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(adopt.onPressed, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

class _FailingConflictAppController extends AppController {
  _FailingConflictAppController(SodiumSumo sodium, ClientDatabase database)
    : super(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
      );

  @override
  Future<void> adoptRemoteConflict(String conflictId) async {
    throw const ApiException(
      statusCode: 409,
      code: 'CONFLICT_BRANCH_REJECTED',
      message: '服务器暂时拒绝该分支。',
    );
  }
}
