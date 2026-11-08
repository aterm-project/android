import 'dart:async';

import '../platform/native_coordination.dart';

Future<void> _tail = Zone.root.run(() => Future<void>.value());

/// Serialize isolates locally, then use the app support folder's permanent OS
/// lock file to exclude independent native windows/processes.
Future<T> withLocalProfileBootstrapLock<T>(Future<T> Function() action) async {
  final previous = _tail;
  final released = Zone.root.run(() => Completer<void>());
  _tail = released.future;
  await previous;
  try {
    final lock = await nativeProcessLock();
    return await lock.run('local-profile-device-bootstrap-v1', action);
  } finally {
    released.complete();
  }
}
