import 'dart:typed_data';

class SftpPickedFile {
  const SftpPickedFile({
    required this.name,
    required this.bytes,
  });

  final String name;
  final Uint8List bytes;
}
