import '../domain/models.dart';
import '../l10n/l10n.dart';

/// The saved rule list no longer matches what the user edited, confirmed or
/// deleted (changed by another edit, tab, device or sync). Nothing is written.
class SshPortForwardRuleConflict implements Exception {
  const SshPortForwardRuleConflict();

  @override
  String toString() => 'SshPortForwardRuleConflict';
}

/// Applies ONE rule change to the latest saved list, compare-and-set style:
/// * insert: [expected] null, [replacement] set; its id must not exist yet.
/// * replace: both set with the same id; the saved rule must equal [expected].
/// * delete: [expected] set, [replacement] null; the saved rule must equal
///   [expected].
/// Every other rule of the list is kept exactly as currently saved, so a
/// queued save never reverts an intervening change of another rule.
List<SshPortForwardProfile> applySshPortForwardRuleChange(
  List<SshPortForwardProfile> current, {
  SshPortForwardProfile? expected,
  SshPortForwardProfile? replacement,
}) {
  if (expected == null && replacement == null) {
    throw ArgumentError('A rule change needs an expected or new rule');
  }
  if (expected != null && replacement != null && expected.id != replacement.id) {
    throw ArgumentError('A replaced rule keeps its id');
  }
  final id = (expected ?? replacement)!.id;
  final index = current.indexWhere((rule) => rule.id == id);
  if (expected == null) {
    if (index >= 0) throw const SshPortForwardRuleConflict();
    if (current.length >= maxHostPortForwardProfiles) {
      throw StateError(
        currentL10n.aHostCanHaveAtMost(maxHostPortForwardProfiles),
      );
    }
    return List.unmodifiable([...current, replacement!]);
  }
  if (index < 0 || current[index] != expected) {
    throw const SshPortForwardRuleConflict();
  }
  final next = [...current];
  if (replacement == null) {
    next.removeAt(index);
  } else {
    next[index] = replacement;
  }
  return List.unmodifiable(next);
}
