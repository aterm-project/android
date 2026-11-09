import 'dart:io';

import 'package:aterm_client/platform/file_drop_region.dart';
import 'package:aterm_client/ssh/file_workspace_controller.dart'
    show fileManagerMaxDroppedFiles;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// This file runs in its own isolate and never constructs a FileDropRegion:
// it covers drops that arrive on the home/login screen before any file tab.

Future<void> _send(String method, Object? arguments) =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, arguments),
          ),
          (_) {},
        );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup hook bounds web drops and releases unclaimed drops', () async {
    // Fresh isolate: upstream defaults until the app hook runs.
    expect(DesktopDropWebLimits.maxItems, isNull);
    expect(DesktopDropWebLimits.expandDirectories, isTrue);

    initializeFileDrop();
    initializeFileDrop(); // idempotent: no second listener

    expect(DesktopDropWebLimits.maxItems, fileManagerMaxDroppedFiles);
    expect(DesktopDropWebLimits.expandDirectories, isFalse);

    final released = <String>[];
    debugDroppedFileRelease = released.add;
    try {
      await _send('performOperation', ['/drop/a', '/drop/b']);
      await pumpEventQueue();
      expect(released, ['/drop/a', '/drop/b'], reason: 'released exactly once');

      released.clear();
      await _send('performOperation_web_bounded', {
        'items': [
          {
            'uri': 'blob:http://localhost/1',
            'children': <Object>[],
            'data': null,
            'name': 'a.txt',
            'type': 'text/plain',
            'size': 1,
            'relativePath': '/a.txt',
            'lastModified': 0,
          },
        ],
        'skipped': 0,
      });
      await pumpEventQueue();
      expect(released, ['blob:http://localhost/1']);
    } finally {
      debugDroppedFileRelease = null;
    }
  });

  test('main() runs the hook right after binding initialization', () {
    final source = File('lib/main.dart').readAsStringSync();
    final body = source.substring(
      source.indexOf('Future<void> main(List<String> arguments) async {'),
    );
    final binding = body.indexOf('WidgetsFlutterBinding.ensureInitialized();');
    final hook = body.indexOf('initializeFileDrop();');
    expect(binding, greaterThan(0));
    expect(hook, greaterThan(binding));
    // Before any launch detection, root selection or await.
    for (final later in ['detectLiveTerminalWindow', 'runApp(', 'await ']) {
      expect(hook, lessThan(body.indexOf(later)), reason: later);
    }
  });
}
