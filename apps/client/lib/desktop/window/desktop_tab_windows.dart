import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/application_windows.dart';
import '../desktop_session.dart';
import 'desktop_window_contract.dart';
import 'monitor_windows.dart';

/// Window operations for one remote desktop tab, shared by the local and
/// account workspaces so their integration stays a few lines each.
///
/// Window ids: the tab id for the whole desktop, `"<tab>#monitor<i>"` for
/// monitor windows. All are owned by the workspace's window owner, so the
/// existing `closeOwner` on lock/exit/workspace switch revokes them too.
class DesktopTabWindows {
  const DesktopTabWindows._();
  static const maxMonitors = 16;

  static String monitorId(String tabId, int index) => '$tabId#monitor$index';

  /// Move the whole desktop into its own window. Same contract as terminal
  /// detach: [onDetached] hides the tab, [onRestored] shows it again if the
  /// window is lost, [onUserClosed] runs when the user closes the window.
  static Future<bool> detach({
    required ApplicationWindows windows,
    required Object owner,
    required String tabId,
    required DesktopSession session,
    required String title,
    required VoidCallback onDetached,
    required FutureOr<void> Function() onUserClosed,
    required VoidCallback onRestored,
  }) {
    if (session.state != 'connected') return Future.value(false);
    return windows.detachDesktop(
      owner: owner,
      windowId: tabId,
      session: session,
      spec: DesktopWindowSpec(title: title),
      onDetached: onDetached,
      onUserClosed: onUserClosed,
      onRestored: onRestored,
    );
  }

  /// Open one borderless window per remote monitor. The tab keeps the
  /// session: closing a monitor window ends only that renderer. Calling again
  /// re-opens just the monitors whose windows are gone (already-open ones are
  /// de-duplicated by window id). Returns how many monitor windows are open.
  static Future<int> openMonitors({
    required ApplicationWindows windows,
    required Object owner,
    required String tabId,
    required DesktopSession session,
    required String title,
  }) async {
    final specs = monitorWindowSpecs(
      session.rdpConfig?.monitors ?? const [],
      title,
    );
    if (session.state != 'connected' || specs.isEmpty) return 0;
    final results = await Future.wait([
      for (var i = 0; i < specs.length && i < maxMonitors; i++)
        windows.detachDesktop(
          owner: owner,
          windowId: monitorId(tabId, i),
          session: session,
          spec: specs[i],
          onDetached: () {},
          onUserClosed: () {},
          onRestored: () {},
        ),
    ]);
    return results.where((ok) => ok).length;
  }

  /// Close the tab's main and monitor windows (before closing its session).
  static Future<void> closeAll({
    required ApplicationWindows windows,
    required Object owner,
    required String tabId,
  }) async {
    await Future.wait([
      windows.closeSession(owner, tabId),
      for (var i = 0; i < maxMonitors; i++)
        windows.closeSession(owner, monitorId(tabId, i)),
    ]);
  }
}
