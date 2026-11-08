import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'attachment_file_saver.dart' show maxAttachmentBytesForPlatform;
import 'attachment_upload_source.dart';
import '../api/api_client.dart';
import '../crypto/host_attachment_crypto.dart';
import '../crypto/jcs.dart';
import '../domain/models.dart';
import '../storage/client_database.dart';
import '../l10n/l10n.dart';

const _maxObjectTransportChunkBytes = 1024 * 1024;
const _maxObjectRefs = 1024;
const _maxHostManifestBytes = 32 * 1024;
final _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

Future<String> _digestHex(List<int> bytes) async =>
    (await cryptography.Sha256().hash(
      bytes,
    )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

class HostAttachmentSummary {
  const HostAttachmentSummary({
    required this.blobId,
    required this.fileName,
    required this.mediaType,
    required this.totalSize,
    this.formatVersion = 1,
    this.transferState,
    this.transferProgress,
  });

  final String blobId;
  final String fileName;
  final String mediaType;
  final int totalSize;
  final int formatVersion;
  bool get canDownload => totalSize <= maxAttachmentBytesForPlatform;
  final String? transferState;
  final String? transferProgress;
}

class HostAttachmentV2Preflight {
  const HostAttachmentV2Preflight({
    required this.supportedActiveDevices,
    required this.reason,
  });

  final int supportedActiveDevices;
  final String? reason;

  bool get canUpload => reason == null;
}

class HostAttachmentV2UnavailableException implements Exception {
  const HostAttachmentV2UnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class HostAttachmentTransferSummary {
  const HostAttachmentTransferSummary({
    required this.blobId,
    required this.direction,
    required this.state,
    required this.completedObjects,
    required this.totalObjects,
    required this.transferredBytes,
    required this.totalBytes,
    required this.canResume,
  });

  final String blobId;
  final String direction;
  final String state;
  final int completedObjects;
  final int totalObjects;
  final int transferredBytes;
  final int totalBytes;
  final bool canResume;
}

/// Persists ciphertext transfer state and the encrypted HostRecord together;
/// queued record pushes remain gated until every referenced object is present.
class HostAttachmentService {
  HostAttachmentService({
    required this.api,
    required this.crypto,
    required this.database,
    this.instanceId,
    this.serverSpaceId,
    this.ensureDeviceCapabilityReported,
    this.verifyV2ReaderCapability,
    @visibleForTesting
    this.streamingDownloadMinimumBytes = hostAttachmentMaxBytes,
    @visibleForTesting this.platformAttachmentLimitOverride,
  });

  final ApiClient api;
  final HostAttachmentCrypto crypto;
  final ClientDatabase database;
  final String? instanceId;
  final String? serverSpaceId;
  final Future<void> Function()? ensureDeviceCapabilityReported;
  final bool Function(Map<String, dynamic> device)? verifyV2ReaderCapability;
  @visibleForTesting
  final int streamingDownloadMinimumBytes;
  @visibleForTesting
  final int? platformAttachmentLimitOverride;

  List<HostAttachmentSummary> list(HostRecord host) {
    final current = _read(host);
    try {
      return current.entries
          .map(
            (entry) => HostAttachmentSummary(
              blobId: entry.blobId,
              fileName: entry.fileName,
              mediaType: entry.mediaType,
              totalSize: entry.totalSize,
              formatVersion: entry.formatVersion,
            ),
          )
          .toList(growable: false);
    } finally {
      current.clearSecrets();
    }
  }

  Future<HostRecord> add({
    required String vaultId,
    required HostRecord host,
    required String fileName,
    required String mediaType,
    required List<int> plaintext,
    required Future<void> Function(HostRecord updated) commit,
  }) => addFromSource(
    vaultId: vaultId,
    host: host,
    fileName: fileName,
    mediaType: mediaType,
    source: MemoryAttachmentUploadSource(plaintext),
    commit: commit,
  );

  Future<HostRecord> addFromSource({
    required String vaultId,
    required HostRecord host,
    required String fileName,
    required String mediaType,
    required AttachmentUploadSource source,
    required Future<void> Function(HostRecord updated) commit,
  }) async {
    final useV2 = source.size > hostAttachmentMaxBytes;
    if (useV2) {
      if (source is! BoundedAttachmentUploadSource) {
        throw const HostAttachmentV2UnavailableException(
          'Attachments above 256 MiB require a bounded streaming source; no plaintext was read or staged.',
        );
      }
      final preflight = await preflightV2Upload(
        vaultId: vaultId,
        totalSize: source.size,
      );
      if (!preflight.canUpload) {
        throw HostAttachmentV2UnavailableException(
          preflight.reason ?? currentL10n.someDevicesInTheVaultDont,
        );
      }
    }
    final current = _read(host);
    String? jobId;
    var committed = false;
    try {
      Future<void> onStart(String blobId) async {
        jobId = _jobId(
          'upload',
          vaultId,
          host.id,
          blobId,
          instanceId,
          serverSpaceId,
        );
        await database.beginBlobJob(
          jobId: jobId!,
          vaultId: vaultId,
          recordId: host.id,
          blobId: blobId,
          direction: 'upload',
          state: 'encrypting',
          instanceId: instanceId,
          serverSpaceId: serverSpaceId,
        );
      }

      Future<void> onObject(EncryptedAttachmentObject object) async {
        final id = jobId;
        if (id == null) throw StateError('Attachment job did not start.');
        try {
          if (!_canonicalUuid.hasMatch(object.objectId) ||
              object.bytes.isEmpty ||
              object.bytes.length > hostAttachmentLogicalChunkBytes + 16 ||
              !_sha256Hex.hasMatch(object.sha256) ||
              await _digestHex(object.bytes) != object.sha256) {
            throw FormatException(currentL10n.localIntegrityVerificationOfTheEncrypted);
          }
          await database.stageBlobUploadObject(
            jobId: id,
            objectId: object.objectId,
            sha256: object.sha256,
            bytes: object.bytes,
          );
        } finally {
          object.bytes.fillRange(0, object.bytes.length, 0);
        }
      }

      final manifestEntry = useV2
          ? await crypto.encryptSourceForTransferV2(
              fileName: fileName,
              mediaType: mediaType,
              source: source,
              onStart: onStart,
              onObject: onObject,
            )
          : await crypto.encryptSourceForTransfer(
              fileName: fileName,
              mediaType: mediaType,
              source: source,
              onStart: onStart,
              onObject: onObject,
            );
      final blobId = manifestEntry['blob_id']! as String;
      final objectIds = _manifestObjectIds(manifestEntry);
      final refs = current.objectRefs.toSet();
      for (final objectId in objectIds) {
        if (!refs.add(objectId)) {
          throw FormatException(currentL10n.theAttachmentObjectIdDuplicatesAn);
        }
      }
      if (refs.length > _maxObjectRefs) {
        throw FormatException(currentL10n.thisHostsAttachmentObjectReferencesExceed);
      }

      final updatedManifest =
          Map<String, Object?>.from(host.manifest ?? const {})
            ..['attachments'] = [
              ...current.entries.map((entry) => entry.manifestEntry),
              manifestEntry,
            ]
            ..['object_refs'] = (refs.toList()..sort());
      _validateHostManifestSize(updatedManifest);
      final updated = host.copyWith(manifest: updatedManifest);
      await database.updateBlobJobObjectCount(jobId!, objectIds.length);
      await database.updateBlobJobState(jobId!, 'uploading');
      // Persist the encrypted Host operation before network transfer. The
      // sync repository excludes its record while this durable job is open.
      committed = true;
      // Treat a thrown callback as potentially committed: saveHost may have
      // written the local outbox before a later status refresh fails. Keeping
      // the task is safer than allowing the record to sync without its blobs.
      await commit(updated);
      await resumeUpload(vaultId: vaultId, host: updated, blobId: blobId);
      return updated;
    } catch (error) {
      final id = jobId;
      if (id != null) {
        if (committed) {
          await database.updateBlobJobState(
            id,
            'failed',
            errorCode: _safeErrorCode(error),
          );
        } else {
          await database.deleteBlobJob(id);
        }
      }
      rethrow;
    } finally {
      current.clearSecrets();
    }
  }

  /// Checks server support and every active member device's signed report
  /// before a v2 write can be considered.
  Future<HostAttachmentV2Preflight> preflightV2Upload({
    required String vaultId,
    required int totalSize,
  }) async {
    if (totalSize <= hostAttachmentMaxBytes) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason: currentL10n.v2PreflightIsOnlyRequiredAbove,
      );
    }
    if (totalSize > hostAttachmentV2MaxBytes) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason: currentL10n.attachmentsAreLimitedTo1Gib,
      );
    }
    if (totalSize >
        (platformAttachmentLimitOverride ?? maxAttachmentBytesForPlatform)) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason:
            currentL10n.thisPlatformCannotSafelySaveAttachments,
      );
    }
    final report = ensureDeviceCapabilityReported;
    if (report == null) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason:
            currentL10n.thisDeviceHasNotPublishedIts,
      );
    }
    try {
      await report();
    } catch (_) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason:
            currentL10n.thisDeviceCapabilityReportCouldNot,
      );
    }
    final verifyReader = verifyV2ReaderCapability;
    if (verifyReader == null) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason:
            currentL10n.thisClientCannotAuthenticateOtherDevices,
      );
    }

    final instance = await api.fetchInstance();
    if (!instance.capabilities.contains('device_capability_reports')) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason:
            currentL10n.theServerDoesNotSupportSigned,
      );
    }

    final devices = await api.vaultDevices(vaultId);
    if (devices.isEmpty) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason: currentL10n.theVaultHasNoActiveDevice,
      );
    }
    var activeCount = 0;
    for (final device in devices) {
      final membershipStatus = device['membership_status'];
      final status = device['status'];
      if (membershipStatus is! String ||
          !const {
            'active',
            'invited',
            'revoked',
            'archived',
          }.contains(membershipStatus) ||
          status is! String ||
          !const {'active', 'revoked', 'archived'}.contains(status)) {
        return HostAttachmentV2Preflight(
          supportedActiveDevices: 0,
          reason:
              currentL10n.theServerReturnedAnInvalidVault,
        );
      }
      if (membershipStatus != 'active' || status != 'active') continue;
      activeCount++;
      if (!_supportsAttachmentV2(device, totalSize, verifyReader)) {
        final deviceName = device['name'] is String
            ? (device['name'] as String)
            : 'an active Vault device';
        return HostAttachmentV2Preflight(
          supportedActiveDevices: activeCount - 1,
          reason:
              currentL10n.devicenameHasNoValidSignedReport(deviceName),
        );
      }
    }
    if (activeCount == 0) {
      return HostAttachmentV2Preflight(
        supportedActiveDevices: 0,
        reason: currentL10n.theVaultHasNoActiveDevices,
      );
    }
    return HostAttachmentV2Preflight(
      supportedActiveDevices: activeCount,
      reason: null,
    );
  }

  Future<void> resumeUpload({
    required String vaultId,
    required HostRecord host,
    required String blobId,
  }) async {
    final jobId = _jobId(
      'upload',
      vaultId,
      host.id,
      blobId,
      instanceId,
      serverSpaceId,
    );
    final job = await database.blobJob(jobId);
    if (job == null || job.direction != 'upload') {
      throw StateError('No resumable attachment upload exists.');
    }
    final current = _read(host);
    try {
      final entry = current.entries
          .where((item) => item.blobId == blobId)
          .firstOrNull;
      if (entry == null) {
        throw StateError(
          'The encrypted Host record no longer references this attachment.',
        );
      }
      final rows = await database.blobJobObjectProgressRows(jobId);
      if (rows.length != entry.objectIds.length ||
          rows.any((row) => !entry.objectIds.contains(row.objectId))) {
        throw StateError(
          'The durable attachment ciphertext staging is incomplete.',
        );
      }
      final rowsByObjectId = {for (final row in rows) row.objectId: row};
      await database.updateBlobJobState(jobId, 'uploading');
      final v2 = entry.v2Entry;
      ResolvedHostAttachmentV2? resolvedV2;
      if (v2 != null) {
        final sidecar = await database.blobJobObject(
          jobId,
          v2.manifestObjectId,
        );
        final bytes = sidecar?.bytes;
        if (sidecar == null ||
            bytes == null ||
            bytes.length != v2.manifestCiphertextSize ||
            sidecar.sha256 != v2.manifestCiphertextSha256 ||
            await _digestHex(bytes) != v2.manifestCiphertextSha256) {
          throw FormatException(currentL10n.theLocalAttachmentEncryptionDirectoryIs);
        }
        try {
          resolvedV2 = await crypto.resolveV2Manifest(
            manifestEntry: v2.raw,
            manifestCiphertext: bytes,
          );
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }
      final uploadObjects = v2 == null
          ? entry.chunks
          : <HostAttachmentChunk>[
              ...resolvedV2!.chunks,
              HostAttachmentChunk(
                objectId: v2.manifestObjectId,
                index: -1,
                plaintextSize: 0,
                ciphertextSize: v2.manifestCiphertextSize,
                sha256: v2.manifestCiphertextSha256,
                nonceText: v2.manifestNonceText,
                nonce: v2.manifestNonce,
              ),
            ];
      try {
        for (final chunk in uploadObjects) {
          final progress = rowsByObjectId[chunk.objectId]!;
          if (progress.transferred) continue;
          // Load one durable ciphertext object at a time. The metadata scan
          // above deliberately excludes all BLOB columns.
          final row = await database.blobJobObject(jobId, chunk.objectId);
          if (row == null) {
            throw FormatException(currentL10n.theLocalAttachmentObjectWaitingFor);
          }
          final ciphertext = row.bytes;
          if (ciphertext == null ||
              ciphertext.length != chunk.ciphertextSize ||
              row.sha256 != chunk.sha256 ||
              await _digestHex(ciphertext) != chunk.sha256) {
            throw FormatException(currentL10n.integrityVerificationOfTheLocalAttachment);
          }
          try {
            await _uploadCiphertextObject(
              vaultId,
              jobId,
              row.objectId,
              ciphertext,
              row,
            );
            await database.markBlobUploadObjectTransferred(jobId, row.objectId);
          } finally {
            ciphertext.fillRange(0, ciphertext.length, 0);
          }
        }
      } finally {
        // The synthetic directory chunk points at the descriptor nonce. Do not
        // wipe that shared secret here; _read owns and clears it at the end.
        resolvedV2?.clearSecrets();
      }
      await database.deleteBlobJob(jobId);
    } catch (error) {
      await database.updateBlobJobState(
        jobId,
        'failed',
        errorCode: _safeErrorCode(error),
      );
      rethrow;
    } finally {
      current.clearSecrets();
    }
  }

  Future<List<HostAttachmentTransferSummary>> transfers(
    String vaultId,
    HostRecord host,
  ) async {
    final current = _read(host);
    try {
      final attachedIds = current.entries.map((entry) => entry.blobId).toSet();
      final jobs = await database.blobJobsForRecord(
        vaultId,
        host.id,
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      final summaries = <HostAttachmentTransferSummary>[];
      for (final job in jobs) {
        final objects = await database.blobJobObjectProgressRows(job.jobId);
        final transferredBytes = objects.fold<int>(0, (sum, item) {
          if (item.transferred) return sum + item.size;
          if (job.direction == 'upload') {
            final chunkSize = item.uploadChunkSize ?? 0;
            return sum +
                (chunkSize == 0
                    ? 0
                    : (item.nextChunkIndex * chunkSize)
                          .clamp(0, item.size)
                          .toInt());
          }
          return sum + item.stagedBytes;
        });
        final totalBytes = objects.fold<int>(0, (sum, item) => sum + item.size);
        summaries.add(
          HostAttachmentTransferSummary(
            blobId: job.blobId,
            direction: job.direction,
            state: job.state,
            completedObjects: objects.where((item) => item.transferred).length,
            totalObjects: job.totalObjects,
            transferredBytes: transferredBytes,
            totalBytes: totalBytes,
            canResume:
                job.direction == 'download' ||
                (job.direction == 'upload' && attachedIds.contains(job.blobId)),
          ),
        );
      }
      return summaries;
    } finally {
      current.clearSecrets();
    }
  }

  Future<void> discardOrphanUpload({
    required String vaultId,
    required HostRecord host,
    required String blobId,
  }) async {
    final current = _read(host);
    try {
      if (current.entries.any((item) => item.blobId == blobId)) {
        throw StateError(
          'An attachment referenced by the Host cannot be discarded.',
        );
      }
      final job = await database.blobJob(
        _jobId('upload', vaultId, host.id, blobId, instanceId, serverSpaceId),
      );
      if (job != null) {
        final objects = await database.blobJobObjectProgressRows(job.jobId);
        for (final object in objects) {
          if (await database.pendingRecordReferencesObject(
            vaultId: vaultId,
            recordId: host.id,
            objectId: object.objectId,
            instanceId: instanceId,
            serverSpaceId: serverSpaceId,
          )) {
            throw StateError(
              'A pending encrypted Host operation still references this upload.',
            );
          }
        }
      }
      await database.deleteBlobJob(
        _jobId('upload', vaultId, host.id, blobId, instanceId, serverSpaceId),
      );
    } finally {
      current.clearSecrets();
    }
  }

  Future<HostRecord> remove({
    required String vaultId,
    required HostRecord host,
    required String blobId,
    required Future<void> Function(HostRecord updated) commit,
  }) async {
    final current = _read(host);
    try {
      final removed = current.entries
          .where((entry) => entry.blobId == blobId)
          .toList(growable: false);
      if (removed.isEmpty) {
        throw StateError(currentL10n.theAttachmentIsntInThisHosts);
      }
      final remaining = current.entries
          .where((entry) => entry.blobId != blobId)
          .toList(growable: false);
      final retainedAttachmentRefs = remaining
          .expand((entry) => entry.objectIds)
          .toSet();
      final removedAttachmentRefs = removed
          .expand((entry) => entry.objectIds)
          .toSet();
      final refs = current.objectRefs.toSet()
        ..removeWhere(
          (id) =>
              removedAttachmentRefs.contains(id) &&
              !retainedAttachmentRefs.contains(id),
        );
      final updatedManifest =
          Map<String, Object?>.from(host.manifest ?? const {})
            ..['attachments'] = remaining
                .map((entry) => entry.manifestEntry)
                .toList(growable: false)
            ..['object_refs'] = (refs.toList()..sort());
      _validateHostManifestSize(updatedManifest);
      final updated = host.copyWith(manifest: updatedManifest);
      await commit(updated);
      // Removing the attachment from the encrypted Host record makes any
      // local retry task obsolete. The server independently keeps immutable
      // historical references until normal object GC.
      await database.deleteBlobJob(
        _jobId('upload', vaultId, host.id, blobId, instanceId, serverSpaceId),
      );
      await database.deleteBlobJob(
        _jobId('download', vaultId, host.id, blobId, instanceId, serverSpaceId),
      );
      return updated;
    } finally {
      current.clearSecrets();
    }
  }

  Future<Uint8List> download({
    required String vaultId,
    required HostRecord host,
    required String blobId,
  }) async {
    final current = _read(host);
    final matches = current.entries.where((item) => item.blobId == blobId);
    final entry = matches.isEmpty ? null : matches.first;
    if (entry == null) {
      current.clearSecrets();
      throw StateError(currentL10n.theAttachmentIsntInThisHosts);
    }
    if (entry.totalSize > hostAttachmentMaxBytes) {
      current.clearSecrets();
      throw HostAttachmentV2UnavailableException(
        currentL10n.thisV2AttachmentExceeds256Mib,
      );
    }
    final jobId = _jobId(
      'download',
      vaultId,
      host.id,
      blobId,
      instanceId,
      serverSpaceId,
    );
    try {
      await database.beginBlobJob(
        jobId: jobId,
        vaultId: vaultId,
        recordId: host.id,
        blobId: blobId,
        direction: 'download',
        state: 'downloading',
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      late final Uint8List plaintext;
      final v2 = entry.v2Entry;
      if (v2 == null) {
        await database.prepareBlobDownloadObjects(
          jobId: jobId,
          objects: [
            for (final chunk in entry.chunks)
              (
                objectId: chunk.objectId,
                sha256: chunk.sha256,
                size: chunk.ciphertextSize,
              ),
          ],
        );
        plaintext = await crypto.decryptWithLoader(
          manifestEntry: entry.raw,
          loadCiphertext: (chunk) => _downloadCiphertextObject(
            jobId: jobId,
            vaultId: vaultId,
            objectId: chunk.objectId,
            ciphertextSize: chunk.ciphertextSize,
            sha256: chunk.sha256,
          ),
        );
      } else {
        await database.prepareBlobDownloadObjects(
          jobId: jobId,
          objects: [
            (
              objectId: v2.manifestObjectId,
              sha256: v2.manifestCiphertextSha256,
              size: v2.manifestCiphertextSize,
            ),
          ],
        );
        final directoryCiphertext = await _downloadCiphertextObject(
          jobId: jobId,
          vaultId: vaultId,
          objectId: v2.manifestObjectId,
          ciphertextSize: v2.manifestCiphertextSize,
          sha256: v2.manifestCiphertextSha256,
        );
        ResolvedHostAttachmentV2? resolved;
        try {
          resolved = await crypto.resolveV2Manifest(
            manifestEntry: v2.raw,
            manifestCiphertext: directoryCiphertext,
          );
          await database.prepareBlobDownloadObjects(
            jobId: jobId,
            objects: [
              (
                objectId: v2.manifestObjectId,
                sha256: v2.manifestCiphertextSha256,
                size: v2.manifestCiphertextSize,
              ),
              for (final chunk in resolved.chunks)
                (
                  objectId: chunk.objectId,
                  sha256: chunk.sha256,
                  size: chunk.ciphertextSize,
                ),
            ],
          );
          plaintext = Uint8List(v2.totalSize);
          var offset = 0;
          try {
            for (var index = 0; index < resolved.chunks.length; index++) {
              final chunk = resolved.chunks[index];
              final ciphertext = await _downloadCiphertextObject(
                jobId: jobId,
                vaultId: vaultId,
                objectId: chunk.objectId,
                ciphertextSize: chunk.ciphertextSize,
                sha256: chunk.sha256,
              );
              try {
                final clear = await crypto.decryptV2Chunk(
                  attachment: resolved,
                  index: index,
                  ciphertext: ciphertext,
                );
                try {
                  plaintext.setRange(offset, offset + clear.length, clear);
                  offset += clear.length;
                } finally {
                  clear.fillRange(0, clear.length, 0);
                }
              } finally {
                ciphertext.fillRange(0, ciphertext.length, 0);
              }
            }
            if (offset != plaintext.length ||
                await _digestHex(plaintext) != v2.plaintextSha256) {
              throw FormatException(currentL10n.attachmentPlaintextDigestOrTotalLength);
            }
          } catch (_) {
            plaintext.fillRange(0, plaintext.length, 0);
            rethrow;
          }
        } finally {
          directoryCiphertext.fillRange(0, directoryCiphertext.length, 0);
          resolved?.clearSecrets();
        }
      }
      await database.updateBlobJobState(jobId, 'ready_to_save');
      return plaintext;
    } catch (error) {
      await database.updateBlobJobState(
        jobId,
        'failed',
        errorCode: _safeErrorCode(error),
      );
      rethrow;
    } finally {
      current.clearSecrets();
    }
  }

  /// Streams a large v2 attachment to a temporary destination in two passes.
  /// The first pass authenticates every chunk and the whole-file digest before
  /// any plaintext reaches [onPlaintextChunk]. The second pass repeats all
  /// checks while emitting one bounded plaintext chunk at a time.
  Future<void> downloadToSink({
    required String vaultId,
    required HostRecord host,
    required String blobId,
    required Future<void> Function(Uint8List plaintextChunk) onPlaintextChunk,
  }) async {
    final current = _read(host);
    final entry = current.entries
        .where((item) => item.blobId == blobId)
        .firstOrNull;
    if (entry == null) {
      current.clearSecrets();
      throw StateError(currentL10n.theAttachmentIsntInThisHosts);
    }
    final descriptor = entry.v2Entry;
    if (descriptor == null ||
        descriptor.totalSize <= streamingDownloadMinimumBytes) {
      current.clearSecrets();
      throw StateError(
        'Streaming download is reserved for v2 attachments larger than 256 MiB.',
      );
    }

    final jobId = _jobId(
      'download',
      vaultId,
      host.id,
      blobId,
      instanceId,
      serverSpaceId,
    );
    Uint8List? directoryCiphertext;
    ResolvedHostAttachmentV2? resolved;
    try {
      await database.beginBlobJob(
        jobId: jobId,
        vaultId: vaultId,
        recordId: host.id,
        blobId: blobId,
        direction: 'download',
        state: 'downloading',
        instanceId: instanceId,
        serverSpaceId: serverSpaceId,
      );
      await database.prepareBlobDownloadObjects(
        jobId: jobId,
        objects: [
          (
            objectId: descriptor.manifestObjectId,
            sha256: descriptor.manifestCiphertextSha256,
            size: descriptor.manifestCiphertextSize,
          ),
        ],
      );
      directoryCiphertext = await _downloadCiphertextObject(
        jobId: jobId,
        vaultId: vaultId,
        objectId: descriptor.manifestObjectId,
        ciphertextSize: descriptor.manifestCiphertextSize,
        sha256: descriptor.manifestCiphertextSha256,
      );
      resolved = await crypto.resolveV2Manifest(
        manifestEntry: descriptor.raw,
        manifestCiphertext: directoryCiphertext,
      );
      final attachment = resolved;
      await database.prepareBlobDownloadObjects(
        jobId: jobId,
        objects: [
          (
            objectId: descriptor.manifestObjectId,
            sha256: descriptor.manifestCiphertextSha256,
            size: descriptor.manifestCiphertextSize,
          ),
          for (final chunk in attachment.chunks)
            (
              objectId: chunk.objectId,
              sha256: chunk.sha256,
              size: chunk.ciphertextSize,
            ),
        ],
      );

      final firstDigest = cryptography.Sha256().toSync().newHashSink();
      var firstPassLength = 0;
      for (var index = 0; index < attachment.chunks.length; index++) {
        final chunk = attachment.chunks[index];
        final ciphertext = await _downloadCiphertextObject(
          jobId: jobId,
          vaultId: vaultId,
          objectId: chunk.objectId,
          ciphertextSize: chunk.ciphertextSize,
          sha256: chunk.sha256,
        );
        try {
          final plaintext = await crypto.decryptV2Chunk(
            attachment: attachment,
            index: index,
            ciphertext: ciphertext,
          );
          try {
            if (firstPassLength + plaintext.length > descriptor.totalSize) {
              throw FormatException(currentL10n.theTotalAttachmentPlaintextLengthExceeds);
            }
            firstDigest.addSlice(plaintext, 0, plaintext.length, false);
            firstPassLength += plaintext.length;
          } finally {
            plaintext.fillRange(0, plaintext.length, 0);
          }
        } finally {
          ciphertext.fillRange(0, ciphertext.length, 0);
        }
      }
      firstDigest.close();
      final firstPassSha = _hex((await firstDigest.hash()).bytes);
      if (firstPassLength != descriptor.totalSize ||
          firstPassSha != descriptor.plaintextSha256) {
        throw FormatException(currentL10n.attachmentPlaintextDigestOrTotalLength);
      }

      final secondDigest = cryptography.Sha256().toSync().newHashSink();
      var secondPassLength = 0;
      for (var index = 0; index < attachment.chunks.length; index++) {
        final chunk = attachment.chunks[index];
        final ciphertext = await _downloadCiphertextObject(
          jobId: jobId,
          vaultId: vaultId,
          objectId: chunk.objectId,
          ciphertextSize: chunk.ciphertextSize,
          sha256: chunk.sha256,
        );
        try {
          final plaintext = await crypto.decryptV2Chunk(
            attachment: attachment,
            index: index,
            ciphertext: ciphertext,
          );
          try {
            if (secondPassLength + plaintext.length > descriptor.totalSize) {
              throw FormatException(currentL10n.theTotalAttachmentPlaintextLengthExceeds);
            }
            secondDigest.addSlice(plaintext, 0, plaintext.length, false);
            secondPassLength += plaintext.length;
            await onPlaintextChunk(plaintext);
          } finally {
            plaintext.fillRange(0, plaintext.length, 0);
          }
        } finally {
          ciphertext.fillRange(0, ciphertext.length, 0);
        }
      }
      secondDigest.close();
      final secondPassSha = _hex((await secondDigest.hash()).bytes);
      if (secondPassLength != descriptor.totalSize ||
          secondPassSha != descriptor.plaintextSha256) {
        throw FormatException(currentL10n.attachmentPlaintextDigestOrTotalLength);
      }
      await database.updateBlobJobState(jobId, 'ready_to_save');
    } catch (error) {
      await database.updateBlobJobState(
        jobId,
        'failed',
        errorCode: _safeErrorCode(error),
      );
      rethrow;
    } finally {
      directoryCiphertext?.fillRange(0, directoryCiphertext.length, 0);
      resolved?.clearSecrets();
      current.clearSecrets();
    }
  }

  Future<void> completeDownload({
    required String vaultId,
    required String recordId,
    required String blobId,
  }) => database.deleteBlobJob(
    _jobId('download', vaultId, recordId, blobId, instanceId, serverSpaceId),
  );

  _HostAttachmentManifest _read(HostRecord host) {
    final raw = host.manifest ?? const <String, Object?>{};
    final rawAttachments = raw.containsKey('attachments')
        ? raw['attachments']
        : const [];
    if (rawAttachments is! List || rawAttachments.length > _maxObjectRefs) {
      throw FormatException(currentL10n.invalidHostAttachmentManifestFormat);
    }
    final entries = <_ParsedHostAttachment>[];
    final blobIds = <String>{};
    final attachmentObjectIds = <String>{};
    try {
      for (final value in rawAttachments) {
        final parsed = _parseAttachment(value);
        if (!blobIds.add(parsed.blobId)) {
          parsed.clearSecrets();
          throw FormatException(currentL10n.duplicateHostAttachmentBlobId);
        }
        for (final id in parsed.objectIds) {
          if (!attachmentObjectIds.add(id)) {
            parsed.clearSecrets();
            throw FormatException(currentL10n.differentAttachmentsReferenceTheSameObject);
          }
        }
        entries.add(parsed);
      }
      final objectRefs = raw.containsKey('object_refs')
          ? _validateObjectRefs(raw['object_refs'])
          : const <String>[];
      if (!objectRefs.toSet().containsAll(attachmentObjectIds)) {
        throw FormatException(currentL10n.theEncryptedAttachmentManifestDoesntMatch);
      }
      return _HostAttachmentManifest(entries, objectRefs);
    } catch (_) {
      for (final entry in entries) {
        entry.clearSecrets();
      }
      rethrow;
    }
  }

  Future<void> _uploadCiphertextObject(
    String vaultId,
    String jobId,
    String objectId,
    Uint8List bytes,
    BlobJobObject initial,
  ) async {
    var uploadId = initial.uploadId;
    var chunkSize = initial.uploadChunkSize;
    var nextChunkIndex = initial.nextChunkIndex;
    var expiredRetries = 0;
    while (true) {
      try {
        if (uploadId == null) {
          final initialized = await api.initUpload(vaultId, {
            'object_id': objectId,
            'size': bytes.length,
            'sha256': initial.sha256,
          });
          final returnedId = initialized['upload_id'];
          final returnedChunkSize = initialized['chunk_size'];
          if (returnedId is! String ||
              !_canonicalUuid.hasMatch(returnedId) ||
              returnedChunkSize is! int ||
              returnedChunkSize < 1 ||
              returnedChunkSize > _maxObjectTransportChunkBytes) {
            throw FormatException(currentL10n.theServerReturnedAnInvalidUpload);
          }
          uploadId = returnedId;
          chunkSize = returnedChunkSize;
          nextChunkIndex = 0;
          await database.updateBlobUploadProgress(
            jobId: jobId,
            objectId: objectId,
            uploadId: uploadId,
            chunkSize: chunkSize,
            nextChunkIndex: nextChunkIndex,
          );
        }
        final activeChunkSize = chunkSize;
        if (activeChunkSize == null ||
            activeChunkSize < 1 ||
            activeChunkSize > _maxObjectTransportChunkBytes) {
          throw FormatException(currentL10n.invalidPersistedUploadChunkSize);
        }
        final chunkCount =
            (bytes.length + activeChunkSize - 1) ~/ activeChunkSize;
        if (nextChunkIndex < 0 || nextChunkIndex > chunkCount) {
          throw FormatException(currentL10n.invalidPersistedUploadProgress);
        }
        for (var index = nextChunkIndex; index < chunkCount; index++) {
          final offset = index * activeChunkSize;
          final end = offset + activeChunkSize < bytes.length
              ? offset + activeChunkSize
              : bytes.length;
          final transportChunk = Uint8List.sublistView(bytes, offset, end);
          await api.uploadChunk(
            uploadId: uploadId,
            index: index,
            bytes: transportChunk,
            sha256: await _digestHex(transportChunk),
          );
          nextChunkIndex = index + 1;
          await database.updateBlobUploadProgress(
            jobId: jobId,
            objectId: objectId,
            uploadId: uploadId,
            chunkSize: activeChunkSize,
            nextChunkIndex: nextChunkIndex,
          );
        }
        final completed = await api.completeUpload(uploadId, const {});
        final completedSize = completed['size'];
        if (completed['object_id'] != objectId ||
            completedSize is! int ||
            completedSize != bytes.length ||
            completed['sha256'] != initial.sha256) {
          throw FormatException(currentL10n.theServerAttachmentUploadReceiptDoesnt);
        }
        return;
      } on ApiException catch (error) {
        if (error.code == 'OBJECT_EXISTS' && uploadId == null) {
          await _verifyRemoteObject(
            vaultId,
            objectId,
            initial.sha256,
            bytes.length,
          );
          return;
        }
        if (const {'UPLOAD_EXPIRED', 'OBJECT_COLLECTED'}.contains(error.code) &&
            expiredRetries < 2) {
          expiredRetries++;
          uploadId = null;
          chunkSize = null;
          nextChunkIndex = 0;
          await database.updateBlobUploadProgress(
            jobId: jobId,
            objectId: objectId,
            uploadId: null,
            chunkSize: null,
            nextChunkIndex: 0,
          );
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _verifyRemoteObject(
    String vaultId,
    String objectId,
    String expectedSha,
    int expectedSize,
  ) async {
    final downloaded = await api.downloadObjectWithDigest(vaultId, objectId);
    try {
      if (downloaded.bytes.length != expectedSize ||
          downloaded.sha256 != expectedSha ||
          await _digestHex(downloaded.bytes) != expectedSha) {
        throw FormatException(currentL10n.anAttachmentObjectAlreadyOnThe);
      }
    } finally {
      downloaded.bytes.fillRange(0, downloaded.bytes.length, 0);
    }
  }

  Future<Uint8List> _downloadCiphertextObject({
    required String jobId,
    required String vaultId,
    required String objectId,
    required int ciphertextSize,
    required String sha256,
  }) async {
    var row = await database.blobJobObject(jobId, objectId);
    if (row == null || row.size != ciphertextSize || row.sha256 != sha256) {
      throw StateError(
        'Attachment object is missing from its durable download task.',
      );
    }
    if (row.transferred) {
      final completed = row.bytes;
      if (completed == null ||
          completed.length != ciphertextSize ||
          await _digestHex(completed) != sha256) {
        throw FormatException(currentL10n.integrityVerificationOfAPersistedAttachment);
      }
      return Uint8List.fromList(completed);
    }

    var offset = row.bytes?.length ?? 0;
    while (offset < ciphertextSize) {
      final end = offset + _maxObjectTransportChunkBytes < ciphertextSize
          ? offset + _maxObjectTransportChunkBytes - 1
          : ciphertextSize - 1;
      final range = await api.downloadObjectRange(
        vaultId: vaultId,
        objectId: objectId,
        start: offset,
        end: end,
        expectedSize: ciphertextSize,
        expectedSha256: sha256,
      );
      try {
        await database.appendBlobDownloadRange(
          jobId: jobId,
          objectId: objectId,
          start: offset,
          bytes: range,
        );
      } finally {
        range.fillRange(0, range.length, 0);
      }
      row = (await database.blobJobObject(jobId, objectId))!;
      offset = row.bytes?.length ?? 0;
    }
    final complete = row!.bytes;
    if (complete == null ||
        complete.length != ciphertextSize ||
        await _digestHex(complete) != sha256) {
      await database.resetBlobDownloadObject(jobId, objectId);
      throw FormatException(currentL10n.theDownloadedAttachmentCiphertextDigestOr);
    }
    await database.markBlobObjectTransferred(jobId, objectId);
    return Uint8List.fromList(complete);
  }

  static String _jobId(
    String direction,
    String vaultId,
    String recordId,
    String blobId,
    String? instanceId,
    String? serverSpaceId,
  ) => instanceId == null
      ? '$direction:$vaultId:$recordId:$blobId'
      : '$direction:$instanceId:$serverSpaceId:$vaultId:$recordId:$blobId';

  static List<String> _manifestObjectIds(Map<String, Object?> manifest) {
    if (manifest['format'] == hostAttachmentV2Format) {
      final entry = HostAttachmentV2ManifestEntry.parse(manifest);
      try {
        return entry.objectIds;
      } finally {
        entry.clearSecrets();
      }
    }
    final entry = HostAttachmentManifestEntry.parse(manifest);
    try {
      return entry.objectIds;
    } finally {
      entry.clearKey();
      for (final chunk in entry.chunks) {
        chunk.clearNonce();
      }
    }
  }

  static _ParsedHostAttachment _parseAttachment(Object? value) {
    if (value is Map && value['format'] == hostAttachmentV2Format) {
      final parsed = HostAttachmentV2ManifestEntry.parse(value);
      return _ParsedHostAttachment.v2(parsed);
    }
    return _ParsedHostAttachment.v1(HostAttachmentManifestEntry.parse(value));
  }

  static bool _supportsAttachmentV2(
    Map<String, dynamic> device,
    int requestedBytes,
    bool Function(Map<String, dynamic> device) verify,
  ) {
    final report = device['capability_report'];
    final deviceId = device['device_id'];
    if (report is! Map || deviceId is! String) return false;
    final value = Map<String, dynamic>.from(report);
    final versions = value['host_attachment_manifest_versions'];
    try {
      if (!verify(device)) return false;
    } catch (_) {
      return false;
    }
    return value['device_id'] == deviceId &&
        value['account_id'] is String &&
        (value['account_id'] as String).isNotEmpty &&
        value['revision'] is int &&
        (value['revision'] as int) > 0 &&
        value['signature'] is String &&
        (value['signature'] as String).isNotEmpty &&
        value['max_record_schema'] is int &&
        (value['max_record_schema'] as int) >= 2 &&
        value['max_attachment_bytes'] is int &&
        (value['max_attachment_bytes'] as int) >= hostAttachmentV2MaxBytes &&
        (value['max_attachment_bytes'] as int) >= requestedBytes &&
        versions is List &&
        versions.every((item) => item is int && item > 0) &&
        versions.contains(2);
  }

  static void _validateHostManifestSize(Map<String, Object?> manifest) {
    if (utf8.encode(canonicalJson(manifest)).length > _maxHostManifestBytes) {
      throw FormatException(currentL10n.theHostAttachmentManifestExceedsThe);
    }
  }

  static String _safeErrorCode(Object error) => switch (error) {
    ApiException(:final code) => code,
    FormatException() => 'INTEGRITY_ERROR',
    _ => 'TRANSFER_FAILED',
  };

  static List<String> _validateObjectRefs(Object? value) {
    if (value is! List || value.length > _maxObjectRefs) {
      throw FormatException(currentL10n.hostObjectRefsMustBeAn);
    }
    final refs = <String>[];
    String? previous;
    for (final item in value) {
      if (item is! String ||
          !_canonicalUuid.hasMatch(item) ||
          (previous != null && previous.compareTo(item) >= 0)) {
        throw FormatException(
          currentL10n.hostObjectRefsMustBeUnique,
        );
      }
      refs.add(item);
      previous = item;
    }
    return refs;
  }
}

class _HostAttachmentManifest {
  _HostAttachmentManifest(this.entries, this.objectRefs);

  final List<_ParsedHostAttachment> entries;
  final List<String> objectRefs;

  void clearSecrets() {
    for (final item in entries) {
      item.clearSecrets();
    }
  }
}

class _ParsedHostAttachment {
  _ParsedHostAttachment.v1(HostAttachmentManifestEntry entry)
    : v1Entry = entry,
      v2Entry = null,
      manifestEntry = entry.raw;
  _ParsedHostAttachment.v2(HostAttachmentV2ManifestEntry entry)
    : v1Entry = null,
      v2Entry = entry,
      manifestEntry = entry.raw;

  final HostAttachmentManifestEntry? v1Entry;
  final HostAttachmentV2ManifestEntry? v2Entry;
  final Map<String, Object?> manifestEntry;

  String get blobId => v1Entry?.blobId ?? v2Entry!.blobId;
  String get fileName => v1Entry?.fileName ?? v2Entry!.fileName;
  String get mediaType => v1Entry?.mediaType ?? v2Entry!.mediaType;
  int get totalSize => v1Entry?.totalSize ?? v2Entry!.totalSize;
  int get formatVersion => v1Entry == null ? 2 : 1;
  Map<String, Object?> get raw => manifestEntry;
  List<String> get objectIds => v1Entry?.objectIds ?? v2Entry!.objectIds;
  List<HostAttachmentChunk> get chunks =>
      v1Entry?.chunks ?? const <HostAttachmentChunk>[];

  void clearSecrets() {
    final v1 = v1Entry;
    if (v1 != null) {
      v1.clearKey();
      for (final chunk in v1.chunks) {
        chunk.clearNonce();
      }
    }
    v2Entry?.clearSecrets();
  }
}
