import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show SemanticsAction;

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/device_redaction_capability.dart';
import 'package:aterm_client/domain/record_redaction.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _recordId = '22222222-2222-4222-8222-222222222222';
const _secondRecordId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _privateBlockingDeviceId = 'private-device-id-7f3a';
const _privateAccountMarker = 'private-member@example.test';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Hosts recycle bin shows verified entry and confirms restore', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _RecycleBinController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..session = const AuthSession(
            accountId: '33333333-3333-4333-8333-333333333333',
            accessToken: 'test-access-token',
            expiresIn: 900,
            refreshToken: 'test-refresh-token',
            deviceId: '44444444-4444-4444-8444-444444444444',
            vaults: [
              VaultDescriptor(
                id: _vaultId,
                role: 'owner',
                activeKeyEpoch: '1',
                membershipVersion: '1',
              ),
            ],
          );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();

      expect(find.text('Recycle bin'), findsNWidgets(2));
      expect(find.text('Production edge'), findsOneWidget);
      expect(find.textContaining('Restore deadline'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_restore-$_recordId')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Restore this record?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_restore_confirm')),
      );
      await tester.pumpAndSettle();

      expect(app.restoreCalls, 1);
      expect(find.text('Production edge'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'Recycle bin rows expose identity and status semantics with accessible actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      final semantics = tester.ensureSemantics();
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _makeController(sodium, database)
        ..entries[0] = _recycleBinEntry(
          restoreUntil: DateTime.now().toUtc().add(const Duration(days: 5)),
          autoPurgeEnabled: true,
        );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final openButton = find.byKey(const ValueKey('recycle_bin_open'));
        await tester.ensureVisible(openButton);
        await tester.tap(openButton);
        await tester.pumpAndSettle();

        final enabledRow = tester.getSemantics(
          find.byKey(const ValueKey('recycle_bin_semantics-$_recordId')),
        );
        expect(
          enabledRow.label,
          contains(
            'Recycle bin record: Production edge, ID 22222222, '
            'Automatic purge consent: Enabled, Restore deadline status: Future',
          ),
        );
        final enabledConsentAction = tester.getSemantics(
          find.byKey(const ValueKey('recycle_bin_auto_purge-$_recordId')),
        );
        final enabledRestoreAction = tester.getSemantics(
          find.byKey(const ValueKey('recycle_bin_restore-$_recordId')),
        );
        expect(
          enabledConsentAction.getSemanticsData().hasAction(
            SemanticsAction.tap,
          ),
          isTrue,
        );
        expect(
          enabledRestoreAction.getSemanticsData().hasAction(
            SemanticsAction.tap,
          ),
          isTrue,
        );
        expect(find.text('Withdraw consent'), findsOneWidget);
        expect(find.text('Restore'), findsOneWidget);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        app.entries[0] = _recycleBinEntry(
          recordId: _secondRecordId,
          displayName: 'Staging bastion',
          restoreUntil: DateTime.now().toUtc().subtract(
            const Duration(days: 1),
          ),
        );
        final reopenButton = find.byKey(const ValueKey('recycle_bin_open'));
        await tester.ensureVisible(reopenButton);
        await tester.tap(reopenButton);
        await tester.pumpAndSettle();

        final passedRow = tester.getSemantics(
          find.byKey(const ValueKey('recycle_bin_semantics-$_secondRecordId')),
        );
        expect(
          passedRow.label,
          contains(
            'Recycle bin record: Staging bastion, ID aaaaaaaa, '
            'Automatic purge consent: Off, Restore deadline status: Passed',
          ),
        );
        for (final key in [
          'recycle_bin_auto_purge-$_secondRecordId',
          'recycle_bin_restore-$_secondRecordId',
        ]) {
          final action = tester.getSemantics(find.byKey(ValueKey(key)));
          expect(
            action.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
            reason: key,
          );
        }
        expect(find.text('Allow future purge'), findsOneWidget);
        expect(find.text('Restore'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        semantics.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('expired restore rejection explains how to continue', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)..expireRestore = true;

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_restore-$_recordId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_restore_confirm')),
      );
      await tester.pumpAndSettle();

      final error = tester.widget<Text>(
        find.byKey(const ValueKey('recycle_bin_restore_error')),
      );
      expect(error.data, contains('超过服务端恢复期限'));
      expect(error.data, contains('新的 ID'));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
  testWidgets(
    'owner purge requires explicit acknowledgement and confirmation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _makeController(sodium, database)
        ..entries[0] = _recycleBinEntry(
          restoreUntil: DateTime.utc(2026, 10, 1, 12),
        );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final openButton = find.byKey(const ValueKey('recycle_bin_open'));
        await tester.ensureVisible(openButton);
        await tester.tap(openButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Permanently purge this record?'), findsOneWidget);
        expect(find.textContaining('Restore deadline:'), findsOneWidget);
        expect(find.textContaining('Offline device copies'), findsOneWidget);
        expect(app.purgeCalls, 0);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('recycle_bin_purge_confirm')),
              )
              .onPressed,
          isNull,
        );

        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_purge_acknowledgement')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_purge_confirm')),
        );
        await tester.pumpAndSettle();
        expect(app.purgeCalls, 1);
        expect(find.text('Production edge'), findsNothing);
        expect(
          find.textContaining('permanently removed from active server state'),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('non-owner cannot see permanent purge action', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'editor',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      )
      ..entries[0] = _recycleBinEntry(
        restoreUntil: DateTime.utc(2026, 10, 1, 12),
      );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recycle_bin_auto_purge-$_recordId')),
        findsNothing,
      );
      expect(find.text('Production edge'), findsOneWidget);
      expect(find.textContaining('bounded Maintenance'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'owner must acknowledge and type the phrase to record future purge consent',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _makeController(sodium, database);

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final openButton = find.byKey(const ValueKey('recycle_bin_open'));
        await tester.ensureVisible(openButton);
        await tester.tap(openButton);
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'Consent applies to this exact tombstone. When enabled, bounded Maintenance may purge it after its restore deadline and other required checks.',
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_auto_purge-$_recordId')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Allow future automatic purge?'), findsOneWidget);
        expect(
          find.text(
            'This records consent for this exact tombstone (Production edge) only. When opted in, bounded Maintenance may automatically purge it after its restore deadline and other required checks. Enabling consent does not purge it immediately.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Offline device copies and exports are not removed.'),
          findsOneWidget,
        );
        expect(app.automaticPurgeCalls, 0);

        final confirm = tester.widget<FilledButton>(
          find.byKey(const ValueKey('recycle_bin_auto_purge_confirm')),
        );
        expect(confirm.onPressed, isNull);
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_auto_purge_acknowledgement')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('recycle_bin_auto_purge_phrase')),
          'ENABLE AUTOMATIC PURGE extra',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('recycle_bin_auto_purge_confirm')),
              )
              .onPressed,
          isNull,
        );
        await tester.enterText(
          find.byKey(const ValueKey('recycle_bin_auto_purge_phrase')),
          'ENABLE AUTOMATIC PURGE',
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('recycle_bin_auto_purge_confirm')),
              )
              .onPressed,
          isNotNull,
        );
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_auto_purge_confirm')),
        );
        await tester.pumpAndSettle();

        expect(app.automaticPurgeCalls, 1);
        expect(app.lastAutomaticPurgeEnabled, isTrue);
        expect(app.entries.single.autoPurgeEnabled, isTrue);
        expect(find.textContaining('consent recorded'), findsOneWidget);
        expect(
          find.textContaining(
            'Automatic purge consent: Enabled. Consent applies to this exact tombstone.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('offline device copies and exports'),
          findsWidgets,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('owner withdraws future purge consent with one direct save', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..entries[0] = _recycleBinEntry(
        restoreUntil: DateTime.utc(2026, 10, 31, 12),
        autoPurgeEnabled: true,
        autoPurgeRevision: '4',
      );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_auto_purge-$_recordId')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Allow future automatic purge?'), findsNothing);
      expect(app.automaticPurgeCalls, 1);
      expect(app.lastAutomaticPurgeEnabled, isFalse);
      expect(app.entries.single.autoPurgeEnabled, isFalse);
      expect(
        find.textContaining('Future automatic purge consent withdrawn'),
        findsOneWidget,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('owner waits for the advertised restore deadline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..entries[0] = _recycleBinEntry(
        restoreUntil: DateTime.now().toUtc().add(const Duration(days: 5)),
      );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
        findsNothing,
      );
      expect(
        find.textContaining(
          'Permanent purge becomes available after this deadline',
        ),
        findsOneWidget,
      );
      expect(app.purgeCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('owner cannot purge when server deadline is missing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..entries[0] = _recycleBinEntry(restoreUntil: null);

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recycle_bin_restore-$_recordId')),
        findsOneWidget,
      );
      expect(
        find.textContaining('server did not provide a restore deadline'),
        findsOneWidget,
      );
      expect(app.purgeCalls, 0);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('server purge deadline error displays restore_until', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..purgeNotDue = true
      ..entries[0] = _recycleBinEntry(
        restoreUntil: DateTime.utc(2026, 10, 1, 12),
      );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_purge_acknowledgement')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recycle_bin_purge_confirm')));
      await tester.pumpAndSettle();

      final error = tester.widget<Text>(
        find.byKey(const ValueKey('recycle_bin_purge_error')),
      );
      expect(error.data, contains('restore period has not ended'));
      expect(error.data, contains('Restore deadline:'));
      expect(app.entries, hasLength(1));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets(
    'redaction capability failure gives private-safe upgrade guidance',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _makeController(sodium, database)
        ..purgeCapabilityRequired = true
        ..entries[0] = _recycleBinEntry(
          restoreUntil: DateTime.now().toUtc().subtract(
            const Duration(days: 1),
          ),
        );

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final openButton = find.byKey(const ValueKey('recycle_bin_open'));
        await tester.ensureVisible(openButton);
        await tester.tap(openButton);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_purge_acknowledgement')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('recycle_bin_purge_confirm')),
        );
        await tester.pumpAndSettle();

        final error = tester.widget<Text>(
          find.byKey(const ValueKey('recycle_bin_purge_error')),
        );
        expect(
          error.data,
          'Every active Vault device must support redaction v1 before this record can be purged. Upgrade or retire unsupported devices, then retry.',
        );
        expect(find.textContaining(_privateBlockingDeviceId), findsNothing);
        expect(find.textContaining(_privateAccountMarker), findsNothing);
        expect(app.entries, hasLength(1));
        expect(app.purgeCalls, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets(
    'Recycle Bin shows Vault device blockers and opens trusted device management',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final readyIdentity = DeviceIdentity.create(sodium);
      final missingIdentity = DeviceIdentity.create(sodium);
      final app = _makeController(sodium, database)
        ..vaultDeviceRowsVaultId = _vaultId
        ..vaultDeviceRows = [
          _readinessDevice(
            '77777777-7777-4777-8777-777777777777',
            'Ready member laptop',
            readyIdentity,
            report: _signedRedactionReport(
              sodium,
              readyIdentity,
              deviceId: '77777777-7777-4777-8777-777777777777',
            ),
          ),
          _readinessDevice(
            '88888888-8888-4888-8888-888888888888',
            'Needs sync tablet',
            missingIdentity,
            report: null,
          ),
          _readinessDevice(
            '99999999-9999-4999-8999-999999999999',
            'Revoked phone',
            missingIdentity,
            report: null,
            status: 'revoked',
          ),
        ];

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final openButton = find.byKey(const ValueKey('recycle_bin_open'));
        await tester.ensureVisible(openButton);
        await tester.tap(openButton);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('recycle_bin_redaction_readiness')),
          findsOneWidget,
        );
        expect(find.text('Redaction readiness'), findsOneWidget);
        expect(
          find.text(
            '1 of 2 active Vault devices are ready; 1 report(s) block permanent purge.',
          ),
          findsOneWidget,
        );
        expect(find.text('Report not received'), findsOneWidget);
        expect(find.text('Needs sync tablet · 88888888'), findsOneWidget);
        expect(find.text('Revoked phone · 99999999'), findsNothing);
        expect(
          find.byKey(const ValueKey('vault_redaction_readiness_refresh')),
          findsOneWidget,
        );
        expect(app.vaultDeviceRefreshCalls, 1);
        await tester.tap(
          find.byKey(const ValueKey('vault_redaction_readiness_refresh')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Refresh readiness'), findsOneWidget);
        expect(app.vaultDeviceRefreshCalls, 2);
        final reviewDevices = find.byKey(
          const ValueKey('recycle_bin_review_trusted_devices'),
        );
        await tester.tap(reviewDevices);
        await tester.pumpAndSettle();

        expect(app.page, WorkspacePage.devices);
        expect(find.text('Recycle bin'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        readyIdentity.dispose();
        missingIdentity.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );

  testWidgets('unresolved conflict failure gives private-safe resolve guidance', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..purgeHasUnresolvedConflicts = true
      ..entries[0] = _recycleBinEntry(
        restoreUntil: DateTime.now().toUtc().subtract(const Duration(days: 1)),
      );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_purge_acknowledgement')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recycle_bin_purge_confirm')));
      await tester.pumpAndSettle();

      final error = tester.widget<Text>(
        find.byKey(const ValueKey('recycle_bin_purge_error')),
      );
      expect(
        error.data,
        'Resolve or discard this record’s outstanding conflict before permanently purging it.',
      );
      expect(find.textContaining(_privateBlockingDeviceId), findsNothing);
      expect(find.textContaining(_privateAccountMarker), findsNothing);
      expect(app.entries, hasLength(1));
      expect(app.purgeCalls, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('501 response explains permanent purge is unsupported', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1000));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _makeController(sodium, database)
      ..purgeUnsupported = true
      ..entries[0] = _recycleBinEntry(
        restoreUntil: DateTime.utc(2026, 10, 1, 12),
      );

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      final openButton = find.byKey(const ValueKey('recycle_bin_open'));
      await tester.ensureVisible(openButton);
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_purge-$_recordId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recycle_bin_purge_acknowledgement')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recycle_bin_purge_confirm')));
      await tester.pumpAndSettle();

      final error = tester.widget<Text>(
        find.byKey(const ValueKey('recycle_bin_purge_error')),
      );
      expect(error.data, contains('does not support permanent record purge'));
      expect(error.data, contains('No purge was performed'));
      expect(find.text('Production edge'), findsOneWidget);
      expect(app.purgeCalls, 1);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

RecycleBinRecord _recycleBinEntry({
  required DateTime? restoreUntil,
  String recordId = _recordId,
  String displayName = 'Production edge',
  bool autoPurgeEnabled = false,
  String autoPurgeRevision = '0',
}) => RecycleBinRecord(
  recordId: recordId,
  tombstoneRevisionId: '55555555-5555-4555-8555-555555555555',
  previousRevisionId: '66666666-6666-4666-8666-666666666666',
  deletedSeq: '12',
  recordType: 'host',
  displayName: displayName,
  deletedAt: DateTime.utc(2026, 9, 1, 12),
  restoreUntil: restoreUntil,
  canRestore: true,
  restorePending: false,
  autoPurgeEnabled: autoPurgeEnabled,
  autoPurgeRevision: autoPurgeRevision,
);

Map<String, dynamic> _readinessDevice(
  String deviceId,
  String name,
  DeviceIdentity identity, {
  required Map<String, dynamic>? report,
  String status = 'active',
  String membershipStatus = 'active',
}) => {
  'device_id': deviceId,
  'user_id': '33333333-3333-4333-8333-333333333333',
  'name': name,
  'signing_public_key': encodeBase64Url(identity.signing.publicKey),
  'status': status,
  'membership_status': membershipStatus,
  'redaction_capability_report': report,
};

Map<String, dynamic> _signedRedactionReport(
  SodiumSumo sodium,
  DeviceIdentity signer, {
  required String deviceId,
}) {
  final unsigned = <String, Object?>{
    'format': deviceRedactionCapabilityFormat,
    'account_id': '33333333-3333-4333-8333-333333333333',
    'device_id': deviceId,
    'revision': 3,
    'sync_redaction_version': 1,
  };
  final signature = sodium.crypto.sign.detached(
    message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
    secretKey: signer.signing.secretKey,
  );
  return {
    ...unsigned,
    'signature': encodeBase64Url(signature),
    'invalidated_at': null,
  };
}

_RecycleBinController _makeController(
  SodiumSumo sodium,
  ClientDatabase database,
) =>
    _RecycleBinController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
      )
      ..stage = ClientStage.workspace
      ..page = WorkspacePage.hosts
      ..activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      )
      ..session = const AuthSession(
        accountId: '33333333-3333-4333-8333-333333333333',
        accessToken: 'test-access-token',
        expiresIn: 900,
        refreshToken: 'test-refresh-token',
        deviceId: '44444444-4444-4444-8444-444444444444',
        vaults: [
          VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          ),
        ],
      );

class _RecycleBinController extends AppController {
  _RecycleBinController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  int restoreCalls = 0;
  bool expireRestore = false;
  int purgeCalls = 0;
  int automaticPurgeCalls = 0;
  bool? lastAutomaticPurgeEnabled;
  bool purgeUnsupported = false;
  bool purgeNotDue = false;
  bool purgeCapabilityRequired = false;
  bool purgeHasUnresolvedConflicts = false;
  int vaultDeviceRefreshCalls = 0;
  final List<RecycleBinRecord> entries = [
    RecycleBinRecord(
      recordId: _recordId,
      tombstoneRevisionId: '55555555-5555-4555-8555-555555555555',
      previousRevisionId: '66666666-6666-4666-8666-666666666666',
      deletedSeq: '12',
      recordType: 'host',
      displayName: 'Production edge',
      deletedAt: DateTime.utc(2026, 10, 1, 12),
      restoreUntil: DateTime.utc(2026, 10, 31, 12),
      canRestore: true,
      restorePending: false,
    ),
  ];

  @override
  Future<List<RecycleBinRecord>> loadRecycleBin() async =>
      List.unmodifiable(entries);

  @override
  Future<void> refreshVaultDeviceRows({
    String? vaultId,
    bool background = false,
    bool recoverCurrentDevice = false,
  }) async {
    vaultDeviceRefreshCalls++;
  }

  @override
  Future<void> restoreRecycleBinRecord(RecycleBinRecord entry) async {
    restoreCalls++;
    if (expireRestore) {
      throw const ApiException(
        statusCode: 409,
        code: 'RECORD_RESTORE_EXPIRED',
        message: 'Restore retention expired.',
        details: {'restore_until': '2026-10-01T12:00:00Z'},
      );
    }
    entries.removeWhere((item) => item.recordId == entry.recordId);
  }

  @override
  Future<RecordRedactionProof> purgeRecycleBinRecord(
    RecycleBinRecord entry,
  ) async {
    purgeCalls++;
    if (purgeUnsupported) {
      throw const ApiException(
        statusCode: 501,
        code: 'RECORD_PURGE_BACKEND_PENDING',
        message: 'Permanent purge is not supported for this backend yet.',
      );
    }
    if (purgeNotDue) {
      throw const ApiException(
        statusCode: 409,
        code: 'RECORD_PURGE_NOT_DUE',
        message: 'Restore retention has not elapsed.',
        details: {'restore_until': '2026-10-20T12:00:00Z'},
      );
    }
    if (purgeCapabilityRequired) {
      throw const ApiException(
        statusCode: 409,
        code: 'VAULT_REDACTION_CAPABILITY_REQUIRED',
        message:
            'Blocked by $_privateBlockingDeviceId for $_privateAccountMarker.',
        details: {
          'device_id': _privateBlockingDeviceId,
          'account': _privateAccountMarker,
        },
      );
    }
    if (purgeHasUnresolvedConflicts) {
      throw const ApiException(
        statusCode: 409,
        code: 'RECORD_HAS_UNRESOLVED_CONFLICTS',
        message:
            'Conflict on $_privateBlockingDeviceId for $_privateAccountMarker.',
        details: {
          'device_id': _privateBlockingDeviceId,
          'account': _privateAccountMarker,
        },
      );
    }
    entries.removeWhere((item) => item.recordId == entry.recordId);
    return const RecordRedactionProof(
      redactionId: '77777777-7777-4777-8777-777777777777',
      instanceId: '88888888-8888-4888-8888-888888888888',
      serverSpaceId: '99999999-9999-4999-8999-999999999999',
      vaultId: _vaultId,
      recordId: _recordId,
      deletedRevisionId: '55555555-5555-4555-8555-555555555555',
      deletedSeq: '12',
      redactionSeq: '13',
      signingPublicKey: 'test-public-key',
      signature: 'test-signature',
    );
  }

  @override
  Future<void> setRecycleBinRecordAutomaticPurge(
    RecycleBinRecord entry, {
    required bool enabled,
  }) async {
    automaticPurgeCalls++;
    lastAutomaticPurgeEnabled = enabled;
    final nextRevision = (int.parse(entry.autoPurgeRevision) + 1).toString();
    entries[entries.indexWhere(
      (item) => item.recordId == entry.recordId,
    )] = _recycleBinEntry(
      restoreUntil: entry.restoreUntil,
      autoPurgeEnabled: enabled,
      autoPurgeRevision: nextRevision,
    );
  }
}
