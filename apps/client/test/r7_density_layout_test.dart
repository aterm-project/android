import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_density.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _host = HostRecord(
  id: 'h1',
  name: 'Production database primary',
  address: 'db-primary.internal.example.test',
  port: 2222,
  username: 'operator',
);

class _Case {
  const _Case(this.label, this.size, this.platform, this.textScale);
  final String label;
  final Size size;
  final TargetPlatform platform;
  final double textScale;
}

const _cases = [
  _Case('desktop', Size(1280, 800), TargetPlatform.windows, 1),
  _Case('desktop-small-window', Size(720, 560), TargetPlatform.windows, 1),
  _Case('desktop-text130', Size(1280, 800), TargetPlatform.windows, 1.3),
  _Case('phone', Size(360, 720), TargetPlatform.android, 1),
  _Case('phone-text150', Size(360, 720), TargetPlatform.android, 1.5),
];

const _locales = [Locale('en'), Locale('zh'), Locale('ja'), Locale('ru')];

/// Runs [body] and returns every Flutter framework error with its full
/// diagnostics (including the error-causing widget location), so an overflow
/// failure names the exact Row/Column instead of just "overflowed by N px".
Future<List<String>> _collectErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) => errors.add(
    details.toDiagnosticsNode().toStringDeep().split('\n').take(40).join('\n'),
  );
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

Future<void> _pump(
  WidgetTester tester,
  _Case c,
  Locale locale,
  Widget home,
) async {
  tester.view.physicalSize = c.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = c.textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizationSetup.delegates,
      supportedLocales: AppLocalizationSetup.locales,
      theme: buildAppTheme(
        locale: locale,
        platform: c.platform,
      ).copyWith(platform: c.platform),
      home: home,
    ),
  );
  await tester.pumpAndSettle();
}

List<SettingsSection> _sections() => [
  for (final id in ['general', 'terminal', 'security'])
    SettingsSection(
      id: id,
      title: 'Section $id',
      icon: Icons.tune,
      description:
          'Description for $id with enough words to wrap on a narrow window '
          'and still stay readable.',
      builder: (context) => SettingsCards(
        children: [
          SettingsCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.l10n.settings,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextField(
                  key: ValueKey('field_$id'),
                  decoration: InputDecoration(labelText: context.l10n.name),
                ),
                SwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  title: Text(context.l10n.settings),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
];

void main() {
  for (final c in _cases) {
    for (final locale in _locales) {
      testWidgets(
        'host editor fits and edits: ${c.label} ${locale.languageCode}',
        (tester) async {
          final errors = await _collectErrors(() async {
            await _pump(
              tester,
              c,
              locale,
              const Scaffold(
                body: HostEditorPanel(groups: [], hosts: [], existing: _host),
              ),
            );
            expect(tester.takeException(), isNull);
            final density = AppDensity.of(
              tester.element(find.byType(HostEditorPanel)),
            );
            expect(
              density.profile,
              c.platform == TargetPlatform.windows
                  ? AppDensityProfile.compact
                  : AppDensityProfile.touch,
            );
            // Panel never wider than the window; compact desktop is narrower
            // than the R6a 540px panel.
            final dialog = tester.getRect(
              find
                  .descendant(
                    of: find.byType(Dialog),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            expect(dialog.width, lessThanOrEqualTo(c.size.width));
            if (density.isCompact && c.size.width > 600) {
              expect(dialog.width, lessThan(540));
            }

            // Text input still edits normally (IME-free path).
            final name = find.byKey(const ValueKey('host_editor_name'));
            await tester.ensureVisible(name);
            await tester.pumpAndSettle();
            await tester.enterText(name, 'renamed host');
            await tester.pump();
            expect(find.text('renamed host'), findsOneWidget);

            // Inputs keep a usable height (touch: >= 48dp hit target).
            final fieldHeight = tester.getSize(name).height;
            expect(
              fieldHeight,
              // Compact desktop ~90% of R6a's 48px (pointer); touch keeps 48dp.
              greaterThanOrEqualTo(density.isCompact ? 40 : 48),
            );

            // Helper copy is never truncated (wraps under user text scale).
            final decorators = tester.widgetList<InputDecorator>(
              find.byType(InputDecorator),
            );
            for (final decorator in decorators) {
              final theme = Theme.of(
                tester.element(find.byType(HostEditorPanel)),
              ).inputDecorationTheme;
              final resolved = decorator.decoration.applyDefaults(theme);
              if (resolved.helperText != null) {
                expect(resolved.helperMaxLines, greaterThanOrEqualTo(2));
              }
            }

            // Save stays reachable and hittable.
            final save = find.byKey(const ValueKey('host_editor_save'));
            await tester.ensureVisible(save);
            await tester.pumpAndSettle();
            expect(save.hitTestable(), findsOneWidget);
            if (!density.isCompact) {
              expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
            }
            expect(tester.takeException(), isNull);
          });
          expect(errors, isEmpty);
        },
      );

      testWidgets('settings scaffold fits: ${c.label} ${locale.languageCode}', (
        tester,
      ) async {
        final errors = await _collectErrors(() async {
          await _pump(
            tester,
            c,
            locale,
            Scaffold(body: SettingsScaffold(sections: _sections())),
          );
          expect(tester.takeException(), isNull);
          final field = find.byKey(const ValueKey('field_general'));
          await tester.enterText(field, 'abc');
          await tester.pump();
          expect(find.text('abc'), findsOneWidget);
          if (c.size.width >= 700) {
            await tester.tap(
              find.byKey(const ValueKey('settings_category_security')),
            );
            await tester.pumpAndSettle();
            expect(
              find.byKey(const ValueKey('field_security')),
              findsOneWidget,
            );
          }
          expect(tester.takeException(), isNull);
        });
        expect(errors, isEmpty);
      });
    }
  }

  // Root handoff: R6a status bar overflowed 30px at 340px, ru, text 1.6.
  for (final width in [340.0, 360.0, 1024.0]) {
    for (final scale in [1.0, 1.6]) {
      for (final locale in _locales) {
        for (final withTransfer in [false, true]) {
          testWidgets('status bar fits: ${width.toInt()}px x$scale '
              '${locale.languageCode} transfer=$withTransfer', (tester) async {
            var opened = 0;
            final errors = await _collectErrors(() async {
              await _pump(
                tester,
                _Case('bar', Size(width, 640), TargetPlatform.android, scale),
                locale,
                Scaffold(
                  body: const SizedBox.expand(),
                  bottomNavigationBar: Builder(
                    builder: (context) => WorkspaceStatusBar(
                      status: context.l10n.sshDisconnected,
                      detail: [
                        'operator@db-primary.internal.example.test:2222',
                        'Production vault',
                        context.l10n.pendingCountShort(12),
                      ].join(' · '),
                      sessionCount: 12,
                      onProperties: () => opened++,
                      transfer: withTransfer
                          ? const Text(
                              'Uploading 3 files · 42%',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11),
                            )
                          : null,
                    ),
                  ),
                ),
              );
              final bar = find.byKey(const ValueKey('workspace_status_bar'));
              expect(bar, findsOneWidget);
              final size = tester.getSize(bar);
              expect(size.width, lessThanOrEqualTo(width));
              // Height follows text scale (never clips glyphs).
              expect(size.height, greaterThanOrEqualTo(28));
              expect(
                size.height,
                greaterThanOrEqualTo(11 * scale * 1.4 + 12 - 0.01),
              );
              expect(find.text('12 SSH'), findsOneWidget);
              await tester.tap(find.textContaining('operator@'));
              expect(opened, 1);
              expect(tester.takeException(), isNull);
            });
            expect(errors, isEmpty);
          });
        }
      }
    }
  }

  testWidgets('compact theme adds no transform: pointer maps 1:1', (
    tester,
  ) async {
    const c = _Case('desktop', Size(1280, 800), TargetPlatform.windows, 1);
    Offset? local;
    Offset? global;
    await _pump(
      tester,
      c,
      const Locale('en'),
      Scaffold(
        body: Padding(
          padding: const EdgeInsets.only(left: 100, top: 60),
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              local = event.localPosition;
              global = event.position;
            },
            child: const SizedBox(
              key: ValueKey('surface'),
              width: 640,
              height: 400,
            ),
          ),
        ),
      ),
    );
    final origin = tester.getTopLeft(find.byKey(const ValueKey('surface')));
    final gesture = await tester.startGesture(
      origin + const Offset(320, 200),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    expect(global, origin + const Offset(320, 200));
    expect(local, const Offset(320, 200));
    expect(
      tester.getSize(find.byKey(const ValueKey('surface'))),
      const Size(640, 400),
    );
  });
}
