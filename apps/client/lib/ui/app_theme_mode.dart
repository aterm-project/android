import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../storage/app_theme_store.dart';
import 'app_theme.dart';

/// Device-local UI theme choice. [code] is the stable persisted value; never
/// rename it. The historic dark theme stays the default until the user picks
/// another option explicitly.
enum AppThemePreference {
  dark('dark', ThemeMode.dark),
  light('light', ThemeMode.light),
  system('system', ThemeMode.system);

  const AppThemePreference(this.code, this.mode);
  final String code;
  final ThemeMode mode;

  String label(AppLocalizations l10n) => switch (this) {
    dark => l10n.themeOptionDark,
    light => l10n.themeOptionLight,
    system => l10n.themeOptionSystem,
  };
}

const defaultAppThemePreference = AppThemePreference.dark;

AppThemePreference parseAppThemePreference(String? value) {
  final normalized = value?.trim().toLowerCase();
  for (final preference in AppThemePreference.values) {
    if (preference.code == normalized) return preference;
  }
  return defaultAppThemePreference;
}

/// Owns the persisted UI theme preference. Changing it only swaps the
/// [ThemeData] handed to the app roots, so sessions, panes and form drafts keep
/// their State.
class AppThemeController extends ChangeNotifier {
  AppThemeController();

  static AppThemeController? _instance;

  /// Process-wide controller used by the app roots.
  static AppThemeController get instance => _instance ??= AppThemeController();

  @visibleForTesting
  static set debugInstance(AppThemeController? controller) =>
      _instance = controller;

  AppThemeStore? _store;
  AppThemePreference _preference = defaultAppThemePreference;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void> _writeChain = Future<void>.value();
  bool _disposed = false;

  AppThemePreference get preference => _preference;
  ThemeMode get themeMode => _preference.mode;

  /// Whether the last attempt to persist a choice failed. The choice still
  /// applies for this run.
  bool get writeFailed => _writeFailed;

  /// Reads the stored preference. Missing, invalid or failing reads keep the
  /// dark default.
  Future<void> load(AppThemeStore store) async {
    _store = store;
    AppThemePreference next;
    try {
      final stored = await store.read().timeout(const Duration(seconds: 2));
      next = parseAppThemePreference(stored);
    } on Object {
      next = defaultAppThemePreference;
    }
    if (next != _preference) {
      _preference = next;
      notifyListeners();
    }
  }

  /// Applies [preference] immediately and persists it as a device preference.
  /// Writes are serialized and coalesced; only the latest choice may update
  /// [writeFailed].
  Future<void> setPreference(AppThemePreference preference) {
    if (preference != _preference) {
      _preference = preference;
      notifyListeners();
    }
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    final code = preference.code;
    final next = _writeChain.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        await store.write(code);
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      if (_writeFailed != failed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
    _writeChain = next;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Unawaited-safe helper for persisting a theme choice from UI callbacks.
void selectAppTheme(
  AppThemePreference preference, {
  AppThemeController? using,
}) =>
    unawaited((using ?? AppThemeController.instance).setPreference(preference));

/// Rebuilds an app root (normally a `MaterialApp`) with the current
/// [ThemeMode]. The root widget is updated in place, never recreated.
class AppThemeModeBuilder extends StatelessWidget {
  const AppThemeModeBuilder({
    required this.builder,
    this.controller,
    super.key,
  });

  final Widget Function(BuildContext context, ThemeMode mode) builder;
  final AppThemeController? controller;

  @override
  Widget build(BuildContext context) {
    final themes = controller ?? AppThemeController.instance;
    return ListenableBuilder(
      listenable: themes,
      builder: (context, _) => builder(context, themes.themeMode),
    );
  }
}

/// Appearance setting: Dark / Light / Match system. Applies immediately.
class AppThemeSettings extends StatelessWidget {
  const AppThemeSettings({this.controller, this.dense = false, super.key});

  final AppThemeController? controller;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final themes = controller ?? AppThemeController.instance;
    return ListenableBuilder(
      listenable: themes,
      builder: (context, _) {
        final l10n = context.l10n;
        final palette = context.palette;
        final current = themes.preference;
        final systemDark =
            MediaQuery.maybePlatformBrightnessOf(context) != Brightness.light;
        final resolved = systemDark
            ? l10n.themeOptionDark
            : l10n.themeOptionLight;
        return Column(
          key: const ValueKey('app_theme_settings'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, size: 20, color: palette.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.themeSettingTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (!dense) ...[
              const SizedBox(height: 6),
              Text(
                l10n.themeSettingDescription,
                style: TextStyle(color: palette.muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 8),
            Semantics(
              container: true,
              label: l10n.themeSettingTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final preference in AppThemePreference.values)
                    _ThemeOption(
                      preference: preference,
                      selected: preference == current,
                      label: preference.label(l10n),
                      subtitle: preference == AppThemePreference.system
                          ? l10n.themeSettingSystemResolved(resolved)
                          : null,
                      onSelected: () =>
                          selectAppTheme(preference, using: themes),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              themes.writeFailed
                  ? l10n.themeSettingSaveFailed
                  : l10n.languageSettingDevicePreference,
              key: const ValueKey('app_theme_storage_note'),
              style: TextStyle(
                color: themes.writeFailed ? palette.orange : palette.muted,
                fontSize: 12,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.preference,
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.onSelected,
  });

  final AppThemePreference preference;
  final bool selected;
  final String label;
  final String? subtitle;
  final VoidCallback onSelected;

  IconData get _icon => switch (preference) {
    AppThemePreference.dark => Icons.dark_mode_outlined,
    AppThemePreference.light => Icons.light_mode_outlined,
    AppThemePreference.system => Icons.brightness_auto_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: ListTile(
        key: ValueKey('app_theme_${preference.code}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selected: selected,
        selectedColor: palette.accentText,
        selectedTileColor: palette.accent.withValues(alpha: 0.12),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? palette.accentText : palette.muted,
          size: 20,
        ),
        title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Icon(_icon, size: 18, color: palette.muted),
        onTap: onSelected,
      ),
    );
  }
}
