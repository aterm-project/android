import 'dart:convert';

import '../crypto/jcs.dart';
import 'client_database.dart';
import 'local_host_repository.dart';
import '../l10n/l10n.dart';

/// Verifies the exact records written by one LocalVault migration while
/// allowing independent records that another tab/device may add to the new
/// Vault after its creation.
void validateLocalMigrationTargetState({
  required List<EncryptedRecord> cached,
  required List<PendingOperation> pending,
  required Map<String, LocalMigrationStagedItem> stagedById,
  bool requireAllCommitted = false,
}) {
  final cachedById = <String, EncryptedRecord>{};
  for (final row in cached) {
    if (cachedById.containsKey(row.recordId)) {
      throw FormatException(
        currentL10n.theMigrationDestinationContainsDuplicateRecord,
      );
    }
    cachedById[row.recordId] = row;

    final staged = stagedById[row.recordId];
    if (staged == null) continue;
    if (row.isDeleted) {
      throw FormatException(currentL10n.aStagedRecordInTheMigration);
    }
    if (!_sameJson(row.envelopeJson, staged.targetEnvelopeJson)) {
      throw FormatException(
        currentL10n.theMigrationDestinationRecordDoesntMatch,
      );
    }
    if (requireAllCommitted && row.commitSeq == null) {
      throw FormatException(currentL10n.theServerHasntConfirmedAllMigration);
    }
  }

  final stagedOperationIds = <String, String>{};
  for (final entry in stagedById.entries) {
    final envelope = jsonDecode(entry.value.targetEnvelopeJson);
    if (envelope is! Map || envelope['header'] is! Map) {
      throw FormatException(currentL10n.invalidStagedMigrationCiphertextFormat);
    }
    final header = envelope['header'] as Map;
    final recordId = header['record_id'];
    final opId = header['op_id'];
    if (recordId != entry.key || opId is! String || opId.isEmpty) {
      throw FormatException(
        currentL10n.invalidStagedMigrationCiphertextContext,
      );
    }
    if (stagedOperationIds.containsKey(opId)) {
      throw FormatException(
        currentL10n.theMigrationJournalContainsDuplicateOperation,
      );
    }
    stagedOperationIds[opId] = entry.key;

    if (requireAllCommitted) {
      final row = cachedById[entry.key];
      if (row == null || row.isDeleted || row.commitSeq == null) {
        throw FormatException(currentL10n.theServerHasntConfirmedAllMigration);
      }
    }
  }

  final pendingMigrationRecordIds = <String>{};
  for (final operation in pending) {
    final stagedRecordId = stagedOperationIds[operation.opId];
    final staged = stagedById[operation.recordId];
    if (stagedRecordId == null && staged == null) {
      // Other pending records belong to concurrent work in the new Vault.
      continue;
    }
    if (stagedRecordId != operation.recordId || staged == null) {
      throw FormatException(
        currentL10n.theMigrationDestinationOutboxDoesntMatch2,
      );
    }
    if (!pendingMigrationRecordIds.add(operation.recordId) ||
        !_sameJson(operation.envelopeJson, staged.targetEnvelopeJson)) {
      throw FormatException(
        currentL10n.theMigrationDestinationOutboxDoesntMatch,
      );
    }
    if (requireAllCommitted) {
      throw FormatException(currentL10n.theMigrationRecordStillHasUnconfirmed);
    }
  }
}

bool _sameJson(String left, String right) {
  final decodedLeft = jsonDecode(left);
  final decodedRight = jsonDecode(right);
  return canonicalJson(decodedLeft) == canonicalJson(decodedRight);
}
