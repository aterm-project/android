import 'dart:ui';

import '../rdp_settings.dart';
import 'desktop_window_contract.dart';
import '../../l10n/l10n.dart';

/// One window per remote monitor of a multi-monitor RDP session. The remote
/// framebuffer spans the bounding box of the layout sent at connect, so each
/// viewport is that monitor's rectangle relative to the box origin. Local
/// monitor rectangles use Windows virtual-screen coordinates, where the
/// primary monitor is at (0,0) — the same normalization sent to the server.
List<DesktopWindowSpec> monitorWindowSpecs(
  List<RdpMonitorLayout> layout,
  String title,
) {
  if (layout.length < 2) return const [];
  final left = layout.map((m) => m.x).reduce((a, b) => a < b ? a : b);
  final top = layout.map((m) => m.y).reduce((a, b) => a < b ? a : b);
  return [
    for (var i = 0; i < layout.length; i++)
      DesktopWindowSpec(
        title: currentL10n.titleMonitorValuevalueValuevalue2(
          title,
          i + 1,
          layout[i].primary ? currentL10n.primary : '',
        ),
        viewport: Rect.fromLTWH(
          (layout[i].x - left).toDouble(),
          (layout[i].y - top).toDouble(),
          layout[i].width.toDouble(),
          layout[i].height.toDouble(),
        ),
        coverMonitor: Rect.fromLTWH(
          layout[i].x.toDouble(),
          layout[i].y.toDouble(),
          layout[i].width.toDouble(),
          layout[i].height.toDouble(),
        ),
      ),
  ];
}
