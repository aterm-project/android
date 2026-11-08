import 'dart:typed_data';

bool get supportsRestrictedDesktopSave => false;

Future<bool> saveRestricted({
  required String fileName,
  required Uint8List bytes,
  required bool restrictToOwner,
}) => throw UnsupportedError('Restricted desktop saves are unavailable.');
