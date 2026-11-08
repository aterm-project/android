import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../apps/client/lib/desktop/direct/rdp.dart';
import '../../apps/client/lib/desktop/direct/connection.dart';

Future<void> main(List<String> args) async {
  final config = jsonDecode(
    await File(args.single).readAsString(),
  ) as Map<String, dynamic>;
  Future<String> rejected(String pin) async {
    final c = RdpConnection.connect(
      config['host'],
      config['port'],
      'test',
      '',
      pin,
    );
    final done = Completer<String>();
    final sub = c.events.listen(
      (event) {
        if (event is DesktopFrame && !done.isCompleted)
          done.completeError(StateError('Frame before certificate approval'));
      },
      onError: (Object e) {
        if (!done.isCompleted) {
          if (e is RdpCertificateException) {
            done.complete(e.sha256);
          } else {
            done.completeError(e);
          }
        }
      },
      onDone: () {
        if (!done.isCompleted)
          done.completeError(StateError('No certificate challenge'));
      },
    );
    try {
      return await done.future.timeout(const Duration(seconds: 20));
    } finally {
      await c.close();
      await sub.cancel();
    }
  }

  final observed = await rejected('');
  if (observed != config['expected_sha256'])
    throw StateError('Incorrect peer fingerprint');
  final changed = await rejected('0' * 64);
  if (changed != observed)
    throw StateError('Changed certificate fingerprint missing');
  final c = RdpConnection.connect(
    config['host'],
    config['port'],
    'test',
    '',
    observed,
  );
  final done = Completer<void>();
  final sub = c.events.listen(
    (event) {
      if (event is DesktopFrame) {
        event.onConsumed?.call();
        if (!done.isCompleted) done.complete();
      }
    },
    onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    },
  );
  try {
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    await c.close();
    await sub.cancel();
  }
  stdout.writeln(
    jsonEncode({
      'unknown_certificate_challenge': true,
      'wrong_pin_challenge': true,
      'fingerprint_matches_server_der': true,
      'approved_pin_connects': true,
    }),
  );
}
