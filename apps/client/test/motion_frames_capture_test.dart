// Frame-sequence capture for motion review. Skipped unless
// ATERMIUS_MOTION_CAPTURE_DIR is set; uses synthetic Hosts only and never
// renders credentials. Optional CJK font: ATERMIUS_MOTION_CAPTURE_FONT.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/app_motion.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/host_search_palette.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _outDir = Platform.environment['ATERMIUS_MOTION_CAPTURE_DIR'];
final _fontPath = Platform.environment['ATERMIUS_MOTION_CAPTURE_FONT'];
final _variant =
    Platform.environment['ATERMIUS_MOTION_CAPTURE_VARIANT'] ?? 'after';
const _frames = [0, 40, 80, 120, 160, 220];
final _boundary = GlobalKey();

const _hosts = [
  HostRecord(
    id: 'h1',
    name: 'Production edge',
    address: 'edge.example.test',
    username: 'ops',
  ),
  HostRecord(
    id: 'h2',
    name: '构建服务器',
    address: 'build.example.test',
    username: 'ci',
  ),
  HostRecord(
    id: 'h3',
    name: 'Windows jump',
    address: 'jump.example.test',
    protocol: HostProtocol.rdp,
  ),
];

Future<void> _loadFonts() async {
  final sdk = Platform.environment['FLUTTER_ROOT'];
  if (sdk != null) {
    final icons = File(
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  }
  final path = _fontPath;
  if (path != null && File(path).existsSync()) {
    final bytes = ByteData.sublistView(File(path).readAsBytesSync());
    for (final family in ['Roboto', 'CaptureSans']) {
      final loader = FontLoader(family)..addFont(Future.value(bytes));
      await loader.load();
    }
  }
}

Future<void> _snap(WidgetTester tester, String name, int ms) async {
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory('$_outDir/$_variant/$name')
      ..createSync(recursive: true);
    File('${dir.path}/${ms.toString().padLeft(3, '0')}ms.png')
        .writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Future<void> _sequence(WidgetTester tester, String name) async {
  var elapsed = 0;
  for (final ms in _frames) {
    await tester.pump(Duration(milliseconds: ms - elapsed));
    elapsed = ms;
    await _snap(tester, name, ms);
  }
  await tester.pumpAndSettle();
}

class _Harness extends StatefulWidget {
  const _Harness({required this.reduced});
  final bool reduced;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String page = 'hosts';
  String selected = 'hosts';
  final tabs = <WorkspaceTab>[
    const WorkspaceTab(id: 'hosts', title: 'Hosts', isHome: true),
    const WorkspaceTab(id: 't1', title: 'Production edge', isConnected: true),
  ];

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: widget.reduced),
    child: Scaffold(
      body: Column(
        children: [
          WorkspaceTabBar(
            tabs: List.of(tabs),
            selectedId: selected,
            onSelect: (id) => setState(() => selected = id),
            onClose: (_) {},
            onSearch: () {},
            homeMenuActions: [
              WorkspaceAction(
                'menu_settings',
                'Settings',
                Icons.settings_outlined,
                () {},
              ),
              WorkspaceAction(
                'menu_new_ssh',
                '新建 SSH 主机',
                Icons.terminal,
                () {},
              ),
              WorkspaceAction(
                'menu_combo',
                'Save window set',
                Icons.dashboard_customize_outlined,
                () {},
              ),
            ],
          ),
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 72,
                  color: AppPalette.dark.rail,
                  child: Column(
                    children: [
                      for (final (id, icon) in [
                        ('hosts', Icons.dns_outlined),
                        ('settings', Icons.settings_outlined),
                      ])
                        IconButton(
                          key: ValueKey('nav_$id'),
                          color: page == id
                              ? AppColors.accentText
                              : AppColors.muted,
                          onPressed: () => setState(() => page = id),
                          icon: Icon(icon),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: MotionEntrance(
                    trigger: page,
                    child: page == 'hosts' ? const _HostsGrid() : _settings(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _settings() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text('设置 · Settings', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      for (final label in ['Terminal font size', '同步', 'Devices'])
        const Card(child: ListTile(title: Text('Synthetic setting'))),
    ],
  );

  void openTab() => setState(() {
    tabs.add(const WorkspaceTab(id: 't2', title: '构建服务器', isConnected: true));
    selected = 't2';
  });
}

class _HostsGrid extends StatelessWidget {
  const _HostsGrid();
  @override
  Widget build(BuildContext context) => GridView.extent(
    padding: const EdgeInsets.all(20),
    maxCrossAxisExtent: 300,
    mainAxisExtent: 96,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
    children: [
      for (final host in _hosts)
        Card(
          child: ListTile(
            leading: Icon(
              host.protocol == HostProtocol.rdp
                  ? Icons.desktop_windows_outlined
                  : Icons.terminal,
              color: AppColors.accentText,
            ),
            title: Text(host.name),
            subtitle: Text('${host.username}@${host.address}'),
          ),
        ),
    ],
  );
}

void main() {
  final skip = _outDir == null;
  setUpAll(() async {
    if (!skip) await _loadFonts();
  });

  Future<void> pumpHarness(WidgetTester tester, {bool reduced = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 640);
    addTearDown(tester.view.reset);
    final theme = buildAppTheme();
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _fontPath == null
              ? theme
              : theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'CaptureSans'),
                ),
          home: _Harness(reduced: reduced),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final reduced in [false, true]) {
    final suffix = reduced ? '_reduced' : '';
    testWidgets('capture page switch$suffix', skip: skip, (tester) async {
      await pumpHarness(tester, reduced: reduced);
      await tester.tap(find.byKey(const ValueKey('nav_settings')));
      await _sequence(tester, 'page_switch$suffix');
    });

    testWidgets('capture host editor drawer$suffix', skip: skip, (
      tester,
    ) async {
      await pumpHarness(tester, reduced: reduced);
      final context = tester.element(find.byType(_HostsGrid));
      showHostEditorPanel(context, groups: const [], hosts: _hosts);
      await _sequence(tester, 'host_drawer$suffix');
    });

    if (!reduced) {
      testWidgets('capture search palette', skip: skip, (tester) async {
        await pumpHarness(tester);
        final context = tester.element(find.byType(_HostsGrid));
        showHostSearchPalette(
          context,
          hosts: () => _hosts,
          groups: const {},
          fieldKey: const ValueKey('capture_search'),
          isCurrent: () => true,
        );
        await _sequence(tester, 'search_palette');
      });

      testWidgets('capture host menu', skip: skip, (tester) async {
        await pumpHarness(tester);
        await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
        await _sequence(tester, 'host_menu');
      });

      testWidgets('capture tab open + select', skip: skip, (tester) async {
        await pumpHarness(tester);
        tester.state<_HarnessState>(find.byType(_Harness)).openTab();
        await _sequence(tester, 'tab_open');
      });
    }
  }
}
