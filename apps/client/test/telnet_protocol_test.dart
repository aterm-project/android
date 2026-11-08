import 'dart:typed_data';

import 'package:aterm_client/telnet/telnet_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const iac = TelnetCommand.iac;
const sb = TelnetCommand.sb;
const se = TelnetCommand.se;
const will = TelnetCommand.will;
const wont = TelnetCommand.wont;
const doo = TelnetCommand.doOption;
const dont = TelnetCommand.dont;

/// Parses [bytes] split into [chunkSize]-byte chunks and returns a canonical
/// description (data merged) for comparison across split points.
List<String> parseInChunks(List<int> bytes, int chunkSize, {bool binary = false}) {
  final parser = TelnetParser();
  final nvt = TelnetNvtReceiveFilter()..binary = binary;
  final out = <String>[];
  final data = <int>[];
  void flush() {
    if (data.isNotEmpty) {
      out.add('data:${data.join(',')}');
      data.clear();
    }
  }

  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, bytes.length);
    for (final event in parser.parse(bytes.sublist(i, end))) {
      switch (event) {
        case TelnetDataEvent(:final bytes):
          data.addAll(nvt.filter(bytes));
        case TelnetCommandEvent(:final command):
          flush();
          out.add('cmd:$command');
        case TelnetNegotiationEvent(:final verb, :final option):
          flush();
          out.add('neg:$verb:$option');
        case TelnetSubnegotiationEvent(
          :final option,
          :final payload,
          :final overflowed,
        ):
          flush();
          out.add('sb:$option:${payload.join(',')}:$overflowed');
      }
    }
  }
  flush();
  return out;
}

void main() {
  group('TelnetParser', () {
    final stream = <int>[
      ...'ab'.codeUnits,
      iac, iac, // escaped 255 data byte
      iac, will, TelnetOption.echo,
      ...'c'.codeUnits,
      13, 0, // CR NUL -> CR
      13, 10, // CR LF stays
      iac, sb, TelnetOption.terminalType, 1, iac, se,
      iac, sb, 99, 1, iac, iac, 2, iac, se, // escaped IAC inside SB
      iac, TelnetCommand.nop,
      iac, doo, TelnetOption.naws,
      ...'z'.codeUnits,
    ];
    final expected = [
      'data:97,98,255',
      'neg:$will:${TelnetOption.echo}',
      'data:99,13,13,10',
      'sb:${TelnetOption.terminalType}:1:false',
      'sb:99:1,255,2:false',
      'cmd:${TelnetCommand.nop}',
      'neg:$doo:${TelnetOption.naws}',
      'data:122',
    ];

    test('is independent of chunk boundaries (every split size)', () {
      for (var size = 1; size <= stream.length; size++) {
        expect(parseInChunks(stream, size), expected, reason: 'chunk=$size');
      }
    });

    test('CR NUL is preserved verbatim in BINARY mode', () {
      expect(parseInChunks([13, 0, 65], 1, binary: true), ['data:13,0,65']);
      expect(parseInChunks([13, 0, 65], 1), ['data:13,65']);
    });

    test('oversized subnegotiation is discarded but stream stays in sync', () {
      final big = <int>[
        iac, sb, TelnetOption.terminalType,
        for (var i = 0; i < maxTelnetSubnegotiationBytes + 100; i++) 65,
        iac, iac, // still unescaped correctly while overflowing
        iac, se,
        ...'ok'.codeUnits,
      ];
      for (final size in [1, 7, 512, big.length]) {
        expect(parseInChunks(big, size), [
          'sb:${TelnetOption.terminalType}::true',
          'data:111,107',
        ]);
      }
    });

    test('IAC command inside SB aborts the subnegotiation and resyncs', () {
      final bytes = [iac, sb, 24, 1, iac, will, 1, ...'x'.codeUnits];
      expect(parseInChunks(bytes, 1), ['neg:$will:1', 'data:120']);
    });

    test('NVT filter drops CR NUL across chunks and resets on BINARY change',
        () {
      final nvt = TelnetNvtReceiveFilter();
      expect(nvt.filter(Uint8List.fromList([65, 13])), [65, 13]);
      expect(nvt.filter(Uint8List.fromList([0, 66])), [66]);
      nvt.filter(Uint8List.fromList([13]));
      nvt.binary = true; // reset: a following NUL is data in BINARY
      expect(nvt.filter(Uint8List.fromList([0])), [0]);
      nvt.binary = false;
      expect(nvt.filter(Uint8List.fromList([13, 0, 13, 10])), [13, 13, 10]);
    });

    test('a buffered partial sequence is reported', () {
      final parser = TelnetParser();
      parser.parse([iac]);
      expect(parser.midSequence, isTrue);
      parser.parse([TelnetCommand.nop]);
      expect(parser.midSequence, isFalse);
    });
  });

  group('TelnetOptionNegotiator (RFC 1143)', () {
    test('accepts supported remote options and refuses others', () {
      final n = TelnetOptionNegotiator();
      expect(n.receive(will, TelnetOption.echo), [iac, doo, TelnetOption.echo]);
      expect(n.remoteEnabled(TelnetOption.echo), isTrue);
      // Repeated WILL while enabled: no reply (loop avoidance).
      expect(n.receive(will, TelnetOption.echo), isNull);
      // Unsupported remote option.
      expect(n.receive(will, 42), [iac, dont, 42]);
      expect(n.remoteEnabled(42), isFalse);
      // Repeated refusal target sends WONT: no reply.
      expect(n.receive(wont, 42), isNull);
    });

    test('accepts DO for NAWS/TTYPE/BINARY/SGA and refuses DO ECHO', () {
      final n = TelnetOptionNegotiator();
      for (final option in [
        TelnetOption.naws,
        TelnetOption.terminalType,
        TelnetOption.binary,
        TelnetOption.suppressGoAhead,
      ]) {
        expect(n.receive(doo, option), [iac, will, option]);
        expect(n.localEnabled(option), isTrue);
        expect(n.receive(doo, option), isNull);
      }
      // We never echo on behalf of the server.
      expect(n.receive(doo, TelnetOption.echo), [iac, wont, TelnetOption.echo]);
      expect(n.localEnabled(TelnetOption.echo), isFalse);
    });

    test('DONT on an enabled option is acknowledged once', () {
      final changes = <String>[];
      final n = TelnetOptionNegotiator()
        ..onLocalChanged = (o, e) => changes.add('$o:$e');
      n.receive(doo, TelnetOption.naws);
      expect(n.receive(dont, TelnetOption.naws), [iac, wont, TelnetOption.naws]);
      expect(n.receive(dont, TelnetOption.naws), isNull);
      expect(changes, ['${TelnetOption.naws}:true', '${TelnetOption.naws}:false']);
    });

    test('our request is not re-sent when the peer agrees (no loop)', () {
      final n = TelnetOptionNegotiator();
      expect(
        n.requestLocal(TelnetOption.naws, true),
        [iac, will, TelnetOption.naws],
      );
      expect(n.localState(TelnetOption.naws), TelnetQState.wantYes);
      // Requesting again while pending sends nothing.
      expect(n.requestLocal(TelnetOption.naws, true), isNull);
      expect(n.receive(doo, TelnetOption.naws), isNull);
      expect(n.localEnabled(TelnetOption.naws), isTrue);
    });

    test('a refused request settles to NO without a reply', () {
      final n = TelnetOptionNegotiator();
      n.requestRemote(TelnetOption.suppressGoAhead, true);
      expect(n.receive(wont, TelnetOption.suppressGoAhead), isNull);
      expect(n.remoteState(TelnetOption.suppressGoAhead), TelnetQState.no);
    });

    test('queued opposite request is honored after the pending answer', () {
      final n = TelnetOptionNegotiator();
      n.requestRemote(TelnetOption.echo, true); // WANTYES
      expect(n.requestRemote(TelnetOption.echo, false), isNull); // queue
      // Peer agrees; we immediately ask to disable.
      expect(n.receive(will, TelnetOption.echo), [iac, dont, TelnetOption.echo]);
      expect(n.remoteState(TelnetOption.echo), TelnetQState.wantNo);
      expect(n.receive(wont, TelnetOption.echo), isNull);
      expect(n.remoteState(TelnetOption.echo), TelnetQState.no);
    });

    test('two RFC 1143 peers converge without looping', () {
      // Connect two negotiators back to back and let both request the same
      // options at once; the exchange must terminate.
      final a = TelnetOptionNegotiator(
        acceptLocal: {TelnetOption.suppressGoAhead},
        acceptRemote: {TelnetOption.suppressGoAhead},
      );
      final b = TelnetOptionNegotiator(
        acceptLocal: {TelnetOption.suppressGoAhead},
        acceptRemote: {TelnetOption.suppressGoAhead},
      );
      final toB = <Uint8List>[
        a.requestLocal(TelnetOption.suppressGoAhead, true)!,
        a.requestRemote(TelnetOption.suppressGoAhead, true)!,
      ];
      final toA = <Uint8List>[
        b.requestLocal(TelnetOption.suppressGoAhead, true)!,
        b.requestRemote(TelnetOption.suppressGoAhead, true)!,
      ];
      var steps = 0;
      while ((toA.isNotEmpty || toB.isNotEmpty) && steps++ < 100) {
        if (toB.isNotEmpty) {
          final m = toB.removeAt(0);
          final r = b.receive(m[1], m[2]);
          if (r != null) toA.add(r);
        }
        if (toA.isNotEmpty) {
          final m = toA.removeAt(0);
          final r = a.receive(m[1], m[2]);
          if (r != null) toB.add(r);
        }
      }
      expect(steps, lessThan(10));
      expect(a.localEnabled(TelnetOption.suppressGoAhead), isTrue);
      expect(b.remoteEnabled(TelnetOption.suppressGoAhead), isTrue);
    });
  });

  group('encoders', () {
    test('NAWS doubles 255 bytes and clamps', () {
      expect(encodeTelnetNaws(80, 24), [iac, sb, 31, 0, 80, 0, 24, iac, se]);
      expect(
        encodeTelnetNaws(255, 0x1ff),
        [iac, sb, 31, 0, 255, 255, 1, 255, 255, iac, se],
      );
      expect(encodeTelnetNaws(0, 70000), [iac, sb, 31, 0, 1, 255, 255, 255, 255, iac, se]);
    });

    test('TTYPE IS is printable ASCII only', () {
      expect(
        encodeTelnetTerminalType('XTERM\u0000ÿ'),
        [iac, sb, 24, 0, ...'XTERM'.codeUnits, iac, se],
      );
      expect(isTelnetTerminalTypeSend(Uint8List.fromList([1])), isTrue);
      expect(isTelnetTerminalTypeSend(Uint8List.fromList([0])), isFalse);
    });

    test('NVT input: line endings become CR LF, IAC doubled', () {
      final e = TelnetInputEncoder();
      expect(e.encode('ls\r'.codeUnits), [...'ls'.codeUnits, 13, 10]);
      expect(e.encode('\n'.codeUnits), isEmpty); // CR then LF across calls
      expect(e.encode('a\nb\r\nc'.codeUnits), [97, 13, 10, 98, 13, 10, 99]);
      expect(e.encode([255, 1]), [255, 255, 1]);
    });

    test('bounded encoding rejects oversized input without state change', () {
      final e = TelnetInputEncoder();
      expect(e.encodeBounded([1, 2, 3], 2), isNull);
      // 0xFF doubles: 2 input bytes become 4 encoded bytes.
      expect(e.encodeBounded([255, 255], 3), isNull);
      expect(e.encodeBounded('a\r'.codeUnits, 2), isNull); // CR -> CR LF
      expect(e.encodeBounded('\n'.codeUnits, 4), [13, 10]);
    });

    test('BINARY input is raw apart from IAC doubling', () {
      final e = TelnetInputEncoder()..binary = true;
      expect(e.encode([13, 0, 10, 255]), [13, 0, 10, 255, 255]);
    });
  });
}
