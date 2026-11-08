import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'scp_transfer_types.dart';

abstract interface class ScpChannel {
  Stream<Uint8List> get stdout;
  Future<void> send(Uint8List bytes);
  Future<void> finishInput();
  Future<void> get done;
  int? get exitCode;
  void close();
}

class ScpProtocolException implements Exception {
  const ScpProtocolException(this.message);
  final String message;
  @override
  String toString() => 'SCP: $message';
}

/// Single-file legacy SCP. Remote names are never used as local destinations.
/// Headers, error frames, chunk size, declared length and file count are bounded.
class ScpProtocol {
  ScpProtocol(
    this.channel,
    this.cancellation, {
    this.maximumBytes = sshTransferMaximumBytes,
  }) : _reader = _ScpReader(channel.stdout, cancellation);
  final ScpChannel channel;
  final SshTransferCancellation cancellation;
  final int maximumBytes;
  final _ScpReader _reader;
  static final _ack = Uint8List(1);

  Future<void> upload({
    required Stream<Uint8List> source,
    required int size,
    void Function(SshTransferProgress)? onProgress,
  }) async {
    if (size < 0 || size > maximumBytes) {
      throw const ScpProtocolException('File exceeds transfer size limit.');
    }
    try {
      await _readAck();
      await _send(Uint8List.fromList(ascii.encode('C0600 $size payload\n')));
      await _readAck();
      var sent = 0;
      onProgress?.call(
        SshTransferProgress(0, size, SshTransferPhase.transferring),
      );
      final iterator = StreamIterator<Uint8List>(source);
      try {
        while (await cancellation.wait(iterator.moveNext())) {
          final chunk = iterator.current;
          if (sent + chunk.length > size) {
            throw const ScpProtocolException('Local file changed length.');
          }
          for (
            var offset = 0;
            offset < chunk.length;
            offset += sshTransferChunkBytes
          ) {
            final part = Uint8List.sublistView(
              chunk,
              offset,
              min(offset + sshTransferChunkBytes, chunk.length),
            );
            await _send(part);
            sent += part.length;
            onProgress?.call(
              SshTransferProgress(sent, size, SshTransferPhase.transferring),
            );
          }
        }
      } finally {
        await iterator.cancel();
      }
      if (sent != size) {
        throw const ScpProtocolException('Local file changed length.');
      }
      await _send(_ack);
      await _readAck();
      cancellation.beginCommit();
      onProgress?.call(
        SshTransferProgress(sent, size, SshTransferPhase.committing),
      );
      await channel.finishInput().timeout(const Duration(seconds: 30));
      await _reader.expectEof();
      await channel.done.timeout(const Duration(seconds: 30));
      if (channel.exitCode != 0) {
        throw const ScpProtocolException(
          'Remote publication failed; destination may already exist.',
        );
      }
      onProgress?.call(
        SshTransferProgress(sent, size, SshTransferPhase.complete),
      );
    } finally {
      channel.close();
      await _reader.close();
    }
  }

  Future<int> download({
    required Future<void> Function(Uint8List) onChunk,
    void Function(SshTransferProgress)? onProgress,
  }) async {
    try {
      await _send(_ack);
      var header = await _reader.line();
      if (header.startsWith('T')) {
        if (!RegExp(
          r'^T[0-9]{1,16} [0-9]{1,6} [0-9]{1,16} [0-9]{1,6}$',
        ).hasMatch(header)) {
          throw const ScpProtocolException('Invalid timestamp frame.');
        }
        await _send(_ack);
        header = await _reader.line();
      }
      final match = RegExp(
        r'^C[0-7]{4} ([0-9]{1,16}) (.+)$',
      ).firstMatch(header);
      if (match == null) {
        throw const ScpProtocolException('Expected a single regular file.');
      }
      final name = match[2]!;
      if (name == '.' ||
          name == '..' ||
          name.contains('/') ||
          name.contains('\\') ||
          name.runes.any((c) => c < 32 || (c >= 127 && c <= 159))) {
        throw const ScpProtocolException('Unsafe server filename.');
      }
      final size = int.tryParse(match[1]!);
      if (size == null || size < 0 || size > maximumBytes) {
        throw const ScpProtocolException(
          'Remote file exceeds transfer size limit.',
        );
      }
      await _send(_ack);
      var received = 0;
      onProgress?.call(
        SshTransferProgress(0, size, SshTransferPhase.transferring),
      );
      while (received < size) {
        final part = await _reader.readSome(
          min(sshTransferChunkBytes, size - received),
        );
        if (part == null) throw const ScpProtocolException('Truncated file.');
        await cancellation.wait(onChunk(part));
        received += part.length;
        onProgress?.call(
          SshTransferProgress(received, size, SshTransferPhase.transferring),
        );
      }
      await _readAck();
      await _send(_ack);
      await channel.finishInput().timeout(const Duration(seconds: 30));
      await _reader.expectEof();
      await cancellation.wait(channel.done);
      if (channel.exitCode != 0) {
        throw const ScpProtocolException('Remote SCP failed.');
      }
      return received;
    } finally {
      channel.close();
      await _reader.close();
    }
  }

  Future<void> _send(Uint8List bytes) => cancellation.wait(channel.send(bytes));
  Future<void> _readAck() async {
    final code = await _reader.byte();
    if (code == 0) return;
    if (code == 1 || code == 2) {
      await _reader.line();
      throw const ScpProtocolException('Remote SCP rejected the transfer.');
    }
    throw const ScpProtocolException('Invalid acknowledgement.');
  }
}

class _ScpReader {
  _ScpReader(Stream<Uint8List> source, this.cancel)
    : iterator = StreamIterator(source);
  final StreamIterator<Uint8List> iterator;
  final SshTransferCancellation cancel;
  Uint8List _chunk = Uint8List(0);
  int _offset = 0;
  Future<Uint8List?> readSome(int maximum) async {
    cancel.check();
    while (_offset == _chunk.length) {
      if (!await cancel.wait(iterator.moveNext())) return null;
      _chunk = iterator.current;
      _offset = 0;
      if (_chunk.length > 1024 * 1024) {
        throw const ScpProtocolException('Oversized transport frame.');
      }
    }
    final end = min(_offset + maximum, _chunk.length);
    final result = Uint8List.sublistView(_chunk, _offset, end);
    _offset = end;
    return result;
  }

  Future<int> byte() async {
    final bytes = await readSome(1);
    if (bytes == null) {
      throw const ScpProtocolException('Unexpected end of stream.');
    }
    return bytes[0];
  }

  Future<String> line() async {
    final data = BytesBuilder(copy: false);
    for (var count = 0; count < 4096; count++) {
      final b = await byte();
      if (b == 10) {
        try {
          return utf8.decode(data.takeBytes());
        } on FormatException {
          throw const ScpProtocolException('Invalid header encoding.');
        }
      }
      data.addByte(b);
    }
    throw const ScpProtocolException('Header exceeds size limit.');
  }

  Future<void> expectEof() async {
    if (await readSome(1) != null) {
      throw const ScpProtocolException(
        'Unexpected extra file or trailing data.',
      );
    }
  }

  Future<void> close() => iterator.cancel();
}
