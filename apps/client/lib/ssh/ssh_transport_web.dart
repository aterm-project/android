import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

Future<SSHSocket> connectDirect(String host, int port) => Future.error(
  UnsupportedError('Browsers require the configured SSH relay.'),
);
