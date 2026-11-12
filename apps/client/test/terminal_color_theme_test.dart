import 'dart:math' as math;

import 'package:aterm_client/domain/vault_preference.dart';
import 'package:flutter/painting.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validated choices construct distinct terminal palettes', () {
    final dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);
    final light = buildTerminalColorTheme(VaultTerminalThemeChoice.light);

    expect(dark.background.toARGB32(), 0xFF0F1425);
    // Default SSH text is grass green and independent of the blue app accent.
    expect(dark.foreground.toARGB32(), 0xFF9BEF60);
    expect(dark.foreground, isNot(AppColors.accent));
    expect(dark.foreground, isNot(AppColors.accentText));
    // ANSI semantics are preserved (programs keep their colors).
    expect(dark.red.toARGB32(), 0xFFFF6888);
    expect(dark.green.toARGB32(), 0xFF69E19C);
    expect(dark.blue.toARGB32(), 0xFF7CA7FF);
    expect(dark.white.toARGB32(), 0xFFE9EDFF);
    expect(light.background.toARGB32(), 0xFFF8FAFC);
    expect(light.foreground.toARGB32(), 0xFF17202D);
    expect(light.background, isNot(dark.background));
    expect(light.cursor, isNot(dark.cursor));
  });

  test('default SSH text has stronger contrast and saturation', () {
    final dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);
    double contrast(Color a, Color b) =>
        (math.max(a.computeLuminance(), b.computeLuminance()) + .05) /
        (math.min(a.computeLuminance(), b.computeLuminance()) + .05);
    expect(
      contrast(dark.foreground, dark.background),
      greaterThan(contrast(const Color(0xFF9BD477), const Color(0xFF141729))),
    );
    expect(
      HSVColor.fromColor(dark.foreground).saturation,
      greaterThan(HSVColor.fromColor(const Color(0xFF9BD477)).saturation),
    );
    for (final color in [
      dark.foreground,
      dark.red,
      dark.green,
      dark.yellow,
      dark.blue,
      dark.magenta,
      dark.cyan,
      dark.white,
    ]) {
      expect(contrast(color, dark.background), greaterThan(4.5));
    }
  });

  test('app theme uses the emerald-teal emphasis with legible on-colors', () {
    final scheme = buildAppTheme().colorScheme;
    expect(scheme.primary.toARGB32(), 0xFF0F7B6C);
    expect(scheme.secondary.toARGB32(), 0xFF4FD8C4);
    expect(AppColors.accentText.toARGB32(), 0xFF4FD8C4);
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
    }

    expect(contrast(scheme.onPrimary, scheme.primary), greaterThan(4.5));
    expect(
      contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
      greaterThan(4.5),
    );
    expect(contrast(scheme.onSecondary, scheme.secondary), greaterThan(4.5));
    expect(contrast(AppColors.accentText, AppColors.surface), greaterThan(4.5));
    expect(
      contrast(AppColors.accentText, AppColors.background),
      greaterThan(4.5),
    );
  });
}
