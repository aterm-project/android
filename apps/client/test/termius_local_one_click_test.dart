import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/termius_indexeddb_reader.dart';
import 'package:aterm_client/import/termius_local_normalizer.dart';
import 'package:aterm_client/import/termius_local_vault_cipher.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/home_add_sharing_row.dart';
import 'package:aterm_client/ui/termius_transfer_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart' as sodium_api;
import 'package:sodium/sodium_sumo.dart';

const _syntheticPrivateKey =
    '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n'
    'QyNTUxOQAAACBzeW50aGV0aWMtdGVzdC1rZXktYnl0ZXMtZm9yLXVuaXQtdGVzdHM=\n'
    '-----END OPENSSH PRIVATE KEY-----\n';

String _encryptTermiusEnvelope(
  sodium_api.Sodium sodium,
  Uint8List rawKey,
  String plaintext, {
  int nonceSeed = 1,
}) {
  final nonce = Uint8List(termiusVaultNonceBytes);
  for (var i = 0; i < nonce.length; i++) {
    nonce[i] = (nonceSeed + i * 7) & 0xff;
  }
  final key = sodium.secureCopy(rawKey);
  try {
    final cipher = sodium.crypto.secretBox.easy(
      message: Uint8List.fromList(utf8.encode(plaintext)),
      nonce: nonce,
      key: key,
    );
    final envelope = BytesBuilder(copy: false)
      ..add(termiusVaultKnownHeader)
      ..add(nonce)
      ..add(cipher);
    return base64.encode(envelope.takeBytes());
  } finally {
    key.dispose();
  }
}

void _writeVarint(BytesBuilder out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.addByte(v & 0x7f);
}

void _writeUtf16Be(BytesBuilder out, String text) {
  for (final unit in text.codeUnits) {
    out.addByte((unit >> 8) & 0xff);
    out.addByte(unit & 0xff);
  }
}

/// Encodes a Dart value using V8's `ValueSerializer` v15 wire format.
void _writeV8Value(BytesBuilder out, Object? value) {
  if (value == null) {
    out.addByte(0x30); // '0' Null
    return;
  }
  if (value is bool) {
    out.addByte(value ? 0x54 : 0x46); // 'T' / 'F'
    return;
  }
  if (value is int) {
    out.addByte(0x49); // 'I' ZigZag int32
    final zigzag = (value << 1) ^ (value >> 31);
    _writeVarint(out, zigzag & 0xffffffff);
    return;
  }
  if (value is String) {
    final ascii = value.codeUnits.every((c) => c <= 0x7f);
    if (ascii) {
      out.addByte(0x22); // '"' OneByteString
      _writeVarint(out, value.length);
      out.add(value.codeUnits);
    } else {
      out.addByte(0x63); // 'c' TwoByteString (UTF-16LE)
      _writeVarint(out, value.length * 2);
      for (final unit in value.codeUnits) {
        out.addByte(unit & 0xff);
        out.addByte((unit >> 8) & 0xff);
      }
    }
    return;
  }
  if (value is List) {
    out.addByte(0x41); // 'A' BeginDenseJSArray
    _writeVarint(out, value.length);
    for (final item in value) {
      _writeV8Value(out, item);
    }
    out.addByte(0x24); // '$' EndDenseJSArray
    _writeVarint(out, 0); // extra properties
    _writeVarint(out, value.length);
    return;
  }
  if (value is Map) {
    out.addByte(0x6f); // 'o' BeginJSObject
    var count = 0;
    for (final entry in value.entries) {
      _writeV8Value(out, entry.key.toString());
      _writeV8Value(out, entry.value);
      count++;
    }
    out.addByte(0x7b); // '{' EndJSObject
    _writeVarint(out, count);
    return;
  }
  throw ArgumentError('Unsupported synthetic V8 value: ${value.runtimeType}');
}

/// Encodes a Chromium IndexedDB record value wrapped in Blink SSV v21
/// (optionally Snappy-compressed via `0xFF 0x11 0x02`).
Uint8List _encodeIndexedDbRecord(
  Map<String, Object?> record, {
  bool snappyWrap = false,
}) {
  final innerBlink = BytesBuilder(copy: false)
    ..addByte(0xff)
    ..addByte(21) // Blink wire version 21
    ..addByte(0xfe) // 13-byte trailer header
    ..add(List<int>.filled(12, 0))
    ..addByte(0xff)
    ..addByte(15); // V8 format version 15
  _writeV8Value(innerBlink, record);
  final blinkBytes = innerBlink.takeBytes();

  final outer = BytesBuilder(copy: false);
  _writeVarint(outer, 1); // IndexedDB value version
  if (snappyWrap) {
    outer
      ..addByte(0xff)
      ..addByte(0x11)
      ..addByte(0x02) // kCompressedWithSnappy
      ..add(snappyCompressLiteral(blinkBytes));
  } else {
    outer.add(blinkBytes);
  }
  return outer.takeBytes();
}

Uint8List _encodeGlobalDbNameKey(String origin, String dbName) {
  final out = BytesBuilder(copy: false)
    ..add(const [0x00, 0x00, 0x00, 0x00, 0xc9]);
  _writeVarint(out, origin.length);
  _writeUtf16Be(out, origin);
  _writeVarint(out, dbName.length);
  _writeUtf16Be(out, dbName);
  return out.takeBytes();
}

Uint8List _encodeIdbObjectDataKey(int dbId, int storeId, int recordKey) {
  // Single-byte dbId, storeId, indexId=1 => header byte 0x00.
  final out = BytesBuilder(copy: false)
    ..addByte(0x00)
    ..addByte(dbId & 0xff)
    ..addByte(storeId & 0xff)
    ..addByte(1); // ObjectStoreDataKeyPrefix (indexId = 1)
  _writeVarint(out, recordKey);
  return out.takeBytes();
}

/// Builds a valid LevelDB `.log` WAL containing a single WriteBatch.
Uint8List _buildLevelDbWal(List<(Uint8List key, Uint8List value)> puts) {
  final batch = BytesBuilder(copy: false);
  final header = ByteData(12)
    ..setUint32(0, 1, Endian.little) // sequence lo
    ..setUint32(4, 0, Endian.little) // sequence hi
    ..setUint32(8, puts.length, Endian.little);
  batch.add(header.buffer.asUint8List());

  for (final (key, value) in puts) {
    batch.addByte(1); // kTypeValue
    _writeVarint(batch, key.length);
    batch.add(key);
    _writeVarint(batch, value.length);
    batch.add(value);
  }

  final payload = batch.takeBytes();
  expect(
    payload.length + 7,
    lessThan(32768),
    reason: 'Single synthetic WAL record fits in one 32 KiB LevelDB log block',
  );
  final logRecord = BytesBuilder(copy: false);
  final recHead = ByteData(7)
    ..setUint32(0, 0, Endian.little) // CRC (not required by read-only scanner)
    ..setUint16(4, payload.length, Endian.little)
    ..setUint8(6, 1); // Full record
  logRecord
    ..add(recHead.buffer.asUint8List())
    ..add(payload);
  return logRecord.takeBytes();
}

class _FakeTransferTarget implements TermiusTransferTarget {
  _FakeTransferTarget({this.hosts = const []});

  @override
  bool get canWrite => true;

  @override
  String? get contextKey => 'fake-local';

  final List<HostRecord> hosts;
  final appliedPlans = <TermiusImportPlan>[];

  @override
  Future<TermiusCatalog> loadCatalog() async =>
      TermiusCatalog(hosts: hosts, groups: const []);

  @override
  Future<TermiusApplyReport> apply(TermiusImportPlan plan) async {
    appliedPlans.add(plan);
    return TermiusApplyReport(
      createdHosts: plan.createCount,
      createdGroups: plan.newGroups.length,
    );
  }
}

void main() {
  late sodium_api.Sodium sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  group('Snappy & XSalsa20-Poly1305 local vault primitives', () {
    test('decompresses literal and copy-1 / copy-2 back-reference blocks', () {
      final sample = Uint8List.fromList(utf8.encode('atermius-snappy-roundtrip'));
      expect(snappyUncompress(snappyCompressLiteral(sample)), sample);

      // Construct a Snappy stream with a 4-byte literal "abcd" followed by a
      // Copy-1 back-reference (len=8, offset=4) => "abcdabcdabcd" (12 bytes).
      final rleStream = Uint8List.fromList([
        12, // uncompressed length varint
        (3 << 2) | 0x00, // literal len = 4
        0x61, 0x62, 0x63, 0x64, // "abcd"
        ((8 - 4) << 2) | 0x01, // copy-1: len = 8, high offset bits = 0
        4, // offset = 4
      ]);
      expect(utf8.decode(snappyUncompress(rleStream)), 'abcdabcdabcd');
    });

    test('decrypts 0x04 0x01 secretbox fields including empty strings', () {
      final rawKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 11));
      final wrongKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 99));

      final secretCipher = _encryptTermiusEnvelope(
        sodium,
        rawKey,
        's3cr3t-pass!',
        nonceSeed: 10,
      );
      final emptyCipher = _encryptTermiusEnvelope(
        sodium,
        rawKey,
        '',
        nonceSeed: 40,
      );

      expect(isTermiusEncryptedEnvelope(secretCipher), isTrue);
      expect(isTermiusEncryptedEnvelope(emptyCipher), isTrue);
      expect(isTermiusEncryptedEnvelope('plain-hostname.example.com'), isFalse);

      final decryptor = TermiusVaultDecryptor(sodium, rawKey);
      final badDecryptor = TermiusVaultDecryptor(sodium, wrongKey);
      addTearDown(() {
        decryptor.dispose();
        badDecryptor.dispose();
      });

      expect(decryptor.canDecryptEnvelope(secretCipher), isTrue);
      expect(badDecryptor.canDecryptEnvelope(secretCipher), isFalse);
      expect(decryptor.decryptField(secretCipher), 's3cr3t-pass!');
      expect(decryptor.decryptField(emptyCipher), '');
      expect(decryptor.decryptField('unencrypted'), 'unencrypted');
    });

    test('rejects unknown envelope headers in strict mode', () {
      final rawKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      final decryptor = TermiusVaultDecryptor(sodium, rawKey);
      addTearDown(decryptor.dispose);

      final futureVersion = Uint8List(termiusVaultMinEnvelopeBytes + 8)
        ..[0] = 0x05
        ..[1] = 0x01;
      expect(
        () => decryptor.decryptField(base64.encode(futureVersion)),
        throwsA(isA<TermiusUnknownCipherVersionException>()),
      );
    });
  });

  group('End-to-end IndexedDB + vault decryption + 3-hop normalization', () {
    test('reads synthetic LevelDB WAL, deduplicates, decrypts, and plans hosts', () {
      final rawKey = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));
      String enc(String plain, int seed) =>
          _encryptTermiusEnvelope(sodium, rawKey, plain, nonceSeed: seed);

      // Database IDs in synthetic GlobalMetadata:
      // 1=groups, 2=keys, 3=ssh_identities, 4=ssh_configs, 5=hosts,
      // 6=tags, 7=tag_hosts, 8=pf_rules
      final dbMap = <int, String>{
        1: 'groups',
        2: 'keys',
        3: 'ssh_identities',
        4: 'ssh_configs',
        5: 'hosts',
        6: 'tags',
        7: 'tag_hosts',
        8: 'pf_rules',
      };

      final puts = <(Uint8List, Uint8List)>[
        for (final entry in dbMap.entries)
          (
            _encodeGlobalDbNameKey('file__0', entry.value),
            Uint8List.fromList([entry.key]),
          ),
        // Nested groups: Prod -> Core
        (
          _encodeIdbObjectDataKey(1, 1, 1),
          _encodeIndexedDbRecord({
            'id': 10,
            'label': enc('Prod', 1),
            'updated_at': '2026-01-01T00:00:00Z',
          }),
        ),
        (
          _encodeIdbObjectDataKey(1, 1, 2),
          _encodeIndexedDbRecord({
            'id': 11,
            'label': enc('Core', 2),
            'parent_group': {'id': 10},
            'updated_at': '2026-01-01T00:00:00Z',
          }),
        ),
        // SSH key (Snappy-wrapped Blink record)
        (
          _encodeIdbObjectDataKey(2, 1, 1),
          _encodeIndexedDbRecord(
            {
              'id': 20,
              'label': enc('deploy-ed25519', 3),
              'private_key': enc(_syntheticPrivateKey, 4),
              'updated_at': '2026-01-01T00:00:00Z',
            },
            snappyWrap: true,
          ),
        ),
        // Identities: 30 = bastion (password), 31 = app-node (private key)
        (
          _encodeIdbObjectDataKey(3, 1, 1),
          _encodeIndexedDbRecord({
            'id': 30,
            'username': enc('ops', 5),
            'password': enc('bastion-pw-42', 6),
          }),
        ),
        (
          _encodeIdbObjectDataKey(3, 1, 2),
          _encodeIndexedDbRecord({
            'id': 31,
            'username': enc('ubuntu', 7),
            'password': enc('', 8),
            'ssh_key': {'id': 20},
          }),
        ),
        // SSH configs: 40 = bastion:2222, 41 = app-node via jumphost 100
        (
          _encodeIdbObjectDataKey(4, 1, 1),
          _encodeIndexedDbRecord({
            'id': 40,
            'port': 2222,
            'identity': {'id': 30},
          }),
        ),
        (
          _encodeIdbObjectDataKey(4, 1, 2),
          _encodeIndexedDbRecord({
            'id': 41,
            'port': 22,
            'identity': {'id': 31},
            'jumphost': {'id': 100},
          }),
        ),
        // Host 100: older stale revision followed by newer revision + packed IPv4
        (
          _encodeIdbObjectDataKey(5, 1, 1),
          _encodeIndexedDbRecord({
            'id': 100,
            'label': enc('stale-bastion', 9),
            'address': enc('198.51.100.1', 10),
            'ssh_config': {'id': 40},
            'updated_at': '2026-01-01T00:00:00Z',
          }),
        ),
        (
          _encodeIdbObjectDataKey(5, 1, 2),
          _encodeIndexedDbRecord(
            {
              'id': 100,
              'label': enc('bastion', 11),
              // 3221226008 == 192.0.2.24
              'address': enc('3221226008', 12),
              'group': {'id': 10},
              'ssh_config': {'id': 40},
              'updated_at': '2026-02-01T00:00:00Z',
            },
            snappyWrap: true,
          ),
        ),
        // Host 101: app-node in Prod/Core using 3-hop key + jump host
        (
          _encodeIdbObjectDataKey(5, 1, 3),
          _encodeIndexedDbRecord({
            'id': 101,
            'label': enc('app-node', 13),
            'address': enc('10.20.30.40', 14),
            'group': {'id': 11},
            'ssh_config': {'id': 41},
            'updated_at': '2026-02-02T00:00:00Z',
          }),
        ),
        // Soft-deleted host 102 should be ignored
        (
          _encodeIdbObjectDataKey(5, 1, 4),
          _encodeIndexedDbRecord({
            'id': 102,
            'label': enc('deleted-host', 15),
            'address': enc('10.0.0.99', 16),
            'is_deleted': true,
            'updated_at': '2026-02-03T00:00:00Z',
          }),
        ),
        // Tag + tag_hosts link
        (
          _encodeIdbObjectDataKey(6, 1, 1),
          _encodeIndexedDbRecord({'id': 60, 'label': enc('edge', 17)}),
        ),
        (
          _encodeIdbObjectDataKey(7, 1, 1),
          _encodeIndexedDbRecord({
            'id': 70,
            'tag': {'id': 60},
            'host': {'id': 101},
          }),
        ),
        // Port forwarding rule on app-node
        (
          _encodeIdbObjectDataKey(8, 1, 1),
          _encodeIndexedDbRecord({
            'id': 80,
            'label': enc('postgres-tunnel', 18),
            'pf_type': 'L',
            'host': {'id': 101},
            'bound_address': enc('127.0.0.1', 19),
            'local_port': 15432,
            'hostname': enc('127.0.0.1', 20),
            'remote_port': 5432,
          }),
        ),
      ];

      final files = <String, Uint8List>{
        'CURRENT': Uint8List.fromList(utf8.encode('MANIFEST-000001\n')),
        '000003.log': _buildLevelDbWal(puts),
      };

      final rawTables = readTermiusIndexedDbTables(files);
      expect(rawTables.countsBeforeDedup['hosts'], 4);
      expect(rawTables['hosts'].length, 2);
      expect(firstTermiusCiphertext(rawTables.tables), isNotNull);

      final decryptor = TermiusVaultDecryptor(sodium, rawKey);
      addTearDown(decryptor.dispose);

      final doc = buildTermiusDocumentFromLocalTables(rawTables, decryptor);
      expect(doc.blocksWholeFile, isFalse);
      expect(doc.rows.length, 2);

      final plan = TermiusImportPlanner.plan(
        doc,
        TermiusCatalog(hosts: const [], groups: const []),
      );
      expect(plan.canApply, isTrue);
      expect(plan.createCount, 2);
      expect(plan.newGroups.map((g) => g.name), containsAll(['Prod', 'Core']));

      final bastion = plan.rows.firstWhere((r) => r.source.label == 'bastion');
      expect(bastion.source.address, '192.0.2.24');
      expect(bastion.source.port, 2222);
      expect(bastion.source.username, 'ops');
      expect(bastion.source.password, 'bastion-pw-42');
      expect(bastion.source.groupPath, ['Prod']);

      final appNode = plan.rows.firstWhere((r) => r.source.label == 'app-node');
      expect(appNode.source.address, '10.20.30.40');
      expect(appNode.source.username, 'ubuntu');
      expect(appNode.source.password, isNull);
      expect(appNode.source.privateKey, isNotNull);
      expect(appNode.source.groupPath, ['Prod', 'Core']);
      expect(appNode.source.tags, ['edge']);
      expect(appNode.source.jumpAlias, 'bastion');
      expect(appNode.source.forwards.length, 1);
      expect(appNode.source.forwards.single.bindPort, 15432);
      expect(appNode.source.forwards.single.destinationPort, 5432);
    });
  });

  group('One-click Termius UI flows', () {
    final syntheticDoc = buildTermiusDocumentFromDecryptedTables({
      'groups': [
        {'id': 1, 'label': 'Infra'},
      ],
      'hosts': [
        {
          'id': 10,
          'label': 'core-gw',
          'address': '198.51.100.25',
          'group': {'id': 1},
          'username': 'admin',
          'password': 'synthetic-password',
        },
      ],
    });

    testWidgets('runOneClickTermiusImport applies immediately without file picker or confirm dialog', (
      tester,
    ) async {
      final target = _FakeTransferTarget();
      TermiusTransferOutcome? outcome;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => HomeAddSharingRow(
                idPrefix: 'local',
                onAddHost: (_) {},
                onLaunchShell: (_) {},
                onSerialConsole: (_) {},
                onQuickImportTermius: () async {
                  outcome = await runOneClickTermiusImport(
                    context,
                    target: target,
                    loadLocalAppForTesting: () async => (
                      document: syntheticDoc,
                      sourceLabel: 'Termius Desktop',
                    ),
                  );
                },
                sharing: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );

      final quickBtn = find.byKey(
        const ValueKey('local_home_one_click_termius'),
      );
      expect(quickBtn, findsOneWidget);
      await tester.tap(quickBtn);
      await tester.pumpAndSettle();

      expect(outcome, isNotNull);
      expect(outcome!.importedHosts, 1);
      expect(outcome!.createdGroups, 1);
      expect(target.appliedPlans.length, 1);
      expect(
        find.byKey(const ValueKey('termius_import_confirm_dialog')),
        findsNothing,
      );
    });

    testWidgets('TermiusTransferDialog renders top one-click button and imports in one click', (
      tester,
    ) async {
      final target = _FakeTransferTarget();
      TermiusTransferOutcome? outcome;

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 1400);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: const ValueKey('open_dialog'),
                onPressed: () async {
                  outcome = await showDialog<TermiusTransferOutcome>(
                    context: context,
                    builder: (_) => TermiusTransferDialog(
                      target: target,
                      loadLocalAppForTesting: () async => (
                        document: syntheticDoc,
                        sourceLabel: 'Termius Desktop',
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('open_dialog')));
      await tester.pumpAndSettle();

      final oneClickBtn = find.byKey(
        const ValueKey('termius_one_click_local_import'),
      );
      expect(oneClickBtn, findsOneWidget);

      await tester.tap(oneClickBtn);
      await tester.pumpAndSettle();

      expect(outcome, isNotNull);
      expect(outcome!.importedHosts, 1);
      expect(outcome!.createdGroups, 1);
      expect(target.appliedPlans.length, 1);
    });
  });
}
