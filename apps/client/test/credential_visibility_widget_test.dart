import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_ack_store.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_models.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_service.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/account_settings.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/credential_visibility/credential_visibility_admin_ui.dart';
import 'package:aterm_client/ui/credential_visibility/credential_visibility_widgets.dart';
import 'package:aterm_client/ui/credential_visibility/database_encryption_status.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sodium/sodium_sumo.dart';

import 'support/credential_visibility_fakes.dart';
import 'support/credential_visibility_fixtures.dart';

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  late SodiumSumo sodium;
  late EscrowTestInstance instance;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    sodium = await SodiumSumoInit.init();
    instance = EscrowTestInstance(sodium);
  });

  /// A signed-in controller whose credential-visibility service talks to
  /// [server] and uses an in-memory acknowledgement store.
  (
    CvTestAppController,
    CredentialVisibilityService,
    MemoryCredentialVisibilityAckStore,
  )
  bind(
    FakeCredentialVisibilityServer server, {
    bool admin = false,
    MemoryCredentialVisibilityAckStore? store,
  }) {
    final app = cvApp(
      sodium,
      server.api,
      pinnedKey: instance.signingPublicKey,
      admin: admin,
    );
    final ackStore = store ?? MemoryCredentialVisibilityAckStore();
    final service = CredentialVisibilityService(app, ackStore: ackStore);
    debugInstallCredentialVisibilityService(app, service);
    return (app, service, ackStore);
  }

  Future<void> settle(
    WidgetTester tester,
    CredentialVisibilityService service,
  ) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (!service.refreshing) break;
    }
    await tester.pump();
  }

  group('settings section', () {
    testWidgets('private: green lock, explanation, no views', (tester) async {
      await tester.pumpWidget(
        _host(
          const CredentialVisibilityStatusView(
            mode: CredentialVisibilityMode.private,
            changedAt: null,
            status: null,
          ),
        ),
      );
      final l10n = currentL10n;
      expect(
        find.byKey(const ValueKey('credential_visibility_mode_private')),
        findsOneWidget,
      );
      expect(find.text(l10n.cvModePrivateShort), findsOneWidget);
      expect(find.text(l10n.cvModePrivateBody), findsOneWidget);
      expect(find.text(l10n.cvModeAdminVisibleBody), findsNothing);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential_visibility_no_views')),
        findsOneWidget,
      );
      expect(find.text(l10n.cvModeSetByAdmin), findsOneWidget);
    });

    testWidgets('admin-visible: amber warning, escrow status, admin views', (
      tester,
    ) async {
      final status = CredentialVisibilityStatus.fromJson({
        'mode': 'admin_visible',
        'changed_at': '2026-11-13T09:00:00Z',
        'escrow_status': 'pending',
        'escrow_key': null,
        'missing': const [],
        'admin_views': [
          {
            'viewed_at': '2026-11-13T11:00:00Z',
            'admin_username': 'root@example.test',
            'vault_id': escrowVaultId,
          },
          {
            'viewed_at': '2026-11-12T11:00:00Z',
            'admin_username': null,
            'vault_id': null,
          },
        ],
      });
      await tester.pumpWidget(
        _host(
          CredentialVisibilityStatusView(
            mode: status.mode,
            changedAt: status.changedAt,
            status: status,
            vaultName: (id) => id == escrowVaultId ? 'Production' : null,
          ),
        ),
      );
      final l10n = currentL10n;
      expect(
        find.byKey(const ValueKey('credential_visibility_mode_admin_visible')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text(l10n.cvModeAdminVisibleBody), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential_visibility_escrow_pending')),
        findsOneWidget,
      );
      expect(
        find.textContaining('root@example.test viewed your credentials at'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          '${l10n.cvAdminViewDeletedAdmin} viewed your credentials at',
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.cvAdminViewVault('Production')), findsOneWidget);
    });

    testWidgets('Chinese catalog carries the specified notices', (
      tester,
    ) async {
      debugCurrentL10n = appLocalizationsFor(const Locale('zh'));
      addTearDown(
        () => debugCurrentL10n = appLocalizationsFor(fallbackAppLocale),
      );
      await tester.pumpWidget(
        _host(
          const Column(
            children: [
              CredentialVisibilityStatusView(
                mode: CredentialVisibilityMode.private,
                changedAt: null,
                status: null,
              ),
              CredentialVisibilityStatusView(
                mode: CredentialVisibilityMode.adminVisible,
                changedAt: null,
                status: null,
              ),
            ],
          ),
        ),
      );
      expect(
        find.text(
          '私密加密：你保存的主机密码、私钥等凭据只在你的设备上解密，服务器管理员无法查看。忘记主密码时，管理员也无法帮你恢复这些数据。',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          '管理员可见：本服务器的管理员可以查看你保存的主机密码、私钥和口令。你的账户主密码不会发送到服务器，管理员看不到。管理员每次查看都会被记录并显示在这里。',
        ),
        findsOneWidget,
      );
      expect(find.text('凭据可见性'), findsNWidgets(2));
    });

    testWidgets('settings card follows the live service state', (tester) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final (app, service, _) = bind(server);
      await tester.pumpWidget(
        _host(CredentialVisibilitySettingsCard(app: app)),
      );
      await settle(tester, service);
      expect(
        find.byKey(const ValueKey('credential_visibility_mode_private')),
        findsOneWidget,
      );
      server.status = cvStatus(
        mode: 'admin_visible',
        escrowStatus: 'complete',
        changedAt: '2026-11-13T12:00:00Z',
      );
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_refresh')),
      );
      await settle(tester, service);
      expect(
        find.byKey(const ValueKey('credential_visibility_mode_admin_visible')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('credential_visibility_escrow_complete')),
        findsOneWidget,
      );
      service.dispose();
      app.dispose();
    });
  });

  group('workspace indicator', () {
    testWidgets('shows only in admin-visible mode and opens the details', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(mode: 'admin_visible', escrowStatus: 'no_key'),
      );
      final (app, service, _) = bind(server);
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              CredentialVisibilityIndicator(app: app),
              CredentialVisibilityPrivacyBadge(
                app: app,
                fallback: const Text('PRIVATE'),
              ),
            ],
          ),
        ),
      );
      await settle(tester, service);
      final l10n = currentL10n;
      expect(
        find.byKey(const ValueKey('credential_visibility_indicator')),
        findsNWidgets(2),
      );
      expect(
        find.text('PRIVATE'),
        findsNothing,
        reason: 'never claims private',
      );
      // The header badge is icon-only; the full indicator carries the label.
      expect(find.text(l10n.cvModeAdminVisibleShort), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_indicator')).first,
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.cvModeAdminVisibleBody), findsOneWidget);
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();

      server.status = cvStatus(
        mode: 'private',
        changedAt: '2026-11-13T12:00:00Z',
      );
      await service.refresh();
      await settle(tester, service);
      expect(
        find.byKey(const ValueKey('credential_visibility_indicator')),
        findsNothing,
      );
      expect(find.text('PRIVATE'), findsOneWidget);
      service.dispose();
      app.dispose();
    });

    testWidgets('fits narrow rails and unbounded rows in every language', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(mode: 'admin_visible', escrowStatus: 'no_key'),
      );
      final (app, service, _) = bind(server);
      addTearDown(
        () => debugCurrentL10n = appLocalizationsFor(fallbackAppLocale),
      );
      for (final code in ['en', 'zh', 'ja', 'ru']) {
        debugCurrentL10n = appLocalizationsFor(Locale(code));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  // The wide rail header: title + badge in a 168px row.
                  SizedBox(
                    width: 168,
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Atermius',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        CredentialVisibilityPrivacyBadge(
                          app: app,
                          fallback: const Text('PRIVATE'),
                        ),
                      ],
                    ),
                  ),
                  // Unbounded row: the full label must stay bounded.
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [CredentialVisibilityIndicator(app: app)],
                    ),
                  ),
                  // Narrow rail footer.
                  SizedBox(
                    width: 52,
                    child: CredentialVisibilityIndicator(
                      app: app,
                      compact: true,
                    ),
                  ),
                  // Phone-width status bar with the badge.
                  SizedBox(
                    width: 320,
                    child: WorkspaceStatusBar(
                      status: 'SSH connected',
                      detail: 'ops@db-01.internal:22 · Production · Synced',
                      sessionCount: 3,
                      badge: CredentialVisibilityIndicator(app: app),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await settle(tester, service);
        expect(tester.takeException(), isNull, reason: code);
        expect(
          find.byKey(const ValueKey('credential_visibility_indicator')),
          findsNWidgets(4),
          reason: code,
        );
      }
      service.dispose();
      app.dispose();
    });

    testWidgets('in the workspace it opens Settings › Account', (tester) async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(mode: 'admin_visible', escrowStatus: 'no_key'),
      );
      final (app, service, _) = bind(server);
      app
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts;
      addTearDown(() => SettingsScaffold.requestedSection.value = null);
      SettingsSection section(String id, String body) => SettingsSection(
        id: id,
        title: id,
        icon: Icons.settings_outlined,
        description: id,
        builder: (_) => Text(body),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: app,
              builder: (_, _) => app.page == WorkspacePage.settings
                  ? SettingsScaffold(
                      sections: [
                        section('workspace', 'WORKSPACE BODY'),
                        section(accountSettingsSectionId, 'ACCOUNT BODY'),
                      ],
                    )
                  : CredentialVisibilityIndicator(app: app),
            ),
          ),
        ),
      );
      await settle(tester, service);
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_indicator')),
      );
      await tester.pumpAndSettle();
      expect(app.page, WorkspacePage.settings);
      expect(find.byType(AlertDialog), findsNothing, reason: 'no dialog');
      expect(find.text('ACCOUNT BODY').hitTestable(), findsOneWidget);
      expect(find.text('WORKSPACE BODY'), findsNothing, reason: 'not visited');
      expect(SettingsScaffold.requestedSection.value, isNull);

      // A settings page that is already showing follows a request as well.
      SettingsScaffold.requestSection('workspace');
      await tester.pumpAndSettle();
      expect(find.text('WORKSPACE BODY').hitTestable(), findsOneWidget);
      // A category the page does not offer is dropped, not kept for later.
      SettingsScaffold.requestSection('no-such-category');
      await tester.pump();
      expect(SettingsScaffold.requestedSection.value, isNull);
      expect(find.text('WORKSPACE BODY').hitTestable(), findsOneWidget);
      service.dispose();
      app.dispose();
    });

    testWidgets('a private account never sees "private" in an admin-visible '
        'Vault', (tester) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final (app, service, _) = bind(server);
      VaultDescriptor vault({required bool adminVisible}) =>
          VaultDescriptor.fromJson({
            'vault_id': escrowVaultId,
            'role': 'editor',
            'admin_visible': adminVisible,
          });
      app.activeVault = vault(adminVisible: true);
      await tester.pumpWidget(
        _host(
          CredentialVisibilityPrivacyBadge(
            app: app,
            fallback: const Text('PRIVATE'),
          ),
        ),
      );
      await settle(tester, service);
      const badge = ValueKey('credential_visibility_vault_badge');
      expect(service.adminVisible, isFalse);
      expect(find.text('PRIVATE'), findsNothing);
      expect(find.byKey(badge), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential_visibility_indicator')),
        findsNothing,
        reason: 'the account itself is private',
      );

      // Switching to a private Vault restores the pill without a rebuild
      // from the parent.
      app.activeVault = vault(adminVisible: false);
      app.emitChange();
      await tester.pump();
      expect(find.text('PRIVATE'), findsOneWidget);
      expect(find.byKey(badge), findsNothing);

      // The switcher marks admin-visible Vaults in its plain-text menu.
      final l10n = currentL10n;
      expect(
        credentialVisibilityVaultMenuLabel(
          l10n,
          vault(adminVisible: true),
          'Vault: Ops',
        ),
        'Vault: Ops · ${l10n.cvModeAdminVisibleShort}',
      );
      expect(
        credentialVisibilityVaultMenuLabel(
          l10n,
          vault(adminVisible: false),
          'Vault: Ops',
        ),
        'Vault: Ops',
      );
      service.dispose();
      app.dispose();
    });

    testWidgets('is absent without server support', (tester) async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(mode: 'admin_visible'),
      );
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
        capability: false,
      );
      await tester.pumpWidget(
        _host(
          CredentialVisibilityPrivacyBadge(
            app: app,
            fallback: const Text('PRIVATE'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('PRIVATE'), findsOneWidget);
      expect(server.requests, isEmpty);
      app.dispose();
    });
  });

  group('one-time notice', () {
    Future<void> pumpNotice(WidgetTester tester, AppController app) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(body: CredentialVisibilityNoticeHost(app: app)),
          ),
        );

    testWidgets('admin-visible first sign-in: modal, acknowledge once', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(
          mode: 'admin_visible',
          escrowStatus: 'no_key',
          changedAt: '2026-11-13T09:00:00Z',
        ),
      );
      final (app, service, store) = bind(server);
      await pumpNotice(tester, app);
      await settle(tester, service);
      await tester.pumpAndSettle();
      final l10n = currentL10n;
      expect(
        find.byKey(const ValueKey('credential_visibility_notice_adminVisible')),
        findsOneWidget,
      );
      expect(find.text(l10n.cvNoticeAdminVisibleTitle), findsOneWidget);
      expect(find.text(l10n.cvModeAdminVisibleBody), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_notice_ack')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CredentialVisibilityNoticeDialog), findsNothing);
      expect(store.writes, 1);
      expect(service.pendingNotice, isNull);
      // A refresh with the same mode/changed_at does not show it again.
      await service.refresh();
      await settle(tester, service);
      await tester.pumpAndSettle();
      expect(find.byType(CredentialVisibilityNoticeDialog), findsNothing);

      // The admin switches the account back to private.
      server.status = cvStatus(
        mode: 'private',
        changedAt: '2026-11-13T14:00:00Z',
      );
      await service.refresh();
      await settle(tester, service);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('credential_visibility_notice_switchedToPrivate'),
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.cvNoticeSwitchedPrivateTitle), findsOneWidget);
      expect(find.text(l10n.cvNoticeSwitchedPrivateBody), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_notice_ack')),
      );
      await tester.pumpAndSettle();
      expect(store.writes, 2);
      service.dispose();
      app.dispose();
    });

    testWidgets('only the buttons acknowledge; back or route removal do not', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(
        cvStatus(
          mode: 'admin_visible',
          escrowStatus: 'no_key',
          changedAt: '2026-11-13T09:00:00Z',
        ),
      );
      final (app, service, store) = bind(server);
      await pumpNotice(tester, app);
      await settle(tester, service);
      await tester.pumpAndSettle();
      final dialog = find.byType(CredentialVisibilityNoticeDialog);
      expect(dialog, findsOneWidget);

      // Android system back (gesture or button) does not dismiss it.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(store.writes, 0);

      // Removed without a button (e.g. by another route change): not
      // acknowledged, so the notice comes back.
      Navigator.of(tester.element(dialog)).pop();
      await tester.pumpAndSettle();
      expect(store.writes, 0);
      expect(service.pendingNotice, CredentialVisibilityNotice.adminVisible);
      expect(dialog, findsOneWidget, reason: 'shown again');

      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_notice_ack')),
      );
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(store.writes, 1);
      expect(service.pendingNotice, isNull);
      service.dispose();
      app.dispose();
    });

    testWidgets('private first sign-in and switched-to-admin-visible texts', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final (app, service, store) = bind(server);
      await pumpNotice(tester, app);
      await settle(tester, service);
      await tester.pumpAndSettle();
      final l10n = currentL10n;
      expect(
        find.byKey(const ValueKey('credential_visibility_notice_private')),
        findsOneWidget,
      );
      expect(find.text(l10n.cvNoticePrivateTitle), findsOneWidget);
      // "View details" acknowledges and opens the details dialog.
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_notice_details')),
      );
      await tester.pumpAndSettle();
      expect(store.writes, 1);
      expect(
        find.byKey(const ValueKey('credential_visibility_section')),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n.close));
      await tester.pumpAndSettle();

      server.status = cvStatus(
        mode: 'admin_visible',
        escrowStatus: 'no_key',
        changedAt: '2026-11-13T15:00:00Z',
      );
      await service.refresh();
      await settle(tester, service);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('credential_visibility_notice_switchedToAdminVisible'),
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.cvNoticeSwitchedAdminVisibleTitle), findsOneWidget);
      expect(find.text(l10n.cvNoticeAdminVisibleDeposit), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_notice_ack')),
      );
      await tester.pumpAndSettle();
      service.dispose();
      app.dispose();
    });
  });

  group('registration and vault notices', () {
    InstanceInfo info({String? defaultMode, bool capability = true}) =>
        InstanceInfo(
          instanceId: escrowInstanceId,
          serverSpaceId: escrowServerSpaceId,
          generation: '1',
          protocolVersion: 1,
          setupRequired: false,
          capabilities: [if (capability) 'credential_visibility'],
          credentialVisibilityDefault: defaultMode,
        );

    testWidgets('registration notice only for an admin-visible default', (
      tester,
    ) async {
      const key = ValueKey('credential_visibility_registration_notice');
      await tester.pumpWidget(
        _host(
          CredentialVisibilityRegistrationNotice(
            instance: info(defaultMode: 'admin_visible'),
          ),
        ),
      );
      expect(find.byKey(key), findsOneWidget);
      expect(find.text(currentL10n.cvRegistrationNoticeBody), findsOneWidget);
      await tester.pumpWidget(
        _host(
          CredentialVisibilityRegistrationNotice(
            instance: info(defaultMode: 'private'),
          ),
        ),
      );
      expect(find.byKey(key), findsNothing);
      await tester.pumpWidget(
        _host(
          CredentialVisibilityRegistrationNotice(
            instance: info(defaultMode: 'admin_visible', capability: false),
          ),
        ),
      );
      expect(find.byKey(key), findsNothing);
      await tester.pumpWidget(
        _host(const CredentialVisibilityRegistrationNotice(instance: null)),
      );
      expect(find.byKey(key), findsNothing);
    });

    testWidgets('shared-vault notice follows the server admin_visible flag', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      const notice = ValueKey('credential_visibility_shared_vault_notice');
      Future<void> pump() => tester.pumpWidget(
        _host(
          Column(
            children: [
              CredentialVisibilitySharedVaultNotice(
                app: app,
                vaultId: escrowVaultId,
              ),
              if (app.activeVault?.adminVisible ?? false)
                const CredentialVisibilityVaultBadge(),
            ],
          ),
        ),
      );
      await pump();
      expect(find.byKey(notice), findsNothing, reason: 'unknown vault');
      app.activeVault = VaultDescriptor.fromJson({
        'vault_id': escrowVaultId,
        'role': 'owner',
        'admin_visible': false,
      });
      await pump();
      expect(find.byKey(notice), findsNothing);
      app.activeVault = VaultDescriptor.fromJson({
        'vault_id': escrowVaultId,
        'role': 'owner',
        'admin_visible': true,
      });
      await pump();
      expect(find.byKey(notice), findsOneWidget);
      expect(find.text(currentL10n.cvSharedVaultNotice), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential_visibility_vault_badge')),
        findsOneWidget,
      );
      expect(find.text(currentL10n.cvModeAdminVisibleShort), findsOneWidget);
      app.dispose();
    });

    testWidgets('shared-vault notice asks the server, not the cached list', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      bool? serverFlag;
      var vaultReads = 0;
      server.onOtherRequest = (http.Request request) async {
        if (request.method != 'GET' || request.url.path != '/api/v1/vaults') {
          throw StateError('unexpected ${request.method} ${request.url}');
        }
        vaultReads++;
        if (serverFlag == null) {
          return FakeCredentialVisibilityServer.json({
            'error': {
              'code': 'INTERNAL',
              'message': 'unavailable',
              'request_id': 'r',
            },
          }, 503);
        }
        return FakeCredentialVisibilityServer.json({
          'vaults': [
            {
              'vault_id': escrowVaultId,
              'role': 'owner',
              'admin_visible': serverFlag,
            },
          ],
        });
      };
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      const notice = ValueKey('credential_visibility_shared_vault_notice');
      void cache(bool adminVisible) =>
          app.activeVault = VaultDescriptor.fromJson({
            'vault_id': escrowVaultId,
            'role': 'owner',
            'admin_visible': adminVisible,
          });
      var opened = 0;
      // Each share flow opens a new notice, as each dialog does.
      Future<void> open() async {
        opened++;
        await tester.pumpWidget(
          _host(
            CredentialVisibilitySharedVaultNotice(
              key: ValueKey(opened),
              app: app,
              vaultId: escrowVaultId,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      // Another member became admin-visible after this list was loaded.
      cache(false);
      serverFlag = true;
      await open();
      expect(find.byKey(notice), findsOneWidget);
      expect(vaultReads, 1);

      // That member is private again: the stale cached flag is not shown.
      cache(true);
      serverFlag = false;
      await open();
      expect(find.byKey(notice), findsNothing);

      // The server cannot answer: the cached flag stays in effect.
      serverFlag = null;
      await open();
      expect(find.byKey(notice), findsOneWidget);
      expect(vaultReads, 3);

      // Without the capability nothing is fetched.
      final plain = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
        capability: false,
      );
      await tester.pumpWidget(
        _host(
          CredentialVisibilitySharedVaultNotice(
            app: plain,
            vaultId: escrowVaultId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(vaultReads, 3);
      plain.dispose();
      app.dispose();
    });
  });

  group('admin controls', () {
    AdminAccountMetadata account(
      String mode, {
      String escrow = 'not_required',
    }) => AdminAccountMetadata.fromJson({
      'user_id': escrowUserId,
      'username': 'alice@example.test',
      'status': 'active',
      'created_at': '2026-11-01T00:00:00Z',
      'active_device_count': 1,
      'active_session_count': 1,
      'credential_visibility': mode,
      'escrow_status': escrow,
    });

    testWidgets('per-account selector confirms and sends the new mode', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final puts = <Map<String, dynamic>>[];
      server.onOtherRequest = (http.Request request) async {
        final path = request.url.path;
        if (request.method == 'PUT' &&
            path ==
                '/api/v1/admin/accounts/$escrowUserId/credential-visibility') {
          puts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return FakeCredentialVisibilityServer.json({
            'user_id': escrowUserId,
            'mode': 'admin_visible',
            'changed_at': '2026-11-13T12:00:00Z',
            'escrow_status': 'pending',
          });
        }
        if (request.method == 'GET' && path == '/api/v1/admin/accounts') {
          return FakeCredentialVisibilityServer.json({
            'accounts': [
              {
                'user_id': escrowUserId,
                'username': 'alice@example.test',
                'status': 'active',
                'created_at': '2026-11-01T00:00:00Z',
                'active_device_count': 1,
                'active_session_count': 1,
                'credential_visibility': 'admin_visible',
                'escrow_status': 'pending',
              },
            ],
            'total': 1,
            'limit': 50,
            'offset': 0,
          });
        }
        throw StateError('unexpected ${request.method} $path');
      };
      final (app, service, _) = bind(server, admin: true);
      await tester.pumpWidget(
        _host(
          CredentialVisibilityAdminAccountRow(
            app: app,
            account: account('private'),
          ),
        ),
      );
      final l10n = currentL10n;
      expect(find.text(l10n.cvModePrivateShort), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('credential_visibility_admin_escrow_$escrowUserId'),
        ),
        findsOneWidget,
      );
      // Private accounts have no "View credentials".
      expect(
        find.byKey(
          const ValueKey('credential_visibility_admin_view_$escrowUserId'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('credential_visibility_admin_mode_$escrowUserId'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cvModeAdminVisibleShort).last);
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.cvAdminConfirmAdminVisibleTitle('alice@example.test')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_admin_mode_confirm')),
      );
      await tester.pumpAndSettle();
      expect(puts, [
        {'mode': 'admin_visible'},
      ]);
      expect(
        app.adminAccountsPage?.accounts.single.credentialVisibility,
        'admin_visible',
      );

      // An admin-visible row offers "View credentials".
      await tester.pumpWidget(
        _host(
          CredentialVisibilityAdminAccountRow(
            app: app,
            account: account('admin_visible', escrow: 'complete'),
          ),
        ),
      );
      expect(
        find.byKey(
          const ValueKey('credential_visibility_admin_view_$escrowUserId'),
        ),
        findsOneWidget,
      );
      service.dispose();
      app.dispose();
    });

    testWidgets('rows stay hidden without capability or admin policy', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final (app, service, _) = bind(server);
      await tester.pumpWidget(
        _host(
          CredentialVisibilityAdminAccountRow(
            app: app,
            account: account('private'),
          ),
        ),
      );
      expect(
        find.byKey(
          const ValueKey('credential_visibility_admin_row_$escrowUserId'),
        ),
        findsNothing,
      );
      service.dispose();
      app.dispose();
    });

    testWidgets('invitation selector defaults to the instance default', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final (app, service, _) = bind(server, admin: true);
      CredentialVisibilityMode? chosen;
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => CredentialVisibilityInvitationField(
              app: app,
              value: chosen,
              onChanged: (value) => setState(() => chosen = value),
            ),
          ),
        ),
      );
      final l10n = currentL10n;
      expect(find.text(l10n.cvInstanceDefaultOption), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey('admin_account_invitation_credential_visibility'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cvModeAdminVisibleShort).last);
      await tester.pumpAndSettle();
      expect(chosen, CredentialVisibilityMode.adminVisible);
      service.dispose();
      app.dispose();
    });

    testWidgets('admin card loads the default, counts and key state', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      var defaultMode = 'private';
      final escrow = sodium.crypto.box.keyPair();
      Object? key;
      server.onOtherRequest = (http.Request request) async {
        if (request.url.path != '/api/v1/admin/credential-visibility') {
          throw StateError('unexpected ${request.url}');
        }
        if (request.method == 'PUT') {
          defaultMode =
              (jsonDecode(request.body) as Map)['default_mode'] as String;
        }
        return FakeCredentialVisibilityServer.json({
          'default_mode': defaultMode,
          'escrow_key': key,
          'caller_wrap': null,
          'recovery_wrap': key == null
              ? null
              : {
                  'version': 1,
                  'kdf': {
                    'id': 'argon2id13',
                    'salt': 'AAAAAAAAAAAAAAAAAAAAAA',
                    'mem_kib': 65536,
                    'iterations': 3,
                    'parallelism': 1,
                  },
                  'nonce': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                  'ciphertext': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                },
          'counts': {'admin_visible': 1, 'private': 3, 'pending': 1},
        });
      };
      final (app, service, _) = bind(server, admin: true);
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_host(CredentialVisibilityAdminCard(app: app)));
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_admin_load')),
      );
      await tester.pumpAndSettle();
      final l10n = currentL10n;
      expect(find.text(l10n.cvAdminCounts(1, 3, 1)), findsOneWidget);
      expect(find.text(l10n.cvAdminKeyMissing), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_create_key')),
        findsOneWidget,
      );

      // Change the instance default.
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_admin_default')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cvModeAdminVisibleShort).last);
      await tester.pumpAndSettle();
      expect(defaultMode, 'admin_visible');

      // A key signed by this instance without a wrap for this admin.
      key = instance.descriptor(
        keyId: escrowKeyId,
        publicKey: escrow.publicKey,
      );
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_admin_load')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_no_wrap')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_unlock')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_reset')),
        findsOneWidget,
      );

      // A key the pinned instance key did not sign is flagged.
      key = EscrowTestInstance(sodium)
          .descriptor(keyId: escrowKeyId, publicKey: escrow.publicKey);
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_admin_load')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_key_invalid')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_unlock')),
        findsNothing,
      );

      // Reset requires typing the confirmation word.
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_admin_reset')),
      );
      await tester.pumpAndSettle();
      final confirm = find.byKey(
        const ValueKey('credential_escrow_reset_confirm'),
      );
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('credential_escrow_reset_confirm_input')),
        'reset',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      escrow.dispose();
      service.dispose();
      app.dispose();
    });
  });

  // Security review follow-ups (2026-11-14).
  group('review follow-ups', () {
    const recipientDevice = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    const recipientPath =
        '/api/v1/credential-visibility/vaults/$escrowVaultId/recipients/'
        '$recipientDevice';

    testWidgets('private mode names the shared admin-visible Vault exception', (
      tester,
    ) async {
      final l10n = currentL10n;
      await tester.pumpWidget(
        _host(
          const CredentialVisibilityStatusView(
            mode: CredentialVisibilityMode.private,
            changedAt: null,
            status: null,
            sharedAdminVisibleVaults: true,
          ),
        ),
      );
      expect(find.text(l10n.cvModePrivateBodySharedException), findsOneWidget);
      expect(find.text(l10n.cvModePrivateBody), findsNothing);
      expect(
        find.byKey(
          const ValueKey('credential_visibility_private_shared_exception'),
        ),
        findsOneWidget,
      );
      // The admin-visible text never changes.
      await tester.pumpWidget(
        _host(
          const CredentialVisibilityStatusView(
            mode: CredentialVisibilityMode.adminVisible,
            changedAt: null,
            status: null,
            sharedAdminVisibleVaults: true,
          ),
        ),
      );
      expect(find.text(l10n.cvModeAdminVisibleBody), findsOneWidget);
      expect(find.text(l10n.cvModePrivateBodySharedException), findsNothing);
      // Both private notices use the qualified text too.
      for (final notice in [
        CredentialVisibilityNotice.private,
        CredentialVisibilityNotice.switchedToPrivate,
      ]) {
        await tester.pumpWidget(
          _host(
            CredentialVisibilityNoticeDialog(
              notice: notice,
              sharedAdminVisibleVaults: true,
            ),
          ),
        );
        expect(
          find.text(l10n.cvModePrivateBodySharedException),
          findsOneWidget,
          reason: notice.name,
        );
        expect(find.text(l10n.cvModePrivateBody), findsNothing);
      }
      await tester.pumpWidget(
        _host(
          const CredentialVisibilityNoticeDialog(
            notice: CredentialVisibilityNotice.private,
          ),
        ),
      );
      expect(find.text(l10n.cvModePrivateBody), findsOneWidget);
    });

    testWidgets('a status with admin-visible Vaults qualifies private mode and '
        'refreshes stale Vault badges', (tester) async {
      final server = FakeCredentialVisibilityServer({
        ...cvStatus(mode: 'private'),
        'admin_visible_vaults': 1,
      });
      var vaultReads = 0;
      server.onOtherRequest = (http.Request request) async {
        if (request.method != 'GET' || request.url.path != '/api/v1/vaults') {
          throw StateError('unexpected ${request.method} ${request.url}');
        }
        vaultReads++;
        return FakeCredentialVisibilityServer.json({
          'vaults': [
            {'vault_id': escrowVaultId, 'role': 'owner', 'admin_visible': true},
          ],
        });
      };
      final (app, service, _) = bind(server);
      // The cached descriptor predates the share that made it visible.
      app.activeVault = VaultDescriptor.fromJson({
        'vault_id': escrowVaultId,
        'role': 'owner',
        'admin_visible': false,
      });
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              CredentialVisibilityPrivacyBadge(
                app: app,
                fallback: const Text('PRIVATE'),
              ),
              CredentialVisibilitySettingsCard(app: app),
            ],
          ),
        ),
      );
      await settle(tester, service);
      await tester.pump();
      expect(service.status!.adminVisibleVaults, 1);
      expect(vaultReads, 1);
      expect(app.activeVault!.adminVisible, isTrue);
      expect(find.text('PRIVATE'), findsNothing);
      expect(
        find.byKey(const ValueKey('credential_visibility_vault_badge')),
        findsOneWidget,
      );
      expect(service.privateWithAdminVisibleVaults, isTrue);
      expect(
        find.text(currentL10n.cvModePrivateBodySharedException),
        findsOneWidget,
      );
      expect(find.text(currentL10n.cvModePrivateBody), findsNothing);
      service.dispose();
      app.dispose();
    });

    testWidgets('a status without the count fetches no Vault list', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final (app, service, _) = bind(server);
      await tester.pumpWidget(
        _host(CredentialVisibilitySettingsCard(app: app)),
      );
      await settle(tester, service);
      expect(service.status!.adminVisibleVaults, isNull);
      expect(
        server.requests.where(
          (request) => request.url.path == '/api/v1/vaults',
        ),
        isEmpty,
      );
      expect(service.privateWithAdminVisibleVaults, isFalse);
      expect(find.text(currentL10n.cvModePrivateBody), findsOneWidget);
      service.dispose();
      app.dispose();
    });

    Future<({List<bool> reports, StateSetter rebuild})> pumpGate(
      WidgetTester tester,
      AppController app,
    ) async {
      final reports = <bool>[];
      late StateSetter rebuild;
      var allowed = !credentialVisibilityShareCheckRequired(app);
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Column(
                children: [
                  CredentialVisibilityShareRecipientGate(
                    app: app,
                    vaultId: escrowVaultId,
                    recipientDeviceId: recipientDevice,
                    recipientName: 'ops@example.test',
                    onChanged: (value) => setState(() {
                      allowed = value;
                      reports.add(value);
                    }),
                  ),
                  FilledButton(
                    key: const ValueKey('sign'),
                    onPressed: allowed ? () {} : null,
                    child: const Text('Sign'),
                  ),
                ],
              );
            },
          ),
        ),
      );
      return (reports: reports, rebuild: rebuild);
    }

    bool signEnabled(WidgetTester tester) =>
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('sign')))
            .onPressed !=
        null;

    testWidgets('sharing with an admin-visible recipient needs explicit '
        'confirmation; a private one does not', (tester) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      Map<String, Object?>? answer = {
        'recipient_admin_visible': true,
        'vault_admin_visible': false,
      };
      var checks = 0;
      server.onOtherRequest = (http.Request request) async {
        if (request.method != 'GET' || request.url.path != recipientPath) {
          throw StateError('unexpected ${request.method} ${request.url}');
        }
        checks++;
        final body = answer;
        if (body == null) {
          return FakeCredentialVisibilityServer.json({
            'error': {
              'code': 'INTERNAL',
              'message': 'unavailable',
              'request_id': 'r',
            },
          }, 503);
        }
        return FakeCredentialVisibilityServer.json(body);
      };
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
      );
      final l10n = currentL10n;
      var gate = await pumpGate(tester, app);
      // Blocked while checking.
      expect(signEnabled(tester), isFalse);
      expect(
        find.byKey(const ValueKey('credential_visibility_share_checking')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(checks, 1);
      expect(
        find.byKey(
          const ValueKey('credential_visibility_share_recipient_admin_visible'),
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.cvShareRecipientAdminVisibleTitle), findsOneWidget);
      expect(
        find.text(l10n.cvShareRecipientAdminVisibleBody('ops@example.test')),
        findsOneWidget,
      );
      expect(signEnabled(tester), isFalse, reason: 'not confirmed yet');
      final confirm = find.byKey(
        const ValueKey('credential_visibility_share_confirm'),
      );
      await tester.tap(confirm);
      await tester.pump();
      expect(signEnabled(tester), isTrue);
      await tester.tap(confirm);
      await tester.pump();
      expect(signEnabled(tester), isFalse, reason: 'consent withdrawn');
      expect(gate.reports, [false, true, false]);

      // A private recipient: nothing to confirm.
      answer = {'recipient_admin_visible': false, 'vault_admin_visible': true};
      await tester.pumpWidget(const SizedBox.shrink());
      gate = await pumpGate(tester, app);
      await tester.pumpAndSettle();
      expect(signEnabled(tester), isTrue);
      expect(confirm, findsNothing);
      expect(gate.reports, [true]);

      // The check fails: treated like an admin-visible recipient.
      answer = null;
      await tester.pumpWidget(const SizedBox.shrink());
      gate = await pumpGate(tester, app);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('credential_visibility_share_check_failed')),
        findsOneWidget,
      );
      expect(find.text(l10n.cvShareRecipientCheckFailed), findsOneWidget);
      expect(signEnabled(tester), isFalse);
      // Retrying after the server recovers clears it.
      answer = {'recipient_admin_visible': false, 'vault_admin_visible': false};
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_share_check_retry')),
      );
      await tester.pumpAndSettle();
      expect(signEnabled(tester), isTrue);
      expect(gate.reports, [false, false, true]);
      expect(checks, 4);
      app.dispose();
    });

    testWidgets('servers without the capability are not asked', (tester) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      final app = cvApp(
        sodium,
        server.api,
        pinnedKey: instance.signingPublicKey,
        capability: false,
      );
      expect(credentialVisibilityShareCheckRequired(app), isFalse);
      await pumpGate(tester, app);
      expect(signEnabled(tester), isTrue);
      await tester.pumpAndSettle();
      expect(signEnabled(tester), isTrue);
      expect(server.requests, isEmpty);
      app.dispose();
    });

    testWidgets('delivering a key to an admin-visible grantee asks first', (
      tester,
    ) async {
      final l10n = currentL10n;
      bool? result;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Column(
              children: [
                const CredentialVisibilityGranteeWarning(
                  recipientName: 'ops@example.test',
                ),
                TextButton(
                  onPressed: () async =>
                      result = await confirmCredentialVisibilityRecipient(
                        context,
                        recipientName: 'ops@example.test',
                      ),
                  child: const Text('Deliver'),
                ),
              ],
            ),
          ),
        ),
      );
      final body = l10n.cvShareRecipientAdminVisibleBody('ops@example.test');
      expect(find.text(body), findsOneWidget);
      for (final (button, expected) in [
        ('credential_visibility_share_cancel', false),
        ('credential_visibility_share_anyway', true),
      ]) {
        result = null;
        await tester.tap(find.text('Deliver'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const ValueKey('credential_visibility_share_confirm_dialog'),
          ),
          findsOneWidget,
        );
        expect(find.text(body), findsNWidgets(2));
        await tester.tap(find.byKey(ValueKey(button)));
        await tester.pumpAndSettle();
        expect(result, expected, reason: button);
      }
    });

    testWidgets('database encryption status: warning, quiet line or nothing', (
      tester,
    ) async {
      final l10n = currentL10n;
      const warning = ValueKey('database_encryption_disabled_warning');
      const enabled = ValueKey('database_encryption_enabled');
      await tester.pumpWidget(
        _host(const DatabaseEncryptionStatus(databaseEncryption: 'disabled')),
      );
      expect(find.byKey(warning), findsOneWidget);
      expect(find.text(l10n.cvDatabaseNotEncryptedTitle), findsOneWidget);
      expect(find.text(databaseEncryptCommand), findsOneWidget);
      expect(
        find.text(
          l10n.cvDatabaseEncryptionGuide(databaseEncryptionRunbookPath),
        ),
        findsOneWidget,
      );
      expect(find.byKey(enabled), findsNothing);
      await tester.pumpWidget(
        _host(const DatabaseEncryptionStatus(databaseEncryption: 'enabled')),
      );
      expect(find.byKey(enabled), findsOneWidget);
      expect(find.text(l10n.cvDatabaseEncryptedAtRest), findsOneWidget);
      expect(find.byKey(warning), findsNothing);
      for (final value in [null, 'unknown']) {
        await tester.pumpWidget(
          _host(DatabaseEncryptionStatus(databaseEncryption: value)),
        );
        expect(find.byKey(warning), findsNothing);
        expect(find.byKey(enabled), findsNothing);
      }
    });

    testWidgets('escrow admin card warns about a plaintext database', (
      tester,
    ) async {
      final server = FakeCredentialVisibilityServer(cvStatus(mode: 'private'));
      String? databaseEncryption = 'disabled';
      server.onOtherRequest = (http.Request request) async {
        switch (request.url.path) {
          case '/api/v1/admin/credential-visibility':
            return FakeCredentialVisibilityServer.json({
              'default_mode': 'private',
              'escrow_key': null,
              'caller_wrap': null,
              'recovery_wrap': null,
              'counts': {'admin_visible': 0, 'private': 1, 'pending': 0},
            });
          case '/api/v1/admin/overview':
            return FakeCredentialVisibilityServer.json({
              'instance': {
                'instance_id': escrowInstanceId,
                'server_space_id': escrowServerSpaceId,
                'generation': '1',
                'protocol_version': 1,
              },
              'counts': {
                for (final key in [
                  'accounts_total',
                  'accounts_active',
                  'accounts_disabled',
                  'accounts_deleting',
                  'devices_active',
                  'vaults_active',
                  'vaults_deleting',
                  'stored_bytes',
                  'reserved_upload_bytes',
                  'vault_quota_bytes',
                ])
                  key: 0,
              },
              'relay': {
                'enabled': false,
                'allow_cidrs': <String>[],
                'allow_ports': <int>[],
                'max_connections_per_user': 1,
              },
              'generated_at': '2026-11-14T10:00:00Z',
              'database_encryption': ?databaseEncryption,
            });
        }
        throw StateError('unexpected ${request.url}');
      };
      final (app, service, _) = bind(server, admin: true);
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_host(CredentialVisibilityAdminCard(app: app)));
      const warning = ValueKey('database_encryption_disabled_warning');
      const enabled = ValueKey('database_encryption_enabled');
      Future<void> load() async {
        await tester.tap(
          find.byKey(const ValueKey('credential_visibility_admin_load')),
        );
        await tester.pumpAndSettle();
      }

      await load();
      expect(find.byKey(warning), findsOneWidget);
      expect(
        find.byKey(const ValueKey('credential_visibility_admin_create_key')),
        findsOneWidget,
      );
      databaseEncryption = 'enabled';
      await load();
      expect(find.byKey(warning), findsNothing);
      expect(find.byKey(enabled), findsOneWidget);
      databaseEncryption = null;
      await load();
      expect(find.byKey(warning), findsNothing);
      expect(find.byKey(enabled), findsNothing);
      service.dispose();
      app.dispose();
    });
  });
}
