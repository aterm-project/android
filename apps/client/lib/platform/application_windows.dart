import '../domain/window_placement.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../desktop/desktop_session.dart';
import '../desktop/window/desktop_window.dart';
import '../terminal/live_terminal_window.dart';
import '../terminal/mirrored_terminal.dart';
import 'window_chrome.dart';
import '../ssh/scp_transfer_activity.dart';

typedef LiveTerminalWindowOpener =
    Future<LiveTerminalWindowHandle> Function({
      required MirroredTerminal terminal,
      required String title,
      VoidCallback? onReady,
      ValueChanged<LiveTerminalWindowCloseReason>? onClosed,
      VoidCallback? onOpenFiles,
    });

typedef DesktopWindowOpener =
    Future<LiveTerminalWindowHandle> Function({
      required DesktopSession session,
      required DesktopWindowSpec spec,
      VoidCallback? onReady,
    });

/// Coordinates child-window lifetimes without moving SSH or credentials.
/// An owner must revoke its windows before locking/discarding its session keys.
class ApplicationWindows extends ChangeNotifier {
  ApplicationWindows({
    WindowChromeController? windowChrome,
    LiveTerminalWindowOpener? opener,
    DesktopWindowOpener? desktopOpener,
    bool? liveWindowsSupported,
    this.transferDrainTimeout = const Duration(seconds: 5),
  }) : _chrome = windowChrome ?? WindowChromeController.instance,
       _open = opener ?? openLiveTerminalWindow,
       _openDesktop = desktopOpener ?? openDesktopWindow,
       _supported = liveWindowsSupported ?? supportsLiveTerminalWindows;
  static final instance = ApplicationWindows();
  final WindowChromeController _chrome;
  final LiveTerminalWindowOpener _open;
  final DesktopWindowOpener _openDesktop;
  final bool _supported;
  final Duration transferDrainTimeout;
  final Map<_WindowKey, _WindowEntry> _entries = {};
  final Map<LiveTerminalWindowHandle, _WindowKey> _retiredChildren = {};
  final Set<LiveTerminalWindowHandle> _userClosing = {};
  final Map<Object, Future<void> Function()> _visibleClosers = {};
  final Map<Object, Future<void> Function()> _ownerClosers = {};
  bool _hidden = false,
      _parentClosing = false,
      _handlingClose = false,
      _exiting = false;
  int _finishing = 0;
  bool get hasDetachedWindows =>
      _entries.values.any((entry) => entry.ready && !entry.revoked);
  bool get supported =>
      _supported && _chrome.supported && _chrome.state.enabled;
  bool isDetached(Object owner, String sessionId) =>
      _entries[_WindowKey(owner, sessionId)]?.ready == true;
  Set<String> detachedSessionIds(Object owner) => _entries.values
      .where(
        (entry) =>
            identical(entry.key.owner, owner) && entry.ready && !entry.revoked,
      )
      .map((entry) => entry.key.sessionId)
      .toSet();

  /// In-memory window identities only; convert them to recipe pane indices.
  Future<List<DetachedWindowPlacement>> captureWindowPlacements(
    Object owner,
  ) async {
    final entries = _entries.values
        .where(
          (entry) =>
              identical(entry.key.owner, owner) &&
              entry.ready &&
              !entry.revoked,
        )
        .toList();
    if (entries.length > 32)
      throw StateError('Too many detached windows to save.');
    final snapshots = <DetachedWindowPlacement>[];
    await Future.wait(
      entries.map((entry) async {
        SavedWindowPlacement? placement;
        try {
          placement = await entry.handle?.capturePlacement?.call();
        } catch (_) {}
        if (identical(_entries[entry.key], entry) &&
            entry.ready &&
            !entry.revoked) {
          snapshots.add(
            DetachedWindowPlacement(
              windowId: entry.key.sessionId,
              placement: placement,
              desktopSpec: entry.desktopSpec,
            ),
          );
        }
      }),
    );
    return List.unmodifiable(snapshots);
  }

  Future<bool> applyWindowPlacement(
    Object owner,
    String windowId,
    SavedWindowPlacement placement,
  ) async {
    final key = _WindowKey(owner, windowId),
        entry = _entries[_WindowKey(owner, windowId)];
    if (entry == null || !entry.ready || entry.revoked) return false;
    try {
      final applied =
          await entry.handle?.applyPlacement?.call(placement) ?? false;
      return applied && !entry.revoked && identical(_entries[key], entry);
    } catch (_) {
      return false;
    }
  }

  Future<void> start({
    bool terminalChild = false,
    bool desktopChild = false,
  }) async {
    await _chrome.start();
    await _chrome.setCloseGuard(
      terminalChild
          ? () async {
              await closeLiveTerminalWindowClient();
              await _chrome.closeNow();
            }
          : desktopChild
          ? () async {
              await closeDesktopWindowClient();
              await _chrome.closeNow();
            }
          : requestParentClose,
    );
  }

  VoidCallback registerVisibleOwner(
    Object owner,
    Future<void> Function() closeVisible,
  ) {
    _visibleClosers[owner] = closeVisible;
    return () {
      if (identical(_visibleClosers[owner], closeVisible)) {
        _visibleClosers.remove(owner);
      }
    };
  }

  VoidCallback registerOwnerCloser(
    Object owner,
    Future<void> Function() closeOwner,
  ) {
    _ownerClosers[owner] = closeOwner;
    return () {
      if (identical(_ownerClosers[owner], closeOwner)) {
        _ownerClosers.remove(owner);
      }
    };
  }

  Future<bool> detach({
    required Object owner,
    required String sessionId,
    required MirroredTerminal terminal,
    required String title,
    required VoidCallback onDetached,
    required FutureOr<void> Function() onUserClosed,
    required VoidCallback onRestored,
    VoidCallback? onOpenFiles,
  }) async {
    return _detachWith(
      owner: owner,
      sessionId: sessionId,
      onDetached: onDetached,
      onUserClosed: onUserClosed,
      onRestored: onRestored,
      open: (entry, onReady) => _open(
        terminal: terminal,
        title: title,
        onReady: onReady,
        onOpenFiles: () {
          if (entry.revoked || !entry.ready) return;
          unawaited(
            showParent()
                .then((_) {
                  onOpenFiles?.call();
                })
                .catchError((Object _) {}),
          );
        },
      ),
    );
  }

  /// Show an RDP/VNC session (or one remote monitor of it) in its own window.
  /// The session, Host and credentials stay in this process; the child only
  /// mirrors frames and returns input. Keys are per [windowId], so one
  /// session can have several monitor windows. Owner revocation closes them
  /// exactly like terminal windows.
  Future<bool> detachDesktop({
    required Object owner,
    required String windowId,
    required DesktopSession session,
    required DesktopWindowSpec spec,
    required VoidCallback onDetached,
    required FutureOr<void> Function() onUserClosed,
    required VoidCallback onRestored,
  }) => _detachWith(
    owner: owner,
    desktopSpec: spec,
    sessionId: windowId,
    onDetached: onDetached,
    onUserClosed: onUserClosed,
    onRestored: onRestored,
    open: (entry, onReady) =>
        _openDesktop(session: session, spec: spec, onReady: onReady),
  );

  Future<bool> _detachWith({
    DesktopWindowSpec? desktopSpec,
    required Object owner,
    required String sessionId,
    required VoidCallback onDetached,
    required FutureOr<void> Function() onUserClosed,
    required VoidCallback onRestored,
    required Future<LiveTerminalWindowHandle> Function(
      _WindowEntry entry,
      VoidCallback onReady,
    )
    open,
  }) async {
    if (!supported || _exiting || _parentClosing) return false;
    final key = _WindowKey(owner, sessionId);
    final previous = _entries[key];
    if (previous != null) return previous.readiness.future;
    final entry = _WindowEntry(
      key,
      onUserClosed,
      onRestored,
      desktopSpec: desktopSpec,
    );
    _entries[key] = entry;
    try {
      final handle = await open(entry, () {
        if (entry.revoked || entry.finished.isCompleted) return;
        entry.ready = true;
        try {
          onDetached();
        } catch (_) {}
        notifyListeners();
      });
      entry.handle = handle;
      entry.started.complete();
      unawaited(handle.outcome.then((reason) => _finish(entry, reason)));
      if (entry.revoked) await handle.close();
      final ready = await handle.ready;
      if (!entry.readiness.isCompleted) {
        entry.readiness.complete(ready && !entry.revoked);
      }
      return ready && !entry.revoked;
    } catch (_) {
      if (!entry.started.isCompleted) entry.started.complete();
      await _finish(entry, LiveTerminalWindowCloseReason.startupFailed);
      return false;
    }
  }

  Future<void> _finish(
    _WindowEntry entry,
    LiveTerminalWindowCloseReason reason,
  ) async {
    if (entry.finishing || entry.finished.isCompleted) return;
    entry.finishing = true;
    _finishing++;
    if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
    if (!entry.readiness.isCompleted) entry.readiness.complete(false);
    final handle = entry.handle;
    if (handle != null) {
      _retiredChildren[handle] = entry.key;
      unawaited(
        handle.processExited.then((_) {
          _retiredChildren.remove(handle);
        }),
      );
      if (reason == LiveTerminalWindowCloseReason.user) {
        _userClosing.add(handle);
      }
    }
    try {
      if (!entry.revoked && entry.ready) {
        if (reason == LiveTerminalWindowCloseReason.user) {
          await entry.onUserClosed();
        } else {
          entry.onRestored();
          await showParent();
        }
      }
    } catch (_) {
      if (!entry.revoked && entry.ready) {
        try {
          entry.onRestored();
        } catch (_) {}
        await showParent();
      }
    } finally {
      if (handle != null) _userClosing.remove(handle);
      _finishing--;
      entry.finished.complete();
      notifyListeners();
      await _exitHiddenParentIfDone();
    }
  }

  Future<void> closeSession(Object owner, String sessionId) async {
    // Monitor mirrors are owned by their source session even after restore.
    final related = _entries.values
        .where(
          (entry) =>
              identical(entry.key.owner, owner) &&
              entry.key.sessionId.startsWith('$sessionId#'),
        )
        .toList();
    await Future.wait(
      related.map((entry) => closeSession(owner, entry.key.sessionId)),
    );

    final key = _WindowKey(owner, sessionId);
    final entry = _entries[key];
    final retired = _retiredChildren.entries
        .where(
          (item) =>
              (item.value == key ||
                  (identical(item.value.owner, owner) &&
                      item.value.sessionId.startsWith('$sessionId#'))) &&
              !_userClosing.contains(item.key),
        )
        .map((item) => item.key)
        .toList();
    if (entry != null) {
      entry.revoked = true;
      await entry.started.future;
      await entry.handle?.close();
      await entry.finished.future;
    }
    await Future.wait(retired.map((handle) => handle.close()));
  }

  Future<void> closeOwner(Object owner) async {
    final entries = _entries.values
        .where((entry) => identical(entry.key.owner, owner))
        .toList();
    final retired = _retiredChildren.entries
        .where((item) => identical(item.value.owner, owner))
        .map((item) => item.key)
        .toList();
    for (final entry in entries) {
      entry.revoked = true;
    }
    await Future.wait([
      ...entries.map((entry) => closeSession(owner, entry.key.sessionId)),
      ...retired.map((handle) => handle.close()),
    ]);
  }

  Future<void> closeAll() async {
    final entries = _entries.values.toList();
    final retired = _retiredChildren.keys.toList();
    for (final entry in entries) {
      entry.revoked = true;
    }
    await Future.wait([
      ...entries.map(
        (entry) => closeSession(entry.key.owner, entry.key.sessionId),
      ),
      ...retired.map((handle) => handle.close()),
    ]);
  }

  Future<void> showParent() async {
    _hidden = false;
    _parentClosing = false;
    await _chrome.show();
  }

  Future<void> requestParentClose() async {
    if (_handlingClose || _exiting) return;
    _handlingClose = true;
    _parentClosing = true;
    try {
      // Transfer channels must stop before their owning SSH sessions close.
      sshTransferActivity.cancelAll();
      if (sshTransferActivity.activeCount > 0) {
        final drained = Completer<void>();
        void check() {
          if (sshTransferActivity.activeCount == 0 && !drained.isCompleted) {
            drained.complete();
          }
        }

        sshTransferActivity.addListener(check);
        try {
          check();
          await drained.future.timeout(transferDrainTimeout);
        } finally {
          sshTransferActivity.removeListener(check);
        }
      }
      await Future.wait(
        _retiredChildren.keys.toList().map((handle) => handle.close()),
      );
      // Pending launches have not detached: close them before visible-session
      // cleanup so a late ready cannot claim a session already being closed.
      final pending = _entries.values.where((entry) => !entry.ready).toList();
      for (final entry in pending) {
        await closeSession(entry.key.owner, entry.key.sessionId);
      }
      for (final close in _visibleClosers.values.toList()) {
        await close();
      }
      if (hasDetachedWindows) {
        _hidden = true;
        await _chrome.hide();
      } else {
        await _closeNativeAfterOwners();
      }
    } catch (_) {
      _parentClosing = false;
      await _chrome.show();
    } finally {
      _handlingClose = false;
    }
  }

  Future<void> _exitHiddenParentIfDone() async {
    if (_parentClosing && _hidden && _entries.isEmpty && _finishing == 0) {
      await _closeNativeAfterOwners();
    }
  }

  Future<void> _closeNativeAfterOwners() async {
    if (_exiting) return;
    _exiting = true;
    try {
      // A concurrently revoking owner may have no visible detached windows
      // while its child process is still exiting. Drain every owned handle.
      await closeAll();
      for (final close in _ownerClosers.values.toList().reversed) {
        await close();
      }
      await _chrome.closeNow();
    } catch (_) {
      _exiting = false;
      _parentClosing = false;
      _hidden = false;
      await _chrome.show();
    }
  }
}

class _WindowKey {
  const _WindowKey(this.owner, this.sessionId);
  final Object owner;
  final String sessionId;
  @override
  bool operator ==(Object other) =>
      other is _WindowKey &&
      identical(owner, other.owner) &&
      sessionId == other.sessionId;
  @override
  int get hashCode => Object.hash(identityHashCode(owner), sessionId);
}

class _WindowEntry {
  _WindowEntry(
    this.key,
    this.onUserClosed,
    this.onRestored, {
    this.desktopSpec,
  });
  final DesktopWindowSpec? desktopSpec;
  final _WindowKey key;
  final FutureOr<void> Function() onUserClosed;
  final VoidCallback onRestored;
  final started = Completer<void>(), finished = Completer<void>();
  final readiness = Completer<bool>();
  LiveTerminalWindowHandle? handle;
  bool ready = false, revoked = false, finishing = false;
}

class DetachedWindowPlacement {
  const DetachedWindowPlacement({
    required this.windowId,
    required this.placement,
    this.desktopSpec,
  });
  final String windowId;
  final SavedWindowPlacement? placement;
  final DesktopWindowSpec? desktopSpec;
}
