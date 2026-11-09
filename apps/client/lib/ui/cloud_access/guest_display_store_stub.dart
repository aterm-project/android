import 'dart:typed_data';

class GuestDisplayStore {
  GuestDisplayStore._();
  static final _memory = <String, Uint8List>{};
  static Uint8List? read(String linkId, int version) =>
      _memory['$linkId/$version'];
  static void write(String linkId, int version, Uint8List key) =>
      _memory['$linkId/$version'] = Uint8List.fromList(key);
  static void clear(String linkId) =>
      _memory.removeWhere((k, _) => k.startsWith('$linkId/'));
}
