import 'dart:io';
import 'dart:ui' as ui;

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/settings_navigation.dart';

// Optional real-font screenshots for manual review; regular tests need no files.
const _captureDir = String.fromEnvironment('SETTINGS_CAPTURE_DIR');
const _captureFont = String.fromEnvironment('SETTINGS_CAPTURE_FONT');

void main() {
  testWidgets('account settings categories fit desktop and narrow windows', (
    tester,
  ) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _SettingsController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.settings
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
            canWrite: true,
          );
    final boundary = GlobalKey();
    var theme = buildAppTheme();
    if (_captureFont.isNotEmpty) {
      await tester.runAsync(() async {
        final loader = FontLoader('SettingsReview')
          ..addFont(
            File(_captureFont)
                .readAsBytes()
                .then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      });
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      theme = theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'SettingsReview'),
      );
    }
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: boundary,
            child: AppShell(controller: app),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sections = tester
          .widget<SettingsScaffold>(find.byType(SettingsScaffold))
          .sections
          .map((section) => section.id)
          .toList();
      for (final width in [1280.0, 800.0, 390.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpAndSettle();
        for (final section in sections) {
          await openSettingsCategory(tester, section);
          await tester.pumpAndSettle();
          expect(
            find.byKey(ValueKey('settings_page_$section')),
            findsOneWidget,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$section at width $width',
          );
          if (_captureDir.isNotEmpty &&
              [
                'workspace',
                'terminal',
                'security',
                'access',
              ].contains(section)) {
            await tester.runAsync(() async {
              final rendered =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final png = await rendered.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('$_captureDir/$section-${width.toInt()}.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png!.buffer.asUint8List());
              rendered.dispose();
            });
          }
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
      await tester.binding.setSurfaceSize(null);
    }
  });
}

class _SettingsController extends AppController {
  _SettingsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
  @override
  bool get isInstanceAdmin => true;
}
