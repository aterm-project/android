import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/wallpaper_store.dart';
import 'package:aterm_client/storage/wallpaper_store_native.dart'
    show FileWallpaperStore;
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:aterm_client/ui/wallpaper.dart';
import 'package:aterm_client/ui/wallpaper_settings.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  canvas.drawRect(rect, Paint()..color = color);
  canvas.drawCircle(rect.center, height / 3, Paint()..color = Colors.white);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 64, 64),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

double _contrastOf(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
}

Uint8List _pngHeader(int width, int height) {
  final b = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add([0, 0, 0, 13])
    ..add(ascii.encode('IHDR'))
    ..add([
      width >> 24 & 255, width >> 16 & 255, width >> 8 & 255, width & 255, //
      height >> 24 & 255, height >> 16 & 255, height >> 8 & 255, height & 255,
      8, 6, 0, 0, 0, // depth, color type, compression, filter, interlace
      0, 0, 0, 0, // CRC (wrong on purpose)
    ])
    ..add(List.filled(32, 0x42));
  return b.toBytes();
}

Uint8List _jpegHeader(int width, int height) => Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46, // APP0
  0xFF, 0xC2, 0x00, 0x11, 0x08, //
  height >> 8, height & 255, width >> 8, width & 255, //
  3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1,
]);

Uint8List _webp(String chunk, List<int> payload) {
  final body = <int>[...ascii.encode('WEBP'), ...ascii.encode(chunk), 0, 0, 0, 0];
  final bytes = <int>[...ascii.encode('RIFF'), 0, 0, 0, 0, ...body, ...payload];
  while (bytes.length < 40) {
    bytes.add(0);
  }
  return Uint8List.fromList(bytes);
}

Widget _app({
  required Widget child,
  required WallpaperController controller,
  Locale locale = const Locale('en'),
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  theme: buildAppTheme(locale: locale, brightness: brightness),
  builder: (context, navigator) =>
      WallpaperWindowHost(controller: controller, child: navigator!),
  home: child,
);

/// Fake session view: counts State lifecycles like a PTY/SSH owner would.
class _FakeSession extends StatefulWidget {
  const _FakeSession(this.id, this.log);
  final String id;
  final List<String> log;
  @override
  State<_FakeSession> createState() => _FakeSessionState();
}

class _FakeSessionState extends State<_FakeSession> {
  final draft = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.log.add('open:${widget.id}');
  }

  @override
  void dispose() {
    widget.log.add('close:${widget.id}');
    draft.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: Column(
      children: [
        TextField(key: ValueKey('draft-${widget.id}'), controller: draft),
        Expanded(
          child: TerminalView(
            Terminal(),
            backgroundOpacity: wallpaperTerminalBackgroundOpacity(context),
          ),
        ),
      ],
    ),
  );
}

/// Lets real engine work (decode/encode) finish, then pumps frames.
Future<void> settle(WidgetTester tester, {required bool Function() until}) async {
  for (var i = 0; i < 50 && !until(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('default terminal text stays readable over the brightest and darkest images', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
    }

    // Same compositing as xterm's TerminalView:
    // theme.background.withOpacity(backgroundOpacity) over the backdrop.
    // Luminance is monotonic per channel, so for any image (and any scrim
    // over it) the composite lies between the white and black composites;
    // if the default foreground is outside that range, these two are the
    // worst cases.
    for (final choice in VaultTerminalThemeChoice.values) {
      final theme = buildTerminalColorTheme(choice);
      final fill = theme.background.withValues(alpha: wallpaperTerminalOpacity);
      final overWhite = Color.alphaBlend(fill, Colors.white);
      final overBlack = Color.alphaBlend(fill, Colors.black);
      final fg = theme.foreground.computeLuminance();
      final lo = overBlack.computeLuminance(), hi = overWhite.computeLuminance();
      expect(fg < lo || fg > hi, isTrue, reason: '${choice.value} fg inside range');
      for (final (name, backdrop) in [('white', overWhite), ('black', overBlack)]) {
        expect(
          contrast(theme.foreground, backdrop),
          greaterThanOrEqualTo(4.5),
          reason: '${choice.value} over $name image',
        );
      }
    }
    // The wallpaper is still visible through the terminal.
    expect(wallpaperTerminalOpacity, lessThan(1));
  });

  group('chrome readability over the wallpaper', () {
    test('scrim stays at the floor for suitable images and rises for clashing ones', () {
      for (final palette in [AppPalette.dark, AppPalette.light]) {
        // Suitable: dark image under dark UI, bright image under light UI.
        final suitable = palette.isDark
            ? const WallpaperLuminance(0, .02)
            : const WallpaperLuminance(.9, 1);
        expect(
          wallpaperScrimAlpha(palette, suitable, pane: true),
          closeTo(palette.isDark ? .38 : .46, 1e-9),
        );
        expect(
          wallpaperScrimAlpha(palette, suitable, pane: false),
          closeTo(palette.isDark ? .58 : .64, 1e-9),
        );
        for (final pane in [true, false]) {
          final alpha = wallpaperScrimAlpha(
            palette,
            WallpaperLuminance.unknown,
            pane: pane,
          );
          expect(alpha, lessThan(1));
          for (final backdrop in [Colors.white, Colors.black]) {
            final surface = Color.alphaBlend(
              palette.background.withValues(alpha: alpha),
              backdrop,
            );
            for (final ink in [palette.text, palette.muted]) {
              expect(
                _contrastOf(ink, surface),
                greaterThanOrEqualTo(4.5),
                reason: '${palette.brightness} pane=$pane over $backdrop',
              );
            }
          }
        }
      }
    });

    for (final (brightness, image) in [
      (Brightness.dark, Colors.white),
      (Brightness.light, Colors.black),
    ]) {
      for (final mode in WallpaperLayoutMode.values) {
        testWidgets(
          'raster: ${brightness.name} UI over a ${image == Colors.white ? 'white' : 'black'} image, ${mode.code}',
          (tester) async {
            tester.view.physicalSize = const Size(400, 300);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final controller = (await tester.runAsync(() async {
              final created = WallpaperController();
              await created.load(MemoryWallpaperStore());
              created.setMode(mode);
              created.setBlur(0);
              expect(await created.setImageBytes(await _solidPng(image)), isNull);
              return created;
            }))!;
            final workspace = SessionWorkspaceController()..activate('a');
            final boundary = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: _app(
                  controller: controller,
                  brightness: brightness,
                  // A real pane hosting chrome text without its own surface
                  // (like a file list or the live-split header).
                  child: Scaffold(
                    body: SessionWorkspaceView(
                      controller: workspace,
                      terminalBuilder: (context, id) => Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            'Pane header',
                            key: const ValueKey('chrome-label'),
                            style: TextStyle(color: context.palette.muted),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final palette = brightness == Brightness.dark
                ? AppPalette.dark
                : AppPalette.light;
            final label = tester.getRect(find.byKey(const ValueKey('chrome-label')));
            final pixels = (await tester.runAsync(() async {
              final shot = await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
              final data = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
              final width = shot.width;
              shot.dispose();
              Color at(Offset p) {
                final i = (p.dy.round() * width + p.dx.round()) * 4;
                return Color.fromARGB(
                  255,
                  data!.getUint8(i),
                  data.getUint8(i + 1),
                  data.getUint8(i + 2),
                );
              }

              // Surface right next to the label, and under it in the gap.
              return [
                at(label.topLeft - const Offset(12, 12)),
                at(label.bottomRight + const Offset(12, 12)),
              ];
            }))!;
            for (final surface in pixels) {
              // The scrim is really over the image (not an opaque fill).
              expect(surface, isNot(palette.background));
              for (final ink in [palette.text, palette.muted]) {
                expect(
                  _contrastOf(ink, surface),
                  greaterThanOrEqualTo(4.5),
                  reason: 'surface $surface',
                );
              }
            }
            expect(tester.takeException(), isNull);
            await tester.runAsync(
              () => controller.debugIdle.timeout(const Duration(seconds: 10)),
            );
            controller.dispose();
          },
        );
      }
    }
  });

  group('validation', () {
    test('formats come from signatures and header dimensions', () async {
      final png = await _png(64, 40, Colors.blue);
      final info = wallpaperInspectImage(png);
      expect((info.format, info.width, info.height), (
        WallpaperImageFormat.png,
        64,
        40,
      ));
      final jpeg = wallpaperInspectImage(_jpegHeader(1920, 1080));
      expect((jpeg.format, jpeg.width, jpeg.height), (
        WallpaperImageFormat.jpeg,
        1920,
        1080,
      ));
      // VP8L: 14-bit (width-1) | (height-1) << 14.
      const w = 800, h = 600;
      const bits = (w - 1) | ((h - 1) << 14);
      final lossless = wallpaperInspectImage(
        _webp('VP8L', [0x2F, bits & 255, bits >> 8 & 255, bits >> 16 & 255, bits >> 24 & 255]),
      );
      expect((lossless.width, lossless.height), (800, 600));
    });

    test('rejects oversize, unknown, animated and decompression bombs', () async {
      Matcher fails(WallpaperImageError error) => throwsA(
        isA<WallpaperImageException>().having((e) => e.error, 'error', error),
      );
      expect(
        () => wallpaperInspectImage(Uint8List(wallpaperMaxEncodedBytes + 1)),
        fails(WallpaperImageError.tooLarge),
      );
      expect(
        () => wallpaperInspectImage(Uint8List.fromList(utf8.encode('GIF89a....'))),
        fails(WallpaperImageError.unsupported),
      );
      expect(
        () => wallpaperInspectImage(
          Uint8List.fromList(utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"/>')),
        ),
        fails(WallpaperImageError.unsupported),
      );
      // Animated WebP (VP8X animation flag).
      expect(
        () => wallpaperInspectImage(_webp('VP8X', [0x02, 0, 0, 0, 10, 0, 0, 10, 0, 0])),
        fails(WallpaperImageError.unsupported),
      );
      // Header claims a 20000 x 20000 image: rejected before any decode.
      expect(
        () => wallpaperInspectImage(_pngHeader(20000, 20000)),
        fails(WallpaperImageError.dimensions),
      );
      expect(
        () => wallpaperInspectImage(_pngHeader(9000, 9000)),
        fails(WallpaperImageError.dimensions),
      );
      expect(
        () => wallpaperInspectImage(_pngHeader(0, 10)),
        fails(WallpaperImageError.corrupt),
      );
      // Valid-looking header with damaged data fails at decode.
      await expectLater(
        decodeWallpaperImage(_pngHeader(32, 32)),
        fails(WallpaperImageError.corrupt),
      );
    });

    test('decodes at a bounded size', () async {
      final image = await decodeWallpaperImage(
        await _png(3000, 1500, Colors.teal),
      );
      expect(image.width, wallpaperMaxDecodedSide);
      expect(image.height, 1280);
      image.dispose();
    });

    test('settings reads are sanitized field by field', () {
      final parsed = WallpaperPreferences.parse(
        jsonEncode({
          'v': 1,
          'image': '../../etc/passwd',
          'mode': 'everywhere',
          'blur': 1e9,
        }),
      );
      expect(parsed.imageId, isNull);
      expect(parsed.mode, WallpaperLayoutMode.window);
      expect(parsed.blur, wallpaperMaxBlur);
      expect(
        WallpaperPreferences.parse('{"v":1,"blur":"x","mode":"panes"}').blur,
        wallpaperDefaultBlur,
      );
      expect(
        WallpaperPreferences.parse('{"v":1,"blur":-3,"mode":"panes"}').mode,
        WallpaperLayoutMode.panes,
      );
      expect(WallpaperPreferences.parse('{"v":1,"blur":-3}').blur, 0);
      expect(WallpaperPreferences.parse('{"v":2,"blur":3}').blur, wallpaperDefaultBlur);
      expect(WallpaperPreferences.parse('not json').imageId, isNull);
      expect(WallpaperPreferences.parse('x' * 600).mode, WallpaperLayoutMode.window);
    });
  });

  group('persistence', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('wallpaper-test-'));
    tearDown(() => root.deleteSync(recursive: true));

    List<String> owned() => Directory('${root.path}/wallpaper-v1').existsSync()
        ? Directory('${root.path}/wallpaper-v1')
              .listSync()
              .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
              .where((name) => name.endsWith('.img'))
              .toList()
        : <String>[];

    test('select, replace, reload and reset keep only owned content', () async {
      final store = FileWallpaperStore(directory: () async => root);
      final controller = WallpaperController();
      await controller.load(store, cleanupStale: true);
      expect(controller.active, isFalse);

      final first = await _png(320, 200, Colors.red);
      expect(await controller.setImageBytes(first), isNull);
      controller.setMode(WallpaperLayoutMode.panes);
      controller.setBlur(12.25);
      await controller.debugIdle;
      expect(controller.active, isTrue);
      expect(owned(), hasLength(1));
      final settings = File('${root.path}/wallpaper-v1/settings.json').readAsStringSync();
      final json = jsonDecode(settings) as Map;
      expect(json.keys.toSet(), {'v', 'image', 'mode', 'blur'});
      expect(json['mode'], 'panes');
      expect(json['blur'], 12.5);
      expect(settings.length, lessThan(160)); // no image bytes, no paths
      expect(settings, isNot(contains(root.path)));
      expect(
        File('${root.path}/wallpaper-v1/${owned().single}').readAsBytesSync(),
        first,
      );
      // The blur is pre-rendered once, at half resolution.
      expect(controller.bakedImage, isNotNull);
      expect(controller.bakedImage!.width, 160);

      final firstFile = owned().single;
      expect(await controller.setImageBytes(await _png(200, 320, Colors.green)), isNull);
      await controller.debugIdle;
      expect(owned(), hasLength(1));
      expect(owned().single, isNot(firstFile));

      // A rejected replacement keeps the current wallpaper and files.
      final kept = owned().single;
      expect(
        await controller.setImageBytes(_pngHeader(20000, 20000)),
        WallpaperImageError.dimensions,
      );
      await controller.debugIdle;
      expect(owned(), [kept]);
      expect(controller.active, isTrue);

      // Another window loads the same preferences and image content.
      final child = WallpaperController();
      await child.load(FileWallpaperStore(directory: () async => root));
      await child.debugRestoring;
      expect(child.active, isTrue);
      expect(child.mode, WallpaperLayoutMode.panes);
      expect(child.blur, 12.5);
      expect(child.image!.width, 200);
      child.dispose();

      await controller.reset();
      await controller.debugIdle;
      expect(controller.active, isFalse);
      expect(owned(), isEmpty);
      final cleared = jsonDecode(
        File('${root.path}/wallpaper-v1/settings.json').readAsStringSync(),
      ) as Map;
      expect(cleared.containsKey('image'), isFalse);
      controller.dispose();
    });

    test('missing or damaged stored image falls back without wallpaper', () async {
      final id = 'ab' * 16;
      final store = MemoryWallpaperStore(
        settings: jsonEncode({'v': 1, 'image': id, 'mode': 'window', 'blur': 4}),
      );
      final missing = WallpaperController();
      await missing.load(store);
      await missing.debugRestoring;
      expect(missing.status, WallpaperStatus.missing);
      expect(missing.active, isFalse);
      expect(missing.hasImage, isTrue);
      missing.dispose();

      store.images[id] = _pngHeader(64, 64);
      final damaged = WallpaperController();
      await damaged.load(store);
      await damaged.debugRestoring;
      expect(damaged.status, WallpaperStatus.failed);
      expect(damaged.active, isFalse);
      damaged.dispose();
    });

    test('main-window load removes orphaned owned images only', () async {
      final dir = Directory('${root.path}/wallpaper-v1')..createSync();
      final keep = 'cd' * 16, orphan = 'ef' * 16;
      File('${dir.path}/$keep.img').writeAsBytesSync(await _png(8, 8, Colors.red));
      File('${dir.path}/$orphan.img').writeAsBytesSync([1, 2, 3]);
      File('${dir.path}/unrelated.txt').writeAsStringSync('user file');
      File('${dir.path}/settings.json').writeAsStringSync(
        jsonEncode({'v': 1, 'image': keep, 'mode': 'window', 'blur': 0}),
      );
      final child = WallpaperController();
      await child.load(FileWallpaperStore(directory: () async => root));
      await child.debugIdle;
      expect(owned(), hasLength(2)); // child windows never clean up
      child.dispose();
      final main = WallpaperController();
      await main.load(
        FileWallpaperStore(directory: () async => root),
        cleanupStale: true,
      );
      await main.debugRestoring;
      await main.debugIdle;
      expect(owned(), ['$keep.img']);
      expect(File('${dir.path}/unrelated.txt').existsSync(), isTrue);
      expect(main.active, isTrue);
      main.dispose();
    });

    test('unreadable, hung or untrusted settings never delete owned images', () async {
      final keep = 'cd' * 16;
      final png = await _png(16, 16, Colors.red);
      Future<void> expectKept(
        MemoryWallpaperStore store, {
        String? description,
      }) async {
        final main = WallpaperController();
        await main.load(store, cleanupStale: true);
        await main.debugIdle;
        expect(store.images.keys, [keep], reason: description);
        // Mode/blur changes apply but are not persisted over the unknown
        // record (they would drop its image reference).
        final before = store.settings;
        main.setMode(WallpaperLayoutMode.panes);
        main.setBlur(3);
        await main.debugIdle;
        expect(main.mode, WallpaperLayoutMode.panes, reason: description);
        expect(store.settings, before, reason: description);
        expect(main.writeFailed, isTrue, reason: description);
        expect(store.images.keys, [keep], reason: description);
        main.dispose();
      }

      final saved = jsonEncode({'v': 1, 'image': keep, 'mode': 'window', 'blur': 0});
      await expectKept(
        MemoryWallpaperStore(settings: saved, images: {keep: png})
          ..readFailWith = const FileSystemException('locked'),
        description: 'read failure',
      );
      await expectKept(
        MemoryWallpaperStore(settings: saved, images: {keep: png})
          ..readHangs = true,
        description: 'read timeout',
      );
      await expectKept(
        MemoryWallpaperStore(
          settings: '{"v":1,"image":"../escape","blur":2}',
          images: {keep: png},
        ),
        description: 'untrusted image reference',
      );
      await expectKept(
        MemoryWallpaperStore(settings: '{not json', images: {keep: png}),
        description: 'corrupt record',
      );

      // A failed write removes only its own uncommitted copy.
      final failing = MemoryWallpaperStore(
        settings: saved,
        images: {keep: png},
      )..readFailWith = const FileSystemException('locked');
      final main = WallpaperController();
      await main.load(failing, cleanupStale: true);
      failing.failWith = const FileSystemException('full');
      expect(await main.setImageBytes(png), WallpaperImageError.storage);
      await main.debugIdle;
      expect(failing.images.keys, [keep]);
      // An explicit removal is a known state again.
      failing.failWith = null;
      await main.reset();
      await main.debugIdle;
      expect(failing.images, isEmpty);
      main.dispose();
    });

    test('oversized native settings record is unreadable, not absent', () async {
      final dir = Directory('${root.path}/wallpaper-v1')..createSync();
      File('${dir.path}/settings.json').writeAsStringSync('x' * 2048);
      final keep = 'cd' * 16;
      File('${dir.path}/$keep.img').writeAsBytesSync(await _png(8, 8, Colors.red));
      final main = WallpaperController();
      await main.load(
        FileWallpaperStore(directory: () async => root),
        cleanupStale: true,
      );
      await main.debugIdle;
      expect(owned(), ['$keep.img']);
      expect(main.active, isFalse);
      main.dispose();
    });
  });

  group('bounded reads', () {
    test('oversize picker metadata never requests content', () async {
      var listened = false;
      final stream = Stream<List<int>>.multi((controller) {
        listened = true;
        controller.closeSync();
      });
      await expectLater(
        readPickedWallpaperFile(
          PlatformFile(name: 'huge.png', size: wallpaperMaxEncodedBytes + 1, readStream: stream),
        ),
        throwsA(
          isA<WallpaperImageException>().having(
            (e) => e.error,
            'error',
            WallpaperImageError.tooLarge,
          ),
        ),
      );
      expect(listened, isFalse);
    });

    test('a growing or under-reported stream is cut off at the bound', () async {
      var produced = 0;
      var cancelled = false;
      late StreamController<List<int>> source;
      source = StreamController<List<int>>(
        onListen: () async {
          // Never ends on its own: keeps "growing" until cancelled.
          while (!cancelled && produced < 100000) {
            produced++;
            source.add(List<int>.filled(100, 7));
            await Future<void>.delayed(Duration.zero);
          }
        },
        onCancel: () => cancelled = true,
      );
      await expectLater(
        readPickedWallpaperFile(
          PlatformFile(name: 'grow.png', size: 10, readStream: source.stream),
          maxBytes: 1000,
        ),
        throwsA(
          isA<WallpaperImageException>().having(
            (e) => e.error,
            'error',
            WallpaperImageError.tooLarge,
          ),
        ),
      );
      expect(cancelled, isTrue);
      expect(produced, lessThanOrEqualTo(12));
      final exact = await readBoundedWallpaperBytes(
        Stream.fromIterable([List.filled(600, 1), List.filled(400, 2)]),
        maxBytes: 1000,
      );
      expect(exact.length, 1000);
    });

    test('native source and image reads stop at the limit', () async {
      final dir = Directory.systemTemp.createTempSync('wallpaper-read-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final big = File('${dir.path}/big.png')..writeAsBytesSync(List.filled(5000, 1));
      await expectLater(
        readWallpaperSourceFile(big.path, maxBytes: 4096),
        throwsA(isA<WallpaperSourceTooLargeException>()),
      );
      expect(
        (await readWallpaperSourceFile(big.path, maxBytes: 5000)).length,
        5000,
      );
      final store = FileWallpaperStore(directory: () async => dir);
      final id = 'ab' * 16;
      await store.writeImage(id, Uint8List(5000));
      expect(await store.readImage(id, maxBytes: 4096), isNull);
      expect((await store.readImage(id, maxBytes: 5000))!.length, 5000);
    });
  });

  test('a failing blur bake is not retried until the input changes', () async {
    var bakes = 0;
    final controller = WallpaperController(
      bakeBlur: (_, _) async {
        bakes++;
        throw StateError('offscreen rendering unavailable');
      },
    );
    await controller.load(MemoryWallpaperStore());
    expect(await controller.setImageBytes(await _png(64, 40, Colors.blue)), isNull);
    controller.setBlur(10);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(bakes, 1); // one attempt for (image, 10); no 120 ms retry loop
    await controller.debugIdle;
    expect(controller.active, isTrue); // live image filter fallback
    expect(controller.bakedImage, isNull);
    controller.setBlur(14);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(bakes, 2);
    controller.dispose();
  });

  testWidgets(
    'toggling wallpaper, mode and blur keeps pane sessions, drafts and owners',
    (tester) async {
      // Created in the real zone so its storage chain runs under runAsync.
      final controller = (await tester.runAsync(() async {
        final created = WallpaperController();
        await created.load(MemoryWallpaperStore());
        return created;
      }))!;
      final png = await tester.runAsync(() => _png(400, 240, Colors.indigo));
      final log = <String>[];
      final workspace = SessionWorkspaceController()..activate('a');
      workspace.split('b', 'a', SessionSplitEdge.right);
      await tester.pumpWidget(
        _app(
          controller: controller,
          child: Scaffold(
            body: SessionWorkspaceView(
              controller: workspace,
              terminalBuilder: (_, id) => _FakeSession(id, log),
            ),
          ),
        ),
      );
      await tester.enterText(find.byKey(const ValueKey('draft-a')), 'unsent');
      final states = {
        for (final id in ['a', 'b'])
          id: tester.state(find.byWidgetPredicate(
            (w) => w is _FakeSession && w.id == id,
          )),
      };
      double terminalOpacity() => tester
          .widget<TerminalView>(find.byType(TerminalView).first)
          .backgroundOpacity;
      Color scaffoldColor() => Theme.of(
        tester.element(find.byKey(const ValueKey('draft-a'))),
      ).scaffoldBackgroundColor;
      expect(terminalOpacity(), 1);
      expect(find.byType(WallpaperImageLayer), findsNothing);

      // Bounded: a stalled step fails fast instead of hanging the driver.
      Future<void> step(Future<void> Function() change) async {
        await tester.runAsync(
          () => change().timeout(const Duration(seconds: 10)),
        );
        await tester.pump();
      }

      await step(() async => controller.setImageBytes(png!));
      expect(controller.active, isTrue);
      expect(find.byType(WallpaperImageLayer), findsOneWidget); // whole window
      expect(terminalOpacity(), wallpaperTerminalOpacity);
      expect(scaffoldColor(), Colors.transparent); // nested scaffolds in panes

      await step(() async => controller.setMode(WallpaperLayoutMode.panes));
      expect(find.byType(WallpaperImageLayer), findsNWidgets(2)); // one per pane
      await step(() async => controller.setBlur(20, persist: false));
      // Resize and reorder: panes keep their own images and States.
      workspace.resize(workspace.root as SessionWorkspaceSplit, .3);
      await tester.pump();
      workspace.split('a', 'b', SessionSplitEdge.right);
      await tester.pump();
      expect(find.byType(WallpaperImageLayer), findsNWidgets(2));
      await step(() async => controller.setMode(WallpaperLayoutMode.window));
      await step(() async => controller.reset());
      expect(find.byType(WallpaperImageLayer), findsNothing);
      expect(terminalOpacity(), 1);

      expect(log, ['open:a', 'open:b']); // never reopened or closed
      for (final entry in states.entries) {
        expect(
          tester.state(find.byWidgetPredicate(
            (w) => w is _FakeSession && w.id == entry.key,
          )),
          same(entry.value),
        );
      }
      expect(
        (states['a']! as _FakeSessionState).draft.text,
        'unsent',
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () => controller.debugIdle.timeout(const Duration(seconds: 10)),
      );
      controller.dispose();
    },
  );

  for (final locale in AppLocalizationSetup.locales) {
    testWidgets('Theme wallpaper card fits 390 px (${locale.languageCode})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Created in the real zone so its storage chain runs under runAsync.
      final controller = (await tester.runAsync(() async {
        final created = WallpaperController();
        await created.load(MemoryWallpaperStore());
        return created;
      }))!;
      final png = await tester.runAsync(() => _png(300, 200, Colors.orange));
      Uint8List? picked = png;
      await tester.pumpWidget(
        _app(
          controller: controller,
          locale: locale,
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: WallpaperSettings(
                    controller: controller,
                    pickImage: () async => picked,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('wallpaper_reset')), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.byKey(const ValueKey('wallpaper_reset'))).onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('wallpaper_choose')));
      await settle(tester, until: () => controller.active);
      expect(controller.active, isTrue);
      expect(find.byKey(const ValueKey('wallpaper_preview')), findsOneWidget);
      expect(find.byType(WallpaperImageLayer), findsNWidgets(2)); // preview + window

      await tester.tap(find.byKey(const ValueKey('wallpaper_mode_panes')));
      await tester.pump();
      expect(controller.mode, WallpaperLayoutMode.panes);

      // Unsupported content shows an error and keeps the wallpaper.
      picked = Uint8List.fromList(utf8.encode('GIF89a-not-allowed'));
      await tester.tap(find.byKey(const ValueKey('wallpaper_choose')));
      await settle(tester, until: () => controller.lastError != null);
      expect(find.byKey(const ValueKey('wallpaper_error')), findsOneWidget);
      expect(controller.active, isTrue);

      await tester.tap(find.byKey(const ValueKey('wallpaper_reset')));
      await settle(tester, until: () => !controller.active);
      await tester.runAsync(() => controller.debugIdle);
      expect(controller.active, isFalse);
      expect(tester.takeException(), isNull);
      controller.dispose();
    });
  }
}
