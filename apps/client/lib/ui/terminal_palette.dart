import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';
import '../storage/terminal_palette_store.dart';
import 'terminal_color_theme.dart';
import 'terminal_palette_presets.dart';
import 'terminal_palette_spec.dart';

export 'terminal_palette_spec.dart' show TerminalPaletteSpec;

/// All device-local preset palettes, keyed by stable id.
final Map<String, TerminalPaletteSpec> terminalPalettePresets = {
  for (final spec in terminalPalettePresetSpecs) spec.id: spec,
};

/// Device-local palette overlay on top of the Vault-synced terminal theme.
///
/// * No preset selected (the default): terminals use the synced
///   [VaultTerminalThemeChoice] exactly as before (default Atermius Dark with
///   grass-green text).
/// * A preset selected: every terminal surface on this device (local profile,
///   cloud workspace and separate terminal windows, which read the same store
///   at startup) uses it. The synced Vault record is never modified, so older
///   clients that strictly accept only `atermius-dark`/`light` keep working.
class TerminalPaletteController extends ChangeNotifier {
  TerminalPaletteController();

  static TerminalPaletteController? _instance;

  /// Process-wide controller used by the app roots.
  static TerminalPaletteController get instance =>
      _instance ??= TerminalPaletteController();

  @visibleForTesting
  static set debugInstance(TerminalPaletteController? controller) =>
      _instance = controller;

  /// The controller of the enclosing [TerminalPaletteScope], else [instance].
  /// Does not register a rebuild dependency (for callbacks).
  static TerminalPaletteController of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TerminalPaletteScope>()?.notifier ??
      instance;

  TerminalPaletteStore? _store;
  String? _presetId;
  int _selectionGeneration = 0;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void> _writeChain = Future<void>.value();
  bool _disposed = false;
  final Map<String, TerminalTheme> _themes = {};

  /// The selected preset id, or null to follow the synced theme.
  String? get presetId => _presetId;
  TerminalPaletteSpec? get preset =>
      _presetId == null ? null : terminalPalettePresets[_presetId];

  /// Whether persisting the latest selection failed; it still applies now.
  bool get writeFailed => _writeFailed;

  /// Increases with every explicit [select] (including re-selecting the same
  /// preset) and every [load]. Capture it before an awaited synced-theme save
  /// and pass it to [followSyncedIf], so a device choice made meanwhile is
  /// never cleared, even if it equals the earlier one.
  int get selectionGeneration => _selectionGeneration;

  /// Reads the stored overlay. Unknown ids (e.g. written by a newer version)
  /// and read failures fall back to the synced theme without rewriting the
  /// stored value.
  Future<void> load(TerminalPaletteStore store) async {
    _store = store;
    String? id;
    try {
      id = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      id = null;
    }
    final next = terminalPalettePresets.containsKey(id) ? id : null;
    _selectionGeneration++;
    if (next != _presetId) {
      _presetId = next;
      notifyListeners();
    }
  }

  /// Applies [id] immediately (null follows the synced theme) and persists it.
  /// Writes are serialized and coalesced like the display language, so the
  /// last selection always wins on disk.
  Future<void> select(String? id) {
    if (id != null && !terminalPalettePresets.containsKey(id)) {
      throw ArgumentError.value(id, 'id', 'Unknown terminal palette');
    }
    _selectionGeneration++;
    if (id != _presetId) {
      _presetId = id;
      notifyListeners();
    }
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    final next = _writeChain.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        await store.write(id);
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      if (failed != _writeFailed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
    _writeChain = next;
    return next;
  }

  /// Makes the synced (Vault/profile) terminal theme visible on this device
  /// by clearing an active device preset. For an explicit synced-theme choice
  /// that needs no save. Returns whether an overlay was cleared.
  bool followSynced() {
    if (_disposed || _presetId == null) return false;
    unawaited(select(null));
    return true;
  }

  /// Like [followSynced], but only while no device palette selection happened
  /// since [generation] was read from [selectionGeneration]. Used after a
  /// successful awaited synced-theme save, so a newer user choice (including
  /// re-selecting the same preset) is never cleared.
  bool followSyncedIf(int generation) {
    if (generation != _selectionGeneration) return false;
    return followSynced();
  }

  /// Theme of a preset (cached so terminal views keep a stable instance).
  TerminalTheme presetTheme(TerminalPaletteSpec spec) =>
      _themes[spec.id] ??= spec.toTheme();

  /// Effective terminal theme for a surface whose synced choice is [synced].
  TerminalTheme resolve(VaultTerminalThemeChoice synced) {
    final spec = preset;
    return spec == null ? buildTerminalColorTheme(synced) : presetTheme(spec);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Rebuilds terminal surfaces when the device palette changes. Installed by
/// [WindowsWindowChrome] in every app root's `MaterialApp.builder`.
class TerminalPaletteScope extends InheritedNotifier<TerminalPaletteController> {
  const TerminalPaletteScope({
    super.key,
    required TerminalPaletteController super.notifier,
    required super.child,
  });
}

/// The terminal theme every terminal surface should use: the device palette
/// overlay when one is selected, otherwise the synced [synced] choice.
TerminalTheme terminalColorThemeOf(
  BuildContext context,
  VaultTerminalThemeChoice synced,
) {
  final controller =
      context
          .dependOnInheritedWidgetOfExactType<TerminalPaletteScope>()
          ?.notifier ??
      TerminalPaletteController.instance;
  return controller.resolve(synced);
}

/// Like [terminalColorThemeOf] without registering a rebuild dependency; for
/// callbacks and helpers outside `build` (e.g. search highlight colors).
TerminalTheme readTerminalColorTheme(
  BuildContext context,
  VaultTerminalThemeChoice synced,
) {
  final controller =
      context.getInheritedWidgetOfExactType<TerminalPaletteScope>()?.notifier ??
      TerminalPaletteController.instance;
  return controller.resolve(synced);
}
