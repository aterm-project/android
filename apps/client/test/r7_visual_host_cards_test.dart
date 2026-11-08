import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_card_layout.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

class _CardsController extends AppController {
  _CardsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
  HostRecord? connected;
  @override
  Future<void> openTerminalTab(HostRecord host, {void Function(String)? onTabOpened}) async => connected = host;
}

const _groupId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

void main() {
  test('metrics are compact, text-scale aware and responsive', () {
    final desktop = HostCardMetrics.resolve(textScale: 1, touch: false);
    expect(desktop.extent(withMeta: true), lessThan(76));
    expect(desktop.extent(withMeta: true), lessThan(108 * .7));
    expect(desktop.extent(withMeta: false), lessThan(72));
    final touch = HostCardMetrics.resolve(textScale: 1, touch: true);
    expect(touch.buttonExtent, 48, reason: 'touch hit boxes are 48x48');
    expect(desktop.buttonExtent, 28);
    expect(
      touch.extent(withMeta: true) - desktop.extent(withMeta: true),
      lessThanOrEqualTo(21),
    );
    expect(
      touch.extent(withMeta: true),
      greaterThan(desktop.extent(withMeta: true)),
    );
    final large = HostCardMetrics.resolve(textScale: 2, touch: false);
    expect(
      large.extent(withMeta: true),
      greaterThan(desktop.extent(withMeta: true)),
    );
    expect(desktop.columnsFor(1200), greaterThanOrEqualTo(4));
    expect(desktop.columnsFor(500), 2);
    expect(desktop.columnsFor(300), 1);
    expect(large.columnsFor(1200), lessThan(desktop.columnsFor(1200)));
  });

  testWidgets('cloud Home sidebar opens integrated forwarding and transfer', (tester) async {
    final db = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = _CardsController(
      sodium: await SodiumSumoInit.init(), database: db,
      secureStore: ClientSecureStore(),
    )..stage = ClientStage.workspace
     ..page = WorkspacePage.hosts
     ..activeVault = const VaultDescriptor(
       id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', role: 'owner',
       activeKeyEpoch: '1', membershipVersion: '1', canWrite: true,
     );
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(platform: TargetPlatform.windows),
        home: AppShell(controller: app),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home_nav_forwarding')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ssh-forwarding-page')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('home_nav_import_export')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('home_nav_action_cloud_termius_transfer')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('termius_transfer_dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('termius_transfer_close')));
      await tester.pumpAndSettle();
      expect(app.terminalTabs, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.runAsync(() => db.close());
    }
  });

  for (final (locale, scale, platform) in [
    ('en', 1.0, TargetPlatform.windows),
    ('zh', 1.0, TargetPlatform.windows),
    ('ja', 1.3, TargetPlatform.windows),
    ('ru', 1.6, TargetPlatform.windows),
    ('zh', 1.0, TargetPlatform.android),
    ('ru', 1.3, TargetPlatform.android),
  ]) {
    testWidgets(
      'cloud host cards fit without clipping ($locale, x$scale, ${platform.name})',
      (tester) async {
        final db = ClientDatabase.forTesting(NativeDatabase.memory());
        final app =
            _CardsController(
                sodium: await SodiumSumoInit.init(),
                database: db,
                secureStore: ClientSecureStore(),
              )
              ..stage = ClientStage.workspace
              ..page = WorkspacePage.hosts
              ..activeVault = const VaultDescriptor(
                id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                role: 'owner',
                activeKeyEpoch: '1',
                membershipVersion: '1',
              );
        app.groups.add(
          const GroupRecord(id: _groupId, name: 'Производственные серверы'),
        );
        app.hosts.addAll([
          const HostRecord(
            id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
            name: '本番データベース・プライマリ・東京リージョン',
            address: 'db-primary.tokyo.example.test',
            username: 'administrator',
            port: 22122,
            groupId: _groupId,
            tags: ['prod', 'db', 'tokyo'],
          ),
          const HostRecord(
            id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            name: 'Staging',
            address: 'stage.example.test',
            username: 'root',
          ),
        ]);
        try {
          for (final width in [1280.0, 640.0, 340.0]) {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            await tester.pumpWidget(
              MaterialApp(
                theme: buildAppTheme().copyWith(platform: platform),
                locale: Locale(locale),
                localizationsDelegates: AppLocalizationSetup.delegates,
                supportedLocales: AppLocalizationSetup.locales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: AppShell(controller: app),
              ),
            );
            await tester.pumpAndSettle();
            if (platform == TargetPlatform.android) {
              final hit = tester.getSize(find.byKey(const ValueKey('home_nav_forwarding')));
              expect(hit.height, greaterThanOrEqualTo(48));
              expect(hit.width, greaterThanOrEqualTo(48));
            }
            // Full-page assertion: any overflow anywhere fails the test.
            final error = tester.takeException();
            expect(
              error,
              isNull,
              reason:
                  '$width: ${error is FlutterError ? error.toStringDeep() : error}',
            );
            final card = find.byKey(
              const ValueKey(
                'host_connect_cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              ),
            );
            expect(card, findsOneWidget);
            final metrics = HostCardMetrics.resolve(
              textScale: scale,
              touch: platform == TargetPlatform.android,
            );
            final height = tester.getSize(card).height;
            // Much denser than R6a's fixed 108 px at the default text size.
            if (scale == 1 && platform == TargetPlatform.windows) {
              expect(height, lessThan(76), reason: '$width');
            }
            expect(
              height,
              lessThanOrEqualTo(metrics.extent(withMeta: true)),
              reason: '$width',
            );
            // Name and endpoint stay inside the card (ellipsized, not cut).
            final cardRect = tester.getRect(card);
            for (final text in [
              find.descendant(
                of: card,
                matching: find.text('本番データベース・プライマリ・東京リージョン'),
              ),
              find.descendant(
                of: card,
                matching: find.textContaining('administrator@'),
              ),
            ]) {
              final rect = tester.getRect(text);
              expect(rect.top, greaterThanOrEqualTo(cardRect.top));
              expect(rect.bottom, lessThanOrEqualTo(cardRect.bottom));
            }
            // Trailing favorite/overflow buttons: real hit boxes, 48x48 on
            // touch platforms and 28x28 on desktop pointer platforms.
            final favorite = find.descendant(
              of: card,
              matching: find.byType(IconButton),
            );
            final overflow = find.descendant(
              of: card,
              matching: find.byIcon(Icons.more_horiz),
            );
            final expected = platform == TargetPlatform.android ? 48.0 : 28.0;
            expect(tester.getSize(favorite), Size(expected, expected));
            final overflowBox = tester.getSize(
              find
                  .ancestor(of: overflow, matching: find.byType(InkWell))
                  .first,
            );
            expect(overflowBox, Size(expected, expected));
            if (platform == TargetPlatform.android && width == 1280) {
              // Real 48 dp hit region: a tap 2 px inside the corner of the
              // overflow box opens the host menu.
              final box = tester.getRect(
                find
                    .ancestor(of: overflow, matching: find.byType(InkWell))
                    .first,
              );
              await tester.tapAt(box.topLeft + const Offset(2, 2));
              await tester.pumpAndSettle();
              final menuItem = find.byKey(
                const ValueKey(
                  'host-connect-cccccccc-cccc-4ccc-8ccc-cccccccccccc',
                ),
              );
              expect(menuItem, findsOneWidget);
              await tester.tapAt(const Offset(4, 890));
              await tester.pumpAndSettle();
              expect(menuItem, findsNothing);
            }
            if (width >= 360) {
              // Group metadata is preserved on the wider layouts.
              expect(
                find.byKey(
                  const ValueKey(
                    'host-group-tag-cccccccc-cccc-4ccc-8ccc-cccccccccccc',
                  ),
                ),
                findsOneWidget,
              );
            }
          }
          await tester.tap(
            find.byKey(
              const ValueKey('host_connect_dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
            ),
          );
          await tester.pumpAndSettle();
          expect(app.connected?.name, 'Staging');
        } finally {
          await tester.pumpWidget(const SizedBox());
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          app.dispose();
          await db.close();
        }
      },
    );
  }
}
