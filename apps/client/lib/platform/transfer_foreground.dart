import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'transfer_foreground_platform_stub.dart'
    if (dart.library.io) 'transfer_foreground_platform_io.dart'
    as platform;

/// Keeps the Android SSH process active while a system file picker is in front.
/// No server, path, credential or file contents cross this channel.
class TransferForegroundGuard {
  const TransferForegroundGuard({
    this.channel = const MethodChannel('atermius/transfer_foreground'),
    this.enabled,
    this.requestTimeout = const Duration(seconds: 10),
    this.renewInterval = const Duration(seconds: 30),
  });

  final MethodChannel channel;
  final bool? enabled;
  final Duration requestTimeout;
  final Duration renewInterval;

  Future<T> run<T>(String operation, Future<T> Function() action) {
    // Preserve synchronous invocation/user activation on Web and other targets.
    if (!(enabled ?? platform.needsTransferForegroundService)) return action();
    if (operation != 'upload' && operation != 'download') {
      return Future<T>.error(ArgumentError.value(operation, 'operation'));
    }
    return _run(operation, action);
  }

  Future<T> _run<T>(String operation, Future<T> Function() action) async {
    final id = const Uuid().v4();
    final arguments = <String, Object>{'leaseId': id};
    Timer? heartbeat;
    var renewing = false;
    var finished = false;
    try {
      final ready = await channel
          .invokeMethod<bool>('acquire', {...arguments, 'operation': operation})
          .timeout(requestTimeout);
      if (ready != true) {
        throw StateError('The file transfer service could not start.');
      }
      heartbeat = Timer.periodic(renewInterval, (_) async {
        if (renewing || finished) return;
        renewing = true;
        try {
          final active = await channel
              .invokeMethod<bool>('renew', arguments)
              .timeout(requestTimeout);
          if (active != true) heartbeat?.cancel();
        } on Object {
          // The native lease expires without renewal. Do not restart a service
          // from the background or misreport a completed native save as failed.
          heartbeat?.cancel();
        } finally {
          renewing = false;
        }
      });
      return await action();
    } finally {
      finished = true;
      heartbeat?.cancel();
      try {
        // The caller-generated ID also releases an acquire whose ACK timed out.
        await channel
            .invokeMethod<void>('release', arguments)
            .timeout(requestTimeout);
      } on Object {
        // Native TTL/engine teardown is the fallback; preserve the picker result.
      }
    }
  }
}

const transferForeground = TransferForegroundGuard();
