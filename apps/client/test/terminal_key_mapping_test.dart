import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('cursor application mode is independent of numeric keypad mode', () {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;
    terminal.keyInput(TerminalKey.arrowUp);
    terminal.write('\x1b[?1h');
    terminal.keyInput(TerminalKey.arrowUp);
    terminal.write('\x1b[?1l\x1b=');
    terminal.keyInput(TerminalKey.arrowUp);
    expect(output, ['\x1b[A', '\x1bOA', '\x1b[A']);
  });

  test('Alt letter preserves case on both key and character paths', () {
    final output = <String>[];
    final terminal = Terminal(platform: TerminalTargetPlatform.windows)
      ..onOutput = output.add;
    terminal.keyInput(TerminalKey.keyB, alt: true);
    terminal.keyInput(TerminalKey.keyB, alt: true, shift: true);
    terminal.charInput('b'.codeUnitAt(0), alt: true);
    expect(output, ['\x1bb', '\x1bB', '\x1bb']);
  });

  testWidgets(
    'Ctrl A and V reach the shell instead of GUI shortcuts',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              focusNode: focus,
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(output, ['\x01', '\x16']);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
