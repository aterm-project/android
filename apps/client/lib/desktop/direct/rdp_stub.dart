import '../rdp_features.dart';
import 'connection.dart';

bool get bundledRdpAvailable => false;

RdpFeatures rdpEngineFeatures() => RdpFeatures.none;

class RdpConnection {
  static DirectDesktopConnection connect(
    String host,
    int port,
    String user,
    String password,
    String pin, {
    String config = '',
  }) => throw UnsupportedError('Direct RDP requires the native client.');
}
