import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/terminal/terminal_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('terminal shortcut matching', () {
    test('maps mod locally and requires an exact chord', () {
      final bindings = TerminalShortcutBindings.defaults;
      expect(
        terminalShortcutActionForKeyEvent(
          bindings: bindings,
          logicalKey: LogicalKeyboardKey.keyF,
          controlPressed: true,
          metaPressed: false,
          altPressed: true,
          shiftPressed: true,
          platform: TargetPlatform.linux,
        ),
        TerminalShortcutAction.search,
      );
      expect(
        terminalShortcutActionForKeyEvent(
          bindings: bindings,
          logicalKey: LogicalKeyboardKey.keyF,
          controlPressed: false,
          metaPressed: true,
          altPressed: true,
          shiftPressed: true,
          platform: TargetPlatform.macOS,
        ),
        TerminalShortcutAction.search,
      );
      expect(
        terminalShortcutActionForKeyEvent(
          bindings: bindings,
          logicalKey: LogicalKeyboardKey.keyF,
          controlPressed: true,
          metaPressed: false,
          altPressed: false,
          shiftPressed: true,
          platform: TargetPlatform.linux,
        ),
        isNull,
      );
      expect(
        terminalShortcutActionForKeyEvent(
          bindings: bindings,
          logicalKey: LogicalKeyboardKey.keyF,
          controlPressed: true,
          metaPressed: true,
          altPressed: true,
          shiftPressed: true,
          platform: TargetPlatform.linux,
        ),
        isNull,
      );
    });

    test('default chords avoid browser-reserved Mod+F/G/W', () {
      final bindings = TerminalShortcutBindings.defaults;
      expect(bindings.chordFor(TerminalShortcutAction.search), isNot('mod+f'));
      expect(
        bindings.chordFor(TerminalShortcutAction.searchNext),
        isNot('mod+g'),
      );
      expect(
        bindings.chordFor(TerminalShortcutAction.disconnect),
        isNot('mod+w'),
      );
    });

    test('dispatches each configured semantic action on its exact chord', () {
      final bindings = TerminalShortcutBindings.fromBindings({
        TerminalShortcutAction.search: 'mod+alt+e',
        TerminalShortcutAction.searchNext: 'mod+alt+g',
        TerminalShortcutAction.searchPrevious: 'mod+alt+h',
        TerminalShortcutAction.disconnect: 'mod+alt+d',
      });

      for (final action in TerminalShortcutAction.values) {
        final actions = <TerminalShortcutAction>[];
        final key = _keyForChord(bindings.chordFor(action));
        final result = dispatchTerminalShortcut(
          bindings: bindings,
          logicalKey: key,
          controlPressed: true,
          metaPressed: false,
          altPressed: true,
          shiftPressed: false,
          platform: TargetPlatform.windows,
          onAction: actions.add,
        );

        expect(result, KeyEventResult.handled, reason: action.id);
        expect(actions, [action], reason: action.id);
      }
    });

    test(
      'rejects wrong platform and additional modifiers for every action',
      () {
        final bindings = TerminalShortcutBindings.fromBindings({
          TerminalShortcutAction.search: 'mod+alt+e',
          TerminalShortcutAction.searchNext: 'mod+alt+g',
          TerminalShortcutAction.searchPrevious: 'mod+alt+h',
          TerminalShortcutAction.disconnect: 'mod+alt+d',
        });

        for (final action in TerminalShortcutAction.values) {
          final key = _keyForChord(bindings.chordFor(action));
          for (final state in [
            // Windows maps `mod` to Control, so Meta alone is incorrect.
            (
              control: false,
              meta: true,
              alt: true,
              shift: false,
              platform: TargetPlatform.windows,
            ),
            // Supplying both primary modifiers adds a modifier to the chord.
            (
              control: true,
              meta: true,
              alt: true,
              shift: false,
              platform: TargetPlatform.windows,
            ),
            // Shift is not present in any of these configured chords.
            (
              control: true,
              meta: false,
              alt: true,
              shift: true,
              platform: TargetPlatform.windows,
            ),
          ]) {
            final actions = <TerminalShortcutAction>[];
            final result = dispatchTerminalShortcut(
              bindings: bindings,
              logicalKey: key,
              controlPressed: state.control,
              metaPressed: state.meta,
              altPressed: state.alt,
              shiftPressed: state.shift,
              platform: state.platform,
              onAction: actions.add,
            );

            expect(result, KeyEventResult.ignored, reason: action.id);
            expect(actions, isEmpty, reason: action.id);
          }
        }
      },
    );

    test('maps mod to Control on Windows and Meta on iOS', () {
      final bindings = TerminalShortcutBindings.defaults;
      final actions = <TerminalShortcutAction>[];
      final key = _keyForChord(
        bindings.chordFor(TerminalShortcutAction.search),
      );

      KeyEventResult dispatch({
        required TargetPlatform platform,
        required bool control,
        required bool meta,
      }) => dispatchTerminalShortcut(
        bindings: bindings,
        logicalKey: key,
        controlPressed: control,
        metaPressed: meta,
        altPressed: true,
        shiftPressed: true,
        platform: platform,
        onAction: actions.add,
      );

      expect(
        dispatch(platform: TargetPlatform.windows, control: true, meta: false),
        KeyEventResult.handled,
      );
      expect(
        dispatch(platform: TargetPlatform.iOS, control: false, meta: true),
        KeyEventResult.handled,
      );
      expect(
        dispatch(platform: TargetPlatform.windows, control: false, meta: true),
        KeyEventResult.ignored,
      );
      expect(
        dispatch(platform: TargetPlatform.iOS, control: true, meta: false),
        KeyEventResult.ignored,
      );
      expect(actions, [
        TerminalShortcutAction.search,
        TerminalShortcutAction.search,
      ]);
    });
  });

  testWidgets(
    'shortcuts run only in terminal focus and unmatched keys pass through',
    (tester) async {
      final terminal = Terminal();
      final terminalFocus = FocusNode();
      final searchFocus = FocusNode();
      final searchController = TextEditingController();
      final terminalOutput = <String>[];
      final actions = <TerminalShortcutAction>[];
      terminal.onOutput = terminalOutput.add;
      final bindings = TerminalShortcutBindings.defaults;

      KeyEventResult handleTerminalKey(FocusNode _, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        return dispatchTerminalShortcut(
          bindings: bindings,
          logicalKey: event.logicalKey,
          controlPressed: HardwareKeyboard.instance.isControlPressed,
          metaPressed: HardwareKeyboard.instance.isMetaPressed,
          altPressed: HardwareKeyboard.instance.isAltPressed,
          shiftPressed: HardwareKeyboard.instance.isShiftPressed,
          platform: TargetPlatform.linux,
          onAction: actions.add,
        );
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: TerminalView(
                      terminal,
                      focusNode: terminalFocus,
                      autofocus: true,
                      hardwareKeyboardOnly: true,
                      onKeyEvent: handleTerminalKey,
                    ),
                  ),
                  TextField(
                    key: const ValueKey('search_input'),
                    controller: searchController,
                    focusNode: searchFocus,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        expect(terminalFocus.hasFocus, isTrue);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF, character: 'F');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        expect(actions, [TerminalShortcutAction.search]);
        expect(terminalOutput, isEmpty);

        await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
        expect(terminalOutput, ['a']);

        searchFocus.requestFocus();
        await tester.pump();
        expect(searchFocus.hasFocus, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB, character: 'b');
        expect(actions, [TerminalShortcutAction.search]);
        expect(terminalOutput, ['a']);
        await tester.enterText(
          find.byKey(const ValueKey('search_input')),
          'query',
        );
        expect(searchController.text, 'query');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        terminalFocus.dispose();
        searchFocus.dispose();
        searchController.dispose();
      }
    },
  );
}

LogicalKeyboardKey _keyForChord(String chord) {
  final key = chord.split('+').last;
  return switch (key) {
    'a' => LogicalKeyboardKey.keyA,
    'b' => LogicalKeyboardKey.keyB,
    'd' => LogicalKeyboardKey.keyD,
    'e' => LogicalKeyboardKey.keyE,
    'f' => LogicalKeyboardKey.keyF,
    'g' => LogicalKeyboardKey.keyG,
    'h' => LogicalKeyboardKey.keyH,
    _ => throw ArgumentError.value(chord, 'chord', 'Unexpected test key'),
  };
}
