// Opt-in screenshot capture for UI review. Skipped unless
import 'dart:async';
// ATERMIUS_UI_CAPTURE_DIR is set; fonts come from ATERMIUS_UI_FONTS_* paths.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aterm_client/desktop/desktop_resolution_dialog.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_settings_editor.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _out = Platform.environment['ATERMIUS_UI_CAPTURE_DIR'];

class _Fake implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
  @override
  Future<void> close() async {}
}

Future<void> _fonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    for (final p in paths) {
      if (File(p).existsSync()) {
        loader.addFont(Future.value(ByteData.sublistView(File(p).readAsBytesSync())));
      }
    }
    await loader.load();
  }

  final sdk = Platform.environment['ATERMIUS_UI_FONTS_SDK']!;
  await load('Roboto', ['$sdk/Roboto-Regular.ttf', '$sdk/Roboto-Medium.ttf', '$sdk/Roboto-Bold.ttf']);
  await load('MaterialIcons', ['$sdk/MaterialIcons-Regular.otf']);
  await load('NotoSansSC', [Platform.environment['ATERMIUS_UI_FONTS_CJK']!]);
}

ThemeData _theme() {
  final base = buildAppTheme();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: const ['NotoSansSC']),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto', fontFamilyFallback: const ['NotoSansSC']),
  );
}

final _boundary = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final render = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<void> _app(WidgetTester tester, Size logical, double dpr, Widget home) async {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: home,
      ),
    ),
  );
}

Future<DesktopSession> _session(WidgetTester tester, HostRecord host) async {
  final fake = _Fake();
  final session = DesktopSession(directConnectionForTesting: (_) => fake)
    ..rdpFeaturesForTesting = const RdpFeatures(0x0ff);
  await tester.runAsync(() async {
    await session.connectLocal(host);
    // A synthetic desktop: dark wallpaper with a lighter "window".
    const w = 1280, h = 800;
    final px = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        final inWindow = x > 160 && x < 900 && y > 120 && y < 600;
        px[i] = inWindow ? 235 : 90;
        px[i + 1] = inWindow ? 235 : 60;
        px[i + 2] = inWindow ? 235 : 30;
        px[i + 3] = 255;
      }
    }
    fake.controller.add(DesktopFrame(w, h, px));
    for (var i = 0; i < 50 && session.state != 'connected'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fake.controller.add(DesktopResizeStatus(serverResize: host.protocol == HostProtocol.rdp));
    fake.controller.add(DesktopRemoteFiles(['报告.docx'], 3, 1024));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  return session;
}

void main() {
  final skip = _out == null;
  setUpAll(() async {
    if (!skip) await _fonts();
  });

  const rdp = HostRecord(
    id: 'r',
    name: 'Windows 11',
    address: 'win.example',
    protocol: HostProtocol.rdp,
    manifest: {
      'rdp_settings_v1': {'version': 1, 'clipboard_files': true},
    },
  );
  const vnc = HostRecord(id: 'v', name: 'Ubuntu VNC', address: 'vnc', protocol: HostProtocol.vnc);

  for (final (label, size, dpr) in [
    ('wide_1x', const Size(1280, 800), 1.0),
    ('narrow_1x', const Size(640, 480), 1.0),
    ('wide_150', const Size(1280, 800), 1.5),
  ]) {
    testWidgets('desktop menu $label', skip: skip, (tester) async {
      final session = await _session(tester, rdp);
      await _app(tester, size, dpr, Scaffold(body: DesktopView(session: session)));
      await _shot(tester, 'desktop_$label');
      await tester.tap(find.byTooltip('Remote desktop menu'));
      await _shot(tester, 'desktop_menu_$label');
    });
  }

  for (final (name, host) in [('rdp', rdp), ('vnc', vnc)]) {
    testWidgets('resolution dialog $name', skip: skip, (tester) async {
      final session = await _session(tester, host);
      await _app(
        tester,
        const Size(1280, 800),
        1.0,
        Scaffold(body: DesktopView(session: session)),
      );
      await tester.tap(find.byTooltip('Remote desktop menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop_display_menu')));
      await _shot(tester, 'resolution_dialog_$name');
    });
  }

  for (final (label, width) in [('wide', 520.0), ('narrow', 360.0)]) {
    testWidgets('host editor rdp options $label', skip: skip, (tester) async {
      await _app(
        tester,
        Size(width, 1500),
        1.0,
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: RdpSettingsEditor(
              initial: const RdpSettings(
                drives: [RdpDriveRedirect(name: 'Work', path: r'C:\Users\me\Work')],
                clipboardFiles: true,
              ),
              features: const RdpFeatures(0x0ff),
              pickFolder: () async => null,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('RDP options'));
      await _shot(tester, 'host_rdp_options_$label');
    });
  }

  testWidgets('host editor vnc display', skip: skip, (tester) async {
    await _app(
      tester,
      const Size(520, 700),
      1.0,
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: VncSettingsEditor(
            initial: const VncSettings(resolution: VncResolutionMode.fixed, width: 1600, height: 900),
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('VNC display'));
    await _shot(tester, 'host_vnc_display');
  });

  testWidgets('file transfer overlay', skip: skip, (tester) async {
    final session = await _session(tester, rdp);
    session.transfer = DesktopFileTransfer(done: 1, total: 3, bytes: 100);
    await _app(tester, const Size(1280, 800), 1.0, Scaffold(body: DesktopView(session: session)));
    await _shot(tester, 'desktop_transfer');
  });
}
