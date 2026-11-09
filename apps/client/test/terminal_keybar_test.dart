import 'dart:ui' show SemanticsActionEvent, Tristate;

import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/terminal_keybar_store.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

const _android = TargetPlatformVariant({TargetPlatform.android});
const _platforms = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.android,
});

const _expandedLabels = [
  'Esc',
  'Ctrl',
  'Alt',
  'Tab',
  '←',
  '↓',
  '↑',
  '→',
  'Paste',
  'Reset',
  'Home',
  'End',
  'PgUp',
  'PgDn',
  'Ins',
  'Del',
  '⌫',
  'Enter',
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
  'Less',
];

late MemoryTerminalKeybarStore _store;

void main() {
  setUp(() {
    _store = MemoryTerminalKeybarStore();
    TerminalKeybarPreferences.debugInstance = TerminalKeybarPreferences(
      storeFactory: () => _store,
    );
  });
  tearDown(() => TerminalKeybarPreferences.debugInstance = null);

  testWidgets('Windows hides the keybar without intercepting physical input', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    final original = terminal.inputHandler;
    final focus = FocusNode();
    await tester.pumpWidget(_harness(terminal, focus));
    await tester.pump();
    expect(find.text('Ctrl'), findsNothing);
    expect(find.text('Alt'), findsNothing);
    expect(tester.getSize(find.byType(TerminalKeybar)).height, 0);
    expect(terminal.inputHandler, same(original));
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '你'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(output, ['你', '\x03']);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(terminal.inputHandler, same(original));
    focus.dispose();
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  testWidgets(
    'single tap arms Ctrl for the next IME key only and keeps Unicode intact',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      await tester.pumpWidget(
        _harness(terminal, focus, onChanged: modifiers.add),
      );
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(tester.testTextInput.setClientArgs?['viewId'], tester.view.viewId);

      // The first committed character must be sent immediately, exactly once.
      _commit(tester, 'x');
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      // Armed at once: no wait for a possible second tap.
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
      expect(_modifierValue(tester, 'Ctrl'), 'Next key only');
      expect(focus.hasFocus, isTrue);

      // Composition and Unicode without a terminal key neither use nor
      // release the armed modifier, and are sent once, unmodified.
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      expect(output, ['x']);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '你',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      expect(output, ['x', '你']);
      expect(modifiers.last.ctrl, isTrue);

      _commit(tester, 'c');
      await tester.pump();
      expect(output, ['x', '你', '\x03']);
      expect(modifiers.last, const TerminalKeyModifiers());
      expect(_modifierValue(tester, 'Ctrl'), 'Off');
      _commit(tester, 'c');
      await tester.pump();
      expect(output, ['x', '你', '\x03', 'c']);

      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(find.text('Alt'));
      await tester.pump();
      _commit(tester, 'b');
      await tester.pump();
      _commit(tester, 'b');
      await tester.pump();
      expect(output.sublist(4), ['\x1bb', 'b']);
      expect(modifiers.map((m) => (m.ctrl, m.alt)), [
        (true, false),
        (false, false),
        (false, true),
        (false, false),
      ]);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _platforms,
  );

  testWidgets('double tap locks until tapped again and shows a lock', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    final focus = FocusNode();
    final modifiers = <TerminalKeyModifiers>[];
    await tester.pumpWidget(
      _harness(terminal, focus, onChanged: modifiers.add),
    );
    await tester.pump();
    final ctrlWidth = tester.getSize(_buttonOf('Ctrl')).width;
    await tester.tap(find.text('Ctrl'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(modifiers.map((m) => (m.ctrl, m.ctrlLocked)), [
      (true, false),
      (true, true),
    ]);
    expect(find.byKey(const ValueKey('terminal-keybar-lock-ctrl')), findsOne);
    expect(_modifierValue(tester, 'Ctrl'), 'Locked');
    // The lock icon has reserved room; locking never reflows the rows.
    expect(tester.getSize(_buttonOf('Ctrl')).width, ctrlWidth);
    for (final letter in ['c', 'd', 'c']) {
      _commit(tester, letter);
      await tester.pump();
    }
    await tester.tap(find.text('←'));
    await tester.pump();
    expect(output, ['\x03', '\x04', '\x03', '\x1b[1;5D']);
    // Long after locking, one tap releases the lock.
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(modifiers.last, const TerminalKeyModifiers());
    expect(
      find.byKey(const ValueKey('terminal-keybar-lock-ctrl')),
      findsNothing,
    );
    _commit(tester, 'c');
    await tester.pump();
    expect(output.last, 'c');

    // A slow second tap is a toggle-off, never a lock.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Alt'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.tap(find.text('Alt'));
    await tester.pump();
    expect(modifiers.last, const TerminalKeyModifiers());
    expect(
      find.byKey(const ValueKey('terminal-keybar-lock-alt')),
      findsNothing,
    );
    _commit(tester, 'b');
    await tester.pump();
    expect(output.last, 'b');

    // A double tap whose first tap was already used re-arms instead of locking.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    await tester.tap(find.text('Tab'));
    await tester.pump();
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(modifiers.last, const TerminalKeyModifiers());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  }, variant: _platforms);

  testWidgets(
    'locked and armed modifiers combine, then only the armed one releases',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      await tester.pumpWidget(
        _harness(terminal, focus, onChanged: modifiers.add),
      );
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.tap(find.text('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(find.text('Alt'));
      await tester.pump();
      expect(
        modifiers.last,
        const TerminalKeyModifiers(ctrl: true, alt: true, ctrlLocked: true),
      );
      // Hardware-style keys whose escape sequences encode both modifiers.
      terminal.keyInput(TerminalKey.home);
      terminal.keyInput(TerminalKey.home);
      await tester.pump();
      expect(output, ['\x1b[1;7H', '\x1b[1;5H']);
      expect(
        modifiers.last,
        const TerminalKeyModifiers(ctrl: true, ctrlLocked: true),
      );
      // Both armed: one key uses both, then both release.
      await tester.tap(find.text('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(find.text('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(find.text('Alt'));
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true, alt: true));
      terminal.keyInput(TerminalKey.delete);
      await tester.pump();
      await tester.tap(find.text('→'));
      await tester.pump();
      expect(output.sublist(2), ['\x1b[3;7~', '\x1b[C']);
      expect(modifiers.last, const TerminalKeyModifiers());
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets(
    'hardware modifiers, unmapped keys and paste consume an armed key correctly',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': '中文🙂\nnext'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        _harness(terminal, focus, onChanged: modifiers.add),
      );
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      // Pressing and releasing a hardware modifier is not the next key.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
      await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
      expect(modifiers.last.ctrl, isTrue);
      // Bracketed paste is text, not a key: sent verbatim, modifier kept.
      terminal.write('\x1b[?2004h');
      await tester.tap(find.text('Paste'));
      await tester.pump();
      expect(output, ['\x1b[200~中文🙂\nnext\x1b[201~']);
      expect(modifiers.last.ctrl, isTrue);
      // Hardware key: one key event, one control code, then released.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      expect(output.last, '\x03');
      expect(modifiers.last, const TerminalKeyModifiers());
      // Physical Ctrl still works without any soft modifier.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(output.last, '\x04');

      // An IME key whose Ctrl combination has no mapping falls back to the
      // plain character exactly once and still uses the armed modifier.
      final reference = <String>[];
      final referenceTerminal = Terminal()..onOutput = reference.add;
      if (!referenceTerminal.keyInput(TerminalKey.digit1, ctrl: true)) {
        referenceTerminal.textInput('1');
      }
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      final before = output.length;
      _commit(tester, '1');
      await tester.pump();
      expect(output.sublist(before), reference);
      expect(modifiers.last, const TerminalKeyModifiers());
      _commit(tester, 'c');
      await tester.pump();
      expect(output.last, 'c');
      // Multi-character IME commits are plain text and keep the modifier.
      await tester.tap(find.text('Alt'));
      await tester.pump();
      _commit(tester, 'hello');
      await tester.pump();
      expect(output.last, 'hello');
      expect(modifiers.last.alt, isTrue);
      _commit(tester, 'b');
      await tester.pump();
      expect(output.last, '\x1bb');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _platforms,
  );

  testWidgets('screen readers get modifier state and a lock action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    final focus = FocusNode();
    await tester.pumpWidget(_harness(terminal, focus));
    await tester.pump();
    final node = tester.getSemantics(find.text('Ctrl'));
    final data = node.getSemanticsData();
    expect(data.value, 'Off');
    // The tooltip node wraps the button node, as for every app tooltip.
    expect(node.parent!.getSemanticsData().tooltip, contains('double-tap'));
    expect(data.customSemanticsActionIds, isNotEmpty);
    tester.binding.performSemanticsAction(
      SemanticsActionEvent(
        type: SemanticsAction.customAction,
        viewId: tester.view.viewId,
        nodeId: node.id,
        arguments: data.customSemanticsActionIds!.single,
      ),
    );
    await tester.pump();
    final locked = tester.getSemantics(find.text('Ctrl')).getSemanticsData();
    expect(locked.value, 'Locked');
    expect(locked.customSemanticsActionIds ?? const <int>[], isEmpty);
    _commit(tester, 'c');
    await tester.pump();
    _commit(tester, 'c');
    await tester.pump();
    expect(output, ['\x03', '\x03']);
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
    semantics.dispose();
  }, variant: _android);

  testWidgets(
    'navigation keys and paste preserve focus and bracketed Unicode',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': '中文🙂\nnext'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_harness(terminal, focus));
      await tester.pump();
      for (final label in ['Esc', 'Tab', '←', '↓', '↑', '→']) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(focus.hasFocus, isTrue);
      }
      expect(output, ['\x1b', '\t', '\x1b[D', '\x1b[B', '\x1b[A', '\x1b[C']);
      terminal.write('\x1b[?2004h');
      await tester.tap(find.text('Paste'));
      await tester.pump();
      expect(output.last, '\x1b[200~中文🙂\nnext\x1b[201~');
      expect(focus.hasFocus, isTrue);
      await tester.tap(find.text('More'));
      await tester.pump();
      for (final label in [
        'Home',
        'End',
        'PgUp',
        'PgDn',
        'Del',
        'Enter',
        'F1',
        'F12',
      ]) {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pump();
      }
      expect(output.sublist(7), [
        '\x1b[H',
        '\x1b[F',
        '\x1b[5~',
        '\x1b[6~',
        '\x1b[3~',
        '\r',
        '\x1bOP',
        '\x1b[24~',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _platforms,
  );

  testWidgets(
    '390 px phone spreads every expanded key without scrolling or shrinking',
    (tester) async {
      _setScreen(tester, const Size(390, 844));
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      await tester.pumpWidget(_harness(terminal, focus, paneHeight: 700));
      await tester.pump();
      // Collapsed: More stays on screen without scrolling.
      _expectOnScreen(tester, ['More'], 390);
      expect(tester.getSize(find.byType(TerminalKeybar)).height, 48);
      await tester.tap(find.text('More'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final height = tester.getSize(find.byType(TerminalKeybar)).height;
      expect(height % 48, 0);
      expect(height, greaterThan(48));
      expect(height, lessThanOrEqualTo(350));
      expect(_keybarScrollables(), findsNothing);
      _expectOnScreen(tester, _expandedLabels, 390);
      _expectTargets(tester, _expandedLabels);
      expect(
        tester.getSize(find.byKey(const ValueKey('terminal-keybar-pin'))),
        _atLeastTarget,
      );
      // Every key works in place, without scrolling.
      final expected = <String>[];
      final reference = Terminal()..onOutput = expected.add;
      for (final entry in _keys.entries) {
        reference.keyInput(entry.value);
        await tester.tap(find.text(entry.key));
        await tester.pump();
        expect(focus.hasFocus, isTrue, reason: entry.key);
      }
      expect(output, expected);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets('tablet width uses fewer, wider rows', (tester) async {
    _setScreen(tester, const Size(1024, 768));
    final terminal = Terminal();
    final focus = FocusNode();
    await tester.pumpWidget(_harness(terminal, focus, paneHeight: 700));
    await tester.pump();
    final collapsedEsc = tester.getSize(_buttonOf('Esc')).width;
    await tester.tap(find.text('More'));
    await tester.pump();
    final height = tester.getSize(find.byType(TerminalKeybar)).height;
    expect(height, inInclusiveRange(96, 144));
    expect(_keybarScrollables(), findsNothing);
    _expectOnScreen(tester, _expandedLabels, 1024);
    _expectTargets(tester, _expandedLabels);
    // Spread out: keys grow to fill the width instead of leaving a gap.
    expect(tester.getSize(_buttonOf('Esc')).width, greaterThan(48));
    expect(collapsedEsc, greaterThan(48));
    final f12 = tester.getRect(_buttonOf('F12'));
    expect(f12.right, closeTo(1024, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  }, variant: _android);

  testWidgets(
    '142 px pane exposes every expanded key in one row without losing IME',
    (tester) async {
      _setScreen(tester, const Size(360, 800));
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': '中文🙂'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_harness(terminal, focus, paneHeight: 142));
      await tester.pump();
      final state = tester.state(find.byType(TerminalView));
      final collapsed = tester.getSize(find.byType(TerminalKeybar)).height;
      Future<void> press(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: label);
        expect(focus.hasFocus, isTrue, reason: label);
        expect(tester.testTextInput.hasAnyClients, isTrue, reason: label);
      }

      await press('More');
      expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed);
      expect(
        tester.getSize(find.byType(TerminalView)).height,
        greaterThanOrEqualTo(80),
      );
      // Less and the pin stay fixed on screen while the keys scroll.
      _expectOnScreen(tester, ['Less'], 360);
      final expected = <String>[];
      final reference = Terminal()..onOutput = expected.add;
      for (final entry in _keys.entries) {
        reference.keyInput(entry.value);
        await press(entry.key);
        _expectTargets(tester, [entry.key]);
      }
      expect(output, expected);
      await press('Ctrl');
      terminal.keyInput(TerminalKey.keyC);
      expect(output.last, '\x03');
      await tester.pump(kDoubleTapTimeout * 2);
      await press('Alt');
      terminal.keyInput(TerminalKey.keyB);
      expect(output.last, '\x1bb');
      await press('Paste');
      expect(output.last, '中文🙂');
      await press('Less');
      expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed);
      expect(tester.state(find.byType(TerminalView)), same(state));
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets(
    'pinned keys survive typing, IME resize and tab switches, and persist',
    (tester) async {
      _setScreen(tester, const Size(390, 844));
      final output = <String>[];
      final first = Terminal()..onOutput = output.add;
      final second = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      await tester.pumpWidget(_harness(first, focus, paneHeight: 700));
      await tester.pump();
      final state = tester.state(find.byType(TerminalView));
      await tester.tap(find.text('More'));
      await tester.pump();
      final spreadHeight = tester.getSize(find.byType(TerminalKeybar)).height;
      expect(find.byKey(const ValueKey('terminal-keybar-pin')), findsOne);
      // The icon-only pin is a named toggle button, not just a tooltip.
      final unpinned = _pinSemantics(tester);
      expect(unpinned.label, 'Keep extra keys open');
      expect(unpinned.flagsCollection.isButton, isTrue);
      expect(unpinned.flagsCollection.isToggled, Tristate.isFalse);
      expect(unpinned.hasAction(SemanticsAction.tap), isTrue);
      await tester.tap(find.byKey(const ValueKey('terminal-keybar-pin')));
      await tester.pump();
      expect(TerminalKeybarPreferences.instance.pinned, isTrue);
      expect(_store.value, 'pinned');
      final pinnedNode = _pinSemantics(tester);
      expect(pinnedNode.label, 'Keep extra keys open');
      expect(pinnedNode.flagsCollection.isToggled, Tristate.isTrue);

      // Typing keeps it open.
      for (final text in ['l', 's', '你']) {
        _commit(tester, text);
        await tester.pump();
      }
      expect(output, ['l', 's', '你']);
      expect(find.text('F12'), findsOne);

      // IME shows: the pane shrinks, rows become bounded and scroll.
      await tester.pumpWidget(_harness(first, focus, paneHeight: 330));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final imeHeight = tester.getSize(find.byType(TerminalKeybar)).height;
      expect(imeHeight, lessThanOrEqualTo(165));
      expect(imeHeight, lessThan(spreadHeight));
      expect(
        tester.getSize(find.byType(TerminalView)).height,
        greaterThanOrEqualTo(165),
      );
      expect(find.text('Less'), findsOne);
      _expectOnScreen(tester, ['Less'], 390);
      expect(tester.state(find.byType(TerminalView)), same(state));
      expect(focus.hasFocus, isTrue);
      await tester.ensureVisible(find.text('F12'));
      await tester.tap(find.text('F12'));
      await tester.pump();
      expect(output.last, '\x1b[24~');

      // IME hides: spread again.
      await tester.pumpWidget(_harness(first, focus, paneHeight: 700));
      await tester.pump();
      expect(tester.getSize(find.byType(TerminalKeybar)).height, spreadHeight);
      expect(_keybarScrollables(), findsNothing);

      // Tab switch with a fresh keybar state (as in per-session panes).
      await tester.pumpWidget(
        _harness(second, focus, paneHeight: 700, key: const ValueKey('b')),
      );
      await tester.pump();
      expect(find.text('Less'), findsOne);
      expect(tester.getSize(find.byType(TerminalKeybar)).height, spreadHeight);

      // Restart: a new preference instance reads the stored pin.
      await tester.pumpWidget(const SizedBox.shrink());
      TerminalKeybarPreferences.debugInstance = TerminalKeybarPreferences(
        storeFactory: () => _store,
      );
      await tester.pumpWidget(_harness(first, focus, paneHeight: 700));
      await tester.pump();
      expect(find.text('Less'), findsOne);
      expect(find.text('F12'), findsOne);

      // Less is the explicit way out and is persisted too.
      await tester.tap(find.text('Less'));
      await tester.pump();
      expect(find.text('More'), findsOne);
      expect(find.text('F12'), findsNothing);
      expect(_store.value, 'off');
      expect(TerminalKeybarPreferences.instance.pinned, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets(
    'large accessibility text keeps targets and bounded height in a split pane',
    (tester) async {
      _setScreen(tester, const Size(390, 844));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      for (final pane in [800.0, 400.0, 200.0]) {
        await tester.pumpWidget(_harness(terminal, focus, paneHeight: pane));
        await tester.pump();
        if (find.text('More').evaluate().isNotEmpty) {
          await tester.ensureVisible(find.text('More'));
          await tester.tap(find.text('More'));
          await tester.pump();
        }
        expect(tester.takeException(), isNull, reason: '$pane');
        final height = tester.getSize(find.byType(TerminalKeybar)).height;
        final row = tester.getSize(_buttonOf('Esc')).height;
        expect(row, greaterThanOrEqualTo(48));
        expect(
          height,
          lessThanOrEqualTo(pane > 3 * row ? pane / 2 : row),
          reason: '$pane',
        );
        for (final label in ['Ctrl', 'F12', 'Enter']) {
          await tester.ensureVisible(find.text(label));
          await tester.pump();
          _expectTargets(tester, [label]);
        }
        await tester.ensureVisible(find.text('Enter'));
        await tester.tap(find.text('Enter'));
        await tester.pump();
        expect(output.last, '\r');
        expect(focus.hasFocus, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets('expanded bar adapts to a short pane and restores normal rows', (
    tester,
  ) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    final focus = FocusNode();
    await tester.pumpWidget(_harness(terminal, focus, paneHeight: 400));
    await tester.pump();
    final state = tester.state(find.byType(TerminalView));
    final collapsed = tester.getSize(find.byType(TerminalKeybar)).height;
    await tester.tap(find.text('Ctrl'));
    await tester.tap(find.text('More'));
    await tester.pump();
    final expanded = tester.getSize(find.byType(TerminalKeybar)).height;
    expect(expanded, greaterThan(collapsed));
    expect(expanded, lessThanOrEqualTo(200));
    await tester.pumpWidget(_harness(terminal, focus, paneHeight: 142));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed);
    expect(find.text('Less'), findsOneWidget);
    expect(tester.state(find.byType(TerminalView)), same(state));
    expect(focus.hasFocus, isTrue);
    terminal.keyInput(TerminalKey.keyC);
    expect(output.last, '\x03');
    await tester.pumpWidget(_harness(terminal, focus, paneHeight: 400));
    await tester.pump();
    expect(tester.getSize(find.byType(TerminalKeybar)).height, expanded);
    expect(tester.state(find.byType(TerminalView)), same(state));
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  }, variant: _android);

  testWidgets(
    'short cloud and detached columns account for their fixed headers',
    (tester) async {
      final terminal = Terminal();
      final focus = FocusNode();
      for (final headerHeight in [48.0, 77.0]) {
        await tester.pumpWidget(
          _harness(
            terminal,
            focus,
            paneHeight: 142,
            headerHeight: headerHeight,
          ),
        );
        await tester.pump();
        if (find.text('More').evaluate().isNotEmpty) {
          await tester.tap(find.text('More'));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(TerminalKeybar)).height, 48);
        await tester.ensureVisible(find.text('F12'));
        await tester.tap(find.text('F12'));
        await tester.pump();
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets(
    'responsive expanded bar keeps translated tooltips and live input across languages',
    (tester) async {
      final controller = AppLanguageController(
        systemLocales: () => const [Locale('en')],
      );
      final previous = currentL10n;
      addTearDown(() => debugCurrentL10n = previous);
      addTearDown(controller.dispose);
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async =>
            call.method == 'Clipboard.getData' ? {'text': '中日🙂'} : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        AppLanguageHost(
          controller: controller,
          builder: (context, locale) =>
              _harness(terminal, focus, paneHeight: 142),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('More'));
      await tester.pump();
      final state = tester.state(find.byType(TerminalView));
      for (final (language, paste, reset) in [
        (AppLanguage.chinese, '粘贴', '重置'),
        (AppLanguage.japanese, '貼り付け', '解除'),
        (AppLanguage.russian, 'Вставить', 'Сброс'),
        (AppLanguage.english, 'Paste', 'Reset'),
      ]) {
        controller.setPreference(language);
        await tester.pump();
        expect(find.byTooltip(currentL10n.keybarCtrlGuidance), findsOneWidget);
        expect(find.byTooltip(currentL10n.keybarAltGuidance), findsOneWidget);
        expect(find.byTooltip(currentL10n.keybarPinExpanded), findsOneWidget);
        expect(_pinSemantics(tester).label, currentL10n.keybarPinExpanded);
        expect(tester.getSize(find.byType(TerminalKeybar)).height, 48);
        expect(tester.state(find.byType(TerminalView)), same(state));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        await tester.ensureVisible(find.text('Ctrl'));
        await tester.tap(find.text('Ctrl'));
        await tester.pump();
        terminal.keyInput(TerminalKey.keyC);
        expect(output.last, '\x03');
        expect(find.text(paste), findsOneWidget);
        expect(find.text(reset), findsOneWidget);
        await tester.ensureVisible(find.text(paste));
        await tester.tap(find.text(paste));
        await tester.pump();
        expect(output.last, '中日🙂');
        terminal.textInput('c');
        expect(output.last, 'c');
        await tester.pump(kDoubleTapTimeout * 2);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets('lifecycle reset callback can rebuild its parent', (
    tester,
  ) async {
    final terminal = Terminal();
    final focus = FocusNode();
    var readOnly = false;
    var callbacks = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          rebuild = setState;
          return _harness(
            terminal,
            focus,
            readOnly: readOnly,
            onChanged: (_) {
              setState(() => callbacks++);
            },
          );
        },
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    rebuild(() => readOnly = true);
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(callbacks, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(callbacks, 2);
    focus.dispose();
  });

  testWidgets(
    'read-only, terminal replacement and disposal release armed and locked modifiers',
    (tester) async {
      final output = <String>[];
      final first = Terminal()..onOutput = output.add;
      final originalHandler = first.inputHandler;
      final second = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump();
      // Locked Ctrl is released by read-only.
      await tester.tap(find.text('Ctrl'));
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(modifiers.last.ctrlLocked, isTrue);
      await tester.pumpWidget(
        _harness(first, focus, readOnly: true, onChanged: modifiers.add),
      );
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers());
      await tester.tap(find.text('Tab'));
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(output, isEmpty);
      expect(first.keyInput(TerminalKey.keyC), isFalse);
      expect(
        tester.getSemantics(find.text('Ctrl')).getSemanticsData().value,
        'Off',
      );
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump(kDoubleTapTimeout * 2);
      // Armed Alt and locked Ctrl are released by a terminal replacement.
      await tester.tap(find.text('Ctrl'));
      await tester.tap(find.text('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(find.text('Alt'));
      await tester.pump();
      await tester.pumpWidget(
        _harness(second, focus, onChanged: modifiers.add),
      );
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers());
      expect(first.inputHandler, same(originalHandler));
      expect(first.keyInput(TerminalKey.keyB), isFalse);
      expect(second.keyInput(TerminalKey.keyB), isFalse);
      expect(second.keyInput(TerminalKey.keyC), isFalse);
      // A pending double tap does not lock on the new terminal.
      await tester.tap(find.text('Ctrl'));
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
      // Another owner wraps the handler; after disposal the stale wrapper is
      // inert and the locked state does not leak.
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(modifiers.last.ctrlLocked, isTrue);
      first.inputHandler = CascadeInputHandler([first.inputHandler!]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(first.keyInput(TerminalKey.keyC), isFalse);
      expect(second.inputHandler, same(originalHandler));
      expect(output, isEmpty);
      focus.dispose();
    },
  );

  group('TerminalKeybarPreferences', () {
    test('loads, applies and persists the pin', () async {
      final store = MemoryTerminalKeybarStore('pinned');
      final preferences = TerminalKeybarPreferences(storeFactory: () => store);
      await preferences.ensureLoaded();
      expect(preferences.pinned, isTrue);
      await preferences.setPinned(false);
      expect(store.value, 'off');
      expect(preferences.writeFailed, isFalse);
      preferences.dispose();
    });

    test('invalid or failing reads keep the unpinned default', () async {
      for (final store in [
        MemoryTerminalKeybarStore('garbage'),
        _FailingStore(),
      ]) {
        final preferences = TerminalKeybarPreferences(
          storeFactory: () => store,
        );
        await preferences.ensureLoaded();
        expect(preferences.pinned, isFalse);
        preferences.dispose();
      }
    });

    test(
      'a choice made during loading wins; write failures are reported',
      () async {
        final store = MemoryTerminalKeybarStore('off');
        final preferences = TerminalKeybarPreferences(
          storeFactory: () => store,
        );
        final loading = preferences.ensureLoaded();
        final writing = preferences.setPinned(true);
        await loading;
        await writing;
        expect(preferences.pinned, isTrue);
        expect(store.value, 'pinned');
        store.failWith = StateError('disk full');
        await preferences.setPinned(false);
        expect(preferences.pinned, isFalse);
        expect(preferences.writeFailed, isTrue);
        store.failWith = null;
        await preferences.setPinned(true);
        expect(preferences.writeFailed, isFalse);
        preferences.dispose();
      },
    );
  });
}

class _FailingStore implements TerminalKeybarStore {
  @override
  Future<String?> read() async => throw StateError('unreadable');

  @override
  Future<void> write(String value) async {}
}

final _keys = <String, TerminalKey>{
  'Esc': TerminalKey.escape,
  'Tab': TerminalKey.tab,
  '←': TerminalKey.arrowLeft,
  '↓': TerminalKey.arrowDown,
  '↑': TerminalKey.arrowUp,
  '→': TerminalKey.arrowRight,
  'Home': TerminalKey.home,
  'End': TerminalKey.end,
  'PgUp': TerminalKey.pageUp,
  'PgDn': TerminalKey.pageDown,
  'Ins': TerminalKey.insert,
  'Del': TerminalKey.delete,
  '⌫': TerminalKey.backspace,
  'Enter': TerminalKey.enter,
  for (var i = 0; i < 12; i++)
    'F${i + 1}': TerminalKey.values[TerminalKey.f1.index + i],
};

final _atLeastTarget = predicate<Size>(
  (size) => size.width >= 48 && size.height >= 48,
  'at least a 48x48 tap target',
);

void _commit(WidgetTester tester, String text) =>
    tester.testTextInput.updateEditingValue(TextEditingValue(text: text));

void _setScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Finder _buttonOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextButton));

Finder _keybarScrollables() => find.descendant(
  of: find.byType(TerminalKeybar),
  matching: find.byType(Scrollable),
);

SemanticsData _pinSemantics(WidgetTester tester) => tester
    .getSemantics(find.byKey(const ValueKey('terminal-keybar-pin')))
    .getSemanticsData();

String _modifierValue(WidgetTester tester, String label) =>
    tester.getSemantics(find.text(label)).getSemanticsData().value;

void _expectOnScreen(WidgetTester tester, List<String> labels, double width) {
  for (final label in labels) {
    final rect = tester.getRect(_buttonOf(label));
    expect(rect.left, greaterThanOrEqualTo(-0.01), reason: label);
    expect(rect.right, lessThanOrEqualTo(width + 0.01), reason: label);
    final text = tester.getRect(find.text(label));
    expect(rect.contains(text.center), isTrue, reason: label);
  }
}

void _expectTargets(WidgetTester tester, List<String> labels) {
  for (final label in labels) {
    expect(tester.getSize(_buttonOf(label)), _atLeastTarget, reason: label);
  }
}

Widget _harness(
  Terminal terminal,
  FocusNode focus, {
  Key? key,
  bool readOnly = false,
  double? paneHeight,
  double headerHeight = 0,
  ValueChanged<TerminalKeyModifiers>? onChanged,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        height: paneHeight,
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            children: [
              if (headerHeight > 0) SizedBox(height: headerHeight),
              Expanded(
                child: TerminalView(
                  terminal,
                  focusNode: focus,
                  autofocus: true,
                  readOnly: readOnly,
                ),
              ),
              TerminalKeybar(
                key: key,
                terminal: terminal,
                focusNode: focus,
                readOnly: readOnly,
                availablePaneHeight: constraints.maxHeight - headerHeight,
                onModifiersChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);
