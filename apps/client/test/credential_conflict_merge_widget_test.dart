import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/domain/credential_conflict_merge.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _conflictId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _branchRevision = '44444444-4444-4444-8444-444444444444';
const _headRevision = '55555555-5555-4555-8555-555555555555';
const _deviceId = '66666666-6666-4666-8666-666666666666';
const _generation = '77777777-7777-4777-8777-777777777777';

CredentialConflictMergePreview _preview({
  String currentHead = _headRevision,
  bool sameName = false,
  bool sameUsername = false,
  bool sameSecret = false,
}) => CredentialConflictMergePreview(
  conflictId: _conflictId,
  recordId: _recordId,
  branchRevisionId: _branchRevision,
  currentHeadRevisionId: currentHead,
  name: CredentialConflictMergeFieldPreview(
    localValue: sameName ? 'Shared name' : 'Conflict branch name',
    remoteValue: sameName ? 'Shared name' : 'Current head name',
  ),
  username: CredentialConflictMergeFieldPreview(
    localValue: sameUsername ? 'shared-user' : 'conflict-user',
    remoteValue: sameUsername ? 'shared-user' : 'current-user',
  ),
  secret: CredentialConflictMergeFieldPreview(
    localValue: sameSecret ? 'same-secret' : 'conflict-secret-value',
    remoteValue: sameSecret ? 'same-secret' : 'current-secret-value',
  ),
);

ConflictFeedReviewItem _feedItem() => ConflictFeedReviewItem(
  conflictId: _conflictId,
  recordId: _recordId,
  seq: '17',
  createdAt: '2026-09-27T18:00:00Z',
  serverGeneration: _generation,
  partitionId: 'partition-1',
  baseRevisionId: _headRevision,
  branchRevisionId: _branchRevision,
  branchDeviceId: _deviceId,
  branchOperation: 'update',
  keyEpoch: '2',
  membershipVersion: '3',
  currentHeadRevisionId: _headRevision,
  currentHeadExists: true,
  currentHeadDeleted: false,
  currentHeadCommitted: true,
  isVerified: true,
  verificationError: null,
  isResolved: false,
  resolutionState: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'merge opener and save each expose one actionable semantic button',
    (tester) async {
      final fixture = await _fixture(previews: [_preview()]);
      final semantics = tester.ensureSemantics();
      try {
        await _pump(tester, fixture);
        await tester.pumpAndSettle();

        final opener = find.byKey(const ValueKey('credential-merge-open'));
        await tester.ensureVisible(opener);
        await tester.pumpAndSettle();
        final openerLabel = find.bySemanticsLabel('Merge password fields');
        expect(openerLabel, findsOneWidget);
        expect(
          tester
              .getSemantics(openerLabel)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );

        await tester.tap(opener);
        await tester.pumpAndSettle();
        final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
        expect(dialog.semanticLabel, 'Merge password fields');
        final dialogNameNodes = find.semantics
            .byLabel('Merge password fields')
            .evaluate();
        expect(dialogNameNodes, isNotEmpty);
        List<SemanticsNode> descendantsOf(SemanticsNode node) {
          final descendants = <SemanticsNode>[];
          void visit(SemanticsNode parent) {
            parent.visitChildren((child) {
              descendants.add(child);
              visit(child);
              return true;
            });
          }

          visit(node);
          return descendants;
        }

        bool isOptionNode(SemanticsNode node) {
          final label = node.getSemanticsData().label;
          return label.startsWith('Use conflict branch\n') ||
              label.startsWith('Use current Vault version\n');
        }

        for (final label in const ['Name', 'Username', 'Password secret']) {
          final exactLabelNodes = find.semantics
              .byLabel(label)
              .evaluate()
              .toList();
          expect(exactLabelNodes, hasLength(1));
          final namedGroups = find.semantics
              .byPredicate((node) {
                final data = node.getSemanticsData();
                return data.label == label &&
                    descendantsOf(node).where(isOptionNode).length == 2;
              })
              .evaluate()
              .toList();
          expect(namedGroups, hasLength(1));
          final radioOptions = descendantsOf(
            namedGroups.single,
          ).where(isOptionNode).toList();
          expect(radioOptions, hasLength(2));
          expect(
            radioOptions.every(
              (node) => node.getSemanticsData().hasAction(SemanticsAction.tap),
            ),
            isTrue,
          );
          if (label == 'Password secret') {
            final maskedAndSafe = radioOptions.every((node) {
              final accessibleLabel = node.getSemanticsData().label;
              return accessibleLabel.contains('••••••••') &&
                  !accessibleLabel.contains('conflict-secret-value') &&
                  !accessibleLabel.contains('current-secret-value');
            });
            expect(
              maskedAndSafe,
              isTrue,
              reason:
                  'Password radio names expose only the visible mask while the secret is hidden.',
            );
          }
        }
        await _selectAllDivergentFields(tester);

        final saveLabel = find.bySemanticsLabel('Save merged Credential');
        expect(saveLabel, findsOneWidget);
        expect(
          tester
              .getSemantics(saveLabel)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        await tester.tap(_saveButton());
        await tester.pumpAndSettle();
        expect(fixture.app.mergeCalls, 1);
      } finally {
        semantics.dispose();
        await _dispose(tester, fixture);
      }
    },
  );

  testWidgets(
    'password merge requires explicit choices and masks the secret by default',
    (tester) async {
      final fixture = await _fixture(previews: [_preview()]);
      try {
        await _pump(tester, fixture);
        await _openMerge(tester);

        expect(find.text('Name'), findsOneWidget);
        expect(find.text('Username'), findsOneWidget);
        expect(find.text('Password secret'), findsOneWidget);
        expect(find.text('Conflict branch name'), findsOneWidget);
        expect(find.text('Current head name'), findsOneWidget);
        expect(find.text('conflict-secret-value'), findsNothing);
        expect(find.text('current-secret-value'), findsNothing);
        expect(find.text('••••••••'), findsNWidgets(2));

        var save = tester.widget<FilledButton>(_saveButton());
        expect(save.onPressed, isNull);

        await tester.tap(
          find.byKey(const ValueKey('credential-merge-field-name-local')),
        );
        await tester.pump();
        save = tester.widget<FilledButton>(_saveButton());
        expect(save.onPressed, isNull);

        await tester.tap(
          find.byKey(const ValueKey('credential-merge-field-username-remote')),
        );
        await tester.pump();
        save = tester.widget<FilledButton>(_saveButton());
        expect(save.onPressed, isNull);

        await tester.tap(
          find.byKey(const ValueKey('credential-merge-field-secret-local')),
        );
        await tester.pump();
        save = tester.widget<FilledButton>(_saveButton());
        expect(save.onPressed, isNotNull);

        await tester.tap(_saveButton());
        await tester.pumpAndSettle();

        expect(fixture.app.mergeCalls, 1);
        expect(fixture.app.lastExpectedHeadRevisionId, _headRevision);
        expect(fixture.app.lastChoices, {
          CredentialConflictMergeField.name:
              CredentialConflictMergeBranch.local,
          CredentialConflictMergeField.username:
              CredentialConflictMergeBranch.remote,
          CredentialConflictMergeField.secret:
              CredentialConflictMergeBranch.local,
        });
        expect(find.text('Credential merge saved and syncing'), findsOneWidget);
      } finally {
        await _dispose(tester, fixture);
      }
    },
  );

  testWidgets(
    'equal text fields are fixed while password source still needs a choice',
    (tester) async {
      final fixture = await _fixture(
        previews: [
          _preview(sameName: true, sameUsername: true, sameSecret: true),
        ],
      );
      try {
        await _pump(tester, fixture);
        await _openMerge(tester);

        expect(
          find.text('Same on both branches · Shared name'),
          findsOneWidget,
        );
        expect(
          find.text('Same on both branches · shared-user'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('credential-merge-field-name-local')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('credential-merge-field-username-local')),
          findsNothing,
        );
        expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNull);

        await tester.tap(
          find.byKey(const ValueKey('credential-merge-field-secret-remote')),
        );
        await tester.pump();
        expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNotNull);
        await tester.tap(_saveButton());
        await tester.pumpAndSettle();

        expect(fixture.app.lastChoices, {
          CredentialConflictMergeField.secret:
              CredentialConflictMergeBranch.remote,
        });
      } finally {
        await _dispose(tester, fixture);
      }
    },
  );

  testWidgets(
    'stale head clears choices until a fresh verified preview is reviewed',
    (tester) async {
      final fixture = await _fixture(
        previews: [
          _preview(),
          _preview(currentHead: '88888888-8888-4888-8888-888888888888'),
        ],
        outcomes: [
          const CredentialConflictMergeOutcome.reviewRequired(),
          const CredentialConflictMergeOutcome.staged(revisionId: '99999999'),
        ],
      );
      try {
        await _pump(tester, fixture);
        await _openMerge(tester);
        await tester.tap(find.byTooltip('Reveal password secret'));
        await tester.pump();
        expect(find.text('conflict-secret-value'), findsOneWidget);
        expect(find.text('current-secret-value'), findsOneWidget);
        await _selectAllDivergentFields(tester);
        await tester.tap(_saveButton());
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('credential-merge-stale')),
          findsOneWidget,
        );
        expect(find.text('conflict-secret-value'), findsNothing);
        expect(find.text('current-secret-value'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find
                    .ancestor(
                      of: find.byIcon(Icons.visibility_outlined),
                      matching: find.byType(IconButton),
                    )
                    .first,
              )
              .onPressed,
          isNull,
        );
        expect(fixture.app.mergeCalls, 1);
        expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNull);
        expect(
          tester
              .widget<RadioListTile<CredentialConflictMergeBranch>>(
                find.byKey(const ValueKey('credential-merge-field-name-local')),
              )
              .groupValue,
          isNull,
        );

        await tester.tap(find.text('Review current version'));
        await tester.pumpAndSettle();
        expect(fixture.app.previewCalls, 2);
        expect(
          find.byKey(const ValueKey('credential-merge-stale')),
          findsNothing,
        );
        expect(find.textContaining('88888888'), findsOneWidget);
        expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNull);

        await _selectAllDivergentFields(tester);
        await tester.tap(_saveButton());
        await tester.pumpAndSettle();
        expect(fixture.app.mergeCalls, 2);
        expect(find.text('Credential merge saved and syncing'), findsOneWidget);
      } finally {
        await _dispose(tester, fixture);
      }
    },
  );

  testWidgets(
    'ineligible conflicts keep whole-branch choices without password merge UI',
    (tester) async {
      final fixture = await _fixture(previews: const [], eligible: false);
      try {
        await _pump(tester, fixture);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('credential-merge-open')),
          findsNothing,
        );
        expect(find.text('Adopt this branch'), findsOneWidget);
        expect(find.text('Keep current version'), findsOneWidget);
        expect(fixture.app.previewCalls, 0);
      } finally {
        await _dispose(tester, fixture);
      }
    },
  );

  testWidgets('merge API errors stay visible and can be retried', (
    tester,
  ) async {
    final fixture = await _fixture(
      previews: [_preview()],
      mergeError: StateError('temporary merge error'),
    );
    try {
      await _pump(tester, fixture);
      await _openMerge(tester);
      await _selectAllDivergentFields(tester);
      await tester.tap(_saveButton());
      await tester.pumpAndSettle();

      expect(find.text('Bad state: temporary merge error'), findsOneWidget);
      expect(fixture.app.mergeCalls, 1);
      expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNotNull);
    } finally {
      await _dispose(tester, fixture);
    }
  });
}

Finder _saveButton() => find.byKey(const ValueKey('credential-merge-save'));

Future<void> _openMerge(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final button = find.byKey(const ValueKey('credential-merge-open'));
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(find.text('Merge password fields'), findsOneWidget);
}

Future<void> _selectAllDivergentFields(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey('credential-merge-field-name-local')),
  );
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey('credential-merge-field-username-remote')),
  );
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey('credential-merge-field-secret-local')),
  );
  await tester.pump();
}

Future<void> _pump(WidgetTester tester, _MergeFixture app) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app.app),
    ),
  );
}

Future<void> _dispose(WidgetTester tester, _MergeFixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  fixture.app.dispose();
  await fixture.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<_MergeFixture> _fixture({
  required List<CredentialConflictMergePreview?> previews,
  List<CredentialConflictMergeOutcome>? outcomes,
  bool eligible = true,
  Object? mergeError,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _CredentialMergeController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          previews: previews,
          outcomes:
              outcomes ??
              [
                const CredentialConflictMergeOutcome.staged(
                  revisionId: '99999999',
                ),
              ],
          eligible: eligible,
          mergeError: mergeError,
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.sync
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '2',
          membershipVersion: '3',
        )
        ..feedConflictItems = [_feedItem()];
  return _MergeFixture(app, database);
}

class _MergeFixture {
  const _MergeFixture(this.app, this.database);

  final _CredentialMergeController app;
  final ClientDatabase database;
}

class _CredentialMergeController extends AppController {
  _CredentialMergeController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    required List<CredentialConflictMergePreview?> previews,
    required List<CredentialConflictMergeOutcome> outcomes,
    required this.eligible,
    this.mergeError,
  }) : _previews = List.of(previews),
       _outcomes = List.of(outcomes);

  final List<CredentialConflictMergePreview?> _previews;
  final List<CredentialConflictMergeOutcome> _outcomes;
  final bool eligible;
  final Object? mergeError;
  int previewCalls = 0;
  int mergeCalls = 0;
  String? lastExpectedHeadRevisionId;
  Map<CredentialConflictMergeField, CredentialConflictMergeBranch>? lastChoices;

  @override
  Future<bool> isPasswordCredentialMergeEligible({
    required String conflictId,
  }) async => eligible;

  @override
  Future<CredentialConflictMergePreview?> loadCredentialConflictMergePreview({
    required String conflictId,
  }) async {
    previewCalls++;
    return _previews.isEmpty ? null : _previews.removeAt(0);
  }

  @override
  Future<CredentialConflictMergeOutcome> mergePasswordCredentialConflict({
    required String conflictId,
    required String expectedHeadRevisionId,
    required Map<CredentialConflictMergeField, CredentialConflictMergeBranch>
    choices,
  }) async {
    mergeCalls++;
    if (mergeError != null) throw mergeError!;
    lastExpectedHeadRevisionId = expectedHeadRevisionId;
    lastChoices = Map.of(choices);
    return _outcomes.isEmpty
        ? const CredentialConflictMergeOutcome.staged(revisionId: '99999999')
        : _outcomes.removeAt(0);
  }
}
