import 'dart:convert';

import 'package:aterm_client/import/termius_json.dart';
import 'package:aterm_client/import/termius_openssh_bundle.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/termius_transfer_dialog.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _sampleInlineKey =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
    '-----END OPENSSH PRIVATE KEY-----';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Termius Desktop JSON & CSV enhancements', () {
    test(
      'parses Termius Desktop JSON hierarchy, identities, ssh_configs, and inline keys',
      () {
        final payload = jsonEncode({
          'groups': [
            {'id': 'g-prod', 'label': 'Production'},
            {'id': 'g-api', 'label': 'API', 'parent_group': 'g-prod'},
          ],
          'keys': [
            {'id': 'k-1', 'private_key': _sampleInlineKey},
          ],
          'identities': [
            {'id': 'id-1', 'username': 'deploy', 'ssh_key': 'k-1'},
          ],
          'ssh_configs': [
            {'id': 'cfg-1', 'port': 2222, 'identity': 'id-1'},
          ],
          'hosts': [
            {
              'label': 'Core Gateway',
              'address': 'gw.example.test',
              'group': 'g-api',
              'ssh_config': 'cfg-1',
              'tags': ['edge', 'tokyo'],
            },
            {
              'name': 'Quick Box',
              'address': 'ops@10.0.0.12:2200',
            },
          ],
        });

        final doc = TermiusJsonImporter.parse(payload);
        expect(doc.blocksWholeFile, isFalse);
        expect(doc.rows, hasLength(2));

        final first = doc.rows[0];
        expect(first.label, 'Core Gateway');
        expect(first.address, 'gw.example.test');
        expect(first.port, 2222);
        expect(first.username, 'deploy');
        expect(first.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
        expect(first.groupPath, ['Production', 'API']);
        expect(first.tags, ['edge', 'tokyo']);

        final second = doc.rows[1];
        expect(second.label, 'Quick Box');
        expect(second.address, '10.0.0.12');
        expect(second.port, 2200);
        expect(second.username, 'ops');

        final plan = TermiusImportPlanner.plan(
          doc,
          TermiusCatalog(groups: const [], hosts: const []),
        );
        expect(plan.canApply, isTrue);
        expect(plan.createCount, 2);
        expect(plan.newGroups, hasLength(2));
        expect(plan.secretCount, 1);
      },
    );

    test(
      'supports CSV header aliases, user@host:port, and fallbackUsername completion',
      () {
        const csv =
            'Name,Address,User,Folder,Tag\r\n'
            'Web 01,ubuntu@192.0.2.10:2202,,Prod/Web,frontend\r\n'
            'DB 01,192.0.2.20,,Prod/Data,postgres\r\n';
        final doc = TermiusCsvImporter.parse(csv);
        expect(doc.blocksWholeFile, isFalse);
        expect(doc.rows, hasLength(2));
        expect(doc.rows[0].username, 'ubuntu');
        expect(doc.rows[0].address, '192.0.2.10');
        expect(doc.rows[0].port, 2202);
        expect(doc.rows[1].username, isEmpty);
        expect(TermiusImportPlanner.hasRowsMissingUsername(doc), isTrue);

        final emptyCatalog = TermiusCatalog(groups: const [], hosts: const []);
        final withoutFallback = TermiusImportPlanner.plan(doc, emptyCatalog);
        expect(withoutFallback.createCount, 1);
        expect(
          withoutFallback.rows[1].disposition,
          TermiusRowDisposition.blocked,
        );

        final withFallback = TermiusImportPlanner.plan(
          doc,
          emptyCatalog,
          fallbackUsername: 'ec2-user',
        );
        expect(withFallback.createCount, 2);
        expect(withFallback.rows[1].disposition, TermiusRowDisposition.create);
        expect(withFallback.rows[1].host?.username, 'ec2-user');
      },
    );

    test(
      'ignores macOS Finder __MACOSX, .DS_Store, and AppleDouble entries in ZIP bundles',
      () {
        final zipBytes = TermiusZip.encode([
          TermiusZipEntry('.DS_Store', Uint8List.fromList([0, 1, 2, 3])),
          TermiusZipEntry(
            '__MACOSX/._config',
            Uint8List.fromList([0, 5, 22, 7]),
          ),
          TermiusZipEntry('._config', Uint8List.fromList([0, 5, 22, 7])),
          TermiusZipEntry(
            'config',
            Uint8List.fromList(
              utf8.encode('Host prod\n  HostName 198.51.100.8\n  User admin\n'),
            ),
          ),
        ]);

        final doc = TermiusOpenSshBundleImporter.parseZip(zipBytes);
        expect(doc.blocksWholeFile, isFalse);
        expect(doc.rows, hasLength(1));
        expect(doc.rows.single.address, '198.51.100.8');
        expect(doc.rows.single.username, 'admin');
      },
    );
  });

  testWidgets(
    'TermiusTransferDialog imports JSON and completes missing SSH usernames',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 960);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final target = _MemoryTransferTarget();
      final jsonBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'hosts': [
              {'label': 'Mac Mini Node', 'address': '10.10.0.5'},
            ],
          }),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: TermiusTransferDialog(
              target: target,
              pickBytesForTesting: (_) async => (
                bytes: jsonBytes,
                name: 'termius-export.json',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('termius_import_pick_json')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('termius_import_fallback_username')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('termius_import_apply')),
            )
            .onPressed,
        isNull,
      );

      await tester.tap(
        find.byKey(const ValueKey('termius_import_fallback_root_user')),
      );
      await tester.pumpAndSettle();

      final applyButton = tester.widget<FilledButton>(
        find.byKey(const ValueKey('termius_import_apply')),
      );
      expect(applyButton.onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('termius_import_apply')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('termius_import_confirm_accept')),
      );
      await tester.pumpAndSettle();

      expect(target.appliedPlan, isNotNull);
      expect(target.appliedPlan!.createCount, 1);
      expect(target.appliedPlan!.rows.single.host?.username, 'root');
    },
  );

  testWidgets(
    'macOS unified tab bar reserves traffic-light inset and closes tab on middle click',
    (tester) async {
      const channel = MethodChannel('atermius/test_macos_chrome');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'enable' || call.method == 'getState') {
              return <String, Object?>{
                'enabled': true,
                'customFrame': false,
                'maximized': false,
                'minimized': false,
                'focused': true,
                'captionHeight': 38.0,
                'leadingInset': 76.0,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final controller = WindowChromeController(
        channel: channel,
        supported: true,
      );
      addTearDown(controller.dispose);
      final closed = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(
            platform: TargetPlatform.macOS,
          ).copyWith(platform: TargetPlatform.macOS),
          builder: (context, child) => WindowsWindowChrome(
            controller: controller,
            navigationEmbedded: () => true,
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                WorkspaceTabBar(
                  tabs: const [
                    WorkspaceTab(id: 'home', title: 'Hosts', isHome: true),
                    WorkspaceTab(
                      id: 'ssh-1',
                      title: 'prod-macos',
                      isConnected: true,
                    ),
                  ],
                  selectedId: 'ssh-1',
                  onSelect: (_) {},
                  onClose: closed.add,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final navRect = tester.getRect(
        find.byKey(const ValueKey('workspace_navigation_bar')),
      );
      expect(navRect.height, 38.0);

      final homeRect = tester.getRect(
        find.byKey(const ValueKey('workspace-tab-home')),
      );
      expect(homeRect.left, greaterThanOrEqualTo(76.0));

      // Middle-click closes the SSH session tab.
      final sshCenter = tester.getCenter(
        find.byKey(const ValueKey('workspace-tab-ssh-1')),
      );
      final gesture = await tester.startGesture(
        sshCenter,
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(closed, ['ssh-1']);
    },
  );
}

class _MemoryTransferTarget implements TermiusTransferTarget {
  TermiusImportPlan? appliedPlan;

  @override
  bool get canWrite => true;

  @override
  String? get contextKey => 'memory-test';

  @override
  Future<TermiusCatalog> loadCatalog() async =>
      TermiusCatalog(groups: const [], hosts: const []);

  @override
  Future<TermiusApplyReport> apply(TermiusImportPlan plan) async {
    appliedPlan = plan;
    return TermiusApplyReport(
      createdHosts: plan.createCount,
      createdGroups: plan.newGroups.length,
      createdCredentials: plan.secretCount,
    );
  }
}
