import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/attachments/attachment_upload_source.dart';
import 'package:aterm_client/attachments/attachment_file_saver.dart';
import 'package:aterm_client/attachments/host_attachment_service.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_attachments_dialog.dart';
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _hostId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _blobId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dialog lists attachment metadata and confirms removal', (
    tester,
  ) async {
    final (app, database) = await _createController();
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'deploy-notes.txt',
        mediaType: 'text/plain',
        totalSize: 2048,
      ),
    ];
    try {
      await _openDialog(tester, app);
      expect(find.text('deploy-notes.txt'), findsOneWidget);
      expect(find.text('text/plain · 2.0 KB'), findsOneWidget);
      expect(find.text('Attach file'), findsOneWidget);
      expect(find.byTooltip('Download attachment'), findsOneWidget);
      expect(find.byTooltip('Remove attachment'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      expect(find.text('Remove attachment from this host?'), findsOneWidget);
      expect(
        find.textContaining('Earlier host revisions may retain'),
        findsOneWidget,
      );
      await tester.tap(find.text('Remove from host'));
      await tester.pumpAndSettle();
      expect(app.removedBlobId, _blobId);
      expect(find.text('No attachments saved for this host.'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('dialog shows encrypted manifest errors without hiding them', (
    tester,
  ) async {
    final (app, database) = await _createController();
    app.failList = true;
    try {
      await _openDialog(tester, app);
      expect(
        find.textContaining('Attachment manifest rejected.'),
        findsOneWidget,
      );
      expect(find.text('Attach file'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('persistent failed uploads expose a retry action', (
    tester,
  ) async {
    final (app, database) = await _createController();
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'deploy-notes.txt',
        mediaType: 'text/plain',
        totalSize: 2048,
      ),
    ];
    app.transfers = [
      const HostAttachmentTransferSummary(
        blobId: _blobId,
        direction: 'upload',
        state: 'failed',
        completedObjects: 0,
        totalObjects: 1,
        transferredBytes: 17,
        totalBytes: 2048,
        canResume: true,
      ),
    ];
    try {
      await _openDialog(tester, app);
      expect(find.text('failed · 1% · 17 B / 2.0 KB'), findsOneWidget);
      await tester.tap(find.byTooltip('Resume upload'));
      await tester.pumpAndSettle();
      expect(app.resumedBlobId, _blobId);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('failed downloads expose discard when no attachment is listed', (
    tester,
  ) async {
    final (app, database) = await _createController();
    app.transfers = [
      const HostAttachmentTransferSummary(
        blobId: _blobId,
        direction: 'download',
        state: 'failed',
        completedObjects: 0,
        totalObjects: 1,
        transferredBytes: 1024,
        totalBytes: 4096,
        canResume: true,
      ),
    ];
    try {
      await _openDialog(tester, app);
      expect(find.byTooltip('Discard downloaded copy'), findsOneWidget);
      await tester.tap(find.byTooltip('Discard downloaded copy'));
      await tester.pumpAndSettle();
      expect(app.discardedDownloadBlobId, _blobId);
      expect(find.text('Transfer tasks'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('viewer can download but has no attach or remove controls', (
    tester,
  ) async {
    final (app, database) = await _createController(canWrite: false);
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'deploy-notes',
        mediaType: 'text/plain',
        totalSize: 3,
      ),
    ];
    app.downloadBytes = Uint8List.fromList([1, 2, 3]);
    final picker = _RecordingFilePicker();
    FilePicker? originalPicker;
    try {
      try {
        originalPicker = FilePicker.platform;
      } catch (_) {
        // Some Flutter test bindings do not register a native picker plugin.
      }
      FilePicker.platform = picker;

      await _openDialog(tester, app);
      expect(find.text('Attach file'), findsNothing);
      expect(find.byTooltip('Remove attachment'), findsNothing);
      expect(find.byTooltip('Download attachment'), findsOneWidget);

      await tester.tap(find.byTooltip('Download attachment'));
      await tester.pumpAndSettle();
      expect(app.downloadedBlobId, _blobId);
      expect(picker.savedFileName, 'deploy-notes');
      expect(picker.savedBytes, [1, 2, 3]);
      expect(find.byTooltip('Download attachment'), findsOneWidget);
    } finally {
      if (originalPicker != null) FilePicker.platform = originalPicker;
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('large attachment availability follows platform save support', (
    tester,
  ) async {
    final (app, database) = await _createController(canWrite: false);
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'large-v2.bin',
        mediaType: 'application/octet-stream',
        totalSize: 256 * 1024 * 1024 + 1,
        formatVersion: 2,
      ),
    ];
    try {
      await _openDialog(tester, app);
      final disabledDownload = tester
          .widgetList<IconButton>(find.byType(IconButton))
          .single;
      if (maxAttachmentBytesForPlatform >= 256 * 1024 * 1024 + 1) {
        expect(find.byTooltip('Download attachment'), findsOneWidget);
        expect(disabledDownload.onPressed, isNotNull);
      } else {
        expect(
          find.textContaining('download unavailable above'),
          findsOneWidget,
        );
        expect(disabledDownload.onPressed, isNull);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('streaming save picker cancellation prevents network work', (
    tester,
  ) async {
    if (!supportsStreamingAttachmentSave) return;
    final (app, database) = await _createController(canWrite: false);
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'large-v2.bin',
        mediaType: 'application/octet-stream',
        totalSize: 256 * 1024 * 1024 + 1,
        formatVersion: 2,
      ),
    ];
    final picker = _RecordingFilePicker(savePath: null);
    FilePicker? originalPicker;
    try {
      originalPicker = FilePicker.platform;
      FilePicker.platform = picker;
      await _openDialog(tester, app);
      await tester.tap(find.byTooltip('Download attachment'));
      await tester.pumpAndSettle();
      expect(picker.savedFileName, 'large-v2.bin');
      expect(app.streamedDownloadBlobId, isNull);
      expect(app.completedBlobId, isNull);
      expect(find.text('Save cancelled.'), findsOneWidget);
    } finally {
      if (originalPicker != null) FilePicker.platform = originalPicker;
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('streaming download commits an injected writer after success', (
    tester,
  ) async {
    if (!supportsStreamingAttachmentSave) return;
    final (app, database) = await _createController(canWrite: false);
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'large-v2.bin',
        mediaType: 'application/octet-stream',
        totalSize: 256 * 1024 * 1024 + 1,
        formatVersion: 2,
      ),
    ];
    app.streamedBytes = Uint8List.fromList([1, 4, 7]);
    final writer = _FakeStreamingSaveWriter();
    var pickerOpened = false;
    try {
      await _openDialog(
        tester,
        app,
        streamingSaveOpener: ({required fileName, required mediaType}) {
          pickerOpened = true;
          app.streamingEvents.add('picker');
          return Future.value(writer);
        },
      );
      await tester.tap(find.byTooltip('Download attachment'));
      await tester.pumpAndSettle();

      expect(pickerOpened, isTrue);
      expect(app.streamingEvents, ['picker', 'network']);
      expect(app.streamedDownloadBlobId, _blobId);
      expect(writer.chunks, [
        [1, 4, 7],
      ]);
      expect(writer.committed, isTrue);
      expect(writer.abortCalls, 0);
      expect(app.completedBlobId, _blobId);
      expect(find.byTooltip('Download attachment'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('a throwing writer abort preserves the download error', (
    tester,
  ) async {
    if (!supportsStreamingAttachmentSave) return;
    final (app, database) = await _createController(canWrite: false);
    app.attachments = [
      const HostAttachmentSummary(
        blobId: _blobId,
        fileName: 'large-v2.bin',
        mediaType: 'application/octet-stream',
        totalSize: 256 * 1024 * 1024 + 1,
        formatVersion: 2,
      ),
    ];
    app.streamedBytes = Uint8List.fromList([1, 4, 7]);
    app.streamedDownloadFails = true;
    final writer = _FakeStreamingSaveWriter(throwOnAbort: true);
    try {
      await _openDialog(
        tester,
        app,
        streamingSaveOpener: ({required fileName, required mediaType}) =>
            Future.value(writer),
      );
      await tester.tap(find.byTooltip('Download attachment'));
      await tester.pumpAndSettle();

      expect(writer.committed, isFalse);
      expect(writer.abortCalls, 2);
      expect(app.completedBlobId, isNull);
      expect(find.textContaining('injected streamed failure'), findsOneWidget);
      expect(find.byTooltip('Download attachment'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('attachment picker uses a bounded read stream', (tester) async {
    final (app, database) = await _createController();
    final expectedBytes = Uint8List.fromList(
      List<int>.generate(128 * 1024 + 19, (index) => index & 0xff),
    );
    final picker = _RecordingFilePicker(
      pickedResult: FilePickerResult([
        PlatformFile(
          name: 'streamed.bin',
          size: expectedBytes.length,
          readStream: Stream<List<int>>.fromIterable([
            Uint8List.fromList(expectedBytes.sublist(0, 17 * 1024)),
            Uint8List.fromList(expectedBytes.sublist(17 * 1024)),
          ]),
        ),
      ]),
    );
    FilePicker? originalPicker;
    try {
      try {
        originalPicker = FilePicker.platform;
      } catch (_) {
        // Some Flutter test bindings do not register a native picker plugin.
      }
      FilePicker.platform = picker;
      await _openDialog(tester, app);
      await tester.tap(find.text('Attach file'));
      await tester.pumpAndSettle();

      expect(picker.lastWithData, isFalse);
      expect(picker.lastWithReadStream, isTrue);
      expect(app.uploadedFileName, 'streamed.bin');
      expect(app.uploadedSourceSize, expectedBytes.length);
      expect(app.uploadedSourceChunkSizes, [
        17 * 1024,
        expectedBytes.length - 17 * 1024,
      ]);
      expect(app.uploadedPlaintext, expectedBytes);
    } finally {
      if (originalPicker != null) FilePicker.platform = originalPicker;
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });
}

Future<void> _openDialog(
  WidgetTester tester,
  _AttachmentController app, {
  AttachmentStreamingSaveOpener? streamingSaveOpener,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => showHostAttachmentsDialog(
                context,
                app: app,
                host: app.testHost,
                streamingSaveOpener: streamingSaveOpener,
              ),
              child: const Text('Open attachments'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open attachments'));
  await tester.pumpAndSettle();
}

Future<(_AttachmentController, ClientDatabase)> _createController({
  bool canWrite = true,
}) async {
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      _AttachmentController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.hosts
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        )
        ..hosts.add(_host);
  return (app, database);
}

const _host = HostRecord(
  id: _hostId,
  name: 'Production',
  address: 'host.example.test',
  username: 'deploy',
);

class _AttachmentController extends AppController {
  _AttachmentController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  HostRecord get testHost => hosts.single;

  List<HostAttachmentSummary> attachments = [];
  List<HostAttachmentTransferSummary> transfers = [];
  bool failList = false;
  String? removedBlobId;
  String? downloadedBlobId;
  String? resumedBlobId;
  String? discardedDownloadBlobId;
  String? streamedDownloadBlobId;
  String? completedBlobId;
  Uint8List streamedBytes = Uint8List(0);
  bool streamedDownloadFails = false;
  List<String> streamingEvents = [];
  Uint8List downloadBytes = Uint8List(0);
  String? uploadedFileName;
  int? uploadedSourceSize;
  List<int> uploadedSourceChunkSizes = const [];
  Uint8List? uploadedPlaintext;

  @override
  List<HostAttachmentSummary> hostAttachments(String hostId) {
    if (failList) throw const FormatException('Attachment manifest rejected.');
    return attachments;
  }

  @override
  Future<List<HostAttachmentTransferSummary>> hostAttachmentTransfers(
    String hostId,
  ) async => transfers;

  @override
  Future<void> resumeHostAttachmentUpload({
    required String hostId,
    required String blobId,
  }) async {
    resumedBlobId = blobId;
  }

  @override
  Future<void> addHostAttachmentFromSource({
    required String hostId,
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
  }) async {
    uploadedFileName = fileName;
    uploadedSourceSize = source.size;
    final sourceChunks = <int>[];
    final output = BytesBuilder(copy: true);
    await for (final chunk in source.openRead()) {
      sourceChunks.add(chunk.length);
      output.add(chunk);
      source.releaseReadChunk(chunk);
    }
    uploadedSourceChunkSizes = sourceChunks;
    uploadedPlaintext = output.takeBytes();
  }

  @override
  Future<void> completeHostAttachmentDownload({
    required String hostId,
    required String blobId,
  }) async {
    completedBlobId = blobId;
  }

  @override
  Future<void> downloadHostAttachmentToSink({
    required String hostId,
    required String blobId,
    required Future<void> Function(Uint8List plaintextChunk) onPlaintextChunk,
  }) async {
    streamingEvents.add('network');
    streamedDownloadBlobId = blobId;
    await onPlaintextChunk(Uint8List.fromList(streamedBytes));
    if (streamedDownloadFails) {
      throw StateError('injected streamed failure');
    }
  }

  @override
  Future<void> discardHostAttachmentDownload({
    required String hostId,
    required String blobId,
  }) async {
    discardedDownloadBlobId = blobId;
    transfers = transfers
        .where((item) => item.blobId != blobId)
        .toList(growable: false);
  }

  @override
  Future<void> removeHostAttachment({
    required String hostId,
    required String blobId,
  }) async {
    removedBlobId = blobId;
    attachments = attachments
        .where((attachment) => attachment.blobId != blobId)
        .toList(growable: false);
  }

  @override
  Future<Uint8List> downloadHostAttachment({
    required String hostId,
    required String blobId,
  }) async {
    downloadedBlobId = blobId;
    return Uint8List.fromList(downloadBytes);
  }

  @override
  String friendlyError(Object error) => error.toString();
}

class _FakeStreamingSaveWriter implements AttachmentStreamingSaveWriter {
  _FakeStreamingSaveWriter({this.throwOnAbort = false});

  final bool throwOnAbort;
  final List<List<int>> chunks = [];
  var committed = false;
  var abortCalls = 0;

  @override
  Future<void> write(Uint8List plaintextChunk) async {
    chunks.add(List<int>.of(plaintextChunk));
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> abort() async {
    abortCalls++;
    if (throwOnAbort) throw StateError('injected abort failure');
  }
}

class _RecordingFilePicker extends FilePicker {
  _RecordingFilePicker({
    this.pickedResult,
    this.savePath = '/tmp/atermius-test-save',
  });

  final FilePickerResult? pickedResult;
  final String? savePath;
  String? savedFileName;
  Uint8List? savedBytes;
  bool? lastWithData;
  bool? lastWithReadStream;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    @Deprecated('allowCompression has no effect.')
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastWithData = withData;
    lastWithReadStream = withReadStream;
    return pickedResult;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    savedFileName = fileName;
    savedBytes = bytes == null ? null : Uint8List.fromList(bytes);
    return savePath;
  }
}
