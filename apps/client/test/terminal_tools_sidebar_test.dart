import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/terminal/terminal_tools.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_tools_sidebar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/l10n_fixture.dart';
import 'package:aterm_client/l10n/l10n.dart';

void main() {
  useAppLocaleFixture('zh');
  resizeTests();
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
        // No "Terminal tools" heading; close shares the section tabs row.
        expect(find.text(currentL10n.terminalTools), findsNothing);
        expect(
          tester
              .getCenter(find.byKey(const ValueKey('terminal-tools-close')))
              .dy,
          moreOrLessEquals(
            tester
                .getCenter(
                  find.byKey(const ValueKey('terminal-tools-section-search')),
                )
                .dy,
            epsilon: 1,
          ),
        );
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

/// Harness for the resize tests. The outer [Listener] mimics the workspace
/// pane listener that moves focus to the terminal on every pointer down.
class _ResizeHarness {
  _ResizeHarness(this.tester);
  final WidgetTester tester;
  final query = TextEditingController();
  final queryFocus = FocusNode();
  final terminalFocus = FocusNode();
  final otherPaneFocus = FocusNode();
  final terminalKey = GlobalKey<_TerminalState>();
  final history = TerminalSearchHistory();
  var section = TerminalToolsSection.search;
  var open = true;
  var layoutKey = 0;
  var size = const Size(1100, 650);

  Finder get sidebar => find.byKey(const ValueKey('terminal-tools-sidebar'));
  Finder get handle =>
      find.byKey(const ValueKey('terminal-tools-resize-handle'));
  Finder get close => find.byKey(const ValueKey('terminal-tools-close'));
  double get sidebarWidth => tester.getSize(sidebar).width;
  double get terminalWidth => tester.getSize(find.byType(_Terminal)).width;

  Future<void> pump() async {
    await tester.binding.setSurfaceSize(size);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: StatefulBuilder(
          builder: (context, update) => Scaffold(
            bottomNavigationBar: Focus(
              focusNode: otherPaneFocus,
              child: const SizedBox(height: 0),
            ),
            body: Listener(
              onPointerDown: (_) => terminalFocus.requestFocus(),
              child: TerminalToolsLayout(
                key: ValueKey('layout-$layoutKey'),
                sidebar: !open
                    ? null
                    : TerminalToolsSidebar(
                        section: section,
                        onSection: (value) => update(() => section = value),
                        onClose: () => update(() => open = false),
                        query: query,
                        queryFocus: queryFocus,
                        onQuery: (_) {},
                        searchStatus: '',
                        previous: null,
                        next: null,
                        searchHistory: history,
                        loadCommands: () async => const [],
                        editCommand: (_) async {},
                        deleteCommand: (_) async {},
                        history: () => const [],
                        onInsert: (_) => true,
                        onConfigureHistory: () async {},
                        onClearHistory: () async {},
                      ),
                child: _Terminal(key: terminalKey, focusNode: terminalFocus),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> drag(double dx) async {
    await tester.drag(handle, Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  void expectSidebarFits() {
    expect(tester.takeException(), isNull);
    final screen = Offset.zero & size;
    for (final finder in [sidebar, close]) {
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(-0.01));
      expect(rect.right, lessThanOrEqualTo(screen.right + 0.01));
    }
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox());
    query.dispose();
    queryFocus.dispose();
    terminalFocus.dispose();
    otherPaneFocus.dispose();
    await tester.binding.setSurfaceSize(null);
    TerminalToolsLayout.sharedWidth.value = TerminalToolsLayout.defaultWidth;
  }
}

void resizeTests() {
  testWidgets(
    'desktop sidebar resizes from its left edge within viewport bounds',
    (tester) async {
      final h = _ResizeHarness(tester);
      final semantics = tester.ensureSemantics();
      try {
        await h.pump();
        final mounted = h.terminalKey.currentState;
        expect(h.sidebarWidth, TerminalToolsLayout.defaultWidth);
        expect(h.terminalWidth, 1100 - TerminalToolsLayout.defaultWidth);
        expect(find.text(currentL10n.terminalTools), findsNothing);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(h.handle));
        addTearDown(mouse.removePointer);
        await tester.pump();
        expect(
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
          SystemMouseCursors.resizeColumn,
        );
        await mouse.moveTo(Offset.zero);

        // Focus + text in the search field survive a drag even though the
        // ancestor pane listener grabs focus for the terminal on pointer down.
        await tester.enterText(
          find.byKey(const ValueKey('terminal-sidebar-query')),
          'needle',
        );
        expect(h.queryFocus.hasFocus, isTrue);
        await h.drag(-100);
        expect(h.sidebarWidth, moreOrLessEquals(440, epsilon: .5));
        expect(h.terminalWidth, moreOrLessEquals(660, epsilon: .5));
        expect(h.queryFocus.hasFocus, isTrue);
        expect(h.query.text, 'needle');
        // Focus outside this sidebar (e.g. another pane) is not pulled back
        // after a drag; the pane's own pointer handling decides.
        h.otherPaneFocus.requestFocus();
        await tester.pump();
        await h.drag(-10);
        expect(h.sidebarWidth, moreOrLessEquals(450, epsilon: .5));
        expect(h.terminalFocus.hasFocus, isTrue);
        expect(h.otherPaneFocus.hasFocus, isFalse);
        h.queryFocus.requestFocus();
        await tester.pump();

        // Max keeps a usable terminal: min(60% of 1100, 1100 - 400) = 660.
        await h.drag(-2000);
        expect(h.sidebarWidth, moreOrLessEquals(660, epsilon: .5));
        expect(h.terminalWidth, greaterThanOrEqualTo(400));
        h.expectSidebarFits();

        // A narrower window clamps the display only; widening restores it.
        h.size = const Size(900, 650);
        await h.pump();
        expect(h.sidebarWidth, moreOrLessEquals(500, epsilon: .5));
        expect(h.terminalWidth, moreOrLessEquals(400, epsilon: .5));
        h.expectSidebarFits();
        h.size = const Size(1100, 650);
        await h.pump();
        expect(h.sidebarWidth, moreOrLessEquals(660, epsilon: .5));

        await h.drag(2000);
        expect(h.sidebarWidth, TerminalToolsLayout.minWidth);
        h.expectSidebarFits();

        // Keyboard: Left widens, Right narrows, clamped at the minimum.
        final handleFocus = Focus.of(
          tester.element(
            find.descendant(of: h.handle, matching: find.byType(MouseRegion)),
          ),
        );
        handleFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(h.sidebarWidth, TerminalToolsLayout.minWidth + 32);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(h.sidebarWidth, TerminalToolsLayout.minWidth);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        const width = TerminalToolsLayout.minWidth + 16;
        expect(h.sidebarWidth, width);

        expect(
          tester.getSemantics(h.handle),
          isSemantics(
            label: currentL10n.sidebarResizeHandle,
            value: currentL10n.sidebarResizeWidthValue(width.round()),
            hint: currentL10n.sidebarResizeHint,
            isSlider: true,
            hasIncreaseAction: true,
            hasDecreaseAction: true,
          ),
        );

        // Width survives section switches, close/reopen and a remount.
        for (final value in TerminalToolsSection.values) {
          await tester.tap(
            find.byKey(ValueKey('terminal-tools-section-${value.name}')),
          );
          await tester.pumpAndSettle();
          expect(h.sidebarWidth, width);
        }
        await tester.tap(h.close);
        await tester.pumpAndSettle();
        expect(h.sidebar, findsNothing);
        expect(h.handle, findsNothing);
        expect(h.terminalWidth, 1100);
        h.open = true;
        await h.pump();
        expect(h.sidebarWidth, width);
        expect(h.terminalKey.currentState, same(mounted));
        h.layoutKey++;
        await h.pump();
        expect(h.sidebarWidth, width);
        expect(h.query.text, 'needle');
      } finally {
        semantics.dispose();
        await h.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('390px overlay sidebar resizes without losing close', (
    tester,
  ) async {
    final h = _ResizeHarness(tester)..size = const Size(390, 800);
    try {
      await h.pump();
      final mounted = h.terminalKey.currentState;
      // Overlay mode: the terminal keeps the full width underneath.
      expect(h.sidebarWidth, TerminalToolsLayout.defaultWidth);
      expect(h.terminalWidth, 390);
      expect(tester.getSize(h.handle).width, 20);
      h.expectSidebarFits();
      await h.drag(-200);
      expect(h.sidebarWidth, 390);
      h.expectSidebarFits();
      await h.drag(1000);
      expect(h.sidebarWidth, TerminalToolsLayout.minWidth);
      h.expectSidebarFits();
      h.size = const Size(320, 640);
      await h.pump();
      h.expectSidebarFits();
      for (final value in TerminalToolsSection.values) {
        await tester.tap(
          find.byKey(ValueKey('terminal-tools-section-${value.name}')),
        );
        await tester.pumpAndSettle();
        h.expectSidebarFits();
      }
      await tester.tap(h.close);
      await tester.pumpAndSettle();
      expect(h.sidebar, findsNothing);
      expect(h.terminalKey.currentState, same(mounted));
    } finally {
      await h.dispose();
    }
  });
}

class _Terminal extends StatefulWidget {
  const _Terminal({this.focusNode, super.key});
  final FocusNode? focusNode;
  @override
  State<_Terminal> createState() => _TerminalState();
}

class _TerminalState extends State<_Terminal> {
  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    child: const ColoredBox(color: Colors.black),
  );
}
