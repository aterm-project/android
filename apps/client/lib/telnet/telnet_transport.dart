import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../api/api_client.dart';
import '../ssh/ssh_relay_socket.dart';
import 'telnet_errors.dart';
import 'telnet_transport_io.dart'
    if (dart.library.js_interop) 'telnet_transport_web.dart'
    as platform;

/// A bidirectional opaque byte stream carrying one Telnet connection.
///
/// Implemented by a native TCP socket (desktop/mobile) or the authenticated
/// server Relay WebSocket (browser). Telnet never launches an OS client.
abstract interface class TelnetByteChannel {
  Stream<Uint8List> get stream;
  void add(Uint8List bytes);

  /// Idempotent. Completes once the transport is torn down.
  Future<void> close();
}

typedef TelnetChannelConnector =
    Future<TelnetByteChannel> Function(String host, int port);

/// True on platforms that can open a raw TCP socket from this process.
bool get telnetDirectTcpSupported => platform.telnetDirectTcpSupported;

/// Opens a direct TCP connection. Browsers throw
/// [TelnetException] with [TelnetFailure.unsupportedPlatform].
Future<TelnetByteChannel> connectTelnetDirect(String host, int port) =>
    platform.connectTelnetDirect(host, port);

/// Opens Telnet through the authenticated server Relay. The Relay applies the
/// same server-side CIDR/port allowlists, per-user policy, one-use ticket and
/// audit rules as SSH; it forwards opaque TCP bytes only.
///
/// There is deliberately no inner timeout around the WebSocket setup:
/// [connectRelaySocket] bounds its own handshake, and the caller
/// ([TelnetSession.connect]) owns the overall deadline/cancellation and closes
/// a channel that resolves after it gave up, so a late socket is never lost.
Future<TelnetByteChannel> connectTelnetViaRelay({
  required ApiClient api,
  required String deviceId,
  required String host,
  required int port,
  Future<SSHSocket> Function(Uri relayUri, String ticket)? relaySocketConnector,
}) => connectTelnetRelayWith(
  issueTicket: () async => (await api
          .createRelayTicket(
            deviceId: deviceId,
            targetHost: host,
            targetPort: port,
          )
          .timeout(const Duration(seconds: 15)))
      .value,
  relayUri: api.relayUri,
  relaySocketConnector: relaySocketConnector ?? connectRelaySocket,
);

/// Relay connection steps with injectable ticket issuance (tests).
@visibleForTesting
Future<TelnetByteChannel> connectTelnetRelayWith({
  required Future<String> Function() issueTicket,
  required Uri Function() relayUri,
  required Future<SSHSocket> Function(Uri relayUri, String ticket)
  relaySocketConnector,
}) async {
  final ticket = await issueTicket();
  final SSHSocket socket;
  try {
    socket = await relaySocketConnector(relayUri(), ticket);
  } on TimeoutException {
    throw const TelnetException(TelnetFailure.timeout);
  } catch (_) {
    // Relay/WebSocket errors may carry endpoint details; keep them out.
    throw const TelnetException(TelnetFailure.relayUnavailable);
  }
  return RelayTelnetChannel(socket);
}

/// Adapts the Relay WebSocket (exposed as an [SSHSocket] byte pipe) to a
/// [TelnetByteChannel]. No SSH framing is involved.
class RelayTelnetChannel implements TelnetByteChannel {
  RelayTelnetChannel(this._socket);

  final SSHSocket _socket;
  Future<void>? _closing;

  @override
  Stream<Uint8List> get stream => _socket.stream;

  @override
  void add(Uint8List bytes) {
    if (_closing != null) return;
    _socket.sink.add(bytes);
  }

  @override
  Future<void> close() => _closing ??= _socket.close().timeout(
    const Duration(seconds: 3),
    onTimeout: _socket.destroy,
  );
}

/// Test-only replacement for the native direct connector used by LocalVault
/// profiles (loopback fixtures). Never set in production code.
@visibleForTesting
TelnetChannelConnector? telnetConnectorOverrideForTesting;

/// Direct connector for LocalVault profiles (native only).
TelnetChannelConnector get localTelnetConnector =>
    telnetConnectorOverrideForTesting ?? connectTelnetDirect;
