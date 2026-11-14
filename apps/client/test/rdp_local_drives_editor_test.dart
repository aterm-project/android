import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_settings_editor.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/rdp_local_drives_store.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';
import 'support/rdp_local_volumes_fake.dart';

const _drives = RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive);
const _switch = ValueKey('host_rdp_local_disks');
const _panelSwitch = ValueKey('host_editor_rdp_local_disks');

/// A store whose reads or writes can be made to fail.
class _FlakyStore extends MemoryRdpLocalDrivesStore {
  bool readFails = false, writeFails = false;
  @override
  Future<String?> read() async {
    if (readFails) throw StateError('locked');
    return super.read();
  }

  @override
  Future<void> write(String value) async {
    if (writeFails) throw StateError('disk full');
    return super.write(value);
  }
}

Future<void> _mountEditor(
  WidgetTester tester, {
  required RdpLocalVolumeSource source,
  RdpFeatures features = _drives,
  bool value = true,
  ValueChanged<bool>? changed,
  RdpLocalDrivesController? localDrives,
  RdpFolderPicker? pickFolder,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: RdpSettingsEditor(
          initial: RdpSettings.defaults,
          onChanged: (_) {},
          features: features,
          localVolumes: source,
          localDrives: localDrives,
          mapLocalDisks: value,
          onMapLocalDisksChanged: changed ?? (_) {},
          pickFolder: pickFolder,
        ),
      ),
    ),
  ),
);

Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpAndSettle();
}

bool _switchValue(WidgetTester tester, Key key) =>
    tester.widget<SwitchListTile>(find.byKey(key)).value;

void main() {
  useAppLocaleFixture('en');

  testWidgets('the switch is on by default, visible without expanding RDP '
      'options, and says what this device maps', (tester) async {
    final changes = <bool>[];
    await _mountEditor(
      tester,
      source: FakeLocalVolumes(
        volumes: const [
          windowsC,
          windowsE,
          RdpLocalVolume(name: 'A', path: r'A:\', ready: false),
        ],
      ),
      changed: changes.add,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_switch), findsOneWidget);
    expect(_switchValue(tester, _switch), isTrue);
    expect(find.text(currentL10n.rdpMapLocalDisks), findsOneWidget);
    expect(find.text(currentL10n.rdpMapLocalDisksThisDevice), findsOneWidget);
    expect(find.text(currentL10n.rdpMapLocalDisksWillMap('C, E')), findsOneWidget);
    // The options tile itself is still collapsed.
    expect(find.byKey(const ValueKey('host_rdp_add_disk')), findsNothing);
    await tester.tap(find.byKey(_switch));
    await tester.pumpAndSettle();
    expect(changes, [false]);
    expect(_switchValue(tester, _switch), isFalse);
    // The manual list is now "additional" folders.
    await tester.tap(find.text(currentL10n.rdpOptions));
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.redirectedFolders), findsOneWidget);
    expect(currentL10n.redirectedFolders, 'Additional mapped folders');
  });

  testWidgets('hidden where local disks are not mapped automatically', (
    tester,
  ) async {
    await _mountEditor(
      tester,
      source: FakeLocalVolumes(os: null, windowsPaths: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_switch), findsNothing);
    await _mountEditor(
      tester,
      source: FakeLocalVolumes(),
      features: const RdpFeatures(RdpFeatures.configV1),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(_switch), findsNothing);
  });

  testWidgets('Android shows the All files access state and a grant button', (
    tester,
  ) async {
    final source = FakeLocalVolumes(
      os: RdpAutoDriveOs.android,
      access: false,
      volumes: const [
        RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
      ],
    );
    await _mountEditor(tester, source: source);
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.rdpMapLocalDisksNeedsAccess), findsOneWidget);
    expect(source.requests, 0, reason: 'opening the editor never prompts');
    await tester.tap(find.byKey(const ValueKey('host_rdp_local_disks_grant')));
    await tester.pumpAndSettle();
    expect(source.requests, 1);
    expect(find.byKey(const ValueKey('host_rdp_local_disks_grant')), findsNothing);
    expect(
      find.text(currentL10n.rdpMapLocalDisksWillMap('Local Storage')),
      findsOneWidget,
    );
  });

  testWidgets('a declined grant says so and keeps the button', (tester) async {
    final source = FakeLocalVolumes(
      os: RdpAutoDriveOs.android,
      access: false,
      grant: false,
    );
    await _mountEditor(tester, source: source);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host_rdp_local_disks_grant')));
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.rdpStoragePermissionRequired), findsOneWidget);
    expect(
      find.byKey(const ValueKey('host_rdp_local_disks_grant')),
      findsOneWidget,
    );
  });

  testWidgets('the switch says when its choice could not be saved', (
    tester,
  ) async {
    final store = _FlakyStore();
    final local = RdpLocalDrivesController(
      source: FakeLocalVolumes(volumes: const [windowsC]),
    );
    await local.load(store);
    store.writeFails = true;
    await _mountEditor(
      tester,
      source: local.source,
      localDrives: local,
      changed: (on) => local.setEnabled('win', on),
    );
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.rdpMapLocalDisksSaveFailed), findsNothing);
    await tester.tap(find.byKey(_switch));
    await tester.pumpAndSettle();
    expect(local.enabled('win'), isFalse, reason: 'applies in this window');
    expect(find.text(currentL10n.rdpMapLocalDisksSaveFailed), findsOneWidget);
    store.writeFails = false;
    await local.refresh();
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.rdpMapLocalDisksSaveFailed), findsNothing);
    expect(store.value, contains('win'));
  });

  testWidgets('the switch says when stored choices cannot be read', (
    tester,
  ) async {
    final store = _FlakyStore()..readFails = true;
    final local = RdpLocalDrivesController(
      source: FakeLocalVolumes(volumes: const [windowsC]),
    );
    await local.load(store);
    await _mountEditor(
      tester,
      source: local.source,
      localDrives: local,
      value: local.enabled('win'),
    );
    await tester.pumpAndSettle();
    expect(_switchValue(tester, _switch), isFalse, reason: 'fails closed');
    expect(find.text(currentL10n.rdpMapLocalDisksUnreadable), findsOneWidget);
    store.readFails = false;
    await local.refresh();
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.rdpMapLocalDisksUnreadable), findsNothing);
  });

  testWidgets('Windows lists its drives once per editor; Android again when '
      'the app resumes from Settings', (tester) async {
    final windows = FakeLocalVolumes(volumes: const [windowsC]);
    await _mountEditor(tester, source: windows);
    await tester.pumpAndSettle();
    expect(windows.listed, 1);
    // Windows desktop "resumes" on every focus change; each listing probes
    // every drive.
    await _resume(tester);
    await _resume(tester);
    expect(windows.listed, 1);

    final android = FakeLocalVolumes(
      os: RdpAutoDriveOs.android,
      volumes: const [
        RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
      ],
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await _mountEditor(tester, source: android);
    await tester.pumpAndSettle();
    expect(android.listed, 1);
    await _resume(tester);
    expect(android.listed, 2);
  });

  testWidgets('a new folder whose path the engine cannot carry is refused '
      'with the reason', (tester) async {
    final long = '/storage/emulated/0/${'资' * 90}';
    await _mountEditor(
      tester,
      source: FakeLocalVolumes(os: null, windowsPaths: false),
      pickFolder: () async => long,
    );
    await tester.tap(find.text(currentL10n.rdpOptions));
    await tester.pumpAndSettle();
    final add = find.byKey(const ValueKey('host_rdp_add_drive'));
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.text(currentL10n.rdpFolderPathTooLong), findsOneWidget);
    expect(find.text(long), findsNothing);
  });

  group('Host editor', () {
    late MemoryRdpLocalDrivesStore store;
    late RdpLocalDrivesController local;
    // Created inside each test body: the controller's write queue must live
    // in the widget test's fake-async zone.
    Future<void> useLocalDrives() async {
      store = MemoryRdpLocalDrivesStore();
      local = await fakeLocalDrives(
        FakeLocalVolumes(volumes: const [windowsC]),
        store: store,
      );
      RdpLocalDrivesController.debugInstance = local;
    }

    tearDown(() => RdpLocalDrivesController.debugInstance = null);

    Future<HostRecord? Function()> openPanel(
      WidgetTester tester, {
      HostRecord? existing,
      bool canEdit = true,
    }) async {
      HostRecord? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                saved = await showDialog<HostRecord>(
                  context: context,
                  builder: (_) => HostEditorPanel(
                    groups: const [],
                    hosts: const [],
                    existing: existing,
                    initialProtocol: HostProtocol.rdp,
                    canEdit: canEdit,
                    rdpFeaturesForTesting: _drives,
                  ),
                );
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      return () => saved;
    }

    testWidgets('a new Host defaults on; turning it off is stored with the '
        'Host id on save and never in the Host', (tester) async {
      await useLocalDrives();
      final result = await openPanel(tester);
      expect(_switchValue(tester, _panelSwitch), isTrue);
      await tester.enterText(
        find.byKey(const ValueKey('host_editor_name')),
        'Win',
      );
      await tester.enterText(
        find.byKey(const ValueKey('host_editor_address')),
        'win.example',
      );
      await tester.ensureVisible(find.byKey(_panelSwitch));
      await tester.tap(find.byKey(_panelSwitch));
      await tester.pumpAndSettle();
      expect(store.value, isNot(contains('"off":["')),
          reason: 'not stored before the Host is saved');
      await tester.ensureVisible(
        find.byKey(const ValueKey('host_editor_save')),
      );
      await tester.tap(find.byKey(const ValueKey('host_editor_save')));
      await tester.pumpAndSettle();
      final saved = result();
      expect(saved, isNotNull);
      expect(local.enabled(saved!.id), isFalse);
      expect(store.value, contains(saved.id));
      // The synchronized Host carries no trace of the device-local choice.
      expect(saved.manifest, isNull);
    });

    testWidgets('saving an existing Host opened while the stored choices '
        'cannot be read never turns mapping off for good', (tester) async {
      const host = HostRecord(
        id: 'win',
        name: 'Win',
        address: 'win.example',
        protocol: HostProtocol.rdp,
      );
      final flaky = _FlakyStore()..readFails = true;
      local = RdpLocalDrivesController(
        source: FakeLocalVolumes(volumes: const [windowsC]),
      );
      await local.load(flaky);
      RdpLocalDrivesController.debugInstance = local;
      final result = await openPanel(tester, existing: host);
      expect(_switchValue(tester, _panelSwitch), isFalse);
      expect(find.text(currentL10n.rdpMapLocalDisksUnreadable), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('host_editor_save')),
      );
      await tester.tap(find.byKey(const ValueKey('host_editor_save')));
      await tester.pumpAndSettle();
      expect(result(), isNotNull);
      flaky.readFails = false;
      await local.refresh();
      expect(local.enabled(host.id), isTrue);
      expect(flaky.value, isNull, reason: 'nothing was written');
    });

    testWidgets('an existing Host shows its stored choice and applies a '
        'change at once, even when the Host is read-only', (tester) async {
      const host = HostRecord(
        id: 'win',
        name: 'Win',
        address: 'win.example',
        protocol: HostProtocol.rdp,
      );
      await useLocalDrives();
      await local.setEnabled(host.id, false);
      await openPanel(tester, existing: host, canEdit: false);
      expect(_switchValue(tester, _panelSwitch), isFalse);
      await tester.ensureVisible(find.byKey(_panelSwitch));
      await tester.tap(find.byKey(_panelSwitch));
      await tester.pumpAndSettle();
      expect(local.enabled(host.id), isTrue);
      expect(store.value, isNot(contains(host.id)));
    });
  });
}
