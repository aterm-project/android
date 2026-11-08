import 'package:aterm_client/ui/app_density.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(
  Widget child, {
  required TargetPlatform platform,
  double textScale = 1,
  Locale locale = const Locale('en'),
}) {
  return MaterialApp(
    theme: buildAppTheme(
      locale: locale,
      platform: platform,
    ).copyWith(platform: platform),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(1280, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets('compact desktop theme is ~90% of Material defaults', (
    tester,
  ) async {
    late ThemeData theme;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) {
            theme = Theme.of(context);
            return const SizedBox();
          },
        ),
        platform: TargetPlatform.windows,
      ),
    );
    final density = AppDensity.of(tester.element(find.byType(SizedBox)));
    expect(density.profile, AppDensityProfile.compact);
    final text = theme.textTheme;
    expect(text.bodyLarge!.fontSize, 14.5);
    expect(text.bodyMedium!.fontSize, 13);
    expect(text.titleLarge!.fontSize, 19);
    expect(text.headlineSmall!.fontSize, 21);
    // M3 line-height ratios survive (no clipped CJK/Cyrillic ascenders).
    expect(text.bodyLarge!.height, greaterThanOrEqualTo(1.2));
    expect(text.titleLarge!.height, greaterThanOrEqualTo(1.2));
    expect(theme.iconTheme.size, 20);
    expect(
      theme.inputDecorationTheme.contentPadding,
      const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
    );
    expect(theme.dialogTheme.titleTextStyle!.fontSize, 19);
  });

  testWidgets('touch keeps 48dp hit targets while glyphs shrink', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        IconButton(
          key: const Key('btn'),
          onPressed: () => taps++,
          icon: const Icon(Icons.add),
        ),
        platform: TargetPlatform.android,
      ),
    );
    final box = tester.getSize(find.byKey(const Key('btn')));
    expect(box.width, greaterThanOrEqualTo(48));
    expect(box.height, greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byIcon(Icons.add)).width, 22);
    // Tap near the hit-box edge still lands.
    final rect = tester.getRect(find.byKey(const Key('btn')));
    await tester.tapAt(rect.topLeft + const Offset(2, 2));
    expect(taps, 1);
  });

  testWidgets('user text scaling is not overridden by density', (tester) async {
    Future<Size> measure(double scale) async {
      await tester.pumpWidget(
        _app(
          const Text('Hosts', key: Key('t')),
          platform: TargetPlatform.windows,
          textScale: scale,
        ),
      );
      return tester.getSize(find.byKey(const Key('t')));
    }

    final normal = await measure(1);
    final large = await measure(1.5);
    expect(large.height, closeTo(normal.height * 1.5, 1.0));
    expect(large.width, closeTo(normal.width * 1.5, 1.0));
  });
}
