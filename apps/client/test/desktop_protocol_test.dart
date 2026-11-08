import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aterm_client/desktop/guacamole_protocol.dart';
import 'package:aterm_client/desktop/desktop_display.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:flutter/material.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native BGRA frames render correct colors and reject invalid buffers',
    () async {
      final display = DesktopDisplay();
      addTearDown(display.dispose);
      await display.frame(
        2,
        1,
        Uint8List.fromList([0, 0, 255, 255, 255, 0, 0, 255]),
      );
      final pixels = (await display
          .layer(0)
          .image!
          .toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(pixels.getUint32(0), 0xff0000ff);
      expect(pixels.getUint32(4), 0x0000ffff);
      await expectLater(
        display.frame(2, 1, Uint8List(4)),
        throwsFormatException,
      );
      await expectLater(
        display.frame(8192, 1, Uint8List(0)),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'desktop uses the full pane and puts controls in a rounded menu',
    (tester) async {
      final session = DesktopSession()..state = 'connected';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DesktopView(session: session)),
        ),
      );
      expect(find.text('connected'), findsNothing);
      session.onNotice?.call('Clipboard disabled by target');
      await tester.pump();
      expect(session.state, 'connected');
      expect(find.text('Clipboard disabled by target'), findsOneWidget);
      ScaffoldMessenger.of(tester.element(find.byType(DesktopView)))
          .clearSnackBars();
      await tester.pumpAndSettle();
      expect(find.byType(LayoutBuilder), findsOneWidget);
      expect(find.text('Send Ctrl+Alt+Delete'), findsNothing);
      await tester.tap(find.byTooltip('Remote desktop menu'));
      await tester.pumpAndSettle();
      expect(find.text('Send Ctrl+Alt+Delete'), findsOneWidget);
      expect(find.text('Paste local clipboard text'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
  testWidgets(
    'inactive desktop releases modifiers and cannot receive hidden input',
    (tester) async {
      final session = _RecordingDesktopSession()..state = 'connected';
      var inactive = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ExcludeFocus(
                  excluding: inactive,
                  child: DesktopView(session: session),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(session.sent, contains(equals(['key', 0xffe3, 1])));
      update(() => inactive = true);
      await tester.pump();
      expect(session.sent, contains(equals(['key', 0xffe3, 0])));
      final count = session.sent.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(session.sent.length, count);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
  testWidgets(
    'one click activates an excluded desktop pane before keyboard input',
    (tester) async {
      final session = _RecordingDesktopSession()..state = 'connected';
      var inactive = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Listener(
                onPointerDown: (_) => setState(() => inactive = false),
                child: ExcludeFocus(
                  excluding: inactive,
                  child: DesktopView(session: session),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tapAt(const Offset(200, 200));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(session.sent, contains(equals(['key', 'a'.codeUnitAt(0), 1])));
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
  );
  test('Unicode instructions survive every UTF-8 packet boundary', () async {
    final bytes = utf8.encode(
      guacamoleInstruction(['name', '中😀,;']) +
          guacamoleInstruction(['sync', 123]),
    );
    final decoded = await decodeGuacamole(
      Stream.fromIterable(bytes.map((b) => Uint8List.fromList([b]))),
    ).toList();
    expect(decoded, [
      ['name', '中😀,;'],
      ['sync', '123'],
    ]);
  });
  test('framing rejects oversized, malformed and truncated instructions', () {
    for (final bad in ['x.key;', '-1.x;', '10000000.x;', '1.x!']) {
      expect(() => GuacamoleParser().add(bad), throwsFormatException);
    }
    final parser = GuacamoleParser()..add('3.key,1.1,');
    expect(parser.finish, throwsFormatException);
  });
  test(
    'legacy SSH and desktop protocols round trip without dropping fields',
    () {
      final legacy = HostRecord.fromJson({
        'id': 'host',
        'address': 'server',
        'username': 'root',
      });
      expect(legacy.protocol, HostProtocol.ssh);
      expect(legacy.toJson().containsKey('protocol'), false);
      for (final protocol in [HostProtocol.rdp, HostProtocol.vnc]) {
        final host = HostRecord(
          id: 'host',
          name: 'Desktop',
          address: 'server',
          protocol: protocol,
          port: protocol.defaultPort,
        );
        expect(host.validate(), null);
        expect(
          HostRecord(id: 'h', name: 'h', address: 'h', protocol: protocol).port,
          protocol.defaultPort,
        );
        expect(
          HostRecord.fromJson(host.copyWith(name: 'Renamed').toJson()).protocol,
          protocol,
        );
        expect(host.copyWith(jumpHostId: 'ssh').validate(), isNotNull);
      }
      expect(
        () => HostRecord.fromJson({'id': 'h', 'protocol': 'other'}),
        throwsFormatException,
      );
    },
  );
  test(
    'renderer draws fills, overlapping copies, PNG streams and reset clipping',
    () async {
      final display = DesktopDisplay();
      addTearDown(display.dispose);
      final replies = <List<Object>>[];
      display.send = replies.add;
      Future<void> op(List<Object> values) =>
          display.instruction(values.map((e) => '$e').toList());
      await op(['size', 0, 4, 4]);
      await op(['rect', 0, 0, 0, 4, 4]);
      await op(['cfill', 12, 0, 255, 0, 0, 255]);
      await op(['copy', 0, 0, 0, 2, 2, 12, 0, 2, 2]);
      await op(['sync', 1]);
      var pixels = (await display
          .layer(0)
          .image!
          .toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(pixels.getUint32(0), 0xff0000ff);
      expect(pixels.getUint32(60), 0xff0000ff);
      await op(['rect', 0, 0, 0, 1, 1]);
      await op(['clip', 0]);
      await op(['rect', 0, 0, 0, 4, 4]);
      await op(['cfill', 12, 0, 0, 255, 0, 255]);
      await op(['reset', 0]);
      await op(['rect', 0, 3, 3, 1, 1]);
      await op(['cfill', 12, 0, 0, 0, 255, 255]);
      await op(['sync', 2]);
      pixels = (await display
          .layer(0)
          .image!
          .toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(pixels.getUint32(0), 0x00ff00ff);
      expect(pixels.getUint32(60), 0x0000ffff);
      final png = (await display
          .layer(0)
          .image!
          .toByteData(format: ui.ImageByteFormat.png))!;
      await op(['size', -1, 4, 4]);
      await op(['img', 1, 12, -1, 'image/png', 0, 0]);
      await op(['blob', 1, base64Encode(png.buffer.asUint8List())]);
      await op(['end', 1]);
      await op(['copy', -1, 0, 0, 4, 4, 12, 0, 0, 0]);
      await op(['sync', 3]);
      pixels = (await display
          .layer(0)
          .image!
          .toByteData(format: ui.ImageByteFormat.rawRgba))!;
      expect(pixels.getUint32(60), 0x0000ffff);
      expect(replies, contains(equals(['ack', 1, 'OK', 0])));
      expect(replies.last, ['sync', '3']);
    },
  );
  test(
    'RDP certificate pins round trip and reject invalid protocol/digests',
    () {
      final pin = List.filled(64, 'a').join();
      final host = HostRecord(
        id: 'h',
        name: 'rdp',
        address: 'server',
        protocol: HostProtocol.rdp,
        rdpCertificateSha256: pin,
      );
      expect(host.validate(), null);
      expect(
        HostRecord.fromJson(host.copyWith(name: 'renamed').toJson())
            .rdpCertificateSha256,
        pin,
      );
      expect(host.copyWith(protocol: HostProtocol.vnc).validate(), isNotNull);
      expect(host.copyWith(rdpCertificateSha256: 'bad').validate(), isNotNull);
      expect(
        host.copyWith(clearRdpCertificate: true).rdpCertificateSha256,
        null,
      );
    },
  );
  test(
    'offscreen bitmap caches grow before fills, copies and transfers',
    () async {
      final display = DesktopDisplay();
      addTearDown(display.dispose);
      Future<void> op(List<Object> v) =>
          display.instruction(v.map((e) => '$e').toList());
      await op(['rect', -1, 0, 0, 8, 6]);
      await op(['cfill', 12, -1, 255, 0, 0, 255]);
      await op(['copy', -1, 0, 0, 8, 6, 12, -2, 2, 2]);
      await op(['transfer', -2, 2, 2, 8, 6, 3, -3, 1, 1]);
      await op(['sync', 1]);
      expect(display.layer(-1).width, 8);
      expect(display.layer(-2).width, 10);
      expect(display.layer(-3).height, 7);
      final image = display.layer(-3).image!;
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      expect(pixels.getUint32((6 * image.width + 8) * 4), 0xff0000ff);
    },
  );
  test('renderer rejects huge surfaces and cyclic visible layers', () async {
    final display = DesktopDisplay();
    addTearDown(display.dispose);
    await expectLater(
      display.instruction(['size', '0', '99999', '99999']),
      throwsFormatException,
    );
    await display.instruction(['move', '1', '0', '0', '0', '0']);
    await display.instruction(['move', '2', '1', '0', '0', '0']);
    await expectLater(
      display.instruction(['move', '1', '2', '0', '0', '0']),
      throwsFormatException,
    );
  });
  test('opaque desktop layers draw directly and translucent groups keep their opacity', () async {
    final display = DesktopDisplay();
    addTearDown(display.dispose);
    Future<void> op(List<Object> v) =>
        display.instruction(v.map((e) => '$e').toList());
    await op(['size', 0, 4, 4]);
    await op(['rect', 0, 0, 0, 4, 4]);
    await op(['cfill', 12, 0, 0, 0, 255, 255]);
    await op(['size', 1, 2, 2]);
    await op(['rect', 1, 0, 0, 2, 2]);
    await op(['cfill', 12, 1, 255, 0, 0, 255]);
    await op(['move', 1, 0, 1, 1, 0]);
    await op(['size', 2, 1, 1]);
    await op(['rect', 2, 0, 0, 1, 1]);
    await op(['cfill', 12, 2, 0, 255, 0, 255]);
    await op(['move', 2, 1, 0, 0, 0]);
    await op(['sync', 1]);
    Future<ByteData> pixels() async {
      final recorder = ui.PictureRecorder();
      display.paint(ui.Canvas(recorder));
      final picture = recorder.endRecording();
      final image = await picture.toImage(4, 4);
      try {
        return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    var bytes = await pixels();
    expect(bytes.getUint32(20), 0x00ff00ff);
    expect(bytes.getUint32(40), 0xff0000ff);
    await op(['shade', 1, 128]);
    bytes = await pixels();
    expect(bytes.getUint8(20), 0);
    expect(bytes.getUint8(21), closeTo(128, 1));
    expect(bytes.getUint8(22), closeTo(127, 1));
    await op(['shade', 1, 0]);
    bytes = await pixels();
    expect(bytes.getUint32(20), 0x0000ffff);
  });
  test('keyboard maps modifiers, navigation and Unicode to X11 keysyms', () {
    expect(
      desktopKeysym(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.controlLeft,
          logicalKey: LogicalKeyboardKey.controlLeft,
          timeStamp: Duration.zero,
        ),
      ),
      0xffe3,
    );
    expect(
      desktopKeysym(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          character: 'A',
          timeStamp: Duration.zero,
        ),
      ),
      65,
    );
  });
}

class _RecordingDesktopSession extends DesktopSession {
  final sent = <List<Object>>[];
  @override
  void send(List<Object> values) => sent.add(values);
}
