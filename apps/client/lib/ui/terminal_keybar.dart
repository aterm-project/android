import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';
import '../storage/terminal_keybar_store.dart';

/// Soft Ctrl/Alt state reported by [TerminalKeybar.onModifiersChanged].
///
/// [ctrl]/[alt] are true while the modifier applies to the next key, either
/// armed for one key or locked; [ctrlLocked]/[altLocked] distinguish a lock.
@immutable
class TerminalKeyModifiers {
  const TerminalKeyModifiers({
    this.ctrl = false,
    this.alt = false,
    this.ctrlLocked = false,
    this.altLocked = false,
  });

  final bool ctrl;
  final bool alt;
  final bool ctrlLocked;
  final bool altLocked;

  @override
  bool operator ==(Object other) =>
      other is TerminalKeyModifiers &&
      other.ctrl == ctrl &&
      other.alt == alt &&
      other.ctrlLocked == ctrlLocked &&
      other.altLocked == altLocked;

  @override
  int get hashCode => Object.hash(ctrl, alt, ctrlLocked, altLocked);

  @override
  String toString() =>
      'TerminalKeyModifiers(ctrl: $ctrl${ctrlLocked ? ' locked' : ''}, '
      'alt: $alt${altLocked ? ' locked' : ''})';
}

/// Device-wide touch keybar preferences shared by every terminal pane.
///
/// Pinning keeps the expanded key rows open across typing, IME show/hide,
/// resizing, tab/split switches and restarts. The value is loaded lazily the
/// first time a visible keybar mounts, so app roots need no extra wiring.
class TerminalKeybarPreferences extends ChangeNotifier {
  TerminalKeybarPreferences({TerminalKeybarStore Function()? storeFactory})
    : _storeFactory = storeFactory ?? createTerminalKeybarStore;

  static TerminalKeybarPreferences? _instance;

  /// Process-wide preferences used by every [TerminalKeybar].
  static TerminalKeybarPreferences get instance =>
      _instance ??= TerminalKeybarPreferences();

  @visibleForTesting
  static set debugInstance(TerminalKeybarPreferences? preferences) =>
      _instance = preferences;

  static const _pinnedValue = 'pinned';
  static const _unpinnedValue = 'off';

  final TerminalKeybarStore Function() _storeFactory;
  TerminalKeybarStore? _store;
  Future<void>? _loading;
  bool _pinned = false;
  bool _writeFailed = false;
  int _revision = 0;
  Future<void>? _writeChain;
  bool _disposed = false;

  /// Whether expanded keys stay open in every keybar.
  bool get pinned => _pinned;

  /// Whether the last attempt to persist a choice failed. The choice still
  /// applies for this run.
  bool get writeFailed => _writeFailed;

  /// Loads the stored preference once. Failures keep the unpinned default.
  Future<void> ensureLoaded() => _loading ??= _load(_storeFactory());

  /// Loads from [store]; later [setPinned] calls persist to it.
  Future<void> load(TerminalKeybarStore store) => _loading = _load(store);

  Future<void> _load(TerminalKeybarStore store) async {
    _store = store;
    final revision = _revision;
    String? stored;
    try {
      stored = await store.read();
    } on Object {
      stored = null;
    }
    // A choice made while the read was in flight wins over the stored value.
    if (_disposed || revision != _revision) return;
    final next = stored == _pinnedValue;
    if (next != _pinned) {
      _pinned = next;
      notifyListeners();
    }
  }

  /// Applies [pinned] immediately and persists it. Writes are serialized and
  /// coalesced; only the latest choice may update [writeFailed].
  Future<void> setPinned(bool pinned) {
    final revision = ++_revision;
    if (pinned != _pinned) {
      _pinned = pinned;
      notifyListeners();
    }
    final store = _store;
    if (store == null) return Future<void>.value();
    final value = pinned ? _pinnedValue : _unpinnedValue;
    // Created per call so the chain runs in the caller's zone.
    final previous = _writeChain ?? Future<void>.value();
    final next = previous.then((_) async {
      if (revision != _revision || _disposed) return;
      var failed = false;
      try {
        await store.write(value);
      } on Object {
        failed = true;
      }
      if (revision != _revision || _disposed) return;
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

enum _Modifier { ctrl, alt }

enum _Latch { off, armed, locked }

/// Terminal keys that keep the terminal's input connection and selection alive.
///
/// Ctrl and Alt are sticky modifiers:
/// * a single tap arms the modifier for the next key only; it is released as
///   soon as a non-modifier key reaches the terminal input handler, whether
///   that key comes from this bar, a hardware keyboard or IME-committed ASCII;
/// * a second tap within [kDoubleTapTimeout] locks it until it is tapped again
///   or Reset is tapped (the button then shows a lock icon). Assistive
///   technologies get the same lock as a custom semantics action.
///
/// Arming never waits for a possible second tap, so a single tap applies
/// immediately. Modifier-only and lock key presses, IME composition, Unicode
/// text that has no terminal key and clipboard paste neither use nor release
/// an armed modifier. The bar is hidden on Windows, where physical keyboards
/// are used directly and the terminal's input handler is left untouched.
///
/// Rows are packed to the available width without shrinking tap targets. When
/// the pane is too short for every expanded key, the bar keeps at most half of
/// the pane (and at least two key rows for the terminal) and the rows scroll
/// horizontally instead.
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
  /// Short panes keep fewer, horizontally scrollable key rows so the terminal
  /// retains room for input and output. Defaults to the screen height.
  final double? availablePaneHeight;
  final ValueChanged<TerminalKeyModifiers>? onModifiersChanged;

  @override
  State<TerminalKeybar> createState() => _TerminalKeybarState();
}

class _TerminalKeybarState extends State<TerminalKeybar> {
  static const _horizontalPadding = 6.0;
  // Guards against sub-pixel differences between measuring and painting.
  static const _measureSlack = 4.0;
  static const _lockIconSize = 14.0;
  static const _lockIconGap = 2.0;
  static const _pinIconSize = 18.0;

  _ModifierInputHandler? _handler;
  TerminalKeybarPreferences? _preferences;
  bool get _visible =>
      kIsWeb || defaultTargetPlatform != TargetPlatform.windows;
  _Latch _ctrl = _Latch.off;
  _Latch _alt = _Latch.off;
  bool _expanded = false;
  _Modifier? _doubleTapCandidate;
  Timer? _doubleTapTimer;

  @override
  void initState() {
    super.initState();
    if (!_visible) return;
    final preferences = TerminalKeybarPreferences.instance;
    _preferences = preferences..addListener(_preferencesChanged);
    unawaited(preferences.ensureLoaded());
    _attach();
  }

  void _preferencesChanged() {
    if (mounted) setState(() {});
  }

  void _attach() {
    if (!_visible) return;
    _handler = _ModifierInputHandler(
      widget.terminal.inputHandler,
      () => TerminalKeyModifiers(
        ctrl: _ctrl != _Latch.off,
        alt: _alt != _Latch.off,
        ctrlLocked: _ctrl == _Latch.locked,
        altLocked: _alt == _Latch.locked,
      ),
      _consumeArmed,
    );
    widget.terminal.inputHandler = _handler!;
  }

  void _detach(Terminal terminal) {
    // Another owner may replace the handler while the view is mounted.
    if (_handler != null && identical(terminal.inputHandler, _handler)) {
      terminal.inputHandler = _handler!.delegate;
    }
    _handler?.detached = true;
    _handler = null;
  }

  @override
  void didUpdateWidget(covariant TerminalKeybar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_visible) return;
    if (!identical(oldWidget.terminal, widget.terminal)) {
      _detach(oldWidget.terminal);
      _releaseAll(deferNotification: true);
      _attach();
    } else if (widget.readOnly && !oldWidget.readOnly) {
      _releaseAll(deferNotification: true);
    }
  }

  @override
  void dispose() {
    _cancelDoubleTap();
    _preferences?.removeListener(_preferencesChanged);
    _detach(widget.terminal);
    super.dispose();
  }

  _Latch _latchOf(_Modifier modifier) =>
      modifier == _Modifier.ctrl ? _ctrl : _alt;

  void _cancelDoubleTap() {
    _doubleTapTimer?.cancel();
    _doubleTapTimer = null;
    _doubleTapCandidate = null;
  }

  void _releaseAll({bool deferNotification = false}) {
    _cancelDoubleTap();
    _setLatches(_Latch.off, _Latch.off, deferNotification: deferNotification);
  }

  void _setLatches(_Latch ctrl, _Latch alt, {bool deferNotification = false}) {
    if (_ctrl == ctrl && _alt == alt) return;
    _ctrl = ctrl;
    _alt = alt;
    final modifiers = TerminalKeyModifiers(
      ctrl: ctrl != _Latch.off,
      alt: alt != _Latch.off,
      ctrlLocked: ctrl == _Latch.locked,
      altLocked: alt == _Latch.locked,
    );
    void notify() {
      if (!mounted || _ctrl != ctrl || _alt != alt) return;
      widget.onModifiersChanged?.call(modifiers);
    }

    if (deferNotification) {
      // Widget updates run during the parent's build; callbacks may setState there.
      WidgetsBinding.instance.addPostFrameCallback((_) => notify());
    } else {
      notify();
    }
  }

  /// Releases armed (not locked) modifiers after an effective key event.
  void _consumeArmed() {
    if (!mounted || (_ctrl != _Latch.armed && _alt != _Latch.armed)) return;
    _cancelDoubleTap();
    final ctrl = _ctrl == _Latch.armed ? _Latch.off : _ctrl;
    final alt = _alt == _Latch.armed ? _Latch.off : _alt;
    final building =
        SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks;
    // The state change applies at once so a following key is unmodified; only
    // the repaint and callback wait when input arrives during a build.
    _setLatches(ctrl, alt, deferNotification: building);
    if (building) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _tapModifier(_Modifier modifier) {
    if (widget.readOnly) return;
    final current = _latchOf(modifier);
    final secondTap = _doubleTapCandidate == modifier;
    _cancelDoubleTap();
    final next = switch (current) {
      _Latch.off => _Latch.armed,
      _Latch.armed => secondTap ? _Latch.locked : _Latch.off,
      _Latch.locked => _Latch.off,
    };
    if (next == _Latch.armed) {
      // Arm immediately; a second tap inside the window upgrades to a lock.
      _doubleTapCandidate = modifier;
      _doubleTapTimer = Timer(kDoubleTapTimeout, () {
        _doubleTapTimer = null;
        _doubleTapCandidate = null;
      });
    }
    _applyModifier(modifier, next);
  }

  void _lockModifier(_Modifier modifier) {
    if (widget.readOnly) return;
    _cancelDoubleTap();
    _applyModifier(modifier, _Latch.locked);
  }

  void _applyModifier(_Modifier modifier, _Latch latch) {
    setState(
      () => modifier == _Modifier.ctrl
          ? _setLatches(latch, _alt)
          : _setLatches(_ctrl, latch),
    );
    _focusTerminal();
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

  void _toggleExpanded(bool expanded) {
    setState(() => _expanded = !expanded);
    // Collapsing is the explicit way out of a pinned layout.
    if (expanded && _preferences!.pinned) {
      unawaited(_preferences!.setPinned(false));
    }
    _focusTerminal();
  }

  void _togglePinned() {
    final pinned = !_preferences!.pinned;
    // The pin is only shown while expanded; unpinning keeps this bar open.
    setState(() => _expanded = true);
    unawaited(_preferences!.setPinned(pinned));
    _focusTerminal();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ExcludeFocus(
        // Pointer/semantics activation must not take focus from the IME.
        child: LayoutBuilder(builder: _buildRows),
      ),
    );
  }

  Widget _buildRows(BuildContext context, BoxConstraints constraints) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final textStyle =
        theme.textTheme.labelLarge ?? const TextStyle(fontSize: 14);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : MediaQuery.sizeOf(context).width;

    double measure(String label, {double extra = 0}) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final measured = painter.width;
      painter.dispose();
      return math.max(
        kMinInteractiveDimension,
        (measured + extra + 2 * _horizontalPadding + _measureSlack)
            .ceilToDouble(),
      );
    }

    final linePainter = TextPainter(
      text: TextSpan(text: 'Mg', style: textStyle),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final rowExtent = math.max(
      kMinInteractiveDimension,
      (linePainter.height + 16).ceilToDouble(),
    );
    linePainter.dispose();

    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(kMinInteractiveDimension, 36),
      padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
      textStyle: textStyle,
    );

    _KeySpec button(
      String label,
      String tooltip,
      VoidCallback? onPressed, {
      bool selected = false,
    }) => _KeySpec(
      measure(label),
      Tooltip(
        message: tooltip,
        child: TextButton(
          style: buttonStyle.copyWith(
            backgroundColor: selected
                ? WidgetStatePropertyAll(theme.colorScheme.secondaryContainer)
                : null,
            foregroundColor: selected
                ? WidgetStatePropertyAll(theme.colorScheme.onSecondaryContainer)
                : null,
          ),
          onPressed: onPressed,
          child: Semantics(
            toggled: selected ? true : null,
            child: _label(label),
          ),
        ),
      ),
    );

    _KeySpec key(String label, TerminalKey key, [String? tooltip]) => button(
      label,
      tooltip ?? label,
      widget.readOnly ? null : () => _send(key),
    );

    _KeySpec modifier(
      _Modifier modifier,
      String label,
      String guidance,
      String lockAction,
    ) {
      final latch = _latchOf(modifier);
      final scheme = theme.colorScheme;
      final (background, foreground) = switch (latch) {
        _Latch.off => (null, null),
        _Latch.armed => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
        _Latch.locked => (scheme.primary, scheme.onPrimary),
      };
      final enabled = !widget.readOnly;
      return _KeySpec(
        // Reserve the lock icon so locking never reflows the rows.
        measure(label, extra: _lockIconSize + _lockIconGap),
        Tooltip(
          message: guidance,
          child: TextButton(
            style: buttonStyle.copyWith(
              backgroundColor: background == null
                  ? null
                  : WidgetStatePropertyAll(background),
              foregroundColor: foreground == null
                  ? null
                  : WidgetStatePropertyAll(foreground),
            ),
            onPressed: enabled ? () => _tapModifier(modifier) : null,
            child: Semantics(
              toggled: latch != _Latch.off,
              value: switch (latch) {
                _Latch.off => l10n.keybarModifierOff,
                _Latch.armed => l10n.keybarModifierArmed,
                _Latch.locked => l10n.keybarModifierLocked,
              },
              customSemanticsActions: enabled && latch != _Latch.locked
                  ? {
                      CustomSemanticsAction(label: lockAction): () =>
                          _lockModifier(modifier),
                    }
                  : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _label(
                    label,
                    // Armed is underlined, locked shows a lock: not color only.
                    decoration: latch == _Latch.armed
                        ? TextDecoration.underline
                        : null,
                  ),
                  if (latch == _Latch.locked) ...[
                    const SizedBox(width: _lockIconGap),
                    Icon(
                      Icons.lock,
                      key: ValueKey('terminal-keybar-lock-${modifier.name}'),
                      size: _lockIconSize,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    final pinned = _preferences!.pinned;
    final expanded = _expanded || pinned;
    final primaryKeys = <_KeySpec>[
      key('Esc', TerminalKey.escape),
      modifier(
        _Modifier.ctrl,
        'Ctrl',
        l10n.keybarCtrlGuidance,
        l10n.lockControlModifier,
      ),
      modifier(
        _Modifier.alt,
        'Alt',
        l10n.keybarAltGuidance,
        l10n.lockAltModifier,
      ),
      key('Tab', TerminalKey.tab),
      key('←', TerminalKey.arrowLeft, l10n.leftArrow),
      key('↓', TerminalKey.arrowDown, l10n.downArrow),
      key('↑', TerminalKey.arrowUp, l10n.upArrow),
      key('→', TerminalKey.arrowRight, l10n.rightArrow),
      button(
        l10n.keybarPaste,
        l10n.pasteClipboard,
        widget.readOnly ? null : _paste,
      ),
      button(
        l10n.keybarReset,
        l10n.releaseControlAndAlt,
        _ctrl != _Latch.off || _alt != _Latch.off
            ? () {
                setState(_releaseAll);
                _focusTerminal();
              }
            : null,
      ),
    ];
    final moreLabel = expanded ? l10n.keybarLess : l10n.keybarMore;
    final more = button(
      moreLabel,
      l10n.moreTerminalKeys,
      () => _toggleExpanded(expanded),
    );
    final trailing = <_KeySpec>[
      // Same width for More and Less so toggling never reflows the rows.
      _KeySpec(
        math.max(measure(l10n.keybarMore), measure(l10n.keybarLess)),
        more.child,
      ),
      if (expanded)
        _KeySpec(
          kMinInteractiveDimension,
          Tooltip(
            message: l10n.keybarPinExpanded,
            child: TextButton(
              key: const ValueKey('terminal-keybar-pin'),
              style: buttonStyle.copyWith(
                backgroundColor: pinned
                    ? WidgetStatePropertyAll(
                        theme.colorScheme.secondaryContainer,
                      )
                    : null,
                foregroundColor: pinned
                    ? WidgetStatePropertyAll(
                        theme.colorScheme.onSecondaryContainer,
                      )
                    : null,
              ),
              onPressed: _togglePinned,
              child: Semantics(
                toggled: pinned,
                child: Icon(
                  pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: _pinIconSize,
                ),
              ),
            ),
          ),
        ),
    ];
    final keys = <_KeySpec>[
      ...primaryKeys,
      if (expanded) ...[
        key('Home', TerminalKey.home),
        key('End', TerminalKey.end),
        key('PgUp', TerminalKey.pageUp),
        key('PgDn', TerminalKey.pageDown),
        key('Ins', TerminalKey.insert),
        key('Del', TerminalKey.delete),
        key('⌫', TerminalKey.backspace, 'Backspace'),
        key('Enter', TerminalKey.enter),
        for (var index = 0; index < 12; index++)
          key(
            'F${index + 1}',
            TerminalKey.values[TerminalKey.f1.index + index],
          ),
      ],
    ];

    // Keep at least two key rows of terminal and give the bar at most half
    // of the pane, so short, split and IME-shrunk panes stay usable.
    final pane =
        widget.availablePaneHeight ?? MediaQuery.sizeOf(context).height;
    final maxRows = expanded
        ? math.max(
            1,
            math.min(
              ((pane - 2 * rowExtent) / rowExtent).floor(),
              (pane / 2 / rowExtent).floor(),
            ),
          )
        : 1;
    final trailingWidth = trailing.fold(0.0, (sum, spec) => sum + spec.width);
    // Very narrow panes cannot spare a fixed trailing area; scroll it instead.
    final fixedTrailing = width >= trailingWidth + kMinInteractiveDimension;
    final flow = fixedTrailing ? keys : [...keys, ...trailing];
    final firstWidth = fixedTrailing ? width - trailingWidth : width;
    final widths = [for (final spec in flow) spec.width];
    final spread = _packRows(widths, firstWidth, width, maxRows);
    final starts =
        spread ?? _scrollRows(widths, math.min(maxRows, flow.length));
    final rows = <Widget>[];
    for (var row = 0; row < starts.length; row++) {
      final end = row + 1 < starts.length ? starts[row + 1] : flow.length;
      final specs = flow.sublist(starts[row], end);
      Widget content = spread != null
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final spec in specs)
                  Expanded(
                    // Spread every key by its natural width; never below it.
                    flex: (spec.width * 16).round(),
                    child: spec.child,
                  ),
              ],
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final spec in specs)
                    SizedBox(width: spec.width, child: spec.child),
                ],
              ),
            );
      if (row == 0 && fixedTrailing) {
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: content),
            for (final spec in trailing)
              SizedBox(width: spec.width, child: spec.child),
          ],
        );
      }
      rows.add(SizedBox(height: rowExtent, child: content));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  static Widget _label(String text, {TextDecoration? decoration}) => FittedBox(
    // Only shrinks if measurement and painting disagree; targets keep size.
    fit: BoxFit.scaleDown,
    child: Text(
      text,
      maxLines: 1,
      softWrap: false,
      style: decoration == null ? null : TextStyle(decoration: decoration),
    ),
  );
}

@immutable
class _KeySpec {
  const _KeySpec(this.width, this.child);

  final double width;
  final Widget child;
}

/// Greedy line breaking of [widths] into at most [maxRows] rows, the first of
/// [firstWidth] and the others of [rowWidth], balanced so rows are similarly
/// full. Returns the first index of every row, or null when the keys only fit
/// with horizontal scrolling.
List<int>? _packRows(
  List<double> widths,
  double firstWidth,
  double rowWidth,
  int maxRows,
) {
  const epsilon = 0.01;
  List<int>? greedy(double scale, int limit) {
    final starts = <int>[0];
    var capacity = firstWidth * scale;
    var used = 0.0;
    for (var index = 0; index < widths.length; index++) {
      final width = widths[index];
      if (used > 0 && used + width > capacity + epsilon) {
        if (starts.length == limit) return null;
        starts.add(index);
        capacity = rowWidth * scale;
        used = 0;
      }
      if (width > capacity + epsilon) return null;
      used += width;
    }
    return starts;
  }

  final fit = greedy(1, maxRows);
  if (fit == null || fit.length == 1) return fit;
  var best = fit;
  var low = 0.0;
  var high = 1.0;
  for (var step = 0; step < 16; step++) {
    final middle = (low + high) / 2;
    final candidate = greedy(middle, fit.length);
    if (candidate != null) {
      best = candidate;
      high = middle;
    } else {
      low = middle;
    }
  }
  return best;
}

/// Splits [widths] into [rows] horizontally scrollable rows of similar width.
List<int> _scrollRows(List<double> widths, int rows) {
  if (rows <= 1 || widths.isEmpty) return const [0];
  final total = widths.fold(0.0, (sum, width) => sum + width);
  final target = total / rows;
  final starts = <int>[0];
  var before = 0.0;
  for (var index = 0; index < widths.length; index++) {
    final row = math.min(
      rows - 1,
      ((before + widths[index] / 2) / target).floor(),
    );
    if (row >= starts.length && index > starts.last) starts.add(index);
    before += widths[index];
  }
  return starts;
}

/// Keys that only change modifier or lock state and so never use up an armed
/// soft modifier.
const _modifierOnlyKeys = <TerminalKey>{
  TerminalKey.shift,
  TerminalKey.shiftLeft,
  TerminalKey.shiftRight,
  TerminalKey.control,
  TerminalKey.controlLeft,
  TerminalKey.controlRight,
  TerminalKey.alt,
  TerminalKey.altLeft,
  TerminalKey.altRight,
  TerminalKey.meta,
  TerminalKey.metaLeft,
  TerminalKey.metaRight,
  TerminalKey.hyper,
  TerminalKey.superKey,
  TerminalKey.fn,
  TerminalKey.fnLock,
  TerminalKey.capsLock,
  TerminalKey.numLock,
  TerminalKey.scrollLock,
};

class _ModifierInputHandler implements TerminalInputHandler {
  _ModifierInputHandler(this.delegate, this.modifiers, this.onEffectiveKey);

  final TerminalInputHandler? delegate;
  final TerminalKeyModifiers Function() modifiers;
  final VoidCallback onEffectiveKey;

  /// Set once the owning keybar lets go, so a stale wrapper retained by some
  /// other handler chain neither applies nor consumes soft modifiers.
  bool detached = false;

  @override
  String? call(TerminalKeyboardEvent event) {
    if (detached) return delegate?.call(event);
    final soft = modifiers();
    final result = delegate?.call(
      event.copyWith(ctrl: event.ctrl || soft.ctrl, alt: event.alt || soft.alt),
    );
    // Every non-modifier key reaching the handler is the "next key", even when
    // the combination has no mapping and TerminalView falls back to plain
    // text, so an armed modifier cannot linger onto a later key.
    if ((soft.ctrl || soft.alt) && !_modifierOnlyKeys.contains(event.key)) {
      onEffectiveKey();
    }
    return result;
  }
}
