import 'dart:io';
import 'dart:convert';
import 'package:aterm_client/attachments/attachment_file_saver.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'temporary writer leaves target untouched until verified commit',
    () async {
      if (!supportsStreamingAttachmentSave) return;
      final directory = await Directory.systemTemp.createTemp(
        'atermius-stream-save-',
      );
      final support = Directory('${directory.path}/app-support')
        ..createSync(recursive: true);
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (call) async => support.path,
          );
      final staging = Directory(
        '${support.path}${Platform.pathSeparator}atermius-attachment-staging',
      )..createSync(recursive: true);
      final staleFile = File(
        '${staging.path}${Platform.pathSeparator}crashed.partial',
      )..writeAsStringSync('stale decrypted bytes');
      final staleFileCreatedWhileOpen = File(
        '${staging.path}${Platform.pathSeparator}crashed-during-open.partial',
      );
      final target = File('${directory.path}/selected.bin');
      await target.writeAsString('previous file');
      final picker = _SavePicker(target.path);
      FilePicker? originalPicker;
      try {
        try {
          originalPicker = FilePicker.platform;
        } on Object {
          // The plugin is not registered in a standalone unit test.
        }
        FilePicker.platform = picker;
        final writer = await openAttachmentStreamingSave(
          fileName: 'selected.bin',
          mediaType: 'application/octet-stream',
        );
        expect(writer, isNotNull);
        await writer!.write(Uint8List.fromList([1, 3, 5]));
        await writer.write(Uint8List.fromList([7, 9]));
        expect(await target.readAsString(), 'previous file');
        expect(await staleFile.exists(), isFalse);
        staleFileCreatedWhileOpen.writeAsStringSync('stale bytes');
        final secondWriter = await openAttachmentStreamingSave(
          fileName: 'selected.bin',
          mediaType: 'application/octet-stream',
        );
        expect(secondWriter, isNotNull);
        expect(await staleFileCreatedWhileOpen.exists(), isFalse);
        final stagingFiles = staging
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.partial'))
            .toList();
        expect(stagingFiles, hasLength(2));
        expect((await staging.stat()).mode & 0x1ff, 0x1c0);
        for (final stagingFile in stagingFiles) {
          expect((await stagingFile.stat()).mode & 0x1ff, 0x180);
        }
        await secondWriter!.abort();
        expect(
          staging.listSync().whereType<File>().where(
            (file) => file.path.endsWith('.partial'),
          ),
          hasLength(1),
        );
        await writer.commit();
        expect(await target.readAsBytes(), [1, 3, 5, 7, 9]);
        expect(
          directory.listSync().where(
            (entity) => entity.path.contains('.partial'),
          ),
          isEmpty,
        );
        await expectLater(
          writer.write(Uint8List.fromList([0])),
          throwsA(isA<StateError>()),
        );
      } finally {
        if (originalPicker != null) FilePicker.platform = originalPicker;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        await directory.delete(recursive: true);
      }
    },
  );

  test('abort removes temporary bytes and preserves chosen file', () async {
    if (!supportsStreamingAttachmentSave) return;
    final directory = await Directory.systemTemp.createTemp(
      'atermius-stream-abort-',
    );
    final support = Directory('${directory.path}/app-support')
      ..createSync(recursive: true);
    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (call) async => support.path,
        );
    final target = File('${directory.path}/selected.bin');
    await target.writeAsString('keep this');
    final picker = _SavePicker(target.path);
    FilePicker? originalPicker;
    try {
      try {
        originalPicker = FilePicker.platform;
      } on Object {
        // The plugin is not registered in a standalone unit test.
      }
      FilePicker.platform = picker;
      final writer = await openAttachmentStreamingSave(
        fileName: 'selected.bin',
        mediaType: 'application/octet-stream',
      );
      await writer!.write(Uint8List.fromList([2, 4, 6]));
      await writer.abort();
      expect(await target.readAsString(), 'keep this');
      expect(
        directory.listSync().where(
          (entity) => entity.path.contains('.partial'),
        ),
        isEmpty,
      );
    } finally {
      if (originalPicker != null) FilePicker.platform = originalPicker;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      await directory.delete(recursive: true);
    }
  });

  test(
    'staging sweep skips a live cross-process writer without waiting',
    () async {
      if (!supportsStreamingAttachmentSave) return;
      final directory = await Directory.systemTemp.createTemp(
        'atermius-stream-lock-',
      );
      final support = Directory('${directory.path}/app-support')
        ..createSync(recursive: true);
      const pathProviderChannel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathProviderChannel,
            (call) async => support.path,
          );
      final staging = Directory(
        '${support.path}${Platform.pathSeparator}atermius-attachment-staging',
      )..createSync(recursive: true);
      final liveFile = File(
        '${staging.path}${Platform.pathSeparator}live.partial',
      )..writeAsStringSync('active decrypted bytes');
      final liveLock = File('${liveFile.path}.lock')..createSync();
      final staleFile = File(
        '${staging.path}${Platform.pathSeparator}crashed.partial',
      )..writeAsStringSync('stale decrypted bytes');
      final script = File('${directory.path}/hold_lock.dart')
        ..writeAsStringSync('''
import 'dart:io';

Future<void> main(List<String> args) async {
  final lockFile = await File(args.single).open(mode: FileMode.append);
  await lockFile.lock(FileLock.blockingExclusive);
  stdout.writeln('locked');
  await stdout.flush();
  await stdin.first;
  await lockFile.unlock();
  await lockFile.close();
}
''');
      final target = File('${directory.path}/selected.bin');
      final picker = _SavePicker(target.path);
      FilePicker? originalPicker;
      Process? lockOwner;
      try {
        try {
          originalPicker = FilePicker.platform;
        } on Object {
          // The plugin is not registered in a standalone unit test.
        }
        FilePicker.platform = picker;
        final dart = await _findDartExecutable();
        lockOwner = await Process.start(dart.path, [
          script.path,
          liveLock.path,
        ]);
        final ready = lockOwner.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 5));
        expect(await ready, 'locked');

        final writer = await openAttachmentStreamingSave(
          fileName: 'selected.bin',
          mediaType: 'application/octet-stream',
        );
        expect(writer, isNotNull);
        expect(await liveFile.readAsString(), 'active decrypted bytes');
        expect(await staleFile.exists(), isFalse);
        await writer!.abort();

        lockOwner.stdin.writeln('release');
        await lockOwner.stdin.flush();
        await lockOwner.exitCode.timeout(const Duration(seconds: 5));
        lockOwner = null;

        final cleanupWriter = await openAttachmentStreamingSave(
          fileName: 'selected.bin',
          mediaType: 'application/octet-stream',
        );
        expect(await liveFile.exists(), isFalse);
        await cleanupWriter!.abort();
      } finally {
        if (lockOwner != null) {
          lockOwner.kill();
          await lockOwner.exitCode;
        }
        if (originalPicker != null) FilePicker.platform = originalPicker;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, null);
        await directory.delete(recursive: true);
      }
    },
  );
}

Future<File> _findDartExecutable() async {
  final executable = File(Platform.resolvedExecutable);
  if (executable.uri.pathSegments.last == 'dart' ||
      executable.uri.pathSegments.last == 'dart.exe') {
    return executable;
  }
  var directory = executable.parent;
  for (var depth = 0; depth < 10; depth++) {
    final candidates = [
      File(
        '${directory.path}${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart',
      ),
      File(
        '${directory.path}${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart.exe',
      ),
    ];
    for (final candidate in candidates) {
      if (await candidate.exists()) return candidate;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Could not locate the Dart executable for the lock test.');
}

class _SavePicker extends FilePicker {
  _SavePicker(this.path);

  final String path;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}
