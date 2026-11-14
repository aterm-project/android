// Owner UI driven end to end: the real Share dialog and Organizations page on
// the REAL AppController against the REAL server binary, plus narrow layouts
// in all four languages. Requires ATERMIUS_TEST_SERVER_BINARY (see
// support/cloud_real_server.dart); reports itself as skipped otherwise.
import 'dart:io';

import 'package:aterm_client/cloud/cloud_access_service.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_api.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_models.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/cloud_access/organizations_page.dart';
import 'package:aterm_client/ui/cloud_access/share_host_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

Widget _host(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  theme: buildAppTheme(locale: locale),
  home: Scaffold(body: child),
);

/// Lets real network I/O progress while advancing fake time, until [done].
Future<void> _until(
  WidgetTester tester,
  bool Function() done, {
  int rounds = 300,
  String what = 'condition',
}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done()) {
    final texts = find
        .byType(Text, skipOffstage: false)
        .evaluate()
        .map(
          (e) =>
              (e.widget as Text).data ??
              (e.widget as Text).textSpan?.toPlainText(),
        )
        .join(' | ');
    fail('$what not reached; visible text: $texts');
  }
}

/// Runs [action] on the real event loop while pumping the fake zone, for
/// controller operations that may join work the UI started in the fake zone.
Future<T> _realPumped<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  int rounds = 600,
}) async {
  var done = false;
  T? value;
  Object? error;
  StackTrace? trace;
  await tester.runAsync(() async {
    action().then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e, StackTrace st) {
        error = e;
        trace = st;
        done = true;
      },
    );
  });
  await _until(tester, () => done, rounds: rounds, what: 'real operation');
  if (error != null) Error.throwWithStackTrace(error!, trace!);
  return value as T;
}

/// The controller outlives the widget tree; requests it started in the
/// test's fake zone carry fake-time timeouts. Unmount, let real I/O finish,
/// then advance fake time past those timeouts.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(seconds: 2));
  }
}

Future<T> _real<T>(WidgetTester tester, Future<T> Function() action) async =>
    (await tester.runAsync(action)) as T;

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    testWidgets('owner widgets on a real server', (_) async {}, skip: true);
    return;
  }
  late SodiumSumo sodium;
  late TestServer server;
  late Party owner;
  late Party recipient;
  late HostRecord h1;
  late HostRecord h2;
  late HostRecord rdp;
  late String sourceVaultId;
  late String orgId;

  setUpAll(() async {
    // flutter_test mocks HttpClient for widget tests; these tests talk to a
    // real local server on purpose.
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
    // The owner is also the instance administrator, so it can make a grantee
    // admin_visible (credential visibility).
    server = await TestServer.start(
      extraEnv: const {'ATERMIUS_ADMIN_USERNAMES': 'owner@example.test'},
    );
    owner = await party(
      sodium,
      server.baseUrl,
      username: 'owner@example.test',
      bootstrap: server.bootstrapToken(),
    );
    recipient = await party(
      sodium,
      server.baseUrl,
      username: 'recipient@example.test',
      invitation: server.accountInvitation('recipient@example.test'),
      storagePrefix: 'recipient.',
    );
    sourceVaultId = owner.app.activeVault!.id;
    h1 = testHost('H1');
    h2 = testHost('H2-private');
    // Pinned certificate: shareable through links without a prior SSH trust.
    rdp = testHost('R-desktop', protocol: HostProtocol.rdp, cert: 'ab' * 32);
    await owner.app.saveHost(h1);
    await owner.app.saveHost(h2);
    await owner.app.saveHost(rdp);
    orgId =
        (await owner.service.api.createOrg('Widget org'))['org_id'] as String;
    await owner.app.synchronize();
    await idle(owner.app);
  });

  tearDownAll(() async {
    await server.stop();
  });

  testWidgets(
    'Share… members flow: H1-only sharing Vault, delivery and signed role change via the UI',
    (tester) async {
      tester.view.physicalSize = const Size(560, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final host = owner.app.hosts.firstWhere((h) => h.id == h1.id);
      final before = owner.app.vaults.map((v) => v.id).toSet();
      await _real(tester, () async {
        final invite = await owner.service.api.createInvitation(
          orgId,
          role: 'member',
          username: 'recipient@example.test',
        );
        await recipient.service.api.acceptInvitation(invite['token'] as String);
        await recipient.service.publishDeviceCard();
      });

      await tester.pumpWidget(
        _host(CloudShareHostPanel(app: owner.app, host: host)),
      );
      await tester.pump();
      await tester.tap(find.text(l10n.cloudAccessTabMembers));
      await tester.pump();
      // Consent is required before the copy.
      final create = find.widgetWithText(
        FilledButton,
        l10n.cloudAccessCreateSharingVault,
      );
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.tap(find.text(l10n.cloudAccessConsentCopy));
      await tester.pump();
      await tester.tap(create);
      await _until(
        tester,
        () => find.text(l10n.cloudAccessAttachOrg).evaluate().isNotEmpty,
      );
      final created = owner.app.vaults
          .map((v) => v.id)
          .toSet()
          .difference(before)
          .single;
      expect(owner.app.activeVault?.id, sourceVaultId);

      // Attach the organization and grant the recipient through the UI.
      await tester.tap(
        find.widgetWithText(TextButton, l10n.cloudAccessAttach).first,
      );
      await _until(
        tester,
        () => find.byTooltip(l10n.cloudAccessAddGrant).evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip(l10n.cloudAccessAddGrant));
      await tester.pumpAndSettle();
      await tester.tap(find.text('recipient@example.test').last);
      await _until(
        tester,
        () => find.text(l10n.cloudAccessDeliverKey).evaluate().isNotEmpty,
      );
      // Fingerprint confirmation dialog, then delivery.
      await tester.tap(
        find.widgetWithText(TextButton, l10n.cloudAccessDeliverKey),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.cloudAccessConfirmFingerprintTitle),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(FilledButton, l10n.cloudAccessDeliverKey),
      );
      await _until(
        tester,
        () => find
            .text(l10n.cloudAccessWaitingForRecipient)
            .evaluate()
            .isNotEmpty,
      );
      expect(owner.app.activeVault?.id, sourceVaultId);
      final recipientHosts = await _real(tester, () async {
        expect(await recipient.service.acceptDeliveries(), 1);
        return hostsIn(recipient.app, created);
      });
      expect(recipientHosts.map((h) => h.name), [
        'H1',
      ], reason: 'only H1 reaches the recipient');

      // Raise the desired grant to editor in the UI; the owner then applies
      // the signed role change through the explicit "Make Editor" action.
      final panel = find.byType(VaultGrantsPanel);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.tap(
        find
            .descendant(
              of: panel,
              matching: find.byType(DropdownButton<String>),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.cloudAccessRoleEditor).last);
      final apply = find.text(
        l10n.cloudAccessApplyRole(l10n.cloudAccessRoleEditor),
      );
      await _until(tester, () => apply.evaluate().isNotEmpty);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(find.text(l10n.cloudAccessApplyRoleTitle), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(
            FilledButton,
            l10n.cloudAccessApplyRole(l10n.cloudAccessRoleEditor),
          ),
        ),
      );
      await _until(tester, () => apply.evaluate().isEmpty, rounds: 600);
      final role = await _real(tester, () async {
        final members = await owner.app.api!.vaultMembers(created);
        return members.firstWhere(
          (m) => m['user_id'] == recipient.app.account!.accountId,
        )['role'];
      });
      expect(role, 'editor');
      expect(owner.app.activeVault?.id, sourceVaultId);
      expect(orgId, isNotEmpty);

      // Back to viewer through the same signed service operation. Running it
      // outside the fake zone also re-homes the controller's periodic sync and
      // presence timers that the UI-driven rotation (re)started in it.
      await tester.pumpWidget(const SizedBox());
      final back = await _realPumped(tester, () async {
        await owner.service.changeMemberRole(
          vaultId: created,
          userId: recipient.app.account!.accountId,
          role: 'viewer',
        );
        final members = await owner.app.api!.vaultMembers(created);
        return members.firstWhere(
          (m) => m['user_id'] == recipient.app.account!.accountId,
        )['role'];
      });
      expect(back, 'viewer');
      expect(owner.app.activeVault?.id, sourceVaultId);
      await _drain(tester);
    },
  );

  testWidgets(
    'an admin-visible grantee is flagged and its key is delivered only after '
    'explicit consent',
    (tester) async {
      tester.view.physicalSize = const Size(560, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      const username = 'visible-grantee@example.test';
      final grantee = await _real(
        tester,
        () => party(
          sodium,
          server.baseUrl,
          username: username,
          invitation: server.accountInvitation(username),
          storagePrefix: 'visible-grantee.',
        ),
      );
      final granteeId = grantee.app.account!.accountId;
      // Delivery must not change the owner's selection, whatever it is now.
      final selected = owner.app.activeVault?.id;
      await _real(tester, () async {
        expect(owner.app.isInstanceAdmin, isTrue);
        await CredentialVisibilityApi(owner.app.api!).setAccountMode(
          userId: granteeId,
          mode: CredentialVisibilityMode.adminVisible,
        );
        final invite = await owner.service.api.createInvitation(
          orgId,
          role: 'member',
          username: username,
        );
        await grantee.service.api.acceptInvitation(invite['token'] as String);
        await grantee.service.publishDeviceCard();
        await owner.service.api.attachVault(sourceVaultId, orgId);
        final grants = await owner.service.api.grants(sourceVaultId);
        await owner.service.api.setGrant(
          sourceVaultId,
          'user',
          granteeId,
          'viewer',
          grants['grants_revision'] as int,
        );
      });

      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: VaultGrantsPanel(
              service: owner.service,
              vaultId: sourceVaultId,
            ),
          ),
        ),
      );
      final warning = find.byKey(
        ValueKey('cloud-access-admin-visible-$granteeId'),
      );
      await _until(tester, () => warning.evaluate().isNotEmpty);
      final body = l10n.cvShareRecipientAdminVisibleBody(username);
      expect(find.text(body), findsOneWidget);
      final deliver = find.widgetWithText(
        TextButton,
        l10n.cloudAccessDeliverKey,
      );
      expect(deliver, findsOneWidget);

      // Declining the warning delivers nothing and skips the fingerprint step.
      await tester.tap(deliver);
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('credential_visibility_share_confirm_dialog'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_share_cancel')),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.cloudAccessConfirmFingerprintTitle), findsNothing);
      expect(
        owner.client.sent(
          'POST',
          '/api/v1/vaults/$sourceVaultId/key-deliveries',
        ),
        isFalse,
      );

      // Explicit consent, then the usual fingerprint confirmation.
      await tester.tap(deliver);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('credential_visibility_share_anyway')),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.cloudAccessConfirmFingerprintTitle),
        findsOneWidget,
      );
      await tester.tap(
        find.widgetWithText(FilledButton, l10n.cloudAccessDeliverKey),
      );
      await _until(
        tester,
        () => find
            .text(l10n.cloudAccessWaitingForRecipient)
            .evaluate()
            .isNotEmpty,
      );
      expect(
        owner.client.sent(
          'POST',
          '/api/v1/vaults/$sourceVaultId/key-deliveries',
        ),
        isTrue,
      );
      expect(owner.app.activeVault?.id, selected);
      // The UI-driven invitation restarted the controller's sync timers in
      // the fake zone; locking and unlocking in the real zone re-homes them.
      await tester.pumpWidget(const SizedBox());
      await _realPumped(tester, () async {
        await owner.app.lock();
        await owner.app.unlockLockedWorkspace(password: realServerPassword);
        await idle(owner.app);
      });
      expect(owner.app.activeVault?.id, selected);
      await _drain(tester);
      await _real(tester, () async => grantee.app.dispose());
    },
  );

  for (final locale in const [
    Locale('en'),
    Locale('zh'),
    Locale('ja'),
    Locale('ru'),
  ]) {
    // 320 px wide: any RenderFlex overflow or other layout error is reported
    // to the test framework and fails the test.
    testWidgets('narrow owner layouts (${locale.languageCode})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l10n = await AppLocalizations.delegate.load(locale);
      final service = CloudAccessService(owner.app);
      Finder vertical() => find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first;
      Future<void> scrollTo(Finder target) async {
        for (var i = 0; i < 40 && target.evaluate().isEmpty; i++) {
          await tester.drag(vertical(), const Offset(0, -200));
          await tester.pumpAndSettle();
        }
        expect(target, findsWidgets, reason: 'not reachable by scrolling');
        await tester.ensureVisible(target.last);
        await tester.pumpAndSettle();
      }

      // Links tab, then the complete new-link form scrolled end to end.
      final host = owner.app.hosts.firstWhere((h) => h.id == rdp.id);
      await tester.pumpWidget(
        _host(
          CloudShareHostPanel(app: owner.app, host: host),
          locale: locale,
        ),
      );
      await _until(
        tester,
        () => find
            .text(l10n.cloudAccessNoLinks, skipOffstage: false)
            .evaluate()
            .isNotEmpty,
        what: 'links loaded',
      );
      expect(find.text(l10n.cloudAccessErrorCertificateRequired), findsNothing);
      await scrollTo(find.byIcon(Icons.add_link));
      await tester.tap(find.byIcon(Icons.add_link));
      await tester.pumpAndSettle();
      await scrollTo(find.text(l10n.cloudAccessCreateLink));
      expect(find.text(l10n.cloudAccessCreateLink), findsOneWidget);

      // Members tab (dedicated-Vault plan) on a fresh panel.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _host(
          CloudShareHostPanel(app: owner.app, host: host),
          locale: locale,
        ),
      );
      await tester.tap(find.text(l10n.cloudAccessTabMembers));
      await _until(
        tester,
        () => find
            .text(l10n.cloudAccessDedicatedVault, skipOffstage: false)
            .evaluate()
            .isNotEmpty,
        what: 'members plan',
      );
      await scrollTo(find.text(l10n.cloudAccessCreateSharingVault));

      // Grants and key distribution (populated when the members flow ran).
      final shared =
          owner.app.vaults
              .where((v) => v.id != sourceVaultId && v.role == 'owner')
              .firstOrNull
              ?.id ??
          sourceVaultId;
      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: VaultGrantsPanel(service: service, vaultId: shared),
          ),
          locale: locale,
        ),
      );
      await _until(
        tester,
        () =>
            find.byType(DropdownButton<String>).evaluate().isNotEmpty ||
            find.text(l10n.cloudAccessAttachOrg).evaluate().isNotEmpty,
        what: 'grants loaded',
      );

      // Organizations list and the organization detail page.
      await tester.pumpWidget(
        _host(OrganizationsPage(service: service), locale: locale),
      );
      await _until(
        tester,
        () => find.text('Widget org').evaluate().isNotEmpty,
        what: 'organizations loaded',
      );
      await scrollTo(find.text('Widget org'));
      await tester.tap(find.text('Widget org'));
      await _until(
        tester,
        () => find
            .text(l10n.cloudAccessTeams, skipOffstage: false)
            .evaluate()
            .isNotEmpty,
        what: 'organization detail',
      );
      await scrollTo(find.text(l10n.cloudAccessInvitations));
      expect(tester.takeException(), isNull);
      expect(orgId, isNotEmpty);
      await _drain(tester);
    });
  }
}
