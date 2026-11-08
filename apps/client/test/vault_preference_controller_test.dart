import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/domain/window_combination.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'support/l10n_fixture.dart';

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _userId = '44444444-4444-4444-8444-444444444444';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'window combinations persist encrypted and reload without connecting',
    () async {
      final (app, database, repository, identity, key) = await _fixture(sodium);
      try {
        final value = WindowCombination(
          id: 'combo-1',
          name: 'private-window-recipe',
          mainPlacement: SavedWindowPlacement(
            x: 50,
            y: 60,
            width: 1000,
            height: 700,
            maximized: true,
          ),
          panes: [
            CombinationPane(kind: 'rdp', hostId: 'host-ref'),
            CombinationPane(kind: 'ssh', hostId: 'host-second'),
            CombinationPane(
              kind: 'sftp',
              hostId: 'host-file',
              remotePath: '/latest-directory',
            ),
          ],
          tree: {
            'axis': 'horizontal',
            'ratio': .42,
            'first': {'pane': 0},
            'second': {'pane': 1},
          },
          activePane: 1,
          groups: [
            CombinationGroup(
              tree: {
                'axis': 'horizontal',
                'ratio': .42,
                'first': {'pane': 0},
                'second': {'pane': 1},
              },
              activePane: 1,
            ),
          ],
          windows: [
            CombinationWindow(
              pane: 2,
              independentFile: true,
              placement: SavedWindowPlacement(
                x: 10,
                y: 20,
                width: 900,
                height: 600,
              ),
            ),
          ],
        );
        await app.saveWindowCombinations([value]);
        final preference = app.preferences.single;
        final stored = (await database.encryptedRecord(
          _vaultId,
          preference.id,
        ))!;
        expect(stored.envelopeJson, isNot(contains('private-window-recipe')));
        app.preferences.clear();
        await app.reloadRecords();
        expect(app.windowCombinations.single.name, 'private-window-recipe');
        expect(app.windowCombinations.single.mainPlacement!.maximized, true);
        expect(app.windowCombinations.single.groups.single.activePane, 1);
        expect(
          app.windowCombinations.single.windows.single.independentFile,
          true,
        );
        expect(app.windowCombinations.single.schemaVersion, 3);
        expect(app.terminalTabs, isEmpty);
        await app.saveWindowCombinations([]);
        expect(app.windowCombinations, isEmpty);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'saves a server-Vault encrypted preference and updates its revision',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        await app.saveWorkspaceDefaultSection('snippets');

        final created = app.preferences.single;
        expect(created.value, 'snippets');
        expect(created.revisionId, isNotNull);
        expect((await database.countPending(_vaultId)), 1);

        final stored = await database.encryptedRecord(_vaultId, created.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('snippets')));
        final plain = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plain['type'], 'preference');
        expect(plain['scope'], 'workspace');
        expect(plain['key'], 'defaultSection');
        expect(plain['platform_family'], 'all');
        expect(plain['value'], 'snippets');

        await app.saveWorkspaceDefaultSection('groups');
        final updated = app.preferences.single;
        expect(updated.id, created.id);
        expect(updated.revisionId, isNot(created.revisionId));
        expect(updated.value, 'groups');
        expect(app.defaultWorkspaceSection, 'groups');
        expect(await database.countPending(_vaultId), 1);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'saves terminal font size encrypted and preserves default-section data',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        await app.saveTerminalFontSizePreference(16);
        expect(app.terminalFontSize, 16);
        final fontRecord = app.preferences.singleWhere(
          (record) => record.isTerminalFontSize,
        );
        expect(fontRecord.revisionId, isNotNull);

        final stored = await database.encryptedRecord(_vaultId, fontRecord.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('terminalFontSize')));
        expect(stored.envelopeJson, isNot(contains('"value":"16"')));
        final plaintext = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plaintext['scope'], 'workspace');
        expect(plaintext['key'], 'terminalFontSize');
        expect(plaintext['platform_family'], 'all');
        expect(plaintext['value'], '16');

        final createdRevision = fontRecord.revisionId;
        await app.saveTerminalFontSizePreference(14);
        final updatedFontRecord = app.preferences.singleWhere(
          (record) => record.isTerminalFontSize,
        );
        expect(updatedFontRecord.id, fontRecord.id);
        expect(updatedFontRecord.value, '14');
        expect(updatedFontRecord.revisionId, isNot(createdRevision));
        expect(app.terminalFontSize, 14);

        await app.saveWorkspaceDefaultSection('groups');
        expect(app.defaultWorkspaceSection, 'groups');
        expect(app.terminalFontSize, 14);
        expect(
          app.preferences.map((record) => record.key),
          containsAll(['defaultSection', 'terminalFontSize']),
        );
        expect(await database.countPending(_vaultId), 2);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'saves terminal theme encrypted and updates the existing tuple',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        await app.saveTerminalThemePreference(VaultTerminalThemeChoice.light);
        expect(app.terminalTheme, VaultTerminalThemeChoice.light);
        final themeRecord = app.preferences.singleWhere(
          (record) => record.isTerminalTheme,
        );
        expect(themeRecord.revisionId, isNotNull);

        final stored = await database.encryptedRecord(_vaultId, themeRecord.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('terminalTheme')));
        expect(stored.envelopeJson, isNot(contains('"value":"light"')));
        final plaintext = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plaintext['scope'], 'workspace');
        expect(plaintext['key'], 'terminalTheme');
        expect(plaintext['platform_family'], 'all');
        expect(plaintext['value'], 'light');

        final createdRevision = themeRecord.revisionId;
        await app.saveTerminalThemePreference(
          VaultTerminalThemeChoice.atermDark,
        );
        final updated = app.preferences.singleWhere(
          (record) => record.isTerminalTheme,
        );
        expect(updated.id, themeRecord.id);
        expect(updated.value, 'atermius-dark');
        expect(updated.revisionId, isNot(createdRevision));
        expect(app.terminalTheme, VaultTerminalThemeChoice.atermDark);

        await app.saveTerminalFontSizePreference(16);
        expect(app.terminalFontSize, 16);
        expect(app.terminalTheme, VaultTerminalThemeChoice.atermDark);
        expect(
          app.preferences.map((record) => record.key),
          containsAll(['terminalTheme', 'terminalFontSize']),
        );
        expect(await database.countPending(_vaultId), 2);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'saves semantic terminal shortcuts encrypted and updates the same record',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        final initial = TerminalShortcutBindings.defaults;
        await app.saveTerminalShortcutsPreference(initial);
        expect(app.terminalShortcutBindings, initial);
        final created = app.preferences.singleWhere(
          (record) => record.isTerminalShortcuts,
        );
        final stored = await database.encryptedRecord(_vaultId, created.id);
        expect(stored, isNotNull);
        expect(stored!.envelopeJson, isNot(contains('terminalShortcuts')));
        expect(stored.envelopeJson, isNot(contains('terminal.search')));
        final plaintext = await repository.crypto.decryptRecord(
          vaultKey: key,
          envelope: jsonDecode(stored.envelopeJson) as Map<String, dynamic>,
          authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
        );
        expect(plaintext['key'], 'terminalShortcuts');
        expect(plaintext['platform_family'], 'all');
        expect(plaintext['value'], initial.toValue());

        final updated = TerminalShortcutBindings.fromBindings({
          ...initial.bindings,
          TerminalShortcutAction.searchNext: 'alt+g',
        });
        final oldRevision = created.revisionId;
        await app.saveTerminalShortcutsPreference(updated);
        final saved = app.preferences.singleWhere(
          (record) => record.isTerminalShortcuts,
        );
        expect(saved.id, created.id);
        expect(saved.revisionId, isNot(oldRevision));
        expect(app.terminalShortcutBindings, updated);
        expect(await database.countPending(_vaultId), 1);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'fails closed and repairs duplicate terminal shortcut records',
    () async {
      const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final changed = TerminalShortcutBindings.fromBindings({
        ...TerminalShortcutBindings.defaults.bindings,
        TerminalShortcutAction.searchNext: 'alt+g',
      });
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _terminalShortcutsPreferenceRow(
            id: keepId,
            bindings: TerminalShortcutBindings.defaults,
            revisionId: _revisionA,
          ),
          _terminalShortcutsPreferenceRow(
            id: removeId,
            bindings: changed,
            revisionId: _revisionB,
          ),
        ],
      );
      final (app, database, repository, identity, key) = fixture;
      final repairRepository =
          repository as _SimulatedPreferenceRepairRepository;
      try {
        await app.reloadRecords();
        expect(app.hasTerminalShortcutsPreferenceConflict, isTrue);
        expect(app.terminalShortcutBindings, TerminalShortcutBindings.defaults);
        expect(
          app.terminalShortcutsConflictCandidates.map((record) => record.id),
          unorderedEquals([keepId, removeId]),
        );
        await expectLater(
          app.saveTerminalShortcutsPreference(changed),
          throwsA(isA<StateError>()),
        );

        await app.repairTerminalShortcutsPreferenceConflict(
          retainedRecordId: removeId,
        );

        expect(app.hasTerminalShortcutsPreferenceConflict, isFalse);
        expect(app.terminalShortcutBindings, changed);
        expect(app.preferences.single.id, removeId);
        expect(repairRepository.serverRows, hasLength(1));
        final deletion = repairRepository.savedOperations.single;
        expect(deletion['recordId'], keepId);
        expect(deletion['operation'], 'delete');
        expect(
          (deletion['plaintext']
              as Map<String, Object?>)['preference_conflict_repair'],
          {
            'version': 1,
            'kind': 'duplicate_preference_tuple',
            'scope': 'workspace',
            'key': 'terminalShortcuts',
            'platform_family': 'all',
            'retained_record_id': removeId,
          },
        );
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('real repository confirms shortcut tombstone and reloads one retained record', () async {
    const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final fixture = await _fixture(
      sodium,
      repairRows: [
        _terminalShortcutsPreferenceRow(
          id: keepId,
          bindings: TerminalShortcutBindings.defaults,
          revisionId: _revisionA,
        ),
        _terminalShortcutsPreferenceRow(
          id: removeId,
          bindings: TerminalShortcutBindings.fromBindings({
            ...TerminalShortcutBindings.defaults.bindings,
            TerminalShortcutAction.search: 'mod+alt+f',
          }),
          revisionId: _revisionB,
        ),
      ],
      useActualPreferenceRepairMarkers: true,
    );
    final (app, database, repository, identity, key) = fixture;
    try {
      await app.reloadRecords();
      expect(app.hasTerminalShortcutsPreferenceConflict, isTrue);

      await app.repairTerminalShortcutsPreferenceConflict(
        retainedRecordId: keepId,
      );

      expect(app.hasTerminalShortcutsPreferenceConflict, isFalse);
      expect(app.preferences.single.id, keepId);
      expect(await repository.unconfirmedPreferenceRepairs(), isEmpty);
      expect(await database.countPending(_vaultId), 0);

      await app.reloadRecords();
      expect(app.hasTerminalShortcutsPreferenceConflict, isFalse);
      expect(app.preferenceError, isNull);
      expect(app.preferences, hasLength(1));
      expect(app.preferences.single.id, keepId);
      expect(app.terminalShortcutBindings, TerminalShortcutBindings.defaults);
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'fails closed and repairs duplicate terminal theme records by ID',
    () async {
      const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _terminalThemePreferenceRow(
            id: keepId,
            theme: 'light',
            revisionId: _revisionA,
          ),
          _terminalThemePreferenceRow(
            id: removeId,
            theme: 'atermius-dark',
            revisionId: _revisionB,
          ),
        ],
      );
      final (app, database, repository, identity, key) = fixture;
      final repairRepository =
          repository as _SimulatedPreferenceRepairRepository;
      try {
        await app.reloadRecords();
        expect(app.hasTerminalThemePreferenceConflict, isTrue);
        expect(app.terminalTheme, VaultTerminalThemeChoice.atermDark);
        expect(
          app.terminalThemeConflictCandidates.map((record) => record.id),
          unorderedEquals([keepId, removeId]),
        );
        await expectLater(
          app.saveTerminalThemePreference(VaultTerminalThemeChoice.light),
          throwsA(isA<StateError>()),
        );

        await app.repairTerminalThemePreferenceConflict(
          retainedRecordId: keepId,
        );

        expect(app.hasTerminalThemePreferenceConflict, isFalse);
        expect(app.terminalTheme, VaultTerminalThemeChoice.light);
        expect(app.preferences.single.id, keepId);
        expect(repairRepository.serverRows, hasLength(1));
        final deleteCall = repairRepository.savedOperations.single;
        expect(deleteCall['recordId'], removeId);
        final plaintext = deleteCall['plaintext'] as Map<String, Object?>;
        expect(plaintext['preference_conflict_repair'], {
          'version': 1,
          'kind': 'duplicate_preference_tuple',
          'scope': 'workspace',
          'key': 'terminalTheme',
          'platform_family': 'all',
          'retained_record_id': keepId,
        });
        expect(plaintext, isNot(contains('value')));
        expect(await database.countPending(_vaultId), 0);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'preference repair and automatic sync share the controller sync queue',
    () async {
      const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _preferenceRow(id: keepId, value: 'groups', revisionId: _revisionA),
          _preferenceRow(id: removeId, value: 'hosts', revisionId: _revisionB),
        ],
      );
      final (app, database, repository, identity, key) = fixture;
      final repairRepository =
          repository as _SimulatedPreferenceRepairRepository;
      final repairSyncStarted = Completer<void>();
      final releaseRepairSync = Completer<void>();
      repairRepository.syncPassStarted[1] = repairSyncStarted;
      repairRepository.syncPassGates[1] = releaseRepairSync;
      Future<Object?>? repairOutcome;
      Future<Object?>? competingSyncOutcome;
      try {
        await app.reloadRecords();
        final repair = app.repairDefaultWorkspaceSectionConflict(
          retainedRecordId: keepId,
        );
        await repairSyncStarted.future.timeout(const Duration(seconds: 2));
        repairOutcome = repair.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );

        var competingSyncFinished = false;
        competingSyncOutcome = app.synchronize(background: true).then<Object?>((
          _,
        ) {
          competingSyncFinished = true;
          return null;
        }, onError: (Object error) => error);
        await Future<void>.delayed(Duration.zero);

        // A repair pass must own the controller sync slot. A second sync
        // request waits here instead of starting a repository pass that can
        // overwrite the repair's observed status.
        expect(competingSyncFinished, isFalse);
        expect(repairRepository.maximumConcurrentSyncPasses, 1);

        releaseRepairSync.complete();
        await Future.wait([repairOutcome!, competingSyncOutcome!]);
        expect(await repairOutcome!, isNull);
        expect(await competingSyncOutcome!, isNull);
        expect(competingSyncFinished, isTrue);
        expect(repairRepository.maximumConcurrentSyncPasses, 1);
        expect(app.hasDefaultSectionPreferenceConflict, isFalse);
        expect(app.preferences.single.id, keepId);
        expect(await database.countPending(_vaultId), 0);
      } finally {
        if (!releaseRepairSync.isCompleted) releaseRepairSync.complete();
        if (repairOutcome != null && competingSyncOutcome != null) {
          await Future.wait([repairOutcome!, competingSyncOutcome!]);
        }
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'repairs duplicate terminal font-size creates by selected record ID',
    () async {
      const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _terminalFontSizePreferenceRow(
            id: keepId,
            fontSize: 16,
            revisionId: _revisionA,
          ),
          _terminalFontSizePreferenceRow(
            id: removeId,
            fontSize: 14,
            revisionId: _revisionB,
          ),
        ],
      );
      final (app, database, repository, identity, key) = fixture;
      final repairRepository =
          repository as _SimulatedPreferenceRepairRepository;
      try {
        await app.reloadRecords();
        expect(app.hasTerminalFontSizePreferenceConflict, isTrue);
        expect(
          app.terminalFontSize,
          VaultPreferenceRecord.defaultTerminalFontSize,
        );
        expect(
          app.terminalFontSizeConflictCandidates.map((record) => record.id),
          unorderedEquals([keepId, removeId]),
        );
        expect(app.hasDefaultSectionPreferenceConflict, isFalse);
        await expectLater(
          app.saveTerminalFontSizePreference(18),
          throwsA(isA<StateError>()),
        );

        await app.repairTerminalFontSizePreferenceConflict(
          retainedRecordId: keepId,
        );

        expect(app.hasTerminalFontSizePreferenceConflict, isFalse);
        expect(app.terminalFontSize, 16);
        expect(app.preferences.single.id, keepId);
        expect(repairRepository.serverRows, hasLength(1));
        expect(repairRepository.serverRows.single['_record_id'], keepId);
        expect(await database.countPending(_vaultId), 0);
        final deleteCall = repairRepository.savedOperations.single;
        expect(deleteCall['recordId'], removeId);
        expect(deleteCall['baseRevisionId'], _revisionB);
        expect(deleteCall['operation'], 'delete');
        final plaintext = deleteCall['plaintext'] as Map<String, Object?>;
        expect(plaintext['preference_conflict_repair'], {
          'version': 1,
          'kind': 'duplicate_preference_tuple',
          'scope': 'workspace',
          'key': 'terminalFontSize',
          'platform_family': 'all',
          'retained_record_id': keepId,
        });
        expect(plaintext, isNot(contains('value')));
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('loads each strict workspace preference tuple independently', () async {
    const sectionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const fontId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    const themeId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
    final fixture = await _fixture(
      sodium,
      repairRows: [
        _preferenceRow(id: sectionId, value: 'groups', revisionId: _revisionA),
        _terminalFontSizePreferenceRow(
          id: fontId,
          fontSize: 18,
          revisionId: _revisionB,
        ),
        _terminalThemePreferenceRow(
          id: themeId,
          theme: 'light',
          revisionId: _revisionC,
        ),
      ],
    );
    final (app, database, _, identity, key) = fixture;
    try {
      await app.reloadRecords();
      expect(app.preferenceError, isNull);
      expect(app.defaultWorkspaceSection, 'groups');
      expect(app.terminalFontSize, 18);
      expect(app.terminalTheme, VaultTerminalThemeChoice.light);
      expect(app.hasDefaultSectionPreferenceConflict, isFalse);
      expect(app.hasTerminalFontSizePreferenceConflict, isFalse);
      expect(app.hasTerminalThemePreferenceConflict, isFalse);
      expect(
        app.preferences.map((record) => record.id),
        unorderedEquals([sectionId, fontId, themeId]),
      );
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'repairing one preference tuple does not clear another tuple conflict',
    () async {
      const keepSectionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removeSectionId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      const keepFontId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
      const removeFontId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _preferenceRow(
            id: keepSectionId,
            value: 'groups',
            revisionId: _revisionA,
          ),
          _preferenceRow(
            id: removeSectionId,
            value: 'hosts',
            revisionId: _revisionB,
          ),
          _terminalFontSizePreferenceRow(
            id: keepFontId,
            fontSize: 16,
            revisionId: _revisionC,
          ),
          _terminalFontSizePreferenceRow(
            id: removeFontId,
            fontSize: 14,
            revisionId: _revisionA,
          ),
        ],
      );
      final (app, database, repository, identity, key) = fixture;
      try {
        await app.reloadRecords();
        expect(app.hasDefaultSectionPreferenceConflict, isTrue);
        expect(app.hasTerminalFontSizePreferenceConflict, isTrue);

        await app.repairDefaultWorkspaceSectionConflict(
          retainedRecordId: keepSectionId,
        );

        expect(app.hasDefaultSectionPreferenceConflict, isFalse);
        expect(app.hasTerminalFontSizePreferenceConflict, isTrue);
        expect(
          app.terminalFontSizeConflictCandidates.map((r) => r.id),
          unorderedEquals([keepFontId, removeFontId]),
        );
        expect(app.preferenceError, contains('终端字号'));
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'opaque cursor sequence metadata is parsed without HMAC verification',
    () async {
      final fixture = await _fixture(sodium);
      final (_, database, repository, identity, key) = fixture;
      repository.serverGeneration = _serverGeneration;
      const ordinaryDeleteId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const unrelatedHostDeleteId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      const repairDeleteId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      const retainedId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
      try {
        await repository.saveRecord(
          recordId: unrelatedHostDeleteId,
          operation: 'delete',
          plaintext: {
            'id': unrelatedHostDeleteId,
            'type': 'host',
            'deleted': true,
          },
        );
        expect(await repository.unconfirmedDefaultPreferenceRepairs(), isEmpty);

        await repository.saveRecord(
          recordId: ordinaryDeleteId,
          operation: 'delete',
          plaintext: {
            'id': ordinaryDeleteId,
            'type': 'preference',
            'deleted': true,
          },
        );
        expect(await repository.unconfirmedDefaultPreferenceRepairs(), isEmpty);

        await repository.saveRecord(
          recordId: repairDeleteId,
          operation: 'delete',
          plaintext: {
            'id': repairDeleteId,
            'type': 'preference',
            'deleted': true,
            'default_section_conflict_repair': {
              'version': 1,
              'retained_record_id': retainedId,
            },
          },
        );
        expect(await repository.unconfirmedDefaultPreferenceRepairs(), [
          isA<PendingDefaultPreferenceRepair>()
              .having(
                (item) => item.deletedRecordId,
                'deleted ID',
                repairDeleteId,
              )
              .having(
                (item) => item.retainedRecordId,
                'retained ID',
                retainedId,
              ),
        ]);

        final pending = await database.allPendingOperations(_vaultId);
        for (final operation in pending) {
          await database.markCommitted(
            opId: operation.opId,
            commitSeq: operation.recordId == repairDeleteId
                ? '3'
                : operation.recordId == ordinaryDeleteId
                ? '4'
                : '5',
          );
        }
        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          cursor: _serverCursor('2'),
          serverGeneration: _serverGeneration,
        );
        expect(
          await repository.unconfirmedDefaultPreferenceRepairs(),
          hasLength(1),
        );

        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          cursor: _serverCursor('3'),
          serverGeneration: _serverGeneration,
        );
        expect(await repository.unconfirmedDefaultPreferenceRepairs(), isEmpty);

        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          cursor: _serverCursor('3', generation: _otherServerGeneration),
          serverGeneration: _otherServerGeneration,
        );
        expect(
          await repository.unconfirmedDefaultPreferenceRepairs(),
          hasLength(1),
        );

        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          cursor: _serverCursor('3', generation: _otherServerGeneration),
          serverGeneration: _serverGeneration,
        );
        expect(
          await repository.unconfirmedDefaultPreferenceRepairs(),
          hasLength(1),
        );

        await database.saveCheckpoint(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          cursor: _serverCursor('3', vaultId: _otherVaultId),
          serverGeneration: _serverGeneration,
        );
        expect(
          await repository.unconfirmedDefaultPreferenceRepairs(),
          hasLength(1),
        );

        for (final invalidCursor in [
          '5',
          _opaqueServerCursor('not-json'),
          _serverCursor('9223372036854775808'),
        ]) {
          await database.saveCheckpoint(
            vaultId: _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
            cursor: invalidCursor,
            serverGeneration: _serverGeneration,
          );
          expect(
            await repository.unconfirmedDefaultPreferenceRepairs(),
            hasLength(1),
          );
        }

        final stored = await database.encryptedRecord(_vaultId, repairDeleteId);
        final altered =
            jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
        (altered['header'] as Map<String, dynamic>)['device_id'] =
            'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
        await database.storeRemoteEnvelope(
          vaultId: _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          recordId: repairDeleteId,
          revisionId: _revisionA,
          envelope: altered,
          commitSeq: '6',
          deleted: true,
        );
        await expectLater(
          repository.unconfirmedDefaultPreferenceRepairs(),
          throwsA(isA<FormatException>()),
        );
      } finally {
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'versioned preference repair markers bind to a supported tuple',
    () async {
      final fixture = await _fixture(sodium);
      final (_, database, repository, identity, key) = fixture;
      const deletedId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      const retainedId = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
      try {
        await repository.saveRecord(
          recordId: deletedId,
          operation: 'delete',
          plaintext: {
            'id': deletedId,
            'type': 'preference',
            'deleted': true,
            'preference_conflict_repair': {
              'version': 1,
              'kind': 'duplicate_preference_tuple',
              'scope': 'workspace',
              'key': 'terminalFontSize',
              'platform_family': 'all',
              'retained_record_id': retainedId,
            },
          },
        );

        expect(await repository.unconfirmedDefaultPreferenceRepairs(), isEmpty);
        expect(await repository.unconfirmedPreferenceRepairs(), [
          isA<PendingDefaultPreferenceRepair>()
              .having((item) => item.deletedRecordId, 'deleted ID', deletedId)
              .having(
                (item) => item.retainedRecordId,
                'retained ID',
                retainedId,
              )
              .having((item) => item.scope, 'scope', 'workspace')
              .having((item) => item.key, 'key', 'terminalFontSize')
              .having((item) => item.platformFamily, 'platform', 'all'),
        ]);

        await repository.saveRecord(
          recordId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          operation: 'delete',
          plaintext: {
            'id': 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            'type': 'preference',
            'deleted': true,
            'preference_conflict_repair': {
              'version': 1,
              'kind': 'duplicate_preference_tuple',
              'scope': 'workspace',
              'key': 'terminalTheme',
              'platform_family': 'all',
              'retained_record_id': retainedId,
            },
          },
        );
        expect(
          await repository.unconfirmedPreferenceRepairs(),
          contains(
            isA<PendingDefaultPreferenceRepair>()
                .having((item) => item.key, 'key', 'terminalTheme')
                .having((item) => item.isTerminalTheme, 'theme tuple', isTrue),
          ),
        );

        const shortcutDeletedId = '99999999-9999-4999-8999-999999999999';
        await repository.saveRecord(
          recordId: shortcutDeletedId,
          operation: 'delete',
          plaintext: {
            'id': shortcutDeletedId,
            'type': 'preference',
            'deleted': true,
            'preference_conflict_repair': {
              'version': 1,
              'kind': 'duplicate_preference_tuple',
              'scope': 'workspace',
              'key': 'terminalShortcuts',
              'platform_family': 'all',
              'retained_record_id': retainedId,
            },
          },
        );
        expect(
          await repository.unconfirmedPreferenceRepairs(),
          contains(
            isA<PendingDefaultPreferenceRepair>()
                .having(
                  (item) => item.deletedRecordId,
                  'deleted ID',
                  shortcutDeletedId,
                )
                .having(
                  (item) => item.key,
                  'key',
                  VaultPreferenceRecord.terminalShortcutsKey,
                )
                .having(
                  (item) => item.isTerminalShortcuts,
                  'shortcut tuple',
                  isTrue,
                ),
          ),
        );

        await repository.saveRecord(
          recordId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          operation: 'delete',
          plaintext: {
            'id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            'type': 'preference',
            'deleted': true,
            'preference_conflict_repair': {
              'version': 1,
              'kind': 'duplicate_preference_tuple',
              'scope': 'workspace',
              'key': 'unknownPreference',
              'platform_family': 'all',
              'retained_record_id': retainedId,
            },
          },
        );
        await expectLater(
          repository.unconfirmedPreferenceRepairs(),
          throwsA(isA<FormatException>()),
        );
      } finally {
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('a save finishing after Vault selection changes is not applied to the new view', () async {
    final fixture = await _fixture(sodium, delaySave: true);
    final (app, database, repository, identity, key) = fixture;
    final delayedRepository = repository as _DelayedSavePreferenceRepository;
    try {
      final save = app.saveWorkspaceDefaultSection('snippets');
      await delayedRepository.saveStarted.future;
      app.activeVault = const VaultDescriptor(
        id: '55555555-5555-4555-8555-555555555555',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
        canWrite: true,
      );
      delayedRepository.saveResult.complete({
        'header': {'revision_id': _revisionB},
      });

      expect(await save, WorkspacePreferenceSaveOutcome.queuedInOriginalVault);
      expect(app.preferences, isEmpty);
      expect(app.defaultWorkspaceSection, 'hosts');
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'applies a preference received after unlock until the user navigates',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        app.stage = ClientStage.workspace;
        app.page = WorkspacePage.hosts;
        await app.reloadRecords();
        expect(app.page, WorkspacePage.hosts);

        final record = VaultPreferenceRecord.defaultWorkspaceSection(
          value: 'groups',
        );
        await repository.saveRecord(
          recordId: record.id,
          plaintext: record.toJson(),
          operation: 'create',
        );
        await app.reloadRecords();
        expect(app.page, WorkspacePage.groups);

        // A user's explicit page choice supersedes a later synchronized update.
        app.showWorkspacePage(WorkspacePage.credentials);
        final next = record.copyWith(value: 'snippets');
        await repository.saveRecord(
          recordId: next.id,
          plaintext: next.toJson(),
          baseRevisionId: app.preferences.single.revisionId,
          operation: 'update',
        );
        await app.reloadRecords();
        expect(app.page, WorkspacePage.credentials);
        expect(app.defaultWorkspaceSection, 'snippets');
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'an older same-Vault reload cannot overwrite the newer loaded state',
    () async {
      final olderResult = Completer<List<Map<String, dynamic>>>();
      final newerResult = Completer<List<Map<String, dynamic>>>();
      var loadCount = 0;
      final fixture = await _fixture(
        sodium,
        loadRecordsForTesting: (_) {
          loadCount++;
          return loadCount == 1 ? olderResult.future : newerResult.future;
        },
      );
      final (app, database, _, identity, key) = fixture;
      try {
        app
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts;

        final olderReload = app.reloadRecords();
        final newerReload = app.reloadRecords();
        expect(loadCount, 2);

        newerResult.complete([
          _preferenceRow(value: 'snippets', revisionId: _revisionB),
        ]);
        await newerReload;
        expect(app.defaultWorkspaceSection, 'snippets');
        expect(app.page, WorkspacePage.snippets);

        olderResult.complete([
          _preferenceRow(value: 'hosts', revisionId: _revisionA),
        ]);
        await olderReload;

        expect(app.defaultWorkspaceSection, 'snippets');
        expect(app.preferences.single.revisionId, _revisionB);
        expect(app.page, WorkspacePage.snippets);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'duplicate logical tuples pause applying and editing the preference',
    () async {
      final fixture = await _fixture(sodium);
      final (app, database, repository, identity, key) = fixture;
      try {
        for (final value in ['snippets', 'credentials']) {
          final record = VaultPreferenceRecord.defaultWorkspaceSection(
            value: value,
          );
          await repository.saveRecord(
            recordId: record.id,
            plaintext: record.toJson(),
            operation: 'create',
          );
        }

        await app.reloadRecords();
        expect(app.preferences, hasLength(2));
        expect(app.preferenceError, contains('重复记录'));
        expect(app.page, WorkspacePage.hosts);
        await expectLater(
          app.saveWorkspaceDefaultSection('groups'),
          throwsA(isA<StateError>()),
        );
        expect(await database.countPending(_vaultId), 2);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('a second profile clears its conflict only after a fresh idle singleton pull', () async {
    const retainedId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const removedId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final fixture = await _fixture(
      sodium,
      repairRows: [
        _preferenceRow(id: retainedId, value: 'groups', revisionId: _revisionA),
        _preferenceRow(
          id: removedId,
          value: 'credentials',
          revisionId: _revisionB,
        ),
      ],
    );
    final (app, database, repository, identity, key) = fixture;
    final pullRepository = repository as _SimulatedPreferenceRepairRepository;
    try {
      await app.reloadRecords();
      expect(app.hasDefaultSectionPreferenceConflict, isTrue);
      expect(
        app.defaultSectionConflictCandidates.map((item) => item.id),
        unorderedEquals([retainedId, removedId]),
      );

      // Another profile's confirmed tombstone removes the duplicate from
      // this profile's next complete server view.
      pullRepository.serverRows.removeWhere(
        (row) => row['_record_id'] == removedId,
      );
      await app.reloadRecords();
      expect(app.hasDefaultSectionPreferenceConflict, isTrue);

      await pullRepository.synchronize();
      app.syncStatus = 'pending';
      await app.reloadRecords();
      expect(app.hasDefaultSectionPreferenceConflict, isTrue);

      app.syncStatus = 'idle';
      await app.reloadRecords();
      expect(app.hasDefaultSectionPreferenceConflict, isFalse);
      expect(app.preferenceError, isNull);
      expect(app.preferences.single.id, retainedId);
      expect(await database.countPending(_vaultId), 0);
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test(
    'a marker verification failure cannot be cleared by a later singleton pull',
    () async {
      const retainedId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removedId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _preferenceRow(
            id: retainedId,
            value: 'groups',
            revisionId: _revisionA,
          ),
          _preferenceRow(
            id: removedId,
            value: 'credentials',
            revisionId: _revisionB,
          ),
        ],
        failPreferenceRepairScan: true,
      );
      final (app, database, repository, identity, key) = fixture;
      final pullRepository = repository as _SimulatedPreferenceRepairRepository;
      try {
        await app.reloadRecords();
        expect(app.hasDefaultSectionPreferenceConflict, isTrue);
        expect(app.preferenceError, contains('无法验证'));

        pullRepository.failPreferenceRepairScan = false;
        pullRepository.serverRows.removeWhere(
          (row) => row['_record_id'] == removedId,
        );
        await pullRepository.synchronize();
        await app.reloadRecords();

        expect(app.hasDefaultSectionPreferenceConflict, isTrue);
        expect(app.preferenceError, isNotNull);
        expect(await database.countPending(_vaultId), 0);

        await app.repairDefaultWorkspaceSectionConflict(
          retainedRecordId: retainedId,
        );
        expect(app.hasDefaultSectionPreferenceConflict, isFalse);
        expect(app.defaultWorkspaceSection, 'groups');
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test(
    'font-size marker scan failure needs explicit singleton repair too',
    () async {
      const retainedId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      const removedId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
      final fixture = await _fixture(
        sodium,
        repairRows: [
          _terminalFontSizePreferenceRow(
            id: retainedId,
            fontSize: 16,
            revisionId: _revisionA,
          ),
          _terminalFontSizePreferenceRow(
            id: removedId,
            fontSize: 14,
            revisionId: _revisionB,
          ),
        ],
        failPreferenceRepairScan: true,
      );
      final (app, database, repository, identity, key) = fixture;
      final pullRepository = repository as _SimulatedPreferenceRepairRepository;
      try {
        await app.reloadRecords();
        expect(app.hasTerminalFontSizePreferenceConflict, isTrue);
        expect(app.preferenceError, contains('无法验证'));

        pullRepository.failPreferenceRepairScan = false;
        pullRepository.serverRows.removeWhere(
          (row) => row['_record_id'] == removedId,
        );
        await pullRepository.synchronize();
        await app.reloadRecords();

        expect(app.hasTerminalFontSizePreferenceConflict, isTrue);
        expect(app.terminalFontSizeConflictCandidates.single.id, retainedId);
        expect(app.preferenceError, isNotNull);
        expect(await database.countPending(_vaultId), 0);

        await app.repairTerminalFontSizePreferenceConflict(
          retainedRecordId: retainedId,
        );
        expect(app.hasTerminalFontSizePreferenceConflict, isFalse);
        expect(app.terminalFontSize, 16);
      } finally {
        app.dispose();
        identity.dispose();
        key.fillRange(0, key.length, 0);
        await database.close();
      }
    },
  );

  test('selected record repair keeps its ID and removes losers with encrypted tombstones', () async {
    const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final fixture = await _fixture(
      sodium,
      repairRows: [
        _preferenceRow(id: keepId, value: 'snippets', revisionId: _revisionA),
        _preferenceRow(
          id: removeId,
          value: 'credentials',
          revisionId: _revisionB,
        ),
      ],
    );
    final (app, database, repository, identity, key) = fixture;
    final repairRepository = repository as _SimulatedPreferenceRepairRepository;
    try {
      app
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.settings;
      await app.reloadRecords();
      expect(app.hasDefaultSectionPreferenceConflict, isTrue);
      expect(
        app.defaultSectionConflictCandidates.map((candidate) => candidate.id),
        unorderedEquals([keepId, removeId]),
      );

      await app.repairDefaultWorkspaceSectionConflict(retainedRecordId: keepId);

      expect(app.preferenceError, isNull);
      expect(app.hasDefaultSectionPreferenceConflict, isFalse);
      expect(app.preferences.single.id, keepId);
      expect(app.preferences.single.value, 'snippets');
      expect(repairRepository.serverRows, hasLength(1));
      expect(repairRepository.serverRows.single['_record_id'], keepId);
      expect(await database.countPending(_vaultId), 0);

      final deleteCall = repairRepository.savedOperations.single;
      expect(deleteCall['recordId'], removeId);
      expect(deleteCall['operation'], 'delete');
      expect(deleteCall['baseRevisionId'], _revisionB);
      final tombstone = await database.encryptedRecord(_vaultId, removeId);
      expect(tombstone, isNotNull);
      expect(tombstone!.envelopeJson, isNot(contains('retained_record_id')));
      expect(tombstone.envelopeJson, isNot(contains(keepId)));
      expect(tombstone.envelopeJson, isNot(contains('credentials')));
      final plain = await repository.crypto.decryptRecord(
        vaultKey: key,
        envelope: jsonDecode(tombstone.envelopeJson) as Map<String, dynamic>,
        authorPublicKey: Uint8List.fromList(identity.signing.publicKey),
      );
      expect(plain['deleted'], isTrue);
      expect(plain['preference_conflict_repair'], {
        'version': 1,
        'kind': 'duplicate_preference_tuple',
        'scope': 'workspace',
        'key': 'defaultSection',
        'platform_family': 'all',
        'retained_record_id': keepId,
      });
      expect(repairRepository.syncPasses, greaterThanOrEqualTo(3));
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test('changed candidate revision aborts before writing tombstones', () async {
    const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final fixture = await _fixture(
      sodium,
      repairRows: [
        _preferenceRow(id: keepId, value: 'snippets', revisionId: _revisionA),
        _preferenceRow(
          id: removeId,
          value: 'credentials',
          revisionId: _revisionB,
        ),
      ],
      changeCandidateOnSync: true,
    );
    final (app, database, repository, identity, key) = fixture;
    final repairRepository = repository as _SimulatedPreferenceRepairRepository;
    try {
      await app.reloadRecords();
      await expectLater(
        app.repairDefaultWorkspaceSectionConflict(retainedRecordId: keepId),
        throwsA(isA<StateError>()),
      );
      expect(repairRepository.savedOperations, isEmpty);
      expect(app.hasDefaultSectionPreferenceConflict, isTrue);
      expect(app.preferenceError, isNotNull);
      expect(await database.countPending(_vaultId), 0);
      expect(
        app.defaultSectionConflictCandidates
            .singleWhere((candidate) => candidate.id == keepId)
            .revisionId,
        _revisionC,
      );
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test('failed sync keeps repair locked and the same retained ID can retry', () async {
    const keepId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const removeId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
    final fixture = await _fixture(
      sodium,
      repairRows: [
        _preferenceRow(id: keepId, value: 'snippets', revisionId: _revisionA),
        _preferenceRow(
          id: removeId,
          value: 'credentials',
          revisionId: _revisionB,
        ),
      ],
      failSyncPass: 2,
    );
    final (app, database, repository, identity, key) = fixture;
    final repairRepository = repository as _SimulatedPreferenceRepairRepository;
    try {
      await app.reloadRecords();
      await expectLater(
        app.repairDefaultWorkspaceSectionConflict(retainedRecordId: keepId),
        throwsA(isA<StateError>()),
      );
      expect(app.hasDefaultSectionPreferenceConflict, isTrue);
      expect(app.preferenceError, contains('尚未确认'));
      expect(app.defaultSectionConflictRetainedRecordId, keepId);
      expect(repairRepository.unconfirmedMarkers, hasLength(1));
      expect(await database.countPending(_vaultId), 0);

      // The failure projection already removed the optimistic tombstone from
      // active candidates, but its marker keeps the latch until retry readback.
      repairRepository.failSyncPass = null;
      await app.repairDefaultWorkspaceSectionConflict(retainedRecordId: keepId);
      expect(app.hasDefaultSectionPreferenceConflict, isFalse);
      expect(app.preferenceError, isNull);
      expect(app.defaultSectionConflictCandidates, isEmpty);
      expect(repairRepository.unconfirmedMarkers, isEmpty);
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });

  test('read-only Vault rejects a preference write', () async {
    final fixture = await _fixture(sodium, canWrite: false);
    final (app, database, _, identity, key) = fixture;
    try {
      await expectLater(
        app.saveWorkspaceDefaultSection('snippets'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        app.saveTerminalFontSizePreference(16),
        throwsA(isA<StateError>()),
      );
      expect(await database.countPending(_vaultId), 0);

      app.activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
        status: 'deleting',
        canWrite: true,
      );
      await expectLater(
        app.saveWorkspaceDefaultSection('snippets'),
        throwsA(isA<StateError>()),
      );
      expect(await database.countPending(_vaultId), 0);
    } finally {
      app.dispose();
      identity.dispose();
      key.fillRange(0, key.length, 0);
      await database.close();
    }
  });
}

Future<
  (AppController, ClientDatabase, SyncRepository, DeviceIdentity, Uint8List)
>
_fixture(
  SodiumSumo sodium, {
  bool canWrite = true,
  bool delaySave = false,
  List<Map<String, dynamic>>? repairRows,
  bool changeCandidateOnSync = false,
  int? failSyncPass,
  bool failPreferenceRepairScan = false,
  bool useActualPreferenceRepairMarkers = false,
  Future<List<Map<String, dynamic>>> Function(SyncRepository repository)?
  loadRecordsForTesting,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final key = sodium.randombytes.buf(32);
  final api = _PreferenceApi(identity);
  final repository = delaySave
      ? _DelayedSavePreferenceRepository(
          api: api,
          database: database,
          crypto: VaultCrypto(sodium),
          identity: identity,
          serverSpaceId: _serverSpaceId,
          instanceId: _instanceId,
          vaultId: _vaultId,
          keyEpoch: '1',
          membershipVersion: '1',
          serverGeneration: '1',
          vaultKey: key,
          canWrite: canWrite,
        )
      : repairRows != null
      ? _SimulatedPreferenceRepairRepository(
          api: api,
          database: database,
          crypto: VaultCrypto(sodium),
          identity: identity,
          serverSpaceId: _serverSpaceId,
          instanceId: _instanceId,
          vaultId: _vaultId,
          keyEpoch: '1',
          membershipVersion: '1',
          serverGeneration: '1',
          vaultKey: key,
          canWrite: canWrite,
          initialRows: repairRows,
          changeCandidateOnSync: changeCandidateOnSync,
          failSyncPass: failSyncPass,
          failPreferenceRepairScan: failPreferenceRepairScan,
          useActualPreferenceRepairMarkers: useActualPreferenceRepairMarkers,
        )
      : SyncRepository(
          api: api,
          database: database,
          crypto: VaultCrypto(sodium),
          identity: identity,
          serverSpaceId: _serverSpaceId,
          instanceId: _instanceId,
          vaultId: _vaultId,
          keyEpoch: '1',
          membershipVersion: '1',
          serverGeneration: '1',
          vaultKey: key,
          canWrite: canWrite,
        );
  if (useActualPreferenceRepairMarkers) {
    repository.serverGeneration = _serverGeneration;
  }
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          repositoryForTesting: repository,
          loadRecordsForTesting: loadRecordsForTesting,
        )
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  return (app, database, repository, identity, key);
}

Map<String, dynamic> _preferenceRow({
  String id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  required String value,
  required String revisionId,
}) => {
  'id': id,
  'type': 'preference',
  'scope': 'workspace',
  'key': 'defaultSection',
  'value': value,
  'platform_family': 'all',
  '_record_id': id,
  '_revision_id': revisionId,
};

Map<String, dynamic> _terminalFontSizePreferenceRow({
  String id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  required int fontSize,
  required String revisionId,
}) => {
  'id': id,
  'type': 'preference',
  'scope': 'workspace',
  'key': 'terminalFontSize',
  'value': '$fontSize',
  'platform_family': 'all',
  '_record_id': id,
  '_revision_id': revisionId,
};

Map<String, dynamic> _terminalThemePreferenceRow({
  String id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  required String theme,
  required String revisionId,
}) => {
  'id': id,
  'type': 'preference',
  'scope': 'workspace',
  'key': 'terminalTheme',
  'value': theme,
  'platform_family': 'all',
  '_record_id': id,
  '_revision_id': revisionId,
};

Map<String, dynamic> _terminalShortcutsPreferenceRow({
  String id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  required TerminalShortcutBindings bindings,
  required String revisionId,
}) => {
  'id': id,
  'type': 'preference',
  'scope': 'workspace',
  'key': 'terminalShortcuts',
  'value': bindings.toValue(),
  'platform_family': 'all',
  '_record_id': id,
  '_revision_id': revisionId,
};

const _revisionA = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _revisionB = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _revisionC = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
const _otherVaultId = '66666666-6666-4666-8666-666666666666';
const _serverGeneration = '77777777-7777-4777-8777-777777777777';
const _otherServerGeneration = '88888888-8888-4888-8888-888888888888';

// The scanner extracts cursor ordering metadata; it does not validate this
// dummy HMAC. API-server acceptance of a real cursor is covered by the Web E2E.
String _serverCursor(
  String sequence, {
  String generation = _serverGeneration,
  String vaultId = _vaultId,
}) => _opaqueServerCursor(
  '{"generation":"$generation","seq":$sequence,"v":1,'
  '"vault_id":"$vaultId"}',
);

String _opaqueServerCursor(String payload) => base64Url
    .encode([...utf8.encode(payload), ...List<int>.filled(32, 0)])
    .replaceAll('=', '');

class _PreferenceApi extends ApiClient {
  _PreferenceApi(this.identity) : super(baseUrl: 'https://preference.test');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': _userId,
    'signing_public_key': identity.signingPublicKey,
    'status': 'active',
  };

  @override
  Future<List<Map<String, dynamic>>> devices() async => [_device];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    _device,
  ];
}

class _DelayedSavePreferenceRepository extends SyncRepository {
  _DelayedSavePreferenceRepository({
    required super.api,
    required super.database,
    required super.crypto,
    required super.identity,
    required super.serverSpaceId,
    required super.instanceId,
    required super.vaultId,
    required super.keyEpoch,
    required super.membershipVersion,
    required super.serverGeneration,
    required super.vaultKey,
    required super.canWrite,
  });

  final saveStarted = Completer<void>();
  final saveResult = Completer<Map<String, Object?>>();

  @override
  Future<Map<String, Object?>> saveRecord({
    required String recordId,
    required Map<String, Object?> plaintext,
    String? baseRevisionId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String operation = 'create',
    bool cleanupAttachmentJobsOnDelete = false,
  }) {
    if (!saveStarted.isCompleted) saveStarted.complete();
    return saveResult.future;
  }
}

class _SimulatedPreferenceRepairRepository extends SyncRepository {
  _SimulatedPreferenceRepairRepository({
    required super.api,
    required super.database,
    required super.crypto,
    required super.identity,
    required super.serverSpaceId,
    required super.instanceId,
    required super.vaultId,
    required super.keyEpoch,
    required super.membershipVersion,
    required super.serverGeneration,
    required super.vaultKey,
    required super.canWrite,
    required List<Map<String, dynamic>> initialRows,
    required this.changeCandidateOnSync,
    required this.failSyncPass,
    required this.failPreferenceRepairScan,
    required this.useActualPreferenceRepairMarkers,
  }) : serverRows = initialRows.map(Map<String, dynamic>.from).toList();

  final List<Map<String, dynamic>> serverRows;
  final List<Map<String, Object?>> savedOperations = [];
  final List<PendingDefaultPreferenceRepair> unconfirmedMarkers = [];
  final Map<int, Completer<void>> syncPassStarted = {};
  final Map<int, Completer<void>> syncPassGates = {};
  final bool changeCandidateOnSync;
  final bool useActualPreferenceRepairMarkers;
  bool failPreferenceRepairScan;
  int? failSyncPass;
  int syncPasses = 0;
  int activeSyncPasses = 0;
  int maximumConcurrentSyncPasses = 0;
  int _commitSequence = 10;

  @override
  Future<List<Map<String, dynamic>>> loadRecords({
    bool includeDeleted = false,
  }) async {
    unavailableRecordIds.clear();
    return serverRows.map(Map<String, dynamic>.from).toList(growable: false);
  }

  @override
  Future<List<PendingDefaultPreferenceRepair>>
  unconfirmedDefaultPreferenceRepairs() async {
    final all = await unconfirmedPreferenceRepairs();
    return List.unmodifiable(
      all.where((marker) => marker.isDefaultWorkspaceSection),
    );
  }

  @override
  Future<List<PendingDefaultPreferenceRepair>>
  unconfirmedPreferenceRepairs() async {
    if (useActualPreferenceRepairMarkers) {
      return super.unconfirmedPreferenceRepairs();
    }
    if (failPreferenceRepairScan) {
      throw const FormatException('simulated invalid repair marker');
    }
    return List.unmodifiable(unconfirmedMarkers);
  }

  @override
  Future<Map<String, Object?>> saveRecord({
    required String recordId,
    required Map<String, Object?> plaintext,
    String? baseRevisionId,
    String? expectedCachedHeadRevisionId,
    Map<String, String>? expectedVaultHeadRevisionIds,
    bool preserveOutboxChain = false,
    String operation = 'create',
    bool cleanupAttachmentJobsOnDelete = false,
  }) async {
    final envelope = await super.saveRecord(
      recordId: recordId,
      plaintext: plaintext,
      baseRevisionId: baseRevisionId,
      expectedCachedHeadRevisionId: expectedCachedHeadRevisionId,
      expectedVaultHeadRevisionIds: expectedVaultHeadRevisionIds,
      preserveOutboxChain: preserveOutboxChain,
      operation: operation,
      cleanupAttachmentJobsOnDelete: cleanupAttachmentJobsOnDelete,
    );
    savedOperations.add({
      'recordId': recordId,
      'baseRevisionId': baseRevisionId,
      'operation': operation,
      'plaintext': Map<String, Object?>.from(plaintext),
    });
    final marker =
        plaintext['preference_conflict_repair'] ??
        plaintext['default_section_conflict_repair'];
    if (!useActualPreferenceRepairMarkers &&
        operation == 'delete' &&
        marker is Map) {
      unconfirmedMarkers.add(
        PendingDefaultPreferenceRepair(
          deletedRecordId: recordId,
          retainedRecordId: marker['retained_record_id']! as String,
          scope:
              marker['scope'] as String? ??
              VaultPreferenceRecord.workspaceScope,
          key:
              marker['key'] as String? ??
              VaultPreferenceRecord.defaultSectionKey,
          platformFamily:
              marker['platform_family'] as String? ??
              VaultPreferenceRecord.allPlatforms,
        ),
      );
    }
    return envelope;
  }

  @override
  Future<SyncResult> synchronize() async {
    final pass = ++syncPasses;
    activeSyncPasses++;
    if (activeSyncPasses > maximumConcurrentSyncPasses) {
      maximumConcurrentSyncPasses = activeSyncPasses;
    }
    final started = syncPassStarted[pass];
    if (started != null && !started.isCompleted) started.complete();
    try {
      await syncPassGates[pass]?.future;
      verifiedServerViewRevision++;
      if (changeCandidateOnSync && pass == 1) {
        final current = serverRows.first;
        current['value'] = 'groups';
        current['_revision_id'] = _revisionC;
      }
      final pending = await database.allPendingOperations(vaultId);
      final cursorBeforePendingCommit = _commitSequence;
      for (final operation in pending) {
        final envelope =
            jsonDecode(operation.envelopeJson) as Map<String, dynamic>;
        final header = envelope['header'] as Map<String, dynamic>;
        if (header['operation'] == 'delete') {
          serverRows.removeWhere(
            (row) => row['_record_id'] == operation.recordId,
          );
        }
        _commitSequence++;
        await database.markCommitted(
          opId: operation.opId,
          commitSeq: '$_commitSequence',
        );
      }
      if (pending.isEmpty && unconfirmedMarkers.isNotEmpty) {
        unconfirmedMarkers.clear();
      }
      if (failSyncPass == pass) {
        throw StateError('simulated sync failure');
      }
      await database.saveCheckpoint(
        vaultId: vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        cursor: useActualPreferenceRepairMarkers
            ? _serverCursor(
                '${pending.isEmpty ? _commitSequence : cursorBeforePendingCommit}',
              )
            : null,
        serverGeneration: serverGeneration,
      );
      return SyncResult(
        pendingCount: await database.countPending(vaultId),
        receivedCount: 0,
        conflictCount: 0,
        status: 'idle',
        serverGeneration: serverGeneration,
      );
    } finally {
      activeSyncPasses--;
    }
  }
}
