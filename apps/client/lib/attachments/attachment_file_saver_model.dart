import 'dart:typed_data';

/// A temporary, sequential destination for one authenticated attachment.
///
/// Call [commit] only after the service has verified the complete plaintext
/// length and digest. Call [abort] after any transfer or integrity failure.
abstract interface class AttachmentStreamingSaveWriter {
  Future<void> write(Uint8List plaintextChunk);

  Future<void> commit();

  Future<void> abort();
}
