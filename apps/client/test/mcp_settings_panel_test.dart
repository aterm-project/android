import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/mcp_settings_panel.dart';
import 'package:aterm_client/ui/responsive_layout.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the panel asks the policy layer to do. Only the contract
/// members the panel uses are implemented; anything else fails loudly.
class _FakeMcpService extends ChangeNotifier implements McpService {
  _FakeMcpService({List<HostRecord>? hosts}) : hosts = hosts ?? _hosts(3);

  List<HostRecord> hosts;
  bool isRunning = true;
  int port = 8765;
  bool loading = false;
  bool ready = true;
  bool failWrites = false;
  bool localDevice = true;
  Completer<void>? writeGate;
  McpAccessMode mode = McpAccessMode.readOnly;
  final overrides = <String, McpAccessMode>{};
  final defaultCalls = <McpAccessMode>[];
  final hostCalls = <(String, McpAccessMode?)>[];
  var stopCalls = 0;

  void changed() => notifyListeners();

  @override
  bool get supported => true;
  @override
  bool get running => isRunning;
  @override
  bool get starting => false;
  @override
  bool get workspaceReady => true;
  @override
  Uri? get endpoint =>
      isRunning ? Uri.parse('http://127.0.0.1:$port/mcp') : null;
  @override
  List<McpAuditEntry> get audit => const [];
  @override
  bool get permissionsLoading => loading;
  @override
  bool get permissionsReady => ready;
  @override
  bool get localDeviceAccessApplicable => localDevice;
  @override
  McpAccessMode get defaultAccess => mode;
  @override
  List<HostRecord> get permissionHosts => hosts;
  @override
  McpAccessMode? accessOverrideForHost(String hostId) => overrides[hostId];
  @override
  McpAccessMode effectiveAccessForHost(String hostId) =>
      overrides[hostId] ?? mode;

  @override
  Future<void> setDefaultAccess(McpAccessMode value) async {
    defaultCalls.add(value);
    await writeGate?.future;
    if (failWrites) throw StateError('store unavailable');
    mode = value;
    notifyListeners();
  }

  @override
  Future<void> setHostAccess(String hostId, McpAccessMode? value) async {
    hostCalls.add((hostId, value));
    await writeGate?.future;
    if (failWrites) throw StateError('store unavailable');
    if (value == null) {
      overrides.remove(hostId);
    } else {
      overrides[hostId] = value;
    }
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    isRunning = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

List<HostRecord> _hosts(int count) => [
  for (var i = 0; i < count; i++)
    HostRecord(
      id: 'host-$i',
      // Long, unbreakable names are what overflow phone rows in practice.
      name: i == 0
          ? 'production-database-primary-eu-west-replica-$i'
          : 'server-$i',
      address: '10.0.0.${i + 1}',
      username: 'admin',
    ),
];

Future<void> _pump(
  WidgetTester tester,
  _FakeMcpService service, {
  required Size size,
  Locale locale = const Locale('en'),
  TargetPlatform platform = TargetPlatform.android,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizationSetup.delegates,
      supportedLocales: AppLocalizationSetup.locales,
      theme: buildAppTheme(
        locale: locale,
        platform: platform,
      ).copyWith(platform: platform),
      home: Scaffold(
        // The real settings page, so padding/breakpoints match the app.
        body: SettingsScaffold(
          sections: [
            SettingsSection(
              id: 'mcp',
              title: 'AI / MCP',
              icon: Icons.hub_outlined,
              description: 'MCP',
              builder: (_) => McpSettingsPanel(service: service),
            ),
          ],
        ),
      ),
    ),
  );
  // A loading spinner never settles; pump a few frames instead.
  settle
      ? await tester.pumpAndSettle()
      : await tester.pump(const Duration(milliseconds: 100));
}

Finder _hostField(String id) => find.byKey(ValueKey('mcp_host_access_$id'));

Future<void> _choose(WidgetTester tester, String id, String label) async {
  await tester.ensureVisible(_hostField(id));
  await tester.tap(_hostField(id));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _tapRadio(
  WidgetTester tester,
  McpAccessMode mode, {
  bool settle = true,
}) async {
  final finder = find.byKey(ValueKey('mcp_default_access_${mode.name}'));
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder, warnIfMissed: false);
  settle
      ? await tester.pumpAndSettle()
      : await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('port follows a running listener across updates and recreation', (
    tester,
  ) async {
    final service = _FakeMcpService()..port = 28765;
    await _pump(tester, service, size: const Size(1280, 800));
    TextField field() =>
        tester.widget<TextField>(find.byKey(const ValueKey('mcp_port')));
    expect(field().controller!.text, '28765');
    service.port = 28767;
    service.changed();
    await tester.pump();
    expect(field().controller!.text, '28767');
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, service, size: const Size(1280, 800));
    expect(field().controller!.text, '28767');
  });

  const phone = Size(390, 844);
  const tablet = Size(1024, 768);
  const desktop = Size(1280, 900);

  for (final locale in AppLocalizationSetup.locales) {
    testWidgets(
      'phone 390 px (${locale.languageCode}): every card fits and machine '
      'choices stack at full width',
      (tester) async {
        final service = _FakeMcpService(hosts: _hosts(8))
          ..overrides['host-1'] = McpAccessMode.readWrite;
        await _pump(tester, service, size: phone, locale: locale);
        final l10n = lookupAppLocalizations(locale);

        expect(tester.takeException(), isNull);
        expect(find.text(l10n.mcpMachineAccessTitle), findsOneWidget);
        expect(find.text(l10n.mcpLocalDeviceName), findsOneWidget);
        // The old global switch must not come back: per-machine policy owns it.
        expect(
          find.byKey(const ValueKey('mcp_allow_operations')),
          findsNothing,
        );

        final card = tester.getRect(
          find.byKey(const ValueKey('mcp_machine_access')),
        );
        expect(card.right, lessThanOrEqualTo(phone.width));
        for (final id in [mcpLocalDeviceHostId, 'host-0', 'host-7']) {
          await tester.ensureVisible(_hostField(id));
          await tester.pumpAndSettle();
          final row = tester.getRect(find.byKey(ValueKey('mcp_host_row_$id')));
          final field = tester.getRect(_hostField(id));
          // Stacked: the choice sits under the name and spans the row.
          expect(field.width, closeTo(row.width, 1), reason: id);
          expect(field.right, lessThanOrEqualTo(card.right));
          expect(field.height, greaterThanOrEqualTo(40), reason: 'touch');
        }
        // Each mode description is readable (wraps instead of clipping).
        for (final mode in McpAccessMode.values) {
          expect(
            find.text(mcpAccessModeDescription(l10n, mode)),
            findsOneWidget,
          );
        }
        // Android shows the loopback forwarding command for the live port.
        await tester.ensureVisible(
          find.byKey(const ValueKey('mcp_android_forward_command')),
        );
        expect(find.text('adb forward tcp:8765 tcp:8765'), findsOneWidget);
        expect(find.text(l10n.mcpAndroidBackgroundHint), findsOneWidget);
        expect(
          find.text(l10n.mcpRunningDefaultAccess(l10n.mcpAccessModeReadOnly)),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('mcp_host_custom_host-1')), findsOne);
        expect(find.text(l10n.mcpCustomizedCount(1)), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (size, platform) in [
    (tablet, TargetPlatform.android),
    (desktop, TargetPlatform.windows),
  ]) {
    testWidgets(
      '${size.width.toInt()} px ${platform.name}: name and choice share one '
      'row like the Windows client',
      (tester) async {
        final service = _FakeMcpService();
        await _pump(
          tester,
          service,
          size: size,
          locale: const Locale('ru'),
          platform: platform,
        );
        expect(tester.takeException(), isNull);
        final row = tester.getRect(
          find.byKey(const ValueKey('mcp_host_row_host-0')),
        );
        final field = tester.getRect(_hostField('host-0'));
        expect(field.width, closeTo(220, 1));
        expect(field.right, closeTo(row.right, 1));
        expect(field.center.dy, closeTo(row.center.dy, 4));
        expect(
          find.byKey(const ValueKey('mcp_android_forward_command')),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const ValueKey('mcp_android_background_hint')),
          platform == TargetPlatform.android ? findsOneWidget : findsNothing,
        );
      },
    );
  }

  testWidgets('per-machine choice stores an override and can return to the '
      'default', (tester) async {
    final service = _FakeMcpService();
    await _pump(tester, service, size: phone);
    final l10n = lookupAppLocalizations(const Locale('en'));

    await _choose(tester, 'host-2', l10n.mcpAccessModeReadWrite);
    expect(service.hostCalls, [('host-2', McpAccessMode.readWrite)]);
    expect(find.byKey(const ValueKey('mcp_host_custom_host-2')), findsOne);
    expect(find.text(l10n.mcpCustomizedCount(1)), findsOneWidget);

    await _choose(tester, 'host-2', l10n.mcpHostUseDefault('Read-only'));
    expect(service.hostCalls.last, ('host-2', null));
    expect(service.overrides, isEmpty);
    expect(find.byKey(const ValueKey('mcp_host_custom_host-2')), findsNothing);

    // The hostless local console is its own policy identity, never "no host".
    await _choose(tester, mcpLocalDeviceHostId, l10n.mcpAccessModeDenied);
    expect(service.hostCalls.last, (
      mcpLocalDeviceHostId,
      McpAccessMode.denied,
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('read & write for every machine needs confirmation; narrower '
      'defaults apply directly', (tester) async {
    final service = _FakeMcpService();
    await _pump(tester, service, size: phone, locale: const Locale('zh'));

    await _tapRadio(tester, McpAccessMode.readWrite);
    expect(
      find.byKey(const ValueKey('mcp_confirm_read_write_default')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('mcp_confirm_read_write_cancel')),
    );
    await tester.pumpAndSettle();
    expect(service.defaultCalls, isEmpty);
    expect(service.mode, McpAccessMode.readOnly);

    await _tapRadio(tester, McpAccessMode.readWrite);
    await tester.tap(
      find.byKey(const ValueKey('mcp_confirm_read_write_accept')),
    );
    await tester.pumpAndSettle();
    expect(service.defaultCalls, [McpAccessMode.readWrite]);

    await _tapRadio(tester, McpAccessMode.denied);
    expect(
      find.byKey(const ValueKey('mcp_confirm_read_write_default')),
      findsNothing,
    );
    expect(service.defaultCalls, [
      McpAccessMode.readWrite,
      McpAccessMode.denied,
    ]);
    final l10n = lookupAppLocalizations(const Locale('zh'));
    expect(
      find.text(l10n.mcpRunningDefaultAccess(l10n.mcpAccessModeDenied)),
      findsOneWidget,
    );
  });

  testWidgets('while settings load or are unavailable nothing can be changed '
      'and the status reports denied', (tester) async {
    final service = _FakeMcpService()
      ..loading = true
      ..ready = false
      ..mode = McpAccessMode.readWrite;
    await _pump(tester, service, size: phone, settle: false);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.byKey(const ValueKey('mcp_access_loading')), findsOneWidget);
    expect(_hostField('host-0'), findsNothing);
    expect(_hostField(mcpLocalDeviceHostId), findsNothing);
    await _tapRadio(tester, McpAccessMode.readOnly, settle: false);
    expect(service.defaultCalls, isEmpty);
    expect(
      find.text(l10n.mcpRunningDefaultAccess(l10n.mcpAccessModeDenied)),
      findsOneWidget,
    );

    service
      ..loading = false
      ..changed();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mcp_access_unavailable')),
      findsOneWidget,
    );
    await _tapRadio(tester, McpAccessMode.readOnly);
    expect(service.defaultCalls, isEmpty);
    expect(_hostField('host-0'), findsNothing);

    service
      ..ready = true
      ..changed();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp_access_unavailable')), findsNothing);
    expect(_hostField('host-0'), findsOneWidget);
  });

  testWidgets('a failed save shows an error and the field shows the stored '
      'value again', (tester) async {
    final service = _FakeMcpService()..failWrites = true;
    await _pump(tester, service, size: phone, locale: const Locale('ja'));
    final l10n = lookupAppLocalizations(const Locale('ja'));

    await _choose(tester, 'host-0', l10n.mcpAccessModeReadWrite);
    expect(service.hostCalls, [('host-0', McpAccessMode.readWrite)]);
    expect(find.byKey(const ValueKey('mcp_access_error')), findsOneWidget);
    expect(find.text(l10n.mcpAccessSaveFailed), findsOneWidget);
    expect(
      find.descendant(
        of: _hostField('host-0'),
        matching: find.text(l10n.mcpHostUseDefault(l10n.mcpAccessModeReadOnly)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a machine is locked while its change is being saved', (
    tester,
  ) async {
    final service = _FakeMcpService()..writeGate = Completer<void>();
    await _pump(
      tester,
      service,
      size: desktop,
      platform: TargetPlatform.windows,
    );
    final l10n = lookupAppLocalizations(const Locale('en'));

    await _choose(tester, 'host-1', l10n.mcpAccessModeDenied);
    expect(service.hostCalls, hasLength(1));
    final defaults = find.text(
      l10n.mcpHostUseDefault(l10n.mcpAccessModeReadOnly),
    );
    final before = defaults.evaluate().length;
    await tester.tap(_hostField('host-1'), warnIfMissed: false);
    await tester.pumpAndSettle();
    // Disabled dropdown opens no menu, so no second write can race the first.
    expect(defaults.evaluate().length, before);
    expect(service.hostCalls, hasLength(1));
    service.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(service.overrides['host-1'], McpAccessMode.denied);
  });

  testWidgets('the local device row appears only where it applies', (
    tester,
  ) async {
    final service = _FakeMcpService()
      ..localDevice = false
      ..overrides[mcpLocalDeviceHostId] = McpAccessMode.readWrite;
    await _pump(tester, service, size: phone);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(_hostField(mcpLocalDeviceHostId), findsNothing);
    expect(find.text(l10n.mcpLocalDeviceName), findsNothing);
    // A stale stored override for a non-applicable identity isn't counted.
    expect(find.text(l10n.mcpCustomizedCount(0)), findsOneWidget);
    service
      ..localDevice = true
      ..changed();
    await tester.pumpAndSettle();
    expect(_hostField(mcpLocalDeviceHostId), findsOneWidget);
    expect(find.text(l10n.mcpCustomizedCount(1)), findsOneWidget);
  });

  testWidgets('large inventories are searchable and paged', (tester) async {
    final service = _FakeMcpService(hosts: _hosts(120));
    await _pump(tester, service, size: phone, locale: const Locale('ru'));
    final l10n = lookupAppLocalizations(const Locale('ru'));

    expect(_hostField('host-49'), findsOneWidget);
    expect(_hostField('host-50'), findsNothing);
    final more = find.byKey(const ValueKey('mcp_machine_show_more'));
    await tester.ensureVisible(more);
    expect(find.text(l10n.mcpShowMoreMachines(70)), findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(_hostField('host-99'), findsOneWidget);
    expect(find.text(l10n.mcpShowMoreMachines(20)), findsOneWidget);

    final search = find.byKey(const ValueKey('mcp_machine_search'));
    await tester.ensureVisible(search);
    await tester.enterText(search, '10.0.0.77');
    await tester.pumpAndSettle();
    expect(_hostField('host-76'), findsOneWidget);
    expect(_hostField('host-1'), findsNothing);
    // The local device row is not part of the inventory filter.
    expect(_hostField(mcpLocalDeviceHostId), findsOneWidget);
    expect(more, findsNothing);

    await tester.enterText(search, 'no-such-machine');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp_machine_no_match')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (size, platform) in [
    (phone, TargetPlatform.android),
    (desktop, TargetPlatform.windows),
  ]) {
    testWidgets(
      'accessibility ${size.width.toInt()} px ${platform.name}: port and '
      'machine fields are their own nodes, sized to the field, with only '
      'their own labels',
      (tester) async {
        final semantics = tester.ensureSemantics();
        // More than 6 hosts, so the machine search field is shown too.
        final service = _FakeMcpService(hosts: _hosts(8))..isRunning = false;
        await _pump(tester, service, size: size, platform: platform);
        final l10n = lookupAppLocalizations(const Locale('en'));
        // Text from elsewhere in the same cards must not leak into a field.
        final unrelated = [
          l10n.externalAiAccess,
          l10n.letExternalAiUseTheHosts,
          l10n.off,
          l10n.readOnlyModeCanStillRead,
          l10n.listensOn127001,
          l10n.mcpAndroidBackgroundHint,
          l10n.mcpMachineAccessTitle,
          l10n.mcpMachineAccessDescription,
          l10n.mcpDefaultAccessTitle,
        ];

        SemanticsNode textFieldNode(Finder field) {
          final node = tester.getSemantics(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          expect(node.flagsCollection.isTextField, isTrue);
          return node;
        }

        void expectOwnText(SemanticsNode node, String expected, String what) {
          final data = node.getSemanticsData();
          final all = '${data.label}\n${data.hint}\n${data.value}';
          expect(all, contains(expected), reason: what);
          for (final text in unrelated) {
            expect(all, isNot(contains(text)), reason: '$what has "$text"');
          }
        }

        void expectRectNear(SemanticsNode node, Finder field, String what) {
          final nodeRect = MatrixUtils.transformRect(
            node.transform ?? Matrix4.identity(),
            node.rect,
          );
          // Node rect is in its parent's coordinates; compare sizes, which
          // are what screen readers and UI automation report as bounds.
          final fieldRect = tester.getRect(field);
          expect(
            nodeRect.height,
            lessThan(fieldRect.height + 24),
            reason: what,
          );
          expect(
            nodeRect.width,
            lessThanOrEqualTo(fieldRect.width + 1),
            reason: what,
          );
        }

        final port = find.byKey(const ValueKey('mcp_port'));
        final portNode = textFieldNode(port);
        expectOwnText(portNode, l10n.localListeningPort, 'port');
        expect(portNode.getSemanticsData().value, '8765');
        expectRectNear(portNode, port, 'port');
        final card = find.ancestor(of: port, matching: find.byType(Card));
        expect(
          portNode.rect.height,
          lessThan(tester.getRect(card).height / 2),
          reason: 'port node must not span the whole service card',
        );

        // The machine search field sits in the machine card with the same
        // risk of being merged into it.
        final search = find.byKey(const ValueKey('mcp_machine_search'));
        await tester.ensureVisible(search);
        await tester.pumpAndSettle();
        final searchNode = textFieldNode(search);
        expectOwnText(searchNode, l10n.mcpSearchMachines, 'search');
        expectRectNear(searchNode, search, 'search');

        // Each machine choice is a separate control named for its machine.
        for (final (id, name) in [
          (mcpLocalDeviceHostId, l10n.mcpLocalDeviceName),
          ('host-0', 'production-database-primary-eu-west-replica-0'),
          ('host-1', 'server-1'),
        ]) {
          final field = _hostField(id);
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          final node = tester.getSemantics(field);
          final data = node.getSemanticsData();
          final all = '${data.label}\n${data.hint}\n${data.value}';
          expect(all, contains(name), reason: id);
          for (final text in unrelated) {
            expect(all, isNot(contains(text)), reason: '$id has "$text"');
          }
          for (final other in ['server-2', if (id != 'host-1') 'server-1']) {
            expect(all, isNot(contains(other)), reason: '$id has "$other"');
          }
          expect(
            node.rect.height,
            lessThan(
              tester
                      .getRect(find.byKey(const ValueKey('mcp_machine_access')))
                      .height /
                  4,
            ),
            reason: '$id node must not span the machine card',
          );
        }

        // The default-access radios stay individually focusable.
        for (final mode in McpAccessMode.values) {
          final data = tester
              .getSemantics(
                find.byKey(ValueKey('mcp_default_access_${mode.name}')),
              )
              .getSemanticsData();
          expect(data.label, contains(mcpAccessModeLabel(l10n, mode)));
          expect(data.label, isNot(contains(l10n.mcpMachineAccessDescription)));
        }
        semantics.dispose();
      },
    );
  }

  testWidgets('stopping revokes from the same button on every platform', (
    tester,
  ) async {
    final service = _FakeMcpService();
    await _pump(tester, service, size: phone);
    await tester.ensureVisible(find.byKey(const ValueKey('mcp_toggle')));
    await tester.tap(find.byKey(const ValueKey('mcp_toggle')));
    await tester.pumpAndSettle();
    expect(service.stopCalls, 1);
    expect(find.byKey(const ValueKey('mcp_endpoint')), findsNothing);
    expect(
      find.byKey(const ValueKey('mcp_android_forward_command')),
      findsNothing,
    );
    // Policy stays editable while stopped, so access can be set up first.
    expect(_hostField('host-0'), findsOneWidget);
  });

  group('settings scaffold on touch devices', () {
    Future<void> pumpScaffold(
      WidgetTester tester, {
      required double windowWidth,
      required double railWidth,
      required TargetPlatform platform,
    }) async {
      await tester.binding.setSurfaceSize(Size(windowWidth, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(platform: platform).copyWith(platform: platform),
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: railWidth),
                Expanded(
                  child: SettingsScaffold(
                    sections: [
                      SettingsSection(
                        id: 'a',
                        title: 'A',
                        icon: Icons.abc,
                        description: 'a',
                        builder: (_) => const Column(
                          children: [
                            TextField(key: ValueKey('field')),
                            // Enough content that the page really scrolls.
                            SizedBox(height: 2000),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    SingleChildScrollView page(WidgetTester tester) =>
        tester.widget<SingleChildScrollView>(
          find.byKey(const PageStorageKey('settings_scroll_a')),
        );

    testWidgets('padding follows the space the page gets, not the window', (
      tester,
    ) async {
      // Tablet portrait beside the 72 px Home rail: 768 - 72 < 700.
      await pumpScaffold(
        tester,
        windowWidth: 768,
        railWidth: 72,
        platform: TargetPlatform.android,
      );
      expect(
        find.byKey(const ValueKey('settings_category_navigation')),
        findsNothing,
      );
      expect(page(tester).padding, const EdgeInsets.all(12));
      expect(
        page(tester).keyboardDismissBehavior,
        ScrollViewKeyboardDismissBehavior.onDrag,
      );
    });

    testWidgets('desktop keeps inherited keyboard handling and page padding', (
      tester,
    ) async {
      await pumpScaffold(
        tester,
        windowWidth: 1280,
        railWidth: 200,
        platform: TargetPlatform.windows,
      );
      expect(
        find.byKey(const ValueKey('settings_category_navigation')),
        findsOneWidget,
      );
      expect(page(tester).padding, isNot(const EdgeInsets.all(12)));
      // Unchanged from before: inherits the app scroll behaviour (manual).
      expect(page(tester).keyboardDismissBehavior, isNull);
    });

    testWidgets('dragging the page hides the Android soft keyboard', (
      tester,
    ) async {
      await pumpScaffold(
        tester,
        windowWidth: 390,
        railWidth: 52,
        platform: TargetPlatform.android,
      );
      await tester.tap(find.byKey(const ValueKey('field')));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.drag(
        find.byKey(const PageStorageKey('settings_scroll_a')),
        const Offset(0, -40),
      );
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });
  });

  test('breakpoints and touch detection', () {
    expect(isTouchPlatform(TargetPlatform.android), isTrue);
    expect(isTouchPlatform(TargetPlatform.windows), isFalse);
    expect(
      AppBreakpoints.stackedRow,
      lessThan(AppBreakpoints.settingsNavigation),
    );
  });

  test('every MCP access label exists in all four catalogs with matching '
      'placeholders', () {
    Map<String, dynamic> arb(String code) =>
        jsonDecode(File('lib/l10n/app_$code.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = arb('en');
    final keys = en.keys
        .where((k) => k.startsWith('mcp') && !k.startsWith('@'))
        .toList();
    expect(keys.length, greaterThanOrEqualTo(33));
    final placeholder = RegExp(r'\{(\w+)\}');
    Set<String> names(String s) =>
        placeholder.allMatches(s).map((m) => m.group(1)!).toSet();
    for (final code in ['zh', 'ja', 'ru']) {
      final other = arb(code);
      for (final key in keys) {
        final value = other[key];
        expect(value, isA<String>(), reason: '$code:$key missing');
        expect((value as String).trim(), isNotEmpty, reason: '$code:$key');
        expect(names(value), names(en[key] as String), reason: '$code:$key');
        expect(value, isNot(en[key]), reason: '$code:$key untranslated');
      }
    }
  });
}
