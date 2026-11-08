import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which proportion set the UI chrome uses.
///
/// [compact] is the desktop/pointer set (about 90% of the R6a comfortable
/// proportions). [touch] keeps phone/tablet glyphs a little smaller than R6a
/// but never shrinks hit targets below the platform minimum (48dp).
enum AppDensityProfile { compact, touch }

/// Shared presentation metrics for app chrome (dialogs, lists, forms, cards).
///
/// These are *pre-text-scale* logical sizes. Nothing here overrides the
/// user's text scaling, applies a transform, or feeds terminal cell metrics,
/// framebuffer (RDP/VNC) pointer mapping, split geometry, or native window
/// caption metrics — those stay owned by their own subsystems.
@immutable
class AppDensity extends ThemeExtension<AppDensity> {
  const AppDensity({
    required this.profile,
    required this.space1,
    required this.space2,
    required this.space3,
    required this.space4,
    required this.space5,
    required this.space6,
    required this.space7,
    required this.iconSm,
    required this.iconMd,
    required this.iconLg,
    required this.iconDefault,
    required this.controlHeight,
    required this.listGap,
    required this.pagePadding,
    required this.cardPadding,
    required this.dialogPadding,
    required this.inputPadding,
    required this.listTilePadding,
    required this.dialogSm,
    required this.dialogMd,
    required this.dialogLg,
    required this.dialogXl,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusDialog,
  });

  /// Desktop / pointer proportions.
  static const compact = AppDensity(
    profile: AppDensityProfile.compact,
    space1: 2,
    space2: 4,
    space3: 6,
    space4: 8,
    space5: 12,
    space6: 16,
    space7: 20,
    iconSm: 15,
    iconMd: 18,
    iconLg: 22,
    iconDefault: 20,
    controlHeight: 34,
    listGap: 8,
    pagePadding: EdgeInsets.all(20),
    cardPadding: EdgeInsets.all(14),
    dialogPadding: EdgeInsets.fromLTRB(20, 18, 20, 16),
    inputPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    listTilePadding: EdgeInsets.symmetric(horizontal: 12),
    dialogSm: 400,
    dialogMd: 480,
    dialogLg: 600,
    dialogXl: 860,
    radiusSm: 6,
    radiusMd: 10,
    radiusLg: 12,
    radiusDialog: 16,
  );

  /// Touch (Android/iOS) proportions: glyphs slightly smaller than R6a, hit
  /// targets unchanged.
  static const touch = AppDensity(
    profile: AppDensityProfile.touch,
    space1: 2,
    space2: 4,
    space3: 8,
    space4: 10,
    space5: 14,
    space6: 18,
    space7: 24,
    iconSm: 17,
    iconMd: 20,
    iconLg: 24,
    iconDefault: 22,
    controlHeight: 40,
    listGap: 8,
    pagePadding: EdgeInsets.all(16),
    cardPadding: EdgeInsets.all(14),
    dialogPadding: EdgeInsets.fromLTRB(20, 20, 20, 16),
    inputPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    listTilePadding: EdgeInsets.symmetric(horizontal: 14),
    dialogSm: 400,
    dialogMd: 480,
    dialogLg: 600,
    dialogXl: 860,
    radiusSm: 8,
    radiusMd: 12,
    radiusLg: 14,
    radiusDialog: 18,
  );

  static AppDensity forPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => touch,
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => compact,
  };

  /// The density installed by [buildAppTheme], or the platform default when a
  /// widget is built under a bare theme (tests, embedded routes).
  static AppDensity of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppDensity>() ?? forPlatform(theme.platform);
  }

  final AppDensityProfile profile;
  final double space1;
  final double space2;
  final double space3;
  final double space4;
  final double space5;
  final double space6;
  final double space7;
  final double iconSm;
  final double iconMd;
  final double iconLg;
  final double iconDefault;

  /// Visible height of buttons and segmented controls. Touch keeps a 48dp hit
  /// area through [MaterialTapTargetSize.padded].
  final double controlHeight;
  final double listGap;
  final EdgeInsets pagePadding;
  final EdgeInsets cardPadding;
  final EdgeInsets dialogPadding;
  final EdgeInsets inputPadding;
  final EdgeInsets listTilePadding;
  final double dialogSm;
  final double dialogMd;
  final double dialogLg;
  final double dialogXl;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusDialog;

  bool get isCompact => profile == AppDensityProfile.compact;

  /// A dialog body width that never exceeds the available screen width minus
  /// the dialog inset, so narrow windows and phones do not overflow.
  double dialogWidth(BuildContext context, double preferred) {
    final available = MediaQuery.sizeOf(context).width - 2 * dialogInset;
    return math.max(0, math.min(preferred, available));
  }

  /// Multiplier applied to R6a fixed dialog/page widths.
  double get widthFactor => isCompact ? 0.9 : 1.0;

  /// Horizontal inset Material dialogs keep from the window edge.
  double get dialogInset => isCompact ? 24 : 16;

  /// Material text sizes for this density. Line-height *ratios* stay the M3
  /// ones (all >= 1.2), so line boxes shrink with the glyphs while CJK and
  /// Cyrillic ascenders/descenders keep the same proportional room.
  TextTheme applyTextSizes(TextTheme base) {
    final sizes = isCompact ? _compactSizes : _touchSizes;
    TextStyle? sized(TextStyle? style, double size, [double? height]) =>
        style?.copyWith(fontSize: size, height: height);
    // Compact desktop tightens the airy M3 1.43–1.5 body/title line boxes to
    // ~1.38–1.4 (still >= 1.35 for CJK/Cyrillic). Touch keeps M3 ratios.
    double? tight(double ratio) => isCompact ? ratio : null;

    return base.copyWith(
      displayLarge: sized(base.displayLarge, sizes[0]),
      displayMedium: sized(base.displayMedium, sizes[1]),
      displaySmall: sized(base.displaySmall, sizes[2]),
      headlineLarge: sized(base.headlineLarge, sizes[3]),
      headlineMedium: sized(base.headlineMedium, sizes[4]),
      headlineSmall: sized(base.headlineSmall, sizes[5]),
      titleLarge: sized(base.titleLarge, sizes[6]),
      titleMedium: sized(base.titleMedium, sizes[7], tight(1.4)),
      titleSmall: sized(base.titleSmall, sizes[8]),
      bodyLarge: sized(base.bodyLarge, sizes[9], tight(1.4)),
      bodyMedium: sized(base.bodyMedium, sizes[10], tight(1.38)),
      bodySmall: sized(base.bodySmall, sizes[11]),
      labelLarge: sized(base.labelLarge, sizes[12], tight(1.38)),
      labelMedium: sized(base.labelMedium, sizes[13]),
      labelSmall: sized(base.labelSmall, sizes[14]),
    );
  }

  // display L/M/S, headline L/M/S, title L/M/S, body L/M/S, label L/M/S.
  // Material 3 defaults: 57 45 36 / 32 28 24 / 22 16 14 / 16 14 12 / 14 12 11.
  static const _compactSizes = <double>[
    50, 40, 32, 28, 25, 21, 19, 14.5, 13, 14.5, 13, 11.5, 13, 11.5, 10.5, //
  ];
  static const _touchSizes = <double>[
    54, 43, 34, 30, 27, 23, 21, 16, 14, 15.5, 14, 12, 14, 12, 11, //
  ];

  @override
  AppDensity copyWith({AppDensityProfile? profile}) {
    if (profile == null || profile == this.profile) return this;
    return profile == AppDensityProfile.compact ? compact : touch;
  }

  @override
  AppDensity lerp(covariant AppDensity? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// An R6a fixed dialog or empty-state width scaled to the active density
/// (compact: 90%, rounded to 4px) and clamped to the current window, so
/// narrow windows and phones never overflow horizontally.
double appDialogWidth(BuildContext context, double r6aWidth) {
  final density = AppDensity.of(context);
  final scaled = (r6aWidth * density.widthFactor / 4).round() * 4.0;
  return density.dialogWidth(context, scaled);
}
