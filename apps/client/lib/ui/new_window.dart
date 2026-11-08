import '../domain/window_placement.dart';
import '../platform/file_window_tracking_contract.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/files_window_launch.dart';
import 'new_window_native.dart'
    if (dart.library.js_interop) 'new_window_web.dart'
    as platform;
import '../l10n/l10n.dart';

bool get supportsNewWindow => platform.supportsNewWindow;
bool get supportsFilesWindows => platform.supportsFilesWindows;
Future<void> openNewWindow() => platform.openNewWindow();
Future<void> openFilesWindow(
  FilesWindowLaunch launch, {
  Object? trackingOwner,
}) => platform.openFilesWindow(launch, trackingOwner: trackingOwner);
Future<TrackedFileWindowHandle> openTrackedFilesWindow(
  FilesWindowLaunch launch, {
  required Object owner,
  SavedWindowPlacement? placement,
  bool Function()? isCurrent,
}) => platform.openTrackedFilesWindow(
  launch,
  owner: owner,
  placement: placement,
  isCurrent: isCurrent,
);

KeyEventResult handleNewWindowKeyEvent(BuildContext context, KeyEvent event) {
  final keyboard = HardwareKeyboard.instance;
  if (!supportsNewWindow ||
      event is! KeyDownEvent ||
      event.logicalKey != LogicalKeyboardKey.keyN ||
      !keyboard.isControlPressed ||
      !keyboard.isShiftPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed) {
    return KeyEventResult.ignored;
  }
  openNewWindow().catchError((Object _) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(context.l10n.couldntOpenANewWindow)),
      );
    }
  });
  return KeyEventResult.handled;
}

/// Put inside MaterialApp's builder so errors have a ScaffoldMessenger.
class WorkspaceWindowShortcuts extends StatelessWidget {
  const WorkspaceWindowShortcuts({
    super.key,
    required this.child,
    this.onError,
  });
  final Widget child;
  final VoidCallback? onError;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: supportsNewWindow
        ? <ShortcutActivator, VoidCallback>{
            const SingleActivator(
              LogicalKeyboardKey.keyN,
              control: true,
              shift: true,
            ): () async {
              try {
                await openNewWindow();
              } catch (_) {
                if (onError != null) {
                  onError!();
                } else if (context.mounted) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(context.l10n.unableToOpenANewWindow),
                    ),
                  );
                }
              }
            },
          }
        : const <ShortcutActivator, VoidCallback>{},
    child: child,
  );
}
