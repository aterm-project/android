import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/desktop/direct/rdp_file_transfer_io.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_file_clipboard.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_settings_editor.dart';
import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _all = RdpFeatures(0x3ff);
const _rdp = HostRecord(
  id: 'h1',
  name: 'Win',
  address: 'win.example',
  protocol: HostProtocol.rdp,
);

void main() {
  group('RdpSettings persistence', () {
    test('defaults leave Host records unchanged', () {
      expect(RdpSettings.defaults.applyTo(null), isNull);
      final other = {hostOperatingSystemManifestKey: {'version': 1}};
      expect(RdpSettings.defaults.applyTo(other), other);
      expect(RdpSettings.of(_rdp), RdpSettings.defaults);
    });

    test('round-trips through the encrypted Host JSON with other manifest keys', () {
      const settings = RdpSettings(
        resolution: RdpResolutionMode.fixed,
        width: 1920,
        height: 1080,
        scalePercent: 150,
        multiMonitor: true,
        clipboardFiles: true,
        drives: [RdpDriveRedirect(name: 'Work', path: r'C:\Users\me\Work')],
        audio: RdpAudioMode.remote,
        microphone: true,
        printers: RdpPrinterMode.defaultPrinter,
        smartCards: true,
        cameras: true,
        usbDevices: ['046d:c52b'],
      );
      final host = _rdp.copyWith(
        manifest: settings.applyTo({'other_v1': 'kept'}),
      );
      final decoded = HostRecord.fromJson(host.toJson());
      expect(RdpSettings.of(decoded), settings);
      expect(decoded.manifest!['other_v1'], 'kept');
      // Clearing back to defaults removes only our key.
      expect(RdpSettings.defaults.applyTo(decoded.manifest), {'other_v1': 'kept'});
    });

    test('strict decoding rejects unsafe or unknown values', () {
      Map<String, Object?> base() => RdpSettings.defaults.toJson();
      for (final bad in <Map<String, Object?>>[
        {...base(), 'version': 2},
        {...base(), 'audio': 'speaker'},
        {...base(), 'scale': 133},
        {...base(), 'clipboard_files': 'yes'},
        {
          ...base(),
          'drives': [
            {'name': '../x', 'path': r'C:\x'},
          ],
        },
        {
          ...base(),
          'drives': [
            {'name': 'X', 'path': r'C:\data\..\Windows'},
          ],
        },
        {
          ...base(),
          'drives': [
            {'name': 'X', 'path': 'relative\\dir'},
          ],
        },
        {
          ...base(),
          'drives': [
            {'name': 'X', 'path': 'C:\\a|b'},
          ],
        },
        {
          ...base(),
          'drives': [
            {'name': 'A', 'path': r'C:\a'},
            {'name': 'a', 'path': r'C:\b'},
          ],
        },
        {
          ...base(),
          'usb_devices': ['046d:c52'],
        },
        {
          ...base(),
          'usb_devices': ['046d:c52b', '046d:c52b'],
        },
        {...base(), 'monitors': [-1]},
      ]) {
        expect(() => RdpSettings.fromJson(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('a corrupt or newer entry falls back to defaults and is flagged', () {
      final host = _rdp.copyWith(
        manifest: {
          rdpSettingsManifestKey: {'version': 9, 'cameras': true},
        },
      );
      expect(RdpSettings.of(host), RdpSettings.defaults);
      expect(RdpSettings.unreadable(host), isTrue);
      expect(RdpSettings.unreadable(_rdp), isFalse);
    });
  });

  group('native config', () {
    test('omits and reports resources the engine cannot provide', () {
      const settings = RdpSettings(
        drives: [RdpDriveRedirect(name: 'Work', path: '/srv/work')],
        microphone: true,
        cameras: true,
        clipboardFiles: true,
        usbDevices: ['1234:abcd'],
      );
      const features = RdpFeatures(
        RdpFeatures.configV1 | RdpFeatures.drive | RdpFeatures.fileClipboard,
      );
      final config = settings.toNativeConfig(
        features: features,
        initialWidth: 1000,
        initialHeight: 700,
      );
      expect(config.text, contains('\ndrive=Work|/srv/work\n'));
      expect(config.text, contains('\nclipboard_files=1\n'));
      expect(config.text, contains('\ncameras=0\n'));
      expect(config.text, contains('\nmicrophone=0\n'));
      expect(config.text, contains('\naudio=2\n'));
      expect(config.text, isNot(contains('usb=')));
      expect(
        config.unavailable,
        containsAll(['audio playback', 'microphone', 'cameras', 'USB devices']),
      );
    });

    test('engine without config support reports everything as unavailable', () {
      const settings = RdpSettings(smartCards: true);
      final config = settings.toNativeConfig(
        features: const RdpFeatures(RdpFeatures.smartcard),
        initialWidth: 1280,
        initialHeight: 800,
      );
      expect(config.unavailable, contains('smart cards'));
    });

    test('multi-monitor layout is normalized to the primary origin', () {
      const settings = RdpSettings(multiMonitor: true);
      final config = settings.toNativeConfig(
        features: _all,
        initialWidth: 1280,
        initialHeight: 800,
        monitorLayout: const [
          RdpMonitorLayout(x: -1920, y: 0, width: 1920, height: 1080, primary: false),
          RdpMonitorLayout(x: 0, y: 0, width: 2560, height: 1440, primary: true),
        ],
      );
      expect(config.text, contains('\ndynamic_resolution=0\n'));
      expect(config.text, contains('\nmonitor=-1920|0|1920|1080|0\n'));
      expect(config.text, contains('\nmonitor=0|0|2560|1440|1\n'));
      expect(config.monitors, hasLength(2));
      expect(
        () => RdpMonitorLayout.normalize(const [
          RdpMonitorLayout(x: 0, y: 0, width: 8192, height: 800, primary: true),
          RdpMonitorLayout(x: 30000, y: 0, width: 8192, height: 800, primary: false),
        ]),
        throwsFormatException,
      );
    });

    test('default printer requires a safe local name', () {
      const settings = RdpSettings(printers: RdpPrinterMode.defaultPrinter);
      final ok = settings.toNativeConfig(
        features: _all,
        initialWidth: 1280,
        initialHeight: 800,
        defaultPrinterName: 'Office HP',
      );
      expect(ok.text, contains('\nprinters=1\nprinter_name=Office HP\n'));
      final bad = settings.toNativeConfig(
        features: _all,
        initialWidth: 1280,
        initialHeight: 800,
        defaultPrinterName: 'evil\nusb=1234:5678',
      );
      expect(bad.text, contains('\nprinters=0\n'));
      expect(bad.text, isNot(contains('usb=')));
      expect(bad.unavailable, contains('default printer'));
    });
  });

  group('clipboard file list', () {
    test('round-trips descriptors including nested folders and sizes', () {
      final when = DateTime.utc(2026, 11, 7, 12);
      final entries = [
        ClipboardFileEntry(relativePath: 'dir', isDirectory: true, size: 0),
        ClipboardFileEntry(
          relativePath: 'dir\\报告.txt',
          isDirectory: false,
          size: 5000000000,
          modified: when,
        ),
      ];
      final decoded = decodeFileList(encodeFileList(entries));
      expect(decoded.map((e) => e.relativePath), ['dir', 'dir\\报告.txt']);
      expect(decoded[0].isDirectory, isTrue);
      expect(decoded[1].size, 5000000000);
      expect(decoded[1].modified, when);
    });

    test('rejects hostile remote names as a whole list', () {
      Uint8List listWith(String name) {
        final good = encodeFileList([
          ClipboardFileEntry(relativePath: 'x', isDirectory: false, size: 1),
        ]);
        final data = ByteData.sublistView(good);
        for (var i = 0; i < 260; i++) {
          data.setUint16(4 + 72 + i * 2, i < name.length ? name.codeUnitAt(i) : 0, Endian.little);
        }
        return good;
      }

      for (final name in [
        '..\\evil',
        'a\\..\\b',
        'C:\\Windows\\x',
        '\\\\server\\share',
        'CON',
        'nul.txt',
        'a/b',
        'trailing.',
        'bad\u0001name',
        'x:stream',
      ]) {
        expect(() => decodeFileList(listWith(name)), throwsFormatException, reason: name);
      }
      expect(() => decodeFileList(Uint8List(3)), throwsFormatException);
      expect(() => decodeFileList(Uint8List(4 + 591)), throwsFormatException);
    });
  });

  group('file transfer', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('rdp-files-'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('offer → download reproduces files without overwriting', () async {
      final src = Directory(p.join(temp.path, 'src', 'Project'))..createSync(recursive: true);
      File(p.join(src.path, 'a.bin')).writeAsBytesSync(List.generate(3 * 1024 * 1024 + 7, (i) => i % 251));
      Directory(p.join(src.path, 'sub')).createSync();
      File(p.join(src.path, 'sub', 'b.txt')).writeAsStringSync('hello');
      File(p.join(src.path, 'link-target')).writeAsStringSync('t');
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      Directory(p.join(out.path, 'Project')).createSync(); // existing name

      final offer = LocalFileOffer.build([src.path]);
      expect(offer.entries.map((e) => e.relativePath), contains('Project\\sub\\b.txt'));
      final remote = decodeFileList(offer.encode());
      late RemoteFileDownload job;
      job = RemoteFileDownload(
        entries: remote,
        target: out.path,
        request: (stream, index, flags, position, size) {
          scheduleMicrotask(() {
            final data = offer.serve(index, flags, position, size);
            job.onData(stream, data != null, data ?? Uint8List(0));
          });
          return true;
        },
      );
      final saved = await job.start();
      offer.close();
      expect(saved, [p.join(out.path, 'Project (2)')]);
      expect(
        File(p.join(out.path, 'Project (2)', 'a.bin')).readAsBytesSync(),
        File(p.join(src.path, 'a.bin')).readAsBytesSync(),
      );
      expect(File(p.join(out.path, 'Project (2)', 'sub', 'b.txt')).readAsStringSync(), 'hello');
      expect(out.listSync(recursive: true).where((e) => e.path.endsWith('.atermius-partial')), isEmpty);
    });

    test('a server sending more than the declared size fails and cleans up', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      late RemoteFileDownload job;
      job = RemoteFileDownload(
        entries: [ClipboardFileEntry(relativePath: 'f.txt', isDirectory: false, size: 4)],
        target: out.path,
        request: (stream, index, flags, position, size) {
          scheduleMicrotask(() {
            if (flags == fileContentsSize) {
              job.onData(stream, true, (ByteData(8)..setUint64(0, 4, Endian.little)).buffer.asUint8List());
            } else {
              job.onData(stream, true, Uint8List(64));
            }
          });
          return true;
        },
      );
      await expectLater(job.start(), throwsFormatException);
      expect(out.listSync(), isEmpty);
    });

    // Serves sizes/ranges from in-memory contents; [onRequest] can interfere.
    RemoteFileDownload fakeDownload(
      Directory out,
      Map<String, List<int>> files, {
      void Function(int count, RemoteFileDownload job)? onRequest,
    }) {
      final entries = [
        for (final name in files.keys)
          ClipboardFileEntry(relativePath: name, isDirectory: false, size: files[name]!.length),
      ];
      late RemoteFileDownload job;
      var count = 0;
      job = RemoteFileDownload(
        entries: entries,
        target: out.path,
        request: (stream, index, flags, position, size) {
          scheduleMicrotask(() {
            onRequest?.call(++count, job);
            final data = files.values.elementAt(index);
            job.onData(
              stream,
              true,
              flags == fileContentsSize
                  ? (ByteData(8)..setUint64(0, data.length, Endian.little)).buffer.asUint8List()
                  : Uint8List.fromList(data.sublist(position, (position + size).clamp(0, data.length))),
            );
          });
          return true;
        },
      );
      return job;
    }

    test('pre-existing partial-looking user files are never opened or deleted', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      final userPartial = File(p.join(out.path, 'f.txt.atermius-partial'))..writeAsStringSync('mine');
      final userHidden = File(p.join(out.path, '.f.txt.atermius-partial'))..writeAsStringSync('mine too');
      final saved = await fakeDownload(out, {'f.txt': 'remote'.codeUnits}).start();
      expect(saved, [p.join(out.path, 'f.txt')]);
      expect(File(p.join(out.path, 'f.txt')).readAsStringSync(), 'remote');
      expect(userPartial.readAsStringSync(), 'mine');
      expect(userHidden.readAsStringSync(), 'mine too');
      // And on cancellation they still survive.
      final job = fakeDownload(
        out,
        {'f.txt': List.filled(3 * downloadChunk, 7)},
        onRequest: (n, job) {
          if (n == 2) job.cancel();
        },
      );
      await expectLater(job.start(), throwsA(isA<FileSystemException>()));
      expect(userPartial.readAsStringSync(), 'mine');
      expect(userHidden.readAsStringSync(), 'mine too');
      expect(File(p.join(out.path, 'f.txt')).readAsStringSync(), 'remote');
      expect(
        out.listSync().map((e) => p.basename(e.path)).toSet(),
        {'f.txt', 'f.txt.atermius-partial', '.f.txt.atermius-partial'},
      );
    });

    test('cancel removes only entries this download created', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      File(p.join(out.path, 'keep.txt')).writeAsStringSync('keep');
      Directory(p.join(out.path, 'Project')).createSync();
      File(p.join(out.path, 'Project', 'old.txt')).writeAsStringSync('old');
      final entries = [
        ClipboardFileEntry(relativePath: 'Project', isDirectory: true, size: 0),
        ClipboardFileEntry(relativePath: 'Project\\a.txt', isDirectory: false, size: 3),
        ClipboardFileEntry(relativePath: 'Project\\big.bin', isDirectory: false, size: 3 * downloadChunk),
      ];
      final data = [<int>[], 'abc'.codeUnits, List.filled(3 * downloadChunk, 1)];
      late RemoteFileDownload job;
      var ranges = 0;
      job = RemoteFileDownload(
        entries: entries,
        target: out.path,
        request: (stream, index, flags, position, size) {
          scheduleMicrotask(() {
            if (flags == fileContentsRange && index == 2 && ++ranges == 2) {
              job.cancel();
              return;
            }
            final d = data[index];
            job.onData(
              stream,
              true,
              flags == fileContentsSize
                  ? (ByteData(8)..setUint64(0, d.length, Endian.little)).buffer.asUint8List()
                  : Uint8List.fromList(d.sublist(position, (position + size).clamp(0, d.length))),
            );
          });
          return true;
        },
      );
      await expectLater(job.start(), throwsA(isA<FileSystemException>()));
      expect(File(p.join(out.path, 'keep.txt')).readAsStringSync(), 'keep');
      expect(File(p.join(out.path, 'Project', 'old.txt')).readAsStringSync(), 'old');
      expect(Directory(p.join(out.path, 'Project (2)')).existsSync(), isFalse);
      expect(out.listSync().map((e) => p.basename(e.path)).toSet(), {'keep.txt', 'Project'});
    });

    test('a symlink planted at the reserved name is not followed or deleted', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      final outside = File(p.join(temp.path, 'outside.txt'))..writeAsStringSync('secret');
      final job = fakeDownload(
        out,
        {'f.txt': 'remote-data'.codeUnits},
        onRequest: (n, job) {
          if (n == 1) {
            // Race: replace our reserved placeholder with a link to a victim.
            final reserved = p.join(out.path, 'f.txt');
            File(reserved).deleteSync();
            Link(reserved).createSync(outside.path);
          }
        },
      );
      await expectLater(job.start(), throwsA(isA<FileSystemException>()));
      expect(outside.readAsStringSync(), 'secret');
      expect(FileSystemEntity.typeSync(p.join(out.path, 'f.txt'), followLinks: false),
          FileSystemEntityType.link);
      expect(out.listSync().where((e) => e.path.endsWith('.atermius-partial')), isEmpty);
    }, skip: Platform.isWindows ? 'symlinks need privileges on Windows' : false);

    test('an existing symlink at a remote name gets a unique name instead', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      final outside = File(p.join(temp.path, 'outside.txt'))..writeAsStringSync('secret');
      Link(p.join(out.path, 'f.txt')).createSync(outside.path);
      final saved = await fakeDownload(out, {'f.txt': 'remote'.codeUnits}).start();
      expect(saved, [p.join(out.path, 'f (2).txt')]);
      expect(outside.readAsStringSync(), 'secret');
    }, skip: Platform.isWindows ? 'symlinks need privileges on Windows' : false);

    test('a FILECONTENTS_SIZE larger than the descriptor is rejected before any data', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      final requests = <int>[];
      late RemoteFileDownload job;
      job = RemoteFileDownload(
        entries: [ClipboardFileEntry(relativePath: 'tiny.txt', isDirectory: false, size: 1)],
        target: out.path,
        request: (stream, index, flags, position, size) {
          requests.add(flags);
          scheduleMicrotask(() => job.onData(
                stream,
                true,
                (ByteData(8)..setUint64(0, 1 << 50, Endian.little)).buffer.asUint8List(), // 1 PiB
              ));
          return true;
        },
      );
      await expectLater(job.start(), throwsFormatException);
      expect(requests, [fileContentsSize]); // never asked for a range
      expect(out.listSync(), isEmpty);
    });

    test('undeclared sizes get a strict cap; oversized lists are refused up front', () async {
      final out = Directory(p.join(temp.path, 'out'))..createSync();
      late RemoteFileDownload job;
      job = RemoteFileDownload(
        entries: [
          ClipboardFileEntry(relativePath: 'u.bin', isDirectory: false, size: 0, sizeKnown: false),
        ],
        target: out.path,
        request: (stream, index, flags, position, size) {
          scheduleMicrotask(() => job.onData(
                stream,
                true,
                (ByteData(8)..setUint64(0, maxUndeclaredFileBytes + 1, Endian.little))
                    .buffer
                    .asUint8List(),
              ));
          return true;
        },
      );
      await expectLater(job.start(), throwsFormatException);
      var asked = false;
      final huge = RemoteFileDownload(
        entries: [
          ClipboardFileEntry(relativePath: 'h.bin', isDirectory: false, size: maxDownloadFileBytes + 1),
        ],
        target: out.path,
        request: (_, _, _, _, _) => asked = true,
      );
      await expectLater(huge.start(), throwsA(isA<FileSystemException>()));
      expect(asked, isFalse);
      expect(out.listSync(), isEmpty);
      // Omitted FD_FILESIZE decodes as an undeclared size.
      final list = encodeFileList([
        ClipboardFileEntry(relativePath: 'x', isDirectory: false, size: 5),
      ]);
      final flags = ByteData.sublistView(list).getUint32(4, Endian.little);
      ByteData.sublistView(list).setUint32(4, flags & ~0x40, Endian.little);
      expect(decodeFileList(list).single.sizeKnown, isFalse);
    });

    test('offer serves only listed regular files', () {
      final file = File(p.join(temp.path, 'x.txt'))..writeAsStringSync('abc');
      final offer = LocalFileOffer.build([file.path]);
      expect(offer.serve(0, fileContentsSize, 0, 8), isNotNull);
      expect(offer.serve(0, fileContentsRange, 1, 10), Uint8List.fromList('bc'.codeUnits));
      expect(offer.serve(1, fileContentsRange, 0, 1), isNull);
      expect(offer.serve(0, 7, 0, 1), isNull);
      offer.close();
      expect(() => LocalFileOffer.build([p.join(temp.path, 'missing')]), throwsFormatException);
    });
  });

  group('editor', () {
    testWidgets('switches without a backend are disabled and labeled', (tester) async {
      RdpSettings? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RdpSettingsEditor(
                initial: const RdpSettings(cameras: true),
                features: const RdpFeatures(
                  RdpFeatures.configV1 | RdpFeatures.fileClipboard,
                ),
                onChanged: (v) => changed = v,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('RDP options'));
      await tester.pumpAndSettle();
      final camera = tester.widget<SwitchListTile>(find.byKey(const ValueKey('host_rdp_cameras')));
      expect(camera.onChanged, isNull);
      expect(camera.value, isFalse);
      expect(find.text('Not available in this RDP engine build'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('host_rdp_clipboard_files')));
      await tester.pump();
      expect(changed?.clipboardFiles, isTrue);
    });

    testWidgets('host editor saves RDP options into the Host manifest', (tester) async {
      HostRecord? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showHostEditorPanel(
                  context,
                  groups: const [],
                  hosts: const [],
                  existing: _rdp.copyWith(
                    manifest: const RdpSettings(clipboardText: false).applyTo({'keep': 1}),
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('RDP options'), findsOneWidget);
      await tester.tap(find.text('Save encrypted host'));
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(saved!.manifest!['keep'], 1);
      expect(RdpSettings.of(saved!).clipboardText, isFalse);
    });
  });
}
