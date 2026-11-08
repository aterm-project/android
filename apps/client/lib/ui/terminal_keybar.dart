import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';

@immutable
class TerminalKeyModifiers {
  const TerminalKeyModifiers({this.ctrl = false, this.alt = false});

  final bool ctrl;
  final bool alt;
}

/// Terminal keys that keep the terminal's input connection and selection alive.
///
/// Ctrl and Alt are explicit locks: tap again, or tap Reset, to release them.
/// The handler is shared by hardware keys, IME-committed ASCII and these buttons.
/// Unicode composition and clipboard text bypass key mapping entirely.
class TerminalKeybar extends StatefulWidget {
  const TerminalKeybar({
    super.key,
    required this.terminal,
    this.focusNode,
    this.readOnly = false,
    this.availablePaneHeight,
    this.onModifiersChanged,
  });

  final Terminal terminal;
  final FocusNode? focusNode;
  final bool readOnly;

  /// Bounded height of the containing terminal pane, including this keybar.
  /// Short panes keep expanded keys in one horizontal strip so the terminal
  /// retains room for input/output instead of competing with three key rows.
  final double? availablePaneHeight;
  final ValueChanged<TerminalKeyModifiers>? onModifiersChanged;

  @override
  State<TerminalKeybar> createState() => _TerminalKeybarState();
}

class _TerminalKeybarState extends State<TerminalKeybar> {
  _ModifierInputHandler? _handler;
  bool get _visible =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.windows;
  bool _ctrl = false;
  bool _alt = false;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    if (!_visible) return;
    _handler = _ModifierInputHandler(widget.terminal.inputHandler, () {
      return TerminalKeyModifiers(ctrl: _ctrl, alt: _alt);
    });
    widget.terminal.inputHandler = _handler!;
  }

  void _detach(Terminal terminal) {
    // Another owner may replace the handler while the view is mounted.
    if (_handler != null && identical(terminal.inputHandler, _handler)) {
      terminal.inputHandler = _handler!.delegate;
    }
  }

  @override
  void didUpdateWidget(covariant TerminalKeybar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.terminal, widget.terminal)) {
      _detach(oldWidget.terminal);
      _setModifiers(ctrl: false, alt: false, deferNotification: true);
      _attach();
    } else if (widget.readOnly && !oldWidget.readOnly) {
      _setModifiers(ctrl: false, alt: false, deferNotification: true);
    }
  }

  @override
  void dispose() {
    _detach(widget.terminal);
    super.dispose();
  }

  void _setModifiers({
    required bool ctrl,
    required bool alt,
    bool deferNotification = false,
  }) {
    if (_ctrl == ctrl && _alt == alt) return;
    _ctrl = ctrl;
    _alt = alt;
    void notify() {
      if (!mounted || _ctrl != ctrl || _alt != alt) return;
      widget.onModifiersChanged?.call(
        TerminalKeyModifiers(ctrl: ctrl, alt: alt),
      );
    }

    if (deferNotification) {
      // Widget updates run during the parent's build; callbacks may setState there.
      WidgetsBinding.instance.addPostFrameCallback((_) => notify());
    } else {
      notify();
    }
  }

  void _focusTerminal() => widget.focusNode?.requestFocus();

  void _send(TerminalKey key) {
    if (widget.readOnly) return;
    widget.terminal.keyInput(key);
    _focusTerminal();
  }

  Future<void> _paste() async {
    if (widget.readOnly) return;
    final terminal = widget.terminal;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || widget.readOnly || !identical(terminal, widget.terminal)) {
      return;
    }
    final text = clipboard?.text;
    if (text != null) terminal.paste(text);
    _focusTerminal();
  }

  Widget _button(
    String label,
    String tooltip,
    VoidCallback? onPressed, {
    bool selected = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(40, 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          backgroundColor: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          foregroundColor: selected
              ? Theme.of(context).colorScheme.onSecondaryContainer
              : null,
        ),
        onPressed: onPressed,
        child: Semantics(toggled: selected, child: Text(label)),
      ),
    );
  }

  Widget _key(String label, TerminalKey key, [String? tooltip]) => _button(
    label,
    tooltip ?? label,
    widget.readOnly ? null : () => _send(key),
  );

  Widget _row(List<Widget> children) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: children),
  );

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final primaryKeys = <Widget>[
      _key('Esc', TerminalKey.escape),
      _button(
        'Ctrl',
        context.l10n.lockControlModifier,
        widget.readOnly
            ? null
            : () {
                setState(() => _setModifiers(ctrl: !_ctrl, alt: _alt));
                _focusTerminal();
              },
        selected: _ctrl,
      ),
      _button(
        'Alt',
        context.l10n.lockAltModifier,
        widget.readOnly
            ? null
            : () {
                setState(() => _setModifiers(ctrl: _ctrl, alt: !_alt));
                _focusTerminal();
              },
        selected: _alt,
      ),
      _key('Tab', TerminalKey.tab),
      _key('←', TerminalKey.arrowLeft, context.l10n.leftArrow),
      _key('↓', TerminalKey.arrowDown, context.l10n.downArrow),
      _key('↑', TerminalKey.arrowUp, context.l10n.upArrow),
      _key('→', TerminalKey.arrowRight, context.l10n.rightArrow),
      _button(
        context.l10n.keybarPaste,
        context.l10n.pasteClipboard,
        widget.readOnly ? null : _paste,
      ),
      _button(
        context.l10n.keybarReset,
        context.l10n.releaseControlAndAlt,
        _ctrl || _alt
            ? () {
                setState(() => _setModifiers(ctrl: false, alt: false));
                _focusTerminal();
              }
            : null,
      ),
      _button(
        _expanded ? context.l10n.keybarLess : context.l10n.keybarMore,
        context.l10n.moreTerminalKeys,
        () {
          setState(() => _expanded = !_expanded);
          _focusTerminal();
        },
      ),
    ];
    final navigationKeys = <Widget>[
      _key('Home', TerminalKey.home),
      _key('End', TerminalKey.end),
      _key('PgUp', TerminalKey.pageUp),
      _key('PgDn', TerminalKey.pageDown),
      _key('Ins', TerminalKey.insert),
      _key('Del', TerminalKey.delete),
      _key('⌫', TerminalKey.backspace, 'Backspace'),
      _key('Enter', TerminalKey.enter),
    ];
    final functionKeys = <Widget>[
      for (var index = 0; index < 12; index++)
        _key('F${index + 1}', TerminalKey.values[TerminalKey.f1.index + index]),
    ];
    // Three Material tap rows need at least 144 px at normal text size.
    // Reserve two more rows for the terminal itself. Larger accessibility
    // text selects the compact strip sooner, without shrinking tap targets.
    final textScale = MediaQuery.textScalerOf(context).scale(20) / 20;
    final rowExtent =
        kMinInteractiveDimension * (textScale > 1 ? textScale : 1);
    final compact =
        widget.availablePaneHeight != null &&
        widget.availablePaneHeight! < rowExtent * 5;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ExcludeFocus(
        // Pointer/semantics activation must not take focus from the IME.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _row([
              ...primaryKeys,
              if (_expanded && compact) ...navigationKeys,
              if (_expanded && compact) ...functionKeys,
            ]),
            if (_expanded && !compact) ...[
              _row(navigationKeys),
              _row(functionKeys),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModifierInputHandler implements TerminalInputHandler {
  _ModifierInputHandler(this.delegate, this.modifiers);

  final TerminalInputHandler? delegate;
  final TerminalKeyModifiers Function() modifiers;

  @override
  String? call(TerminalKeyboardEvent event) {
    final locked = modifiers();
    return delegate?.call(
      event.copyWith(
        ctrl: event.ctrl || locked.ctrl,
        alt: event.alt || locked.alt,
      ),
    );
  }
}
