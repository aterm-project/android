import 'package:uuid/uuid.dart';

import '../crypto/jcs.dart';
import '../domain/ansible_inventory_metadata.dart';
import '../domain/models.dart';
import 'ansible_inventory_import.dart';
import '../l10n/l10n.dart';

const _uuid = Uuid();

enum AnsibleInventoryRefreshStatus {
  create,
  update,
  unchanged,
  missing,
  skipped,
  blocked,
}

class AnsibleInventoryRefreshField {
  const AnsibleInventoryRefreshField({
    required this.key,
    String? label,
    this.labelBuilder,
    required this.current,
    required this.incoming,
    required this.proposed,
    required this.conflict,
    required this.changed,
    // Preserve the public named parameter while keeping presentation lazy.
    // ignore: prefer_initializing_formals
  }) : assert(label != null || labelBuilder != null),
       _label = label;

  final String key;
  final String? _label;
  final String Function()? labelBuilder;

  String get label => labelBuilder?.call() ?? _label ?? '';
  final Object? current;
  final Object? incoming;
  final Object? proposed;
  final bool conflict;
  final bool changed;
}

class AnsibleInventoryRefreshRow {
  const AnsibleInventoryRefreshRow({
    required this.name,
    required this.status,
    this.existing,
    this.plannedHost,
    this.expectedRevisionId,
    String? note,
    this.noteBuilder,
    this.fields = const [],
    // Preserve the public named parameter while keeping presentation lazy.
    // ignore: prefer_initializing_formals
  }) : _note = note;

  final String name;
  final AnsibleInventoryRefreshStatus status;
  final HostRecord? existing;
  final HostRecord? plannedHost;
  final String? expectedRevisionId;
  final String? _note;
  final String? Function()? noteBuilder;

  String? get note => noteBuilder?.call() ?? _note;
  final List<AnsibleInventoryRefreshField> fields;

  bool get needsSave =>
      (status == AnsibleInventoryRefreshStatus.create ||
          status == AnsibleInventoryRefreshStatus.update ||
          status == AnsibleInventoryRefreshStatus.missing) &&
      plannedHost != null;

  bool get hasConflict => fields.any((field) => field.conflict);

  AnsibleInventoryRefreshRow resolveConflicts({
    Set<String> useInventoryFields = const {},
  }) {
    final planned = plannedHost;
    final currentHost = existing;
    if (currentHost == null || planned == null || !hasConflict) return this;
    final values = <String, Object?>{
      'name': planned.name,
      'address': planned.address,
      'port': planned.port,
      'username': planned.username,
    };
    for (final field in fields.where((item) => item.conflict)) {
      values[field.key] = useInventoryFields.contains(field.key)
          ? field.incoming
          : field.current;
    }
    final resolvedFields = fields
        .map((field) {
          if (!field.conflict) return field;
          final proposed = useInventoryFields.contains(field.key)
              ? field.incoming
              : field.current;
          return AnsibleInventoryRefreshField(
            key: field.key,
            labelBuilder: () => field.label,
            current: field.current,
            incoming: field.incoming,
            proposed: proposed,
            conflict: true,
            changed: !_sameValue(field.current, proposed),
          );
        })
        .toList(growable: false);
    final metadata = planned.ansibleInventoryImport;
    final resolved = currentHost
        .copyWith(
          name: values['name']! as String,
          address: values['address']! as String,
          port: values['port']! as int,
          username: values['username']! as String,
          tags: planned.tags,
        )
        .copyWithAnsibleInventoryImport(metadata);
    return AnsibleInventoryRefreshRow(
      name: name,
      status: _sameImportedHost(currentHost, resolved, metadata)
          ? AnsibleInventoryRefreshStatus.unchanged
          : AnsibleInventoryRefreshStatus.update,
      existing: currentHost,
      plannedHost: resolved,
      expectedRevisionId: expectedRevisionId,
      noteBuilder: () => note,
      fields: List.unmodifiable(resolvedFields),
    );
  }
}

class AnsibleInventoryRefreshPlan {
  const AnsibleInventoryRefreshPlan({
    required this.sourceId,
    required this.sourceLabel,
    required this.rows,
    required this.staleMarkingAllowed,
    String? staleMarkingReason,
    this.staleMarkingReasonBuilder,
    // Preserve the public named parameter while keeping presentation lazy.
    // ignore: prefer_initializing_formals
  }) : _staleMarkingReason = staleMarkingReason;

  final String sourceId;
  final String sourceLabel;
  final List<AnsibleInventoryRefreshRow> rows;
  final bool staleMarkingAllowed;
  final String? _staleMarkingReason;
  final String? Function()? staleMarkingReasonBuilder;

  String? get staleMarkingReason =>
      staleMarkingReasonBuilder?.call() ?? _staleMarkingReason;

  int get createCount => rows
      .where((row) => row.status == AnsibleInventoryRefreshStatus.create)
      .length;
  int get updateCount => rows
      .where((row) => row.status == AnsibleInventoryRefreshStatus.update)
      .length;
  int get unchangedCount => rows
      .where((row) => row.status == AnsibleInventoryRefreshStatus.unchanged)
      .length;
  int get staleCount => rows
      .where((row) => row.status == AnsibleInventoryRefreshStatus.missing)
      .length;
  int get blockedCount => rows
      .where((row) => row.status == AnsibleInventoryRefreshStatus.blocked)
      .length;

  List<AnsibleInventoryRefreshRow> get actionableRows =>
      rows.where((row) => row.needsSave).toList(growable: false);

  AnsibleInventoryRefreshPlan resolveConflicts({
    Map<String, Set<String>> useInventoryFieldsByHostId = const {},
  }) => AnsibleInventoryRefreshPlan(
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    rows: List.unmodifiable([
      for (final row in rows)
        row.resolveConflicts(
          useInventoryFields:
              useInventoryFieldsByHostId[row.existing?.id] ?? const {},
        ),
    ]),
    staleMarkingAllowed: staleMarkingAllowed,
    staleMarkingReasonBuilder: () => staleMarkingReason,
  );
}

/// Plans a safe, repeatable refresh for one explicitly selected inventory
/// source. Existing user edits are compared against the last accepted source
/// baseline, and unrelated Host fields are preserved. This function does not
/// write records or execute any inventory logic.
AnsibleInventoryRefreshPlan planAnsibleInventoryRefresh({
  required AnsibleInventoryParseResult parsed,
  required List<HostRecord> savedHosts,
  required String sourceId,
  required String sourceLabel,
  String Function()? createHostId,
}) {
  final sourceMetadata = <HostRecord, AnsibleInventoryImportMetadata>{};
  final entriesByKey = <String, List<HostRecord>>{};
  for (final host in savedHosts) {
    final metadata = host.ansibleInventoryImport;
    if (metadata == null || metadata.sourceId != sourceId) continue;
    sourceMetadata[host] = metadata;
    entriesByKey.putIfAbsent(metadata.entryKey, () => []).add(host);
  }

  final candidatesByKey = <String, List<AnsibleInventoryHost>>{};
  for (final candidate in parsed.hosts) {
    candidatesByKey.putIfAbsent(candidate.name, () => []).add(candidate);
  }
  final allCandidatesComplete =
      !parsed.blocksWholeFile &&
      parsed.hosts.isNotEmpty &&
      parsed.hosts.every(
        (candidate) =>
            candidate.canImport &&
            candidate.username != null &&
            candidate.username!.trim().isNotEmpty &&
            (candidatesByKey[candidate.name]?.length ?? 0) == 1,
      );
  final staleMarkingAllowed = allCandidatesComplete;
  String? staleMarkingReason() => staleMarkingAllowed
      ? null
      : parsed.blocksWholeFile
      ? currentL10n.inventoryBlockedSource
      : parsed.hosts.isEmpty
      ? currentL10n.inventoryEmptySource
      : currentL10n.inventoryPartialSource;

  final rows = <AnsibleInventoryRefreshRow>[];
  final matchedKeys = <String>{};
  final idFactory = createHostId ?? _uuid.v4;
  for (final candidate in parsed.hosts) {
    final sameKeyCandidates = candidatesByKey[candidate.name] ?? const [];
    if (parsed.blocksWholeFile || !candidate.canImport) {
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: AnsibleInventoryRefreshStatus.blocked,
          noteBuilder: () => candidate.issues.isEmpty
              ? currentL10n.inventoryBlockedPlan
              : currentL10n.inventoryBlockedEntry,
        ),
      );
      continue;
    }
    if (sameKeyCandidates.length != 1) {
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: AnsibleInventoryRefreshStatus.blocked,
          noteBuilder: () => currentL10n.inventoryDuplicateIdentity,
        ),
      );
      continue;
    }
    final username = candidate.username;
    if (username == null || username.trim().isEmpty) {
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: AnsibleInventoryRefreshStatus.skipped,
          noteBuilder: () => currentL10n.inventoryUsernameRequired,
        ),
      );
      continue;
    }

    final matchingHosts = entriesByKey[candidate.name] ?? const [];
    // A candidate with this exact source identity prevents an existing
    // ambiguous saved identity from being misclassified as absent.
    matchedKeys.add(candidate.name);
    if (matchingHosts.length > 1) {
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: AnsibleInventoryRefreshStatus.blocked,
          noteBuilder: () => currentL10n.inventoryMultipleSaved,
        ),
      );
      continue;
    }
    final incoming = AnsibleInventoryImportedValues(
      name: candidate.name,
      address: candidate.address,
      port: candidate.port,
      username: username,
      tags: candidate.groups,
    );
    if (matchingHosts.isEmpty) {
      final sameName = savedHosts.where(
        (host) => _normalize(host.name) == _normalize(candidate.name),
      );
      if (sameName.isNotEmpty) {
        rows.add(
          AnsibleInventoryRefreshRow(
            name: candidate.name,
            status: AnsibleInventoryRefreshStatus.skipped,
            existing: sameName.length == 1 ? sameName.single : null,
            noteBuilder: () => currentL10n.inventoryKeepOtherSource,
          ),
        );
        continue;
      }
      final metadata = AnsibleInventoryImportMetadata(
        sourceId: sourceId,
        sourceLabel: sourceLabel,
        entryKey: candidate.name,
        baseline: incoming,
      );
      final host = HostRecord(
        id: idFactory(),
        name: incoming.name,
        address: incoming.address,
        port: incoming.port,
        username: incoming.username,
        tags: incoming.tags,
      ).copyWithAnsibleInventoryImport(metadata);
      final validation = host.validate();
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: validation == null
              ? AnsibleInventoryRefreshStatus.create
              : AnsibleInventoryRefreshStatus.skipped,
          plannedHost: validation == null ? host : null,
          noteBuilder: host.validate,
        ),
      );
      continue;
    }

    final current = matchingHosts.single;
    matchedKeys.add(candidate.name);
    final oldMetadata = sourceMetadata[current]!;
    final expectedRevision = current.revisionId;
    if (expectedRevision == null || expectedRevision.isEmpty) {
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: AnsibleInventoryRefreshStatus.blocked,
          existing: current,
          noteBuilder: () => currentL10n.inventoryRevisionUnavailable,
        ),
      );
      continue;
    }
    final baseline = oldMetadata.baseline;
    final fields = <AnsibleInventoryRefreshField>[];
    final nextValues = <String, Object?>{};
    for (final field in [
      (key: 'name', label: () => currentL10n.displayName),
      (key: 'address', label: () => currentL10n.address),
      (key: 'port', label: () => currentL10n.port),
      (key: 'username', label: () => currentL10n.sshUsername),
    ]) {
      final baseValue = _valueFor(baseline, field.key);
      final currentValue = _valueForHost(current, field.key);
      final incomingValue = _valueFor(incoming, field.key);
      final userChanged = !_sameValue(currentValue, baseValue);
      final sourceChanged = !_sameValue(incomingValue, baseValue);
      final conflict =
          userChanged &&
          sourceChanged &&
          !_sameValue(currentValue, incomingValue);
      final proposed = conflict || (userChanged && !sourceChanged)
          ? currentValue
          : incomingValue;
      nextValues[field.key] = proposed;
      fields.add(
        AnsibleInventoryRefreshField(
          key: field.key,
          labelBuilder: field.label,
          current: currentValue,
          incoming: incomingValue,
          proposed: proposed,
          conflict: conflict,
          changed: !_sameValue(currentValue, proposed),
        ),
      );
    }

    final currentTags = _tagMap(current.tags);
    final baseTags = _tagMap(baseline.tags);
    final incomingTags = _tagMap(incoming.tags);
    final suppressed = _tagMap(oldMetadata.suppressedTags);
    final retained = _tagMap(oldMetadata.retainedTags);
    for (final tag in currentTags.values) {
      if (suppressed.containsKey(tag.toLowerCase())) {
        suppressed.remove(tag.toLowerCase());
        retained[tag.toLowerCase()] = tag;
      }
    }
    for (final entry in baseTags.entries) {
      if (!currentTags.containsKey(entry.key)) {
        suppressed[entry.key] = entry.value;
        retained.remove(entry.key);
      }
    }
    retained.removeWhere((key, _) => !currentTags.containsKey(key));
    for (final entry in currentTags.entries) {
      if (!baseTags.containsKey(entry.key)) retained[entry.key] = entry.value;
    }
    final nextTags = <String, String>{};
    for (final entry in incomingTags.entries) {
      if (!suppressed.containsKey(entry.key)) nextTags[entry.key] = entry.value;
    }
    nextTags.addAll(retained);
    final mergedTags = _sortedTags(nextTags.values);
    final currentTagsList = _sortedTags(current.tags);
    fields.add(
      AnsibleInventoryRefreshField(
        key: 'tags',
        labelBuilder: () => currentL10n.hostTags,
        current: currentTagsList,
        incoming: _sortedTags(incoming.tags),
        proposed: mergedTags,
        conflict: false,
        changed: !_sameTags(currentTagsList, mergedTags),
      ),
    );
    final nextMetadata = AnsibleInventoryImportMetadata(
      sourceId: oldMetadata.sourceId,
      sourceLabel: sourceLabel,
      entryKey: oldMetadata.entryKey,
      baseline: incoming,
      state: AnsibleInventoryEntryState.active,
      suppressedTags: _sortedTags(suppressed.values),
      retainedTags: _sortedTags(retained.values),
    );
    final plannedHost = current
        .copyWith(
          name: nextValues['name']! as String,
          address: nextValues['address']! as String,
          port: nextValues['port']! as int,
          username: nextValues['username']! as String,
          tags: mergedTags,
        )
        .copyWithAnsibleInventoryImport(nextMetadata);
    if (mergedTags.length > 128) {
      rows.add(
        AnsibleInventoryRefreshRow(
          name: candidate.name,
          status: AnsibleInventoryRefreshStatus.blocked,
          existing: current,
          expectedRevisionId: expectedRevision,
          fields: List.unmodifiable(fields),
          noteBuilder: () => currentL10n.inventoryTagLimit,
        ),
      );
      continue;
    }
    final metadataChanged =
        canonicalJson(oldMetadata.toJson()) !=
        canonicalJson(nextMetadata.toJson());
    final fieldChanged = fields.any((field) => field.changed);
    rows.add(
      AnsibleInventoryRefreshRow(
        name: candidate.name,
        status: fieldChanged || metadataChanged
            ? AnsibleInventoryRefreshStatus.update
            : AnsibleInventoryRefreshStatus.unchanged,
        existing: current,
        plannedHost: plannedHost,
        expectedRevisionId: expectedRevision,
        fields: List.unmodifiable(fields),
        noteBuilder: () => oldMetadata.state == AnsibleInventoryEntryState.stale
            ? currentL10n.inventoryRestoreActive
            : null,
      ),
    );
  }

  if (staleMarkingAllowed) {
    for (final host in sourceMetadata.keys) {
      final metadata = sourceMetadata[host]!;
      if (matchedKeys.contains(metadata.entryKey) ||
          metadata.state == AnsibleInventoryEntryState.stale) {
        continue;
      }
      final revision = host.revisionId;
      if (revision == null || revision.isEmpty) {
        rows.add(
          AnsibleInventoryRefreshRow(
            name: host.name,
            status: AnsibleInventoryRefreshStatus.blocked,
            existing: host,
            noteBuilder: () => currentL10n.inventoryMissingRevision,
          ),
        );
        continue;
      }
      final staleMetadata = metadata.copyWith(
        sourceLabel: sourceLabel,
        state: AnsibleInventoryEntryState.stale,
      );
      rows.add(
        AnsibleInventoryRefreshRow(
          name: host.name,
          status: AnsibleInventoryRefreshStatus.missing,
          existing: host,
          plannedHost: host.copyWithAnsibleInventoryImport(staleMetadata),
          expectedRevisionId: revision,
          noteBuilder: () => currentL10n.inventoryAbsentHost,
        ),
      );
    }
  }

  return AnsibleInventoryRefreshPlan(
    sourceId: sourceId,
    sourceLabel: sourceLabel,
    rows: List.unmodifiable(rows),
    staleMarkingAllowed: staleMarkingAllowed,
    staleMarkingReasonBuilder: () => staleMarkingReason(),
  );
}

Object? _valueFor(AnsibleInventoryImportedValues values, String key) =>
    switch (key) {
      'name' => values.name,
      'address' => values.address,
      'port' => values.port,
      'username' => values.username,
      _ => null,
    };

Object? _valueForHost(HostRecord host, String key) => switch (key) {
  'name' => host.name,
  'address' => host.address,
  'port' => host.port,
  'username' => host.username,
  _ => null,
};

bool _sameValue(Object? left, Object? right) =>
    canonicalJson(left) == canonicalJson(right);

bool _sameTags(List<String> left, List<String> right) =>
    _sameValue(_sortedTags(left), _sortedTags(right));

bool _sameImportedHost(
  HostRecord existing,
  HostRecord planned,
  AnsibleInventoryImportMetadata? metadata,
) =>
    existing.name == planned.name &&
    existing.address == planned.address &&
    existing.port == planned.port &&
    existing.username == planned.username &&
    _sameTags(existing.tags, planned.tags) &&
    canonicalJson(existing.ansibleInventoryImport?.toJson()) ==
        canonicalJson(metadata?.toJson());

String _normalize(String value) => value.trim().toLowerCase();

Map<String, String> _tagMap(List<String> tags) => {
  for (final tag in tags) tag.toLowerCase(): tag,
};

List<String> _sortedTags(Iterable<String> tags) {
  final unique = _tagMap(tags.toList());
  final values = unique.values.toList();
  values.sort((left, right) {
    final folded = left.toLowerCase().compareTo(right.toLowerCase());
    return folded == 0 ? left.compareTo(right) : folded;
  });
  return List.unmodifiable(values);
}
