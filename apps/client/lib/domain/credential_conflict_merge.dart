/// A field offered by the explicit password Credential conflict resolver.
enum CredentialConflictMergeField { name, username, secret }

/// Which verified value to retain for one Credential field.
///
/// `local` is the signed losing conflict branch. `remote` is the currently
/// committed record head reviewed when the merge preview was loaded.
enum CredentialConflictMergeBranch { local, remote }

enum CredentialConflictMergeStatus { staged, reviewRequired }

class CredentialConflictMergeFieldPreview {
  const CredentialConflictMergeFieldPreview({
    required this.localValue,
    required this.remoteValue,
  });

  final String localValue;
  final String remoteValue;

  bool get sameOnBothBranches => localValue == remoteValue;
}

/// Decrypted values for one verified, same-record password Credential pair.
/// Keep this object transient; callers should discard it when its review UI
/// closes. Other Credential kinds are intentionally not represented here.
class CredentialConflictMergePreview {
  const CredentialConflictMergePreview({
    required this.conflictId,
    required this.recordId,
    required this.branchRevisionId,
    required this.currentHeadRevisionId,
    required this.name,
    required this.username,
    required this.secret,
  });

  final String conflictId;
  final String recordId;
  final String branchRevisionId;
  final String currentHeadRevisionId;
  final CredentialConflictMergeFieldPreview name;
  final CredentialConflictMergeFieldPreview username;
  final CredentialConflictMergeFieldPreview secret;
}

class CredentialConflictMergeOutcome {
  const CredentialConflictMergeOutcome._({
    required this.status,
    this.resolutionRevisionId,
  });

  const CredentialConflictMergeOutcome.staged({required String revisionId})
    : this._(
        status: CredentialConflictMergeStatus.staged,
        resolutionRevisionId: revisionId,
      );

  const CredentialConflictMergeOutcome.reviewRequired()
    : this._(status: CredentialConflictMergeStatus.reviewRequired);

  final CredentialConflictMergeStatus status;
  final String? resolutionRevisionId;
}
