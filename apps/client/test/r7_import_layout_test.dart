import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/termius_transfer_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Target implements TermiusTransferTarget {
  @override
  bool get canWrite => true;
  @override
  String get contextKey => 'layout-fixture';
  @override
  Future<TermiusCatalog> loadCatalog() async => TermiusCatalog(
    hosts: const [HostRecord(id: 'fixture', name: 'Test 主机',
      address: 'example.test', username: 'user')], groups: const []);
  @override
  Future<TermiusApplyReport> apply(TermiusImportPlan plan) =>
      throw StateError('Layout must not import any records');
}

void main() {
  for (final language in ['en', 'zh', 'ja', 'ru']) {
    for (final width in [340.0, 640.0, 1280.0]) {
      for (final scale in [1.0, 1.6]) {
        testWidgets('Termius dialog $language width $width scale $scale', (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: buildAppTheme(platform: width < 600 ? TargetPlatform.android : TargetPlatform.windows),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(builder: (context) => Scaffold(body: TextButton(
              key: const ValueKey('open-transfer'), child: const Text('Open'),
              onPressed: () => showDialog<void>(context: context, builder: (_) =>
                TermiusTransferDialog(target: _Target(), pickBytesForTesting: (_) async => (
                  name: 'synthetic.csv', bytes: Uint8List.fromList(utf8.encode(
                    'Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password\r\n'
                    'Team,Example 主机,,fixture.example,ssh,22,testuser,\r\n')))),
              ),
            ))),
          ));
          await tester.tap(find.byKey(const ValueKey('open-transfer')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final pick = find.byKey(const ValueKey('termius_import_pick_csv'));
          await tester.ensureVisible(pick);
          await tester.tap(pick);
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('termius_import_preview')), findsOneWidget);
          expect(tester.takeException(), isNull);
          final export = find.byKey(const ValueKey('termius_mode_export'));
          await tester.ensureVisible(export);
          await tester.tap(export);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
      }
    }
  }
}
