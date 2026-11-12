import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_motion.dart';

abstract final class AppColors {
  static const background = Color(0xFF0B0F10);
  static const surface = Color(0xFF12191C);
  static const surfaceRaised = Color(0xFF182226);
  static const surfaceSoft = Color(0xFF1F2C31);
  static const line = Color(0xFF28383E);
  static const text = Color(0xFFECF3F2);
  static const muted = Color(0xFF91A3A0);

  /// Obsidian-Emerald app emphasis. `accent` fills large controls (filled
  /// buttons, switches, selection borders) and always pairs with [onAccent];
  /// emerald-teal text and small glyphs on dark surfaces use [accentText] for
  /// legible WCAG AA+ contrast. Terminal text colors are owned by
  /// `terminal_color_theme.dart` and are deliberately not derived from these
  /// values.
  static const accent = Color(0xFF0F7B6C);
  static const onAccent = Color(0xFFFFFFFF);
  static const accentContainer = Color(0xFF133B36);
  static const onAccentContainer = Color(0xFFD2F7EE);
  static const accentText = Color(0xFF4FD8C4);
  static const onAccentText = Color(0xFF062924);
  static const accentSoft = Color(0xFF8BE8D9);
  // Compatibility names for existing surfaces share the emerald emphasis.
  static const lime = accentText;
  static const teal = accentSoft;
  static const orange = Color(0xFFFFB55E);
  static const red = Color(0xFFFF7379);
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
    rail: Color(0xFF0E1416),
    line: AppColors.line,
    text: AppColors.text,
    muted: AppColors.muted,
    hint: Color(0xFF677A77),
    accent: AppColors.accent,
    onAccent: AppColors.onAccent,
    accentContainer: AppColors.accentContainer,
    onAccentContainer: AppColors.onAccentContainer,
    accentText: AppColors.accentText,
    onAccentText: AppColors.onAccentText,
    accentSoft: AppColors.accentSoft,
    info: Color(0xFF67CBFF),
    hostBlue: Color(0xFF6AA9FF),
    orange: AppColors.orange,
    red: AppColors.red,
    errorContainer: Color(0xFF4F2224),
    onErrorContainer: Color(0xFFFFFFFF),
    warningContainer: Color(0xFF332919),
    codeBackground: Color(0xFF0A0E0F),
    codeText: Color(0xFFC9DCD9),
    tooltipBackground: Color(0xFF1C272B),
    tooltipText: Color(0xFFFFFFFF),
  );

  /// White canvas and cards, cool porcelain separators, dark readable text and
  /// the emerald-teal app accent. Text-role colors meet WCAG AA (>= 4.5:1).
  static const light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF3F7F6),
    surfaceSoft: Color(0xFFE6EFED),
    rail: Color(0xFFF3F7F6),
    line: Color(0xFFD6E2DF),
    text: Color(0xFF14211F),
    muted: Color(0xFF516360),
    hint: Color(0xFF657875),
    accent: AppColors.accent,
    onAccent: AppColors.onAccent,
    accentContainer: Color(0xFFD4F5EC),
    onAccentContainer: Color(0xFF0A3D35),
    accentText: Color(0xFF0C6B5E),
    onAccentText: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF137A6B),
    info: Color(0xFF0E6496),
    hostBlue: Color(0xFF2864B8),
    orange: Color(0xFF9E4B00),
    red: Color(0xFFBE2331),
    errorContainer: Color(0xFFFDE8EA),
    onErrorContainer: Color(0xFF75151E),
    warningContainer: Color(0xFFFFF4E0),
    codeBackground: Color(0xFFF3F7F6),
    codeText: Color(0xFF1E302D),
    tooltipBackground: Color(0xFF1A2524),
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
    'Hiragino Sans',
    'Yu Gothic UI',
    'Meiryo UI',
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Microsoft YaHei UI',
  ],
  'zh' => const [
    'PingFang SC',
    'Hiragino Sans GB',
    'Microsoft YaHei UI',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Yu Gothic UI',
  ],
  _ => const [
    '.AppleSystemUIFont',
    'SF Pro Text',
    'Segoe UI',
    'Roboto',
    'Noto Sans',
    'PingFang SC',
    'Microsoft YaHei UI',
  ],
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
            inversePrimary: const Color(0xFF4FD8C4),
            surfaceTint: Colors.transparent,
            surface: p.surface,
            onSurface: p.text,
            onSurfaceVariant: p.muted,
            surfaceContainerLowest: p.surface,
            surfaceContainerLow: p.surface,
            surfaceContainer: p.surface,
            surfaceContainerHigh: p.surfaceRaised,
            surfaceContainerHighest: p.surfaceSoft,
            outline: const Color(0xFF809490),
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
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accentText,
        side: BorderSide(color: p.line),
        padding: EdgeInsets.symmetric(horizontal: density.space6),
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: density.space6),
        shape: RoundedRectangleBorder(borderRadius: radiusMd),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: density.isCompact
            ? VisualDensity.compact
            : VisualDensity.standard,
        side: WidgetStatePropertyAll(BorderSide(color: p.line)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: radiusMd),
        ),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(999),
      thickness: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ? 7.0 : 5.0,
      ),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => p.muted.withValues(
          alpha: states.contains(WidgetState.hovered) ? .55 : .30,
        ),
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
      elevation: 12,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: p.line),
        borderRadius: BorderRadius.circular(density.radiusDialog),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: density.dialogInset,
        vertical: 24,
      ),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: p.text,
        fontWeight: FontWeight.w600,
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
