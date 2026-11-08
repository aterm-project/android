import 'sync_hint_socket.dart';
import 'sync_hint_socket_stub.dart'
    if (dart.library.io) 'sync_hint_socket_io.dart'
    as platform;

Future<SyncHintSocket> connectSyncHintSocket(
  Uri uri, {
  required String origin,
}) => platform.connectSyncHintSocket(uri, origin: origin);
