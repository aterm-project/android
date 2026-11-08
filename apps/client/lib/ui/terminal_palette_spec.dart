import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

/// Plain color constants for one terminal palette. [ansi] holds the 16 ANSI
/// colors in standard order (black, red, green, yellow, blue, magenta, cyan,
/// white, then the bright variants).
@immutable
class TerminalPaletteSpec {
  const TerminalPaletteSpec(
    this.id,
    this.name,
    this.background,
    this.foreground,
    this.cursor,
    this.selection,
    this.ansi,
  );

  /// Stable device-local identifier (lowercase slug). Never localized.
  final String id;

  /// Proper name of the scheme (shown untranslated, like a font name).
  final String name;
  final int background, foreground, cursor, selection;
  final List<int> ansi;

  bool get isDark => Color(background).computeLuminance() < .5;

  TerminalTheme toTheme() {
    assert(ansi.length == 16);
    final c = [for (final value in ansi) Color(value)];
    final bg = Color(background);
    // Search hits are painted over glyphs, so they stay translucent.
    final hit = c[11].withValues(alpha: .38);
    final current = c[3].withValues(alpha: .62);
    return TerminalTheme(
      cursor: Color(cursor),
      selection: Color(selection),
      foreground: Color(foreground),
      background: bg,
      black: c[0],
      red: c[1],
      green: c[2],
      yellow: c[3],
      blue: c[4],
      magenta: c[5],
      cyan: c[6],
      white: c[7],
      brightBlack: c[8],
      brightRed: c[9],
      brightGreen: c[10],
      brightYellow: c[11],
      brightBlue: c[12],
      brightMagenta: c[13],
      brightCyan: c[14],
      brightWhite: c[15],
      searchHitBackground: hit,
      searchHitBackgroundCurrent: current,
      searchHitForeground: Color(foreground),
    );
  }
}
