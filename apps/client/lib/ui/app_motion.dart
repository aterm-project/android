import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Shared motion language for Atermius.
///
/// Rules (see `.codex-build/motion-claude-20261107/STATUS.md`):
/// * Short and calm: 120–220 ms, decelerate in / accelerate out, never
///   overshoot or bounce.
/// * Paint-only: opacity, translation and scale. Motion never changes the
///   layout size of a hit target, so pointer, drag-to-split and caption
///   buttons land exactly where the final frame shows them.
/// * Identity-preserving: motion wrappers never re-key, duplicate or delay
///   the child they animate. Live terminal / desktop views keep their
///   element, focus node, IME connection and parent-owned transport.
/// * Accessibility: `MediaQuery.disableAnimations` → instant final state;
///   `MediaQuery.accessibleNavigation` (screen reader) → fade only, no
///   movement, and semantics stay present during the fade.
enum MotionLevel { full, fadeOnly, off }

abstract final class MotionDurations {
  /// Selection colour / border changes and menu dismissal.
  static const quick = Duration(milliseconds: 120);

  /// Dialogs, popovers, menus, tab entrance, small status swaps.
  static const standard = Duration(milliseconds: 160);

  /// Page / category switches and theme page routes.
  static const page = Duration(milliseconds: 200);

  /// Side sheet (Host editor drawer).
  static const sheet = Duration(milliseconds: 220);
}

abstract final class MotionCurves {
  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve move = Curves.easeInOutCubic;
}

abstract final class MotionDistances {
  /// Vertical lift for pages, lists and route entrances.
  static const double lift = 8;

  /// Horizontal travel of the right-hand side sheet.
  static const double sheet = 28;

  /// Drop distance of the top search palette.
  static const double palette = 8;

  /// Starting scale of centred dialogs.
  static const double dialogScale = .97;
}

abstract final class AppMotion {
  static MotionLevel levelOf(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return MotionLevel.off;
    }
    if (MediaQuery.maybeAccessibleNavigationOf(context) ?? false) {
      return MotionLevel.fadeOnly;
    }
    return MotionLevel.full;
  }

  static bool reduced(BuildContext context) =>
      levelOf(context) == MotionLevel.off;

  static Duration duration(BuildContext context, Duration value) =>
      reduced(context) ? Duration.zero : value;

  /// Popup menus: the Material reveal shortened from 300 ms to 160 ms
  /// (the default reverse interval closes in ~2/3 of that).
  static AnimationStyle menuStyle(BuildContext context) => reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
          duration: MotionDurations.standard,
          curve: MotionCurves.enter,
        );

  static AnimationStyle dialogStyle(
    BuildContext context, {
    AppDialogMotion motion = AppDialogMotion.center,
  }) => reduced(context)
      ? AnimationStyle.noAnimation
      : AnimationStyle(
          duration: motion == AppDialogMotion.sideSheet
              ? MotionDurations.sheet
              : MotionDurations.standard,
          curve: MotionCurves.enter,
          reverseCurve: MotionCurves.exit,
        );
}

/// Replays a short fade + lift on [trigger] changes while keeping the very
/// same [child] element mounted. Nothing is re-keyed: the caller's widget
/// identity rules (types / keys) decide whether state survives, exactly as
/// without this wrapper. Use for page/category switches, list filter changes
/// and one-shot phase changes; there is no outgoing copy that could keep
/// focus or receive taps.
class MotionEntrance extends StatefulWidget {
  const MotionEntrance({
    super.key,
    required this.trigger,
    required this.child,
    this.duration = MotionDurations.page,
    this.offset = const Offset(0, MotionDistances.lift),
    this.animateOnFirstBuild = false,
  });

  final Object? trigger;
  final Widget child;
  final Duration duration;
  final Offset offset;

  /// Startup surfaces should stay `false` so first use is never delayed.
  final bool animateOnFirstBuild;

  @override
  State<MotionEntrance> createState() => _MotionEntranceState();
}

class _MotionEntranceState extends State<MotionEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );
  bool _started = false;
  MotionLevel _level = MotionLevel.full;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _level = AppMotion.levelOf(context);
    if (!_started) {
      _started = true;
      if (widget.animateOnFirstBuild) _replay();
    } else if (_level == MotionLevel.off && _controller.isAnimating) {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(MotionEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.trigger != oldWidget.trigger) _replay();
  }

  void _replay() {
    if (_level == MotionLevel.off) {
      _controller.value = 1;
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _FadeLift(
    animation: _controller,
    curve: MotionCurves.enter,
    offset: _level == MotionLevel.full ? widget.offset : Offset.zero,
    child: widget.child,
  );
}

/// Opacity + translation driven by [animation]. Only this thin wrapper
/// rebuilds per frame; the identical child widget is reused untouched. At
/// rest (t == 1) `RenderOpacity` paints the child directly without a layer.
///
/// The widget structure (Opacity → Transform → child) is identical in every
/// motion level, so toggling reduced motion or a screen reader at runtime only
/// changes values and never remounts the child (no lost input or focus).
class _FadeLift extends AnimatedWidget {
  const _FadeLift({
    required Animation<double> animation,
    required this.curve,
    required this.offset,
    required this.child,
    this.reverseCurve,
    this.hideWhileReversing = false,
  }) : super(listenable: animation);

  final Curve curve;
  final Curve? reverseCurve;
  final Offset offset;
  final Widget child;

  /// Reduced-motion routes: show the final state at once and hide a popped
  /// page immediately instead of fading it.
  final bool hideWhileReversing;

  @override
  Widget build(BuildContext context) {
    final animation = listenable as Animation<double>;
    final hidden =
        hideWhileReversing && animation.status == AnimationStatus.reverse;
    final t = hidden
        ? 0.0
        : hideWhileReversing
        ? 1.0
        : _curved(animation, curve, reverseCurve ?? curve);
    return Opacity(
      opacity: t,
      alwaysIncludeSemantics: !hidden,
      child: Transform.translate(offset: offset * (1 - t), child: child),
    );
  }
}

double _curved(Animation<double> animation, Curve enter, Curve exit) {
  final value = animation.value.clamp(0.0, 1.0);
  if (value >= 1) return 1;
  if (value <= 0) return 0;
  return (animation.status == AnimationStatus.reverse ? exit : enter).transform(
    value,
  );
}

/// Fade (no movement) between small *stateless* status widgets: loading /
/// success / error indicators, counters, labels. Outgoing children are
/// non-interactive and invisible to focus and semantics. Never wrap live
/// session views, text fields or anything holding a `GlobalKey`.
class MotionSwitcher extends StatelessWidget {
  const MotionSwitcher({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: AppMotion.duration(context, MotionDurations.standard),
    reverseDuration: AppMotion.duration(context, MotionDurations.quick),
    switchInCurve: MotionCurves.enter,
    switchOutCurve: MotionCurves.exit,
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    transitionBuilder: _fadeTransition,
    child: child,
  );

  static Widget _fadeTransition(Widget child, Animation<double> animation) =>
      _OutgoingGuard(
        animation: animation,
        child: FadeTransition(opacity: animation, child: child),
      );
}

class _OutgoingGuard extends AnimatedWidget {
  const _OutgoingGuard({
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outgoing =
        (listenable as Animation<double>).status == AnimationStatus.reverse;
    return IgnorePointer(
      ignoring: outgoing,
      child: ExcludeFocus(
        excluding: outgoing,
        child: ExcludeSemantics(excluding: outgoing, child: child),
      ),
    );
  }
}

enum AppDialogMotion {
  /// Centred dialogs: fade + 0.97 → 1 scale.
  center,

  /// Right-aligned drawer (Host editor): fade + slide from the right edge.
  sideSheet,

  /// Top command / search palette: fade + small drop.
  palette,
}

/// Paint-only entrance for dialog content, driven by the enclosing route's
/// animation (the route itself supplies the barrier and the fade).
class AppDialogMotionFrame extends StatelessWidget {
  const AppDialogMotionFrame({
    super.key,
    required this.motion,
    required this.child,
  });

  final AppDialogMotion motion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Always AnimatedBuilder → Transform → child, whatever the motion level:
    // a runtime accessibility change (reduced motion, screen reader) must not
    // remount dialog content and lose unsaved input or focus. When motion is
    // not full the transform is simply the identity.
    final animation =
        ModalRoute.of(context)?.animation ?? kAlwaysCompleteAnimation;
    final moving = AppMotion.levelOf(context) == MotionLevel.full;
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final rest = moving
            ? 1 - _curved(animation, MotionCurves.enter, MotionCurves.exit)
            : 0.0;
        final direction = Directionality.of(context) == TextDirection.rtl
            ? -1.0
            : 1.0;
        final scale = 1 - (1 - MotionDistances.dialogScale) * rest;
        final transform = switch (motion) {
          AppDialogMotion.center => Matrix4.diagonal3Values(scale, scale, 1),
          AppDialogMotion.sideSheet => Matrix4.translationValues(
            MotionDistances.sheet * rest * direction,
            0,
            0,
          ),
          AppDialogMotion.palette => Matrix4.translationValues(
            0,
            -MotionDistances.palette * rest,
            0,
          ),
        };
        return Transform(
          alignment: Alignment.center,
          transform: transform,
          child: child,
        );
      },
    );
  }
}

/// Drop-in replacement for [showDialog] with the shared dialog motion.
/// Keeps every framework behaviour of `showDialog` (theme capture, pop
/// scope, focus traversal, barrier semantics); only the timing and a
/// paint-only scale / slide are added. Duration is zero when animations are
/// disabled so the dialog appears and disappears in its final state.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AppDialogMotion motion = AppDialogMotion.center,
}) => showDialog<T>(
  context: context,
  builder: (dialogContext) =>
      AppDialogMotionFrame(motion: motion, child: builder(dialogContext)),
  barrierDismissible: barrierDismissible,
  barrierColor: barrierColor,
  barrierLabel: barrierLabel,
  useSafeArea: useSafeArea,
  useRootNavigator: useRootNavigator,
  routeSettings: routeSettings,
  anchorPoint: anchorPoint,
  traversalEdgeBehavior: traversalEdgeBehavior,
  fullscreenDialog: fullscreenDialog,
  requestFocus: requestFocus,
  animationStyle: AppMotion.dialogStyle(context, motion: motion),
);

/// [DialogRoute] with the shared motion, for call sites that need the route
/// object itself (e.g. to remove it when its data becomes stale).
class AppDialogRoute<T> extends DialogRoute<T> {
  AppDialogRoute({
    required super.context,
    required WidgetBuilder builder,
    AppDialogMotion motion = AppDialogMotion.center,
    super.barrierColor,
    super.barrierDismissible,
    super.barrierLabel,
    super.useSafeArea,
    super.settings,
    super.themes,
  }) : super(
         builder: (dialogContext) => AppDialogMotionFrame(
           motion: motion,
           child: builder(dialogContext),
         ),
         animationStyle: AppMotion.dialogStyle(context, motion: motion),
       );
}

/// Theme-level page route motion: fade + 8 px lift over 200 ms. Replaces the
/// platform zoom / fade-forwards transitions so routes and in-app page
/// switches share one timing and never stack into a longer sequence.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => MotionDurations.page;

  @override
  Duration get reverseTransitionDuration => MotionDurations.standard;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final level = AppMotion.levelOf(context);
    // One structure for every level. Reduced motion: the route controller
    // still runs, but the page is shown in its final state at once and hidden
    // as soon as it is popped (the route already ignores pointers then).
    return _FadeLift(
      animation: animation,
      curve: MotionCurves.enter,
      reverseCurve: MotionCurves.exit,
      hideWhileReversing: level == MotionLevel.off,
      offset: level == MotionLevel.full
          ? const Offset(0, MotionDistances.lift)
          : Offset.zero,
      child: child,
    );
  }
}

/// Page transitions for [buildAppTheme]. iOS and macOS keep Cupertino so the
/// edge back-swipe gesture and platform convention stay intact.
const appPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: AppPageTransitionsBuilder(),
    TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
    TargetPlatform.linux: AppPageTransitionsBuilder(),
    TargetPlatform.windows: AppPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
  },
);
