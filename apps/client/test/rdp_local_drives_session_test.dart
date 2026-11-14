import 'dart:async';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/rdp_local_drives_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';
import 'support/rdp_local_volumes_fake.dart';

class _Connection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }

  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
}

// Local audio playback (the default) is available, so only drive notices show.
const _drives = RdpFeatures(
  RdpFeatures.configV1 | RdpFeatures.drive | RdpFeatures.audioOut,
);
const _host = HostRecord(
  id: 'win',
  name: 'Win',
  address: 'win.example',
  protocol: HostProtocol.rdp,
);

void main() {
  useAppLocaleFixture('en');

  Future<(DesktopSession, List<_Connection>)> connect(
    RdpLocalDrivesController local, {
    RdpFeatures features = _drives,
    HostRecord host = _host,
    List<String>? notices,
  }) async {
    final connections = <_Connection>[];
    final session = DesktopSession(
      localDrives: local,
      directConnectionForTesting: (_) {
        final c = _Connection();
        connections.add(c);
        return c;
      },
    )..rdpFeaturesForTesting = features;
    if (notices != null) session.onNotice = notices.add;
    addTearDown(() async {
      await session.close();
      session.dispose();
    });
    await session.connectLocal(host);
    return (session, connections);
  }

  Future<void> drop(DesktopSession session, _Connection connection) async {
    connection.controller.addError(StateError('Disconnected'));
    await Future<void>.delayed(Duration.zero);
  }

  test('local disks map by default with a one-time notice per Host', () async {
    final store = MemoryRdpLocalDrivesStore();
    final local = await fakeLocalDrives(
      FakeLocalVolumes(volumes: const [windowsC, windowsE]),
      store: store,
    );
    final notices = <String>[];
    final (session, connections) = await connect(local, notices: notices);
    expect(connections, hasLength(1));
    expect(session.rdpConfig!.text, contains('\ndrive=C|C:\\\n'));
    expect(session.rdpConfig!.text, contains('\ndrive=E|E:\\\n'));
    expect(notices, [currentL10n.rdpLocalDisksMapped('C, E')]);
    await Future<void>.delayed(Duration.zero);
    expect(local.noticeShown(_host.id), isTrue);
    expect(store.value, contains(_host.id));

    await drop(session, connections.single);
    await session.reconnect();
    expect(session.rdpConfig!.text, contains('\ndrive=C|C:\\\n'));
    expect(notices, hasLength(1), reason: 'shown once per Host and device');
  });

  test('an engine without the drive channel gets no drive lines', () async {
    final source = FakeLocalVolumes(volumes: const [windowsC]);
    final local = await fakeLocalDrives(source);
    final notices = <String>[];
    final (session, _) = await connect(
      local,
      features: const RdpFeatures(
        RdpFeatures.configV1 | RdpFeatures.audioOut,
      ),
      notices: notices,
    );
    expect(session.rdpConfig!.text, isNot(contains('drive=')));
    expect(source.listed, 0);
    expect(notices, isEmpty);
  });

  test('switch off: no local disks, Host folders still map', () async {
    final local = await fakeLocalDrives(
      FakeLocalVolumes(volumes: const [windowsC]),
    );
    await local.setEnabled(_host.id, false);
    final host = _host.copyWith(
      manifest: const RdpSettings(
        drives: [RdpDriveRedirect(name: 'Work', path: r'D:\Work')],
      ).applyTo(null),
    );
    final notices = <String>[];
    final (session, _) = await connect(local, host: host, notices: notices);
    final lines = session.rdpConfig!.text
        .split('\n')
        .where((l) => l.startsWith('drive='));
    expect(lines, [r'drive=Work|D:\Work']);
    expect(notices, isEmpty);
  });

  test('Android without All files access connects without local storage, '
      'never opens Settings and says how to grant it', () async {
    final source = FakeLocalVolumes(
      os: RdpAutoDriveOs.android,
      access: false,
      volumes: const [
        RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
      ],
    );
    final local = await fakeLocalDrives(source);
    final notices = <String>[];
    final (session, connections) = await connect(local, notices: notices);
    expect(connections, hasLength(1), reason: 'the connection proceeds');
    expect(session.state, 'connecting');
    expect(session.error, isNull);
    expect(session.rdpConfig!.text, isNot(contains('drive=')));
    expect(source.requests, 0);
    expect(notices, [currentL10n.rdpLocalDisksNeedAccess]);

    // Once access is granted, the next reconnect maps the storage.
    source.access = true;
    await drop(session, connections.single);
    await session.reconnect();
    expect(
      session.rdpConfig!.text,
      contains('\ndrive=Local Storage|/storage/emulated/0\n'),
    );
  });

  test('skipped disks, other-device or too long folders and the cap are '
      'reported', () async {
    final local = await fakeLocalDrives(
      FakeLocalVolumes(
        volumes: [
          for (var i = 0; i < 27; i++)
            RdpLocalVolume(name: 'V$i', path: 'C:\\Mount\\$i'),
          const RdpLocalVolume(name: 'F', path: r'F:\', ready: false),
        ],
      ),
    );
    await local.markNoticeShown(_host.id);
    // Stored by an earlier version (up to 1024 characters were accepted).
    final long = 'C:\\${'资' * 90}';
    final host = _host.copyWith(
      manifest: RdpSettings(
        drives: [
          const RdpDriveRedirect(name: 'Phone', path: '/storage/emulated/0'),
          RdpDriveRedirect(name: 'Long', path: long),
          for (var i = 0; i < 6; i++)
            RdpDriveRedirect(name: 'Folder $i', path: 'C:\\Data\\$i'),
        ],
      ).applyTo(null),
    );
    expect(RdpSettings.of(host).drives, hasLength(8));
    final notices = <String>[];
    final (session, connections) = await connect(
      local,
      host: host,
      notices: notices,
    );
    expect(connections, hasLength(1));
    expect('drive='.allMatches(session.rdpConfig!.text), hasLength(32));
    expect(session.rdpConfig!.text, isNot(contains('/storage/emulated/0')));
    expect(session.rdpConfig!.text, isNot(contains(long)));
    expect(notices, [
      currentL10n.rdpDrivesFromOtherDevice('Phone'),
      currentL10n.rdpDrivesPathTooLong('Long'),
      currentL10n.rdpLocalDisksUnavailable('F'),
      currentL10n.rdpDrivesLeftOut(32, 'V26'),
    ]);
  });

  test('switch off with a failed save still maps no local disks on '
      'connect and reconnect', () async {
    final store = _FailingWrites();
    final local = RdpLocalDrivesController(
      source: FakeLocalVolumes(volumes: const [windowsC]),
    );
    await local.load(store);
    await local.setEnabled(_host.id, false);
    expect(local.writeFailed, isTrue);
    final (session, connections) = await connect(local);
    expect(local.enabled(_host.id), isFalse);
    expect(session.rdpConfig!.text, isNot(contains('drive=')));
    await drop(session, connections.single);
    await session.reconnect();
    expect(session.rdpConfig!.text, isNot(contains('drive=')));
  });

  test('stored choices that cannot be read map no local disks, once '
      'explained per tab', () async {
    final store = _FailingWrites()..readFails = true;
    final local = RdpLocalDrivesController(
      source: FakeLocalVolumes(volumes: const [windowsC]),
    );
    await local.load(store);
    final notices = <String>[];
    final (session, connections) = await connect(local, notices: notices);
    expect(session.rdpConfig!.text, isNot(contains('drive=')));
    expect(notices, [currentL10n.rdpMapLocalDisksUnreadable]);
    await drop(session, connections.single);
    await session.reconnect();
    expect(notices, hasLength(1));
    // Readable again: the default (on) applies on the next reconnect.
    store.readFails = false;
    await drop(session, connections.last);
    await session.reconnect();
    expect(session.rdpConfig!.text, contains('\ndrive=C|C:\\\n'));
  });

  test('notices raised before a view attaches are replayed to it', () async {
    final local = await fakeLocalDrives(
      FakeLocalVolumes(volumes: const [windowsC]),
    );
    final (session, _) = await connect(local);
    final shown = <String>[];
    session.onNotice = shown.add;
    expect(shown, isEmpty, reason: 'replayed after the attaching build');
    await Future<void>.delayed(Duration.zero);
    expect(shown, [currentL10n.rdpLocalDisksMapped('C')]);
    session.onNotice = null;
    session.onNotice = shown.add;
    await Future<void>.delayed(Duration.zero);
    expect(shown, hasLength(1), reason: 'each notice is delivered once');
  });

  test('a closed session never finishes a connect started before', () async {
    final source = _SlowVolumes();
    final local = RdpLocalDrivesController(source: source);
    await local.load(MemoryRdpLocalDrivesStore());
    final connections = <_Connection>[];
    final session = DesktopSession(
      localDrives: local,
      directConnectionForTesting: (_) {
        final c = _Connection();
        connections.add(c);
        return c;
      },
    )..rdpFeaturesForTesting = _drives;
    final connecting = session.connectLocal(_host);
    await Future<void>.delayed(Duration.zero);
    await session.close();
    source.release.complete([windowsC]);
    await connecting;
    expect(connections, isEmpty);
    session.dispose();
  });
}

class _FailingWrites implements RdpLocalDrivesStore {
  bool readFails = false;
  @override
  Future<String?> read() async {
    if (readFails) throw StateError('locked');
    return null;
  }

  @override
  Future<void> write(String value) async => throw StateError('disk full');
}

class _SlowVolumes extends FakeLocalVolumes {
  final release = Completer<List<RdpLocalVolume>>();
  @override
  Future<List<RdpLocalVolume>> volumes() => release.future;
}
