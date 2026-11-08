import 'dart:async';

import 'support/native_test_coordination_stub.dart'
    if (dart.library.io) 'support/native_test_coordination.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  configureNativeTestCoordination();
  await testMain();
}
