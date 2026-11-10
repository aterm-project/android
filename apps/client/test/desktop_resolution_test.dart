import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/direct/rfb.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Reader {
  _Reader(Socket socket) {
    socket.listen(_buffer.addAll);
  }
  final _buffer = <int>[];
  Future<List<int>> read(int n) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (_buffer.length < n) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('read $n');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  int get pending => _buffer.length;
}

/// Minimal RFB 3.8 server with no authentication.
Future<(RfbConnection, Socket, _Reader, ServerSocket)> _vnc(int w, int h) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = server.first;
  final connection = RfbConnection.connect('127.0.0.1', server.port, '');
  final socket = await accepted;
  final reader = _Reader(socket);
  socket.add('RFB 003.008\n'.codeUnits);
  await reader.read(12);
  socket.add([1, 1]);
  await reader.read(1);
  socket.add([0, 0, 0, 0]);
  await reader.read(1); // shared flag
  socket.add((ByteData(24)
        ..setUint16(0, w)
        ..setUint16(2, h))
      .buffer
      .asUint8List());
  await reader.read(20); // pixel format
  final encodings = ByteData.sublistView(Uint8List.fromList(await reader.read(28)));
  expect(encodings.getInt32(16), -308);
  await reader.read(10); // first update request
  return (connection, socket, reader, server);
}

List<int> _extendedSize(int reason, int status, int w, int h, int screenId) => [
  ...(ByteData(4)
        ..setUint8(0, 0)
        ..setUint16(2, 1))
      .buffer
      .asUint8List(),
  ...(ByteData(12)
        ..setUint16(0, reason)
        ..setUint16(2, status)
        ..setUint16(4, w)
        ..setUint16(6, h)
        ..setInt32(8, -308))
      .buffer
      .asUint8List(),
  1, 0, 0, 0,
  ...(ByteData(16)
        ..setUint32(0, screenId)
        ..setUint16(8, w)
        ..setUint16(10, h))
      .buffer
      .asUint8List(),
];

void main() {
  group('resolution settings', () {
    test('presets are within bounds and labelled', () {
      for (final p in desktopResolutionPresets) {
        expect(validateDesktopSize(p.width, p.height), isNull, reason: p.size);
        expect(p.label, isNotEmpty);
      }
      expect(validateDesktopSize(199, 800), isNotNull);
      expect(validateDesktopSize(8193, 800), isNotNull);
      expect(validateDesktopSize(8192, 8192), isNotNull); // pixel cap
      expect(validateDesktopSize(8192, 4096), isNull);
    });

    test('VNC settings round-trip per Host and reject invalid sizes', () {
      const settings = VncSettings(
        resolution: VncResolutionMode.fixed,
        width: 2560,
        height: 1440,
        scaling: DesktopLocalScaling.actualSize,
      );
      const host = HostRecord(id: 'v', name: 'V', address: 'v', protocol: HostProtocol.vnc);
      final saved = HostRecord.fromJson(
        host.copyWith(manifest: settings.applyTo(null)).toJson(),
      );
      expect(VncSettings.of(saved), settings);
      expect(VncSettings.defaults.applyTo(null), isNull);
      expect(
        () => VncSettings.fromJson({'version': 1, 'resolution': 'fixed', 'width': 10, 'height': 10}),
        throwsFormatException,
      );
      expect(() => VncSettings.fromJson({'version': 1, 'resolution': 'huge'}), throwsFormatException);
    });

    test('RDP fixed size reaches the native config; auto follows the window', () {
      const fixed = RdpSettings(resolution: RdpResolutionMode.fixed, width: 1600, height: 900);
      final config = fixed.toNativeConfig(
        features: const RdpFeatures(RdpFeatures.configV1),
        initialWidth: 1000,
        initialHeight: 700,
      );
      expect(config.text, contains('\nwidth=1600\nheight=900\ndynamic_resolution=0\n'));
      final auto = RdpSettings.defaults.toNativeConfig(
        features: const RdpFeatures(RdpFeatures.configV1),
        initialWidth: 1000,
        initialHeight: 700,
      );
      expect(auto.text, contains('\nwidth=1000\nheight=700\ndynamic_resolution=1\n'));
      expect(
        () => const RdpSettings(resolution: RdpResolutionMode.fixed, width: 8192, height: 8192)
            .toNativeConfig(features: RdpFeatures.none, initialWidth: 1, initialHeight: 1),
        throwsFormatException,
      );
    });
  });

  group('RFB SetDesktopSize', () {
    test('encodes one screen keeping the server screen id', () {
      final bytes = rfbSetDesktopSize(
        1920,
        1080,
        const [RfbScreen(id: 42, x: 0, y: 0, width: 800, height: 600, flags: 3)],
        supported: true,
      )!;
      final d = ByteData.sublistView(bytes);
      expect(bytes.length, 24);
      expect(d.getUint8(0), 251);
      expect((d.getUint16(2), d.getUint16(4), d.getUint8(6)), (1920, 1080, 1));
      expect(d.getUint32(8), 42);
      expect((d.getUint16(16), d.getUint16(18), d.getUint32(20)), (1920, 1080, 3));
      expect(rfbSetDesktopSize(1920, 1080, const [], supported: false), isNull);
      expect(rfbSetDesktopSize(9000, 1080, const [], supported: true), isNull);
      expect(rfbSetDesktopSize(8192, 8192, const [], supported: true), isNull);
    });

    test('negotiated server: request, response and resized framebuffer', () async {
      final (connection, socket, reader, server) = await _vnc(2, 2);
      addTearDown(() async {
        await connection.close();
        socket.destroy();
        await server.close();
      });
      final events = StreamIterator(
        connection.events.where((e) => e is! DesktopReady),
      );
      // Server advertises ExtendedDesktopSize in its first update.
      socket.add(_extendedSize(0, 0, 2, 2, 7));
      expect(await events.moveNext(), isTrue);
      expect(events.current, isA<DesktopResizeStatus>());
      expect((events.current as DesktopResizeStatus).serverResize, isTrue);
      expect(await events.moveNext(), isTrue); // the (empty) frame
      (events.current as DesktopFrame).onConsumed?.call();
      await reader.read(10); // next update request
      connection.send(['size', 640, 480, true]);
      final request = ByteData.sublistView(Uint8List.fromList(await reader.read(24)));
      expect(request.getUint8(0), 251);
      expect((request.getUint16(2), request.getUint16(4)), (640, 480));
      expect(request.getUint32(8), 7);
      socket.add(_extendedSize(1, 0, 640, 480, 7));
      expect(await events.moveNext(), isTrue);
      final status = events.current as DesktopResizeStatus;
      expect(status.result, DesktopResizeResult.applied);
      expect(await events.moveNext(), isTrue);
      final frame = events.current as DesktopFrame;
      expect((frame.width, frame.height), (640, 480));
      frame.onConsumed?.call();
      // Rejected request reports the server status and keeps the size.
      await reader.read(10);
      connection.send(['size', 4000, 3000, true]);
      await reader.read(24);
      socket.add(_extendedSize(1, 2, 640, 480, 7));
      expect(await events.moveNext(), isTrue);
      expect((events.current as DesktopResizeStatus).result, DesktopResizeResult.outOfResources);
      await events.cancel();
    });

    test('server without the extension never receives SetDesktopSize', () async {
      final (connection, socket, reader, server) = await _vnc(2, 2);
      addTearDown(() async {
        await connection.close();
        socket.destroy();
        await server.close();
      });
      final events = StreamIterator(
        connection.events.where((e) => e is! DesktopReady),
      );
      connection.send(['size', 1280, 720, true]);
      expect(await events.moveNext(), isTrue);
      final status = events.current as DesktopResizeStatus;
      expect(status.serverResize, isFalse);
      expect(status.result, DesktopResizeResult.unsupported);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(reader.pending, 0);
      await events.cancel();
    });
  });

  testWidgets('Ctrl+Alt+Home opens the session menu locally', (tester) async {
    final fake = _FakeConnection();
    final session = DesktopSession(directConnectionForTesting: (_) => fake);
    await tester.runAsync(() => session.connectLocal(
          const HostRecord(id: 'r', name: 'R', address: 'r', protocol: HostProtocol.rdp),
        ));
    session.state = 'connected';
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DesktopView(session: session))));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(find.text('Send Ctrl+Alt+Delete'), findsOneWidget);
    // Home never reached the remote; held modifiers were released.
    expect(fake.sent.where((c) => c[0] == 'key' && c[1] == 0xff50), isEmpty);
    expect(fake.sent.where((c) => c[0] == 'key' && c[1] == 0xffe3 && c[2] == 0), isNotEmpty);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.home);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.close);
  });

  group('session policy', () {
    test('VNC fixed size is requested only after the server negotiates it', () async {
      final fake = _FakeConnection();
      final session = DesktopSession(directConnectionForTesting: (_) => fake);
      final host = HostRecord(
        id: 'v',
        name: 'V',
        address: 'v',
        protocol: HostProtocol.vnc,
        manifest: const VncSettings(
          resolution: VncResolutionMode.fixed,
          width: 1600,
          height: 900,
        ).applyTo(null),
      );
      await session.connectLocal(host);
      expect(session.followsWindowSize, isFalse);
      fake.controller.add(DesktopResizeStatus(serverResize: true));
      await Future<void>.delayed(Duration.zero);
      expect(fake.sent.single, ['size', 1600, 900, true]);
      // A later switch to automatic follows the window only when negotiated.
      await session.changeResolution();
      expect(session.followsWindowSize, isTrue);
      await session.close();
    });

    test('a same-Host reconnect keeps the display choice but takes latest redirections', () async {
      final fakes = <_FakeConnection>[];
      final session = DesktopSession(
        directConnectionForTesting: (_) => (fakes..add(_FakeConnection())).last,
      );
      final first = HostRecord(
        id: 'r',
        name: 'R',
        address: 'r',
        protocol: HostProtocol.rdp,
        manifest: const RdpSettings(cameras: true, clipboardFiles: true).applyTo(null),
      );
      await session.connectLocal(first);
      fakes.last.controller.add(DesktopResizeStatus(serverResize: true));
      await Future<void>.delayed(Duration.zero);
      await session.changeResolution(width: 1600, height: 900);
      // The Host was edited meanwhile (cameras/files off); reconnect with it.
      final edited = first.copyWith(manifest: const RdpSettings().applyTo(null), clearManifest: true);
      await session.connectLocal(edited);
      expect(session.rdpSettings.cameras, isFalse);
      expect(session.rdpSettings.clipboardFiles, isFalse);
      expect((session.rdpSettings.width, session.rdpSettings.height), (1600, 900));
      await session.close();
    });

    test('in-session change is persisted through the Host callback', () async {
      final fake = _FakeConnection();
      HostRecord? persisted;
      final session = DesktopSession(
        directConnectionForTesting: (_) => fake,
        saveDisplaySettings: (h) async => persisted = h,
      );
      const host = HostRecord(id: 'r', name: 'R', address: 'r', protocol: HostProtocol.rdp);
      await session.connectLocal(host);
      fake.controller.add(DesktopResizeStatus(serverResize: true));
      await Future<void>.delayed(Duration.zero);
      await session.changeResolution(width: 1920, height: 1080);
      expect(fake.sent.last, ['size', 1920, 1080, true]);
      final saved = RdpSettings.of(persisted!);
      expect((saved.resolution, saved.width, saved.height), (RdpResolutionMode.fixed, 1920, 1080));
      expect(session.followsWindowSize, isFalse);
      await expectLater(session.changeResolution(width: 100, height: 100), throwsFormatException);
      await session.close();
    });
  });
}

class _FakeConnection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  final sent = <List<Object>>[];
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) => sent.add(command);
  @override
  void paste(String text) {}
  @override
  Future<void> close() async => controller.close();
}
