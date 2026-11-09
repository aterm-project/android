import 'dart:async';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/ui/account_settings.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:aterm_client/ui/workspace_mode_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _summary = AccountSessionSummary(
  username: 'alice',
  serverUrl: 'https://sync.example.test',
  accountId: 'acct-1234',
  deviceId: 'device-5678',
  vaultName: 'Personal',
  instanceAdmin: false,
);

Widget _host(
  Widget child, {
  WorkspaceMode mode = WorkspaceMode.server,
  Future<void> Function()? onSwitch,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, routeChild) => WorkspaceModeScope(
    mode: mode,
    busy: false,
    onSwitch: onSwitch ?? () async {},
    child: routeChild!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

class _ModeStore implements WorkspaceModeStore {
  WorkspaceMode? saved;
  final writes = <WorkspaceMode>[];
  @override
  Future<WorkspaceMode?> read() async => saved;
  @override
  Future<void> write(WorkspaceMode mode) async {
    writes.add(mode);
    saved = mode;
  }
}

class _Controller extends AppController {
  _Controller({required super.sodium, required super.database})
    : super(secureStore: ClientSecureStore());
  int restores = 0;
  @override
  Future<void> restoreLastServer() async => restores++;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (!tester.binding.hasScheduledFrame) break;
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('signed-in account page', () {
    testWidgets('shows mode, identity and server without secrets', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AccountSettingsView(
            summary: _summary,
            onLock: () async {},
            onSignOut: () async {},
            describeError: (_) => 'failed',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Account and sync'), findsOneWidget);
      expect(find.text('https://sync.example.test'), findsOneWidget);
      expect(find.text('alice'), findsNWidgets(2));
      expect(find.text('acct-1234'), findsOneWidget);
      expect(find.text('device-5678'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sign out requires confirmation and blocks repeat taps', (
      tester,
    ) async {
      var signOuts = 0;
      final pending = Completer<void>();
      await tester.pumpWidget(
        _host(
          AccountSettingsView(
            summary: _summary,
            onLock: () async {},
            onSignOut: () {
              signOuts++;
              return pending.future;
            },
            describeError: (_) => 'failed',
          ),
        ),
      );
      final signOut = find.byKey(const ValueKey('account_settings_sign_out'));
      await tester.tap(signOut);
      await tester.pumpAndSettle();
      expect(find.text('Sign out of this account?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('account_settings_confirm_cancel')),
      );
      await tester.pumpAndSettle();
      expect(signOuts, 0);

      await tester.tap(signOut);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account_settings_confirm')));
      await tester.pump();
      expect(signOuts, 1);
      expect(tester.widget<OutlinedButton>(signOut).onPressed, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('account_settings_lock')),
            )
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(signOut).onPressed, isNotNull);
    });

    testWidgets('confirmation for one account is not applied to another', (
      tester,
    ) async {
      var signOuts = 0;
      final summary = ValueNotifier<AccountSessionSummary>(_summary);
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<AccountSessionSummary>(
            valueListenable: summary,
            builder: (context, value, child) => AccountSettingsView(
              summary: value,
              onLock: () async {},
              onSignOut: () async => signOuts++,
              describeError: (_) => 'failed',
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('account_settings_sign_out')));
      await tester.pumpAndSettle();
      summary.value = const AccountSessionSummary(
        username: 'bob',
        serverUrl: 'https://sync.example.test',
        accountId: 'acct-other',
        deviceId: 'device-5678',
        vaultName: null,
        instanceAdmin: false,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('account_settings_confirm')));
      await tester.pumpAndSettle();
      expect(signOuts, 0);
    });

    testWidgets('lifecycle refusal is reported through the friendly mapper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AccountSettingsView(
            summary: _summary,
            onLock: () async => throw StateError('/private/token'),
            onSignOut: () async {},
            describeError: (_) => 'Finish the key rotation first.',
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('account_settings_lock')));
      await tester.pumpAndSettle();
      expect(find.text('Finish the key rotation first.'), findsOneWidget);
      expect(find.textContaining('/private/token'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switch to local goes through the app mode switch', (
      tester,
    ) async {
      var switches = 0;
      await tester.pumpWidget(
        _host(
          AccountSettingsView(
            summary: _summary,
            onLock: () async {},
            onSignOut: () async {},
            describeError: (_) => 'failed',
          ),
          onSwitch: () async => switches++,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('account_settings_switch_local')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('account_settings_confirm_cancel')),
      );
      await tester.pumpAndSettle();
      expect(switches, 0);
      await tester.tap(
        find.byKey(const ValueKey('account_settings_switch_local')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account_settings_confirm')));
      await tester.pumpAndSettle();
      expect(switches, 1);
    });

    testWidgets('security link opens the existing Account security category', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SettingsScaffold(
              sections: [
                SettingsSection(
                  id: accountSettingsSectionId,
                  title: 'Account & sign-in',
                  icon: Icons.account_circle_outlined,
                  description: 'account',
                  builder: (_) => AccountSettingsView(
                    summary: _summary,
                    onLock: () async {},
                    onSignOut: () async {},
                    describeError: (_) => 'failed',
                  ),
                ),
                SettingsSection(
                  id: accountSecuritySectionId,
                  title: 'Account security',
                  icon: Icons.shield_outlined,
                  description: 'security',
                  builder: (_) => const Text('security page body'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('security page body'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('account_settings_open_security')),
      );
      await tester.pumpAndSettle();
      expect(find.text('security page body'), findsOneWidget);
    });
  });

  group('narrow layout', () {
    const longSummary = AccountSessionSummary(
      username: 'a-very-long-account-username-without-spaces@example.test',
      serverUrl:
          'https://sync.very-long-subdomain-for-layout.example.test/tenant/atermius',
      accountId: '0f1e2d3c-4b5a-4968-8776-655443322110',
      deviceId: 'ffeeddcc-bbaa-4998-8776-554433221100',
      vaultName: 'A shared team Vault with a deliberately long display name',
      instanceAdmin: true,
    );

    for (final width in [390.0, 320.0]) {
      for (final locale in const [Locale('en'), Locale('zh'), Locale('ru')]) {
        testWidgets(
          'account and local panels wrap at ${width.toInt()}px (${locale.languageCode})',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 1400));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await tester.pumpWidget(
              MaterialApp(
                locale: locale,
                localizationsDelegates:
                    AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => WorkspaceModeScope(
                  mode: WorkspaceMode.server,
                  busy: false,
                  onSwitch: () async {},
                  child: child!,
                ),
                home: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AccountSettingsView(
                          summary: longSummary,
                          onLock: () async {},
                          onSignOut: () async {},
                          describeError: (_) => 'failed',
                        ),
                        LocalAccountSettingsPanel(onSignIn: () async {}),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            for (final key in const [
              'account_settings_admin_badge',
              'account_settings_identity',
              'account_settings_server',
              'account_settings_open_security',
              'account_settings_sign_out',
              'account_settings_switch_local',
              'account_settings_local_sign_in',
            ]) {
              final rect = tester.getRect(find.byKey(ValueKey(key)));
              expect(rect.right, lessThanOrEqualTo(width), reason: key);
              expect(rect.left, greaterThanOrEqualTo(0), reason: key);
            }
            // Identifiers stay complete (wrapped, never ellipsized/cropped).
            expect(find.text(longSummary.serverUrl!), findsOneWidget);
            expect(find.text(longSummary.accountId!), findsOneWidget);
          },
        );
      }
    }
  });

  group('local account entry', () {
    testWidgets('explains sync and only switches after confirmation', (
      tester,
    ) async {
      var signIns = 0;
      await tester.pumpWidget(
        _host(
          LocalAccountSettingsPanel(onSignIn: () async => signIns++),
          mode: WorkspaceMode.local,
        ),
      );
      expect(find.text('Local only (this device)'), findsOneWidget);
      expect(find.textContaining('never sync'), findsOneWidget);
      final signIn = find.byKey(const ValueKey('account_settings_local_sign_in'));
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      expect(find.textContaining('are not uploaded'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('account_settings_confirm_cancel')),
      );
      await tester.pumpAndSettle();
      expect(signIns, 0);
      await tester.tap(signIn);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account_settings_confirm')));
      await tester.pumpAndSettle();
      expect(signIns, 1);
    });

    testWidgets('switch failure is redacted', (tester) async {
      await tester.pumpWidget(
        _host(
          LocalAccountSettingsPanel(
            onSignIn: () async => throw StateError('/private/path'),
          ),
          mode: WorkspaceMode.local,
        ),
      );
      await tester.tap(
        find.byKey(const ValueKey('account_settings_local_sign_in')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('account_settings_confirm')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Couldn't switch the workspace mode. Check local storage and try again.",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('/private/path'), findsNothing);
    });

    group('app routing', () {
      late SodiumSumo sodium;
      late VaultCrypto crypto;
      final databases = <ClientDatabase>[];
      setUpAll(() async {
        sodium = await SodiumSumoInit.init();
        crypto = VaultCrypto(sodium);
      });
      tearDown(() async {
        for (final db in databases) {
          await db.close();
        }
        databases.clear();
      });

      testWidgets(
        'local Sign in opens the existing server sign-in flow and persists mode',
        (tester) async {
          final store = _ModeStore()..saved = WorkspaceMode.local;
          final controllers = <_Controller>[];
          var serverStarts = 0;
          await tester.pumpWidget(
            AtermiusApp(
              enableProfileModeSelection: true,
              modeStore: store,
              crypto: crypto,
              localProfileCatalogInitializer: () async =>
                  LocalProfileCatalog.forTesting(NativeDatabase.memory()),
              serverInitializer: () async {
                serverStarts++;
                final db = ClientDatabase.forTesting(NativeDatabase.memory());
                databases.add(db);
                final controller = _Controller(sodium: sodium, database: db);
                controllers.add(controller);
                return controller;
              },
            ),
          );
          await _settle(tester);
          await tester.tap(find.byTooltip('Host menu · click to open'));
          await _settle(tester);
          await tester.tap(
            find.byKey(const ValueKey('local_profile_preferences_toggle')),
          );
          await _settle(tester);
          final signIn = find.byKey(
            const ValueKey('account_settings_local_sign_in'),
          );
          await tester.ensureVisible(signIn);
          await tester.pumpAndSettle();

          // Cancelling keeps the local workspace and never opens the server.
          await tester.tap(signIn);
          await _settle(tester);
          await tester.tap(
            find.byKey(const ValueKey('account_settings_confirm_cancel')),
          );
          await _settle(tester);
          expect(serverStarts, 0);
          expect(store.saved, WorkspaceMode.local);

          await tester.tap(signIn);
          await _settle(tester);
          await tester.tap(
            find.byKey(const ValueKey('account_settings_confirm')),
          );
          await _settle(tester);
          expect(find.text('Connect to your server'), findsOneWidget);
          expect(serverStarts, 1);
          // The stored-session restore path is the existing one, run once.
          expect(controllers.single.restores, 1);
          expect(store.writes, [WorkspaceMode.server]);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
        },
      );
    });
  });
}
