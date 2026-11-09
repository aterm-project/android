import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

enum _Latch { off, armed, locked }

/// A pane-local IME client. The dock always stays on an edge of the pane;
/// keyboard events go to its session, never through the SSH terminal input.
class DesktopMobileControls extends StatefulWidget {
  const DesktopMobileControls({
    super.key,
    required this.focus,
    required this.onActivate,
    required this.send,
    required this.connected,
    required this.trackpad,
    required this.onTogglePointer,
    required this.onKeyboardChanged,
    required this.keybarHeight,
  });
  final FocusNode focus;
  final VoidCallback onActivate;
  final void Function(List<Object>) send;
  final bool connected, trackpad;
  final VoidCallback onTogglePointer;
  final ValueChanged<bool> onKeyboardChanged;
  final double keybarHeight;
  @override
  State<DesktopMobileControls> createState() => DesktopMobileControlsState();
}

class DesktopMobileControlsState extends State<DesktopMobileControls>
    with TextInputClient, WidgetsBindingObserver {
  static const _seed = TextEditingValue(
    text: '\u200b',
    selection: TextSelection.collapsed(offset: 1),
  );
  TextInputConnection? _connection;
  TextEditingValue _value = _seed;
  bool _open = false, _left = false, _imeSeen = false;
  ui.FlutterView? _view;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
  }

  double _heightFraction = .3;
  int? _lastModifier;
  Timer? _doubleTap;
  final _modifiers = <int, _Latch>{
    0xffe3: _Latch.off,
    0xffe9: _Latch.off,
    0xffe1: _Latch.off,
    0xffeb: _Latch.off,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(DesktopMobileControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus.removeListener(_focusChanged);
      widget.focus.addListener(_focusChanged);
      releaseInput();
    }
    if (!widget.connected && oldWidget.connected) {
      final wasOpen = _open;
      releaseInput(notify: false);
      if (wasOpen)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onKeyboardChanged(false);
        });
    }
  }

  void _focusChanged() {
    if (!widget.focus.hasFocus) releaseInput();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) releaseInput();
  }

  @override
  void didChangeMetrics() {
    if (!_open || !mounted) return;
    final visible = (_view?.viewInsets.bottom ?? 0) > 0;
    if (_imeSeen && !visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _open) releaseInput();
      });
    }
    if (visible) _imeSeen = true;
  }

  void _setOpen(bool value) {
    if (_open == value) return;
    setState(() => _open = value);
    widget.onKeyboardChanged(value);
  }

  void _toggleKeyboard() {
    if (_open) {
      releaseInput();
      return;
    }
    if (!widget.connected) return;
    widget.onActivate();
    _value = _seed;
    _imeSeen = false;
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        viewId: View.of(context).viewId,
      ),
    );
    _connection!.setEditingState(_value);
    _connection!.show();
    _setOpen(true);
  }

  void _key(int sym, bool down) {
    if (widget.connected) widget.send(['key', sym, down ? 1 : 0]);
  }

  void stroke(int sym) {
    if (!widget.connected) return;
    _key(sym, true);
    _key(sym, false);
    consumeModifiers();
  }

  void consumeModifiers() {
    _doubleTap?.cancel();
    _lastModifier = null;
    var changed = false;
    for (final sym in _modifiers.keys) {
      if (_modifiers[sym] == _Latch.armed) {
        _key(sym, false);
        _modifiers[sym] = _Latch.off;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _modifier(int sym) {
    final previous = _modifiers[sym]!;
    final next = previous == _Latch.off
        ? _Latch.armed
        : previous == _Latch.armed && _lastModifier == sym
        ? _Latch.locked
        : _Latch.off;
    _doubleTap?.cancel();
    _lastModifier = next == _Latch.armed ? sym : null;
    if (_lastModifier != null) {
      _doubleTap = Timer(kDoubleTapTimeout, () => _lastModifier = null);
    }
    if (previous == _Latch.off) _key(sym, true);
    if (next == _Latch.off) _key(sym, false);
    setState(() => _modifiers[sym] = next);
  }

  /// Also called before replacing or closing the owning DesktopSession.
  void releaseInput({bool notify = true}) {
    _doubleTap?.cancel();
    _lastModifier = null;
    for (final sym in _modifiers.keys) {
      if (_modifiers[sym] != _Latch.off) _key(sym, false);
      _modifiers[sym] = _Latch.off;
    }
    _connection?.close();
    _connection = null;
    _value = _seed;
    _imeSeen = false;
    if (!notify) _open = false;
    if (notify && mounted) {
      if (_open) {
        _setOpen(false);
      } else {
        setState(() {});
      }
    }
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;
  @override
  AutofillScope? get currentAutofillScope => null;
  @override
  void updateEditingValue(TextEditingValue value) {
    if (!_open || !widget.connected || !widget.focus.hasFocus) return;
    _value = value;
    // Preedit belongs to the IME. Send only its final committed text once.
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    var text = value.text.replaceAll('\r\n', '\n');
    if (text.isEmpty) {
      stroke(0xff08); // the sentinel lets Backspace work at an empty IME
    } else {
      if (text.startsWith(_seed.text)) text = text.substring(1);
      for (final rune in text.runes) {
        stroke(switch (rune) {
          10 || 13 => 0xff0d,
          9 => 0xff09,
          8 => 0xff08,
          _ =>
            _modifiers.values.any((value) => value != _Latch.off) && rune <= 255
                ? rune
                : 0x01000000 | rune,
        });
      }
    }
    _value = _seed;
    _connection?.setEditingState(_value);
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.done) {
      releaseInput();
    } else if (action == TextInputAction.newline) {
      stroke(0xff0d);
    }
  }

  @override
  void connectionClosed() {
    _connection = null;
    releaseInput();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void dispose() {
    releaseInput(notify: false);
    widget.focus.removeListener(_focusChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget _keyButton(String label, int sym) {
    final latch = _modifiers[sym];
    final active = latch != null && latch != _Latch.off;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      excludeSemantics: true,
      onTap: () => latch == null ? stroke(sym) : _modifier(sym),
      label: label,
      toggled: latch == null ? null : active,
      value: latch == null
          ? null
          : latch == _Latch.locked
          ? context.l10n.keybarModifierLocked
          : active
          ? context.l10n.keybarModifierArmed
          : context.l10n.keybarModifierOff,
      child: TextButton(
        key: ValueKey('desktop_key_$sym'),
        onPressed: () => latch == null ? stroke(sym) : _modifier(sym),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          foregroundColor: active ? colors.onPrimary : colors.onSurface,
          backgroundColor: active ? colors.primary : Colors.transparent,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                decoration: latch == _Latch.armed
                    ? TextDecoration.underline
                    : TextDecoration.none,
              ),
            ),
            if (latch == _Latch.locked) const Icon(Icons.lock, size: 12),
          ],
        ),
      ),
    );
  }

  Widget _keybar() {
    // Put the common keys at the start of both rows on a phone. Function
    // keys remain available by horizontal scrolling without hiding arrows.
    final first = <(String, int)>[
      ('Ctrl', 0xffe3),
      ('Alt', 0xffe9),
      ('Shift', 0xffe1),
      ('Win', 0xffeb),
      ('Esc', 0xff1b),
      ('Tab', 0xff09),
      ('Del', 0xffff),
      ('PgUp', 0xff55),
      ('PgDn', 0xff56),
      ('Ins', 0xff63),
      for (var i = 1; i <= 6; i++) ('F$i', 0xffbd + i),
    ];
    final second = <(String, int)>[
      ('←', 0xff51),
      ('↓', 0xff54),
      ('↑', 0xff52),
      ('→', 0xff53),
      ('Enter', 0xff0d),
      ('Home', 0xff50),
      ('End', 0xff57),
      ('⌫', 0xff08),
      for (var i = 7; i <= 12; i++) ('F$i', 0xffbd + i),
    ];
    final rows = widget.keybarHeight >= 96
        ? [first, second]
        : [
            [...first, ...second],
          ];
    return Material(
      key: const ValueKey('desktop_special_keybar'),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            SizedBox(
              height: 48,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [for (final key in row) _keyButton(key.$1, key.$2)],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    descendantsAreFocusable: false,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 96;
        final dockHeight = narrow ? 96.0 : 48.0;
        final maxY = math.max(
          0.0,
          constraints.maxHeight - widget.keybarHeight - dockHeight,
        );
        final minY = math.min(52.0, maxY);
        final travelY = maxY - minY;
        final buttons = <Widget>[
          IconButton(
            key: const ValueKey('desktop_keyboard_toggle'),
            tooltip: _open
                ? context.l10n.desktopKeyboardHide
                : context.l10n.desktopKeyboardShow,
            isSelected: _open,
            onPressed: widget.connected ? _toggleKeyboard : null,
            icon: Icon(_open ? Icons.keyboard_hide : Icons.keyboard),
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          ),
          Semantics(
            value: widget.trackpad
                ? context.l10n.desktopTrackpadMode
                : context.l10n.desktopTouchMode,
            child: IconButton(
              key: const ValueKey('desktop_pointer_mode_toggle'),
              tooltip: widget.trackpad
                  ? context.l10n.desktopTouchMode
                  : context.l10n.desktopTrackpadMode,
              isSelected: widget.trackpad,
              onPressed: widget.onTogglePointer,
              icon: Icon(
                widget.trackpad
                    ? Icons.mouse_outlined
                    : Icons.touch_app_outlined,
              ),
              constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            ),
          ),
        ];
        return Stack(
          children: [
            if (_open)
              Positioned(left: 0, right: 0, bottom: 0, child: _keybar()),
            Positioned(
              left: _left ? 0 : null,
              right: _left ? null : 0,
              top: minY + travelY * _heightFraction,
              child: GestureDetector(
                key: const ValueKey('desktop_edge_dock'),
                onPanUpdate: (details) {
                  final box = context.findRenderObject()! as RenderBox;
                  final point = box.globalToLocal(details.globalPosition);
                  setState(() {
                    _left = point.dx < constraints.maxWidth / 2;
                    if (travelY > 0)
                      _heightFraction =
                          (_heightFraction + details.delta.dy / travelY).clamp(
                            0,
                            1,
                          );
                  });
                },
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh
                      .withValues(alpha: .94),
                  elevation: 3,
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(_left ? 0 : 16),
                    right: Radius.circular(_left ? 16 : 0),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: narrow
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: buttons,
                        )
                      : Row(mainAxisSize: MainAxisSize.min, children: buttons),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
