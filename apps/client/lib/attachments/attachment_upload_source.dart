import 'dart:async';
import 'dart:typed_data';

const hostAttachmentLogicalChunkBytes = 4 * 1024 * 1024;

/// One-shot source for attachment upload plaintext.
///
/// Implementations should emit bounded chunks (at most one logical crypto
/// chunk). The consumer pulls each event before requesting the next one, so a
/// source can provide back-pressure without keeping the complete file in
/// memory. The consumer calls [releaseReadChunk] after consuming an event;
/// implementations may clear the owned plaintext buffer at that point.
abstract interface class AttachmentUploadSource {
  int get size;

  Stream<List<int>> openRead();

  void releaseReadChunk(List<int> bytes) {}
}

/// Marker for sources whose implementation guarantees back-pressured reads
/// with bounded chunks rather than retaining the complete plaintext file.
/// Implementations used for v2 encryption must honor the 4 MiB event ceiling.
abstract interface class BoundedAttachmentUploadSource
    implements AttachmentUploadSource {}

/// Compatibility adapter for callers that already own bytes in memory.
///
/// Slices are views; this does not make a second file-sized copy.
class MemoryAttachmentUploadSource implements AttachmentUploadSource {
  MemoryAttachmentUploadSource(this.bytes);

  final List<int> bytes;

  @override
  int get size => bytes.length;

  @override
  Stream<List<int>> openRead() async* {
    for (
      var offset = 0;
      offset < bytes.length;
      offset += hostAttachmentLogicalChunkBytes
    ) {
      final end = offset + hostAttachmentLogicalChunkBytes < bytes.length
          ? offset + hostAttachmentLogicalChunkBytes
          : bytes.length;
      if (bytes is Uint8List) {
        yield Uint8List.sublistView(bytes as Uint8List, offset, end);
      } else {
        yield bytes.sublist(offset, end);
      }
    }
  }

  @override
  void releaseReadChunk(List<int> bytes) {}
}

/// Wraps a one-shot platform file stream selected by the user.
class StreamAttachmentUploadSource implements BoundedAttachmentUploadSource {
  StreamAttachmentUploadSource({required this.size, required this.stream});

  @override
  final int size;

  final Stream<List<int>> stream;

  var _opened = false;

  @override
  Stream<List<int>> openRead() {
    if (_opened) {
      return Stream<List<int>>.error(
        StateError('Attachment file source can only be read once.'),
      );
    }
    _opened = true;
    return stream;
  }

  @override
  void releaseReadChunk(List<int> bytes) {
    try {
      bytes.fillRange(0, bytes.length, 0);
    } on UnsupportedError {
      // Some platform adapters expose immutable List views. The stream has
      // already been consumed, but there is no writable buffer to clear.
    }
  }
}
