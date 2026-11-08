import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/domain/host_security_conflict_merge.dart';
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
const _recordId = '22222222-2222-4222-8222-222222222222';
const _conflictId = '33333333-3333-4333-8333-333333333333';
const _branchRevision = '44444444-4444-4444-8444-444444444444';
const _headRevision = '55555555-5555-4555-8555-555555555555';
const _nextHeadRevision = '66666666-6666-4666-8666-666666666666';
const _deviceId = '77777777-7777-4777-8777-777777777777';
const _generation = '88888888-8888-4888-8888-888888888888';

HostSecurityConflictMergePreview _preview({String head = _headRevision}) =>
    HostSecurityConflictMergePreview(
      conflictId: _conflictId,
      recordId: _recordId,
      branchRevisionId: _branchRevision,
      baseRevisionId: '99999999-9999-4999-8999-999999999999',
      currentHeadRevisionId: head,
      fields: const [
        HostSecurityFieldPreview(
          label: 'Address',
          base: 'prod.example.test',
          conflict: 'staging.example.test',
          current: 'prod.example.test',
        ),
        HostSecurityFieldPreview(
          label: 'Port',
          base: '22',
          conflict: '22',
          current: '2202',
        ),
        HostSecurityFieldPreview(
          label: 'Proxy settings',
          base: 'Not configured',
          conflict: '••••••••',
          current: '••••••••',
        ),
        HostSecurityFieldPreview(
          label: 'Jump Host route',
          base: 'Not configured',
          conflict: 'Host 12345678…',
          current: 'Host 87654321…',
        ),
        HostSecurityFieldPreview(
          label: 'Port forwarding',
          base: 'None',
          conflict: '1 forwarding rule(s)',
          current: 'None',
        ),
        HostSecurityFieldPreview(
          label: 'Host trust',
          base: 'No recorded trust',
          conflict: '•••••••• (configured)',
          current: '•••••••• (configured)',
        ),
      ],
    );

ConflictFeedReviewItem _feedItem({bool verified = true}) =>
    ConflictFeedReviewItem(
      conflictId: _conflictId,
      recordId: _recordId,
      seq: '17',
      createdAt: '2026-09-27T18:00:00Z',
      serverGeneration: _generation,
      partitionId: 'partition-1',
      baseRevisionId: _preview().baseRevisionId,
      branchRevisionId: _branchRevision,
      branchDeviceId: _deviceId,
      branchOperation: 'update',
      keyEpoch: '2',
      membershipVersion: '3',
      currentHeadRevisionId: _headRevision,
      currentHeadExists: true,
      currentHeadDeleted: false,
      currentHeadCommitted: true,
      isVerified: verified,
      verificationError: verified ? null : 'unverified',
      isResolved: false,
      resolutionState: null,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Host merge requires a tuple choice and displays masked review values',
    (tester) async {
      final fixture = await _fixture(
        previews: [_preview()],
        outcomes: [
          const HostSecurityConflictMergeOutcome.staged(
            revisionId: _nextHeadRevision,
          ),
        ],
      );
      try {
        await _pump(tester, fixture);
        await tester.pumpAndSettle();
        final opener = find.byKey(const ValueKey('host-security-merge-open'));
        expect(opener, findsOneWidget);
        await tester.ensureVisible(opener);
        await tester.tap(opener);
        // The underlying card shows an indeterminate spinner while the modal
        // is open; pump through the dialog transition without settling it.
        await tester.pump(const Duration(milliseconds: 300));

        expect(
          find.descendant(
            of: find.byKey(const ValueKey('host-security-merge-dialog')),
            matching: find.text('Review Host connection settings'),
          ),
          findsOneWidget,
        );
        final dialog = find.byKey(const ValueKey('host-security-merge-dialog'));
        expect(
          find.descendant(of: dialog, matching: find.text('prod.example.test')),
          findsNWidgets(2),
        );
        expect(
          find.descendant(
            of: dialog,
            matching: find.text('staging.example.test'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('2202')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('••••••••')),
          findsNWidgets(2),
        );
        expect(find.text('conflict-proxy-password-marker'), findsNothing);
        expect(find.text('private-host-trust-marker'), findsNothing);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('host-security-merge-save')),
              )
              .onPressed,
          isNull,
        );

        await tester.tap(
          find.byKey(const ValueKey('host-security-merge-choice-conflict')),
        );
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('host-security-merge-save')),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('host-security-merge-save')),
        );
        await tester.pumpAndSettle();

        expect(fixture.app.mergeCalls, 1);
        expect(fixture.app.lastExpectedHeadRevisionId, _headRevision);
        expect(fixture.app.lastChoice, HostSecurityMergeBranch.conflict);
        expect(
          find.text('Host connection settings reviewed and queued to sync.'),
          findsOneWidget,
        );
      } finally {
        await _dispose(tester, fixture);
      }
    },
  );

  testWidgets('changed head clears choice until latest tuple is reviewed', (
    tester,
  ) async {
    final fixture = await _fixture(
      previews: [
        _preview(),
        _preview(head: _nextHeadRevision),
      ],
      outcomes: [
        const HostSecurityConflictMergeOutcome.reviewRequired(),
        const HostSecurityConflictMergeOutcome.staged(
          revisionId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
      ],
    );
    try {
      await _pump(tester, fixture);
      await tester.pumpAndSettle();
      final opener = find.byKey(const ValueKey('host-security-merge-open'));
      await tester.ensureVisible(opener);
      await tester.tap(opener);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.byKey(const ValueKey('host-security-merge-choice-conflict')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host-security-merge-save')));
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const ValueKey('host-security-merge-stale')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('host-security-merge-save')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<RadioListTile<HostSecurityMergeBranch>>(
              find.byKey(const ValueKey('host-security-merge-choice-conflict')),
            )
            .groupValue,
        isNull,
      );

      await tester.tap(
        find.byKey(const ValueKey('host-security-merge-review-current')),
      );
      await tester.pump();
      expect(fixture.app.previewCalls, 2);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('host-security-merge-dialog')),
          matching: find.textContaining('66666666'),
        ),
        findsNWidgets(2),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('host-security-merge-save')),
            )
            .onPressed,
        isNull,
      );
      final currentChoice = find.byKey(
        const ValueKey('host-security-merge-choice-current'),
      );
      await tester.ensureVisible(currentChoice);
      await tester.pump();
      await tester.tap(currentChoice);
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('host-security-merge-save')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const ValueKey('host-security-merge-save')));
      await tester.pumpAndSettle();
      expect(fixture.app.mergeCalls, 2);
      expect(fixture.app.lastExpectedHeadRevisionId, _nextHeadRevision);
      expect(fixture.app.lastChoice, HostSecurityMergeBranch.current);
    } finally {
      await _dispose(tester, fixture);
    }
  });

  testWidgets('unverified and non-Host conflicts cannot open Host merge', (
    tester,
  ) async {
    final fixture = await _fixture(
      previews: const [],
      outcomes: const [],
      item: _feedItem(verified: false),
    );
    try {
      await _pump(tester, fixture);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('host-security-merge-open')),
        findsNothing,
      );
    } finally {
      await _dispose(tester, fixture);
    }
  });

  testWidgets(
    'Host review remains available when the feed item is folded into its local conflict card',
    (tester) async {
      final fixture = await _fixture(
        previews: const [],
        outcomes: const [],
        localConflict: true,
      );
      try {
        await _pump(tester, fixture);
        await tester.pumpAndSettle();

        final opener = find.byKey(const ValueKey('host-security-merge-open'));
        expect(opener, findsOneWidget);
        expect(tester.widget<OutlinedButton>(opener).onPressed, isNotNull);
      } finally {
        await _dispose(tester, fixture);
      }
    },
  );
}

Future<_Fixture> _fixture({
  required List<HostSecurityConflictMergePreview?> previews,
  required List<HostSecurityConflictMergeOutcome> outcomes,
  ConflictFeedReviewItem? item,
  bool localConflict = false,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _HostMergeController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          previews: previews,
          outcomes: outcomes,
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.sync
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '2',
          membershipVersion: '3',
        )
        ..feedConflictItems = [item ?? _feedItem()]
        ..openConflicts = localConflict
            ? [
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
            : []
        ..hosts.add(
          const HostRecord(
            id: _recordId,
            name: 'Production Host',
            address: 'prod.example.test',
            username: 'deploy',
          ),
        );
  return _Fixture(app, database);
}

Future<void> _pump(WidgetTester tester, _Fixture fixture) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: fixture.app),
    ),
  );
}

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  fixture.app.dispose();
  await fixture.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

class _Fixture {
  const _Fixture(this.app, this.database);

  final _HostMergeController app;
  final ClientDatabase database;
}

class _HostMergeController extends AppController {
  _HostMergeController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required List<HostSecurityConflictMergePreview?> previews,
    required List<HostSecurityConflictMergeOutcome> outcomes,
  }) : _previews = List.of(previews),
       _outcomes = List.of(outcomes);

  final List<HostSecurityConflictMergePreview?> _previews;
  final List<HostSecurityConflictMergeOutcome> _outcomes;
  int previewCalls = 0;
  int mergeCalls = 0;
  String? lastExpectedHeadRevisionId;
  HostSecurityMergeBranch? lastChoice;

  @override
  Future<HostSecurityConflictMergePreview?>
  loadHostSecurityConflictMergePreview({required String conflictId}) async {
    previewCalls++;
    return _previews.isEmpty ? null : _previews.removeAt(0);
  }

  @override
  Future<HostSecurityConflictMergeOutcome> mergeHostSecurityConflict({
    required String conflictId,
    required String expectedHeadRevisionId,
    required HostSecurityMergeBranch choice,
  }) async {
    mergeCalls++;
    lastExpectedHeadRevisionId = expectedHeadRevisionId;
    lastChoice = choice;
    return _outcomes.isEmpty
        ? const HostSecurityConflictMergeOutcome.reviewRequired()
        : _outcomes.removeAt(0);
  }
}
