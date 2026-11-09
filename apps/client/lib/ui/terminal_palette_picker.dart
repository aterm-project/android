import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';
import '../l10n/l10n.dart';
import 'app_theme.dart';
import 'terminal_color_theme.dart';
import 'terminal_palette.dart';

/// A small, real rendering of a terminal palette: default text, a prompt,
/// colored `ls`-style output and all 16 ANSI swatches.
class TerminalPalettePreview extends StatelessWidget {
  const TerminalPalettePreview({
    required this.theme,
    this.height = 64,
    this.showSwatches = true,
    super.key,
  });
  final TerminalTheme theme;
  final double height;
  final bool showSwatches;

  static const _mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Cascadia Mono', 'Consolas', 'Menlo', 'monospace'],
    fontSize: 10.5,
    height: 1.25,
  );

  @override
  Widget build(BuildContext context) {
    final ansi = [
      theme.black,
      theme.red,
      theme.green,
      theme.yellow,
      theme.blue,
      theme.magenta,
      theme.cyan,
      theme.white,
      theme.brightBlack,
      theme.brightRed,
      theme.brightGreen,
      theme.brightYellow,
      theme.brightBlue,
      theme.brightMagenta,
      theme.brightCyan,
      theme.brightWhite,
    ];
    return ExcludeSemantics(
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        color: theme.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                style: _mono.copyWith(color: theme.foreground),
                children: [
                  TextSpan(
                    text: 'user@host',
                    style: TextStyle(color: theme.green),
                  ),
                  const TextSpan(text: ':'),
                  TextSpan(text: '~', style: TextStyle(color: theme.blue)),
                  const TextSpan(text: r'$ ls'),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Container(
                      width: 6,
                      height: 11,
                      margin: const EdgeInsets.only(left: 3),
                      color: theme.cursor,
                    ),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
            ),
            Text.rich(
              TextSpan(
                style: _mono.copyWith(color: theme.foreground),
                children: [
                  TextSpan(text: 'src ', style: TextStyle(color: theme.blue)),
                  TextSpan(
                    text: 'run.sh ',
                    style: TextStyle(color: theme.brightGreen),
                  ),
                  TextSpan(text: 'err ', style: TextStyle(color: theme.red)),
                  TextSpan(
                    text: 'warn',
                    style: TextStyle(color: theme.yellow),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
            ),
            if (showSwatches) ...[
              const Spacer(),
              for (final row in [ansi.sublist(0, 8), ansi.sublist(8)])
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      for (final color in row)
                        Expanded(
                          child: Container(
                            height: 5,
                            margin: const EdgeInsets.only(right: 2),
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One selectable palette card with a preview and its name.
class TerminalPaletteTile extends StatelessWidget {
  const TerminalPaletteTile({
    required this.theme,
    required this.name,
    required this.selected,
    required this.onSelected,
    this.subtitle,
    this.width = 172,
    super.key,
  });
  final TerminalTheme theme;
  final String name;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onSelected;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      enabled: onSelected != null,
      label: subtitle == null ? name : '$name, $subtitle',
      onTap: onSelected,
      child: ExcludeSemantics(
        child: SizedBox(
          width: width,
          child: Material(
            color: context.palette.surfaceRaised,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: selected ? colors.primary : context.palette.line,
                width: selected ? 2 : 1,
              ),
            ),
            child: InkWell(
              onTap: onSelected,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TerminalPalettePreview(theme: theme),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 5, 6, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (subtitle case final subtitle?)
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: context.palette.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_circle,
                            size: 16,
                            color: colors.primary,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Settings category holding the UI theme mode, terminal font size, synced
/// terminal theme and device palette gallery (account and local settings).
const settingsThemeSectionId = 'appearance';

/// Settings category holding only the terminal keyboard shortcuts.
const settingsShortcutsSectionId = 'shortcuts';

/// Selector for the Vault-synced theme (the strict two-value schema). Keeps
/// the existing option keys `terminal-theme-option-<value>`.
///
/// A device palette overlay ([TerminalPaletteController]) masks the synced
/// theme, so the selector says so, and explicitly selecting the already saved
/// [persisted] theme clears the overlay at once (there is nothing to save).
/// Saving a different draft clears it in the owning section after the save
/// succeeds, guarded by [TerminalPaletteController.followSyncedIf].
class TerminalSyncedThemeSelector extends StatelessWidget {
  const TerminalSyncedThemeSelector({
    required this.selected,
    required this.onSelected,
    this.persisted,
    this.palettes,
    super.key,
  });
  final VaultTerminalThemeChoice selected;

  /// Null disables selection (read-only vault, busy or conflicted).
  final ValueChanged<VaultTerminalThemeChoice>? onSelected;

  /// The saved synced theme; null when unknown (no overlay handling).
  final VaultTerminalThemeChoice? persisted;
  final TerminalPaletteController? palettes;

  @override
  Widget build(BuildContext context) {
    final controller = palettes ?? TerminalPaletteController.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final overlay = persisted == null ? null : controller.preset;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final choice in VaultTerminalThemeChoice.values)
                  TerminalPaletteTile(
                    key: ValueKey('terminal-theme-option-${choice.value}'),
                    theme: buildTerminalColorTheme(choice),
                    name: choice.label,
                    selected: choice == selected,
                    onSelected: onSelected == null
                        ? null
                        : () {
                            if (choice == persisted) controller.followSynced();
                            onSelected!(choice);
                          },
                  ),
              ],
            ),
            if (overlay != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    context.l10n.settingsThemeOverlayActive(overlay.name),
                    key: const ValueKey('terminal_theme_overlay_notice'),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: context.palette.orange,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

enum _PaletteFilter { all, dark, light }

/// Device-local palette gallery: search, dark/light filter and live previews
/// of all presets plus "follow the synced theme". Selection applies at once
/// to every terminal on this device and persists across launches.
class TerminalPaletteGallery extends StatefulWidget {
  const TerminalPaletteGallery({
    required this.synced,
    this.controller,
    super.key,
  });

  /// The currently synced theme, previewed by the "follow synced" tile.
  final VaultTerminalThemeChoice synced;
  final TerminalPaletteController? controller;

  @override
  State<TerminalPaletteGallery> createState() => _TerminalPaletteGalleryState();
}

class _TerminalPaletteGalleryState extends State<TerminalPaletteGallery> {
  final _query = TextEditingController();
  _PaletteFilter _filter = _PaletteFilter.all;

  TerminalPaletteController get _palettes =>
      widget.controller ?? TerminalPaletteController.instance;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matches(TerminalPaletteSpec spec) {
    final query = _query.text.trim().toLowerCase();
    if (query.isNotEmpty && !spec.name.toLowerCase().contains(query)) {
      return false;
    }
    return switch (_filter) {
      _PaletteFilter.all => true,
      _PaletteFilter.dark => spec.isDark,
      _PaletteFilter.light => !spec.isDark,
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _palettes,
    builder: (context, _) {
      final l10n = context.l10n;
      final active = _palettes.preset;
      final presets = terminalPalettePresets.values
          .where(_matches)
          .toList(growable: false);
      final showSynced = _query.text.trim().isEmpty;
      return Column(
        key: const ValueKey('terminal_palette_gallery'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.r7UiPaletteGalleryTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.r7UiPaletteGalleryDescription,
            style: TextStyle(
              color: context.palette.muted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          // Large live preview of what terminals on this device use now.
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: TerminalPalettePreview(
              key: const ValueKey('terminal_palette_active_preview'),
              theme: _palettes.resolve(widget.synced),
              height: 72,
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            liveRegion: true,
            child: Text(
              active == null
                  ? l10n.r7UiPaletteFollowingSynced
                  : l10n.r7UiPaletteActiveOverride(active.name),
              key: const ValueKey('terminal_palette_status'),
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
          ),
          if (_palettes.writeFailed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.r7UiPaletteSaveFailed,
                key: const ValueKey('terminal_palette_save_failed'),
                style: TextStyle(fontSize: 12, color: context.palette.orange),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  key: const ValueKey('terminal_palette_search'),
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.r7UiPaletteSearchHint,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              SegmentedButton<_PaletteFilter>(
                key: const ValueKey('terminal_palette_filter'),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: [
                  ButtonSegment(
                    value: _PaletteFilter.all,
                    label: Text(l10n.r7UiPaletteFilterAll),
                  ),
                  ButtonSegment(
                    value: _PaletteFilter.dark,
                    icon: const Icon(Icons.dark_mode_outlined, size: 16),
                    label: Text(l10n.r7UiPaletteFilterDark),
                  ),
                  ButtonSegment(
                    value: _PaletteFilter.light,
                    icon: const Icon(Icons.light_mode_outlined, size: 16),
                    label: Text(l10n.r7UiPaletteFilterLight),
                  ),
                ],
                selected: {_filter},
                onSelectionChanged: (value) =>
                    setState(() => _filter = value.single),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!showSynced && presets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                l10n.r7UiPaletteNoMatches,
                key: const ValueKey('terminal_palette_no_matches'),
                style: TextStyle(color: context.palette.muted),
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (showSynced)
                  TerminalPaletteTile(
                    key: const ValueKey('terminal_palette_option_synced'),
                    theme: buildTerminalColorTheme(widget.synced),
                    name: l10n.r7UiPaletteFollowSynced(widget.synced.label),
                    selected: active == null,
                    onSelected: () => unawaited(_palettes.select(null)),
                  ),
                for (final spec in presets)
                  TerminalPaletteTile(
                    key: ValueKey('terminal_palette_option_${spec.id}'),
                    theme: _palettes.presetTheme(spec),
                    name: spec.name,
                    selected: active?.id == spec.id,
                    onSelected: () => unawaited(_palettes.select(spec.id)),
                  ),
              ],
            ),
        ],
      );
    },
  );
}
