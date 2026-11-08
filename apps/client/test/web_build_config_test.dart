import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final bootstrapFile = File('build/web/flutter_bootstrap.js');
  test(
    'release Web bundle uses same-origin CanvasKit and font fallback assets',
    () {
      expect(bootstrapFile.existsSync(), isTrue, reason: 'Build Web first.');
      final bootstrap = bootstrapFile.readAsStringSync();
      const assignment = '_flutter.buildConfig = ';
      final valueStart = bootstrap.indexOf(assignment);
      expect(
        valueStart,
        isNonNegative,
        reason: 'Flutter build config is missing.',
      );
      final jsonStart = valueStart + assignment.length;
      final jsonEnd = bootstrap.indexOf(';', jsonStart);
      expect(jsonEnd, greaterThan(jsonStart));
      final encodedConfig = bootstrap.substring(jsonStart, jsonEnd);
      final config = jsonDecode(encodedConfig) as Map<String, dynamic>;

      expect(
        bootstrap,
        contains("canvasKitBaseUrl: 'canvaskit/'"),
        reason: 'CanvasKit must be loaded from the same application origin.',
      );
      expect(encodedConfig, isNot(contains('gstatic.com/flutter-canvaskit')));
      expect(config, isNot(contains('canvasKitBaseUrl')));
      expect(
        bootstrap,
        contains("fontFallbackBaseUrl: 'fonts/'"),
        reason: 'CJK font fallback must be served by the application origin.',
      );
      expect(
        bootstrap,
        isNot(contains('https://fonts.gstatic.com')),
        reason: 'The Web application must not depend on a font CDN.',
      );
      expect(
        (config['builds'] as List).any(
          (build) =>
              build is Map &&
              build['compileTarget'] == 'dart2js' &&
              build['renderer'] == 'canvaskit',
        ),
        isTrue,
      );

      for (final path in [
        'build/web/canvaskit/chromium/canvaskit.js',
        'build/web/canvaskit/chromium/canvaskit.wasm',
        'build/web/canvaskit/canvaskit.js',
        'build/web/canvaskit/canvaskit.wasm',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: 'Missing $path.');
      }

      final compiledJs = File('build/web/main.dart.js').readAsStringSync();
      final fallbackPaths = RegExp(
        r'"([^"]+\.woff2)"',
      ).allMatches(compiledJs).map((match) => match.group(1)!).toSet();
      expect(fallbackPaths, isNotEmpty);
      for (final path in fallbackPaths) {
        expect(
          File('build/web/fonts/$path').existsSync(),
          isTrue,
          reason: 'Missing bundled Flutter fallback font: $path',
        );
      }
    },
    skip: bootstrapFile.existsSync()
        ? false
        : 'Release Web bundle is not built; run flutter build web first.',
  );
}
