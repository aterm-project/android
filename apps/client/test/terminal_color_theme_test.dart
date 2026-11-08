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

    expect(dark.background.toARGB32(), 0xFF141729);
    // Default SSH text is grass green and independent of the blue app accent.
    expect(dark.foreground.toARGB32(), 0xFF9BD477);
    expect(dark.foreground, isNot(AppColors.accent));
    expect(dark.foreground, isNot(AppColors.accentText));
    // ANSI semantics are preserved (programs keep their colors).
    expect(dark.red.toARGB32(), 0xFFEC7893);
    expect(dark.green.toARGB32(), 0xFF74C99B);
    expect(dark.blue.toARGB32(), 0xFF82A5F0);
    expect(dark.white.toARGB32(), 0xFFD9DFF0);
    expect(light.background.toARGB32(), 0xFFF8FAFC);
    expect(light.foreground.toARGB32(), 0xFF1F2937);
    expect(light.background, isNot(dark.background));
    expect(light.cursor, isNot(dark.cursor));
  });

  test('app theme uses the deep-blue emphasis with legible on-colors', () {
    final scheme = buildAppTheme().colorScheme;
    expect(scheme.primary.toARGB32(), 0xFF315BC5);
    expect(scheme.secondary.toARGB32(), 0xFF8DAEF4);
    expect(AppColors.accentText.toARGB32(), 0xFF8DAEF4);
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
    expect(contrast(AppColors.accentText, AppColors.background), greaterThan(4.5));
  });
}
