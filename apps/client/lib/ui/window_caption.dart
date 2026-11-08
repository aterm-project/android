import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/window_chrome.dart';
import 'terminal_palette.dart';
import 'workspace_controls.dart';
import '../l10n/l10n.dart';

class WindowChromeScope extends InheritedWidget {
  const WindowChromeScope({
    super.key,
    required this.controller,
    required super.child,
    this.menuContext,
  });
  final WindowChromeController controller;
  final BuildContext? Function()? menuContext;
  static WindowChromeController of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WindowChromeScope>()
          ?.controller ??
      WindowChromeController.instance;
  @override
  bool updateShouldNotify(WindowChromeScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Wrap in MaterialApp.builder so startup, authentication and both workspaces
/// share one caption. Unsupported/missing native runners retain their frame.
class WindowsWindowChrome extends StatefulWidget {
  const WindowsWindowChrome({
    super.key,
    required this.child,
    this.title = '',
    this.leading,
    this.actions = const [],
    this.controller,
    this.navigationState,
    this.navigationEmbedded,
  });

  final Widget child;
  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final WindowChromeController? controller;
  final Listenable? navigationState;
  final bool Function()? navigationEmbedded;

  @override
  State<WindowsWindowChrome> createState() => _WindowsWindowChromeState();
}

class _WindowsWindowChromeState extends State<WindowsWindowChrome> {
  final _contentKey = GlobalKey();
  WindowChromeController get controller =>
      widget.controller ?? WindowChromeController.instance;

  BuildContext? _findMenuContext() {
    // MaterialApp.builder sits above its Navigator. Use only the Navigator
    // contained in this window when its fallback caption opens an app menu.
    BuildContext? result;
    void visit(Element element) {
      if (result != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        final overlay =
            (element.state as NavigatorState).overlay?.context as Element?;
        overlay?.visitChildElements((child) => result ??= child);
        return;
      }
      element.visitChildElements(visit);
    }

    (_contentKey.currentContext as Element?)?.visitChildElements(visit);
    return result;
  }

  @override
  void initState() {
    super.initState();
    unawaited(controller.start());
  }

  @override
  void didUpdateWidget(WindowsWindowChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(controller.start());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, widget.navigationState]),
    builder: (context, _) {
      return WindowChromeScope(
        controller: controller,
        menuContext: _findMenuContext,
        // App-root presentation scope: every MaterialApp root wraps its
        // content in this chrome, so terminal views rebuild in place when the
        // device-local palette overlay changes.
        child: TerminalPaletteScope(
          notifier: TerminalPaletteController.instance,
          child: Overlay.wrap(
          child: Column(
            children: [
              if (controller.supported &&
                  controller.state.enabled &&
                  !(widget.navigationEmbedded?.call() ?? false))
                WindowCaption(
                  controller: controller,
                  title: widget.title,
                  leading: widget.leading,
                  actions: widget.actions,
                ),
              Expanded(
                child: KeyedSubtree(key: _contentKey, child: widget.child),
              ),
            ],
          ),
        ),
        ),
      );
    },
  );
}

/// Sizes for the single merged Windows top bar (caption, drag region, Home and
/// session tabs, search/tools icons and caption buttons share one row).
///
/// On a custom-chrome Windows window the row height is the runner-reported
/// native caption metric ([WindowChromeState.captionHeight]); it follows DPI,
/// non-client metric and theme changes through `stateChanged`. It only grows
/// beyond the metric when the user's text scale would otherwise clip the tab
/// label. Elsewhere (Android/iOS/web/macOS/Linux, or Windows with the system
/// frame) the existing 48 px touch-sized bar is kept unchanged.
@immutable
class WindowBarMetrics {
  const WindowBarMetrics._({
    required this.height,
    required this.dense,
    required this.tabHeight,
    required this.tabInset,
    required this.iconSize,
    required this.actionWidth,
  });

  /// Touch-sized bar used when the native caption is not merged.
  static const touch = WindowBarMetrics._(
    height: 48,
    dense: false,
    tabHeight: 32,
    tabInset: 8,
    iconSize: 18,
    actionWidth: 48,
  );

  /// Used only if a custom-chrome runner does not report the metric.
  static const fallbackCaptionHeight = 32.0;

  /// Label font size inside dense native-height tabs.
  static const denseLabelSize = 12.5;

  factory WindowBarMetrics.of(
    BuildContext context,
    WindowChromeController controller,
  ) {
    if (!controller.supported || !controller.state.enabled) return touch;
    return WindowBarMetrics.native(
      controller.state.captionHeight ?? fallbackCaptionHeight,
      MediaQuery.textScalerOf(context),
    );
  }

  /// [captionHeight] is the native metric in logical pixels.
  factory WindowBarMetrics.native(double captionHeight, TextScaler scaler) {
    const inset = 4.0;
    // Strut-forced label line + 1 px borders: the minimum that never clips.
    final label = scaler.scale(denseLabelSize) * _labelLineHeight + 2;
    final height = math.max(captionHeight, label + inset * 2);
    return WindowBarMetrics._(
      height: height,
      dense: true,
      tabHeight: height - inset * 2,
      tabInset: inset,
      iconSize: 16,
      actionWidth: 40,
    );
  }

  static const _labelLineHeight = 1.3;

  /// Strut that pins the tab label line box so CJK/Cyrillic fallback fonts
  /// cannot grow it past [tabHeight].
  static const denseLabelStrut = StrutStyle(
    fontSize: denseLabelSize,
    height: _labelLineHeight,
    forceStrutHeight: true,
  );

  final double height;
  final bool dense;
  final double tabHeight;
  final double tabInset;
  final double iconSize;
  final double actionWidth;
}

class WindowCaption extends StatelessWidget {
  const WindowCaption({
    super.key,
    required this.controller,
    this.title = '',
    this.leading,
    this.actions = const [],
  });

  /// Height when the runner did not report a native metric.
  static const height = WindowBarMetrics.fallbackCaptionHeight;
  final WindowChromeController controller;
  final String title;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final metrics = WindowBarMetrics.of(context, controller);
      return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        key: const ValueKey('windows_window_caption'),
        height: metrics.height,
        child: Row(
          children: [
            ?leading,
            Expanded(
              child: WindowDragArea(
                controller: controller,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: controller.state.focused
                            ? null
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ...actions,
            WindowCaptionControls(
              controller: controller,
              height: metrics.height,
            ),
          ],
        ),
      ),
    );
    },
  );
}

/// Only the unused navigation area initiates a window drag; tab gestures keep
/// their existing drag-to-reorder/split behavior.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({
    super.key,
    required this.controller,
    required this.child,
  });
  final WindowChromeController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('window_caption_drag_area'),
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => unawaited(controller.beginDrag()),
    onDoubleTap: () => unawaited(controller.toggleMaximize()),
    onSecondaryTapDown: (event) {
      final target = Navigator.maybeOf(context) != null
          ? context
          : context
                .getInheritedWidgetOfExactType<WindowChromeScope>()
                ?.menuContext
                ?.call();
      if (target == null || !target.mounted) return;
      unawaited(
        showWorkspaceContextMenu(target, event.globalPosition, [
          WorkspaceAction(
            'window_restore',
            context.l10n.restore2,
            Icons.filter_none,
            controller.toggleMaximize,
            enabled: controller.state.maximized,
          ),
          WorkspaceAction(
            'window_minimize',
            context.l10n.minimize2,
            Icons.remove,
            controller.minimize,
          ),
          WorkspaceAction(
            'window_maximize',
            context.l10n.maximize2,
            Icons.crop_square,
            controller.toggleMaximize,
            enabled: !controller.state.maximized,
          ),
          WorkspaceAction(
            'window_close',
            context.l10n.closeWindow2,
            Icons.close,
            controller.close,
          ),
        ]),
      );
    },
    child: child,
  );
}

class WindowCaptionControls extends StatelessWidget {
  const WindowCaptionControls({
    super.key,
    required this.controller,
    this.height,
  });
  final WindowChromeController controller;

  /// Null follows the native caption metric of [controller].
  final double? height;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.supported || !controller.state.enabled) {
        return const SizedBox.shrink();
      }
      final height =
          this.height ?? WindowBarMetrics.of(context, controller).height;
      return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CaptionButton(
                height: height,
                id: 'minimize',
                label: context.l10n.minimize,
                icon: Icons.remove,
                onPressed: controller.minimize,
              ),
              _CaptionButton(
                height: height,
                id: 'maximize',
                label: controller.state.maximized
                    ? context.l10n.restore
                    : context.l10n.maximize,
                icon: controller.state.maximized
                    ? Icons.filter_none
                    : Icons.crop_square,
                onPressed: controller.toggleMaximize,
              ),
              _CaptionButton(
                height: height,
                id: 'close',
                label: context.l10n.closeWindow,
                icon: Icons.close,
                close: true,
                onPressed: controller.close,
              ),
            ],
          );
    },
  );
}

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    required this.id,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.close = false,
    required this.height,
  });
  final String id;
  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool close;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 46,
    height: height,
    child: Tooltip(
      message: label,
      child: TextButton(
        key: ValueKey('window_caption_$id'),
        onPressed: () => unawaited(onPressed()),
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          minimumSize: const WidgetStatePropertyAll(Size.zero),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                close &&
                    (states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.pressed))
                ? Colors.white
                : Theme.of(context).colorScheme.onSurface,
          ),
          overlayColor: close
              ? WidgetStateProperty.resolveWith(
                  (states) =>
                      states.contains(WidgetState.hovered) ||
                          states.contains(WidgetState.pressed)
                      ? const Color(0xFFE81123)
                      : null,
                )
              : null,
        ),
        child: Semantics(label: label, child: Icon(icon, size: 16)),
      ),
    ),
  );
}
