import '../ui/app_motion.dart';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'desktop_resolution.dart';
import 'desktop_resolution_picker.dart';
import 'desktop_session.dart';
import 'rdp_settings.dart';
import '../l10n/l10n.dart';
import '../ui/app_density.dart';

/// In-session resolution dialog. States the negotiated capability so a local
/// scaling change is never presented as a remote resize.
Future<void> showDesktopResolutionDialog(
  BuildContext context,
  DesktopSession session,
) async {
  final vnc = session.protocol == HostProtocol.vnc;
  var value = vnc
      ? DesktopResolutionValue(
          switch (session.vncSettings.resolution) {
            VncResolutionMode.server => DesktopResolutionKind.server,
            VncResolutionMode.fitWindow => DesktopResolutionKind.auto,
            VncResolutionMode.fixed => DesktopResolutionKind.fixed,
          },
          width: session.vncSettings.width,
          height: session.vncSettings.height,
        )
      : DesktopResolutionValue(
          session.rdpSettings.resolution == RdpResolutionMode.fixed
              ? DesktopResolutionKind.fixed
              : DesktopResolutionKind.auto,
          width: session.rdpSettings.width,
          height: session.rdpSettings.height,
        );
  final initial = value;
  var scaling = session.localScaling;
  final multimon = (session.rdpConfig?.monitors.length ?? 0) > 1;
  String capability() => switch (session.serverResize) {
    true =>
      vnc
          ? context.l10n.theServerSupportsResizingExtendeddesktopsize
          : context.l10n.theServerSupportsLiveResizingDisplay,
    false =>
      vnc
          ? context.l10n.theServerDoesntSupportResizingOnly
          : context.l10n.theServerDoesntOfferDisplayControl,
    null => context.l10n.waitingForTheServerToReport,
  };
  await showAppDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const ValueKey('desktop_resolution_dialog'),
        title: Text(context.l10n.resolutionAndScaling),
        content: SizedBox(
          width: appDialogWidth(context, 420),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  multimon
                      ? context.l10n.thisSessionUsesAllLocalMonitors
                      : capability(),
                  key: const ValueKey('desktop_resolution_capability'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                DesktopResolutionPicker(
                  keyPrefix: 'session',
                  chinese: true,
                  allowServer: vnc,
                  enabled: true,
                  value: value,
                  onChanged: (v) => setState(() => value = v),
                  scaling: scaling,
                  onScalingChanged: (s) => setState(() => scaling = s),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('desktop_resolution_apply'),
            onPressed: value.validate() != null
                ? null
                : () async {
                    Navigator.of(dialogContext).pop();
                    if (scaling != session.localScaling) {
                      await session.setLocalScaling(scaling);
                    }
                    final changed =
                        value.kind != initial.kind ||
                        (value.kind == DesktopResolutionKind.fixed &&
                            (value.width != initial.width ||
                                value.height != initial.height));
                    if (!multimon && changed) {
                      await session.changeResolution(
                        width: value.kind == DesktopResolutionKind.fixed
                            ? value.width
                            : null,
                        height: value.kind == DesktopResolutionKind.fixed
                            ? value.height
                            : null,
                        server: value.kind == DesktopResolutionKind.server,
                      );
                    }
                  },
            child: Text(context.l10n.apply),
          ),
        ],
      ),
    ),
  );
}
