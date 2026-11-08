import 'package:dartssh2/dartssh2.dart';

import 'ssh_transport_io.dart'
    if (dart.library.js_interop) 'ssh_transport_web.dart'
    as platform;

export 'ssh_relay_socket.dart' show connectRelaySocket;

Future<SSHSocket> connectDirect(String host, int port) =>
    platform.connectDirect(host, port);
