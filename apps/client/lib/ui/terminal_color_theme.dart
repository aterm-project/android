import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';

/// Default SSH terminal text color (grass green). Owned by the terminal palette
/// and intentionally independent of the app's blue emphasis colors.
const atermDarkTerminalForeground = Color(0xFF9BEF60);
// xterm paints the selection over glyphs, so it must be translucent.
const _atermDarkTerminalSelection = Color(0x804A6FD0);

/// Builds a terminal palette only from the synchronized, strictly decoded
/// theme choice. Keep all terminal surfaces routed through this constructor.
/// Built-in palettes keep the ANSI hue meanings while giving foreground and
/// colored output stronger contrast/chroma. Device presets remain untouched.
TerminalTheme buildTerminalColorTheme(VaultTerminalThemeChoice choice) =>
    switch (choice) {
      VaultTerminalThemeChoice.atermDark => const TerminalTheme(
        cursor: atermDarkTerminalForeground,
        selection: _atermDarkTerminalSelection,
        foreground: atermDarkTerminalForeground,
        background: Color(0xFF0F1425),
        black: Color(0xFF303A58),
        red: Color(0xFFFF6888),
        green: Color(0xFF69E19C),
        yellow: Color(0xFFFFD166),
        blue: Color(0xFF7CA7FF),
        magenta: Color(0xFFC39AFF),
        cyan: Color(0xFF55D7F0),
        white: Color(0xFFE9EDFF),
        brightBlack: Color(0xFFA1ABC3),
        brightRed: Color(0xFFFF93AE),
        brightGreen: Color(0xFF8AF1AE),
        brightYellow: Color(0xFFFFE091),
        brightBlue: Color(0xFFA5C1FF),
        brightMagenta: Color(0xFFD3AEFF),
        brightCyan: Color(0xFF8AEAFF),
        brightWhite: Colors.white,
        searchHitBackground: Color(0xFF665324),
        searchHitBackgroundCurrent: Color(0xFF8A6620),
        searchHitForeground: Color(0xFFFFFFFF),
      ),
      VaultTerminalThemeChoice.light => const TerminalTheme(
        cursor: Color(0xFF325E98),
        selection: Color(0x8071A9E8),
        foreground: Color(0xFF17202D),
        background: Color(0xFFF8FAFC),
        black: Color(0xFF263238),
        red: Color(0xFFB42318),
        green: Color(0xFF18794E),
        yellow: Color(0xFF8A6100),
        blue: Color(0xFF175CD3),
        magenta: Color(0xFF9333A6),
        cyan: Color(0xFF087E8B),
        white: Color(0xFF374151),
        brightBlack: Color(0xFF667085),
        brightRed: Color(0xFFC22228),
        brightGreen: Color(0xFF087F47),
        brightYellow: Color(0xFF8C6200),
        brightBlue: Color(0xFF1769D2),
        brightMagenta: Color(0xFFA328B3),
        brightCyan: Color(0xFF007C91),
        brightWhite: Color(0xFF111827),
        searchHitBackground: Color(0xFFFFE08A),
        searchHitBackgroundCurrent: Color(0xFFFFC247),
        searchHitForeground: Color(0xFF17202D),
      ),
    };
