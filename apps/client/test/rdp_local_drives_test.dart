import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/desktop/rdp_storage_io.dart';
import 'package:aterm_client/storage/rdp_local_drives_store.dart';
import 'package:aterm_client/storage/rdp_local_drives_store_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:win32/win32.dart'
    show
        DRIVE_CDROM,
        DRIVE_FIXED,
        DRIVE_NO_ROOT_DIR,
        DRIVE_RAMDISK,
        DRIVE_REMOTE,
        DRIVE_REMOVABLE,
        DRIVE_UNKNOWN;

import 'support/rdp_local_volumes_fake.dart';

/// A store whose reads or writes can be made to fail.
class _FlakyStore extends MemoryRdpLocalDrivesStore {
  _FlakyStore([super.value]);
  bool readFails = false, writeFails = false;
  int writes = 0;
  @override
  Future<String?> read() async {
    if (readFails) throw const FileSystemException('locked');
    return super.read();
  }

  @override
  Future<void> write(String value) async {
    writes++;
    if (writeFails) throw const FileSystemException('disk full');
    return super.write(value);
  }
}

RdpDriveRedirect _drive(String name, String path) =>
    RdpDriveRedirect(name: name, path: path);

void main() {
  group('device-local store', () {
    test('mapping is on by default and turning it off persists', () async {
      final store = MemoryRdpLocalDrivesStore();
      final controller = await fakeLocalDrives(FakeLocalVolumes(), store: store);
      expect(controller.enabled('h1'), isTrue);
      expect(controller.enabled(null), isTrue, reason: 'unsaved Host');
      expect(controller.noticeShown('h1'), isFalse);
      await controller.setEnabled('h1', false);
      expect(controller.enabled('h1'), isFalse);
      expect(controller.enabled('h2'), isTrue);
      expect(jsonDecode(store.value!), {
        'version': 1,
        'off': ['h1'],
        'noticed': [],
      });

      final again = await fakeLocalDrives(FakeLocalVolumes(), store: store);
      expect(again.enabled('h1'), isFalse);
      await again.setEnabled('h1', true);
      expect(again.enabled('h1'), isTrue);
      expect(jsonDecode(store.value!)['off'], isEmpty);
    });

    test('missing, corrupt, oversized or future data means the defaults', () async {
      for (final raw in <String?>[
        null,
        '',
        'not json',
        '[]',
        '{"version":2,"off":["h1"],"noticed":["h1"]}',
        '{"version":1,"off":"h1"}',
        '{"version":1,"off":[1]}',
        '{"version":1,"off":["h1"],"noticed":[""]}',
        '{"version":1,"off":["${'x' * (rdpLocalDrivesStoreMaxBytes)}"]}',
      ]) {
        final controller = await fakeLocalDrives(
          FakeLocalVolumes(),
          store: MemoryRdpLocalDrivesStore(raw),
        );
        expect(controller.enabled('h1'), isTrue, reason: '$raw');
        expect(controller.noticeShown('h1'), isFalse, reason: '$raw');
      }
    });

    test('a store that cannot be read maps nothing until a read succeeds, '
        'and is never overwritten meanwhile', () async {
      final store = _FlakyStore(
        jsonEncode({
          'version': 1,
          'off': ['h1'],
          'noticed': [],
        }),
      )..readFails = true;
      final controller = RdpLocalDrivesController(source: FakeLocalVolumes());
      await controller.load(store);
      expect(controller.unreadable, isTrue);
      expect(controller.enabled('h1'), isFalse);
      expect(controller.enabled('h2'), isFalse, reason: 'fails closed');
      expect(controller.enabled(null), isTrue, reason: 'unsaved Host');
      await controller.refresh();
      expect(controller.enabled('h2'), isFalse);

      // A choice made meanwhile applies at once but is not written over
      // choices that could not be read.
      await controller.setEnabled('h2', true);
      await controller.setEnabled('h3', false);
      expect(controller.enabled('h2'), isTrue);
      expect(controller.enabled('h3'), isFalse);
      expect(controller.writeFailed, isTrue);
      expect(store.writes, 0);

      store.readFails = false;
      await controller.refresh();
      expect(controller.unreadable, isFalse);
      expect(controller.writeFailed, isFalse);
      expect(controller.enabled('h1'), isFalse, reason: 'stored choice kept');
      expect(controller.enabled('h2'), isTrue);
      expect(controller.enabled('h3'), isFalse);
      expect(controller.enabled('h4'), isTrue);
      expect(jsonDecode(store.value!)['off'], ['h1', 'h3']);
    });

    test('a choice that could not be saved is never undone by a refresh and '
        'is written again', () async {
      final store = _FlakyStore();
      final controller = await fakeLocalDrives(FakeLocalVolumes(), store: store);
      store.writeFails = true;
      await controller.setEnabled('h1', false);
      expect(controller.enabled('h1'), isFalse);
      expect(controller.writeFailed, isTrue);
      // Every connect refreshes; the older stored content must not win.
      await controller.refresh();
      expect(controller.enabled('h1'), isFalse);
      expect(controller.writeFailed, isTrue);
      // Another process changed the store meanwhile: both choices hold.
      store.value = jsonEncode({
        'version': 1,
        'off': ['other'],
        'noticed': [],
      });
      store.writeFails = false;
      await controller.refresh();
      expect(controller.writeFailed, isFalse);
      expect(controller.enabled('h1'), isFalse);
      expect(controller.enabled('other'), isFalse);
      expect(jsonDecode(store.value!)['off'], ['other', 'h1']);
      final reloaded = await fakeLocalDrives(
        FakeLocalVolumes(),
        store: MemoryRdpLocalDrivesStore(store.value),
      );
      expect(reloaded.enabled('h1'), isFalse);
    });

    test('refresh reads another writer; the one-time notice and a new Host '
        'id follow the choice', () async {
      final store = MemoryRdpLocalDrivesStore();
      final controller = await fakeLocalDrives(FakeLocalVolumes(), store: store);
      store.value = jsonEncode({
        'version': 1,
        'off': ['other'],
        'noticed': [],
      });
      await controller.refresh();
      expect(controller.enabled('other'), isFalse);

      await controller.setEnabled('draft', false);
      await controller.markNoticeShown('draft');
      await controller.moveHost('draft', 'saved');
      expect(controller.enabled('draft'), isTrue);
      expect(controller.enabled('saved'), isFalse);
      expect(controller.noticeShown('saved'), isTrue);
      final reloaded = await fakeLocalDrives(FakeLocalVolumes(), store: store);
      expect(reloaded.enabled('saved'), isFalse);
      expect(reloaded.enabled('other'), isFalse);
      expect(reloaded.noticeShown('saved'), isTrue);
    });

    test('lists stay bounded, dropping the oldest entries', () async {
      final controller = await fakeLocalDrives(FakeLocalVolumes());
      for (var i = 0; i <= RdpLocalDrivesController.maxEntries; i++) {
        unawaited(controller.setEnabled('h$i', false));
      }
      await controller.setEnabled('last', false);
      expect(controller.enabled('h0'), isTrue);
      expect(controller.enabled('h1'), isTrue);
      expect(controller.enabled('h2'), isFalse);
      expect(controller.enabled('last'), isFalse);
    });

    test('the file store lives in the app support directory', () async {
      final dir = await Directory.systemTemp.createTemp('atermius-drives-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileRdpLocalDrivesStore(directory: () async => dir);
      expect(await store.read(), isNull);
      final controller = RdpLocalDrivesController(source: FakeLocalVolumes());
      await controller.load(store);
      await controller.setEnabled('h1', false);
      final file = File('${dir.path}/rdp-local-drives-v1');
      expect(file.existsSync(), isTrue);
      final again = RdpLocalDrivesController(source: FakeLocalVolumes());
      await again.load(FileRdpLocalDrivesStore(directory: () async => dir));
      expect(again.enabled('h1'), isFalse);
      // Only the value file remains (the temporary write directory is gone).
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), [
        'rdp-local-drives-v1',
      ]);
      file.writeAsStringSync('x' * (rdpLocalDrivesStoreMaxBytes + 1));
      expect(await store.read(), isNull);
    });

    test('on Windows the file stays out of the roaming profile', () {
      expect(
        windowsDeviceLocalPath(
          r'C:\Users\me\AppData\Roaming\Atermius\Atermius',
          roaming: r'C:\Users\me\AppData\Roaming',
          local: r'C:\Users\me\AppData\Local',
        ),
        r'C:\Users\me\AppData\Local\Atermius\Atermius',
      );
      expect(
        windowsDeviceLocalPath(
          r'c:\users\me\appdata\roaming\Atermius\Atermius',
          roaming: r'C:\Users\me\AppData\Roaming\',
          local: r'D:\Local\',
        ),
        r'D:\Local\Atermius\Atermius',
      );
      // Unknown folders or another layout keep the support directory.
      for (final (roaming, local) in [
        (null, r'C:\Local'),
        (r'C:\Roaming', null),
        ('', r'C:\Local'),
        (r'C:\Elsewhere', r'C:\Local'),
        (r'C:\Users\me\AppData\Roam', r'C:\Local'),
      ]) {
        expect(
          windowsDeviceLocalPath(
            r'C:\Users\me\AppData\Roaming\Atermius',
            roaming: roaming,
            local: local,
          ),
          r'C:\Users\me\AppData\Roaming\Atermius',
          reason: '$roaming $local',
        );
      }
    });
  });

  group('Windows volumes', () {
    test('fixed, removable, optical and RAM disks; network and unknown drives '
        'never; each named by its letter', () async {
      const types = {
        'A': DRIVE_REMOVABLE, // card reader without media
        'C': DRIVE_FIXED,
        'D': DRIVE_CDROM, // empty
        'E': DRIVE_REMOVABLE,
        'F': DRIVE_REMOTE,
        'G': DRIVE_RAMDISK,
        'H': DRIVE_NO_ROOT_DIR,
        'I': DRIVE_UNKNOWN,
        'J': DRIVE_FIXED, // probe hangs
        'K': DRIVE_FIXED, // probe fails
      };
      var mask = 0;
      for (final letter in types.keys) {
        mask |= 1 << (letter.codeUnitAt(0) - 65);
      }
      final probed = <String>[];
      final hang = Completer<bool>();
      final volumes = await windowsRdpVolumes(
        mask: mask,
        driveType: (root) => types[root[0]]!,
        ready: (root) {
          probed.add(root);
          return switch (root[0]) {
            'A' || 'D' => Future.value(false),
            'J' => hang.future,
            'K' => Future.error(StateError('device error')),
            _ => Future.value(true),
          };
        },
        timeout: const Duration(milliseconds: 50),
      );
      expect(volumes, const [
        RdpLocalVolume(name: 'A', path: r'A:\', ready: false),
        RdpLocalVolume(name: 'C', path: r'C:\'),
        RdpLocalVolume(name: 'D', path: r'D:\', ready: false),
        RdpLocalVolume(name: 'E', path: r'E:\'),
        RdpLocalVolume(name: 'G', path: r'G:\'),
        RdpLocalVolume(name: 'J', path: r'J:\', ready: false),
        RdpLocalVolume(name: 'K', path: r'K:\', ready: false),
      ]);
      // Network, unknown and missing roots are never touched.
      expect(probed, isNot(contains(r'F:\')));
      expect(probed, isNot(contains(r'H:\')));
      expect(probed, isNot(contains(r'I:\')));

      final expansion = await expandRdpDrives(
        explicit: const [],
        automatic: true,
        source: FakeLocalVolumes(volumes: volumes),
      );
      expect(expansion.drives, [
        _drive('C', r'C:\'),
        _drive('E', r'E:\'),
        _drive('G', r'G:\'),
      ]);
      expect(expansion.mapped, ['C', 'E', 'G']);
      expect(expansion.unavailable, ['A', 'D', 'J', 'K']);
      final config = RdpSettings(drives: expansion.drives).toNativeConfig(
        features: const RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive),
        initialWidth: 1280,
        initialHeight: 800,
      );
      // The server shows \\tsclient\C, like mstsc.
      expect(config.text, contains('\ndrive=C|C:\\\n'));
      expect(config.text, contains('\ndrive=E|E:\\\n'));
    });
  });

  group('Android volumes', () {
    test('mounted volumes map with stable names; others are named or ignored', () {
      final volumes = rdpAndroidVolumesFrom([
        {
          'path': '/storage/emulated/0',
          'label': 'Internal shared storage',
          'primary': true,
          'state': 'mounted',
          'readable': true,
        },
        {
          'path': '/storage/1A2B-3C4D',
          'label': 'SD 卡',
          'primary': false,
          'uuid': '1A2B-3C4D',
          'state': 'mounted',
          'readable': true,
        },
        {
          'path': '',
          'label': 'USB drive',
          'uuid': '0000-1111',
          'state': 'checking',
          'readable': false,
        },
        {'path': '', 'uuid': '2222-3333', 'state': 'removed'},
        {'path': '/storage/legacy'}, // runner without state: usable
        'garbage',
      ]);
      expect(volumes, const [
        RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
        RdpLocalVolume(name: 'Storage 1A2B-3C4D', path: '/storage/1A2B-3C4D'),
        RdpLocalVolume(name: 'Storage 0000-1111', path: '', ready: false),
        RdpLocalVolume(name: 'Storage legacy', path: '/storage/legacy'),
      ]);
      for (final volume in volumes.where((v) => v.ready)) {
        expect(
          RdpDriveRedirect(name: volume.name, path: volume.path).validate(),
          isNull,
        );
      }
    });

    test('without All files access nothing is listed or requested', () async {
      final source = FakeLocalVolumes(
        os: RdpAutoDriveOs.android,
        access: false,
        volumes: const [
          RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
        ],
      );
      final expansion = await expandRdpDrives(
        explicit: [_drive('Work', '/storage/emulated/0/Work')],
        automatic: true,
        source: source,
      );
      expect(expansion.accessRequired, isTrue);
      expect(expansion.drives, [_drive('Work', '/storage/emulated/0/Work')]);
      expect(source.listed, 0);
      expect(source.requests, 0);
    });
  });

  group('expansion', () {
    test('Host folders first; same path skipped (case-insensitive on '
        'Windows); names stay unique', () async {
      final expansion = await expandRdpDrives(
        explicit: [_drive('D', r'D:\Data'), _drive('Root', 'c:/')],
        automatic: true,
        source: FakeLocalVolumes(
          volumes: const [windowsC, RdpLocalVolume(name: 'D', path: r'D:\')],
        ),
      );
      expect(expansion.drives, [
        _drive('D', r'D:\Data'),
        _drive('Root', 'c:/'),
        _drive('D 2', r'D:\'),
      ]);
      expect(expansion.mapped, ['D 2']);
      expect(RdpSettings(drives: expansion.drives).validate(), isNull);
    });

    test('the total is capped at 32 and what was left out is named', () async {
      final explicit = [
        for (var i = 0; i < 30; i++) _drive('Folder $i', 'C:\\Data\\$i'),
      ];
      final expansion = await expandRdpDrives(
        explicit: explicit,
        automatic: true,
        source: FakeLocalVolumes(
          volumes: [
            for (final letter in ['C', 'D', 'E', 'F', 'G'])
              RdpLocalVolume(name: letter, path: '$letter:\\'),
          ],
        ),
      );
      expect(RdpSettings.maxConnectionDrives, 32);
      expect(expansion.drives, hasLength(32));
      expect(expansion.mapped, ['C', 'D']);
      expect(expansion.leftOut, ['E', 'F', 'G']);
      final config = RdpSettings(drives: expansion.drives).toNativeConfig(
        features: const RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive),
        initialWidth: 1280,
        initialHeight: 800,
      );
      expect('drive='.allMatches(config.text), hasLength(32));
      expect(
        () => RdpSettings(
          drives: [...expansion.drives, _drive('More', r'H:\')],
        ).toNativeConfig(
          features: const RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive),
          initialWidth: 1280,
          initialHeight: 800,
        ),
        throwsFormatException,
      );
    });

    test('a Host folder from the other operating system is skipped, not fatal',
        () async {
      final onWindows = await expandRdpDrives(
        explicit: [
          _drive('Phone', '/storage/emulated/0'),
          _drive('Work', r'C:\Work'),
        ],
        automatic: false,
        source: FakeLocalVolumes(),
      );
      expect(onWindows.otherDevice, ['Phone']);
      expect(onWindows.drives, [_drive('Work', r'C:\Work')]);
      final onAndroid = await expandRdpDrives(
        explicit: [
          _drive('PC', r'C:\'),
          _drive('Share', r'\\server\share'),
          _drive('Phone', '/storage/emulated/0'),
        ],
        automatic: false,
        source: FakeLocalVolumes(os: RdpAutoDriveOs.android),
      );
      expect(onAndroid.otherDevice, ['PC', 'Share']);
      expect(onAndroid.drives, [_drive('Phone', '/storage/emulated/0')]);
    });

    test('new mappings fit 259 UTF-8 bytes; a longer stored Host folder is '
        'skipped and named, a longer volume is skipped', () async {
      final ascii259 = '/${'a' * 258}';
      final cjk259 = '/${'资' * 86}'; // 1 + 86 * 3 bytes
      expect(rdpPathFitsEngine(ascii259), isTrue);
      expect(rdpPathFitsEngine('${ascii259}b'), isFalse);
      expect(rdpPathFitsEngine(cjk259), isTrue);
      expect(rdpPathFitsEngine('$cjk259资'), isFalse);
      // Stored paths keep the limit earlier versions accepted.
      expect(isSafeLocalPath('$cjk259资'), isTrue);
      expect(isSafeLocalPath('/${'a' * 1023}'), isTrue);
      expect(isSafeLocalPath('/${'a' * 1024}'), isFalse);
      expect(_drive('Long', '$cjk259资').validate(), isNull);
      final expansion = await expandRdpDrives(
        explicit: [
          _drive('Long', '$cjk259资'),
          _drive('Work', '/storage/emulated/0/Work'),
        ],
        automatic: true,
        source: FakeLocalVolumes(
          os: RdpAutoDriveOs.android,
          volumes: [
            RdpLocalVolume(name: 'Huge', path: '$cjk259资'),
            const RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
          ],
        ),
      );
      expect(expansion.tooLong, ['Long']);
      expect(expansion.unavailable, ['Huge']);
      expect(expansion.mapped, ['Local Storage']);
      expect(expansion.drives.map((d) => d.name), ['Work', 'Local Storage']);
      // The engine rejects the whole configuration for a longer path: it
      // never reaches the native config.
      final config = RdpSettings(
        drives: [_drive('Long', '$cjk259资'), _drive('Work', '/srv/work')],
      ).toNativeConfig(
        features: const RdpFeatures(
          RdpFeatures.configV1 | RdpFeatures.drive | RdpFeatures.audioOut,
        ),
        initialWidth: 1280,
        initialHeight: 800,
      );
      expect(config.text, isNot(contains('drive=Long')));
      expect(config.text, contains('\ndrive=Work|/srv/work\n'));
      expect(config.unavailable, ['folders']);
    });

    test('switch off maps no local volumes; Host folders still map', () async {
      final source = FakeLocalVolumes(volumes: const [windowsC]);
      final expansion = await expandRdpDrives(
        explicit: [_drive('Work', r'D:\Work')],
        automatic: false,
        source: source,
      );
      expect(expansion.drives, [_drive('Work', r'D:\Work')]);
      expect(expansion.mapped, isEmpty);
      expect(source.listed, 0);
    });

    test('platforms without automatic mapping add nothing', () async {
      final source = FakeLocalVolumes(
        os: null,
        windowsPaths: false,
        volumes: const [RdpLocalVolume(name: 'Home', path: '/Users/me')],
      );
      final expansion = await expandRdpDrives(
        explicit: const [],
        automatic: true,
        source: source,
      );
      expect(expansion.drives, isEmpty);
      expect(source.listed, 0);
    });

    test('vanished, not-ready or unreadable volumes never throw', () async {
      final failing = FakeLocalVolumes()..error = StateError('gone');
      final failed = await expandRdpDrives(
        explicit: const [],
        automatic: true,
        source: failing,
      );
      expect(failed.drives, isEmpty);
      final partial = await expandRdpDrives(
        explicit: const [],
        automatic: true,
        source: FakeLocalVolumes(
          volumes: const [
            windowsC,
            RdpLocalVolume(name: 'E', path: r'E:\', ready: false),
          ],
        ),
      );
      expect(partial.mapped, ['C']);
      expect(partial.unavailable, ['E']);
    });
  });
}
