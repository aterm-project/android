import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/desktop_resolution_picker.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_settings_editor.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugCurrentL10n = appLocalizationsFor(const Locale('en')));
  for (final code in ['en', 'zh', 'ja', 'ru']) {
    testWidgets('context locale $code overrides legacy selector and global', (
      t,
    ) async {
      debugCurrentL10n = appLocalizationsFor(const Locale('en'));
      final l = appLocalizationsFor(Locale(code));
      await t.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          home: Scaffold(
            body: DesktopResolutionPicker(
              chinese: code != 'zh',
              value: const DesktopResolutionValue(DesktopResolutionKind.auto),
              scaling: DesktopLocalScaling.fit,
              onChanged: (_) {},
              onScalingChanged: (_) {},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text(l.remoteResolution), findsOneWidget);
      expect(find.text(l.desktopAutomaticFitWindow), findsWidgets);
      expect(find.text(l.scalesThisWindowOnlyTheRemote), findsOneWidget);
      expect(
        validateDesktopSize(199, 200, l10n: l),
        l.desktopResolutionSideBounds(200, 8192),
      );
      expect(
        validateDesktopSize(8192, 4097, l10n: l),
        l.desktopResolutionPixelLimit(32),
      );
      expect(validateDesktopSize(8192, 4096, l10n: l), isNull);
      debugCurrentL10n = l;
      expect(
        validateDesktopSize(0, 200),
        l.desktopResolutionSideBounds(200, 8192),
      );
    });
  }
  testWidgets('folder error refreshes and VNC helper follows runtime locale', (
    t,
  ) async {
    final controller = AppLanguageController(
      systemLocales: () => [const Locale('en')],
    );
    addTearDown(controller.dispose);
    var changes = 0;
    await t.pumpWidget(
      AppLanguageHost(
        controller: controller,
        builder: (_, locale) => MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  RdpSettingsEditor(
                    initial: const RdpSettings(),
                    features: const RdpFeatures(
                      RdpFeatures.configV1 | RdpFeatures.drive,
                    ),
                    pickFolder: () async => 'relative/path',
                    onChanged: (_) => changes++,
                  ),
                  VncSettingsEditor(
                    initial: const VncSettings(),
                    onChanged: (_) => changes++,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('host_rdp_options')));
    await t.pumpAndSettle();
    final add = find.byKey(const ValueKey('host_rdp_add_drive'));
    await t.ensureVisible(add);
    await t.tap(add);
    await t.pumpAndSettle();
    final rdpState = t.state(find.byType(RdpSettingsEditor));
    for (final lang in [
      AppLanguage.japanese,
      AppLanguage.russian,
      AppLanguage.chinese,
      AppLanguage.english,
    ]) {
      await controller.setPreference(lang);
      await t.pumpAndSettle();
      final l = appLocalizationsFor(lang.locale!);
      expect(find.text(l.desktopChooseAbsoluteLocalFolder), findsOneWidget);
      expect(
        identical(t.state(find.byType(RdpSettingsEditor)), rdpState),
        isTrue,
      );
      expect(changes, 0);
    }
    final vnc = find.byKey(const ValueKey('host_vnc_options'));
    await t.ensureVisible(vnc);
    await t.tap(vnc);
    await t.pumpAndSettle();
    for (final lang in [
      AppLanguage.japanese,
      AppLanguage.russian,
      AppLanguage.chinese,
      AppLanguage.english,
    ]) {
      await controller.setPreference(lang);
      await t.pumpAndSettle();
      expect(
        find.text(appLocalizationsFor(lang.locale!).desktopVncResizeHelp),
        findsOneWidget,
      );
      expect(changes, 0);
    }
  });
  testWidgets(
    'runtime locale retains editor state, focused input and invalid dimensions',
    (t) async {
      final controller = AppLanguageController(
        systemLocales: () => [const Locale('en')],
      );
      addTearDown(controller.dispose);
      var changes = 0;
      await t.pumpWidget(
        AppLanguageHost(
          controller: controller,
          builder: (_, locale) => MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: RdpSettingsEditor(
                  initial: const RdpSettings(
                    resolution: RdpResolutionMode.fixed,
                    width: 1234,
                    height: 1000,
                  ),
                  features: RdpFeatures.none,
                  onChanged: (_) => changes++,
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('host_rdp_options')));
      await t.pumpAndSettle();
      final width = find.byKey(const ValueKey('host_rdp_resolution_width'));
      await t.ensureVisible(width);
      await t.enterText(width, '199');
      final field = t.widget<TextField>(width);
      final editable = t.state<EditableTextState>(
        find.descendant(of: width, matching: find.byType(EditableText)),
      );
      final state = t.state(find.byType(RdpSettingsEditor));
      expect(editable.widget.focusNode.hasFocus, isTrue);
      final calls = changes;
      for (final lang in [
        AppLanguage.japanese,
        AppLanguage.russian,
        AppLanguage.chinese,
        AppLanguage.english,
      ]) {
        await controller.setPreference(lang);
        await t.pumpAndSettle();
        final l = appLocalizationsFor(lang.locale!);
        expect(
          identical(t.state(find.byType(RdpSettingsEditor)), state),
          isTrue,
        );
        expect(
          identical(t.widget<TextField>(width).controller, field.controller),
          isTrue,
        );
        expect(field.controller!.text, '199');
        expect(editable.widget.focusNode.hasFocus, isTrue);
        expect(
          find.text(l.desktopResolutionSideBounds(200, 8192)),
          findsWidgets,
        );
        expect(find.text(l.desktopClipboardText), findsOneWidget);
        expect(find.text(l.desktopRdpEngineFeatureUnavailable), findsWidgets);
        expect(changes, calls);
      }
    },
  );
}
