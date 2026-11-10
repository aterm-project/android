import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/direct/rfb.dart';
import 'package:aterm_client/desktop/direct/rdp_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('VNC DES authentication matches independent OpenSSL known answer', () {
    expect(
      vncChallengeResponse(
        'secret',
        Uint8List.fromList(List.generate(16, (i) => i)),
      ),
      _hex('ee22539f33a5983ec12f9c2edbc995dd'),
    );
  });

  test('direct VNC authenticates, paints and sends key/mouse/clipboard without gateway', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = server.first;
    final connection = RfbConnection.connect(
      '127.0.0.1',
      server.port,
      'secret',
    );
    final frames = StreamIterator(
      connection.events.where((e) => e is! DesktopReady),
    );
    final socket = await accepted;
    final client = _Reader(socket);
    addTearDown(() async {
      await connection.close();
      socket.destroy();
      await server.close();
    });
    socket.add('RFB 003.008\n'.codeUnits);
    expect(await client.read(12), 'RFB 003.008\n'.codeUnits);
    socket.add([1, 2]);
    expect(await client.read(1), [2]);
    socket.add([0, 1, 2]);
    await socket.flush();
    socket.add(List.generate(13, (i) => i + 3));
    expect(await client.read(16), _hex('ee22539f33a5983ec12f9c2edbc995dd'));
    socket.add([0, 0, 0, 0]);
    expect(await client.read(1), [1]);
    final init = ByteData(24)
      ..setUint16(0, 2)
      ..setUint16(2, 2);
    socket.add(init.buffer.asUint8List());
    final format = await client.read(20);
    expect(format.sublist(4, 8), [32, 24, 0, 1]);
    final encodings = ByteData.sublistView(
      Uint8List.fromList(await client.read(28)),
    );
    expect(encodings.getUint8(0), 2);
    expect(encodings.getUint16(2), 6);
    expect(encodings.getInt32(16), -308); // ExtendedDesktopSize advertised
    expect(encodings.getInt32(20), -239); // RichCursor
    expect(encodings.getInt32(24), -232); // PointerPos
    expect(await client.read(10), [3, 0, 0, 0, 0, 0, 0, 2, 0, 2]);
    final rect = ByteData(16)
      ..setUint16(2, 1)
      ..setUint16(8, 2)
      ..setUint16(10, 2);
    socket.add([...rect.buffer.asUint8List(), ...List.generate(16, (i) => i)]);
    expect(await frames.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final frame = frames.current as DesktopFrame;
    expect((frame.width, frame.height), (2, 2));
    expect(frame.bgra, [
      0,
      1,
      2,
      255,
      4,
      5,
      6,
      255,
      8,
      9,
      10,
      255,
      12,
      13,
      14,
      255,
    ]);
    frame.onConsumed?.call();
    expect((await client.read(10))[1], 1);
    List<int> cursorRect(int x, int y, int w, int h, int encoding) =>
        (ByteData(12)
              ..setUint16(0, x)
              ..setUint16(2, y)
              ..setUint16(4, w)
              ..setUint16(6, h)
              ..setInt32(8, encoding))
            .buffer
            .asUint8List();
    socket.add([
      0,
      0,
      0,
      3,
      ...cursorRect(1, 0, 2, 1, -239),
      0,
      0,
      255,
      0,
      255,
      0,
      0,
      0,
      0x80,
      ...cursorRect(1, 1, 0, 0, -232),
      ...cursorRect(0, 0, 0, 0, -239),
    ]);
    expect(await frames.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final cursor = frames.current as DesktopCursor;
    expect(
      (cursor.width, cursor.height, cursor.hotX, cursor.hotY),
      (2, 1, 1, 0),
    );
    expect(cursor.bgra, [0, 0, 255, 255, 255, 0, 0, 0]);
    expect(await frames.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    final position = frames.current as DesktopPointerPosition;
    expect((position.x, position.y), (1, 1));
    expect(await frames.moveNext().timeout(const Duration(seconds: 3)), isTrue);
    expect((frames.current as DesktopCursor).kind, DesktopCursorKind.hidden);
    // Cursor-only updates request the next frame without allocating a new one.
    expect((await client.read(10))[1], 1);
    connection.send(['key', 0xff51, 1]);
    expect(await client.read(8), [4, 1, 0, 0, 0, 0, 255, 81]);
    connection.send(['mouse', 1, 1, 4]);
    expect(await client.read(6), [5, 4, 0, 1, 0, 1]);
    connection.paste('abc');
    expect(await client.read(11), [6, 0, 0, 0, 0, 0, 0, 3, 97, 98, 99]);
    await connection.close();
    await frames.cancel();
  });

  test(
    'VNC rejects oversized server dimensions before reading frame data',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final connection = RfbConnection.connect('127.0.0.1', server.port, '');
      final failure = expectLater(
        connection.events,
        emitsError(isA<FormatException>()),
      );
      final socket = await accepted;
      final client = _Reader(socket);
      addTearDown(() async {
        await connection.close();
        socket.destroy();
        await server.close();
      });
      socket.add('RFB 003.008\n'.codeUnits);
      await client.read(12);
      socket.add([1, 1]);
      await client.read(1);
      socket.add([0, 0, 0, 0]);
      await client.read(1);
      final init = ByteData(24)
        ..setUint16(0, 8193)
        ..setUint16(2, 1);
      socket.add(init.buffer.asUint8List());
      await failure.timeout(const Duration(seconds: 3));
    },
  );

  test('RDP physical modifiers and navigation retain extended scancodes', () {
    expect(rdpScancode(0xffe3), 0x1d);
    expect(rdpScancode(0xffe4), 0x11d);
    expect(rdpScancode(0xff51), 0x14b);
    expect(rdpScancode(0xffff), 0x153);
    expect(rdpScancode('C'.codeUnitAt(0)), 0x2e);
    expect(rdpScancode(0x01004f60), isNull);
  });
}

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

class _Reader {
  _Reader(Stream<List<int>> stream) : iterator = StreamIterator(stream);
  final StreamIterator<List<int>> iterator;
  final bytes = <int>[];
  Future<List<int>> read(int n) async {
    while (bytes.length < n) {
      if (!await iterator.moveNext()) throw StateError('Client disconnected');
      bytes.addAll(iterator.current);
    }
    final result = bytes.sublist(0, n);
    bytes.removeRange(0, n);
    return result;
  }
}
