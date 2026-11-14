// Merge regression: the approved owner controls remain reachable through the
// newer Account category and the existing Host menus, on the real controller.
import 'dart:io';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_service.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/account_settings.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/cloud_access/organizations_page.dart';
import 'package:aterm_client/ui/cloud_access/share_host_dialog.dart';
import 'package:aterm_client/ui/sync_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';
import 'support/settings_navigation.dart';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue);
}

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    testWidgets(
      'merged cloud shell hooks require real server',
      (_) async {},
      skip: true,
    );
    return;
  }
  late TestServer server;
  late Party owner;
  final host = testHost('Merged owner Host');
  setUpAll(() async {
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    final sodium = await SodiumSumoInit.init();
    server = await TestServer.start();
    owner = await party(
      sodium,
      server.baseUrl,
      username: 'merged-owner@example.test',
      bootstrap: server.bootstrapToken(),
    );
    await owner.app.saveHost(host);
    await owner.app.synchronize();
    await idle(owner.app);
    // Credential visibility v1: the first sign-in on a device shows a
    // one-time modal mode notice over the shell until it is acknowledged
    // (credential_visibility_real_server_test.dart and
    // credential_visibility_widget_test.dart cover the notice). Acknowledge
    // the owner's private-mode notice up front so the merge regression below
    // drives the Account and Host menus unobstructed.
    final visibility = credentialVisibilityFor(owner.app);
    await visibility.refresh();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (visibility.pendingNotice == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(visibility.pendingNotice, CredentialVisibilityNotice.private);
    await visibility.acknowledge();
    expect(visibility.pendingNotice, isNull);
  });
  tearDownAll(() async {
    owner.app.dispose();
    owner.client.close();
    await server.stop();
  });

  for (final (locale, width) in [
    (const Locale('en'), 1280.0),
    (const Locale('ru'), 390.0),
  ]) {
    testWidgets(
      'merged Account cloud entry and Host sharing at $width ${locale.languageCode}',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final l10n = await AppLocalizations.delegate.load(locale);
        owner.app.showWorkspacePage(WorkspacePage.settings);
        try {
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizationSetup.delegates,
              supportedLocales: AppLocalizationSetup.locales,
              theme: buildAppTheme(locale: locale),
              home: AppShell(controller: owner.app),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          // The legacy About section must not retain the moved account hook.
          if (width >= 760) {
            await openSettingsCategory(tester, 'about');
            expect(find.byType(CloudAccessAccountCard), findsNothing);
            expect(tester.takeException(), isNull);
          }
          await openSettingsCategory(tester, 'account');
          expect(find.byType(AccountSettingsPanel), findsOneWidget);
          expect(find.byType(SyncSettingsPanel), findsOneWidget);
          expect(find.byType(CloudAccessAccountCard), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const ValueKey('account_settings_sign_out')),
            findsOneWidget,
          );
          await tester.ensureVisible(find.byType(CloudAccessAccountCard));
          await tester.tap(find.byType(CloudAccessAccountCard));
          await _until(
            tester,
            () => find.byType(OrganizationsPage).evaluate().isNotEmpty,
          );
          expect(find.text(l10n.cloudAccessOrganizations), findsWidgets);
          Navigator.of(tester.element(find.byType(OrganizationsPage))).pop();
          await tester.pump(const Duration(milliseconds: 400));
          owner.app.showWorkspacePage(WorkspacePage.hosts);
          await tester.pump(const Duration(milliseconds: 400));
          final card = find.byKey(ValueKey('host_connect_${host.id}'));
          await _until(tester, () => card.evaluate().isNotEmpty);
          final menu = find.descendant(
            of: card,
            matching: find.byIcon(Icons.more_horiz),
          );
          await tester.ensureVisible(menu);
          await tester.tap(menu);
          final shareAction = find.text(l10n.cloudAccessShareMenu);
          await _until(
            tester,
            () => shareAction.hitTestable().evaluate().isNotEmpty,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(shareAction);
          await _until(
            tester,
            () => find.byType(CloudShareHostPanel).evaluate().isNotEmpty,
          );
          final panel = tester.widget<CloudShareHostPanel>(
            find.byType(CloudShareHostPanel),
          );
          expect(identical(panel.app, owner.app), isTrue);
          expect(panel.host.id, host.id);
          expect(
            find.text(l10n.cloudAccessShareTitle(host.name)),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(seconds: 2));
          }
        }
      },
    );
  }
}
