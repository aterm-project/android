import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/ssh/scp_protocol.dart';
import 'package:aterm_client/ssh/scp_transfer_types.dart';
import 'package:aterm_client/ssh/scp_transfer_activity.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

class Channel implements ScpChannel {
  Channel(List<Uint8List> packets) : stdout = Stream.fromIterable(packets);
  @override
  final Stream<Uint8List> stdout;
  final sent = <Uint8List>[];
  bool closed = false;
  @override
  int? exitCode = 0;
  @override
  Future<void> get done => Future.value();
  @override
  Future<void> finishInput() async {}
  @override
  Future<void> send(Uint8List b) async {
    sent.add(Uint8List.fromList(b));
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test(
    'path quoting preserves spaces apostrophes Unicode and rejects controls',
    () {
      expect(
        scpDownloadCommand("/tmp/it's 中文 -file"),
        "scp -f -- '/tmp/it'\"'\"'s 中文 -file'",
      );
      expect(scpDownloadCommand('-file'), "scp -f -- './-file'");
      for (final path in [
        '',
        '/tmp/',
        '/tmp/..',
        'a\nb',
        'a\x00b',
        'a\x1bb',
        'a\u0085b',
      ]) {
        expect(() => scpDownloadCommand(path), throwsFormatException);
      }
      final command = scpUploadCommand(
        remotePath: '/tmp/x;touch nope',
        stageDirectory: '/tmp/.random',
      );
      expect(command, contains("t='/tmp/x;touch nope'"));
      expect(command, contains('&& ln --'));
      expect(command.indexOf('mkdir --'), lessThan(command.indexOf('trap ')));
    },
  );
  test(
    'upload streams exact length with monotonic progress and fixed filename',
    () async {
      final channel = Channel([
        Uint8List.fromList([0, 0, 0]),
      ]);
      final progress = <SshTransferProgress>[];
      await ScpProtocol(channel, SshTransferCancellation()).upload(
        source: Stream.fromIterable([bytes('a'), bytes('中文')]),
        size: 7,
        onProgress: progress.add,
      );
      expect(utf8.decode(channel.sent.first), 'C0600 7 payload\n');
      expect(channel.sent.sublist(1).expand((e) => e), [
        ...utf8.encode('a中文'),
        0,
      ]);
      expect(progress.map((p) => p.transferred), [0, 1, 7, 7, 7]);
      expect(progress.last.phase, SshTransferPhase.complete);
      expect(channel.closed, true);
    },
  );
  test(
    'download fragmented header/data, ignored safe remote basename',
    () async {
      final channel = Channel([
        bytes('C0600 7 different'),
        bytes(' 中文.txt\na'),
        bytes('中文'),
        Uint8List(1),
      ]);
      final received = BytesBuilder();
      final n = await ScpProtocol(
        channel,
        SshTransferCancellation(),
      ).download(onChunk: (p) async => received.add(p));
      expect(n, 7);
      expect(utf8.decode(received.takeBytes()), 'a中文');
      expect(channel.sent.expand((e) => e), [0, 0, 0]);
    },
  );
  test('empty file has a complete protocol and zero-byte result', () async {
    final channel = Channel([bytes('C0600 0 zero\n'), Uint8List(1)]);
    expect(
      await ScpProtocol(
        channel,
        SshTransferCancellation(),
      ).download(onChunk: (_) async => fail('no body')),
      0,
    );
  });
  test(
    'rejects traversal, directories, overflows and oversized headers',
    () async {
      for (final header in [
        'C0600 1 ../bad\n',
        'C0600 1 a/b\n',
        'C0600 1 a\\b\n',
        'D0755 0 folder\n',
        'C0600 1073741825 huge\n',
        'C0600 99999999999999999 huge\n',
        'C0600 1 ${'x' * 4096}\n',
      ]) {
        final channel = Channel([bytes(header)]);
        await expectLater(
          ScpProtocol(
            channel,
            SshTransferCancellation(),
          ).download(onChunk: (_) async {}),
          throwsA(isA<ScpProtocolException>()),
        );
        expect(channel.closed, true);
      }
    },
  );
  test(
    'rejects short body, bad terminator, extra files and remote error',
    () async {
      for (final data in [
        bytes('C0600 3 x\na'),
        bytes('C0600 1 x\naX'),
        Uint8List.fromList([
          ...utf8.encode('C0600 1 x\na'),
          0,
          ...utf8.encode('C0600 0 second\n'),
        ]),
        Uint8List.fromList([1, ...utf8.encode('private server diagnostic\n')]),
      ]) {
        final channel = Channel([data]);
        await expectLater(
          ScpProtocol(
            channel,
            SshTransferCancellation(),
          ).download(onChunk: (_) async {}),
          throwsA(isA<ScpProtocolException>()),
        );
        expect(channel.closed, true);
      }
    },
  );
  test('upload refuses both short and overlong local source', () async {
    for (final size in [0, 2]) {
      final channel = Channel([
        Uint8List.fromList([0, 0]),
      ]);
      await expectLater(
        ScpProtocol(
          channel,
          SshTransferCancellation(),
        ).upload(source: Stream.value(bytes('x')), size: size),
        throwsA(isA<ScpProtocolException>()),
      );
      expect(channel.closed, true);
    }
  });
  test(
    'cancellation closes a stalled channel and does not consume more source',
    () async {
      final stream = StreamController<Uint8List>.broadcast();
      final channel = _StalledChannel(stream.stream);
      final cancel = SshTransferCancellation();
      final result = ScpProtocol(
        channel,
        cancel,
      ).download(onChunk: (_) async {});
      final check = expectLater(result, throwsA(isA<SshTransferCancelled>()));
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await check;
      expect(channel.closed, true);
      await stream.close();
    },
  );
  test(
    'activity reports real byte aggregation and honours commit boundary',
    () {
      final activity = SshTransferActivity();
      final a = SshTransferCancellation();
      final b = SshTransferCancellation();
      final first = activity.begin(a);
      final second = activity.begin(b);
      activity.update(
        first,
        const SshTransferProgress(10, 20, SshTransferPhase.transferring),
      );
      activity.update(
        second,
        const SshTransferProgress(20, 80, SshTransferPhase.transferring),
      );
      expect(activity.progressFraction, .3);
      b.beginCommit();
      activity.cancelAll();
      expect(a.isCancelled, true);
      expect(b.isCancelled, false);
      activity.end(first);
      activity.end(second);
      expect(activity.activeCount, 0);
      activity.dispose();
    },
  );
}

class _StalledChannel extends Channel {
  _StalledChannel(this.stream) : super([]);
  final Stream<Uint8List> stream;
  @override
  Stream<Uint8List> get stdout => stream;
}
