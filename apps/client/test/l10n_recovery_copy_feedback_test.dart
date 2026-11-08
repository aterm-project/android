import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/app_language_store.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/settings_navigation.dart';

const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _recoveryCode = 'abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE';

/// Narrow proof for the recovery-code Copy feedback (Settings dialog and the
/// auth-flow rotated-code dialog): the outcome
/// is a stable bool, so a runtime language switch relabels the feedback but
/// never flips success (teal) into failure (error colour) or vice versa.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AppLanguageController.debugInstance = null;
    debugCurrentL10n = appLocalizationsFor(fallbackAppLocale);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final copySucceeds in [true, false]) {
    testWidgets(
      'recovery Copy ${copySucceeds ? 'success' : 'failure'} feedback keeps '
      'its outcome across a language switch',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 1200);
        tester.view.devicePixelRatio = 1;
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (!copySucceeds) {
                throw PlatformException(code: 'clipboard_unavailable');
              }
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        final language = AppLanguageController(
          systemLocales: () => const [Locale('en', 'US')],
        );
        await language.load(MemoryAppLanguageStore());
        AppLanguageController.debugInstance = language;

        final sodium = await SodiumSumoInit.init();
        final database = ClientDatabase.forTesting(NativeDatabase.memory());
        final app =
            _RecoverySettingsController(
                sodium: sodium,
                database: database,
                secureStore: ClientSecureStore(),
              )
              ..stage = ClientStage.workspace
              ..page = WorkspacePage.settings
              ..account = const AccountProfile(
                accountId: _accountId,
                deviceId: _deviceId,
                accountKeyEnvelopeVersion: 1,
                accountKeyEnvelope: {},
              )
              ..session = const AuthSession(
                accountId: _accountId,
                accessToken: 'test-access-token',
                expiresIn: 900,
                refreshToken: 'test-refresh-token',
                deviceId: _deviceId,
                vaults: [],
              );

        try {
          await tester.pumpWidget(
            AppLanguageHost(
              controller: language,
              builder: (context, locale) => MaterialApp(
                locale: locale,
                localizationsDelegates: AppLocalizationSetup.delegates,
                supportedLocales: AppLocalizationSetup.locales,
                theme: buildAppTheme(locale: locale),
                home: AppShell(controller: app),
              ),
            ),
          );
          await tester.pump();
          if (find
              .byKey(const ValueKey('cloud_settings'))
              .evaluate()
              .isNotEmpty) {
            await openSettingsCategory(tester, 'security', ifAvailable: true);
          }
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('account_recovery_configure')),
          );
          await tester.tap(
            find.byKey(const ValueKey('account_recovery_configure')),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextField).last,
            'current password',
          );
          await tester.tap(find.text('Continue'));
          await tester.pumpAndSettle();
          expect(find.text(_recoveryCode), findsOneWidget);

          await _expectStableCopyFeedback(
            tester,
            language,
            copySucceeds: copySucceeds,
            code: _recoveryCode,
            copied: () => copied,
          );

          await tester.tap(find.text('I stored this code securely'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Finish'));
          await tester.pumpAndSettle();
          expect(find.text(_recoveryCode), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
          await database.close();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }

  for (final copySucceeds in [true, false]) {
    testWidgets(
      'rotated recovery code Copy ${copySucceeds ? 'success' : 'failure'} '
      'feedback keeps its outcome across a language switch',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 1000);
        tester.view.devicePixelRatio = 1;
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (!copySucceeds) {
                throw PlatformException(code: 'clipboard_unavailable');
              }
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        final language = AppLanguageController(
          systemLocales: () => const [Locale('en', 'US')],
        );
        await language.load(MemoryAppLanguageStore());
        AppLanguageController.debugInstance = language;

        final sodium = await SodiumSumoInit.init();
        final database = ClientDatabase.forTesting(NativeDatabase.memory());
        final app = _RecoveryAuthController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )..stage = ClientStage.login;

        try {
          await tester.pumpWidget(
            AppLanguageHost(
              controller: language,
              builder: (context, locale) => MaterialApp(
                locale: locale,
                localizationsDelegates: AppLocalizationSetup.delegates,
                supportedLocales: AppLocalizationSetup.locales,
                theme: buildAppTheme(locale: locale),
                home: AuthFlow(controller: app),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('account_recovery_open')),
          );
          await tester.tap(find.byKey(const ValueKey('account_recovery_open')));
          await tester.pumpAndSettle();
          await tester.enterText(_field('Account name'), 'alice@example.test');
          await tester.enterText(
            _field('Recovery code'),
            'previous-recovery-code',
          );
          await tester.enterText(
            _field('New master password · 12+ characters'),
            'new secure master password',
          );
          await tester.enterText(
            _field('Confirm new master password'),
            'new secure master password',
          );
          await tester.enterText(_field('New device name'), 'Recovery browser');
          await tester.tap(find.text('Verify recovery code'));
          await tester.pumpAndSettle();
          expect(find.text('Store the new recovery code'), findsOneWidget);

          await _expectStableCopyFeedback(
            tester,
            language,
            copySucceeds: copySucceeds,
            code: _recoveryCode,
            copied: () => copied,
          );

          await tester.tap(find.text('I stored this code securely'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Commit recovery'));
          await tester.pumpAndSettle();
          expect(find.text(_recoveryCode), findsNothing);
          expect(app.completedRecovery, isTrue);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
          await database.close();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      },
    );
  }
}

/// Taps Copy in the open recovery dialog and checks that the feedback keeps
/// its outcome (text + colour) while the language switches en → zh → en.
Future<void> _expectStableCopyFeedback(
  WidgetTester tester,
  AppLanguageController language, {
  required bool copySucceeds,
  required String code,
  required String? Function() copied,
}) async {
  Color? feedbackColor(String text) =>
      tester.widget<Text>(find.text(text)).style?.color;

  const enSuccess = 'Recovery code copied.';
  const enFailure =
      'Could not copy the recovery code. Select and copy it manually.';
  const zhSuccess = '恢复码已复制。';
  const zhFailure = '无法复制恢复码。请手动选中并复制。';
  expect(find.text(enSuccess), findsNothing);
  expect(find.text(enFailure), findsNothing);

  await tester.tap(find.text('Copy code'));
  await tester.pumpAndSettle();

  final dialogTheme = Theme.of(tester.element(find.text(code)));
  final expectedColor = copySucceeds
      ? AppColors.teal
      : dialogTheme.colorScheme.error;
  expect(AppColors.teal, isNot(dialogTheme.colorScheme.error));

  final en = copySucceeds ? enSuccess : enFailure;
  expect(find.text(en), findsOneWidget);
  expect(find.text(copySucceeds ? enFailure : enSuccess), findsNothing);
  expect(feedbackColor(en), expectedColor);
  expect(copied(), copySucceeds ? code : isNull);

  // Runtime switch to Chinese: same outcome, relabelled in place.
  await language.setPreference(AppLanguage.chinese);
  await tester.pumpAndSettle();
  final zh = copySucceeds ? zhSuccess : zhFailure;
  expect(find.text(zh), findsOneWidget);
  expect(find.text(copySucceeds ? zhFailure : zhSuccess), findsNothing);
  expect(find.text(en), findsNothing);
  expect(feedbackColor(zh), expectedColor);
  // The dialog (and its code) survived the switch.
  expect(find.text(code), findsOneWidget);

  // And back to English.
  await language.setPreference(AppLanguage.english);
  await tester.pumpAndSettle();
  expect(find.text(en), findsOneWidget);
  expect(feedbackColor(en), expectedColor);
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'text field "$label"',
);

class _RecoveryAuthController extends AppController {
  _RecoveryAuthController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  bool completedRecovery = false;

  @override
  Future<AccountRecoveryPreparation> prepareFullAccountRecovery({
    required String username,
    required String recoveryCode,
    required String newPassword,
    required String confirmationPassword,
    required String deviceName,
  }) async => const AccountRecoveryPreparation(
    recoveryCode: _recoveryCode,
    recoveredContexts: 1,
  );

  @override
  Future<void> completePreparedAccountRecovery() async {
    completedRecovery = true;
  }

  @override
  Future<void> cancelPreparedAccountRecovery({
    bool force = false,
    bool clearStoredPending = true,
  }) async {}
}

class _RecoverySettingsController extends AppController {
  _RecoverySettingsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  @override
  String? get authenticatedUsername => 'alice@example.test';

  @override
  Future<AccountMfaStatus> refreshAccountMfaStatus() async {
    accountMfaEnabled = false;
    accountMfaRecoveryCodesRemaining = 0;
    return const AccountMfaStatus(enabled: false, recoveryCodesRemaining: 0);
  }

  @override
  Future<AccountRecoverySetupResult> configureAccountRecovery({
    required String currentPassword,
  }) async {
    accountRecoveryStatus = 'current';
    notifyListeners();
    return const AccountRecoverySetupResult(
      recoveryCode: _recoveryCode,
      status: 'current',
      coveredContexts: 1,
      requiredContexts: 1,
    );
  }
}
