import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'telnet_errors.dart';
import 'telnet_transport.dart';

const bool telnetDirectTcpSupported = true;

Future<TelnetByteChannel> connectTelnetDirect(String host, int port) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
    );
  } on SocketException catch (error) {
    // OS error text can include resolver details; map to a fixed category.
    throw TelnetException(_classify(error));
  } on TimeoutException {
    throw const TelnetException(TelnetFailure.timeout);
  }
  try {
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {
    // Best effort; Nagle only affects keystroke latency.
  }
  return _SocketTelnetChannel(socket);
}

TelnetFailure _classify(SocketException error) {
  final code = error.osError?.errorCode;
  final message = error.message.toLowerCase();
  if (message.contains('timed out') || code == 110 || code == 60) {
    return TelnetFailure.timeout;
  }
  if (message.contains('refused') ||
      code == 111 ||
      code == 61 ||
      code == 10061) {
    return TelnetFailure.refused;
  }
  if (message.contains('lookup') || message.contains('host lookup')) {
    return TelnetFailure.hostLookup;
  }
  return TelnetFailure.unreachable;
}

class _SocketTelnetChannel implements TelnetByteChannel {
  _SocketTelnetChannel(this._socket);

  final Socket _socket;
  Future<void>? _closing;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  void add(Uint8List bytes) {
    if (_closing != null) return;
    try {
      _socket.add(bytes);
    } catch (_) {
      // A write after the peer reset is reported through the read stream.
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Fall through to destroy.
    }
    _socket.destroy();
  }
}
