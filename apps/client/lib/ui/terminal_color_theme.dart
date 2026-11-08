import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';

/// Default SSH terminal text color (grass green). Owned by the terminal palette
/// and intentionally independent of the app's blue emphasis colors.
const atermDarkTerminalForeground = Color(0xFF9BD477);
// xterm paints the selection over glyphs, so it must be translucent.
const _atermDarkTerminalSelection = Color(0x804A6FD0);

/// Builds a terminal palette only from the synchronized, strictly decoded
/// theme choice. Keep all terminal surfaces routed through this constructor.
/// Only the default foreground/cursor/selection are themed here; the ANSI 16
/// colors keep their semantic hues so programs' colored output is unchanged.
TerminalTheme buildTerminalColorTheme(VaultTerminalThemeChoice choice) =>
    switch (choice) {
      VaultTerminalThemeChoice.atermDark => const TerminalTheme(
        cursor: atermDarkTerminalForeground,
        selection: _atermDarkTerminalSelection,
        foreground: atermDarkTerminalForeground,
        background: Color(0xFF141729),
        black: Color(0xFF252A40),
        red: Color(0xFFEC7893),
        green: Color(0xFF74C99B),
        yellow: Color(0xFFE7C685),
        blue: Color(0xFF82A5F0),
        magenta: Color(0xFFB79ADE),
        cyan: Color(0xFF79BCD4),
        white: Color(0xFFD9DFF0),
        brightBlack: Color(0xFF8690A8),
        brightRed: Color(0xFFF39AAD),
        brightGreen: Color(0xFF99DBB7),
        brightYellow: Color(0xFFF0D9A4),
        brightBlue: Color(0xFFA7BFF8),
        brightMagenta: Color(0xFFCEB6EC),
        brightCyan: Color(0xFF9ED3E5),
        brightWhite: Colors.white,
        searchHitBackground: Color(0xFF665324),
        searchHitBackgroundCurrent: Color(0xFF8A6620),
        searchHitForeground: Color(0xFFFFFFFF),
      ),
      VaultTerminalThemeChoice.light => const TerminalTheme(
        cursor: Color(0xFF325E98),
        selection: Color(0x8071A9E8),
        foreground: Color(0xFF1F2937),
        background: Color(0xFFF8FAFC),
        black: Color(0xFF263238),
        red: Color(0xFFB42318),
        green: Color(0xFF18794E),
        yellow: Color(0xFF8A6100),
        blue: Color(0xFF175CD3),
        magenta: Color(0xFF9333A6),
        cyan: Color(0xFF087E8B),
        white: Color(0xFFF1F5F9),
        brightBlack: Color(0xFF667085),
        brightRed: Color(0xFFD92D20),
        brightGreen: Color(0xFF12A66A),
        brightYellow: Color(0xFFA87500),
        brightBlue: Color(0xFF2E90FA),
        brightMagenta: Color(0xFFB547C1),
        brightCyan: Color(0xFF17A2B8),
        brightWhite: Colors.white,
        searchHitBackground: Color(0xFFFFE08A),
        searchHitBackgroundCurrent: Color(0xFFFFC247),
        searchHitForeground: Color(0xFF1F2937),
      ),
    };
