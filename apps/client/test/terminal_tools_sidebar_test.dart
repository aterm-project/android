import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/terminal/terminal_tools.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_tools_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/l10n_fixture.dart';
import 'package:aterm_client/l10n/l10n.dart';

void main() {
  useAppLocaleFixture('zh');
  test('query retention and command insertion have independent bounds', () {
    final history = TerminalSearchHistory();
    for (var i = 0; i < 40; i++) {
      history.remember('query $i');
    }
    history.remember('query 25');
    expect(history.items.length, 20);
    expect(history.items.first, 'query 25');
    expect(history.items.where((q) => q == 'query 25').length, 1);
    expect(isSafeTerminalCommand('echo test'), true);
    for (final unsafe in [
      'echo test\n',
      'echo test\r',
      '\x1b[1G',
      '\u0085',
      'a' * 4097,
    ]) {
      expect(isSafeTerminalCommand(unsafe), false);
    }
    expect(
      terminalQuickCommands(const [
        SnippetRecord(id: 'one', title: 'One', body: 'pwd'),
        SnippetRecord(id: 'two', title: 'Two', body: 'pwd\nls'),
        SnippetRecord(
          id: 'three',
          title: 'Three',
          body: 'print(1)',
          shell: 'python',
        ),
      ]).map((e) => e.id),
      ['one'],
    );
  });

  testWidgets(
    'right sidebar remembers searches, filters history and fills without Enter',
    (tester) async {
      final query = TextEditingController();
      final focus = FocusNode();
      final history = TerminalSearchHistory();
      final inserted = <String>[];
      var section = TerminalToolsSection.search;
      var open = true;
      var size = const Size(1100, 650);
      final terminalKey = GlobalKey<_TerminalState>();
      Future<void> pump() async {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: StatefulBuilder(
              builder: (context, update) => Scaffold(
                body: TerminalToolsLayout(
                  child: _Terminal(key: terminalKey),
                  sidebar: !open
                      ? null
                      : TerminalToolsSidebar(
                          section: section,
                          onSection: (value) => update(() => section = value),
                          onClose: () => update(() => open = false),
                          query: query,
                          queryFocus: focus,
                          onQuery: (_) {},
                          searchStatus: '1 of 2 matches',
                          previous: () {},
                          next: () {},
                          searchHistory: history,
                          loadCommands: () async => const [
                            TerminalCommandItem(
                              id: 'quick',
                              title: '工作目录',
                              command: 'pwd',
                            ),
                          ],
                          editCommand: (_) async {},
                          deleteCommand: (_) async {},
                          history: () => const [
                            TerminalCommandItem(
                              id: 'history',
                              title: 'Yesterday',
                              command: 'echo previous',
                            ),
                          ],
                          onInsert: (value) {
                            inserted.add(value);
                            return true;
                          },
                          onConfigureHistory: () async {},
                          onClearHistory: () async {},
                        ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      try {
        await pump();
        final mountedTerminal = terminalKey.currentState;
        await tester.enterText(
          find.byKey(const ValueKey('terminal-sidebar-query')),
          'needle',
        );
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(history.items, ['needle']);
        expect(find.text('needle'), findsNWidgets(2));
        // Section selectors are icons with localized tooltips and exclusive
        // selected semantics; the selected section name is shown as a title.
        expect(find.byTooltip(currentL10n.search), findsOneWidget);
        expect(find.byTooltip(currentL10n.quickCommands), findsOneWidget);
        expect(find.byTooltip(currentL10n.inputHistory), findsOneWidget);
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('terminal-tools-section-search')),
          ),
          matchesSemantics(
            label: currentL10n.search,
            isButton: true,
            isSelected: true,
            hasSelectedState: true,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
          ),
        );
        // Test platform is Android: section icons keep a real 48x48 hit box.
        expect(
          tester.getSize(
            find.byKey(const ValueKey('terminal-tools-section-search')),
          ),
          const Size(48, 48),
        );
        await tester.tap(find.byTooltip(currentL10n.quickCommands));
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(
            find.byKey(const ValueKey('terminal-tools-section-commands')),
          ),
          matchesSemantics(
            label: currentL10n.quickCommands,
            isButton: true,
            isSelected: true,
            hasSelectedState: true,
            isInMutuallyExclusiveGroup: true,
            hasTapAction: true,
          ),
        );
        expect(
          find.byKey(const ValueKey('terminal-tools-section-title')),
          findsOneWidget,
        );
        await tester.tap(find.text('pwd'));
        expect(inserted, ['pwd']);
        await tester.tap(find.byTooltip(currentL10n.inputHistory));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('terminal-history-filter')),
          'previous',
        );
        await tester.pump();
        await tester.tap(find.text('echo previous'));
        expect(inserted, ['pwd', 'echo previous']);
        // Android landscape leaves about 230px for the workspace when the
        // keyboard is open. Resizing must neither overflow nor remount input.
        section = TerminalToolsSection.search;
        await pump();
        await tester.tap(find.byKey(const ValueKey('terminal-sidebar-query')));
        await tester.pump();
        final queryFocus = FocusManager.instance.primaryFocus;
        size = const Size(1100, 230);
        await pump();
        expect(tester.takeException(), isNull);
        expect(FocusManager.instance.primaryFocus, same(queryFocus));
        expect(query.text, 'needle');
        expect(terminalKey.currentState, same(mountedTerminal));
        for (final value in TerminalToolsSection.values) {
          final label = switch (value) {
            TerminalToolsSection.search => '搜索',
            TerminalToolsSection.commands => '快捷指令',
            TerminalToolsSection.history => '输入历史',
          };
          final selector = find.byKey(
            ValueKey('terminal-tools-section-${value.name}'),
          );
          expect(find.byTooltip(label), findsOneWidget);
          await tester.ensureVisible(selector);
          await tester.tap(selector);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('terminal-tools-section-title')),
                )
                .data,
            label,
          );
          expect(tester.takeException(), isNull);
          final item = switch (value) {
            TerminalToolsSection.search => find.text(currentL10n.clear),
            TerminalToolsSection.commands => find.text('pwd'),
            TerminalToolsSection.history => find.text('echo previous'),
          };
          await tester.ensureVisible(item);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(terminalKey.currentState, same(mountedTerminal));
        }
        size = const Size(320, 650);
        await pump();
        expect(tester.takeException(), isNull);
        expect(terminalKey.currentState, same(mountedTerminal));
        await tester.tap(find.byKey(const ValueKey('terminal-tools-close')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('terminal-tools-sidebar')),
          findsNothing,
        );
        expect(terminalKey.currentState, same(mountedTerminal));
        expect(history.items, ['needle']);
      } finally {
        await tester.pumpWidget(const SizedBox());
        query.dispose();
        focus.dispose();
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}

class _Terminal extends StatefulWidget {
  const _Terminal({super.key});
  @override
  State<_Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<_Terminal> {
  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}
