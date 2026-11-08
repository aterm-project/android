// Renders real-font screenshots of density-owned surfaces for proportion
// review. Written only when R7_DENSITY_SHOT_DIR is set; always asserts the
// surfaces render without layout exceptions. Uses only APIs that also exist
// in the R6a baseline so the same file renders before/after images.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = HostRecord(
  id: 'h1',
  name: 'Production database primary',
  address: 'db-primary.internal.example.test',
  port: 2222,
  username: 'operator',
);

final _fontRoot =
    '${Platform.environment['FLUTTER_ROOT'] ?? '/root/.cache/atermius/flutter'}'
    '/bin/cache/artifacts/material_fonts';

Future<void> _loadFonts() async {
  Future<ByteData> bytes(String name) async => ByteData.sublistView(
    Uint8List.fromList(await File('$_fontRoot/$name').readAsBytes()),
  );
  // Android typography asks for Roboto, desktop (Windows) for Segoe UI;
  // both are served by the SDK's Roboto files so text has real metrics.
  for (final family in ['Roboto', 'Segoe UI']) {
    final loader = FontLoader(family)
      ..addFont(bytes('Roboto-Regular.ttf'))
      ..addFont(bytes('Roboto-Medium.ttf'))
      ..addFont(bytes('Roboto-Bold.ttf'));
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('MaterialIcons-Regular.otf'));
  await icons.load();
}

List<SettingsSection> _sections() => [
  for (final id in ['general', 'terminal', 'security'])
    SettingsSection(
      id: id,
      title: 'Settings $id',
      icon: Icons.tune,
      description: 'Preferences that apply to every window on this device.',
      builder: (context) => SettingsCards(
        children: [
          for (var i = 0; i < 2; i++)
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Card $i',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const TextField(
                    decoration: InputDecoration(labelText: 'Value'),
                  ),
                  SwitchListTile(
                    value: i.isEven,
                    onChanged: (_) {},
                    title: const Text('Enable option'),
                    subtitle: const Text('Secondary explanation line'),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () {},
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
];

Widget _dialogSample() => Builder(
  builder: (context) => AlertDialog(
    title: const Text('Verify SSH host key'),
    content: const SizedBox(
      width: 440,
      child: Text(
        'The server presented a key that is not yet trusted. Compare the '
        'fingerprint with the one published by the administrator.',
      ),
    ),
    actions: [
      TextButton(onPressed: () {}, child: const Text('Cancel')),
      FilledButton(onPressed: () {}, child: const Text('Trust')),
    ],
  ),
);

Future<void> _shot(
  WidgetTester tester, {
  required String name,
  required Size size,
  required TargetPlatform platform,
  required Locale locale,
  required Widget home,
  double textScale = 1,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  try {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(locale: locale),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final dir = Platform.environment['R7_DENSITY_SHOT_DIR'];
    if (dir != null && dir.isNotEmpty) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$dir/$name.png')
            .writeAsBytes(png!.buffer.asUint8List(), flush: true);
      });
    }
  } finally {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  setUpAll(_loadFonts);

  const desktop = Size(1280, 800);
  const phone = Size(390, 780);

  for (final lang in ['en', 'ru']) {
    testWidgets('shot host editor desktop $lang', (tester) async {
      await _shot(
        tester,
        name: 'host_editor_desktop_$lang',
        size: desktop,
        platform: TargetPlatform.windows,
        locale: Locale(lang),
        home: const Scaffold(
          body: HostEditorPanel(groups: [], hosts: [], existing: _host),
        ),
      );
    });
  }

  testWidgets('shot host editor phone en', (tester) async {
    await _shot(
      tester,
      name: 'host_editor_phone_en',
      size: phone,
      platform: TargetPlatform.android,
      locale: const Locale('en'),
      home: const Scaffold(
        body: HostEditorPanel(groups: [], hosts: [], existing: _host),
      ),
    );
  });

  testWidgets('shot host editor desktop en text150', (tester) async {
    await _shot(
      tester,
      name: 'host_editor_desktop_en_text150',
      size: desktop,
      platform: TargetPlatform.windows,
      locale: const Locale('en'),
      textScale: 1.5,
      home: const Scaffold(
        body: HostEditorPanel(groups: [], hosts: [], existing: _host),
      ),
    );
  });

  testWidgets('shot settings desktop en', (tester) async {
    await _shot(
      tester,
      name: 'settings_desktop_en',
      size: desktop,
      platform: TargetPlatform.windows,
      locale: const Locale('en'),
      home: Scaffold(body: SettingsScaffold(sections: _sections())),
    );
  });

  testWidgets('shot dialog desktop en', (tester) async {
    await _shot(
      tester,
      name: 'dialog_desktop_en',
      size: desktop,
      platform: TargetPlatform.windows,
      locale: const Locale('en'),
      home: Scaffold(body: Center(child: _dialogSample())),
    );
  });
}
