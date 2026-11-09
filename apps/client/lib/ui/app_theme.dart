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

/// Context-scoped UI chrome palette.
///
/// Installed by [buildAppTheme] as a [ThemeExtension]; read it with
/// `context.palette`. [AppPalette.dark] carries exactly the historic
/// [AppColors] values so the default dark theme is unchanged. Terminal text,
/// ANSI and custom terminal palettes, and remote-desktop framebuffers are
/// deliberately not derived from this palette.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSoft,
    required this.rail,
    required this.line,
    required this.text,
    required this.muted,
    required this.hint,
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.accentText,
    required this.onAccentText,
    required this.accentSoft,
    required this.info,
    required this.hostBlue,
    required this.orange,
    required this.red,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.warningContainer,
    required this.codeBackground,
    required this.codeText,
    required this.tooltipBackground,
    required this.tooltipText,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceSoft;

  /// Navigation rail / secondary chrome behind the main canvas.
  final Color rail;
  final Color line;
  final Color text;
  final Color muted;
  final Color hint;
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;
  final Color accentText;
  final Color onAccentText;
  final Color accentSoft;

  /// Informational blue for links/directories, readable on [surface].
  final Color info;

  /// Third host-avatar color.
  final Color hostBlue;
  final Color orange;
  final Color red;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color warningContainer;

  /// Read-only command/script previews (not live terminal content).
  final Color codeBackground;
  final Color codeText;

  /// Tooltips are always dark with white text, in both themes.
  final Color tooltipBackground;
  final Color tooltipText;

  bool get isDark => brightness == Brightness.dark;

  // Compatibility names for existing surfaces share the blue emphasis.
  Color get lime => accentText;
  Color get teal => accentSoft;

  static const dark = AppPalette(
    brightness: Brightness.dark,
    background: AppColors.background,
    surface: AppColors.surface,
    surfaceRaised: AppColors.surfaceRaised,
    surfaceSoft: AppColors.surfaceSoft,
    rail: Color(0xFF0D141C),
    line: AppColors.line,
    text: AppColors.text,
    muted: AppColors.muted,
    hint: Color(0xFF687788),
    accent: AppColors.accent,
    onAccent: AppColors.onAccent,
    accentContainer: AppColors.accentContainer,
    onAccentContainer: AppColors.onAccentContainer,
    accentText: AppColors.accentText,
    onAccentText: AppColors.onAccentText,
    accentSoft: AppColors.accentSoft,
    info: Color(0xFF8CC8FF),
    hostBlue: Color(0xFF82A7FF),
    orange: AppColors.orange,
    red: AppColors.red,
    errorContainer: Color(0xFF51251F),
    onErrorContainer: Color(0xFFFFFFFF),
    warningContainer: Color(0xFF302719),
    codeBackground: Color(0xFF0B1016),
    codeText: Color(0xFFC3D4E2),
    tooltipBackground: Color(0xFF2A3A4A),
    tooltipText: Color(0xFFFFFFFF),
  );

  /// White canvas and cards, cool-gray separators, dark readable text and the
  /// same blue app accent. Text-role colors meet WCAG AA (>= 4.5:1) on white.
  static const light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF4F6F9),
    surfaceSoft: Color(0xFFE9EDF2),
    rail: Color(0xFFF4F6F9),
    line: Color(0xFFDCE2E9),
    text: Color(0xFF17202B),
    muted: Color(0xFF586575),
    hint: Color(0xFF6B7787),
    accent: AppColors.accent,
    onAccent: AppColors.onAccent,
    accentContainer: Color(0xFFDCE6FF),
    onAccentContainer: Color(0xFF1D3466),
    accentText: Color(0xFF2A51B5),
    onAccentText: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF3B5DB8),
    info: Color(0xFF1B5FAA),
    hostBlue: Color(0xFF4767C9),
    orange: Color(0xFFA34E00),
    red: Color(0xFFC0262D),
    errorContainer: Color(0xFFFDE8E6),
    onErrorContainer: Color(0xFF7A1A16),
    warningContainer: Color(0xFFFFF4E0),
    codeBackground: Color(0xFFF4F6F9),
    codeText: Color(0xFF243142),
    tooltipBackground: Color(0xFF26313E),
    tooltipText: Color(0xFFFFFFFF),
  );

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? dark;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < .5 ? brightness : other.brightness,
      background: c(background, other.background),
      surface: c(surface, other.surface),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      surfaceSoft: c(surfaceSoft, other.surfaceSoft),
      rail: c(rail, other.rail),
      line: c(line, other.line),
      text: c(text, other.text),
      muted: c(muted, other.muted),
      hint: c(hint, other.hint),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      accentContainer: c(accentContainer, other.accentContainer),
      onAccentContainer: c(onAccentContainer, other.onAccentContainer),
      accentText: c(accentText, other.accentText),
      onAccentText: c(onAccentText, other.onAccentText),
      accentSoft: c(accentSoft, other.accentSoft),
      info: c(info, other.info),
      hostBlue: c(hostBlue, other.hostBlue),
      orange: c(orange, other.orange),
      red: c(red, other.red),
      errorContainer: c(errorContainer, other.errorContainer),
      onErrorContainer: c(onErrorContainer, other.onErrorContainer),
      warningContainer: c(warningContainer, other.warningContainer),
      codeBackground: c(codeBackground, other.codeBackground),
      codeText: c(codeText, other.codeText),
      tooltipBackground: c(tooltipBackground, other.tooltipBackground),
      tooltipText: c(tooltipText, other.tooltipText),
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// UI chrome palette of the nearest [Theme] (dark when none is installed).
  ///
  /// Unmounted contexts (late async callbacks) get the dark palette instead of
  /// an ancestor-lookup assertion; callers should still check `mounted`.
  AppPalette get palette => mounted ? AppPalette.of(this) : AppPalette.dark;
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

/// Builds the app theme. The default (no [brightness]) is the historic dark
/// theme; [Brightness.light] builds the white/light UI chrome theme. Both
/// share the R7 density, motion and font fallbacks.
ThemeData buildAppTheme({
  Locale? locale,
  TargetPlatform? platform,
  Brightness brightness = Brightness.dark,
}) {
  final dark = brightness == Brightness.dark;
  final p = dark ? AppPalette.dark : AppPalette.light;
  final base = dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  final fallback = appFontFallback(locale);
  // R7 density: shared compact (desktop) / touch proportions. Sizes only;
  // never a transform or a text-scale override.
  final density = AppDensity.forPlatform(platform ?? base.platform);
  final textTheme = density.applyTextSizes(base.textTheme);
  final radiusSm = BorderRadius.circular(density.radiusSm);
  final radiusMd = BorderRadius.circular(density.radiusMd);
  final radiusLg = BorderRadius.circular(density.radiusLg);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[density, p],
    pageTransitionsTheme: appPageTransitionsTheme,
    scaffoldBackgroundColor: p.background,
    canvasColor: dark ? base.canvasColor : p.surface,
    colorScheme: dark
        ? const ColorScheme.dark(
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
          )
        : ColorScheme.light(
            primary: p.accent,
            onPrimary: p.onAccent,
            primaryContainer: p.accentContainer,
            onPrimaryContainer: p.onAccentContainer,
            secondary: p.accentText,
            onSecondary: p.onAccentText,
            secondaryContainer: p.accentContainer,
            onSecondaryContainer: p.onAccentContainer,
            tertiary: p.accentSoft,
            onTertiary: p.onAccentText,
            inversePrimary: const Color(0xFF8DAEF4),
            surfaceTint: Colors.transparent,
            surface: p.surface,
            onSurface: p.text,
            onSurfaceVariant: p.muted,
            surfaceContainerLowest: p.surface,
            surfaceContainerLow: p.surface,
            surfaceContainer: p.surface,
            surfaceContainerHigh: p.surfaceRaised,
            surfaceContainerHighest: p.surfaceSoft,
            outline: const Color(0xFF8A96A5),
            outlineVariant: p.line,
            inverseSurface: p.tooltipBackground,
            onInverseSurface: p.tooltipText,
            error: p.red,
            errorContainer: p.errorContainer,
            onErrorContainer: p.onErrorContainer,
          ),
    textTheme: textTheme.apply(
      bodyColor: p.text,
      displayColor: p.text,
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
    dividerColor: p.line,
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: p.surfaceRaised,
      selectedColor: p.accentContainer,
      labelStyle: TextStyle(color: p.text),
      secondaryLabelStyle: TextStyle(color: p.onAccentContainer),
      checkmarkColor: p.onAccentContainer,
      side: BorderSide(color: p.line),
      shape: RoundedRectangleBorder(borderRadius: radiusSm),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accentText,
        padding: EdgeInsets.symmetric(horizontal: density.space5),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accentText,
        padding: EdgeInsets.symmetric(horizontal: density.space6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: density.space6),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(foregroundColor: p.accentText),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accentText,
      selectionColor: p.accent.withValues(alpha: .45),
      selectionHandleColor: p.accentText,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.accentText,
      indicatorColor: p.accentText,
      unselectedLabelColor: p.muted,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: p.line),
        borderRadius: radiusMd,
      ),
      menuPadding: EdgeInsets.symmetric(vertical: density.space2),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: density.textSize(density.isCompact ? 12 : 13),
          height: 1.3,
          color: states.contains(WidgetState.disabled)
              ? p.muted.withValues(alpha: .5)
              : p.text,
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
            side: BorderSide(color: p.line),
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
      fillColor: p.surfaceRaised,
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
        borderSide: BorderSide(color: p.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(color: p.lime, width: 1.4),
      ),
      labelStyle: TextStyle(color: p.muted),
      hintStyle: TextStyle(color: p.hint),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surfaceSoft,
      contentTextStyle: TextStyle(color: p.text),
      behavior: SnackBarBehavior.floating,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(density.radiusDialog),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: density.dialogInset,
        vertical: 24,
      ),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: p.text,
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
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: p.line),
        borderRadius: radiusLg,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
    ),
    // Tooltips stay dark in both themes, so their text is explicitly white
    // (Material's dark-theme default text would be black on this surface).
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.tooltipBackground,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      textStyle: TextStyle(
        color: p.tooltipText,
        fontSize: density.isCompact ? 12 : 13,
        height: 1.3,
        fontFamilyFallback: fallback,
      ),
    ),
  );
}
