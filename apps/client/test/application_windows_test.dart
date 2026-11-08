import 'package:aterm_client/ssh/scp_transfer_activity.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'dart:async';
import 'package:aterm_client/platform/application_windows.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Chrome extends WindowChromeController {
  _Chrome({this.enabled = true}) : super(supported: true);
  final bool enabled;
  @override
  WindowChromeState get state => WindowChromeState(enabled: enabled);
  final calls = <String>[];
  Future<void> Function()? guard;
  @override
  Future<void> start() async {}
  @override
  Future<void> setCloseGuard(Future<void> Function()? guard) async {
    this.guard = guard;
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> show() async {
    calls.add('show');
  }

  @override
  Future<void> closeNow() async {
    calls.add('close');
  }
}

class _Child {
  final ready = Completer<bool>(), closed = Completer<void>();
  final outcome = Completer<LiveTerminalWindowCloseReason>();
  final processExited = Completer<void>();
  Completer<void>? exitGate;
  Future<void>? _closing;
  int ownerCloses = 0;
  VoidCallback? onReady, onFiles;
  late final handle = LiveTerminalWindowHandle(
    ready: ready.future,
    closed: closed.future,
    outcome: outcome.future,
    processExited: processExited.future,
    close: closeOwner,
    port: 1234,
    sessionId: 'test',
  );
  Future<LiveTerminalWindowHandle> open({
    required MirroredTerminal terminal,
    required String title,
    VoidCallback? onReady,
    ValueChanged<LiveTerminalWindowCloseReason>? onClosed,
    VoidCallback? onOpenFiles,
  }) async {
    this.onReady = onReady;
    onFiles = onOpenFiles;
    return handle;
  }

  void paintReady() {
    onReady?.call();
    ready.complete(true);
  }

  Future<void> closeOwner() => _closing ??= (() async {
    ownerCloses++;
    if (exitGate != null) {
      // Deliberately publish socket outcome before physical exit to reproduce
      // the hidden-parent shutdown race independently of the native wrapper.
      await finish(
        LiveTerminalWindowCloseReason.parentClosed,
        processExit: false,
      );
      await exitGate!.future;
    }
    await finish(LiveTerminalWindowCloseReason.parentClosed);
  })();
  Future<void> finish(
    LiveTerminalWindowCloseReason reason, {
    bool processExit = true,
  }) async {
    if (!ready.isCompleted) ready.complete(false);
    if (!closed.isCompleted) closed.complete();
    if (!outcome.isCompleted) outcome.complete(reason);
    if (processExit && !processExited.isCompleted) processExited.complete();
  }
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'source remains visible until child paint acknowledgment; parent hides until last explicit child close',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      final actions = <String>[];
      manager.registerVisibleOwner(owner, () async {
        actions.add('close-visible');
      });
      manager.registerOwnerCloser(owner, () async {
        actions.add('close-owner');
      });
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () => actions.add('detached'),
        onRestored: () => actions.add('restored'),
        onUserClosed: () async {
          await manager.closeSession(owner, 'a');
          actions.add('close-ssh');
        },
      );
      await _flush();
      expect(manager.isDetached(owner, 'a'), isFalse);
      expect(actions, isEmpty);
      child.paintReady();
      expect(await opening, isTrue);
      expect(manager.isDetached(owner, 'a'), isTrue);
      await manager.requestParentClose();
      expect(actions, ['detached', 'close-visible']);
      expect(chrome.calls, ['hide']);
      await child.finish(LiveTerminalWindowCloseReason.user);
      await _flush();
      await _flush();
      expect(actions, [
        'detached',
        'close-visible',
        'close-ssh',
        'close-owner',
      ]);
      expect(chrome.calls, ['hide', 'close']);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'transport failure restores the source terminal and shows its hidden parent',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      var restored = 0, sshClosed = 0;
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () {},
        onRestored: () => restored++,
        onUserClosed: () async {
          sshClosed++;
        },
      );
      await _flush();
      child.paintReady();
      await opening;
      await manager.requestParentClose();
      await child.finish(LiveTerminalWindowCloseReason.transportLost);
      await _flush();
      expect(restored, 1);
      expect(sshClosed, 0);
      expect(chrome.calls, ['hide', 'show']);
      expect(manager.hasDetachedWindows, isFalse);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'owner revocation closes its child without resurrecting a locked source',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      var restored = 0, userClosed = 0;
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () {},
        onRestored: () => restored++,
        onUserClosed: () async {
          userClosed++;
        },
      );
      await _flush();
      child.paintReady();
      await opening;
      await manager.closeOwner(owner);
      expect(manager.hasDetachedWindows, isFalse);
      expect(restored, 0);
      expect(userClosed, 0);
      expect(chrome.calls, isEmpty);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'closing parent during pending launch cancels detach before visible session cleanup',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      var detached = 0, visibleClosed = 0;
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      manager.registerVisibleOwner(owner, () async {
        visibleClosed++;
      });
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () => detached++,
        onRestored: () {},
        onUserClosed: () async {},
      );
      await _flush();
      await manager.requestParentClose();
      expect(await opening, isFalse);
      expect(detached, 0);
      expect(visibleClosed, 1);
      expect(chrome.calls, ['close']);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'file intent shows source window without moving SSH ownership',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      var files = 0;
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () {},
        onRestored: () {},
        onUserClosed: () async {},
        onOpenFiles: () => files++,
      );
      await _flush();
      child.paintReady();
      await opening;
      await manager.requestParentClose();
      child.onFiles!();
      await _flush();
      expect(files, 1);
      expect(chrome.calls, ['hide', 'show']);
      expect(manager.isDetached(owner, 'a'), isTrue);
      await manager.closeAll();
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'visible SSH closure waits for transfer cancellation to drain',
    () async {
      final chrome = _Chrome(), owner = Object();
      final manager = ApplicationWindows(
        windowChrome: chrome,
        liveWindowsSupported: true,
      );
      final cancellation = SshTransferCancellation();
      final job = sshTransferActivity.begin(cancellation);
      final actions = <String>[];
      unawaited(
        cancellation.whenCancelled.then((_) {
          actions.add('cancel-transfer');
          sshTransferActivity.end(job);
        }),
      );
      manager.registerVisibleOwner(owner, () async {
        actions.add('close-visible');
      });
      await manager.requestParentClose();
      expect(actions, ['cancel-transfer', 'close-visible']);
      expect(chrome.calls, ['close']);
      expect(sshTransferActivity.activeCount, 0);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'a transfer still committing prevents parent teardown on drain timeout',
    () async {
      final chrome = _Chrome(), owner = Object();
      var visibleClosed = false;
      final manager = ApplicationWindows(
        windowChrome: chrome,
        liveWindowsSupported: true,
        transferDrainTimeout: const Duration(milliseconds: 10),
      );
      final cancellation = SshTransferCancellation()..beginCommit();
      final job = sshTransferActivity.begin(cancellation);
      manager.registerVisibleOwner(owner, () async {
        visibleClosed = true;
      });
      try {
        await manager.requestParentClose();
        expect(visibleClosed, isFalse);
        expect(chrome.calls, ['show']);
        expect(cancellation.isCancelled, isFalse);
      } finally {
        sshTransferActivity.end(job);
        manager.dispose();
        chrome.dispose();
      }
    },
  );
  test(
    'live detach refuses a runner without the native lifetime guard',
    () async {
      final chrome = _Chrome(enabled: false),
          child = _Child(),
          owner = Object();
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      expect(manager.supported, isFalse);
      expect(
        await manager.detach(
          owner: owner,
          sessionId: 'a',
          terminal: MirroredTerminal(),
          title: 'shell',
          onDetached: () => fail('source hidden without guard'),
          onUserClosed: () async {},
          onRestored: () {},
        ),
        isFalse,
      );
      expect(child.onReady, isNull);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'concurrent last children wait for both SSH close callbacks before engine exit',
    () async {
      final chrome = _Chrome(), owner = Object();
      final children = {'a': _Child(), 'b': _Child()};
      final gate = Completer<void>();
      final manager = ApplicationWindows(
        windowChrome: chrome,
        liveWindowsSupported: true,
        opener:
            ({
              required terminal,
              required title,
              onReady,
              onClosed,
              onOpenFiles,
            }) => children[title]!.open(
              terminal: terminal,
              title: title,
              onReady: onReady,
              onClosed: onClosed,
              onOpenFiles: onOpenFiles,
            ),
      );
      final openings = [
        for (final id in ['a', 'b'])
          manager.detach(
            owner: owner,
            sessionId: id,
            terminal: MirroredTerminal(),
            title: id,
            onDetached: () {},
            onRestored: () {},
            onUserClosed: () async {
              if (id == 'a') await gate.future;
            },
          ),
      ];
      await _flush();
      for (final child in children.values) {
        child.paintReady();
      }
      await Future.wait(openings);
      await manager.requestParentClose();
      await children['a']!.finish(LiveTerminalWindowCloseReason.user);
      await children['b']!.finish(LiveTerminalWindowCloseReason.user);
      await _flush();
      expect(chrome.calls, ['hide']);
      gate.complete();
      await _flush();
      await _flush();
      expect(chrome.calls, ['hide', 'close']);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'hidden-parent owner revoke cannot exit engine before the owned child process dies',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () {},
        onRestored: () {},
        onUserClosed: () async {},
      );
      await _flush();
      child.paintReady();
      await opening;
      await manager.requestParentClose();
      child.exitGate = Completer<void>();
      final closing = manager.closeOwner(owner);
      await _flush();
      await _flush();
      expect(chrome.calls, ['hide']);
      expect(child.processExited.isCompleted, isFalse);
      child.exitGate!.complete();
      await closing;
      await _flush();
      expect(child.processExited.isCompleted, isTrue);
      expect(chrome.calls, ['hide', 'close']);
      manager.dispose();
      chrome.dispose();
    },
  );
  test(
    'a disconnected read-only child remains owned and is terminated on later owner lock',
    () async {
      final chrome = _Chrome(), child = _Child(), owner = Object();
      var restored = 0;
      final manager = ApplicationWindows(
        windowChrome: chrome,
        opener: child.open,
        liveWindowsSupported: true,
      );
      final opening = manager.detach(
        owner: owner,
        sessionId: 'a',
        terminal: MirroredTerminal(),
        title: 'shell',
        onDetached: () {},
        onRestored: () => restored++,
        onUserClosed: () async {},
      );
      await _flush();
      child.paintReady();
      await opening;
      await child.finish(
        LiveTerminalWindowCloseReason.transportLost,
        processExit: false,
      );
      await _flush();
      expect(restored, 1);
      expect(child.ownerCloses, 0);
      expect(child.processExited.isCompleted, isFalse);
      await manager.closeOwner(owner);
      expect(child.ownerCloses, 1);
      expect(child.processExited.isCompleted, isTrue);
      manager.dispose();
      chrome.dispose();
    },
  );
}
