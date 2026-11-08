import 'package:dartssh2/dartssh2.dart';

Future<SSHSocket> connectDirect(String host, int port) =>
    SSHSocket.connect(host, port, timeout: const Duration(seconds: 15));
