import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/vault_preference.dart';
import '../l10n/l10n.dart';
import 'app_theme.dart';

/// Localized name of a semantic terminal shortcut action.
String terminalShortcutActionLabel(
  BuildContext context,
  TerminalShortcutAction action,
) => switch (action) {
  TerminalShortcutAction.search => context.l10n.searchTerminalHistory,
  TerminalShortcutAction.searchNext => context.l10n.nextMatch2,
  TerminalShortcutAction.searchPrevious => context.l10n.previousMatch2,
  TerminalShortcutAction.disconnect => context.l10n.disconnectCurrentTerminal,
};

bool _usesMetaForMod(TargetPlatform platform) =>
    platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;

/// Converts a recorded key-down into the stored chord syntax using the same
/// rules as the terminal dispatcher (`mod` = Command on Apple platforms,
/// Control elsewhere; key = lower-cased logical key label). Returns null for
/// modifier-only presses. The result is not validated here.
@visibleForTesting
String? terminalShortcutChordFromKey({
  required LogicalKeyboardKey key,
  required bool controlPressed,
  required bool metaPressed,
  required bool altPressed,
  required bool shiftPressed,
  required TargetPlatform platform,
}) {
  final modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
  };
  if (modifiers.contains(key)) return null;
  final label = key.keyLabel.toLowerCase();
  if (label.isEmpty) return null;
  final mod = _usesMetaForMod(platform) ? metaPressed : controlPressed;
  return [
    if (mod) 'mod',
    if (altPressed) 'alt',
    if (shiftPressed) 'shift',
    label,
  ].join('+');
}

/// Visual keycaps for a chord such as `mod+alt+shift+f`.
class TerminalShortcutKeycaps extends StatelessWidget {
  const TerminalShortcutKeycaps({required this.chord, super.key});
  final String chord;

  static String capLabel(String token, TargetPlatform platform) {
    final apple = _usesMetaForMod(platform);
    return switch (token) {
      'mod' => apple ? '⌘' : 'Ctrl',
      'alt' => apple ? '⌥' : 'Alt',
      'shift' => apple ? '⇧' : 'Shift',
      _ => token.toUpperCase(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final tokens = chord
        .split('+')
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    return Semantics(
      label: tokens.map((token) => capLabel(token, platform)).join(' + '),
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 3,
          runSpacing: 3,
          children: [
            for (final token in tokens)
              Container(
                constraints: const BoxConstraints(minWidth: 22),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSoft,
                  borderRadius: BorderRadius.circular(5),
                  border: const Border(
                    top: BorderSide(color: AppColors.line),
                    left: BorderSide(color: AppColors.line),
                    right: BorderSide(color: AppColors.line),
                    bottom: BorderSide(color: AppColors.line, width: 2),
                  ),
                ),
                child: Text(
                  capLabel(token, platform),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _RowProblem { invalid, duplicate }

/// Shortcut list editor: one row per semantic action with keycaps, a
/// record-a-combination button, per-row reset and inline validation. It only
/// edits the caller's text controllers (same field keys as before); saving,
/// conflict repair and Vault/profile persistence stay with the caller, and
/// every chord is still validated by [TerminalShortcutBindings].
class TerminalShortcutEditor extends StatefulWidget {
  const TerminalShortcutEditor({
    required this.controllers,
    required this.fieldKey,
    required this.enabled,
    required this.onChanged,
    super.key,
  });
  final Map<TerminalShortcutAction, TextEditingController> controllers;

  /// Key for the action's text field (keeps existing widget-test keys).
  final Key Function(TerminalShortcutAction action) fieldKey;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  State<TerminalShortcutEditor> createState() => _TerminalShortcutEditorState();
}

class _TerminalShortcutEditorState extends State<TerminalShortcutEditor> {
  TerminalShortcutAction? _recording;
  final _recordFocus = FocusNode(debugLabel: 'terminal-shortcut-recorder');

  /// Keys pressed while recording; their key-ups are consumed too, so no part
  /// of the recorded combination reaches app or terminal shortcuts.
  final _pressed = <PhysicalKeyboardKey>{};

  @override
  void initState() {
    super.initState();
    _recordFocus.addListener(_onRecordFocus);
  }

  @override
  void didUpdateWidget(covariant TerminalShortcutEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _recording != null) _recording = null;
  }

  @override
  void dispose() {
    _recordFocus
      ..removeListener(_onRecordFocus)
      ..dispose();
    super.dispose();
  }

  void _onRecordFocus() {
    if (_recordFocus.hasFocus) return;
    _pressed.clear();
    if (_recording != null && mounted) setState(() => _recording = null);
  }

  Map<TerminalShortcutAction, _RowProblem> _problems() {
    final problems = <TerminalShortcutAction, _RowProblem>{};
    final owners = <String, List<TerminalShortcutAction>>{};
    for (final action in TerminalShortcutAction.values) {
      try {
        final chord = TerminalShortcutBindings.normalizeChord(
          widget.controllers[action]!.text,
        );
        (owners[chord] ??= []).add(action);
      } on FormatException {
        problems[action] = _RowProblem.invalid;
      }
    }
    for (final actions in owners.values) {
      if (actions.length < 2) continue;
      for (final action in actions) {
        problems[action] = _RowProblem.duplicate;
      }
    }
    return problems;
  }

  void _set(TerminalShortcutAction action, String chord) {
    widget.controllers[action]!.text = chord;
    widget.onChanged();
  }

  void _startRecording(TerminalShortcutAction action) {
    setState(() => _recording = action);
    _recordFocus.requestFocus();
  }

  KeyEventResult _record(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent && _pressed.remove(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    final action = _recording;
    if (action == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    _pressed.add(event.physicalKey);
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed) {
      setState(() => _recording = null);
      return KeyEventResult.handled;
    }
    final chord = terminalShortcutChordFromKey(
      key: event.logicalKey,
      controlPressed: keyboard.isControlPressed,
      metaPressed: keyboard.isMetaPressed,
      altPressed: keyboard.isAltPressed,
      shiftPressed: keyboard.isShiftPressed,
      platform: Theme.of(context).platform,
    );
    // Modifier-only presses keep waiting; everything is consumed so the
    // recorded combination never reaches app or terminal shortcuts.
    if (chord == null) return KeyEventResult.handled;
    // Focus stays on the recorder until the pressed keys are released.
    setState(() => _recording = null);
    _set(action, chord);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final problems = _problems();
    return Focus(
      focusNode: _recordFocus,
      onKeyEvent: _record,
      child: Column(
        key: const ValueKey('terminal_shortcut_editor'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final action in TerminalShortcutAction.values)
            _row(context, action, problems[action]),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    TerminalShortcutAction action,
    _RowProblem? problem,
  ) {
    final l10n = context.l10n;
    final label = terminalShortcutActionLabel(context, action);
    final controller = widget.controllers[action]!;
    final recording = _recording == action;
    final fallback = TerminalShortcutBindings.defaults.chordFor(action);
    final field = TextField(
      key: widget.fieldKey(action),
      controller: controller,
      enabled: widget.enabled,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.none,
      onChanged: (_) => widget.onChanged(),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
      decoration: InputDecoration(
        labelText: label,
        hintText: 'mod+alt+shift+f',
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        errorText: switch (problem) {
          _RowProblem.invalid => l10n.r7UiShortcutInvalid,
          _RowProblem.duplicate => l10n.r7UiShortcutDuplicate,
          null => null,
        },
      ),
    );
    final caps = recording
        ? Container(
            key: ValueKey('terminal_shortcut_recording_${action.name}'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.accentContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Semantics(
              liveRegion: true,
              child: Text(
                l10n.r7UiShortcutRecording,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.onAccentContainer,
                ),
              ),
            ),
          )
        : problem == _RowProblem.invalid
        ? const Icon(Icons.error_outline, size: 18, color: AppColors.orange)
        : TerminalShortcutKeycaps(
            key: ValueKey('terminal_shortcut_keycaps_${action.name}'),
            chord: TerminalShortcutBindings.normalizeChord(controller.text),
          );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: ValueKey('terminal_shortcut_record_${action.name}'),
          tooltip: l10n.r7UiShortcutRecordTooltip(label),
          visualDensity: VisualDensity.compact,
          isSelected: recording,
          onPressed: widget.enabled
              ? () => recording
                    ? setState(() => _recording = null)
                    : _startRecording(action)
              : null,
          icon: const Icon(Icons.keyboard_outlined, size: 18),
          selectedIcon: const Icon(Icons.radio_button_checked, size: 18),
        ),
        IconButton(
          key: ValueKey('terminal_shortcut_reset_${action.name}'),
          tooltip: l10n.r7UiShortcutReset(label),
          visualDensity: VisualDensity.compact,
          onPressed: widget.enabled && controller.text != fallback
              ? () => _set(action, fallback)
              : null,
          icon: const Icon(Icons.undo, size: 18),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 560) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field),
                const SizedBox(width: 10),
                SizedBox(
                  width: 168,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Align(alignment: Alignment.centerLeft, child: caps),
                  ),
                ),
                buttons,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field,
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: caps),
                  ),
                  buttons,
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
