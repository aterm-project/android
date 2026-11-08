import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
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
    focus.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.windows}));

  final platforms = TargetPlatformVariant({
    TargetPlatform.linux,
    TargetPlatform.android,
  });

  testWidgets('modifier locks affect soft keys and leave IME Unicode intact', (
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
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.testTextInput.setClientArgs?['viewId'], tester.view.viewId);

    // The first committed character must be sent immediately, exactly once.
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'x'));
    await tester.pump();
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'c'));
    await tester.pump();
    expect(output, ['x', '\x03']);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    expect(output, ['x', '\x03']);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(output, ['x', '\x03', '你']);

    await tester.tap(find.text('Reset'));
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'c'));
    await tester.pump();
    expect(output, ['x', '\x03', '你', 'c']);
    expect(modifiers.map((m) => (m.ctrl, m.alt)), [
      (true, false),
      (false, false),
    ]);
    await tester.tap(find.text('Alt'));
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'b'));
    await tester.pump();
    expect(output.last, '\x1bb');
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  }, variant: platforms);

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
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
    variant: platforms,
  );

  testWidgets(
    '142 px pane exposes every expanded key in one row without losing IME',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      final keys = <String, TerminalKey>{
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
      final expected = <String>[];
      final reference = Terminal()..onOutput = expected.add;
      for (final entry in keys.entries) {
        reference.keyInput(entry.value);
        await press(entry.key);
      }
      expect(output, expected);
      await press('Ctrl');
      terminal.keyInput(TerminalKey.keyC);
      expect(output.last, '\x03');
      await press('Reset');
      await press('Alt');
      terminal.keyInput(TerminalKey.keyB);
      expect(output.last, '\x1bb');
      await press('Reset');
      await press('Paste');
      expect(output.last, '中文🙂');
      await press('Less');
      expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed);
      expect(tester.state(find.byType(TerminalView)), same(state));
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
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
    expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed * 3);
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
    expect(tester.getSize(find.byType(TerminalKeybar)).height, collapsed * 3);
    expect(tester.state(find.byType(TerminalView)), same(state));
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
  }, variant: TargetPlatformVariant({TargetPlatform.android}));

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
    variant: const TargetPlatformVariant({TargetPlatform.android}),
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
      await tester.tap(find.text('Ctrl'));
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
        expect(find.byTooltip(currentL10n.lockControlModifier), findsOneWidget);
        expect(tester.getSize(find.byType(TerminalKeybar)).height, 48);
        expect(tester.state(find.byType(TerminalView)), same(state));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        terminal.keyInput(TerminalKey.keyC);
        expect(output.last, '\x03');
        expect(find.text(paste), findsOneWidget);
        expect(find.text(reset), findsOneWidget);
        await tester.ensureVisible(find.text(paste));
        await tester.tap(find.text(paste));
        await tester.pump();
        expect(output.last, '中日🙂');
        await tester.ensureVisible(find.text(reset));
        await tester.tap(find.text(reset));
        await tester.pump();
        terminal.textInput('c');
        expect(output.last, 'c');
        await tester.ensureVisible(find.text('Ctrl'));
        await tester.tap(find.text('Ctrl'));
        await tester.pump();
        expect(tester.state(find.byType(TerminalView)), same(state));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
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
    'read-only, terminal replacement and disposal release modifiers',
    (tester) async {
      final output = <String>[];
      final first = Terminal()..onOutput = output.add;
      final originalHandler = first.inputHandler;
      final second = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      final modifiers = <TerminalKeyModifiers>[];
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump();
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      await tester.pumpWidget(
        _harness(first, focus, readOnly: true, onChanged: modifiers.add),
      );
      await tester.pump();
      expect(modifiers.last.ctrl, isFalse);
      await tester.tap(find.text('Tab'));
      expect(output, isEmpty);
      expect(first.keyInput(TerminalKey.keyC), isFalse);
      await tester.pumpWidget(_harness(first, focus, onChanged: modifiers.add));
      await tester.pump();
      await tester.tap(find.text('Alt'));
      await tester.pump();
      await tester.pumpWidget(
        _harness(second, focus, onChanged: modifiers.add),
      );
      await tester.pump();
      expect(modifiers.last.alt, isFalse);
      expect(first.inputHandler, same(originalHandler));
      expect(second.keyInput(TerminalKey.keyB), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.inputHandler, same(originalHandler));
      focus.dispose();
    },
  );
}

Widget _harness(
  Terminal terminal,
  FocusNode focus, {
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
