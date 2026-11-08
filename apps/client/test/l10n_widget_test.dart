import 'dart:async';

import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/storage/app_language_store.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/ui/app_language_settings.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_mode_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for a live terminal/SFTP pane: counts State creations so a
/// language switch that recreated session widgets would be detected.
class _SessionProbe extends StatefulWidget {
  const _SessionProbe();
  static int created = 0;

  @override
  State<_SessionProbe> createState() => _SessionProbeState();
}

class _SessionProbeState extends State<_SessionProbe> {
  final input = TextEditingController();
  final focus = FocusNode();
  late final int identity;

  @override
  void initState() {
    super.initState();
    identity = ++_SessionProbe.created;
  }

  @override
  void dispose() {
    input.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(context.l10n.languageSettingTitle, key: const ValueKey('ctx')),
      const _GlobalLabel(),
      Text('session #$identity', key: const ValueKey('identity')),
      TextField(
        key: const ValueKey('terminal_input'),
        controller: input,
        focusNode: focus,
      ),
    ],
  );
}

/// Uses the context-free catalog (as controllers do) and is const, so it only
/// updates if the host really rebuilds the tree in place.
class _GlobalLabel extends StatelessWidget {
  const _GlobalLabel();

  @override
  Widget build(BuildContext context) =>
      Text(currentL10n.terminalTools, key: const ValueKey('global'));
}

Widget _app(AppLanguageController controller, Widget home, {Size? size}) =>
    AppLanguageHost(
      controller: controller,
      builder: (context, locale) => MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(locale: locale),
        home: Scaffold(body: SingleChildScrollView(child: home)),
      ),
    );

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

/// Builds the controller and store inside the test body so their futures
/// (including the serialized preference-write chain) live in the same
/// FakeAsync zone as the widget test; futures created in `setUp` run in the
/// real zone and would never be flushed by `tester.pump`.
Future<(AppLanguageController, MemoryAppLanguageStore)> _languageFixture() async {
  final store = MemoryAppLanguageStore();
  final controller = AppLanguageController(
    systemLocales: () => const [Locale('en', 'US')],
  );
  await controller.load(store);
  AppLanguageController.debugInstance = controller;
  _SessionProbe.created = 0;
  return (controller, store);
}

void main() {

  tearDown(() {
    AppLanguageController.debugInstance = null;
    debugCurrentL10n = appLocalizationsFor(fallbackAppLocale);
  });

  testWidgets(
    'runtime switch relabels in place and keeps session state, input and focus',
    (tester) async {
      final (controller, store) = await _languageFixture();
      await tester.pumpWidget(_app(controller, const _SessionProbe()));
      expect(_text(tester, 'ctx'), 'Language');
      expect(_text(tester, 'global'), 'Terminal tools');

      await tester.enterText(
        find.byKey(const ValueKey('terminal_input')),
        'tail -f /var/log/syslog',
      );
      await tester.pump();
      final state = tester.state<_SessionProbeState>(find.byType(_SessionProbe));
      expect(state.focus.hasFocus, isTrue);

      for (final (language, label, tools) in [
        (AppLanguage.japanese, '言語', 'ターミナルツール'),
        (AppLanguage.russian, 'Язык', 'Инструменты терминала'),
        (AppLanguage.chinese, '语言', '终端工具'),
        (AppLanguage.english, 'Language', 'Terminal tools'),
      ]) {
        await controller.setPreference(language);
        await tester.pump();
        expect(_text(tester, 'ctx'), label, reason: language.code);
        expect(_text(tester, 'global'), tools, reason: language.code);
        expect(
          identical(
            tester.state<_SessionProbeState>(find.byType(_SessionProbe)),
            state,
          ),
          isTrue,
        );
        expect(state.input.text, 'tail -f /var/log/syslog');
        expect(state.focus.hasFocus, isTrue);
        expect(store.value, language.code);
      }
      expect(_SessionProbe.created, 1);
      expect(_text(tester, 'identity'), 'session #1');
    },
  );

  testWidgets('system language changes follow the platform when "system" is chosen', (
    tester,
  ) async {
    _SessionProbe.created = 0;
    tester.platformDispatcher.localesTestValue = const [Locale('ja', 'JP')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final system = AppLanguageController();
    await system.load(MemoryAppLanguageStore('system'));
    await tester.pumpWidget(_app(system, const _SessionProbe()));
    expect(_text(tester, 'ctx'), '言語');

    tester.platformDispatcher.localesTestValue = const [
      Locale('de', 'DE'),
      Locale('ru', 'RU'),
    ];
    await tester.pump();
    expect(_text(tester, 'ctx'), 'Язык');

    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    await tester.pump();
    expect(_text(tester, 'ctx'), 'Language', reason: 'English fallback');
    expect(_SessionProbe.created, 1);
  });

  testWidgets('settings picker persists the choice and shows native names', (
    tester,
  ) async {
    final (controller, store) = await _languageFixture();
    await tester.pumpWidget(_app(controller, const AppLanguageSettings()));
    for (final name in ['English', '简体中文', '日本語', 'Русский']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('System default · currently English'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app_language_ja')));
    await tester.pumpAndSettle();
    expect(store.value, 'ja');
    expect(controller.preference, AppLanguage.japanese);
    expect(find.text('言語'), findsOneWidget);
    expect(find.text('システムの既定 · 現在はEnglish'), findsOneWidget);
    expect(find.text('English'), findsOneWidget, reason: 'native names stay');

    await tester.tap(find.byKey(const ValueKey('app_language_system')));
    await tester.pumpAndSettle();
    expect(store.value, 'system');
    expect(find.text('Language'), findsOneWidget);
  });

  testWidgets('system option describes platform language under an explicit choice', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final controller = AppLanguageController();
    await controller.load(MemoryAppLanguageStore());
    await tester.pumpWidget(
      _app(controller, AppLanguageSettings(controller: controller)),
    );

    for (final language in [
      AppLanguage.chinese,
      AppLanguage.japanese,
      AppLanguage.russian,
      AppLanguage.english,
    ]) {
      await tester.tap(find.byKey(ValueKey('app_language_${language.code}')));
      await tester.pumpAndSettle();
      final l10n = appLocalizationsFor(Locale(language.code));
      expect(
        find.text(l10n.languageSettingSystemResolved('English')),
        findsOneWidget,
        reason: 'System remains English while UI is ${language.code}',
      );
      expect(controller.locale, language.locale);
    }

    await tester.tap(find.byKey(const ValueKey('app_language_zh')));
    await tester.pumpAndSettle();
    tester.platformDispatcher.localesTestValue = const [Locale('ja', 'JP')];
    await tester.pumpAndSettle();
    expect(controller.locale, const Locale('zh'));
    expect(find.text('跟随系统 · 当前为日本語'), findsOneWidget);

    tester.platformDispatcher.localesTestValue = const [Locale('de', 'DE')];
    await tester.pumpAndSettle();
    expect(controller.locale, const Locale('zh'));
    expect(find.text('跟随系统 · 当前为English'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app_language_system')));
    await tester.pumpAndSettle();
    expect(controller.locale, const Locale('en'));
    expect(find.text('System default · currently English'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('pre-login language menu switches without a workspace', (
    tester,
  ) async {
    final (controller, store) = await _languageFixture();
    await tester.pumpWidget(_app(controller, const AppLanguageMenuButton()));
    await tester.tap(find.byKey(const ValueKey('app_language_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app_language_menu_ru')));
    await tester.pumpAndSettle();
    expect(store.value, 'ru');
    expect(controller.locale, const Locale('ru'));
  });

  testWidgets('startup recovery is localized before secure storage exists', (
    tester,
  ) async {
    final (controller, _) = await _languageFixture();
    await controller.setPreference(AppLanguage.japanese);
    await tester.pumpWidget(
      AtermiusStartup(initialize: () => Future<Widget>.error(StateError('x'))),
    );
    await tester.pump();
    expect(find.text('セキュアワークスペースを初期化できませんでした'), findsOneWidget);
    expect(find.text('再試行'), findsOneWidget);
    expect(find.textContaining('StateError'), findsNothing);
  });

  for (final language in [
    AppLanguage.english,
    AppLanguage.chinese,
    AppLanguage.japanese,
    AppLanguage.russian,
  ]) {
    testWidgets(
      '${language.code}: settings, mode card and menus fit 320dp at 2x text',
      (tester) async {
        final (controller, _) = await _languageFixture();
        await controller.setPreference(language);
        await tester.binding.setSurfaceSize(const Size(320, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 900),
              textScaler: TextScaler.linear(2),
            ),
            child: _app(
              controller,
              Column(
                children: [
                  const AppLanguageSettings(),
                  WorkspaceModeSettings(
                    mode: WorkspaceMode.local,
                    onSwitch: () {},
                  ),
                  WorkspaceOverflowMenu(
                    actions: [
                      WorkspaceAction(
                        'settings',
                        currentL10n.settings,
                        Icons.settings,
                        () {},
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(appLocalizationsFor(Locale(language.code)).workspaceMode),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(PopupMenuButton<String>));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.text(appLocalizationsFor(Locale(language.code)).settings),
          findsOneWidget,
        );
      },
    );
  }
}
