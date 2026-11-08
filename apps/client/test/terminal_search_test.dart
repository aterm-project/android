import 'dart:async';

import 'package:aterm_client/l10n/l10n.dart';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/terminal_search.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'search status follows locale, count grammar, limits and state priority',
    () {
      final previous = currentL10n;
      addTearDown(() => debugCurrentL10n = previous);
      final expected = <String, List<String>>{
        'en': [
          'Query too long',
          'Searching…',
          '0 matches',
          '1 of 1 match',
          '2 of 3 matches',
          '2 of 3 matches · results limited',
        ],
        'zh': [
          '查询过长',
          '正在搜索…',
          '0 处匹配',
          '第 1 / 1 处匹配',
          '第 2 / 3 处匹配',
          '第 2 / 3 处匹配 · 结果已限制',
        ],
        'ja': [
          '検索語が長すぎます',
          '検索中…',
          '一致なし',
          '1 件中 1 件目',
          '3 件中 2 件目',
          '3 件中 2 件目 · 検索結果は制限されています',
        ],
        'ru': [
          'Слишком длинный запрос',
          'Поиск…',
          'Нет совпадений',
          '1 из 1 совпадения',
          '2 из 3 совпадений',
          '2 из 3 совпадений · результаты ограничены',
        ],
      };
      for (final entry in expected.entries) {
        debugCurrentL10n = appLocalizationsFor(Locale(entry.key));
        String label({
          int total = 0,
          int selected = -1,
          bool limited = false,
          bool pending = false,
          bool tooLong = false,
        }) => terminalSearchCountLabel(
          matchCount: total,
          selectedIndex: selected,
          truncated: limited,
          searching: pending,
          queryTooLong: tooLong,
        );
        expect(
          label(tooLong: true, pending: true, limited: true),
          entry.value[0],
          reason: entry.key,
        );
        expect(
          label(pending: true, limited: true),
          entry.value[1],
          reason: entry.key,
        );
        expect(label(), entry.value[2], reason: entry.key);
        expect(label(total: 1, selected: 0), entry.value[3], reason: entry.key);
        expect(label(total: 3, selected: 1), entry.value[4], reason: entry.key);
        expect(
          label(total: 3, selected: 1, limited: true),
          entry.value[5],
          reason: entry.key,
        );
        // Zero results may also be truncated by a row/cell scan limit.
        expect(
          label(limited: true),
          currentL10n.terminalSearchLimitedCount(entry.value[2]),
          reason: entry.key,
        );
      }
    },
  );

  group('searchTerminalBuffer', () {
    test('reports bounded-result truncation in the hit count', () {
      expect(
        terminalSearchCountLabel(
          matchCount: 2,
          selectedIndex: 0,
          truncated: true,
          searching: false,
        ),
        '1 of 2 matches · results limited',
      );
      expect(
        terminalSearchCountLabel(
          matchCount: 0,
          selectedIndex: -1,
          truncated: true,
          searching: false,
        ),
        '0 matches · results limited',
      );
      expect(
        terminalSearchCountLabel(
          matchCount: 0,
          selectedIndex: -1,
          truncated: false,
          searching: false,
          queryTooLong: true,
        ),
        'Query too long',
      );
    });

    test('matches case-insensitively and ignores parsed ANSI sequences', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('\u001b[31mServer READY: 服务可用\u001b[0m');

      final latin = searchTerminalBuffer(terminal, 'server ready');
      final cjk = searchTerminalBuffer(terminal, '服务可用');

      expect(latin.matches, hasLength(1));
      expect(cjk.matches, hasLength(1));
      expect(latin.matches.single.start.y, latin.matches.single.end.y);
      expect(cjk.matches.single.start.x, 14);
      expect(cjk.matches.single.end.x, 22);
      expect(terminal.buffer.getText(), contains('服务可用'));
      expect(terminal.buffer.getText(), isNot(contains('\u001b[31m')));
    });

    test('matches Greek final and ordinary sigma case-insensitively', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('ΟΣ\r\nος');

      final result = searchTerminalBuffer(terminal, 'ος');

      expect(result.matches, hasLength(2));
      expect(result.matches.map((match) => match.start.y), [0, 1]);
    });

    test('matches decomposed combining runes at their base cell', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('Cafe\u0301 au lait');

      final result = searchTerminalBuffer(terminal, 'cafe\u0301');

      expect(result.matches, hasLength(1));
      expect(result.matches.single.start.x, 0);
      // The zero-width accent shares the preceding `e` cell for highlighting.
      expect(result.matches.single.end.x, 4);
    });

    test('keeps sparse erased cells as spaces instead of joining text', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(20, 2);
      terminal.write('aXb\u001b[2G\u001b[X');

      final falsePositive = searchTerminalBuffer(terminal, 'ab');
      final withBlank = searchTerminalBuffer(terminal, 'a b');

      expect(terminal.buffer.lines[0].getTrimmedLength(terminal.viewWidth), 3);
      expect(terminal.buffer.lines[0].getCodePoint(1), 0);
      expect(terminal.buffer.lines[0].getWidth(1), 0);
      expect(falsePositive.matches, isEmpty);
      expect(withBlank.matches, hasLength(1));
    });

    test('does not map a combining rune back across an erased blank', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(20, 2);
      terminal.write('aX\u0301b\u001b[2G\u001b[X');

      final result = searchTerminalBuffer(terminal, ' \u0301');

      expect(terminal.buffer.lines[0].getCodePoint(1), 0);
      expect(terminal.buffer.lines[0].getCodePoint(2), 0x0301);
      expect(result.matches, hasLength(1));
      expect(result.matches.single.start.x, 1);
      expect(result.matches.single.end.x, 3);
    });

    test('does not match a query across a hard row break', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(40, 3);
      terminal.write('alpha\r\nbeta');

      expect(searchTerminalBuffer(terminal, 'alpha\nbeta').matches, isEmpty);
      expect(searchTerminalBuffer(terminal, 'alpha').matches, hasLength(1));
      expect(searchTerminalBuffer(terminal, 'beta').matches, hasLength(1));
    });

    test('finds overlapping literal matches with a linear matcher', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(20, 2);
      terminal.write('aaaa');

      final result = searchTerminalBuffer(terminal, 'aa');

      expect(result.matches, hasLength(3));
      expect(result.matches.map((match) => match.start.x), [0, 1, 2]);
    });

    test('finds a literal match across rows wrapped by the terminal', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(8, 3);
      terminal.write('ABCDEFGHIJKLMN');

      final matches = searchTerminalBuffer(terminal, 'hij');

      expect(matches.matches, hasLength(1));
      expect(
        matches.matches.single.start.y,
        lessThan(matches.matches.single.end.y),
      );
      expect(matches.matches.single.start.x, 7);
      expect(matches.matches.single.end.x, 2);
    });

    test('limits scanning to the newest configured number of rows', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(40, 2);
      terminal.write('older marker\r\nnewer marker\r\nlatest marker');

      expect(
        searchTerminalBuffer(terminal, 'older', maxRows: 2).matches,
        isEmpty,
      );
      final latest = searchTerminalBuffer(terminal, 'latest', maxRows: 2);
      expect(latest.matches, hasLength(1));
      expect(latest.truncated, isTrue);
    });

    test('caps scanned cells and reports omitted content', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(40, 2);
      terminal.write('marker marker marker');

      final result = searchTerminalBuffer(
        terminal,
        'marker',
        maxScannedCells: 10,
      );

      expect(result.matches, hasLength(1));
      expect(result.scannedCells, 10);
      expect(result.truncated, isTrue);
    });

    test('caps hit count and marks the result as limited', () {
      final terminal = Terminal(maxLines: 100);
      terminal.resize(40, 2);
      terminal.write('x x x x');

      final result = searchTerminalBuffer(terminal, 'x', maxMatches: 2);

      expect(result.matches, hasLength(2));
      expect(result.truncated, isTrue);
    });

    test('empty queries and absent text have no matches', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('visible text');

      expect(searchTerminalBuffer(terminal, '').matches, isEmpty);
      expect(searchTerminalBuffer(terminal, 'not present').matches, isEmpty);
    });

    test('rejects an overlong code-unit query before scanning', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('some visible text');

      final result = searchTerminalBuffer(
        terminal,
        'x' * (terminalSearchMaxQueryCodeUnits + 1),
      );

      expect(result.matches, isEmpty);
      expect(result.scannedCells, 0);
      expect(result.queryTooLong, isTrue);
    });
  });

  testWidgets('terminal search navigates highlighted hits without SSH input', (
    tester,
  ) async {
    final language = AppLanguageController(
      systemLocales: () => [const Locale('en')],
    );
    addTearDown(() {
      language.dispose();
      debugCurrentL10n = appLocalizationsFor(fallbackAppLocale);
    });
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final connections = {
      'host-search': _RecordingConnection(),
      'host-beta': _RecordingConnection(),
    };
    final identity = DeviceIdentity.create(sodium);
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorForTesting: ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => connections[host.id]!,
          )
          ..session = AuthSession(
            accountId: 'account-test',
            accessToken: 'access-test',
            expiresIn: 3600,
            refreshToken: 'refresh-test',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.terminal
          ..activeVault = const VaultDescriptor(
            id: '11111111-1111-4111-8111-111111111111',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..credentials.addAll([
            const CredentialRecord(
              id: 'credential-search',
              name: 'Search credential',
              username: 'tester',
              secret: 'test-only-secret',
            ),
            const CredentialRecord(
              id: 'credential-beta',
              name: 'Beta credential',
              username: 'tester',
              secret: 'test-only-secret',
            ),
          ]);
    const host = HostRecord(
      id: 'host-search',
      name: 'Search host',
      address: 'search.example.test',
      username: 'tester',
      credentialId: 'credential-search',
    );
    const betaHost = HostRecord(
      id: 'host-beta',
      name: 'Beta host',
      address: 'beta.example.test',
      username: 'tester',
      credentialId: 'credential-beta',
    );
    var shellMounted = false;
    final previousTargetPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;

    try {
      await app.openTerminalTab(host);
      final alphaTab = app.activeTerminalTab!;
      connections['host-search']!.emit(
        '\r\nFIRST SearchMarker\r\nSECOND searchmarker\r\n',
      );
      await app.openTerminalTab(betaHost);
      final betaTab = app.activeTerminalTab!;
      connections['host-beta']!.emit('\r\nBETA-ONLY\r\n');
      await tester.pumpWidget(
        AppLanguageHost(
          controller: language,
          builder: (_, locale) => MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: buildAppTheme(locale: locale),
            home: AnimatedBuilder(
              animation: app,
              builder: (context, _) => AppShell(controller: app),
            ),
          ),
        ),
      );
      shellMounted = true;
      await tester.pump();

      await _openTerminalAction(tester, 'terminal-search');
      await tester.pumpAndSettle();
      final searchField = _terminalSearchField();
      final betaSearchTextField = tester.widget<TextField>(searchField);
      expect(betaSearchTextField.maxLength, terminalSearchMaxQueryGraphemes);
      expect(
        betaSearchTextField.maxLengthEnforcement,
        MaxLengthEnforcement.enforced,
      );
      await tester.enterText(searchField, 'x' * 257);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(searchField).controller!.text,
        hasLength(terminalSearchMaxQueryGraphemes),
      );
      final overlongCombiningQuery = 'e${'\u0301' * 1024}';
      await tester.enterText(searchField, overlongCombiningQuery);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(searchField).controller!.text.length,
        greaterThan(terminalSearchMaxQueryCodeUnits),
      );
      expect(find.text('Query too long'), findsOneWidget);
      await tester.enterText(searchField, 'beta-only');
      await tester.pumpAndSettle();
      expect(find.text('1 of 1 match'), findsOneWidget);
      final betaSearchController = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .controller!;
      expect(connections['host-beta']!.inputs, isEmpty);
      final betaTerminalState = tester.state(find.byType(TerminalView));
      await language.setPreference(AppLanguage.chinese);
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 1 处匹配'), findsOneWidget);
      expect(
        tester.widget<TextField>(_terminalSearchField()).controller!.text,
        'beta-only',
      );
      expect(tester.state(find.byType(TerminalView)), same(betaTerminalState));
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).controller,
        same(betaSearchController),
      );
      expect(app.activeTerminalTab, same(betaTab));
      expect(connections['host-beta']!.inputs, isEmpty);
      await language.setPreference(AppLanguage.english);
      await tester.pumpAndSettle();
      expect(find.text('1 of 1 match'), findsOneWidget);

      await tester.tap(
        find.bySemanticsLabel('Search host terminal tab, connected, inactive'),
      );
      await tester.pumpAndSettle();
      await _sendDefaultTerminalShortcut(
        tester,
        key: LogicalKeyboardKey.keyF,
        character: 'F',
        shift: true,
      );
      final alphaSearchField = _terminalSearchField();
      expect(alphaSearchField, findsOneWidget);
      await tester.enterText(alphaSearchField, 'searchmarker');
      await tester.pumpAndSettle();

      expect(find.text('1 of 2 matches'), findsOneWidget);
      final alphaSearchController = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .controller!;
      expect(alphaSearchController, isNot(same(betaSearchController)));
      expect(
        tester
            .widget<TerminalView>(find.byType(TerminalView))
            .controller!
            .highlights,
        hasLength(3),
      );
      final alphaHighlights = alphaSearchController.highlights;
      expect(
        alphaHighlights.where(
          (highlight) => highlight.color == const Color(0xFF514A2F),
        ),
        hasLength(2),
      );
      expect(
        alphaHighlights.where(
          (highlight) => highlight.color == const Color(0xFF8A6620),
        ),
        hasLength(1),
      );
      expect(connections['host-search']!.inputs, isEmpty);

      await tester.tap(find.byTooltip('Next match'));
      await tester.pump();
      expect(find.text('2 of 2 matches'), findsOneWidget);
      expect(alphaSearchController.highlights, hasLength(3));
      expect(
        alphaSearchController.highlights.where(
          (highlight) => highlight.color == const Color(0xFF514A2F),
        ),
        hasLength(2),
      );
      expect(
        alphaSearchController.highlights.where(
          (highlight) => highlight.color == const Color(0xFF8A6620),
        ),
        hasLength(1),
      );
      expect(connections['host-search']!.inputs, isEmpty);

      await tester.tap(find.byTooltip('Previous match'));
      await tester.pump();
      expect(find.text('1 of 2 matches'), findsOneWidget);
      expect(connections['host-search']!.inputs, isEmpty);

      await _sendDefaultTerminalShortcut(
        tester,
        key: LogicalKeyboardKey.keyG,
        character: 'g',
      );
      expect(find.text('2 of 2 matches'), findsOneWidget);
      expect(connections['host-search']!.inputs, isEmpty);
      await _sendDefaultTerminalShortcut(
        tester,
        key: LogicalKeyboardKey.keyG,
        character: 'G',
        shift: true,
      );
      expect(find.text('1 of 2 matches'), findsOneWidget);
      expect(connections['host-search']!.inputs, isEmpty);

      await tester.enterText(alphaSearchField, 'absent-marker');
      await tester.pumpAndSettle();
      expect(find.text('0 matches'), findsOneWidget);
      expect(alphaSearchController.highlights, isEmpty);
      expect(connections['host-search']!.inputs, isEmpty);

      app.activateTerminalTab(betaTab.id);
      await tester.pumpAndSettle();
      final restoredBetaSearchField = _terminalSearchField();
      expect(
        tester.widget<TextField>(restoredBetaSearchField).controller!.text,
        'beta-only',
      );
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).controller,
        same(betaSearchController),
      );
      expect(connections['host-beta']!.inputs, isEmpty);

      app.activateTerminalTab(alphaTab.id);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('terminal-tools-close')));
      await tester.pump();
      expect(_terminalSearchField(), findsNothing);
      expect(
        connections.values.every((connection) => connection.inputs.isEmpty),
        isTrue,
      );
      expect(app.terminalTabFor(alphaTab.id), same(alphaTab));
      expect(app.terminalTabFor(betaTab.id), same(betaTab));
      expect(alphaTab.connection, same(connections['host-search']));
      expect(alphaTab.connectionCancellation, isNull);
      expect(alphaTab.outputSubscription, isNotNull);

      await _sendDefaultTerminalShortcut(
        tester,
        key: LogicalKeyboardKey.keyD,
        character: 'D',
        shift: true,
      );
      expect(app.terminalTabFor(alphaTab.id), isNull);
      expect(alphaTab.closed, isTrue);
      expect(alphaTab.state, 'closed');
      expect(alphaTab.connection, isNull);
      expect(alphaTab.connectionCancellation, isNull);
      expect(alphaTab.outputSubscription, isNull);
      expect(app.terminalTabs, [betaTab]);
      expect(app.activeTerminalTabId, betaTab.id);
      expect(app.activeTerminalTab, same(betaTab));
      expect(betaTab.connection, same(connections['host-beta']));
      expect(betaTab.state, 'connected');
      await tester.runAsync(
        () => connections['host-search']!.subscriptionCancelledFuture.timeout(
          const Duration(seconds: 2),
        ),
      );
      await tester.runAsync(
        () => connections['host-search']!.closedFuture.timeout(
          const Duration(seconds: 2),
        ),
      );
      expect(connections['host-search']!.closed, isTrue);
      expect(connections['host-beta']!.closed, isFalse);
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).controller,
        same(betaSearchController),
      );
      expect(
        connections.values.every((connection) => connection.inputs.isEmpty),
        isTrue,
      );
    } finally {
      if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = previousTargetPlatform;
      app.dispose();
      await database.close();
    }
  });
}

Finder _terminalSearchField() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.key == const ValueKey('terminal-sidebar-query'),
);

Future<void> _sendDefaultTerminalShortcut(
  WidgetTester tester, {
  required LogicalKeyboardKey key,
  required String character,
  bool shift = false,
}) async {
  final terminalView = find.byType(TerminalView);
  expect(terminalView, findsOneWidget);
  await tester.tapAt(tester.getTopLeft(terminalView) + const Offset(12, 40));
  await tester.pump();
  // xterm keeps a double-tap window after every terminal tap. There may be no
  // scheduled frame for pumpAndSettle to advance that timer, so drain it before
  // the widget test tears down.
  await tester.pump(const Duration(milliseconds: 350));

  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await tester.sendKeyEvent(key, character: character);
  } finally {
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pumpAndSettle();
}

class _RecordingConnection implements SshConnection {
  final _subscriptionCancelledCompleter = Completer<void>();
  _RecordingConnection() {
    _output = StreamController<String>.broadcast(
      sync: true,
      onCancel: _markSubscriptionCancelled,
    );
  }

  late final StreamController<String> _output;
  final _closedCompleter = Completer<void>();
  final inputs = <String>[];
  bool closed = false;

  Future<void> get subscriptionCancelledFuture =>
      _subscriptionCancelledCompleter.future;

  Future<void> get closedFuture => _closedCompleter.future;

  void _markSubscriptionCancelled() {
    if (!_subscriptionCancelledCompleter.isCompleted) {
      _subscriptionCancelledCompleter.complete();
    }
  }

  void emit(String text) => _output.add(text);

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) => inputs.add(text);

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    try {
      if (!_output.isClosed) await _output.close();
    } finally {
      if (!_closedCompleter.isCompleted) _closedCompleter.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _openTerminalAction(WidgetTester tester, String id) async {
  final menu = find.byKey(const ValueKey('terminal_function_menu'));
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
  final action = find.byKey(ValueKey(id));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}
