import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../platform/fullscreen.dart';
import '../storage/desktop_keyboard_store.dart';

enum DesktopKeyboardMode { overlay, resize }

/// Keyboard ownership is separate from the saved mode: forms and SSH keep
/// their usual IME layout, even when overlay is the remote-desktop default.
class DesktopKeyboardController extends ChangeNotifier {
  static DesktopKeyboardController? _instance;
  static DesktopKeyboardController get instance =>
      _instance ??= DesktopKeyboardController();
  @visibleForTesting
  static set debugInstance(DesktopKeyboardController? value) =>
      _instance = value;
  DesktopKeyboardMode mode = DesktopKeyboardMode.overlay;
  final _owners = <Object>{};
  DesktopKeyboardStore? _store;
  Future<void> _writes = Future.value();
  bool writeFailed = false, _disposed = false, _notificationPending = false;
  FocusNode? closingKeyboardFocus;
  bool get overlayActive =>
      mode == DesktopKeyboardMode.overlay && _owners.isNotEmpty;

  Future<void> load(DesktopKeyboardStore store) async {
    _store = store;
    String? value;
    try {
      value = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      /* A missing/unreadable preference keeps the overlay default. */
    }
    if (_disposed) return;
    mode = value == 'resize'
        ? DesktopKeyboardMode.resize
        : DesktopKeyboardMode.overlay;
    notifyListeners();
  }

  void keyboardVisible(Object owner, bool visible, {FocusNode? focus}) {
    final previous = overlayActive;
    closingKeyboardFocus = focus;
    if (visible) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    if ((previous == overlayActive && visible) ||
        _notificationPending ||
        _disposed)
      return;
    // Focus/dispose callbacks can run during layout. Never dirty an ancestor
    // synchronously while its pane is being built or removed.
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> select(DesktopKeyboardMode value) {
    mode = value;
    notifyListeners();
    final store = _store;
    if (store == null || _disposed) return Future<void>.value();
    return _writes = _writes.then((_) async {
      if (_disposed) return;
      try {
        await store.write(value.name);
        writeFailed = false;
      } on Object {
        writeFailed = true;
      }
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _owners.clear();
    super.dispose();
  }
}

/// Keep the Navigator and every live pane in the same widget slot. Removing
/// IME insets only while a desktop owns it makes Android draw the keyboard
/// over the existing workspace instead of resizing its remote framebuffer.
class DesktopKeyboardViewport extends StatefulWidget {
  const DesktopKeyboardViewport({required this.child, super.key});
  final Widget child;
  @override
  State<DesktopKeyboardViewport> createState() =>
      _DesktopKeyboardViewportState();
}

class _DesktopKeyboardViewportState extends State<DesktopKeyboardViewport> {
  double? _idleBottom;
  bool _wasFullscreen = false;
  bool _holdOverlay = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      DesktopKeyboardController.instance,
      FullscreenController.instance,
    ]),
    child: widget.child,
    builder: (context, child) {
      final data = MediaQuery.of(context);
      final android = Theme.of(context).platform == TargetPlatform.android;
      final fullscreen = android && FullscreenController.instance.enabled;
      // Capture the actual safe area before IME owns the navigation bar.
      // In fullscreen it starts at zero; while typing Android may add a
      // navigation bar, so using the *current* viewPadding would resize again.
      if (fullscreen) {
        _idleBottom = 0;
      } else if (_wasFullscreen || data.viewInsets.bottom == 0) {
        _idleBottom = data.viewInsets.bottom == 0
            ? data.padding.bottom
            : data.viewPadding.bottom;
      }
      _wasFullscreen = fullscreen;
      final keyboards = DesktopKeyboardController.instance;
      if (keyboards.overlayActive) {
        _holdOverlay = true;
      } else if (data.viewInsets.bottom == 0 ||
          keyboards.closingKeyboardFocus?.hasFocus != true) {
        _holdOverlay = false;
      }
      final overlay =
          android &&
          keyboards.mode == DesktopKeyboardMode.overlay &&
          (keyboards.overlayActive || _holdOverlay);
      return MediaQuery(
        data: overlay
            ? data.copyWith(
                viewInsets: data.viewInsets.copyWith(bottom: 0),
                // Android normally removes the navigation safe area while
                // IME is visible. Keep it too, otherwise a tablet desktop
                // grows by that strip and still sends a remote resize.
                padding: data.padding.copyWith(
                  bottom: _idleBottom ?? data.viewPadding.bottom,
                ),
              )
            : fullscreen
            ? data.copyWith(padding: data.padding.copyWith(bottom: 0))
            : data,
        child: child!,
      );
    },
  );
}

class DesktopKeyboardSettings extends StatelessWidget {
  const DesktopKeyboardSettings({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: DesktopKeyboardController.instance,
    builder: (context, _) {
      final controller = DesktopKeyboardController.instance;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.desktopKeyboardModeTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<DesktopKeyboardMode>(
            key: const ValueKey('desktop_keyboard_mode'),
            initialValue: controller.mode,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.l10n.desktopKeyboardModeTitle,
            ),
            items: [
              DropdownMenuItem(
                value: DesktopKeyboardMode.overlay,
                child: Text(context.l10n.desktopKeyboardOverlay),
              ),
              DropdownMenuItem(
                value: DesktopKeyboardMode.resize,
                child: Text(context.l10n.desktopKeyboardResize),
              ),
            ],
            onChanged: (value) {
              if (value != null) unawaited(controller.select(value));
            },
          ),
          const SizedBox(height: 8),
          Text(
            controller.mode == DesktopKeyboardMode.overlay
                ? context.l10n.desktopKeyboardOverlayDescription
                : context.l10n.desktopKeyboardResizeDescription,
          ),
          if (controller.writeFailed)
            Text(context.l10n.desktopKeyboardSaveFailed),
        ],
      );
    },
  );
}
