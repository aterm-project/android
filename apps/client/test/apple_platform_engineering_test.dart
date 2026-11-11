import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/console/serial_console_io.dart';
import 'package:aterm_client/desktop/direct/rdp_io.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/platform/application_windows.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/sftp/external_edit_policy.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Apple WindowChrome native-titlebar mode', () {
    testWidgets(
      'customFrame=false enables ApplicationWindows close guard without drawing Windows caption buttons',
      (tester) async {
        const channel = MethodChannel('atermius/test_macos_chrome');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'enable' || call.method == 'getState') {
                return {
                  'enabled': true,
                  'customFrame': false,
                  'maximized': false,
                  'minimized': false,
                  'focused': true,
                };
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );

        final chrome = WindowChromeController(channel: channel, supported: true);
        await chrome.start();
        expect(chrome.state.enabled, isTrue);
        expect(chrome.state.customFrame, isFalse);

        final appWindows = ApplicationWindows(
          windowChrome: chrome,
          liveWindowsSupported: true,
        );
        expect(appWindows.supported, isTrue);

        await tester.pumpWidget(
          MaterialApp(
            home: WindowsWindowChrome(
              controller: chrome,
              title: 'Atermius',
              child: const Scaffold(body: Text('Workspace')),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Workspace'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('windows_window_caption')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('window_caption_close')),
          findsNothing,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        chrome.dispose();
        appWindows.dispose();
      },
    );
  });

  group('macOS POSIX serial console & QuickConnect', () {
    test('parses /dev/cu.* and /dev/tty.* preserving case and rejects traversal', () {
      final cu = QuickConnectRequest.parse(
        'console /dev/cu.Bluetooth-Incoming-Port -b 115200',
      );
      expect(cu, isNotNull);
      expect(cu!.kind, QuickConnectKind.serial);
      expect(cu.address, '/dev/cu.Bluetooth-Incoming-Port');
      expect(cu.baudRate, 115200);

      final tty = QuickConnectRequest.parse(
        'tty /dev/tty.usbserial-1410 -b 921600',
      );
      expect(tty, isNotNull);
      expect(tty!.kind, QuickConnectKind.serial);
      expect(tty.address, '/dev/tty.usbserial-1410');
      expect(tty.baudRate, 921600);

      expect(
        () => QuickConnectRequest.parse('console /dev/cu..bad -b 115200'),
        throwsFormatException,
      );
      expect(
        () => QuickConnectRequest.parse('console /etc/passwd -b 115200'),
        throwsFormatException,
      );
    });

    test('validates POSIX serial device paths on macOS', () {
      if (!Platform.isMacOS) return;
      expect(
        () => openSerialConsole('/etc/hosts', baudRate: 115200),
        throwsFormatException,
      );
      expect(
        () => openSerialConsole('/dev/cu.test..escape', baudRate: 115200),
        throwsFormatException,
      );
    });
  });

  group('iOS external edit policy', () {
    test('classifies scripts as text edit and regular documents as open', () {
      expect(
        externalEditLaunchMode(
          'deploy.sh',
          Uint8List.fromList('#!/bin/sh\n'.codeUnits),
          ExternalEditPlatformKind.ios,
        ),
        ExternalEditLaunchMode.edit,
      );
      expect(
        externalEditLaunchMode(
          'report.pdf',
          Uint8List.fromList('%PDF-1.7'.codeUnits),
          ExternalEditPlatformKind.ios,
        ),
        ExternalEditLaunchMode.open,
      );
    });
  });

  group('Apple bundled FreeRDP 3.33.0 FFI verification', () {
    test('loads compiled libatermius_rdp.dylib when ATERMIUS_RDP_LIBRARY is set', () {
      final envPath = Platform.environment['ATERMIUS_RDP_LIBRARY'];
      if (envPath == null || !File(envPath).existsSync()) return;
      final features = rdpEngineFeatures();
      expect(features.bits, greaterThan(0));
      expect(features.has(RdpFeatures.configV1), isTrue);
      expect(features.has(RdpFeatures.drive), isTrue);
      expect(features.has(RdpFeatures.multimon), isTrue);
      expect(features.has(RdpFeatures.fileClipboard), isTrue);
      expect(features.has(RdpFeatures.nativeTouch), isTrue);
      expect(features.has(RdpFeatures.printer), isFalse);
    });
  });
}
