import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/app_theme_store.dart';
import 'package:aterm_client/ui/app_density.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/app_theme_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  group('buildAppTheme', () {
    test('default callers keep the historic dark theme', () {
      final theme = buildAppTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, AppColors.background);
      expect(theme.colorScheme.primary, AppColors.accent);
      expect(theme.colorScheme.surface, AppColors.surface);
      expect(theme.extension<AppPalette>(), same(AppPalette.dark));
      // R7 density stays installed.
      expect(theme.extension<AppDensity>(), isNotNull);
    });

    test('light theme: white canvas, same accent, readable text roles', () {
      final theme = buildAppTheme(brightness: Brightness.light);
      final p = theme.extension<AppPalette>()!;
      expect(theme.brightness, Brightness.light);
      expect(p, same(AppPalette.light));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
      expect(theme.cardTheme.color, const Color(0xFFFFFFFF));
      expect(theme.colorScheme.primary, AppColors.accent);
      for (final role in [p.text, p.muted, p.accentText, p.orange, p.red]) {
        expect(_contrast(role, p.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(role, p.surfaceRaised), greaterThanOrEqualTo(4.5));
      }
      expect(_contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.onErrorContainer, p.errorContainer), greaterThan(7));
    });

    for (final brightness in Brightness.values) {
      test('$brightness tooltips are dark with explicit white text', () {
        final tooltip = buildAppTheme(brightness: brightness).tooltipTheme;
        final background = (tooltip.decoration! as BoxDecoration).color!;
        final text = tooltip.textStyle!.color!;
        expect(text, const Color(0xFFFFFFFF));
        expect(background.computeLuminance(), lessThan(.05));
        expect(_contrast(text, background), greaterThanOrEqualTo(7));
      });
    }
  });

  group('AppThemeController', () {
    test('missing, invalid and failing reads keep the dark default', () async {
      for (final stored in [null, '', 'neon', 'x' * 40]) {
        final controller = AppThemeController();
        await controller.load(MemoryAppThemeStore(stored));
        expect(controller.preference, AppThemePreference.dark);
        expect(controller.themeMode, ThemeMode.dark);
      }
    });

    test('restores and persists explicit choices', () async {
      final store = MemoryAppThemeStore('light');
      final controller = AppThemeController();
      await controller.load(store);
      expect(controller.themeMode, ThemeMode.light);
      await controller.setPreference(AppThemePreference.system);
      expect(controller.themeMode, ThemeMode.system);
      expect(store.value, 'system');
      expect(controller.writeFailed, isFalse);
    });

    test('a failed write still applies and is reported', () async {
      final store = MemoryAppThemeStore()..failWith = StateError('disk');
      final controller = AppThemeController();
      await controller.load(store);
      await controller.setPreference(AppThemePreference.light);
      expect(controller.themeMode, ThemeMode.light);
      expect(controller.writeFailed, isTrue);
    });
  });

  testWidgets('switching theme applies in place and keeps State and drafts', (
    tester,
  ) async {
    final controller = AppThemeController();
    await controller.load(MemoryAppThemeStore());
    final draft = TextEditingController(text: 'unsaved draft');
    addTearDown(draft.dispose);
    var created = 0;
    await tester.pumpWidget(
      AppThemeModeBuilder(
        controller: controller,
        builder: (context, mode) => MaterialApp(
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(brightness: Brightness.light),
          darkTheme: buildAppTheme(),
          themeMode: mode,
          home: Scaffold(
            body: ListView(
              children: [
                _Counter(onCreate: () => created++),
                TextField(key: const ValueKey('draft'), controller: draft),
                AppThemeSettings(controller: controller),
                const Tooltip(message: 'Hint', child: Text('target')),
              ],
            ),
          ),
        ),
      ),
    );
    BuildContext ctx() => tester.element(find.text('target'));
    expect(Theme.of(ctx()).brightness, Brightness.dark);

    await tester.tap(find.byKey(const ValueKey('app_theme_light')));
    await tester.pumpAndSettle();
    expect(controller.preference, AppThemePreference.light);
    expect(Theme.of(ctx()).brightness, Brightness.light);
    expect(ctx().palette.isDark, isFalse);
    expect(created, 1, reason: 'subtree must not be recreated');
    expect(draft.text, 'unsaved draft');
    expect(find.text('unsaved draft'), findsOneWidget);

    // The rendered tooltip label is white on the light theme too.
    tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
    await tester.pumpAndSettle();
    final label = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == 'Hint',
      ),
    );
    expect(label.text.style?.color, const Color(0xFFFFFFFF));
  });
}

class _Counter extends StatefulWidget {
  const _Counter({required this.onCreate});
  final VoidCallback onCreate;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 1);
}
