import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:aterm_client/ui/terminal_palette.dart';
import 'package:aterm_client/ui/terminal_palette_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  final presetId = terminalPalettePresets.keys.first;

  group('TerminalPaletteController.followSyncedIf', () {
    test('clears the overlay when nothing was selected meanwhile', () async {
      final palettes = TerminalPaletteController();
      await palettes.select(presetId);
      final generation = palettes.selectionGeneration;
      expect(palettes.followSyncedIf(generation), isTrue);
      expect(palettes.presetId, isNull);
      expect(palettes.followSynced(), isFalse);
      palettes.dispose();
    });

    test('keeps a newer selection, also the same preset again (ABA)', () async {
      final palettes = TerminalPaletteController();
      await palettes.select(presetId);
      final generation = palettes.selectionGeneration;
      await palettes.select(presetId);
      expect(palettes.followSyncedIf(generation), isFalse);
      expect(palettes.presetId, presetId);
      palettes.dispose();
    });
  });

  testWidgets('selecting the synced theme repaints a live terminal view', (
    tester,
  ) async {
    final palettes = TerminalPaletteController();
    addTearDown(palettes.dispose);
    await palettes.select(presetId);
    final terminal = Terminal()..write('live terminal');
    const synced = VaultTerminalThemeChoice.atermDark;
    var draft = synced;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TerminalPaletteScope(
          notifier: palettes,
          child: Scaffold(
            body: Column(
              children: [
                SizedBox(
                  height: 120,
                  child: Builder(
                    builder: (context) => TerminalView(
                      terminal,
                      key: const ValueKey('live_terminal'),
                      theme: terminalColorThemeOf(context, synced),
                    ),
                  ),
                ),
                StatefulBuilder(
                  builder: (context, setState) => TerminalSyncedThemeSelector(
                    selected: draft,
                    persisted: synced,
                    onSelected: (value) => setState(() => draft = value),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    TerminalTheme liveTheme() => tester
        .widget<TerminalView>(find.byKey(const ValueKey('live_terminal')))
        .theme;

    final presetTheme = palettes.presetTheme(terminalPalettePresets[presetId]!);
    expect(liveTheme(), same(presetTheme));
    expect(
      find.byKey(const ValueKey('terminal_theme_overlay_notice')),
      findsOneWidget,
    );

    // A different (unsaved) draft does not change the live terminal.
    await tester.tap(find.byKey(const ValueKey('terminal-theme-option-light')));
    await tester.pumpAndSettle();
    expect(liveTheme(), same(presetTheme));

    // Explicitly choosing the saved synced theme applies it at once.
    await tester.tap(
      find.byKey(const ValueKey('terminal-theme-option-atermius-dark')),
    );
    await tester.pumpAndSettle();
    expect(palettes.presetId, isNull);
    expect(liveTheme(), same(buildTerminalColorTheme(synced)));
    expect(
      find.byKey(const ValueKey('terminal_theme_overlay_notice')),
      findsNothing,
    );
  });
}
