import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// Touch selection in the vendored xterm [TerminalView]: magnifier and
/// context preview while dragging, Copy/Paste toolbar after release.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final android = TargetPlatformVariant.only(TargetPlatform.android);

  testWidgets(
    'long-press drag drives the native magnifier and live context preview, '
    'release shows Copy/Paste and Copy keeps the selection while pressed',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      h.terminal.write('${'\r\n' * 12}alpha beta gamma delta epsilon\r\n');
      await tester.pump();
      final row = h.rowOf('alpha');

      final gesture = await tester.startGesture(h.cellCenter(7, row));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(h.selectedText, 'beta');
      expect(h.chrome.isDragging, isTrue);
      expect(find.byType(TextMagnifier), findsOneWidget);
      expect(find.byType(RawMagnifier), findsOneWidget);
      expect(
        h.chrome.magnifierInfo.globalGesturePosition,
        h.cellCenter(7, row),
      );
      expect(h.chrome.magnifierInfo.caretRect, h.cellRect(7, row));
      expect(h.previewText, 'alpha beta gamma delta epsilon');
      expect(find.byKey(_toolbarKey), findsNothing);

      // Drag to "delta": selection, magnifier focal point and preview follow.
      await gesture.moveTo(h.cellCenter(19, row));
      await tester.pump();
      await tester.pump();
      expect(h.selectedText, 'beta gamma delta');
      expect(
        h.chrome.magnifierInfo.globalGesturePosition,
        h.cellCenter(19, row),
      );
      expect(h.chrome.magnifierInfo.caretRect, h.cellRect(19, row));
      expect(h.previewSelected, 'beta gamma delta');

      // The preview is inside the pane and does not cover the magnifier.
      final pane = tester.getRect(find.byType(TerminalView));
      final previewRect = tester.getRect(find.byKey(_previewKey));
      expect(_contains(pane, previewRect), isTrue, reason: '$previewRect');
      final magnifierRect = tester.getRect(find.byType(RawMagnifier));
      expect(previewRect.overlaps(magnifierRect), isFalse);
      expect(previewRect.bottom, lessThanOrEqualTo(magnifierRect.top));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(TextMagnifier), findsNothing);
      expect(find.byKey(_previewKey), findsNothing);
      expect(find.byKey(_toolbarKey), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(h.selectedText, 'beta gamma delta');

      // Pressing (not yet releasing) Copy must not clear the selection.
      final press = await tester.startGesture(
        tester.getCenter(find.text('Copy')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.selectedText, 'beta gamma delta');
      expect(find.byKey(_toolbarKey), findsOneWidget);
      await press.up();
      await tester.pumpAndSettle();

      expect(h.clipboard, 'beta gamma delta');
      expect(h.controller.selection, isNull);
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(h.output, isEmpty, reason: 'selection must not reach the remote');
    },
  );

  testWidgets(
    'Paste is offered only when writable and sends the clipboard once',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester, clipboard: 'echo ok');
      h.terminal.write('${'\r\n' * 12}first second\r\n');
      await tester.pump();
      final row = h.rowOf('first');

      await h.longPress(h.cellCenter(8, row));
      expect(h.selectedText, 'second');
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(h.output, ['echo ok']);
      expect(h.controller.selection, isNull);
      expect(find.byKey(_toolbarKey), findsNothing);

      // Long press on blank cells: nothing to copy, Paste only.
      h.output.clear();
      await h.longPress(h.cellCenter(20, row + 3));
      expect(h.controller.selection, isNull);
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Paste'), findsOneWidget);
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(h.output, ['echo ok']);

      // Read-only views copy but never paste.
      h.output.clear();
      await h.rebuild(readOnly: true);
      await h.longPress(h.cellCenter(1, row));
      expect(h.selectedText, 'first');
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Paste'), findsNothing);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(h.clipboard, 'first');

      await h.longPress(h.cellCenter(20, row + 3));
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(h.output, isEmpty);
    },
  );

  testWidgets(
    'touch long press and scroll send no stray mouse report; a tap still '
    'reports press and release; mouse taps stay immediate',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      // Remote application enables X11 mouse reporting.
      h.terminal.write('\x1b[?1000h${'\r\n' * 12}mouse word here');
      await tester.pump();
      final row = h.rowOf('mouse');

      await h.longPress(h.cellCenter(7, row));
      expect(h.selectedText, 'word');
      expect(h.output, isEmpty, reason: 'long press leaked ${h.output}');

      // Tapping the terminal dismisses the toolbar and selection. The tap is
      // a real click for the remote application (press + release).
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(h.output, hasLength(2));
      h.output.clear();

      // A touch scroll is not a click.
      final drag = await tester.startGesture(h.cellCenter(5, row));
      await tester.pump(const Duration(milliseconds: 150));
      await drag.moveBy(const Offset(0, -120));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(h.output, isEmpty, reason: 'scroll leaked ${h.output}');

      // Desktop mouse: press is reported before release, as before.
      final mouse = await tester.startGesture(
        h.cellCenter(2, row),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(h.output, hasLength(1));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(h.output, hasLength(2));
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(find.byType(TextMagnifier), findsNothing);
    },
  );

  testWidgets(
    'mouse drag selection is unchanged and shows no touch chrome',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      final h = await _Harness.pump(tester);
      h.terminal.write('${'\r\n' * 5}select with mouse');
      await tester.pump();
      final row = h.rowOf('select');
      final mouse = await tester.startGesture(
        h.cellCenter(0, row),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(h.cellCenter(5, row));
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(h.selectedText, 'select');
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(find.byKey(_previewKey), findsNothing);
      expect(h.chrome.isToolbarVisible, isFalse);
    },
  );

  testWidgets(
    'toolbar is dismissed by focus loss, outside taps, session replacement '
    'and disposal',
    variant: android,
    (tester) async {
      final other = FocusNode();
      addTearDown(other.dispose);
      final h = await _Harness.pump(
        tester,
        extra: Focus(
          focusNode: other,
          child: GestureDetector(
            key: const Key('outside'),
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: const SizedBox(height: 40, width: double.infinity),
          ),
        ),
      );
      h.terminal.write('${'\r\n' * 12}focus target words');
      await tester.pump();
      final row = h.rowOf('focus');

      // Focus moves elsewhere: toolbar goes, selection stays.
      await h.longPress(h.cellCenter(1, row));
      expect(h.focusNode.hasFocus, isTrue);
      expect(find.byKey(_toolbarKey), findsOneWidget);
      other.requestFocus();
      await tester.pumpAndSettle();
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(h.selectedText, 'focus');

      // Tap outside the terminal and toolbar.
      h.focusNode.requestFocus();
      await h.longPress(h.cellCenter(7, row));
      expect(find.byKey(_toolbarKey), findsOneWidget);
      await tester.tap(find.byKey(const Key('outside')));
      await tester.pumpAndSettle();
      expect(find.byKey(_toolbarKey), findsNothing);

      // The view is re-bound to a new session.
      await h.longPress(h.cellCenter(7, row));
      expect(find.byKey(_toolbarKey), findsOneWidget);
      final replacement = Terminal();
      replacement.write('${'\r\n' * 12}new session');
      await h.rebuild(terminal: replacement);
      await tester.pumpAndSettle();
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(h.controller.selection, isNull);

      // Disposal mid-drag removes the magnifier and the preview.
      final gesture = await tester.startGesture(h.cellCenter(1, row));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(find.byType(TextMagnifier), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(find.byType(TextMagnifier), findsNothing);
      expect(find.byKey(_previewKey), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'CJK words and wide characters select and copy whole characters',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      h.terminal.write('${'\r\n' * 12}ls 你好世界 done');
      await tester.pump();
      final row = h.rowOf('ls');
      // Cell 6 is the trailing half of "好".
      await h.longPress(h.cellCenter(6, row));
      expect(h.selectedText, '你好世界');
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(h.clipboard, '你好世界');
    },
  );

  testWidgets(
    'selection in scrollback anchors the toolbar to the scrolled rows',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      for (var i = 0; i < 200; i++) {
        h.terminal.write('line$i payload\r\n');
      }
      await tester.pump();
      h.scrollController.jumpTo(0);
      await tester.pumpAndSettle();
      final row = h.rowOf('line3 ');
      expect(row, 3);
      await h.longPress(h.cellCenter(1, row));
      expect(h.selectedText, 'line3');
      final toolbar = tester.getRect(find.text('Copy'));
      final cell = h.cellRect(1, row);
      expect((toolbar.center.dx - cell.center.dx).abs(), lessThan(200));
      expect(
        toolbar.top >= cell.bottom || toolbar.bottom <= cell.top,
        isTrue,
        reason: 'toolbar $toolbar must not cover selected row $cell',
      );
      // Scrolling the selected rows out of view hides the toolbar until they
      // come back; the selection is kept.
      h.scrollController.jumpTo(h.scrollController.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(_toolbarKey), findsNothing);
      expect(h.selectedText, 'line3');
      h.scrollController.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.byKey(_toolbarKey), findsOneWidget);
    },
  );

  testWidgets(
    'preview stays compact at 390px, text scale 2, dark mode and open IME; '
    'toolbar labels are localized',
    variant: android,
    (tester) async {
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      final h = await _Harness.pump(
        tester,
        textScale: 2,
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        locale: const Locale('zh'),
      );
      final long = List.generate(40, (i) => 'w$i').join('-');
      h.terminal.write('${'\r\n' * 8}$long');
      await tester.pump();
      final row = h.rowOf('w0-');
      final pane = tester.getRect(find.byType(TerminalView));
      expect(pane.bottom, lessThanOrEqualTo(844 - 300 + 0.5));

      final gesture = await tester.startGesture(h.cellCenter(4, row));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(h.cellCenter(4, row + 2));
      await tester.pump();
      await tester.pump();

      final preview = tester.getRect(find.byKey(_previewKey));
      expect(_contains(pane, preview), isTrue, reason: '$preview in $pane');
      expect(preview.width, lessThanOrEqualTo(390));
      expect(preview.bottom, lessThanOrEqualTo(844 - 300));
      final text = tester.widget<Text>(find.byKey(_previewTextKey));
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      final context = tester.element(find.byKey(_previewKey));
      expect(Theme.of(context).brightness, Brightness.dark);
      // Long selection is elided in the middle and context stays bounded.
      expect(h.previewSelected, contains('…'));
      expect(h.previewSelected.length, lessThanOrEqualTo(26));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('粘贴'), findsOneWidget);
      final toolbar = tester.getRect(find.text('复制'));
      expect(toolbar.bottom, lessThanOrEqualTo(844 - 300 + 0.5));
    },
  );

  testWidgets(
    'Android swipe in a normal shell with scrollback scrolls history and '
    'never sends mouse/escape bytes; taps report live-screen rows',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      for (var i = 0; i < 300; i++) {
        h.terminal.write('history $i\r\n');
      }
      // A program (fzf, or a crashed vim/tmux) left SGR mouse reporting on
      // in the main buffer.
      h.terminal.write('\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      final scrollBack = h.terminal.buffer.scrollBack;
      expect(scrollBack, greaterThan(200));
      final bottom = h.scrollController.position.pixels;

      // Swipe down (towards older output) with a pause before moving, like a
      // hesitant finger: no press, no release, no wheel, no arrow keys.
      final swipe = await tester.startGesture(h.cellCenter(3, scrollBack + 4));
      await tester.pump(const Duration(milliseconds: 200));
      for (var i = 0; i < 6; i++) {
        await swipe.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await tester.pumpAndSettle();
      expect(h.output, isEmpty, reason: 'swipe leaked ${h.output}');
      expect(h.scrollController.position.pixels, lessThan(bottom));
      expect(h.controller.selection, isNull);

      // A tap on a history row (not on the live screen) is not reported.
      final historyRow = h.rowOf('history 100');
      h.scrollController.jumpTo(historyRow * h.view.renderTerminal.lineHeight);
      await tester.pumpAndSettle();
      await tester.tapAt(h.cellCenter(2, historyRow));
      await tester.pumpAndSettle();
      expect(h.output, isEmpty, reason: 'history tap leaked ${h.output}');

      // A tap on the live screen reports screen-relative 1-based rows.
      h.scrollController.jumpTo(h.scrollController.position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tapAt(h.cellCenter(2, scrollBack + 5));
      await tester.pumpAndSettle();
      expect(h.output, ['\x1b[<0;3;6M', '\x1b[<0;3;6m']);
    },
  );

  testWidgets(
    'X10 mouse reports encode 1-based screen rows',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      h.terminal.write('\x1b[?1000h');
      await tester.pump();
      await tester.tapAt(h.cellCenter(0, 0));
      await tester.pumpAndSettle();
      // Button 0 press, column 1, row 1; then release (button 3).
      expect(h.output, ['\x1b[M !!', '\x1b[M#!!']);
    },
  );

  testWidgets(
    'alternate-screen swipe sends wheel reports at the touched cell when the '
    'app uses the mouse, arrows otherwise, and nothing when read-only',
    variant: android,
    (tester) async {
      final h = await _Harness.pump(tester);
      // tmux/vim style: alternate screen with SGR mouse reporting.
      h.terminal.write('\x1b[?1049h\x1b[?1000h\x1b[?1006hvim buffer text');
      await tester.pump();
      await tester.pump();

      Future<void> swipeDown() async {
        final g = await tester.startGesture(h.cellCenter(4, 6));
        await tester.pump(const Duration(milliseconds: 200));
        for (var i = 0; i < 4; i++) {
          await g.moveBy(const Offset(0, 30));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await tester.pumpAndSettle();
      }

      await swipeDown();
      expect(h.output, isNotEmpty);
      for (final event in h.output) {
        expect(event, '\x1b[<64;5;7M', reason: 'unexpected ${h.output}');
      }

      // Without mouse reporting the alternate screen gets arrow keys.
      h.output.clear();
      h.terminal.write('\x1b[?1000l');
      await tester.pump();
      await swipeDown();
      expect(h.output, isNotEmpty);
      expect(h.output.toSet(), {'\x1b[A'});

      // A long press in the alternate screen selects locally, silently.
      h.output.clear();
      await h.longPress(h.cellCenter(1, 0));
      expect(h.selectedText, 'vim');
      expect(h.output, isEmpty);
      await tester.tapAt(h.cellCenter(10, 10));
      await tester.pumpAndSettle();

      // Read-only views never translate swipes into input.
      h.output.clear();
      await h.rebuild(readOnly: true);
      await swipeDown();
      expect(h.output, isEmpty);
    },
  );

  test('context preview reads a bounded window across soft wraps', () {
    final terminal = Terminal(maxLines: 10000);
    terminal.resize(20, 5);
    // 50 characters soft-wrap over three rows; then a hard line break.
    terminal.write(
      '${List.generate(50, (i) => String.fromCharCode(97 + i % 26)).join()}\r\nnext',
    );
    final buffer = terminal.buffer;
    final rowOf = buffer.lines.toList().indexWhere(
      (line) => line.getText().startsWith('abc'),
    );
    // Select "w" .. "b" crossing the first wrap (cells 22..27 overall).
    final description = TerminalSelectionContext.describe(
      buffer,
      BufferRangeLine(CellOffset(2, rowOf + 1), CellOffset(8, rowOf + 1)),
      contextCells: 6,
    )!;
    expect(description.selected, 'wxyzab');
    expect(description.before, 'qrstuv');
    expect(description.after, 'cdefgh');
    expect(description.truncatedBefore, isTrue);
    expect(description.truncatedAfter, isTrue);

    // After-context stops at the hard line break.
    final tail = TerminalSelectionContext.describe(
      buffer,
      BufferRangeLine(CellOffset(5, rowOf + 2), CellOffset(8, rowOf + 2)),
      contextCells: 20,
    )!;
    expect(tail.selected, 'tuv');
    expect(tail.after, 'wx');
    expect(tail.truncatedAfter, isFalse);
    // Before-context crosses the wrap into the previous row.
    expect(tail.before, 'zabcdefghijklmnopqrs');
    expect(tail.truncatedBefore, isTrue);

    // Selecting all scrollback reads only head and tail.
    for (var i = 0; i < 5000; i++) {
      terminal.write('row$i\r\n');
    }
    final all = TerminalSelectionContext.describe(
      buffer,
      BufferRangeLine(CellOffset(0, 0), CellOffset(0, buffer.lines.length - 1)),
    )!;
    expect(all.selectedElided, isTrue);
    expect(all.selected.characters.length, lessThanOrEqualTo(25));
  });
}

const _toolbarKey = ValueKey('terminal-touch-selection-toolbar');
const _previewKey = ValueKey('terminal-touch-selection-preview');
const _previewTextKey = ValueKey('terminal-touch-selection-preview-text');

bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.5 &&
    inner.top >= outer.top - 0.5 &&
    inner.right <= outer.right + 0.5 &&
    inner.bottom <= outer.bottom + 0.5;

class _Harness {
  _Harness(
    this.tester,
    this.terminal,
    this.extra,
    this.textScale,
    this.theme,
    this.locale,
  );

  final WidgetTester tester;
  Terminal terminal;
  final Widget? extra;
  final double textScale;
  final ThemeData? theme;
  final Locale? locale;
  final controller = TerminalController();
  final focusNode = FocusNode();
  final scrollController = ScrollController();
  final output = <String>[];
  String? clipboard;
  bool readOnly = false;

  static Future<_Harness> pump(
    WidgetTester tester, {
    String? clipboard,
    Widget? extra,
    double textScale = 1,
    ThemeData? theme,
    Locale? locale,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = _Harness(tester, Terminal(), extra, textScale, theme, locale);
    h.clipboard = clipboard;
    h.terminal.onOutput = h.output.add;
    addTearDown(h.controller.dispose);
    addTearDown(h.focusNode.dispose);
    addTearDown(h.scrollController.dispose);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            h.clipboard = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return h.clipboard == null ? null : {'text': h.clipboard};
          case 'Clipboard.hasStrings':
            return {'value': h.clipboard?.isNotEmpty == true};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await h._pumpView();
    return h;
  }

  Future<void> rebuild({bool? readOnly, Terminal? terminal}) async {
    if (readOnly != null) this.readOnly = readOnly;
    if (terminal != null) {
      this.terminal = terminal;
      terminal.onOutput = output.add;
    }
    await _pumpView();
  }

  Future<void> _pumpView() async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        locale: locale,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('en'), Locale('zh')],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [
              if (extra != null) extra!,
              Expanded(
                child: TerminalView(
                  terminal,
                  controller: controller,
                  focusNode: focusNode,
                  scrollController: scrollController,
                  autofocus: true,
                  readOnly: readOnly,
                  textStyle: const TerminalStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  TerminalViewState get view =>
      tester.state<TerminalViewState>(find.byType(TerminalView));

  TerminalTouchSelectionState get chrome => view.touchSelection!;

  String? get selectedText {
    final selection = controller.selection;
    return selection == null ? null : terminal.buffer.getText(selection);
  }

  int rowOf(String prefix) {
    final lines = terminal.buffer.lines.toList();
    final row = lines.indexWhere((line) => line.getText().startsWith(prefix));
    expect(row, isNot(-1), reason: 'no row starts with $prefix');
    return row;
  }

  Rect cellRect(int x, int y) {
    final render = view.renderTerminal;
    return render
        .cellRect(CellOffset(x, y))
        .shift(render.localToGlobal(Offset.zero));
  }

  Offset cellCenter(int x, int y) => cellRect(x, y).center;

  Future<void> longPress(Offset position) async {
    final gesture = await tester.startGesture(position);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Text get _previewTextWidget =>
      tester.widget<Text>(find.byKey(_previewTextKey));

  String get previewText =>
      _previewTextWidget.textSpan!.toPlainText(includeSemanticsLabels: false);

  String get previewSelected {
    final spans = (_previewTextWidget.textSpan! as TextSpan).children!;
    return (spans[1] as TextSpan).text!;
  }
}
