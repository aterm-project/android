import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_density.dart';

/// Shared density rules for Home host cards (cloud and local profile).
///
/// Line boxes are pinned with forced struts, so a CJK/Cyrillic fallback font
/// cannot grow a line past the height the grid reserved for it. The grid
/// extent is then derived from those struts and the user's text scale rather
/// than a fixed pixel height, and nothing is clipped at large text sizes.
@immutable
class HostCardMetrics {
  const HostCardMetrics._({
    required this.textScale,
    required this.touch,
    required this.textNudge,
  });

  factory HostCardMetrics.of(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final platform = Theme.of(context).platform;
    return HostCardMetrics.resolve(
      textScale: scaler.scale(titleSize) / titleSize,
      textNudge: AppDensity.of(context).textSize(0),
      touch:
          platform == TargetPlatform.android || platform == TargetPlatform.iOS,
    );
  }

  factory HostCardMetrics.resolve({
    required double textScale,
    required bool touch,
    double textNudge = 0,
  }) => HostCardMetrics._(
    textScale: textScale.isFinite && textScale > 0 ? textScale : 1,
    touch: touch,
    textNudge: textNudge,
  );

  static const titleSize = 13.0;
  static const subtitleSize = 11.0;
  static const metaSize = 10.5;
  static const lineHeight = 1.3;
  static const iconSize = 20.0;
  static const iconPadding = 4.0;
  static const metaIconSize = 14.0;
  static const metaGap = 3.0;
  static const titleGap = 1.0;
  static const padding = EdgeInsets.symmetric(horizontal: 10, vertical: 6);

  /// Smallest comfortable tile width at text scale 1.
  static const minTileWidth = 220.0;
  static const maxTileWidth = 300.0;
  static const spacing = 8.0;

  static const titleStrut = StrutStyle(
    fontSize: titleSize,
    height: lineHeight,
    forceStrutHeight: true,
  );
  static const subtitleStrut = StrutStyle(
    fontSize: subtitleSize,
    height: lineHeight,
    forceStrutHeight: true,
  );
  static const metaStrut = StrutStyle(
    fontSize: metaSize,
    height: lineHeight,
    forceStrutHeight: true,
  );

  StrutStyle _strut(double size) => StrutStyle(
    fontSize: size,
    height: lineHeight,
    forceStrutHeight: true,
  );

  final double textScale;
  final double textNudge;
  double get titleTextSize => titleSize + textNudge;
  double get subtitleTextSize => subtitleSize + textNudge;
  double get metaTextSize => metaSize + textNudge;
  double get glyphSize => iconSize + textNudge;
  StrutStyle get titleTextStrut => _strut(titleTextSize);
  StrutStyle get subtitleTextStrut =>
      _strut(subtitleTextSize);
  StrutStyle get metaTextStrut => _strut(metaTextSize);

  /// Touch platforms (Android/iOS) use a real 48x48 trailing hit box; pointer
  /// platforms use 28. Visible glyphs stay 17-18 px either way.
  final bool touch;

  /// Actual laid-out size of the favorite/overflow buttons (= hit area).
  double get buttonExtent => touch ? 48 : 28 + textNudge * 2;

  /// The button box itself is the hit area, so Material must not add or cap
  /// padding around it.
  MaterialTapTargetSize get tapTargetSize => MaterialTapTargetSize.shrinkWrap;
  double get iconBox => glyphSize + iconPadding * 2;

  double _line(double size) => size * textScale * lineHeight;

  double get headerHeight => [
    iconBox,
    buttonExtent,
    _line(titleTextSize) + titleGap + _line(subtitleTextSize),
  ].reduce(math.max);

  double get metaHeight => math.max(metaIconSize, _line(metaTextSize));

  /// Card height; [withMeta] adds the group/tags/route row.
  double extent({required bool withMeta}) =>
      (padding.vertical +
              headerHeight +
              (withMeta ? metaGap + metaHeight : 0) +
              // Card outline and rounding slack.
              2)
          .ceilToDouble();

  /// Responsive column count: tiles widen with text scale so long German,
  /// Russian or Japanese labels keep their ellipsis budget.
  int columnsFor(double width) {
    final scale = textScale.clamp(1.0, 1.6);
    final minWidth = minTileWidth * scale;
    final count = ((width + spacing) / (minWidth + spacing)).floor();
    return math.max(1, count);
  }

  SliverGridDelegate gridDelegate(double width, {bool withMeta = true}) =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnsFor(width),
        mainAxisExtent: extent(withMeta: withMeta),
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
      );
}
