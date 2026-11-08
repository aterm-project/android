import 'dart:typed_data';
import '../attachments/attachment_file_saver_model.dart';
import 'scp_transfer_types.dart';

const mobileSshTransferMaximumBytes = 16 * 1024 * 1024;

/// A bounded adapter for mobile's existing native save picker. The picker is
/// invoked only after the protocol has validated the entire file. Buffers are
/// cleared on success, failure and cancellation; no local partial file is made.
class MobileSshTransferSaveWriter implements AttachmentStreamingSaveWriter {
  MobileSshTransferSaveWriter({
    required this.save,
    this.maximumBytes = mobileSshTransferMaximumBytes,
  });
  final Future<bool> Function(Uint8List bytes) save;
  final int maximumBytes;
  final _chunks = <Uint8List>[];
  int _length = 0;
  bool _finished = false;
  int get bufferedBytes => _length;
  @override
  Future<void> write(Uint8List bytes) async {
    if (_finished) throw StateError('Destination is closed.');
    if (_length + bytes.length > maximumBytes) {
      await abort();
      throw const FormatException('Mobile downloads are limited to 16 MiB.');
    }
    _chunks.add(Uint8List.fromList(bytes));
    _length += bytes.length;
  }

  @override
  Future<void> commit() async {
    if (_finished) throw StateError('Destination is closed.');
    final data = Uint8List(_length);
    var offset = 0;
    for (final chunk in _chunks) {
      data.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    _clear();
    _finished = true;
    try {
      if (!await save(data)) throw const SshTransferCancelled();
    } finally {
      data.fillRange(0, data.length, 0);
    }
  }

  @override
  Future<void> abort() async {
    _finished = true;
    _clear();
  }

  void _clear() {
    for (final chunk in _chunks) {
      chunk.fillRange(0, chunk.length, 0);
    }
    _chunks.clear();
    _length = 0;
  }
}
