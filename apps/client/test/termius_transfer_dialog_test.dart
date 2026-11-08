import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_csv.dart';
import 'package:aterm_client/import/termius_openssh_bundle.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/termius_transfer_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic values only.
const _csv =
    'Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password\r\n'
    'Project/Dev,web,"a,b",w.example,ssh,22,alice," spaced pw "\r\n'
    ',db,,d.example,ssh,2200,bob,\r\n'
    ',bad,,d.example,telnet,23,bob,\r\n';
const _key =
    '-----BEGIN OPENSSH PRIVATE KEY-----\nc3ludGhldGlj\n-----END OPENSSH PRIVATE KEY-----\n';

class _FakeTarget implements TermiusTransferTarget {
  _FakeTarget({this.canWrite = true, this.hosts = const []});

  @override
  final bool canWrite;
  final List<HostRecord> hosts;
  final applied = <TermiusImportPlan>[];
  TermiusApplyException? failWith;

  @override
  String? get contextKey => 'fake';

  @override
  Future<TermiusCatalog> loadCatalog() async =>
      TermiusCatalog(hosts: hosts, groups: const []);

  @override
  Future<TermiusApplyReport> apply(TermiusImportPlan plan) async {
    final failure = failWith;
    if (failure != null) throw failure;
    applied.add(plan);
    return TermiusApplyReport(
      createdHosts: plan.createCount,
      createdGroups: plan.newGroups.length,
    );
  }
}

class _ReadOnlyFilePicker extends FilePicker {
  _ReadOnlyFilePicker(this.file);

  PlatformFile file;
  var calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    expect(withData, isTrue);
    expect(allowMultiple, isFalse);
    return FilePickerResult([file]);
  }
}

class _Saved {
  String? fileName;
  Uint8List? bytes;
  bool? containsSecrets;
  var calls = 0;
}

Future<TermiusTransferOutcome?> Function() _open(
  WidgetTester tester, {
  required TermiusTransferTarget target,
  TermiusTransferMode mode = TermiusTransferMode.importData,
  Map<TermiusImportSource, Uint8List> files = const {},
  _Saved? saved,
  bool usePlatformPicker = false,
}) {
  TermiusTransferOutcome? outcome;
  var closed = false;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 1600);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  return () async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () async {
                  outcome = await showDialog<TermiusTransferOutcome>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => TermiusTransferDialog(
                      target: target,
                      initialMode: mode,
                      pickBytesForTesting: usePlatformPicker
                          ? null
                          : (source) async {
                              final bytes = files[source];
                              return bytes == null
                                  ? null
                                  : (
                                      bytes: Uint8List.fromList(bytes),
                                      name: 'file',
                                    );
                            },
                      saveForTesting:
                          ({
                            required String fileName,
                            required Uint8List bytes,
                            required bool containsSecrets,
                          }) async {
                            saved?.calls++;
                            saved?.fileName = fileName;
                            saved?.bytes = Uint8List.fromList(bytes);
                            saved?.containsSecrets = containsSecrets;
                            return true;
                          },
                    ),
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    return closed ? outcome : null;
  };
}

AppLocalizations get _l10n => appLocalizationsFor(const Locale('en'));

void main() {
  setUpAll(FilePickerIO.registerWith);

  testWidgets(
    'CSV import previews, confirm-cancel writes nothing, accept applies',
    (tester) async {
      final target = _FakeTarget();
      await _open(
        tester,
        target: target,
        files: {TermiusImportSource.csv: Uint8List.fromList(utf8.encode(_csv))},
      )();
      await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('termius_import_preview')),
        findsOneWidget,
      );
      expect(find.text(_l10n.r7ImportSummary(2, 2, 0, 1)), findsOneWidget);
      // The password is never displayed, only its presence.
      expect(find.textContaining('spaced pw'), findsNothing);
      expect(find.textContaining(_l10n.r7ImportRowPassword), findsOneWidget);
      expect(
        find.textContaining(_l10n.r7ImportIssueUnsupportedProtocol('telnet')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('termius_import_apply')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('termius_import_confirm_cancel')),
      );
      await tester.pumpAndSettle();
      expect(target.applied, isEmpty);

      // Exclude one row, then confirm.
      await tester.tap(
        find.byKey(const ValueKey('termius_import_row_include_2')),
      );
      await tester.pumpAndSettle();
      expect(find.text(_l10n.r7ImportSummary(1, 2, 1, 1)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('termius_import_apply')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('termius_import_confirm_accept')),
      );
      await tester.pumpAndSettle();
      expect(target.applied, hasLength(1));
      final host = target.applied.single.hostsToCreate.single;
      expect(host.name, 'web');
      expect(host.login?.password, ' spaced pw ');
      expect(host.tags, ['a', 'b']);
      expect(
        find.byKey(const ValueKey('termius_transfer_dialog')),
        findsNothing,
      );
    },
  );

  testWidgets('platform read-only bytes preview, re-enable and apply', (
    tester,
  ) async {
    final original = Uint8List.fromList(utf8.encode(_csv));
    final bytes = original.asUnmodifiableView();
    final previous = FilePicker.platform;
    final picker = _ReadOnlyFilePicker(
      PlatformFile(name: 'hosts.csv', size: bytes.length, bytes: bytes),
    );
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = previous);
    final target = _FakeTarget();
    await _open(tester, target: target, usePlatformPicker: true)();
    await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(picker.calls, 1);
    expect(bytes, orderedEquals(original));
    expect(
      find.byKey(const ValueKey('termius_import_preview')),
      findsOneWidget,
    );
    expect(find.text(_l10n.r7ImportSummary(2, 2, 0, 1)), findsOneWidget);
    // A second pick verifies the busy flag was cleared after preview cleanup.
    await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
    await tester.pumpAndSettle();
    expect(picker.calls, 2);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('termius_import_apply')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('termius_import_confirm_accept')),
    );
    await tester.pumpAndSettle();
    expect(target.applied, hasLength(1));
    expect(target.applied.single.hostsToCreate, hasLength(2));
    expect(find.byKey(const ValueKey('termius_transfer_dialog')), findsNothing);
  });

  testWidgets('invalid platform read-only bytes show error and allow retry', (
    tester,
  ) async {
    final bytes = Uint8List.fromList(utf8.encode(_csv)).asUnmodifiableView();
    final previous = FilePicker.platform;
    final picker = _ReadOnlyFilePicker(
      PlatformFile(name: 'invalid.csv', size: bytes.length + 1, bytes: bytes),
    );
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = previous);
    final target = _FakeTarget();
    await _open(tester, target: target, usePlatformPicker: true)();
    await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(_l10n.r7ImportFileUnreadable), findsOneWidget);
    expect(find.byKey(const ValueKey('termius_import_preview')), findsNothing);
    expect(target.applied, isEmpty);
    picker.file = PlatformFile(
      name: 'hosts.csv',
      size: bytes.length,
      bytes: bytes,
    );
    await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
    await tester.pumpAndSettle();
    expect(picker.calls, 2);
    expect(tester.takeException(), isNull);
    expect(find.text(_l10n.r7ImportFileUnreadable), findsNothing);
    expect(
      find.byKey(const ValueKey('termius_import_preview')),
      findsOneWidget,
    );
  });

  testWidgets('closing before apply never mutates; stale apply is explained', (
    tester,
  ) async {
    final target = _FakeTarget()
      ..failWith = const TermiusApplyException(TermiusApplyFailure.stalePlan);
    await _open(
      tester,
      target: target,
      files: {TermiusImportSource.csv: Uint8List.fromList(utf8.encode(_csv))},
    )();
    await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('termius_import_apply')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('termius_import_confirm_accept')),
    );
    await tester.pumpAndSettle();
    expect(find.text(_l10n.r7ImportFailStale), findsOneWidget);
    expect(target.applied, isEmpty);
    await tester.tap(find.byKey(const ValueKey('termius_transfer_close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('termius_transfer_dialog')), findsNothing);
    expect(target.applied, isEmpty);
  });

  testWidgets('CSV export: secrets off by default; opt-in needs confirmation', (
    tester,
  ) async {
    final target = _FakeTarget(
      hosts: const [
        HostRecord(
          id: 'h1',
          name: 'web',
          address: 'w.example',
          username: 'alice',
          login: HostLogin(kind: AuthKind.password, password: ' pw-synthetic '),
        ),
      ],
    );
    final saved = _Saved();
    await _open(
      tester,
      target: target,
      mode: TermiusTransferMode.exportData,
      saved: saved,
    )();
    expect(find.text(_l10n.r7ImportExportSummary(1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('termius_export_save')));
    await tester.pumpAndSettle();
    expect(saved.calls, 1);
    expect(saved.containsSecrets, isFalse);
    final text = utf8.decode(saved.bytes!);
    expect(text, isNot(contains('pw-synthetic')));
    expect(TermiusCsv.parse(text).first.fields, TermiusCsvColumn.template);

    // Reopen, opt in, cancel the confirmation: nothing saved.
    await _open(
      tester,
      target: target,
      mode: TermiusTransferMode.exportData,
      saved: saved,
    )();
    await tester.tap(
      find.byKey(const ValueKey('termius_export_include_secrets')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('termius_export_secret_warning')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('termius_export_save')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('termius_export_secret_confirm_cancel')),
    );
    await tester.pumpAndSettle();
    expect(saved.calls, 1);
    await tester.tap(find.byKey(const ValueKey('termius_export_save')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('termius_export_secret_confirm_accept')),
    );
    await tester.pumpAndSettle();
    expect(saved.calls, 2);
    expect(saved.containsSecrets, isTrue);
    expect(utf8.decode(saved.bytes!), contains('" pw-synthetic "'));
  });

  testWidgets('bundle export with keys needs confirmation and imports back', (
    tester,
  ) async {
    final target = _FakeTarget(
      hosts: const [
        HostRecord(
          id: 'h1',
          name: 'keyed',
          address: 'k.example',
          username: 'alice',
          login: HostLogin(kind: AuthKind.privateKey, privateKey: _key),
        ),
      ],
    );
    final saved = _Saved();
    await _open(
      tester,
      target: target,
      mode: TermiusTransferMode.exportData,
      saved: saved,
    )();
    await tester.tap(
      find.byKey(const ValueKey('termius_export_format_bundle')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('termius_export_include_keys')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('termius_export_save')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('termius_export_secret_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('termius_export_secret_confirm_accept')),
    );
    await tester.pumpAndSettle();
    expect(saved.calls, 1);
    expect(saved.fileName, endsWith('.zip'));
    expect(saved.containsSecrets, isTrue);
    final document = TermiusOpenSshBundleImporter.parseZip(saved.bytes!);
    expect(document.rows.single.privateKey, _key);
  });

  testWidgets('read-only target opens in export mode with import disabled', (
    tester,
  ) async {
    await _open(tester, target: _FakeTarget(canWrite: false))();
    expect(find.text(_l10n.r7ImportReadOnly), findsOneWidget);
    expect(find.byKey(const ValueKey('termius_export_save')), findsOneWidget);
    expect(find.byKey(const ValueKey('termius_import_pick_csv')), findsNothing);
  });

  testWidgets('localized in zh, ja and ru without overflow', (tester) async {
    for (final code in ['zh', 'ja', 'ru']) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(code),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(),
          home: Scaffold(
            body: TermiusTransferDialog(
              target: _FakeTarget(),
              pickBytesForTesting: (_) async =>
                  (bytes: Uint8List.fromList(utf8.encode(_csv)), name: 'x.csv'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
      await tester.pumpAndSettle();
      final l10n = appLocalizationsFor(Locale(code));
      expect(find.text(l10n.r7ImportTransferTitle), findsOneWidget);
      expect(find.text(l10n.r7ImportSummary(2, 2, 0, 1)), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
