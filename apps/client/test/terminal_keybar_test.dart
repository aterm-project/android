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
  'Shift',
  'Tab',
  '←',
  '↑',
  '↓',
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
    expect(_find('Ctrl'), findsNothing);
    expect(_find('Alt'), findsNothing);
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
      await tester.tap(_find('Ctrl'));
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
      await tester.tap(_find('Alt'));
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

  testWidgets(
    'Shift applies once, combines with navigation and locks on double tap',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      await tester.pumpWidget(
        _harness(terminal, focus, onChanged: modifiers.add),
      );
      await tester.pump();
      await tester.tap(_find('Shift'));
      await tester.pump();
      _commit(tester, 'a');
      await tester.pump();
      _commit(tester, 'a');
      await tester.pump();
      expect(output, ['A', 'a']);
      expect(modifiers.last.shift, isFalse);
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Shift'));
      await tester.pump();
      await tester.tap(_find('Tab'));
      await tester.pump();
      expect(output.last, '\x1b[Z');
      expect(modifiers.last.shift, isFalse);
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Shift'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(_find('Shift'));
      await tester.pump();
      expect(modifiers.last.shiftLocked, isTrue);
      _commit(tester, 'b');
      await tester.pump();
      _commit(tester, 'c');
      await tester.pump();
      expect(output.sublist(output.length - 2), ['B', 'C']);
      await tester.ensureVisible(_find('Reset'));
      await tester.tap(_find('Reset'));
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers());
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
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
    await tester.tap(_find('Ctrl'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(_find('Ctrl'));
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
    await tester.tap(_find('←'));
    await tester.pump();
    expect(output, ['\x03', '\x04', '\x03', '\x1b[1;5D']);
    // Long after locking, one tap releases the lock.
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(_find('Ctrl'));
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
    await tester.tap(_find('Alt'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.tap(_find('Alt'));
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
    await tester.tap(_find('Ctrl'));
    await tester.pump();
    await tester.tap(_find('Tab'));
    await tester.pump();
    await tester.tap(_find('Ctrl'));
    await tester.pump();
    expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
    await tester.ensureVisible(_find('Reset'));
    await tester.tap(_find('Reset'));
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
      await tester.tap(_find('Ctrl'));
      await tester.tap(_find('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Alt'));
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
      await tester.tap(_find('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Alt'));
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true, alt: true));
      terminal.keyInput(TerminalKey.delete);
      await tester.pump();
      await tester.tap(_find('→'));
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
      await tester.tap(_find('Ctrl'));
      await tester.pump();
      // Pressing and releasing a hardware modifier is not the next key.
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
      await tester.sendKeyEvent(LogicalKeyboardKey.capsLock);
      expect(modifiers.last.ctrl, isTrue);
      // Bracketed paste is text, not a key: sent verbatim, modifier kept.
      terminal.write('\x1b[?2004h');
      await tester.tap(_find('Paste'));
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
      await tester.tap(_find('Ctrl'));
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
      await tester.tap(_find('Alt'));
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
    final node = tester.getSemantics(_find('Ctrl'));
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
    final locked = tester.getSemantics(_find('Ctrl')).getSemanticsData();
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
      for (final label in ['Esc', 'Tab', '←', '↑', '↓', '→']) {
        await tester.tap(_find(label));
        await tester.pump();
        expect(focus.hasFocus, isTrue);
      }
      expect(output, ['\x1b', '\t', '\x1b[D', '\x1b[A', '\x1b[B', '\x1b[C']);
      terminal.write('\x1b[?2004h');
      await tester.tap(_find('Paste'));
      await tester.pump();
      expect(output.last, '\x1b[200~中文🙂\nnext\x1b[201~');
      expect(focus.hasFocus, isTrue);
      await tester.tap(_find('More'));
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
        await tester.ensureVisible(_find(label));
        await tester.tap(_find(label));
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
      await tester.tap(_find('More'));
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
        await tester.tap(_find(entry.key));
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
    await tester.tap(_find('More'));
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
        await tester.ensureVisible(_find(label));
        await tester.tap(_find(label));
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
      await tester.tap(_find('More'));
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
      expect(_find('F12'), findsOne);

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
      expect(_find('Less'), findsOne);
      _expectOnScreen(tester, ['Less'], 390);
      expect(tester.state(find.byType(TerminalView)), same(state));
      expect(focus.hasFocus, isTrue);
      await tester.ensureVisible(_find('F12'));
      await tester.tap(_find('F12'));
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
      expect(_find('Less'), findsOne);
      expect(tester.getSize(find.byType(TerminalKeybar)).height, spreadHeight);

      // Restart: a new preference instance reads the stored pin.
      await tester.pumpWidget(const SizedBox.shrink());
      TerminalKeybarPreferences.debugInstance = TerminalKeybarPreferences(
        storeFactory: () => _store,
      );
      await tester.pumpWidget(_harness(first, focus, paneHeight: 700));
      await tester.pump();
      expect(_find('Less'), findsOne);
      expect(_find('F12'), findsOne);

      // Less is the explicit way out and is persisted too.
      await tester.tap(_find('Less'));
      await tester.pump();
      expect(_find('More'), findsOne);
      expect(_find('F12'), findsNothing);
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
        if (_find('More').evaluate().isNotEmpty) {
          await tester.ensureVisible(_find('More'));
          await tester.tap(_find('More'));
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
          await tester.ensureVisible(_find(label));
          await tester.pump();
          _expectTargets(tester, [label]);
        }
        await tester.ensureVisible(_find('Enter'));
        await tester.tap(_find('Enter'));
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
    await tester.tap(_find('Ctrl'));
    await tester.tap(_find('More'));
    await tester.pump();
    final expanded = tester.getSize(find.byType(TerminalKeybar)).height;
    expect(expanded, greaterThan(collapsed));
    expect(expanded, lessThanOrEqualTo(200));
    await tester.pumpWidget(_harness(terminal, focus, paneHeight: 142));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed);
    expect(_find('Less'), findsOneWidget);
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
        if (_find('More').evaluate().isNotEmpty) {
          await tester.tap(_find('More'));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(TerminalKeybar)).height, 48);
        await tester.ensureVisible(_find('F12'));
        await tester.tap(_find('F12'));
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
      await tester.tap(_find('More'));
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
        await tester.ensureVisible(_find('Ctrl'));
        await tester.tap(_find('Ctrl'));
        await tester.pump();
        terminal.keyInput(TerminalKey.keyC);
        expect(output.last, '\x03');
        expect(_find(paste), findsOneWidget);
        expect(_find(reset), findsOneWidget);
        await tester.ensureVisible(_find(paste));
        await tester.tap(_find(paste));
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
    await tester.tap(_find('Ctrl'));
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
      await tester.tap(_find('Ctrl'));
      await tester.tap(_find('Ctrl'));
      await tester.pump();
      expect(modifiers.last.ctrlLocked, isTrue);
      await tester.pumpWidget(
        _harness(first, focus, readOnly: true, onChanged: modifiers.add),
      );
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers());
      await tester.tap(_find('Tab'));
      await tester.tap(_find('Ctrl'));
      await tester.pump();
      expect(output, isEmpty);
      expect(first.keyInput(TerminalKey.keyC), isFalse);
      expect(
        tester.getSemantics(_find('Ctrl')).getSemanticsData().value,
        'Off',
      );
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump(kDoubleTapTimeout * 2);
      // Armed Alt and locked Ctrl are released by a terminal replacement.
      await tester.tap(_find('Ctrl'));
      await tester.tap(_find('Ctrl'));
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Alt'));
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
      await tester.tap(_find('Ctrl'));
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump();
      await tester.tap(_find('Ctrl'));
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
      // Another owner wraps the handler; after disposal the stale wrapper is
      // inert and the locked state does not leak.
      await tester.tap(_find('Ctrl'));
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

  testWidgets(
    'arrows are ordered left, up, down, right, drawn thick and send cursor keys',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      await tester.pumpWidget(_harness(terminal, focus));
      await tester.pump();
      final order = ['←', '↑', '↓', '→'];
      final rects = [for (final label in order) tester.getRect(_find(label))];
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].top, rects[0].top, reason: order[i]);
        expect(rects[i].left, greaterThan(rects[i - 1].left), reason: order[i]);
      }
      // Left and right keep their neighbours: Tab before, Paste after.
      expect(tester.getRect(_buttonOf('Tab')).right, closeTo(rects[0].left, 1));
      expect(
        tester.getRect(_buttonOf('Paste')).left,
        closeTo(rects.last.right, 1),
      );
      // Same targets as the old text arrows.
      _expectTargets(tester, order);

      const turns = {'←': -0.5, '↑': 0.0, '↓': 1.0, '→': 0.5};
      for (final label in order) {
        final painter = find.descendant(
          of: _find(label),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is CustomPaint &&
                widget.painter.runtimeType.toString() == '_ArrowPainter',
          ),
        );
        expect(painter, findsOne, reason: label);
        // A heavy round stroke, much thicker than a ~1 px font arrow, and
        // rotated to its own direction.
        expect(
          tester.renderObject(painter),
          paints
            ..rotate(angle: turns[label]! * 3.141592653589793)
            ..something((method, arguments) {
              if (method != #drawLine) return false;
              final paint = arguments[2] as Paint;
              return paint.strokeWidth >= 2.5 &&
                  paint.style == PaintingStyle.stroke &&
                  paint.strokeCap == StrokeCap.round;
            })
            ..path(style: PaintingStyle.stroke),
          reason: label,
        );
      }
      // Each arrow has its spoken name, not a symbol.
      for (final (label, name) in [
        ('←', 'Left arrow'),
        ('↑', 'Up arrow'),
        ('↓', 'Down arrow'),
        ('→', 'Right arrow'),
      ]) {
        final data = tester.getSemantics(_find(label)).getSemanticsData();
        expect(data.label, contains(name), reason: label);
        expect(data.hasAction(SemanticsAction.tap), isTrue, reason: label);
      }
      for (final label in order) {
        await tester.tap(_find(label));
        await tester.pump();
      }
      expect(output, ['\x1b[D', '\x1b[A', '\x1b[B', '\x1b[C']);
      // Application cursor mode keeps the right sequences for each arrow.
      terminal.write('\x1b[?1h');
      for (final label in order) {
        await tester.tap(_find(label));
        await tester.pump();
      }
      expect(output.sublist(4), ['\x1bOD', '\x1bOA', '\x1bOB', '\x1bOC']);
      // Soft Ctrl and Alt still combine with the arrows, once.
      terminal.write('\x1b[?1l');
      final reference = <String>[];
      Terminal()
        ..onOutput = reference.add
        ..keyInput(TerminalKey.arrowUp, ctrl: true)
        ..keyInput(TerminalKey.arrowDown)
        ..keyInput(TerminalKey.arrowLeft, alt: true);
      expect(reference, hasLength(3));
      await tester.tap(_find('Ctrl'));
      await tester.pump();
      await tester.tap(_find('↑'));
      await tester.pump();
      await tester.tap(_find('↓'));
      await tester.pump();
      await tester.pump(kDoubleTapTimeout * 2);
      await tester.tap(_find('Alt'));
      await tester.pump();
      await tester.tap(_find('←'));
      await tester.pump();
      expect(output.sublist(8), reference);
      // Read-only disables the drawn arrows like every other key.
      await tester.pumpWidget(_harness(terminal, focus, readOnly: true));
      await tester.pump();
      await tester.tap(_find('↑'), warnIfMissed: false);
      await tester.pump();
      expect(output, hasLength(11));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      semantics.dispose();
    },
    variant: _platforms,
  );

  testWidgets(
    'Android: tap after hiding the keyboard only focuses; the keybar button opens it',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      final input = tester.testTextInput;
      bool shown() => input.log.any((call) => call.method == 'TextInput.show');
      Future<void> tapTerminal() async {
        await tester.tapAt(tester.getCenter(find.byType(TerminalView)));
        await tester.pump(kDoubleTapTimeout * 2);
      }

      await tester.pumpWidget(
        _harness(terminal, focus, paneHeight: 700, onChanged: modifiers.add),
      );
      await tester.pump();
      // Connecting still opens the keyboard once, as before.
      expect(focus.hasFocus, isTrue);
      expect(shown(), isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      expect(_keyboardSemantics(tester).label, 'Hide keyboard');

      // The user hides the keyboard natively (back gesture): the input
      // connection stays attached, only the inset goes away.
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(_keyboardSemantics(tester).label, 'Show keyboard');
      final button = _keyboardSemantics(tester);
      expect(button.flagsCollection.isButton, isTrue);
      expect(button.hasAction(SemanticsAction.tap), isTrue);
      input.log.clear();
      for (var i = 0; i < 3; i++) {
        await tapTerminal();
      }
      expect(shown(), isFalse);
      expect(focus.hasFocus, isTrue);
      expect(input.hasAnyClients, isTrue);
      // Hardware keys and IME commits still type while the keyboard is hidden.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      _commit(tester, 'b');
      await tester.pump();
      expect(output, ['\r', 'b']);

      // Arm Ctrl and pin the extra keys; the button keeps both.
      await tester.tap(_find('More'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('terminal-keybar-pin')));
      await tester.pump();
      await tester.tap(_find('Ctrl'));
      await tester.pump();
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
      input.log.clear();
      await tester.tap(find.byKey(const ValueKey('terminal-keybar-keyboard')));
      await tester.pump();
      expect(shown(), isTrue);
      expect(focus.hasFocus, isTrue);
      expect(modifiers.last, const TerminalKeyModifiers(ctrl: true));
      expect(TerminalKeybarPreferences.instance.pinned, isTrue);
      expect(_find('F12'), findsOne);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(_keyboardSemantics(tester).label, 'Hide keyboard');
      _commit(tester, 'c');
      await tester.pump();
      _commit(tester, 'ls');
      await tester.pump();
      expect(output.sublist(2), ['\x03', 'ls']);
      expect(modifiers.last, const TerminalKeyModifiers());

      // The same button hides it; taps then still leave it hidden.
      await tester.tap(find.byKey(const ValueKey('terminal-keybar-keyboard')));
      await tester.pump();
      expect(input.hasAnyClients, isFalse);
      expect(focus.hasFocus, isTrue);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      input.log.clear();
      await tapTerminal();
      expect(shown(), isFalse);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(output.last, '\x1b[A');
      await tester.tap(find.byKey(const ValueKey('terminal-keybar-keyboard')));
      await tester.pump();
      expect(shown(), isTrue);
      expect(input.hasAnyClients, isTrue);
      _commit(tester, 'e');
      await tester.pump();
      expect(output.last, 'e');

      // Focus elsewhere: a tap, or a keybar key, refocuses without keyboard.
      focus.unfocus();
      await tester.pump();
      expect(input.hasAnyClients, isFalse);
      input.log.clear();
      await tapTerminal();
      expect(focus.hasFocus, isTrue);
      expect(input.hasAnyClients, isTrue);
      expect(shown(), isFalse);
      _commit(tester, 'f');
      await tester.pump();
      expect(output.last, 'f');
      focus.unfocus();
      await tester.pump();
      input.log.clear();
      await tester.tap(_find('Esc'));
      await tester.pump();
      expect(output.last, '\x1b');
      expect(focus.hasFocus, isTrue);
      expect(shown(), isFalse);

      // Mouse-reporting apps still get the tap, without the keyboard.
      terminal.write('\x1b[?1000h');
      input.log.clear();
      final before = output.length;
      await tapTerminal();
      expect(output.sublist(before).join(), startsWith('\x1b[M'));
      expect(shown(), isFalse);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
      semantics.dispose();
    },
    variant: _android,
  );

  testWidgets(
    'keyboard button fits 390 px and large text, and is disabled read-only',
    (tester) async {
      _setScreen(tester, const Size(390, 844));
      final terminal = Terminal();
      final focus = FocusNode();
      await tester.pumpWidget(_harness(terminal, focus, paneHeight: 700));
      await tester.pump();
      final keyboard = find.byKey(const ValueKey('terminal-keybar-keyboard'));
      Rect rect() => tester.getRect(keyboard);
      // Fixed beside More in the first row, collapsed and expanded.
      expect(
        rect().right,
        lessThanOrEqualTo(tester.getRect(_buttonOf('More')).left + 0.01),
      );
      expect(rect().top, 0 + tester.getRect(find.byType(TerminalKeybar)).top);
      expect(tester.getSize(keyboard), _atLeastTarget);
      await tester.tap(_find('More'));
      await tester.pump();
      expect(_keybarScrollables(), findsNothing);
      _expectOnScreen(tester, _expandedLabels, 390);
      expect(rect().right, lessThanOrEqualTo(390.01));
      expect(tester.getSize(keyboard), _atLeastTarget);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(rect().left, greaterThanOrEqualTo(-0.01));
      expect(rect().right, lessThanOrEqualTo(390.01));
      expect(tester.getSize(keyboard), _atLeastTarget);
      await tester.pumpWidget(
        _harness(terminal, focus, paneHeight: 700, readOnly: true),
      );
      await tester.pump();
      expect(tester.widget<TextButton>(keyboard).onPressed, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: _android,
  );

  testWidgets(
    'other platforms keep tap-to-type and have no keyboard button',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      await tester.pumpWidget(_harness(terminal, focus));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('terminal-keybar-keyboard')),
        findsNothing,
      );
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .showKeyboardOnTap,
        isTrue,
      );
      focus.unfocus();
      await tester.pump();
      tester.testTextInput.log.clear();
      await tester.tapAt(tester.getCenter(find.byType(TerminalView)));
      await tester.pump(kDoubleTapTimeout * 2);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        contains('TextInput.show'),
      );
      _commit(tester, 'x');
      await tester.pump();
      expect(output, ['x']);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.iOS,
    }),
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
  '↑': TerminalKey.arrowUp,
  '↓': TerminalKey.arrowDown,
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

const _arrowKeys = {
  '←': ValueKey('terminal-keybar-arrow-left'),
  '↑': ValueKey('terminal-keybar-arrow-up'),
  '↓': ValueKey('terminal-keybar-arrow-down'),
  '→': ValueKey('terminal-keybar-arrow-right'),
};

/// Finds a key by its label; arrows are drawn, so they resolve by key.
Finder _find(String label) {
  final arrow = _arrowKeys[label];
  return arrow == null ? find.text(label) : find.byKey(arrow);
}

Finder _buttonOf(String label) => _arrowKeys.containsKey(label)
    ? _find(label)
    : find.ancestor(of: _find(label), matching: find.byType(TextButton));

Finder _keybarScrollables() => find.descendant(
  of: find.byType(TerminalKeybar),
  matching: find.byType(Scrollable),
);

SemanticsData _pinSemantics(WidgetTester tester) => tester
    .getSemantics(find.byKey(const ValueKey('terminal-keybar-pin')))
    .getSemanticsData();

SemanticsData _keyboardSemantics(WidgetTester tester) => tester
    .getSemantics(find.byKey(const ValueKey('terminal-keybar-keyboard')))
    .getSemanticsData();

String _modifierValue(WidgetTester tester, String label) =>
    tester.getSemantics(_find(label)).getSemanticsData().value;

void _expectOnScreen(WidgetTester tester, List<String> labels, double width) {
  for (final label in labels) {
    final rect = tester.getRect(_buttonOf(label));
    expect(rect.left, greaterThanOrEqualTo(-0.01), reason: label);
    expect(rect.right, lessThanOrEqualTo(width + 0.01), reason: label);
    final text = tester.getRect(_find(label));
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
                  // Production wiring of every SSH terminal with a keybar.
                  showKeyboardOnTap: !terminalTouchKeyboardOnDemand,
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
