import 'dart:ui' as ui;

import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('layout eviction releases native resources and preserves recently used entries', () {
    final cache = ParagraphCache(2);
    addTearDown(cache.clear);
    ui.Paragraph put(int key) => cache.performAndCacheLayout(
      '$key',
      const TextStyle(fontSize: 14),
      TextScaler.noScaling,
      key,
    );
    final first = put(1), second = put(2);
    expect(cache.getLayoutFromCache(1), same(first));
    final third = put(3);
    expect(second.debugDisposed, isTrue);
    expect(first.debugDisposed, isFalse);
    expect(cache.getLayoutFromCache(2), isNull);
    final replacement = put(1);
    expect(first.debugDisposed, isTrue);
    expect(cache.length, 2);
    cache.clear();
    expect(third.debugDisposed, isTrue);
    expect(replacement.debugDisposed, isTrue);
    expect(cache.length, 0);
    cache.clear();
  });

  test(
    'evicting glyphs after recording does not erase their recorded pixels',
    () async {
      final cache = ParagraphCache(1);
      addTearDown(cache.clear);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paragraph = cache.performAndCacheLayout(
        'M',
        const TextStyle(fontSize: 20, color: Colors.white),
        TextScaler.noScaling,
        1,
      );
      canvas.drawParagraph(paragraph, Offset.zero);
      cache.performAndCacheLayout(
        'N',
        const TextStyle(fontSize: 20),
        TextScaler.noScaling,
        2,
      );
      expect(paragraph.debugDisposed, isTrue);
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      try {
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        expect(pixels.any((byte) => byte != 0), isTrue);
      } finally {
        image.dispose();
        picture.dispose();
      }
    },
  );

  testWidgets(
    'unmounting a terminal releases layouts and keeps its session scrollback',
    (tester) async {
      final terminal = Terminal()..write('saved terminal output\r\n');
      Widget view() =>
          MaterialApp(home: Scaffold(body: TerminalView(terminal)));
      await tester.pumpWidget(view());
      await tester.pump();
      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final renderer = state.renderTerminal;
      expect(renderer.debugCachedParagraphCount, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(renderer.debugCachedParagraphCount, 0);
      expect(terminal.buffer.getText(), contains('saved terminal output'));
      await tester.pumpWidget(view());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .state<TerminalViewState>(find.byType(TerminalView))
            .renderTerminal
            .debugCachedParagraphCount,
        greaterThan(0),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'closing a terminal clears replay and scrollback, including late output',
    () async {
      final terminal = MirroredTerminal(maxLines: 10000);
      terminal.write(List.filled(5000, 'a terminal output line\r\n').join());
      expect(terminal.retainedBytes, greaterThan(0));
      expect(terminal.mainBuffer.lines.length, greaterThan(1000));
      await terminal.closeMirror();
      expect(terminal.retainedBytes, 0);
      expect(terminal.history, isEmpty);
      expect(terminal.mainBuffer.lines.length, terminal.viewHeight);
      expect(terminal.altBuffer.lines.length, terminal.viewHeight);
      terminal.write('late output from a closing connection');
      expect(terminal.retainedBytes, 0);
      expect(terminal.mainBuffer.getText(), isNot(contains('late output')));
      await terminal.closeMirror();
    },
  );
}
