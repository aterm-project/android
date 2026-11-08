import 'dart:async';
import 'dart:io';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:flutter_test/flutter_test.dart';

class _OwnedProcess implements Process {
  final exit = Completer<int>();
  int kills = 0;
  @override
  int get pid => 12345;
  @override
  Future<int> get exitCode => exit.future;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!exit.isCompleted) exit.complete(1);
    return true;
  }
}

void main() {
  test(
    'owner revoke stops authorization before killing exactly its owned child, idempotently',
    () async {
      final process = _OwnedProcess();
      final order = <String>[];
      final child = OwnedLiveTerminalChild(
        process: process,
        stopBroker: () async {
          order.add('revoke');
          expect(process.kills, 0);
        },
        onProcessExit: () async {
          order.add('exit');
        },
      );
      final first = child.closeOwner(), second = child.closeOwner();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      expect(process.kills, 1);
      expect(order, ['revoke', 'exit']);
      await child.closeOwner();
      expect(process.kills, 1);
    },
  );
  test(
    'spontaneous child exit only reports transport loss and never sends kill',
    () async {
      final process = _OwnedProcess();
      var exits = 0, revoke = 0;
      final child = OwnedLiveTerminalChild(
        process: process,
        stopBroker: () async {
          revoke++;
        },
        onProcessExit: () async {
          exits++;
        },
      );
      process.exit.complete(0);
      await child.exited;
      await Future<void>.delayed(Duration.zero);
      expect(process.kills, 0);
      expect(exits, 1);
      expect(revoke, 0);
      await child.closeOwner();
      expect(process.kills, 0);
      expect(revoke, 1);
    },
  );
}
