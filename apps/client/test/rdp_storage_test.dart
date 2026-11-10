import 'dart:async';
import 'dart:io';

import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_settings_editor.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/desktop/rdp_storage_io.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

const features = RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive);
Future<void> mount(
  WidgetTester tester, {
  required ValueChanged<RdpSettings> changed,
  Future<String?> Function()? folder,
  Future<String?> Function(BuildContext)? disk,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: RdpSettingsEditor(
            initial: RdpSettings.defaults,
            onChanged: changed,
            features: features,
            pickFolder: folder,
            pickDisk: disk,
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text(currentL10n.rdpOptions));
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey('host_rdp_$key'));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');
  test(
    'drive preflight accepts an existing directory without creating files',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'atermius-rdp-storage-',
      );
      addTearDown(() => dir.delete(recursive: true));
      await validateRdpDriveConfig('version=1\ndrive=Owned|${dir.path}\n');
      expect(await dir.list().toList(), isEmpty);
      await expectLater(
        validateRdpDriveConfig('version=1\ndrive=Gone|${dir.path}/absent\n'),
        throwsA(
          isA<RdpStorageException>().having(
            (e) => e.name,
            'mapping name',
            'Gone',
          ),
        ),
      );
      await expectLater(
        validateRdpDriveConfig('version=1\ndrive=Other Device|C:\\Private\n'),
        throwsA(isA<RdpStorageException>()),
      );
      await validateRdpDriveConfig('version=1\nclipboard_text=1\n');
    },
  );
  testWidgets(
    'non-Latin folder names get valid unique share names; disk roots get useful names',
    (tester) async {
      RdpSettings? value;
      await mount(
        tester,
        changed: (v) => value = v,
        folder: () async => '/storage/emulated/0/资料',
        disk: (_) async => '/storage/emulated/0',
      );
      await press(tester, 'add_drive');
      await press(tester, 'add_drive');
      expect(value!.drives.map((d) => d.name), ['Folder', 'Folder 2']);
      expect(value!.validate(), isNull);
      await press(tester, 'add_disk');
      expect(value!.drives.last.name, 'Local Storage');
      expect(value!.drives.last.path, '/storage/emulated/0');
    },
  );
  testWidgets(
    'permission error and cancellation preserve existing mappings and picker is single-flight',
    (tester) async {
      var calls = 0;
      final pending = Completer<String?>();
      RdpSettings? value;
      await mount(
        tester,
        changed: (v) => value = v,
        folder: () {
          calls++;
          return pending.future;
        },
        disk: (_) async =>
            throw const RdpStorageException(RdpStorageIssue.permission),
      );
      await press(tester, 'add_disk');
      expect(
        find.text(currentL10n.rdpStoragePermissionRequired),
        findsOneWidget,
      );
      expect(value, isNull);
      final add = find.byKey(const ValueKey('host_rdp_add_drive'));
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pump();
      expect(tester.widget<TextButton>(add).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('host_rdp_add_disk')))
            .onPressed,
        isNull,
      );
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(value, isNull);
      expect(tester.widget<TextButton>(add).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Windows root maps as Drive C and can be renamed through the actual dialog',
    (tester) async {
      RdpSettings? value;
      await mount(tester, changed: (v) => value = v, disk: (_) async => 'C:\\');
      await press(tester, 'add_disk');
      expect(value!.drives.single.name, 'Drive C');
      await tester.ensureVisible(find.byTooltip(currentL10n.rdpRenameMapping));
      await tester.tap(find.byTooltip(currentL10n.rdpRenameMapping));
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Bad|name');
      await tester.tap(find.widgetWithText(TextButton, currentL10n.save));
      await tester.pump();
      expect(find.text(currentL10n.driveNameMustBe131), findsOneWidget);
      expect(value!.drives.single.name, 'Drive C');
      await tester.enterText(field, 'Work');
      await tester.tap(find.widgetWithText(TextButton, currentL10n.save));
      await tester.pumpAndSettle();
      expect(value!.drives.single.name, 'Work');
      expect(value!.drives.single.path, 'C:\\');
      expect(tester.takeException(), isNull);
    },
  );
  for (final locale in ['en', 'zh', 'ja', 'ru']) {
    group(locale, () {
      useAppLocaleFixture(locale);
      testWidgets('390px disk/folder controls and inline failure wrap', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await mount(
          tester,
          changed: (_) {},
          folder: () async => null,
          disk: (_) async =>
              throw const RdpStorageException(RdpStorageIssue.permission),
        );
        await press(tester, 'add_disk');
        expect(
          find.text(currentL10n.rdpStoragePermissionRequired),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    });
  }
}
