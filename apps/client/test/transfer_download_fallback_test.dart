import 'package:aterm_client/ui/transfer_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const platforms = <({String name, bool stream, bool mobile, bool fallback})>[
    (name: 'Firefox without save picker', stream: false, mobile: false, fallback: true),
    (name: 'macOS byte-save provider', stream: false, mobile: false, fallback: true),
    (name: 'Windows streaming picker', stream: true, mobile: false, fallback: false),
    (name: 'Android bounded writer', stream: false, mobile: true, fallback: false),
    (name: 'iOS bounded writer', stream: false, mobile: true, fallback: false),
  ];
  for (final platform in platforms) {
    test('${platform.name} retains the correct SFTP download route', () {
      expect(useLegacySftpDownload(protocol: SshTransferProtocol.sftp,
        supportsStreamingSave: platform.stream,
        mobileWriterAvailable: platform.mobile), platform.fallback);
    });
    test('${platform.name} never silently changes SCP to SFTP', () {
      expect(useLegacySftpDownload(protocol: SshTransferProtocol.scp,
        supportsStreamingSave: platform.stream,
        mobileWriterAvailable: platform.mobile), isFalse);
    });
  }
}
