import 'dart:io';

import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/storage/terminal_palette_store.dart';
import 'package:aterm_client/storage/terminal_palette_store_native.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:aterm_client/ui/terminal_palette.dart';
import 'package:aterm_client/ui/terminal_palette_picker.dart';
import 'package:aterm_client/ui/terminal_shortcut_editor.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: buildAppTheme(),
  locale: locale,
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  builder: (context, page) => WindowsWindowChrome(
    controller: WindowChromeController(supported: false),
    child: page!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('palette catalog', () {
    test('presets are complete, unique and free of vendor branding', () {
      expect(terminalPalettePresets, hasLength(62));
      for (final spec in terminalPalettePresets.values) {
        expect(spec.ansi, hasLength(16), reason: spec.name);
        expect(spec.id, matches(RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$')));
        expect(spec.name.toLowerCase(), isNot(contains('termius')));
        expect(spec.id, isNot(contains('termius')));
        // Selection is painted over glyphs, so it must be translucent.
        expect(spec.selection >> 24, lessThan(0xFF), reason: spec.name);
      }
      final dracula = terminalPalettePresets['dracula']!.toTheme();
      expect(dracula.background.toARGB32(), 0xFF282A36);
      expect(dracula.foreground.toARGB32(), 0xFFF8F8F2);
      expect(terminalPalettePresets['rose-pine-moon']!.name, 'Rosé Pine Moon');
      expect(terminalPalettePresets['solarized-light']!.isDark, isFalse);
      expect(terminalPalettePresets['nord-dark']!.isDark, isTrue);
    });

    test('built-in synced palettes keep translucent selection', () {
      for (final choice in VaultTerminalThemeChoice.values) {
        final theme = buildTerminalColorTheme(choice);
        expect(theme.selection.a, lessThan(1), reason: choice.value);
      }
    });
  });

  group('device palette overlay', () {
    test('defaults to the synced theme and ignores unknown stored ids', () async {
      final store = MemoryTerminalPaletteStore('from-a-newer-version');
      final controller = TerminalPaletteController();
      await controller.load(store);
      expect(controller.presetId, isNull);
      expect(store.writes, 0, reason: 'unknown values are not overwritten');
      expect(
        controller.resolve(VaultTerminalThemeChoice.atermDark),
        buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark),
      );
      expect(
        controller
            .resolve(VaultTerminalThemeChoice.atermDark)
            .foreground
            .toARGB32(),
        0xFF9BD477,
      );
    });

    test('selection applies at once, persists, clears and reports failures', () async {
      final store = MemoryTerminalPaletteStore();
      final controller = TerminalPaletteController();
      await controller.load(store);
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.select('dracula');
      expect(controller.presetId, 'dracula');
      expect(store.value, 'dracula');
      expect(notified, greaterThan(0));
      final dracula = controller.resolve(VaultTerminalThemeChoice.light);
      expect(dracula.background.toARGB32(), 0xFF282A36);
      expect(
        identical(dracula, controller.resolve(VaultTerminalThemeChoice.light)),
        isTrue,
        reason: 'terminal views receive a stable theme instance',
      );

      final reloaded = TerminalPaletteController();
      await reloaded.load(store);
      expect(reloaded.presetId, 'dracula', reason: 'persists across launch');

      await controller.select(null);
      expect(store.value, isNull);
      expect(
        controller.resolve(VaultTerminalThemeChoice.light),
        buildTerminalColorTheme(VaultTerminalThemeChoice.light),
      );

      expect(() => controller.select('no-such-palette'), throwsArgumentError);

      store.failWith = const FileSystemException('read-only');
      await controller.select('nord-dark');
      expect(controller.presetId, 'nord-dark');
      expect(controller.writeFailed, isTrue);
      store.failWith = null;
      await controller.select('nord-dark');
      expect(controller.writeFailed, isFalse);
    });

    test('file store round-trips and rejects oversized content', () async {
      final directory = await Directory.systemTemp.createTemp('r7-palette-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileTerminalPaletteStore(directory: () async => directory);
      expect(await store.read(), isNull);
      await store.write('gruvbox-dark');
      expect(await store.read(), 'gruvbox-dark');
      await store.write(null);
      expect(await store.read(), isNull);
      await File(
        '${directory.path}/terminal-palette-v1',
      ).writeAsString('x' * 500);
      expect(await store.read(), isNull);
    });
  });

  group('palette gallery', () {
    tearDown(() => TerminalPaletteController.debugInstance = null);

    testWidgets('searches, filters, selects and rebuilds terminal surfaces', (
      tester,
    ) async {
      // Built inside the FakeAsync zone so its write chain is pumped.
      final store = MemoryTerminalPaletteStore();
      final palettes = TerminalPaletteController();
      TerminalPaletteController.debugInstance = palettes;
      await palettes.load(store);
      tester.view.physicalSize = const Size(1100, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              Builder(
                builder: (context) => Text(
                  terminalColorThemeOf(
                    context,
                    VaultTerminalThemeChoice.atermDark,
                  ).background.toARGB32().toRadixString(16),
                  key: const ValueKey('surface_background'),
                ),
              ),
              const TerminalPaletteGallery(
                synced: VaultTerminalThemeChoice.atermDark,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      Text surface() =>
          tester.widget<Text>(find.byKey(const ValueKey('surface_background')));
      expect(surface().data, 'ff141729');
      final synced = find.byKey(const ValueKey('terminal_palette_option_synced'));
      expect(
        tester.getSemantics(synced),
        matchesSemantics(
          label: 'Saved theme (Atermius Dark)',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isInMutuallyExclusiveGroup: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
        ),
      );
      expect(
        find.byKey(const ValueKey('terminal_palette_option_dracula')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('terminal_palette_search')),
        'drac',
      );
      await tester.pumpAndSettle();
      expect(synced, findsNothing);
      expect(
        find.byKey(const ValueKey('terminal_palette_option_nord-dark')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('terminal_palette_option_dracula')),
      );
      await tester.pumpAndSettle();
      expect(palettes.presetId, 'dracula');
      expect(store.value, 'dracula');
      expect(surface().data, 'ff282a36', reason: 'terminal surface rebuilt');
      expect(find.text('Terminals on this device use Dracula.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('terminal_palette_search')),
        'zzzz',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal_palette_no_matches')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('terminal_palette_search')),
        '',
      );
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal_palette_option_solarized-light')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal_palette_option_dracula')),
        findsNothing,
      );
      await tester.tap(synced);
      await tester.pumpAndSettle();
      expect(palettes.presetId, isNull);
      expect(store.value, isNull);
      expect(surface().data, 'ff141729');
    });

    for (final locale in const ['en', 'zh', 'ja', 'ru']) {
      testWidgets('gallery and editor fit a narrow $locale settings card', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 2600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controllers = {
          for (final action in TerminalShortcutAction.values)
            action: TextEditingController(
              text: TerminalShortcutBindings.defaults.chordFor(action),
            ),
        };
        addTearDown(() {
          for (final controller in controllers.values) {
            controller.dispose();
          }
        });
        await tester.pumpWidget(
          _app(
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TerminalSyncedThemeSelector(
                    selected: VaultTerminalThemeChoice.atermDark,
                    onSelected: (_) {},
                  ),
                  const TerminalPaletteGallery(
                    synced: VaultTerminalThemeChoice.atermDark,
                  ),
                  TerminalShortcutEditor(
                    controllers: controllers,
                    fieldKey: (action) => ValueKey('field-${action.name}'),
                    enabled: true,
                    onChanged: () {},
                  ),
                ],
              ),
            ),
            locale: Locale(locale),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('shortcut editor', () {
    late Map<TerminalShortcutAction, TextEditingController> controllers;
    var changes = 0;
    setUp(() {
      changes = 0;
      controllers = {
        for (final action in TerminalShortcutAction.values)
          action: TextEditingController(
            text: TerminalShortcutBindings.defaults.chordFor(action),
          ),
      };
    });
    tearDown(() {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    });

    Widget editor({bool enabled = true}) => _app(
      StatefulBuilder(
        builder: (context, setState) => TerminalShortcutEditor(
          controllers: controllers,
          fieldKey: (action) => ValueKey('field-${action.name}'),
          enabled: enabled,
          onChanged: () => setState(() => changes++),
        ),
      ),
    );

    test('recorded chords use the dispatcher modifier mapping', () {
      expect(
        terminalShortcutChordFromKey(
          key: LogicalKeyboardKey.keyK,
          controlPressed: true,
          metaPressed: false,
          altPressed: true,
          shiftPressed: false,
          platform: TargetPlatform.windows,
        ),
        'mod+alt+k',
      );
      expect(
        terminalShortcutChordFromKey(
          key: LogicalKeyboardKey.keyK,
          controlPressed: false,
          metaPressed: true,
          altPressed: false,
          shiftPressed: true,
          platform: TargetPlatform.macOS,
        ),
        'mod+shift+k',
      );
      expect(
        terminalShortcutChordFromKey(
          key: LogicalKeyboardKey.f5,
          controlPressed: false,
          metaPressed: false,
          altPressed: true,
          shiftPressed: false,
          platform: TargetPlatform.linux,
        ),
        'alt+f5',
      );
      expect(
        terminalShortcutChordFromKey(
          key: LogicalKeyboardKey.shiftLeft,
          controlPressed: false,
          metaPressed: false,
          altPressed: false,
          shiftPressed: true,
          platform: TargetPlatform.windows,
        ),
        isNull,
      );
    });

    testWidgets('records a combination, swallows it and shows keycaps', (
      tester,
    ) async {
      var leaked = 0;
      await tester.pumpWidget(
        Focus(
          onKeyEvent: (_, _) {
            leaked++;
            return KeyEventResult.ignored;
          },
          child: editor(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal_shortcut_keycaps_search')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('terminal_shortcut_record_search')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('terminal_shortcut_recording_search')),
        findsOneWidget,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controllers[TerminalShortcutAction.search]!.text, 'mod+alt+k');
      expect(changes, 1);
      expect(leaked, 0, reason: 'recorded keys never reach outer shortcuts');
      final caps = find.byKey(const ValueKey('terminal_shortcut_keycaps_search'));
      for (final cap in ['Ctrl', 'Alt', 'K']) {
        expect(
          find.descendant(of: caps, matching: find.text(cap)),
          findsOneWidget,
        );
      }

      // Escape cancels without changing the binding.
      await tester.tap(
        find.byKey(const ValueKey('terminal_shortcut_record_disconnect')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal_shortcut_recording_disconnect')),
        findsNothing,
      );
      expect(
        controllers[TerminalShortcutAction.disconnect]!.text,
        TerminalShortcutBindings.defaults.chordFor(
          TerminalShortcutAction.disconnect,
        ),
      );

      // Per-row reset restores the default and is disabled once equal.
      final reset = find.byKey(const ValueKey('terminal_shortcut_reset_search'));
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(
        controllers[TerminalShortcutAction.search]!.text,
        TerminalShortcutBindings.defaults.chordFor(TerminalShortcutAction.search),
      );
      expect(tester.widget<IconButton>(reset).onPressed, isNull);
    });

    testWidgets('flags duplicate and reserved chords inline', (tester) async {
      await tester.pumpWidget(editor());
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('field-searchNext')),
        'mod+alt+shift+f',
      );
      await tester.pumpAndSettle();
      expect(find.text('Also used by another action'), findsNWidgets(2));
      await tester.enterText(
        find.byKey(const ValueKey('field-searchNext')),
        'mod+w',
      );
      await tester.pumpAndSettle();
      expect(find.text('Also used by another action'), findsNothing);
      expect(find.text('Unsupported or reserved combination'), findsOneWidget);
      // Semantics are unchanged: the saved bindings model rejects it too.
      expect(
        () => TerminalShortcutBindings.normalizeChord('mod+w'),
        throwsFormatException,
      );
    });

    testWidgets('disabled editor cannot record or reset', (tester) async {
      controllers[TerminalShortcutAction.search]!.text = 'alt+shift+f';
      await tester.pumpWidget(editor(enabled: false));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('terminal_shortcut_record_search')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('terminal_shortcut_reset_search')),
            )
            .onPressed,
        isNull,
      );
    });
  });
}
