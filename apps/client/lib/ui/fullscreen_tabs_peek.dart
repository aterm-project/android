import 'dart:async';

import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Android fullscreen "peek": tapping the white pane handle temporarily drops
/// the workspace tab strip down as an overlay above the selected pane.
///
/// The strip is painted in the route's [Overlay], so the workspace layout is
/// untouched: terminal grids and RDP resolutions keep their size and no pane
/// is remounted or reconnected. The peek hides itself after [autoHide] of
/// inactivity, but never while a finger is down on it (tab drags, long-press)
/// or while a menu/dialog route covers the workspace.
class FullscreenTabsPeek extends ChangeNotifier {
  FullscreenTabsPeek({this.autoHide = const Duration(seconds: 4)});

  static FullscreenTabsPeek? _instance;
  static FullscreenTabsPeek get instance => _instance ??= FullscreenTabsPeek();
  @visibleForTesting
  static set debugInstance(FullscreenTabsPeek? value) => _instance = value;

  /// [TapRegion] group shared by the dropped strip and the pane handle, so a
  /// tap on either is "inside" and anything else dismisses the peek.
  static const Object tapGroup = #atermiusFullscreenTabsPeek;

  final Duration autoHide;
  bool _visible = false, _disposed = false;
  final _pointers = <int>{};
  final _blockers = <Object>{};
  Timer? _timer;

  bool get visible => _visible;

  /// True while an interaction must keep the strip on screen.
  bool get held => _pointers.isNotEmpty || _blockers.isNotEmpty;

  @visibleForTesting
  bool get debugTimerActive => _timer?.isActive ?? false;

  void show() {
    if (_disposed) return;
    _arm();
    if (_visible) return;
    _visible = true;
    notifyListeners();
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    _pointers.clear();
    if (_disposed || !_visible) return;
    _visible = false;
    notifyListeners();
  }

  void toggle() => _visible ? hide() : show();

  /// Restarts the auto-hide countdown after an interaction.
  void keepAlive() {
    if (_visible && !_disposed) _arm();
  }

  void pointerDown(int pointer) {
    if (!_visible || _disposed) return;
    _pointers.add(pointer);
    _timer?.cancel();
    _timer = null;
  }

  void pointerUp(int pointer) {
    if (_pointers.remove(pointer)) keepAlive();
  }

  /// A menu or dialog route above the workspace pauses the countdown; its
  /// result must still reach the strip that opened it.
  void block(Object token) {
    if (!_blockers.add(token)) return;
    _timer?.cancel();
    _timer = null;
  }

  void unblock(Object token) {
    if (_blockers.remove(token)) keepAlive();
  }

  void _arm() {
    _timer?.cancel();
    _timer = held
        ? null
        : Timer(autoHide, () {
            _timer = null;
            if (!held) hide();
          });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Layout-free host for the workspace tab strip in Android fullscreen.
///
/// Occupies no space in the workspace column; while the peek is visible the
/// strip built by [builder] is painted at the top of the route's overlay.
class FullscreenTabsOverlay extends StatefulWidget {
  const FullscreenTabsOverlay({super.key, required this.builder});
  final WidgetBuilder builder;
  @override
  State<FullscreenTabsOverlay> createState() => _FullscreenTabsOverlayState();
}

class _FullscreenTabsOverlayState extends State<FullscreenTabsOverlay> {
  final _portal = OverlayPortalController();
  final _routeToken = Object();
  late final FullscreenTabsPeek _peek = FullscreenTabsPeek.instance;

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  bool get _routeCurrent => ModalRoute.isCurrentOf(context) ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent ? _peek.unblock(_routeToken) : _peek.block(_routeToken);
  }

  @override
  void dispose() {
    final peek = _peek;
    peek.unblock(_routeToken);
    // Leaving fullscreen or selecting Home retires the strip; notify only
    // after the current frame has finished unmounting.
    scheduleMicrotask(peek.hide);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Overlay.maybeOf(context) == null) return const SizedBox.shrink();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => ListenableBuilder(
        listenable: _peek,
        builder: (overlayContext, _) => Stack(
          children: [
            if (_peek.visible)
              Positioned(
                key: const ValueKey('fullscreen_tabs_overlay'),
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: TapRegion(
                    groupId: FullscreenTabsPeek.tapGroup,
                    // The dismissing tap stops here: gesture handlers outside
                    // the strip/handle (terminal, desktop, dock) never see
                    // it. Raw pointer input on the pane is blocked by the
                    // pane's barrier. Disabled by TapRegion itself while a
                    // menu/dialog route is on top; tab drags start inside.
                    consumeOutsideTaps: true,
                    onTapOutside: (_) {
                      // A tap inside an open menu/dialog is not "outside".
                      if (mounted && _routeCurrent) _peek.hide();
                    },
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) =>
                          _peek.pointerDown(event.pointer),
                      onPointerUp: (event) => _peek.pointerUp(event.pointer),
                      onPointerCancel: (event) =>
                          _peek.pointerUp(event.pointer),
                      child: MotionEntrance(
                        trigger: null,
                        animateOnFirstBuild: true,
                        duration: MotionDurations.quick,
                        offset: const Offset(0, -8),
                        child: DecoratedBox(
                          decoration: const BoxDecoration(
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x55000000),
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: widget.builder(overlayContext),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      child: const SizedBox.shrink(),
    );
  }
}
