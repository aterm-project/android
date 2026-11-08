import 'dart:io';

import 'package:aterm_client/platform/native_coordination.dart';
import 'package:flutter_test/flutter_test.dart';

/// Use actual process locks without requiring a platform-channel plugin in
/// FlutterTester. Each suite gets an isolated, disposable support directory.
void configureNativeTestCoordination() {
  Directory? directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('atermius-test-locks-');
    coordinationDirectory = () async => directory!;
  });
  tearDownAll(() async {
    if (directory != null && await directory!.exists()) {
      await directory!.delete(recursive: true);
    }
  });
}
