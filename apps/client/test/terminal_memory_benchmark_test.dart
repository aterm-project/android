// Opt-in synthetic native benchmark; compare runs with the same Flutter SDK.
// flutter test --dart-define=TERMINAL_MEMORY_BENCHMARK=true test/terminal_memory_benchmark_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'four terminals with many colored glyphs retain bounded layouts',
    () async {
      final painters = List.generate(
        4,
        (_) => TerminalPainter(
          theme: TerminalThemes.defaultTheme,
          textStyle: const TerminalStyle(),
          textScaler: TextScaler.noScaling,
        ),
      );
      final baseline = ProcessInfo.currentRss;
      final watch = Stopwatch()..start();
      for (final painter in painters) {
        for (var batch = 0; batch < 12; batch++) {
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          for (var i = batch * 1000; i < (batch + 1) * 1000; i++) {
            final cell = CellData.empty()
              ..content = (65 + i % 26) | (1 << CellContent.widthShift)
              ..foreground = CellColor.rgb | (i * 31);
            painter.paintCellForeground(canvas, ui.Offset.zero, cell);
          }
          recorder.endRecording().dispose();
          await Future<void>.delayed(Duration.zero);
        }
      }
      final loaded = ProcessInfo.currentRss;
      final elapsed = watch.elapsedMilliseconds;
      for (final painter in painters) {
        painter.clearFontCache();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // RSS includes Flutter/allocator overhead. This is diagnostic evidence,
      // not a portable threshold or a claim about Windows Task Manager.
      // ignore: avoid_print
      print(
        jsonEncode({
          'baselineRss': baseline,
          'loadedRss': loaded,
          'deltaRss': loaded - baseline,
          'clearedRss': ProcessInfo.currentRss,
          'elapsedMs': elapsed,
        }),
      );
    },
    skip: !const bool.fromEnvironment('TERMINAL_MEMORY_BENCHMARK'),
  );
}
