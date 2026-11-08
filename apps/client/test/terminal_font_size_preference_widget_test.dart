import 'support/settings_navigation.dart';

import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_palette_picker.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the default and only supported discrete font sizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();

    try {
      await _mountSettings(tester, app);

      final dropdown = tester.widget<DropdownButtonFormField<int>>(
        find.byKey(const ValueKey('vault_terminal_font_size')),
      );
      expect(
        dropdown.initialValue,
        VaultPreferenceRecord.defaultTerminalFontSize,
      );
      expect(find.text('13 px'), findsOneWidget);
      expect(
        find.textContaining('Allowed sizes: 10, 11, 12, 13, 14, 16, 18 px'),
        findsOneWidget,
      );
      final fontSizeDropdown = find.byKey(
        const ValueKey('vault_terminal_font_size'),
      );
      await tester.ensureVisible(fontSizeDropdown);
      await tester.tap(fontSizeDropdown);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-10')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-11')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-12')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-13')),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-14')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-16')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-18')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-font-size-option-15')),
        findsNothing,
      );
      expect(app.fontSizeSaveCalls, 0);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('saves a selected size through the Vault controller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();

    try {
      await _mountSettings(tester, app);
      final fontSizeDropdown = find.byKey(
        const ValueKey('vault_terminal_font_size'),
      );
      await tester.ensureVisible(fontSizeDropdown);
      await tester.tap(fontSizeDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('16 px').last);
      await tester.pumpAndSettle();

      final save = find.byKey(const ValueKey('save_vault_terminal_font_size'));
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(app.fontSizeSaveCalls, 1);
      expect(app.savedFontSize, 16);
      expect(app.terminalFontSize, 16);
      expect(
        find.text(
          'Saved 16 px. This encrypted preference will sync to devices with access to this Vault.',
        ),
        findsOneWidget,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('read-only Vault keeps the font-size preference read-only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(canWrite: false);

    try {
      await _mountSettings(tester, app);

      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byKey(const ValueKey('vault_terminal_font_size')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_vault_terminal_font_size')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text(
          'This Vault is read-only. You can view the shared terminal font size but cannot change it.',
        ),
        findsOneWidget,
      );
      expect(app.fontSizeSaveCalls, 0);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('saves the selected theme through the Vault controller', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    try {
      await _mountSettings(tester, app);
      final themeDropdown = find.byKey(const ValueKey('vault_terminal_theme'));
      expect(
        tester.widget<TerminalSyncedThemeSelector>(themeDropdown).selected,
        VaultTerminalThemeChoice.atermDark,
      );
      final lightOption = find.byKey(
        const ValueKey('terminal-theme-option-light'),
      );
      expect(lightOption, findsOneWidget);
      await tester.ensureVisible(lightOption);
      await tester.tap(lightOption);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TerminalSyncedThemeSelector>(themeDropdown).selected,
        VaultTerminalThemeChoice.light,
      );
      final save = find.byKey(const ValueKey('save_vault_terminal_theme'));
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(app.themeSaveCalls, 1);
      expect(app.savedTheme, VaultTerminalThemeChoice.light);
      expect(app.terminalTheme, VaultTerminalThemeChoice.light);
      expect(
        find.text(
          'Saved Light. This encrypted preference will sync to devices with access to this Vault.',
        ),
        findsOneWidget,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('read-only Vault keeps the terminal theme preference read-only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(canWrite: false);
    try {
      await _mountSettings(tester, app);
      expect(
        tester
            .widget<TerminalSyncedThemeSelector>(
              find.byKey(const ValueKey('vault_terminal_theme')),
            )
            .onSelected,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_vault_terminal_theme')),
            )
            .onPressed,
        isNull,
      );
      expect(
        find.text(
          'This Vault is read-only. You can view the shared terminal color theme but cannot change it.',
        ),
        findsOneWidget,
      );
      expect(app.themeSaveCalls, 0);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('shortcut defaults can be restored and explicitly saved', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    try {
      await _mountSettings(tester, app);
      final search = find.byKey(const ValueKey('terminal-shortcut-search'));
      await tester.ensureVisible(search);
      expect(
        tester.widget<TextField>(search).controller!.text,
        TerminalShortcutBindings.defaults.chordFor(
          TerminalShortcutAction.search,
        ),
      );
      await tester.enterText(search, 'mod+alt+f');
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('save_terminal_shortcuts'));
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(app.shortcutSaveCalls, 1);
      expect(
        app.terminalShortcutBindings.chordFor(TerminalShortcutAction.search),
        'mod+alt+f',
      );
      expect(
        find.text(
          'Saved. These encrypted semantic bindings will sync to devices with access to this Vault.',
        ),
        findsOneWidget,
      );

      await tester.enterText(search, 'mod+alt+shift+f');
      await tester.pumpAndSettle();
      final restore = find.byKey(
        const ValueKey('restore_default_terminal_shortcuts'),
      );
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      app.notifyUnrelatedForTesting();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(search).controller!.text,
        TerminalShortcutBindings.defaults.chordFor(
          TerminalShortcutAction.search,
        ),
      );
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(app.shortcutSaveCalls, 2);
      expect(app.savedShortcuts, TerminalShortcutBindings.defaults);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('remote shortcut updates replace an untouched draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    final remoteBindings = TerminalShortcutBindings.fromBindings({
      ...TerminalShortcutBindings.defaults.bindings,
      TerminalShortcutAction.search: 'mod+alt+shift+j',
    });

    try {
      await _mountSettings(tester, app);
      final search = find.byKey(const ValueKey('terminal-shortcut-search'));
      expect(
        tester.widget<TextField>(search).controller!.text,
        TerminalShortcutBindings.defaults.chordFor(
          TerminalShortcutAction.search,
        ),
      );

      // Simulate a record arriving from another device after this form mounted.
      await app.receiveRemoteShortcutBindingsForTesting(remoteBindings);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(search).controller!.text,
        'mod+alt+shift+j',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_terminal_shortcuts')),
            )
            .onPressed,
        isNull,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('remote shortcut updates preserve a locally edited draft', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    final remoteBindings = TerminalShortcutBindings.fromBindings({
      ...TerminalShortcutBindings.defaults.bindings,
      TerminalShortcutAction.search: 'mod+alt+shift+j',
    });

    try {
      await _mountSettings(tester, app);
      final search = find.byKey(const ValueKey('terminal-shortcut-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'mod+alt+e');
      await tester.pumpAndSettle();

      await app.receiveRemoteShortcutBindingsForTesting(remoteBindings);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(search).controller!.text, 'mod+alt+e');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_terminal_shortcuts')),
            )
            .onPressed,
        isNotNull,
      );
      expect(app.shortcutSaveCalls, 0);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets(
    'reverting to the old binding stays dirty after unrelated app updates',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 960));
      final (app, database) = await _makeController();
      final oldBindings = TerminalShortcutBindings.defaults;
      final remoteBindings = TerminalShortcutBindings.fromBindings({
        ...oldBindings.bindings,
        TerminalShortcutAction.search: 'mod+alt+shift+j',
      });

      try {
        await _mountSettings(tester, app);
        final search = find.byKey(const ValueKey('terminal-shortcut-search'));
        await tester.ensureVisible(search);

        // A local edit makes the remote update preserve this draft. Reverting
        // to the old server value must remain an intentional unsaved edit.
        await tester.enterText(search, 'mod+alt+e');
        await tester.pumpAndSettle();
        await app.receiveRemoteShortcutBindingsForTesting(remoteBindings);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(search).controller!.text, 'mod+alt+e');

        await tester.enterText(
          search,
          oldBindings.chordFor(TerminalShortcutAction.search),
        );
        await tester.pumpAndSettle();
        app.notifyUnrelatedForTesting();
        await tester.pumpAndSettle();

        expect(
          tester.widget<TextField>(search).controller!.text,
          oldBindings.chordFor(TerminalShortcutAction.search),
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('save_terminal_shortcuts')),
              )
              .onPressed,
          isNotNull,
        );
        expect(app.shortcutSaveCalls, 0);
      } finally {
        await _dispose(tester, app, database);
      }
    },
  );

  testWidgets('switching Vault resets shortcut draft to that Vault', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    final secondVaultBindings = TerminalShortcutBindings.fromBindings({
      ...TerminalShortcutBindings.defaults.bindings,
      TerminalShortcutAction.search: 'mod+alt+shift+j',
    });

    try {
      await _mountSettings(tester, app);
      final search = find.byKey(const ValueKey('terminal-shortcut-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'mod+alt+e');
      await tester.pumpAndSettle();

      app.switchVaultForTesting(
        vaultId: '22222222-2222-4222-8222-222222222222',
        shortcuts: secondVaultBindings,
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(search).controller!.text,
        'mod+alt+shift+j',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_terminal_shortcuts')),
            )
            .onPressed,
        isNull,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('duplicate shortcut chords show validation and cannot save', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    try {
      await _mountSettings(tester, app);
      final search = find.byKey(const ValueKey('terminal-shortcut-search'));
      final next = find.byKey(const ValueKey('terminal-shortcut-searchNext'));
      await tester.ensureVisible(next);
      await tester.enterText(
        next,
        TerminalShortcutBindings.defaults.chordFor(
          TerminalShortcutAction.search,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal_shortcuts_validation_error')),
        findsOneWidget,
      );
      final save = find.byKey(const ValueKey('save_terminal_shortcuts'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(app.shortcutSaveCalls, 0);
      expect(
        tester.widget<TextField>(search).controller!.text,
        TerminalShortcutBindings.defaults.chordFor(
          TerminalShortcutAction.search,
        ),
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('reserved browser chords show validation and cannot save', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController();
    try {
      await _mountSettings(tester, app);
      final search = find.byKey(const ValueKey('terminal-shortcut-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'mod+w');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('terminal_shortcuts_validation_error')),
        findsOneWidget,
      );
      expect(find.textContaining('non-reserved chord'), findsOneWidget);
      final save = find.byKey(const ValueKey('save_terminal_shortcuts'));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      expect(app.shortcutSaveCalls, 0);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('shortcut record conflict requires explicit candidate repair', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(
      shortcutConflictCandidates: [
        _shortcutCandidate(
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          TerminalShortcutBindings.defaults,
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        _shortcutCandidate(
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          TerminalShortcutBindings.fromBindings({
            ...TerminalShortcutBindings.defaults.bindings,
            TerminalShortcutAction.search: 'mod+alt+f',
          }),
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        ),
      ],
    );
    try {
      await _mountSettings(tester, app);
      expect(
        find.byKey(const ValueKey('terminal_shortcuts_conflict')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_terminal_shortcuts')),
            )
            .onPressed,
        isNull,
      );
      final repair = find.byKey(
        const ValueKey('repair_terminal_shortcuts_conflict'),
      );
      final firstCandidate = find.byKey(
        const ValueKey(
          'terminal-shortcut-conflict-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
      );
      await tester.ensureVisible(firstCandidate);
      await tester.tap(firstCandidate);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(repair).onPressed, isNotNull);
      await tester.ensureVisible(repair);
      await tester.tap(repair);
      await tester.pumpAndSettle();
      expect(app.shortcutRepairCalls, 1);
      expect(
        find.text(
          'The selected shortcut bindings were confirmed after Vault sync.',
        ),
        findsOneWidget,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('theme conflict locks saving and repairs the selected record', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    const retainedId = '22222222-2222-4222-8222-222222222222';
    const otherId = '33333333-3333-4333-8333-333333333333';
    final (app, database) = await _makeController(
      themeConflictCandidates: [
        _themeCandidate(
          retainedId,
          VaultTerminalThemeChoice.light,
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
        _themeCandidate(
          otherId,
          VaultTerminalThemeChoice.atermDark,
          'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
      ],
      retainedThemeRecordId: retainedId,
    );
    try {
      await _mountSettings(tester, app);
      expect(
        find.text('Choose the terminal-theme record to keep'),
        findsOneWidget,
      );
      final conflict = find.byKey(const ValueKey('terminal_theme_conflict'));
      expect(
        find.descendant(of: conflict, matching: find.text('Light')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: conflict, matching: find.text('Atermius Dark')),
        findsWidgets,
      );
      expect(
        tester
            .widget<TerminalSyncedThemeSelector>(
              find.byKey(const ValueKey('vault_terminal_theme')),
            )
            .onSelected,
        isNull,
      );
      final repair = find.byKey(
        const ValueKey('repair_terminal_theme_conflict'),
      );
      expect(tester.widget<FilledButton>(repair).onPressed, isNotNull);
      await tester.ensureVisible(repair);
      await tester.tap(repair);
      await tester.pumpAndSettle();

      expect(app.themeRepairCalls, 1);
      expect(app.repairedThemeRecordId, retainedId);
      expect(app.hasTerminalThemePreferenceConflict, isFalse);
      expect(app.terminalTheme, VaultTerminalThemeChoice.light);
      expect(
        find.text(
          'The selected terminal theme was confirmed after Vault sync.',
        ),
        findsOneWidget,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('save errors use a fixed message and hide exception details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final (app, database) = await _makeController(failFontSizeSave: true);

    try {
      await _mountSettings(tester, app);
      final fontSizeDropdown = find.byKey(
        const ValueKey('vault_terminal_font_size'),
      );
      await tester.ensureVisible(fontSizeDropdown);
      await tester.tap(fontSizeDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('18 px').last);
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('save_vault_terminal_font_size'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(app.fontSizeSaveCalls, 1);
      expect(
        find.text(
          'Could not save terminal font size. Check Vault write access and try again.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('private response body'), findsNothing);
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('font-size conflicts lock editing and retain repair selection', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    const retainedId = '22222222-2222-4222-8222-222222222222';
    const otherId = '33333333-3333-4333-8333-333333333333';
    final (app, database) = await _makeController(
      fontSizeConflictCandidates: [
        _fontSizeCandidate(
          retainedId,
          13,
          'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
        _fontSizeCandidate(otherId, 18, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
      ],
      retainedFontSizeRecordId: retainedId,
    );
    app
      ..setFontSizeForTesting(10)
      ..updateFontSizeDuringRepair = true;

    try {
      await _mountSettings(tester, app);

      expect(
        find.text('Choose the terminal font-size record to keep'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('terminal-font-size-conflict-$retainedId')),
          matching: find.text('13 px'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('terminal-font-size-conflict-$otherId')),
          matching: find.text('18 px'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining(retainedId), findsWidgets);
      expect(
        find.textContaining('Revision: aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byKey(const ValueKey('vault_terminal_font_size')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('save_vault_terminal_font_size')),
            )
            .onPressed,
        isNull,
      );
      final otherCandidate = tester.widget<RadioListTile<String>>(
        find.byKey(ValueKey('terminal-font-size-conflict-$otherId')),
      );
      expect(otherCandidate.enabled, isFalse);

      final repair = find.byKey(
        const ValueKey('repair_terminal_font_size_conflict'),
      );
      expect(tester.widget<FilledButton>(repair).onPressed, isNotNull);
      await tester.ensureVisible(repair);
      await tester.tap(repair);
      await tester.pumpAndSettle();

      expect(app.fontSizeRepairCalls, 1);
      expect(app.repairedFontSizeRecordId, retainedId);
      expect(app.hasTerminalFontSizePreferenceConflict, isFalse);
      expect(app.terminalFontSize, 13);
      expect(
        find.text(
          'The selected terminal font size was confirmed after Vault sync.',
        ),
        findsOneWidget,
      );
    } finally {
      await _dispose(tester, app, database);
    }
  });

  testWidgets('terminal view uses the active synced font size', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 960));
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final connection = _RecordingConnection();
    final app =
        _FontSizePreferenceController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorForTesting: ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => connection,
          )
          ..setFontSizeForTesting(18)
          ..setThemeForTesting(VaultTerminalThemeChoice.light)
          ..session = AuthSession(
            accountId: 'account-test',
            accessToken: 'access-test',
            expiresIn: 3600,
            refreshToken: 'refresh-test',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..activeVault = const VaultDescriptor(
            id: _vaultId,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..credentials.add(
            const CredentialRecord(
              id: 'credential-terminal-font',
              name: 'Terminal font test credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          );
    const host = HostRecord(
      id: 'host-terminal-font',
      name: 'Terminal font test host',
      address: 'font.example.test',
      username: 'tester',
      credentialId: 'credential-terminal-font',
    );

    try {
      await app.openTerminalTab(host);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AnimatedBuilder(
            animation: app,
            builder: (context, _) => AppShell(controller: app),
          ),
        ),
      );
      await tester.pump();
      if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
        await openSettingsCategory(tester, 'terminal', ifAvailable: true);
      }
      await tester.pump();

      expect(find.byType(TerminalView), findsOneWidget);
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .textStyle
            .fontSize,
        18.0,
      );
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .theme
            .background
            .toARGB32(),
        0xFFF8FAFC,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

Future<(_FontSizePreferenceController, ClientDatabase)> _makeController({
  bool canWrite = true,
  bool failFontSizeSave = false,
  List<VaultPreferenceRecord> themeConflictCandidates = const [],
  String? retainedThemeRecordId,
  List<VaultPreferenceRecord> fontSizeConflictCandidates = const [],
  String? retainedFontSizeRecordId,
  List<VaultPreferenceRecord> shortcutConflictCandidates = const [],
  String? retainedShortcutRecordId,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _FontSizePreferenceController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..failFontSizeSave = failFontSizeSave
        ..setConflictForTesting(
          candidates: fontSizeConflictCandidates,
          retainedRecordId: retainedFontSizeRecordId,
        )
        ..setThemeConflictForTesting(
          candidates: themeConflictCandidates,
          retainedRecordId: retainedThemeRecordId,
        )
        ..setShortcutConflictForTesting(
          candidates: shortcutConflictCandidates,
          retainedRecordId: retainedShortcutRecordId,
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.settings
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  return (app, database);
}

Future<void> _mountSettings(
  WidgetTester tester,
  _FontSizePreferenceController app,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app),
    ),
  );
  await tester.pump();
  if (find.byKey(const ValueKey('cloud_settings')).evaluate().isNotEmpty) {
    await openSettingsCategory(tester, 'terminal', ifAvailable: true);
  }
  await tester.pumpAndSettle();
}

Future<void> _dispose(
  WidgetTester tester,
  _FontSizePreferenceController app,
  ClientDatabase database,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  app.dispose();
  await database.close();
  await tester.binding.setSurfaceSize(null);
}

VaultPreferenceRecord _fontSizeCandidate(
  String id,
  int fontSize,
  String revisionId,
) => VaultPreferenceRecord.terminalFontSize(
  fontSize: fontSize,
  id: id,
).copyWith(revisionId: revisionId);

VaultPreferenceRecord _themeCandidate(
  String id,
  VaultTerminalThemeChoice theme,
  String revisionId,
) => VaultPreferenceRecord.terminalTheme(
  theme: theme,
  id: id,
).copyWith(revisionId: revisionId);

VaultPreferenceRecord _shortcutCandidate(
  String id,
  TerminalShortcutBindings bindings,
  String revisionId,
) => VaultPreferenceRecord.terminalShortcuts(
  bindings: bindings,
  id: id,
).copyWith(revisionId: revisionId);

class _FontSizePreferenceController extends AppController {
  _FontSizePreferenceController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    super.sshConnectorForTesting,
  });

  int _fontSize = VaultPreferenceRecord.defaultTerminalFontSize;
  VaultTerminalThemeChoice _theme = VaultPreferenceRecord.defaultTerminalTheme;
  TerminalShortcutBindings _shortcuts =
      VaultPreferenceRecord.defaultTerminalShortcuts;
  bool failFontSizeSave = false;
  bool updateFontSizeDuringRepair = false;
  final List<VaultPreferenceRecord> _conflictCandidates = [];
  bool _hasConflict = false;
  String? _retainedRecordId;
  int fontSizeSaveCalls = 0;
  int? savedFontSize;
  int fontSizeRepairCalls = 0;
  String? repairedFontSizeRecordId;
  final List<VaultPreferenceRecord> _themeConflictCandidates = [];
  bool _hasThemeConflict = false;
  String? _retainedThemeRecordId;
  int themeSaveCalls = 0;
  VaultTerminalThemeChoice? savedTheme;
  int themeRepairCalls = 0;
  String? repairedThemeRecordId;
  final List<VaultPreferenceRecord> _shortcutConflictCandidates = [];
  bool _hasShortcutConflict = false;
  String? _retainedShortcutRecordId;
  int shortcutSaveCalls = 0;
  TerminalShortcutBindings? savedShortcuts;
  int shortcutRepairCalls = 0;
  String? repairedShortcutRecordId;

  @override
  int get terminalFontSize => _fontSize;

  @override
  VaultTerminalThemeChoice get terminalTheme => _theme;

  @override
  TerminalShortcutBindings get terminalShortcutBindings => _shortcuts;

  @override
  bool get hasTerminalFontSizePreferenceConflict => _hasConflict;

  @override
  List<VaultPreferenceRecord> get terminalFontSizeConflictCandidates =>
      List.unmodifiable(_conflictCandidates);

  @override
  String? get terminalFontSizeConflictRetainedRecordId => _retainedRecordId;

  @override
  bool get terminalFontSizeConflictRepairBusy => false;

  @override
  bool get hasTerminalThemePreferenceConflict => _hasThemeConflict;

  @override
  List<VaultPreferenceRecord> get terminalThemeConflictCandidates =>
      List.unmodifiable(_themeConflictCandidates);

  @override
  String? get terminalThemeConflictRetainedRecordId => _retainedThemeRecordId;

  @override
  bool get hasTerminalShortcutsPreferenceConflict => _hasShortcutConflict;

  @override
  List<VaultPreferenceRecord> get terminalShortcutsConflictCandidates =>
      List.unmodifiable(_shortcutConflictCandidates);

  @override
  String? get terminalShortcutsConflictRetainedRecordId =>
      _retainedShortcutRecordId;

  @override
  bool get terminalShortcutsConflictRepairBusy => false;

  @override
  bool get terminalThemeConflictRepairBusy => false;

  void setFontSizeForTesting(int fontSize) => _fontSize = fontSize;

  void setThemeForTesting(VaultTerminalThemeChoice theme) => _theme = theme;

  void setShortcutBindingsForTesting(TerminalShortcutBindings bindings) {
    _shortcuts = bindings;
    notifyListeners();
  }

  Future<void> receiveRemoteShortcutBindingsForTesting(
    TerminalShortcutBindings bindings,
  ) async {
    await Future<void>.value();
    setShortcutBindingsForTesting(bindings);
  }

  void notifyUnrelatedForTesting() => notifyListeners();

  void switchVaultForTesting({
    required String vaultId,
    required TerminalShortcutBindings shortcuts,
  }) {
    activeVault = VaultDescriptor(
      id: vaultId,
      role: 'owner',
      activeKeyEpoch: '1',
      membershipVersion: '1',
      canWrite: true,
    );
    _shortcuts = shortcuts;
    notifyListeners();
  }

  void setShortcutConflictForTesting({
    required List<VaultPreferenceRecord> candidates,
    required String? retainedRecordId,
  }) {
    _shortcutConflictCandidates
      ..clear()
      ..addAll(candidates);
    _hasShortcutConflict = candidates.isNotEmpty;
    _retainedShortcutRecordId = retainedRecordId;
    if (candidates.isNotEmpty) {
      _shortcuts = candidates.first.terminalShortcutBindings;
    }
  }

  void setThemeConflictForTesting({
    required List<VaultPreferenceRecord> candidates,
    required String? retainedRecordId,
  }) {
    _themeConflictCandidates
      ..clear()
      ..addAll(candidates);
    _hasThemeConflict = candidates.isNotEmpty;
    _retainedThemeRecordId = retainedRecordId;
  }

  void setConflictForTesting({
    required List<VaultPreferenceRecord> candidates,
    required String? retainedRecordId,
  }) {
    _conflictCandidates
      ..clear()
      ..addAll(candidates);
    _hasConflict = candidates.isNotEmpty;
    _retainedRecordId = retainedRecordId;
  }

  @override
  Future<WorkspacePreferenceSaveOutcome> saveTerminalFontSizePreference(
    int fontSize,
  ) async {
    fontSizeSaveCalls++;
    savedFontSize = fontSize;
    if (failFontSizeSave) throw StateError('private response body');
    _fontSize = fontSize;
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  @override
  Future<void> repairTerminalFontSizePreferenceConflict({
    required String retainedRecordId,
  }) async {
    fontSizeRepairCalls++;
    repairedFontSizeRecordId = retainedRecordId;
    if (updateFontSizeDuringRepair) {
      _fontSize = int.parse(
        _conflictCandidates
            .singleWhere((candidate) => candidate.id == retainedRecordId)
            .value,
      );
    }
    _hasConflict = false;
    _retainedRecordId = null;
    _conflictCandidates.clear();
    notifyListeners();
  }

  @override
  Future<WorkspacePreferenceSaveOutcome> saveTerminalThemePreference(
    VaultTerminalThemeChoice theme,
  ) async {
    themeSaveCalls++;
    savedTheme = theme;
    _theme = theme;
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  @override
  Future<void> repairTerminalThemePreferenceConflict({
    required String retainedRecordId,
  }) async {
    themeRepairCalls++;
    repairedThemeRecordId = retainedRecordId;
    _theme = _themeConflictCandidates
        .singleWhere((candidate) => candidate.id == retainedRecordId)
        .terminalThemeValue;
    _hasThemeConflict = false;
    _retainedThemeRecordId = null;
    _themeConflictCandidates.clear();
    notifyListeners();
  }

  @override
  Future<WorkspacePreferenceSaveOutcome> saveTerminalShortcutsPreference(
    TerminalShortcutBindings bindings,
  ) async {
    shortcutSaveCalls++;
    savedShortcuts = bindings;
    _shortcuts = bindings;
    notifyListeners();
    return WorkspacePreferenceSaveOutcome.savedToActiveVault;
  }

  @override
  Future<void> repairTerminalShortcutsPreferenceConflict({
    required String retainedRecordId,
  }) async {
    shortcutRepairCalls++;
    repairedShortcutRecordId = retainedRecordId;
    _shortcuts = _shortcutConflictCandidates
        .singleWhere((candidate) => candidate.id == retainedRecordId)
        .terminalShortcutBindings;
    _hasShortcutConflict = false;
    _retainedShortcutRecordId = null;
    _shortcutConflictCandidates.clear();
    notifyListeners();
  }
}

class _RecordingConnection implements SshConnection {
  _RecordingConnection()
    : portForwards = SshPortForwardManager(
        _FakeSshClient(),
        platform: const _UnsupportedPortForwardPlatform(),
      );

  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );

  @override
  final SshPortForwardManager portForwards;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    await portForwards.closeAll();
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshClient extends Fake implements SSHClient {}

class _UnsupportedPortForwardPlatform implements SshPortForwardPlatform {
  const _UnsupportedPortForwardPlatform();

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => 'Unsupported in this test.';

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => throw UnsupportedError('Unsupported in this terminal font-size test.');
}
