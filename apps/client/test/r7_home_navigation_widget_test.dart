import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/home_sidebar.dart';
import 'package:aterm_client/ui/keychain_page.dart';
import 'package:aterm_client/ui/session_logs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _all = [
  HomeDestination.hosts,
  HomeDestination.groups,
  HomeDestination.logs,
  HomeDestination.snippets,
  HomeDestination.keychain,
  HomeDestination.settings,
];

Widget _app(Widget child, {Locale locale = const Locale('en'), TargetPlatform? platform}) {
  debugCurrentL10n = appLocalizationsFor(locale);
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizationSetup.delegates,
    supportedLocales: AppLocalizationSetup.locales,
    theme: buildAppTheme().copyWith(platform: platform),
    home: Scaffold(body: child),
  );
}

Widget _homeWithSidebar(double width, ValueChanged<HomeDestination> onSelect) =>
    Center(
      child: SizedBox(
        width: width,
        height: 640,
        child: LayoutBuilder(
          builder: (context, c) => Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HomeSidebar(
                layout: homeSidebarLayoutFor(c.maxWidth),
                selected: HomeDestination.hosts,
                onSelect: onSelect,
                destinations: _all,
                footerActions: [
                  HomeSidebarAction(
                    id: 'archive',
                    label: 'Archive',
                    icon: Icons.archive,
                    onSelected: () {},
                  ),
                ],
              ),
              const Expanded(child: Placeholder(key: ValueKey('home_body'))),
            ],
          ),
        ),
      ),
    );

void main() {
  tearDown(() => debugCurrentL10n = appLocalizationsFor(const Locale('en')));

  group('HomeSidebar', () {
    testWidgets('always a LEFT column: labelled, rail and phone rail', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final (width, expected, label) in [
        (1200.0, 200.0, true),
        (800.0, 72.0, true),
        (360.0, 52.0, false),
      ]) {
        HomeDestination? picked;
        await tester.pumpWidget(_app(_homeWithSidebar(width, (d) => picked = d)));
        final bar = tester.getRect(find.byKey(const ValueKey('home_sidebar')));
        final body = tester.getRect(find.byKey(const ValueKey('home_body')));
        expect(bar.width, expected);
        // Left of the body and full height: never a strip above content.
        expect(bar.right, lessThanOrEqualTo(body.left));
        expect(bar.height, body.height);
        expect(find.text('Logs'), label ? findsOneWidget : findsNothing);
        await tester.tap(find.byKey(const ValueKey('home_nav_logs')));
        expect(picked, HomeDestination.logs);
        if (!label) {
          expect(find.byTooltip('Keychain'), findsOneWidget);
        }
      }
    });

    testWidgets('touch platforms keep 48dp targets and semantics', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          _homeWithSidebar(360, (_) {}),
          platform: TargetPlatform.android,
        ),
      );
      for (final d in _all) {
        final size = tester.getSize(find.byKey(ValueKey('home_nav_${d.name}')));
        expect(size.height, greaterThanOrEqualTo(48), reason: d.name);
        expect(size.width, greaterThanOrEqualTo(44), reason: d.name);
      }
      expect(
        tester.getSemantics(find.byKey(const ValueKey('home_nav_hosts'))),
        matchesSemantics(
          label: 'Hosts',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('labels localized in zh/ja/ru without overflow', (tester) async {
      for (final code in ['zh', 'ja', 'ru']) {
        final locale = Locale(code);
        await tester.pumpWidget(
          _app(_homeWithSidebar(1200, (_) {}), locale: locale),
        );
        final l10n = appLocalizationsFor(locale);
        expect(find.text(l10n.r7NavLogs), findsOneWidget);
        expect(find.text(l10n.r7NavKeychain), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          _app(_homeWithSidebar(800, (_) {}), locale: locale),
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('4 locales x textScale 1.6 at 340/640/1280 never overflow', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final code in ['en', 'zh', 'ja', 'ru']) {
        for (final width in [340.0, 640.0, 1280.0]) {
          tester.view.physicalSize = Size(width, 700);
          debugCurrentL10n = appLocalizationsFor(Locale(code));
          await tester.pumpWidget(
            MediaQuery(
              data: MediaQueryData(
                size: Size(width, 700),
                textScaler: const TextScaler.linear(1.6),
              ),
              child: MaterialApp(
                locale: Locale(code),
                localizationsDelegates: AppLocalizationSetup.delegates,
                supportedLocales: AppLocalizationSetup.locales,
                theme: buildAppTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(1.6)),
                  child: child!,
                ),
                home: Scaffold(body: _homeWithSidebar(width, (_) {})),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$code@$width');
          final bar = tester.getRect(find.byKey(const ValueKey('home_sidebar')));
          expect(bar.left, lessThanOrEqualTo(0.5), reason: '$code@$width');
        }
      }
    });

    testWidgets('import/export footer menu runs real actions', (tester) async {
      var ran = 0;
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 1200,
            height: 600,
            child: Row(
              children: [
                HomeSidebar(
                  layout: HomeSidebarLayout.labelled,
                  selected: HomeDestination.hosts,
                  onSelect: (_) {},
                  destinations: _all,
                  footerActions: [
                    HomeSidebarAction(
                      id: 'one',
                      label: 'Run one',
                      icon: Icons.upload,
                      onSelected: () => ran++,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('home_nav_import_export')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run one'));
      await tester.pumpAndSettle();
      expect(ran, 1);
    });
  });

  group('SessionLogsPage', () {
    testWidgets('lists, filters, toggles recording and shows details', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final book = SessionLogBook.memory();
      const ok = HostRecord(id: 'a', name: 'alpha', address: 'a.test', username: 'u');
      const bad = HostRecord(id: 'b', name: 'beta', address: 'b.test', username: 'u');
      await book.setRecordTranscripts(true);
      final first = book.begin(host: ok)..markConnected();
      first.output('hello transcript\n');
      first.markClosed(SessionLogEndReason.user);
      book.begin(host: bad).markFailed(StateError('secret text'));
      await book.flush();
      await tester.pumpWidget(_app(SessionLogsPage(book: book)));
      await tester.pumpAndSettle();
      expect(find.textContaining('alpha'), findsOneWidget);
      expect(find.textContaining('beta'), findsOneWidget);
      expect(find.textContaining('secret text'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('session_logs_filter_failed')));
      await tester.pumpAndSettle();
      expect(find.textContaining('alpha'), findsNothing);
      expect(find.textContaining('other error'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('session_logs_filter_all')));
      await tester.enterText(
        find.byKey(const ValueKey('session_logs_search')),
        'alp',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('beta'), findsNothing);
      await tester.tap(find.textContaining('alpha'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('session_log_detail')), findsOneWidget);
      expect(find.text('hello transcript\n'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session_log_delete')));
      await tester.pumpAndSettle();
      expect(book.entries, hasLength(1));

      final toggle = find.byKey(const ValueKey('session_logs_record_toggle'));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(book.recordTranscripts, isFalse);
    });
  });

  group('KeychainPage', () {
    testWidgets('search, filters, usage and blocked delete of referenced', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final deleted = <String>[];
      await tester.pumpWidget(
        _app(
          KeychainPage(
            canWrite: true,
            onAdd: () {},
            onEdit: (_) {},
            onDelete: (e) => deleted.add(e.id),
            entries: const [
              KeychainEntry(
                id: 'pw',
                name: 'deploy password',
                username: 'deploy',
                kind: AuthKind.password,
              ),
              KeychainEntry(
                id: 'key',
                name: 'ops key',
                username: 'ops',
                kind: AuthKind.privateKey,
                keyFingerprint: 'SHA256:abcdef',
                usedBy: ['Host “web”'],
              ),
            ],
          ),
        ),
      );
      expect(find.text('SHA256:abcdef'), findsOneWidget);
      expect(find.textContaining('web'), findsOneWidget);
      // Delete is offered via the actions menu; the owner (repository)
      // refuses referenced items with a notice. Usage is shown up front.
      await tester.tap(find.byKey(const ValueKey('keychain_actions_pw')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete credential').last);
      await tester.pumpAndSettle();
      expect(deleted, ['pw']);
      expect(
        find.byKey(const ValueKey('keychain_usage_key')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('keychain_filter_keys')));
      await tester.pumpAndSettle();
      expect(find.text('deploy password'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('keychain_filter_all')));
      await tester.enterText(
        find.byKey(const ValueKey('keychain_search')),
        'abcdef',
      );
      await tester.pumpAndSettle();
      expect(find.text('ops key'), findsOneWidget);
      expect(find.text('deploy password'), findsNothing);
    });

    test('checkKeychainKey keeps key-only behaviour and rejects garbage cert', () {
      final noCert = checkKeychainKey(privateKey: 'not-a-real-key');
      expect(noCert.error, isNull);
      expect(noCert.certificate, isNull);
      final badCert = checkKeychainKey(
        privateKey: 'not-a-real-key',
        certificateText: 'ssh-ed25519-cert-v01@openssh.com AAAA',
      );
      expect(badCert.error, isNotNull);
    });
  });
}
