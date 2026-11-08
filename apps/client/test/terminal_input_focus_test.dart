import 'dart:ui' show SemanticsAction, Tristate;

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hardware keyboard mode sends Enter to terminal output', (
    tester,
  ) async {
    final terminal = Terminal();
    final focusNode = FocusNode();
    final output = <String>[];
    terminal.onOutput = output.add;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              focusNode: focusNode,
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.binding.testTextInput.hasAnyClients, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(output, ['\r']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      focusNode.dispose();
    }
  });

  testWidgets('soft keyboard newline action sends one terminal Enter', (
    tester,
  ) async {
    final terminal = Terminal();
    final focusNode = FocusNode();
    final output = <String>[];
    terminal.onOutput = output.add;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              focusNode: focusNode,
              autofocus: true,
              hardwareKeyboardOnly: false,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(focusNode.hasFocus, isTrue);
      expect(tester.binding.testTextInput.hasAnyClients, isTrue);
      await tester.binding.testTextInput.receiveAction(TextInputAction.newline);
      expect(output, ['\r']);
      await tester.binding.testTextInput.receiveAction(TextInputAction.done);
      expect(output, ['\r', '\r']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      focusNode.dispose();
    }
  });

  testWidgets(
    'connected TerminalView receives typed input after reconnect focus request',
    (tester) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final firstConnection = _RecordingSshConnection();
      final semantics = tester.ensureSemantics();
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.terminal
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..selectedHost = const HostRecord(
              id: 'terminal-input-host',
              name: 'Terminal input fixture',
              address: '127.0.0.1',
              username: 'fixture',
            )
            ..terminalConnection = firstConnection;

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(find.byType(TerminalView), findsOneWidget);
        var terminalState = tester.state<TerminalViewState>(
          find.byType(TerminalView),
        );
        expect(terminalState.hasInputConnection, isTrue);
        var terminal = tester.widget<TerminalView>(find.byType(TerminalView));
        expect(terminal.focusNode?.hasFocus, isTrue);
        expect(terminal.hardwareKeyboardOnly, isFalse);
        expect(tester.binding.testTextInput.hasAnyClients, isTrue);
        expect(_terminalSemantics(tester).properties.enabled, isTrue);
        expect(find.semantics.byLabel('SSH terminal input'), findsOneWidget);
        expect(
          _terminalSemanticsData(tester).flagsCollection.isTextField,
          isTrue,
        );
        expect(
          _terminalSemanticsData(tester).flagsCollection.isFocused,
          Tristate.isTrue,
          reason: tester.semantics
              .simulatedAccessibilityTraversal()
              .map((node) => '${node.id}: ${node.getSemanticsData()}')
              .join('\n'),
        );
        expect(
          _terminalSemanticsData(tester).flagsCollection.isEnabled,
          Tristate.isTrue,
        );
        terminal.focusNode!.unfocus();
        await tester.pump();
        await tester.pump();
        expect(terminal.focusNode!.hasFocus, isFalse);
        expect(terminalState.hasInputConnection, isFalse);
        expect(
          _terminalSemanticsData(tester).flagsCollection.isFocused,
          Tristate.isFalse,
        );
        tester.semantics.performAction(
          find.semantics.byLabel('SSH terminal input'),
          SemanticsAction.focus,
        );
        // A focus event from the semantics editor must move the real xterm
        // FocusNode and reopen the input connection.
        await tester.pump();
        await tester.pump();
        expect(terminalState.hasInputConnection, isTrue);
        expect(terminal.focusNode!.hasFocus, isTrue);
        expect(
          _terminalSemanticsData(tester).flagsCollection.isFocused,
          Tristate.isTrue,
        );

        terminal.focusNode!.unfocus();
        await tester.pump();
        await tester.pump();
        expect(terminalState.hasInputConnection, isFalse);
        await tester.tap(find.byType(TerminalView));
        await tester.pump(const Duration(milliseconds: 350));
        expect(terminalState.hasInputConnection, isTrue);
        expect(tester.binding.testTextInput.hasAnyClients, isTrue);

        tester.binding.testTextInput.enterText('printf first-session');
        await tester.pump();
        expect(firstConnection.inputs, ['printf first-session']);

        app.terminalConnection = null;
        app.notifyListeners();
        await tester.pump();
        expect(find.byType(TerminalView), findsNothing);
        expect(tester.binding.testTextInput.hasAnyClients, isFalse);

        final secondConnection = _RecordingSshConnection();
        app.terminalConnection = secondConnection;
        app.notifyListeners();
        await tester.pump();
        await tester.pump();

        expect(find.byType(TerminalView), findsOneWidget);
        terminalState = tester.state<TerminalViewState>(
          find.byType(TerminalView),
        );
        expect(terminalState.hasInputConnection, isTrue);
        terminal = tester.widget<TerminalView>(find.byType(TerminalView));
        expect(terminal.focusNode?.hasFocus, isTrue);
        expect(tester.binding.testTextInput.hasAnyClients, isTrue);
        tester.binding.testTextInput.enterText('printf second-session');
        await tester.pump();
        expect(secondConnection.inputs, ['printf second-session']);
        expect(firstConnection.inputs, ['printf first-session']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        app.dispose();
        await database.close();
      }
    },
  );
}

Semantics _terminalSemantics(WidgetTester tester) => tester.widget<Semantics>(
  find.byWidgetPredicate(
    (widget) =>
        widget is Semantics && widget.properties.label == 'SSH terminal input',
  ),
);

_terminalSemanticsData(WidgetTester tester) => tester
    .getSemantics(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == 'SSH terminal input',
      ),
    )
    .getSemanticsData();

class _RecordingSshConnection implements SshConnection {
  final List<String> inputs = [];

  @override
  Stream<String> get output => const Stream<String>.empty();

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
