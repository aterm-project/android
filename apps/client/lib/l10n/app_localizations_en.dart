// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get languageSystemDefault => 'System default';

  @override
  String get languageSettingTitle => 'Language';

  @override
  String get languageSettingDescription =>
      'Choose the display language for this device. System default follows your device language and uses English when it isn\'t supported.';

  @override
  String languageSettingSystemResolved(Object language) {
    return 'System default · currently $language';
  }

  @override
  String get languageSettingSaveFailed =>
      'The language changed for this session but couldn\'t be saved on this device.';

  @override
  String get languageSettingDevicePreference =>
      'Saved on this device only. Not synced and not stored in the Vault.';

  @override
  String tabSemanticsLabel(Object title, Object status, Object selection) {
    return '$title terminal tab, $status, $selection';
  }

  @override
  String get tabSemanticsConnected => 'connected';

  @override
  String get tabSemanticsDisconnected => 'disconnected';

  @override
  String get tabSemanticsActive => 'active';

  @override
  String get tabSemanticsInactive => 'inactive';

  @override
  String mfaChallengeTotp(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return 'Enter a six-digit code from your authenticator app to continue. This challenge expires $expiresAtString.';
  }

  @override
  String mfaChallengeRecovery(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return 'Enter a one-time recovery code to continue. This challenge expires $expiresAtString.';
  }

  @override
  String get propertyAuthentication => 'Authentication';

  @override
  String get propertyStatus => 'Status';

  @override
  String get propertyRoute => 'Route';

  @override
  String get propertyTags => 'Tags';

  @override
  String keyEpochLocalMismatch(int epoch) {
    return 'Key epoch $epoch maps to different local keys on this device.';
  }

  @override
  String get recoveryCodeCopiedFeedback => 'Recovery code copied.';

  @override
  String get recoveryCodeCopyFailedFeedback =>
      'Could not copy the recovery code. Select and copy it manually.';

  @override
  String sessionsRevokedForSelectedAccount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sessions revoked',
      one: '1 session revoked',
    );
    return '$_temp0 for the selected account.';
  }

  @override
  String get usernameOptional => 'Username (optional)';

  @override
  String get forwardRuntimeUnsupported =>
      'SSH port forwarding cannot run on this platform.';

  @override
  String get forwardRuntimeDisconnected =>
      'Not connected. You can edit profiles now; connect this Host over SSH to start them.';

  @override
  String get forwardRuntimeRunningNote =>
      'Running forwards stay on this device and stop automatically when this SSH connection ends.';

  @override
  String forwardStatusRunning(int active, int total) {
    return 'Running · $active active · $total total';
  }

  @override
  String get forwardStatusStopping => 'Stopping…';

  @override
  String get forwardStatusStopped => 'Stopped';

  @override
  String forwardStatusFailed(Object error) {
    return 'Failed: $error';
  }

  @override
  String get forwardStatusUnknownError => 'unknown error';

  @override
  String forwardExposureLocal(Object bind, Object destination) {
    return 'Other devices on your networks that can reach $bind will be able to connect to $destination through your SSH login.';
  }

  @override
  String forwardExposureDynamic(Object bind) {
    return 'Other devices that can reach $bind will be able to use an unauthenticated SOCKS proxy through your SSH login.';
  }

  @override
  String forwardExposureRemoteLoopback(Object destination) {
    return 'Connections arriving at the SSH server will be relayed by this device to $destination.';
  }

  @override
  String forwardExposureRemotePublic(Object destination) {
    return 'Connections arriving at the SSH server will be relayed by this device to $destination, and the server may accept them from other machines.';
  }

  @override
  String forwardRemoteListenerRejected(Object endpoint) {
    return 'The SSH server rejected a listener on $endpoint. The port may be in use on the server, or AllowTcpForwarding/PermitListen may forbid it.';
  }

  @override
  String forwardLocalDestinationUnreachable(Object endpoint) {
    return 'This device could not connect to $endpoint.';
  }

  @override
  String get keybarMore => 'More';

  @override
  String get keybarLess => 'Less';

  @override
  String get invalidAttachedFileOwner => 'Invalid attached file owner.';

  @override
  String get unexpectedWindowCombinationOwnerField => 'Unexpected owner field.';

  @override
  String get fileSessionSshOwnerMissingFromWindowSet =>
      'The file session\'s SSH owner isn\'t included in the window set.';

  @override
  String get terminalStateConnected => 'connected';

  @override
  String get terminalStateConnecting => 'connecting';

  @override
  String get terminalStateReconnecting => 'reconnecting';

  @override
  String get terminalStateDisconnected => 'disconnected';

  @override
  String get terminalStateClosed => 'closed';

  @override
  String get terminalStateEnded => 'ended';

  @override
  String get terminalStateFailed => 'failed';

  @override
  String get sshPasswordLabel => 'SSH password';

  @override
  String get passwordOptionalLabel => 'Password (optional)';

  @override
  String quotedHostName(Object name) {
    return 'Host “$name”';
  }

  @override
  String hostsReferenceUnavailableGroups(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Hosts reference',
      one: '1 Host references',
    );
    return '$_temp0 unavailable Groups. Edit affected Hosts to choose a current Group or explicitly choose No group.';
  }

  @override
  String pendingCountShort(int count) {
    return '$count pending';
  }

  @override
  String get purgeConsentEnabled => 'Enabled';

  @override
  String get purgeConsentOff => 'Off';

  @override
  String get restoreDeadlineStatusUnavailable =>
      'Restore deadline status: Unavailable';

  @override
  String get restoreDeadlineStatusPassed =>
      'Restore deadline status: Passed according to this device clock; the server makes the final decision';

  @override
  String restoreDeadlineStatusFuture(DateTime deadline) {
    final intl.DateFormat deadlineDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String deadlineString = deadlineDateFormat.format(deadline);

    return 'Restore deadline status: Future, $deadlineString';
  }

  @override
  String get groupParentNeedsRepair => 'Parent relationship needs repair';

  @override
  String groupInsideParent(Object parent) {
    return 'Inside $parent';
  }

  @override
  String groupHostCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hosts',
      one: '1 host',
    );
    return '$_temp0';
  }

  @override
  String groupSubgroupCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count subgroups',
      one: '1 subgroup',
    );
    return '$_temp0';
  }

  @override
  String get groupDefaultCredentialUnavailable =>
      'Default credential unavailable';

  @override
  String groupDefaultCredentialName(Object name) {
    return 'Default credential: $name';
  }

  @override
  String get credentialPasswordStoredEncrypted => 'Password stored encrypted';

  @override
  String get credentialPrivateKeyStoredEncrypted =>
      'Private key stored encrypted';

  @override
  String get splitAxisSideBySide => 'Side by side';

  @override
  String get splitAxisStacked => 'Stacked';

  @override
  String get execCancelledUnknown =>
      'Canceled. Remote completion status is unknown; the command was not retried.';

  @override
  String get execOpenTimedOut =>
      'Timed out waiting for the SSH exec request. Disconnect and reconnect before retrying; remote completion is unknown.';

  @override
  String get execTimedOutUnknown =>
      'Timed out. Remote completion status is unknown; the command was not retried.';

  @override
  String get execOutputTruncated =>
      'Output exceeded the 64 KiB limit. The exec channel was closed; completion status is unknown.';

  @override
  String get execBashUnavailable =>
      'Bash is unavailable on this target, or its login shell is not POSIX-compatible. No snippet payload was executed.';

  @override
  String unableToReviewHostConnectionSettings(Object error) {
    return 'Unable to review Host connection settings: $error';
  }

  @override
  String get adminJobBackupCompleted => 'Encrypted backup completed on server';

  @override
  String get adminJobBackupFailed =>
      'Encrypted backup failed; check server backup configuration';

  @override
  String get adminJobBackupInterrupted => 'Encrypted backup job interrupted';

  @override
  String get adminJobRestorePrepared =>
      'Isolated restore copy prepared; it is not activated';

  @override
  String get adminJobRestoreFailed =>
      'Isolated restore copy preparation failed; live data is unchanged';

  @override
  String get adminJobRestorePreparedStatusInterrupted =>
      'Restore copy prepared; job status update was interrupted';

  @override
  String get adminJobRestoreInterrupted =>
      'Isolated restore copy preparation interrupted';

  @override
  String get adminJobMaintenanceFailed =>
      'Maintenance failed; check server health before retrying';

  @override
  String get adminJobMaintenanceInterrupted =>
      'Maintenance was interrupted; refresh the job list before retrying';

  @override
  String adminJobResultCode(Object code) {
    return 'Result $code';
  }

  @override
  String get masterPasswordChangedSessionsRevoked =>
      'Master password changed. Other sessions were revoked.';

  @override
  String get masterPasswordChangeConfirmedSessionsRevoked =>
      'Master password change confirmed. Other sessions were revoked.';

  @override
  String confirmRemoveMemberAndRotate(Object username) {
    return 'Remove $username and rotate the Vault key for every remaining active member device? The removed account receives no new key. Existing old copies cannot be erased remotely. Other pending invitation tokens become invalid and must be reissued.';
  }

  @override
  String confirmCancelInvitationAndRotate(Object username) {
    return 'Cancel the pending invitation for $username and rotate the Vault key for every remaining active member device? The removed account receives no new key. Existing old copies cannot be erased remotely. Other pending invitation tokens become invalid and must be reissued.';
  }

  @override
  String recycleBinPurgeConsentLine(Object consent) {
    return '$consent.';
  }

  @override
  String recycleBinPurgeConsentLineOwner(Object consent) {
    return '$consent. Consent applies to this exact tombstone. When enabled, bounded Maintenance may purge it after its restore deadline and other required checks. Enabling consent does not purge it immediately; offline device copies and exports are not removed.';
  }

  @override
  String get objectDownloadFailed => 'Object download failed.';

  @override
  String get objectRangeDownloadFailed => 'Object range download failed.';

  @override
  String get requestFailed => 'Request failed.';

  @override
  String get theServerReturnedAnInvalidResponse =>
      'The server returned an invalid response.';

  @override
  String consoleExitedCode(int code) {
    return '\n[Console exited: $code]\n';
  }

  @override
  String get thisDevicesSecureStorageCouldntDelete =>
      ' This device\'s secure storage couldn\'t delete the old refresh token; the token has been revoked on the server.';

  @override
  String get someLocalStateCleanupHitAn =>
      ' Some local state cleanup hit an error; the app forced the current session to sign out.';

  @override
  String get aVaultRecoveryContextHasNo =>
      'A Vault recovery context has no valid signed membership version.';

  @override
  String get aCommandSnippetIsAlreadyRunning =>
      'A command snippet is already running.';

  @override
  String get aDisabledRecoveryAccountReturnedActive =>
      'A disabled Recovery account returned active recovery material.';

  @override
  String get aNewRecoveryKeyboxFailedIts =>
      'A new Recovery keybox failed its local check.';

  @override
  String get aNewDeviceKeyEnvelopeFailed =>
      'A new device key envelope failed its local check.';

  @override
  String get aPreviousSshExecRequestIs =>
      'A previous SSH exec request is still pending. Disconnect and reconnect before running another command.';

  @override
  String get aRecoveryConfirmationIsAlreadyPending =>
      'A recovery confirmation is already pending.';

  @override
  String get aReferencedSnippetCredentialChangedAfter =>
      'A referenced Snippet Credential changed after review. Review the full batch again.';

  @override
  String get aRequiredVaultKeyCouldNot =>
      'A required Vault key could not be recovered. Check recovery status and try an enrolled device.';

  @override
  String get aSelectedHostConnectionOrSnippet =>
      'A selected Host, connection, or Snippet changed after review. Review the full batch again.';

  @override
  String get accountRecoveredSignInWithThe2 =>
      'Account recovered. Sign in with the new master password on this device.';

  @override
  String get accountRecoveryIsBusy => 'Account recovery is busy.';

  @override
  String get accountRelayPolicyResetToInherit =>
      'Account relay policy reset to inherit.';

  @override
  String get accountRelayPolicySaved => 'Account relay policy saved.';

  @override
  String accountStatusUpdatedToStatusRevokedsessions(
    String status,
    int revokedSessions,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      revokedSessions,
      locale: localeName,
      other: '$revokedSessions sessions',
      one: '1 session',
    );
    return 'Account status updated to $status; $_temp0 revoked.';
  }

  @override
  String get anExistingRecoveryKeyboxCouldNot =>
      'An existing Recovery keybox could not be verified or opened; refusing to rotate away the only recovery copy.';

  @override
  String get bashExecutionRequiresACancellationHandle =>
      'Bash execution requires a cancellation handle.';

  @override
  String get batchExecutionIsOnlySupportedFor =>
      'Batch execution is only supported for structured Bash snippets.';

  @override
  String get batchTargetsMustBeDistinctConnected =>
      'Batch targets must be distinct connected Hosts.';

  @override
  String get bucketAccessVerifiedWithHeadbucketThis =>
      'Bucket access verified with HeadBucket. This check does not verify uploads, multipart operations, restore, or provider-wide interoperability.';

  @override
  String chooseBetweenTwoAndMaxterminaltabsConnected(int maxTerminalTabs) {
    return 'Choose between two and $maxTerminalTabs connected Hosts.';
  }

  @override
  String get commandExecutionIsUnavailableNoCommand =>
      'Command execution is unavailable. No command was sent.';

  @override
  String get conflictingSignedRecoveryKeyboxesExistFor =>
      'Conflicting signed Recovery keyboxes exist for a Vault epoch.';

  @override
  String get connectThisTerminalBeforeEnablingShell =>
      'Connect this terminal before enabling shell integration.';

  @override
  String get connectToTheServerBeforeChecking =>
      'Connect to the server before checking backup bucket access.';

  @override
  String get theConsoleOutputStreamClosed =>
      'The console output stream closed.';

  @override
  String get couldNotDisableBackgroundSyncNotifications =>
      'Could not disable background sync notifications.';

  @override
  String get couldNotEnableBackgroundSyncNotifications =>
      'Could not enable background sync notifications.';

  @override
  String get couldNotPersistTheMobilePush =>
      'Could not persist the mobile push opt-out.';

  @override
  String get couldNotRemoveThisDevicesPush =>
      'Could not remove this device’s push endpoint.';

  @override
  String credentialReferenceNameIsMissingOr(String name) {
    return 'Credential reference $name is missing or is not a password Credential';
  }

  @override
  String get currentAccountSessionExpired => 'Current account session expired.';

  @override
  String get enterTheAccountName => 'Enter the account name.';

  @override
  String get groupRelayPolicyResetToInherit =>
      'Group Relay policy reset to inherit.';

  @override
  String get groupRelayPolicySaved => 'Group Relay policy saved.';

  @override
  String get groupDefault => 'Group default';

  @override
  String get groupDefaultIsUnavailableChooseA =>
      'Group default is unavailable. Choose a Host override or repair the Group default.';

  @override
  String get groupMembershipSaved => 'Group membership saved.';

  @override
  String get hostChangedRepeatedlyWhileSavingReopen =>
      'Host changed repeatedly while saving; reopen and retry.';

  @override
  String get hostIdentityChangedWhileTheEditor =>
      'Host identity changed while the editor was open.';

  @override
  String get hostOverrideIsUnavailableChooseInherit =>
      'Host override is unavailable. Choose Inherit from Group or another credential.';

  @override
  String hostOverrideIdentity(String identity) {
    return 'Host override: $identity';
  }

  @override
  String get theHostsTagsFieldWasAlso =>
      'The Host\'s \"Tags\" field was also changed during editing. Reopen and review it, then try again.';

  @override
  String theHostsLabelFieldWasAlso(String label) {
    return 'The Host\'s \"$label\" field was also changed during editing. Reopen and review it, then try again.';
  }

  @override
  String inheritedFromValuevalueIdentity(String valueValue, String identity) {
    return 'Inherited from $valueValue: $identity';
  }

  @override
  String get instanceAdminAccessIsRequiredTo =>
      'Instance admin access is required to check backup bucket access.';

  @override
  String get invalidAdminVaultPaginationResponse =>
      'Invalid admin Vault pagination response.';

  @override
  String get invalidAdminAccountInvitationPaginationResponse =>
      'Invalid admin account invitation pagination response.';

  @override
  String get invalidAdminAccountPaginationResponse =>
      'Invalid admin account pagination response.';

  @override
  String get invalidAdminAccountSessionsPaginationResponse =>
      'Invalid admin account sessions pagination response.';

  @override
  String get invalidAdminMaintenancePaginationResponse =>
      'Invalid admin maintenance pagination response.';

  @override
  String get invalidMobilePushToken => 'Invalid mobile push token.';

  @override
  String get invalidRestoreJobReceipt => 'Invalid restore job receipt.';

  @override
  String get invalidRestoreSourcePageResponse =>
      'Invalid restore source page response.';

  @override
  String invitationCreatedForUsername(String username) {
    return 'Invitation created for $username.';
  }

  @override
  String get invitationRevoked => 'Invitation revoked.';

  @override
  String jumpHostCredentialForHostnameChanged(String hostName) {
    return 'Jump Host Credential for $hostName changed before dispatch. The remaining batch was stopped.';
  }

  @override
  String jumpHostRoutingForHostnameChanged(String hostName) {
    return 'Jump Host routing for $hostName changed before dispatch. Review the batch again.';
  }

  @override
  String couldntResolveTheSshCredentialFor(
    String name,
    String connectionError,
  ) {
    return 'Couldn\'t resolve the SSH credential for Jump Host $name: $connectionError';
  }

  @override
  String get theJumpHostMustUseThe =>
      'The Jump Host must use the SSH protocol.';

  @override
  String get theJumpHostRouteChangedWhile =>
      'The Jump Host route changed while preparing the connection. Reconnect.';

  @override
  String get theJumpHostRouteOrCredential =>
      'The Jump Host route or credential changed while preparing the connection. Reconnect.';

  @override
  String get theJumpHostChainCantForm =>
      'The Jump Host chain can\'t form a cycle.';

  @override
  String get theJumpHostChainContainsA =>
      'The Jump Host chain contains a host that no longer exists; edit and repair this reference.';

  @override
  String theJumpHostChainSupportsUp(int maxJumpHostHops) {
    return 'The Jump Host chain supports up to $maxJumpHostHops hops.';
  }

  @override
  String get loadAConsistentAccountAndInstance =>
      'Load a consistent account and instance policy before resetting.';

  @override
  String get loadAConsistentAccountAndInstance2 =>
      'Load a consistent account and instance policy before saving.';

  @override
  String get loadTheLatestSshRelayPolicy =>
      'Load the latest SSH relay policy before saving.';

  @override
  String get theMfaSignInResponseDoesnt =>
      'The MFA sign-in response doesn\'t match the current account or device.';

  @override
  String get mfaSettingsAreBeingProcessed =>
      'MFA settings are being processed.';

  @override
  String get mfaVerificationFailedTheCodeIs =>
      'MFA verification failed: the code is invalid or already used, or the sign-in challenge expired. Sign in again and enter a new code.';

  @override
  String get mfaVerifiedAndUnlockedLocallyThe =>
      'MFA verified and unlocked locally; the server still stores only encrypted records and key envelopes.';

  @override
  String get mustBeBetween0And1000000 => 'Must be between 0 and 1000000.';

  @override
  String get mustNotBeNegative => 'Must not be negative.';

  @override
  String get noS3BackupBucketIsConfigured =>
      'No S3 backup bucket is configured on the server.';

  @override
  String get noSshCredentialIsConfiguredChoose =>
      'No SSH credential is configured. Choose a Host override or set a Group default.';

  @override
  String get noAccountRecoveryIsAwaitingConfirmation =>
      'No account recovery is awaiting confirmation.';

  @override
  String get noAuthenticatedSession => 'No authenticated session.';

  @override
  String get noEffectiveSshCredentialIsSet =>
      'No effective SSH credential is set. Choose a Host override or set a Group default.';

  @override
  String get notStartedBecauseBatchCancellationWas =>
      'Not started because batch cancellation was requested during preflight.';

  @override
  String get notStartedBecauseBatchCancellationWas2 =>
      'Not started because batch cancellation was requested.';

  @override
  String get notStartedBecauseThePreviousHost =>
      'Not started because the previous Host did not complete successfully.';

  @override
  String get notStartedBecauseThePreviousHost2 =>
      'Not started because the previous Host failed validation or execution.';

  @override
  String get offlineKnownhostApprovalIsLimitedTo =>
      'Offline KnownHost approval is limited to a first-seen endpoint with no local trust or revocation history.';

  @override
  String get offlineKnownhostQueueDidNotMatch =>
      'Offline KnownHost queue did not match the explicitly reviewed SSH key.';

  @override
  String get prometheusScrapeCredentialRevoked =>
      'Prometheus scrape credential revoked.';

  @override
  String get rdpCertificate => 'RDP certificate';

  @override
  String get recoveryCouldNotBeStartedCheck =>
      'Recovery could not be started. Check the account name and code.';

  @override
  String get recoveryDescriptorHashIsInvalid =>
      'Recovery descriptor hash is invalid.';

  @override
  String get recoveryDescriptorPublicKeysDoNot =>
      'Recovery descriptor public keys do not match the wrapped identity.';

  @override
  String get recoveryIdentityEnvelopeIsMissing =>
      'Recovery identity envelope is missing.';

  @override
  String get referencedCredentialChangedAfterPreviewReview =>
      'Referenced Credential changed after preview. Review the command and try again.';

  @override
  String get reloadTheLatestAccountAndInstance =>
      'Reload the latest account and instance policies before resetting.';

  @override
  String get reloadTheLatestAccountAndInstance2 =>
      'Reload the latest account and instance policies before saving.';

  @override
  String get reloadTheLatestGroupAndInstance =>
      'Reload the latest group and instance policies before resetting.';

  @override
  String get reloadTheLatestGroupAndInstance2 =>
      'Reload the latest group and instance policies before saving.';

  @override
  String get reloadTheLatestPolicyAfterThe =>
      'Reload the latest policy after the revision conflict before retrying.';

  @override
  String get restoreIsEncryptedAndQueuedOn =>
      'Restore is encrypted and queued on this device; sync status will retry.';

  @override
  String get restoreIsEncryptedLocallyAndWaiting =>
      'Restore is encrypted locally and waiting to sync.';

  @override
  String get restoreIsSafelyQueuedOnThis =>
      'Restore is safely queued on this device and will retry when the server is reachable.';

  @override
  String get restoreStageResponseDidNotMatch =>
      'Restore stage response did not match.';

  @override
  String get retryThePendingAccountRecoveryCompletion =>
      'Retry the pending account recovery completion before signing in.';

  @override
  String get theSftpDocumentBelongsToA =>
      'The SFTP document belongs to a different SSH session.';

  @override
  String get theSftpServerVersionDoesntSupport =>
      'The SFTP server version doesn\'t support safe file uploads.';

  @override
  String get theSftpServerVersionIsBelow =>
      'The SFTP server version is below 3 and doesn\'t support safe text editing.';

  @override
  String sshCredentialForHostnameChangedBefore(String hostName) {
    return 'SSH Credential for $hostName changed before dispatch. The remaining batch was stopped.';
  }

  @override
  String get sshConnectionOrHostChangedAfter =>
      'SSH connection or Host changed after preview. Review the target and try again.';

  @override
  String get sshExecFailedAfterDispatchRemote =>
      'SSH exec failed after dispatch. Remote completion status is unknown; the command was not retried.';

  @override
  String get sshHostKeyApprovalProofAccount =>
      'SSH host-key approval proof account or Vault scope changed.';

  @override
  String get sshHostKeyTestDecisionBecame =>
      'SSH host-key test decision became stale.';

  @override
  String sshHostKeyTrustChangedFor(String hostName) {
    return 'SSH host-key trust changed for $hostName. Reconnect and review the batch again.';
  }

  @override
  String sshHostKeyVerificationEvidenceIs(String hostName) {
    return 'SSH host-key verification evidence is missing for $hostName. Reconnect before running a batch.';
  }

  @override
  String get sshRelayPolicySaved => 'SSH relay policy saved.';

  @override
  String get sshHostKeyTrustWasConfirmed =>
      'SSH host key trust was confirmed by sync in the current Vault.';

  @override
  String get sshHostKeyTrustWasRevoked =>
      'SSH host key trust was revoked and saved encrypted to the current Vault.';

  @override
  String get theSshHostKeyApprovalWas =>
      'The SSH host key approval was queued encrypted; the current connection stopped. Connect after the Vault sync confirms it.';

  @override
  String get theSshHostOrJumpHost =>
      'The SSH host or Jump Host route changed. Reconnect and try again.';

  @override
  String get theSshHostSettingsChangedReconnect =>
      'The SSH host settings changed; reconnect the current workspace pane.';

  @override
  String get sshSessionClosed => 'SSH session closed';

  @override
  String get sshCredentials2 => 'SSH credentials';

  @override
  String get theSshCredentialWasSavedEncrypted =>
      'The SSH credential was saved encrypted and added to the local sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get sshCredentialSavedEncryptedPlaintextIs =>
      'SSH credential saved encrypted; plaintext is kept only in the unlocked session.';

  @override
  String get theSshCredentialChangedReconnectThe =>
      'The SSH credential changed; reconnect the current workspace pane.';

  @override
  String get theSshCredentialOrHostSettings =>
      'The SSH credential or host settings changed; reconnect the current workspace pane.';

  @override
  String get sshStoppedTheFirstHostKey =>
      'SSH stopped: the first host key approval was queued encrypted. Reconnect after the Vault sync confirms it.';

  @override
  String sshConnectedToEndpoint(String endpoint) {
    return 'SSH connected to $endpoint.';
  }

  @override
  String get sshSignInDetails => 'SSH sign-in details';

  @override
  String get theSshTerminalIsClosedSo =>
      'The SSH terminal is closed, so input control can\'t be granted.';

  @override
  String get theSshConnectionClosedReconnectThe =>
      'The SSH connection closed; reconnect the current workspace pane.';

  @override
  String get selectAVaultBeforeResolvingThis =>
      'Select a Vault before resolving this Credential.';

  @override
  String get selectAVaultBeforeResolvingThis2 =>
      'Select a Vault before resolving this Host.';

  @override
  String get selectAnActiveMemberOfThis =>
      'Select an active member of this server-managed group.';

  @override
  String get selectedSessionRevoked => 'Selected session revoked.';

  @override
  String get selectedSessionWasAlreadyRevoked =>
      'Selected session was already revoked.';

  @override
  String get serverActivationWasSuperseded =>
      'Server activation was superseded.';

  @override
  String get serverCommittedTheRotationButThe =>
      'Server committed the rotation but the new local key state failed verification.';

  @override
  String get serverStateAdvancedUnexpectedlyDuringRotation =>
      'Server state advanced unexpectedly during rotation recovery.';

  @override
  String get signOutBeforeStartingFullAccount =>
      'Sign out before starting full account recovery.';

  @override
  String get snippetArgumentsChangedAfterPreviewReview =>
      'Snippet arguments changed after preview. Review them and try again.';

  @override
  String get snippetArgumentsChangedAfterReviewReview =>
      'Snippet arguments changed after review. Review the full batch again.';

  @override
  String get snippetDefinitionChangedAfterPreviewReview =>
      'Snippet definition changed after preview. Review it and try again.';

  @override
  String get snippetScriptIsEmpty => 'Snippet script is empty';

  @override
  String get splitWorkspacesRequireExactlyTwoHosts =>
      'Split workspaces require exactly two Hosts.';

  @override
  String get storedNextRecoveryPackageIsInvalid =>
      'Stored next Recovery package is invalid.';

  @override
  String get storedRecoveryChallengeIsInvalid =>
      'Stored recovery challenge is invalid.';

  @override
  String get storedRecoveryDeviceKeyIsInvalid =>
      'Stored recovery device key is invalid.';

  @override
  String get storedRecoveryDeviceProofIsInvalid =>
      'Stored recovery device proof is invalid.';

  @override
  String get storedRecoveryRequestDoesNotMatch =>
      'Stored recovery request does not match this server instance.';

  @override
  String get theGroupInheritanceChainIsUnavailable =>
      'The Group inheritance chain is unavailable. Choose a valid Group or a Host override.';

  @override
  String get theHostGroupInheritanceChainIs =>
      'The Host Group inheritance chain is unavailable. Choose a valid Group or a Host credential override.';

  @override
  String get theHostDidNotReturnA =>
      'The Host did not return a Bash execution result.';

  @override
  String get theSshExecRequestFailedAfter =>
      'The SSH exec request failed after dispatch.';

  @override
  String get theAccountNowInheritsTheInstance =>
      'The account now inherits the instance relay policy.';

  @override
  String get theEffectiveSshCredentialIsUnavailable =>
      'The effective SSH credential is unavailable. Choose a valid Host override or repair the Group default.';

  @override
  String get theEnabledRecoveryIdentityHasAn =>
      'The enabled Recovery identity has an invalid generation.';

  @override
  String get theEncryptedSshHostKeyApproval =>
      'The encrypted SSH host-key approval was not durably queued.';

  @override
  String get theExistingRecoveryDescriptorDoesNot =>
      'The existing Recovery descriptor does not match its wrapped identity.';

  @override
  String get theGroupNowInheritsTheInstance =>
      'The group now inherits the instance Relay policy.';

  @override
  String get theInstanceRelayPolicyChangedWhile =>
      'The instance Relay policy changed while this group was loading. Reload to get a consistent snapshot.';

  @override
  String get theInstanceRelayPolicyChangedReload =>
      'The instance Relay policy changed. Reload this group before reviewing effective access.';

  @override
  String get theInstancePolicyChangedWhileResetting =>
      'The instance policy changed while resetting. Reload the latest policies; your draft is preserved.';

  @override
  String get theInstancePolicyChangedWhileSaving =>
      'The instance policy changed while saving. Reload the latest policies; your draft is preserved.';

  @override
  String get theInstanceRelayPolicyChangedWhile2 =>
      'The instance relay policy changed while this account policy was loading. Reload to get a consistent snapshot.';

  @override
  String get theMergedHostRecordIsInvalid =>
      'The merged Host record is invalid.';

  @override
  String get theNewMasterPasswordMustContain =>
      'The new master password must contain at least 12 characters.';

  @override
  String get theNewMasterPasswordsDoNot =>
      'The new master passwords do not match.';

  @override
  String get theRecoveryChallengeExpiredStartAgain =>
      'The recovery challenge expired. Start again.';

  @override
  String get theRecoveryCodeOrServerDescriptor =>
      'The recovery code or server descriptor is invalid.';

  @override
  String get theRecoveryCompletionReceiptIsInvalid =>
      'The recovery completion receipt is invalid.';

  @override
  String get theRecoveryResponseDidNotMatch =>
      'The recovery response did not match this account.';

  @override
  String get theRelayPolicyChangedElsewhereReload =>
      'The relay policy changed elsewhere. Reload the latest settings before retrying.';

  @override
  String theReviewedSshSessionForHostname(String hostName) {
    return 'The reviewed SSH session for $hostName changed before dispatch.';
  }

  @override
  String get theServerCouldNotVerifyAccess =>
      'The server could not verify access to the configured S3 backup bucket.';

  @override
  String get theServerDeploymentDoesNotCurrently =>
      'The server deployment does not currently allow this relay setting. Your edits are still here; review the deployment limits and retry.';

  @override
  String get theServerOrAuthenticationStateChanged =>
      'The server or authentication state changed during recovery. Start again.';

  @override
  String get theServerRestorePeriodHasNot =>
      'The server restore period has not ended.';

  @override
  String get thisSnippetReferencesACredentialThat =>
      'This Snippet references a Credential that is not currently available. Restore that Credential first.';

  @override
  String get thisCommandPreviewHasAlreadyBeen =>
      'This command preview has already been confirmed.';

  @override
  String get thisRecordTypeCannotBeRestored =>
      'This record type cannot be restored by this client version.';

  @override
  String get thisRecoveryCodeBelongsToAnother =>
      'This recovery code belongs to another server instance.';

  @override
  String get thisWorkspaceReferencesAHostThat =>
      'This workspace references a Host that is not currently available. Restore the Host first.';

  @override
  String get tooManySshHostKeyChecks =>
      'Too many SSH host-key checks were requested for this route.';

  @override
  String get unableToLoadTheSshRelay =>
      'Unable to load the SSH relay policy. Check your connection and retry.';

  @override
  String get unableToSaveTheSshRelay =>
      'Unable to save the SSH relay policy. Check your connection and retry.';

  @override
  String get vaultChangedWhileSshHostKey =>
      'Vault changed while SSH host-key approval was reviewed.';

  @override
  String get vaultChangedWhileSshHostKey2 =>
      'Vault changed while SSH host-key approval was saved.';

  @override
  String get vaultChangedWhileSshHostKey3 =>
      'Vault changed while SSH host-key approval was syncing.';

  @override
  String get vaultChangedWhileSshHostKey4 =>
      'Vault changed while SSH host-key revocation was saved.';

  @override
  String get vaultContainsAnUnsupportedReferenceRecord =>
      'Vault contains an unsupported reference record type.';

  @override
  String get vaultContainsDuplicateCredentialIdentities =>
      'Vault contains duplicate Credential identities.';

  @override
  String get vaultKeysAreBeingCleared => 'Vault keys are being cleared.';

  @override
  String vaultQuotaUpdatedToQuotabytesBytes(int quotaBytes) {
    return 'Vault quota updated to $quotaBytes bytes.';
  }

  @override
  String get vaultReferenceRecordIdentityIsMalformed =>
      'Vault reference record identity is malformed.';

  @override
  String get vaultSyncDidNotConfirmThe =>
      'Vault sync did not confirm the reviewed SSH host-key approval.';

  @override
  String get vaultSyncDidNotConfirmThis =>
      'Vault sync did not confirm this SSH key approval. The connection was stopped; sync the Vault and review the key again.';

  @override
  String get vaultSyncIsUnavailableExistingSsh =>
      'Vault sync is unavailable. Existing SSH host-key history must be checked online before this connection can continue.';

  @override
  String vaultIdHasConflictingDeviceKeys(String id) {
    return 'Vault $id has conflicting device keys for one key epoch.';
  }

  @override
  String vaultIdHasNoKeyEnvelope(String id) {
    return 'Vault $id has no key envelope for its active key epoch.';
  }

  @override
  String vaultIdHasNoKeyEnvelope2(String id) {
    return 'Vault $id has no key envelope for the current device.';
  }

  @override
  String vaultIdKeyEnvelopeEpochDoes(String id) {
    return 'Vault $id key envelope epoch does not match its membership version.';
  }

  @override
  String vaultIdKeyEnvelopeRefersTo(String id) {
    return 'Vault $id key envelope refers to an unknown membership version.';
  }

  @override
  String vaultIdKeyEnvelopeSignerIs(String id) {
    return 'Vault $id key envelope signer is not a member at the signed version.';
  }

  @override
  String vaultIdLatestSignedMembershipEpoch(String id) {
    return 'Vault $id latest signed membership epoch does not match the server descriptor.';
  }

  @override
  String vaultIdLegacyDisplayNameEnvelope(String id) {
    return 'Vault $id legacy display name envelope cannot be opened by any available epoch key.';
  }

  @override
  String vaultIdMembershipDoesNotInclude(String id) {
    return 'Vault $id membership does not include this account as an active member.';
  }

  @override
  String vaultIdSignedDisplayNameEnvelope(String id) {
    return 'Vault $id signed display name envelope is invalid.';
  }

  @override
  String theEpochEpochKeyForVault(String id, int epoch) {
    return 'The epoch $epoch key for Vault $id is missing; approval was aborted.';
  }

  @override
  String theCurrentKeyEpochOfVault(String id) {
    return 'The current key epoch of Vault $id isn\'t on this device, so that device can\'t be approved.';
  }

  @override
  String theSigningDeviceForVaultId(String id) {
    return 'The signing device for Vault $id is unknown, so its key envelope can\'t be verified.';
  }

  @override
  String vaultSubstring(String substring) {
    return 'Vault $substring';
  }

  @override
  String vaultVaultidChangedOwnerWithoutA(String vaultId) {
    return 'Vault $vaultId changed Owner without a transfer signed by the prior Owner.';
  }

  @override
  String vaultVaultidHasAnOwnershipTransfer(String vaultId) {
    return 'Vault $vaultId has an ownership transfer signed by the new owner.';
  }

  @override
  String vaultVaultidMembershipHasAnInvalid(String vaultId) {
    return 'Vault $vaultId membership has an invalid member.';
  }

  @override
  String vaultVaultidMembershipHasNoMembers(String vaultId) {
    return 'Vault $vaultId membership has no members.';
  }

  @override
  String vaultVaultidMembershipMustContainExactly(String vaultId) {
    return 'Vault $vaultId membership must contain exactly one active owner.';
  }

  @override
  String vaultVaultidMembershipSignerIsAbsent(String vaultId) {
    return 'Vault $vaultId membership signer is absent from its device directory.';
  }

  @override
  String vaultVaultidMembershipWasNotSigned(String vaultId) {
    return 'Vault $vaultId membership was not signed by its active owner.';
  }

  @override
  String vaultVaultidOwnershipTransferChangedUnrelated(String vaultId) {
    return 'Vault $vaultId ownership transfer changed unrelated membership data.';
  }

  @override
  String vaultVaultidOwnershipTransferDoesNot(String vaultId) {
    return 'Vault $vaultId ownership transfer does not follow the signed owner and epoch chain.';
  }

  @override
  String vaultVaultidOwnershipTransferMetadataIs(String vaultId) {
    return 'Vault $vaultId ownership transfer metadata is invalid.';
  }

  @override
  String vaultVaultidOwnershipTransferUnexpectedlyChanged(String vaultId) {
    return 'Vault $vaultId ownership transfer unexpectedly changed the member set.';
  }

  @override
  String theApprovalKeyEnvelopeSignatureFor(String vaultId) {
    return 'The approval key envelope signature for Vault $vaultId is invalid.';
  }

  @override
  String theApprovedKeyForVaultVaultid(String vaultId) {
    return 'The approved key for Vault $vaultId couldn\'t be unsealed as the server key.';
  }

  @override
  String theServerKeyEnvelopeForVault(String vaultId) {
    return 'The server key envelope for Vault $vaultId doesn\'t match the approval file.';
  }

  @override
  String get someActiveDevicesInTheVault =>
      'Some active devices in the Vault don\'t support schema 2 or 1 GiB attachments. Update those devices, or remove active devices that are no longer used from the Vault, then try again.';

  @override
  String get vaultCreationReturnedSuccessButThe =>
      'Vault creation returned success, but the server couldn\'t verify the staged data yet; the migration journal is kept.';

  @override
  String get theVaultCreationResultCantBe =>
      'The Vault creation result can\'t be confirmed right now; the migration journal is kept. Resume later.';

  @override
  String get theVaultDeletionGracePeriodHas =>
      'The Vault deletion grace period has ended; the deletion can\'t be cancelled.';

  @override
  String get theVaultDeletionScheduleWasCreated =>
      'The Vault deletion schedule was created; the server deadline was updated.';

  @override
  String get theVaultDeletionScheduleWasCancelled =>
      'The Vault deletion schedule was cancelled and write access restored.';

  @override
  String get theVaultSyncStateIsAbnormal =>
      'The Vault sync state is abnormal, so SSH host keys can\'t be verified safely.';

  @override
  String get theVaultNameHasntBeenVerified =>
      'The Vault name hasn\'t been verified with its key; creating the member invitation was stopped.';

  @override
  String get theVaultNameHasntBeenVerified2 =>
      'The Vault name hasn\'t been verified with its key; the member key rotation was stopped.';

  @override
  String get theVaultWasSwitchedWhilePreparing =>
      'The Vault was switched while preparing the workspace connection. Reconnect.';

  @override
  String get theVaultKeyStateStillCant =>
      'The Vault key state still can\'t be verified; pending local data is kept.';

  @override
  String get youCantSwitchVaultsWhileThe =>
      'You can\'t switch Vaults while the Vault key is being rotated.';

  @override
  String get theVaultHasntFinishedFullySyncing =>
      'The Vault hasn\'t finished fully syncing the current version. Sync and try again.';

  @override
  String get theVaultWasSwitchedReopenThe =>
      'The Vault was switched. Reopen the Host and try again.';

  @override
  String get theVaultWasSwitchedReopenThe2 =>
      'The Vault was switched. Reopen the credential and try again.';

  @override
  String get theVaultWasSwitchedReopenThe4 =>
      'The Vault was switched. Reopen the group and try again.';

  @override
  String get theVaultWasSwitchedReopenThe3 =>
      'The Vault was switched. Reopen the recycle bin.';

  @override
  String get theVaultWasSwitchedReopenThe5 =>
      'The Vault was switched. Reopen the snippet and try again.';

  @override
  String get theVaultWasSwitchedThePreference =>
      'The Vault was switched; the preference repair is paused.';

  @override
  String get theVaultWasSwitchedCommandHistory =>
      'The Vault was switched; command history sync wasn\'t enabled.';

  @override
  String get vaultCreatedItsKeyWasGenerated =>
      'Vault created; its key was generated and signed by this device.';

  @override
  String get theVaultsCurrentEpochOrMembership =>
      'The Vault\'s current epoch or membership version is invalid.';

  @override
  String get theVaultsCurrentKeyEpochDoesnt =>
      'The Vault\'s current key epoch doesn\'t match the signed membership list.';

  @override
  String get aVaultMemberChangeIsIn =>
      'A Vault member change is in progress. Try again later.';

  @override
  String get localChangesArePausedDuringThe =>
      'Local changes are paused during the Vault member key rotation. Try again after it completes.';

  @override
  String get theVaultMemberKeyRotationIs =>
      'The Vault member key rotation is being committed. Wait for it to finish before locking the workspace.';

  @override
  String get theVaultMemberKeyRotationIs2 =>
      'The Vault member key rotation is being committed. Wait for it to finish before locking the account.';

  @override
  String get vaultMembersOrTheSignedIn =>
      'Vault members or the signed-in device changed. Choose the observer devices again.';

  @override
  String get invalidVaultMembershipVersionSyncAnd =>
      'Invalid Vault membership version. Sync and try again.';

  @override
  String get vaultMembershipChangedUnlockToVerify =>
      'Vault membership changed; unlock to verify the latest permissions and keys.';

  @override
  String get theVaultOrSshConnectionChanged =>
      'The Vault or SSH connection changed; reconnect the current workspace pane.';

  @override
  String get theVaultOrSignInSession =>
      'The Vault or sign-in session was switched. Reopen the recycle bin.';

  @override
  String get theVaultOrSignedInDevice =>
      'The Vault or signed-in device changed; joining the terminal share was cancelled.';

  @override
  String get theVaultOrSignedInDevice2 =>
      'The Vault or signed-in device changed; reconnecting the terminal share was cancelled.';

  @override
  String get theVaultOrDeviceStateChanged =>
      'The Vault or device state changed. Reopen the terminal share.';

  @override
  String get vaultOwnershipWasTransferredThisAccount =>
      'Vault ownership was transferred. This account keeps editor access, and the new Owner and every retained active device received the new epoch key. Pending invitation tokens are invalid and must be reissued by the new Owner.';

  @override
  String get theVaultIsRestoringOrChanging =>
      'The Vault is restoring or changing membership, so SSH host keys can\'t be verified right now.';

  @override
  String get aVaultStateActionIsIn =>
      'A Vault state action is in progress. Try again later.';

  @override
  String get theVaultDeviceDirectoryIsMissing =>
      'The Vault device directory is missing a valid account or signing public key.';

  @override
  String get theTmuxSessionStartedAndWas =>
      'The tmux session started and was saved encrypted to the workspace.';

  @override
  String get theTmuxActionTimedOutCheck =>
      'The tmux action timed out. Check the host status and try again.';

  @override
  String theLabelPreferenceConflictWasRepaired(String label) {
    return 'The $label preference conflict was repaired and confirmed by server sync.';
  }

  @override
  String theLabelPreferenceConflictWasConfirmed(String label) {
    return 'The $label preference conflict was confirmed by sync.';
  }

  @override
  String messageCode(String message, String code) {
    return '$message ($code)';
  }

  @override
  String noticemessageThisDeviceCouldntSaveThe(Object noticeMessage) {
    return '$noticeMessage This device couldn\'t save the current session sync state; other open tabs may need to sign in again.';
  }

  @override
  String get uploadMissingEncryptedObjectsAndRestore =>
      'Upload missing encrypted objects and restore local state atomically';

  @override
  String get youCantRevokeThisDeviceFrom =>
      'You can\'t revoke this device from itself';

  @override
  String get theCurrentlySignedInAdminAccount =>
      'The currently signed-in admin account can\'t be managed from here.';

  @override
  String get aGroupCantBeMovedInto =>
      'A group can\'t be moved into itself or one of its subgroups.';

  @override
  String get theCurrentVaultOwnerCantBe =>
      'The current Vault Owner can\'t be revoked or demoted through a member rotation.';

  @override
  String get theVaultOwnerCantBeRevoked =>
      'The Vault Owner can\'t be revoked or demoted through this action.';

  @override
  String get theNewMasterPasswordsDontMatch =>
      'The new master passwords don\'t match.';

  @override
  String get thePersonalVaultWasGeneratedAnd =>
      'The personal Vault was generated and encrypted on this device; its key is never sent to the server.';

  @override
  String get aMasterPasswordChangeIsIn =>
      'A master password change is in progress. Wait for it to finish before deleting the account.';

  @override
  String get aMasterPasswordChangeIsIn2 =>
      'A master password change is in progress. Try again later.';

  @override
  String get theMasterPasswordChangeIsBeing =>
      'The master password change is being committed. Wait for it to finish before locking the workspace.';

  @override
  String get theMasterPasswordChangeIsBeing2 =>
      'The master password change is being committed. Wait for it to finish before locking the account.';

  @override
  String get masterPasswordChangedOtherSignIn =>
      'Master password changed; other sign-in sessions were revoked.';

  @override
  String get theMasterPasswordWasCommittedBut =>
      'The master password was committed, but the refreshed account profile is inconsistent; retry to confirm.';

  @override
  String get theMasterPasswordMustBeAt2 =>
      'The master password must be at least 12 characters';

  @override
  String get theMasterPasswordMustBeAt3 =>
      'The master password must be at least 12 characters.';

  @override
  String get masterPasswordVerificationFailedTheDeletion =>
      'Master password verification failed; the deletion schedule wasn\'t changed. Enter the master password again.';

  @override
  String get aHostCantUseItselfAs =>
      'A host can\'t use itself as its Jump Host.';

  @override
  String get theHostCouldntBeReadBack =>
      'The host couldn\'t be read back after saving.';

  @override
  String get theHostHasntGrantedThisDevice =>
      'The host hasn\'t granted this device valid input control.';

  @override
  String get theHostNoLongerExistsResync =>
      'The host no longer exists. Resync and try again.';

  @override
  String get theHostWasSavedEncryptedAnd =>
      'The host was saved encrypted and added to the local sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get theHostWasSavedEncryptedLocally =>
      'The host was saved encrypted locally, waiting to sync.';

  @override
  String get theHostRevokedOrEndedInput =>
      'The host revoked or ended input control.';

  @override
  String get theHostOrJumpHostRoute =>
      'The host or Jump Host route changed while preparing the connection. Reconnect.';

  @override
  String get hostInputControlEnded => 'Host input control ended.';

  @override
  String get hostInputControlAuthorizationExpired =>
      'Host input control authorization expired.';

  @override
  String get onlyIsolatedRestoreCopiesInThe =>
      'Only isolated restore copies in the \"prepared\" state can be discarded. Refresh the job list.';

  @override
  String get theJobIsStillRunningAnd =>
      'The job is still running and automatic status checks are paused. You can refresh the job status manually.';

  @override
  String get theJobStatusIsTemporarilyUnavailable =>
      'The job status is temporarily unavailable and automatic status checks are paused. You can refresh the job status manually.';

  @override
  String get theSessionWasRefreshedButThe =>
      'The session was refreshed, but the new session snapshot couldn\'t be saved safely; this tab can keep working for now, but other tabs need to sign in again.';

  @override
  String get theSavedTmuxSessionNoLonger =>
      'The saved tmux session no longer exists; a new session won\'t be created automatically.';

  @override
  String get theRepairTombstoneHasntBeenConfirmed =>
      'The repair tombstone hasn\'t been confirmed by the server change cursor yet. Sync and try again.';

  @override
  String get theCandidateRecordIsMissingA =>
      'The candidate record is missing a verified current version; the repair is paused.';

  @override
  String get aPreferenceRepairIsInProgress =>
      'A preference repair is in progress. Wait for it to finish and try again.';

  @override
  String get thePreferenceRepairStateCantBe =>
      'The preference repair state can\'t be verified. Retry the sync before continuing.';

  @override
  String get thePreferenceRepairStateCantBe2 =>
      'The preference repair state can\'t be verified; resync before handling it.';

  @override
  String get theSharedSessionEndedAndThe =>
      'The shared session ended and the input control lease was revoked.';

  @override
  String get compatibleSftpDownloadsOnlySupportFiles =>
      'Compatible SFTP downloads only support files up to 16 MiB';

  @override
  String get invalidCompatibleDownloadSizeLimit =>
      'Invalid compatible download size limit';

  @override
  String get preparingExport => 'Preparing export';

  @override
  String get preparingVerification => 'Preparing verification';

  @override
  String get theCredentialNameCantBeEmpty =>
      'The credential name can\'t be empty';

  @override
  String get theCredentialUserNameCantBe =>
      'The credential user name can\'t be empty';

  @override
  String get theShareRequestComesFromA =>
      'The share request comes from a different server instance.';

  @override
  String get groups => 'Groups';

  @override
  String get theGroupDeletionWasSavedEncrypted =>
      'The group deletion was saved encrypted and added to the local sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get theGroupDeletionWasSavedEncrypted2 =>
      'The group deletion was saved encrypted and will propagate to other devices after sync.';

  @override
  String get theGroupNameCantExceed256 =>
      'The group name can\'t exceed 256 UTF-8 bytes.';

  @override
  String get theGroupNameContainsUnsupportedControl =>
      'The group name contains unsupported control characters.';

  @override
  String get theGroupWasSavedEncryptedAnd =>
      'The group was saved encrypted and added to the local sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get groupSavedEncryptedWaitingToSync =>
      'Group saved encrypted, waiting to sync.';

  @override
  String get invalidGroupColor => 'Invalid group color.';

  @override
  String get anAccountBeingDeletedCantPerform =>
      'An account being deleted can\'t perform this action.';

  @override
  String get anAccountBeingDeletedCantRevoke =>
      'An account being deleted can\'t revoke sessions.';

  @override
  String get theDeletionTombstoneIsStillWaiting =>
      'The deletion tombstone is still waiting for change-feed confirmation. Retry the sync.';

  @override
  String get theDeletionTombstoneWasSavedEncrypted =>
      'The deletion tombstone was saved encrypted and added to the local sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get theDeletionWasSavedAsAn =>
      'The deletion was saved as an encrypted tombstone and will propagate to other devices after sync.';

  @override
  String get encryptedBackupJobSubmittedItsStatus =>
      'Encrypted backup job submitted. Its status appears in the list below.';

  @override
  String get protocol2 => 'Protocol';

  @override
  String get anotherSyncTaskIsStillRunning =>
      'Another sync task is still running. Retry the preference repair after it finishes.';

  @override
  String get anotherInstanceAdminJobIsRunning =>
      'Another instance admin job is running. Try again later.';

  @override
  String get onlyTheVaultOwnerCanManage =>
      'Only the Vault Owner can manage deletion schedules.';

  @override
  String get onlyTheVaultOwnerCanManage2 =>
      'Only the Vault Owner can manage members.';

  @override
  String get onlyTheVaultOwnerCanInvite =>
      'Only the Vault owner can invite members.';

  @override
  String get onlyTheCurrentVaultOwnerCan =>
      'Only the current Vault Owner can change automatic purge consent.';

  @override
  String get onlyTheCurrentVaultOwnerCan2 =>
      'Only the current Vault Owner can permanently purge records.';

  @override
  String get inputControlCanOnlyBeGranted =>
      'Input control can only be granted to devices explicitly approved for this share.';

  @override
  String get onlyExistingHostsInTheCurrent =>
      'Only existing hosts in the current Vault can be referenced.';

  @override
  String get aVaultWithThisIdAlready =>
      'A Vault with this ID already exists, but it isn\'t the new empty Vault staged this time.';

  @override
  String get aGroupWithThisNameAlready =>
      'A group with this name already exists under the same parent. Change the name or choose another parent.';

  @override
  String get theSyncVaultWasSwitchedOr =>
      'The sync Vault was switched or is no longer writable; migration is paused.';

  @override
  String get theSyncVaultWasSwitchedMigration =>
      'The sync Vault was switched; migration is paused.';

  @override
  String get aSyncIsStillRunningThe =>
      'A sync is still running; the member change was cancelled. Try again later.';

  @override
  String get aSyncIsStillRunningRetry =>
      'A sync is still running. Retry the preference repair after it finishes.';

  @override
  String get theConflictCandidatesOrVersionsChanged =>
      'The conflict candidates or versions changed after sync. Check the list and choose again.';

  @override
  String syncCompleteReceivedcountChangesReceived(int receivedCount) {
    String _temp0 = intl.Intl.pluralLogic(
      receivedCount,
      locale: localeName,
      other: '$receivedCount changes received',
      one: '1 change received',
    );
    return 'Sync complete: $_temp0.';
  }

  @override
  String get theMasterPasswordCantBeChanged =>
      'The master password can\'t be changed during sync or snapshot restore. Try again after it completes.';

  @override
  String get theAccountCantBeDeletedDuring =>
      'The account can\'t be deleted during sync or snapshot restore. Try again after it completes.';

  @override
  String get name => 'Name';

  @override
  String get address => 'Address';

  @override
  String get theBackupIntervalMustBe1 =>
      'The backup interval must be 1 to 720 hours.';

  @override
  String get aMasterPasswordChangeIsWaiting =>
      'A master password change is waiting for confirmation; retry the original action first.';

  @override
  String get theInstanceIsAlreadyInitializedFirst =>
      'The instance is already initialized; first-account registration can\'t be used again.';

  @override
  String get theAuditCursorExpiredTheServer =>
      'The audit cursor expired. The server may have switched generations; reload from the first page.';

  @override
  String get thePasswordCantBeEmpty => 'The password can\'t be empty';

  @override
  String get thePasswordChangeOperationStateConflicts =>
      'The password change operation state conflicts. To avoid changing it twice, keep the current session and contact an administrator.';

  @override
  String get noServerInstanceIsConfiguredYet =>
      'No server instance is configured yet.';

  @override
  String get nestedWorkspacesCanOnlyReferenceExisting =>
      'Nested workspaces can only reference existing hosts in the current Vault.';

  @override
  String get theWorkspaceTmuxReferenceChangedReload =>
      'The workspace tmux reference changed. Reload and try again.';

  @override
  String get theWorkspaceHostWasRemovedFrom =>
      'The workspace host was removed from the current Vault while preparing the connection; repair the reference first.';

  @override
  String get theWorkspaceDeletionWasAddedTo =>
      'The workspace deletion was added to the local encrypted sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get theWorkspaceDeletionWasSavedEncrypted =>
      'The workspace deletion was saved encrypted and will propagate to other devices after sync.';

  @override
  String get workspacesCanOnlyAddReferencesTo =>
      'Workspaces can only add references to existing hosts in the current Vault.';

  @override
  String get theWorkspaceNoLongerExistsIn =>
      'The workspace no longer exists in the current Vault.';

  @override
  String get theWorkspaceWasSwitchedTryAgain =>
      'The workspace was switched. Try again.';

  @override
  String get theWorkspaceWasSavedEncryptedAnd =>
      'The workspace was saved encrypted and added to the local sync queue; refreshing sync status failed and will be retried later.';

  @override
  String get workspaceSavedEncryptedWaitingToSync =>
      'Workspace saved encrypted, waiting to sync.';

  @override
  String get theWorkspaceChanged => 'The workspace changed.';

  @override
  String get theWorkspaceIsLockedButThis =>
      'The workspace is locked, but this device\'s automatic unlock record couldn\'t be cleared; fix local storage, then sign in again and lock.';

  @override
  String get theWorkspaceIsntLockedRightNow =>
      'The workspace isn\'t locked right now.';

  @override
  String get theWorkspacePaneNoLongerExists =>
      'The workspace pane no longer exists.';

  @override
  String get theWorkspacePaneOrHostReference =>
      'The workspace pane or host reference changed. Reconnect and try again.';

  @override
  String get localChangesAreBlockedWhileThe =>
      'Local changes are blocked while the workspace is locked. Unlock it first.';

  @override
  String uploadedName(String name) {
    return 'Uploaded $name';
  }

  @override
  String savedName(String name) {
    return 'Saved $name';
  }

  @override
  String savedNameButCouldntConfirmThe(String name) {
    return 'Saved $name, but couldn\'t confirm the original permissions were restored; check the remote file permissions.';
  }

  @override
  String get thePinnedServerIdentityChangedDuring =>
      'The pinned server identity changed during confirmation. Reconnect and try again.';

  @override
  String get unlockedLocallyTheServerStillStores =>
      'Unlocked locally; the server still stores only encrypted records and key envelopes.';

  @override
  String get memberInvitationAcceptedTheVaultIs =>
      'Member invitation accepted; the Vault is unlocked and syncing has started.';

  @override
  String get anExistingRepairTombstoneAlreadySpecifies =>
      'An existing repair tombstone already specifies the retained record; retry the repair with that record.';

  @override
  String get theRecordRetainedByAnExisting =>
      'The record retained by an existing repair tombstone is inconsistent and needs a manual check.';

  @override
  String get aServerAccessGroupWithThe =>
      'A server access group with the same name already exists (ignoring case and Unicode compatibility characters).';

  @override
  String get thePreviouslySubmittedMasterPasswordChange =>
      'The previously submitted master password change was confirmed; other sign-in sessions were revoked.';

  @override
  String get attachedToTheSavedTmuxSession =>
      'Attached to the saved tmux session.';

  @override
  String theKeyKeyInTheArchive(String key) {
    return 'The $key key in the archive doesn\'t match the locally unlocked key.';
  }

  @override
  String get theArchiveNoLongerCorrespondsTo =>
      'The archive no longer corresponds to the current server space/Vault; nothing was imported.';

  @override
  String get theArchiveWasVerifiedAndRestored =>
      'The archive was verified and restored. Historical keys are kept only in this client\'s memory; the local outbox and conflict branches are preserved.';

  @override
  String get lockTheWorkspaceAfterTheArchive =>
      'Lock the workspace after the archive operation completes.';

  @override
  String get theCurrentOwnerDeviceIsntIn =>
      'The current Owner device isn\'t in the retained members\' set of active devices; the rotation was aborted.';

  @override
  String get theCurrentPostgresqlModeSupportsInstance =>
      'The current PostgreSQL mode supports instance maintenance; server-side encrypted backup and restore aren\'t available yet.';

  @override
  String get theCurrentVaultIsntWritable =>
      'The current Vault isn\'t writable.';

  @override
  String theCurrentVaultIsntWritableSo(String label) {
    return 'The current Vault isn\'t writable, so the $label preference can\'t be repaired.';
  }

  @override
  String get theCurrentVaultIsReadOnly6 =>
      'The current Vault is read-only or being deleted; command history sync can\'t be enabled.';

  @override
  String get theCurrentVaultIsReadOnly =>
      'The current Vault is read-only; preferences can\'t be changed.';

  @override
  String get theCurrentVaultIsReadOnly2 =>
      'The current Vault is read-only; groups can\'t be changed.';

  @override
  String get theCurrentVaultIsReadOnly3 =>
      'The current Vault is read-only; groups can\'t be deleted.';

  @override
  String get theCurrentVaultIsReadOnly4 =>
      'The current Vault is read-only; automatic purge consent can\'t be changed.';

  @override
  String get theCurrentVaultIsReadOnly5 =>
      'The current Vault is read-only; records can\'t be purged permanently.';

  @override
  String get theCurrentVaultSyncRepositoryIsnt =>
      'The current Vault sync repository isn\'t ready yet.';

  @override
  String get theCurrentVaultSyncTimedOut =>
      'The current Vault sync timed out; the SSH host key trust check was stopped.';

  @override
  String get theCurrentVaultIsLockedSo =>
      'The current Vault is locked, so SSH host keys can\'t be verified.';

  @override
  String get theCurrentVaultOrSignedIn =>
      'The current Vault or signed-in device can\'t be used for terminal sharing.';

  @override
  String get refreshingTheCurrentVaultStateTimed =>
      'Refreshing the current Vault state timed out; the SSH host key trust check was stopped.';

  @override
  String get theCurrentMasterPasswordOrSix =>
      'The current master password or six-digit authenticator code is invalid or already used. Enter the master password and a new six-digit code again.';

  @override
  String get theCurrentMasterPasswordOrAccount =>
      'The current master password or account key envelope can\'t be verified.';

  @override
  String get theCurrentMasterPasswordMustBe =>
      'The current master password must be at least 12 characters.';

  @override
  String get theCurrentMasterPasswordCouldntBe =>
      'The current master password couldn\'t be verified; the account credentials weren\'t changed. Check the password and try again.';

  @override
  String get theCurrentHostOrVaultIs =>
      'The current host or Vault is unavailable.';

  @override
  String get tmuxIsntAvailableOnTheCurrent =>
      'tmux isn\'t available on the current host.';

  @override
  String get theCurrentSessionIsMissingThe =>
      'The current session is missing the account name.';

  @override
  String get theCurrentSyncHasntFinishedWait =>
      'The current sync hasn\'t finished. Wait for it before creating a member invitation.';

  @override
  String get theCurrentSyncHasntFinishedWait2 =>
      'The current sync hasn\'t finished. Wait for it before changing Vault members.';

  @override
  String get anInputControlLeaseIsAlready =>
      'An input control lease is already active. Revoke it first.';

  @override
  String get theCurrentMemberRoleCantBe =>
      'The current member role can\'t be revoked through this action.';

  @override
  String get theCurrentServerDoesntDeclareSupport =>
      'The current server doesn\'t declare support for discarding isolated restore copies.';

  @override
  String get theresNoSignedInAccountWhose =>
      'There\'s no signed-in account whose password can be changed.';

  @override
  String get noAccountIsSignedIn => 'No account is signed in.';

  @override
  String thereAreNoPendingLabelPreference(String label) {
    return 'There are no pending $label preference conflicts.';
  }

  @override
  String get theCurrentTestSshConnectorDoesnt =>
      'The current test SSH connector doesn\'t support Jump Hosts.';

  @override
  String get theCurrentTestSshConnectorDoesnt2 =>
      'The current test SSH connector doesn\'t support multi-hop Jump Hosts.';

  @override
  String get thisBrowserHasNoRegisteredDevice =>
      'This browser has no registered device key. Add this device again from an authorized device.';

  @override
  String get thisBrowserHasNoRegisteredDevice2 =>
      'This browser has no registered device key. Add this device from an authorized device first.';

  @override
  String get theCurrentDeviceKeyIsMissing =>
      'The current device key is missing or doesn\'t match the session. Authorize this device again.';

  @override
  String get thisDeviceDoesntHaveKeysFor =>
      'This device doesn\'t have keys for every Vault, so it can\'t approve that device.';

  @override
  String get theCurrentDeviceIdentityDoesntMatch =>
      'The current device identity doesn\'t match the sign-in session.';

  @override
  String get theCurrentAccountOrVaultChanged =>
      'The current account or Vault changed, so the SSH host key can\'t be verified.';

  @override
  String get theCurrentAccountDoesntHaveInstance =>
      'The current account doesn\'t have instance admin permissions.';

  @override
  String get theCurrentAccountIdentityIsUnavailable =>
      'The current account identity is unavailable. Sign in again.';

  @override
  String get theCurrentAccountVerificationDetailsDont =>
      'The current account verification details don\'t match.';

  @override
  String get theRoleOfAPendingInvitation =>
      'The role of a pending invitation can\'t be changed directly. Revoke it and invite again with the new role.';

  @override
  String get thePendingMasterPasswordChangeRequest =>
      'The pending master password change request was cleared.';

  @override
  String get theServerIdentityAwaitingConfirmationWas =>
      'The server identity awaiting confirmation was cancelled. Reconnect and try again.';

  @override
  String get theSnapshotWasRestoredSafelySome =>
      'The snapshot was restored safely; some operations are still waiting to upload or conflicts are waiting to retry. The original outbox is kept.';

  @override
  String snapshotRestoreCompleteReceivedcountRecordsVerified(
    int receivedCount,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      receivedCount,
      locale: localeName,
      other: '$receivedCount records verified and rebuilt',
      one: '1 record verified and rebuilt',
    );
    return 'Snapshot restore complete: $_temp0.';
  }

  @override
  String get youCantSwitchVaultsDuringSnapshot =>
      'You can\'t switch Vaults during snapshot restore.';

  @override
  String get localChangesArePausedDuringSnapshot =>
      'Local changes are paused during snapshot restore. Try again after it completes.';

  @override
  String get theMemberRoleCanOnlyBe =>
      'The member role can only be set to editor or viewer.';

  @override
  String get theMemberRoleWasUpdatedAnd =>
      'The member role was updated and new keys were rotated for every retained member device.';

  @override
  String get theMemberRoleWasUpdatedAnd2 =>
      'The member role was updated and new keys were rotated for every retained member device. Pending invitations stay pending, but old tokens are invalid; invite again.';

  @override
  String get memberRoleUpdatedTheServerCommitted =>
      'Member role updated; the server committed a new key epoch.';

  @override
  String get memberAccessWasRevokedAndThe =>
      'Member access was revoked and the Vault key was rotated for retained members. Pending invitations stay pending, but old tokens are invalid; invite again.';

  @override
  String get memberAccessWasRevokedAndThe3 =>
      'Member access was revoked and the Vault key rotated for retained members. The revoked member doesn\'t receive the new epoch key; copies they already saved can\'t be deleted remotely.';

  @override
  String get memberAccessWasRevokedAndThe2 =>
      'Member access was revoked and the server committed a new key epoch. Note that copies they already saved can\'t be deleted remotely.';

  @override
  String get invalidMemberAccountIdFormat =>
      'Invalid member account ID format.';

  @override
  String get theMemberRotationResultCantBe =>
      'The member rotation result can\'t be confirmed right now, so this Vault was locked to avoid using the old key. Sign in again and check the membership before continuing.';

  @override
  String get ownershipCanOnlyBeTransferredTo =>
      'Ownership can only be transferred to an active member who accepted their invitation.';

  @override
  String get theSelectedJumpHostNoLonger =>
      'The selected Jump Host no longer exists. Choose a valid host or clear the stale reference.';

  @override
  String get theSelectedSshCredentialNoLonger =>
      'The selected SSH credential no longer exists. Choose a valid credential or clear this override.';

  @override
  String get theSelectedSessionNoLongerExists =>
      'The selected session no longer exists or was already revoked. Refresh the session list.';

  @override
  String get theSelectedRetainedRecordChangedCheck =>
      'The selected retained record changed. Check the candidates again.';

  @override
  String get theSelectedGroupNoLongerExists =>
      'The selected group no longer exists. Choose a valid group or remove the group.';

  @override
  String get theSelectedEncryptedArchiveIsUnavailable =>
      'The selected encrypted archive is unavailable. Refresh the source list and try again.';

  @override
  String get theSelectedArchiveIsInvalidRefresh =>
      'The selected archive is invalid. Refresh the source list and try again.';

  @override
  String get theSelectedArchiveSourceIsInvalid =>
      'The selected archive source is invalid. Refresh the source list and try again.';

  @override
  String get theSelectedServerAccessGroupNo =>
      'The selected server access group no longer exists. Refresh the list.';

  @override
  String get theApprovalFileDoesntMatchThe =>
      'The approval file doesn\'t match the device request generated by this browser.';

  @override
  String get theVaultKeyEnvelopeContextIn =>
      'The Vault key envelope context in the approval file is invalid.';

  @override
  String get theVaultKeyEnvelopeInThe2 =>
      'The Vault key envelope in the approval file has an invalid format.';

  @override
  String get theDeviceCapabilityReportInThe =>
      'The device capability report in the approval file has an invalid format.';

  @override
  String get theApprovalFileContainsDuplicateVault =>
      'The approval file contains duplicate Vault key envelopes.';

  @override
  String get theApprovalFileBelongsToA =>
      'The approval file belongs to a different account or server instance.';

  @override
  String get theApprovalFileIsStagedAfter =>
      'The approval file is staged. After sign-in, the client verifies the owner certificate and each Vault key envelope before unlocking data.';

  @override
  String get theDeviceSelfProofInThe =>
      'The device self-proof in the approval file doesn\'t match the local device key.';

  @override
  String get theApproverOrCurrentDeviceIsnt =>
      'The approver or current device isn\'t in the server account\'s device directory.';

  @override
  String get theApproverCertificateFieldsAreInvalid =>
      'The approver certificate fields are invalid.';

  @override
  String get theApproverCertificateSignatureIsInvalid =>
      'The approver certificate signature is invalid.';

  @override
  String get thisHostCouldntBeFound => 'This host couldn\'t be found.';

  @override
  String get theVaultOnThisDeviceCouldnt =>
      'The Vault on this device couldn\'t be found.';

  @override
  String get theScrapeCredentialWasRotatedThe =>
      'The scrape credential was rotated; the value is shown only once.';

  @override
  String get toCancelAccountDeletionSignOut =>
      'To cancel account deletion, sign out first and use the recovery option on the sign-in page.';

  @override
  String theFileWasSavedButThe(String friendlyError) {
    return 'The file was saved, but the folder couldn\'t be refreshed: $friendlyError';
  }

  @override
  String get theNewMasterPasswordMustDiffer =>
      'The new master password must differ from the current one.';

  @override
  String get theNewMasterPasswordMustBe =>
      'The new master password must be at least 12 characters.';

  @override
  String get couldntDiscardTheIsolatedRestoreCopy =>
      'Couldn\'t discard the isolated restore copy. Refresh the job list and try again.';

  @override
  String get couldntSaveChangesToTheTmux =>
      'Couldn\'t save changes to the tmux session reference. Try again later.';

  @override
  String get couldntSaveTheScheduledBackupSettings =>
      'Couldn\'t save the scheduled backup settings. Try again.';

  @override
  String get couldntPrepareTheIsolatedRestoreCopy =>
      'Couldn\'t prepare the isolated restore copy. Live data wasn\'t changed.';

  @override
  String get couldntCreateANewTmuxSession =>
      'Couldn\'t create a new tmux session. Try again.';

  @override
  String get couldntJoinInputControlMakeSure =>
      'Couldn\'t join input control. Make sure the host still grants control to this device.';

  @override
  String get couldntStartTheLocalShell => 'Couldn\'t start the local shell.';

  @override
  String get couldntStartTerminalSharingCheckThe =>
      'Couldn\'t start terminal sharing. Check the connection and Vault membership, then try again.';

  @override
  String couldntSafelyCreateRemoteFileName(String name, Object error) {
    return 'Couldn\'t safely create remote file $name. It may already exist, or the current user lacks write permission; existing files aren\'t overwritten. ($error)';
  }

  @override
  String get couldntSafelyRestoreTheSignIn =>
      'Couldn\'t safely restore the sign-in session. Sign in again.';

  @override
  String get theRefreshRequestStateCouldntBe =>
      'The refresh request state couldn\'t be recorded safely, so the refresh request was blocked. Check this device\'s secure storage and try again.';

  @override
  String get couldntCompleteTheTmuxSessionAction =>
      'Couldn\'t complete the tmux session action. Check the host status and try again.';

  @override
  String couldntFinishSyncingTheCurrentVault(String syncStatus) {
    return 'Couldn\'t finish syncing the current Vault ($syncStatus); the SSH host key trust check was stopped.';
  }

  @override
  String get couldntConfirmTheTmuxSessionStarted =>
      'Couldn\'t confirm the tmux session started. Check the host and try again.';

  @override
  String get couldntReadEncryptedArchiveSourcesTry =>
      'Couldn\'t read encrypted archive sources. Try again later.';

  @override
  String get couldntReadLocalSecuritySettingsCheck =>
      'Couldn\'t read local security settings. Check browser storage and try again.';

  @override
  String get couldntReadThisTerminalShare =>
      'Couldn\'t read this terminal share.';

  @override
  String get couldntReadTheScheduledBackupSettings =>
      'Couldn\'t read the scheduled backup settings. Try again.';

  @override
  String get couldntReadTheRestoreJobStatus2 =>
      'Couldn\'t read the restore job status. Try again later.';

  @override
  String get couldntRejoinTheShareMayHave =>
      'Couldn\'t rejoin; the share may have ended or Vault access may have changed.';

  @override
  String get couldntVerifyTheCurrentDeviceApproval =>
      'Couldn\'t verify the current device approval.';

  @override
  String get thePendingVaultRecordsCouldntBe =>
      'The pending Vault records couldn\'t be verified; turning off sync took effect, but the offline queue wasn\'t cleared.';

  @override
  String get thePendingCommandHistoryCouldntBe =>
      'The pending command history couldn\'t be verified; turning off sync took effect, but the offline queue wasn\'t cleared.';

  @override
  String get theStagedVaultCreationDataDoesnt =>
      'The staged Vault creation data doesn\'t match the target ID.';

  @override
  String get theStagedVaultCreationDataHas =>
      'The staged Vault creation data has an invalid format.';

  @override
  String get couldntReadTheRestoreJobStatus3 =>
      'Couldn\'t read the restore job status right now; the system will keep trying.';

  @override
  String get couldntReadTheRestoreJobStatus =>
      'Couldn\'t read the restore job status right now. Retry manually.';

  @override
  String upToMaxterminaltabsSshTerminalTabs(int maxTerminalTabs) {
    return 'Up to $maxTerminalTabs SSH terminal tabs can be open at once; close a tab first.';
  }

  @override
  String get aVaultIsInItsDeletion =>
      'A Vault is in its deletion grace period, so the server doesn\'t allow approving new devices right now.';

  @override
  String get theServerSyncGenerationChangedUnlock =>
      'The server sync generation changed; unlock the Vault to resume sync safely.';

  @override
  String get theServerHasntConfiguredEncryptedBackups =>
      'The server hasn\'t configured encrypted backups. Ask the instance operator to set ATERMIUS_BACKUP_ARCHIVE_DIR (an owner-only directory outside the data directory) and ATERMIUS_BACKUP_KEY_FILE (a 32-byte owner-only key file outside the data directory). This client never sends or shows these paths, archive file names or keys.';

  @override
  String get theServerHasntConfiguredIsolatedRestore =>
      'The server hasn\'t configured isolated restore storage. Contact the instance operator.';

  @override
  String get theServerAccessGroupWasUpdated =>
      'The server access group was updated by another administrator. Reload the latest data; your current draft is kept.';

  @override
  String get theServersInitialVaultMembershipRecord =>
      'The server\'s initial Vault membership record has an invalid format.';

  @override
  String get theServerVaultKeyEnvelopeDoesnt =>
      'The server Vault key envelope doesn\'t match the creation data staged on this device.';

  @override
  String get theServersVaultMembershipListHas =>
      'The server\'s Vault membership list has an invalid format; the key rotation was stopped.';

  @override
  String get theServerVaultMembershipChainDoesnt =>
      'The server Vault membership chain doesn\'t match the creation data staged on this device.';

  @override
  String get theServersEncryptedArchiveConfigurationIs =>
      'The server\'s encrypted archive configuration is unavailable. Contact the server operator.';

  @override
  String get theServerSyncCursorExpiredA =>
      'The server sync cursor expired; a new snapshot is required.';

  @override
  String get theServerInstanceIdChangedAnd =>
      'The server instance ID changed and can\'t be confirmed through key recovery.';

  @override
  String get theServerInstanceIdentityChangedTo =>
      'The server instance identity changed. To protect your local vault, the client refused to connect.';

  @override
  String theServerHasntConfirmedThatOnly(String label) {
    return 'The server hasn\'t confirmed that only the selected $label preference record remains. Sync and try again.';
  }

  @override
  String get theServerHasntConfiguredAUsable =>
      'The server hasn\'t configured a usable encrypted backup destination and key; the scheduled backup wasn\'t changed.';

  @override
  String get theServerAcceptedTheRevocationRequest =>
      'The server accepted the revocation request. The old session won\'t be restored; sign in again.';

  @override
  String get theServerAcceptedTheDeletionRequest2 =>
      'The server accepted the deletion request, but returned an invalid grace period state.';

  @override
  String get theServerAcceptedTheDeletionRequest =>
      'The server accepted the deletion request; the current session and this device\'s unlock key were cleared. Use the account recovery option on the sign-in page; if still within the grace period you can cancel, then you must sign in again.';

  @override
  String get theServerCommittedTheVaultOwnership =>
      'The server committed the Vault ownership transfer and a new key epoch; this account was demoted to editor.';

  @override
  String get theServerSnapshotContainsRecordsThis =>
      'The server snapshot contains records this device already purged. To prevent old data from coming back, the client keeps its current cache, sync cursor and local drafts and stops automatic sync. If the server was just restored from a pre-purge backup, an administrator must first review and reprocess the server restore state; this device won\'t automatically delete saved purge receipts.';

  @override
  String get theServerCommittedTheMemberRotation =>
      'The server committed the member rotation, but the new epoch and membership can\'t be verified locally; further actions were stopped.';

  @override
  String get theServerMembershipChainBelongsTo =>
      'The server membership chain belongs to a different Vault.';

  @override
  String get theServerRejectedThisBackupSchedule =>
      'The server rejected this backup schedule request. Refresh and try again.';

  @override
  String get theServerRejectedThisIsolatedRestore =>
      'The server rejected this isolated restore request. Refresh the source list and try again.';

  @override
  String get theServerDidntReturnTheVault =>
      'The server didn\'t return the Vault ID for the accepted invitation.';

  @override
  String get theServerDidntReturnAValid =>
      'The server didn\'t return a valid deletion grace period and deadline.';

  @override
  String get theServerDidntProvideAVerifiable =>
      'The server didn\'t provide a verifiable restore deadline, so the permanent purge was blocked.';

  @override
  String get theServerDidntProvideAValid =>
      'The server didn\'t provide a valid instance signing identity.';

  @override
  String get theServerDidntReturnAnAccount =>
      'The server didn\'t return an account identifier, so a device request can\'t be created.';

  @override
  String get theServerSigningKeyDoesntMatch =>
      'The server signing key doesn\'t match the pinned identity. Verify the candidate fingerprint over a separate trusted channel first.';

  @override
  String get theServerSigningKeyDoesntMatch2 =>
      'The server signing key doesn\'t match the pinned identity. Compare the candidate fingerprint over a separate trusted channel; no account connection or authentication request is sent before you confirm.';

  @override
  String get theServerIsMissingTheExisting =>
      'The server is missing the existing recovery identity envelope, so it can\'t be rotated safely.';

  @override
  String get theServerDeviceDirectoryDoesntMatch =>
      'The server device directory doesn\'t match the account or public key in the approval file.';

  @override
  String get theServersDeviceCapabilityReportDoesnt =>
      'The server\'s device capability report doesn\'t match the approval file.';

  @override
  String get theServerIdentityChangedDuringConfirmation =>
      'The server identity changed during confirmation. Reconnect and verify the new fingerprint.';

  @override
  String get serverIdentityConfirmationIsInProgress =>
      'Server identity confirmation is in progress.';

  @override
  String get serverIdentityConfirmationIsInProgress2 =>
      'Server identity confirmation is in progress and can\'t be cancelled right now.';

  @override
  String get serverIdentityConfirmationIsInProgress3 =>
      'Server identity confirmation is in progress. Wait for the current action to finish.';

  @override
  String get theServerRotationResultDoesntMatch =>
      'The server rotation result doesn\'t match the signed epoch/membership version.';

  @override
  String get theServerReturnedADifferentMigration =>
      'The server returned a different migration destination Vault ID.';

  @override
  String get theVaultOwnerStateReturnedBy =>
      'The Vault Owner state returned by the server doesn\'t match.';

  @override
  String get theServerReturnedAnInvalidMaster =>
      'The server returned an invalid master password change receipt.';

  @override
  String get theServerReturnedAnInvalidRecovery =>
      'The server returned an invalid recovery setup receipt.';

  @override
  String get theMembershipVersionReturnedByThe =>
      'The membership version returned by the server doesn\'t match the local signature.';

  @override
  String get theRevocationStateReturnedByThe =>
      'The revocation state returned by the server is invalid; the Vault stays locked.';

  @override
  String get theAccountRevocationStateReturnedBy =>
      'The account revocation state returned by the server is invalid.';

  @override
  String get theServerReturnedDuplicateMigrationDestination =>
      'The server returned duplicate migration destination Vaults.';

  @override
  String get noIsolatedRestoreCopyToDiscard =>
      'No isolated restore copy to discard was found. Refresh the job list.';

  @override
  String get thereAreUncommittedLocalChangesRotate =>
      'There are uncommitted local changes. Rotate member keys after sync completes so older records can still be committed.';

  @override
  String get thereAreUncommittedLocalChangesCreate =>
      'There are uncommitted local changes. Create the member invitation after sync succeeds so older records can still be committed.';

  @override
  String get theLocalFileNameIsntA =>
      'The local file name isn\'t a safe remote file name.';

  @override
  String get localConsole => 'Local Console';

  @override
  String get theLocalConsoleRequiresTheDesktop =>
      'The local Console requires the desktop client.';

  @override
  String get thisDevicesEncryptedHistoryRepositoryIsnt =>
      'This device\'s encrypted history repository isn\'t ready yet.';

  @override
  String get thisDeviceHasNoCurrentSession =>
      'This device has no current session snapshot that can be restored safely. Sign in again.';

  @override
  String get thisSignInCanContinueBut =>
      'This sign-in can continue, but the sign-in state can\'t be remembered.';

  @override
  String get refreshingVaultMembershipTryChangingIt =>
      'Refreshing Vault membership. Try changing it again shortly.';

  @override
  String get anotherVaultMemberInvitationIsBeing =>
      'Another Vault member invitation is being accepted. Try again later.';

  @override
  String get confirmingTheInputControlRevocationTry =>
      'Confirming the input control revocation. Try again shortly.';

  @override
  String get connectingHostApprovedInputControl =>
      'Connecting host-approved input control.';

  @override
  String get thisHostChangedAfterThePreview =>
      'This Host changed after the preview. Resync and review the refresh differences.';

  @override
  String get thisHostNoLongerExistsOr =>
      'This Host no longer exists or can\'t be read uniquely; resync before editing.';

  @override
  String get thisHostsLocalEncryptedRecordCouldnt =>
      'This Host\'s local encrypted record couldn\'t be verified; saving was stopped to avoid overwriting or losing data.';

  @override
  String get thisHostIsMissingAVerifiable =>
      'This Host is missing a verifiable local revision; saving was stopped to avoid breaking the sync history.';

  @override
  String thisSshCredentialIsStillReferenced(
    int groupCount,
    int hostCount,
    int snippetParameterCount,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      groupCount,
      locale: localeName,
      other: '$groupCount group defaults',
      one: '1 group default',
    );
    String _temp1 = intl.Intl.pluralLogic(
      hostCount,
      locale: localeName,
      other: '$hostCount host overrides',
      one: '1 host override',
    );
    String _temp2 = intl.Intl.pluralLogic(
      snippetParameterCount,
      locale: localeName,
      other: '$snippetParameterCount snippet secret parameters',
      one: '1 snippet secret parameter',
    );
    return 'This SSH credential is still referenced by $_temp0, $_temp1 and $_temp2; replace or clear these references first.';
  }

  @override
  String get thisSshCredentialNoLongerExists =>
      'This SSH credential no longer exists or can\'t be verified; resync the Vault first.';

  @override
  String get theTerminalFontSizePreferenceIn =>
      'The terminal font size preference in this Vault has duplicate records or an unconfirmed repair. Complete an explicit repair.';

  @override
  String get theTerminalShortcutPreferenceInThis =>
      'The terminal shortcut preference in this Vault has duplicate records or an unconfirmed repair. Complete an explicit repair.';

  @override
  String get theTerminalColorPreferenceInThis =>
      'The terminal color preference in this Vault has duplicate records or an unconfirmed repair. Complete an explicit repair.';

  @override
  String get theDefaultWorkspacePreferenceInThis =>
      'The default workspace preference in this Vault has duplicate records or an unconfirmed repair. Complete an explicit repair.';

  @override
  String get thisVaultContainsUnsupportedPreferenceRecords =>
      'This Vault contains unsupported preference records; the repair is paused.';

  @override
  String get thisVaultContainsPreferencesThatThis =>
      'This Vault contains preferences that this client doesn\'t support.';

  @override
  String get thisVaultCantBeUsedTo =>
      'This Vault can\'t be used to create a terminal share right now.';

  @override
  String get thisVaultIsntCurrentlyInAn =>
      'This Vault isn\'t currently in an active state that allows deletion.';

  @override
  String get thisVaultIsCurrentlyReadOnly =>
      'This Vault is currently read-only; members can\'t be changed.';

  @override
  String get thisVaultHasNoDeletionSchedule =>
      'This Vault has no deletion schedule that can be cancelled.';

  @override
  String get thisVaultIsInItsDeletion =>
      'This Vault is in its deletion grace period and is currently read-only.';

  @override
  String get thisVaultIsInItsDeletion2 =>
      'This Vault is in its deletion grace period and read-only; the Owner can cancel the deletion before the deadline.';

  @override
  String thisHostIsStillUsedAs(int dependants) {
    String _temp0 = intl.Intl.pluralLogic(
      dependants,
      locale: localeName,
      other: '$dependants hosts',
      one: '1 host',
    );
    return 'This host is still used as a Jump Host by $_temp0; replace or clear these references first.';
  }

  @override
  String get thisSessionWasSignedOutIn =>
      'This session was signed out in another tab. Sign in again.';

  @override
  String get thisSessionsRefreshTokenStateCant =>
      'This session\'s refresh token state can\'t be restored safely. Sign in again.';

  @override
  String get thisSharedSessionDoesntHaveHost =>
      'This shared session doesn\'t have host-approved input control enabled.';

  @override
  String thisGroupIsStillReferencedBy(int hostCount, int childCount) {
    String _temp0 = intl.Intl.pluralLogic(
      hostCount,
      locale: localeName,
      other: '$hostCount Hosts',
      one: '1 Host',
    );
    String _temp1 = intl.Intl.pluralLogic(
      childCount,
      locale: localeName,
      other: '$childCount subgroups',
      one: '1 subgroup',
    );
    return 'This group is still referenced by $_temp0 and $_temp1; move those records first.';
  }

  @override
  String get thisGroupNoLongerExistsOr =>
      'This group no longer exists or can\'t be verified; resync the Vault first.';

  @override
  String thisDeletedRecordIsPastThe(String dateText) {
    return 'This deleted record is past the server restore deadline$dateText. The tombstone keeps reserving this record ID; to keep using it, create a new record with a new ID.';
  }

  @override
  String get thisInstanceIsntInitializedYetCreate =>
      'This instance isn\'t initialized yet. Create the first account with the one-time bootstrap token generated by the administrator.';

  @override
  String get thisWorkspaceHostNoLongerExists =>
      'This workspace host no longer exists in the current Vault. Repair the reference first.';

  @override
  String get thisWorkspacePaneAlreadyHasA =>
      'This workspace pane already has a tmux session reference; use Resume.';

  @override
  String get thisWorkspacePaneIsAlreadyAttached =>
      'This workspace pane is already attached to tmux.';

  @override
  String get thisWorkspacePaneIsRunningA =>
      'This workspace pane is running a tmux action.';

  @override
  String get thisWorkspacePaneHasNoSaved =>
      'This workspace pane has no saved tmux session reference.';

  @override
  String get mobilePushIsntSupportedOnThis =>
      'Mobile push isn\'t supported on this platform.';

  @override
  String get thisAppBuildDoesntHaveFirebase =>
      'This app build doesn\'t have Firebase Cloud Messaging configured.';

  @override
  String get thisMembersAccessWasRevokedTo =>
      'This member\'s access was revoked; to authorize them again, create a new member invitation.';

  @override
  String get thisBrowserCantSafelyCoordinateSession =>
      'This browser can\'t safely coordinate session refresh across tabs, so the refresh token wasn\'t rotated. Update the browser to enable safe session sync.';

  @override
  String get thisBrowserHasNoDeviceKey =>
      'This browser has no device key awaiting approval. Generate a device request first.';

  @override
  String get youLeftThisTerminalShareEnter =>
      'You left this terminal share. Enter the session UUID again.';

  @override
  String get thisTerminalIsAlreadyBeingShared =>
      'This terminal is already being shared.';

  @override
  String get thisRecordIdIsReservedBy =>
      'This record ID is reserved by a deletion tombstone and can\'t be recreated. Restore it from the recycle bin, or create a record with a new ID.';

  @override
  String get thisRecordWasUpdatedOnAnother =>
      'This record was updated on another device; the conflict branch was kept.';

  @override
  String get thisRecordHasNoHistoricalVersion =>
      'This record has no historical version that can be restored.';

  @override
  String get thisRecordsHostIdentityCantBe =>
      'This record\'s Host identity can\'t be verified; saving was stopped to avoid overwriting other data.';

  @override
  String get backgroundSyncNotificationsAreTurnedOff =>
      'Background sync notifications are turned off on this device.';

  @override
  String get backgroundSyncNotificationsAreOnFor =>
      'Background sync notifications are on for this device.';

  @override
  String get thisDeviceWasRevokedSignIn =>
      'This device was revoked. Sign in again on an administrator-approved device.';

  @override
  String get thisAccountIsntAMemberOf =>
      'This account isn\'t a member of the current Vault.';

  @override
  String get thisAccountNameDoesntMatchThe =>
      'This account name doesn\'t match the signed-in account.';

  @override
  String get thisChangeCantBeMadeIn =>
      'This change can\'t be made in the account\'s current state.';

  @override
  String get theresNoMasterPasswordChangeWaiting =>
      'There\'s no master password change waiting for confirmation.';

  @override
  String get theresNoServerIdentityRecoveryWaiting =>
      'There\'s no server identity recovery waiting for confirmation.';

  @override
  String get theresNoActivePrometheusScrapeCredential =>
      'There\'s no active Prometheus scrape credential.';

  @override
  String get theParentGroupNoLongerExists2 =>
      'The parent group no longer exists. Choose another parent or Top-level group.';

  @override
  String get invalidParentGroupChooseAValid =>
      'Invalid parent group. Choose a valid group or Top-level group.';

  @override
  String thePasswordCredentialReferencedBySnippet(String name) {
    return 'The password credential referenced by snippet parameter \"$name\" doesn\'t exist or is unavailable; saving was stopped.';
  }

  @override
  String get theSnippetCommandCantBeEmpty =>
      'The snippet command can\'t be empty';

  @override
  String get theSnippetTitleCantBeEmpty => 'The snippet title can\'t be empty';

  @override
  String get userName => 'User name';

  @override
  String get theSignInSessionWasRestored =>
      'The sign-in session was restored. Enter the master password to unlock the encrypted workspace.';

  @override
  String get theSignInSessionDeviceId =>
      'The sign-in session device ID doesn\'t match the local device identity.';

  @override
  String get theSignInResponseDoesntMatch =>
      'The sign-in response doesn\'t match the current account or device.';

  @override
  String get theSignInStateChangedTry =>
      'The sign-in state changed. Try again.';

  @override
  String get theSignInStateExpiredSign =>
      'The sign-in state expired. Sign in again.';

  @override
  String get theSignedInAccountChangedSign =>
      'The signed-in account changed; sign out and sign in again with the new master password.';

  @override
  String get invalidFolderNameFormat => 'Invalid folder name format';

  @override
  String get theDestinationVaultsCurrentServerState =>
      'The destination Vault\'s current server state isn\'t verified yet; continue the migration after snapshot restore completes.';

  @override
  String get theTargetHostsSshCredentialChanged =>
      'The target host\'s SSH credential changed while preparing the connection. Reconnect.';

  @override
  String get theTargetMemberHasNoActive =>
      'The target member has no active device that can receive the new Vault key; the ownership transfer was cancelled.';

  @override
  String get theTargetAccountIsNoLonger =>
      'The target account is no longer in the current admin list. Refresh and try again.';

  @override
  String get thePrivateKeyCantBeEmpty => 'The private key can\'t be empty';

  @override
  String get theWindowSetHasASync =>
      'The window set has a sync conflict. Resolve the conflict first.';

  @override
  String get theWindowSetIsBeingSaved =>
      'The window set is being saved. Try again shortly.';

  @override
  String get port2 => 'Port';

  @override
  String get theSignedMembershipEntryHasAn =>
      'The signed membership entry has an invalid format.';

  @override
  String get theSignedMembershipListDoesntMatch =>
      'The signed membership list doesn\'t match the server ACL state; refresh and try again.';

  @override
  String get theSignedMembershipListDoesntMatch2 =>
      'The signed membership list doesn\'t match the server membership directory.';

  @override
  String get theSignedMembershipListContainsInvalid =>
      'The signed membership list contains invalid or duplicate members.';

  @override
  String get theSignedMembershipListIsMissing =>
      'The signed membership list is missing existing server members.';

  @override
  String get theAdminAuditCursorExpiredThe =>
      'The admin audit cursor expired. The instance or server generation may have changed; reload from the first page.';

  @override
  String get theAdminAuditCursorIsInvalid =>
      'The admin audit cursor is invalid or doesn\'t belong to the current admin/instance. Reload from the first page.';

  @override
  String get theTerminalVaultOrSignedIn =>
      'The terminal, Vault or signed-in device changed; sharing was cancelled.';

  @override
  String get terminalSharingStoppedBecauseAnObservers =>
      'Terminal sharing stopped because an observer\'s connection was too slow; the SSH connection can still be used.';

  @override
  String get terminalSharingHasntDisconnectedYet =>
      'Terminal sharing hasn\'t disconnected yet.';

  @override
  String get terminalSharingDisconnectedTheSshConnection =>
      'Terminal sharing disconnected. The SSH connection can still be used.';

  @override
  String get terminalSharingDisconnectedTheSshConnection2 =>
      'Terminal sharing disconnected; the SSH connection can still be used.';

  @override
  String get theTerminalSharingConnectionWasDisconnected =>
      'The terminal sharing connection was disconnected.';

  @override
  String get terminalFontSize => 'Terminal font size';

  @override
  String get terminalFontSizePreferenceSavedEncrypted =>
      'Terminal font size preference saved encrypted; it syncs to other devices through the current Vault.';

  @override
  String get theTerminalFontSizePreferenceNeeds =>
      'The terminal font size preference needs an explicit repair first.';

  @override
  String get aHostReferencedByTheTerminal =>
      'A host referenced by the terminal is no longer in the current Vault; reopen the host before saving the layout.';

  @override
  String get terminalShortcuts => 'Terminal shortcuts';

  @override
  String get terminalShortcutPreferenceSavedEncryptedIt =>
      'Terminal shortcut preference saved encrypted; it syncs to other devices through the current Vault.';

  @override
  String get theTerminalShortcutPreferenceNeedsAn =>
      'The terminal shortcut preference needs an explicit repair first.';

  @override
  String get theTerminalControlChannelDisconnectedThe =>
      'The terminal control channel disconnected; the SSH connection can still be used.';

  @override
  String get terminalColors => 'Terminal colors';

  @override
  String get terminalColorPreferenceSavedEncryptedIt =>
      'Terminal color preference saved encrypted; it syncs to other devices through the current Vault.';

  @override
  String get theTerminalColorPreferenceNeedsAn =>
      'The terminal color preference needs an explicit repair first.';

  @override
  String get maintenanceJobSubmittedRefreshTheJob =>
      'Maintenance job submitted. Refresh the job list to see its status.';

  @override
  String get automaticStatusChecksArePausedYou =>
      'Automatic status checks are paused. You can refresh the job status manually.';

  @override
  String get scheduledBackupsTurnedOff => 'Scheduled backups turned off.';

  @override
  String get scheduledBackupSettingsSaved => 'Scheduled backup settings saved.';

  @override
  String get authenticationMethod => 'Authentication method';

  @override
  String get theRecordWasClearedFromThis =>
      'The record was cleared from this device\'s active cache and a signed server proof was received; catching up the sync cursor failed. Retrying the sync fetches the cleanup marker before sending pending content.';

  @override
  String thePublicKeysForDeviceDeviceid(String deviceId) {
    return 'The public keys for device $deviceId differ between the account directory and the Vault directory.';
  }

  @override
  String theEncryptionPublicKeyOfDevice(String deviceId) {
    return 'The encryption public key of device $deviceId has an invalid length.';
  }

  @override
  String theKeyEnvelopeTargetForDevice(String deviceId) {
    return 'The key envelope target for device $deviceId is invalid or duplicated.';
  }

  @override
  String theSigningPublicKeyOfDevice(String deviceId) {
    return 'The signing public key of device $deviceId has an invalid length.';
  }

  @override
  String get deviceRevoked2 => 'Device revoked.';

  @override
  String get deviceAddedGiveTheApprovalResult =>
      'Device added. Give the approval result to the new device and import it there.';

  @override
  String get theVaultKeyEnvelopeInThe =>
      'The Vault key envelope in the device approval has an invalid format.';

  @override
  String get theKeyEnvelopeContextInThe =>
      'The key envelope context in the device approval is invalid.';

  @override
  String get theDeviceApprovalContainsDuplicateVault =>
      'The device approval contains duplicate Vault key envelopes.';

  @override
  String get theDeviceApprovalFileHasAn =>
      'The device approval file has an invalid format.';

  @override
  String get theDeviceApprovalFilesAccountOr =>
      'The device approval file\'s account or structure is invalid.';

  @override
  String get theDeviceApprovalCertificateFieldsAre =>
      'The device approval certificate fields are missing.';

  @override
  String get theDeviceRequestIsMalformedOr =>
      'The device request is malformed or belongs to a different account.';

  @override
  String get thisAccountIsAlreadyAnActive =>
      'This account is already an active member of the Vault; use the authorized-device approval flow.';

  @override
  String get thisInvitationIsNoLongerWaiting =>
      'This invitation is no longer waiting to be accepted. Refresh and try again.';

  @override
  String get closeASessionTabFirst => 'Close a session tab first.';

  @override
  String get joinTheHostsTerminalShareFirst =>
      'Join the host\'s terminal share first.';

  @override
  String get openThisAccountsSessionListFirst =>
      'Open this account\'s session list first.';

  @override
  String get openAtLeastOneTerminalTab =>
      'Open at least one terminal tab first.';

  @override
  String get signInAndUnlockTheAccount =>
      'Sign in and unlock the account on a trusted device first.';

  @override
  String get signInFirst => 'Sign in first.';

  @override
  String get signInBeforeChangingMfaSettings =>
      'Sign in before changing MFA settings.';

  @override
  String get signInBeforeViewingMfaSettings =>
      'Sign in before viewing MFA settings.';

  @override
  String get signInBeforeManagingThisDevices =>
      'Sign in before managing this device\'s background sync notifications.';

  @override
  String get signInAndUnlockTheSync =>
      'Sign in and unlock the sync account first.';

  @override
  String get signInAndUnlockTheTarget =>
      'Sign in and unlock the target Vault first.';

  @override
  String get signInAndUnlockTheAccount2 =>
      'Sign in and unlock the account first.';

  @override
  String get signInToThisAccountAnd =>
      'Sign in to this account and unlock the current device first.';

  @override
  String get resolveThePreferenceReadErrorFirst =>
      'Resolve the preference read error first.';

  @override
  String get unlockTheVaultFirst => 'Unlock the Vault first';

  @override
  String get unlockTheVaultFirst2 => 'Unlock the Vault first.';

  @override
  String get unlockAVaultBeforeSharingA =>
      'Unlock a Vault before sharing a terminal.';

  @override
  String get unlockTheWorkspaceFirst => 'Unlock the workspace first.';

  @override
  String get unlockTheCurrentVaultBeforeVerifying =>
      'Unlock the current Vault before verifying SSH host keys.';

  @override
  String get unlockTheWorkspaceThatContainsThe =>
      'Unlock the workspace that contains the current host first.';

  @override
  String get unlockTheVaultThatOwnsThis =>
      'Unlock the Vault that owns this shared session first.';

  @override
  String get unlockTheAccountBeforeExportingA =>
      'Unlock the account before exporting a share request.';

  @override
  String get connectToAnSshHostFirst => 'Connect to an SSH host first';

  @override
  String get connectSshBeforeStartingTerminalSharing =>
      'Connect SSH before starting terminal sharing.';

  @override
  String get connectToTheServerFirst => 'Connect to the server first.';

  @override
  String get connectTheHostForThisWorkspace =>
      'Connect the host for this workspace pane first.';

  @override
  String get chooseAVaultFirst => 'Choose a Vault first.';

  @override
  String get chooseAndUnlockAVaultFirst => 'Choose and unlock a Vault first.';

  @override
  String get configureTheServerAddressFirst =>
      'Configure the server address first';

  @override
  String get retryThePendingMasterPasswordChange =>
      'Retry the pending master password change before deleting the account.';

  @override
  String get tooManyRequestsTryAgainLater =>
      'Too many requests. Try again later.';

  @override
  String get waitForTheCurrentSyncOr =>
      'Wait for the current sync or archive operation to finish.';

  @override
  String get enterAVaultName => 'Enter a Vault name';

  @override
  String get enterTheBootstrapToken => 'Enter the bootstrap token';

  @override
  String get enterAGroupName => 'Enter a group name.';

  @override
  String get enterTheCurrentMasterPassword =>
      'Enter the current master password.';

  @override
  String get enterTheCurrentAccountNameAnd =>
      'Enter the current account name and master password to verify again.';

  @override
  String get enterANameForTheNew => 'Enter a name for the new Vault.';

  @override
  String get enterAValidTerminalSharingSession =>
      'Enter a valid terminal sharing session UUID.';

  @override
  String get enterAValidAccountNameAnd =>
      'Enter a valid account name and a duration of 1 to 30 days.';

  @override
  String get enterTheServerAddress => 'Enter the server address';

  @override
  String get enterAnMfaCodeValidFor =>
      'Enter an MFA code valid for this account.';

  @override
  String get enterTheAccountInvitationTokenIssued =>
      'Enter the account invitation token issued by the administrator';

  @override
  String get enterTheAccountNameAndMaster =>
      'Enter the account name and master password.';

  @override
  String get enterTheAccountPassword => 'Enter the account password.';

  @override
  String get enterTheAccountEmailUserName =>
      'Enter the account email/user name';

  @override
  String get enterTheInvitationToken => 'Enter the invitation token.';

  @override
  String get choose1To8ActiveVault => 'Choose 1 to 8 active Vault devices.';

  @override
  String chooseALabelPreferenceFromThe(String label) {
    return 'Choose a $label preference from the current conflict list.';
  }

  @override
  String get theAccountIsStillTheOwner =>
      'The account is still the Owner of a shared Vault with other members. The server won\'t transfer ownership or delete other accounts\' data automatically; remove the other members, then try again.';

  @override
  String get theAccountSessionChangedSignIn =>
      'The account session changed. Sign in again, then unlock.';

  @override
  String get theAccountDeletionGracePeriodHas =>
      'The account deletion grace period has ended; it can\'t be cancelled.';

  @override
  String theAccountDeletionWasCancelledThe(String valueValue) {
    return 'The account deletion was cancelled. The server won\'t restore old sessions; enter your password to sign in again.$valueValue';
  }

  @override
  String get theAccountResponseDoesntMatchThe =>
      'The account response doesn\'t match the current session.';

  @override
  String get accountSecuritySettingsAreBeingProcessed =>
      'Account security settings are being processed. Try again later.';

  @override
  String get invalidAccountKeyLength => 'Invalid account key length.';

  @override
  String get invalidAccountKeyLengthTheMaster =>
      'Invalid account key length; the master password change was stopped.';

  @override
  String get theAccountAlreadyHasAPending =>
      'The account already has a pending deletion; cancel it from the account recovery option on the sign-in page.';

  @override
  String theAccountEnteredItsDeletionGrace(
    String deadline,
    String valueValue,
    String valueValue2,
  ) {
    return 'The account entered its deletion grace period. Server purge_after: $deadline. The current session and this device\'s unlock key were cleared; during the grace period you can cancel on the sign-in page, then you must sign in again.$valueValue$valueValue2';
  }

  @override
  String get accountRecoverySettingsAreBeingProcessed =>
      'Account recovery settings are being processed.';

  @override
  String get theAccountStateJustChangedSign =>
      'The account state just changed. Sign in again to view it.';

  @override
  String get anAccountStateActionIsIn =>
      'An account state action is in progress. Try again later.';

  @override
  String get theInputControlAuthorizationOrVault =>
      'The input control authorization or Vault state changed; joining was cancelled.';

  @override
  String get theInputControlConnectionWasDisconnected =>
      'The input control connection was disconnected.';

  @override
  String get theFingerprintYouEnteredDoesntMatch =>
      'The fingerprint you entered doesn\'t match the candidate instance signing key.';

  @override
  String get invalidMigrationDestinationVaultId =>
      'Invalid migration destination Vault ID.';

  @override
  String get theMigrationDestinationVaultCouldntBe =>
      'The migration destination Vault couldn\'t be verified as a writable Owner Vault for this device.';

  @override
  String get theMigrationDestinationVaultCouldntBe2 =>
      'The migration destination Vault couldn\'t be opened; the local migration journal can still be resumed.';

  @override
  String get theMigrationDestinationVaultIsMissing =>
      'The migration destination Vault is missing its initial signed membership chain.';

  @override
  String get invalidMigrationRecordId => 'Invalid migration record ID.';

  @override
  String get theRestoreJobFinishedButThe =>
      'The restore job finished, but the isolated copy state isn\'t verified and can\'t be managed from here.';

  @override
  String get remoteDesktopRequiresASignIn =>
      'Remote desktop requires a sign-in gateway.';

  @override
  String get invalidRemoteFileNameFormat => 'Invalid remote file name format';

  @override
  String get invalidRemoteFilePathFormat => 'Invalid remote file path format';

  @override
  String get notificationPermissionWasntGrantedBackgroundSync =>
      'Notification permission wasn\'t granted; background sync notifications weren\'t registered.';

  @override
  String get invitationCreatedGiveTheOneTime =>
      'Invitation created. Give the one-time token to the target account over a trusted channel.';

  @override
  String get theInvitationWasAcceptedButThis =>
      'The invitation was accepted, but this device couldn\'t switch to the invited Vault. Select that Vault again and sync.';

  @override
  String get theInvitationWasAcceptedButThis2 =>
      'The invitation was accepted, but this device didn\'t receive a Vault key envelope it can decrypt. Ask the inviter to check the device public key.';

  @override
  String get theInvitationRoleCanOnlyBe =>
      'The invitation role can only be editor or viewer.';

  @override
  String get someLocalRecordsCouldntBeVerified3 =>
      'Some local records couldn\'t be verified, so the host\'s group, credential or Jump Host references can\'t be checked safely. Repair or resync the Vault first.';

  @override
  String get someLocalRecordsCouldntBeVerified4 =>
      'Some local records couldn\'t be verified, so credential references can\'t be checked safely. Repair or resync the Vault first.';

  @override
  String get someLocalRecordsCouldntBeVerified =>
      'Some local records couldn\'t be verified, so group references can\'t be checked safely. Repair or resync the Vault first.';

  @override
  String get someLocalRecordsCouldntBeVerified2 =>
      'Some local records couldn\'t be verified, so the snippet\'s SSH credential references can\'t be checked safely. Repair or resync the Vault first.';

  @override
  String get theQuotaMustBeBetween1 =>
      'The quota must be between 1 byte and 1 TiB.';

  @override
  String get theReVerifiedAccountMustMatch =>
      'The re-verified account must match the currently signed-in account.';

  @override
  String get theIsolatedCopyIsntVerifiedYet =>
      'The isolated copy isn\'t verified yet. The server verifies ownership and integrity before cleanup.';

  @override
  String get theIsolatedCopyWasDiscardedYou =>
      'The isolated copy was discarded. You can prepare it again from the source archive.';

  @override
  String get isolatedCopyCleanupHasntFinishedYou =>
      'Isolated copy cleanup hasn\'t finished. You can safely retry the cleanup.';

  @override
  String get isolatedCopyCleanupDidntFinishYou =>
      'Isolated copy cleanup didn\'t finish; you can safely retry.';

  @override
  String get theIsolatedRestoreCopyPreparationJob3 =>
      'The isolated restore copy preparation job was interrupted. Live data wasn\'t changed.';

  @override
  String get theIsolatedRestoreCopyPreparationJob =>
      'The isolated restore copy preparation job was accepted. It won\'t activate the copy or replace live data.';

  @override
  String get theIsolatedRestoreCopyPreparationJob2 =>
      'The isolated restore copy preparation job finished. Live data wasn\'t changed.';

  @override
  String get theIsolatedRestoreCopyWasDiscarded =>
      'The isolated restore copy was discarded. The source archive and live data weren\'t changed.';

  @override
  String get theIsolatedRestoreCopyIsReady =>
      'The isolated restore copy is ready. Live data wasn\'t changed.';

  @override
  String get theIsolatedRestoreCopyIsReady2 =>
      'The isolated restore copy is ready, but a job status update was interrupted. Live data wasn\'t changed.';

  @override
  String get theIsolatedRestoreCopyIsInvalid =>
      'The isolated restore copy is invalid. Refresh the job list and try again.';

  @override
  String get theIsolatedRestoreCopyFailedVerification =>
      'The isolated restore copy failed verification; the server didn\'t delete any unknown files. Contact the instance operator.';

  @override
  String get theIsolatedRestoreCopyStateChanged =>
      'The isolated restore copy state changed. Refresh the job list and try again.';

  @override
  String get theDefaultSshCredentialNoLonger =>
      'The default SSH credential no longer exists. Choose a valid credential or clear the default.';

  @override
  String get defaultWorkspace => 'Default workspace';

  @override
  String get defaultWorkspacePreferenceSavedEncryptedIt =>
      'Default workspace preference saved encrypted; it syncs to other devices through the current Vault.';

  @override
  String get theDefaultWorkspacePreferenceNeedsAn =>
      'The default workspace preference needs an explicit repair first.';

  @override
  String restoreDeadlineFormat(String format) {
    return '(restore deadline $format)';
  }

  @override
  String get unsupportedArgon2idParameters =>
      'Unsupported Argon2id parameters.';

  @override
  String get notASupportedAtermiusEncryptedArchive =>
      'Not a supported Atermius encrypted archive.';

  @override
  String get anEncryptedArchiveChunkIsTruncated =>
      'An encrypted archive chunk is truncated.';

  @override
  String get theEncryptedArchiveExceedsTheFile =>
      'The encrypted archive exceeds the file size limit.';

  @override
  String get anArchiveObjectIsEmptyOr =>
      'An archive object is empty or exceeds the 32 MiB limit.';

  @override
  String get invalidArchiveArgon2idSaltLength =>
      'Invalid archive Argon2id salt length.';

  @override
  String get theArchiveContentExceedsTheSize =>
      'The archive content exceeds the size that can be processed.';

  @override
  String get theArchiveChunkLengthDoesntMatch =>
      'The archive chunk length doesn\'t match.';

  @override
  String get theArchiveHeaderIsntCanonicalJson =>
      'The archive header isn\'t canonical JSON.';

  @override
  String get theArchiveHeaderHasUnknownOr =>
      'The archive header has unknown or incomplete fields.';

  @override
  String get theArchiveHeaderExceedsTheSize =>
      'The archive header exceeds the size limit.';

  @override
  String get invalidArchiveHeaderLength => 'Invalid archive header length.';

  @override
  String get wrongArchivePasswordOrTheArchive =>
      'Wrong archive password, or the archive content failed integrity verification.';

  @override
  String get theTotalArchiveObjectDataExceeds =>
      'The total archive object data exceeds the limit.';

  @override
  String get theNumberOfArchiveObjectsExceeds =>
      'The number of archive objects exceeds the limit.';

  @override
  String get theArchiveHasTrailingDataOr =>
      'The archive has trailing data or incomplete content.';

  @override
  String get theArchiveFileSizeIsInvalid =>
      'The archive file size is invalid or exceeds the limit.';

  @override
  String get theArchiveFileIsTruncated => 'The archive file is truncated.';

  @override
  String get invalidArchivePlaintextSize => 'Invalid archive plaintext size.';

  @override
  String get invalidArchivePlaintextType => 'Invalid archive plaintext type.';

  @override
  String get theArchivePlaintextExceedsTheFile =>
      'The archive plaintext exceeds the file size limit.';

  @override
  String get theArchiveManifestIsntCanonicalJson =>
      'The archive manifest isn\'t canonical JSON.';

  @override
  String get theArchiveManifestExceedsThe16 =>
      'The archive manifest exceeds the 16 MiB limit.';

  @override
  String get invalidArchiveManifestLength => 'Invalid archive manifest length.';

  @override
  String get theArchiveVersionServerSpaceOr =>
      'The archive version, server space or Vault doesn\'t match the current target. Cross-space and cross-Vault imports aren\'t supported yet.';

  @override
  String get theArchiveLengthOrChunkParameters =>
      'The archive length or chunk parameters exceed resource limits.';

  @override
  String get theSeparateArchivePasswordMustBe =>
      'The separate archive password must be at least 12 UTF-8 bytes.';

  @override
  String get invalidDecryptedArchiveChunkLength =>
      'Invalid decrypted archive chunk length.';

  @override
  String get notASupportedLocalEncryptedArchive =>
      'Not a supported local encrypted archive.';

  @override
  String get aLocalEncryptedArchiveChunkIs =>
      'A local encrypted archive chunk is truncated.';

  @override
  String get theLocalEncryptedArchiveExceedsThe =>
      'The local encrypted archive exceeds the file size limit.';

  @override
  String get unsupportedLocalArchiveArgon2idParameters =>
      'Unsupported local archive Argon2id parameters.';

  @override
  String get invalidSshTrustRecordMetadataIn =>
      'Invalid SSH trust record metadata in the local archive.';

  @override
  String get invalidOrderOrUniquenessOfSsh =>
      'Invalid order or uniqueness of SSH trust records in the local archive.';

  @override
  String get theNumberOfSshTrustRecords =>
      'The number of SSH trust records in the local archive exceeds the limit.';

  @override
  String get invalidSshTrustRecordInThe =>
      'Invalid SSH trust record in the local archive.';

  @override
  String get invalidBase64urlEncodingInTheLocal =>
      'Invalid base64url encoding in the local archive.';

  @override
  String get invalidLocalArchiveSaltLength =>
      'Invalid local archive salt length.';

  @override
  String get theLocalArchiveContentIsntCanonical =>
      'The local archive content isn\'t canonical JSON.';

  @override
  String get theLocalArchiveContentIsEmpty =>
      'The local archive content is empty or exceeds the size limit.';

  @override
  String get unsupportedLocalArchiveContentFormatOr =>
      'Unsupported local archive content format or version.';

  @override
  String get theLocalArchiveChunkLengthDoesnt =>
      'The local archive chunk length doesn\'t match.';

  @override
  String get theLocalArchivePassphraseMustBe =>
      'The local archive passphrase must be 12 to 1024 UTF-8 bytes.';

  @override
  String get theLocalArchiveContainsDuplicateRecord =>
      'The local archive contains duplicate record IDs.';

  @override
  String get theLocalArchiveSizeIsInvalid =>
      'The local archive size is invalid or exceeds the limit.';

  @override
  String get theLocalArchiveHeaderIsntCanonical =>
      'The local archive header isn\'t canonical JSON.';

  @override
  String get theLocalArchiveHeaderHasUnknown =>
      'The local archive header has unknown or incomplete fields.';

  @override
  String get theLocalArchiveHeaderExceedsThe =>
      'The local archive header exceeds the size limit.';

  @override
  String get invalidLocalArchiveHeaderLength =>
      'Invalid local archive header length.';

  @override
  String get wrongLocalArchivePasswordOrThe =>
      'Wrong local archive password, or the archive failed integrity verification.';

  @override
  String get theLocalArchiveHasTrailingData =>
      'The local archive has trailing data or incomplete content.';

  @override
  String get theLocalArchiveFileIsTruncated =>
      'The local archive file is truncated.';

  @override
  String get theLocalArchivePlaintextIsEmpty =>
      'The local archive plaintext is empty or exceeds the limit.';

  @override
  String get theLocalArchivePlaintextExceedsThe =>
      'The local archive plaintext exceeds the size limit.';

  @override
  String get unsupportedLocalArchiveFormatOrVersion =>
      'Unsupported local archive format or version.';

  @override
  String get invalidDecryptedChunkLengthInThe =>
      'Invalid decrypted chunk length in the local archive.';

  @override
  String get theLocalArchiveRecordListExceeds =>
      'The local archive record list exceeds the limit.';

  @override
  String get invalidRecordOrderOrUniquenessIn =>
      'Invalid record order or uniqueness in the local archive.';

  @override
  String get theNumberOfRecordsInThe =>
      'The number of records in the local archive exceeds the limit.';

  @override
  String get invalidLocalArchiveRecord => 'Invalid local archive record.';

  @override
  String get theLocalArchiveLengthOrChunk =>
      'The local archive length or chunk parameters exceed the limits.';

  @override
  String get theVaultMembershipChainIsMissing =>
      'The Vault membership chain is missing or exceeds the limit.';

  @override
  String get aDeviceSequenceFloorIsOut =>
      'A device sequence floor is out of the safe range.';

  @override
  String get invalidDeviceSequenceFloorsFormat =>
      'Invalid device sequence floors format.';

  @override
  String get theEpochKeySha256Doesnt =>
      'The epoch key SHA-256 doesn\'t match the binary block.';

  @override
  String get theEpochKeyDescriptorsDontMatch =>
      'The epoch key descriptors don\'t match the key envelope set.';

  @override
  String get invalidDeviceSignatureOnTheEpoch =>
      'Invalid device signature on the epoch key.';

  @override
  String get theEpochKeyProofSignerIsnt =>
      'The epoch key proof signer isn\'t a Vault member in that version.';

  @override
  String epochEpochMapsToInconsistentVault(int epoch) {
    return 'Epoch $epoch maps to inconsistent Vault keys.';
  }

  @override
  String get theUnsealedKeyEnvelopeDoesntMatch =>
      'The unsealed key envelope doesn\'t match the local epoch key.';

  @override
  String get invalidMembershipEncryptionFingerprint =>
      'Invalid membership encryption fingerprint.';

  @override
  String get invalidMembershipMemberRoleStateId =>
      'Invalid membership member role/state/id.';

  @override
  String get theMembershipSignerWasntAnActive =>
      'The membership signer wasn\'t an active Owner in the corresponding signed version.';

  @override
  String get objectRefsMustBeUniqueLowercase =>
      'object_refs must be unique lowercase UUIDs in strictly ascending order.';

  @override
  String get objectRefsIsntAnArrayOr =>
      'object_refs isn\'t an array or exceeds 1024 entries.';

  @override
  String get theSnapshotCurrentHeadIsInconsistent =>
      'The snapshot current head is inconsistent with the same pinned history watermark.';

  @override
  String get theSnapshotHeadCommitSeqDoesnt =>
      'The snapshot head commit_seq doesn\'t match the pinned history watermark.';

  @override
  String get theSnapshotHeadCommitSeqExceeds =>
      'The snapshot head commit_seq exceeds the pinned snapshot watermark.';

  @override
  String get aSnapshotHeadIsMissingFields =>
      'A snapshot head is missing fields or duplicated.';

  @override
  String get theSnapshotHeadSetDoesntCover =>
      'The snapshot head set doesn\'t cover all history records.';

  @override
  String fieldMustBeADecimalString(String field) {
    return '$field must be a decimal string.';
  }

  @override
  String labelMustBeAJsonObject(String label) {
    return '$label must be a JSON object.';
  }

  @override
  String uploadedObjectObjectidFailedReadBack(String objectId) {
    return 'Uploaded object $objectId failed read-back verification.';
  }

  @override
  String get revisionCommitSeqIsntMonotonicOr =>
      'Revision commit_seq isn\'t monotonic or exceeds the snapshot watermark.';

  @override
  String get theRevisionHistoryCursorIsInvalid =>
      'The revision history cursor is invalid or repeated.';

  @override
  String get theRevisionHistoryExceedsTheArchive =>
      'The revision history exceeds the archive entry limit.';

  @override
  String get theServerGenerationDiffersBetweenRevision =>
      'The server generation differs between revision and conflict history pages.';

  @override
  String get conflictSeqIsntMonotonicOrExceeds =>
      'conflict_seq isn\'t monotonic or exceeds the snapshot watermark.';

  @override
  String get aConflictBranchReferencesABase =>
      'A conflict branch references a base revision outside the snapshot.';

  @override
  String get theConflictHistoryCursorIsInvalid =>
      'The conflict history cursor is invalid or repeated.';

  @override
  String get theConflictHistoryExceedsTheArchive =>
      'The conflict history exceeds the archive entry limit.';

  @override
  String get aConflictResolutionReferencesARevision =>
      'A conflict resolution references a revision outside the snapshot.';

  @override
  String get theConflictResolutionStateAndResolution =>
      'The conflict resolution state and resolution_seq don\'t match.';

  @override
  String get encryptedArchiveFile => 'Encrypted archive file';

  @override
  String get theHistorySnapshotContainsADuplicate =>
      'The history snapshot contains a duplicate conflict_id.';

  @override
  String get theHistorySnapshotContainsADuplicate2 =>
      'The history snapshot contains a duplicate revision_id.';

  @override
  String historicalSigningDeviceIdIsntIn(String id) {
    return 'Historical signing device $id isn\'t in the verifiable Vault directory.';
  }

  @override
  String get historyEntriesExceedTheArchiveResource =>
      'History entries exceed the archive resource limit.';

  @override
  String get aHistoryPageDoesntMatchThe =>
      'A history page doesn\'t match the pinned Vault snapshot context.';

  @override
  String get theSameDeviceIdHasConflicting =>
      'The same device ID has conflicting public key directory entries.';

  @override
  String get pinningTheServerHistorySnapshot =>
      'Pinning the server history snapshot';

  @override
  String sha256OfObjectIdDoesnt(String id) {
    return 'SHA-256 of object $id doesn\'t match its content digest.';
  }

  @override
  String objectIdIsReferencedByVerified(String id) {
    return 'Object $id is referenced by verified records, but neither the server nor the local archive cache has its content; an incomplete archive won\'t be created.';
  }

  @override
  String get unsupportedArchiveBinaryBlockKind =>
      'Unsupported archive binary block kind.';

  @override
  String get archiveBinaryBlockOffsetsHaveGaps =>
      'Archive binary block offsets have gaps, overlaps or exceed limits.';

  @override
  String get tooManyArchiveBinaryBlocks => 'Too many archive binary blocks.';

  @override
  String get theArchiveBinaryBlocksDontCover =>
      'The archive binary blocks don\'t cover the full payload.';

  @override
  String get duplicateArchiveBinaryObjectId =>
      'Duplicate archive binary object_id.';

  @override
  String get invalidArchiveConflictResolutionOutboxLink =>
      'Invalid archive conflict resolution/outbox link.';

  @override
  String get invalidArchiveConflictOrderWatermarkOr =>
      'Invalid archive conflict order, watermark or uniqueness.';

  @override
  String get theArchiveCreatedAtIsntAn =>
      'The archive created_at isn\'t an RFC3339 time.';

  @override
  String get invalidArchiveEpochKeyBinaryBlock =>
      'Invalid archive epoch key binary block.';

  @override
  String get theArchiveEpochKeyBlockDoesnt =>
      'The archive epoch key block doesn\'t match the signed descriptor.';

  @override
  String archiveEpochKeyKeyDoesntMatch(String key) {
    return 'Archive epoch key $key doesn\'t match this device\'s key.';
  }

  @override
  String get theArchiveGraveyardCountDoesntMatch =>
      'The archive graveyard count doesn\'t match the snapshot tombstones.';

  @override
  String get theArchiveGraveyardDoesntMatchThe =>
      'The archive graveyard doesn\'t match the verified tombstones.';

  @override
  String get invalidArchiveKeyEnvelopeContextOr =>
      'Invalid archive key envelope context or uniqueness.';

  @override
  String get invalidArchiveKeyEnvelopeSealingFormat =>
      'Invalid archive key envelope sealing format.';

  @override
  String get invalidArchiveKeyEnvelopeSignature =>
      'Invalid archive key envelope signature.';

  @override
  String get invalidArchiveLocalPendingSchema =>
      'Invalid archive local_pending schema.';

  @override
  String get theArchiveMembershipDoesntIncludeThe =>
      'The archive membership doesn\'t include the current account.';

  @override
  String get theArchiveMembershipIsntAValid =>
      'The archive membership isn\'t a valid prefix of the current Vault chain.';

  @override
  String get theArchiveMembershipIsNewerThan =>
      'The archive membership is newer than the current Vault chain.';

  @override
  String get theArchiveObjectBlockSetDiffers =>
      'The archive object block set differs from the verified object_refs.';

  @override
  String get theArchiveOutboxBaseEnvelopeIs =>
      'The archive outbox base envelope is missing its base revision.';

  @override
  String get anArchiveOutboxDeviceSeqIs =>
      'An archive outbox device_seq is out of the safe integer range.';

  @override
  String get invalidArchiveOutboxState => 'Invalid archive outbox state.';

  @override
  String get anArchiveRevisionIsDuplicatedOr =>
      'An archive revision is duplicated or its base chain isn\'t continuous.';

  @override
  String get anArchiveSignedEnvelopeIsMissing =>
      'An archive signed envelope is missing its header.';

  @override
  String get invalidArchiveSnapshotCursorGeneration =>
      'Invalid archive snapshot cursor/generation.';

  @override
  String get anArchiveTombstoneDoesntMatchThe =>
      'An archive tombstone doesn\'t match the latest history record.';

  @override
  String get unsupportedArchiveVaultRole => 'Unsupported archive vault_role.';

  @override
  String get invalidArchiveRevisionOrderOrWatermark =>
      'Invalid archive revision order or watermark.';

  @override
  String get theArchiveConflictBaseRevisionDoesnt =>
      'The archive conflict base revision doesn\'t exist.';

  @override
  String get anArchiveConflictEnvelopeHasNo =>
      'An archive conflict envelope has no signed header.';

  @override
  String get anArchiveConflictResolutionPointsTo =>
      'An archive conflict resolution points to an invalid target.';

  @override
  String get duplicateExternalDeviceOutboxConflictId =>
      'Duplicate external-device outbox conflict ID in the archive.';

  @override
  String archiveFieldKeyIsMissingOr(String key) {
    return 'Archive field $key is missing or invalid.';
  }

  @override
  String get invalidArchiveFieldType => 'Invalid archive field type.';

  @override
  String get anArchiveObjectIdLengthOr =>
      'An archive object ID, length or SHA-256 failed pre-apply verification; nothing was uploaded or written to the local database.';

  @override
  String sha256MismatchForArchiveObject(String objectId) {
    return 'SHA-256 mismatch for archive object $objectId.';
  }

  @override
  String get theNumberOfEncryptedObjectsReferenced =>
      'The number of encrypted objects referenced by the archive exceeds the limit.';

  @override
  String get theArchiveMustBeBoundTo =>
      'The archive must be bound to one exporting device\'s key envelope set.';

  @override
  String get unsupportedArchiveLocalConflictKindState =>
      'Unsupported archive local conflict kind/state.';

  @override
  String get invalidLinkBetweenArchiveLocalConflict =>
      'Invalid link between archive local conflict resolution state and outbox.';

  @override
  String get duplicateArchiveLocalConflictId =>
      'Duplicate archive local conflict_id.';

  @override
  String get theArchivesLocalOutboxBaseRevision =>
      'The archive\'s local outbox base_revision can\'t be verified.';

  @override
  String get theArchivesLocalOutboxMetadataIs =>
      'The archive\'s local outbox metadata is invalid or duplicated.';

  @override
  String get theArchiveFormatFieldsAreInvalid =>
      'The archive format fields are invalid or differ from the current service space/Vault.';

  @override
  String get anArchiveRecordDeviceSeqIs =>
      'An archive record device_seq is out of the safe range.';

  @override
  String get anArchiveDevicePublicKeyIs =>
      'An archive device public key is invalid or duplicated.';

  @override
  String archiveDeviceDirectoryKeyDoesntMatch(String key) {
    return 'Archive device directory $key doesn\'t match the current Vault directory.';
  }

  @override
  String get invalidArchiveDeviceDirectoryOrMembership =>
      'Invalid archive device directory or membership chain format.';

  @override
  String get theCurrentVaultMembershipChainIs =>
      'The current Vault membership chain is invalid.';

  @override
  String get theCurrentVaultDeviceIsntUnlocked =>
      'The current Vault/device isn\'t unlocked, so an archive can\'t be created.';

  @override
  String get thisDeviceHasNoVaultEpoch =>
      'This device has no Vault epoch key to export.';

  @override
  String get theCurrentDevicesKeyEnvelopeSource =>
      'The current device\'s key envelope source or context couldn\'t be verified.';

  @override
  String get theCurrentAccountIsntInThe =>
      'The current account isn\'t in the latest signed membership.';

  @override
  String get theSnapshotExceedsTheArchiveCapacity =>
      'The snapshot exceeds the archive capacity (100,000 records); no archive was created.';

  @override
  String get collectingAndCheckingEncryptedObjects =>
      'Collecting and checking encrypted objects';

  @override
  String get theTombstoneGraveyardCouldntBeRebuilt =>
      'The tombstone graveyard couldn\'t be rebuilt from the pinned history.';

  @override
  String get theLastSnapshotPageStillContains =>
      'The last snapshot page still contains a continuation cursor.';

  @override
  String get duplicateServerKeyEnvelopeContext =>
      'Duplicate server key envelope context.';

  @override
  String serverObjectObjectidConflictsWithThe(String objectId) {
    return 'Server object $objectId conflicts with the archive content; the immutable object won\'t be overwritten.';
  }

  @override
  String get theServerSnapshotItemCountDoesnt =>
      'The server snapshot item_count doesn\'t match the paged manifest count.';

  @override
  String get theServerSnapshotItemCountDoesnt2 =>
      'The server snapshot item_count doesn\'t match the full manifest count.';

  @override
  String get theServerSnapshotItemCountIs =>
      'The server snapshot item_count is inconsistent between pages.';

  @override
  String get invalidServerSnapshotItemCount =>
      'Invalid server snapshot item_count.';

  @override
  String get theServerSnapshotItemCountIs2 =>
      'The server snapshot item_count is invalid or changed.';

  @override
  String get theServerSnapshotPageManifestHas =>
      'The server snapshot page manifest has too many entries.';

  @override
  String get invalidServerSnapshotPageBoundaryOr =>
      'Invalid server snapshot page boundary or manifest format.';

  @override
  String get theServerSnapshotContainsInvalidRecords =>
      'The server snapshot contains invalid records.';

  @override
  String get theServerSnapshotReturnedAnEmpty =>
      'The server snapshot returned an empty page before completing.';

  @override
  String get theServerSnapshotManifestExceedsThe =>
      'The server snapshot manifest exceeds the client\'s 64 MiB limit.';

  @override
  String get theServerSnapshotContinuationCursorIs =>
      'The server snapshot continuation cursor is empty, repeated or invalid.';

  @override
  String get aLocalConflictKindStateIs =>
      'A local conflict kind/state is invalid or duplicated.';

  @override
  String get invalidLinkToTheLocalConflict =>
      'Invalid link to the local conflict resolution state.';

  @override
  String get invalidLocalConflictResolutionOutboxLink =>
      'Invalid local conflict resolution/outbox link.';

  @override
  String invalidLocalEpochKeyIdentifierValuevalue(String valueValue) {
    return 'Invalid local epoch key identifier: $valueValue';
  }

  @override
  String get theLocalOutboxBaseEnvelopeDoesnt =>
      'The local outbox base envelope doesn\'t match the revision.';

  @override
  String get theLocalOutboxBaseRevisionCant =>
      'The local outbox base_revision can\'t be verified for archiving.';

  @override
  String get aLocalOutboxRevisionIdIs =>
      'A local outbox revision_id is missing or duplicated.';

  @override
  String get theLocalOutboxMetadataDoesntMatch =>
      'The local outbox metadata doesn\'t match the signature header.';

  @override
  String get theLocalOutboxContainsADuplicate =>
      'The local outbox contains a duplicate op_id.';

  @override
  String get theLocalOutboxStateCantSafely =>
      'The local outbox state can\'t safely round-trip through an archive.';

  @override
  String get localOutboxConflictsExceedTheArchive =>
      'Local outbox/conflicts exceed the archive entry limit.';

  @override
  String get thisDevicesEpochKeysDontFully =>
      'This device\'s epoch keys don\'t fully match the key envelope set.';

  @override
  String get thisDevicesPublicKeyDoesntMatch =>
      'This device\'s public key doesn\'t match the server Vault directory, so it can\'t export.';

  @override
  String get thisDevicesIdentityCouldntBeMatched =>
      'This device\'s identity couldn\'t be matched to the current Vault device directory.';

  @override
  String get checkingArchiveConflictBranchFields =>
      'Checking archive conflict branch fields';

  @override
  String get checkingArchiveConflictFields =>
      'Checking archive conflict fields';

  @override
  String get checkingArchiveManifestFieldTypes =>
      'Checking archive manifest field types';

  @override
  String get checkingArchiveManifestEntryLimits =>
      'Checking archive manifest entry limits';

  @override
  String get checkingArchiveManifestIdentityAndRole =>
      'Checking archive manifest identity and role';

  @override
  String get checkingArchiveManifestTopLevelFields =>
      'Checking archive manifest top-level fields';

  @override
  String get checkingArchiveMembershipFields =>
      'Checking archive membership fields';

  @override
  String get checkingArchiveOutboxFields => 'Checking archive outbox fields';

  @override
  String get checkingArchiveRevisionFields =>
      'Checking archive revision fields';

  @override
  String get checkingArchiveSnapshotHeadFields =>
      'Checking archive snapshot head fields';

  @override
  String get checkingArchiveSnapshotSchema =>
      'Checking archive snapshot schema';

  @override
  String get checkingArchiveDeviceDirectoryFields =>
      'Checking archive device directory fields';

  @override
  String get theSignedObjectRefsDontMatch =>
      'The signed object_refs don\'t match the encrypted plaintext manifest.';

  @override
  String get decryptingTheArchiveContainer =>
      'Decrypting the archive container';

  @override
  String get aRecordEnvelopeIsMissingIts =>
      'A record envelope is missing its signature header.';

  @override
  String get theRecordSignerEpochDoesntBelong =>
      'The record signer/epoch doesn\'t belong to that membership version.';

  @override
  String theBaseRevisionChainForRecord(String recordId) {
    return 'The base_revision chain for record $recordId isn\'t continuous.';
  }

  @override
  String get trustCouldntBeEstablishedForThe =>
      'Trust couldn\'t be established for the record\'s signer or key epoch.';

  @override
  String get theRecordSignatureHeaderDoesntMatch =>
      'The record signature header doesn\'t match the archive index.';

  @override
  String get invalidDeviceSigningKeyLength =>
      'Invalid device signing key length.';

  @override
  String theHistoryDirectoryOfDeviceId(String id) {
    return 'The history directory of device $id conflicts with the current Vault directory.';
  }

  @override
  String get readingEveryHistoryPageOfThe =>
      'Reading every history page of the pinned snapshot';

  @override
  String get readingTheArchiveManifestAndBinary =>
      'Reading the archive manifest and binary blocks';

  @override
  String get verifyingArchiveKeyEnvelopesAndEpoch =>
      'Verifying archive key envelopes and epoch keys';

  @override
  String get verifyingArchiveEncryptedObjectBlocks =>
      'Verifying archive encrypted object blocks';

  @override
  String get verifyingArchiveHistoryConflicts =>
      'Verifying archive history conflicts';

  @override
  String get verifyingArchiveHistoryRevisions =>
      'Verifying archive history revisions';

  @override
  String get verifyingTheArchivesLocalOutboxAnd =>
      'Verifying the archive\'s local outbox and conflict branches';

  @override
  String get verifyingArchiveFormatAndTarget =>
      'Verifying archive format and target';

  @override
  String get verifyingArchiveDeviceSequenceWatermarks =>
      'Verifying archive device sequence watermarks';

  @override
  String get verifyingTheMemberSignatureChainAnd =>
      'Verifying the member signature chain and device trust';

  @override
  String get verifyingSignaturesKeyEpochsAndObject =>
      'Verifying signatures, key epochs and object references';

  @override
  String get verifyingTheDeviceDirectoryAndSigned =>
      'Verifying the device directory and signed membership chain';

  @override
  String get attachmentsAreLimitedTo1Gib => 'Attachments are limited to 1 GiB.';

  @override
  String get theVaultHasNoActiveDevice =>
      'The Vault has no active device capability reports.';

  @override
  String get theVaultHasNoActiveDevices =>
      'The Vault has no active devices that can read attachment v2.';

  @override
  String get theServerDoesNotSupportSigned =>
      'The server does not support signed device capability reports required for v2 attachments.';

  @override
  String get theServerReturnedAnInvalidVault =>
      'The server returned an invalid Vault device inventory; v2 upload was blocked.';

  @override
  String get thisClientCannotAuthenticateOtherDevices =>
      'This client cannot authenticate other devices’ signed capability reports; v2 upload was blocked.';

  @override
  String get thisDeviceCapabilityReportCouldNot =>
      'This device capability report could not be published; no attachment data was staged.';

  @override
  String get thisDeviceHasNotPublishedIts =>
      'This device has not published its signed attachment capability report.';

  @override
  String get thisPlatformCannotSafelySaveAttachments =>
      'This platform cannot safely save attachments above 256 MiB; no attachment data was staged.';

  @override
  String get someDevicesInTheVaultDont =>
      'Some devices in the Vault don\'t support this attachment size.';

  @override
  String get v2PreflightIsOnlyRequiredAbove =>
      'v2 preflight is only required above 256 MiB.';

  @override
  String devicenameHasNoValidSignedReport(String deviceName) {
    return '$deviceName has no valid signed report for 1 GiB attachment records; update or remove that active device before enabling v2.';
  }

  @override
  String get theDownloadedAttachmentCiphertextDigestOr =>
      'The downloaded attachment ciphertext digest or length doesn\'t match.';

  @override
  String get differentAttachmentsReferenceTheSameObject =>
      'Different attachments reference the same object.';

  @override
  String get hostObjectRefsMustBeUnique =>
      'Host object_refs must be unique lowercase UUIDs in strictly ascending order.';

  @override
  String get hostObjectRefsMustBeAn =>
      'Host object_refs must be an array of at most 1024 items.';

  @override
  String get duplicateHostAttachmentBlobId =>
      'Duplicate host attachment blob ID.';

  @override
  String get invalidHostAttachmentManifestFormat =>
      'Invalid host attachment manifest format.';

  @override
  String get theHostAttachmentManifestExceedsThe =>
      'The host attachment manifest exceeds the 32 KiB storage limit.';

  @override
  String get localIntegrityVerificationOfTheEncrypted =>
      'Local integrity verification of the encrypted attachment object failed.';

  @override
  String get theEncryptedAttachmentManifestDoesntMatch =>
      'The encrypted attachment manifest doesn\'t match object_refs.';

  @override
  String get invalidPersistedUploadChunkSize =>
      'Invalid persisted upload chunk size.';

  @override
  String get invalidPersistedUploadProgress =>
      'Invalid persisted upload progress.';

  @override
  String get integrityVerificationOfAPersistedAttachment =>
      'Integrity verification of a persisted attachment ciphertext chunk failed.';

  @override
  String get theServerReturnedAnInvalidUpload =>
      'The server returned an invalid upload reservation.';

  @override
  String get anAttachmentObjectAlreadyOnThe =>
      'An attachment object already on the server doesn\'t match the persisted ciphertext.';

  @override
  String get theServerAttachmentUploadReceiptDoesnt =>
      'The server attachment upload receipt doesn\'t match the ciphertext object.';

  @override
  String get integrityVerificationOfTheLocalAttachment =>
      'Integrity verification of the local attachment ciphertext waiting for upload failed.';

  @override
  String get theLocalAttachmentObjectWaitingFor =>
      'The local attachment object waiting for upload is missing.';

  @override
  String get theLocalAttachmentEncryptionDirectoryIs =>
      'The local attachment encryption directory is missing or failed integrity verification.';

  @override
  String get thisV2AttachmentExceeds256Mib =>
      'This v2 attachment exceeds 256 MiB; this client doesn\'t implement bounded decryption and streaming save yet.';

  @override
  String get thisHostsAttachmentObjectReferencesExceed =>
      'This host\'s attachment object references exceed the 1024 limit.';

  @override
  String get theAttachmentIsntInThisHosts =>
      'The attachment isn\'t in this host\'s encrypted manifest.';

  @override
  String get theAttachmentObjectIdDuplicatesAn =>
      'The attachment object ID duplicates an existing host reference.';

  @override
  String get theTotalAttachmentPlaintextLengthExceeds =>
      'The total attachment plaintext length exceeds the manifest declaration.';

  @override
  String get attachmentPlaintextDigestOrTotalLength =>
      'Attachment plaintext digest or total length verification failed.';

  @override
  String get theComSerialConsoleRequiresThe =>
      'The COM serial Console requires the Windows client.';

  @override
  String get theBrowserCantStartALocal =>
      'The browser can\'t start a local shell directly; use the desktop client.';

  @override
  String get theSerialInputQueueIsFull =>
      '\n[The serial input queue is full; this input wasn\'t sent. Send input in smaller batches.]\n';

  @override
  String get couldntStartTheSerialConsole =>
      '\n[Couldn\'t start the serial Console]\n';

  @override
  String get theSerialConsoleFailedToStart =>
      'The serial Console failed to start.';

  @override
  String get theSerialPortDoesntSupportThis =>
      'The serial port doesn\'t support this configuration.';

  @override
  String get serialWriteFailedOrTheDevice =>
      'Serial write failed or the device was disconnected.';

  @override
  String get serialWriteTimedOut => 'Serial write timed out.';

  @override
  String get invalidSerialPortOrBaudRate => 'Invalid serial port or baud rate.';

  @override
  String get serialReadFailedOrTheDevice =>
      'Serial read failed or the device was disconnected.';

  @override
  String get serialInputExceedsTheLimit => 'Serial input exceeds the limit.';

  @override
  String couldntOpenItemWindowsGetlasterrorCheck(
    Object item,
    int GetLastError,
  ) {
    return 'Couldn\'t open $item (Windows $GetLastError). Check the serial port name and whether it\'s in use.';
  }

  @override
  String get couldntReadTheSerialPortConfiguration =>
      'Couldn\'t read the serial port configuration.';

  @override
  String get unsupportedAttachmentManifestFormat =>
      'Unsupported attachment manifest format.';

  @override
  String get invalidAttachmentMimeTypeFormat =>
      'Invalid attachment MIME type format.';

  @override
  String get invalidAttachmentBlobIdFormat =>
      'Invalid attachment blob ID format.';

  @override
  String get invalidAttachmentEncryptionDirectoryFormat =>
      'Invalid attachment encryption directory format.';

  @override
  String get attachmentEncryptionDirectoryAuthenticationOrParsing =>
      'Attachment encryption directory authentication or parsing failed.';

  @override
  String get theAttachmentEncryptionDirectoryExceedsThe =>
      'The attachment encryption directory exceeds the size limit.';

  @override
  String get invalidAttachmentBlockFieldFormat =>
      'Invalid attachment block field format.';

  @override
  String get theAttachmentBlockCountDoesntMatch =>
      'The attachment block count doesn\'t match the file length.';

  @override
  String get invalidAttachmentBlockCount => 'Invalid attachment block count.';

  @override
  String get theNumberOfAttachmentBlocksExceeds =>
      'The number of attachment blocks exceeds the v2 format limit.';

  @override
  String get theNumberOfAttachmentBlocksExceeds2 =>
      'The number of attachment blocks exceeds the current format limit.';

  @override
  String get invalidAttachmentBlockEntryFormat =>
      'Invalid attachment block entry format.';

  @override
  String get invalidAttachmentBlockManifestFormat =>
      'Invalid attachment block manifest format.';

  @override
  String get attachmentBlockAuthenticationFailedTheFile =>
      'Attachment block authentication failed; the file may have been tampered with.';

  @override
  String get attachmentBlockOrderLengthOrUniqueness =>
      'Attachment block order, length or uniqueness verification failed.';

  @override
  String get theAttachmentSizeIsOutsideThe =>
      'The attachment size is outside the range the client supports.';

  @override
  String get attachmentIntegrityOrFinalLengthVerification =>
      'Attachment integrity or final length verification failed.';

  @override
  String get theAttachmentCiphertextObjectIsMissing =>
      'The attachment ciphertext object is missing.';

  @override
  String get attachmentCiphertextDigestOrLengthVerification =>
      'Attachment ciphertext digest or length verification failed.';

  @override
  String get invalidAttachmentCiphertextLength =>
      'Invalid attachment ciphertext length.';

  @override
  String get invalidAttachmentKeyFormat => 'Invalid attachment key format.';

  @override
  String get theAttachmentObjectIdIsInvalid =>
      'The attachment object ID is invalid or duplicated.';

  @override
  String get invalidAttachmentFileNameOrMime =>
      'Invalid attachment file name or MIME type format.';

  @override
  String get invalidAttachmentFileNameFormat =>
      'Invalid attachment file name format.';

  @override
  String get attachmentPlaintextBlockLengthVerificationFailed =>
      'Attachment plaintext block length verification failed.';

  @override
  String get invalidAttachmentPlaintextDigestFormat =>
      'Invalid attachment plaintext digest format.';

  @override
  String get invalidAttachmentManifestEntryFormat =>
      'Invalid attachment manifest entry format.';

  @override
  String get theAttachmentSourceReturnsOnlyEmpty =>
      'The attachment source returns only empty blocks.';

  @override
  String get theAttachmentSourceKeepsReturningEmpty =>
      'The attachment source keeps returning empty blocks at the end of the file.';

  @override
  String get theAttachmentSourceEndedEarlyIts =>
      'The attachment source ended early; its length doesn\'t match the file info.';

  @override
  String get anAttachmentSourceBlockExceedsThe =>
      'An attachment source block exceeds the 4 MiB read limit.';

  @override
  String get theAttachmentSourceLengthExceedsThe =>
      'The attachment source length exceeds the file info.';

  @override
  String get invalidAttachmentDirectoryNonceFormat =>
      'Invalid attachment directory nonce format.';

  @override
  String get theAttachmentDirectoryBlockCountDoesnt =>
      'The attachment directory block count doesn\'t match the descriptor.';

  @override
  String get attachmentDirectoryBlockOrderLengthOr =>
      'Attachment directory block order, length or uniqueness verification failed.';

  @override
  String get invalidAttachmentDirectoryCiphertextSize =>
      'Invalid attachment directory ciphertext size.';

  @override
  String get attachmentDirectoryCiphertextDigestOrLength =>
      'Attachment directory ciphertext digest or length verification failed.';

  @override
  String get invalidAttachmentDirectoryCiphertextLength =>
      'Invalid attachment directory ciphertext length.';

  @override
  String get invalidAttachmentDirectoryObjectIdFormat =>
      'Invalid attachment directory object ID format.';

  @override
  String get invalidAttachmentDirectoryDigestFormat =>
      'Invalid attachment directory digest format.';

  @override
  String get theAttachmentExceedsThe1Gib =>
      'The attachment exceeds the 1 GiB client size limit.';

  @override
  String get theAttachmentExceedsThe256Mib =>
      'The attachment exceeds the 256 MiB client size limit.';

  @override
  String get theShareRequestIsMalformedOr =>
      'The share request is malformed or comes from a different server instance.';

  @override
  String get invalidShareRequestAccountIdentifier =>
      'Invalid share request account identifier.';

  @override
  String get invalidDeviceSelfProofPublicKey =>
      'Invalid device self-proof public key or signature length.';

  @override
  String get invalidDeviceSelfProofFields =>
      'Invalid device self-proof fields.';

  @override
  String get invalidDeviceSelfProofSignature =>
      'Invalid device self-proof signature.';

  @override
  String get invalidDeviceSelfProofAccountIdentifier =>
      'Invalid device self-proof account identifier.';

  @override
  String remoteDesktopConnectionFailedCodeLast(String last) {
    return 'Remote desktop connection failed (code $last). Check credentials, certificate trust and gateway logs.';
  }

  @override
  String get remoteDesktopDisconnected => 'Remote desktop disconnected.';

  @override
  String get resolutionAndScaling => 'Resolution and scaling';

  @override
  String get apply => 'Apply';

  @override
  String get theServerDoesntSupportResizingOnly =>
      'The server doesn\'t support resizing; only local scaling is possible.';

  @override
  String get theServerSupportsLiveResizingDisplay =>
      'The server supports live resizing (display control channel).';

  @override
  String get theServerSupportsResizingExtendeddesktopsize =>
      'The server supports resizing (ExtendedDesktopSize).';

  @override
  String get theServerDoesntOfferDisplayControl =>
      'The server doesn\'t offer display control; a new resolution takes effect after reconnecting.';

  @override
  String get waitingForTheServerToReport =>
      'Waiting for the server to report whether it supports resizing…';

  @override
  String get thisSessionUsesAllLocalMonitors =>
      'This session uses all local monitors; the remote resolution is determined by the monitor layout.';

  @override
  String get scalesThisWindowOnlyTheRemote =>
      'Scales this window only; the remote resolution doesn\'t change.';

  @override
  String get actualSize11Scrollable => 'Actual size (1:1, scrollable)';

  @override
  String get width => 'Width';

  @override
  String get serverDefaultDontRequestAResize =>
      'Server default (don\'t request a resize)';

  @override
  String get localDisplay => 'Local display';

  @override
  String get custom => 'Custom…';

  @override
  String get remoteResolution => 'Remote resolution';

  @override
  String get fitToWindow => 'Fit to window';

  @override
  String get height => 'Height';

  @override
  String get clipboardIsLimitedTo64Kib => 'Clipboard is limited to 64 KiB';

  @override
  String invalidRdpOptionsMessage(String message) {
    return 'Invalid RDP options: $message';
  }

  @override
  String get remoteDesktopConnectionClosed =>
      'Remote desktop connection closed.';

  @override
  String get remoteDesktopSetupTimedOutCheck =>
      'Remote desktop setup timed out. Check the gateway and target.';

  @override
  String get remoteDesktopStreamFailed => 'Remote desktop stream failed.';

  @override
  String get unableToConnectCheckTheDesktop =>
      'Unable to connect. Check the desktop gateway, Relay policy, credentials and certificate trust.';

  @override
  String get theHostSettingsChangedReconnect =>
      'The host settings changed. Reconnect.';

  @override
  String get theResolutionSettingAppliesToThis =>
      'The resolution setting applies to this session only; it couldn\'t be saved to the host.';

  @override
  String get inAMultiMonitorSessionThe =>
      'In a multi-monitor session, the resolution is set by this computer\'s monitors; turn off \"Use all monitors\" to set it.';

  @override
  String get stoppedRequestingAResizeTheServer =>
      'Stopped requesting a resize; the server keeps its current resolution.';

  @override
  String get theInstalledRdpEngineDoesntSupport =>
      'The installed RDP engine doesn\'t support this host\'s RDP options; connected with default settings.';

  @override
  String get couldntConnectToTheLocalGuacd =>
      'Couldn\'t connect to the local guacd (127.0.0.1:4822). Start the gateway or use a signed-in cloud workspace.';

  @override
  String get theServerDoesntAcceptThisResolution =>
      'The server doesn\'t accept this resolution.';

  @override
  String get theServerDoesntSupportResizingOnly2 =>
      'The server doesn\'t support resizing; only local scaling is available.';

  @override
  String get theServerRefusedTheResize => 'The server refused the resize.';

  @override
  String get theServerDoesntOfferDynamicResolution =>
      'The server doesn\'t offer dynamic resolution; the new resolution takes effect after reconnecting.';

  @override
  String get theServerLacksTheResourcesFor =>
      'The server lacks the resources for this resolution.';

  @override
  String get thisRdpCertificateWasntTrustedThe =>
      'This RDP certificate wasn\'t trusted; the connection was cancelled.';

  @override
  String get thisVncServerDoesntSupportResizing =>
      'This VNC server doesn\'t support resizing (ExtendedDesktopSize wasn\'t negotiated); only local scaling is available. The setting was kept.';

  @override
  String get clipboardTextIsTurnedOffFor =>
      'Clipboard text is turned off for this host.';

  @override
  String get thisHostCantSaveCertificates =>
      'This host can\'t save certificates.';

  @override
  String thisClientCantProvideJoinThe(String join) {
    return 'This client can\'t provide: $join. The other options apply as usual.';
  }

  @override
  String get theCertificateCouldntBeSavedThe =>
      'The certificate couldn\'t be saved. The host may have been changed or the workspace locked; try again or reconnect.';

  @override
  String couldntSaveRemoteFilesError(Object error) {
    return 'Couldn\'t save remote files: $error';
  }

  @override
  String get invalidRemoteDesktopHostSettings =>
      'Invalid remote desktop host settings.';

  @override
  String get invalidRemoteDesktopImage => 'Invalid remote desktop image.';

  @override
  String get theRemoteDesktopConnectionFailed =>
      'The remote desktop connection failed.';

  @override
  String get theRemoteDesktopConnectionClosed =>
      'The remote desktop connection closed.';

  @override
  String get theRemoteDesktopConnectionTimedOut =>
      'The remote desktop connection timed out. Check the target address and network.';

  @override
  String get rdpCertificateFingerprintChanged =>
      'RDP certificate fingerprint changed';

  @override
  String get saveRemoteClipboardFiles => 'Save remote clipboard files';

  @override
  String get saveRemoteClipboardFiles2 => 'Save remote clipboard files…';

  @override
  String saveRemoteClipboardFilesFilecountFiles(
    int fileCount,
    String formatTransferBytes,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      fileCount,
      locale: localeName,
      other: '$fileCount files',
      one: '1 file',
    );
    return 'Save remote clipboard files ($_temp0, $formatTransferBytes)…';
  }

  @override
  String get trustAndSave => 'Trust and save';

  @override
  String get trustThisRdpCertificate => 'Trust this RDP certificate?';

  @override
  String get resolutionAndScaling2 => 'Resolution and scaling…';

  @override
  String get sendCtrlAltDelete => 'Send Ctrl+Alt+Delete';

  @override
  String get sendLocallyCopiedFiles => 'Send locally copied files';

  @override
  String get cancel => 'Cancel';

  @override
  String get openInNewWindow => 'Open in new window';

  @override
  String get copyRemoteClipboardText => 'Copy remote clipboard text';

  @override
  String savedCountItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return 'Saved $_temp0.';
  }

  @override
  String savedCountItemsAndPlacedThem(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return 'Saved $_temp0 and placed them on this computer\'s clipboard, ready to paste.';
  }

  @override
  String get savedSha256 => 'Saved SHA-256';

  @override
  String get currentCertificateSha256 => 'Current certificate SHA-256';

  @override
  String get couldntSendClipboardText => 'Couldn\'t send clipboard text.';

  @override
  String get updateAndConnect => 'Update and connect';

  @override
  String get theServerCertificateDiffersFromThe =>
      'The server certificate differs from the saved record. Verify the new fingerprint; after confirming, this host\'s trust record is updated and the connection continues.';

  @override
  String get thereAreNoCopiedFilesOn =>
      'There are no copied files on this computer\'s clipboard.';

  @override
  String get saving => 'Saving…';

  @override
  String savingRemoteFilesDoneTotal(int done, int total) {
    return 'Saving remote files $done/$total';
  }

  @override
  String get thisCertificateIsntTrustedYetVerify =>
      'This certificate isn\'t trusted yet. Verify the fingerprint; after confirming, it\'s saved to this host and the connection continues.';

  @override
  String get oneWindowPerMonitor => 'One window per monitor';

  @override
  String get pasteLocalClipboardText => 'Paste local clipboard text';

  @override
  String get remoteDesktopMenu => 'Remote desktop menu';

  @override
  String get chooseFilesForTheRemoteClipboard =>
      'Choose files for the remote clipboard…';

  @override
  String get theRdpCertificateIsntTrustedYet =>
      'The RDP certificate isn\'t trusted yet; its SHA-256 fingerprint needs confirmation.';

  @override
  String get folderNestingIsTooDeep => 'Folder nesting is too deep';

  @override
  String get noFilesToSend => 'No files to send';

  @override
  String notARegularFileOrFolder(String name) {
    return 'Not a regular file or folder: $name';
  }

  @override
  String get tooManyFilesForTheClipboard => 'Too many files for the clipboard';

  @override
  String unsupportedOrDuplicateFileNameName(String name) {
    return 'Unsupported or duplicate file name: $name';
  }

  @override
  String fileTooLargeRelativepath(String relativePath) {
    return 'File too large: $relativePath';
  }

  @override
  String get theTotalSizeOfTheRemote =>
      'The total size of the remote files exceeds the limit.';

  @override
  String get rdpTlsHandshakeFailed20008No =>
      'RDP TLS handshake failed (20008). No verifiable certificate was received; check the target port and TLS configuration.';

  @override
  String get theRdpSessionDisconnected => 'The RDP session disconnected.';

  @override
  String get invalidRdpImageSize => 'Invalid RDP image size.';

  @override
  String get theRdpEngineCantBeLoaded =>
      'The RDP engine can\'t be loaded. Install the full Windows client.';

  @override
  String get theRdpEngineIsTooOld =>
      'The RDP engine is too old to apply this host\'s RDP options. Install the full client update.';

  @override
  String rdpConnectionFailedToradixstringCheckThe(String toRadixString) {
    return 'RDP connection failed ($toRadixString). Check the address, user name and password.';
  }

  @override
  String get theRdpConfigurationIsInvalidOr =>
      'The RDP configuration is invalid or the engine failed to initialize.';

  @override
  String placedCountFilesOnTheRemote(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return 'Placed $_temp0 on the remote clipboard; paste on the remote side.';
  }

  @override
  String get theCurrentRdpEngineDoesntSupport =>
      'The current RDP engine doesn\'t support the file clipboard.';

  @override
  String couldntSendFilesMessage(String message) {
    return 'Couldn\'t send files: $message';
  }

  @override
  String get couldntStartTheRdpEngineCheck =>
      'Couldn\'t start the RDP engine. Check the client installation.';

  @override
  String get couldntReadTheSelectedFiles =>
      'Couldn\'t read the selected files.';

  @override
  String get theTargetRdpSessionDoesntHave =>
      'The target RDP session doesn\'t have the file clipboard enabled, or this host turned it off.';

  @override
  String get theTargetRdpSessionDoesntHave2 =>
      'The target RDP session doesn\'t have the text clipboard enabled.';

  @override
  String get theRemoteClipboardHasNoFiles =>
      'The remote clipboard has no files to save.';

  @override
  String get anUnsafeFileNameOnThe =>
      'An unsafe file name on the remote clipboard was ignored.';

  @override
  String get theRemoteFilesCouldntBeSaved =>
      'The remote files couldn\'t be saved.';

  @override
  String get sshHostsDontHaveRemoteDesktop =>
      'SSH hosts don\'t have remote desktop display settings.';

  @override
  String get theHostChangedTheResolutionSetting =>
      'The host changed; the resolution setting wasn\'t saved.';

  @override
  String get theHostOrCertificateTrustChanged =>
      'The host or certificate trust changed. Reconnect.';

  @override
  String get theHostsRdpOptionsWereSaved =>
      'The host\'s RDP options were saved by a newer version; the resolution setting wasn\'t saved.';

  @override
  String get theHostsVncDisplaySettingsWere =>
      'The host\'s VNC display settings were saved by a newer version; the resolution setting wasn\'t saved.';

  @override
  String get couldntSaveTheCertificate => 'Couldn\'t save the certificate.';

  @override
  String atMostMaxdrivesRedirectedFolders(int maxDrives) {
    return 'At most $maxDrives redirected folders';
  }

  @override
  String atMostMaxusbdevicesUsbDevices(int maxUsbDevices) {
    return 'At most $maxUsbDevices USB devices';
  }

  @override
  String get driveFolderMustBeAnAbsolute =>
      'Drive folder must be an absolute path';

  @override
  String get driveNameMustBe131 =>
      'Drive name must be 1–31 letters, digits, spaces, _ or -';

  @override
  String get monitorLayoutExceedsRdpLimits =>
      'Monitor layout exceeds RDP limits';

  @override
  String get redirectedFolderNamesMustBeUnique =>
      'Redirected folder names must be unique';

  @override
  String get usbDevicesMustBeUniqueVendor =>
      'USB devices must be unique vendor:product hex IDs';

  @override
  String get unsupportedRdpDisplayScale => 'Unsupported RDP display scale';

  @override
  String get addFolder => 'Add folder';

  @override
  String get allPrinters => 'All printers';

  @override
  String get defaultPrinter => 'Default printer';

  @override
  String get displayClipboardAndLocalResources =>
      'Display, clipboard and local resources';

  @override
  String get doNotPlay => 'Do not play';

  @override
  String get eachMonitorCanBeOpenedIn =>
      'Each monitor can be opened in its own window';

  @override
  String get leaveOnRemoteComputer => 'Leave on remote computer';

  @override
  String get off2 => 'Off';

  @override
  String get onlyDevicesAlreadyUsingTheWinusb =>
      'Only devices already using the WinUSB driver. No driver is installed.';

  @override
  String get playOnThisComputer => 'Play on this computer';

  @override
  String get printers => 'Printers';

  @override
  String get rdpOptions => 'RDP options';

  @override
  String get redirectedFolders => 'Redirected folders';

  @override
  String get remoteAudio => 'Remote audio';

  @override
  String get remoteDisplayScale => 'Remote display scale';

  @override
  String get removeFolder => 'Remove folder';

  @override
  String get requiresAMatchingPrinterDriverOn =>
      'Requires a matching printer driver on the remote computer';

  @override
  String get requiresCameraRedirectionSupportOnThe =>
      'Requires camera redirection support on the server';

  @override
  String get resolutionAndLocalScaling => 'Resolution and local scaling';

  @override
  String get savedRdpOptionsWereWrittenBy =>
      'Saved RDP options were written by a newer version and are ignored. Saving replaces them.';

  @override
  String get usbDevicesVendorProduct => 'USB devices (vendor:product)';

  @override
  String get vncDisplay => 'VNC display';

  @override
  String get theRemoteDesktopInTheMain =>
      'The remote desktop in the main window was closed or disconnected.';

  @override
  String get remoteDesktop => 'Remote desktop';

  @override
  String get closeThisMonitorWindow => 'Close this monitor window';

  @override
  String get couldntOpenTheRemoteDesktopWindow =>
      'Couldn\'t open the remote desktop window. Go back to the main window and try again.';

  @override
  String titleMonitorValuevalueValuevalue2(
    String title,
    int valueValue,
    String valueValue2,
  ) {
    return '$title · Monitor $valueValue$valueValue2';
  }

  @override
  String get primary => '(primary)';

  @override
  String aHostCanHaveAtMost2(int maxHostPortForwardProfiles) {
    return 'A Host can have at most $maxHostPortForwardProfiles port forward profiles';
  }

  @override
  String get dynamicForwardingDoesNotHaveA =>
      'Dynamic forwarding does not have a fixed destination';

  @override
  String get forwardDestinationHostIsInvalid =>
      'Forward destination host is invalid';

  @override
  String get forwardDestinationPortMustBeBetween =>
      'Forward destination port must be between 1 and 65535';

  @override
  String get forwardListenerAddressAndPortMust =>
      'Forward listener address and port must be unique';

  @override
  String get forwardListenerAddressMustBeLocalhost =>
      'Forward listener address must be localhost or an IP address';

  @override
  String get forwardListenerPortMustBeBetween =>
      'Forward listener port must be between 0 and 65535';

  @override
  String get forwardListenersMustBindToLoopback =>
      'Forward listeners must bind to loopback unless network exposure is confirmed';

  @override
  String get forwardProfileIdIsInvalid => 'Forward profile ID is invalid';

  @override
  String get forwardProfileIdsMustBeUnique =>
      'Forward profile IDs must be unique';

  @override
  String get forwardProfileNameMustBe1 =>
      'Forward profile name must be 1–64 characters';

  @override
  String get hostAddressIsRequired => 'Host address is required';

  @override
  String get hostLoginAndAuthenticationSettingsDo =>
      'Host login and authentication settings do not match';

  @override
  String get hostNameIsRequired => 'Host name is required';

  @override
  String get portMustBeBetween1And => 'Port must be between 1 and 65535';

  @override
  String get rdpCertificateFingerprintMustContain64 =>
      'RDP certificate fingerprint must contain 64 hexadecimal SHA-256 digits';

  @override
  String get remoteDesktopsUsePasswordLoginWithout =>
      'Remote desktops use password login without SSH routes or forwards';

  @override
  String get remoteForwardingTargetsMustUseThis =>
      'Remote forwarding targets must use this device loopback unless network exposure is confirmed';

  @override
  String get unnamedHost => 'Unnamed host';

  @override
  String get untitledSnippet => 'Untitled snippet';

  @override
  String get usernameIsRequired => 'Username is required';

  @override
  String get enterAValidSshPassword => 'Enter a valid SSH password';

  @override
  String get enterAValidSshPrivateKey =>
      'Enter a valid SSH private key and passphrase';

  @override
  String get aPortNumberIsRequiredAfter => 'A port number is required after -p';

  @override
  String get aUserNameIsRequiredBefore => 'A user name is required before @';

  @override
  String get serialFormatConsoleTtyCom3B =>
      'Serial format: console tty @COM3 -b 115200';

  @override
  String get invalidHostOrUserNameFormat => 'Invalid host or user name format';

  @override
  String get onlyUserHostAndPPort =>
      'Only [user@]host and -p port are supported; shell arguments are never executed';

  @override
  String get dontSpecifyThePortBothIn =>
      'Don\'t specify the port both in the address and with -p';

  @override
  String get openLocalConsole => 'Open local Console';

  @override
  String formatVerbValuevalueHostPValuevalue2(
    String verb,
    String valueValue,
    int valueValue2,
  ) {
    return 'Format: $verb ${valueValue}host -p $valueValue2';
  }

  @override
  String get baudRateFormatB115200 => 'Baud rate format: -b 115200';

  @override
  String get baudRateMustBe504000000 => 'Baud rate must be 50–4000000';

  @override
  String get thePortCanOnlyBeSpecified => 'The port can only be specified once';

  @override
  String get portMustBe165535 => 'Port must be 1–65535';

  @override
  String get enterAValidSerialPortFor =>
      'Enter a valid serial port, for example console tty @COM3';

  @override
  String connectAddressBaudrateBaud8n1(String address, int baudRate) {
    return 'Connect $address · $baudRate baud · 8N1';
  }

  @override
  String get theActivePaneIsntInThe => 'The active pane isn\'t in the split.';

  @override
  String get invalidWindowSetHostPathOr =>
      'Invalid window set host, path or protocol.';

  @override
  String get theWindowSetHasTooMany => 'The window set has too many sessions.';

  @override
  String get invalidWindowSetSplit => 'Invalid window set split.';

  @override
  String get invalidWindowSetList => 'Invalid window set list.';

  @override
  String get invalidWindowSetNameOrSession =>
      'Invalid window set name or session.';

  @override
  String get windowSetIsNestedTooDeeply => 'Window set is nested too deeply.';

  @override
  String get aHostInThisWindowSet =>
      'A host in this window set no longer exists or its protocol changed. Delete the set and save it again.';

  @override
  String get windowSetDataIsTooLarge => 'Window set data is too large.';

  @override
  String get invalidWindowSetCountOrIdentifier =>
      'Invalid window set count or identifier.';

  @override
  String get invalidWindowSetFormat => 'Invalid window set format.';

  @override
  String get invalidWindowSetNode => 'Invalid window set node.';

  @override
  String get invalidWindowSetPaneReference =>
      'Invalid window set pane reference.';

  @override
  String get invalidWindowSetPane => 'Invalid window set pane.';

  @override
  String get hostTags => 'Host tags';

  @override
  String get addAUserDirectiveBeforeImporting =>
      'Add a User directive before importing this Host.';

  @override
  String get commandDirectivesAreNeverExecutedThis =>
      'Command directives are never executed; this Host will not be imported.';

  @override
  String get identityfileIsNotReadOrImported =>
      'IdentityFile is not read or imported. Add the key as a Credential separately.';

  @override
  String get identityfileNeedsOneValueThisHost =>
      'IdentityFile needs one value; this Host will not be imported.';

  @override
  String get theConfigFileExceedsThe1 =>
      'The config file exceeds the 1 MiB import limit.';

  @override
  String get theConfigFileHasTooMany =>
      'The config file has too many lines to review safely.';

  @override
  String get thisDirectiveNeedsExactlyOneValue =>
      'This directive needs exactly one value.';

  @override
  String get thisValueIsInvalidOrUnsupported =>
      'This value is invalid or unsupported.';

  @override
  String get atermiusRemoteDesktop => 'Atermius · Remote desktop';

  @override
  String get atermiusTerminal => 'Atermius · Terminal';

  @override
  String get atermiusNeedsReliablePersistentBrowserStorage =>
      'Atermius needs reliable persistent browser storage to keep offline data and multi-tab sync safe. Use a browser that supports OPFS or shared IndexedDB, allow this site to use local storage in a normal (non-private) window, and try again.';

  @override
  String get chooseAWorkspace => 'Choose a workspace';

  @override
  String get conflictingWindowRequests => 'Conflicting window requests.';

  @override
  String get continueLabel => 'Continue';

  @override
  String get createOrUnlockAnEncryptedHost =>
      'Create or unlock an encrypted Host and Credential vault. No account, server connection, or cross-device sync.';

  @override
  String get localProfileStorageIsUnavailableServer =>
      'Local profile storage is unavailable. Server mode can still be used if its storage backend is supported.';

  @override
  String get localOnlyProfile => 'Local-only profile';

  @override
  String get openLocally => 'Open locally';

  @override
  String get opening => 'Opening…';

  @override
  String get serverAccountAndSync => 'Server account and sync';

  @override
  String get serverProfilesSyncEncryptedDataAcross =>
      'Server profiles sync encrypted data across your devices. Local-only profiles stay on this browser or device and are not synced.';

  @override
  String get useYourSelfHostedServerAccount =>
      'Use your self-hosted server account and synchronized Vault.';

  @override
  String get workspaceSwitchCouldNotBeCompleted =>
      'Workspace switch could not be completed.';

  @override
  String get theSecurityComponentsOrLocalStorage =>
      'The security components or local storage couldn\'t start. Make sure the deployment files are complete and that the browser allows this site to use local storage, then try again.';

  @override
  String get workspaceMenu => 'Workspace menu';

  @override
  String get workspaceModeSettings => 'Workspace mode settings';

  @override
  String get couldntSaveOrSwitchTheWorkspace =>
      'Couldn\'t save or switch the workspace mode. Check local storage and try again.';

  @override
  String get couldntInitializeTheSecureWorkspace =>
      'Couldn\'t initialize the secure workspace';

  @override
  String get couldntOpenTheCloudWorkspaceOr =>
      'Couldn\'t open the cloud workspace or save the workspace mode. Check local storage and try again.';

  @override
  String get couldntOpenLocalProfileStorageAllow =>
      'Couldn\'t open local profile storage. Allow this site to use persistent storage, then try again.';

  @override
  String get couldntVerifyTheSeparateWindowTry =>
      'Couldn\'t verify the separate window. Try again from the original window.';

  @override
  String get aLocalStorageWriteWasInterrupted =>
      'A local storage write was interrupted. Free up storage space and close other Atermius tabs for this site, then reload the page to recover and try again.';

  @override
  String get preparingSecureWorkspace => 'Preparing secure workspace';

  @override
  String get checkingLocalEncryptedStorage =>
      'Checking local encrypted storage.';

  @override
  String get reloadPage => 'Reload page';

  @override
  String get retry => 'Retry';

  @override
  String get supportedBrowserStorageRequired =>
      'Supported browser storage required';

  @override
  String get supportedBrowserStorageIsRequiredCheck =>
      'Supported browser storage is required. Check persistent storage permission and try again.';

  @override
  String get someFileWindowsArentUnlockedAre =>
      'Some file windows aren\'t unlocked, are switching, or don\'t have a position yet; wait and save again.';

  @override
  String theRemotePathIsntARegular(String path) {
    return 'The remote path isn\'t a regular file: $path';
  }

  @override
  String get scpFileListingRequiresTheSftp =>
      'SCP file listing requires the SFTP directory channel of this SSH connection. Check whether the server has SFTP enabled.';

  @override
  String get theFileActionFailedCheckThe =>
      'The file action failed. Check the SSH/SFTP connection and folder permissions.';

  @override
  String get invalidRemoteFolderPath => 'Invalid remote folder path.';

  @override
  String get theSshSftpSessionIsClosed => 'The SSH/SFTP session is closed.';

  @override
  String get onlyRegularFilesCanBeDownloaded =>
      'Only regular files can be downloaded.';

  @override
  String get onlySizeBoundedRegularFilesCan =>
      'Only size-bounded regular files can be streamed.';

  @override
  String get invalidFileNameFormat => 'Invalid file name format.';

  @override
  String get theFileExceedsThisPlatformsSftp =>
      'The file exceeds this platform\'s SFTP upload size limit.';

  @override
  String couldntSafelyCreateTheRemoteFile(Object error) {
    return 'Couldn\'t safely create the remote file. It may already exist, or the current user lacks write permission; existing files aren\'t overwritten. ($error)';
  }

  @override
  String get invalidFolderNameFormat2 => 'Invalid folder name format.';

  @override
  String get invalidRemoteFileNameFormat2 => 'Invalid remote file name format.';

  @override
  String get theRemoteFileExceedsTheLocal =>
      'The remote file exceeds the local download size limit.';

  @override
  String get theRemoteFileExceedsTheStreaming =>
      'The remote file exceeds the streaming download size limit.';

  @override
  String get theRemotePathIsntASize =>
      'The remote path isn\'t a size-bounded regular file.';

  @override
  String get theRemotePathIsntARegular2 =>
      'The remote path isn\'t a regular file.';

  @override
  String get theRemotePathIsNoLonger =>
      'The remote path is no longer a regular file.';

  @override
  String get anotherForwardAlreadyUsesThisListener =>
      'Another forward already uses this listener address and port.';

  @override
  String get couldNotStartThisForwardCheck =>
      'Could not start this forward. Check port availability and the SSH server forwarding policy.';

  @override
  String get forwardStartWasCancelled => 'Forward start was cancelled.';

  @override
  String get sshConnectionClosedWhileForwardingWas =>
      'SSH connection closed while forwarding was starting';

  @override
  String get sshPortForwardingIsUnavailableHere =>
      'SSH port forwarding is unavailable here.';

  @override
  String get sshPortForwardingRuntimeIsUnavailable =>
      'SSH port forwarding runtime is unavailable in this platform.';

  @override
  String get theSshConnectionForThisForward =>
      'The SSH connection for this forward has ended. Reconnect first.';

  @override
  String get theForwardProfileIsInvalid => 'The forward profile is invalid.';

  @override
  String get theForwardStoppedUnexpectedly =>
      'The forward stopped unexpectedly.';

  @override
  String get thisSshPortForwardProfileIs =>
      'This SSH port forward profile is already active.';

  @override
  String addressBindaddressIsNotAvailableOn(String bindAddress) {
    return 'Address $bindAddress is not available on this device.';
  }

  @override
  String connectionLimitSshportforwardmaxconnectionsReachedNewClients(
    int sshPortForwardMaxConnections,
  ) {
    return 'Connection limit ($sshPortForwardMaxConnections) reached; new clients are refused until others close.';
  }

  @override
  String couldNotOpenAnSshChannel(String target) {
    return 'Could not open an SSH channel to $target.';
  }

  @override
  String portEndpointIsAlreadyInUse(String endpoint) {
    return 'Port $endpoint is already in use on this device.';
  }

  @override
  String get theSshConnectionIsNoLonger =>
      'The SSH connection is no longer available.';

  @override
  String theSshServerCouldNotConnect(String target) {
    return 'The SSH server could not connect to $target.';
  }

  @override
  String theSshServerDeniedForwardingTo(String target) {
    return 'The SSH server denied forwarding to $target (administratively prohibited).';
  }

  @override
  String get theSshServerDidNotAnswer =>
      'The SSH server did not answer the remote forward request in time. A late listener will be cancelled; if the server does not confirm that, the SSH connection is closed.';

  @override
  String get theSshServerDidNotConfirm =>
      'The SSH server did not confirm remote forward removal.';

  @override
  String get theSshServerIsOutOf =>
      'The SSH server is out of resources for new channels.';

  @override
  String theSshServerRefusedAChannel(String target) {
    return 'The SSH server refused a channel to $target.';
  }

  @override
  String get theDeviceSocksListenerStoppedUnexpectedly =>
      'The device SOCKS listener stopped unexpectedly.';

  @override
  String get theDeviceListenerStoppedUnexpectedly =>
      'The device listener stopped unexpectedly.';

  @override
  String thisDeviceCouldNotListenOn(String endpoint) {
    return 'This device could not listen on $endpoint.';
  }

  @override
  String thisDeviceRefusedToListenOn(String endpoint) {
    return 'This device refused to listen on $endpoint (permission denied; low ports or a reserved port range may be blocked).';
  }

  @override
  String timedOutOpeningAnSshChannel(String target) {
    return 'Timed out opening an SSH channel to $target.';
  }

  @override
  String get thisBrowserBuildCannotOpenTcp =>
      'This browser build cannot open TCP listeners or outbound sockets, so SSH port forwarding cannot run here. Profiles still sync for desktop and mobile apps.';

  @override
  String get theSshRelayOriginDoesntMatch =>
      'The SSH relay origin doesn\'t match the server configuration. Ask an administrator to check the public site address.';

  @override
  String get theSshRelayTargetMustBe =>
      'The SSH relay target must be a valid IP address and port; the server relay doesn\'t accept DNS host names.';

  @override
  String get theSshRelayTicketExpiredStart =>
      'The SSH relay ticket expired. Start the connection again.';

  @override
  String get tooManySshRelayRequestsTry =>
      'Too many SSH relay requests. Try again later.';

  @override
  String get theSshRelayConnectionTimedOut =>
      'The SSH relay connection timed out. Check server availability, the network and the target address.';

  @override
  String get theSshHostKeyDiffersFrom =>
      'The SSH host key differs from the saved fingerprint; the connection was rejected. Verify the new fingerprint over a trusted channel before updating trust.';

  @override
  String get sshHostKeyVerificationFailedThe =>
      'SSH host key verification failed; the connection was rejected. Check the server identity and connection path.';

  @override
  String get sshAuthenticatedButTheTerminalSession =>
      'SSH authenticated, but the terminal session couldn\'t be opened.';

  @override
  String get sshHandshakeFailedCheckTheSsh =>
      'SSH handshake failed. Check the SSH server and relay connection.';

  @override
  String get theSshPrivateKeyCouldntBe =>
      'The SSH private key couldn\'t be parsed or the passphrase is wrong. Check the key format and passphrase.';

  @override
  String get theSshNetworkConnectionWasInterrupted =>
      'The SSH network connection was interrupted. Check the relay and target server.';

  @override
  String get sshAuthenticationFailedCheckTheUser =>
      'SSH authentication failed. Check the user name, password or private key.';

  @override
  String get theSshConnectionDroppedBeforeAuthentication =>
      'The SSH connection dropped before authentication finished. Check the network and server, then try again.';

  @override
  String get theUntrustedSshHostKeyWas =>
      'The untrusted SSH host key was rejected and the connection was cancelled.';

  @override
  String get couldntEstablishTheSshRelayWebsocket =>
      'Couldn\'t establish the SSH relay WebSocket. Check the instance HTTPS/WSS address, relay origin settings and network, then try again.';

  @override
  String get theServerRelayPolicyRejectedThis =>
      'The server relay policy rejected this target address or port. Ask an administrator to check the SSH target allowlist.';

  @override
  String get theServerHasntEnabledTheSsh =>
      'The server hasn\'t enabled the SSH relay. Ask an administrator to configure the relay and target networks.';

  @override
  String get localStorageNeedsRecoveryReadingEditing2 =>
      'Local storage needs recovery. Reading, editing and syncing this database are paused; close all Atermius tabs and reopen to restore the last persisted data.';

  @override
  String get invalidWindowSetPreferenceFormat =>
      'Invalid window set preference format.';

  @override
  String get invalidStagedMigrationCiphertextContext =>
      'Invalid staged migration ciphertext context.';

  @override
  String get invalidStagedMigrationCiphertextFormat =>
      'Invalid staged migration ciphertext format.';

  @override
  String get theServerHasntConfirmedAllMigration =>
      'The server hasn\'t confirmed all migration records yet.';

  @override
  String get theMigrationJournalContainsDuplicateOperation =>
      'The migration journal contains duplicate operation IDs.';

  @override
  String get theMigrationDestinationOutboxDoesntMatch =>
      'The migration destination outbox doesn\'t match the staged ciphertext.';

  @override
  String get theMigrationDestinationOutboxDoesntMatch2 =>
      'The migration destination outbox doesn\'t match the staging journal.';

  @override
  String get aStagedRecordInTheMigration =>
      'A staged record in the migration destination was deleted.';

  @override
  String get theMigrationDestinationContainsDuplicateRecord =>
      'The migration destination contains duplicate record heads.';

  @override
  String get theMigrationDestinationRecordDoesntMatch =>
      'The migration destination record doesn\'t match the staged ciphertext.';

  @override
  String get theMigrationRecordStillHasUnconfirmed =>
      'The migration record still has unconfirmed outbox operations.';

  @override
  String get recycleBinSnapshotExpiredBeforeIt =>
      'Recycle bin snapshot expired before it could be read.';

  @override
  String get snapshotExpiredBeforeRecoveryCouldStart =>
      'Snapshot expired before recovery could start.';

  @override
  String get theServerGenerationChangedSynchronizeBefore =>
      'The server generation changed; synchronize before restoring.';

  @override
  String itemExitItem2(Object item, Object item2) {
    return '$item · exit $item2';
  }

  @override
  String get addThisAccountInYourAuthenticator =>
      'Add this account in your authenticator app, then enter the current six-digit code. The setup secret is temporary and is never saved by this client.';

  @override
  String get authenticatorCode => 'Authenticator code';

  @override
  String get disableMfa => 'Disable MFA';

  @override
  String get disableTwoFactorSignIn => 'Disable two-factor sign-in';

  @override
  String get disabled => 'Disabled';

  @override
  String get eachCodeCanBeUsedOnce =>
      'Each code can be used once if you lose access to your authenticator. Save them in a password manager or another secure place. This is the only time the full codes are shown; this client does not save or copy them.';

  @override
  String get enabled => 'Enabled';

  @override
  String get enterExactlySixDigits => 'Enter exactly six digits.';

  @override
  String get enterYourCurrentPasswordAndAuthenticator =>
      'Enter your current password and authenticator code.';

  @override
  String get iSavedTheseCodesSecurely => 'I saved these codes securely';

  @override
  String get mfaRecoveryCodesWereRotated => 'MFA recovery codes were rotated.';

  @override
  String mfaRecoveryCodesFormattedcodes(String formattedCodes) {
    return 'MFA recovery codes: $formattedCodes';
  }

  @override
  String get newRecoveryCodesWereGeneratedBut =>
      'New recovery codes were generated but were not confirmed as saved. Rotate again to display a replacement set.';

  @override
  String get provisioningUri => 'Provisioning URI';

  @override
  String get refreshMfaStatus => 'Refresh MFA status';

  @override
  String get rotateMfaRecoveryCodes => 'Rotate MFA recovery codes';

  @override
  String get rotateCodes => 'Rotate codes';

  @override
  String get rotateRecoveryCodes => 'Rotate recovery codes';

  @override
  String get saveYourMfaRecoveryCodes => 'Save your MFA recovery codes';

  @override
  String get setUpAuthenticator => 'Set up authenticator';

  @override
  String get setUpAuthenticatorApp => 'Set up authenticator app';

  @override
  String setupExpiresTolocal(DateTime toLocal) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return 'Setup expires $toLocalString.';
  }

  @override
  String get setupSecret => 'Setup secret';

  @override
  String totpProvisioningUriProvisioninguri(String provisioningUri) {
    return 'TOTP provisioning URI: $provisioningUri';
  }

  @override
  String totpSetupSecretSecret(String secret) {
    return 'TOTP setup secret: $secret';
  }

  @override
  String get theLastRecoveryCodesWereNot =>
      'The last recovery codes were not confirmed as saved. Rotate the codes to display a new set.';

  @override
  String get twoFactorSignIn => 'Two-factor sign-in';

  @override
  String get useAnAuthenticatorAppOrA =>
      'Use an authenticator app or a one-time recovery code as a second sign-in factor. The server stores the TOTP seed encrypted; the client keeps setup secrets and recovery codes only long enough to display them.';

  @override
  String get verifyAndEnable => 'Verify and enable';

  @override
  String get youWillBeAbleToSign =>
      'You will be able to sign in with your master password alone. Your authenticator and unused recovery codes will stop working.';

  @override
  String valuevalueRecoveryCodesRemaining(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: '$valueValue recovery codes remaining.',
      one: '1 recovery code remaining.',
    );
    return '$_temp0';
  }

  @override
  String get aHostChangedAfterThePreview =>
      'A Host changed after the preview. Reopen the importer and review its latest revision.';

  @override
  String get aHostWithThisNameWas =>
      'A Host with this name was saved during review. Reopen the importer to compare it.';

  @override
  String get applyTheseInventoryChanges => 'Apply these inventory changes?';

  @override
  String applyCountChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes',
      one: '1 change',
    );
    return 'Apply $_temp0';
  }

  @override
  String applyCountReviewedChangeSTo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count reviewed changes',
      one: '1 reviewed change',
    );
    return 'Apply $_temp0 to encrypted Host records in the active Vault. Missing entries will only be marked stale; no Host will be deleted. Ansible groups are saved as Host tags. Credentials are not imported, and no inventory or SSH command is executed.';
  }

  @override
  String get chooseInventoryFile => 'Choose inventory file';

  @override
  String get confirmChanges => 'Confirm changes';

  @override
  String get createANewSource => 'Create a new source';

  @override
  String get importAnsibleInventory => 'Import Ansible inventory';

  @override
  String get inventory => 'Inventory';

  @override
  String get inventoryFile => 'Inventory file';

  @override
  String get inventoryFilesAreLimitedTo1 =>
      'Inventory files are limited to 1 MiB.';

  @override
  String get inventorySource => 'Inventory source';

  @override
  String get inventorySourcesAreLimitedTo1 =>
      'Inventory sources are limited to 1 MiB.';

  @override
  String get keepManual => 'Keep manual';

  @override
  String get markStaleKeepThisHostSaved => 'Mark stale; keep this Host saved';

  @override
  String get noHostsWereImportedTheVault =>
      'No Hosts were imported. The Vault may have changed or a Host could not be saved.';

  @override
  String get noConcreteHostCandidatesWereFound =>
      'No concrete Host candidates were found.';

  @override
  String get pasteOrChooseAStaticIni =>
      'Paste or choose a static INI/YAML inventory. Dynamic inventory is rejected; this importer never runs scripts, plugins, Ansible, SSH, or network requests. Only reviewed Host connection fields are imported. Credentials and private keys are ignored.';

  @override
  String get pastedInventory => 'Pasted inventory';

  @override
  String get reviewBlockedThisInventoryCannotBe =>
      'Review blocked: this inventory cannot be imported.';

  @override
  String get reviewEachFieldConflictManualEdits =>
      'Review each field conflict. Manual edits are kept by default. Missing entries stay saved and can only be marked stale after explicit selection.';

  @override
  String get reviewPastedInventory => 'Review pasted inventory';

  @override
  String get savedInEncryptedHostMetadataFile =>
      'Saved in encrypted Host metadata; file paths are not stored.';

  @override
  String get sourceLabel => 'Source label';

  @override
  String get staticInventoryText => 'Static inventory text';

  @override
  String get theActiveVaultChangedOrBecame =>
      'The active Vault changed or became read-only during import.';

  @override
  String get theActiveVaultChangedOrIs =>
      'The active Vault changed or is not writable; review the inventory again before importing.';

  @override
  String get theInventoryCouldNotBeReviewed =>
      'The inventory could not be reviewed safely.';

  @override
  String get theSelectedFileCouldNotBe =>
      'The selected file could not be read.';

  @override
  String get theSelectedFileCouldNotBe2 =>
      'The selected file could not be reviewed.';

  @override
  String get useInventory => 'Use inventory';

  @override
  String restoreDeadlineFormat2(String format) {
    return ' Restore deadline: $format.';
  }

  @override
  String get n0Auto => '0 = auto';

  @override
  String get n180UnicodeCharactersUniqueWithout =>
      '1–80 Unicode characters; unique without regard to case.';

  @override
  String aHostCanHaveAtMost(int maxHostPortForwardProfiles) {
    return 'A Host can have at most $maxHostPortForwardProfiles port forward profiles.';
  }

  @override
  String get aConcurrentChangeWasDetectedYour =>
      'A concurrent change was detected. Your name, membership and policy drafts are preserved.';

  @override
  String get aNewEncryptedRevisionWillBe =>
      'A new encrypted revision will be created against the current remote head. The old branch remains recorded until the server accepts the resolution.';

  @override
  String get aNewerAtermiusWebBuildIs =>
      'A newer Atermius Web build is available.';

  @override
  String get aNewerWebBuildIsAvailable =>
      'A newer Web build is available. Review the notice above when it is safe to reload.';

  @override
  String aPreviousRepairAlreadySelectedRetainedrepairid(
    String retainedRepairId,
  ) {
    return 'A previous repair already selected $retainedRepairId. Retry must keep that record until sync confirms the tombstones.';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry(String retainedRecordId) {
    return 'A previous repair selected $retainedRecordId. Retry must keep that record until Vault sync confirms the tombstones.';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry2(
    String retainedRecordId,
  ) {
    return 'A previous repair selected $retainedRecordId. Retry must keep this record until Vault sync confirms the tombstones.';
  }

  @override
  String get aRandomRecoveryCodeEncryptsA =>
      'A random recovery code encrypts a separate Recovery identity. That identity stores sealed copies of Vault epoch keys; your account key is not a Vault key. Keep the code outside this device.';

  @override
  String get aSplitWorkspaceNeedsAtLeast =>
      'A split Workspace needs at least two panes';

  @override
  String get aUsersEffectiveRelayAccessAlso =>
      'A user’s effective Relay access also intersects their account policy, every other server group, and the deployment limits.';

  @override
  String get active => 'ACTIVE';

  @override
  String get apiEndpoint => 'API endpoint';

  @override
  String get acceptVaultInvitation => 'Accept Vault invitation';

  @override
  String get acceptAndUnlockVault => 'Accept and unlock Vault';

  @override
  String get acceptInvitation => 'Accept invitation';

  @override
  String get acceptedByAdapter7UtcDays => 'Accepted by adapter (7 UTC days)';

  @override
  String get accessExpires => 'Access expires';

  @override
  String get account => 'Account';

  @override
  String get accountDevice => 'Account & device';

  @override
  String get accountId => 'Account ID';

  @override
  String get accountRelayPolicy => 'Account Relay policy';

  @override
  String get accountRelayPolicySaveFailed => 'Account Relay policy save failed';

  @override
  String get accountDeletion => 'Account deletion';

  @override
  String get accountDeletionImmediatelyRevokesAllSessions =>
      'Account deletion immediately revokes all sessions and devices. At the server deadline, personal Vaults and account data are purged; your membership and key access to other people’s Vaults are removed. Other members’ shared Vault data is not deleted. An Owner of a shared Vault with other active or invited members must resolve that membership first.';

  @override
  String get accountDeletionScheduledByTheServer =>
      'Account deletion scheduled by the server.';

  @override
  String accountDeletionScheduledServerPurgeAfter(
    Object accountDeletionPurgeAfter,
  ) {
    return 'Account deletion scheduled. Server purge_after: $accountDeletionPurgeAfter.';
  }

  @override
  String get accountDevices => 'Account devices';

  @override
  String get accountInvitationCreated => 'Account invitation created';

  @override
  String get accountInvitations => 'Account invitations';

  @override
  String get accountRecovery => 'Account recovery';

  @override
  String accountRecoveryCodeCode(String code) {
    return 'Account recovery code: $code';
  }

  @override
  String get accountRecoveryWasDisabled => 'Account recovery was disabled.';

  @override
  String accountRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return 'Account revision $revision · updated $formatTime';
  }

  @override
  String get accountSessions => 'Account sessions';

  @override
  String get accounts => 'Accounts';

  @override
  String actionsForFilename(String filename) {
    return 'Actions for $filename';
  }

  @override
  String get active2 => 'Active';

  @override
  String activePaneValuevalue(int valueValue) {
    return 'Active Pane $valueValue';
  }

  @override
  String get activeAccountOnCurrentPage => 'Active account on current page';

  @override
  String get activeDevices => 'Active devices';

  @override
  String get activePane => 'Active pane';

  @override
  String get activeSessions => 'Active sessions';

  @override
  String get actorDeviceId => 'Actor device ID';

  @override
  String get actorUserId => 'Actor user ID';

  @override
  String get add => 'Add';

  @override
  String get addCredentialSecretParameter => 'Add Credential secret parameter';

  @override
  String get addAHostFirst => 'Add a host first.';

  @override
  String get addAPasswordOrPrivateKey =>
      'Add a password or private-key identity, then link it to a host.';

  @override
  String get addCredential2 => 'Add credential';

  @override
  String get addForwardingProfile => 'Add forwarding profile';

  @override
  String get addParameter => 'Add parameter';

  @override
  String get addProfile => 'Add profile';

  @override
  String get addThisValueAsTheBearer =>
      'Add this value as the Bearer credential for /api/v1/admin/metrics. It is not stored in this app and cannot be retrieved later.';

  @override
  String get addYourFirstHost => 'Add your first host';

  @override
  String get adjustTheSearchOrGroupFilter =>
      'Adjust the search or group filter to see more hosts.';

  @override
  String get advanceOnlyAfterEachPageIs =>
      'Advance only after each page is persisted';

  @override
  String get afterConfirmationThisFingerprintIsSaved =>
      'After confirmation, this fingerprint is saved as an encrypted record in the current Vault and syncs to its devices. The client rejects later connections when the key changes.';

  @override
  String algorithmAlgorithm(String algorithm) {
    return 'Algorithm: $algorithm';
  }

  @override
  String get allActiveVaultDevicesReportSupport =>
      'All active Vault devices report support for redaction v1.';

  @override
  String get allowFutureAutomaticPurge => 'Allow future automatic purge?';

  @override
  String get allowFuturePurge => 'Allow future purge';

  @override
  String get allowedCidrNetworks => 'Allowed CIDR networks';

  @override
  String get allowedCidrsOnePerLine => 'Allowed CIDRs (one per line)';

  @override
  String get allowedPorts => 'Allowed ports';

  @override
  String anEncryptedVaultArchiveCoveringPendingcount(int pendingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingCount,
      locale: localeName,
      other: '$pendingCount pending operations',
      one: '1 pending operation',
    );
    return 'An encrypted Vault archive covering $_temp0 was exported recently. The outbox remains stored locally and will sync after reload.';
  }

  @override
  String get anonymousDiagnostics => 'Anonymous diagnostics';

  @override
  String get anonymousSyncDiagnosticsExported =>
      'Anonymous sync diagnostics exported.';

  @override
  String appliedAppliedInventoryChangeSHost(int applied) {
    String _temp0 = intl.Intl.pluralLogic(
      applied,
      locale: localeName,
      other: '$applied inventory changes',
      one: '1 inventory change',
    );
    return 'Applied $_temp0; Host records are encrypted and queued to sync.';
  }

  @override
  String get applyWebUpdate => 'Apply Web update?';

  @override
  String get approvalJsonCopied => 'Approval JSON copied.';

  @override
  String get approveSealKeys => 'Approve & seal keys';

  @override
  String get approveEnrollment => 'Approve enrollment';

  @override
  String approveValuevalue(Object valueValue) {
    return 'Approve $valueValue?';
  }

  @override
  String get archiveBytes => 'Archive bytes';

  @override
  String get archivePassword => 'Archive password';

  @override
  String get archiveSaveWasCanceled => 'Archive save was canceled.';

  @override
  String get argumentsJsonArray2 => 'Arguments (JSON array)';

  @override
  String get askTheServerOperatorToConfigure =>
      'Ask the server operator to configure the encrypted backup destination and key before enabling a schedule.';

  @override
  String get atLeast12CharactersIndependentFrom =>
      'At least 12 characters. Independent from your account password.';

  @override
  String get atTheDeadlineTheServerPurges =>
      'At the deadline the server purges this Vault’s records, history, conflicts, snapshots, encrypted objects, membership and key envelopes. Existing local/offline copies and backups are separate; this action cannot remotely erase them.';

  @override
  String get atTheServerDeadlineRecordsHistory =>
      'At the server deadline, records, history, conflicts, snapshots, encrypted objects and key envelopes are purged. Offline copies and retained backups are separate and are not remotely erased.';

  @override
  String get atermiusWillKeepThisPageAnd =>
      'Atermius will keep this page and its SSH sessions open until you finish the steps below and confirm the reload.';

  @override
  String get atermiusWillReloadThisPageTo =>
      'Atermius will reload this page to load the newer self-hosted Web bundle. The page will not switch until you confirm.';

  @override
  String get attemptedAt => 'Attempted at';

  @override
  String get auditLog2 => 'Audit log';

  @override
  String get automaticPurgeConsentRecordedForThis =>
      'Automatic purge consent recorded for this exact tombstone. Bounded Maintenance may purge it after the restore deadline and other required checks; enabling consent does not purge it immediately. Offline device copies and exports are not removed.';

  @override
  String automaticPurgeConsentValuevalue(String valueValue) {
    return 'Automatic purge consent: $valueValue';
  }

  @override
  String get back => 'Back';

  @override
  String get backgroundSyncNotifications => 'Background sync notifications';

  @override
  String backupBucketAccessCheckResultNotice(String notice) {
    return 'Backup bucket access check result: $notice';
  }

  @override
  String get backupCommandFailed => 'Backup command failed';

  @override
  String baseRevisionShortauditidCurrentHeadShortauditid2(
    String shortAuditId,
    String shortAuditId2,
  ) {
    return 'Base revision: $shortAuditId · Current head: $shortAuditId2';
  }

  @override
  String get bashNonInteractiveExecution => 'Bash non-interactive execution';

  @override
  String get bashNonInteractiveExecutionRequiresA =>
      'Bash non-interactive execution · requires a POSIX-compatible login shell and Bash';

  @override
  String get bashOnlyEachArgvItemIs =>
      'Bash only. Each argv item is a literal or parameter reference and is quoted as one shell word.';

  @override
  String get batchCommandExecution => 'Batch command execution';

  @override
  String bindingsAreEncryptedInCurrentvaultnameAnd(String currentVaultName) {
    return 'Bindings are encrypted in $currentVaultName and sync to devices with access to this Vault.';
  }

  @override
  String get bindingsSyncAsSemanticActionsMod =>
      'Bindings sync as semantic actions. “mod” resolves locally to Command on Apple platforms and Control elsewhere. A shortcut runs only while a terminal input has focus; the search field keeps normal text and keyboard behavior.';

  @override
  String get bothRevisionsStayEncryptedInLocal =>
      'Both revisions stay encrypted in local storage. Choose the branch to become a new revision based on the current remote head.';

  @override
  String branchShortauditid(String shortAuditId) {
    return 'Branch $shortAuditId';
  }

  @override
  String get browseFiles2 => 'Browse files';

  @override
  String browseFilesOnValuevalue(String valueValue) {
    return 'Browse files on $valueValue';
  }

  @override
  String get byApprovingThisActiveMemberDevice =>
      'By approving, this active member device sends sealed key envelopes for every Vault and key epoch it can access. Verify the request and device identity with the person who controls the new browser.';

  @override
  String get conflictConnectionsBlocked => 'CONFLICT — CONNECTIONS BLOCKED';

  @override
  String get currentVault => 'CURRENT VAULT';

  @override
  String get cancelBatch => 'Cancel batch';

  @override
  String get cancelDeletion => 'Cancel deletion';

  @override
  String get cancelExecution => 'Cancel execution';

  @override
  String get cancelScheduledDeletion => 'Cancel scheduled deletion?';

  @override
  String cancelThePendingDeletionForVaultname(
    String vaultName,
    String vaultLifecycleDate,
  ) {
    return 'Cancel the pending deletion for $vaultName? Server writes become available again and the encrypted outbox can resume syncing. The cancellation is possible only before $vaultLifecycleDate.';
  }

  @override
  String get cancellationRequestedTheActiveCommandMay =>
      'Cancellation requested. The active command may have started; no later Host will run.';

  @override
  String get cancellationRequestedTheCommandMayAlready =>
      'Cancellation requested. The command may already have started; it will not be retried.';

  @override
  String get capabilities => 'Capabilities';

  @override
  String get changeMasterPassword => 'Change master password';

  @override
  String changeToRole(String role) {
    return 'Change to $role';
  }

  @override
  String changeUsernameFromItemToRole(
    String username,
    Object item,
    String role,
  ) {
    return 'Change $username from $item to $role? This signs a new membership version and rotates the Vault key for every remaining active member device. Pending invitation tokens become invalid and must be reissued. Old key copies cannot be erased remotely.';
  }

  @override
  String get changingPassword => 'Changing password…';

  @override
  String get checkBucketAccess => 'Check bucket access';

  @override
  String get checkForUpdates => 'Check for updates';

  @override
  String get checkingConfiguredBucketAccessWithHeadbucket =>
      'Checking configured bucket access with HeadBucket…';

  @override
  String get checkingOnlineDevices => 'Checking online devices…';

  @override
  String get checkingThisSelfHostedInstanceFor =>
      'Checking this self-hosted instance for a newer Web build…';

  @override
  String get choose2575 => 'Choose 25–75';

  @override
  String get chooseConnectOnTheLeftTo =>
      'Choose Connect on the left to start a new session.';

  @override
  String get chooseAHost => 'Choose a Host';

  @override
  String chooseAHostForPaneValuevalue(int valueValue) {
    return 'Choose a Host for Pane $valueValue';
  }

  @override
  String get chooseAHostFromTheActive =>
      'Choose a Host from the active Vault. The replacement is saved as an encrypted layout update; it will not connect.';

  @override
  String get chooseAHostOnTheLeft =>
      'Choose a host on the left to start an SSH session.';

  @override
  String get chooseALocalEncryptedArchiveOr =>
      'Choose a local encrypted archive or its remote replica to prepare a separate copy while the service stays online. Remote bytes are checked against their digest and archive authentication before the stage is published. This action does not activate the copy or replace live data; operators handle any later offline cutover.';

  @override
  String get chooseALocalEncryptedArchiveTo =>
      'Choose a local encrypted archive to prepare a separate copy while the service stays online. The archive is checked again before the stage is published. This action does not activate the copy or replace live data; operators handle any later offline cutover.';

  @override
  String get chooseANewMasterPasswordDifferent =>
      'Choose a new master password different from the current one.';

  @override
  String get chooseASourceForEachChanged =>
      'Choose a source for each changed field. The conflict branch is the verified losing version; the current Vault version is the committed head.';

  @override
  String get chooseActiveVaultDevicesThatMay =>
      'Choose active Vault devices that may observe encrypted terminal output. Observers cannot type or resize the host terminal. This list is fixed for the session; a device only receives output sent after it joins, with no earlier scrollback replay.';

  @override
  String get chooseConnectedHosts => 'Choose connected Hosts';

  @override
  String get chooseHowOftenThisServerCreates =>
      'Choose how often this server creates an encrypted backup. The archive destination and encryption key stay private on the server.';

  @override
  String get chooseOneDeviceAlreadyApprovedFor =>
      'Choose one device already approved for this share. It can type into this SSH session for up to five minutes; the SSH connection stays on this host device.';

  @override
  String get chooseTheDefaultPreferenceRecordTo =>
      'Choose the default preference record to keep';

  @override
  String get chooseTheDefaultWorkspaceSectionFor =>
      'Choose the default workspace section for the active Vault. This preference is encrypted before syncing to devices with access to the Vault.';

  @override
  String get chooseTheShortcutPreferenceRecordTo =>
      'Choose the shortcut preference record to keep';

  @override
  String get chooseTheTerminalFontSizeRecord =>
      'Choose the terminal font-size record to keep';

  @override
  String get chooseTheTerminalPaletteSharedBy =>
      'Choose the terminal palette shared by every device authorized for this Vault. The selected palette is stored as an encrypted, allowlisted preference.';

  @override
  String get chooseTheTerminalThemeRecordTo =>
      'Choose the terminal-theme record to keep';

  @override
  String get cleanupPending => 'Cleanup pending';

  @override
  String get clearLocalHistoryOnlyRemovesThis =>
      'Clear local history only removes this device’s rows. It does not delete records already synced to the Vault.';

  @override
  String get clearThisHostsLocalHistory => 'Clear this host’s local history';

  @override
  String get closeActiveSshTerminalsBeforeApplying =>
      'Close active SSH terminals before applying the update.';

  @override
  String get closeSavedLayoutPreview => 'Close saved layout preview';

  @override
  String get color2 => 'Color';

  @override
  String get commaOrLineSeparatedPortNumbers =>
      'Comma or line separated port numbers.';

  @override
  String get commaOrNewlineSeparatedForExample =>
      'Comma or newline separated, for example 22, 2222';

  @override
  String get commandHistory => 'Command history';

  @override
  String get commandSnippets => 'Command snippets';

  @override
  String get commandSuggestions => 'Command suggestions';

  @override
  String get commandsAppearHereAfterTheHook =>
      'Commands appear here after the hook is pasted and a command finishes.';

  @override
  String get commandsRunOneAtATime =>
      'Commands run one at a time. A failure, non-zero exit, timeout, or unknown result stops the batch; no command is retried.';

  @override
  String get compareEachValueAndRecordId =>
      'Compare each value and record ID. The chosen record ID stays active; the other records are removed with encrypted tombstones.';

  @override
  String get compareThisPublicFingerprintWithAnother =>
      'Compare this public fingerprint with another device or a trusted administrator over a separate channel to confirm the instance identity.';

  @override
  String get comparedWithTheLastVerifiedServer =>
      'Compared with the last verified server metadata; this value may be stale while offline.';

  @override
  String get compatibilityReportNotReported =>
      'Compatibility report · not reported';

  @override
  String get compatibilityReportUnverifiedDetailsHidden =>
      'Compatibility report · unverified; details hidden';

  @override
  String get completionStatusUnknown => 'Completion status unknown';

  @override
  String get concurrentLayoutEditsAreKeptAs =>
      'Concurrent layout edits are kept as separate encrypted branches. Saving this device branch as a named copy leaves the original conflict open; no pane is connected.';

  @override
  String get confirmAndReAuthenticate => 'Confirm and re-authenticate';

  @override
  String get confirmAndRun => 'Confirm and run';

  @override
  String confirmAndRunOnCountHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Hosts',
      one: '1 Host',
    );
    return 'Confirm and run on $_temp0';
  }

  @override
  String get confirmArchivePassword => 'Confirm archive password';

  @override
  String get confirmNewMasterPassword => 'Confirm new master password';

  @override
  String get confirmRevokeInvitation => 'Confirm revoke invitation';

  @override
  String confirmTargetName(String name) {
    return 'Confirm target: $name';
  }

  @override
  String get conflictBranches => 'Conflict branches';

  @override
  String get conflictResolutionSynced => 'Conflict resolution synced.';

  @override
  String conflictingSshKeysAreSavedFor(String join) {
    return 'Conflicting SSH keys are saved for $join. Connections are blocked. Revoke every key you do not intend to trust; if neither fingerprint is verified, revoke both, then approve a key only after checking it out of band.';
  }

  @override
  String get conflictingBranchesArePreservedUntilYou =>
      'Conflicting branches are preserved until you choose the version to keep.';

  @override
  String get connect => 'Connect';

  @override
  String get connectAnSshHostToBrowse =>
      'Connect an SSH host to browse remote files.';

  @override
  String connectToNameToOpenAn(String name) {
    return 'Connect to $name to open an interactive shell.';
  }

  @override
  String get connectionSettingsAreKeptAsOne =>
      'Connection settings are kept as one tuple. Review the original base and both verified branches, then select one complete tuple. This includes the address, port, SSH username, authentication method, selected Credential, route, proxy, forwarding rules, and host trust settings.';

  @override
  String get connections => 'Connections';

  @override
  String connectionsToEndpointUsingAlgorithmWill(
    String endpoint,
    String algorithm,
  ) {
    return 'Connections to $endpoint using $algorithm will be blocked on devices after this signed revocation syncs. The fingerprint remains in history.';
  }

  @override
  String get consumed => 'Consumed';

  @override
  String get continueToFinalConfirmation => 'Continue to final confirmation';

  @override
  String get continueToReAuthenticate => 'Continue to re-authenticate';

  @override
  String get controlActive => 'Control active';

  @override
  String get copied => 'Copied';

  @override
  String get copiedPasteThisCommandIntoThe =>
      'Copied. Paste this command into the terminal:';

  @override
  String get copiesWaiting => 'Copies waiting';

  @override
  String get copy => 'Copy';

  @override
  String get copyCode => 'Copy code';

  @override
  String get copyCredential => 'Copy credential';

  @override
  String get copyFailedSelectTheValueManually =>
      'Copy failed; select the value manually';

  @override
  String get copyInvitationToken => 'Copy invitation token';

  @override
  String get copySignedShareRequest => 'Copy signed share request';

  @override
  String get copyTerminalShareId => 'Copy terminal share ID';

  @override
  String get copyThisOneTimeInvitationToken =>
      'Copy this one-time invitation token and share it with the intended account holder. It will not be shown again after this dialog closes.';

  @override
  String get copyThisResponseToTheNew =>
      'Copy this response to the new browser. It contains public identity material and sealed key envelopes, not private keys.';

  @override
  String get copyToken => 'Copy token';

  @override
  String get copyingEncryptedArchive => 'Copying encrypted archive';

  @override
  String get couldNotClearThisHostsLocal =>
      'Could not clear this host’s local history.';

  @override
  String get couldNotConfirmInputControlRevocation =>
      'Could not confirm input control revocation. The host SSH connection remains active.';

  @override
  String get couldNotCopyTheSetupCommand =>
      'Could not copy the setup command. No command was sent to the remote shell.';

  @override
  String get couldNotEnableVaultHistorySync =>
      'Could not enable Vault history sync. Check that the active Vault is writable and try again.';

  @override
  String get couldNotExportAnonymousSyncDiagnostics =>
      'Could not export anonymous sync diagnostics.';

  @override
  String get couldNotGrantInputControlCheck =>
      'Could not grant input control. Check the session and try again.';

  @override
  String get couldNotJoinCheckTheSession =>
      'Could not join. Check the session ID and Vault access.';

  @override
  String couldNotLoadTheCurrentHost(String friendlyError) {
    return 'Could not load the current Host: $friendlyError';
  }

  @override
  String get couldNotRemoveThisForwardingProfile =>
      'Could not remove this forwarding profile. Check the connection, then sync and retry.';

  @override
  String get couldNotSaveForwardingSettingsSync =>
      'Could not save forwarding settings. Sync and retry; your current settings are unchanged.';

  @override
  String get couldNotSaveTerminalFontSize =>
      'Could not save terminal font size. Check Vault write access and try again.';

  @override
  String get couldNotSaveTerminalShortcutsCheck =>
      'Could not save terminal shortcuts. Check Vault write access and try again.';

  @override
  String get couldNotSaveTerminalThemeCheck =>
      'Could not save terminal theme. Check Vault write access and try again.';

  @override
  String couldNotSaveTheReviewedTuple(String friendlyError) {
    return 'Could not save the reviewed tuple: $friendlyError';
  }

  @override
  String get couldNotSaveThisGroupYour =>
      'Could not save this group. Your changes remain in the form; check Vault access and retry.';

  @override
  String get couldNotSaveThisPreferenceCheck =>
      'Could not save this preference. Check Vault write access and try again.';

  @override
  String get couldNotStartOrStopThis =>
      'Could not start or stop this forward. Check port availability and SSH server forwarding policy.';

  @override
  String get couldNotStartTerminalSharingCheck =>
      'Could not start terminal sharing. Check the Vault and network, then retry.';

  @override
  String get couldNotTurnOffVaultHistory =>
      'Could not turn off Vault history sync. Please try again.';

  @override
  String get create2 => 'Create';

  @override
  String get createVault => 'Create Vault';

  @override
  String get createADedicatedReadOnlyBearer =>
      'Create a dedicated read-only Bearer credential for GET /api/v1/admin/metrics. The secret is shown once and never saved by this app.';

  @override
  String get createAGroupToOrganizeRelated =>
      'Create a group to organize related servers.';

  @override
  String get createAnotherVault => 'Create another Vault';

  @override
  String get createCredential => 'Create credential';

  @override
  String get createEncryptedVault => 'Create encrypted Vault';

  @override
  String get createGroup => 'Create group';

  @override
  String get createInvitation => 'Create invitation';

  @override
  String get createRemoteFolder => 'Create remote folder';

  @override
  String get createResolution => 'Create resolution';

  @override
  String get createSnippet => 'Create snippet';

  @override
  String get createSplitWorkspace => 'Create split Workspace';

  @override
  String get createUsernameBoundInvitationsAndReview =>
      'Create username-bound invitations and review their status.';

  @override
  String get createYourFirstGroup => 'Create your first group';

  @override
  String get createYourFirstHostAndAttach =>
      'Create your first host and attach a client-side encrypted SSH credential. Nothing here is sample or demo data.';

  @override
  String get created => 'Created';

  @override
  String get createdAt => 'Created at';

  @override
  String createdFormattimeUpdatedFormattime2(
    String formatTime,
    String formatTime2,
  ) {
    return 'Created $formatTime · updated $formatTime2';
  }

  @override
  String createdFormat(String format) {
    return 'Created · $format';
  }

  @override
  String get createsAV2RoomInputStays =>
      'Creates a v2 room. Input stays off until you grant one approved device a lease of up to five minutes.';

  @override
  String get credential => 'Credential';

  @override
  String credentialActionsName(String name) {
    return 'Credential actions: $name';
  }

  @override
  String get credentialMergeSavedAndSyncing =>
      'Credential merge saved and syncing';

  @override
  String get credentialName2 => 'Credential name';

  @override
  String credentialReferenceNameMustPointTo(String name) {
    return 'Credential reference $name must point to a password Credential';
  }

  @override
  String credentialReferenceNameWasNotFound(String name) {
    return 'Credential reference $name was not found in this Vault';
  }

  @override
  String get credentialSelectionProxySettingsForwardingDetails =>
      'Credential selection, proxy settings, forwarding details, and host trust material are masked. They are preserved from the selected branch.';

  @override
  String get credentialStatus => 'Credential status';

  @override
  String get credentialValuesAreSentOnlyThrough =>
      'Credential values are sent only through the encrypted SSH exec channel. The remote program receives them as arguments and may expose them to processes running as the same remote user.';

  @override
  String credentialNameUsernameValuevalue(
    String name,
    String username,
    String valueValue,
  ) {
    return 'Credential: $name; $username; $valueValue';
  }

  @override
  String get currentVault2 => 'Current Vault';

  @override
  String get currentAccount => 'Current account';

  @override
  String currentAccountValuevalue(String valueValue) {
    return 'Current account: $valueValue';
  }

  @override
  String get currentDevice => 'Current device';

  @override
  String currentHeadShortauditid(String shortAuditId) {
    return 'Current head: $shortAuditId';
  }

  @override
  String get currentMasterPassword => 'Current master password';

  @override
  String get currentSignedInAccountAdministrativeActions =>
      'Current signed-in account · administrative actions hidden';

  @override
  String get cursorPolicy => 'Cursor policy';

  @override
  String get deletionScheduled => 'DELETION SCHEDULED';

  @override
  String get deadLettered => 'Dead-lettered';

  @override
  String get defaultLabel2 => 'Default';

  @override
  String get defaultSshCredential => 'Default SSH credential';

  @override
  String defaultSectionSectionlabelRecordIdId(
    String sectionLabel,
    String id,
    String revisionLabel,
  ) {
    return 'Default section: $sectionLabel; Record ID: $id; Revision: $revisionLabel';
  }

  @override
  String get defaultWorkspaceSection => 'Default workspace section';

  @override
  String defaultDefaultvalue(Object defaultValue) {
    return 'Default: $defaultValue';
  }

  @override
  String get delete2 => 'Delete';

  @override
  String get deleteForwardingProfile => 'Delete forwarding profile';

  @override
  String get deleteGroup3 => 'Delete group';

  @override
  String get deleteGroup4 => 'Delete group?';

  @override
  String get deleteServerManagedGroup => 'Delete server-managed group';

  @override
  String get deleteServerManagedGroup2 => 'Delete server-managed group?';

  @override
  String get deleteThisItem => 'Delete this item?';

  @override
  String get deletingAccountAdministrativeActionsUnavailable =>
      'Deleting account · administrative actions unavailable';

  @override
  String get deletingThisVaultStartsTheServer =>
      'Deleting this Vault starts the server configured grace period. Members become read-only immediately; the exact purge deadline is returned by the server.';

  @override
  String get deletionCanceledPendingEncryptedSyncCan =>
      'Deletion canceled; pending encrypted sync can resume.';

  @override
  String get deletionRequested => 'Deletion requested';

  @override
  String get deletionScheduledByTheServer =>
      'Deletion scheduled by the server.';

  @override
  String deletionScheduledServerPurgeAfterVaultlifecycledate(
    String vaultLifecycleDate,
  ) {
    return 'Deletion scheduled. Server purge after $vaultLifecycleDate.';
  }

  @override
  String get deliveryHistoryIsUnavailableOnThis =>
      'Delivery history is unavailable on this server.';

  @override
  String get deliveryWindowUtc => 'Delivery window (UTC)';

  @override
  String get deploymentCidrLimits => 'Deployment CIDR limits';

  @override
  String get deploymentPortLimits => 'Deployment port limits';

  @override
  String get deploymentRelayAvailability => 'Deployment relay availability';

  @override
  String get destinationOnSshTarget => 'Destination on SSH target';

  @override
  String get destinationOnThisDevice => 'Destination on this device';

  @override
  String get deviceId => 'Device ID';

  @override
  String get deviceSocksListenerAddress => 'Device SOCKS listener address';

  @override
  String get deviceAccessRevoked => 'Device access revoked';

  @override
  String get deviceApproved => 'Device approved';

  @override
  String get deviceCapabilitySignerIsInvalid =>
      'Device capability signer is invalid.';

  @override
  String get deviceCompatibilityReportIsInvalid =>
      'Device compatibility report is invalid.';

  @override
  String get deviceListenerAddress => 'Device listener address';

  @override
  String get deviceRevoked3 => 'Device revoked';

  @override
  String deviceSubstring(String substring) {
    return 'Device $substring';
  }

  @override
  String get devicesActive => 'Devices active';

  @override
  String get diagnosticsExportCancelled => 'Diagnostics export cancelled.';

  @override
  String get direction => 'Direction';

  @override
  String get directory => 'Directory';

  @override
  String get directoryIsEmpty => 'Directory is empty';

  @override
  String get disableAccount => 'Disable account';

  @override
  String get disableAccountRecovery2 => 'Disable account recovery';

  @override
  String get disableAccountRecovery => 'Disable account recovery?';

  @override
  String get disableAccount2 => 'Disable account?';

  @override
  String get disableOrReEnableAccountsAnd =>
      'Disable or re-enable accounts and revoke their active sessions.';

  @override
  String get disableRecovery => 'Disable recovery';

  @override
  String disableUsernameServerSessionsWillBe(String username) {
    return 'Disable $username? Server sessions will be revoked and they will not be able to sign in again. Cached device data will not be erased, and existing direct SSH connections may continue until their SSH servers close them.';
  }

  @override
  String get disabledByPolicy => 'Disabled by policy';

  @override
  String get discardIsolatedCopy => 'Discard isolated copy';

  @override
  String get discardIsolatedRestoreCopy => 'Discard isolated restore copy?';

  @override
  String get discarded => 'Discarded';

  @override
  String get disconnect2 => 'Disconnect';

  @override
  String get disconnected2 => 'Disconnected';

  @override
  String get disconnectedRecursivePreview => 'Disconnected recursive preview';

  @override
  String get disconnectedConnectTabsExplicitly =>
      'Disconnected · connect tabs explicitly';

  @override
  String disconnectedDirectionlabelFirstpercentSecondpercentPanecountPanes(
    String directionLabel,
    int firstPercent,
    int secondPercent,
    int paneCount,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      paneCount,
      locale: localeName,
      other: '$paneCount panes',
      one: '1 pane',
    );
    return 'Disconnected · $directionLabel · $firstPercent/$secondPercent · $_temp0 · Connect panes explicitly';
  }

  @override
  String get done2 => 'Done';

  @override
  String get download2 => 'Download';

  @override
  String get due => 'Due';

  @override
  String get duplicate => 'Duplicate';

  @override
  String get duplicateWorkspace => 'Duplicate workspace';

  @override
  String get dynamicSocks5 => 'Dynamic SOCKS5';

  @override
  String dynamicSocks5Bind(String bind) {
    return 'Dynamic SOCKS5 · $bind';
  }

  @override
  String get dynamicForwardingIsALoopbackOnly =>
      'Dynamic forwarding is a loopback-only SOCKS5 CONNECT proxy without SOCKS authentication. Use it only on a trusted device.';

  @override
  String get eachDeviceKeepsItsPrivateSigning =>
      'Each device keeps its private signing and encryption keys locally. Approval sends only opaque sealed envelopes containing each Vault key epoch that this device can access. Never approve an enrollment you did not request.';

  @override
  String get eachSelectedHostReceivesReferencedCredential =>
      'Each selected Host receives referenced Credential secrets through its encrypted SSH exec channel. The remote program receives them as arguments and may expose them to processes running as the same remote user.';

  @override
  String get edit2 => 'Edit';

  @override
  String get editVaultQuota => 'Edit Vault quota';

  @override
  String get editCommandSnippet => 'Edit command snippet';

  @override
  String get editCredential2 => 'Edit credential';

  @override
  String get editForwardingProfile => 'Edit forwarding profile';

  @override
  String get editGroup2 => 'Edit group';

  @override
  String get editHostGroup => 'Edit host group';

  @override
  String get editQuota => 'Edit quota';

  @override
  String get editText2 => 'Edit text';

  @override
  String editableCeilingValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Editable ceiling: $valueValue · CIDRs: $summarize · ports: $summarize2';
  }

  @override
  String get editorCanEditVaultRecords => 'Editor · can edit Vault records';

  @override
  String get effectiveSshRelayService => 'Effective SSH relay service';

  @override
  String effectiveGroupStateValuevalueCidrsSummarize(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Effective group state: $valueValue · CIDRs: $summarize · ports: $summarize2';
  }

  @override
  String effectiveStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Effective state: $valueValue · CIDRs: $summarize · ports: $summarize2';
  }

  @override
  String get enableBashCommandHistory => 'Enable Bash command history';

  @override
  String get enableBashIntegration => 'Enable Bash integration';

  @override
  String get enableRelayForThisAccount => 'Enable Relay for this account';

  @override
  String get enableRelayForThisGroup => 'Enable Relay for this group';

  @override
  String get enableSshRelay => 'Enable SSH relay';

  @override
  String get enableVaultSync => 'Enable Vault sync';

  @override
  String get enableAndCopy => 'Enable and copy';

  @override
  String get enableHostApprovedInputControl =>
      'Enable host-approved input control';

  @override
  String get enableScheduledBackups => 'Enable scheduled backups';

  @override
  String get enabledForThisDeviceTheServer =>
      'Enabled for this device. The server sends only a generic sync hint.';

  @override
  String get enablingSyncUploadsUpTo500 =>
      'Enabling sync uploads up to 500 existing local commands for hosts in the active Vault, then uploads future commands. Commands are encrypted with the active Vault key, and any Vault member with access can read them. Turning sync off cancels queued commands that have not been sent. Commands already sent or committed may still arrive and remain in the Vault.';

  @override
  String get encryptVaultArchive => 'Encrypt Vault archive';

  @override
  String get encryptedVaultArchiveSaved => 'Encrypted Vault archive saved.';

  @override
  String get encryptedArchive => 'Encrypted archive';

  @override
  String get encryptedArchiveBytes => 'Encrypted archive bytes';

  @override
  String get encryptedBackup => 'Encrypted backup';

  @override
  String get encryptedBackupsAreCreatedOnThe =>
      'Encrypted backups are created on the server after the operator configures owner-only ATERMIUS_BACKUP_ARCHIVE_DIR and ATERMIUS_BACKUP_KEY_FILE paths outside the instance data directory. No archive or key paths are sent by this client.';

  @override
  String encryptedObjectBlocksCount(int count) {
    return 'Encrypted object blocks: $count';
  }

  @override
  String get encryptedRecordsImmutableRetriesAndRecovery =>
      'Encrypted records, immutable retries and recovery checkpoints for this Vault.';

  @override
  String get encryptedWithTheActiveVaultKey =>
      'Encrypted with the active Vault key. Members with access can read it. Turning sync off cancels unsent queued commands; sent or committed commands may still arrive and remain in the Vault.';

  @override
  String get encryptionKeyFingerprint => 'Encryption key fingerprint';

  @override
  String get encryptionKeyFingerprintSha256 =>
      'Encryption key fingerprint · SHA-256';

  @override
  String get enrollmentJson => 'Enrollment JSON';

  @override
  String get enrollmentJsonIsNotValid => 'Enrollment JSON is not valid.';

  @override
  String get enterAWorkspaceName => 'Enter a Workspace name';

  @override
  String get enterAQuotaFrom1Byte => 'Enter a quota from 1 byte through 1 TiB.';

  @override
  String get enterASupportedNonReservedChord =>
      'Enter a supported, non-reserved chord such as mod+alt+shift+f. Each chord must be valid and unique.';

  @override
  String get enterAWholeNumberFrom1 => 'Enter a whole number from 1 to 720.';

  @override
  String get enterAWholeNumberPercent => 'Enter a whole-number percent';

  @override
  String get enterRequiredValuesToPreview =>
      'Enter required values to preview.';

  @override
  String get enterTheCurrentMasterPasswordAt =>
      'Enter the current master password (at least 12 characters).';

  @override
  String get enterTheSessionUuidProvidedBy =>
      'Enter the session UUID provided by the host. This opens a separate read-only terminal and does not create an SSH connection.';

  @override
  String epochKeyVersionsCount(int count) {
    return 'Epoch key versions: $count';
  }

  @override
  String get eventId => 'Event ID';

  @override
  String get everyActiveVaultDeviceMustSupport =>
      'Every active Vault device must support redaction v1 before this record can be purged. Upgrade or retire unsupported devices, then retry.';

  @override
  String get everyRoleChangeAndRevocationCommits =>
      'Every role change and revocation commits a signed membership update with a new key epoch. The Owner and all retained active member devices receive the new key.';

  @override
  String get executionMode => 'Execution mode';

  @override
  String get executionPreview => 'Execution preview';

  @override
  String existingShellLabelShell2(String shell) {
    return 'Existing shell label: $shell';
  }

  @override
  String exitCodeExitcode(Object exitCode) {
    return 'Exit code: $exitCode';
  }

  @override
  String exitExitstatusCompletedat(int exitStatus, String completedAt) {
    return 'Exit $exitStatus · $completedAt';
  }

  @override
  String get expectedAJsonArray => 'Expected a JSON array';

  @override
  String get expired => 'Expired';

  @override
  String get expires => 'Expires';

  @override
  String get exportArchive => 'Export archive';

  @override
  String get exportDiagnostics => 'Export diagnostics';

  @override
  String get exportTheFixedServerHistoryCurrent =>
      'Export the fixed server history, current tombstones, local outbox/conflict branches and encrypted object blocks. A separate archive password protects the file with Argon2id and XChaCha20-Poly1305.';

  @override
  String get failed2 => 'Failed';

  @override
  String get failureCategory => 'Failure category';

  @override
  String get favorite => 'Favorite';

  @override
  String get file => 'File';

  @override
  String get filterCommands => 'Filter commands';

  @override
  String get fingerprintsApprovedDuringSshConnectionAre =>
      'Fingerprints approved during SSH connection are encrypted in this Vault and sync to its devices. Revocation is also encrypted and leaves the approval history visible. Old device-only pins are not imported as Vault trust.';

  @override
  String get finish => 'Finish';

  @override
  String get finishedAt => 'Finished at';

  @override
  String get firstChild => 'First child (%)';

  @override
  String get focus => 'Focus';

  @override
  String get folderName => 'Folder name';

  @override
  String get forExample104000 => 'For example: 10.40.0.0/16';

  @override
  String get forwardType => 'Forward type';

  @override
  String get freeFormScriptLegacy => 'Free-form script (legacy)';

  @override
  String get futureAutomaticPurgeConsentWithdrawn =>
      'Future automatic purge consent withdrawn.';

  @override
  String get generatedAt => 'Generated at';

  @override
  String get generation => 'Generation';

  @override
  String get generationCheckpoint => 'Generation checkpoint';

  @override
  String get generationMatches => 'Generation matches';

  @override
  String get generationMismatch => 'Generation mismatch';

  @override
  String get go => 'Go';

  @override
  String get goToPath => 'Go to path';

  @override
  String get goToRemotePath => 'Go to remote path';

  @override
  String get grantFor5Minutes => 'Grant for 5 minutes';

  @override
  String get grantInputControl => 'Grant input control';

  @override
  String get groupRelayPolicy => 'Group Relay policy';

  @override
  String groupActionsName2(String name) {
    return 'Group actions: $name';
  }

  @override
  String get groupName3 => 'Group name';

  @override
  String groupRevisionRevisionMembershipRevisionMembershiprevision(
    int revision,
    int membershipRevision,
    int revision2,
  ) {
    return 'Group revision $revision · membership revision $membershipRevision · policy revision $revision2';
  }

  @override
  String groupGroupname(Object groupName) {
    return 'Group: $groupName';
  }

  @override
  String headShortauditid(String shortAuditId) {
    return 'Head $shortAuditId';
  }

  @override
  String get hideRelayPolicy => 'Hide Relay policy';

  @override
  String get hidePasswordSecret => 'Hide password secret';

  @override
  String get hideSessions => 'Hide sessions';

  @override
  String get host => 'Host';

  @override
  String get hostConnectionSettingsReviewedAndQueued =>
      'Host connection settings reviewed and queued to sync.';

  @override
  String get hostGroups => 'Host groups';

  @override
  String get hostIsNoLongerAvailableSync =>
      'Host is no longer available; sync and retry.';

  @override
  String get hostUnavailable => 'Host unavailable';

  @override
  String hostPaneValuevalue(int valueValue) {
    return 'Host · Pane $valueValue';
  }

  @override
  String get hostApprovedTerminalInput => 'Host-approved terminal input';

  @override
  String hostNameUsernameEndpointValuevalue(
    String name,
    String username,
    String endpoint,
    String valueValue,
  ) {
    return 'Host: $name; $username@$endpoint$valueValue';
  }

  @override
  String get hostsWithoutAnOverrideInheritThe =>
      'Hosts without an override inherit the nearest Group default.';

  @override
  String get iStoredThisCodeSecurely => 'I stored this code securely';

  @override
  String get iUnderstandBoundedMaintenanceMayPurge =>
      'I understand bounded Maintenance may purge this tombstone after its restore deadline and required checks.';

  @override
  String get iUnderstandThisPermanentlyRemovesThe =>
      'I understand this permanently removes the record from active server state.';

  @override
  String get iveSavedIt => 'I\'ve saved it';

  @override
  String get idle => 'Idle';

  @override
  String get ifCopyingIsUnavailableSelectThe =>
      'If copying is unavailable, select the value above.';

  @override
  String get ifYouOwnASharedVault =>
      'If you own a shared Vault with other active or invited members, the server rejects deletion; ownership is not transferred. During the grace period you can cancel from the login page using your account name and master password, then sign in again. Save an encrypted archive before continuing.';

  @override
  String get importSshConfig => 'Import SSH config';

  @override
  String get importArchive => 'Import archive';

  @override
  String get importToThisVault => 'Import to this Vault';

  @override
  String get importVerifiedVaultArchive => 'Import verified Vault archive?';

  @override
  String importedImportedHostSRecordsAre(int imported) {
    String _temp0 = intl.Intl.pluralLogic(
      imported,
      locale: localeName,
      other: '$imported Hosts',
      one: '1 Host',
    );
    return 'Imported $_temp0; records are encrypted and queued to sync.';
  }

  @override
  String get includesTheInstanceAccountAndEvery =>
      'Includes the instance, account and every assigned server group.';

  @override
  String get inputControlOff => 'Input control: off';

  @override
  String get inputControlRevoking => 'Input control: revoking';

  @override
  String inputControlControllerlabel(Object controllerLabel) {
    return 'Input control: $controllerLabel';
  }

  @override
  String get inputIsEncryptedToTheHost =>
      'Input is encrypted to the host and expires with the host-approved lease. Resize remains disabled; only live output is available.';

  @override
  String get installationWideEventsSeparateFromAccount =>
      'Installation-wide events, separate from account and Vault audit pages.';

  @override
  String get instance => 'Instance';

  @override
  String get instanceId => 'Instance ID';

  @override
  String get instanceVaultQuotas => 'Instance Vault quotas';

  @override
  String get instanceAccountsAndSessions => 'Instance accounts and sessions';

  @override
  String get instanceAdminAudit => 'Instance admin audit';

  @override
  String get instanceAdminOverview => 'Instance admin overview';

  @override
  String get instanceBackupStatus => 'Instance backup status';

  @override
  String get instanceJobs => 'Instance jobs';

  @override
  String instanceRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return 'Instance revision $revision · updated $formatTime';
  }

  @override
  String get instanceSigningKeyFingerprintSha256 =>
      'Instance signing key fingerprint · SHA-256';

  @override
  String get instanceWideBootstrapAndNetworkPolicy =>
      'Instance-wide bootstrap and network policy are managed by the self-hosted server operator.';

  @override
  String get interrupted => 'Interrupted';

  @override
  String get interruptedRetryPending => 'Interrupted · retry pending';

  @override
  String get intervalInHours => 'Interval in hours';

  @override
  String get invalidFontSizeValue => 'Invalid font-size value';

  @override
  String get invalidToken7UtcDays => 'Invalid token (7 UTC days)';

  @override
  String get inventoryEntryStale => 'Inventory entry stale';

  @override
  String get invitationCreated => 'Invitation created';

  @override
  String get invitationExpired => 'Invitation expired';

  @override
  String get invitationExpiresInDays => 'Invitation expires in days';

  @override
  String invitationExpiresFormattedexpiry(String formattedExpiry) {
    return 'Invitation expires $formattedExpiry';
  }

  @override
  String get invitationNeedsReissue => 'Invitation needs reissue';

  @override
  String get invitationPending => 'Invitation pending';

  @override
  String get invitationToken => 'Invitation token';

  @override
  String get invitationTokenCopied => 'Invitation token copied.';

  @override
  String get invitationUsername => 'Invitation username';

  @override
  String get inviteMember => 'Invite member';

  @override
  String inviteToCurrentvaultname(String currentVaultName) {
    return 'Invite to $currentVaultName';
  }

  @override
  String get issueAccountInvitation => 'Issue account invitation';

  @override
  String get issueCategory => 'Issue category';

  @override
  String get join => 'Join';

  @override
  String get joinASharedTerminal => 'Join a shared terminal';

  @override
  String get joinHostGrantedControl => 'Join host-granted control';

  @override
  String get keepVault => 'Keep Vault';

  @override
  String get keepAccess => 'Keep access';

  @override
  String get keepAccount => 'Keep account';

  @override
  String get keepCurrentOwner => 'Keep current Owner';

  @override
  String get keepRepeatableCommandsInTheSame =>
      'Keep repeatable commands in the same encrypted vault as your hosts.';

  @override
  String get keepScheduledDeletion => 'Keep scheduled deletion';

  @override
  String get keepSelectedBindingsAndRemoveDuplicates =>
      'Keep selected bindings and remove duplicates';

  @override
  String get keepSelectedFontSizeAndRemove =>
      'Keep selected font size and remove duplicates';

  @override
  String get keepSelectedRecordAndRemoveDuplicates =>
      'Keep selected record and remove duplicates';

  @override
  String get keepSelectedThemeAndRemoveDuplicates =>
      'Keep selected theme and remove duplicates';

  @override
  String get keepThisDeviceVersion => 'Keep this device version';

  @override
  String get keepThisDeviceVersion2 => 'Keep this device version?';

  @override
  String get keyPassphraseOptional => 'Key passphrase (optional)';

  @override
  String get keyUpdateNeeded => 'Key update needed';

  @override
  String get knownHost => 'Known Host';

  @override
  String get lastChanged => 'Last changed';

  @override
  String get lastPull => 'Last pull';

  @override
  String get lastRun => 'Last run';

  @override
  String get lastRunStatus => 'Last run status';

  @override
  String get lastSuccessfulSync => 'Last successful sync';

  @override
  String get lastUpdated => 'Last updated';

  @override
  String lastVerifiedServerShortkey(String shortKey) {
    return 'Last verified server: $shortKey';
  }

  @override
  String get latestCopy => 'Latest copy';

  @override
  String get leased => 'Leased';

  @override
  String get leaveSharedTerminal => 'Leave shared terminal';

  @override
  String get loadRelayPolicies => 'Load Relay policies';

  @override
  String get loadVaults => 'Load Vaults';

  @override
  String get loadAccountInvitations => 'Load account invitations';

  @override
  String get loadAccountsToAddMembers => 'Load accounts to add members';

  @override
  String get loadAdminAccounts => 'Load admin accounts';

  @override
  String get loadAdminAudit => 'Load admin audit';

  @override
  String get loadBackupSchedule => 'Load backup schedule';

  @override
  String get loadBackupStatus => 'Load backup status';

  @override
  String get loadInstanceJobs => 'Load instance jobs';

  @override
  String get loadOverview => 'Load overview';

  @override
  String get loadPushHealth => 'Load push health';

  @override
  String get loadRelayPolicy => 'Load relay policy';

  @override
  String get loadReplicationStatus => 'Load replication status';

  @override
  String get loadRestoreSources => 'Load restore sources';

  @override
  String get loadServerManagedGroups => 'Load server-managed groups';

  @override
  String get loadStatus => 'Load status';

  @override
  String get loadingSshRelayPolicy => 'Loading SSH relay policy…';

  @override
  String get loadingAccountAndInstancePolicyRevisions =>
      'Loading account and instance policy revisions…';

  @override
  String get loadingAccountInvitations => 'Loading account invitations…';

  @override
  String get loadingAccountSessions => 'Loading account sessions…';

  @override
  String get loadingBackupSchedule => 'Loading backup schedule…';

  @override
  String get loadingEncryptedArchiveSources =>
      'Loading encrypted archive sources…';

  @override
  String get loadingGroupMembershipAndRelayPolicy =>
      'Loading group membership and Relay policy…';

  @override
  String get loadingServerManagedGroups => 'Loading server-managed groups…';

  @override
  String get local => 'Local';

  @override
  String get localArchive => 'Local archive';

  @override
  String get localDevice => 'Local device';

  @override
  String get localEditsAreEncryptedAndCommitted =>
      'Local edits are encrypted and committed to the persistent outbox before any network request. A retry reuses the same operation IDs and ciphertext. The server never receives credentials or the Vault key.';

  @override
  String get localEncryptedArchiveUnavailable =>
      'Local encrypted archive unavailable';

  @override
  String localRevisionItem(Object item) {
    return 'Local revision  $item';
  }

  @override
  String localBindDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return 'Local · $bind → $destinationAddress:$destinationPort';
  }

  @override
  String get localOnlyProfiles => 'Local-only profiles';

  @override
  String get lockWorkspace => 'Lock workspace';

  @override
  String get loopbackOnly => 'Loopback only';

  @override
  String get maintenance => 'Maintenance';

  @override
  String get maintenanceRunsTheConfiguredRetentionAnd =>
      'Maintenance runs the configured retention and expired-object cleanup pass. The server reports which instance actions are available.';

  @override
  String get makeEditor => 'Make editor';

  @override
  String get makeViewer => 'Make viewer';

  @override
  String makeUsernameTheSoleOwnerYour(String username) {
    return 'Make $username the sole Owner. Your account will remain an active editor. This action signs a new membership version and rotates the Vault key for every active member device in one atomic update. Pending invitation tokens will become invalid and must be reissued. The new Owner will be able to manage members and delete the Vault.';
  }

  @override
  String get manageVaultMembers => 'Manage Vault members';

  @override
  String get masterPasswordIsUsedOnlyFor =>
      'Master password is used only for client-side key derivation.';

  @override
  String get maxSshRelayConnectionsPerUser =>
      'Max SSH relay connections per user';

  @override
  String get maxRelayConnectionsPerUser => 'Max relay connections per user';

  @override
  String memberEffectiveRelayAccessValuevalueCidrs(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Member effective Relay access: $valueValue · CIDRs: $summarize · ports: $summarize2';
  }

  @override
  String get members => 'Members';

  @override
  String membersCurrentvaultname(String currentVaultName) {
    return 'Members · $currentVaultName';
  }

  @override
  String get mergePasswordFields => 'Merge password fields';

  @override
  String get migrationVersion => 'Migration version';

  @override
  String get missingHost => 'Missing Host';

  @override
  String get moveEncryptedLocalHostsCredentialsGroups =>
      'Move encrypted local Hosts, Credentials, Groups, Snippets, and supported workspace preferences into a new empty sync Vault. The local profile stays intact; migration pauses local edits until every staged record is confirmed by the server.';

  @override
  String moveOrUnassignHostcountHostS(
    int hostCount,
    int childCount,
    String name,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      hostCount,
      locale: localeName,
      other: '$hostCount hosts',
      one: '1 host',
    );
    String _temp1 = intl.Intl.pluralLogic(
      childCount,
      locale: localeName,
      other: '$childCount child groups',
      one: '1 child group',
    );
    return 'Move or unassign $_temp0 and $_temp1 before deleting “$name”.';
  }

  @override
  String get name2 => 'Name';

  @override
  String get needsMoreVaultKeys => 'Needs more Vault keys';

  @override
  String get needsOperatorAttention => 'Needs operator attention';

  @override
  String get networkUnavailable => 'Network unavailable';

  @override
  String get newSshCredential => 'New SSH credential';

  @override
  String get newArchivePassword => 'New archive password';

  @override
  String get newCommandSnippet => 'New command snippet';

  @override
  String get newDevice => 'New device';

  @override
  String get newFirstChild => 'New first child (%)';

  @override
  String get newFolder2 => 'New folder';

  @override
  String get newGroup2 => 'New group';

  @override
  String get newHostGroup => 'New host group';

  @override
  String get newMasterPassword => 'New master password';

  @override
  String get newServerGroupName => 'New server group name';

  @override
  String get newSnippet => 'New snippet';

  @override
  String get newSplitSideBySide => 'New split: side by side';

  @override
  String get newSplitStacked => 'New split: stacked';

  @override
  String get newTab => 'New tab';

  @override
  String get next => 'Next';

  @override
  String get nextAccounts => 'Next accounts';

  @override
  String get nextInvitations => 'Next invitations';

  @override
  String get nextRun => 'Next run';

  @override
  String get nextSessions => 'Next sessions';

  @override
  String get noCliOrServerTriggeredBackup =>
      'No CLI or server-triggered backup attempt recorded.';

  @override
  String get noVaultIsCurrentlyAvailableTo =>
      'No Vault is currently available to this device. Accept an invitation to restore access, or create an independent encrypted Vault.';

  @override
  String get noVaultsFound => 'No Vaults found.';

  @override
  String get noVaultsOnThisPage => 'No Vaults on this page.';

  @override
  String get noAccessibleVaults => 'No accessible Vaults';

  @override
  String get noAccountInvitationsFound => 'No account invitations found.';

  @override
  String get noAccountsFound => 'No accounts found.';

  @override
  String get noAccountsOnThisPage => 'No accounts on this page.';

  @override
  String get noActiveSshSession => 'No active SSH session';

  @override
  String get noActiveVaultDeviceReportsAre =>
      'No active Vault device reports are available.';

  @override
  String get noActiveCredential => 'No active credential';

  @override
  String get noCheckpoint => 'No checkpoint';

  @override
  String get noCommandEventsReceivedYetPaste =>
      'No command events received yet. Paste the copied setup command into an interactive Bash shell and press Enter.';

  @override
  String get noCredentialsSaved => 'No credentials saved';

  @override
  String get noDefaultCredential2 => 'No default credential';

  @override
  String get noDeletedRecordsInThisVault => 'No deleted records in this Vault.';

  @override
  String get noDeviceListLoaded => 'No device list loaded';

  @override
  String get noDevicesOnline => 'No devices online';

  @override
  String get noForwardingProfilesSavedForThis =>
      'No forwarding profiles saved for this Host.';

  @override
  String get noHostGroupsYet => 'No host groups yet';

  @override
  String get noHostKeysHaveBeenApproved =>
      'No host keys have been approved in this Vault.';

  @override
  String get noHostsSavedYet => 'No hosts saved yet';

  @override
  String get noInstanceAdminAuditEvents => 'No instance admin audit events.';

  @override
  String get noInstanceJobs => 'No instance jobs.';

  @override
  String get noInvitationsOnThisPage => 'No invitations on this page.';

  @override
  String get noJobs => 'No jobs';

  @override
  String get noMatchingHosts2 => 'No matching hosts';

  @override
  String get noMatchingSingleLineCommands =>
      'No matching single-line commands.';

  @override
  String get noMembersWereReturned => 'No members were returned.';

  @override
  String get noNewerBundleIsAvailableAt =>
      'No newer bundle is available at this address yet. Update the self-hosted Web assets, then check again.';

  @override
  String get noOpenConflicts => 'No open conflicts';

  @override
  String get noOtherActiveVaultDevicesCan =>
      'No other active Vault devices can receive this terminal share.';

  @override
  String get noPushProviderSnapshotIsAvailable =>
      'No push provider snapshot is available.';

  @override
  String get noRemoteCopyAttemptRecordedYet =>
      'No remote copy attempt recorded yet.';

  @override
  String get noResult => 'No result';

  @override
  String get noSavedWorkspaces => 'No saved workspaces';

  @override
  String get noScheduledBackupRunsRecorded =>
      'No scheduled backup runs recorded';

  @override
  String get noServerManagedGroupsYet => 'No server-managed groups yet.';

  @override
  String get noSessionsFound => 'No sessions found.';

  @override
  String get noSessionsOnThisPage => 'No sessions on this page.';

  @override
  String get noSnippetsYet2 => 'No snippets yet';

  @override
  String get noSupportedEncryptedArchivesAreAvailable =>
      'No supported encrypted archives are available on this page.';

  @override
  String get noVerifiedCandidateIsAvailableRetry =>
      'No verified candidate is available. Retry Vault sync; malformed repair state remains locked.';

  @override
  String get noVerifiedCandidateIsAvailableRetry2 =>
      'No verified candidate is available. Retry a Vault sync; malformed repair state remains locked.';

  @override
  String get noVerifiedCandidateIsAvailableRetry3 =>
      'No verified candidate is available. Retry a Vault sync; malformed repair state stays locked for manual recovery.';

  @override
  String get none => 'None';

  @override
  String get notConfigured => 'Not configured';

  @override
  String get notScheduledYet => 'Not scheduled yet';

  @override
  String get notStarted => 'Not started';

  @override
  String get owner => 'OWNER';

  @override
  String observerState(String state) {
    return 'Observer $state';
  }

  @override
  String get occurredAt => 'Occurred at';

  @override
  String get offByDefaultEnablingUploadsUp =>
      'Off by default. Enabling uploads up to 500 existing local commands for hosts in this Vault and future commands.';

  @override
  String get offSiteEncryptedBackupCopies => 'Off-site encrypted backup copies';

  @override
  String get offline => 'Offline';

  @override
  String get offlineDeviceCopiesAndExportsAre =>
      'Offline device copies and exports are not removed.';

  @override
  String get offlineDeviceCopiesAndRetainedBackups =>
      'Offline device copies and retained backups are not remotely erased.';

  @override
  String get offlineFirstCiphertextOnly => 'Offline-first, ciphertext-only';

  @override
  String get oneCanonicalNetworkCidrPerLine =>
      'One canonical network CIDR per line.';

  @override
  String get oneTimePrometheusScrapeCredential =>
      'One-time Prometheus scrape credential';

  @override
  String get oneTimeInvitationToken => 'One-time invitation token';

  @override
  String get oneTimeToken => 'One-time token';

  @override
  String onlineDeviceStatusCouldNotBe(Object vaultPresenceError) {
    return 'Online device status could not be loaded: $vaultPresenceError';
  }

  @override
  String get onlineStatusUnavailable => 'Online status unavailable';

  @override
  String get onlyASignedEnrollmentFromAn =>
      'Only a signed enrollment from an active device can join this account. Devices receive sealed keys for accessible Vaults, if any.';

  @override
  String get onlyAlreadyConnectedSshSessionsAre =>
      'Only already-connected SSH sessions are available. Select at least two Hosts; each will be reviewed before any command is sent.';

  @override
  String get openSettingsDataAndMigrationTo =>
      'Open Settings → Data and migration to export an encrypted archive';

  @override
  String get openTerminal => 'Open Terminal';

  @override
  String get openTerminalChooseAHostAnd =>
      'Open Terminal, choose a host and connect. SFTP uses the same verified SSH transport.';

  @override
  String get openVault => 'Open Vault';

  @override
  String get openAVaultToReadOr =>
      'Open a Vault to read or save synced preferences.';

  @override
  String get openAVaultToReadOr2 =>
      'Open a Vault to read or save these synced preferences.';

  @override
  String get openAVaultToReadOr3 =>
      'Open a Vault to read or save this synced preference.';

  @override
  String get openANewTerminalTab => 'Open a new terminal tab';

  @override
  String get openActiveTerminals => 'Open active terminals';

  @override
  String get openConflicts => 'Open conflicts';

  @override
  String get openTerminal2 => 'Open terminal';

  @override
  String get optionalBackgroundSyncHintsForThis =>
      'Optional background sync hints for this device. iOS prefers APNs when available.';

  @override
  String get organizeYourHostsIntoGroups => 'Organize your hosts into groups.';

  @override
  String get otherSyncIssue => 'Other sync issue';

  @override
  String get outboxItems => 'Outbox items';

  @override
  String get outputIsEncryptedForThisDevice =>
      'Output is encrypted for this device. Input and resize controls stay disabled until the host explicitly grants this device control. Earlier scrollback is unavailable.';

  @override
  String get ownerAccountId => 'Owner account ID';

  @override
  String get ownerUserId => 'Owner user ID';

  @override
  String get pemPrivateKey => 'PEM private key';

  @override
  String get private => 'PRIVATE';

  @override
  String pageValuevalue(int valueValue) {
    return 'Page $valueValue';
  }

  @override
  String paneValuevalue(int valueValue) {
    return 'Pane $valueValue';
  }

  @override
  String paneValuevalueValuevalue2(int valueValue, String valueValue2) {
    return 'Pane $valueValue · $valueValue2';
  }

  @override
  String paneValuevalueValuevalue2Valuevalue3(
    int valueValue,
    String valueValue2,
    String valueValue3,
  ) {
    return 'Pane $valueValue · $valueValue2 · $valueValue3';
  }

  @override
  String paneValuevalueValuevalue22(int valueValue, int valueValue2) {
    return 'Pane $valueValue · $valueValue2%';
  }

  @override
  String get parameterDefinitionsJsonArray2 =>
      'Parameter definitions (JSON array)';

  @override
  String get parameterName => 'Parameter name';

  @override
  String get parentGroup2 => 'Parent group';

  @override
  String get password => 'Password';

  @override
  String get passwordCredential => 'Password Credential';

  @override
  String get passwordFieldMergeIsNoLonger =>
      'Password field merge is no longer available. Use the verified branch actions instead.';

  @override
  String get passwordSecret => 'Password secret';

  @override
  String get passwordsPrivateKeysAndPassphrasesAre =>
      'Passwords, private keys and passphrases are encrypted on this device before sync. Plaintext secrets are only used in an unlocked session.';

  @override
  String get pasteThePublicRequestFromThe =>
      'Paste the public request from the new browser. Private keys are never included.';

  @override
  String get pasteTheRecipientsSignedPublicDevice =>
      'Paste the recipient’s signed public Device Card. The account must already exist on this instance and the card must match the active device that will accept the invite.';

  @override
  String get pending => 'Pending';

  @override
  String get permanentPurgeAfter => 'Permanent purge after';

  @override
  String get permanentPurgeBecomesAvailableAfterThis =>
      'Permanent purge becomes available after this deadline.';

  @override
  String get permanentPurgeIsUnavailableBecauseThis =>
      'Permanent purge is unavailable because this server did not provide a restore deadline.';

  @override
  String permanentlyDeleteNameItsMembershipAnd(String name) {
    return 'Permanently delete “$name”, its membership and Relay policy? Unused Relay tickets for its members will be revoked, and active sessions granted by this group will close after policy recheck.';
  }

  @override
  String get permanentlyPurge => 'Permanently purge';

  @override
  String get permanentlyPurgeThisRecord => 'Permanently purge this record?';

  @override
  String get policyRevision => 'Policy revision';

  @override
  String policyRevisionRevisionInstanceRevisionInstancepolicyrevision(
    int revision,
    int instancePolicyRevision,
    String formatTime,
  ) {
    return 'Policy revision $revision · instance revision $instancePolicyRevision · updated $formatTime';
  }

  @override
  String get port => 'Port';

  @override
  String get portableEncryptedVaultArchive =>
      'Portable encrypted Vault archive';

  @override
  String get preference => 'Preference';

  @override
  String get preflightFailedBeforeAnyTargetReceived =>
      'Preflight failed before any target received a command.';

  @override
  String get prepareIsolatedCopy => 'Prepare isolated copy';

  @override
  String get prepareIsolatedRestoreCopy => 'Prepare isolated restore copy';

  @override
  String get prepareIsolatedRestoreCopy2 => 'Prepare isolated restore copy?';

  @override
  String get prepared => 'Prepared';

  @override
  String get preparingIsolatedCopy => 'Preparing isolated copy';

  @override
  String get preparingLocalEncryptedArchive =>
      'Preparing local encrypted archive';

  @override
  String get previewDisconnectedLayout => 'Preview disconnected layout';

  @override
  String get previewMemberEffectiveRelayAccess =>
      'Preview member effective Relay access';

  @override
  String get previewOnly => 'Preview only';

  @override
  String get previewStructuredCommandsOrReviewAnd =>
      'Preview structured commands, or review and confirm scripts before sending them to an active terminal.';

  @override
  String get previous => 'Previous';

  @override
  String get previousAccounts => 'Previous accounts';

  @override
  String get previousInvitations => 'Previous invitations';

  @override
  String get previousSessions => 'Previous sessions';

  @override
  String get privateKey => 'Private key';

  @override
  String get privateSigningAndEncryptionKeysStay =>
      'Private signing and encryption keys stay in this device secure store.';

  @override
  String get profileName => 'Profile name';

  @override
  String get profilesAreEncryptedAndSyncWith =>
      'Profiles are encrypted and sync with the Vault. This browser cannot open the local TCP listeners required to run port forwarding.';

  @override
  String get profilesAreEncryptedInThisHost =>
      'Profiles are encrypted in this Host and sync with the Vault. Running listeners stay on this device and stop when this SSH tab disconnects.';

  @override
  String get profilesAreEncryptedInsideThisHost =>
      'Profiles are encrypted inside this Host record and sync with the Vault. Running state and sockets are never synced.';

  @override
  String get program2 => 'Program';

  @override
  String get prometheusRequestsUsingThisCredentialWill =>
      'Prometheus requests using this credential will stop working immediately. You can create a replacement later.';

  @override
  String get prometheusScrapeCredential => 'Prometheus scrape credential';

  @override
  String get protocol => 'Protocol';

  @override
  String get protocolVersion => 'Protocol version';

  @override
  String get providerAdapter => 'Provider adapter';

  @override
  String get publicDeviceCard => 'Public Device Card';

  @override
  String get publicDeviceCardJson => 'Public Device Card JSON';

  @override
  String get pushIsABestEffortWake =>
      'Push is a best-effort wake-up hint. It does not prove delivery or synchronization.';

  @override
  String get pushProviderHealth => 'Push provider health';

  @override
  String get queuedNotTrusted => 'QUEUED — NOT TRUSTED';

  @override
  String get queueApprovalAndStop => 'Queue approval and stop';

  @override
  String get queued => 'Queued';

  @override
  String get quota => 'Quota';

  @override
  String get quotaInBytes => 'Quota in bytes';

  @override
  String get readOnly2 => 'READ ONLY';

  @override
  String get reissueRequired => 'REISSUE REQUIRED';

  @override
  String get revoked2 => 'REVOKED';

  @override
  String get reAuthenticateToCancel => 'Re-authenticate to cancel';

  @override
  String get reEnterAccountMasterPassword => 'Re-enter account master password';

  @override
  String get readOnlyGracePeriodAllMembers =>
      'Read-only grace period · All members can keep reading; writes and member changes are paused. You can create a separately password-protected encrypted archive in Settings.';

  @override
  String get readOnlyInstanceIdentityUsageAnd =>
      'Read-only instance identity, usage and relay policy.';

  @override
  String get readOnlyProviderConfigurationAggregateQueue =>
      'Read-only provider configuration, aggregate queue counts, and adapter outcomes.';

  @override
  String get ready => 'Ready';

  @override
  String get rebuildSnapshot => 'Rebuild snapshot';

  @override
  String get rebuildingSnapshot => 'Rebuilding snapshot';

  @override
  String get rebuildingSnapshot2 => 'Rebuilding snapshot…';

  @override
  String get reconnectObserver => 'Reconnect observer';

  @override
  String get record => 'Record';

  @override
  String recordIdIdRevisionRevisionlabel(String id, String revisionLabel) {
    return 'Record ID: $id\nRevision: $revisionLabel';
  }

  @override
  String recordIdIdRevisionValuevalue(String id, String valueValue) {
    return 'Record ID: $id\nRevision: $valueValue';
  }

  @override
  String get recordConsent => 'Record consent';

  @override
  String get recordPermanentlyRemovedFromActiveServer =>
      'Record permanently removed from active server state. Offline device copies and retained backups are not erased.';

  @override
  String get recordsAndConflictsRemainEncryptedExisting =>
      'Records and conflicts remain encrypted. Existing local branches and other Vaults are preserved. Cross-space migration and ID remapping are not supported.';

  @override
  String get recordsAreDecryptedOnlyOnThis =>
      'Records are decrypted only on this device. Restore creates a new signed revision if the same tombstone is still current.';

  @override
  String get recoveryDetails => 'Recovery details';

  @override
  String get recoveryInProgress => 'Recovery in progress';

  @override
  String get recoveryIsEnabledButThisCode =>
      'Recovery is enabled, but this code was not confirmed as stored. Rotate it now to display a fresh code.';

  @override
  String recoveryIsStatusCoveredcontextsOfRequiredcontexts(
    String status,
    int coveredContexts,
    int requiredContexts,
  ) {
    return 'Recovery is $status. $coveredContexts of $requiredContexts current contexts are covered; this device will retry missing keys in the background.';
  }

  @override
  String get recoveryRequired => 'Recovery required';

  @override
  String get recoveryRequiredSyncing => 'Recovery required · Syncing…';

  @override
  String get recycleBin => 'Recycle bin';

  @override
  String recycleBinRecordDisplaynameIdSubstring(
    String displayName,
    String substring,
    String automaticPurgeConsentText,
    String restoreDeadlineSemantics,
  ) {
    return 'Recycle bin record: $displayName, ID $substring, $automaticPurgeConsentText, $restoreDeadlineSemantics';
  }

  @override
  String redactionProofItem(Object item) {
    return 'Redaction proof  $item';
  }

  @override
  String get redactionReadiness => 'Redaction readiness';

  @override
  String get refresh2 => 'Refresh';

  @override
  String get refreshVaultList => 'Refresh Vault list';

  @override
  String get refreshVaultStates => 'Refresh Vault states';

  @override
  String get refreshAccountInvitations => 'Refresh account invitations';

  @override
  String get refreshAccountSessions => 'Refresh account sessions';

  @override
  String get refreshAdminAccounts => 'Refresh admin accounts';

  @override
  String get refreshAdminAudit => 'Refresh admin audit';

  @override
  String get refreshBackupStatus => 'Refresh backup status';

  @override
  String get refreshDevices => 'Refresh devices';

  @override
  String get refreshExpires => 'Refresh expires';

  @override
  String get refreshInstanceJobs => 'Refresh instance jobs';

  @override
  String get refreshKeyCoverage => 'Refresh key coverage';

  @override
  String get refreshMembersAndOnlineDevices =>
      'Refresh members and online devices';

  @override
  String get refreshOverview => 'Refresh overview';

  @override
  String get refreshPushHealth => 'Refresh push health';

  @override
  String get refreshReadiness => 'Refresh readiness';

  @override
  String get refreshRelayPolicy => 'Refresh relay policy';

  @override
  String get refreshReplicationStatus => 'Refresh replication status';

  @override
  String get refreshRestoreSources => 'Refresh restore sources';

  @override
  String get refreshRestoreStatus => 'Refresh restore status';

  @override
  String get refreshSchedule => 'Refresh schedule';

  @override
  String get refreshServerManagedGroups => 'Refresh server-managed groups';

  @override
  String get refreshStatus => 'Refresh status';

  @override
  String get refreshToLoadApprovedDevicesFrom =>
      'Refresh to load approved devices from the server.';

  @override
  String get registeredEndpoints => 'Registered endpoints';

  @override
  String get reject2 => 'Reject';

  @override
  String get relayCidrs => 'Relay CIDRs';

  @override
  String get relayAvailable => 'Relay available';

  @override
  String get relayPolicy => 'Relay policy';

  @override
  String get relayPorts => 'Relay ports';

  @override
  String get relayUnavailable => 'Relay unavailable';

  @override
  String get reloadAccountAndInstanceRelayPolicies =>
      'Reload account and instance Relay policies';

  @override
  String get reloadFirstPage => 'Reload first page';

  @override
  String get reloadGroupAndInstancePoliciesKeep =>
      'Reload group and instance policies, keep drafts';

  @override
  String get reloadLatestGroupKeepDrafts => 'Reload latest group, keep drafts';

  @override
  String get reloadLatestPolicy => 'Reload latest policy';

  @override
  String get reloadLatestPolicyKeepDraft => 'Reload latest policy, keep draft';

  @override
  String get remote => 'Remote';

  @override
  String get remoteSshListenerAddress => 'Remote SSH listener address';

  @override
  String get remoteArchiveIntegrityMismatch =>
      'Remote archive integrity mismatch';

  @override
  String get remoteCompletionUnknownNotRetried =>
      'Remote completion unknown · not retried';

  @override
  String get remoteCopyFailed => 'Remote copy failed';

  @override
  String get remoteCopyVerified => 'Remote copy verified';

  @override
  String get remoteCredentialsUnavailable => 'Remote credentials unavailable';

  @override
  String remoteFilesEndpoint(Object endpoint) {
    return 'Remote files · $endpoint';
  }

  @override
  String get remoteHeadIsAbsent => 'Remote head is absent';

  @override
  String get remotePath2 => 'Remote path';

  @override
  String remotePathSftppath(String sftpPath) {
    return 'Remote path: $sftpPath';
  }

  @override
  String get remoteReplica => 'Remote replica';

  @override
  String get remoteReplication => 'Remote replication';

  @override
  String remoteRevisionItem(Object item) {
    return 'Remote revision $item';
  }

  @override
  String get remoteStorageUnavailable => 'Remote storage unavailable';

  @override
  String remoteSshBindDeviceDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return 'Remote · SSH $bind → device $destinationAddress:$destinationPort';
  }

  @override
  String removePaneValuevalue(int valueValue) {
    return 'Remove Pane $valueValue';
  }

  @override
  String get removeFavorite => 'Remove favorite';

  @override
  String get removeReference => 'Remove reference';

  @override
  String get removeTmuxSessionReference2 => 'Remove tmux session reference';

  @override
  String get removeTmuxSessionReference => 'Remove tmux session reference?';

  @override
  String removeUsernameFromGroupDraft(String username) {
    return 'Remove $username from group draft';
  }

  @override
  String get rename => 'Rename';

  @override
  String get renameWorkspace => 'Rename workspace';

  @override
  String get repairAHost => 'Repair a Host';

  @override
  String get repairAGroup => 'Repair a group';

  @override
  String get repairIsNotConfirmedYetSync =>
      'Repair is not confirmed yet. Sync the active Vault and retry with the same record ID.';

  @override
  String get replaceHost => 'Replace Host';

  @override
  String get replaceMissingHost => 'Replace missing Host';

  @override
  String get requestedAt => 'Requested at';

  @override
  String get requiredTextValue => 'Required text value';

  @override
  String get reservedUploads => 'Reserved uploads';

  @override
  String get resetToInherit => 'Reset to inherit';

  @override
  String get resolutionSavedOnThisDeviceWaiting =>
      'Resolution saved on this device; waiting for sync confirmation.';

  @override
  String get resolveOrDiscardThisRecordsOutstanding =>
      'Resolve or discard this record’s outstanding conflict before permanently purging it.';

  @override
  String get resourceIdHmacSha256 => 'Resource ID (HMAC-SHA-256)';

  @override
  String get resourceType => 'Resource type';

  @override
  String responseValuevalue(int valueValue) {
    return 'Response $valueValue';
  }

  @override
  String get responsesAreSentOnlyForThis =>
      'Responses are sent only for this SSH authentication and are not saved.';

  @override
  String get restore => 'Restore';

  @override
  String get restoreDeadlinePassedAccordingToThis =>
      'Restore deadline passed according to this device clock; the server makes the final decision.';

  @override
  String restoreDeadlineFormat3(String format) {
    return 'Restore deadline $format';
  }

  @override
  String restoreDeadlineFormatTheServerChecks(String format) {
    return 'Restore deadline: $format. The server checks this deadline again when you confirm.';
  }

  @override
  String get restoreDefaults => 'Restore defaults';

  @override
  String get restoreIsRestrictedToTheSame =>
      'Restore is restricted to the same server space and Vault. Server-purged data is not included; store the downloaded archive and password separately from this device.';

  @override
  String get restorePreparesAnIsolatedCopyWhile =>
      'Restore prepares an isolated copy while the service stays online. Operators handle any later offline cutover.';

  @override
  String get restoreStaging => 'Restore staging';

  @override
  String restoreStagingAdminrestorejobstatuslabel(
    String adminRestoreJobStatusLabel,
  ) {
    return 'Restore staging · $adminRestoreJobStatusLabel';
  }

  @override
  String get restoreThisRecord => 'Restore this record?';

  @override
  String restoreUsernameInGroupDraft(String username) {
    return 'Restore $username in group draft';
  }

  @override
  String get result => 'Result';

  @override
  String get resumeSession => 'Resume session';

  @override
  String get resumeTmuxSession2 => 'Resume tmux session';

  @override
  String get resumeTmuxSession => 'Resume tmux session?';

  @override
  String get retry2 => 'Retry';

  @override
  String get retryAccountInvitations => 'Retry account invitations';

  @override
  String get retryAccountList => 'Retry account list';

  @override
  String get retryAndVerifyRepair => 'Retry and verify repair';

  @override
  String get retryBackupRequestSafely => 'Retry backup request safely';

  @override
  String get retryDiscard => 'Retry discard';

  @override
  String get retryDiscardSafely => 'Retry discard safely';

  @override
  String get retryGroupDetails => 'Retry group details';

  @override
  String get retryGroupList => 'Retry group list';

  @override
  String get retryPasswordChange => 'Retry password change';

  @override
  String get retryPending => 'Retry pending';

  @override
  String get retryQueued => 'Retry queued';

  @override
  String get retryRequestSafely => 'Retry request safely';

  @override
  String get retryScheduled => 'Retry scheduled';

  @override
  String get retrySessionList => 'Retry session list';

  @override
  String get retryWaiting => 'Retry waiting';

  @override
  String get retryableFailure7UtcDays => 'Retryable failure (7 UTC days)';

  @override
  String get revealPasswordSecret => 'Reveal password secret';

  @override
  String get reviewHostConnectionSettings => 'Review Host connection settings';

  @override
  String get reviewAndRun => 'Review and run';

  @override
  String get reviewBatchCommand => 'Review batch command';

  @override
  String get reviewCommandExecution => 'Review command execution';

  @override
  String get reviewCurrentVersion => 'Review current version';

  @override
  String get reviewDeviceEnrollment => 'Review device enrollment';

  @override
  String get reviewEachSynchronizedBindingAndRecord =>
      'Review each synchronized binding and record ID. Duplicate records are removed with encrypted tombstones.';

  @override
  String get reviewKeys => 'Review keys';

  @override
  String get reviewLocalProfileMigration => 'Review local profile migration';

  @override
  String reviewOnCountConnectedHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count connected Hosts',
      one: '1 connected Host',
    );
    return 'Review on $_temp0';
  }

  @override
  String get reviewThePaletteAndRecordId =>
      'Review the palette and record ID. The selected record stays active; duplicates are removed with encrypted tombstones.';

  @override
  String get reviewTheSizeAndRecordId =>
      'Review the size and record ID. The selected record ID stays active; other records are removed with encrypted tombstones.';

  @override
  String get reviewTrustedDevices => 'Review trusted devices';

  @override
  String get reviewUpdate => 'Review update';

  @override
  String reviewCountHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Hosts',
      one: '1 Host',
    );
    return 'Review $_temp0';
  }

  @override
  String get revokePrometheusScrapeCredential =>
      'Revoke Prometheus scrape credential?';

  @override
  String revokeSshHostKeyTrustFor(String endpoint, String fingerprint) {
    return 'Revoke SSH host-key trust for $endpoint ($fingerprint)';
  }

  @override
  String get revokeSshHostKeyTrust2 => 'Revoke SSH host-key trust?';

  @override
  String get revokeAccess => 'Revoke access';

  @override
  String get revokeAccountInvitation => 'Revoke account invitation?';

  @override
  String get revokeAllSessions => 'Revoke all sessions';

  @override
  String get revokeAllSessions2 => 'Revoke all sessions?';

  @override
  String get revokeAndRotateKey => 'Revoke and rotate key';

  @override
  String get revokeCredential => 'Revoke credential';

  @override
  String get revokeDevice => 'Revoke device';

  @override
  String get revokeDevice2 => 'Revoke device?';

  @override
  String revokeEveryActiveSessionForUsername(String username) {
    return 'Revoke every active session for $username? Their next request from those sessions will require a new sign-in.';
  }

  @override
  String get revokeInputControl => 'Revoke input control';

  @override
  String get revokeInvitation => 'Revoke invitation';

  @override
  String get revokeInvitation2 => 'Revoke invitation?';

  @override
  String get revokeMemberAccess => 'Revoke member access?';

  @override
  String get revokeSession => 'Revoke session';

  @override
  String get revokeSessions => 'Revoke sessions';

  @override
  String revokeTheSessionOnDevicenameFor(String deviceName, String username) {
    return 'Revoke the session on $deviceName for $username?';
  }

  @override
  String get revokeThisSession => 'Revoke this session?';

  @override
  String get revokeTrust2 => 'Revoke trust';

  @override
  String get revoked3 => 'Revoked';

  @override
  String get revokedAt => 'Revoked at';

  @override
  String revokedFormat(String format) {
    return 'Revoked $format';
  }

  @override
  String revokedFormat2(String format) {
    return 'Revoked · $format';
  }

  @override
  String get role => 'Role';

  @override
  String get rotatePrometheusScrapeCredential =>
      'Rotate Prometheus scrape credential?';

  @override
  String get rotateCredential => 'Rotate credential';

  @override
  String get rotateKeyAndChangeRole => 'Rotate key and change role?';

  @override
  String get rotateRecoveryCode => 'Rotate recovery code';

  @override
  String get rotationImmediatelyInvalidatesTheCurrentCredential =>
      'Rotation immediately invalidates the current credential. Update the Prometheus scrape configuration after copying the new value; it will be shown only once.';

  @override
  String get runEncryptedBackup => 'Run encrypted backup';

  @override
  String get runMaintenanceNow => 'Run maintenance now';

  @override
  String get running => 'Running';

  @override
  String get runningOnceThroughANonPty =>
      'Running once through a non-PTY SSH exec channel. Output is limited to 64 KiB.';

  @override
  String get scpUpload => 'SCP upload…';

  @override
  String get scpDownload => 'SCP download…';

  @override
  String get scpFileManager => 'SCP file manager';

  @override
  String get sftpFileBrowser => 'SFTP file browser';

  @override
  String get sftpFileManager => 'SFTP file manager';

  @override
  String get socks5ConnectOnlyNoSocksUser =>
      'SOCKS5 CONNECT only, no SOCKS user authentication. The proxy listens on this device loopback address.';

  @override
  String get sshRelayConnected => 'SSH Relay connected';

  @override
  String get sshTerminal => 'SSH Terminal';

  @override
  String get sshAuthenticationChallenge => 'SSH authentication challenge';

  @override
  String get sshConnected => 'SSH connected';

  @override
  String get sshConnecting => 'SSH connecting';

  @override
  String get sshConnectionFailed => 'SSH connection failed';

  @override
  String get sshCredentials => 'SSH credentials';

  @override
  String get sshDisconnected => 'SSH disconnected';

  @override
  String get sshExecFailedAfterDispatchThe =>
      'SSH exec failed after dispatch. The command may have started; its remote completion is unknown. It was not retried.';

  @override
  String get sshHostKeyChangesAreRejected =>
      'SSH host key changes are rejected after first verified trust.';

  @override
  String sshHostKeyFingerprintFingerprint(String fingerprint) {
    return 'SSH host key fingerprint: $fingerprint';
  }

  @override
  String get sshHostKeyTrust => 'SSH host-key trust';

  @override
  String get sshPortForwarding => 'SSH port forwarding';

  @override
  String get sshRelay => 'SSH relay';

  @override
  String get sshRelayPolicy => 'SSH relay policy';

  @override
  String get sshSessionIsDisconnected => 'SSH session is disconnected.';

  @override
  String get sshTerminalInput => 'SSH terminal input';

  @override
  String get sshUsername => 'SSH username';

  @override
  String get sshHostTrust => 'SSH host trust';

  @override
  String sameOnBothBranchesValuevalue(String valueValue) {
    return 'Same on both branches · $valueValue';
  }

  @override
  String get save => 'Save';

  @override
  String get saveConflictBranchAsWorkspaceCopy =>
      'Save conflict branch as workspace copy';

  @override
  String get saveCurrentTabs => 'Save current tabs';

  @override
  String get saveEncryptedCredential2 => 'Save encrypted credential';

  @override
  String get saveEncryptedGroup => 'Save encrypted group';

  @override
  String get saveEncryptedProfile => 'Save encrypted profile';

  @override
  String get saveGroupOverride => 'Save group override';

  @override
  String get saveLocalLayoutAsNamedCopy => 'Save local layout as named copy';

  @override
  String get saveMembership => 'Save membership';

  @override
  String get saveMergedCredential => 'Save merged Credential';

  @override
  String get saveOverride => 'Save override';

  @override
  String get saveQuota => 'Save quota';

  @override
  String get saveRelayPolicy => 'Save relay policy';

  @override
  String get saveReviewedTuple => 'Save reviewed tuple';

  @override
  String get saveSchedule => 'Save schedule';

  @override
  String get saveShortcuts2 => 'Save shortcuts';

  @override
  String get saveSnippet => 'Save snippet';

  @override
  String get saveSplitWorkspace => 'Save split Workspace';

  @override
  String get saveSyncedPreference => 'Save synced preference';

  @override
  String get saveTerminalColorTheme => 'Save terminal color theme';

  @override
  String get saveTerminalFontSize2 => 'Save terminal font size';

  @override
  String get saveThisCredentialNow => 'Save this credential now';

  @override
  String get saveWorkspace => 'Save workspace';

  @override
  String savedAsItemThisPreferenceIs(Object item) {
    return 'Saved as $item. This preference is encrypted in the active Vault and will sync to its authorized devices.';
  }

  @override
  String savedCheckpointShortkey(String shortKey) {
    return 'Saved checkpoint: $shortKey';
  }

  @override
  String get savedSettingsCanOnlyNarrowThe =>
      'Saved settings can only narrow the immutable limits configured by the server operator.';

  @override
  String get savedWorkspaces => 'Saved workspaces';

  @override
  String savedFontsizePxThisEncryptedPreference(int fontSize) {
    return 'Saved $fontSize px. This encrypted preference will sync to devices with access to this Vault.';
  }

  @override
  String savedLabelThisEncryptedPreferenceWill(String label) {
    return 'Saved $label. This encrypted preference will sync to devices with access to this Vault.';
  }

  @override
  String get savingAndPreviewingDoNotConnect =>
      'Saving and previewing do not connect. Choose any pane, then split it to add another Host leaf.';

  @override
  String get scheduleVaultDeletion => 'Schedule Vault deletion';

  @override
  String get scheduleVaultDeletion2 => 'Schedule Vault deletion?';

  @override
  String get scheduleAccountDeletion => 'Schedule account deletion';

  @override
  String get scheduleAccountDeletion2 => 'Schedule account deletion?';

  @override
  String get scheduleDeletion => 'Schedule deletion';

  @override
  String get scheduledEncryptedBackups => 'Scheduled encrypted backups';

  @override
  String get scheduledFor => 'Scheduled for';

  @override
  String get scriptBody2 => 'Script body';

  @override
  String get searchThisHostsCompletedCommandsPlain =>
      'Search this Host’s completed commands, plain Bash Snippets, and local Bash command names. Selecting a suggestion types one line at the current terminal cursor; it never presses Enter.';

  @override
  String searchValuevalueScrollback(String valueValue) {
    return 'Search $valueValue scrollback';
  }

  @override
  String get secureTerminalWorkspace => 'Secure terminal workspace';

  @override
  String get securityPolicy => 'Security policy';

  @override
  String get selectAnActiveVaultBeforeEnabling =>
      'Select an active Vault before enabling sync.';

  @override
  String get selectFirstHost => 'Select first host';

  @override
  String get selectedArchive => 'Selected archive';

  @override
  String get selectedServerManagedGroup => 'Selected server-managed group';

  @override
  String selectedStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Selected state: $valueValue · CIDRs: $summarize · ports: $summarize2';
  }

  @override
  String get sendANewInvitationFromSettings =>
      'Send a new invitation from Settings > Invite member.';

  @override
  String get sendResponses => 'Send responses';

  @override
  String get serverBackupConfigurationNotReady =>
      'Server backup configuration not ready';

  @override
  String get serverBackupConfigurationReady =>
      'Server backup configuration ready';

  @override
  String get serverGenerationUnknown => 'Server generation unknown';

  @override
  String get serverSpaceId => 'Server space ID';

  @override
  String serverSpaceServerspaceid(String serverSpaceId) {
    return 'Server space: $serverSpaceId';
  }

  @override
  String get serverManagedAccessGroups => 'Server-managed access groups';

  @override
  String get serverManagedGroupActionFailed =>
      'Server-managed group action failed';

  @override
  String get serverManagedGroupSaveFailed => 'Server-managed group save failed';

  @override
  String serverLocalConflictBranchesConflictcount(int conflictCount) {
    return 'Server/local conflict branches: $conflictCount';
  }

  @override
  String get sessionId => 'Session ID';

  @override
  String get setTheIntervalBelowThenSave =>
      'Set the interval below, then save your changes.';

  @override
  String setTheSharedTerminalTextSize(
    String join,
    int defaultTerminalFontSize,
  ) {
    return 'Set the shared terminal text size for this Vault. Allowed sizes: $join px. Default: $defaultTerminalFontSize px.';
  }

  @override
  String get setUpAccountRecovery => 'Set up account recovery';

  @override
  String get setUpRecovery => 'Set up recovery';

  @override
  String get shareThisTerminal => 'Share this terminal';

  @override
  String get sharedTerminalOutputReadOnly =>
      'Shared terminal output, read only';

  @override
  String get sharedTerminalHostApprovedControl =>
      'Shared terminal · host-approved control';

  @override
  String get sharedTerminalReadOnly => 'Shared terminal · read only';

  @override
  String get shellLabel2 => 'Shell label';

  @override
  String shellLabelShellSentToThe(String shell) {
    return 'Shell label: $shell · sent to the active SSH PTY';
  }

  @override
  String showingCountLocalArchivesOnThis(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count local archives',
      one: '1 local archive',
    );
    return 'Showing $_temp0 on this page';
  }

  @override
  String showingFirstLastOfAdmincountAccounts(
    int first,
    int last,
    String adminCount,
  ) {
    return 'Showing $first–$last of $adminCount accounts';
  }

  @override
  String showingFirstLastOfAdmincountInvitations(
    int first,
    int last,
    String adminCount,
  ) {
    return 'Showing $first–$last of $adminCount invitations';
  }

  @override
  String showingFirstLastOfAdmincountSessions(
    int first,
    int last,
    String adminCount,
  ) {
    return 'Showing $first–$last of $adminCount sessions';
  }

  @override
  String showingStartEndOfAdmincountVaults(
    int start,
    int end,
    String adminCount,
  ) {
    return 'Showing $start–$end of $adminCount Vaults';
  }

  @override
  String showingValuevalueValuevalue2OfTotal(
    int valueValue,
    int valueValue2,
    int total,
  ) {
    return 'Showing $valueValue–$valueValue2 of $total';
  }

  @override
  String get showsTheLatestCompletedBackupAttempt =>
      'Shows the latest completed backup attempt recorded by this server. The size can be unknown when an archive is no longer available to this node. This does not confirm that the archive still exists or that an isolated restore will succeed.';

  @override
  String get sideBySide => 'Side by side';

  @override
  String get sideBySideLeftRight => 'Side by side (left/right)';

  @override
  String get signAndCreateInvitation => 'Sign and create invitation';

  @override
  String get signInNeeded => 'Sign in needed';

  @override
  String get signedVaultShareRequest => 'Signed Vault share request';

  @override
  String get signedShareRequestCopied => 'Signed share request copied.';

  @override
  String get signingKeyFingerprint => 'Signing key fingerprint';

  @override
  String get signingKeyFingerprintSha256 => 'Signing key fingerprint · SHA-256';

  @override
  String get snapshotExceedsClientLimit => 'Snapshot exceeds client limit';

  @override
  String get snapshotGenerated => 'Snapshot generated';

  @override
  String get snapshotLimitReached => 'Snapshot limit reached';

  @override
  String get snapshotNeeded => 'Snapshot needed';

  @override
  String get snapshotSizeLimit => 'Snapshot size limit';

  @override
  String get snapshotVerificationIsInProgressLocal =>
      'Snapshot verification is in progress. Local edits are paused; the existing cache and outbox remain intact until the full manifest verifies.';

  @override
  String get snippet2 => 'Snippet';

  @override
  String get snippetScriptIsRequired => 'Snippet script is required';

  @override
  String get snippetTitleIsRequired => 'Snippet title is required';

  @override
  String snippetTitle3(String title) {
    return 'Snippet: $title';
  }

  @override
  String get source => 'Source';

  @override
  String get splitWorkspaceSavedEncryptedToThis =>
      'Split Workspace saved encrypted to this Vault.';

  @override
  String splitControlsCountDividersEachRatio(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dividers',
      one: '1 divider',
    );
    return 'Split controls · $_temp0 · each ratio sizes the first child';
  }

  @override
  String get splitSelectedPane => 'Split selected pane';

  @override
  String splitValuevalue(int valueValue) {
    return 'Split $valueValue';
  }

  @override
  String splitValuevalueAxisFirstpercentValuevalue2(
    int valueValue,
    String axis,
    int firstPercent,
    int valueValue2,
  ) {
    return 'Split $valueValue · $axis · $firstPercent/$valueValue2';
  }

  @override
  String splitFirstpercentSecondpercent(int firstPercent, int secondPercent) {
    return 'Split · $firstPercent/$secondPercent';
  }

  @override
  String get stacked => 'Stacked';

  @override
  String get stackedTopBottom => 'Stacked (top/bottom)';

  @override
  String get stageId => 'Stage ID';

  @override
  String get startForwarding => 'Start forwarding';

  @override
  String get startResumableSession => 'Start resumable session';

  @override
  String get startResumableTmuxSession => 'Start resumable tmux session?';

  @override
  String get startSession => 'Start session';

  @override
  String get startSharing => 'Start sharing';

  @override
  String get startedAt => 'Started at';

  @override
  String get stopAuthentication => 'Stop authentication';

  @override
  String get stopForwarding => 'Stop forwarding';

  @override
  String get stopLocalCapture => 'Stop local capture';

  @override
  String get stopTerminalSharing => 'Stop terminal sharing';

  @override
  String get stopThisForwardBeforeEditingIts =>
      'Stop this forward before editing its profile.';

  @override
  String get storeYourRecoveryCode => 'Store your recovery code';

  @override
  String get stored => 'Stored';

  @override
  String get storedData => 'Stored data';

  @override
  String get structuredBashCommand2 => 'Structured Bash command';

  @override
  String get submitBackupRequest => 'Submit backup request';

  @override
  String get submittingBackup => 'Submitting backup…';

  @override
  String get succeeded2 => 'Succeeded';

  @override
  String get syncCommandHistoryToVault => 'Sync command history to Vault';

  @override
  String get syncCommandHistoryToThisVault =>
      'Sync command history to this Vault?';

  @override
  String get syncError => 'Sync error';

  @override
  String get syncHealth => 'Sync health';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncPendingChanges => 'Sync pending changes';

  @override
  String get syncServiceError => 'Sync service error';

  @override
  String get syncStatus => 'Sync status';

  @override
  String get syncing => 'Syncing';

  @override
  String get thisDevice => 'THIS DEVICE';

  @override
  String tabValuevalue(int valueValue) {
    return 'Tab $valueValue';
  }

  @override
  String tabValuevalueMissingHost(int valueValue) {
    return 'Tab $valueValue · Missing Host';
  }

  @override
  String tabValuevalueName(int valueValue, String name) {
    return 'Tab $valueValue · $name';
  }

  @override
  String get tagsSeparatedByCommas => 'Tags, separated by commas';

  @override
  String targetValuevalueOfCountValuevalue2(
    int valueValue,
    int count,
    String valueValue2,
  ) {
    return 'Target $valueValue of $count: $valueValue2';
  }

  @override
  String targetValuevalueHostnameEndpoint(
    int valueValue,
    String hostName,
    String endpoint,
  ) {
    return 'Target $valueValue: $hostName · $endpoint';
  }

  @override
  String targetHostnameEndpoint(String hostName, String endpoint) {
    return 'Target: $hostName · $endpoint';
  }

  @override
  String get targetsRunSequentiallyNoTargetStarts =>
      'Targets run sequentially. No target starts until this full review is confirmed. The batch stops at the first non-zero or unknown result and never retries.';

  @override
  String get terminal => 'Terminal';

  @override
  String get terminalColorTheme => 'Terminal color theme';

  @override
  String get terminalFontSize3 => 'Terminal font size';

  @override
  String terminalFontSizeValuevaluePxRecord(
    Object valueValue,
    String id,
    String revisionLabel,
  ) {
    return 'Terminal font size: $valueValue px; Record ID: $id; Revision: $revisionLabel';
  }

  @override
  String get terminalHistory => 'Terminal history';

  @override
  String get terminalKeyboardShortcuts => 'Terminal keyboard shortcuts';

  @override
  String terminalPanesCountMaxworkspacepanes(int count, int maxWorkspacePanes) {
    return 'Terminal panes · $count/$maxWorkspacePanes';
  }

  @override
  String terminalSharePhase(String phase) {
    return 'Terminal share $phase';
  }

  @override
  String terminalThemeThemelabelRecordIdId(
    String themeLabel,
    String id,
    String valueValue,
  ) {
    return 'Terminal theme: $themeLabel; Record ID: $id; Revision: $valueValue';
  }

  @override
  String get theHostConflictCanNoLonger =>
      'The Host conflict can no longer be reviewed safely.';

  @override
  String get theSshServerGatewayportsSettingMay =>
      'The SSH server GatewayPorts setting may widen this loopback bind request. Verify the server configuration before using remote forwarding.';

  @override
  String get theSshServerRequestedTooMany =>
      'The SSH server requested too many responses. Authentication was stopped.';

  @override
  String get theVaultChangedReopenPortForwarding =>
      'The Vault changed; reopen port forwarding.';

  @override
  String get theVaultOrOneOfThe =>
      'The Vault or one of the selected Hosts is no longer available.';

  @override
  String get theArchiveHasPassedSignatureMembership =>
      'The archive has passed signature, membership, envelope, object hash and schema checks. Import merges into this Vault only. Missing encrypted objects may be uploaded to this same Vault; the import does not include session tokens or device private keys. Outbox entries authored by another device stay as local conflicts and are not replayed with this device identity.';

  @override
  String get theCommittedHostChangedAfterThis =>
      'The committed Host changed after this preview. No edit was staged; review the latest head before choosing again.';

  @override
  String get theCommittedHostChangedReviewIts =>
      'The committed Host changed. Review its latest connection settings before merging.';

  @override
  String get theCommittedVaultVersionChangedReview =>
      'The committed Vault version changed. Review it again before merging.';

  @override
  String get theCredentialIsNoLongerAvailable =>
      'The credential is no longer available in this session. If the rotation completed, rotate again after checking the status to receive a new one-time value.';

  @override
  String get theCurrentVaultVersionChangedWhile =>
      'The current Vault version changed while you were reviewing. Your selections were cleared. Review the current version before choosing again.';

  @override
  String get theDefaultPreferenceWasConfirmedAfter =>
      'The default preference was confirmed after Vault sync.';

  @override
  String get theDeploymentGateIsAvailableWith =>
      'The deployment gate is available with ATERMIUS_RELAY_ENABLED=true. Effective authorization always remains limited by the configured CIDRs and ports.';

  @override
  String get theExportContainsARandomReport =>
      'The export contains a random report ID, a fixed error code, client version, sync counts and dates rounded to UTC days. It never includes Vault records, account details, server addresses or device identifiers.';

  @override
  String get theFullScriptIsReviewedBefore =>
      'The full script is reviewed before sending to the active PTY.';

  @override
  String get theLastResponseWasNotConfirmed =>
      'The last response was not confirmed. The server may already have changed the password. Retry sends the exact same request; no password is stored for retry. Remember the new password. Signing out clears this retry request.';

  @override
  String get theLocalBranchAndItsOriginal =>
      'The local branch and its original CAS base stay encrypted in local storage. The snapshot has no current remote head for this record; keeping the local branch will create a new root revision.';

  @override
  String get theLocalLayoutBranchWasSaved =>
      'The local layout branch was saved as a new encrypted workspace.';

  @override
  String get theOperatingSystemWillAskFor =>
      'The operating system will ask for notification permission only when you turn this on. Vault data still syncs through the authenticated WebSocket or polling path.';

  @override
  String get theOptInRemoteBashHook =>
      'The opt-in remote Bash hook stores up to 500 completed commands in encrypted device-local storage. The remote host can forge OSC entries. Password prompts are not read, but secrets typed as command text may be captured. Stop local capture ignores new events; run \"atermius_off\" in Bash or close the shell to stop the hook.';

  @override
  String get thePasswordStaysInThisForm =>
      'The password stays in this form and is never sent.';

  @override
  String thePendingInvitationForUsernameWill(String username) {
    return 'The pending invitation for $username will no longer be accepted.';
  }

  @override
  String get thePreviousCodeWasNotConfirmed =>
      'The previous code was not confirmed as stored. Rotate recovery to show a replacement code.';

  @override
  String get theSavedPolicyExceedsTheCurrent =>
      'The saved policy exceeds the current deployment ceilings. Effective authorization remains restricted by the current limits. Narrow the CIDRs and ports below before saving; ATERMIUS_RELAY_ENABLED=true is also required for the relay service to run.';

  @override
  String get theSavedPolicyRemainsSelectedAs =>
      'The saved policy remains selected as enabled, but the effective relay service is unavailable while the deployment gate is off. ATERMIUS_RELAY_ENABLED=true is required; turn off the selection before saving other changes. The Web UI cannot change this gate.';

  @override
  String get theSecretIsReadFromThe =>
      'The secret is read from the encrypted Credential when you run this Snippet; it is never copied into the Snippet record or preview.';

  @override
  String get theSelectedDefaultPreferenceWasConfirmed =>
      'The selected default preference was confirmed after Vault sync.';

  @override
  String get theSelectedShortcutBindingsWereConfirmed =>
      'The selected shortcut bindings were confirmed after Vault sync.';

  @override
  String get theSelectedTerminalFontSizeWas =>
      'The selected terminal font size was confirmed after Vault sync.';

  @override
  String get theSelectedTerminalThemeWasConfirmed =>
      'The selected terminal theme was confirmed after Vault sync.';

  @override
  String get theServerCanCopyEncryptedInstance =>
      'The server can copy encrypted instance archives to an operator-configured S3-compatible target. The destination and credentials remain on the server. The access check performs HeadBucket only; it does not verify uploads, multipart operations, restore, or provider-wide interoperability.';

  @override
  String get theServerDeploymentGateMustAlso =>
      'The server deployment gate must also be enabled.';

  @override
  String get theServerDidNotRequestA =>
      'The server did not request a response.';

  @override
  String get theServerFirstValidatesThatThis =>
      'The server first validates that this copy and its receipt belong to this restore job. It leaves the files untouched if it cannot verify them. Confirmed cleanup permanently removes only this isolated copy; the source encrypted archive and active service data remain unchanged. You can prepare another isolated copy from the source archive later.';

  @override
  String get theServerReceivesPasswordDerivedVerifiers =>
      'The server receives password-derived verifiers and a newly encrypted account-key envelope. Your master password and account key stay on this device.';

  @override
  String get theServerRequiresANewerWeb =>
      'The server requires a newer Web client protocol.';

  @override
  String get theServerRequiresANewerClient =>
      'The server requires a newer client protocol. Confirm that the deployed Web bundle is the intended compatible release.';

  @override
  String theServerRestorePeriodHasNot2(String deadlineText) {
    return 'The server restore period has not ended.$deadlineText Refresh the recycle bin and try again later.';
  }

  @override
  String get theServerWillDeleteTheEncrypted =>
      'The server will delete the encrypted recovery package and all recovery keyboxes. You will need an approved device to set it up again.';

  @override
  String get theServerWillStartItsConfigured =>
      'The server will start its configured grace period. All active members immediately become read-only, while reads remain available until the server deadline. Create and store a portable encrypted archive separately before the deadline; this client restores only to the same server space and Vault. The server returns the exact purge time after confirmation.';

  @override
  String get theServiceStaysOnlineWhileIt =>
      'The service stays online while it prepares a separate copy from the selected local archive. This records a restore job and audit event in the live database and uses the maintenance lock, but does not change active account, Vault, session, or generation data. It does not activate or replace live data. The worker checks the archive again before publishing the isolated stage.';

  @override
  String get theServiceStaysOnlineWhileIt2 =>
      'The service stays online while it prepares a separate copy. This records a restore job and audit event in the live database and uses the maintenance lock, but does not change active account, Vault, session, or generation data. It does not activate or replace live data. The worker checks the chosen local or remote archive again before publishing the isolated stage.';

  @override
  String get theShareExpiresAfter15Minutes =>
      'The share expires after 15 minutes. Terminal output and host resize events are encrypted for each selected device.';

  @override
  String get theSyncCursorExpiredOrThe =>
      'The sync cursor expired or the server generation changed. Rebuild the cache from a verified snapshot; pending local operations are preserved and compared against remote heads.';

  @override
  String get theTerminalChangedBeforeTheSuggestion =>
      'The terminal changed before the suggestion could be inserted. Reopen suggestions and try again.';

  @override
  String get theUpdateCheckCouldNotConfirm =>
      'The update check could not confirm the current Web build.';

  @override
  String get theseInstanceGroupsControlSshRelay =>
      'These instance groups control SSH Relay access. They are separate from encrypted Workspace groups and do not contain Vault data.';

  @override
  String get thisGroupDefaultIsUnavailableChoose =>
      'This Group default is unavailable. Choose no default or a valid credential.';

  @override
  String get thisHostConflictHasNoSafely =>
      'This Host conflict has no safely reviewable connection tuple. Use the verified branch actions instead.';

  @override
  String thisSshKeyIsNotTrusted(String endpoint) {
    return 'This SSH key is not trusted for $endpoint. Compare its fingerprint with a trusted channel before accepting it.';
  }

  @override
  String get thisVaultIsReadOnlyFor =>
      'This Vault is read-only for the current account. Reads remain available where the server permits. A portable encrypted archive can be created from Settings.';

  @override
  String get thisVaultIsReadOnlyMember =>
      'This Vault is read-only. Member changes are unavailable.';

  @override
  String get thisVaultIsReadOnlyYou =>
      'This Vault is read-only. You can view the preference but cannot change it.';

  @override
  String get thisVaultIsReadOnlyYou2 =>
      'This Vault is read-only. You can view the shared shortcuts but cannot change them.';

  @override
  String get thisVaultIsReadOnlyYou3 =>
      'This Vault is read-only. You can view the shared terminal color theme but cannot change it.';

  @override
  String get thisVaultIsReadOnlyYou4 =>
      'This Vault is read-only. You can view the shared terminal font size but cannot change it.';

  @override
  String get thisWebBuildIsCurrent => 'This Web build is current.';

  @override
  String get thisAccountHasNoVaultAvailable =>
      'This account has no Vault available on this device. Create a new encrypted Vault, accept an invitation from an existing member, or ask an Owner to restore your access. Existing encrypted data stays separate from any new Vault.';

  @override
  String get thisAttachesTheCurrentSshPane =>
      'This attaches the current SSH pane to its saved tmux session. Other attached clients remain connected.';

  @override
  String get thisCardContainsTheAccountAnd =>
      'This card contains the account and device public keys plus a self-proof signature. It contains no private key or Vault key. Send it to the Vault owner over a trusted channel.';

  @override
  String get thisCodeIsShownOnceAnyone =>
      'This code is shown once. Anyone who has it can recover the Vault keys in this account. Store it in a password manager or another secure place. It is never saved by this client.';

  @override
  String get thisConflictNoLongerSupportsPassword =>
      'This conflict no longer supports password field merge. Use the verified branch actions instead.';

  @override
  String get thisCreatesATmuxSessionOn =>
      'This creates a tmux session on the current SSH host and saves its reference in this encrypted Workspace.';

  @override
  String get thisDeviceLoopbackOnly => 'This device loopback only';

  @override
  String get thisExactFingerprintWasRevokedBefore =>
      'This exact fingerprint was revoked before. Reapproval creates a new encrypted trust record for this Vault and syncs it to its devices. Verify it out of band before continuing.';

  @override
  String get thisFormNeverSubmitsCredentialText =>
      'This form never submits credential text directly to the server.';

  @override
  String thisGrantsRoleAccessToAll(String role) {
    return 'This grants $role access to all encrypted records in this Vault. The current Vault key is sealed to this device, and the owner signs a new membership version. Verify the account and both fingerprints with the recipient before continuing.';
  }

  @override
  String get thisGroupChangedOnAnotherDevice =>
      'This group changed on another device. Sync and reopen it before retrying.';

  @override
  String get thisGroupHasNoMembers => 'This group has no members.';

  @override
  String get thisImmediatelyRevokesEverySessionAnd =>
      'This immediately revokes every session and device. At the server purge deadline, personal Vaults and account data are deleted and your access to shared Vaults is removed. Other members’ shared Vault data is not deleted.';

  @override
  String get thisInstance => 'This instance';

  @override
  String get thisInvitationWasInvalidatedAfterA =>
      'This invitation was invalidated after a Vault membership change. Send a new invitation from Settings > Invite member.';

  @override
  String get thisInvitationsValidityCouldNotBe =>
      'This invitation\'s validity could not be confirmed. Send a new invitation from Settings > Invite member.';

  @override
  String get thisIsABearerTokenShare =>
      'This is a bearer token. Share it only with the intended recipient through a trusted channel. It is shown once and is bound to the target account and device.';

  @override
  String get thisIsOptInAndBash =>
      'This is opt-in and Bash-only. It does not edit shell startup files or write remote files. After you copy the command, paste it into the connected shell and press Enter. Completed commands are stored encrypted on this device (up to 500). The remote host can forge entries. Password prompts are not read, but secrets typed as command text may be captured.';

  @override
  String get thisMobileAppBuildHasNo =>
      'This mobile app build has no Firebase project configured. Build with this app’s Firebase options to enable provider token registration. For FCM delivery, the Firebase project must match the server service-account project; iOS APNs delivery uses the server APNs configuration. WebSocket and polling sync remain available.';

  @override
  String get thisPasswordIsUsedOnlyTo =>
      'This password is used only to decrypt this archive.';

  @override
  String thisRecordsConsentForThisExact(String recordDisplayName) {
    return 'This records consent for this exact tombstone ($recordDisplayName) only. When opted in, bounded Maintenance may automatically purge it after its restore deadline and other required checks. Enabling consent does not purge it immediately.';
  }

  @override
  String get thisRecordsDeletedVersionChangedThe =>
      'This record’s deleted version changed. The recycle bin is refreshing; review it before trying again.';

  @override
  String get thisRemovesTheEncryptedWorkspaceReference =>
      'This removes the encrypted Workspace reference. It does not stop or delete the remote tmux session.';

  @override
  String get thisRequestBelongsToAnotherAccount =>
      'This request belongs to another account.';

  @override
  String get thisServerBackendDoesNotSupport =>
      'This server backend does not support permanent record purge yet. No purge was performed.';

  @override
  String get thisServerIsNotCurrentlyAccepting =>
      'This server is not currently accepting restore requests. The existing isolated stage and live data are unchanged.';

  @override
  String thisSettingIsEncryptedInCurrentvaultname(String currentVaultName) {
    return 'This setting is encrypted in $currentVaultName and syncs to devices with access to this Vault.';
  }

  @override
  String thisSettingIsStoredAsAn(String currentVaultName) {
    return 'This setting is stored as an encrypted record in $currentVaultName and syncs with that Vault.';
  }

  @override
  String get thisSignedOutboxBranchCameFrom =>
      'This signed outbox branch came from another device. Its operation ID and envelope remain preserved locally, but this device will not replay it with a different signing identity. Keeping the local branch will create a new revision signed by this device.';

  @override
  String get thisSnapshotExceedsThisClientsLimit =>
      'This snapshot exceeds this client’s limit of 64 MiB of serialized manifest data or 100,000 heads. The existing cache, checkpoint, and pending outbox are preserved. Repeating recovery will not help; contact the project maintainer for migration guidance.';

  @override
  String get title => 'Title';

  @override
  String get toEnableSshRelayTheServer =>
      'To enable SSH relay, the server operator must set ATERMIUS_RELAY_ENABLED=true and configure deployment limits. The Web UI cannot change this gate.';

  @override
  String get topLevelGroup2 => 'Top-level group';

  @override
  String get transferVaultOwnership => 'Transfer Vault ownership?';

  @override
  String get transferAndRotateKey => 'Transfer and rotate key';

  @override
  String get transferOwnership => 'Transfer ownership';

  @override
  String get trustAfterVerification => 'Trust after verification';

  @override
  String get trustedDevices => 'Trusted devices';

  @override
  String get typeDeleteToConfirm => 'Type DELETE to confirm';

  @override
  String get typeEnableAutomaticPurge => 'Type ENABLE AUTOMATIC PURGE';

  @override
  String get typeACommandFragmentToSee =>
      'Type a command fragment to see suggestions.';

  @override
  String typeVaultnameToConfirm(String vaultName) {
    return 'Type “$vaultName” to confirm';
  }

  @override
  String unableToCheckBackupBucketAccess(String error) {
    return 'Unable to check backup bucket access: $error';
  }

  @override
  String unableToDiscardIsolatedRestoreCopy(String error) {
    return 'Unable to discard isolated restore copy: $error';
  }

  @override
  String get unableToLoadAccountRelayPolicy =>
      'Unable to load account Relay policy';

  @override
  String get unableToLoadMemberEffectiveRelay =>
      'Unable to load member effective Relay access';

  @override
  String unableToLoadOffSiteBackup(String error) {
    return 'Unable to load off-site backup status: $error';
  }

  @override
  String unableToLoadRestoreSourcesError(String error) {
    return 'Unable to load restore sources: $error';
  }

  @override
  String unableToLoadScheduledBackupsError(String error) {
    return 'Unable to load scheduled backups: $error';
  }

  @override
  String get unableToLoadServerManagedGroup =>
      'Unable to load server-managed group details';

  @override
  String get unableToLoadServerManagedGroups =>
      'Unable to load server-managed groups';

  @override
  String unableToPrepareIsolatedRestoreCopy(String error) {
    return 'Unable to prepare isolated restore copy: $error';
  }

  @override
  String unableToRefreshRestoreStageStatus(String error) {
    return 'Unable to refresh restore stage status: $error';
  }

  @override
  String unableToReviewPasswordFieldsFriendlyerror(String friendlyError) {
    return 'Unable to review password fields: $friendlyError';
  }

  @override
  String unableToSaveScheduledBackupsError(String error) {
    return 'Unable to save scheduled backups: $error';
  }

  @override
  String get unavailableCredential2 => 'Unavailable Credential';

  @override
  String get unavailableCredential => 'Unavailable credential';

  @override
  String get unavailableGroup => 'Unavailable group';

  @override
  String get unavailableInWeb => 'Unavailable in Web';

  @override
  String get unavailableOnThisNode => 'Unavailable on this node';

  @override
  String get unavailableParentChooseAgain => 'Unavailable parent; choose again';

  @override
  String uncommittedOperationsCount(int count) {
    return 'Uncommitted operations: $count';
  }

  @override
  String get unknown => 'Unknown';

  @override
  String get unknownPushProvider => 'Unknown push provider';

  @override
  String get unlockArchive => 'Unlock archive';

  @override
  String get unnamedDevice => 'Unnamed device';

  @override
  String get unsupportedTheme => 'Unsupported theme';

  @override
  String get unverified => 'Unverified';

  @override
  String get upOneDirectory => 'Up one directory';

  @override
  String get updateAndReload => 'Update and reload';

  @override
  String get updateReadinessChangedFinishTheVisible =>
      'Update readiness changed. Finish the visible blocker before confirming.';

  @override
  String get updatingThisDevice => 'Updating this device…';

  @override
  String get upload => 'Upload';

  @override
  String get uploadAFileOrCreateA =>
      'Upload a file or create a folder to get started.';

  @override
  String get useAtLeast12CharactersIf =>
      'Use at least 12 characters. If the response is lost, the client keeps only the exact retry request in memory, not either password.';

  @override
  String get useConflictBranch => 'Use conflict branch';

  @override
  String get useCurrentVaultVersion => 'Use current Vault version';

  @override
  String get useSyncedVersion => 'Use synced version';

  @override
  String get useTheAccountAndApprovedDevice =>
      'Use the account and approved device named by the invitation. The token is sent in the authenticated request body and is never added to a URL.';

  @override
  String get useTheConflictBranchTuple => 'Use the conflict branch tuple';

  @override
  String get useTheCurrentVaultTuple => 'Use the current Vault tuple';

  @override
  String get useTheSyncedVersion => 'Use the synced version?';

  @override
  String get userId => 'User ID';

  @override
  String get username => 'Username';

  @override
  String get validatingAllSelectedHostsBeforeSending =>
      'Validating all selected Hosts before sending the first command.';

  @override
  String get vaultId => 'Vault ID';

  @override
  String get vaultArchiveImportedAndLocalState =>
      'Vault archive imported and local state restored.';

  @override
  String vaultChangedWhileSavingCheckThe(String startingVaultName) {
    return 'Vault changed while saving. Check the preference in $startingVaultName; this active Vault was not marked as saved.';
  }

  @override
  String vaultChangedWhileSavingCheckThe2(String startingVaultName) {
    return 'Vault changed while saving. Check the shortcut preference in $startingVaultName; this active Vault was not marked as saved.';
  }

  @override
  String vaultChangedWhileSavingTheEncrypted(String startingVaultName) {
    return 'Vault changed while saving. The encrypted change remains queued in $startingVaultName; it was not saved to the active Vault.';
  }

  @override
  String vaultChangedWhileSavingTheFont(String startingVaultName) {
    return 'Vault changed while saving. The font-size change remains queued in $startingVaultName; it was not saved to the active Vault.';
  }

  @override
  String vaultChangedWhileSavingTheShortcut(String startingVaultName) {
    return 'Vault changed while saving. The shortcut change remains queued in $startingVaultName; it was not saved to the active Vault.';
  }

  @override
  String vaultChangedWhileSavingTheTheme(String startingVaultName) {
    return 'Vault changed while saving. The theme change remains queued in $startingVaultName; it was not saved to the active Vault.';
  }

  @override
  String vaultDeletionIsScheduledThisVault(String vaultLifecycleDate) {
    return 'Vault deletion is scheduled. This Vault is read-only; server purge after $vaultLifecycleDate. Pending outbox stays on this device and will resume only if an Owner cancels.';
  }

  @override
  String get vaultDeletionPendingReadOnly =>
      'Vault deletion pending · read-only';

  @override
  String vaultDeviceNameStatuslabel(String name, String statusLabel) {
    return 'Vault device $name, $statusLabel';
  }

  @override
  String vaultIsInItsDeletionGrace(int pendingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingCount,
      locale: localeName,
      other: '$pendingCount pending operations remain',
      one: '1 pending operation remains',
    );
    return 'Vault is in its deletion grace period. Pull and reads remain available, but conflict uploads and outbox pushes are paused. Use the portable encrypted archive in Settings to make a local backup; the server purges live Vault data at the displayed deadline. $_temp0 encrypted on this device and resume only if the Owner cancels deletion before the deadline.';
  }

  @override
  String get vaultKeyState => 'Vault key state';

  @override
  String get vaultMetadataAndStorageLimitsEncrypted =>
      'Vault metadata and storage limits. Encrypted names and contents are never shown.';

  @override
  String get vaultName => 'Vault name';

  @override
  String get vaultNameHostsCredentialsAndSnippets =>
      'Vault name, hosts, credentials and snippets are encrypted before sync.';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore =>
      'Vault preference data needs attention before these shortcuts can be changed.';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore2 =>
      'Vault preference data needs attention before this setting can be changed.';

  @override
  String get vaultRole => 'Vault role';

  @override
  String get vaultStatesRefreshedFromTheServer =>
      'Vault states refreshed from the server.';

  @override
  String get vaultSyncIsUnreachableThisConfirmation =>
      'Vault sync is unreachable. This confirmation queues the first-seen fingerprint as an encrypted record on this device; the current SSH connection will stop until Vault sync confirms it. Approvals and revocations from other devices cannot be checked while offline.';

  @override
  String vaultVaultid(String vaultId) {
    return 'Vault $vaultId';
  }

  @override
  String get vaultConflictResolved => 'Vault conflict resolved';

  @override
  String get vaultDeletionCancelled => 'Vault deletion cancelled';

  @override
  String get vaultDeletionScheduled => 'Vault deletion scheduled';

  @override
  String get vaultEncryptedDataSynced => 'Vault encrypted data synced';

  @override
  String get vaultKeyGeneration => 'Vault key generation';

  @override
  String get vaultKeyRotated => 'Vault key rotated';

  @override
  String get vaultCreated => 'Vault created';

  @override
  String get vaultPurged => 'Vault purged';

  @override
  String get vaultOwnershipTransferred => 'Vault ownership transferred';

  @override
  String get vaultScopedAuditIsAvailableOnly =>
      'Vault-scoped audit is available only to the Owner and Editors of the current Vault; your current permissions don\'t return Vault events.';

  @override
  String get vaultSyncedPreferences => 'Vault-synced preferences';

  @override
  String vaultVaultid2(String vaultId) {
    return 'Vault: $vaultId';
  }

  @override
  String vaultVaultname(String vaultName) {
    return 'Vault: $vaultName';
  }

  @override
  String get vaults => 'Vaults';

  @override
  String verifiedCapabilitiesReportRevisionRevisionRecord(
    int revision,
    int maxRecordSchema,
    String attachmentVersions,
    String formatAdminBytes,
  ) {
    return 'Verified capabilities · report revision $revision\nRecord schema ≤ $maxRecordSchema · attachment formats $attachmentVersions · attachment limit $formatAdminBytes';
  }

  @override
  String verifiedRevisionsRecordcount(int recordCount) {
    return 'Verified revisions: $recordCount';
  }

  @override
  String get verifySshHostKey => 'Verify SSH host key';

  @override
  String get verifyAndDiscard => 'Verify and discard';

  @override
  String get verifyAndReview => 'Verify and review';

  @override
  String get verifyArchive => 'Verify archive';

  @override
  String viaJumpHostJumphostname(Object jumpHostName) {
    return 'Via Jump Host: $jumpHostName';
  }

  @override
  String get viewVaultMembers => 'View Vault members';

  @override
  String get viewCommandHistory => 'View command history';

  @override
  String get viewSessions => 'View sessions';

  @override
  String get viewerReadOnlyVaultAccess => 'Viewer · read-only Vault access';

  @override
  String get workspace2 => 'WORKSPACE';

  @override
  String get waitForVaultSyncOrRecovery =>
      'Wait for Vault sync or recovery to finish before changing members.';

  @override
  String get waitForVaultSynchronizationOrRecovery =>
      'Wait for Vault synchronization or recovery to finish.';

  @override
  String get waitingForRemoteCopy => 'Waiting for remote copy';

  @override
  String get waitingToSync => 'Waiting to sync';

  @override
  String get webApplicationUpdates => 'Web application updates';

  @override
  String get wholeHoursFrom1To720 => 'Whole hours from 1 to 720';

  @override
  String get withdrawConsent => 'Withdraw consent';

  @override
  String get workspace3 => 'Workspace';

  @override
  String get workspaceActions => 'Workspace actions';

  @override
  String get workspaceName => 'Workspace name';

  @override
  String get workspaceSavedEncryptedToThisVault =>
      'Workspace saved encrypted to this Vault.';

  @override
  String get youHaveReadOnlyAccessTo =>
      'You have read-only access to this Vault.';

  @override
  String get activePane2 => 'active pane';

  @override
  String get eGGrep => 'e.g. grep';

  @override
  String get redactedDraft => 'redacted draft';

  @override
  String actionFriendlyerror(String action, String friendlyError) {
    return '$action: $friendlyError';
  }

  @override
  String countGroupParentRelationshipSAre(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Group parent relationships are',
      one: '1 Group parent relationship is',
    );
    return '$_temp0 missing or cyclic. Edit an affected Group and choose a valid parent or Top-level group.';
  }

  @override
  String countHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hosts',
      one: '1 host',
    );
    return '$_temp0';
  }

  @override
  String countOfCount2VaultKeyContexts(int count, int count2) {
    return '$count of $count2 Vault key contexts have recovery boxes.';
  }

  @override
  String countSuggestions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count suggestions',
      one: '1 suggestion',
    );
    return '$_temp0';
  }

  @override
  String countTabs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tabs',
      one: '1 tab',
    );
    return '$_temp0';
  }

  @override
  String countTargetSReportedAKnown(
    int count,
    int count2,
    int count3,
    int count4,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count targets reported a known result',
      one: '1 target reported a known result',
    );
    return '$_temp0; $count2 remote completion unknown; $count3 stopped before dispatch; $count4 not started.';
  }

  @override
  String countPendingReview(int count) {
    return '$count pending review';
  }

  @override
  String displaynameAndItsEncryptedPayloadsWill(String displayName) {
    return '$displayName and its encrypted payloads will be removed from active server state. This cannot be undone from the app.';
  }

  @override
  String displaynameWillBeRestoredFromIts(String displayName) {
    return '$displayName will be restored from its last verified live revision. This only succeeds while the matching tombstone is still the current server head.';
  }

  @override
  String filenameWillBeRemovedFromThe(String filename) {
    return '$filename will be removed from the remote host.';
  }

  @override
  String itemSigningKeyShortkey(Object item, String shortKey) {
    return '$item\nSigning key · $shortKey';
  }

  @override
  String labelforIdSubstringDeletedFormat(
    String labelFor,
    String substring,
    String format,
  ) {
    return '$labelFor · ID $substring · Deleted $format';
  }

  @override
  String membercountMembersValuevalueRevisionRevision(
    int memberCount,
    String valueValue,
    int revision,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      memberCount,
      locale: localeName,
      other: '$memberCount members',
      one: '1 member',
    );
    return '$_temp0 · $valueValue · revision $revision';
  }

  @override
  String missingcountMissing(int missingCount) {
    return '$missingCount missing';
  }

  @override
  String nameWillLoseAccountAccessAnd(String name) {
    return '$name will lose account access, and its active sessions will be revoked.';
  }

  @override
  String nameValuevaluePasswordHiddenFromPreview(
    String name,
    String valueValue,
  ) {
    return '$name: $valueValue · password hidden from preview';
  }

  @override
  String pendingcountEncryptedLocalChangeSAre(int pendingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingCount,
      locale: localeName,
      other: '$pendingCount encrypted local changes are',
      one: '1 encrypted local change is',
    );
    return '$_temp0 still in the outbox. They will not be pushed while the Vault is read-only; they remain on this browser and can resume syncing only if deletion is canceled before the deadline.';
  }

  @override
  String roleKeyEpochActivekeyepochMembershipMembershipversion(
    String role,
    String activeKeyEpoch,
    String membershipVersion,
  ) {
    return '$role · key epoch $activeKeyEpoch · membership $membershipVersion';
  }

  @override
  String tolocalExitExitstatus(DateTime toLocal, int exitStatus) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$toLocalString · exit $exitStatus';
  }

  @override
  String unavailablerecordcountEncryptedRecordSCouldNot(
    int unavailableRecordCount,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      unavailableRecordCount,
      locale: localeName,
      other: '$unavailableRecordCount encrypted records',
      one: '1 encrypted record',
    );
    return '$_temp0 could not be verified with the current Vault key/device directory or decoded as a supported record. Their ciphertext remains stored locally and is hidden from trusted data.';
  }

  @override
  String unresolvedconflictcountNeedsReview(int unresolvedConflictCount) {
    return '$unresolvedConflictCount needs review';
  }

  @override
  String valuevalueMoreDeviceSNeedReview(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: '$valueValue more devices need review.',
      one: '1 more device needs review.',
    );
    return '$_temp0';
  }

  @override
  String valuevalueUsernameAndRotateTheVault(
    String valueValue,
    String username,
  ) {
    return '$valueValue $username and rotate the Vault key for every remaining active member device? The removed account receives no new key. Existing old copies cannot be erased remotely. Other pending invitation tokens become invalid and must be reissued.';
  }

  @override
  String get configuredMeansThisServerProcessLoaded =>
      '“Configured” means this server process loaded the provider adapter; it does not confirm connectivity or worker liveness. Push is a best-effort wake-up hint, not proof of delivery or sync; authenticated WebSocket or polling remains the source of truth.';

  @override
  String get previousPage => 'Previous page';

  @override
  String lastArchiveVerificationFailedAtArchivefailurephase(
    Object archiveFailurePhase,
  ) {
    return 'Last archive verification failed at: $archiveFailurePhase';
  }

  @override
  String get nextPage => 'Next page';

  @override
  String get doesntExist => 'Doesn\'t exist';

  @override
  String get masterPasswordChanged => 'Master password changed';

  @override
  String get couldntChangeTheMasterPassword =>
      'Couldn\'t change the master password';

  @override
  String get hosts => 'Hosts';

  @override
  String get onlyTheHostIdTabOrder =>
      'Only the Host ID, tab order, split direction and split ratio are synced. Credentials, running SSH sessions, terminal output, SFTP paths and file state are never written to workspace records.';

  @override
  String get retryFromTheFirstPage => 'Retry from the first page';

  @override
  String get saveAndConnect => 'Save and connect';

  @override
  String get saveCurrentWindowLayout => 'Save current window layout';

  @override
  String get saveTheCurrentTerminalTabsTo =>
      'Save the current terminal tabs to preview the same layout on other authorized devices.';

  @override
  String get keepTheCurrentCommittedVersion =>
      'Keep the current committed version?';

  @override
  String get keepCurrentVersion => 'Keep current version';

  @override
  String get couldntKeepTheCurrentVersion =>
      'Couldn\'t keep the current version';

  @override
  String get vaultsAndMembers => 'Vaults and members';

  @override
  String get change => 'Change';

  @override
  String get openOneOrMoreTabsOn =>
      'Open one or more tabs on the Terminal page first, then save them as a named layout.';

  @override
  String get conflictResolved => 'Conflict resolved.';

  @override
  String get setTheTerminalFontSizeColors2 =>
      'Set the terminal font size, colors and shortcuts separately; they sync with the current Vault.';

  @override
  String get branchsOriginalBase => 'Branch\'s original base';

  @override
  String get branchNotVerifiedYetKeptRead =>
      'Branch not verified yet; kept read-only';

  @override
  String get branchSavedOnThisDeviceWaiting =>
      'Branch saved on this device, waiting for sync confirmation.';

  @override
  String get branchSavedEncryptedOnThisDevice =>
      'Branch saved encrypted on this device, waiting for sync confirmation.';

  @override
  String branchSequenceSeqValuevalue(String seq, String valueValue) {
    return 'Branch sequence $seq · $valueValue';
  }

  @override
  String get branchActions => 'Branch actions';

  @override
  String get branchVersion => 'Branch version';

  @override
  String get groupLayoutReset => 'Group layout reset.';

  @override
  String get refresh => 'Refresh';

  @override
  String get encryptedSessionUnlocked => 'Encrypted session unlocked';

  @override
  String get namedTerminalLayoutsSyncEncryptedIncluding =>
      'Named terminal layouts sync encrypted, including tab order or split direction and ratio. Previews never connect; each pane needs its own Connect confirmation.';

  @override
  String get encryptedBackupJobSubmitted => 'Encrypted backup job submitted';

  @override
  String get readOnlyViewOfCommittedAccount =>
      'Read-only view of committed account and current Vault admin actions; SSH commands, host names and credentials aren\'t recorded.';

  @override
  String get syncAndConflicts => 'Sync and conflicts';

  @override
  String get snippets => 'Snippets';

  @override
  String get completedCommandsAreRecordedAfterEnabling2 =>
      'Completed commands are recorded after enabling Bash integration in Recording settings; input at password prompts isn\'t captured.';

  @override
  String get working => 'Working…';

  @override
  String get backupRestoreAndMaintenance => 'Backup, restore and maintenance';

  @override
  String get backupCompleted => 'Backup completed';

  @override
  String get multiFactorRecoveryCodesRotated =>
      'Multi-factor recovery codes rotated';

  @override
  String get instanceOverview => 'Instance overview';

  @override
  String get instanceAdminInvitationRevoked =>
      'Instance admin invitation revoked';

  @override
  String get instanceAdminInvitationIssued =>
      'Instance admin invitation issued';

  @override
  String get instanceMaintenanceJobSubmitted =>
      'Instance maintenance job submitted';

  @override
  String get auditLog => 'Audit log';

  @override
  String get auditRecords => 'Audit records';

  @override
  String get importAndExportEncryptedArchivesOr =>
      'Import and export encrypted archives, or migrate local profiles.';

  @override
  String get notVerifiedYet => 'Not verified yet';

  @override
  String get properties => 'Properties';

  @override
  String get workspace => 'Workspace';

  @override
  String get workspaceLayouts => 'Workspace layouts';

  @override
  String get theCurrentWindowLayoutForThis =>
      'The current window layout for this group was saved.';

  @override
  String get multiFactorAuthenticationTurnedOff =>
      'Multi-factor authentication turned off';

  @override
  String get memberInvitationCreated => 'Member invitation created';

  @override
  String get deleted => 'Deleted';

  @override
  String deletedValuevalue(String valueValue) {
    return 'Deleted $valueValue';
  }

  @override
  String get bashRecordingIsOnUpTo =>
      'Bash recording is on (up to 500 entries). Click to insert, press Enter to run.';

  @override
  String get multiFactorAuthenticationEnabled =>
      'Multi-factor authentication enabled';

  @override
  String processedBranchesCount(int count) {
    return 'Processed branches · $count';
  }

  @override
  String get multiFactorSignInStarted => 'Multi-factor sign-in started';

  @override
  String get committed => 'Committed';

  @override
  String get committedAdminActionsAppearHereNew =>
      'Committed admin actions appear here. New events aren\'t inserted into the page cursor you\'re browsing.';

  @override
  String get sshRelayConnectionTicketIssued =>
      'SSH Relay connection ticket issued';

  @override
  String get resolved => 'Resolved';

  @override
  String get signedOut => 'Signed out';

  @override
  String get multiFactorAuthenticationWasResetAfter =>
      'Multi-factor authentication was reset after archive restore';

  @override
  String get currentVault3 => 'Current Vault';

  @override
  String get hostsCantBeAddedInThe =>
      'Hosts can\'t be added in the current workspace.';

  @override
  String showingEventsForCurrentvaultnameSwitchingThe(String currentVaultName) {
    return 'Showing events for $currentVaultName. Switching the Vault at the top reloads from the first page.';
  }

  @override
  String get currentServerVersion => 'Current server version';

  @override
  String get theCurrentServerVersionIsCommitted =>
      'The current server version is committed. It\'s recorded as the choice for this conflict; the old branch isn\'t re-uploaded and no new record version is created.';

  @override
  String get theCurrentVersionChangedChooseAgain =>
      'The current version changed; choose again';

  @override
  String get theCurrentVersionIsCommittedWaiting =>
      'The current version is committed, waiting for the server to confirm the conflict resolution.';

  @override
  String get thisWindowHasNoSshLayout =>
      'This window has no SSH layout to save.';

  @override
  String get noAuditRecordsInTheCurrent =>
      'No audit records in the current scope';

  @override
  String get yourCurrentRoleCantViewThe =>
      'Your current role can\'t view the Vault audit';

  @override
  String get restore3 => 'Restore';

  @override
  String get recoveryKeyDeviceEnvelopesUpdated =>
      'Recovery key device envelopes updated';

  @override
  String get succeeded => 'Succeeded';

  @override
  String get memberPermissionsChanged => 'Member permissions changed';

  @override
  String get membershipVersion => 'Membership version';

  @override
  String get memberAccessRevoked => 'Member access revoked';

  @override
  String get memberInvitationAccepted => 'Member invitation accepted';

  @override
  String get theSelectedBranchIsCommittedWaiting =>
      'The selected branch is committed, waiting for the server to confirm the conflict resolution.';

  @override
  String get theSelectedVersionIsCommittedWaiting =>
      'The selected version is committed, waiting for the server to confirm the conflict resolution.';

  @override
  String get dataAndMigration => 'Data and migration';

  @override
  String get files => 'Files';

  @override
  String get theHostSpecifiedByTheFile =>
      'The host specified by the file window is unavailable.';

  @override
  String get fileManager => 'File manager';

  @override
  String get passwordsAndKeysForNewHosts2 =>
      'Passwords and keys for new hosts are set in the host details.';

  @override
  String get newBranchesSyncAutomaticallyWithConflict =>
      'New branches sync automatically with conflict notifications; you can also use Sync at the top to check the server inbox.';

  @override
  String get newLabel => 'New';

  @override
  String newTouppercaseHost(String toUpperCase) {
    return 'New $toUpperCase host';
  }

  @override
  String get newWindow => 'New window';

  @override
  String get theNewWindowWasntReadyThe =>
      'The new window wasn\'t ready; the original SSH session stays connected.';

  @override
  String get theNewWindowWasntReadyThe2 =>
      'The new window wasn\'t ready; the remote desktop stays in the current window.';

  @override
  String couldntLoadTheVaultListError(String error) {
    return 'Couldn\'t load the Vault list: $error';
  }

  @override
  String couldntLoadTheSessionListError(String error) {
    return 'Couldn\'t load the session list: $error';
  }

  @override
  String get couldntLoadBackupCommandStatus =>
      'Couldn\'t load backup command status';

  @override
  String couldntLoadBackupCommandStatusError(String error) {
    return 'Couldn\'t load backup command status: $error';
  }

  @override
  String get couldntLoadInstanceOverview => 'Couldn\'t load instance overview';

  @override
  String couldntLoadInstanceOverviewError(String error) {
    return 'Couldn\'t load instance overview: $error';
  }

  @override
  String get couldntLoadInstanceAdminAuditRecords =>
      'Couldn\'t load instance admin audit records';

  @override
  String couldntLoadInstanceAdminAuditRecords2(String error) {
    return 'Couldn\'t load instance admin audit records: $error';
  }

  @override
  String get couldntLoadAuditRecords => 'Couldn\'t load audit records';

  @override
  String get couldntLoadPushServiceStatus =>
      'Couldn\'t load push service status';

  @override
  String couldntLoadPushServiceStatusError(String error) {
    return 'Couldn\'t load push service status: $error';
  }

  @override
  String get couldntLoadTheAdminVaultList =>
      'Couldn\'t load the admin Vault list';

  @override
  String get couldntLoadTheAdminAccountList =>
      'Couldn\'t load the admin account list';

  @override
  String get couldntLoadTheAccountSessionList =>
      'Couldn\'t load the account session list';

  @override
  String couldntLoadTheAccountListError(String error) {
    return 'Couldn\'t load the account list: $error';
  }

  @override
  String get couldntLoadTheAccountInvitationList =>
      'Couldn\'t load the account invitation list';

  @override
  String couldntLoadTheInvitationListError(String error) {
    return 'Couldn\'t load the invitation list: $error';
  }

  @override
  String get couldntOpenTheFileWindow => 'Couldn\'t open the file window.';

  @override
  String get couldntSubmitTheEncryptedBackupJob =>
      'Couldn\'t submit the encrypted backup job';

  @override
  String couldntSubmitTheEncryptedBackupJob2(String error) {
    return 'Couldn\'t submit the encrypted backup job: $error';
  }

  @override
  String get couldntUpdateTheVaultQuota => 'Couldn\'t update the Vault quota';

  @override
  String couldntUpdateTheVaultQuotaError(String error) {
    return 'Couldn\'t update the Vault quota: $error';
  }

  @override
  String get unreadable => 'Unreadable';

  @override
  String get couldntReadOrSubmitInstanceJobs =>
      'Couldn\'t read or submit instance jobs';

  @override
  String couldntReadOrSubmitInstanceJobs2(String error) {
    return 'Couldn\'t read or submit instance jobs: $error';
  }

  @override
  String get legacySharedCredentials => 'Legacy shared credentials';

  @override
  String missingPlural11MonitorWindow(int missing) {
    String _temp0 = intl.Intl.pluralLogic(
      missing,
      locale: localeName,
      other: '$missing monitor windows couldn\'t open; choose again to retry.',
      one: '1 monitor window couldn\'t open; choose again to retry.',
    );
    return '$_temp0';
  }

  @override
  String get theServerProvidedASignedCleanup =>
      'The server provided a signed cleanup receipt for this record. Pending local changes were isolated as a read-only draft; to avoid recreating the cleaned record, the draft can\'t be kept, merged or uploaded here.';

  @override
  String get theServerMarksTheCurrentCommitted =>
      'The server marks the current committed version as kept without creating a new main record version. Cross-device branches stay as processed history.';

  @override
  String get serverBranch => 'Server branch';

  @override
  String get theServerPageContainsSeveralVisible =>
      'The server page contains several visible scopes; keep paging to find events in the current scope.';

  @override
  String get unknownAction => 'Unknown action';

  @override
  String get unknownResult => 'Unknown result';

  @override
  String get unknownDevice => 'Unknown device';

  @override
  String get localStorageNeedsRecoveryReadingEditing =>
      'Local storage needs recovery. Reading, editing and syncing are paused; close all Atermius tabs and reopen to restore the last persisted data.';

  @override
  String get notCommittedLocally => 'Not committed locally';

  @override
  String get noEventsInThisScopeOn => 'No events in this scope on this page';

  @override
  String get sourceDevice => 'Source device';

  @override
  String get viewInstanceAndPushServiceStatus =>
      'View instance and push service status, and manage monitoring credentials.';

  @override
  String get viewTheCurrentAccountDevicesAnd =>
      'View the current account, devices and server information.';

  @override
  String get reviewInstanceActionsAndAccessAudit =>
      'Review instance actions and access audit records.';

  @override
  String get reviewTrustedHostKeysAndTheir =>
      'Review trusted host keys and their changes.';

  @override
  String get refreshCredentialReplayDetectedTheRelated =>
      'Refresh credential replay detected; the related sessions were revoked';

  @override
  String get readingVaultList => 'Reading Vault list…';

  @override
  String get readingInstanceJobs => 'Reading instance jobs…';

  @override
  String get readingInstanceOverview => 'Reading instance overview…';

  @override
  String get readingInstanceAdminAuditRecords =>
      'Reading instance admin audit records…';

  @override
  String get readingAuditRecords => 'Reading audit records…';

  @override
  String get readingOffSiteBackupStatus => 'Reading off-site backup status…';

  @override
  String get readingPushServiceStatus => 'Reading push service status…';

  @override
  String get readingTheLatestBackupCommandStatus =>
      'Reading the latest backup command status…';

  @override
  String get readingAdminAccountList => 'Reading admin account list…';

  @override
  String get thisGroupHasNoConnectableSsh =>
      'This group has no connectable SSH hosts.';

  @override
  String get eachGroupLayoutCanConnectUp =>
      'Each group layout can connect up to 32 hosts. Split the group and try again.';

  @override
  String get noPendingCrossDeviceBranches => 'No pending cross-device branches';

  @override
  String get browseFiles => 'Browse files';

  @override
  String get addGroup => 'Add group';

  @override
  String get versionCommittedWaitingForTheServer =>
      'Version committed, waiting for the server to confirm the resolution';

  @override
  String get signInFailed => 'Sign-in failed';

  @override
  String get signedIn => 'Signed in';

  @override
  String get confirmKeptVersion => 'Confirm kept version';

  @override
  String get windowSetSavedEncrypted => 'Window set saved encrypted.';

  @override
  String windowSetOpenedCountCount2Sessions(
    int count,
    int count2,
    int failures,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      failures,
      locale: localeName,
      other: '$failures couldn\'t connect',
      one: '1 couldn\'t connect',
    );
    return 'Window set opened $count/$count2 sessions; $_temp0.';
  }

  @override
  String pageValuevalue2(int valueValue) {
    return 'Page $valueValue';
  }

  @override
  String get waitingForThisDeviceToSync =>
      'Waiting for this device to sync the selected version';

  @override
  String get manageTheMasterPasswordTwoFactor =>
      'Manage the master password, two-factor sign-in, recovery and account deletion.';

  @override
  String get manageVaultsMembersAndInvitations =>
      'Manage Vaults, members and invitations.';

  @override
  String get adminBackupFailed => 'Admin backup failed';

  @override
  String get adminBackupInterrupted => 'Admin backup interrupted';

  @override
  String get adminBackupCompleted => 'Admin backup completed';

  @override
  String get adminBackupStarted => 'Admin backup started';

  @override
  String get anAdministratorDiscardedTheIsolatedRestore =>
      'An administrator discarded the isolated restore copy';

  @override
  String get anAdministratorDisabledTheAccount =>
      'An administrator disabled the account';

  @override
  String get anAdministratorCreatedAnSshRelay =>
      'An administrator created an SSH Relay access group';

  @override
  String get anAdministratorDeletedAnSshRelay =>
      'An administrator deleted an SSH Relay access group';

  @override
  String get anAdministratorEnabledTheAccount =>
      'An administrator enabled the account';

  @override
  String get anAdministratorRevokedThePrometheusScrape =>
      'An administrator revoked the Prometheus scrape credential';

  @override
  String get anAdministratorRevokedAnAccountSession =>
      'An administrator revoked an account session';

  @override
  String get anAdministratorRevokedAllOfThe =>
      'An administrator revoked all of the account\'s sessions';

  @override
  String get anAdministratorChangedSshRelayAccess =>
      'An administrator changed SSH Relay access group membership';

  @override
  String get anAdministratorChangedTheSshRelay =>
      'An administrator changed the SSH Relay access group policy';

  @override
  String get anAdministratorChangedTheVaultQuota =>
      'An administrator changed the Vault quota';

  @override
  String get anAdministratorChangedTheScheduledBackup =>
      'An administrator changed the scheduled backup';

  @override
  String get anAdministratorUpdatedTheSshRelay =>
      'An administrator updated the SSH Relay policy';

  @override
  String get anAdministratorRequestedABackup =>
      'An administrator requested a backup';

  @override
  String get anAdministratorRequestedARestoreJob =>
      'An administrator requested a restore job';

  @override
  String get anAdministratorRequestedAMaintenanceJob =>
      'An administrator requested a maintenance job';

  @override
  String get anAdministratorRotatedThePrometheusScrape =>
      'An administrator rotated the Prometheus scrape credential';

  @override
  String get anAdministratorRenamedAnSshRelay =>
      'An administrator renamed an SSH Relay access group';

  @override
  String get anAdministratorResetTheSshRelay =>
      'An administrator reset the SSH Relay access group policy';

  @override
  String get adminRestoreJobFailed => 'Admin restore job failed';

  @override
  String get adminRestoreJobInterrupted => 'Admin restore job interrupted';

  @override
  String get adminRestoreJobCompleted => 'Admin restore job completed';

  @override
  String get adminRestoreJobStarted => 'Admin restore job started';

  @override
  String get adminMaintenanceJobFailed => 'Admin maintenance job failed';

  @override
  String get adminMaintenanceJobInterrupted =>
      'Admin maintenance job interrupted';

  @override
  String get adminMaintenanceJobCompleted => 'Admin maintenance job completed';

  @override
  String get adminMaintenanceJobStarted => 'Admin maintenance job started';

  @override
  String get adminAccountActionFailed => 'Admin account action failed';

  @override
  String get adminAccountInvitationActionFailed =>
      'Admin account invitation action failed';

  @override
  String get manageBackupsAndRestoreCopiesAnd =>
      'Manage backups and restore copies, and check instance maintenance jobs.';

  @override
  String get manageInstanceAccountsInvitationsRelayGroups =>
      'Manage instance accounts, invitations, relay groups and connection policies.';

  @override
  String get manageNotificationsAndClientUpdates =>
      'Manage notifications and client updates.';

  @override
  String get theBranchAndTheCurrentRecord =>
      'The branch and the current record are verified, then this device re-signs and syncs it. The original encrypted branch is kept.';

  @override
  String get terminal2 => 'Terminal';

  @override
  String get terminalAndShortcuts => 'Terminal and shortcuts';

  @override
  String get maintenanceJobs => 'Maintenance jobs';

  @override
  String get editGroup => 'Edit group';

  @override
  String get letExternalAiAccessTheCurrent2 =>
      'Let external AI access the current workspace.';

  @override
  String get theRecordChangedAgainDuringCommit =>
      'The record changed again during commit. Check the current version and choose again.';

  @override
  String get theRecordChangedCheckTheCurrent =>
      'The record changed. Check the current version and choose again.';

  @override
  String get devices => 'Devices';

  @override
  String get deviceApproved2 => 'Device approved';

  @override
  String get deviceRevoked => 'Device revoked';

  @override
  String get settings => 'Settings';

  @override
  String get account2 => 'Account';

  @override
  String accountShortauditidDeviceShortauditid2Valuevalue(
    String shortAuditId,
    String shortAuditId2,
    String valueValue,
  ) {
    return 'Account $shortAuditId  ·  Device $shortAuditId2  ·  $valueValue';
  }

  @override
  String get accountAndDeviceInformation => 'Account and device information';

  @override
  String get accountsAndAccessPolicies => 'Accounts and access policies';

  @override
  String get accountEventsAreStillVisibleOnly =>
      'Account events are still visible. Only the Owner and Editors of this Vault can view Vault-scoped records.';

  @override
  String get accountSessionUnlocked => 'Account session unlocked';

  @override
  String get accountCreated => 'Account created';

  @override
  String get accountSecurity => 'Account security';

  @override
  String get multiFactorAuthenticationWasResetAfter2 =>
      'Multi-factor authentication was reset after account recovery';

  @override
  String get accountRecoveryKeyRotated => 'Account recovery key rotated';

  @override
  String get accountRecoveryDisabled => 'Account recovery disabled';

  @override
  String get accountRecoveryEnabled => 'Account recovery enabled';

  @override
  String get accountRecoveryCompleted => 'Account recovery completed';

  @override
  String accountActionFailedError(String error) {
    return 'Account action failed: $error';
  }

  @override
  String get accountDataCleared => 'Account data cleared';

  @override
  String get accountDeletionCancelled => 'Account deletion cancelled';

  @override
  String get accountDeletionScheduled => 'Account deletion scheduled';

  @override
  String get crossDeviceConflictInbox => 'Cross-device conflict inbox';

  @override
  String get theCrossDeviceBranchIsntVerified =>
      'The cross-device branch isn\'t verified yet; action and server version details are hidden.';

  @override
  String get thisDeviceDecryptsTheVerifiedBranch =>
      'This device decrypts the verified branch, re-signs it with this device\'s identity, then performs a CAS commit against the currently cached version. The original branch ciphertext is kept; the inbox shows this conflict until the commit or server resolution is confirmed.';

  @override
  String get concurrentBranchesSubmittedToTheServer =>
      'Concurrent branches submitted to the server by other devices are shown here. They can be selected only after signature, Vault ownership and key generation are verified; viewing the inbox doesn\'t rewrite the current record.';

  @override
  String get remoteDesktop2 => 'Remote desktop';

  @override
  String get connect2 => 'Connect';

  @override
  String get connectEverySshHostInThe =>
      'Connect every SSH host in the group and restore the layout';

  @override
  String get chooseTheWorkspaceModeAndThe2 =>
      'Choose the workspace mode and the page that opens by default.';

  @override
  String get choiceSavedOnThisDeviceWaiting =>
      'Choice saved on this device, waiting for sync confirmation.';

  @override
  String get choiceSavedTheInboxUpdatesAfter =>
      'Choice saved; the inbox updates after the next sync.';

  @override
  String get choiceSavedEncryptedOnThisDevice =>
      'Choice saved encrypted on this device, waiting for sync confirmation.';

  @override
  String get choiceSavedEncryptedOnThisDevice2 =>
      'Choice saved encrypted on this device and waiting to sync; you can retry once the network is back.';

  @override
  String get notificationsAndUpdates => 'Notifications and updates';

  @override
  String invitationActionFailedError(String error) {
    return 'Invitation action failed: $error';
  }

  @override
  String get couldntAdoptTheBranch => 'Couldn\'t adopt the branch';

  @override
  String get adoptTheVerifiedDeviceBranch =>
      'Adopt the verified device branch?';

  @override
  String get adoptThisBranch => 'Adopt this branch';

  @override
  String get reSignAndSync => 'Re-sign and sync';

  @override
  String get resetLayout => 'Reset layout';

  @override
  String get attachments => 'Attachments';

  @override
  String get needsANewChoice => 'Needs a new choice';

  @override
  String get aDeviceKeyPairIsGenerated =>
      'A device key pair is generated and saved only in this browser. Send the public request to a device that is already approved.';

  @override
  String get aPrivateSshWorkspaceThatSyncs =>
      'A private SSH workspace that syncs encrypted connections, credentials and snippets across your devices.';

  @override
  String get aTrustedDeviceSignsEnvelopesFor =>
      'A trusted device signs envelopes for each new device.';

  @override
  String get accountEmail => 'Account email';

  @override
  String get accountName => 'Account name';

  @override
  String get accountRecoveredSignInWithThe =>
      'Account recovered. Sign in with the new master password.';

  @override
  String get accountRecoveredSignInWithYour =>
      'Account recovered. Sign in with your new master password.';

  @override
  String get addThisDevice => 'Add this device';

  @override
  String get approveEveryDevice => 'Approve every device';

  @override
  String get cancelRecovery => 'Cancel recovery';

  @override
  String get cancelScheduledAccountDeletion =>
      'Cancel scheduled account deletion';

  @override
  String get cancelSignIn => 'Cancel sign-in';

  @override
  String get changeServer => 'Change server';

  @override
  String get commitRecovery => 'Commit recovery';

  @override
  String get confirmFingerprintAndContinue =>
      'Confirm fingerprint and continue';

  @override
  String get confirmMasterPassword => 'Confirm master password';

  @override
  String get connectSecurely => 'Connect securely';

  @override
  String get connectToYourServer => 'Connect to your server';

  @override
  String get copyThisEnrollmentJson => 'Copy this enrollment JSON';

  @override
  String get createInvitedAccount => 'Create invited account';

  @override
  String get createOwnerAccount => 'Create owner account';

  @override
  String get deviceName => 'Device name';

  @override
  String get emailOnTheInvitation => 'Email on the invitation';

  @override
  String get emailOrUsername => 'Email or username';

  @override
  String get encryptedOutboxKeepsEditsSafeBetween =>
      'Encrypted outbox keeps edits safe between connections.';

  @override
  String get endToEndEncryptedVault => 'End-to-end encrypted vault';

  @override
  String get enterAValidRecoveryCodeAnd =>
      'Enter a valid recovery code and matching new master password.';

  @override
  String get enterTheUrlOfYourSelf =>
      'Enter the URL of your self-hosted Atermius instance.';

  @override
  String get fingerprintReturnedByThisServerSha =>
      'Fingerprint returned by this server · SHA-256';

  @override
  String fingerprintReturnedByThisServerSha2(String candidateFingerprint) {
    return 'Fingerprint returned by this server · SHA-256: $candidateFingerprint';
  }

  @override
  String get firstVault => 'First Vault';

  @override
  String get generateRequest => 'Generate request';

  @override
  String get haveAnInstanceInvitationCreateAccount =>
      'Have an instance invitation? Create account';

  @override
  String get importApproval => 'Import approval';

  @override
  String get importApprovedDevice => 'Import approved device';

  @override
  String get importDeviceKeys => 'Import device keys';

  @override
  String get instanceInvitationToken => 'Instance invitation token';

  @override
  String get masterPassword => 'Master password';

  @override
  String get masterPassword12Characters => 'Master password · 12+ characters';

  @override
  String newAccountRecoveryCodeCode(String code) {
    return 'New account recovery code: $code';
  }

  @override
  String get newDeviceName => 'New device name';

  @override
  String get newMasterPassword12Characters =>
      'New master password · 12+ characters';

  @override
  String get offlineFirstSync => 'Offline-first sync';

  @override
  String get onlyYourUnlockedDevicesCanRead =>
      'Only your unlocked devices can read saved data.';

  @override
  String get ownerEmail => 'Owner email';

  @override
  String get pasteApprovalJson => 'Paste approval JSON';

  @override
  String get personalVault => 'Personal vault';

  @override
  String get previouslyTrustedFingerprintSha256 =>
      'Previously trusted fingerprint · SHA-256';

  @override
  String previouslyTrustedFingerprintSha256Pinnedfingerprint(
    String pinnedFingerprint,
  ) {
    return 'Previously trusted fingerprint · SHA-256: $pinnedFingerprint';
  }

  @override
  String get recoverAccount => 'Recover account';

  @override
  String get recoverAccountWithRecoveryCode =>
      'Recover account with recovery code';

  @override
  String get recoveredDevice => 'Recovered device';

  @override
  String get recoveryCode => 'Recovery code';

  @override
  String get recoveryWasCancelledNoAccountChanges =>
      'Recovery was cancelled. No account changes were committed.';

  @override
  String get remoteServersRequireHttpsHttpIs =>
      'Remote servers require HTTPS. HTTP is allowed only for localhost, 127.0.0.1 or ::1 development.';

  @override
  String get requestThisDevice => 'Request this device';

  @override
  String get restoredServerIdentityNeedsConfirmation =>
      'Restored server identity needs confirmation';

  @override
  String get retryRecoveryCompletion => 'Retry recovery completion';

  @override
  String get selfHosted => 'SELF-HOSTED';

  @override
  String get secretsAreEncryptedInThisClient =>
      'Secrets are encrypted in this client before sync.';

  @override
  String get serverUrl => 'Server URL';

  @override
  String get setUpYourPrivateVault => 'Set up your private vault';

  @override
  String get signInAndUnlock => 'Sign in and unlock';

  @override
  String get storeTheNewRecoveryCode => 'Store the new recovery code';

  @override
  String get theBootstrapTokenIsOneUse =>
      'The bootstrap token is one-use. The server never receives your master password or the generated Vault key.';

  @override
  String get theFirstAccountCreatesItsVault =>
      'The first account creates its Vault key on this device.';

  @override
  String get theServerReturnedADifferentSigning =>
      'The server returned a different signing key for the same instance. Compare the candidate fingerprint with an administrator or another trusted device over a separate channel. No account login or authentication request is sent before you confirm.';

  @override
  String get thisOneUseInvitationIsBound =>
      'This one-use invitation is bound to the email shown above. The server never receives your master password or the generated Vault key.';

  @override
  String get thisReplacesTheOldCodeStore =>
      'This replaces the old code. Store it outside this device; it cannot be shown again.';

  @override
  String get typeTheCandidateFingerprintExactly =>
      'Type the candidate fingerprint exactly';

  @override
  String get unlockYourWorkspace => 'Unlock your workspace';

  @override
  String get useARecoveryCode => 'Use a recovery code';

  @override
  String get useAuthenticatorCode => 'Use authenticator code';

  @override
  String get useTheAccountNameAndMaster =>
      'Use the account name and master password. This recovery does not restore a session; sign in again afterward.';

  @override
  String get useTheSaved256BitRecovery =>
      'Use the saved 256-bit recovery code to restore Vault key access and enroll this device. Choose a new master password. The server never receives the recovery code or plaintext Vault keys.';

  @override
  String get verifyAndUnlock => 'Verify and unlock';

  @override
  String get verifyRecoveryCode => 'Verify recovery code';

  @override
  String get verifyYourIdentity => 'Verify your identity';

  @override
  String get yourPasswordUnlocksTheAccountKey =>
      'Your password unlocks the account key locally.';

  @override
  String get yourServersYourKeysYourWorkspace =>
      'Your servers.\nYour keys.\nYour workspace.';

  @override
  String get theMasterPasswordsDontMatch => 'The master passwords don\'t match';

  @override
  String get couldntCancelAccountDeletion =>
      'Couldn\'t cancel account deletion';

  @override
  String get couldntConnectToTheServer => 'Couldn\'t connect to the server';

  @override
  String get registrationFailed => 'Registration failed';

  @override
  String get requestJsonCopied => 'Request JSON copied';

  @override
  String get browserStorage => 'Browser storage';

  @override
  String get checkAgain => 'Check again';

  @override
  String get checkingPersistentStorage => 'Checking persistent storage…';

  @override
  String get checkingStorageUsageEstimate => 'Checking storage usage estimate…';

  @override
  String estimatedUsageFormatbytesOfFormatbytes2For(
    String formatBytes,
    String formatBytes2,
  ) {
    return 'Estimated usage: $formatBytes of $formatBytes2 for this site';
  }

  @override
  String get persistentStorageCanReduceAutomaticEviction =>
      'Persistent storage can reduce automatic eviction, but it does not replace backups.';

  @override
  String get persistentStorageIsEnabled => 'Persistent storage is enabled';

  @override
  String get persistentStorageIsNotEnabled =>
      'Persistent storage is not enabled';

  @override
  String get persistentStorageStatusIsUnavailable =>
      'Persistent storage status is unavailable';

  @override
  String get requestPersistentStorage => 'Request persistent storage';

  @override
  String get storageUsageEstimateIsUnavailable =>
      'Storage usage estimate is unavailable';

  @override
  String get theBrowserCouldNotConfirmPersistent =>
      'The browser could not confirm persistent storage status.';

  @override
  String get theBrowserCurrentlyReportsPersistentStorage =>
      'The browser currently reports persistent storage is enabled.';

  @override
  String get theBrowserDidNotEnablePersistent =>
      'The browser did not enable persistent storage.';

  @override
  String get theRequestReturnedSuccessButThe =>
      'The request returned success, but the browser still reports storage is not persistent.';

  @override
  String get theRequestReturnedSuccessButThe2 =>
      'The request returned success, but the current persistence status could not be verified.';

  @override
  String pendingcountEncryptedChangeSAreWaiting(int pendingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingCount,
      locale: localeName,
      other: '$pendingCount encrypted changes are',
      one: '1 encrypted change is',
    );
    return '$_temp0 waiting in this browser’s local outbox. The server has not acknowledged them; clearing this site’s browser data before sync removes them from this browser.';
  }

  @override
  String roundGib(int round) {
    return '$round GiB';
  }

  @override
  String roundKib(int round) {
    return '$round KiB';
  }

  @override
  String roundMib(int round) {
    return '$round MiB';
  }

  @override
  String get fileWorkspaceIsClosed => 'File workspace is closed.';

  @override
  String get theSavedGroupLayoutIsInvalid =>
      'The saved group layout is invalid. Reset the layout and try again.';

  @override
  String get invalidGroupSessionMapping => 'Invalid group session mapping.';

  @override
  String get aGroupLayoutNeeds1To => 'A group layout needs 1 to 32 SSH hosts.';

  @override
  String get invalidLayoutHostsOrMoreThan =>
      'Invalid layout hosts or more than 32 panes.';

  @override
  String get invalidLayoutRatio => 'Invalid layout ratio.';

  @override
  String get thisWindowHasNoSshSessions =>
      'This window has no SSH sessions for this group.';

  @override
  String get upTo32PanesCanBe => 'Up to 32 panes can be saved.';

  @override
  String get attachFile => 'Attach file';

  @override
  String get attachmentDownload => 'Attachment download';

  @override
  String get attachmentUpload => 'Attachment upload';

  @override
  String attachmentsName(String name) {
    return 'Attachments · $name';
  }

  @override
  String get cancel2 => 'Cancel';

  @override
  String get chooseAFileToAttach => 'Choose a file to attach…';

  @override
  String get close => 'Close';

  @override
  String get discardDownloadedCopy => 'Discard downloaded copy';

  @override
  String get discardOrphanTransfer => 'Discard orphan transfer';

  @override
  String get downloadAttachment => 'Download attachment';

  @override
  String downloadUnavailableAboveFormatsize(String formatSize) {
    return 'Download unavailable above $formatSize';
  }

  @override
  String get downloadingAndVerifyingAttachment =>
      'Downloading and verifying attachment…';

  @override
  String get encryptingAndTransferring => 'Encrypting and transferring…';

  @override
  String get filesAreEncryptedOnThisDevice =>
      'Files are encrypted on this device before upload. Names, types, file keys and file contents stay inside the encrypted host record.';

  @override
  String get noAttachmentsSavedForThisHost =>
      'No attachments saved for this host.';

  @override
  String get preparingAttachment => 'Preparing attachment…';

  @override
  String get removeAttachment => 'Remove attachment';

  @override
  String get removeAttachmentFromThisHost =>
      'Remove attachment from this host?';

  @override
  String get removeFromHost => 'Remove from host';

  @override
  String removeFilenameFromTheCurrentEncrypted(String fileName) {
    return 'Remove $fileName from the current encrypted host record? Earlier host revisions may retain their attachment references until server retention cleanup.';
  }

  @override
  String get removingAttachment => 'Removing attachment…';

  @override
  String get resumeDownload => 'Resume download';

  @override
  String get resumeUpload => 'Resume upload';

  @override
  String get resumingEncryptedUpload => 'Resuming encrypted upload…';

  @override
  String get saveCancelled => 'Save cancelled.';

  @override
  String get saveCancelledTheVerifiedEncryptedDownload =>
      'Save cancelled. The verified encrypted download is kept for retry.';

  @override
  String get savingDecryptedAttachment => 'Saving decrypted attachment…';

  @override
  String get thisFileCannotBeLoadedInto =>
      'This file cannot be loaded into client memory. Try a smaller file.';

  @override
  String get transferTasks => 'Transfer tasks';

  @override
  String valuevalueMoreTasks(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: '$valueValue more tasks',
      one: '1 more task',
    );
    return '$_temp0';
  }

  @override
  String get addAHost => 'Add a host';

  @override
  String get authentication => 'Authentication';

  @override
  String get directConnection => 'Direct connection';

  @override
  String get displayName => 'Display name';

  @override
  String get editHost => 'Edit host';

  @override
  String get editPrivateKey => 'Edit private key';

  @override
  String get group => 'Group';

  @override
  String get hidePrivateKey => 'Hide private key';

  @override
  String get hostnameOrIp => 'Hostname or IP';

  @override
  String get jumpHost => 'Jump Host';

  @override
  String get loginDetailsBelongToThisHost =>
      'Login details belong to this Host and are encrypted with it.';

  @override
  String get noGroup => 'No group';

  @override
  String get noKeyEntered => 'No key entered';

  @override
  String get pinTheCertificateFingerprintSuppliedBy =>
      'Pin the certificate fingerprint supplied by your administrator.';

  @override
  String get rdpCertificateSha256Optional =>
      'RDP certificate SHA-256 (optional)';

  @override
  String get routeThroughUpTo8Hosts =>
      'Route through up to 8 Hosts before opening this Host.';

  @override
  String get saveEncryptedHost => 'Save encrypted host';

  @override
  String get separateTagsWithCommas => 'Separate tags with commas.';

  @override
  String get tags => 'Tags';

  @override
  String get thisSavedGroupIsUnavailableChoose =>
      'This saved Group is unavailable. Choose No group to clear it.';

  @override
  String get thisSavedJumpHostIsUnavailable =>
      'This saved Jump Host is unavailable, forms a cycle, or would exceed 8 hops. Choose Direct connection or a valid Host to repair it.';

  @override
  String get unavailableJumpHost => 'Unavailable Jump Host';

  @override
  String get signInDetailsAreStoredEncrypted =>
      'Sign-in details are stored encrypted. When connecting, the trusted remote desktop gateway handles the sign-in credentials and the display.';

  @override
  String labelPressEnterToConnect(String label) {
    return '$label  ·  Press Enter to connect';
  }

  @override
  String get searchHostsOrTypeAnSsh =>
      'Search hosts, or type an ssh / rdp / vnc / console command';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get chooseAHostToConnectTo => 'Choose a host to connect to';

  @override
  String countHosts2(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hosts',
      one: '1 host',
    );
    return '$_temp0';
  }

  @override
  String get all => 'All';

  @override
  String get closeSearch => 'Close search';

  @override
  String get allGroups => 'All groups';

  @override
  String get filterByGroup => 'Filter by group';

  @override
  String get searchAndQuickConnect => 'Search and quick connect';

  @override
  String get favorites => 'Favorites';

  @override
  String get noMatchingHostsTypeAnSsh =>
      'No matching hosts. Type an ssh / rdp / vnc command to connect to a new address.';

  @override
  String get operatingSystemNotIdentifiedYet =>
      'Operating system not identified yet';

  @override
  String operatingSystemLabel(String label) {
    return 'Operating system: $label';
  }

  @override
  String get originalSshSessionConnected => 'Original SSH session · connected';

  @override
  String get tools => 'Tools';

  @override
  String get originalSshSessionLive => 'Original SSH session · live';

  @override
  String get filesSftpScp => 'Files · SFTP / SCP';

  @override
  String get couldntOpenTheTerminalWindowGo =>
      'Couldn\'t open the terminal window. Go back to the main window and check the connection.';

  @override
  String get thisWindowKeepsUsingTheOriginal =>
      'This window keeps using the original SSH session.';

  @override
  String get terminalProperties => 'Terminal properties';

  @override
  String get earlierOutputExceedsThisWindowsDisplay =>
      'Earlier output exceeds this window\'s display limit. Running commands are not affected.';

  @override
  String get connectionLostReturnToTheOriginal =>
      'Connection lost · return to the original window';

  @override
  String get connectionLost => 'Connection lost';

  @override
  String get sshOutputStreamError => '\n[SSH output stream error]\n';

  @override
  String get sshConnectionClosed => '\n[SSH connection closed]\n';

  @override
  String get sshErrorStreamUnavailable => '\n[SSH error stream unavailable]\n';

  @override
  String get anotherOperationIsRunningRetryWhen =>
      'Another operation is running. Retry when it ends.';

  @override
  String get bashInputHistory => 'Bash input history';

  @override
  String get console => 'Console';

  @override
  String get couldNotSaveForwardingSettingsNothing =>
      'Could not save forwarding settings; nothing was changed.';

  @override
  String get home => 'Home';

  @override
  String hostHostid(String hostId) {
    return 'Host $hostId';
  }

  @override
  String get theHostSaveResultCouldntBe =>
      'The Host save result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get theHostWasSavedButThe =>
      'The Host was saved, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theHostWasDeletedButThe =>
      'The Host was deleted, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theHostWasChangedByAnother =>
      'The Host was changed by another operation. Reopen it and try again.';

  @override
  String get theHostWasUpdatedButThe =>
      'The Host was updated, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get hostActions => 'Host actions';

  @override
  String get whenAHostDoesntSelectA =>
      'When a Host doesn\'t select a credential explicitly, the default credential of the nearest ancestor group is used.';

  @override
  String get localHostRevisionIsMissing => 'Local Host revision is missing.';

  @override
  String get localDefaultWorkspacePreferenceIsInvalid =>
      'Local default workspace preference is invalid.';

  @override
  String get localProfileCleanupFailed => 'Local profile cleanup failed.';

  @override
  String get localvaultHostKeyTrust => 'LocalVault host key trust';

  @override
  String get noLocalProfile => 'No local profile.';

  @override
  String get notStartedFromASingleConnected =>
      'Not started from a single connected SSH tab. Edit profiles here, then use SSH port forwarding in a connected tab to start them.';

  @override
  String get preferencesCannotBeTheDefaultWorkspace =>
      'Preferences cannot be the default workspace.';

  @override
  String get profilesAreEncryptedInsideThisHost2 =>
      'Profiles are encrypted inside this Host record of the local profile on this device. Running state and sockets are never stored.';

  @override
  String get protectedDeviceKeyUnavailable =>
      'Protected device key unavailable.';

  @override
  String get theSshHostKeyChangedOr =>
      'The SSH host key changed or the trust records conflict; the connection was rejected. Review and revoke the old trust first.';

  @override
  String get theSshHostKeyWasntApproved =>
      'The SSH host key wasn\'t approved; the connection was rejected.';

  @override
  String get sshPrivateKey => 'SSH private key';

  @override
  String get sshPortForwarding2 => 'SSH port forwarding';

  @override
  String get shellLabel => 'Shell label';

  @override
  String get snippetChanged => 'Snippet changed';

  @override
  String get theLocalProfileChanged => 'The local profile changed.';

  @override
  String get thisHostChangedInAnotherOperation =>
      'This Host changed in another operation. The list was refreshed; review and retry.';

  @override
  String get webLocalvaultDoesntSupportSshSftp =>
      'Web LocalVault doesn\'t support SSH / SFTP yet';

  @override
  String algorithmFingerprintOriginallyApprovedInArchive(
    String algorithm,
    String fingerprint,
    DateTime toLocal,
  ) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$algorithm\n$fingerprint\nOriginally approved in archive: $toLocalString';
  }

  @override
  String groupparentlabelHostscountHostsChildrencountSubgroups(
    String groupParentLabel,
    int hostsCount,
    int childrenCount,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      hostsCount,
      locale: localeName,
      other: '$hostsCount Hosts',
      one: '1 Host',
    );
    String _temp1 = intl.Intl.pluralLogic(
      childrenCount,
      locale: localeName,
      other: '$childrenCount subgroups',
      one: '1 subgroup',
    );
    return '$groupParentLabel · $_temp0 · $_temp1';
  }

  @override
  String hostPortPendingReview(String host, int port) {
    return '$host:$port · pending review';
  }

  @override
  String nameWillBeDeletedFromThis(String name) {
    return '\"$name\" will be deleted from this local profile.';
  }

  @override
  String titleWillBeDeletedFromThis(String title) {
    return '\"$title\" will be deleted from this local profile.';
  }

  @override
  String get previousMatch2 => 'Previous match';

  @override
  String get nextMatch2 => 'Next match';

  @override
  String get noDefaultCredential => 'No default credential';

  @override
  String get theLocalArchivePassphrasesDontMatch =>
      'The local archive passphrases don\'t match.';

  @override
  String theMasterPasswordMustBeAt(int minimumPasswordLength) {
    return 'The master password must be at least $minimumPasswordLength characters.';
  }

  @override
  String get masterPasswordAtLeast12Characters =>
      'Master password (at least 12 characters)';

  @override
  String get hostsAndSignInDetailsAre =>
      'Hosts and sign-in details are stored in the local profile';

  @override
  String get couldntSaveTheHostCheckThe =>
      'Couldn\'t save the host. Check the settings and try again.';

  @override
  String get useTheModAltAndShift =>
      'Use the mod, alt and shift modifiers; mod means Command on Apple platforms and Control elsewhere. Every shortcut must be unique, and combinations reserved by the browser or operating system can\'t be used.';

  @override
  String get saveGroup => 'Save group';

  @override
  String get saveEncryptedCredential => 'Save encrypted credential';

  @override
  String get saveEncryptedSnippet => 'Save encrypted snippet';

  @override
  String get saveShortcuts => 'Save shortcuts';

  @override
  String get theSavedGroupLayoutIsInvalid2 =>
      'The saved group layout is invalid. Reset the layout first.';

  @override
  String get saveTerminalTheme => 'Save terminal theme';

  @override
  String get saveTerminalFontSize => 'Save terminal font size';

  @override
  String get saveDefaultWorkspace => 'Save default workspace';

  @override
  String get trustReviewFailedTheExistingSsh =>
      'Trust review failed. The existing SSH trust state is unchanged; reload and check again.';

  @override
  String get thePreferenceSaveResultCouldntBe =>
      'The preference save result couldn\'t be confirmed. Reload before deciding whether to save again.';

  @override
  String get preferencesSavedAndApplied => 'Preferences saved and applied.';

  @override
  String get preferencesAreSavedEncryptedInThis =>
      'Preferences are saved encrypted in this local profile.';

  @override
  String get preferencesWereChangedByAnotherOperation =>
      'Preferences were changed by another operation and the current values were reloaded. Review them before saving.';

  @override
  String get stopConnecting => 'Stop connecting';

  @override
  String get stopCapture => 'Stop capture';

  @override
  String get otherLocalRecords => 'Other local records';

  @override
  String get credentials => 'Credentials';

  @override
  String get theCredentialSaveResultCouldntBe =>
      'The credential save result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get theCredentialDeletionResultCouldntBe =>
      'The credential deletion result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String credentialParameterNameMustReferenceA(String name) {
    return 'Credential parameter $name must reference a password credential in this local profile.';
  }

  @override
  String get credentialName => 'Credential name';

  @override
  String get theCredentialNoLongerExistsRefresh =>
      'The credential no longer exists. Refresh the list.';

  @override
  String get theCredentialWasSavedButThe =>
      'The credential was saved, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theCredentialWasDeletedButThe =>
      'The credential was deleted, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theCredentialWasChangedByAnother =>
      'The credential was changed by another operation. Refresh the list and try again.';

  @override
  String get theCredentialWasUpdatedButThe =>
      'The credential was updated, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get credentialActions => 'Credential actions';

  @override
  String get theCredentialUpdateResultCouldntBe =>
      'The credential update result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get setTheTerminalFontSizeColors =>
      'Set the terminal font size, colors and shortcuts separately.';

  @override
  String groupGroupid(String groupId) {
    return 'Group $groupId';
  }

  @override
  String groupName(String name) {
    return 'Group \"$name\"';
  }

  @override
  String get theGroupIsStillUsedBy =>
      'The group is still used by subgroups or Hosts. Move or delete them before deleting this group.';

  @override
  String get theGroupSaveResultCouldntBe =>
      'The group save result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get theGroupDeletionResultCouldntBe =>
      'The group deletion result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get groupName2 => 'Group name';

  @override
  String get theGroupWasSavedButThe =>
      'The group was saved, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theGroupWasDeletedButThe =>
      'The group was deleted, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theGroupChangedRefreshAndSave =>
      'The group changed. Refresh and save the layout again.';

  @override
  String get theGroupWasChangedByAnother =>
      'The group was changed by another operation. Refresh the list and try again.';

  @override
  String get theGroupWasChangedByAnother2 =>
      'The group was changed by another operation. Reopen it and try again.';

  @override
  String get theGroupWasUpdatedButThe =>
      'The group was updated, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String groupActionsName(String name) {
    return 'Group actions: $name';
  }

  @override
  String get theGroupUpdateResultCouldntBe =>
      'The group update result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get groupWindowLayoutSaved => 'Group window layout saved.';

  @override
  String get theGroupRecordWasChangedBy =>
      'The group record was changed by another operation. Refresh the list and try again.';

  @override
  String get listView => 'List view';

  @override
  String get afterCreatingALocalProfileYou =>
      'After creating a local profile, you can store Hosts and sign-in credentials encrypted on this device.';

  @override
  String createdFormatdate(String formatDate) {
    return 'Created $formatDate';
  }

  @override
  String get createGroupsToOrganizeHostsGroups =>
      'Create groups to organize Hosts; groups and parent relationships are stored only in this local profile.';

  @override
  String get createAndUnlock => 'Create and unlock';

  @override
  String get createNewProfile => 'Create new profile';

  @override
  String get couldntDeleteTheHostTryAgain =>
      'Couldn\'t delete the Host. Try again.';

  @override
  String get deleteHost => 'Delete Host?';

  @override
  String get deleteCredential => 'Delete credential';

  @override
  String get deleteCredential2 => 'Delete credential?';

  @override
  String get deleteGroup => 'Delete group';

  @override
  String get deleteGroup2 => 'Delete group?';

  @override
  String get deleteSnippet => 'Delete snippet';

  @override
  String get deleteSnippet2 => 'Delete snippet?';

  @override
  String get couldntSaveHistoryCommandsInMemory =>
      'Couldn\'t save history; commands in memory can still be viewed this time. Check local storage.';

  @override
  String get previousParentUnavailable => 'Previous parent unavailable';

  @override
  String get previousDefaultCredentialUnavailable =>
      'Previous default credential unavailable';

  @override
  String get argumentList => 'Argument list';

  @override
  String get parameterDefinitions => 'Parameter definitions';

  @override
  String get parameterDefinitionsJsonArray =>
      'Parameter definitions (JSON array)';

  @override
  String get argumentsJsonArray => 'Arguments (JSON array)';

  @override
  String windowfailuresPlural11MoreWindow(int windowFailures) {
    String _temp0 = intl.Intl.pluralLogic(
      windowFailures,
      locale: localeName,
      other: '$windowFailures more windows or positions couldn\'t be restored.',
      one: '1 more window or position couldn\'t be restored.',
    );
    return '$_temp0';
  }

  @override
  String onlyContinueAfterVerifyingTheFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
  ) {
    return 'Only continue after verifying the fingerprint over a trusted channel. Once confirmed, this device creates a new local trust record for the following endpoint:\n\n$host:$port\n$algorithm\n$fingerprint\n\nAn old approval in the archive doesn\'t authorize connections by itself.';
  }

  @override
  String get afterEnablingCopyTheSetupCommand =>
      'After enabling, copy the setup command, paste it into the current Bash and press Enter. Only completed commands are recorded; input at password prompts isn\'t captured, but secrets typed in commands may still be recorded. History is saved encrypted in this device\'s Profile, up to 500 entries / 48 KiB per host. After stopping capture, run atermius_off in Bash to remove the hook.';

  @override
  String get enableAndCopySetupCommand => 'Enable and copy setup command';

  @override
  String get completedCommandsAreRecordedAfterEnabling =>
      'Completed commands are recorded after enabling Bash integration in Recording settings.';

  @override
  String get reviewAndTrust => 'Review and trust';

  @override
  String get reviewSshHostKeysFromThe =>
      'Review SSH host keys from the archive';

  @override
  String get wrongPasswordOrTheLocalProfile =>
      'Wrong password, or the local profile can\'t be unlocked.';

  @override
  String get importLocalEncryptedArchive => 'Import local encrypted archive';

  @override
  String get exportLocalEncryptedArchive => 'Export local encrypted archive';

  @override
  String get trusted => 'Trusted';

  @override
  String get savingTheLocalEncryptedArchiveWas =>
      'Saving the local encrypted archive was cancelled.';

  @override
  String get bashRecordingIsOnClickTo =>
      'Bash recording is on. Click to insert, press Enter to run.';

  @override
  String get revoked => 'Revoked';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get theArchiveWasImportedButSome =>
      'The archive was imported, but some lists couldn\'t be refreshed. Reload the profile.';

  @override
  String get thereAreTooManySplitsTo =>
      'There are too many splits to save this group layout.';

  @override
  String get thisWindowHasNoSessionLayout =>
      'This window has no session layout for this group.';

  @override
  String get invalidShortcutUseSupportedLetterDigit =>
      'Invalid shortcut: use supported letter, digit or F1–F12 combinations, and make sure every combination is unique.';

  @override
  String get aShortcutIsInvalidOrDuplicated =>
      'A shortcut is invalid or duplicated. Fix it before saving.';

  @override
  String get restoreDefaultShortcuts => 'Restore default shortcuts';

  @override
  String get theSelectedParentGroupNoLonger =>
      'The selected parent group no longer exists. Refresh the list and try again.';

  @override
  String get openLocalWorkspace => 'Open local workspace';

  @override
  String get executionType => 'Execution type';

  @override
  String get reject => 'Reject';

  @override
  String get searchTerminal => 'Search terminal';

  @override
  String get searchTerminalHistory => 'Search terminal history';

  @override
  String get revokeSshHostKeyTrust => 'Revoke SSH host key trust?';

  @override
  String afterRevokingThisKeyForHost(String host, int port) {
    return 'After revoking this key for $host:$port, later connections must be verified and explicitly approved again.';
  }

  @override
  String get revokeTrust => 'Revoke trust';

  @override
  String get revokingFailedTheTrustStateIs =>
      'Revoking failed. The trust state is unchanged; try again.';

  @override
  String get revokeTrustForThisKey => 'Revoke trust for this key';

  @override
  String get theFileWindowDidntOpenTry =>
      'The file window didn\'t open. Try again.';

  @override
  String get theHostRequestedByTheFile =>
      'The host requested by the file window doesn\'t exist.';

  @override
  String get theLocalProfileRequestedByThe =>
      'The local profile requested by the file window doesn\'t exist.';

  @override
  String get textParametersAndPasswordCredentialReferences =>
      'Text parameters and password credential references use the same structure as server snippets; all bodies and default values are encrypted.';

  @override
  String get disconnectCurrentTerminal => 'Disconnect current terminal';

  @override
  String get disconnect => 'Disconnect';

  @override
  String get passwordsAndKeysForNewHosts =>
      'Passwords and keys for new hosts are set directly in the host details.';

  @override
  String get newGroup => 'New group';

  @override
  String get theNewWindowDidntOpenThe =>
      'The new window didn\'t open; the session stays in the current window.';

  @override
  String get theNewWindowDidntOpenThe2 =>
      'The new window didn\'t open; the remote desktop stays in the current window.';

  @override
  String get couldntSaveTheGroupLayoutTry =>
      'Couldn\'t save the group layout. Try again.';

  @override
  String get couldntSaveTheWindowSetCheck =>
      'Couldn\'t save the window set. Check the name and number of sessions, or unlock again and retry.';

  @override
  String get couldntCreateTheLocalProfileTry =>
      'Couldn\'t create the local profile. Try again.';

  @override
  String get couldntDeleteTheWindowSet => 'Couldn\'t delete the window set.';

  @override
  String get couldntRefreshTheHostListThe =>
      'Couldn\'t refresh the Host list. The write may have been committed; reload before continuing.';

  @override
  String get couldntRefreshTheLocalCredentialList =>
      'Couldn\'t refresh the local credential list. The write may have been committed; reload before continuing.';

  @override
  String get couldntRefreshTheLocalGroupList =>
      'Couldn\'t refresh the local group list. The write may have been committed; reload before continuing.';

  @override
  String get couldntRefreshTheLocalSnippetList =>
      'Couldn\'t refresh the local snippet list. The write may have been committed; reload before continuing.';

  @override
  String get couldntStartTheConsole => 'Couldn\'t start the console.';

  @override
  String get couldntSafelySaveTheDeviceUnlock =>
      'Couldn\'t safely save the device unlock key. Check the system secure storage and try again, or create a password-protected profile manually.';

  @override
  String get couldntExitTheLocalProfileSafely =>
      'Couldn\'t exit the local profile safely. Try again.';

  @override
  String get couldntImportTheLocalArchiveNothing =>
      'Couldn\'t import the local archive; nothing was partially written to the target profile.';

  @override
  String get couldntExportTheLocalProfileTry =>
      'Couldn\'t export the local profile. Try again; local data is unchanged.';

  @override
  String get couldntOpenANewWindowTry =>
      'Couldn\'t open a new window. Try again.';

  @override
  String get couldntOpenTheWindowSet => 'Couldn\'t open the window set.';

  @override
  String get couldntOpenTheRequestedFileWindow =>
      'Couldn\'t open the requested file window. Check the connection and host key trust.';

  @override
  String get couldntConfirmThatTheTargetProfile =>
      'Couldn\'t confirm that the target profile is empty. Try again.';

  @override
  String get couldntReadLocalSshHostKey =>
      'Couldn\'t read local SSH host key trust.';

  @override
  String get couldntReadLocalPreferencesTheSave =>
      'Couldn\'t read local preferences. The save may have been committed; reload before continuing.';

  @override
  String get couldntReadLocalPreferencesYouCan =>
      'Couldn\'t read local preferences. You can retry on the Preferences page.';

  @override
  String get couldntReadTheLocalCredentialList =>
      'Couldn\'t read the local credential list. You can retry on the Credentials page.';

  @override
  String get couldntReadTheLocalGroupList =>
      'Couldn\'t read the local group list. You can retry on the Groups page.';

  @override
  String get couldntReadTheLocalArchiveFile =>
      'Couldn\'t read the local archive file. Try again.';

  @override
  String get couldntReadTheLocalSnippetList =>
      'Couldn\'t read the local snippet list. You can retry on the Snippets page.';

  @override
  String get couldntReadTheLocalProfileList2 =>
      'Couldn\'t read the local profile list. Try again before creating a profile.';

  @override
  String get couldntReadThisHostsSignIn =>
      'Couldn\'t read this host\'s sign-in details.';

  @override
  String get couldntConnectToTheLocalSsh =>
      'Couldn\'t connect to the local SSH Host. Check the network and credentials, then try again.';

  @override
  String get showKey => 'Show key';

  @override
  String get couldntUpdateTheHostTryAgain =>
      'Couldn\'t update the host. Try again.';

  @override
  String valuevaluePlural11MonitorWindow(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other:
          '$valueValue monitor windows couldn\'t open; choose again to retry.',
      one: '1 monitor window couldn\'t open; choose again to retry.',
    );
    return '$_temp0';
  }

  @override
  String get localUnlocked => 'Local · unlocked';

  @override
  String get localLocked => 'Local · locked';

  @override
  String get localEncryptedArchiveSaved => 'Local encrypted archive saved.';

  @override
  String get theLocalEncryptedArchiveWasImported =>
      'The local encrypted archive was imported; each active SSH host key in the archive must be reviewed in Host key trust.';

  @override
  String get localArchivePassphrase => 'Local archive passphrase';

  @override
  String get theLocalArchivePassphraseCanBe =>
      'The local archive passphrase can be at most 1024 UTF-8 bytes.';

  @override
  String get theLocalArchiveFileIsInvalid =>
      'The local archive file is invalid or exceeds the size limit.';

  @override
  String get theLocalArchiveFileExceedsThe =>
      'The local archive file exceeds the size limit.';

  @override
  String get localModeOnlyManagesEncryptedSnippets =>
      'Local mode only manages encrypted snippets; switch to server sync mode to connect to hosts and run snippets.';

  @override
  String get localProfile2 => 'Local profile';

  @override
  String localProfileSubstring2(String substring) {
    return 'Local profile · $substring';
  }

  @override
  String get localProfileMasterPassword => 'Local profile master password';

  @override
  String get localProfileDataIsMissingOr =>
      'Local profile data is missing or unreadable. Unlocking was blocked so an empty database isn\'t treated as a valid profile; restore the local data or use a backup.';

  @override
  String get tagsCommaSeparated => 'Tags (comma-separated)';

  @override
  String get verifyAndTrustThisKey => 'Verify and trust this key';

  @override
  String get thisLocalvaultSshRouteIsntSupported =>
      'This LocalVault SSH route isn\'t supported.';

  @override
  String get thisLocalvaultHasNoSshHost =>
      'This LocalVault has no SSH host key trust records yet.';

  @override
  String get thisHostKeyWasRevokedBefore => 'This host key was revoked before';

  @override
  String thisCredentialIsStillReferencedBy(String credentialReferenceLabel) {
    return 'This credential is still referenced by $credentialReferenceLabel. Change or remove that reference before deleting it.';
  }

  @override
  String get thisGroupDoesntHaveAnyConnectable =>
      'This group doesn\'t have any connectable SSH hosts yet.';

  @override
  String get thisPassphraseIsSeparateFromThe =>
      'This passphrase is separate from the local profile master password; store it separately. Archive contents are encrypted with Argon2id and XChaCha20-Poly1305.';

  @override
  String get thisWorkspaceIsProtectedByThe =>
      'This workspace is protected by the operating system account\'s secure storage; locking closes the current session.';

  @override
  String get thisConsoleIsntSupportedOnThis =>
      'This console isn\'t supported on this platform.';

  @override
  String get eachLayoutCanHaveUpTo =>
      'Each layout can have up to 32 SSH hosts. Split it into subgroups.';

  @override
  String get noMatchingHosts => 'No matching hosts';

  @override
  String get localvaultInTheBrowserCanManage =>
      'LocalVault in the browser can manage Hosts and credentials with local encryption, but it can\'t open SSH or SFTP connections here. Return to workspace selection and enter the server workspace to connect to Hosts in a synced Vault through the Web Relay.';

  @override
  String get addHostDetailsToStoreThem =>
      'Add host details to store them encrypted in this local profile.';

  @override
  String get addCredential => 'Add credential';

  @override
  String get addLocalCredential => 'Add local credential';

  @override
  String get addLocalGroup => 'Add local group';

  @override
  String get addLocalSnippet => 'Add local snippet';

  @override
  String get addSnippet => 'Add snippet';

  @override
  String get addASignInPasswordOr =>
      'Add a sign-in password or SSH private key; the ciphertext is stored only in this local profile.';

  @override
  String get addAScriptOrAStructured =>
      'Add a script or a structured Bash command; the body is saved only in the encrypted local profile.';

  @override
  String get parentGroup => 'Parent group';

  @override
  String get theParentGroupNoLongerExists =>
      'The parent group no longer exists, or this hierarchy would create a cycle. Choose again and retry.';

  @override
  String get parentMissing => 'Parent missing';

  @override
  String parentName(String name) {
    return 'Parent: $name';
  }

  @override
  String get snippet => 'Snippet';

  @override
  String snippetSnippetid(String snippetId) {
    return 'Snippet $snippetId';
  }

  @override
  String snippetTitle(String title) {
    return 'Snippet \"$title\"';
  }

  @override
  String get theSnippetSaveResultCouldntBe =>
      'The snippet save result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get theSnippetDeletionResultCouldntBe =>
      'The snippet deletion result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get theSnippetNoLongerExistsRefresh =>
      'The snippet no longer exists. Refresh the list.';

  @override
  String get theSnippetWasSavedButThe =>
      'The snippet was saved, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theSnippetWasDeletedButThe =>
      'The snippet was deleted, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String get theSnippetWasChangedByAnother =>
      'The snippet was changed by another operation. Refresh the list and try again.';

  @override
  String get theSnippetWasUpdatedButThe =>
      'The snippet was updated, but the list couldn\'t be refreshed. Refresh the list again.';

  @override
  String snippetActionsTitle(String title) {
    return 'Snippet actions: $title';
  }

  @override
  String get theSnippetUpdateResultCouldntBe =>
      'The snippet update result couldn\'t be confirmed. Refresh the list before deciding whether to retry.';

  @override
  String get snippetTitle2 => 'Snippet title';

  @override
  String existingShellLabelShell(String shell) {
    return 'Existing shell label: $shell';
  }

  @override
  String get leaveBlankToKeepTheCurrent =>
      'Leave blank to keep the current key; anything you enter replaces it.';

  @override
  String targetHostPortAlgorithmAlgorithmFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
    String valueValue,
  ) {
    return 'Target: $host:$port\nAlgorithm: $algorithm\nFingerprint: $fingerprint\n\n$valueValue';
  }

  @override
  String get confirmTrustingThisKey => 'Confirm trusting this key';

  @override
  String get confirmLocalArchivePassphrase =>
      'Confirm local archive passphrase';

  @override
  String get privateKeyPassphraseOptional =>
      'Private key passphrase (optional)';

  @override
  String get program => 'Program';

  @override
  String get windowSetSavedSomeSeparateWindows =>
      'Window set saved; some separate windows don\'t support reading their position.';

  @override
  String windowSetOpenedValuevalueCountSessions(
    int valueValue,
    int count,
    int failures,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      failures,
      locale: localeName,
      other: '$failures couldn\'t connect',
      one: '1 couldn\'t connect',
    );
    return 'Window set opened $valueValue/$count sessions; $_temp0.';
  }

  @override
  String get portForwarding => 'Port forwarding';

  @override
  String get manageSshHostKeyTrust => 'Manage SSH host key trust';

  @override
  String get terminalTheme => 'Terminal theme';

  @override
  String get terminalFontSize2 => 'Terminal font size';

  @override
  String get structuredBashCommand => 'Structured Bash command';

  @override
  String get structuredCommandsSupportBashOnlyHere =>
      'Structured commands support Bash only; here they\'re only saved encrypted and never run in local mode.';

  @override
  String get continueLabel2 => 'Continue';

  @override
  String get editCredential => 'Edit credential';

  @override
  String get editLocalCredential => 'Edit local credential';

  @override
  String get editLocalGroup => 'Edit local group';

  @override
  String get editLocalSnippet => 'Edit local snippet';

  @override
  String get editSnippet => 'Edit snippet';

  @override
  String get gridView => 'Grid view';

  @override
  String get script => 'Script';

  @override
  String scriptShell(String shell) {
    return 'Script · $shell';
  }

  @override
  String get scriptBody => 'Script body';

  @override
  String get unlockLocalProfile => 'Unlock local profile';

  @override
  String get authenticationType => 'Authentication type';

  @override
  String get letExternalAiAccessTheCurrent =>
      'Let external AI access the current local workspace.';

  @override
  String get setLocalArchivePassphrase => 'Set local archive passphrase';

  @override
  String get thisPreferenceAlreadyExistsAndThe =>
      'This preference already exists and the current value was reloaded. Review it before saving.';

  @override
  String get thisKeyWasRevokedBeforeOnly =>
      'This key was revoked before. Only approve it again after re-verifying the server\'s identity.';

  @override
  String get thisSnippetIdAlreadyExistsCreate =>
      'This snippet ID already exists. Create it again.';

  @override
  String get createAnEmptyLocalProfileFirst =>
      'Create an empty local profile first, then import the archive.';

  @override
  String get unlockTheLocalProfileFirst => 'Unlock the local profile first.';

  @override
  String get chooseALocalProfileFirst => 'Choose a local profile first.';

  @override
  String get unlockTheTargetLocalProfileTo =>
      'Unlock the target local profile to open the file window.';

  @override
  String get enterTheSshPrivateKey => 'Enter the SSH private key.';

  @override
  String get enterACredentialNameAndUser =>
      'Enter a credential name and user name.';

  @override
  String get enterAPassword => 'Enter a password.';

  @override
  String get enterTheLocalProfileMasterPassword =>
      'Enter the local profile master password.';

  @override
  String get enterASnippetTitle => 'Enter a snippet title.';

  @override
  String get enterTheScriptBody => 'Enter the script body.';

  @override
  String get verifyThisFingerprintOverATrusted =>
      'Verify this fingerprint over a trusted channel. Once approved, it\'s saved only in the current LocalVault.';

  @override
  String get enterLocalArchivePassphrase => 'Enter local archive passphrase';

  @override
  String get backToWorkspaceSelection => 'Back to workspace selection';

  @override
  String get noHostsYet => 'No Hosts yet';

  @override
  String get noCredentialsYet => 'No credentials yet';

  @override
  String get noGroupsYet => 'No groups yet';

  @override
  String get noLocalProfilesYet => 'No local profiles yet';

  @override
  String get noSnippetsYet => 'No snippets yet';

  @override
  String get connectGroup => 'Connect group';

  @override
  String get connectionClosed => 'Connection closed';

  @override
  String get connectDirectFromThisDevice => 'Connect (direct from this device)';

  @override
  String get exitLocalProfile => 'Exit local profile';

  @override
  String get chooseTheWorkspaceModeAndThe =>
      'Choose the workspace mode and the page that opens by default. Settings are saved in the current local profile.';

  @override
  String get chooseAProfileToUnlock => 'Choose a profile to unlock';

  @override
  String get someSeparateWindowsOrWindowPositions =>
      'Some separate windows or window positions couldn\'t be restored; sessions stay in the current window.';

  @override
  String profileSubstring(String substring) {
    return 'Profile $substring';
  }

  @override
  String get profileHostAndCredentialRecordsAre =>
      'Profile, Host and credential records are protected with a local encryption key.';

  @override
  String get theProfileWasClosedButAutomatic =>
      'The profile was closed, but automatic unlock couldn\'t be revoked. Unlock again and lock it to retry.';

  @override
  String get retryRefresh => 'Retry refresh';

  @override
  String get retryReading => 'Retry reading';

  @override
  String get retryReadingProfiles => 'Retry reading profiles';

  @override
  String get lockAndReturnToProfiles => 'Lock and return to profiles';

  @override
  String get lockProfile => 'Lock profile';

  @override
  String get hideKey => 'Hide key';

  @override
  String get topLevelGroup => 'Top-level group';

  @override
  String get color => 'Color';

  @override
  String get firstConnectionUnknownSshHostKey =>
      'First connection: unknown SSH host key';

  @override
  String get defaultLabel => 'Default';

  @override
  String get defaultCredential => 'Default credential';

  @override
  String get allLocalRecordsArePreflightedBefore =>
      'All local records are preflighted before the new Vault is created. Unsupported preferences, tombstones, missing references, or attachment object references stop the migration before any server write.';

  @override
  String get cancelEmptyPreparation => 'Cancel empty preparation';

  @override
  String get continueMigration => 'Continue migration';

  @override
  String get importedLocalProfiles => 'Imported local profiles';

  @override
  String get localProfile => 'Local profile';

  @override
  String get localProfilePassword => 'Local profile password';

  @override
  String localProfileUnlockedCountResumableMigration(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count resumable migrations',
      one: '1 resumable migration',
    );
    return 'Local profile unlocked · $_temp0';
  }

  @override
  String localProfileSubstring(String substring) {
    return 'Local profile · $substring';
  }

  @override
  String get lock => 'Lock';

  @override
  String get migrateLocalProfiles => 'Migrate local profiles';

  @override
  String get migrationCompleted => 'Migration completed';

  @override
  String get migrationNeedsRecovery => 'Migration needs recovery';

  @override
  String get migrationStoppedLocalSourceKept =>
      'Migration stopped · local source kept';

  @override
  String get moveLocalEncryptedRecordsToA =>
      'Move local encrypted records to a new sync Vault';

  @override
  String get newSyncVaultName => 'New sync Vault name';

  @override
  String get noLocalOnlyProfileExistsIn =>
      'No local-only profile exists in this browser yet. Create one from the Local profile workspace, add the records you want, then return here.';

  @override
  String get preflightAndMigrate => 'Preflight and migrate';

  @override
  String get startANewMigration => 'Start a new migration';

  @override
  String get stopAndKeepBoth => 'Stop and keep both';

  @override
  String get stopAndKeepLocalData => 'Stop and keep local data';

  @override
  String get stopMigrationAndKeepLocalData =>
      'Stop migration and keep local data?';

  @override
  String get theClientDecryptsAndValidatesEvery =>
      'The client decrypts and validates every source record, then encrypts it again for the approved server device. The server receives only signed ciphertext. Existing local records remain unchanged, and the local profile is write-frozen until the destination confirms every record.';

  @override
  String get theLocalSourceWillBecomeWritable =>
      'The local source will become writable again and its records will remain unchanged. The destination Vault, committed records, and queued operations will not be deleted or withdrawn; the destination may contain a partial copy.';

  @override
  String get unlockALocalOnlyProfile => 'Unlock a local-only profile';

  @override
  String get unlockAndValidate => 'Unlock and validate';

  @override
  String stagedcountTotalcountEncryptedRecordsStaged(
    int stagedCount,
    int totalCount,
  ) {
    return '$stagedCount / $totalCount encrypted records staged';
  }

  @override
  String stageditemcountItemcountEncryptedRecordsStagedTarget(
    int stagedItemCount,
    int itemCount,
    String substring,
  ) {
    return '$stagedItemCount / $itemCount encrypted records staged · target $substring…';
  }

  @override
  String get theSyncServiceIdentityIsntVerified =>
      'The sync service identity isn\'t verified yet. Sign in again and retry.';

  @override
  String countCount2EncryptedRecordsSafelyStaged(int count, int count2) {
    return '$count / $count2 encrypted records safely staged.';
  }

  @override
  String get destinationDataIsAlreadyStagedThis =>
      'Destination data is already staged; this migration can\'t be cancelled.';

  @override
  String get couldntStopTheMigrationTheSource =>
      'Couldn\'t stop the migration. The source data and staged ciphertext are kept; try again or continue the migration.';

  @override
  String get thisMigrationCantBeResumedSafely =>
      'This migration can\'t be resumed safely. The source data and staged ciphertext are unchanged; check the current device and server state.';

  @override
  String get couldntUnlockOrVerifyThisLocal =>
      'Couldn\'t unlock or verify this local profile. Check the password and local storage, then try again.';

  @override
  String get couldntReadTheLocalProfileList =>
      'Couldn\'t read the local profile list. Close this page and try again.';

  @override
  String get theStagedDestinationCiphertextHasAn =>
      'The staged destination ciphertext has an invalid format.';

  @override
  String get noVaultCreationRequestWasSent =>
      'No Vault creation request was sent; the preparation journal was safely cancelled.';

  @override
  String get localDataWasFullyPreflightedAnd =>
      'Local data was fully preflighted and frozen; preparing the new sync Vault…';

  @override
  String get localSourceSnapshotVerifiedResumingThe =>
      'Local source snapshot verified; resuming the same sync destination…';

  @override
  String get theLocalProfileIsLocked => 'The local profile is locked.';

  @override
  String get encryptingAndStagingRecordsWithThe =>
      'Encrypting and staging records with the destination Vault key…';

  @override
  String get syncingEncryptedRecordsToTheNew =>
      'Syncing encrypted records to the new Vault…';

  @override
  String get confirmingTheSameDestinationVaultAnd =>
      'Confirming the same destination Vault and checking previously staged records…';

  @override
  String get reVerifyingTheLocalSourceSnapshot =>
      'Re-verifying the local source snapshot and staged encrypted data…';

  @override
  String get preflightingAllLocalRecordsWritesTo =>
      'Preflighting all local records; writes to the source profile are temporarily blocked…';

  @override
  String get verifyingTheLocalProfileAndChecking =>
      'Verifying the local profile and checking the recovery journal…';

  @override
  String get thisMigrationCantBeCancelledSafely =>
      'This migration can\'t be cancelled safely. Continue recovering the original destination; the source data stays frozen.';

  @override
  String get theDestinationVaultsSyncPreferencesConflict =>
      'The destination Vault\'s sync preferences conflict; the migration isn\'t fully verified yet.';

  @override
  String get recordsAreSavedEncryptedInThe =>
      'Records are saved encrypted in the sync queue, but not all server confirmations have arrived. The source profile stays frozen; click \"Continue migration\" to retry safely.';

  @override
  String get migrationPreparationHasntSavedTheVault =>
      'Migration preparation hasn\'t saved the Vault creation data yet.';

  @override
  String get migrationCiphertextStagingIsIncomplete =>
      'Migration ciphertext staging is incomplete.';

  @override
  String get migrationStoppedTheLocalSourceData =>
      'Migration stopped. The local source data is intact and writable again; data committed or pending sync in the destination Vault is kept.';

  @override
  String get migrationCompleteTheServerConfirmedEvery =>
      'Migration complete. The server confirmed every record; the local profile still keeps the original data.';

  @override
  String get theMigrationJournalDoesntMatchThe =>
      'The migration journal doesn\'t match the currently verified local source snapshot.';

  @override
  String get theMigrationJournalContainsDuplicateOr =>
      'The migration journal contains duplicate or extra records.';

  @override
  String get migrationIncompleteTheSourceDataIs =>
      'Migration incomplete. The source data is unchanged; if a recovery journal was created, continue the same destination below.';

  @override
  String get theMigrationDestinationBelongsToA =>
      'The migration destination belongs to a different server instance.';

  @override
  String get accountPassword => 'Account password';

  @override
  String get accountSessionExpiredSignInAgain =>
      'Account session expired; sign in again';

  @override
  String get encryptedChangesAreUpToDate => 'Encrypted changes are up to date';

  @override
  String get encryptedSyncWillRetryWhenThe =>
      'Encrypted sync will retry when the connection returns';

  @override
  String get noVaultIsCurrentlyAvailable => 'No Vault is currently available';

  @override
  String get receiveEncryptedChangesNow => 'Receive encrypted changes now';

  @override
  String get receivingSignedEncryptedChanges =>
      'Receiving signed encrypted changes';

  @override
  String get signOut => 'Sign out';

  @override
  String get thisDeviceOrVaultAccessWas =>
      'This device or Vault access was revoked';

  @override
  String get unlockToVerifyTheLatestVault =>
      'Unlock to verify the latest Vault state';

  @override
  String get unlockWorkspace => 'Unlock workspace';

  @override
  String get workspaceLocked => 'Workspace locked';

  @override
  String get yourAccountStaysSignedInWhile =>
      'Your account stays signed in. While locked, this device can receive and store signed ciphertext, but it cannot decrypt records or create or upload changes.';

  @override
  String get sshConsoleSupportReadingTextAnd =>
      'SSH / Console support reading text and input; SSH also supports standalone command execution and SFTP text file read/write. RDP / VNC support connections and tab management; screen recognition and mouse control aren\'t available yet.';

  @override
  String get onlyTheLast50ToolNames =>
      'Only the last 50 tool names and results are kept in memory; commands, file contents and tokens aren\'t recorded.';

  @override
  String get listensOn127001 =>
      'Listens on 127.0.0.1 only. A new token is generated each time it\'s enabled; authorization ends after locking, signing out or switching Vaults. Different windows can use different ports. Stopping MCP doesn\'t close sessions you\'ve opened.';

  @override
  String get stopAndRevokeToken => 'Stop and revoke token';

  @override
  String get allowExternalAiToPerformActions =>
      'Allow external AI to perform actions';

  @override
  String get actionsAllowed => 'Actions allowed';

  @override
  String get allowsConnectingClosingSessionsTerminalInput =>
      'Allows connecting/closing sessions, terminal input, running commands and writing files. Re-enable MCP after changing this.';

  @override
  String get readOnly => 'Read-only';

  @override
  String get readOnlyModeCanStillRead =>
      'Read-only mode can still read terminal output and file contents, which may contain sensitive information. Only give the connection configuration to AI you trust. Saved passwords, private keys and unlock keys are never provided as MCP fields.';

  @override
  String get availableTools => 'Available tools';

  @override
  String get enableMcp => 'Enable MCP';

  @override
  String get copyConnectionConfigIncludesToken =>
      'Copy connection config (includes token)';

  @override
  String get externalAiAccess => 'External AI access';

  @override
  String get failed => 'Failed';

  @override
  String get done => 'Done';

  @override
  String get off => 'Off';

  @override
  String get copiedIncludesAccessToken => 'Copied (includes access token)';

  @override
  String get couldntStartMcpMakeSureThe =>
      'Couldn\'t start MCP. Make sure the workspace is unlocked and the port isn\'t used by another window.';

  @override
  String get couldntCopyTheConfigurationCheckClipboard =>
      'Couldn\'t copy the configuration. Check clipboard permissions.';

  @override
  String get noCallsYet => 'No calls yet';

  @override
  String get recentCalls => 'Recent calls';

  @override
  String get localListeningPort => 'Local listening port';

  @override
  String get starting => 'Starting…';

  @override
  String get theBrowserAndMobileAppsDont =>
      'The browser and mobile apps don\'t provide a local MCP listener. Enable it after opening the workspace in the Windows, Linux or macOS desktop client.';

  @override
  String get portMustBe102465535 => 'Port must be 1024–65535.';

  @override
  String runningValuevalue(String valueValue) {
    return 'Running · $valueValue';
  }

  @override
  String get letExternalAiUseTheHosts =>
      'Let external AI use the hosts, sessions, terminals and remote files in the current workspace through MCP. No model API needs to be configured in Atermius.';

  @override
  String get rdpRemoteDesktop => 'RDP remote desktop';

  @override
  String get sshHost => 'SSH host';

  @override
  String get vncRemoteDesktop => 'VNC remote desktop';

  @override
  String get newSession => 'New session';

  @override
  String get unableToOpenANewWindow => 'Unable to open a new window.';

  @override
  String get couldntOpenANewWindow => 'Couldn\'t open a new window.';

  @override
  String get newWindowsRequireADesktop => 'New windows require a desktop.';

  @override
  String get fileWindowsRequireADesktop => 'File windows require a desktop.';

  @override
  String get independentFileWindowsRequireADesktop =>
      'Independent file windows require a desktop.';

  @override
  String get chooseSshConfigFile => 'Choose SSH config file';

  @override
  String get confirmImport => 'Confirm import';

  @override
  String createCountEncryptedHostRecordS(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count encrypted Host records',
      one: '1 encrypted Host record',
    );
    return 'Create $_temp0. Existing Hosts will not be changed. No SSH connection will be opened.';
  }

  @override
  String get importHosts => 'Import Hosts';

  @override
  String get importOpensshConfig => 'Import OpenSSH config';

  @override
  String get importTheseHosts => 'Import these Hosts?';

  @override
  String importCountHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Hosts',
      one: '1 Host',
    );
    return 'Import $_temp0';
  }

  @override
  String lineLineMessage(int line, String message) {
    return 'Line $line · $message';
  }

  @override
  String get noConcreteHostAliasesWereFound =>
      'No concrete Host aliases were found.';

  @override
  String get proxyjumpReferencesCouldNotBeSaved =>
      'ProxyJump references could not be saved in a safe order.';

  @override
  String get reviewBlockedNoRecordsCanBe =>
      'Review blocked: no records can be imported from this file.';

  @override
  String get reviewLiteralHostAliasesHostnameUser =>
      'Review literal Host aliases, HostName, User, Port, and a single ProxyJump alias before saving. Include, Match, wildcard patterns, ProxyCommand, and LocalCommand are blocked. IdentityFile paths are never opened.';

  @override
  String get theActiveVaultChangedDuringImport =>
      'The active Vault changed during import; remaining Hosts were not saved.';

  @override
  String get theActiveVaultIsReadOnly =>
      'The active Vault is read-only; no Hosts were imported.';

  @override
  String get theConfigFileCouldNotBe => 'The config file could not be read.';

  @override
  String get theSelectedConfigCouldNotBe =>
      'The selected config could not be read.';

  @override
  String get theSelectedConfigExceedsThe1 =>
      'The selected config exceeds the 1 MiB limit.';

  @override
  String get thisProxyjumpChainContainsACycle =>
      'This ProxyJump chain contains a cycle; no Host in the affected route will be imported.';

  @override
  String thisProxyjumpChainExceedsTheMaxjumphosthops(int maxJumpHostHops) {
    return 'This ProxyJump chain exceeds the $maxJumpHostHops-hop limit.';
  }

  @override
  String get thisProxyjumpChainPointsToA =>
      'This ProxyJump chain points to a missing saved Host.';

  @override
  String valuevalueAdditionalFindingsAreHidden(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: '$valueValue additional findings are hidden.',
      one: '1 additional finding is hidden.',
    );
    return '$_temp0';
  }

  @override
  String filenameActions(String filename) {
    return '$filename actions';
  }

  @override
  String get uploadFile => 'Upload file';

  @override
  String get parentFolder => 'Parent folder';

  @override
  String get download => 'Download';

  @override
  String get modified => 'Modified';

  @override
  String get create => 'Create';

  @override
  String deleteFilenameFoldersMustBeEmpty(String filename) {
    return 'Delete \"$filename\"? Folders must be empty. This can\'t be undone.';
  }

  @override
  String get size => 'Size';

  @override
  String get fileActions => 'File actions';

  @override
  String get newFolder => 'New folder';

  @override
  String get thisFolderIsEmpty => 'This folder is empty';

  @override
  String get confirmDeletion => 'Confirm deletion';

  @override
  String get editText => 'Edit text';

  @override
  String get remotePath => 'Remote path';

  @override
  String get closePane => 'Close pane';

  @override
  String get unsplit => 'Unsplit';

  @override
  String get invalidLayoutSession => 'Invalid layout session.';

  @override
  String get layoutIsNestedTooDeeply => 'Layout is nested too deeply.';

  @override
  String get dropToSplit => 'Drop to split';

  @override
  String paneActionsLabel(String label) {
    return 'Pane actions · $label';
  }

  @override
  String get paneActionsTapTheWhiteHandle =>
      'Pane actions: tap the white handle at the top or press Alt+Shift+P';

  @override
  String get paneActionsHoverNearTheTop =>
      'Pane actions: hover near the top, touch the top, or press Alt+Shift+P';

  @override
  String get settingsCategories => 'Settings categories';

  @override
  String get backToConflict => 'Back to conflict';

  @override
  String get compare => 'Compare';

  @override
  String get compareRemoteFileVersions => 'Compare remote file versions';

  @override
  String get editRemoteTextFile => 'Edit remote text file';

  @override
  String get fileName => 'File name';

  @override
  String get latestRemote => 'Latest remote';

  @override
  String get overwriteRemoteFile => 'Overwrite remote file';

  @override
  String get remoteFileChanged => 'Remote file changed';

  @override
  String get remoteFileContents => 'Remote file contents';

  @override
  String get saveAs => 'Save as';

  @override
  String get saveRemoteFileAs => 'Save remote file as';

  @override
  String get theRemoteFileChangedAfterYou =>
      'The remote file changed after you opened it. Your draft has not been saved. Compare versions, save a new copy, or explicitly overwrite the latest version.';

  @override
  String get utf8TextUpTo10 =>
      'UTF-8 text up to 10 MiB. The draft stays in memory and is not synchronized. SFTP cannot guarantee compare-and-swap or no-follow open against a concurrent remote path change; avoid editing files in shared writable directories.';

  @override
  String get yourDraft => 'Your draft';

  @override
  String get advanced => 'Advanced';

  @override
  String get allowNetworkExposure => 'Allow network exposure';

  @override
  String get anotherProfileOfThisHostAlready =>
      'Another profile of this Host already uses this listener address and port.';

  @override
  String get connectThisHostOverSshTo =>
      'Connect this Host over SSH to start forwards.';

  @override
  String get couldNotRemoveThisForwardingProfile2 =>
      'Could not remove this forwarding profile.';

  @override
  String get destinationReachedFromTheSshServer =>
      'Destination reached from the SSH server';

  @override
  String get destinationReachedFromThisDevice =>
      'Destination reached from this device';

  @override
  String get dynamicSocksD => 'Dynamic SOCKS (-D)';

  @override
  String dynamicSocksDBind(String bind) {
    return 'Dynamic SOCKS (-D) · $bind';
  }

  @override
  String get dynamicForwardingIsASocks44a =>
      'Dynamic forwarding is a SOCKS4/4a/5 CONNECT proxy without SOCKS authentication. Anyone who can reach its listener can use your SSH connection.';

  @override
  String get expose => 'Expose';

  @override
  String get exposeThisForwardBeyondLoopback =>
      'Expose this forward beyond loopback?';

  @override
  String lastConnectionLastconnectionerror(Object lastConnectionError) {
    return 'Last connection: $lastConnectionError';
  }

  @override
  String get localL => 'Local (-L)';

  @override
  String localLBindDestinationViaSsh(String bind, String destination) {
    return 'Local (-L) · $bind → $destination via SSH';
  }

  @override
  String get loopbackOrAnIpAddress => 'Loopback or an IP address';

  @override
  String get permitANonLoopbackListenerFor =>
      'Permit a non-loopback listener (for example 0.0.0.0) or, for remote forwards, a device-side destination on your network. You will be asked to confirm before saving and before each start.';

  @override
  String get reachableBeyondLoopback => 'Reachable beyond loopback';

  @override
  String get remoteR => 'Remote (-R)';

  @override
  String remoteRSshServerBindThis(String bind, String destination) {
    return 'Remote (-R) · SSH server $bind → this device $destination';
  }

  @override
  String get socks44a5ConnectWithoutSocks =>
      'SOCKS4/4a/5 CONNECT without SOCKS authentication. Targets are resolved by the SSH server.';

  @override
  String sshPortForwardingHostname(String hostName) {
    return 'SSH port forwarding · $hostName';
  }

  @override
  String get sshServerListenerAddress => 'SSH server listener address';

  @override
  String get theSshServerGatewayportsSettingMay2 =>
      'The SSH server GatewayPorts setting may widen a loopback bind request. Verify the server configuration before using remote forwarding.';

  @override
  String get thisHostIsNoLongerAvailable => 'This Host is no longer available.';

  @override
  String get thisHostIsNotSavedIn =>
      'This Host is not saved in the current profile or Vault (or was removed). Save the Host to keep forwarding profiles; running forwards below can still be stopped.';

  @override
  String sshportforwardprofiledescriptionNoLongerSavedForThis(
    String sshPortForwardProfileDescription,
  ) {
    return '$sshPortForwardProfileDescription\nNo longer saved for this Host, but still running on this connection.';
  }

  @override
  String whatOnlyContinueOnANetwork(String what) {
    return '$what Only continue on a network you trust.';
  }

  @override
  String get downArrow => 'Down arrow';

  @override
  String get leftArrow => 'Left arrow';

  @override
  String get lockAltModifier => 'Lock Alt modifier';

  @override
  String get lockControlModifier => 'Lock Control modifier';

  @override
  String get moreTerminalKeys => 'More terminal keys';

  @override
  String get pasteClipboard => 'Paste clipboard';

  @override
  String get releaseControlAndAlt => 'Release Control and Alt';

  @override
  String get rightArrow => 'Right arrow';

  @override
  String get upArrow => 'Up arrow';

  @override
  String get nextMatch => 'Next match';

  @override
  String get previousMatch => 'Previous match';

  @override
  String get searchTerminalScrollback => 'Search terminal scrollback';

  @override
  String get closeSidebar => 'Close sidebar';

  @override
  String get delete => 'Delete';

  @override
  String get refreshQuickCommands => 'Refresh quick commands';

  @override
  String get saveEncryptedAsSnippets => 'Save encrypted as Snippets';

  @override
  String get singleLineCommand => 'Single-line command';

  @override
  String get insertIntoTerminal => 'Insert into terminal';

  @override
  String get quickCommands => 'Quick commands';

  @override
  String get quickCommandActions => 'Quick command actions';

  @override
  String get searchTermsAreRecordedWhenYou =>
      'Search terms are recorded when you press Enter or close search';

  @override
  String get search => 'Search';

  @override
  String get search2 => 'Search…';

  @override
  String get searchHistory => 'Search history';

  @override
  String get searchCurrentTerminalOutput => 'Search current terminal output';

  @override
  String get theActionDidntCompleteRefreshAnd =>
      'The action didn\'t complete. Refresh and try again.';

  @override
  String get cantInsertSelectASessionThat =>
      'Can\'t insert: select a session that is still connected, and the command must be a single line.';

  @override
  String get couldntReadQuickCommandsRefreshAnd =>
      'Couldn\'t read quick commands. Refresh and try again.';

  @override
  String get showsCommandsCompletedOnTheCurrent =>
      'Shows commands completed on the current host. Click to insert; nothing runs automatically.';

  @override
  String get noMatchingEntries => 'No matching entries';

  @override
  String get addQuickCommand => 'Add quick command';

  @override
  String get clear => 'Clear';

  @override
  String get clearLocalHistory => 'Clear local history';

  @override
  String get clickToInsertPressEnterTo =>
      'Click to insert, press Enter to run. Shows single-line Bash commands without parameters.';

  @override
  String get removeSearchTerm => 'Remove search term';

  @override
  String get filterInputHistory => 'Filter input history';

  @override
  String get filterByNameOrCommand => 'Filter by name or command';

  @override
  String get terminalTools => 'Terminal tools';

  @override
  String get edit => 'Edit';

  @override
  String get editQuickCommand => 'Edit quick command';

  @override
  String get recordingSettings => 'Recording settings';

  @override
  String get enterANameAndASingle =>
      'Enter a name and a single-line command without control characters.';

  @override
  String get inputHistory => 'Input history';

  @override
  String get cancelTransfer => 'Cancel transfer';

  @override
  String get chooseLocalFile => 'Choose local file';

  @override
  String get couldNotOpenAStreamingFile =>
      'Could not open a streaming file source.';

  @override
  String get downloadFile => 'Download file';

  @override
  String get downloadingWithSftpCompatibilityModeUp =>
      'Downloading with SFTP compatibility mode (up to 16 MiB)…';

  @override
  String get fileExceeds1GibTransferLimit =>
      'File exceeds 1 GiB transfer limit.';

  @override
  String get mobileDownloadsUpTo16Mib =>
      'Mobile downloads up to 16 MiB. The save picker opens after the complete file is verified.';

  @override
  String get preparingTransfer => 'Preparing transfer…';

  @override
  String get remoteFilePath => 'Remote file path';

  @override
  String get sftpCompatibilityDownloadsUpTo16 =>
      'SFTP compatibility downloads up to 16 MiB. SCP requires a streaming save destination on this platform.';

  @override
  String get singleFilesUpTo1Gib =>
      'Single files up to 1 GiB. Existing destinations are never replaced. SFTP files are visible while uploading.';

  @override
  String get streamingFileSavesAreUnavailableOn =>
      'Streaming file saves are unavailable on this platform.';

  @override
  String get streamingTransferIsUnavailableOnThis =>
      'Streaming transfer is unavailable on this platform.';

  @override
  String get theSelectedProviderReturnedAnUnsafe =>
      'The selected provider returned an unsafe file name.';

  @override
  String get thisFilePickerDoesNotProvide =>
      'This file picker does not provide a streaming source.';

  @override
  String get transferCancelled => 'Transfer cancelled.';

  @override
  String get transferFailedCheckThePathPermissions =>
      'Transfer failed. Check the path, permissions and whether the destination exists.';

  @override
  String get uploadFile2 => 'Upload file';

  @override
  String get closeWindow => 'Close window';

  @override
  String get maximize => 'Maximize';

  @override
  String get minimize => 'Minimize';

  @override
  String get closeWindow2 => 'Close window';

  @override
  String get maximize2 => 'Maximize';

  @override
  String get minimize2 => 'Minimize';

  @override
  String get restore2 => 'Restore';

  @override
  String get save2 => 'Save';

  @override
  String get saveWindowSet => 'Save window set';

  @override
  String get thisWindowHasSessionsThatCant =>
      'This window has sessions that can\'t be saved. Close them and try again.';

  @override
  String get thisWindowHasNoSessionsTo =>
      'This window has no sessions to save.';

  @override
  String get openWindowSet => 'Open window set';

  @override
  String get couldntDeleteTheWindowSetUnlock =>
      'Couldn\'t delete the window set. Unlock again or sync, then try again.';

  @override
  String get couldntReadWindowSetsUnlockAgain =>
      'Couldn\'t read window sets. Unlock again or sync, then try again.';

  @override
  String get thereAreNoReadySessionsTo =>
      'There are no ready sessions to save.';

  @override
  String get windowSets => 'Window sets';

  @override
  String get setName => 'Set name';

  @override
  String get sshKey => 'SSH key';

  @override
  String get close2 => 'Close';

  @override
  String get password2 => 'Password';

  @override
  String get theActionDidntCompleteTryAgain =>
      'The action didn\'t complete. Try again.';

  @override
  String get more => 'More';

  @override
  String get directConnection2 => 'Direct connection';

  @override
  String get connectionProperties => 'Connection properties';

  @override
  String get viaJumpHost => 'Via jump host';

  @override
  String get theAppOpensInTheCurrent =>
      'The app opens in the current mode next time. Switching modes closes current connections; saved data is kept.';

  @override
  String get cloudSyncMode => 'Cloud sync mode';

  @override
  String get switchToCloudMode => 'Switch to cloud mode';

  @override
  String get switchToLocalMode => 'Switch to local mode';

  @override
  String get workspaceMode => 'Workspace mode';

  @override
  String get couldntSwitchTheWorkspaceModeCheck =>
      'Couldn\'t switch the workspace mode. Check local storage and try again.';

  @override
  String get localMode => 'Local mode';

  @override
  String closeTitle(String title) {
    return 'Close $title';
  }

  @override
  String get newWindowCtrlShiftN => 'New window (Ctrl+Shift+N)';

  @override
  String countCount2Connected(int count, int count2) {
    return '$count/$count2 connected';
  }

  @override
  String get splitTopBottom => 'Split top/bottom';

  @override
  String get hostMenuClickToOpen => 'Host menu · click to open';

  @override
  String get closeOtherTabs => 'Close other tabs';

  @override
  String get closeTab => 'Close tab';

  @override
  String get closeThisSplitGroup => 'Close this split group';

  @override
  String get unsplitCurrentPane => 'Unsplit current pane';

  @override
  String get duplicateTab => 'Duplicate tab';

  @override
  String get splitLeftRight => 'Split left/right';

  @override
  String get connected => 'Connected';

  @override
  String get searchHostsOrQuickConnect => 'Search hosts or quick connect';

  @override
  String get notConnected => 'Not connected';

  @override
  String get moveToNewWindow => 'Move to new window…';

  @override
  String get terminalSidebar => 'Terminal sidebar';

  @override
  String get desktopRdpEngineFeatureUnavailable =>
      'Not available in this RDP engine build';

  @override
  String get desktopChooseAbsoluteLocalFolder =>
      'Choose an absolute local folder';

  @override
  String get desktopRdpMultimonResolutionHelp =>
      'Ignored while \"Use all local monitors\" is on: each monitor keeps its own size.';

  @override
  String get desktopRdpAutomaticResolutionHelp =>
      'Automatic follows the window through RDP display control; fixed sizes are requested at connect.';

  @override
  String get desktopUseAllLocalMonitors => 'Use all local monitors';

  @override
  String get desktopClipboardText => 'Clipboard text';

  @override
  String get desktopClipboardFiles => 'Clipboard files';

  @override
  String get desktopMicrophone => 'Microphone';

  @override
  String get desktopSmartCards => 'Smart cards';

  @override
  String get desktopCameras => 'Cameras';

  @override
  String get desktopVncResizeHelp =>
      'Resize requests need a server with ExtendedDesktopSize (for example TigerVNC or x11vnc with -xrandr). Other servers keep their size and the view scales locally.';

  @override
  String get desktopAutomaticFitWindow => 'Automatic (fit window)';

  @override
  String desktopResolutionSideBounds(int minSide, int maxSide) {
    return 'Resolution must be between $minSide and $maxSide pixels per side';
  }

  @override
  String desktopResolutionPixelLimit(int megapixels) {
    return 'Resolution exceeds $megapixels megapixels';
  }

  @override
  String get inventoryTooLarge =>
      'The inventory exceeds the 1 MiB import limit.';

  @override
  String get inventoryTooManyLines =>
      'The inventory has too many lines to review safely.';

  @override
  String get inventoryLineTooLong =>
      'An inventory line is too long to review safely.';

  @override
  String get inventoryControlCharacter =>
      'Control characters are not allowed in inventory files.';

  @override
  String get inventoryUnsupportedFormat =>
      'This inventory format is not supported.';

  @override
  String get inventoryParseError =>
      'The inventory syntax could not be parsed safely.';

  @override
  String get inventoryUnsupportedConstruct =>
      'The inventory contains an unsupported construct.';

  @override
  String get inventoryDynamicUnsupported =>
      'Dynamic inventory and plugin configuration are not supported.';

  @override
  String get inventoryInvalidGroup =>
      'A group declaration is malformed or unsupported.';

  @override
  String get inventoryInvalidHost =>
      'A host declaration is malformed or unsupported.';

  @override
  String get inventoryInvalidVariable =>
      'An allowlisted connection field has an invalid value.';

  @override
  String get inventoryUnsupportedConnection =>
      'Only static SSH inventory hosts can be imported.';

  @override
  String get inventoryIgnoredVariable =>
      'An unsupported inventory variable was ignored and will not be imported.';

  @override
  String get inventoryConflictingVariable =>
      'Conflicting inventory values make this host ambiguous.';

  @override
  String get inventoryDuplicateVariable =>
      'A connection field is repeated and makes this host ambiguous.';

  @override
  String get inventoryGroupCycle => 'Group inheritance contains a cycle.';

  @override
  String get inventoryLimitExceeded =>
      'The inventory exceeds a safe parsing limit.';

  @override
  String get inventoryEmpty => 'No static hosts were found in this inventory.';

  @override
  String get inventoryBlockedSource =>
      'A blocked inventory cannot change saved source state.';

  @override
  String get inventoryEmptySource =>
      'An empty inventory cannot mark saved Hosts missing.';

  @override
  String get inventoryPartialSource =>
      'A partial or ambiguous inventory cannot mark saved Hosts missing.';

  @override
  String get inventoryBlockedPlan =>
      'The inventory has a blocking finding; no change is planned.';

  @override
  String get inventoryBlockedEntry =>
      'This entry has a blocking finding and will not be changed.';

  @override
  String get inventoryDuplicateIdentity =>
      'This source contains an ambiguous duplicate Host identity.';

  @override
  String get inventoryUsernameRequired =>
      'A username is required to save a Host.';

  @override
  String get inventoryMultipleSaved =>
      'More than one saved Host has this source identity.';

  @override
  String get inventoryKeepOtherSource =>
      'Already saved. The existing Host will be kept unchanged. It belongs to another source or has no source identity.';

  @override
  String get inventoryRevisionUnavailable =>
      'The saved Host revision is unavailable. Refresh the Hosts page and review again.';

  @override
  String get inventoryTagLimit =>
      'The merged Host would exceed the 128-tag storage limit. Remove tags or groups and review the inventory again.';

  @override
  String get inventoryRestoreActive =>
      'This Host will be restored as active in its source.';

  @override
  String get inventoryMissingRevision =>
      'A saved Host revision is unavailable; the missing entry was not marked stale.';

  @override
  String get inventoryAbsentHost =>
      'This saved Host is absent from the complete inventory.';

  @override
  String get sshImportLineTooLong => 'This line is too long to review.';

  @override
  String get sshImportControlCharacter =>
      'Control characters are not allowed in an SSH config file.';

  @override
  String get sshImportUnterminatedQuote =>
      'Unterminated quote or escape; fix this line before import.';

  @override
  String get sshImportAliasRequired => 'A Host line needs a literal alias.';

  @override
  String get sshImportUnsupportedPattern =>
      'Wildcard, negated, or malformed Host patterns are unsupported; use concrete aliases.';

  @override
  String get sshImportHostLimit =>
      'The config file exceeds the 256 Host import limit.';

  @override
  String get sshImportInclude =>
      'Include files are not opened. Flatten the config and review it before import.';

  @override
  String get sshImportMatch =>
      'Match blocks are not evaluated. Convert this file to literal Host blocks before import.';

  @override
  String get sshImportGlobalCommand =>
      'Command directives are never executed; remove this global directive before import.';

  @override
  String get sshImportGlobalIdentity =>
      'IdentityFile needs one value; no file is opened during import.';

  @override
  String get sshImportUnknownDirective =>
      'This directive is not imported. Review or remove it before connecting.';

  @override
  String get sshImportGlobalValueCount =>
      'This global directive needs exactly one value.';

  @override
  String get sshImportGlobalInvalidValue =>
      'This global value is invalid or unsupported.';

  @override
  String get importStatusCreate => 'create';

  @override
  String get importStatusUpdate => 'update';

  @override
  String get importStatusUnchanged => 'unchanged';

  @override
  String get importStatusMissing => 'missing';

  @override
  String get importStatusSkipped => 'skipped';

  @override
  String get importStatusBlocked => 'blocked';

  @override
  String get sshImportBlockedFile =>
      'Blocked because the file contains unsupported structure.';

  @override
  String get sshImportAmbiguousName =>
      'More than one saved Host has this name; nothing will be overwritten.';

  @override
  String get sshImportBlockedHost =>
      'This Host has a blocking finding and will not be imported.';

  @override
  String get sshImportNotImportable => 'This Host is not importable.';

  @override
  String get importUsernameMissing => 'username missing';

  @override
  String importPlannedEndpoint(String endpoint) {
    return 'Planned: $endpoint';
  }

  @override
  String importSavedEndpoint(String endpoint) {
    return 'Saved: $endpoint';
  }

  @override
  String importHostTags(String tags) {
    return 'Host tags to save: $tags';
  }

  @override
  String importSshEndpointLine(
    int line,
    String username,
    String address,
    int port,
  ) {
    return 'Line $line · $username@$address:$port';
  }

  @override
  String importProxyJumpLine(String alias, int line) {
    return 'ProxyJump $alias · line $line';
  }

  @override
  String sshImportSavedName(String name) {
    return 'Already saved as “$name”; it will not be overwritten.';
  }

  @override
  String sshImportJumpAmbiguous(int line) {
    return 'ProxyJump at line $line is ambiguous because more than one saved Host has that name.';
  }

  @override
  String sshImportJumpMissing(int line) {
    return 'ProxyJump at line $line does not resolve to one imported or saved Host.';
  }

  @override
  String sshImportJumpSelf(int line) {
    return 'ProxyJump at line $line points to the Host itself.';
  }

  @override
  String sshImportPreviewCounts(int count) {
    return 'Preview: hosts to create: $count; conflicts and blocked entries will be skipped.';
  }

  @override
  String inventoryPreviewCounts(
    int created,
    int updated,
    int unchanged,
    int missing,
  ) {
    return 'Preview: hosts to create: $created; update: $updated; unchanged: $unchanged; missing: $missing.';
  }

  @override
  String get keybarPaste => 'Paste';

  @override
  String get keybarReset => 'Reset';

  @override
  String get terminalSearchQueryTooLong => 'Query too long';

  @override
  String get terminalSearchSearching => 'Searching…';

  @override
  String terminalSearchMatchCount(int total, int position) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$position of $total matches',
      one: '$position of $total match',
      zero: '0 matches',
    );
    return '$_temp0';
  }

  @override
  String terminalSearchLimitedCount(String countLabel) {
    return '$countLabel · results limited';
  }

  @override
  String get r7UiPaletteGalleryTitle => 'Color schemes';

  @override
  String get r7UiPaletteGalleryDescription =>
      'Applies to every terminal on this device, including local, cloud and separate terminal windows. Stored only on this device; the saved terminal theme is not changed.';

  @override
  String r7UiPaletteFollowSynced(String name) {
    return 'Saved theme ($name)';
  }

  @override
  String get r7UiPaletteSearchHint => 'Search color schemes';

  @override
  String get r7UiPaletteFilterAll => 'All';

  @override
  String get r7UiPaletteFilterDark => 'Dark';

  @override
  String get r7UiPaletteFilterLight => 'Light';

  @override
  String get r7UiPaletteNoMatches => 'No color schemes match.';

  @override
  String r7UiPaletteActiveOverride(String name) {
    return 'Terminals on this device use $name.';
  }

  @override
  String get r7UiPaletteFollowingSynced =>
      'Terminals on this device follow the saved terminal theme.';

  @override
  String get r7UiPaletteSaveFailed =>
      'Couldn\'t save the color scheme on this device. It applies until the app is closed.';

  @override
  String r7UiShortcutRecordTooltip(String action) {
    return 'Record a new shortcut for $action';
  }

  @override
  String get r7UiShortcutRecording => 'Press a key combination… Esc cancels';

  @override
  String r7UiShortcutReset(String action) {
    return 'Reset $action to its default';
  }

  @override
  String get r7UiShortcutDuplicate => 'Also used by another action';

  @override
  String get r7UiShortcutInvalid => 'Unsupported or reserved combination';

  @override
  String get r7NavLogTranscriptNone =>
      'No transcript was recorded for this session.';

  @override
  String get r7NavCertAnyPrincipal => 'any principal';

  @override
  String get r7NavKindKeyWithCertificate => 'Private key + certificate';

  @override
  String get r7NavHomeNavigation => 'Home navigation';

  @override
  String get r7NavKeychainSubtitle =>
      'SSH keys, user certificates and passwords shared by hosts and groups. Hosts can still keep their own sign-in.';

  @override
  String get r7NavAdd => 'Add';

  @override
  String get r7NavImportCertificateFile => 'Import certificate file';

  @override
  String get r7NavLogs => 'Logs';

  @override
  String get r7NavLogHost => 'Host';

  @override
  String r7NavUsedBy(int count, String names) {
    return 'Used by $count: $names';
  }

  @override
  String get r7NavLogTranscriptLiveNotRecorded =>
      'Recording was off when this session started.';

  @override
  String get r7NavLogTranscript => 'Output transcript';

  @override
  String get r7NavCertUnsupported =>
      'This certificate algorithm is not supported (DSA and security-key certificates are not).';

  @override
  String get r7NavLogSearchHint => 'Search host or address';

  @override
  String get r7NavKeychainSearchHint =>
      'Search name, user, fingerprint or host';

  @override
  String get r7NavImportExport => 'Import / Export';

  @override
  String get r7NavLogProtocol => 'Protocol';

  @override
  String get r7NavLogRecordTranscripts => 'Record terminal output transcripts';

  @override
  String get r7NavLogFailureCredential =>
      'sign-in details missing or unreadable';

  @override
  String get r7NavLogFailureNetwork => 'network or handshake error';

  @override
  String get r7NavLogNoMatches =>
      'Nothing matches the current search or filter.';

  @override
  String get r7NavLogCopyTranscript => 'Copy transcript';

  @override
  String get r7NavFilterCertificates => 'Certificates';

  @override
  String get r7NavLogStatusConnecting => 'Connecting';

  @override
  String get r7NavSignInKeychainNote =>
      'Uses the Keychain item (including any certificate). Edit it under Keychain; it stays shared with other hosts.';

  @override
  String r7NavCertCa(String fingerprint) {
    return 'CA $fingerprint';
  }

  @override
  String get r7NavDeleteBlocked =>
      'In use — change those hosts or groups first';

  @override
  String get r7NavLogFilterClosed => 'Closed';

  @override
  String get r7NavKeychain => 'Keychain';

  @override
  String get r7NavLogStorageMemory =>
      'Connection journal of this app session (kept in memory, cleared on lock). Separate from command history.';

  @override
  String get r7NavLogConnectedAt => 'Connected';

  @override
  String get r7NavCertificateOptional => 'OpenSSH user certificate (optional)';

  @override
  String get r7NavLogStorageFailed =>
      'Logs could not be saved or read; the list may be incomplete.';

  @override
  String get r7NavLogFilterAll => 'All';

  @override
  String get r7NavFilterKeys => 'Keys';

  @override
  String get r7NavKindPassword => 'Password';

  @override
  String get r7NavSnippets => 'Quick commands';

  @override
  String get r7NavLogStorageLocal =>
      'Connection journal of this device, encrypted in this local profile. Separate from command history.';

  @override
  String get r7NavLogDuration => 'Duration';

  @override
  String get r7NavImportKeyFile => 'Import key file';

  @override
  String get r7NavLogStatusFailed => 'Failed';

  @override
  String get r7NavCertificateHelper =>
      'Paste or import the *-cert.pub file signed by your CA. It must certify this private key; it is offered before the plain key.';

  @override
  String get r7NavCertKeyUnreadable =>
      'The private key cannot be read to check the certificate (check the key and passphrase).';

  @override
  String get r7NavLogRoute => 'Route';

  @override
  String r7NavSignInKeychainItem(String name) {
    return 'Keychain: $name';
  }

  @override
  String get r7NavLogFailureTimeout => 'timed out';

  @override
  String get r7NavLogStatusConnected => 'Connected';

  @override
  String get r7NavNotUsed => 'Not used by any host or group';

  @override
  String r7NavLogRecordPolicy(int count, int kib) {
    return 'Off by default. Applies to sessions opened after enabling. Saves what the terminal displays (including text the server echoes), never your keystrokes; hidden password prompts are not captured. Avoid displaying secrets while recording. Keeps the newest $count transcripts of up to $kib KiB.';
  }

  @override
  String get r7NavLogStatus => 'Status';

  @override
  String get r7NavLogFailureUnsupported => 'route not supported';

  @override
  String get r7NavLogFailureOther => 'other error';

  @override
  String get r7NavPortForwarding => 'Port forwarding';

  @override
  String get r7NavLogFailureHostKeyRejected => 'host key not approved';

  @override
  String get r7NavCertKeyMismatch =>
      'The certificate does not certify this private key.';

  @override
  String get r7NavLogStarted => 'Started';

  @override
  String get r7NavLogStatusEndedByRemote => 'Ended by server';

  @override
  String r7NavCertPrincipals(String principals) {
    return 'principals: $principals';
  }

  @override
  String get r7NavLogFailureCancelled => 'cancelled';

  @override
  String get r7NavCertInKeyField =>
      'A certificate was entered as the private key; put it in the certificate field.';

  @override
  String get r7NavSignInOwn => 'This host\'s own sign-in';

  @override
  String get r7NavCertValidForever => 'no expiry';

  @override
  String get r7NavImportFileNotText =>
      'The selected file is not a text key or certificate.';

  @override
  String get r7NavLogReason => 'Reason';

  @override
  String get r7NavFilterPasswords => 'Passwords';

  @override
  String get r7NavLogFilterActive => 'Active';

  @override
  String get r7NavLogEmpty =>
      'No sessions logged yet. Connections you open appear here.';

  @override
  String get r7NavLogStatusLost => 'Connection lost';

  @override
  String r7NavCertExpired(String date) {
    return 'expired $date';
  }

  @override
  String get r7NavLogStatusClosed => 'Closed';

  @override
  String get r7NavSignInSource => 'Sign in with';

  @override
  String get r7NavSignInInherited => 'Group default';

  @override
  String get r7NavLogFailureHostKeyChanged => 'host key changed';

  @override
  String get r7NavKindPrivateKey => 'Private key';

  @override
  String get r7NavLogFailureAuthentication => 'authentication rejected';

  @override
  String get r7NavImportFileTooLarge =>
      'The selected file is too large for a key or certificate.';

  @override
  String r7NavCertValidUntil(String date) {
    return 'valid until $date';
  }

  @override
  String get r7NavLogEnded => 'Ended';

  @override
  String get r7NavLogRouteJump => 'via jump host';

  @override
  String get r7NavKeychainEmpty => 'No keys, certificates or passwords yet.';

  @override
  String get r7NavLogClearTitle => 'Clear finished logs';

  @override
  String get r7NavCertMalformed => 'This is not a valid OpenSSH certificate.';

  @override
  String get r7NavNotAPrivateKey =>
      'That file is not a private key (a .pub or certificate belongs in the certificate field).';

  @override
  String get r7NavLogFilterFailed => 'Failed';

  @override
  String get r7NavLogClearBody =>
      'Delete all finished session logs and their transcripts from this device? Active sessions stay listed.';

  @override
  String r7NavCertNotYetValid(String date) {
    return 'not valid before $date';
  }

  @override
  String get r7NavLogEndpoint => 'Endpoint';

  @override
  String get r7NavCertNotUser =>
      'This is a host certificate; sign-in needs a user certificate.';

  @override
  String get r7NavLogTranscriptTruncated =>
      'Older output was dropped to stay within the size limit.';

  @override
  String get r7NavSignInInheritedNote =>
      'Uses the group\'s default sign-in. Choose this host\'s own sign-in to override it.';

  @override
  String r7ForwardSessionLabel(String host, int index) {
    return '$host #$index';
  }

  @override
  String get r7ForwardHostNotConnected => 'Not connected';

  @override
  String get r7ForwardNoRules =>
      'No forwarding rules yet. Choose “New rule” to add one to a host.';

  @override
  String get r7ForwardConnectAndStart => 'Connect and start';

  @override
  String get r7ForwardDuplicateTitle => 'Duplicate forwarding rule';

  @override
  String get r7ForwardDeleteTitle => 'Delete forwarding rule?';

  @override
  String get r7ForwardWaitForSession =>
      'Wait until the session finishes connecting';

  @override
  String get r7ForwardStartCancelled =>
      'Start cancelled. A connection that completes stays open as a normal session.';

  @override
  String get r7ForwardDuplicate => 'Duplicate';

  @override
  String get r7ForwardRuleChanged =>
      'The rule or host changed or was removed; it was not started.';

  @override
  String r7ForwardHostSessions(int count) {
    return '$count sessions';
  }

  @override
  String get r7ForwardMoreActions => 'More actions';

  @override
  String get r7ForwardScopeChanged =>
      'The vault or profile changed while connecting; the rule was not started.';

  @override
  String get r7ForwardChooseHost => 'Choose host';

  @override
  String get r7ForwardSearchHint => 'Search hosts or rules';

  @override
  String r7ForwardDeleteBody(String name) {
    return '“$name” is removed from this host. If it is running, it is stopped first.';
  }

  @override
  String get r7ForwardHostConnecting => 'Connecting…';

  @override
  String get r7ForwardNoMatches => 'Nothing matches the search.';

  @override
  String r7ForwardCopyName(String name) {
    return '$name copy';
  }

  @override
  String get r7ForwardTitle => 'SSH Forwarding';

  @override
  String get r7ForwardRuleConflict =>
      'This rule was changed elsewhere. Nothing was changed here; review the current rule and try again.';

  @override
  String get r7ForwardOpenSession => 'Open session';

  @override
  String get r7ForwardNotConnected =>
      'The connection was not completed; the rule was not started.';

  @override
  String r7ForwardSummary(int rules, int hosts, int running) {
    return '$rules rules on $hosts hosts · $running running';
  }

  @override
  String get r7ForwardRemovedHost =>
      'Host no longer saved — forwards still running';

  @override
  String get r7ForwardChooseSession => 'Choose a session to start rules on';

  @override
  String get r7ForwardHostConnected => 'Connected';

  @override
  String get r7ForwardNewRule => 'New rule';

  @override
  String r7ForwardOnSession(String session, String status) {
    return 'On $session: $status';
  }

  @override
  String get r7ForwardConnectingStart =>
      'Connecting… the rule starts after authentication';

  @override
  String get r7ForwardNoHosts => 'No SSH hosts yet. Add an SSH host first.';

  @override
  String get r7ForwardNoAutoStart =>
      'Rules start only when you start them, over the host\'s authenticated SSH session.';

  @override
  String get r7ForwardShowAllHosts => 'Show hosts without rules';

  @override
  String get r7ImportMenuAction => 'Termius import / export';

  @override
  String get r7ImportIssueCertificateNotStored =>
      'A certificate was found, but this build can’t store certificates; only the private key is imported.';

  @override
  String r7ImportIssueBundleIdentityExtra(String name) {
    return 'Only the first $name of each host is used; others were ignored.';
  }

  @override
  String r7ImportRowJump(String alias) {
    return 'Jump host: $alias';
  }

  @override
  String r7ImportIssueExportHostSkipped(String name) {
    return 'Host “$name” was skipped because a value can’t be written safely.';
  }

  @override
  String get r7ImportIssueBundleConfigMissing =>
      'The bundle contains no OpenSSH “config” file.';

  @override
  String get r7ImportExportSave => 'Save file';

  @override
  String get r7ImportConfirmTitle => 'Import from Termius?';

  @override
  String get r7ImportIssueSshJumpCycle =>
      'The ProxyJump chain loops or is too long.';

  @override
  String get r7ImportExportSecretWarning =>
      'The file will contain readable plaintext passwords or private keys. Anyone with the file can sign in to these hosts. Store it securely and delete it after use.';

  @override
  String r7ImportIssueExportFormulaRisk(int count) {
    return '$count rows contain values starting with =, +, -, @ or a tab. They are written unchanged; open the file only in Termius or a text editor, not a spreadsheet app.';
  }

  @override
  String get r7ImportIssueInvalidTag => 'Too many tags, or a tag is too long.';

  @override
  String get r7ImportDispositionCreate => 'Will be created';

  @override
  String get r7ImportIssueCsvUnterminatedQuote =>
      'A quoted field is never closed.';

  @override
  String r7ImportIssueExportSecretsOmitted(int count) {
    return '$count hosts have saved passwords that are not in this file.';
  }

  @override
  String r7ImportIssueExportKeysOmitted(int count) {
    return '$count hosts sign in with a private key that is not in this export. Use the OpenSSH bundle with key files turned on to include keys.';
  }

  @override
  String get r7ImportFileUnreadable => 'The file couldn’t be read.';

  @override
  String r7ImportIssueExportCertificatesOmitted(int count) {
    return '$count certificates were not exported because key files are turned off.';
  }

  @override
  String get r7ImportExportIntro =>
      'Export hosts as a Termius CSV template file or as an OpenSSH config. Secrets are left out unless you turn them on. The CSV can carry passwords only; use the OpenSSH bundle for key files.';

  @override
  String get r7ImportIssueCsvInvalid => 'The CSV structure is invalid.';

  @override
  String get r7ImportApplyNone => 'Import hosts';

  @override
  String r7ImportMoreRowsHidden(int count) {
    return '$count more rows are not shown; they are still included in the counts.';
  }

  @override
  String get r7ImportFailScopeChanged =>
      'The vault changed during the import, so it was stopped. Records written before the switch stay in the previous vault; review it before retrying.';

  @override
  String get r7ImportIssueBundleTooLarge =>
      'The bundle or one of its files exceeds the import limits.';

  @override
  String get r7ImportReadOnly =>
      'This vault is read-only. You can still export.';

  @override
  String get r7ImportIssueBundleInvalid =>
      'The file is not a valid ZIP bundle.';

  @override
  String get r7ImportIssueCsvNul => 'The file contains a NUL character.';

  @override
  String get r7ImportConfirmAccept => 'Import';

  @override
  String get r7ImportIssueMoshAsSsh =>
      'Mosh isn’t supported; this host is imported as SSH with the same port.';

  @override
  String r7ImportIssueTooManyRows(int count) {
    return 'The file has more than $count hosts.';
  }

  @override
  String r7ImportApply(int count) {
    return 'Import $count hosts';
  }

  @override
  String get r7ImportIssueNotUtf8 =>
      'The file is not valid UTF-8 text. Save it as UTF-8 and try again.';

  @override
  String get r7ImportIssueBundleConfigAmbiguous =>
      'The bundle contains several “config” files at the same level; keep only one.';

  @override
  String r7ImportDone(int hosts, int groups) {
    return 'Imported $hosts hosts and $groups groups. They are saved encrypted.';
  }

  @override
  String get r7ImportBlockedFile =>
      'This file can’t be imported. Fix the findings below and choose it again.';

  @override
  String get r7ImportIssueInvalidRecord =>
      'This host doesn’t pass Atermius validation.';

  @override
  String get r7ImportIssueInvalidPrivateKey =>
      'The SSH_KEY private key is too large or invalid.';

  @override
  String r7ImportRowEndpoint(
    String username,
    String address,
    String port,
    String protocol,
  ) {
    return '$username@$address:$port · $protocol';
  }

  @override
  String r7ImportIssueBundleEntryRejected(String name) {
    return 'Bundle entry “$name” was refused (link, unsafe path, encryption or unsupported compression).';
  }

  @override
  String get r7ImportIssueFileTooLarge =>
      'The file is larger than the import limit.';

  @override
  String get r7ImportDispositionBlocked => 'Not importable';

  @override
  String get r7ImportChooseCsv => 'Choose Termius CSV';

  @override
  String get r7ImportIssueKeyIgnoredForProtocol =>
      'Private keys only apply to SSH; the key was not imported for this host.';

  @override
  String r7ImportIssueExportCertificatesNotRepresented(int count) {
    return '$count hosts use a key with a certificate; the Termius CSV can’t carry certificates.';
  }

  @override
  String r7ImportIssueDuplicateInFile(int row) {
    return 'Same host as row $row.';
  }

  @override
  String r7ImportIssueSshForwardBlocked(String name) {
    return '$name wasn’t imported: only loopback-safe forwards with fixed ports are imported. Add other forwards in the forwarding editor.';
  }

  @override
  String r7ImportIssueUnknownColumnValue(String name) {
    return 'A value in column “$name” was not imported.';
  }

  @override
  String get r7ImportIssuePasswordDroppedForKey =>
      'Both a password and a private key were given. Atermius keeps one sign-in per host, so the private key is used and the password is not imported.';

  @override
  String r7ImportIssueDuplicateTags(int count) {
    return '$count duplicate tags were merged.';
  }

  @override
  String get r7ImportIssueSshBlocked =>
      'The OpenSSH config can’t be imported as written.';

  @override
  String get r7ImportDispositionExcluded => 'Excluded by you';

  @override
  String get r7ImportTransferTitle => 'Termius import & export';

  @override
  String get r7ImportIssueMissingAddress => 'Hostname/IP is empty.';

  @override
  String get r7ImportChooseBundle => 'Choose OpenSSH bundle (.zip)';

  @override
  String get r7ImportRowPrivateKey =>
      'Private key included (stored encrypted, never shown)';

  @override
  String r7ImportIssueExportKeysNotRepresented(int count) {
    return '$count hosts sign in with a private key. The Termius CSV template has no key column, so keys are not exported.';
  }

  @override
  String r7ImportIssueExportGroupWhitespace(String name) {
    return 'Host “$name”: a group name starts or ends with spaces, which Termius trims.';
  }

  @override
  String get r7ImportExported => 'Export saved to the chosen file.';

  @override
  String r7ImportIssueNonTemplateColumn(String name) {
    return 'Column “$name” is not in the Termius template. Atermius reads it, but Termius itself rejects files with this column.';
  }

  @override
  String get r7ImportExportFormatBundle =>
      'OpenSSH bundle (.zip): config and key files';

  @override
  String r7ImportIssueGroupTooDeep(int count) {
    return 'Groups can be nested at most $count levels.';
  }

  @override
  String get r7ImportNativeUnsupported =>
      'Encrypted Termius app data, Termius cloud vaults and native backups are not read. Export a CSV from Termius or use its OpenSSH export instead.';

  @override
  String get r7ImportIssueMissingHostname =>
      'The header has no “Hostname/IP” column.';

  @override
  String get r7ImportRowPassword =>
      'Password included (stored encrypted, never shown)';

  @override
  String get r7ImportIssueInvalidPassword =>
      'The password is too long or contains a NUL character; it was not imported.';

  @override
  String get r7ImportIssueInvalidAddress =>
      'Hostname/IP is not a valid host name or address.';

  @override
  String get r7ImportIssueMissingFields =>
      'This row has fewer columns than the header; missing values are treated as empty.';

  @override
  String get r7ImportIssueSshKeyNotInline =>
      'SSH_KEY is not an inline private key. Key names and file paths are never read; add the key to the host after import.';

  @override
  String r7ImportMoreIssuesHidden(int count) {
    return '$count more findings are hidden.';
  }

  @override
  String r7ImportRowGroup(String path) {
    return 'Group: $path';
  }

  @override
  String get r7ImportFailReadOnly =>
      'This vault is read-only. Nothing was imported.';

  @override
  String r7ImportIssueExportTagComma(String name) {
    return 'Host “$name”: a tag contains “,” or surrounding spaces; Termius splits tags on “,” and trims them.';
  }

  @override
  String get r7ImportIssueBundleCertificateMissing =>
      'CertificateFile is missing from the bundle or is not an OpenSSH user certificate.';

  @override
  String r7ImportRowForwards(int count) {
    return 'Port forwards: $count';
  }

  @override
  String get r7ImportIssueMissingUsername =>
      'SSH hosts need a username in Atermius. Fill in the Username column.';

  @override
  String get r7ImportIssueBundleKeyMissing =>
      'IdentityFile is not inside the selected bundle; no other files are read. Add the key after import.';

  @override
  String get r7ImportExportFormatOpenSsh => 'OpenSSH config';

  @override
  String r7ImportIssueExportJumpHost(String name) {
    return 'Host “$name”: its jump host isn’t in this export, so ProxyJump was left out.';
  }

  @override
  String get r7ImportIssueCertificateWithoutKey =>
      'A certificate has no matching private key and was not imported.';

  @override
  String r7ImportFailPartial(int hosts, int groups, int credentials) {
    return 'The import failed and could not be fully undone. Saved before the failure: $hosts hosts, $groups groups, $credentials keychain credentials; a record changed elsewhere or a write interrupted by a vault switch is kept. Review hosts and the keychain before retrying.';
  }

  @override
  String get r7ImportExportSecretConfirmTitle => 'Export readable secrets?';

  @override
  String r7ImportIssueExportAliasRewritten(String name) {
    return 'Host “$name” was given an OpenSSH-safe alias.';
  }

  @override
  String get r7ImportExportSecretConfirmBody =>
      'The exported file is not encrypted. Passwords or private keys in it can be read by anyone or any app with access to the file, including sync and backup tools.';

  @override
  String get r7ImportExportIncludeKeys =>
      'Include private key files (and certificates)';

  @override
  String get r7ImportDispositionDuplicate => 'Skipped: duplicate row';

  @override
  String get r7ImportIssueInvalidLabel =>
      'The label contains control characters or is too long.';

  @override
  String get r7ImportExportIncludePasswords => 'Include passwords';

  @override
  String get r7ImportIssueBundleKeyInvalid =>
      'The IdentityFile in the bundle is not a private key (or is too large) and was not imported.';

  @override
  String r7ImportIssueExportForwards(int count) {
    return '$count hosts have port forwards, which the Termius CSV can’t represent.';
  }

  @override
  String get r7ImportIssueEmptyGroupSegment =>
      'Empty group names in the path were ignored.';

  @override
  String r7ImportExportSummary(int count) {
    return '$count hosts will be exported.';
  }

  @override
  String r7ImportIssueSshJumpMissing(String name) {
    return 'ProxyJump “$name” doesn’t match exactly one importable or saved host.';
  }

  @override
  String get r7ImportModeImport => 'Import';

  @override
  String get r7ImportImportDuplicates =>
      'Also import rows that match an existing host';

  @override
  String get r7ImportIssueExportTooLarge =>
      'This export is larger than Atermius can import back (too many hosts or too much data for one file). Nothing will be saved; export fewer hosts.';

  @override
  String get r7ImportExportSecretConfirmAccept => 'Export with secrets';

  @override
  String r7ImportIssueExportSharedCredential(int count) {
    return '$count hosts sign in with a shared keychain password; it is written into each host’s row only when passwords are included.';
  }

  @override
  String r7ImportIssueAlreadyExists(String name) {
    return 'Matches saved host “$name”.';
  }

  @override
  String get r7ImportChooseOpenSsh => 'Choose OpenSSH config';

  @override
  String r7ImportSummary(int create, int groups, int skipped, int blocked) {
    return '$create to create · $groups new groups · $skipped skipped · $blocked not importable';
  }

  @override
  String get r7ImportTemplateColumns =>
      'Termius CSV columns: Groups, Label, Tags, Hostname/IP, Protocol, Port, Username, Password. Subgroups are separated by “/” and tags by “,”. An extra SSH_KEY column with an inline private key is accepted on import only.';

  @override
  String get r7ImportExportOpenSshNoSecrets =>
      'This config contains no passwords or key files. Use the OpenSSH bundle to include keys.';

  @override
  String get r7ImportExportBundleHelp =>
      'Standard OpenSSH files to extract into ~/.ssh (see README inside). Not a Termius vault; Termius 10.4 does not read certificate files from it.';

  @override
  String get r7ImportIssueControlCharacter =>
      'A value contains control characters.';

  @override
  String r7ImportIssueAtLine(int line, String message) {
    return 'Line $line: $message';
  }

  @override
  String r7ImportIssueSshHostKeyPolicyIgnored(String name) {
    return '$name was ignored; Atermius always verifies host keys with its own known-hosts list.';
  }

  @override
  String r7ImportIssueDuplicateHeader(String name) {
    return 'The column “$name” appears more than once.';
  }

  @override
  String get r7ImportFailStale =>
      'Hosts or groups changed after the preview. Nothing was imported; choose the file again.';

  @override
  String get r7ImportIssueEmptyFile => 'The file is empty.';

  @override
  String get r7ImportExportFailed => 'The export file couldn’t be saved.';

  @override
  String r7ImportRowTags(String tags) {
    return 'Tags: $tags';
  }

  @override
  String get r7ImportIntro =>
      'Import hosts from the Termius CSV template or from an OpenSSH config (including termius export-ssh-config output). Nothing is saved until you review the preview and confirm.';

  @override
  String get r7ImportExportIncludeDesktops =>
      'Include RDP and VNC hosts (Atermius extension; Termius imports them without connection settings)';

  @override
  String get r7ImportIssueInvalidUsername =>
      'The username contains spaces or control characters, or is too long.';

  @override
  String r7ImportIssueExportPasswordsNotRepresented(int count) {
    return '$count hosts sign in with a password, which OpenSSH files can’t store.';
  }

  @override
  String get r7ImportIssueCsvTooManyFields => 'A row has too many columns.';

  @override
  String get r7ImportModeExport => 'Export';

  @override
  String get r7ImportIssueExtraFields =>
      'This row has values beyond the header columns.';

  @override
  String r7ImportRowEndpointNoUser(
    String address,
    String port,
    String protocol,
  ) {
    return '$address:$port · $protocol';
  }

  @override
  String get r7ImportIssueCsvStrayQuote =>
      'A quote appears inside an unquoted field.';

  @override
  String r7ImportIssueUnsupportedProtocol(String name) {
    return 'Protocol “$name” isn’t supported (SSH, RDP and VNC are).';
  }

  @override
  String r7ImportIssueExportGroupSlash(String name) {
    return 'Host “$name”: a group name contains “/”, which Termius reads as a subgroup separator.';
  }

  @override
  String get r7ImportIssueNoTemplateHeader =>
      'The first row is not a Termius CSV header (expected columns such as Label and Hostname/IP).';

  @override
  String get r7ImportExportCancelled =>
      'Export cancelled. No file was written.';

  @override
  String get r7ImportIssueHeaderOrderNotTermius =>
      'The header differs from the Termius template order; Atermius reads it by column name, but Termius would not import this file.';

  @override
  String get r7ImportIssueNameAlreadyUsed =>
      'Another saved host already uses this name.';

  @override
  String r7ImportIssueExtensionProtocol(String name) {
    return 'Protocol “$name” is an Atermius extension; Termius may not accept it in its CSV template.';
  }

  @override
  String get r7ImportDispositionExisting => 'Skipped: already saved';

  @override
  String r7ImportIssueExportSkippedProtocol(int count) {
    return '$count RDP/VNC hosts are not exported in this format.';
  }

  @override
  String get r7ImportIssueInvalidPort =>
      'Port must be a number from 1 to 65535.';

  @override
  String r7ImportIssueUnknownHeader(String name) {
    return 'Column “$name” is not part of the Termius template; its values are not imported.';
  }

  @override
  String r7ImportIssueExportJumpCount(int count) {
    return '$count hosts use a jump host, which this format can’t represent.';
  }

  @override
  String r7ImportIssueSshOptionIgnored(String name) {
    return '$name isn’t applied by Atermius and was ignored.';
  }

  @override
  String r7ImportConfirmBody(int hosts, int groups, int secrets) {
    return 'Create $hosts encrypted hosts and $groups groups in the current vault. $secrets of these hosts include a password or private key, which is stored encrypted inside that host only.';
  }

  @override
  String r7ImportIssueSshFinding(String directive, String message) {
    return '$directive: $message';
  }

  @override
  String r7ImportIssueExportPassphraseNotExported(int count) {
    return '$count exported keys have a saved passphrase; the passphrase is not written, and encrypted keys will ask for it.';
  }

  @override
  String get r7ImportExportFormatCsv => 'Termius CSV';

  @override
  String get r7ImportIssueInvalidGroup =>
      'A group name contains control characters or is too long.';

  @override
  String get r7ImportIssueCsvFieldTooLong => 'A field is too long.';

  @override
  String get r7ImportFailRolledBack =>
      'The import failed and was undone. Nothing was kept.';

  @override
  String get shellLocalInputTooLarge =>
      'Input too large for the local shell; it was not sent';

  @override
  String get shellLocalKindSystem => 'System default shell';

  @override
  String get shellLocalKindCmd => 'Command Prompt (cmd)';

  @override
  String get shellLocalKindPowershell => 'Windows PowerShell';

  @override
  String get shellLocalKindPwsh => 'PowerShell 7 (pwsh)';

  @override
  String get shellLocalKindBash => 'Bash';

  @override
  String get shellLocalKindZsh => 'Zsh';

  @override
  String get shellLocalKindFish => 'Fish';

  @override
  String get shellLocalKindSh => 'POSIX sh';

  @override
  String get shellLocalOptions => 'Local shell options…';

  @override
  String get shellLocalOptionsTitle => 'Start a local shell';

  @override
  String get shellLocalShellLabel => 'Shell';

  @override
  String get shellLocalWorkingDirectoryLabel => 'Working directory (optional)';

  @override
  String get shellLocalWorkingDirectoryHint =>
      'Absolute path or ~/folder; empty uses your home folder';

  @override
  String get shellLocalStart => 'Start shell';

  @override
  String get shellLocalInvalidWorkingDirectory =>
      'Enter an absolute folder path or ~/folder.';

  @override
  String get shellLocalWorkingDirectoryNotFound =>
      'That working directory doesn\'t exist.';

  @override
  String get shellLocalNotInstalled =>
      'That shell isn\'t installed on this computer.';

  @override
  String get shellLocalUnavailable => 'Local shell (desktop app only)';

  @override
  String get shellLocalUnavailableDetail =>
      'This app can\'t start a shell on your computer here, and Atermius never runs one on the server. Use the Atermius desktop app for local shells.';

  @override
  String shellLocalTabTitle(String shell) {
    return 'Local · $shell';
  }

  @override
  String shellLocalNewShell(String shell) {
    return 'New $shell';
  }

  @override
  String get telnetHost => 'Telnet host';

  @override
  String get telnetProtocolUnencrypted => 'Telnet (unencrypted)';

  @override
  String get telnetInteractiveLogin =>
      'Interactive in terminal (nothing saved is sent)';

  @override
  String get telnetLoginInteractiveHint =>
      'Telnet login is interactive: type your user name and password in the terminal. Saved passwords, keys and Keychain items are never sent over Telnet.';

  @override
  String get telnetPlaintextWarningTitle => 'Telnet is not encrypted';

  @override
  String get telnetPlaintextWarningBody =>
      'Everything sent over Telnet, including passwords you type, travels in plain text and can be read or changed on the network. Use it only on trusted networks or for devices without SSH. The saved host entry itself stays encrypted.';

  @override
  String telnetPlaintextTerminalNotice(String endpoint) {
    return 'Telnet to $endpoint is unencrypted: anything you type, including passwords, is sent in plain text.';
  }

  @override
  String telnetConnectedToEndpoint(String endpoint) {
    return 'Telnet connected to $endpoint (unencrypted)';
  }

  @override
  String get telnetConnectedUnencrypted => 'Telnet connected (unencrypted)';

  @override
  String get telnetConnecting => 'Telnet connecting';

  @override
  String get telnetDisconnected => 'Telnet disconnected';

  @override
  String get telnetConnectionClosedTerminal =>
      '\r\n[Telnet connection closed]\r\n';

  @override
  String get telnetConnectionRefused =>
      'The Telnet server refused the connection.';

  @override
  String get telnetConnectionTimedOut => 'The Telnet connection timed out.';

  @override
  String get telnetHostLookupFailed =>
      'The Telnet host name couldn\'t be resolved.';

  @override
  String get telnetHostUnreachable => 'Couldn\'t reach the Telnet host.';

  @override
  String get telnetRelayUnavailable =>
      'Couldn\'t open Telnet through the server Relay.';

  @override
  String get telnetUnsupportedInBrowser =>
      'Telnet in a browser needs a signed-in Atermius server with Relay enabled for this destination. Browser local profiles can\'t open raw TCP connections.';

  @override
  String get telnetProtocolError =>
      'The Telnet server sent an invalid or excessive negotiation stream, so the connection was closed.';

  @override
  String get telnetConnectionLost => 'The Telnet connection was lost.';

  @override
  String get telnetConnectCancelled => 'The Telnet connection was cancelled.';

  @override
  String get telnetHostSettingsInvalid =>
      'Telnet hosts can\'t use saved sign-in details, Keychain items, Jump Hosts or port forwarding. Log in interactively in the terminal.';

  @override
  String get telnetQuickConnectNoUser =>
      'Telnet doesn\'t send a user name automatically. Use: telnet host[:port] and log in in the terminal.';

  @override
  String get telnetInputTooLarge =>
      'That paste is too large to send over Telnet (limit 1 MiB). Nothing was sent.';

  @override
  String get accountSettingsTitle => 'Account & sign-in';

  @override
  String get accountSettingsDescription =>
      'See which account and server this device uses, manage the session, or sign in to an account.';

  @override
  String get accountSettingsCurrentMode => 'Current mode';

  @override
  String get accountSettingsModeAccount => 'Account and sync';

  @override
  String get accountSettingsModeLocal => 'Local only (this device)';

  @override
  String get accountSettingsSignedInAs => 'Signed in as';

  @override
  String get accountSettingsServer => 'Server';

  @override
  String get accountSettingsSessionUnlocked =>
      'Signed in and unlocked on this device';

  @override
  String get accountSettingsActiveVault => 'Current Vault';

  @override
  String get accountSettingsNoVault => 'No Vault selected';

  @override
  String get accountSettingsInstanceAdmin => 'Instance administrator';

  @override
  String get accountSettingsSessionActions => 'Session';

  @override
  String get accountSettingsSecurityAction =>
      'Password, two-factor and recovery';

  @override
  String get accountSettingsSignOutTitle => 'Sign out of this account?';

  @override
  String get accountSettingsSignOutBody =>
      'Open sessions for this account on this device will close. Your encrypted Vault data stays on the server, and you will need your account password to sign in again.';

  @override
  String get accountSettingsSwitchToLocalTitle => 'Switch to local mode?';

  @override
  String get accountSettingsSwitchToLocalBody =>
      'The account workspace and its open sessions on this device will close. Nothing from the account is copied into local profiles.';

  @override
  String get accountSettingsLocalNotSignedIn => 'Not signed in to an account';

  @override
  String get accountSettingsLocalSyncRequiresAccount =>
      'Local profiles are stored only on this device and never sync. To sync hosts between devices, sign in to an account on your Atermius server.';

  @override
  String get accountSettingsSignIn => 'Sign in or connect to a server';

  @override
  String get accountSettingsSignInTitle => 'Open account sign-in?';

  @override
  String get accountSettingsSignInBody =>
      'The local profile will be locked and its open sessions closed. Local hosts stay on this device and are not uploaded. After signing in you can review moving them in Data and migration.';

  @override
  String get themeSettingTitle => 'Theme';

  @override
  String themeSettingSystemResolved(Object theme) {
    return 'Match system · currently $theme';
  }

  @override
  String get themeOptionSystem => 'Match system';

  @override
  String get themeSettingDescription =>
      'Changes the app\'s windows, menus and panels. Terminal colors and remote desktop images keep their own palette.';

  @override
  String get themeOptionLight => 'Light';

  @override
  String get themeOptionDark => 'Dark';

  @override
  String get themeSettingSaveFailed =>
      'The theme changed for this session but couldn\'t be saved on this device.';

  @override
  String get syncSettingsPreferenceSaveFailed =>
      'Couldn\'t save this choice on this device. It applies until the app restarts.';

  @override
  String get syncSettingsSyncingNow => 'Syncing…';

  @override
  String get syncSettingsDeviceOnly =>
      'These sync choices apply only to this device.';

  @override
  String get syncSettingsPreferenceSaving => 'Saving…';

  @override
  String get syncSettingsAutomaticOffDescription =>
      'Off on this device. Edits stay encrypted in this device\'s queue until you choose Sync now or turn automatic sync back on.';

  @override
  String get syncSettingsNever => 'Never';

  @override
  String get syncSettingsSignInRequired =>
      'Sync needs an account sign-in on this device.';

  @override
  String syncSettingsResultNotCompleted(String status) {
    return 'Sync didn\'t complete. Current status: $status.';
  }

  @override
  String get syncSettingsWaitingToUpload => 'Waiting to upload';

  @override
  String syncSettingsResultFailed(String error) {
    return 'Sync didn\'t complete: $error';
  }

  @override
  String syncSettingsQueuedWhileOff(int count) {
    return 'Encrypted changes queued on this device: $count. They upload when you choose Sync now or turn automatic sync on.';
  }

  @override
  String get syncSettingsTitle => 'Sync';

  @override
  String syncSettingsResultPending(int count) {
    return 'Sync ran, but encrypted changes are still waiting to upload: $count.';
  }

  @override
  String get syncSettingsAutomaticTitle => 'Automatic sync';

  @override
  String get syncSettingsPreferenceLoading =>
      'Loading this device\'s sync choice… Automatic sync starts after it loads.';

  @override
  String get syncSettingsPreferenceReadFailedShort =>
      'Automatic sync stays paused until the saved choice can be read. Retry, or choose a setting to replace it.';

  @override
  String get syncSettingsResultCompleted =>
      'Sync complete. Nothing is waiting to upload.';

  @override
  String get syncSettingsAutomaticOnDescription =>
      'Edits upload and changes from other devices download in the background.';

  @override
  String get syncSettingsPreferenceReadFailed =>
      'Paused: this device\'s saved choice couldn\'t be read.';

  @override
  String get syncSettingsSyncNow => 'Sync now';

  @override
  String get syncSettingsStatus => 'Status';

  @override
  String get settingsThemeShortcutsTitle => 'Shortcuts';

  @override
  String get settingsThemeShortcutsDescription =>
      'Choose the keyboard shortcuts used in terminals.';

  @override
  String get settingsThemeTitle => 'Theme';

  @override
  String settingsThemeOverlayActive(String name) {
    return 'Terminals on this device show the device palette $name instead. Selecting the saved theme, or saving another one, switches them back.';
  }

  @override
  String get settingsThemeDescription =>
      'Choose the app\'s light or dark mode, the terminal font size and terminal colors.';

  @override
  String get wallpaperSettingTitle => 'Wallpaper';

  @override
  String get wallpaperSettingDescription =>
      'Shows an image behind the app and terminal panes. Only the image is blurred; text, controls, terminal text and remote desktop images stay sharp.';

  @override
  String get wallpaperChooseImage => 'Choose image…';

  @override
  String get wallpaperReplaceImage => 'Replace image…';

  @override
  String get wallpaperReset => 'Remove wallpaper';

  @override
  String get wallpaperNoImage => 'No wallpaper';

  @override
  String get wallpaperPreviewLabel => 'Wallpaper preview';

  @override
  String get wallpaperLoading => 'Loading wallpaper…';

  @override
  String get wallpaperMissing =>
      'The saved wallpaper image is missing or can\'t be read. Choose a new image or remove the wallpaper.';

  @override
  String get wallpaperModeTitle => 'Layout';

  @override
  String get wallpaperModeWindow => 'Whole window';

  @override
  String get wallpaperModeWindowHint => 'One image spans the whole window.';

  @override
  String get wallpaperModePanes => 'Follow splits';

  @override
  String get wallpaperModePanesHint =>
      'Each terminal pane shows its own copy of the image and follows resizing and reordering.';

  @override
  String wallpaperBlurValue(String value) {
    return 'Blur: $value';
  }

  @override
  String wallpaperErrorTooLarge(int limit) {
    return 'This image is larger than $limit MB.';
  }

  @override
  String get wallpaperErrorUnsupported =>
      'Choose a PNG, JPEG or still WebP image.';

  @override
  String get wallpaperErrorCorrupt =>
      'This image can\'t be read. It may be damaged.';

  @override
  String wallpaperErrorDimensions(int side) {
    return 'This image is too large to use (up to $side px per side).';
  }

  @override
  String get wallpaperErrorStorage =>
      'The wallpaper couldn\'t be saved on this device.';

  @override
  String get wallpaperSaveFailed =>
      'The wallpaper changed for this session but couldn\'t be saved on this device.';

  @override
  String get wallpaperDeviceNote =>
      'A copy of the image is kept in this app\'s storage on this device. Separate windows use the same wallpaper when they open.';

  @override
  String get fileManagerPasteInto => 'Paste into folder';

  @override
  String get fileManagerPathCopied => 'Path copied';

  @override
  String fileManagerCopying(String name) {
    return 'Copying \"$name\"…';
  }

  @override
  String get fileManagerDropFailed =>
      'The dropped items couldn\'t be read. Nothing was uploaded.';

  @override
  String get fileManagerOperationUnsupported =>
      'This connection doesn\'t support file-manager operations.';

  @override
  String fileManagerDeleteConfirm(String name) {
    return 'Delete \"$name\"? This can\'t be undone.';
  }

  @override
  String get fileManagerOpen => 'Open';

  @override
  String get fileManagerPasteHere => 'Paste here';

  @override
  String fileManagerUploading(String name, int index, int count) {
    return 'Uploading \"$name\" ($index/$count)…';
  }

  @override
  String fileManagerMoveConfirm(String name, String folder) {
    return 'Move \"$name\" into \"$folder\"?';
  }

  @override
  String get fileManagerNameConflictTitle => 'Name already in use';

  @override
  String get fileManagerSkip => 'Skip';

  @override
  String fileManagerClipboardCut(String name) {
    return 'Cut \"$name\" — paste in this tab to move it';
  }

  @override
  String fileManagerRenameTitle(String name) {
    return 'Rename \"$name\"';
  }

  @override
  String fileManagerDeleteFolderConfirm(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'all $count items',
      one: 'the 1 item',
    );
    return 'Delete folder \"$name\" and $_temp0 inside it? Symbolic links are removed, not followed. This can\'t be undone.';
  }

  @override
  String get fileManagerClearClipboard => 'Clear file clipboard';

  @override
  String get fileManagerRename => 'Rename';

  @override
  String fileManagerErrorUnsupportedEntry(String name) {
    return '\"$name\" is a symbolic link, special file or has an unsupported name. Folder copies don\'t follow or recreate these, so nothing was copied.';
  }

  @override
  String get fileManagerKeepBoth => 'Keep both';

  @override
  String fileManagerErrorFileTooLarge(String name) {
    return '\"$name\" is larger than the 1 GiB per-file copy limit.';
  }

  @override
  String get fileManagerCut => 'Cut';

  @override
  String get fileManagerDropNothingAccepted =>
      'Only files can be dropped here. Folders and links to other locations aren\'t uploaded.';

  @override
  String get fileManagerPaste => 'Paste';

  @override
  String get fileManagerErrorSourceChanged =>
      'The item changed or disappeared on the server. Refresh and try again.';

  @override
  String fileManagerErrorExists(String name) {
    return '\"$name\" already exists here. Nothing was replaced.';
  }

  @override
  String get fileManagerMoveTitle => 'Move item';

  @override
  String get fileManagerErrorIntoItself =>
      'A folder can\'t be moved or copied into itself.';

  @override
  String get fileManagerCancelled => 'Cancelled. Nothing else was changed.';

  @override
  String fileManagerDropTooManyFiles(int count) {
    return 'Drop at most $count files at a time.';
  }

  @override
  String get fileManagerBusy => 'Another file action is still running.';

  @override
  String get fileManagerCopyPath => 'Copy path';

  @override
  String fileManagerNameConflictKeepBoth(String name) {
    return '\"$name\" already exists in this folder. Keep both by adding \"(copy)\" to the new name? The existing item won\'t be replaced.';
  }

  @override
  String fileManagerMoving(String name) {
    return 'Moving \"$name\"…';
  }

  @override
  String fileManagerClipboardCopied(String name) {
    return 'Copied \"$name\" — paste in this tab';
  }

  @override
  String get fileManagerDropNeedsSftp =>
      'Dropped files are uploaded with SFTP. Open this folder with SFTP to upload.';

  @override
  String fileManagerDeleting(String name) {
    return 'Deleting \"$name\"…';
  }

  @override
  String fileManagerUploadSummary(int uploaded, int skipped, int failed) {
    return 'Uploaded $uploaded · skipped $skipped · failed $failed';
  }

  @override
  String get fileManagerInvalidName =>
      'Use a single name without slashes, backslashes or control characters.';

  @override
  String fileManagerErrorLimitExceeded(int entries, int depth) {
    return 'This folder is too large for a file-manager action (limit $entries items, $depth levels deep or 2 GiB). Nothing was changed.';
  }

  @override
  String get fileManagerCopy => 'Copy';

  @override
  String get fileManagerDropTargetChanged =>
      'The file tab changed folder or connection while the drop was being checked. Nothing was uploaded; drop the files again.';

  @override
  String fileManagerUploadConflict(String name) {
    return '\"$name\" already exists in this folder. Upload it under a new \"(copy)\" name or skip it? The existing file won\'t be replaced.';
  }

  @override
  String get fileManagerMove => 'Move';

  @override
  String get homeAddSerialConsoleDetail =>
      'Opens a COM port on this computer at 8N1. Nothing runs on the server.';

  @override
  String get homeSharingThisDevice => 'Online on this device';

  @override
  String get homeAddShell => 'Shell (system default)';

  @override
  String homeSharingSharedPresenceUnknown(int members) {
    return 'Shared · $members members · status unknown';
  }

  @override
  String get homeSharingLoading => 'Loading members…';

  @override
  String get homeAddTooltip =>
      'Add a host or open a local Shell or serial Console';

  @override
  String get homeAddButton => 'Add';

  @override
  String get homeSharingLocalOnly => 'Local only';

  @override
  String get homeAddSerialConsolePort => 'Serial port';

  @override
  String homeSharingMore(int count, String names) {
    return '$count more:\n$names';
  }

  @override
  String get homeAddSerialConsoleOpen => 'Open Console';

  @override
  String homeSharingSharedOnline(int members, int online) {
    return 'Shared · $members members · $online online';
  }

  @override
  String get homeAddSerialConsoleBaud => 'Baud rate';

  @override
  String homeSharingYou(String name) {
    return '$name (you)';
  }

  @override
  String get homeAddSerialConsoleTitle => 'Open serial Console';

  @override
  String get homeAddSerialConsole => 'Serial Console (COM)…';

  @override
  String get homeSharingLocalDetail =>
      'This local Profile is stored encrypted on this device only. It has no Vault members, nobody else can see it and no presence is sent. Sign in to an account Vault to share Hosts with other people.';

  @override
  String get homeAddSerialConsoleUnavailable =>
      'Serial Console (Windows app only)';

  @override
  String get homeSharingPresenceUnknown => 'Status unknown';

  @override
  String get homeSharingOffline => 'Offline';

  @override
  String get homeSharingMembersUnavailable => 'Members not loaded';

  @override
  String get homeSharingLocalTooltip =>
      'Local Profile on this device — not shared with anyone';

  @override
  String get homeSharingDetailsTooltip =>
      'Show Vault members and online status';

  @override
  String get homeSharingIndividual => 'Only you';

  @override
  String get homeSharingOnline => 'Online';

  @override
  String sidebarResizeWidthValue(int width) {
    return '$width px wide';
  }

  @override
  String get sidebarResizeHint =>
      'Drag, or use the Left and Right arrow keys, to change the width';

  @override
  String get sidebarResizeHandle => 'Resize sidebar';

  @override
  String get fileEditLaunchFailed => 'No application could open this file.';

  @override
  String get fileEditAtomicUnsupported =>
      'This server can\'t replace files atomically, so nothing was uploaded.';

  @override
  String get fileEditUpload => 'Upload';

  @override
  String get fileEditLocalRejected =>
      'The local copy is no longer a regular file in its private folder. Nothing was uploaded.';

  @override
  String get fileEditConflictTitle => 'Server copy changed';

  @override
  String fileEditUploadedChangedAgain(String name) {
    return 'Uploaded \"$name\", but it changed again locally while sending. Upload again when ready.';
  }

  @override
  String get fileEditBlockedType =>
      'This file type could run when opened, so it isn\'t opened externally. Use Edit text or Download instead.';

  @override
  String get fileEditStatusRejected => 'Local copy rejected';

  @override
  String fileEditFooterTitle(int count) {
    return 'Editing externally ($count)';
  }

  @override
  String get fileEditOpenExternal => 'Open in external app';

  @override
  String get fileEditSessionChanged =>
      'This file tab\'s connection closed or changed. Nothing was uploaded.';

  @override
  String get fileEditStatusChanged => 'Changed locally — not uploaded';

  @override
  String fileEditTooMany(int count) {
    return 'At most $count files can be edited externally at once.';
  }

  @override
  String get fileEditLocalMissing =>
      'The local copy is missing. Nothing was uploaded.';

  @override
  String get fileEditNotRegular =>
      'Only regular remote files can be edited externally.';

  @override
  String get fileEditStatusWatching => 'Watching for saves';

  @override
  String get fileEditIgnore => 'Ignore';

  @override
  String fileEditOpened(String name) {
    return 'Opened \"$name\" externally. After saving there, choose Upload below.';
  }

  @override
  String get fileEditTooLarge =>
      'Only files up to 10 MiB can be edited externally.';

  @override
  String get fileEditLocalTooLarge =>
      'The local copy is larger than 10 MiB. Nothing was uploaded.';

  @override
  String get fileEditStatusUploading => 'Uploading…';

  @override
  String get fileEditUnavailable =>
      'External editing needs the desktop app. Use Edit text to change this file here.';

  @override
  String fileEditConflictMessage(String name) {
    return '\"$name\" changed on the server after you opened it. Replace the server copy with your local version?';
  }

  @override
  String get fileEditStatusConflict => 'Also changed on the server';

  @override
  String fileEditUploaded(String name) {
    return 'Uploaded \"$name\".';
  }

  @override
  String get fileEditStop => 'Stop watching';

  @override
  String get fileEditStatusFailed => 'Upload failed — local change kept';

  @override
  String get fileEditKeepLocal => 'Keep local';

  @override
  String get fileEditReplace => 'Replace server copy';

  @override
  String get cloudAccessShareMenu => 'Share…';

  @override
  String cloudAccessShareTitle(String name) {
    return 'Share $name';
  }

  @override
  String get cloudAccessClose => 'Close';

  @override
  String get cloudAccessTabMembers => 'Members & teams';

  @override
  String get cloudAccessTabLinks => 'Temporary links';

  @override
  String get cloudAccessGatewayTrustNotice =>
      'Guests connect through this server\'s gateway. To make that possible, this Host\'s login is sealed to the server gateway key until the link is revoked or expires. The server operator (or anyone who compromises the server) can open it and see the session. Guests never receive the password or key through this feature, but can do anything the account allows inside the session. Use a dedicated low-privilege account.';

  @override
  String get cloudAccessLinksHeading => 'Links for this Host';

  @override
  String get cloudAccessNewLink => 'New link';

  @override
  String get cloudAccessNoLinks => 'No temporary links yet.';

  @override
  String get cloudAccessStatusActive => 'Active';

  @override
  String get cloudAccessStatusScheduled => 'Scheduled';

  @override
  String get cloudAccessStatusExpired => 'Expired';

  @override
  String get cloudAccessStatusPaused => 'Paused';

  @override
  String get cloudAccessStatusSuspended => 'Suspended';

  @override
  String get cloudAccessStatusRevoked => 'Revoked';

  @override
  String cloudAccessValidUntil(String time) {
    return 'until $time';
  }

  @override
  String cloudAccessRedemptionCount(String used, String max) {
    return '$used/$max opened';
  }

  @override
  String cloudAccessActiveSessions(String count) {
    return '$count active';
  }

  @override
  String get cloudAccessMore => 'More';

  @override
  String get cloudAccessActivity => 'Activity';

  @override
  String get cloudAccessPause => 'Pause';

  @override
  String get cloudAccessResume => 'Resume';

  @override
  String get cloudAccessRotate => 'New secret';

  @override
  String get cloudAccessRevoke => 'Revoke';

  @override
  String get cloudAccessRevokeLinkTitle => 'Revoke this link?';

  @override
  String get cloudAccessRevokeLinkMessage =>
      'The link stops working immediately and active guest sessions are closed within seconds. Revocation cannot undo what guests already did on the Host.';

  @override
  String get cloudAccessRotateTitle => 'Issue a new secret?';

  @override
  String get cloudAccessRotateMessage =>
      'The current URL stops working and its guests are disconnected. You get a new URL to send.';

  @override
  String get cloudAccessScheduleStart => 'Start later';

  @override
  String get cloudAccessStartsNow => 'Starts now';

  @override
  String get cloudAccessPickStart => 'Choose a start time';

  @override
  String get cloudAccessLifetime => 'Valid for';

  @override
  String get cloudAccessOneHour => '1 hour';

  @override
  String get cloudAccessOneDay => '24 hours';

  @override
  String get cloudAccessOneWeek => '7 days';

  @override
  String get cloudAccessCustom => 'Custom…';

  @override
  String cloudAccessWindowSummary(String start, String end, String utc) {
    return 'From $start until $end (your local time; $utc UTC). The server clock decides.';
  }

  @override
  String get cloudAccessEndBeforeStart =>
      'The end must be after the start and in the future.';

  @override
  String get cloudAccessMaxRedemptions => 'Times the link can be opened';

  @override
  String get cloudAccessMaxRedemptionsHelp =>
      'Default 1. Each browser that clicks Continue uses one.';

  @override
  String get cloudAccessUnlimited => 'Unlimited';

  @override
  String get cloudAccessRedemptionsRange =>
      'Enter 1–1000, or choose Unlimited.';

  @override
  String get cloudAccessMaxConnections => 'Connection attempts (optional)';

  @override
  String get cloudAccessMaxConnectionsHelp =>
      'Leave empty for no limit. Refused attempts do not count.';

  @override
  String get cloudAccessConnectionsRange =>
      'Enter a positive number or leave it empty.';

  @override
  String get cloudAccessConcurrent => 'Simultaneous connections';

  @override
  String get cloudAccessViewOnly => 'View only';

  @override
  String get cloudAccessViewOnlyHelp =>
      'Keyboard, mouse and paste are blocked by the server.';

  @override
  String get cloudAccessClipboardToRemote => 'Allow pasting into the Host';

  @override
  String get cloudAccessClipboardFromRemote => 'Allow copying from the Host';

  @override
  String get cloudAccessFilesLocked =>
      'File transfer, drives, printing and recording are off for guests.';

  @override
  String get cloudAccessCustomSlug => 'Custom address (optional)';

  @override
  String get cloudAccessCustomSlugHelp =>
      '3–48 lowercase letters, digits or hyphens. An address is not a password: anyone may guess it, so avoid sensitive words.';

  @override
  String get cloudAccessGuestTitle => 'Title shown to the guest (optional)';

  @override
  String get cloudAccessGuestTitleHelp =>
      'Encrypted with the link secret; the server cannot read it.';

  @override
  String get cloudAccessCancel => 'Cancel';

  @override
  String get cloudAccessCreateLink => 'Create link';

  @override
  String get cloudAccessLinkReady => 'Link created';

  @override
  String get cloudAccessCopyLink => 'Copy link';

  @override
  String get cloudAccessCopied => 'Copied';

  @override
  String get cloudAccessShownOnce =>
      'This is the only time the full link is shown. If it is lost, issue a new secret.';

  @override
  String get cloudAccessSendSafely =>
      'Anyone with this link can open it. Send it only through a channel you trust; some mail scanners may open links and use them up.';

  @override
  String get cloudAccessDone => 'Done';

  @override
  String get cloudAccessBack => 'Back';

  @override
  String cloudAccessActivityFor(String link) {
    return 'Activity · $link';
  }

  @override
  String get cloudAccessGuestSessions => 'Guest sessions';

  @override
  String get cloudAccessNoSessions => 'Nobody has opened this link yet.';

  @override
  String cloudAccessSessionSince(String time) {
    return 'Active since $time';
  }

  @override
  String cloudAccessSessionEnded(String reason) {
    return 'Ended ($reason)';
  }

  @override
  String get cloudAccessTerminate => 'End session';

  @override
  String get cloudAccessAuditEvents => 'Audit (metadata only)';

  @override
  String get cloudAccessMembersExplainer =>
      'Members get this Host through an encrypted Vault. Recipients receive the Vault key only after you confirm each of their devices; organization admins cannot obtain it on their own.';

  @override
  String get cloudAccessDedicatedVault => 'Share only this Host';

  @override
  String get cloudAccessDedicatedVaultHelp =>
      'A new sharing Vault is created with a copy of this Host and only the items listed below. Other Hosts and credentials in your current Vault stay private.';

  @override
  String get cloudAccessSharingVaultName => 'Sharing Vault name';

  @override
  String cloudAccessSharingVaultDefaultName(String name) {
    return 'Shared · $name';
  }

  @override
  String get cloudAccessWillCopy => 'Will be copied:';

  @override
  String cloudAccessDependencyJumpHost(String name) {
    return 'Jump host $name';
  }

  @override
  String cloudAccessDependencyCredential(String name) {
    return 'Credential $name';
  }

  @override
  String cloudAccessDependencyKnownHost(String key) {
    return 'Trusted host key $key';
  }

  @override
  String cloudAccessDependencyGroup(String name) {
    return 'Group $name is not copied';
  }

  @override
  String cloudAccessBlockerMissingJump(String name) {
    return '$name uses a jump host that is not in this Vault.';
  }

  @override
  String cloudAccessBlockerMissingCredential(String name) {
    return '$name references a credential that is not in this Vault.';
  }

  @override
  String cloudAccessBlockerJumpLoop(String name) {
    return '$name has a jump host loop.';
  }

  @override
  String get cloudAccessConsentCopy =>
      'I approve copying exactly these items into the new Vault.';

  @override
  String get cloudAccessCreateSharingVault => 'Create sharing Vault';

  @override
  String get cloudAccessWholeVaultHeading => 'Or share this whole Vault';

  @override
  String get cloudAccessWholeVaultHelp =>
      'Recipients will see every Host, credential and snippet in the current Vault.';

  @override
  String get cloudAccessManageWholeVault => 'Manage whole-Vault access';

  @override
  String get cloudAccessAttachOrg => 'Choose an organization';

  @override
  String get cloudAccessAttachOrgHelp =>
      'Grants refer to members and teams of one organization you manage.';

  @override
  String get cloudAccessAttach => 'Use';

  @override
  String get cloudAccessManageOrganizations => 'Manage organizations';

  @override
  String cloudAccessGrantsIn(String org) {
    return 'Access in $org';
  }

  @override
  String get cloudAccessAddGrant => 'Add member or team';

  @override
  String cloudAccessTeamLabel(String name) {
    return 'Team $name';
  }

  @override
  String get cloudAccessRoleViewer => 'Viewer';

  @override
  String get cloudAccessRoleEditor => 'Editor';

  @override
  String get cloudAccessRemove => 'Remove';

  @override
  String get cloudAccessKeyDistribution => 'Waiting for keys';

  @override
  String get cloudAccessKeyDistributionHelp =>
      'Compare each fingerprint with the recipient through another channel before delivering the Vault key.';

  @override
  String get cloudAccessWaitingForDevice =>
      'Waiting for the recipient to open Organizations on a device';

  @override
  String get cloudAccessWaitingForOwner => 'Ready for you to confirm';

  @override
  String get cloudAccessWaitingForRecipient =>
      'Key sent; waiting for the recipient to accept';

  @override
  String get cloudAccessRoleDiffers =>
      'Signed role differs from the grant; rotate or re-invite to change it';

  @override
  String cloudAccessDeviceFingerprint(String fingerprint) {
    return 'Device $fingerprint';
  }

  @override
  String get cloudAccessConfirmFingerprintTitle => 'Confirm this device';

  @override
  String cloudAccessConfirmFingerprintMessage(String user, String fingerprint) {
    return 'Deliver the Vault key to $user\'s device $fingerprint? Only continue if $user confirmed this fingerprint to you.';
  }

  @override
  String get cloudAccessDeliverKey => 'Deliver key';

  @override
  String get cloudAccessRemovalPending =>
      'Server access is already blocked. Rotate the Vault key to remove this member cryptographically, and change any credentials they have seen.';

  @override
  String get cloudAccessKeepDirect => 'Keep as direct member';

  @override
  String get cloudAccessRotateToRemove => 'Rotate key';

  @override
  String get cloudAccessRestrictedToViewer =>
      'Limited to viewing until the signed role is updated';

  @override
  String get cloudAccessOrganizations => 'Organizations';

  @override
  String get cloudAccessOrganizationsSubtitle =>
      'Members, teams and invitations';

  @override
  String get cloudAccessOrganizationsExplainer =>
      'Organization names, members, roles and teams are visible to this server. Joining an organization never gives you a Vault key by itself.';

  @override
  String get cloudAccessPendingJoin =>
      'You opened an organization invitation — review it';

  @override
  String get cloudAccessJoinOrganization => 'Join an organization';

  @override
  String get cloudAccessJoinLinkField => 'Invitation link';

  @override
  String get cloudAccessJoinInvalid => 'This is not a valid invitation link.';

  @override
  String get cloudAccessReview => 'Review';

  @override
  String cloudAccessJoinSummary(String inviter, String role) {
    return 'Invited by $inviter as $role';
  }

  @override
  String get cloudAccessJoin => 'Join';

  @override
  String get cloudAccessJoined =>
      'Joined. Vault owners still need to confirm your device before you receive any shared Vault.';

  @override
  String get cloudAccessSharedVaultKeys => 'Shared Vault keys';

  @override
  String get cloudAccessSharedVaultKeysHelp =>
      'Publishes this device\'s public keys and accepts Vaults whose owners confirmed this device.';

  @override
  String get cloudAccessCheckDeliveries => 'Check for shared Vaults';

  @override
  String cloudAccessDeliveriesAccepted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count shared Vaults added.',
      one: '1 shared Vault added.',
      zero: 'No new shared Vaults.',
    );
    return '$_temp0';
  }

  @override
  String get cloudAccessYourOrganizations => 'Your organizations';

  @override
  String get cloudAccessNewOrganization => 'New organization';

  @override
  String get cloudAccessOrganizationName => 'Organization name';

  @override
  String get cloudAccessNoOrganizations =>
      'You are not in any organization yet.';

  @override
  String cloudAccessMemberCount(String count) {
    return '$count members';
  }

  @override
  String get cloudAccessOrgRoleOwner => 'Owner';

  @override
  String get cloudAccessOrgRoleAdmin => 'Admin';

  @override
  String get cloudAccessOrgRoleMember => 'Member';

  @override
  String get cloudAccessSave => 'Save';

  @override
  String get cloudAccessMembers => 'Members';

  @override
  String get cloudAccessInviteMember => 'Invite';

  @override
  String get cloudAccessInviteUsername => 'Username (optional)';

  @override
  String get cloudAccessInviteUsernameHelp =>
      'Limit the invitation to one existing account. New people first need an account invitation from an instance administrator.';

  @override
  String get cloudAccessRole => 'Role';

  @override
  String get cloudAccessInitialTeam => 'Team';

  @override
  String get cloudAccessNoTeam => 'No team';

  @override
  String get cloudAccessCreateInvitation => 'Create invitation';

  @override
  String get cloudAccessInvitationReady => 'Invitation link created';

  @override
  String get cloudAccessCopyInvitation => 'Copy invitation link';

  @override
  String get cloudAccessLeave => 'Leave';

  @override
  String get cloudAccessRemoveMemberTitle => 'Remove from organization?';

  @override
  String get cloudAccessRemoveMemberMessage =>
      'Access through organization grants is blocked immediately. Vault owners should then rotate keys of affected Vaults.';

  @override
  String get cloudAccessTeams => 'Teams';

  @override
  String get cloudAccessNewTeam => 'New team';

  @override
  String get cloudAccessTeamName => 'Team name';

  @override
  String cloudAccessTeamMembers(String team) {
    return 'Members of $team';
  }

  @override
  String get cloudAccessInvitations => 'Invitations';

  @override
  String get cloudAccessAnyAccount => 'Any account';

  @override
  String get cloudAccessErrorGeneric => 'The request could not be completed.';

  @override
  String get cloudAccessErrorLinksUnavailable =>
      'Temporary links are not configured on this server.';

  @override
  String get cloudAccessErrorOrganizationsUnavailable =>
      'Organizations are not enabled on this server.';

  @override
  String get cloudAccessErrorProtocolUnavailable =>
      'This Host\'s protocol cannot be shared on this server.';

  @override
  String get cloudAccessErrorOwnerRequired =>
      'Only the Vault owner can share through links.';

  @override
  String get cloudAccessErrorJumpHost =>
      'Hosts that use a jump host cannot be shared through the gateway.';

  @override
  String get cloudAccessErrorPortForward =>
      'Hosts with port forwarding profiles cannot be shared through the gateway.';

  @override
  String get cloudAccessErrorHostKeyRequired =>
      'Connect once and trust this Host\'s SSH key before sharing it.';

  @override
  String get cloudAccessErrorCertificateRequired =>
      'Connect once and trust this Host\'s RDP certificate before sharing it.';

  @override
  String get cloudAccessErrorLoginRequired =>
      'Save a login on this Host before sharing it.';

  @override
  String get cloudAccessErrorHostChanged =>
      'The Host changed or is not synchronized yet. Sync and try again.';

  @override
  String get cloudAccessErrorPlanBlocked =>
      'Resolve the listed problems first.';

  @override
  String get cloudAccessErrorTargetDenied =>
      'This Host\'s address is not allowed by the server\'s sharing policy.';

  @override
  String get cloudAccessErrorSlugTaken => 'This address is not available.';

  @override
  String get cloudAccessErrorSlugInvalid =>
      'Use 3–48 lowercase letters, digits or inner hyphens.';

  @override
  String get cloudAccessErrorTooManyLinks =>
      'Too many active links. Revoke some first.';

  @override
  String get cloudAccessErrorInvalidOptions =>
      'These link options are not allowed by the server.';

  @override
  String get cloudAccessErrorOrgRoleRequired =>
      'Organization owner or admin role is required.';

  @override
  String get cloudAccessErrorOrgCreationRestricted =>
      'Only instance administrators can create organizations here.';

  @override
  String get cloudAccessErrorLastOwner =>
      'An organization needs at least one owner.';

  @override
  String get cloudAccessErrorInvitationUnavailable =>
      'This invitation is not available.';

  @override
  String get cloudAccessErrorAccountNotFound =>
      'No active account has this username.';

  @override
  String get cloudAccessErrorRateLimited =>
      'Too many attempts. Wait a moment and try again.';

  @override
  String get cloudAccessGuestWindowTitle => 'Atermius shared access';

  @override
  String get cloudAccessGuestLanding =>
      'You received an Atermius temporary access link';

  @override
  String get cloudAccessGuestLandingHelp =>
      'Nothing happens until you continue. Continuing may use one of the link\'s allowed openings.';

  @override
  String get cloudAccessGuestContinue => 'Continue';

  @override
  String get cloudAccessGuestHeading => 'Shared access';

  @override
  String cloudAccessGuestValidUntil(String time) {
    return 'This session ends $time';
  }

  @override
  String get cloudAccessGuestViewOnly => 'View only';

  @override
  String get cloudAccessGuestInteractive => 'Interactive';

  @override
  String get cloudAccessGuestClipboardOn => 'Clipboard allowed';

  @override
  String get cloudAccessGuestClipboardOff => 'Clipboard off';

  @override
  String get cloudAccessGuestConnect => 'Connect';

  @override
  String get cloudAccessGuestDisconnect => 'Disconnect';

  @override
  String get cloudAccessGuestLeave => 'End my access';

  @override
  String get cloudAccessGuestLeft =>
      'Your access ended. You can close this tab.';

  @override
  String get cloudAccessGuestTrustNote =>
      'This session runs through the sharer\'s Atermius server, which can see it.';

  @override
  String get cloudAccessGuestUnavailable => 'This link is not available.';

  @override
  String get cloudAccessGuestAskOwner =>
      'Ask the person who shared it to send a new link.';

  @override
  String get cloudAccessGuestNotYetValid => 'This link is not valid yet.';

  @override
  String get cloudAccessGuestExpired => 'This link has expired.';

  @override
  String get cloudAccessGuestExhausted => 'This link has already been used.';

  @override
  String get cloudAccessGuestSuspended =>
      'This link was paused or revoked by its owner.';

  @override
  String get cloudAccessGuestSessionEnded => 'Your session has ended.';

  @override
  String get cloudAccessGuestBusy =>
      'Too many connections right now. Try again shortly.';

  @override
  String get cloudAccessGuestExpiringSoon => 'Ends in 5 minutes';

  @override
  String get cloudAccessGuestClosed => 'The connection closed.';

  @override
  String get cloudAccessGuestClosedRevoked =>
      'Access was revoked or changed by the owner.';

  @override
  String get cloudAccessGuestClosedExpired => 'The access time ended.';

  @override
  String get cloudAccessGuestClosedTarget =>
      'The Host could not be reached or did not match its trusted identity.';

  @override
  String get cloudAccessGuestClosedProtocol =>
      'The connection was closed because of an unexpected message.';

  @override
  String cloudAccessApplyRole(String role) {
    return 'Make $role';
  }

  @override
  String get cloudAccessApplyRoleTitle => 'Change this member\'s role?';

  @override
  String cloudAccessApplyRoleMessage(String user, String role) {
    return '$user becomes $role. This signs a new membership manifest and rotates the Vault key from this device.';
  }

  @override
  String get cloudAccessErrorScopeChanged =>
      'The account, server or selected Vault changed during this action. Nothing was sent; try again.';

  @override
  String get cloudAccessErrorNotSynced =>
      'The sharing Vault was created but is not synchronized yet. Sync it before adding members.';

  @override
  String get cloudAccessErrorScopeEndedCommitted =>
      'The account, server or selected Vault changed after the server had already completed part of this action (for example, created the Vault or the invitation). That part was not undone; review it before trying again.';

  @override
  String get directDesktopSignInHint =>
      'Sign-in details are stored encrypted. This device connects directly to the Host and uses them only for that connection; no gateway is involved.';

  @override
  String get keybarCtrlGuidance =>
      'Ctrl: tap for the next key only, double-tap to lock';

  @override
  String get keybarAltGuidance =>
      'Alt: tap for the next key only, double-tap to lock';

  @override
  String get keybarModifierOff => 'Off';

  @override
  String get keybarModifierArmed => 'Next key only';

  @override
  String get keybarModifierLocked => 'Locked';

  @override
  String get keybarPinExpanded => 'Keep extra keys open';

  @override
  String get mcpAccessModeDenied => 'Denied';

  @override
  String get mcpAccessModeReadOnly => 'Read-only';

  @override
  String get mcpAccessModeReadWrite => 'Read & write';

  @override
  String get mcpAccessModeDeniedDescription =>
      'External AI can\'t see or use the machine. It\'s left out of host and session lists.';

  @override
  String get mcpAccessModeReadOnlyDescription =>
      'External AI can list the machine and read output and files of sessions that are already open. It can\'t connect, type, run commands or change files.';

  @override
  String get mcpAccessModeReadWriteDescription =>
      'External AI can also connect, focus and close sessions, send terminal input, run commands and write files. Host key and sign-in prompts still appear.';

  @override
  String get mcpMachineAccessTitle => 'Machine access';

  @override
  String get mcpMachineAccessDescription =>
      'Choose what external AI may do on each machine. These settings are kept on this device for the current workspace and aren\'t synced. Stopping MCP revokes all access, whatever is chosen here.';

  @override
  String get mcpDefaultAccessTitle => 'Default for all machines';

  @override
  String get mcpDefaultAccessDescription =>
      'Applies to every machine without its own setting, including machines added later.';

  @override
  String get mcpPerMachineTitle => 'Per-machine settings';

  @override
  String mcpCustomizedCount(int count) {
    return 'Machines with their own setting: $count';
  }

  @override
  String get mcpLocalDeviceName => 'This device (local console)';

  @override
  String get mcpLocalDeviceDetail =>
      'Local terminal sessions that aren\'t tied to a saved host';

  @override
  String mcpHostUseDefault(String mode) {
    return 'Default ($mode)';
  }

  @override
  String get mcpHostCustom => 'Custom';

  @override
  String mcpHostAccessFor(String name) {
    return 'Access for $name';
  }

  @override
  String get mcpSearchMachines => 'Search machines';

  @override
  String mcpNoMachinesMatch(String query) {
    return 'No machines match “$query”.';
  }

  @override
  String get mcpNoSavedMachines => 'No saved hosts in this workspace yet.';

  @override
  String mcpShowMoreMachines(int count) {
    return 'Show $count more';
  }

  @override
  String get mcpAccessLoading => 'Loading machine access settings…';

  @override
  String get mcpAccessUnavailable =>
      'Machine access settings aren\'t available right now. Until they load, external AI is denied on every machine.';

  @override
  String get mcpAccessSaveFailed =>
      'Couldn\'t save the access setting. Try again.';

  @override
  String get mcpConfirmReadWriteDefaultTitle =>
      'Allow read & write on all machines?';

  @override
  String get mcpConfirmReadWriteDefaultBody =>
      'Any AI holding the connection token could connect to, type into, run commands on and change files on every machine without its own setting, including machines added later. Host key and sign-in prompts still appear.';

  @override
  String get mcpConfirmReadWriteDefaultConfirm => 'Allow read & write';

  @override
  String mcpRunningDefaultAccess(String mode) {
    return 'Running · Default: $mode';
  }

  @override
  String get mcpAndroidForwardingHint =>
      'MCP listens only on this device\'s loopback address. To use it from AI on a computer connected with USB debugging, run this on the computer, then use the copied configuration there:';

  @override
  String get mcpAndroidBackgroundHint =>
      'While MCP runs, Atermius shows a notification so external AI can keep using it after you switch apps. Stopping it from the notification, locking or signing out revokes the token. If the notification can\'t be shown, MCP stops when you leave the app.';

  @override
  String get mcpForegroundNotificationTitle => 'External AI access is on';

  @override
  String mcpForegroundNotificationText(int port) {
    return 'MCP is listening on 127.0.0.1:$port. Stop it to revoke the access token.';
  }

  @override
  String get mcpForegroundNotificationStop => 'Stop MCP';

  @override
  String get mcpAndroidProtected =>
      'Background access is protected by the MCP notification.';

  @override
  String get mcpAndroidForegroundOnly =>
      'MCP works while this app is visible. Leaving the app revokes access.';

  @override
  String get mcpAndroidStarting => 'Starting Android background protection…';

  @override
  String get desktopKeyboardShow => 'Open keyboard and special keys';

  @override
  String get desktopKeyboardHide => 'Hide keyboard and special keys';

  @override
  String get desktopTouchMode => 'Touch input';

  @override
  String get desktopTrackpadMode => 'Trackpad (mouse)';

  @override
  String get enterFullscreen => 'Enter fullscreen';

  @override
  String get exitFullscreen => 'Exit fullscreen';

  @override
  String get fullscreenUnavailable =>
      'Fullscreen is unavailable for this window.';

  @override
  String get restoreConnection => 'Restore connection';

  @override
  String get reconnectEveryFiveSeconds =>
      'Reconnect automatically every 5 seconds';

  @override
  String get desktopKeyboardModeTitle => 'Remote desktop keyboard mode';

  @override
  String get desktopKeyboardOverlay => 'Overlay (keep resolution)';

  @override
  String get desktopKeyboardResize => 'Resize to keyboard';

  @override
  String get desktopKeyboardOverlayDescription =>
      'Show the keyboard and special keys over the desktop without changing its resolution or scaling.';

  @override
  String get desktopKeyboardResizeDescription =>
      'Shrink the desktop to the space above the keyboard. Window-following sessions also update the remote resolution.';

  @override
  String get desktopKeyboardSaveFailed =>
      'This choice applies now, but could not be saved. Try again.';
}
