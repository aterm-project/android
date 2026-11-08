import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_motion.dart';

abstract final class AppColors {
  static const background = Color(0xFF0A0F15);
  static const surface = Color(0xFF111923);
  static const surfaceRaised = Color(0xFF17222D);
  static const surfaceSoft = Color(0xFF1C2935);
  static const line = Color(0xFF263544);
  static const text = Color(0xFFEAF0F6);
  static const muted = Color(0xFF8D9BAB);

  /// Deep-blue app emphasis. `accent` fills large controls (filled buttons,
  /// switches, selection borders) and always pairs with [onAccent]; blue text
  /// and small glyphs on dark surfaces use [accentText] for legible contrast.
  /// Terminal text colors are owned by `terminal_color_theme.dart` and are
  /// deliberately not derived from these values.
  static const accent = Color(0xFF315BC5);
  static const onAccent = Color(0xFFFFFFFF);
  static const accentContainer = Color(0xFF1D3466);
  static const onAccentContainer = Color(0xFFDCE6FF);
  static const accentText = Color(0xFF8DAEF4);
  static const onAccentText = Color(0xFF0D1C40);
  static const accentSoft = Color(0xFFB7CBF8);
  // Compatibility names for existing surfaces share the blue emphasis.
  static const lime = accentText;
  static const teal = accentSoft;
  static const orange = Color(0xFFFFB865);
  static const red = Color(0xFFFF7676);
}

/// UI font fallbacks per display language. They only apply to glyphs the
/// platform UI font lacks, so Han characters use the regional glyph forms of
/// the selected language (Japanese vs Simplified Chinese) and Cyrillic uses a
/// full-coverage face. Explicit monospace styles (terminal, fingerprints,
/// framebuffer overlays) keep their own families.
List<String> appFontFallback(Locale? locale) => switch (locale?.languageCode) {
  'ja' => const [
    'Yu Gothic UI',
    'Meiryo UI',
    'Hiragino Sans',
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Microsoft YaHei UI',
  ],
  'zh' => const [
    'Microsoft YaHei UI',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Yu Gothic UI',
  ],
  _ => const ['Segoe UI', 'Roboto', 'Noto Sans', 'Microsoft YaHei UI'],
};

ThemeData buildAppTheme({Locale? locale, TargetPlatform? platform}) {
  final base = ThemeData.dark(useMaterial3: true);
  final fallback = appFontFallback(locale);
  // R7 density: shared compact (desktop) / touch proportions. Sizes only;
  // never a transform or a text-scale override.
  final density = AppDensity.forPlatform(platform ?? base.platform);
  final textTheme = density.applyTextSizes(base.textTheme);
  final radiusSm = BorderRadius.circular(density.radiusSm);
  final radiusMd = BorderRadius.circular(density.radiusMd);
  final radiusLg = BorderRadius.circular(density.radiusLg);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[density],
    pageTransitionsTheme: appPageTransitionsTheme,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.accent,
      onPrimary: AppColors.onAccent,
      primaryContainer: AppColors.accentContainer,
      onPrimaryContainer: AppColors.onAccentContainer,
      secondary: AppColors.accentText,
      onSecondary: AppColors.onAccentText,
      secondaryContainer: AppColors.accentContainer,
      onSecondaryContainer: AppColors.onAccentContainer,
      tertiary: AppColors.accentSoft,
      onTertiary: AppColors.onAccentText,
      inversePrimary: AppColors.accentText,
      surfaceTint: Colors.transparent,
      surface: AppColors.surface,
      error: AppColors.red,
    ),
    textTheme: textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: density
        .applyTextSizes(base.primaryTextTheme)
        .apply(fontFamilyFallback: fallback),
    iconTheme: base.iconTheme.copyWith(size: density.iconDefault),
    primaryIconTheme: base.primaryIconTheme.copyWith(size: density.iconDefault),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(iconSize: density.iconDefault),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: density.listTilePadding,
      horizontalTitleGap: density.space5,
      minLeadingWidth: density.iconLg,
    ),
    dividerColor: AppColors.line,
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surfaceRaised,
      selectedColor: AppColors.accentContainer,
      labelStyle: const TextStyle(color: AppColors.text),
      secondaryLabelStyle: const TextStyle(color: AppColors.onAccentContainer),
      checkmarkColor: AppColors.onAccentContainer,
      side: const BorderSide(color: AppColors.line),
      shape: RoundedRectangleBorder(borderRadius: radiusSm),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentText,
        padding: EdgeInsets.symmetric(horizontal: density.space5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentText,
        padding: EdgeInsets.symmetric(horizontal: density.space6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: density.space6),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(foregroundColor: AppColors.accentText),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: AppColors.accentText,
      selectionColor: AppColors.accent.withValues(alpha: .45),
      selectionHandleColor: AppColors.accentText,
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: AppColors.accentText,
      indicatorColor: AppColors.accentText,
      unselectedLabelColor: AppColors.muted,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.line),
        borderRadius: radiusMd,
      ),
      menuPadding: EdgeInsets.symmetric(vertical: density.space2),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: density.textSize(density.isCompact ? 12 : 13),
          height: 1.3,
          color: states.contains(WidgetState.disabled)
              ? AppColors.muted.withValues(alpha: .5)
              : AppColors.text,
        ),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radiusMd,
            side: const BorderSide(color: AppColors.line),
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, density.menuItemHeight)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
        textStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: density.textSize(density.isCompact ? 12 : 13),
            height: 1.3,
          ),
        ),
        iconSize: WidgetStatePropertyAll(density.menuIconSize),
        visualDensity: VisualDensity.standard,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceRaised,
      contentPadding: density.inputPadding,
      // Compact desktop drops the 48px minimum field height (pointer input);
      // touch keeps it so fields stay >= 48dp hit targets.
      isDense: density.isCompact,
      // Helper/error copy wraps instead of ellipsizing at large text scales
      // or in narrower compact panels.
      helperMaxLines: 3,
      errorMaxLines: 3,
      prefixIconConstraints: density.isCompact
          ? const BoxConstraints(minWidth: 40, minHeight: 36)
          : null,
      suffixIconConstraints: density.isCompact
          ? const BoxConstraints(minWidth: 40, minHeight: 36)
          : null,
      border: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: const BorderSide(color: AppColors.lime, width: 1.4),
      ),
      labelStyle: const TextStyle(color: AppColors.muted),
      hintStyle: const TextStyle(color: Color(0xFF687788)),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surfaceSoft,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(density.radiusDialog),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: density.dialogInset,
        vertical: 24,
      ),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: AppColors.text,
        fontFamilyFallback: fallback,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        density.dialogPadding.left,
        0,
        density.dialogPadding.right,
        density.dialogPadding.bottom,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.line),
        borderRadius: radiusLg,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
}
