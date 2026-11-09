import 'package:flutter/material.dart';

/// Width breakpoints shared by settings surfaces on phones, tablets and the
/// desktop clients. Widths are the space actually given to the widget (from a
/// [LayoutBuilder]), not the window size, so a page placed beside a navigation
/// rail or in Android split-screen picks the layout that really fits.
abstract final class AppBreakpoints {
  /// Below this, settings categories collapse into a picker above the page.
  static const double settingsNavigation = 700;

  /// Below this, a labelled control row stacks its control under the label.
  static const double stackedRow = 520;
}

/// Whether the UI is driven by touch first (Android / iOS), following the
/// theme platform so tests and embedders can override it.
bool isTouchPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android || TargetPlatform.iOS => true,
  _ => false,
};

/// A label (with optional leading icon) and a control that sit on one line
/// when there is room, and stack with the control at full width otherwise.
///
/// Desktop keeps the familiar "name left, choice right" row. On a 390 px phone
/// the control gets the whole card width, so long translations never squeeze
/// or overflow it and the touch target stays wide.
class ResponsiveControlRow extends StatelessWidget {
  const ResponsiveControlRow({
    required this.label,
    required this.control,
    this.leading,
    this.controlWidth = 220,
    this.breakpoint = AppBreakpoints.stackedRow,
    super.key,
  });

  final Widget label;
  final Widget control;
  final Widget? leading;
  final double controlWidth;
  final double breakpoint;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final header = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(child: label),
        ],
      );
      if (constraints.maxWidth < breakpoint) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [header, const SizedBox(height: 8), control],
        );
      }
      return Row(
        children: [
          Expanded(child: header),
          const SizedBox(width: 16),
          SizedBox(width: controlWidth, child: control),
        ],
      );
    },
  );
}
