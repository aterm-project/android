import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_motion.dart';
import '../platform/fullscreen.dart';

class WorkspaceStatusBar extends StatelessWidget {
  const WorkspaceStatusBar({
    required this.status,
    required this.detail,
    required this.sessionCount,
    this.onProperties,
    this.transfer,
    super.key,
  });
  final String status;
  final String detail;
  final int sessionCount;
  final VoidCallback? onProperties;
  final Widget? transfer;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FullscreenController.instance,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    if ((Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS) &&
        FullscreenController.instance.enabled)
      return const SizedBox.shrink();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    // The bar grows with the user's text scale instead of clipping glyphs;
    // 28px stays the height at 100%.
    final lineHeight = MediaQuery.textScalerOf(context).scale(11) * 1.4;
    final height = lineHeight + 12 > 28 ? lineHeight + 12 : 28.0;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          key: const ValueKey('workspace_status_bar'),
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Narrow phones / large text: tighter gaps; every text segment
              // can shrink (ellipsis) so the Row never overflows.
              final narrow = constraints.maxWidth < 420;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 12),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 13),
                    const SizedBox(width: 6),
                    // connecting → connected / disconnected cross-fades.
                    Flexible(
                      flex: 2,
                      child: MotionSwitcher(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          status,
                          key: ValueKey(status),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    SizedBox(width: narrow ? 8 : 14),
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        onSecondaryTap: onProperties,
                        onTap: onProperties,
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    if (transfer != null) Flexible(child: transfer!),
                    SizedBox(width: narrow ? 6 : 10),
                    Text(
                      '$sessionCount SSH',
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
