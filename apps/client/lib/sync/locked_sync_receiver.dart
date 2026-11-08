import 'dart:async';
import 'dart:typed_data';

import '../api/api_client.dart';
import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../domain/record_redaction.dart';
import '../storage/client_database.dart';

final _lockedCanonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _lockedCanonicalSequence = RegExp(r'^(0|[1-9][0-9]*)$');
const _lockedMaxI64 = '9223372036854775807';

class LockedSyncGenerationChangedException implements Exception {
  const LockedSyncGenerationChangedException();
}

/// Pulls only signed ciphertext pages while a Vault's decryption keys are
/// absent. It has no DeviceIdentity, Vault key, decrypt, push, or operation
/// creation capability. Verified pages are committed to a separate durable
/// inbox and cursor; the ordinary sync checkpoint is untouched.
class LockedSyncReceiver {
  LockedSyncReceiver({
    required this.api,
    required this.database,
    required this.crypto,
    required this.instanceId,
    required this.serverSpaceId,
    required this.vaultId,
    required this.serverGeneration,
    required this.trustedInstanceSigningPublicKey,
    this.maxPagesPerRun = 20,
  });

  final ApiClient api;
  final ClientDatabase database;
  final VaultCrypto crypto;
  final String instanceId;
  final String serverSpaceId;
  final String vaultId;
  final String serverGeneration;
  final String trustedInstanceSigningPublicKey;
  final int maxPagesPerRun;
  Future<void> _tail = Future<void>.value();

  Future<int> receive() {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    return previous.then((_) async {
      try {
        return await _receiveSerialized();
      } finally {
        release.complete();
      }
    });
  }

  Future<int> _receiveSerialized() async {
    final main = await database.checkpoint(
      vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
    );
    var locked = await database.ensureLockedSyncCheckpoint(
      vaultId: vaultId,
      instanceId: instanceId,
      serverSpaceId: serverSpaceId,
      serverGeneration: serverGeneration,
      initialCursor: main?.serverGeneration == serverGeneration
          ? main?.cursor
          : null,
    );
    var received = 0;
    final signers = await _signerDirectory();
    final seenCursors = <String>{};
    for (var pageNumber = 0; pageNumber < maxPagesPerRun; pageNumber++) {
      final startCursor = locked.cursor;
      if (startCursor != null) seenCursors.add(startCursor);
      final page = await api.changes(vaultId, cursor: startCursor);
      if (page.serverGeneration != serverGeneration) {
        throw const LockedSyncGenerationChangedException();
      }
      if ((page.events.isEmpty && page.hasMore) ||
          ((page.events.isNotEmpty || page.hasMore) &&
              page.nextCursor == null) ||
          (page.nextCursor != null &&
              (page.nextCursor!.isEmpty || page.nextCursor!.length > 2048)) ||
          (page.nextCursor == startCursor &&
              (page.hasMore || page.events.isNotEmpty)) ||
          (page.nextCursor != null &&
              page.nextCursor != startCursor &&
              !seenCursors.add(page.nextCursor!))) {
        throw const FormatException('Locked changes page cursor is invalid.');
      }
      for (final event in page.events) {
        _verifyEvent(event, signers);
      }
      final stored = await database.stageLockedSyncPage(
        vaultId: vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        serverGeneration: serverGeneration,
        expectedPageIndex: locked.nextPageIndex,
        expectedCursor: startCursor,
        nextCursor: page.nextCursor,
        hasMore: page.hasMore,
        hasEvents: page.events.isNotEmpty,
        eventsJson: canonicalJson(page.events),
      );
      if (!stored) {
        throw StateError('Locked sync checkpoint changed during page receipt.');
      }
      await database.flushCommittedWrites();
      received += page.events.length;
      if (!page.hasMore) break;
      locked = await database.ensureLockedSyncCheckpoint(
        vaultId: vaultId,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
        serverGeneration: serverGeneration,
        initialCursor: null,
      );
    }
    return received;
  }

  Future<Map<String, Uint8List>> _signerDirectory() async {
    final devices = <Map<String, dynamic>>[
      ...await api.devices(),
      ...await api.vaultDevices(vaultId),
    ];
    final signers = <String, Uint8List>{};
    final keyOwners = <String, String>{};
    for (final item in devices) {
      final id = item['device_id'];
      final encodedKey = item['signing_public_key'];
      if (id is! String ||
          !_lockedCanonicalUuid.hasMatch(id) ||
          encodedKey is! String ||
          encodedKey.isEmpty) {
        throw const FormatException('Locked signer directory is malformed.');
      }
      final key = decodeBase64Url(encodedKey);
      if (key.length != 32 || encodeBase64Url(key) != encodedKey) {
        throw const FormatException('Locked signer key encoding is invalid.');
      }
      final existing = signers[id];
      if (existing != null && !_sameBytes(existing, key)) {
        throw const FormatException(
          'Locked signer directory has conflicting device keys.',
        );
      }
      final owner = keyOwners[encodedKey];
      if (owner != null && owner != id) {
        throw const FormatException(
          'Locked signer directory reuses a key across device IDs.',
        );
      }
      signers[id] = Uint8List.fromList(key);
      keyOwners[encodedKey] = id;
    }
    return signers;
  }

  void _verifyEvent(
    Map<String, dynamic> event,
    Map<String, Uint8List> signers,
  ) {
    if (event['event_type'] == 'record_redacted') {
      if (!_hasExactKeys(event, const {
        'commit_seq',
        'event_type',
        'record_id',
        'redaction',
      })) {
        throw const FormatException(
          'Locked redaction event fields are invalid.',
        );
      }
      final sequence = event['commit_seq'];
      final recordId = event['record_id'];
      final rawProof = event['redaction'];
      if (sequence is! String ||
          !_isPositiveSequence(sequence) ||
          recordId is! String ||
          !_lockedCanonicalUuid.hasMatch(recordId) ||
          rawProof is! Map ||
          rawProof.keys.any((key) => key is! String)) {
        throw const FormatException(
          'Locked redaction event metadata is invalid.',
        );
      }
      final proof = RecordRedactionProof.verify(
        Map<String, dynamic>.from(rawProof),
        crypto: crypto,
        expectedInstanceId: instanceId,
        expectedServerSpaceId: serverSpaceId,
        expectedVaultId: vaultId,
        expectedRecordId: recordId,
        currentPinnedSigningPublicKey: trustedInstanceSigningPublicKey,
      );
      if (BigInt.parse(sequence) > BigInt.parse(proof.redactionSeq)) {
        throw const FormatException('Locked redaction sequence exceeds proof.');
      }
      return;
    }
    if (!_hasExactKeys(event, const {
      'commit_seq',
      'event_type',
      'record_id',
      'revision_id',
      'envelope',
    })) {
      throw const FormatException('Locked change event fields are invalid.');
    }
    final sequence = event['commit_seq'];
    final eventType = event['event_type'];
    final recordId = event['record_id'];
    final revisionId = event['revision_id'];
    final rawEnvelope = event['envelope'];
    if (sequence is! String ||
        !_isPositiveSequence(sequence) ||
        eventType is! String ||
        !const {'create', 'update', 'delete', 'restore'}.contains(eventType) ||
        recordId is! String ||
        !_lockedCanonicalUuid.hasMatch(recordId) ||
        revisionId is! String ||
        !_lockedCanonicalUuid.hasMatch(revisionId) ||
        rawEnvelope is! Map ||
        rawEnvelope.keys.any((key) => key is! String)) {
      throw const FormatException('Locked change event metadata is invalid.');
    }
    final envelope = Map<String, dynamic>.from(rawEnvelope);
    final header = crypto.validateRecordEnvelope(envelope);
    if (header['record_id'] != recordId ||
        header['revision_id'] != revisionId ||
        header['operation'] != eventType ||
        header['vault_id'] != vaultId ||
        header['server_space_id'] != serverSpaceId) {
      throw const FormatException(
        'Locked event metadata does not match its signed envelope.',
      );
    }
    final signerId = header['device_id'];
    final signer = signerId is String ? signers[signerId] : null;
    if (signer == null) {
      throw const FormatException(
        'Locked event signer is not in the directory.',
      );
    }
    crypto.verifyRecordSignature(envelope: envelope, authorPublicKey: signer);
  }

  bool _isPositiveSequence(String value) =>
      _lockedCanonicalSequence.hasMatch(value) &&
      value != '0' &&
      (value.length < _lockedMaxI64.length ||
          (value.length == _lockedMaxI64.length &&
              value.compareTo(_lockedMaxI64) <= 0));

  bool _hasExactKeys(Map<String, dynamic> value, Set<String> expected) =>
      value.length == expected.length &&
      value.keys.toSet().containsAll(expected);

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left[index] ^ right[index];
    }
    return difference == 0;
  }
}
