import 'telnet_errors.dart';
import 'telnet_transport.dart';

/// Browsers cannot open raw TCP sockets. Telnet in a browser is only possible
/// through the authenticated server Relay ([connectTelnetViaRelay]).
const bool telnetDirectTcpSupported = false;

Future<TelnetByteChannel> connectTelnetDirect(String host, int port) =>
    Future.error(const TelnetException(TelnetFailure.unsupportedPlatform));
