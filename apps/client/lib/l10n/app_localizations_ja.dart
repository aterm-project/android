// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get languageSystemDefault => 'システムの既定';

  @override
  String get languageSettingTitle => '言語';

  @override
  String get languageSettingDescription =>
      'このデバイスの表示言語を選択します。「システムの既定」はデバイスの言語に従い、対応していない場合は英語で表示します。';

  @override
  String languageSettingSystemResolved(Object language) {
    return 'システムの既定 · 現在は$language';
  }

  @override
  String get languageSettingSaveFailed =>
      '言語はこのセッションで切り替わりましたが、このデバイスに保存できませんでした。';

  @override
  String get languageSettingDevicePreference =>
      'このデバイスにのみ保存されます。同期されず、保管庫にも保存されません。';

  @override
  String tabSemanticsLabel(Object title, Object status, Object selection) {
    return '$title ターミナルタブ、$status、$selection';
  }

  @override
  String get tabSemanticsConnected => '接続済み';

  @override
  String get tabSemanticsDisconnected => '未接続';

  @override
  String get tabSemanticsActive => 'アクティブ';

  @override
  String get tabSemanticsInactive => '非アクティブ';

  @override
  String mfaChallengeTotp(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return '続行するには、認証アプリの 6 桁のコードを入力してください。このチャレンジは $expiresAtString に期限切れになります。';
  }

  @override
  String mfaChallengeRecovery(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return '続行するには、使い捨ての復旧コードを入力してください。このチャレンジは $expiresAtString に期限切れになります。';
  }

  @override
  String get propertyAuthentication => '認証';

  @override
  String get propertyStatus => '状態';

  @override
  String get propertyRoute => '経路';

  @override
  String get propertyTags => 'タグ';

  @override
  String keyEpochLocalMismatch(int epoch) {
    return '鍵エポック $epoch に、このデバイス上で異なるローカルの鍵が対応しています。';
  }

  @override
  String get recoveryCodeCopiedFeedback => '復旧コードをコピーしました。';

  @override
  String get recoveryCodeCopyFailedFeedback =>
      '復旧コードをコピーできませんでした。手動で選択してコピーしてください。';

  @override
  String sessionsRevokedForSelectedAccount(int count) {
    return '選択したアカウントのセッションを $count 件失効させました。';
  }

  @override
  String get usernameOptional => 'ユーザー名（任意）';

  @override
  String get forwardRuntimeUnsupported =>
      'このプラットフォームでは SSH ポートフォワーディングを実行できません。';

  @override
  String get forwardRuntimeDisconnected =>
      '未接続です。プロファイルは今すぐ編集できます。開始するには、このホストに SSH で接続してください。';

  @override
  String get forwardRuntimeRunningNote =>
      '実行中の転送はこのデバイス上に残り、この SSH 接続が終了すると自動的に停止します。';

  @override
  String forwardStatusRunning(int active, int total) {
    return '実行中 · アクティブ $active 件 · 合計 $total 件';
  }

  @override
  String get forwardStatusStopping => '停止しています…';

  @override
  String get forwardStatusStopped => '停止済み';

  @override
  String forwardStatusFailed(Object error) {
    return '失敗：$error';
  }

  @override
  String get forwardStatusUnknownError => '不明なエラー';

  @override
  String forwardExposureLocal(Object bind, Object destination) {
    return '$bind に到達できるネットワーク上の他のデバイスは、あなたの SSH ログインを経由して $destination に接続できるようになります。';
  }

  @override
  String forwardExposureDynamic(Object bind) {
    return '$bind に到達できる他のデバイスは、あなたの SSH ログインを経由して認証のない SOCKS プロキシを使用できるようになります。';
  }

  @override
  String forwardExposureRemoteLoopback(Object destination) {
    return 'SSH サーバーに届いた接続は、このデバイスによって $destination に中継されます。';
  }

  @override
  String forwardExposureRemotePublic(Object destination) {
    return 'SSH サーバーに届いた接続は、このデバイスによって $destination に中継されます。また、サーバーは他のマシンからの接続を受け付ける場合があります。';
  }

  @override
  String forwardRemoteListenerRejected(Object endpoint) {
    return 'SSH サーバーは $endpoint でのリスナーを拒否しました。サーバー上でポートが使用中か、AllowTcpForwarding/PermitListen で禁止されている可能性があります。';
  }

  @override
  String forwardLocalDestinationUnreachable(Object endpoint) {
    return 'このデバイスは $endpoint に接続できませんでした。';
  }

  @override
  String get keybarMore => 'その他';

  @override
  String get keybarLess => '閉じる';

  @override
  String get invalidAttachedFileOwner => '添付されたファイルの所有セッションが無効です。';

  @override
  String get unexpectedWindowCombinationOwnerField => '予期しない所有者フィールドがあります。';

  @override
  String get fileSessionSshOwnerMissingFromWindowSet =>
      'ファイルセッションの SSH 所有セッションがウィンドウセットに含まれていません。';

  @override
  String get terminalStateConnected => '接続済み';

  @override
  String get terminalStateConnecting => '接続中';

  @override
  String get terminalStateReconnecting => '再接続中';

  @override
  String get terminalStateDisconnected => '切断';

  @override
  String get terminalStateClosed => '閉じました';

  @override
  String get terminalStateEnded => '終了';

  @override
  String get terminalStateFailed => '失敗';

  @override
  String get sshPasswordLabel => 'SSH パスワード';

  @override
  String get passwordOptionalLabel => 'パスワード（任意）';

  @override
  String quotedHostName(Object name) {
    return 'ホスト「$name」';
  }

  @override
  String hostsReferenceUnavailableGroups(int count) {
    return '$count 台のホストが利用できないグループを参照しています。影響を受けるホストを編集し、現在のグループを選ぶか、明示的に「グループなし」を選択してください。';
  }

  @override
  String pendingCountShort(int count) {
    return '保留中 $count 件';
  }

  @override
  String get purgeConsentEnabled => '有効';

  @override
  String get purgeConsentOff => 'オフ';

  @override
  String get restoreDeadlineStatusUnavailable => '復元期限の状態：利用不可';

  @override
  String get restoreDeadlineStatusPassed =>
      '復元期限の状態：このデバイスの時計では期限切れ。最終的な判断はサーバーが行います';

  @override
  String restoreDeadlineStatusFuture(DateTime deadline) {
    final intl.DateFormat deadlineDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String deadlineString = deadlineDateFormat.format(deadline);

    return '復元期限の状態：期限前、$deadlineString';
  }

  @override
  String get groupParentNeedsRepair => '親子関係の修復が必要です';

  @override
  String groupInsideParent(Object parent) {
    return '$parent の中';
  }

  @override
  String groupHostCount(int count) {
    return 'ホスト $count 台';
  }

  @override
  String groupSubgroupCount(int count) {
    return 'サブグループ $count 個';
  }

  @override
  String get groupDefaultCredentialUnavailable => '既定の認証情報を利用できません';

  @override
  String groupDefaultCredentialName(Object name) {
    return '既定の認証情報：$name';
  }

  @override
  String get credentialPasswordStoredEncrypted => 'パスワードは暗号化して保存されています';

  @override
  String get credentialPrivateKeyStoredEncrypted => '秘密鍵は暗号化して保存されています';

  @override
  String get splitAxisSideBySide => '左右に並べる';

  @override
  String get splitAxisStacked => '上下に並べる';

  @override
  String get execCancelledUnknown => 'キャンセルしました。リモートでの完了状態は不明で、コマンドは再試行していません。';

  @override
  String get execOpenTimedOut =>
      'SSH exec のリクエストの待機がタイムアウトしました。再試行する前に切断して再接続してください。リモートでの完了は不明です。';

  @override
  String get execTimedOutUnknown => 'タイムアウトしました。リモートでの完了状態は不明で、コマンドは再試行していません。';

  @override
  String get execOutputTruncated =>
      '出力が上限の 64 KiB を超えました。exec チャネルを閉じました。完了状態は不明です。';

  @override
  String get execBashUnavailable =>
      'この接続先には Bash がないか、ログインシェルが POSIX 互換ではありません。スニペットの内容は実行されていません。';

  @override
  String unableToReviewHostConnectionSettings(Object error) {
    return 'ホストの接続設定を確認できません：$error';
  }

  @override
  String get adminJobBackupCompleted => 'サーバーで暗号化バックアップが完了しました';

  @override
  String get adminJobBackupFailed => '暗号化バックアップに失敗しました。サーバーのバックアップ設定を確認してください';

  @override
  String get adminJobBackupInterrupted => '暗号化バックアップのジョブが中断されました';

  @override
  String get adminJobRestorePrepared => '隔離された復元用コピーを準備しました。有効化はされていません';

  @override
  String get adminJobRestoreFailed => '隔離された復元用コピーの準備に失敗しました。稼働中のデータは変更されていません';

  @override
  String get adminJobRestorePreparedStatusInterrupted =>
      '復元用コピーは準備できましたが、ジョブの状態の更新が中断されました';

  @override
  String get adminJobRestoreInterrupted => '隔離された復元用コピーの準備が中断されました';

  @override
  String get adminJobMaintenanceFailed =>
      'メンテナンスに失敗しました。再試行する前にサーバーの状態を確認してください';

  @override
  String get adminJobMaintenanceInterrupted =>
      'メンテナンスが中断されました。再試行する前にジョブ一覧を更新してください';

  @override
  String adminJobResultCode(Object code) {
    return '結果 $code';
  }

  @override
  String get masterPasswordChangedSessionsRevoked =>
      'マスターパスワードを変更しました。他のセッションは失効しました。';

  @override
  String get masterPasswordChangeConfirmedSessionsRevoked =>
      'マスターパスワードの変更を確認しました。他のセッションは失効しました。';

  @override
  String confirmRemoveMemberAndRotate(Object username) {
    return '$username を削除し、残りのすべてのアクティブなメンバーデバイスの保管庫鍵を更新しますか？削除されたアカウントには新しい鍵は渡されません。既存の古いコピーをリモートで消去することはできません。保留中の他の招待トークンは無効になり、再発行が必要です。';
  }

  @override
  String confirmCancelInvitationAndRotate(Object username) {
    return '$username への保留中の招待を取り消し、残りのすべてのアクティブなメンバーデバイスの保管庫鍵を更新しますか？削除されたアカウントには新しい鍵は渡されません。既存の古いコピーをリモートで消去することはできません。保留中の他の招待トークンは無効になり、再発行が必要です。';
  }

  @override
  String recycleBinPurgeConsentLine(Object consent) {
    return '$consent。';
  }

  @override
  String recycleBinPurgeConsentLineOwner(Object consent) {
    return '$consent。同意はこの削除マーカーにのみ適用されます。有効にすると、制限付きのメンテナンスが復元期限とその他の必要なチェックの後に完全削除する場合があります。同意しても直ちには削除されず、オフラインのデバイスのコピーやエクスポートしたファイルは削除されません。';
  }

  @override
  String get objectDownloadFailed => 'オブジェクトのダウンロードに失敗しました。';

  @override
  String get objectRangeDownloadFailed => 'オブジェクトの範囲ダウンロードに失敗しました。';

  @override
  String get requestFailed => 'リクエストに失敗しました。';

  @override
  String get theServerReturnedAnInvalidResponse => 'サーバーが無効な応答を返しました。';

  @override
  String consoleExitedCode(int code) {
    return '\n[コンソールが終了しました：$code]\n';
  }

  @override
  String get thisDevicesSecureStorageCouldntDelete =>
      ' このデバイスのセキュアストレージから古いリフレッシュトークンを削除できませんでしたが、トークンはサーバーで失効しています。';

  @override
  String get someLocalStateCleanupHitAn =>
      ' ローカルの状態の一部をクリーンアップする際にエラーが発生したため、アプリは現在のセッションを強制的にサインアウトしました。';

  @override
  String get aVaultRecoveryContextHasNo =>
      '保管庫の復旧コンテキストに有効な署名済みのメンバーシップのバージョンがありません。';

  @override
  String get aCommandSnippetIsAlreadyRunning => 'すでにコマンドスニペットが実行中です。';

  @override
  String get aDisabledRecoveryAccountReturnedActive =>
      '復旧が無効なアカウントから有効な復旧情報が返されました。';

  @override
  String get aNewRecoveryKeyboxFailedIts =>
      '新しい復旧用キーボックスがローカルでのチェックに合格しませんでした。';

  @override
  String get aNewDeviceKeyEnvelopeFailed =>
      '新しいデバイスの鍵エンベロープがローカルでのチェックに合格しませんでした。';

  @override
  String get aPreviousSshExecRequestIs =>
      '前の SSH exec のリクエストがまだ保留中です。切断して再接続してから、別のコマンドを実行してください。';

  @override
  String get aRecoveryConfirmationIsAlreadyPending => '確認待ちの復旧がすでにあります。';

  @override
  String get aReferencedSnippetCredentialChangedAfter =>
      '確認後に参照しているスニペットの認証情報が変更されました。一括処理全体を再確認してください。';

  @override
  String get aRequiredVaultKeyCouldNot =>
      '必要な保管庫の鍵を復旧できませんでした。復旧の状態を確認し、登録済みのデバイスでお試しください。';

  @override
  String get aSelectedHostConnectionOrSnippet =>
      '確認後に選択したホスト、接続、またはスニペットが変更されました。一括処理全体を再確認してください。';

  @override
  String get accountRecoveredSignInWithThe2 =>
      'アカウントを復旧しました。このデバイスで新しいマスターパスワードを使ってサインインしてください。';

  @override
  String get accountRecoveryIsBusy => 'アカウントの復旧を処理中です。';

  @override
  String get accountRelayPolicyResetToInherit => 'アカウントのリレーポリシーを継承にリセットしました。';

  @override
  String get accountRelayPolicySaved => 'アカウントのリレーポリシーを保存しました。';

  @override
  String accountStatusUpdatedToStatusRevokedsessions(
    String status,
    int revokedSessions,
  ) {
    return 'アカウントの状態を $status に更新しました。$revokedSessions 件のセッションを失効させました。';
  }

  @override
  String get anExistingRecoveryKeyboxCouldNot =>
      '既存の復旧用キーボックスを検証または開封できません。唯一の復旧用コピーを失う更新は拒否します。';

  @override
  String get bashExecutionRequiresACancellationHandle =>
      'Bash の実行にはキャンセル用のハンドルが必要です。';

  @override
  String get batchExecutionIsOnlySupportedFor =>
      '一括実行は構造化 Bash スニペットにのみ対応しています。';

  @override
  String get batchTargetsMustBeDistinctConnected =>
      '一括処理の対象は、それぞれ異なる接続済みのホストである必要があります。';

  @override
  String get bucketAccessVerifiedWithHeadbucketThis =>
      'HeadBucket でバケットへのアクセスを確認しました。このチェックでは、アップロード、マルチパート操作、復元、プロバイダー全体の互換性は検証しません。';

  @override
  String chooseBetweenTwoAndMaxterminaltabsConnected(int maxTerminalTabs) {
    return '接続済みのホストを 2〜$maxTerminalTabs 台選択してください。';
  }

  @override
  String get commandExecutionIsUnavailableNoCommand =>
      'コマンドを実行できません。コマンドは送信されていません。';

  @override
  String get conflictingSignedRecoveryKeyboxesExistFor =>
      '保管庫のエポックに競合する署名済みの復旧用キーボックスがあります。';

  @override
  String get connectThisTerminalBeforeEnablingShell =>
      'シェル連携を有効にする前に、このターミナルを接続してください。';

  @override
  String get connectToTheServerBeforeChecking =>
      'バックアップバケットへのアクセスを確認する前にサーバーに接続してください。';

  @override
  String get theConsoleOutputStreamClosed => 'コンソールの出力ストリームが閉じられました。';

  @override
  String get couldNotDisableBackgroundSyncNotifications =>
      'バックグラウンド同期の通知を無効にできませんでした。';

  @override
  String get couldNotEnableBackgroundSyncNotifications =>
      'バックグラウンド同期の通知を有効にできませんでした。';

  @override
  String get couldNotPersistTheMobilePush => 'モバイルプッシュのオプトアウトを保存できませんでした。';

  @override
  String get couldNotRemoveThisDevicesPush => 'このデバイスのプッシュエンドポイントを削除できませんでした。';

  @override
  String credentialReferenceNameIsMissingOr(String name) {
    return '認証情報の参照 $name が見つからないか、パスワード認証情報ではありません';
  }

  @override
  String get currentAccountSessionExpired => '現在のアカウントのセッションは期限切れです。';

  @override
  String get enterTheAccountName => 'アカウント名を入力してください。';

  @override
  String get groupRelayPolicyResetToInherit => 'グループの Relay ポリシーを継承にリセットしました。';

  @override
  String get groupRelayPolicySaved => 'グループの Relay ポリシーを保存しました。';

  @override
  String get groupDefault => 'グループの既定値';

  @override
  String get groupDefaultIsUnavailableChooseA =>
      'グループの既定値は利用できません。ホストの上書きを選択するか、グループの既定値を修復してください。';

  @override
  String get groupMembershipSaved => 'グループのメンバーシップを保存しました。';

  @override
  String get hostChangedRepeatedlyWhileSavingReopen =>
      '保存中にホストが繰り返し変更されました。開き直してから再試行してください。';

  @override
  String get hostIdentityChangedWhileTheEditor =>
      'エディターを開いている間にホストの ID が変更されました。';

  @override
  String get hostOverrideIsUnavailableChooseInherit =>
      'ホストの上書きは利用できません。「グループから継承」または別の認証情報を選択してください。';

  @override
  String hostOverrideIdentity(String identity) {
    return 'ホストの上書き：$identity';
  }

  @override
  String get theHostsTagsFieldWasAlso =>
      '編集中にホストの「タグ」フィールドも変更されました。開き直して確認してから、もう一度お試しください。';

  @override
  String theHostsLabelFieldWasAlso(String label) {
    return '編集中にホストの「$label」フィールドも変更されました。開き直して確認してから、もう一度お試しください。';
  }

  @override
  String inheritedFromValuevalueIdentity(String valueValue, String identity) {
    return '$valueValue から継承：$identity';
  }

  @override
  String get instanceAdminAccessIsRequiredTo =>
      'バックアップバケットへのアクセスを確認するには、インスタンス管理者の権限が必要です。';

  @override
  String get invalidAdminVaultPaginationResponse => '管理者用の保管庫のページング応答が無効です。';

  @override
  String get invalidAdminAccountInvitationPaginationResponse =>
      '管理者用のアカウント招待のページング応答が無効です。';

  @override
  String get invalidAdminAccountPaginationResponse =>
      '管理者用のアカウントのページング応答が無効です。';

  @override
  String get invalidAdminAccountSessionsPaginationResponse =>
      '管理者用のアカウントのセッションのページング応答が無効です。';

  @override
  String get invalidAdminMaintenancePaginationResponse =>
      '管理者用のメンテナンスのページング応答が無効です。';

  @override
  String get invalidMobilePushToken => 'モバイルプッシュのトークンが無効です。';

  @override
  String get invalidRestoreJobReceipt => '復元ジョブの受領情報が無効です。';

  @override
  String get invalidRestoreSourcePageResponse => '復元元のページ応答が無効です。';

  @override
  String invitationCreatedForUsername(String username) {
    return '$username への招待を作成しました。';
  }

  @override
  String get invitationRevoked => '招待を取り消しました。';

  @override
  String jumpHostCredentialForHostnameChanged(String hostName) {
    return '送信前に $hostName の踏み台ホストの認証情報が変更されました。残りの一括処理は停止しました。';
  }

  @override
  String jumpHostRoutingForHostnameChanged(String hostName) {
    return '送信前に $hostName の踏み台ホストの経路が変更されました。一括処理を再確認してください。';
  }

  @override
  String couldntResolveTheSshCredentialFor(
    String name,
    String connectionError,
  ) {
    return '踏み台ホスト $name の SSH 認証情報を解決できません：$connectionError';
  }

  @override
  String get theJumpHostMustUseThe => '踏み台ホストは SSH プロトコルを使用する必要があります。';

  @override
  String get theJumpHostRouteChangedWhile =>
      '接続の準備中に踏み台ホストの経路が変更されました。再接続してください。';

  @override
  String get theJumpHostRouteOrCredential =>
      '接続の準備中に踏み台ホストの経路または認証情報が変更されました。再接続してください。';

  @override
  String get theJumpHostChainCantForm => '踏み台ホストのチェーンを循環させることはできません。';

  @override
  String get theJumpHostChainContainsA =>
      '踏み台ホストのチェーンに、もう存在しないホストが含まれています。編集してこの参照を修復してください。';

  @override
  String theJumpHostChainSupportsUp(int maxJumpHostHops) {
    return '踏み台ホストのチェーンは最大 $maxJumpHostHops 段まで対応しています。';
  }

  @override
  String get loadAConsistentAccountAndInstance =>
      'リセットする前に、一貫したアカウントとインスタンスのポリシーを読み込んでください。';

  @override
  String get loadAConsistentAccountAndInstance2 =>
      '保存する前に、一貫したアカウントとインスタンスのポリシーを読み込んでください。';

  @override
  String get loadTheLatestSshRelayPolicy => '保存する前に最新の SSH リレーのポリシーを読み込んでください。';

  @override
  String get theMfaSignInResponseDoesnt =>
      'MFA サインインの応答が現在のアカウントまたはデバイスと一致しません。';

  @override
  String get mfaSettingsAreBeingProcessed => 'MFA の設定を処理中です。';

  @override
  String get mfaVerificationFailedTheCodeIs =>
      'MFA の確認に失敗しました：コードが無効か使用済みであるか、サインインのチャレンジが期限切れです。もう一度サインインして新しいコードを入力してください。';

  @override
  String get mfaVerifiedAndUnlockedLocallyThe =>
      'MFA の確認が完了し、ローカルでロックを解除しました。サーバーに保存されるのは引き続き暗号化レコードと鍵エンベロープのみです。';

  @override
  String get mustBeBetween0And1000000 => '0〜1000000 の範囲で指定してください。';

  @override
  String get mustNotBeNegative => '負の値にはできません。';

  @override
  String get noS3BackupBucketIsConfigured => 'サーバーに S3 のバックアップバケットが設定されていません。';

  @override
  String get noSshCredentialIsConfiguredChoose =>
      'SSH 認証情報が設定されていません。ホストの上書きを選択するか、グループの既定値を設定してください。';

  @override
  String get noAccountRecoveryIsAwaitingConfirmation => '確認待ちのアカウントの復旧はありません。';

  @override
  String get noAuthenticatedSession => '認証済みのセッションがありません。';

  @override
  String get noEffectiveSshCredentialIsSet =>
      '有効な SSH 認証情報が設定されていません。ホストの上書きを選択するか、グループの既定値を設定してください。';

  @override
  String get notStartedBecauseBatchCancellationWas =>
      '事前チェック中に一括処理のキャンセルがリクエストされたため、開始していません。';

  @override
  String get notStartedBecauseBatchCancellationWas2 =>
      '一括処理のキャンセルがリクエストされたため、開始していません。';

  @override
  String get notStartedBecauseThePreviousHost => '前のホストが正常に完了しなかったため、開始していません。';

  @override
  String get notStartedBecauseThePreviousHost2 =>
      '前のホストが検証または実行に失敗したため、開始していません。';

  @override
  String get offlineKnownhostApprovalIsLimitedTo =>
      'オフラインでの KnownHost の承認は、ローカルの信頼や失効の履歴がない初回のエンドポイントに限られます。';

  @override
  String get offlineKnownhostQueueDidNotMatch =>
      'オフラインの KnownHost のキューが、明示的に確認した SSH 鍵と一致しませんでした。';

  @override
  String get prometheusScrapeCredentialRevoked =>
      'Prometheus のスクレイプ認証情報を失効させました。';

  @override
  String get rdpCertificate => 'RDP 証明書';

  @override
  String get recoveryCouldNotBeStartedCheck =>
      '復旧を開始できませんでした。アカウント名とコードを確認してください。';

  @override
  String get recoveryDescriptorHashIsInvalid => '復旧記述子のハッシュが無効です。';

  @override
  String get recoveryDescriptorPublicKeysDoNot =>
      '復旧記述子の公開鍵がラップされた ID と一致しません。';

  @override
  String get recoveryIdentityEnvelopeIsMissing => '復旧用 ID のエンベロープがありません。';

  @override
  String get referencedCredentialChangedAfterPreviewReview =>
      'プレビュー後に参照している認証情報が変更されました。コマンドを確認してから再試行してください。';

  @override
  String get reloadTheLatestAccountAndInstance =>
      'リセットする前に、最新のアカウントとインスタンスのポリシーを再読み込みしてください。';

  @override
  String get reloadTheLatestAccountAndInstance2 =>
      '保存する前に、最新のアカウントとインスタンスのポリシーを再読み込みしてください。';

  @override
  String get reloadTheLatestGroupAndInstance =>
      'リセットする前に、最新のグループとインスタンスのポリシーを再読み込みしてください。';

  @override
  String get reloadTheLatestGroupAndInstance2 =>
      '保存する前に、最新のグループとインスタンスのポリシーを再読み込みしてください。';

  @override
  String get reloadTheLatestPolicyAfterThe =>
      'リビジョンの競合後は、最新のポリシーを再読み込みしてから再試行してください。';

  @override
  String get restoreIsEncryptedAndQueuedOn =>
      '復元は暗号化されてこのデバイスのキューに追加されました。同期の状態は再試行されます。';

  @override
  String get restoreIsEncryptedLocallyAndWaiting => '復元はローカルで暗号化され、同期を待っています。';

  @override
  String get restoreIsSafelyQueuedOnThis =>
      '復元はこのデバイスで安全にキューに追加され、サーバーに接続できるようになると再試行されます。';

  @override
  String get restoreStageResponseDidNotMatch => '復元のステージの応答が一致しません。';

  @override
  String get retryThePendingAccountRecoveryCompletion =>
      'サインインする前に、保留中のアカウント復旧の完了を再試行してください。';

  @override
  String get theSftpDocumentBelongsToA => 'この SFTP ドキュメントは別の SSH セッションのものです。';

  @override
  String get theSftpServerVersionDoesntSupport =>
      'SFTP サーバーのバージョンは安全なファイルのアップロードに対応していません。';

  @override
  String get theSftpServerVersionIsBelow =>
      'SFTP サーバーのバージョンが 3 未満のため、安全なテキスト編集に対応していません。';

  @override
  String sshCredentialForHostnameChangedBefore(String hostName) {
    return '送信前に $hostName の SSH 認証情報が変更されました。残りの一括処理は停止しました。';
  }

  @override
  String get sshConnectionOrHostChangedAfter =>
      'プレビュー後に SSH 接続またはホストが変更されました。対象を確認してから再試行してください。';

  @override
  String get sshExecFailedAfterDispatchRemote =>
      'SSH exec は送信後に失敗しました。リモートでの完了状態は不明で、コマンドは再試行していません。';

  @override
  String get sshHostKeyApprovalProofAccount =>
      'SSH ホスト鍵の承認の証明のアカウントまたは保管庫の範囲が変更されました。';

  @override
  String get sshHostKeyTestDecisionBecame => 'SSH ホスト鍵のテストの判断が古くなりました。';

  @override
  String sshHostKeyTrustChangedFor(String hostName) {
    return '$hostName の SSH ホスト鍵の信頼が変更されました。再接続して一括処理を再確認してください。';
  }

  @override
  String sshHostKeyVerificationEvidenceIs(String hostName) {
    return '$hostName の SSH ホスト鍵の検証証拠がありません。一括処理を実行する前に再接続してください。';
  }

  @override
  String get sshRelayPolicySaved => 'SSH リレーのポリシーを保存しました。';

  @override
  String get sshHostKeyTrustWasConfirmed => 'SSH ホスト鍵の信頼が現在の保管庫での同期により確認されました。';

  @override
  String get sshHostKeyTrustWasRevoked =>
      'SSH ホスト鍵の信頼を取り消し、現在の保管庫に暗号化して保存しました。';

  @override
  String get theSshHostKeyApprovalWas =>
      'SSH ホスト鍵の承認を暗号化してキューに追加し、現在の接続を停止しました。保管庫の同期で確認された後に接続してください。';

  @override
  String get theSshHostOrJumpHost =>
      'SSH ホストまたは踏み台ホストの経路が変更されました。再接続してから、もう一度お試しください。';

  @override
  String get theSshHostSettingsChangedReconnect =>
      'SSH ホストの設定が変更されました。現在のワークスペースのペインを再接続してください。';

  @override
  String get sshSessionClosed => 'SSH セッションが閉じられました';

  @override
  String get sshCredentials2 => 'SSH の認証情報';

  @override
  String get theSshCredentialWasSavedEncrypted =>
      'SSH の認証情報を暗号化して保存し、ローカルの同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get sshCredentialSavedEncryptedPlaintextIs =>
      'SSH の認証情報を暗号化して保存しました。平文はロック解除されたセッション内にのみ保持されます。';

  @override
  String get theSshCredentialChangedReconnectThe =>
      'SSH の認証情報が変更されました。現在のワークスペースのペインを再接続してください。';

  @override
  String get theSshCredentialOrHostSettings =>
      'SSH の認証情報またはホストの設定が変更されました。現在のワークスペースのペインを再接続してください。';

  @override
  String get sshStoppedTheFirstHostKey =>
      'SSH を停止しました：初回のホスト鍵の承認が暗号化されてキューに追加されました。保管庫の同期で確認された後に再接続してください。';

  @override
  String sshConnectedToEndpoint(String endpoint) {
    return '$endpoint に SSH で接続しました。';
  }

  @override
  String get sshSignInDetails => 'SSH のサインイン情報';

  @override
  String get theSshTerminalIsClosedSo => 'SSH ターミナルが閉じているため、入力操作を付与できません。';

  @override
  String get theSshConnectionClosedReconnectThe =>
      'SSH 接続が閉じられました。現在のワークスペースのペインを再接続してください。';

  @override
  String get selectAVaultBeforeResolvingThis => 'この認証情報を解決する前に保管庫を選択してください。';

  @override
  String get selectAVaultBeforeResolvingThis2 => 'このホストを解決する前に保管庫を選択してください。';

  @override
  String get selectAnActiveMemberOfThis => 'このサーバー管理のグループのアクティブなメンバーを選択してください。';

  @override
  String get selectedSessionRevoked => '選択したセッションを失効させました。';

  @override
  String get selectedSessionWasAlreadyRevoked => '選択したセッションはすでに失効しています。';

  @override
  String get serverActivationWasSuperseded => 'サーバーの有効化は別の処理に置き換えられました。';

  @override
  String get serverCommittedTheRotationButThe =>
      'サーバーは更新を確定しましたが、新しいローカルの鍵の状態の検証に失敗しました。';

  @override
  String get serverStateAdvancedUnexpectedlyDuringRotation =>
      '更新の復旧中にサーバーの状態が予期せず進みました。';

  @override
  String get signOutBeforeStartingFullAccount =>
      'アカウントの完全な復旧を開始する前にサインアウトしてください。';

  @override
  String get snippetArgumentsChangedAfterPreviewReview =>
      'プレビュー後にスニペットの引数が変更されました。確認してから再試行してください。';

  @override
  String get snippetArgumentsChangedAfterReviewReview =>
      '確認後にスニペットの引数が変更されました。一括処理全体を再確認してください。';

  @override
  String get snippetDefinitionChangedAfterPreviewReview =>
      'プレビュー後にスニペットの定義が変更されました。確認してから再試行してください。';

  @override
  String get snippetScriptIsEmpty => 'スニペットのスクリプトが空です';

  @override
  String get splitWorkspacesRequireExactlyTwoHosts =>
      '分割ワークスペースにはホストがちょうど 2 台必要です。';

  @override
  String get storedNextRecoveryPackageIsInvalid => '保存済みの次の復旧パッケージが無効です。';

  @override
  String get storedRecoveryChallengeIsInvalid => '保存済みの復旧のチャレンジが無効です。';

  @override
  String get storedRecoveryDeviceKeyIsInvalid => '保存済みの復旧用デバイス鍵が無効です。';

  @override
  String get storedRecoveryDeviceProofIsInvalid => '保存済みの復旧用デバイスの証明が無効です。';

  @override
  String get storedRecoveryRequestDoesNotMatch =>
      '保存済みの復旧リクエストがこのサーバーインスタンスと一致しません。';

  @override
  String get theGroupInheritanceChainIsUnavailable =>
      'グループの継承チェーンは利用できません。有効なグループまたはホストの上書きを選択してください。';

  @override
  String get theHostGroupInheritanceChainIs =>
      'ホストのグループ継承チェーンは利用できません。有効なグループまたはホストの認証情報の上書きを選択してください。';

  @override
  String get theHostDidNotReturnA => 'ホストが Bash の実行結果を返しませんでした。';

  @override
  String get theSshExecRequestFailedAfter => 'SSH exec のリクエストは送信後に失敗しました。';

  @override
  String get theAccountNowInheritsTheInstance =>
      'このアカウントはインスタンスのリレーポリシーを継承するようになりました。';

  @override
  String get theEffectiveSshCredentialIsUnavailable =>
      '有効な SSH 認証情報を利用できません。有効なホストの上書きを選択するか、グループの既定値を修復してください。';

  @override
  String get theEnabledRecoveryIdentityHasAn => '有効な復旧用 ID の世代が無効です。';

  @override
  String get theEncryptedSshHostKeyApproval =>
      '暗号化された SSH ホスト鍵の承認を永続的にキューに入れられませんでした。';

  @override
  String get theExistingRecoveryDescriptorDoesNot =>
      '既存の復旧記述子がラップされた ID と一致しません。';

  @override
  String get theGroupNowInheritsTheInstance =>
      'このグループはインスタンスの Relay ポリシーを継承するようになりました。';

  @override
  String get theInstanceRelayPolicyChangedWhile =>
      'このグループの読み込み中にインスタンスの Relay ポリシーが変更されました。一貫したスナップショットを取得するには再読み込みしてください。';

  @override
  String get theInstanceRelayPolicyChangedReload =>
      'インスタンスの Relay ポリシーが変更されました。実効アクセスを確認する前にこのグループを再読み込みしてください。';

  @override
  String get theInstancePolicyChangedWhileResetting =>
      'リセット中にインスタンスのポリシーが変更されました。最新のポリシーを再読み込みしてください。下書きは保持されています。';

  @override
  String get theInstancePolicyChangedWhileSaving =>
      '保存中にインスタンスのポリシーが変更されました。最新のポリシーを再読み込みしてください。下書きは保持されています。';

  @override
  String get theInstanceRelayPolicyChangedWhile2 =>
      'このアカウントのポリシーの読み込み中にインスタンスのリレーポリシーが変更されました。一貫したスナップショットを取得するには再読み込みしてください。';

  @override
  String get theMergedHostRecordIsInvalid => 'マージしたホストのレコードが無効です。';

  @override
  String get theNewMasterPasswordMustContain => '新しいマスターパスワードは 12 文字以上にしてください。';

  @override
  String get theNewMasterPasswordsDoNot => '新しいマスターパスワードが一致しません。';

  @override
  String get theRecoveryChallengeExpiredStartAgain =>
      '復旧のチャレンジが期限切れになりました。最初からやり直してください。';

  @override
  String get theRecoveryCodeOrServerDescriptor => '復旧コードまたはサーバーの記述子が無効です。';

  @override
  String get theRecoveryCompletionReceiptIsInvalid => '復旧完了の受領情報が無効です。';

  @override
  String get theRecoveryResponseDidNotMatch => '復旧の応答がこのアカウントと一致しませんでした。';

  @override
  String get theRelayPolicyChangedElsewhereReload =>
      'リレーのポリシーが別の場所で変更されました。再試行する前に最新の設定を再読み込みしてください。';

  @override
  String theReviewedSshSessionForHostname(String hostName) {
    return '送信前に $hostName の確認済みの SSH セッションが変更されました。';
  }

  @override
  String get theServerCouldNotVerifyAccess =>
      'サーバーは設定済みの S3 バックアップバケットへのアクセスを確認できませんでした。';

  @override
  String get theServerDeploymentDoesNotCurrently =>
      'サーバーのデプロイでは現在このリレー設定は許可されていません。編集内容はここに残っています。デプロイの制限を確認してから再試行してください。';

  @override
  String get theServerOrAuthenticationStateChanged =>
      '復旧中にサーバーまたは認証の状態が変わりました。最初からやり直してください。';

  @override
  String get theServerRestorePeriodHasNot => 'サーバーの復元期間はまだ終了していません。';

  @override
  String get thisSnippetReferencesACredentialThat =>
      'このスニペットが参照する認証情報は現在利用できません。先にその認証情報を復元してください。';

  @override
  String get thisCommandPreviewHasAlreadyBeen => 'このコマンドのプレビューはすでに確定されています。';

  @override
  String get thisRecordTypeCannotBeRestored =>
      'このクライアントのバージョンではこのレコードの種類を復元できません。';

  @override
  String get thisRecoveryCodeBelongsToAnother => 'この復旧コードは別のサーバーインスタンスのものです。';

  @override
  String get thisWorkspaceReferencesAHostThat =>
      'このワークスペースが参照するホストは現在利用できません。先にそのホストを復元してください。';

  @override
  String get tooManySshHostKeyChecks => 'この経路で要求された SSH ホスト鍵のチェックが多すぎます。';

  @override
  String get unableToLoadTheSshRelay =>
      'SSH リレーのポリシーを読み込めません。接続を確認してから再試行してください。';

  @override
  String get unableToSaveTheSshRelay =>
      'SSH リレーのポリシーを保存できません。接続を確認してから再試行してください。';

  @override
  String get vaultChangedWhileSshHostKey => 'SSH ホスト鍵の承認を確認している間に保管庫が変更されました。';

  @override
  String get vaultChangedWhileSshHostKey2 => 'SSH ホスト鍵の承認を保存している間に保管庫が変更されました。';

  @override
  String get vaultChangedWhileSshHostKey3 => 'SSH ホスト鍵の承認を同期している間に保管庫が変更されました。';

  @override
  String get vaultChangedWhileSshHostKey4 => 'SSH ホスト鍵の失効を保存している間に保管庫が変更されました。';

  @override
  String get vaultContainsAnUnsupportedReferenceRecord =>
      '保管庫に対応していない参照レコードの種類が含まれています。';

  @override
  String get vaultContainsDuplicateCredentialIdentities =>
      '保管庫に重複した認証情報の ID が含まれています。';

  @override
  String get vaultKeysAreBeingCleared => '保管庫の鍵を消去しています。';

  @override
  String vaultQuotaUpdatedToQuotabytesBytes(int quotaBytes) {
    return '保管庫のクォータを $quotaBytes バイトに更新しました。';
  }

  @override
  String get vaultReferenceRecordIdentityIsMalformed =>
      '保管庫の参照レコードの ID の形式が正しくありません。';

  @override
  String get vaultSyncDidNotConfirmThe =>
      '保管庫の同期で、確認済みの SSH ホスト鍵の承認が確認されませんでした。';

  @override
  String get vaultSyncDidNotConfirmThis =>
      '保管庫の同期でこの SSH 鍵の承認が確認されませんでした。接続を停止しました。保管庫を同期して鍵を再確認してください。';

  @override
  String get vaultSyncIsUnavailableExistingSsh =>
      '保管庫の同期を利用できません。この接続を続行するには、既存の SSH ホスト鍵の履歴をオンラインで確認する必要があります。';

  @override
  String vaultIdHasConflictingDeviceKeys(String id) {
    return '保管庫 $id の 1 つの鍵エポックに競合するデバイスの鍵があります。';
  }

  @override
  String vaultIdHasNoKeyEnvelope(String id) {
    return '保管庫 $id にアクティブな鍵エポックの鍵エンベロープがありません。';
  }

  @override
  String vaultIdHasNoKeyEnvelope2(String id) {
    return '保管庫 $id に現在のデバイスの鍵エンベロープがありません。';
  }

  @override
  String vaultIdKeyEnvelopeEpochDoes(String id) {
    return '保管庫 $id の鍵エンベロープのエポックがメンバーシップのバージョンと一致しません。';
  }

  @override
  String vaultIdKeyEnvelopeRefersTo(String id) {
    return '保管庫 $id の鍵エンベロープが不明なメンバーシップのバージョンを参照しています。';
  }

  @override
  String vaultIdKeyEnvelopeSignerIs(String id) {
    return '保管庫 $id の鍵エンベロープの署名者は、署名したバージョンのメンバーではありません。';
  }

  @override
  String vaultIdLatestSignedMembershipEpoch(String id) {
    return '保管庫 $id の最新の署名済みメンバーシップのエポックがサーバーの記述と一致しません。';
  }

  @override
  String vaultIdLegacyDisplayNameEnvelope(String id) {
    return '保管庫 $id の旧形式の表示名のエンベロープは、利用可能などのエポック鍵でも開けません。';
  }

  @override
  String vaultIdMembershipDoesNotInclude(String id) {
    return '保管庫 $id のメンバーシップに、このアカウントはアクティブなメンバーとして含まれていません。';
  }

  @override
  String vaultIdSignedDisplayNameEnvelope(String id) {
    return '保管庫 $id の署名済み表示名のエンベロープが無効です。';
  }

  @override
  String theEpochEpochKeyForVault(String id, int epoch) {
    return '保管庫 $id のエポック $epoch の鍵がないため、承認を中止しました。';
  }

  @override
  String theCurrentKeyEpochOfVault(String id) {
    return '保管庫 $id の現在の鍵エポックがこのデバイスにないため、そのデバイスを承認できません。';
  }

  @override
  String theSigningDeviceForVaultId(String id) {
    return '保管庫 $id の署名デバイスが不明なため、鍵エンベロープを検証できません。';
  }

  @override
  String vaultSubstring(String substring) {
    return '保管庫 $substring';
  }

  @override
  String vaultVaultidChangedOwnerWithoutA(String vaultId) {
    return '保管庫 $vaultId は、前のオーナーが署名した移転なしにオーナーが変更されました。';
  }

  @override
  String vaultVaultidHasAnOwnershipTransfer(String vaultId) {
    return '保管庫 $vaultId に新しいオーナーが署名した所有権の移転があります。';
  }

  @override
  String vaultVaultidMembershipHasAnInvalid(String vaultId) {
    return '保管庫 $vaultId のメンバーシップに無効なメンバーが含まれています。';
  }

  @override
  String vaultVaultidMembershipHasNoMembers(String vaultId) {
    return '保管庫 $vaultId のメンバーシップにメンバーがいません。';
  }

  @override
  String vaultVaultidMembershipMustContainExactly(String vaultId) {
    return '保管庫 $vaultId のメンバーシップにはアクティブなオーナーがちょうど 1 人必要です。';
  }

  @override
  String vaultVaultidMembershipSignerIsAbsent(String vaultId) {
    return '保管庫 $vaultId のメンバーシップの署名者がデバイスディレクトリにいません。';
  }

  @override
  String vaultVaultidMembershipWasNotSigned(String vaultId) {
    return '保管庫 $vaultId のメンバーシップはアクティブなオーナーによって署名されていません。';
  }

  @override
  String vaultVaultidOwnershipTransferChangedUnrelated(String vaultId) {
    return '保管庫 $vaultId の所有権の移転で、関係のないメンバーシップのデータが変更されました。';
  }

  @override
  String vaultVaultidOwnershipTransferDoesNot(String vaultId) {
    return '保管庫 $vaultId の所有権の移転が、署名済みのオーナーとエポックのチェーンに従っていません。';
  }

  @override
  String vaultVaultidOwnershipTransferMetadataIs(String vaultId) {
    return '保管庫 $vaultId の所有権の移転のメタデータが無効です。';
  }

  @override
  String vaultVaultidOwnershipTransferUnexpectedlyChanged(String vaultId) {
    return '保管庫 $vaultId の所有権の移転で、メンバーの構成が予期せず変更されました。';
  }

  @override
  String theApprovalKeyEnvelopeSignatureFor(String vaultId) {
    return '保管庫 $vaultId の承認用鍵エンベロープの署名が無効です。';
  }

  @override
  String theApprovedKeyForVaultVaultid(String vaultId) {
    return '保管庫 $vaultId の承認済みの鍵をサーバーの鍵として開封できませんでした。';
  }

  @override
  String theServerKeyEnvelopeForVault(String vaultId) {
    return '保管庫 $vaultId のサーバー側の鍵エンベロープが承認ファイルと一致しません。';
  }

  @override
  String get someActiveDevicesInTheVault =>
      '保管庫内に、スキーマ 2 や 1 GiB の添付ファイルに対応していないアクティブなデバイスがあります。それらのデバイスを更新するか、使わなくなったアクティブなデバイスを保管庫から削除してから、もう一度お試しください。';

  @override
  String get vaultCreationReturnedSuccessButThe =>
      '保管庫の作成は成功しましたが、サーバーはステージされたデータをまだ検証できていません。移行ジャーナルは保持されています。';

  @override
  String get theVaultCreationResultCantBe =>
      '保管庫の作成結果を現在確認できません。移行ジャーナルは保持されているため、後で再開してください。';

  @override
  String get theVaultDeletionGracePeriodHas =>
      '保管庫の削除の猶予期間が終了したため、削除を取り消すことはできません。';

  @override
  String get theVaultDeletionScheduleWasCreated =>
      '保管庫の削除予定を作成しました。サーバーの期限が更新されました。';

  @override
  String get theVaultDeletionScheduleWasCancelled =>
      '保管庫の削除予定を取り消し、書き込み権限を復元しました。';

  @override
  String get theVaultSyncStateIsAbnormal =>
      '保管庫の同期状態に異常があるため、SSH ホスト鍵を安全に確認できません。';

  @override
  String get theVaultNameHasntBeenVerified =>
      '保管庫の名前が鍵で検証されていないため、メンバーの招待の作成を中止しました。';

  @override
  String get theVaultNameHasntBeenVerified2 =>
      '保管庫の名前が鍵で検証されていないため、メンバーの鍵の更新を中止しました。';

  @override
  String get theVaultWasSwitchedWhilePreparing =>
      'ワークスペースの接続の準備中に保管庫が切り替わりました。再接続してください。';

  @override
  String get theVaultKeyStateStillCant =>
      '保管庫の鍵の状態をまだ検証できません。同期待ちのローカルデータは保持されています。';

  @override
  String get youCantSwitchVaultsWhileThe => '保管庫の鍵の更新中は保管庫を切り替えられません。';

  @override
  String get theVaultHasntFinishedFullySyncing =>
      '保管庫の現在のバージョンの完全な同期がまだ終わっていません。同期してから、もう一度お試しください。';

  @override
  String get theVaultWasSwitchedReopenThe =>
      '保管庫が切り替わりました。ホストを開き直してから、もう一度お試しください。';

  @override
  String get theVaultWasSwitchedReopenThe2 =>
      '保管庫が切り替わりました。認証情報を開き直してから、もう一度お試しください。';

  @override
  String get theVaultWasSwitchedReopenThe4 =>
      '保管庫が切り替わりました。グループを開き直してから、もう一度お試しください。';

  @override
  String get theVaultWasSwitchedReopenThe3 => '保管庫が切り替わりました。ごみ箱を開き直してください。';

  @override
  String get theVaultWasSwitchedReopenThe5 =>
      '保管庫が切り替わりました。スニペットを開き直してから、もう一度お試しください。';

  @override
  String get theVaultWasSwitchedThePreference => '保管庫が切り替わったため、設定の修復を一時停止しました。';

  @override
  String get theVaultWasSwitchedCommandHistory =>
      '保管庫が切り替わったため、コマンド履歴の同期は有効になっていません。';

  @override
  String get vaultCreatedItsKeyWasGenerated =>
      '保管庫を作成しました。鍵はこのデバイスで生成・署名されました。';

  @override
  String get theVaultsCurrentEpochOrMembership =>
      '保管庫の現在のエポックまたはメンバーシップのバージョンが無効です。';

  @override
  String get theVaultsCurrentKeyEpochDoesnt =>
      '保管庫の現在の鍵エポックが署名済みのメンバーリストと一致しません。';

  @override
  String get aVaultMemberChangeIsIn => '保管庫のメンバーの変更を処理中です。しばらくしてからもう一度お試しください。';

  @override
  String get localChangesArePausedDuringThe =>
      '保管庫メンバーの鍵の更新中はローカルの変更が一時停止されます。完了後にもう一度お試しください。';

  @override
  String get theVaultMemberKeyRotationIs =>
      '保管庫メンバーの鍵の更新を確定中です。完了してからワークスペースをロックしてください。';

  @override
  String get theVaultMemberKeyRotationIs2 =>
      '保管庫メンバーの鍵の更新を確定中です。完了してからアカウントをロックしてください。';

  @override
  String get vaultMembersOrTheSignedIn =>
      '保管庫のメンバーまたはサインイン中のデバイスが変わりました。オブザーバーのデバイスを選び直してください。';

  @override
  String get invalidVaultMembershipVersionSyncAnd =>
      '保管庫のメンバーシップのバージョンが無効です。同期してから、もう一度お試しください。';

  @override
  String get vaultMembershipChangedUnlockToVerify =>
      '保管庫のメンバーシップが変更されました。ロックを解除して最新の権限と鍵を確認してください。';

  @override
  String get theVaultOrSshConnectionChanged =>
      '保管庫または SSH 接続が変わりました。現在のワークスペースのペインを再接続してください。';

  @override
  String get theVaultOrSignInSession =>
      '保管庫またはサインインセッションが切り替わりました。ごみ箱を開き直してください。';

  @override
  String get theVaultOrSignedInDevice =>
      '保管庫またはサインイン中のデバイスが変わったため、ターミナル共有への参加をキャンセルしました。';

  @override
  String get theVaultOrSignedInDevice2 =>
      '保管庫またはサインイン中のデバイスが変わったため、ターミナル共有への再接続をキャンセルしました。';

  @override
  String get theVaultOrDeviceStateChanged =>
      '保管庫またはデバイスの状態が変わりました。ターミナルの共有を開き直してください。';

  @override
  String get vaultOwnershipWasTransferredThisAccount =>
      '保管庫の所有権を移転しました。このアカウントは編集者のアクセス権を保持し、新しいオーナーと残っているすべてのアクティブなデバイスが新しいエポック鍵を受け取りました。承諾待ちの招待トークンは無効になったため、新しいオーナーが再招待する必要があります。';

  @override
  String get theVaultIsRestoringOrChanging =>
      '保管庫で復元またはメンバーの変更が行われているため、現在は SSH ホスト鍵を確認できません。';

  @override
  String get aVaultStateActionIsIn => '保管庫の状態の操作を処理中です。しばらくしてからもう一度お試しください。';

  @override
  String get theVaultDeviceDirectoryIsMissing =>
      '保管庫のデバイスディレクトリに有効なアカウントまたは署名用公開鍵がありません。';

  @override
  String get theTmuxSessionStartedAndWas =>
      'tmux セッションを開始し、ワークスペースに暗号化して保存しました。';

  @override
  String get theTmuxActionTimedOutCheck =>
      'tmux の操作がタイムアウトしました。ホストの状態を確認してから、もう一度お試しください。';

  @override
  String theLabelPreferenceConflictWasRepaired(String label) {
    return '$labelの設定の競合を修復し、サーバーとの同期で確認しました。';
  }

  @override
  String theLabelPreferenceConflictWasConfirmed(String label) {
    return '$labelの設定の競合が同期で確認されました。';
  }

  @override
  String messageCode(String message, String code) {
    return '$message（$code）';
  }

  @override
  String noticemessageThisDeviceCouldntSaveThe(Object noticeMessage) {
    return '$noticeMessage このデバイスは現在のセッションの同期状態を保存できませんでした。開いている他のタブでは再度サインインが必要になる場合があります。';
  }

  @override
  String get uploadMissingEncryptedObjectsAndRestore =>
      '不足している暗号化オブジェクトをアップロードし、ローカルの状態をアトミックに復元';

  @override
  String get youCantRevokeThisDeviceFrom => '現在のデバイスから自分自身を失効させることはできません';

  @override
  String get theCurrentlySignedInAdminAccount =>
      '現在サインインしている管理者アカウントはここから操作できません。';

  @override
  String get aGroupCantBeMovedInto => 'グループをそれ自身やそのサブグループの中に移動することはできません。';

  @override
  String get theCurrentVaultOwnerCantBe =>
      'メンバーの更新で現在の保管庫のオーナーを取り消したり降格したりすることはできません。';

  @override
  String get theVaultOwnerCantBeRevoked =>
      'この操作で保管庫のオーナーを取り消したり降格したりすることはできません。';

  @override
  String get theNewMasterPasswordsDontMatch => '新しいマスターパスワードが一致しません。';

  @override
  String get thePersonalVaultWasGeneratedAnd =>
      '個人用保管庫をこのデバイスで生成して暗号化しました。鍵がサーバーに送信されることはありません。';

  @override
  String get aMasterPasswordChangeIsIn =>
      'マスターパスワードの変更を処理中です。完了してからアカウントを削除してください。';

  @override
  String get aMasterPasswordChangeIsIn2 =>
      'マスターパスワードの変更を処理中です。しばらくしてからもう一度お試しください。';

  @override
  String get theMasterPasswordChangeIsBeing =>
      'マスターパスワードの変更を確定中です。完了してからワークスペースをロックしてください。';

  @override
  String get theMasterPasswordChangeIsBeing2 =>
      'マスターパスワードの変更を確定中です。完了してからアカウントをロックしてください。';

  @override
  String get masterPasswordChangedOtherSignIn =>
      'マスターパスワードを変更しました。他のサインインセッションは失効しました。';

  @override
  String get theMasterPasswordWasCommittedBut =>
      'マスターパスワードは確定されましたが、アカウントのプロフィールの更新結果が一致しません。再試行して確認してください。';

  @override
  String get theMasterPasswordMustBeAt2 => 'マスターパスワードは 12 文字以上にしてください';

  @override
  String get theMasterPasswordMustBeAt3 => 'マスターパスワードは 12 文字以上にしてください。';

  @override
  String get masterPasswordVerificationFailedTheDeletion =>
      'マスターパスワードの確認に失敗したため、削除の予定は変更されていません。マスターパスワードを再入力してください。';

  @override
  String get aHostCantUseItselfAs => 'ホスト自身を踏み台ホストに設定することはできません。';

  @override
  String get theHostCouldntBeReadBack => '保存後にホストを読み込み直せませんでした。';

  @override
  String get theHostHasntGrantedThisDevice => 'ホストはこのデバイスに有効な入力操作を付与していません。';

  @override
  String get theHostNoLongerExistsResync => 'ホストはもう存在しません。再同期してから、もう一度お試しください。';

  @override
  String get theHostWasSavedEncryptedAnd =>
      'ホストを暗号化して保存し、ローカルの同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get theHostWasSavedEncryptedLocally =>
      'ホストをローカルに暗号化して保存しました。同期を待っています。';

  @override
  String get theHostRevokedOrEndedInput => 'ホストが入力操作を取り消したか終了しました。';

  @override
  String get theHostOrJumpHostRoute =>
      '接続の準備中にホストまたは踏み台ホストの経路が変更されました。再接続してください。';

  @override
  String get hostInputControlEnded => 'ホストの入力操作が終了しました。';

  @override
  String get hostInputControlAuthorizationExpired => 'ホストの入力操作の承認が期限切れになりました。';

  @override
  String get onlyIsolatedRestoreCopiesInThe =>
      '破棄できるのは「準備済み」の状態の隔離された復元用コピーのみです。ジョブ一覧を更新してください。';

  @override
  String get theJobIsStillRunningAnd =>
      'ジョブはまだ実行中で、自動の状態チェックは一時停止しています。ジョブの状態は手動で更新できます。';

  @override
  String get theJobStatusIsTemporarilyUnavailable =>
      'ジョブの状態を一時的に取得できないため、自動の状態チェックを一時停止しました。ジョブの状態は手動で更新できます。';

  @override
  String get theSessionWasRefreshedButThe =>
      'セッションは更新されましたが、新しいセッションのスナップショットを安全に保存できませんでした。このタブはしばらく使い続けられますが、他のタブでは再度サインインが必要です。';

  @override
  String get theSavedTmuxSessionNoLonger =>
      '保存済みの tmux セッションはもう存在しません。新しいセッションが自動で作成されることはありません。';

  @override
  String get theRepairTombstoneHasntBeenConfirmed =>
      '修復用の削除マーカーは、まだサーバーの変更カーソルで確認されていません。同期してから、もう一度お試しください。';

  @override
  String get theCandidateRecordIsMissingA =>
      '候補のレコードに検証済みの現在のバージョンがないため、修復を一時停止しました。';

  @override
  String get aPreferenceRepairIsInProgress => '設定の修復を実行中です。完了してからもう一度お試しください。';

  @override
  String get thePreferenceRepairStateCantBe =>
      '設定の修復状態を検証できません。同期を再試行してから続行してください。';

  @override
  String get thePreferenceRepairStateCantBe2 =>
      '設定の修復状態を検証できません。再同期してから対処してください。';

  @override
  String get theSharedSessionEndedAndThe => '共有セッションが終了したため、入力操作のリースを取り消しました。';

  @override
  String get compatibleSftpDownloadsOnlySupportFiles =>
      '互換 SFTP ダウンロードは 16 MiB 以下のファイルにのみ対応しています';

  @override
  String get invalidCompatibleDownloadSizeLimit => '互換ダウンロードのサイズ上限が無効です';

  @override
  String get preparingExport => 'エクスポートを準備しています';

  @override
  String get preparingVerification => '検証を準備しています';

  @override
  String get theCredentialNameCantBeEmpty => '認証情報の名前は必須です';

  @override
  String get theCredentialUserNameCantBe => '認証情報のユーザー名は必須です';

  @override
  String get theShareRequestComesFromA => '共有リクエストは別のサーバーインスタンスからのものです。';

  @override
  String get groups => 'グループ';

  @override
  String get theGroupDeletionWasSavedEncrypted =>
      'グループの削除を暗号化して保存し、ローカルの同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get theGroupDeletionWasSavedEncrypted2 =>
      'グループの削除を暗号化して保存しました。同期後に他のデバイスに反映されます。';

  @override
  String get theGroupNameCantExceed256 => 'グループ名は 256 UTF-8 バイト以内にしてください。';

  @override
  String get theGroupNameContainsUnsupportedControl =>
      'グループ名に対応していない制御文字が含まれています。';

  @override
  String get theGroupWasSavedEncryptedAnd =>
      'グループを暗号化して保存し、ローカルの同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get groupSavedEncryptedWaitingToSync => 'グループを暗号化して保存しました。同期を待っています。';

  @override
  String get invalidGroupColor => 'グループの色が無効です。';

  @override
  String get anAccountBeingDeletedCantPerform => '削除中のアカウントではこの操作を実行できません。';

  @override
  String get anAccountBeingDeletedCantRevoke =>
      '削除中のアカウントはセッションを失効させることができません。';

  @override
  String get theDeletionTombstoneIsStillWaiting =>
      '削除マーカーはまだ変更フィードでの確認を待っています。同期を再試行してください。';

  @override
  String get theDeletionTombstoneWasSavedEncrypted =>
      '削除マーカーを暗号化して保存し、ローカルの同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get theDeletionWasSavedAsAn =>
      '削除は暗号化された削除マーカーとして保存され、同期後に他のデバイスに反映されます。';

  @override
  String get encryptedBackupJobSubmittedItsStatus =>
      '暗号化バックアップのジョブを送信しました。状態は下の一覧に表示されます。';

  @override
  String get protocol2 => 'プロトコル';

  @override
  String get anotherSyncTaskIsStillRunning =>
      '別の同期タスクがまだ実行中です。完了後に設定の修復を再試行してください。';

  @override
  String get anotherInstanceAdminJobIsRunning =>
      '別のインスタンス管理ジョブが実行中です。しばらくしてからもう一度お試しください。';

  @override
  String get onlyTheVaultOwnerCanManage => '削除予定を管理できるのは保管庫のオーナーのみです。';

  @override
  String get onlyTheVaultOwnerCanManage2 => 'メンバーを管理できるのは保管庫のオーナーのみです。';

  @override
  String get onlyTheVaultOwnerCanInvite => 'メンバーを招待できるのは保管庫のオーナーのみです。';

  @override
  String get onlyTheCurrentVaultOwnerCan => '自動削除の同意を変更できるのは、現在の保管庫のオーナーのみです。';

  @override
  String get onlyTheCurrentVaultOwnerCan2 => 'レコードを完全に削除できるのは、現在の保管庫のオーナーのみです。';

  @override
  String get inputControlCanOnlyBeGranted =>
      '入力操作は、この共有で明示的に承認したデバイスにのみ付与できます。';

  @override
  String get onlyExistingHostsInTheCurrent => '参照できるのは現在の保管庫にある既存のホストのみです。';

  @override
  String get aVaultWithThisIdAlready =>
      '同じ保管庫 ID がすでに存在しますが、今回ステージした新しい空の保管庫ではありません。';

  @override
  String get aGroupWithThisNameAlready =>
      '同じ親の下に同じ名前のグループがあります。名前を変更するか、別の親を選択してください。';

  @override
  String get theSyncVaultWasSwitchedOr =>
      '同期先の保管庫が切り替わったか、書き込めなくなったため、移行を一時停止しました。';

  @override
  String get theSyncVaultWasSwitchedMigration =>
      '同期先の保管庫が切り替わったため、移行を一時停止しました。';

  @override
  String get aSyncIsStillRunningThe =>
      '同期がまだ実行中のため、メンバーの変更はキャンセルされました。しばらくしてからもう一度お試しください。';

  @override
  String get aSyncIsStillRunningRetry => '同期がまだ実行中です。完了後に設定の修復を再試行してください。';

  @override
  String get theConflictCandidatesOrVersionsChanged =>
      '同期後に競合の候補またはバージョンが変更されました。一覧を確認して選択し直してください。';

  @override
  String syncCompleteReceivedcountChangesReceived(int receivedCount) {
    return '同期が完了しました：$receivedCount 件の変更を受信しました。';
  }

  @override
  String get theMasterPasswordCantBeChanged =>
      '同期中またはスナップショットの復元中はマスターパスワードを変更できません。完了後にもう一度お試しください。';

  @override
  String get theAccountCantBeDeletedDuring =>
      '同期中またはスナップショットの復元中はアカウントを削除できません。完了後にもう一度お試しください。';

  @override
  String get name => '名前';

  @override
  String get address => 'アドレス';

  @override
  String get theBackupIntervalMustBe1 => 'バックアップの間隔は 1〜720 時間にしてください。';

  @override
  String get aMasterPasswordChangeIsWaiting =>
      '確認待ちのマスターパスワードの変更があります。先に元の操作を再試行してください。';

  @override
  String get theInstanceIsAlreadyInitializedFirst =>
      'インスタンスはすでに初期化されているため、最初のアカウント登録は使用できません。';

  @override
  String get theAuditCursorExpiredTheServer =>
      '監査カーソルが期限切れになりました。サーバーの世代が切り替わった可能性があります。最初のページから再読み込みしてください。';

  @override
  String get thePasswordCantBeEmpty => 'パスワードは必須です';

  @override
  String get thePasswordChangeOperationStateConflicts =>
      'パスワード変更の操作状態が競合しています。二重に変更しないよう、現在のセッションを維持したまま管理者に連絡してください。';

  @override
  String get noServerInstanceIsConfiguredYet => 'サーバーインスタンスがまだ設定されていません。';

  @override
  String get nestedWorkspacesCanOnlyReferenceExisting =>
      '入れ子のワークスペースが参照できるのは、現在の保管庫にある既存のホストのみです。';

  @override
  String get theWorkspaceTmuxReferenceChangedReload =>
      'ワークスペースの tmux 参照が変更されました。再読み込みしてから、もう一度お試しください。';

  @override
  String get theWorkspaceHostWasRemovedFrom =>
      '接続の準備中にワークスペースのホストが現在の保管庫から削除されました。先に参照を修復してください。';

  @override
  String get theWorkspaceDeletionWasAddedTo =>
      'ワークスペースの削除をローカルの暗号化同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get theWorkspaceDeletionWasSavedEncrypted =>
      'ワークスペースの削除を暗号化して保存しました。同期後に他のデバイスに反映されます。';

  @override
  String get workspacesCanOnlyAddReferencesTo =>
      'ワークスペースに追加できるのは、現在の保管庫にある既存のホストへの参照のみです。';

  @override
  String get theWorkspaceNoLongerExistsIn => 'このワークスペースは現在の保管庫にもう存在しません。';

  @override
  String get theWorkspaceWasSwitchedTryAgain => 'ワークスペースが切り替わりました。もう一度お試しください。';

  @override
  String get theWorkspaceWasSavedEncryptedAnd =>
      'ワークスペースを暗号化して保存し、ローカルの同期キューに追加しました。同期状態の更新に失敗したため、後で再試行します。';

  @override
  String get workspaceSavedEncryptedWaitingToSync =>
      'ワークスペースを暗号化して保存しました。同期を待っています。';

  @override
  String get theWorkspaceChanged => 'ワークスペースが変更されました。';

  @override
  String get theWorkspaceIsLockedButThis =>
      'ワークスペースはロックされましたが、このデバイスの自動ロック解除の記録を消去できませんでした。ローカルストレージを修復してから、再度サインインしてロックしてください。';

  @override
  String get theWorkspaceIsntLockedRightNow => 'ワークスペースは現在ロックされていません。';

  @override
  String get theWorkspacePaneNoLongerExists => 'ワークスペースのペインはもう存在しません。';

  @override
  String get theWorkspacePaneOrHostReference =>
      'ワークスペースのペインまたはホストの参照が変更されました。再接続してから、もう一度お試しください。';

  @override
  String get localChangesAreBlockedWhileThe =>
      'ワークスペースがロックされている間はローカルの変更ができません。先にロックを解除してください。';

  @override
  String uploadedName(String name) {
    return '$name をアップロードしました';
  }

  @override
  String savedName(String name) {
    return '$name を保存しました';
  }

  @override
  String savedNameButCouldntConfirmThe(String name) {
    return '$name を保存しましたが、元の権限が復元されたかを確認できませんでした。リモートファイルの権限を確認してください。';
  }

  @override
  String get thePinnedServerIdentityChangedDuring =>
      '確認中に固定済みのサーバー ID が変更されました。再接続してから、もう一度お試しください。';

  @override
  String get unlockedLocallyTheServerStillStores =>
      'ローカルでロックを解除しました。サーバーに保存されるのは引き続き暗号化レコードと鍵エンベロープのみです。';

  @override
  String get memberInvitationAcceptedTheVaultIs =>
      'メンバーの招待を承諾しました。保管庫のロックを解除し、同期を開始しました。';

  @override
  String get anExistingRepairTombstoneAlreadySpecifies =>
      '既存の修復用削除マーカーで保持するレコードが指定されています。そのレコードで修復を再試行してください。';

  @override
  String get theRecordRetainedByAnExisting =>
      '既存の修復用削除マーカーで保持されたレコードが一致しないため、手動での確認が必要です。';

  @override
  String get aServerAccessGroupWithThe =>
      '同じ名前のサーバーアクセスグループがすでに存在します（大文字小文字と Unicode 互換文字は区別しません）。';

  @override
  String get thePreviouslySubmittedMasterPasswordChange =>
      '以前に送信したマスターパスワードの変更を確認しました。他のサインインセッションは失効しました。';

  @override
  String get attachedToTheSavedTmuxSession => '保存済みの tmux セッションにアタッチしました。';

  @override
  String theKeyKeyInTheArchive(String key) {
    return 'アーカイブ内の $key 鍵が、ローカルでロック解除された鍵と一致しません。';
  }

  @override
  String get theArchiveNoLongerCorrespondsTo =>
      'アーカイブが現在のサーバースペース／保管庫に対応しなくなったため、インポートは行われませんでした。';

  @override
  String get theArchiveWasVerifiedAndRestored =>
      'アーカイブを検証して復元しました。過去の鍵はこのクライアントのメモリにのみ保持され、ローカルの送信トレイと競合ブランチは保持されています。';

  @override
  String get lockTheWorkspaceAfterTheArchive =>
      'アーカイブの操作が完了してからワークスペースをロックしてください。';

  @override
  String get theCurrentOwnerDeviceIsntIn =>
      '現在のオーナーのデバイスが、残るメンバーのアクティブなデバイスに含まれていないため、更新を中止しました。';

  @override
  String get theCurrentPostgresqlModeSupportsInstance =>
      '現在の PostgreSQL の実行モードはインスタンスのメンテナンスに対応していますが、サーバー側の暗号化バックアップと復元はまだ利用できません。';

  @override
  String get theCurrentVaultIsntWritable => '現在の保管庫には書き込めません。';

  @override
  String theCurrentVaultIsntWritableSo(String label) {
    return '現在の保管庫には書き込めないため、$labelの設定を修復できません。';
  }

  @override
  String get theCurrentVaultIsReadOnly6 =>
      '現在の保管庫は読み取り専用か削除中のため、コマンド履歴の同期を有効にできません。';

  @override
  String get theCurrentVaultIsReadOnly => '現在の保管庫は読み取り専用のため、設定を変更できません。';

  @override
  String get theCurrentVaultIsReadOnly2 => '現在の保管庫は読み取り専用のため、グループを変更できません。';

  @override
  String get theCurrentVaultIsReadOnly3 => '現在の保管庫は読み取り専用のため、グループを削除できません。';

  @override
  String get theCurrentVaultIsReadOnly4 => '現在の保管庫は読み取り専用のため、自動削除の同意は変更できません。';

  @override
  String get theCurrentVaultIsReadOnly5 => '現在の保管庫は読み取り専用のため、レコードを完全に削除できません。';

  @override
  String get theCurrentVaultSyncRepositoryIsnt =>
      '現在の保管庫の同期リポジトリはまだ準備ができていません。';

  @override
  String get theCurrentVaultSyncTimedOut =>
      '現在の保管庫の同期がタイムアウトしたため、SSH ホスト鍵の信頼チェックを停止しました。';

  @override
  String get theCurrentVaultIsLockedSo => '現在の保管庫はロックされているため、SSH ホスト鍵を確認できません。';

  @override
  String get theCurrentVaultOrSignedIn =>
      '現在の保管庫またはサインイン中のデバイスはターミナルの共有に使用できません。';

  @override
  String get refreshingTheCurrentVaultStateTimed =>
      '現在の保管庫の状態の更新がタイムアウトしたため、SSH ホスト鍵の信頼チェックを停止しました。';

  @override
  String get theCurrentMasterPasswordOrSix =>
      '現在のマスターパスワードまたは 6 桁の認証コードが無効か、使用済みです。マスターパスワードと新しい 6 桁のコードを再入力してください。';

  @override
  String get theCurrentMasterPasswordOrAccount =>
      '現在のマスターパスワードまたはアカウント鍵のエンベロープを検証できません。';

  @override
  String get theCurrentMasterPasswordMustBe =>
      '現在のマスターパスワードは 12 文字以上である必要があります。';

  @override
  String get theCurrentMasterPasswordCouldntBe =>
      '現在のマスターパスワードを確認できなかったため、アカウントの認証情報は変更されていません。パスワードを確認してから、もう一度お試しください。';

  @override
  String get theCurrentHostOrVaultIs => '現在のホストまたは保管庫を利用できません。';

  @override
  String get tmuxIsntAvailableOnTheCurrent => '現在のホストでは tmux を利用できません。';

  @override
  String get theCurrentSessionIsMissingThe => '現在のセッションにアカウント名がありません。';

  @override
  String get theCurrentSyncHasntFinishedWait =>
      '現在の同期がまだ終わっていません。完了してからメンバーの招待を作成してください。';

  @override
  String get theCurrentSyncHasntFinishedWait2 =>
      '現在の同期がまだ終わっていません。完了してから保管庫のメンバーを変更してください。';

  @override
  String get anInputControlLeaseIsAlready => '入力操作のリースがすでに有効です。先に取り消してください。';

  @override
  String get theCurrentMemberRoleCantBe => '現在のメンバーのロールはこの操作では取り消せません。';

  @override
  String get theCurrentServerDoesntDeclareSupport =>
      '現在のサーバーは、隔離された復元用コピーの破棄に対応していません。';

  @override
  String get theresNoSignedInAccountWhose => 'パスワードを変更できるサインイン中のアカウントがありません。';

  @override
  String get noAccountIsSignedIn => 'サインイン中のアカウントはありません。';

  @override
  String thereAreNoPendingLabelPreference(String label) {
    return '保留中の$labelの設定の競合はありません。';
  }

  @override
  String get theCurrentTestSshConnectorDoesnt =>
      '現在のテスト用 SSH コネクターは踏み台ホストに対応していません。';

  @override
  String get theCurrentTestSshConnectorDoesnt2 =>
      '現在のテスト用 SSH コネクターは多段の踏み台ホストに対応していません。';

  @override
  String get thisBrowserHasNoRegisteredDevice =>
      'このブラウザには登録済みのデバイス鍵がありません。承認済みのデバイスからこのデバイスを追加し直してください。';

  @override
  String get thisBrowserHasNoRegisteredDevice2 =>
      'このブラウザには登録済みのデバイス鍵がありません。先に承認済みのデバイスからこのデバイスを追加してください。';

  @override
  String get theCurrentDeviceKeyIsMissing =>
      '現在のデバイス鍵がないか、セッションと一致しません。このデバイスを再度承認してください。';

  @override
  String get thisDeviceDoesntHaveKeysFor =>
      'このデバイスにはすべての保管庫の鍵がないため、そのデバイスを承認できません。';

  @override
  String get theCurrentDeviceIdentityDoesntMatch =>
      '現在のデバイスの ID がサインインセッションと一致しません。';

  @override
  String get theCurrentAccountOrVaultChanged =>
      '現在のアカウントまたは保管庫が変わったため、SSH ホスト鍵を確認できません。';

  @override
  String get theCurrentAccountDoesntHaveInstance =>
      '現在のアカウントにはインスタンス管理者の権限がありません。';

  @override
  String get theCurrentAccountIdentityIsUnavailable =>
      '現在のアカウントの ID を利用できません。もう一度サインインしてください。';

  @override
  String get theCurrentAccountVerificationDetailsDont =>
      '現在のアカウントの検証情報が一致しません。';

  @override
  String get theRoleOfAPendingInvitation =>
      '承諾待ちの招待のロールは直接変更できません。取り消してから、新しいロールで再招待してください。';

  @override
  String get thePendingMasterPasswordChangeRequest =>
      '確認待ちのマスターパスワード変更リクエストを消去しました。';

  @override
  String get theServerIdentityAwaitingConfirmationWas =>
      '確認待ちのサーバー ID はキャンセルされました。再接続してから、もう一度お試しください。';

  @override
  String get theSnapshotWasRestoredSafelySome =>
      'スナップショットは安全に復元されました。アップロード待ちの操作または再試行待ちの競合が残っています。元の送信トレイは保持されています。';

  @override
  String snapshotRestoreCompleteReceivedcountRecordsVerified(
    int receivedCount,
  ) {
    return 'スナップショットの復元が完了しました：$receivedCount 件のレコードを検証して再構築しました。';
  }

  @override
  String get youCantSwitchVaultsDuringSnapshot => 'スナップショットの復元中は保管庫を切り替えられません。';

  @override
  String get localChangesArePausedDuringSnapshot =>
      'スナップショットの復元中はローカルの変更が一時停止されます。完了後にもう一度お試しください。';

  @override
  String get theMemberRoleCanOnlyBe => 'メンバーのロールは editor または viewer にのみ設定できます。';

  @override
  String get theMemberRoleWasUpdatedAnd =>
      'メンバーのロールを更新し、残っているすべてのメンバーデバイスで新しい鍵への更新を完了しました。';

  @override
  String get theMemberRoleWasUpdatedAnd2 =>
      'メンバーのロールを更新し、残っているすべてのメンバーデバイスで新しい鍵への更新を完了しました。承諾待ちの招待は保留のままですが、古いトークンは無効になったため、再度招待してください。';

  @override
  String get memberRoleUpdatedTheServerCommitted =>
      'メンバーのロールを更新し、サーバーが新しい鍵エポックを確定しました。';

  @override
  String get memberAccessWasRevokedAndThe =>
      'メンバーのアクセスを取り消し、残っているメンバーの保管庫鍵を更新しました。承諾待ちの招待は保留のままですが、古いトークンは無効になったため、再度招待してください。';

  @override
  String get memberAccessWasRevokedAndThe3 =>
      'メンバーのアクセスを取り消し、残っているメンバーの保管庫鍵を更新しました。取り消されたメンバーは新しいエポック鍵を受け取りませんが、すでに保存された古いコピーはリモートで削除できません。';

  @override
  String get memberAccessWasRevokedAndThe2 =>
      'メンバーのアクセスを取り消し、サーバーが新しい鍵エポックを確定しました。すでに保存されている古いコピーはリモートで削除できない点に注意してください。';

  @override
  String get invalidMemberAccountIdFormat => 'メンバーのアカウント ID の形式が無効です。';

  @override
  String get theMemberRotationResultCantBe =>
      'メンバーの更新結果を現在確認できないため、古い鍵を使わないようこの保管庫をロックしました。再度サインインしてメンバーの状態を確認してから続行してください。';

  @override
  String get ownershipCanOnlyBeTransferredTo =>
      '所有権は、招待を承諾したアクティブなメンバーにのみ移転できます。';

  @override
  String get theSelectedJumpHostNoLonger =>
      '選択した踏み台ホストはもう存在しません。有効なホストを選択するか、無効な参照をクリアしてください。';

  @override
  String get theSelectedSshCredentialNoLonger =>
      '選択した SSH 認証情報はもう存在しません。有効な認証情報を選択するか、この上書きをクリアしてください。';

  @override
  String get theSelectedSessionNoLongerExists =>
      '選択したセッションはもう存在しないか、すでに失効しています。セッション一覧を更新してください。';

  @override
  String get theSelectedRetainedRecordChangedCheck =>
      '選択した保持レコードが変更されました。候補をもう一度確認してください。';

  @override
  String get theSelectedGroupNoLongerExists =>
      '選択したグループはもう存在しません。有効なグループを選択するか、グループを解除してください。';

  @override
  String get theSelectedEncryptedArchiveIsUnavailable =>
      '選択した暗号化アーカイブは利用できません。ソース一覧を更新してから、もう一度お試しください。';

  @override
  String get theSelectedArchiveIsInvalidRefresh =>
      '選択したアーカイブは無効です。ソース一覧を更新してから、もう一度お試しください。';

  @override
  String get theSelectedArchiveSourceIsInvalid =>
      '選択したアーカイブのソースが無効です。ソース一覧を更新してから、もう一度お試しください。';

  @override
  String get theSelectedServerAccessGroupNo =>
      '選択したサーバーアクセスグループはもう存在しません。一覧を更新してください。';

  @override
  String get theApprovalFileDoesntMatchThe =>
      '承認ファイルがこのブラウザで生成したデバイスのリクエストと一致しません。';

  @override
  String get theVaultKeyEnvelopeContextIn => '承認ファイル内の保管庫鍵エンベロープのコンテキストが無効です。';

  @override
  String get theVaultKeyEnvelopeInThe2 => '承認ファイル内の保管庫鍵エンベロープの形式が無効です。';

  @override
  String get theDeviceCapabilityReportInThe => '承認ファイル内のデバイス機能レポートの形式が無効です。';

  @override
  String get theApprovalFileContainsDuplicateVault =>
      '承認ファイルに重複した保管庫鍵エンベロープが含まれています。';

  @override
  String get theApprovalFileBelongsToA => '承認ファイルは別のアカウントまたはサーバーインスタンスのものです。';

  @override
  String get theApprovalFileIsStagedAfter =>
      '承認ファイルをステージしました。サインイン後、クライアントはデータのロックを解除する前にオーナーの証明書と各保管庫鍵エンベロープを検証します。';

  @override
  String get theDeviceSelfProofInThe => '承認ファイル内のデバイスの自己証明がローカルのデバイス鍵と一致しません。';

  @override
  String get theApproverOrCurrentDeviceIsnt =>
      '承認者または現在のデバイスがサーバーのアカウントのデバイスディレクトリにありません。';

  @override
  String get theApproverCertificateFieldsAreInvalid => '承認者の証明書のフィールドが無効です。';

  @override
  String get theApproverCertificateSignatureIsInvalid => '承認者の証明書の署名が無効です。';

  @override
  String get thisHostCouldntBeFound => 'このホストが見つかりません。';

  @override
  String get theVaultOnThisDeviceCouldnt => 'このデバイス上の保管庫が見つかりません。';

  @override
  String get theScrapeCredentialWasRotatedThe =>
      'スクレイプ認証情報を更新しました。値は一度だけ表示されます。';

  @override
  String get toCancelAccountDeletionSignOut =>
      'アカウント削除を取り消すには、先にサインアウトしてサインインページの復旧オプションを使ってください。';

  @override
  String theFileWasSavedButThe(String friendlyError) {
    return 'ファイルは保存されましたが、フォルダーを更新できませんでした：$friendlyError';
  }

  @override
  String get theNewMasterPasswordMustDiffer => '新しいマスターパスワードは現在のものと異なる必要があります。';

  @override
  String get theNewMasterPasswordMustBe => '新しいマスターパスワードは 12 文字以上にしてください。';

  @override
  String get couldntDiscardTheIsolatedRestoreCopy =>
      '隔離された復元用コピーを破棄できませんでした。ジョブ一覧を更新してから、もう一度お試しください。';

  @override
  String get couldntSaveChangesToTheTmux =>
      'tmux セッション参照の変更を保存できませんでした。しばらくしてからもう一度お試しください。';

  @override
  String get couldntSaveTheScheduledBackupSettings =>
      'スケジュールバックアップの設定を保存できませんでした。もう一度お試しください。';

  @override
  String get couldntPrepareTheIsolatedRestoreCopy =>
      '隔離された復元用コピーを準備できませんでした。稼働中のデータは変更されていません。';

  @override
  String get couldntCreateANewTmuxSession =>
      '新しい tmux セッションを作成できませんでした。もう一度お試しください。';

  @override
  String get couldntJoinInputControlMakeSure =>
      '入力操作に参加できませんでした。ホストがこのデバイスに操作権を付与しているか確認してください。';

  @override
  String get couldntStartTheLocalShell => 'ローカルのシェルを起動できませんでした。';

  @override
  String get couldntStartTerminalSharingCheckThe =>
      'ターミナルの共有を開始できませんでした。接続と保管庫のメンバーシップを確認してから、もう一度お試しください。';

  @override
  String couldntSafelyCreateRemoteFileName(String name, Object error) {
    return 'リモートファイル $name を安全に作成できませんでした。すでに存在しているか、現在のユーザーに書き込み権限がない可能性があります。既存のファイルは上書きされません。（$error）';
  }

  @override
  String get couldntSafelyRestoreTheSignIn =>
      'サインインセッションを安全に復元できませんでした。もう一度サインインしてください。';

  @override
  String get theRefreshRequestStateCouldntBe =>
      'リフレッシュリクエストの状態を安全に記録できないため、リクエストをブロックしました。このデバイスのセキュアストレージを確認してから、もう一度お試しください。';

  @override
  String get couldntCompleteTheTmuxSessionAction =>
      'tmux セッションの操作を完了できませんでした。ホストの状態を確認してから、もう一度お試しください。';

  @override
  String couldntFinishSyncingTheCurrentVault(String syncStatus) {
    return '現在の保管庫の同期を完了できなかったため（$syncStatus）、SSH ホスト鍵の信頼チェックを停止しました。';
  }

  @override
  String get couldntConfirmTheTmuxSessionStarted =>
      'tmux セッションが開始したことを確認できませんでした。ホストを確認してから、もう一度お試しください。';

  @override
  String get couldntReadEncryptedArchiveSourcesTry =>
      '暗号化アーカイブのソースを読み込めませんでした。しばらくしてからもう一度お試しください。';

  @override
  String get couldntReadLocalSecuritySettingsCheck =>
      'ローカルのセキュリティ設定を読み込めませんでした。ブラウザのストレージを確認してから、もう一度お試しください。';

  @override
  String get couldntReadThisTerminalShare => 'このターミナルの共有を読み込めませんでした。';

  @override
  String get couldntReadTheScheduledBackupSettings =>
      'スケジュールバックアップの設定を読み込めませんでした。もう一度お試しください。';

  @override
  String get couldntReadTheRestoreJobStatus2 =>
      '復元ジョブの状態を読み込めませんでした。しばらくしてからもう一度お試しください。';

  @override
  String get couldntRejoinTheShareMayHave =>
      '再参加できませんでした。共有が終了したか、保管庫へのアクセス権が変わった可能性があります。';

  @override
  String get couldntVerifyTheCurrentDeviceApproval => '現在のデバイスの承認を検証できませんでした。';

  @override
  String get thePendingVaultRecordsCouldntBe =>
      '送信待ちの保管庫レコードを検証できませんでした。同期のオフは反映されましたが、オフラインのキューはクリアされていません。';

  @override
  String get thePendingCommandHistoryCouldntBe =>
      '送信待ちのコマンド履歴を検証できませんでした。同期のオフは反映されましたが、オフラインのキューはクリアされていません。';

  @override
  String get theStagedVaultCreationDataDoesnt =>
      'ステージされた保管庫の作成データが対象の ID と一致しません。';

  @override
  String get theStagedVaultCreationDataHas => 'ステージされた保管庫の作成データの形式が無効です。';

  @override
  String get couldntReadTheRestoreJobStatus3 =>
      '現在、復元ジョブの状態を読み込めません。システムは引き続き試行します。';

  @override
  String get couldntReadTheRestoreJobStatus =>
      '現在、復元ジョブの状態を読み込めません。手動で再試行してください。';

  @override
  String upToMaxterminaltabsSshTerminalTabs(int maxTerminalTabs) {
    return '同時に開ける SSH ターミナルのタブは最大 $maxTerminalTabs 個です。先にタブを 1 つ閉じてください。';
  }

  @override
  String get aVaultIsInItsDeletion =>
      '削除の猶予期間中の保管庫があるため、サーバーは現在、新しいデバイスの承認を許可していません。';

  @override
  String get theServerSyncGenerationChangedUnlock =>
      'サーバーの同期の世代が変わりました。保管庫のロックを解除して、安全に同期を再開してください。';

  @override
  String get theServerHasntConfiguredEncryptedBackups =>
      'サーバーで暗号化バックアップが設定されていません。インスタンスの運用者に、ATERMIUS_BACKUP_ARCHIVE_DIR（データディレクトリ外の、オーナーのみアクセス可能なディレクトリ）と ATERMIUS_BACKUP_KEY_FILE（データディレクトリ外の、オーナーのみアクセス可能な 32 バイトの鍵ファイル）の設定を依頼してください。このクライアントがこれらのパス、アーカイブのファイル名、鍵を送信または表示することはありません。';

  @override
  String get theServerHasntConfiguredIsolatedRestore =>
      'サーバーに隔離された復元用ストレージが設定されていません。インスタンスの運用者に連絡してください。';

  @override
  String get theServerAccessGroupWasUpdated =>
      'サーバーアクセスグループは別の管理者によって更新されました。最新のデータを再読み込みしてください。現在の下書きは保持されています。';

  @override
  String get theServersInitialVaultMembershipRecord =>
      'サーバーの保管庫の初期メンバーレコードの形式が無効です。';

  @override
  String get theServerVaultKeyEnvelopeDoesnt =>
      'サーバーの保管庫鍵エンベロープが、このデバイスにステージされた作成データと一致しません。';

  @override
  String get theServersVaultMembershipListHas =>
      'サーバーの保管庫メンバーリストの形式が無効なため、鍵の更新を中止しました。';

  @override
  String get theServerVaultMembershipChainDoesnt =>
      'サーバーの保管庫メンバーシップチェーンが、このデバイスにステージされた作成データと一致しません。';

  @override
  String get theServersEncryptedArchiveConfigurationIs =>
      'サーバーの暗号化アーカイブの設定を利用できません。サーバーの運用者に連絡してください。';

  @override
  String get theServerSyncCursorExpiredA =>
      'サーバーの同期カーソルが期限切れになったため、新しいスナップショットが必要です。';

  @override
  String get theServerInstanceIdChangedAnd =>
      'サーバーのインスタンス ID が変更されたため、鍵の復旧では確認できません。';

  @override
  String get theServerInstanceIdentityChangedTo =>
      'サーバーのインスタンス ID が変更されました。ローカルの保管庫を保護するため、クライアントは接続を拒否しました。';

  @override
  String theServerHasntConfirmedThatOnly(String label) {
    return '選択した$labelの設定レコードだけが残っていることを、サーバーがまだ確認していません。同期してから、もう一度お試しください。';
  }

  @override
  String get theServerHasntConfiguredAUsable =>
      'サーバーに利用可能な暗号化バックアップの保存先と鍵が設定されていないため、スケジュールバックアップは変更されていません。';

  @override
  String get theServerAcceptedTheRevocationRequest =>
      'サーバーが失効リクエストを受け付けました。古いセッションは復元されないため、もう一度サインインしてください。';

  @override
  String get theServerAcceptedTheDeletionRequest2 =>
      'サーバーは削除リクエストを受け付けましたが、無効な猶予期間の状態を返しました。';

  @override
  String get theServerAcceptedTheDeletionRequest =>
      'サーバーが削除リクエストを受け付け、現在のセッションとこのデバイスのロック解除キーを消去しました。サインインページのアカウント復旧を使用してください。猶予期間内であれば取り消すことができ、その後は再度サインインが必要です。';

  @override
  String get theServerCommittedTheVaultOwnership =>
      'サーバーは保管庫の所有権の移転と新しい鍵エポックを確定しました。このアカウントは編集者に降格されました。';

  @override
  String get theServerSnapshotContainsRecordsThis =>
      'サーバーのスナップショットに、このデバイスで以前に完全削除したレコードが含まれています。古いデータの復活を防ぐため、クライアントは現在のキャッシュ、同期カーソル、ローカルの下書きを保持し、自動同期を停止します。サーバーが削除前のバックアップから復元された直後であれば、まず管理者がサーバーの復元状態を確認して再処理する必要があります。このデバイスが保存済みの削除の証明を自動で削除することはありません。';

  @override
  String get theServerCommittedTheMemberRotation =>
      'サーバーはメンバーの更新を確定しましたが、新しいエポックとメンバーシップをローカルで検証できないため、以降の操作を停止しました。';

  @override
  String get theServerMembershipChainBelongsTo =>
      'サーバーのメンバーシップチェーンは別の保管庫のものです。';

  @override
  String get theServerRejectedThisBackupSchedule =>
      'サーバーがこのバックアップスケジュールのリクエストを拒否しました。更新してから、もう一度お試しください。';

  @override
  String get theServerRejectedThisIsolatedRestore =>
      'サーバーがこの隔離された復元のリクエストを拒否しました。ソース一覧を更新してから、もう一度お試しください。';

  @override
  String get theServerDidntReturnTheVault => 'サーバーは承諾した招待の保管庫 ID を返しませんでした。';

  @override
  String get theServerDidntReturnAValid => 'サーバーから有効な削除の猶予期間と期限が返されませんでした。';

  @override
  String get theServerDidntProvideAVerifiable =>
      'サーバーが検証可能な復元期限を提供しなかったため、完全削除をブロックしました。';

  @override
  String get theServerDidntProvideAValid => 'サーバーが有効なインスタンス署名 ID を提供しませんでした。';

  @override
  String get theServerDidntReturnAnAccount =>
      'サーバーがアカウントの識別子を返さなかったため、デバイスのリクエストを作成できません。';

  @override
  String get theServerSigningKeyDoesntMatch =>
      'サーバーの署名鍵が固定済みの ID と一致しません。先に別の信頼できる経路で候補のフィンガープリントを確認してください。';

  @override
  String get theServerSigningKeyDoesntMatch2 =>
      'サーバーの署名鍵が固定済みの ID と一致しません。別の信頼できる経路で候補のフィンガープリントを照合してください。確認するまで、アカウントへの接続や認証リクエストは送信されません。';

  @override
  String get theServerIsMissingTheExisting =>
      'サーバーに既存の復旧用 ID のエンベロープがないため、安全に更新できません。';

  @override
  String get theServerDeviceDirectoryDoesntMatch =>
      'サーバーのデバイスディレクトリが、承認ファイル内のアカウントまたは公開鍵と一致しません。';

  @override
  String get theServersDeviceCapabilityReportDoesnt =>
      'サーバーのデバイス機能レポートが承認ファイルと一致しません。';

  @override
  String get theServerIdentityChangedDuringConfirmation =>
      '確認中にサーバーの ID が変更されました。再接続して新しいフィンガープリントを確認してください。';

  @override
  String get serverIdentityConfirmationIsInProgress => 'サーバー ID の確認を実行中です。';

  @override
  String get serverIdentityConfirmationIsInProgress2 =>
      'サーバー ID の確認を実行中のため、現在はキャンセルできません。';

  @override
  String get serverIdentityConfirmationIsInProgress3 =>
      'サーバー ID の確認を実行中です。現在の操作が完了するまでお待ちください。';

  @override
  String get theServerRotationResultDoesntMatch =>
      'サーバーの更新結果が署名済みのエポック／メンバーシップのバージョンと一致しません。';

  @override
  String get theServerReturnedADifferentMigration =>
      'サーバーが別の移行先の保管庫 ID を返しました。';

  @override
  String get theVaultOwnerStateReturnedBy => 'サーバーが返した保管庫のオーナーの状態が一致しません。';

  @override
  String get theServerReturnedAnInvalidMaster =>
      'サーバーが返したマスターパスワード変更の受領情報が無効です。';

  @override
  String get theServerReturnedAnInvalidRecovery => 'サーバーが返した復旧設定の受領情報が無効です。';

  @override
  String get theMembershipVersionReturnedByThe =>
      'サーバーが返したメンバーシップのバージョンがローカルの署名と一致しません。';

  @override
  String get theRevocationStateReturnedByThe =>
      'サーバーが返した失効状態が無効なため、保管庫はロックされたままです。';

  @override
  String get theAccountRevocationStateReturnedBy => 'サーバーが返したアカウントの失効状態が無効です。';

  @override
  String get theServerReturnedDuplicateMigrationDestination =>
      'サーバーが重複した移行先の保管庫を返しました。';

  @override
  String get noIsolatedRestoreCopyToDiscard =>
      '破棄できる隔離された復元用コピーは見つかりませんでした。ジョブ一覧を更新してください。';

  @override
  String get thereAreUncommittedLocalChangesRotate =>
      'ローカルに未確定の変更があります。古いバージョンのレコードを確定できなくならないよう、同期の完了後にメンバーの鍵を更新してください。';

  @override
  String get thereAreUncommittedLocalChangesCreate =>
      'ローカルに未確定の変更があります。古いバージョンのレコードを確定できなくならないよう、同期の成功後にメンバーの招待を作成してください。';

  @override
  String get theLocalFileNameIsntA => 'ローカルのファイル名は安全なリモートのファイル名ではありません。';

  @override
  String get localConsole => 'ローカルコンソール';

  @override
  String get theLocalConsoleRequiresTheDesktop =>
      'ローカルコンソールにはデスクトップクライアントが必要です。';

  @override
  String get thisDevicesEncryptedHistoryRepositoryIsnt =>
      'このデバイスの暗号化された履歴リポジトリはまだ準備ができていません。';

  @override
  String get thisDeviceHasNoCurrentSession =>
      'このデバイスには安全に復元できる現在のセッションのスナップショットがありません。もう一度サインインしてください。';

  @override
  String get thisSignInCanContinueBut => '今回のサインインは続行できますが、サインイン状態を記憶できません。';

  @override
  String get refreshingVaultMembershipTryChangingIt =>
      '保管庫のメンバーの状態を更新中です。しばらくしてから変更してください。';

  @override
  String get anotherVaultMemberInvitationIsBeing =>
      '別の保管庫メンバーの招待を承諾中です。しばらくしてからもう一度お試しください。';

  @override
  String get confirmingTheInputControlRevocationTry =>
      '入力操作の取り消しを確認中です。しばらくしてからもう一度お試しください。';

  @override
  String get connectingHostApprovedInputControl => 'ホストが承認した入力操作に接続しています。';

  @override
  String get thisHostChangedAfterThePreview =>
      'プレビューの後にこのホストが変更されました。再同期して更新の差分を確認してください。';

  @override
  String get thisHostNoLongerExistsOr =>
      'このホストはもう存在しないか、一意に読み取れません。再同期してから編集してください。';

  @override
  String get thisHostsLocalEncryptedRecordCouldnt =>
      'このホストのローカルの暗号化レコードを検証できませんでした。データの上書きや消失を防ぐため、保存を中止しました。';

  @override
  String get thisHostIsMissingAVerifiable =>
      'このホストには検証可能なローカルのリビジョンがないため、同期履歴を壊さないよう保存を中止しました。';

  @override
  String thisSshCredentialIsStillReferenced(
    int groupCount,
    int hostCount,
    int snippetParameterCount,
  ) {
    return 'この SSH 認証情報は、グループの既定値 $groupCount 件、ホストの上書き $hostCount 件、スニペットのシークレットパラメーター $snippetParameterCount 件からまだ参照されています。先にこれらの参照を変更またはクリアしてください。';
  }

  @override
  String get thisSshCredentialNoLongerExists =>
      'この SSH 認証情報はもう存在しないか、検証できません。先に保管庫を再同期してください。';

  @override
  String get theTerminalFontSizePreferenceIn =>
      'この保管庫のターミナルのフォントサイズの設定に、重複したレコードまたは未確認の修復があります。明示的な修復を完了してください。';

  @override
  String get theTerminalShortcutPreferenceInThis =>
      'この保管庫のターミナルのショートカットの設定に、重複したレコードまたは未確認の修復があります。明示的な修復を完了してください。';

  @override
  String get theTerminalColorPreferenceInThis =>
      'この保管庫のターミナル配色の設定に、重複したレコードまたは未確認の修復があります。明示的な修復を完了してください。';

  @override
  String get theDefaultWorkspacePreferenceInThis =>
      'この保管庫の既定のワークスペースの設定に、重複したレコードまたは未確認の修復があります。明示的な修復を完了してください。';

  @override
  String get thisVaultContainsUnsupportedPreferenceRecords =>
      'この保管庫には対応していない設定レコードが含まれているため、修復を一時停止しました。';

  @override
  String get thisVaultContainsPreferencesThatThis =>
      'この保管庫には、このクライアントが対応していない設定が含まれています。';

  @override
  String get thisVaultCantBeUsedTo => 'この保管庫は現在、ターミナルの共有の作成に使用できません。';

  @override
  String get thisVaultIsntCurrentlyInAn => 'この保管庫は現在、削除できるアクティブな状態ではありません。';

  @override
  String get thisVaultIsCurrentlyReadOnly => 'この保管庫は現在読み取り専用のため、メンバーを変更できません。';

  @override
  String get thisVaultHasNoDeletionSchedule => 'この保管庫には取り消せる削除予定がありません。';

  @override
  String get thisVaultIsInItsDeletion => 'この保管庫は削除の猶予期間中のため、現在は読み取り専用です。';

  @override
  String get thisVaultIsInItsDeletion2 =>
      'この保管庫は削除の猶予期間中で読み取り専用です。オーナーは期限前であれば削除を取り消せます。';

  @override
  String thisHostIsStillUsedAs(int dependants) {
    return 'このホストはまだ $dependants 台のホストで踏み台ホストとして使われています。先にこれらの参照を変更またはクリアしてください。';
  }

  @override
  String get thisSessionWasSignedOutIn =>
      'このセッションは別のタブでサインアウトされました。もう一度サインインしてください。';

  @override
  String get thisSessionsRefreshTokenStateCant =>
      'このセッションのリフレッシュトークンの状態を安全に復元できません。もう一度サインインしてください。';

  @override
  String get thisSharedSessionDoesntHaveHost =>
      'この共有セッションでは、ホストが承認した入力操作は有効になっていません。';

  @override
  String thisGroupIsStillReferencedBy(int hostCount, int childCount) {
    return 'このグループはまだホスト $hostCount 台とサブグループ $childCount 個から参照されています。先にこれらのレコードを移動してください。';
  }

  @override
  String get thisGroupNoLongerExistsOr =>
      'このグループはもう存在しないか、検証できません。先に保管庫を再同期してください。';

  @override
  String thisDeletedRecordIsPastThe(String dateText) {
    return 'この削除済みレコードはサーバーの復元期限$dateTextを過ぎています。削除マーカーはこのレコード ID を引き続き保持します。引き続き使用するには、新しい ID で新しいレコードを作成してください。';
  }

  @override
  String get thisInstanceIsntInitializedYetCreate =>
      'このインスタンスはまだ初期化されていません。管理者が生成したワンタイムのブートストラップトークンで最初のアカウントを作成してください。';

  @override
  String get thisWorkspaceHostNoLongerExists =>
      'このワークスペースのホストは現在の保管庫にもう存在しません。先に参照を修復してください。';

  @override
  String get thisWorkspacePaneAlreadyHasA =>
      'このワークスペースのペインにはすでに tmux セッションの参照があります。「再開」を使ってください。';

  @override
  String get thisWorkspacePaneIsAlreadyAttached =>
      'このワークスペースのペインはすでに tmux にアタッチされています。';

  @override
  String get thisWorkspacePaneIsRunningA => 'このワークスペースのペインは tmux の操作を実行中です。';

  @override
  String get thisWorkspacePaneHasNoSaved =>
      'このワークスペースのペインには保存済みの tmux セッション参照がありません。';

  @override
  String get mobilePushIsntSupportedOnThis => 'このプラットフォームはモバイルプッシュに対応していません。';

  @override
  String get thisAppBuildDoesntHaveFirebase =>
      'このアプリのビルドには Firebase Cloud Messaging が設定されていません。';

  @override
  String get thisMembersAccessWasRevokedTo =>
      'このメンバーのアクセスは取り消されています。再度承認するには、新しいメンバーの招待を作成してください。';

  @override
  String get thisBrowserCantSafelyCoordinateSession =>
      'このブラウザではタブ間のセッション更新を安全に調整できないため、リフレッシュトークンを更新していません。安全なセッション同期を有効にするには、ブラウザを更新してください。';

  @override
  String get thisBrowserHasNoDeviceKey =>
      'このブラウザには承認待ちのデバイス鍵がありません。先にデバイスのリクエストを生成してください。';

  @override
  String get youLeftThisTerminalShareEnter =>
      'このターミナルの共有から退出しました。セッション UUID を再入力してください。';

  @override
  String get thisTerminalIsAlreadyBeingShared => 'このターミナルはすでに共有されています。';

  @override
  String get thisRecordIdIsReservedBy =>
      'このレコード ID は削除マーカーで保持されているため、再作成できません。ごみ箱から復元するか、新しい ID でレコードを作成してください。';

  @override
  String get thisRecordWasUpdatedOnAnother =>
      'このレコードは別のデバイスで更新されたため、競合ブランチを保持しました。';

  @override
  String get thisRecordHasNoHistoricalVersion => 'このレコードには復元できる過去のバージョンがありません。';

  @override
  String get thisRecordsHostIdentityCantBe =>
      'このレコードのホストの ID を検証できないため、他のデータを上書きしないよう保存を中止しました。';

  @override
  String get backgroundSyncNotificationsAreTurnedOff =>
      'このデバイスではバックグラウンド同期の通知がオフになっています。';

  @override
  String get backgroundSyncNotificationsAreOnFor =>
      'このデバイスではバックグラウンド同期の通知がオンになっています。';

  @override
  String get thisDeviceWasRevokedSignIn =>
      'このデバイスは失効しています。管理者が承認したデバイスで再度サインインしてください。';

  @override
  String get thisAccountIsntAMemberOf => 'このアカウントは現在の保管庫のメンバーではありません。';

  @override
  String get thisAccountNameDoesntMatchThe => 'このアカウント名は現在サインイン中のアカウントと一致しません。';

  @override
  String get thisChangeCantBeMadeIn => 'アカウントの現在の状態ではこの変更を実行できません。';

  @override
  String get theresNoMasterPasswordChangeWaiting => '確認待ちのマスターパスワードの変更はありません。';

  @override
  String get theresNoServerIdentityRecoveryWaiting => '確認待ちのサーバー ID の復元はありません。';

  @override
  String get theresNoActivePrometheusScrapeCredential =>
      '有効な Prometheus のスクレイプ認証情報はありません。';

  @override
  String get theParentGroupNoLongerExists2 =>
      '親グループはもう存在しません。別の親または最上位グループを選択してください。';

  @override
  String get invalidParentGroupChooseAValid =>
      '親グループが無効です。有効なグループまたは最上位グループを選択してください。';

  @override
  String thePasswordCredentialReferencedBySnippet(String name) {
    return 'スニペットのパラメーター「$name」が参照するパスワード認証情報が存在しないか利用できないため、保存を中止しました。';
  }

  @override
  String get theSnippetCommandCantBeEmpty => 'スニペットのコマンドは必須です';

  @override
  String get theSnippetTitleCantBeEmpty => 'スニペットのタイトルは必須です';

  @override
  String get userName => 'ユーザー名';

  @override
  String get theSignInSessionWasRestored =>
      'サインインセッションを復元しました。マスターパスワードを入力して、暗号化されたワークスペースのロックを解除してください。';

  @override
  String get theSignInSessionDeviceId =>
      'サインインセッションのデバイス ID がローカルのデバイス ID と一致しません。';

  @override
  String get theSignInResponseDoesntMatch => 'サインインの応答が現在のアカウントまたはデバイスと一致しません。';

  @override
  String get theSignInStateChangedTry => 'サインインの状態が変わりました。もう一度お試しください。';

  @override
  String get theSignInStateExpiredSign =>
      'サインインの状態が期限切れになりました。もう一度サインインしてください。';

  @override
  String get theSignedInAccountChangedSign =>
      'サインイン中のアカウントが変わりました。サインアウトしてから新しいマスターパスワードで再度サインインしてください。';

  @override
  String get invalidFolderNameFormat => 'フォルダー名の形式が無効です';

  @override
  String get theDestinationVaultsCurrentServerState =>
      '移行先の保管庫の現在のサーバー状態はまだ検証されていません。スナップショットの復元が完了してから移行を続けてください。';

  @override
  String get theTargetHostsSshCredentialChanged =>
      '接続の準備中に対象ホストの SSH 認証情報が変更されました。再接続してください。';

  @override
  String get theTargetMemberHasNoActive =>
      '対象のメンバーには新しい保管庫鍵を受け取れるアクティブなデバイスがないため、所有権の移転をキャンセルしました。';

  @override
  String get theTargetAccountIsNoLonger =>
      '対象のアカウントは現在の管理一覧にありません。更新してから、もう一度お試しください。';

  @override
  String get thePrivateKeyCantBeEmpty => '秘密鍵は必須です';

  @override
  String get theWindowSetHasASync => 'ウィンドウセットに同期の競合があります。先に競合を解決してください。';

  @override
  String get theWindowSetIsBeingSaved => 'ウィンドウセットを保存中です。しばらくしてからもう一度お試しください。';

  @override
  String get port2 => 'ポート';

  @override
  String get theSignedMembershipEntryHasAn => '署名済みのメンバーシップ項目の形式が無効です。';

  @override
  String get theSignedMembershipListDoesntMatch =>
      '署名済みのメンバーリストがサーバーの ACL の状態と一致しません。更新してから、もう一度お試しください。';

  @override
  String get theSignedMembershipListDoesntMatch2 =>
      '署名済みのメンバーリストがサーバーのメンバーディレクトリと一致しません。';

  @override
  String get theSignedMembershipListContainsInvalid =>
      '署名済みのメンバーリストに無効または重複したメンバーが含まれています。';

  @override
  String get theSignedMembershipListIsMissing =>
      '署名済みのメンバーリストに、サーバー上の既存のメンバーが含まれていません。';

  @override
  String get theAdminAuditCursorExpiredThe =>
      '管理者の監査カーソルが期限切れになりました。インスタンスまたはサーバーの世代が変わった可能性があります。最初のページから再読み込みしてください。';

  @override
  String get theAdminAuditCursorIsInvalid =>
      '管理者の監査カーソルが無効か、現在の管理者／インスタンスのものではありません。最初のページから再読み込みしてください。';

  @override
  String get theTerminalVaultOrSignedIn =>
      'ターミナル、保管庫、またはサインイン中のデバイスが変わったため、共有をキャンセルしました。';

  @override
  String get terminalSharingStoppedBecauseAnObservers =>
      'オブザーバーの接続が遅すぎるため、ターミナルの共有を停止しました。SSH 接続は引き続き使用できます。';

  @override
  String get terminalSharingHasntDisconnectedYet => 'ターミナルの共有はまだ切断されていません。';

  @override
  String get terminalSharingDisconnectedTheSshConnection =>
      'ターミナルの共有が切断されました。SSH 接続は引き続き使用できます。';

  @override
  String get terminalSharingDisconnectedTheSshConnection2 =>
      'ターミナルの共有が切断されました。SSH 接続は引き続き使用できます。';

  @override
  String get theTerminalSharingConnectionWasDisconnected =>
      'ターミナルの共有の接続が切断されました。';

  @override
  String get terminalFontSize => 'ターミナルのフォントサイズ';

  @override
  String get terminalFontSizePreferenceSavedEncrypted =>
      'ターミナルのフォントサイズの設定を暗号化して保存しました。現在の保管庫を通じて他のデバイスに同期されます。';

  @override
  String get theTerminalFontSizePreferenceNeeds =>
      'ターミナルのフォントサイズの設定は、先に明示的な修復が必要です。';

  @override
  String get aHostReferencedByTheTerminal =>
      'ターミナルが参照するホストが現在の保管庫にありません。ホストを開き直してからレイアウトを保存してください。';

  @override
  String get terminalShortcuts => 'ターミナルのショートカット';

  @override
  String get terminalShortcutPreferenceSavedEncryptedIt =>
      'ターミナルのショートカットの設定を暗号化して保存しました。現在の保管庫を通じて他のデバイスに同期されます。';

  @override
  String get theTerminalShortcutPreferenceNeedsAn =>
      'ターミナルのショートカットの設定は、先に明示的な修復が必要です。';

  @override
  String get theTerminalControlChannelDisconnectedThe =>
      'ターミナルの制御チャネルが切断されました。SSH 接続は引き続き使用できます。';

  @override
  String get terminalColors => 'ターミナルの配色';

  @override
  String get terminalColorPreferenceSavedEncryptedIt =>
      'ターミナルの配色の設定を暗号化して保存しました。現在の保管庫を通じて他のデバイスに同期されます。';

  @override
  String get theTerminalColorPreferenceNeedsAn => 'ターミナルの配色の設定は、先に明示的な修復が必要です。';

  @override
  String get maintenanceJobSubmittedRefreshTheJob =>
      'メンテナンスジョブを送信しました。ジョブ一覧を更新すると状態を確認できます。';

  @override
  String get automaticStatusChecksArePausedYou =>
      '自動の状態チェックは一時停止中です。ジョブの状態は手動で更新できます。';

  @override
  String get scheduledBackupsTurnedOff => 'スケジュールバックアップをオフにしました。';

  @override
  String get scheduledBackupSettingsSaved => 'スケジュールバックアップの設定を保存しました。';

  @override
  String get authenticationMethod => '認証方式';

  @override
  String get theRecordWasClearedFromThis =>
      'レコードはこのデバイスのアクティブなキャッシュから消去され、サーバーの署名付き証明を受信しましたが、同期カーソルの追従に失敗しました。同期を再試行すると、送信待ちの内容を処理する前にクリーンアップのマーカーを取得します。';

  @override
  String thePublicKeysForDeviceDeviceid(String deviceId) {
    return 'デバイス $deviceId の公開鍵が、アカウントのディレクトリと保管庫のディレクトリで一致しません。';
  }

  @override
  String theEncryptionPublicKeyOfDevice(String deviceId) {
    return 'デバイス $deviceId の暗号化用公開鍵の長さが無効です。';
  }

  @override
  String theKeyEnvelopeTargetForDevice(String deviceId) {
    return 'デバイス $deviceId の鍵エンベロープの宛先が無効か重複しています。';
  }

  @override
  String theSigningPublicKeyOfDevice(String deviceId) {
    return 'デバイス $deviceId の署名用公開鍵の長さが無効です。';
  }

  @override
  String get deviceRevoked2 => 'デバイスを失効させました。';

  @override
  String get deviceAddedGiveTheApprovalResult =>
      'デバイスを追加しました。承認結果を新しいデバイスに渡し、そこでインポートしてください。';

  @override
  String get theVaultKeyEnvelopeInThe => 'デバイス承認内の保管庫鍵エンベロープの形式が無効です。';

  @override
  String get theKeyEnvelopeContextInThe => 'デバイス承認内の鍵エンベロープのコンテキストが無効です。';

  @override
  String get theDeviceApprovalContainsDuplicateVault =>
      'デバイスの承認に重複した保管庫鍵エンベロープが含まれています。';

  @override
  String get theDeviceApprovalFileHasAn => 'デバイスの承認ファイルの形式が無効です。';

  @override
  String get theDeviceApprovalFilesAccountOr => 'デバイス承認ファイルのアカウントまたは構造が無効です。';

  @override
  String get theDeviceApprovalCertificateFieldsAre => 'デバイス承認の証明書のフィールドがありません。';

  @override
  String get theDeviceRequestIsMalformedOr =>
      'デバイスのリクエストの形式が正しくないか、別のアカウントのものです。';

  @override
  String get thisAccountIsAlreadyAnActive =>
      'このアカウントはすでに保管庫のアクティブなメンバーです。承認済みデバイスによる承認手順を使ってください。';

  @override
  String get thisInvitationIsNoLongerWaiting =>
      'この招待はもう承諾待ちではありません。更新してから、もう一度お試しください。';

  @override
  String get closeASessionTabFirst => '先にセッションのタブを 1 つ閉じてください。';

  @override
  String get joinTheHostsTerminalShareFirst => '先にホストのターミナル共有に参加してください。';

  @override
  String get openThisAccountsSessionListFirst => '先にこのアカウントのセッション一覧を開いてください。';

  @override
  String get openAtLeastOneTerminalTab => '先にターミナルのタブを 1 つ以上開いてください。';

  @override
  String get signInAndUnlockTheAccount =>
      '先に信頼済みのデバイスでサインインしてアカウントのロックを解除してください。';

  @override
  String get signInFirst => '先にサインインしてください。';

  @override
  String get signInBeforeChangingMfaSettings => 'MFA の設定を変更する前にサインインしてください。';

  @override
  String get signInBeforeViewingMfaSettings => 'MFA の設定を表示する前にサインインしてください。';

  @override
  String get signInBeforeManagingThisDevices =>
      'このデバイスのバックグラウンド同期の通知を管理する前にサインインしてください。';

  @override
  String get signInAndUnlockTheSync => '先に同期アカウントにサインインしてロックを解除してください。';

  @override
  String get signInAndUnlockTheTarget => '先にサインインして対象の保管庫のロックを解除してください。';

  @override
  String get signInAndUnlockTheAccount2 => '先にサインインしてアカウントのロックを解除してください。';

  @override
  String get signInToThisAccountAnd =>
      '先にこのアカウントにサインインして、現在のデバイスのロックを解除してください。';

  @override
  String get resolveThePreferenceReadErrorFirst => '先に設定の読み込みエラーを解決してください。';

  @override
  String get unlockTheVaultFirst => '先に保管庫のロックを解除してください';

  @override
  String get unlockTheVaultFirst2 => '先に保管庫のロックを解除してください。';

  @override
  String get unlockAVaultBeforeSharingA => 'ターミナルを共有する前に保管庫のロックを解除してください。';

  @override
  String get unlockTheWorkspaceFirst => '先にワークスペースのロックを解除してください。';

  @override
  String get unlockTheCurrentVaultBeforeVerifying =>
      'SSH ホスト鍵を確認する前に、現在の保管庫のロックを解除してください。';

  @override
  String get unlockTheWorkspaceThatContainsThe =>
      '先に現在のホストを含むワークスペースのロックを解除してください。';

  @override
  String get unlockTheVaultThatOwnsThis => '先にこの共有セッションを所有する保管庫のロックを解除してください。';

  @override
  String get unlockTheAccountBeforeExportingA =>
      '共有リクエストをエクスポートする前に、アカウントのロックを解除してください。';

  @override
  String get connectToAnSshHostFirst => '先に SSH ホストに接続してください';

  @override
  String get connectSshBeforeStartingTerminalSharing =>
      'ターミナルの共有を開始する前に SSH に接続してください。';

  @override
  String get connectToTheServerFirst => '先にサーバーに接続してください。';

  @override
  String get connectTheHostForThisWorkspace => '先にこのワークスペースのペインのホストに接続してください。';

  @override
  String get chooseAVaultFirst => '先に保管庫を選択してください。';

  @override
  String get chooseAndUnlockAVaultFirst => '先に保管庫を選択してロックを解除してください。';

  @override
  String get configureTheServerAddressFirst => '先にサーバーのアドレスを設定してください';

  @override
  String get retryThePendingMasterPasswordChange =>
      'アカウントを削除する前に、確認待ちのマスターパスワードの変更を再試行してください。';

  @override
  String get tooManyRequestsTryAgainLater => 'リクエストが多すぎます。しばらくしてからもう一度お試しください。';

  @override
  String get waitForTheCurrentSyncOr => '現在の同期またはアーカイブの操作が完了するまでお待ちください。';

  @override
  String get enterAVaultName => '保管庫の名前を入力してください';

  @override
  String get enterTheBootstrapToken => 'ブートストラップトークンを入力してください';

  @override
  String get enterAGroupName => 'グループ名を入力してください。';

  @override
  String get enterTheCurrentMasterPassword => '現在のマスターパスワードを入力してください。';

  @override
  String get enterTheCurrentAccountNameAnd =>
      '再認証するには、現在のアカウント名とマスターパスワードを入力してください。';

  @override
  String get enterANameForTheNew => '新しい保管庫の名前を入力してください。';

  @override
  String get enterAValidTerminalSharingSession =>
      '有効なターミナル共有のセッション UUID を入力してください。';

  @override
  String get enterAValidAccountNameAnd => '有効なアカウント名と 1〜30 日の期間を入力してください。';

  @override
  String get enterTheServerAddress => 'サーバーのアドレスを入力してください';

  @override
  String get enterAnMfaCodeValidFor => 'このアカウントで有効な MFA コードを入力してください。';

  @override
  String get enterTheAccountInvitationTokenIssued =>
      '管理者が発行したアカウントの招待トークンを入力してください';

  @override
  String get enterTheAccountNameAndMaster => 'アカウント名とマスターパスワードを入力してください。';

  @override
  String get enterTheAccountPassword => 'アカウントのパスワードを入力してください。';

  @override
  String get enterTheAccountEmailUserName => 'アカウントのメールアドレス／ユーザー名を入力してください';

  @override
  String get enterTheInvitationToken => '招待トークンを入力してください。';

  @override
  String get choose1To8ActiveVault => 'アクティブな保管庫デバイスを 1〜8 台選択してください。';

  @override
  String chooseALabelPreferenceFromThe(String label) {
    return '現在の競合一覧から$labelの設定を 1 つ選択してください。';
  }

  @override
  String get theAccountIsStillTheOwner =>
      'このアカウントは、他のメンバーがいる共有保管庫のオーナーのままです。サーバーが所有権を自動で移転したり、他のアカウントのデータを削除したりすることはありません。他のメンバーを削除してから、もう一度お試しください。';

  @override
  String get theAccountSessionChangedSignIn =>
      'アカウントのセッションが変わりました。もう一度サインインしてからロックを解除してください。';

  @override
  String get theAccountDeletionGracePeriodHas =>
      'アカウント削除の猶予期間が終了したため、取り消すことはできません。';

  @override
  String theAccountDeletionWasCancelledThe(String valueValue) {
    return 'アカウントの削除予定を取り消しました。サーバーは古いセッションを復元しないため、パスワードを入力して再度サインインしてください。$valueValue';
  }

  @override
  String get theAccountResponseDoesntMatchThe => 'アカウントの応答が現在のセッションと一致しません。';

  @override
  String get accountSecuritySettingsAreBeingProcessed =>
      'アカウントのセキュリティ設定を処理中です。しばらくしてからもう一度お試しください。';

  @override
  String get invalidAccountKeyLength => 'アカウント鍵の長さが無効です。';

  @override
  String get invalidAccountKeyLengthTheMaster =>
      'アカウント鍵の長さが無効なため、マスターパスワードの変更を中止しました。';

  @override
  String get theAccountAlreadyHasAPending =>
      'このアカウントにはすでに保留中の削除があります。サインインページのアカウント復旧から取り消してください。';

  @override
  String theAccountEnteredItsDeletionGrace(
    String deadline,
    String valueValue,
    String valueValue2,
  ) {
    return 'アカウントは削除の猶予期間に入りました。サーバーの purge_after：$deadline。現在のセッションとこのデバイスのロック解除キーは消去されました。猶予期間中はサインインページで取り消すことができ、取り消した後は再度サインインが必要です。$valueValue$valueValue2';
  }

  @override
  String get accountRecoverySettingsAreBeingProcessed => 'アカウントの復旧設定を処理中です。';

  @override
  String get theAccountStateJustChangedSign =>
      'アカウントの状態が変わりました。表示するにはもう一度サインインしてください。';

  @override
  String get anAccountStateActionIsIn =>
      'アカウントの状態の操作を処理中です。しばらくしてからもう一度お試しください。';

  @override
  String get theInputControlAuthorizationOrVault =>
      '入力操作の承認または保管庫の状態が変わったため、参加をキャンセルしました。';

  @override
  String get theInputControlConnectionWasDisconnected => '入力操作の接続が切断されました。';

  @override
  String get theFingerprintYouEnteredDoesntMatch =>
      '入力したフィンガープリントが候補のインスタンス署名鍵と一致しません。';

  @override
  String get invalidMigrationDestinationVaultId => '移行先の保管庫 ID が無効です。';

  @override
  String get theMigrationDestinationVaultCouldntBe =>
      '移行先の保管庫を、このデバイスで書き込み可能なオーナーの保管庫として検証できませんでした。';

  @override
  String get theMigrationDestinationVaultCouldntBe2 =>
      '移行先の保管庫を開けませんでした。ローカルの移行ジャーナルは引き続き再開できます。';

  @override
  String get theMigrationDestinationVaultIsMissing =>
      '移行先の保管庫に最初の署名済みメンバーシップチェーンがありません。';

  @override
  String get invalidMigrationRecordId => '移行レコードの ID が無効です。';

  @override
  String get theRestoreJobFinishedButThe =>
      '復元ジョブは完了しましたが、隔離コピーの状態が検証されていないため、ここから操作できません。';

  @override
  String get remoteDesktopRequiresASignIn => 'リモートデスクトップにはサインインゲートウェイが必要です。';

  @override
  String get invalidRemoteFileNameFormat => 'リモートのファイル名の形式が無効です';

  @override
  String get invalidRemoteFilePathFormat => 'リモートのファイルパスの形式が無効です';

  @override
  String get notificationPermissionWasntGrantedBackgroundSync =>
      '通知の権限が許可されていないため、バックグラウンド同期の通知は登録されませんでした。';

  @override
  String get invitationCreatedGiveTheOneTime =>
      '招待を作成しました。信頼できる経路でワンタイムトークンを対象のアカウントに渡してください。';

  @override
  String get theInvitationWasAcceptedButThis =>
      '招待は承諾されましたが、このデバイスは招待された保管庫に切り替えられませんでした。その保管庫を選択し直して同期してください。';

  @override
  String get theInvitationWasAcceptedButThis2 =>
      '招待は承諾されましたが、このデバイスは復号できる保管庫鍵エンベロープを受け取っていません。招待者にデバイスの公開鍵を確認してもらってください。';

  @override
  String get theInvitationRoleCanOnlyBe =>
      '招待のロールは editor または viewer のみ指定できます。';

  @override
  String get someLocalRecordsCouldntBeVerified3 =>
      '一部のローカルレコードを検証できないため、ホストのグループ、認証情報、踏み台ホストの参照を安全に確認できません。先に保管庫を修復するか再同期してください。';

  @override
  String get someLocalRecordsCouldntBeVerified4 =>
      '一部のローカルレコードを検証できないため、認証情報の参照を安全に確認できません。先に保管庫を修復するか再同期してください。';

  @override
  String get someLocalRecordsCouldntBeVerified =>
      '一部のローカルレコードを検証できないため、グループの参照を安全に確認できません。先に保管庫を修復するか再同期してください。';

  @override
  String get someLocalRecordsCouldntBeVerified2 =>
      '一部のローカルレコードを検証できないため、スニペットの SSH 認証情報の参照を安全に確認できません。先に保管庫を修復するか再同期してください。';

  @override
  String get theQuotaMustBeBetween1 => 'クォータは 1 バイトから 1 TiB の範囲で指定してください。';

  @override
  String get theReVerifiedAccountMustMatch =>
      '再認証するアカウントは、現在サインイン中のアカウントと一致している必要があります。';

  @override
  String get theIsolatedCopyIsntVerifiedYet =>
      '隔離コピーはまだ検証されていません。サーバーはクリーンアップの前に所属と整合性を検証します。';

  @override
  String get theIsolatedCopyWasDiscardedYou =>
      '隔離コピーを破棄しました。元のアーカイブから再度準備できます。';

  @override
  String get isolatedCopyCleanupHasntFinishedYou =>
      '隔離コピーのクリーンアップはまだ完了していません。安全に再試行できます。';

  @override
  String get isolatedCopyCleanupDidntFinishYou =>
      '隔離コピーのクリーンアップが完了していません。安全に再試行できます。';

  @override
  String get theIsolatedRestoreCopyPreparationJob3 =>
      '隔離された復元用コピーの準備ジョブが中断されました。稼働中のデータは変更されていません。';

  @override
  String get theIsolatedRestoreCopyPreparationJob =>
      '隔離された復元用コピーの準備ジョブを受け付けました。このジョブでコピーが有効化されたり、稼働中のデータが置き換えられたりすることはありません。';

  @override
  String get theIsolatedRestoreCopyPreparationJob2 =>
      '隔離された復元用コピーの準備ジョブが終了しました。稼働中のデータは変更されていません。';

  @override
  String get theIsolatedRestoreCopyWasDiscarded =>
      '隔離された復元用コピーを破棄しました。元のアーカイブと稼働中のデータは変更されていません。';

  @override
  String get theIsolatedRestoreCopyIsReady =>
      '隔離された復元用コピーの準備ができました。稼働中のデータは変更されていません。';

  @override
  String get theIsolatedRestoreCopyIsReady2 =>
      '隔離された復元用コピーの準備はできましたが、ジョブの状態の更新が中断されました。稼働中のデータは変更されていません。';

  @override
  String get theIsolatedRestoreCopyIsInvalid =>
      '隔離された復元用コピーが無効です。ジョブ一覧を更新してから、もう一度お試しください。';

  @override
  String get theIsolatedRestoreCopyFailedVerification =>
      '隔離された復元用コピーの検証に失敗しました。サーバーは不明なファイルを削除していません。インスタンスの運用者に連絡してください。';

  @override
  String get theIsolatedRestoreCopyStateChanged =>
      '隔離された復元用コピーの状態が変わりました。ジョブ一覧を更新してから、もう一度お試しください。';

  @override
  String get theDefaultSshCredentialNoLonger =>
      '既定の SSH 認証情報はもう存在しません。有効な認証情報を選択するか、既定をクリアしてください。';

  @override
  String get defaultWorkspace => '既定のワークスペース';

  @override
  String get defaultWorkspacePreferenceSavedEncryptedIt =>
      '既定のワークスペースの設定を暗号化して保存しました。現在の保管庫を通じて他のデバイスに同期されます。';

  @override
  String get theDefaultWorkspacePreferenceNeedsAn =>
      '既定のワークスペースの設定は、先に明示的な修復が必要です。';

  @override
  String restoreDeadlineFormat(String format) {
    return '（復元期限：$format）';
  }

  @override
  String get unsupportedArgon2idParameters => '対応していない Argon2id のパラメーターです。';

  @override
  String get notASupportedAtermiusEncryptedArchive =>
      '対応している Atermius の暗号化アーカイブではありません。';

  @override
  String get anEncryptedArchiveChunkIsTruncated => '暗号化アーカイブのチャンクが途中で切れています。';

  @override
  String get theEncryptedArchiveExceedsTheFile => '暗号化アーカイブがファイルサイズの上限を超えています。';

  @override
  String get anArchiveObjectIsEmptyOr => 'アーカイブのオブジェクトが空か、上限の 32 MiB を超えています。';

  @override
  String get invalidArchiveArgon2idSaltLength => 'アーカイブの Argon2id のソルト長が無効です。';

  @override
  String get theArchiveContentExceedsTheSize => 'アーカイブの内容が処理可能なサイズの上限を超えています。';

  @override
  String get theArchiveChunkLengthDoesntMatch => 'アーカイブのチャンク長が一致しません。';

  @override
  String get theArchiveHeaderIsntCanonicalJson =>
      'アーカイブのヘッダーが正規化された JSON ではありません。';

  @override
  String get theArchiveHeaderHasUnknownOr => 'アーカイブのヘッダーに不明または不完全なフィールドがあります。';

  @override
  String get theArchiveHeaderExceedsTheSize => 'アーカイブのヘッダーがサイズ上限を超えています。';

  @override
  String get invalidArchiveHeaderLength => 'アーカイブのヘッダー長が無効です。';

  @override
  String get wrongArchivePasswordOrTheArchive =>
      'アーカイブのパスワードが間違っているか、アーカイブの内容の整合性検証に失敗しました。';

  @override
  String get theTotalArchiveObjectDataExceeds =>
      'アーカイブのオブジェクトデータの合計が上限を超えています。';

  @override
  String get theNumberOfArchiveObjectsExceeds => 'アーカイブのオブジェクト数が上限を超えています。';

  @override
  String get theArchiveHasTrailingDataOr => 'アーカイブの末尾に余分なデータがあるか、内容が不完全です。';

  @override
  String get theArchiveFileSizeIsInvalid => 'アーカイブファイルのサイズが無効か、上限を超えています。';

  @override
  String get theArchiveFileIsTruncated => 'アーカイブファイルが途中で切れています。';

  @override
  String get invalidArchivePlaintextSize => 'アーカイブの平文のサイズが無効です。';

  @override
  String get invalidArchivePlaintextType => 'アーカイブの平文の種類が無効です。';

  @override
  String get theArchivePlaintextExceedsTheFile => 'アーカイブの平文がファイルサイズの上限を超えています。';

  @override
  String get theArchiveManifestIsntCanonicalJson =>
      'アーカイブのマニフェストが正規化された JSON ではありません。';

  @override
  String get theArchiveManifestExceedsThe16 =>
      'アーカイブのマニフェストが上限の 16 MiB を超えています。';

  @override
  String get invalidArchiveManifestLength => 'アーカイブのマニフェストの長さが無効です。';

  @override
  String get theArchiveVersionServerSpaceOr =>
      'アーカイブのバージョン、サーバースペース、または保管庫が現在の対象と一致しません。スペース間や保管庫間のインポートにはまだ対応していません。';

  @override
  String get theArchiveLengthOrChunkParameters =>
      'アーカイブの長さまたはチャンクのパラメーターがリソースの上限を超えています。';

  @override
  String get theSeparateArchivePasswordMustBe =>
      'アーカイブ専用のパスワードは 12 UTF-8 バイト以上にしてください。';

  @override
  String get invalidDecryptedArchiveChunkLength => '復号したアーカイブのチャンク長が無効です。';

  @override
  String get notASupportedLocalEncryptedArchive =>
      '対応しているローカルの暗号化アーカイブではありません。';

  @override
  String get aLocalEncryptedArchiveChunkIs => 'ローカルの暗号化アーカイブのチャンクが途中で切れています。';

  @override
  String get theLocalEncryptedArchiveExceedsThe =>
      'ローカルの暗号化アーカイブがファイルサイズの上限を超えています。';

  @override
  String get unsupportedLocalArchiveArgon2idParameters =>
      '対応していないローカルアーカイブの Argon2id のパラメーターです。';

  @override
  String get invalidSshTrustRecordMetadataIn =>
      'ローカルアーカイブの SSH 信頼レコードのメタデータが無効です。';

  @override
  String get invalidOrderOrUniquenessOfSsh =>
      'ローカルアーカイブの SSH 信頼レコードの順序または一意性が無効です。';

  @override
  String get theNumberOfSshTrustRecords => 'ローカルアーカイブの SSH 信頼レコードの数が上限を超えています。';

  @override
  String get invalidSshTrustRecordInThe => 'ローカルアーカイブの SSH 信頼レコードが無効です。';

  @override
  String get invalidBase64urlEncodingInTheLocal =>
      'ローカルアーカイブの base64url エンコードが無効です。';

  @override
  String get invalidLocalArchiveSaltLength => 'ローカルアーカイブのソルト長が無効です。';

  @override
  String get theLocalArchiveContentIsntCanonical =>
      'ローカルアーカイブの内容が正規化された JSON ではありません。';

  @override
  String get theLocalArchiveContentIsEmpty => 'ローカルアーカイブの内容が空か、サイズ上限を超えています。';

  @override
  String get unsupportedLocalArchiveContentFormatOr =>
      '対応していないローカルアーカイブの内容の形式またはバージョンです。';

  @override
  String get theLocalArchiveChunkLengthDoesnt => 'ローカルアーカイブのチャンク長が一致しません。';

  @override
  String get theLocalArchivePassphraseMustBe =>
      'ローカルアーカイブのパスフレーズは 12〜1024 UTF-8 バイトにしてください。';

  @override
  String get theLocalArchiveContainsDuplicateRecord =>
      'ローカルアーカイブに重複したレコード ID が含まれています。';

  @override
  String get theLocalArchiveSizeIsInvalid => 'ローカルアーカイブのサイズが無効か、上限を超えています。';

  @override
  String get theLocalArchiveHeaderIsntCanonical =>
      'ローカルアーカイブのヘッダーが正規化された JSON ではありません。';

  @override
  String get theLocalArchiveHeaderHasUnknown =>
      'ローカルアーカイブのヘッダーに不明または不完全なフィールドがあります。';

  @override
  String get theLocalArchiveHeaderExceedsThe => 'ローカルアーカイブのヘッダーがサイズ上限を超えています。';

  @override
  String get invalidLocalArchiveHeaderLength => 'ローカルアーカイブのヘッダー長が無効です。';

  @override
  String get wrongLocalArchivePasswordOrThe =>
      'ローカルアーカイブのパスワードが間違っているか、アーカイブの整合性検証に失敗しました。';

  @override
  String get theLocalArchiveHasTrailingData =>
      'ローカルアーカイブの末尾に余分なデータがあるか、内容が不完全です。';

  @override
  String get theLocalArchiveFileIsTruncated => 'ローカルアーカイブファイルが途中で切れています。';

  @override
  String get theLocalArchivePlaintextIsEmpty => 'ローカルアーカイブの平文が空か、上限を超えています。';

  @override
  String get theLocalArchivePlaintextExceedsThe => 'ローカルアーカイブの平文がサイズ上限を超えています。';

  @override
  String get unsupportedLocalArchiveFormatOrVersion =>
      '対応していないローカルアーカイブの形式またはバージョンです。';

  @override
  String get invalidDecryptedChunkLengthInThe => 'ローカルアーカイブの復号したチャンク長が無効です。';

  @override
  String get theLocalArchiveRecordListExceeds => 'ローカルアーカイブのレコード一覧が上限を超えています。';

  @override
  String get invalidRecordOrderOrUniquenessIn =>
      'ローカルアーカイブのレコードの順序または一意性が無効です。';

  @override
  String get theNumberOfRecordsInThe => 'ローカルアーカイブのレコード数が上限を超えています。';

  @override
  String get invalidLocalArchiveRecord => 'ローカルアーカイブのレコードが無効です。';

  @override
  String get theLocalArchiveLengthOrChunk =>
      'ローカルアーカイブの長さまたはチャンクのパラメーターが上限を超えています。';

  @override
  String get theVaultMembershipChainIsMissing =>
      '保管庫のメンバーシップチェーンがないか、上限を超えています。';

  @override
  String get aDeviceSequenceFloorIsOut => 'device sequence floor が安全な範囲外です。';

  @override
  String get invalidDeviceSequenceFloorsFormat =>
      'device sequence floors の形式が無効です。';

  @override
  String get theEpochKeySha256Doesnt => 'エポック鍵の SHA-256 がバイナリブロックと一致しません。';

  @override
  String get theEpochKeyDescriptorsDontMatch => 'エポック鍵の記述子が鍵エンベロープのセットと一致しません。';

  @override
  String get invalidDeviceSignatureOnTheEpoch => 'エポック鍵のデバイス署名が無効です。';

  @override
  String get theEpochKeyProofSignerIsnt =>
      'エポック鍵の証明の署名者は、そのバージョンの保管庫のメンバーではありません。';

  @override
  String epochEpochMapsToInconsistentVault(int epoch) {
    return 'エポック $epoch に一致しない保管庫の鍵が対応しています。';
  }

  @override
  String get theUnsealedKeyEnvelopeDoesntMatch =>
      '開封した鍵エンベロープがローカルのエポック鍵と一致しません。';

  @override
  String get invalidMembershipEncryptionFingerprint =>
      'メンバーシップの暗号化フィンガープリントが無効です。';

  @override
  String get invalidMembershipMemberRoleStateId =>
      'メンバーシップのメンバーのロール／状態／ID が無効です。';

  @override
  String get theMembershipSignerWasntAnActive =>
      'メンバーシップの署名者は、対応する署名済みバージョンでアクティブなオーナーではありませんでした。';

  @override
  String get objectRefsMustBeUniqueLowercase =>
      'object_refs は、厳密な昇順で一意の小文字の UUID である必要があります。';

  @override
  String get objectRefsIsntAnArrayOr => 'object_refs が配列でないか、1024 件を超えています。';

  @override
  String get theSnapshotCurrentHeadIsInconsistent =>
      'スナップショットの現在の先頭が、同じ固定された履歴の水位と一致しません。';

  @override
  String get theSnapshotHeadCommitSeqDoesnt =>
      'スナップショットの先頭の commit_seq が固定された履歴の水位と一致しません。';

  @override
  String get theSnapshotHeadCommitSeqExceeds =>
      'スナップショットの先頭の commit_seq が固定されたスナップショットの水位を超えています。';

  @override
  String get aSnapshotHeadIsMissingFields => 'スナップショットの先頭にフィールドの欠落または重複があります。';

  @override
  String get theSnapshotHeadSetDoesntCover =>
      'スナップショットの先頭のセットがすべての履歴レコードを網羅していません。';

  @override
  String fieldMustBeADecimalString(String field) {
    return '$field は 10 進数の文字列である必要があります。';
  }

  @override
  String labelMustBeAJsonObject(String label) {
    return '$label は JSON オブジェクトである必要があります。';
  }

  @override
  String uploadedObjectObjectidFailedReadBack(String objectId) {
    return 'アップロードしたオブジェクト $objectId の読み戻し検証に失敗しました。';
  }

  @override
  String get revisionCommitSeqIsntMonotonicOr =>
      'リビジョンの commit_seq が単調でないか、スナップショットの水位を超えています。';

  @override
  String get theRevisionHistoryCursorIsInvalid => 'リビジョン履歴のカーソルが無効か、重複しています。';

  @override
  String get theRevisionHistoryExceedsTheArchive =>
      'リビジョンの履歴がアーカイブの項目数の上限を超えています。';

  @override
  String get theServerGenerationDiffersBetweenRevision =>
      'リビジョンと競合の履歴ページでサーバーの世代が一致しません。';

  @override
  String get conflictSeqIsntMonotonicOrExceeds =>
      'conflict_seq が単調でないか、スナップショットの水位を超えています。';

  @override
  String get aConflictBranchReferencesABase =>
      '競合ブランチがスナップショット外のベースリビジョンを参照しています。';

  @override
  String get theConflictHistoryCursorIsInvalid => '競合の履歴のカーソルが無効か、重複しています。';

  @override
  String get theConflictHistoryExceedsTheArchive =>
      '競合の履歴がアーカイブの項目数の上限を超えています。';

  @override
  String get aConflictResolutionReferencesARevision =>
      '競合の解決がスナップショット外のリビジョンを参照しています。';

  @override
  String get theConflictResolutionStateAndResolution =>
      '競合の解決の状態と resolution_seq が一致しません。';

  @override
  String get encryptedArchiveFile => '暗号化アーカイブファイル';

  @override
  String get theHistorySnapshotContainsADuplicate =>
      '履歴のスナップショットに重複した conflict_id が含まれています。';

  @override
  String get theHistorySnapshotContainsADuplicate2 =>
      '履歴のスナップショットに重複した revision_id が含まれています。';

  @override
  String historicalSigningDeviceIdIsntIn(String id) {
    return '過去の署名デバイス $id は検証可能な保管庫ディレクトリにありません。';
  }

  @override
  String get historyEntriesExceedTheArchiveResource =>
      '履歴の項目がアーカイブのリソース上限を超えています。';

  @override
  String get aHistoryPageDoesntMatchThe =>
      '履歴ページが固定された保管庫のスナップショットのコンテキストと一致しません。';

  @override
  String get theSameDeviceIdHasConflicting =>
      '同じデバイス ID に競合する公開鍵ディレクトリの項目があります。';

  @override
  String get pinningTheServerHistorySnapshot => 'サーバーの履歴のスナップショットを固定';

  @override
  String sha256OfObjectIdDoesnt(String id) {
    return 'オブジェクト $id の SHA-256 が内容のダイジェストと一致しません。';
  }

  @override
  String objectIdIsReferencedByVerified(String id) {
    return 'オブジェクト $id は検証済みのレコードから参照されていますが、サーバーにもローカルのアーカイブキャッシュにも内容がありません。不完全なアーカイブは作成しません。';
  }

  @override
  String get unsupportedArchiveBinaryBlockKind => '対応していないアーカイブのバイナリブロックの種類です。';

  @override
  String get archiveBinaryBlockOffsetsHaveGaps =>
      'アーカイブのバイナリブロックのオフセットに欠落、重複、または上限超過があります。';

  @override
  String get tooManyArchiveBinaryBlocks => 'アーカイブのバイナリブロックが多すぎます。';

  @override
  String get theArchiveBinaryBlocksDontCover =>
      'アーカイブのバイナリブロックがペイロード全体を網羅していません。';

  @override
  String get duplicateArchiveBinaryObjectId => 'アーカイブのバイナリ object_id が重複しています。';

  @override
  String get invalidArchiveConflictResolutionOutboxLink =>
      'アーカイブの競合の解決と送信トレイの関連付けが無効です。';

  @override
  String get invalidArchiveConflictOrderWatermarkOr =>
      'アーカイブの競合の順序、水位、または一意性が無効です。';

  @override
  String get theArchiveCreatedAtIsntAn =>
      'アーカイブの created_at が RFC3339 形式の時刻ではありません。';

  @override
  String get invalidArchiveEpochKeyBinaryBlock => 'アーカイブのエポック鍵のバイナリブロックが無効です。';

  @override
  String get theArchiveEpochKeyBlockDoesnt =>
      'アーカイブのエポック鍵ブロックが署名済みの記述子と一致しません。';

  @override
  String archiveEpochKeyKeyDoesntMatch(String key) {
    return 'アーカイブのエポック鍵 $key がこのデバイスの鍵と一致しません。';
  }

  @override
  String get theArchiveGraveyardCountDoesntMatch =>
      'アーカイブの削除済み一覧の件数がスナップショットの削除マーカーと一致しません。';

  @override
  String get theArchiveGraveyardDoesntMatchThe =>
      'アーカイブの削除済み一覧が検証済みの削除マーカーと一致しません。';

  @override
  String get invalidArchiveKeyEnvelopeContextOr =>
      'アーカイブの鍵エンベロープのコンテキストまたは一意性が無効です。';

  @override
  String get invalidArchiveKeyEnvelopeSealingFormat =>
      'アーカイブの鍵エンベロープの封印形式が無効です。';

  @override
  String get invalidArchiveKeyEnvelopeSignature => 'アーカイブの鍵エンベロープの署名が無効です。';

  @override
  String get invalidArchiveLocalPendingSchema =>
      'アーカイブの local_pending のスキーマが無効です。';

  @override
  String get theArchiveMembershipDoesntIncludeThe =>
      'アーカイブのメンバーシップに現在のアカウントが含まれていません。';

  @override
  String get theArchiveMembershipIsntAValid =>
      'アーカイブのメンバーシップは現在の保管庫のチェーンの有効な先頭部分ではありません。';

  @override
  String get theArchiveMembershipIsNewerThan =>
      'アーカイブのメンバーシップは現在の保管庫のチェーンより新しいです。';

  @override
  String get theArchiveObjectBlockSetDiffers =>
      'アーカイブのオブジェクトブロックのセットが検証済みの object_refs と完全には一致しません。';

  @override
  String get theArchiveOutboxBaseEnvelopeIs =>
      'アーカイブの送信トレイのベースエンベロープにベースリビジョンがありません。';

  @override
  String get anArchiveOutboxDeviceSeqIs =>
      'アーカイブの送信トレイの device_seq が安全な整数の範囲外です。';

  @override
  String get invalidArchiveOutboxState => 'アーカイブの送信トレイの状態が無効です。';

  @override
  String get anArchiveRevisionIsDuplicatedOr =>
      'アーカイブのリビジョンが重複しているか、ベースのチェーンが連続していません。';

  @override
  String get anArchiveSignedEnvelopeIsMissing => 'アーカイブの署名済みエンベロープにヘッダーがありません。';

  @override
  String get invalidArchiveSnapshotCursorGeneration =>
      'アーカイブのスナップショットのカーソル／世代が無効です。';

  @override
  String get anArchiveTombstoneDoesntMatchThe =>
      'アーカイブの削除マーカーが最新の履歴レコードと一致しません。';

  @override
  String get unsupportedArchiveVaultRole => '対応していないアーカイブの vault_role です。';

  @override
  String get invalidArchiveRevisionOrderOrWatermark =>
      'アーカイブのリビジョンの順序または水位が無効です。';

  @override
  String get theArchiveConflictBaseRevisionDoesnt =>
      'アーカイブの競合のベースリビジョンが存在しません。';

  @override
  String get anArchiveConflictEnvelopeHasNo =>
      'アーカイブの競合エンベロープに署名済みのヘッダーがありません。';

  @override
  String get anArchiveConflictResolutionPointsTo => 'アーカイブの競合の解決が無効な対象を指しています。';

  @override
  String get duplicateExternalDeviceOutboxConflictId =>
      'アーカイブ内の外部デバイスの送信トレイの競合 ID が重複しています。';

  @override
  String archiveFieldKeyIsMissingOr(String key) {
    return 'アーカイブのフィールド $key がないか、無効です。';
  }

  @override
  String get invalidArchiveFieldType => 'アーカイブのフィールドの型が無効です。';

  @override
  String get anArchiveObjectIdLengthOr =>
      'アーカイブのオブジェクト ID、長さ、または SHA-256 が適用前の検証に失敗しました。アップロードやローカルデータベースへの書き込みは行われていません。';

  @override
  String sha256MismatchForArchiveObject(String objectId) {
    return 'アーカイブのオブジェクト $objectId の SHA-256 が一致しません。';
  }

  @override
  String get theNumberOfEncryptedObjectsReferenced =>
      'アーカイブが参照する暗号化オブジェクトの数が上限を超えています。';

  @override
  String get theArchiveMustBeBoundTo =>
      'アーカイブは、エクスポートした 1 台のデバイスの鍵エンベロープのセットに紐付けられている必要があります。';

  @override
  String get unsupportedArchiveLocalConflictKindState =>
      '対応していないアーカイブのローカル競合の種類／状態です。';

  @override
  String get invalidLinkBetweenArchiveLocalConflict =>
      'アーカイブのローカル競合の解決状態の関連付けが無効です。';

  @override
  String get duplicateArchiveLocalConflictId =>
      'アーカイブのローカルの conflict_id が重複しています。';

  @override
  String get theArchivesLocalOutboxBaseRevision =>
      'アーカイブのローカル送信トレイの base_revision を検証できません。';

  @override
  String get theArchivesLocalOutboxMetadataIs =>
      'アーカイブのローカル送信トレイのメタデータが無効か、重複しています。';

  @override
  String get theArchiveFormatFieldsAreInvalid =>
      'アーカイブの形式のフィールドが無効か、現在のサービススペース／保管庫と異なります。';

  @override
  String get anArchiveRecordDeviceSeqIs => 'アーカイブのレコードの device_seq が安全な範囲外です。';

  @override
  String get anArchiveDevicePublicKeyIs => 'アーカイブのデバイスの公開鍵が無効か、重複しています。';

  @override
  String archiveDeviceDirectoryKeyDoesntMatch(String key) {
    return 'アーカイブのデバイスディレクトリ $key が現在の保管庫ディレクトリと一致しません。';
  }

  @override
  String get invalidArchiveDeviceDirectoryOrMembership =>
      'アーカイブのデバイスディレクトリまたはメンバーシップチェーンの形式が無効です。';

  @override
  String get theCurrentVaultMembershipChainIs => '現在の保管庫のメンバーシップチェーンが無効です。';

  @override
  String get theCurrentVaultDeviceIsntUnlocked =>
      '現在の保管庫／デバイスのロックが解除されていないため、アーカイブを作成できません。';

  @override
  String get thisDeviceHasNoVaultEpoch => 'このデバイスにはエクスポートできる保管庫のエポック鍵がありません。';

  @override
  String get theCurrentDevicesKeyEnvelopeSource =>
      '現在のデバイスの鍵エンベロープの送信元またはコンテキストを検証できませんでした。';

  @override
  String get theCurrentAccountIsntInThe => '現在のアカウントは最新の署名済みメンバーシップに含まれていません。';

  @override
  String get theSnapshotExceedsTheArchiveCapacity =>
      'スナップショットがアーカイブの容量（100,000 件のレコード）を超えているため、アーカイブは作成されませんでした。';

  @override
  String get collectingAndCheckingEncryptedObjects => '暗号化オブジェクトを収集して照合';

  @override
  String get theTombstoneGraveyardCouldntBeRebuilt =>
      '固定された履歴から削除マーカーの一覧を再構築できませんでした。';

  @override
  String get theLastSnapshotPageStillContains =>
      'スナップショットの最後のページにまだ継続カーソルが含まれています。';

  @override
  String get duplicateServerKeyEnvelopeContext =>
      'サーバーの鍵エンベロープのコンテキストが重複しています。';

  @override
  String serverObjectObjectidConflictsWithThe(String objectId) {
    return 'サーバーのオブジェクト $objectId がアーカイブの内容と競合しています。変更不可のオブジェクトは上書きしません。';
  }

  @override
  String get theServerSnapshotItemCountDoesnt =>
      'サーバーのスナップショットの item_count がページごとのマニフェストの件数と一致しません。';

  @override
  String get theServerSnapshotItemCountDoesnt2 =>
      'サーバーのスナップショットの item_count がマニフェスト全体の件数と一致しません。';

  @override
  String get theServerSnapshotItemCountIs =>
      'サーバーのスナップショットの item_count がページ間で一致しません。';

  @override
  String get invalidServerSnapshotItemCount =>
      'サーバーのスナップショットの item_count が無効です。';

  @override
  String get theServerSnapshotItemCountIs2 =>
      'サーバーのスナップショットの item_count が無効か、変更されました。';

  @override
  String get theServerSnapshotPageManifestHas =>
      'サーバーのスナップショットのページマニフェストの項目が多すぎます。';

  @override
  String get invalidServerSnapshotPageBoundaryOr =>
      'サーバーのスナップショットのページ境界またはマニフェストの形式が無効です。';

  @override
  String get theServerSnapshotContainsInvalidRecords =>
      'サーバーのスナップショットに無効なレコードが含まれています。';

  @override
  String get theServerSnapshotReturnedAnEmpty =>
      'サーバーのスナップショットが完了前に空のページを返しました。';

  @override
  String get theServerSnapshotManifestExceedsThe =>
      'サーバーのスナップショットのマニフェストがクライアントの上限 64 MiB を超えています。';

  @override
  String get theServerSnapshotContinuationCursorIs =>
      'サーバーのスナップショットの継続カーソルが空、重複、または無効です。';

  @override
  String get aLocalConflictKindStateIs => 'ローカル競合の種類／状態が無効か、重複しています。';

  @override
  String get invalidLinkToTheLocalConflict => 'ローカル競合の解決状態の関連付けが無効です。';

  @override
  String get invalidLocalConflictResolutionOutboxLink =>
      'ローカルの競合の解決と送信トレイの関連付けが無効です。';

  @override
  String invalidLocalEpochKeyIdentifierValuevalue(String valueValue) {
    return 'ローカルのエポック鍵の識別子が無効です：$valueValue';
  }

  @override
  String get theLocalOutboxBaseEnvelopeDoesnt =>
      'ローカル送信トレイのベースエンベロープがリビジョンと一致しません。';

  @override
  String get theLocalOutboxBaseRevisionCant =>
      'ローカル送信トレイの base_revision をアーカイブ用に検証できません。';

  @override
  String get aLocalOutboxRevisionIdIs => 'ローカル送信トレイの revision_id がないか、重複しています。';

  @override
  String get theLocalOutboxMetadataDoesntMatch =>
      'ローカル送信トレイのメタデータが署名ヘッダーと一致しません。';

  @override
  String get theLocalOutboxContainsADuplicate =>
      'ローカルの送信トレイに重複した op_id が含まれています。';

  @override
  String get theLocalOutboxStateCantSafely =>
      'ローカル送信トレイの状態は、アーカイブを介して安全に往復できません。';

  @override
  String get localOutboxConflictsExceedTheArchive =>
      'ローカルの送信トレイ／競合がアーカイブの項目数の上限を超えています。';

  @override
  String get thisDevicesEpochKeysDontFully =>
      'このデバイスのエポック鍵が鍵エンベロープのセットと完全には一致しません。';

  @override
  String get thisDevicesPublicKeyDoesntMatch =>
      'このデバイスの公開鍵がサーバーの保管庫ディレクトリと一致しないため、エクスポートできません。';

  @override
  String get thisDevicesIdentityCouldntBeMatched =>
      'このデバイスの ID を現在の保管庫のデバイスディレクトリと照合できませんでした。';

  @override
  String get checkingArchiveConflictBranchFields => 'アーカイブの競合ブランチのフィールドを確認';

  @override
  String get checkingArchiveConflictFields => 'アーカイブの競合フィールドを確認';

  @override
  String get checkingArchiveManifestFieldTypes => 'アーカイブのマニフェストのフィールドの型を確認';

  @override
  String get checkingArchiveManifestEntryLimits => 'アーカイブのマニフェストの項目数の上限を確認';

  @override
  String get checkingArchiveManifestIdentityAndRole =>
      'アーカイブのマニフェストの ID とロールを確認';

  @override
  String get checkingArchiveManifestTopLevelFields =>
      'アーカイブのマニフェストのトップレベルのフィールドを確認';

  @override
  String get checkingArchiveMembershipFields => 'アーカイブのメンバーシップのフィールドを確認';

  @override
  String get checkingArchiveOutboxFields => 'アーカイブの送信トレイのフィールドを確認';

  @override
  String get checkingArchiveRevisionFields => 'アーカイブのリビジョンのフィールドを確認';

  @override
  String get checkingArchiveSnapshotHeadFields => 'アーカイブのスナップショットの先頭フィールドを確認';

  @override
  String get checkingArchiveSnapshotSchema => 'アーカイブのスナップショットのスキーマを確認';

  @override
  String get checkingArchiveDeviceDirectoryFields =>
      'アーカイブのデバイスディレクトリのフィールドを確認';

  @override
  String get theSignedObjectRefsDontMatch =>
      '署名済みの object_refs が暗号化された平文のマニフェストと一致しません。';

  @override
  String get decryptingTheArchiveContainer => 'アーカイブのコンテナを復号';

  @override
  String get aRecordEnvelopeIsMissingIts => 'レコードのエンベロープに署名ヘッダーがありません。';

  @override
  String get theRecordSignerEpochDoesntBelong =>
      'レコードの署名者／エポックはそのメンバーシップのバージョンに属していません。';

  @override
  String theBaseRevisionChainForRecord(String recordId) {
    return 'レコード $recordId の base_revision のチェーンが連続していません。';
  }

  @override
  String get trustCouldntBeEstablishedForThe =>
      'レコードの署名者または鍵エポックの信頼を確立できませんでした。';

  @override
  String get theRecordSignatureHeaderDoesntMatch =>
      'レコードの署名ヘッダーがアーカイブのインデックスと一致しません。';

  @override
  String get invalidDeviceSigningKeyLength => 'デバイスの署名鍵の長さが無効です。';

  @override
  String theHistoryDirectoryOfDeviceId(String id) {
    return 'デバイス $id の履歴ディレクトリが現在の保管庫ディレクトリと競合しています。';
  }

  @override
  String get readingEveryHistoryPageOfThe => '固定されたスナップショットのすべての履歴ページを読み込み';

  @override
  String get readingTheArchiveManifestAndBinary => 'アーカイブのマニフェストとバイナリブロックを読み込み';

  @override
  String get verifyingArchiveKeyEnvelopesAndEpoch => 'アーカイブの鍵エンベロープとエポック鍵を検証';

  @override
  String get verifyingArchiveEncryptedObjectBlocks => 'アーカイブの暗号化オブジェクトブロックを検証';

  @override
  String get verifyingArchiveHistoryConflicts => 'アーカイブの履歴の競合を検証';

  @override
  String get verifyingArchiveHistoryRevisions => 'アーカイブの履歴リビジョンを検証';

  @override
  String get verifyingTheArchivesLocalOutboxAnd => 'アーカイブのローカル送信トレイと競合ブランチを検証';

  @override
  String get verifyingArchiveFormatAndTarget => 'アーカイブの形式と対象を検証';

  @override
  String get verifyingArchiveDeviceSequenceWatermarks =>
      'アーカイブのデバイスのシーケンスの水位を検証';

  @override
  String get verifyingTheMemberSignatureChainAnd => 'メンバーの署名チェーンとデバイスの信頼を検証';

  @override
  String get verifyingSignaturesKeyEpochsAndObject => '署名、鍵エポック、オブジェクト参照を検証';

  @override
  String get verifyingTheDeviceDirectoryAndSigned =>
      'デバイスディレクトリと署名済みのメンバーシップチェーンを検証';

  @override
  String get attachmentsAreLimitedTo1Gib => '添付ファイルは 1 GiB までです。';

  @override
  String get theVaultHasNoActiveDevice => '保管庫にアクティブなデバイス機能レポートがありません。';

  @override
  String get theVaultHasNoActiveDevices =>
      '保管庫に v2 の添付ファイルを読み取れるアクティブなデバイスがありません。';

  @override
  String get theServerDoesNotSupportSigned =>
      'サーバーは v2 の添付ファイルに必要な署名付きデバイス機能レポートに対応していません。';

  @override
  String get theServerReturnedAnInvalidVault =>
      'サーバーが無効な保管庫のデバイス一覧を返したため、v2 のアップロードをブロックしました。';

  @override
  String get thisClientCannotAuthenticateOtherDevices =>
      'このクライアントは他のデバイスの署名付き機能レポートを認証できないため、v2 のアップロードをブロックしました。';

  @override
  String get thisDeviceCapabilityReportCouldNot =>
      'このデバイスの機能レポートを公開できなかったため、添付ファイルのデータはステージされていません。';

  @override
  String get thisDeviceHasNotPublishedIts =>
      'このデバイスはまだ署名付きの添付ファイル機能レポートを公開していません。';

  @override
  String get thisPlatformCannotSafelySaveAttachments =>
      'このプラットフォームでは 256 MiB を超える添付ファイルを安全に保存できません。添付ファイルのデータはステージされていません。';

  @override
  String get someDevicesInTheVaultDont =>
      '保管庫内に、この添付ファイルのサイズに対応していないデバイスがあります。';

  @override
  String get v2PreflightIsOnlyRequiredAbove =>
      'v2 の事前チェックが必要なのは 256 MiB を超える場合のみです。';

  @override
  String devicenameHasNoValidSignedReport(String deviceName) {
    return '$deviceName には 1 GiB の添付ファイルレコードに有効な署名付きレポートがありません。v2 を有効にする前に、そのアクティブなデバイスを更新または削除してください。';
  }

  @override
  String get theDownloadedAttachmentCiphertextDigestOr =>
      'ダウンロードした添付ファイルの暗号文のダイジェストまたは長さが一致しません。';

  @override
  String get differentAttachmentsReferenceTheSameObject =>
      '異なる添付ファイルが同じオブジェクトを参照しています。';

  @override
  String get hostObjectRefsMustBeUnique =>
      'ホストの object_refs は、厳密な昇順で一意の小文字の UUID である必要があります。';

  @override
  String get hostObjectRefsMustBeAn =>
      'ホストの object_refs は最大 1024 項目の配列である必要があります。';

  @override
  String get duplicateHostAttachmentBlobId => 'ホストの添付ファイルの blob ID が重複しています。';

  @override
  String get invalidHostAttachmentManifestFormat =>
      'ホストの添付ファイルのマニフェストの形式が無効です。';

  @override
  String get theHostAttachmentManifestExceedsThe =>
      'ホストの添付ファイルのマニフェストが保存上限の 32 KiB を超えています。';

  @override
  String get localIntegrityVerificationOfTheEncrypted =>
      '暗号化された添付オブジェクトのローカルでの整合性検証に失敗しました。';

  @override
  String get theEncryptedAttachmentManifestDoesntMatch =>
      '暗号化された添付ファイルのマニフェストが object_refs と一致しません。';

  @override
  String get invalidPersistedUploadChunkSize => '保存済みのアップロードのチャンクサイズが無効です。';

  @override
  String get invalidPersistedUploadProgress => '保存済みのアップロードの進捗が無効です。';

  @override
  String get integrityVerificationOfAPersistedAttachment =>
      '保存済みの添付ファイルの暗号文チャンクの整合性検証に失敗しました。';

  @override
  String get theServerReturnedAnInvalidUpload => 'サーバーが無効なアップロードの予約を返しました。';

  @override
  String get anAttachmentObjectAlreadyOnThe =>
      'サーバー上の既存の添付オブジェクトが、保存済みの暗号文と一致しません。';

  @override
  String get theServerAttachmentUploadReceiptDoesnt =>
      'サーバーの添付ファイルのアップロード受領情報が暗号文オブジェクトと一致しません。';

  @override
  String get integrityVerificationOfTheLocalAttachment =>
      'アップロード待ちのローカルの添付ファイルの暗号文の整合性検証に失敗しました。';

  @override
  String get theLocalAttachmentObjectWaitingFor =>
      'アップロード待ちのローカルの添付オブジェクトが見つかりません。';

  @override
  String get theLocalAttachmentEncryptionDirectoryIs =>
      'ローカルの添付ファイル暗号化ディレクトリが見つからないか、整合性検証に失敗しました。';

  @override
  String get thisV2AttachmentExceeds256Mib =>
      'この v2 の添付ファイルは 256 MiB を超えています。このクライアントはまだ範囲を限定した復号とストリーミング保存を実装していません。';

  @override
  String get thisHostsAttachmentObjectReferencesExceed =>
      'このホストの添付オブジェクトの参照が上限の 1024 個を超えています。';

  @override
  String get theAttachmentIsntInThisHosts => 'この添付ファイルはこのホストの暗号化マニフェストにありません。';

  @override
  String get theAttachmentObjectIdDuplicatesAn =>
      '添付オブジェクトの ID がホストの既存の参照と重複しています。';

  @override
  String get theTotalAttachmentPlaintextLengthExceeds =>
      '添付ファイルの平文の合計長がマニフェストの宣言を超えています。';

  @override
  String get attachmentPlaintextDigestOrTotalLength =>
      '添付ファイルの平文のダイジェストまたは合計長の検証に失敗しました。';

  @override
  String get theComSerialConsoleRequiresThe =>
      'COM シリアルコンソールには Windows クライアントが必要です。';

  @override
  String get theBrowserCantStartALocal =>
      'ブラウザからローカルのシェルを直接起動することはできません。デスクトップクライアントを使用してください。';

  @override
  String get theSerialInputQueueIsFull =>
      '\n[シリアルの入力キューがいっぱいのため、この入力は送信されませんでした。分けて入力してください。]\n';

  @override
  String get couldntStartTheSerialConsole => '\n[シリアルコンソールを起動できませんでした]\n';

  @override
  String get theSerialConsoleFailedToStart => 'シリアルコンソールの起動に失敗しました。';

  @override
  String get theSerialPortDoesntSupportThis => 'シリアルポートはこの設定に対応していません。';

  @override
  String get serialWriteFailedOrTheDevice => 'シリアルの書き込みに失敗したか、デバイスが切断されました。';

  @override
  String get serialWriteTimedOut => 'シリアルの書き込みがタイムアウトしました。';

  @override
  String get invalidSerialPortOrBaudRate => 'シリアルポートまたはボーレートが無効です。';

  @override
  String get serialReadFailedOrTheDevice => 'シリアルの読み取りに失敗したか、デバイスが切断されました。';

  @override
  String get serialInputExceedsTheLimit => 'シリアルの入力が上限を超えています。';

  @override
  String couldntOpenItemWindowsGetlasterrorCheck(
    Object item,
    int GetLastError,
  ) {
    return '$item を開けませんでした（Windows $GetLastError）。シリアルポート名と使用状況を確認してください。';
  }

  @override
  String get couldntReadTheSerialPortConfiguration => 'シリアルポートの設定を読み込めませんでした。';

  @override
  String get unsupportedAttachmentManifestFormat =>
      '対応していない添付ファイルのマニフェストの形式です。';

  @override
  String get invalidAttachmentMimeTypeFormat => '添付ファイルの MIME タイプの形式が無効です。';

  @override
  String get invalidAttachmentBlobIdFormat => '添付ファイルの blob ID の形式が無効です。';

  @override
  String get invalidAttachmentEncryptionDirectoryFormat =>
      '添付ファイルの暗号化ディレクトリの形式が無効です。';

  @override
  String get attachmentEncryptionDirectoryAuthenticationOrParsing =>
      '添付ファイルの暗号化ディレクトリの認証または解析に失敗しました。';

  @override
  String get theAttachmentEncryptionDirectoryExceedsThe =>
      '添付ファイルの暗号化ディレクトリがサイズ上限を超えています。';

  @override
  String get invalidAttachmentBlockFieldFormat => '添付ファイルのブロックのフィールドの形式が無効です。';

  @override
  String get theAttachmentBlockCountDoesntMatch =>
      '添付ファイルのブロック数がファイルの長さと一致しません。';

  @override
  String get invalidAttachmentBlockCount => '添付ファイルのブロック数が無効です。';

  @override
  String get theNumberOfAttachmentBlocksExceeds =>
      '添付ファイルのブロック数が v2 形式の上限を超えています。';

  @override
  String get theNumberOfAttachmentBlocksExceeds2 =>
      '添付ファイルのブロック数が現在の形式の上限を超えています。';

  @override
  String get invalidAttachmentBlockEntryFormat => '添付ファイルのブロックの項目の形式が無効です。';

  @override
  String get invalidAttachmentBlockManifestFormat =>
      '添付ファイルのブロックのマニフェストの形式が無効です。';

  @override
  String get attachmentBlockAuthenticationFailedTheFile =>
      '添付ファイルのブロックの認証に失敗しました。ファイルが改ざんされている可能性があります。';

  @override
  String get attachmentBlockOrderLengthOrUniqueness =>
      '添付ファイルのブロックの順序、長さ、または一意性の検証に失敗しました。';

  @override
  String get theAttachmentSizeIsOutsideThe => '添付ファイルのサイズがクライアントの対応範囲外です。';

  @override
  String get attachmentIntegrityOrFinalLengthVerification =>
      '添付ファイルの整合性または最終的な長さの検証に失敗しました。';

  @override
  String get theAttachmentCiphertextObjectIsMissing =>
      '添付ファイルの暗号文オブジェクトが見つかりません。';

  @override
  String get attachmentCiphertextDigestOrLengthVerification =>
      '添付ファイルの暗号文のダイジェストまたは長さの検証に失敗しました。';

  @override
  String get invalidAttachmentCiphertextLength => '添付ファイルの暗号文の長さが無効です。';

  @override
  String get invalidAttachmentKeyFormat => '添付ファイルの鍵の形式が無効です。';

  @override
  String get theAttachmentObjectIdIsInvalid => '添付オブジェクトの ID が無効か、重複しています。';

  @override
  String get invalidAttachmentFileNameOrMime =>
      '添付ファイルのファイル名または MIME タイプの形式が無効です。';

  @override
  String get invalidAttachmentFileNameFormat => '添付ファイルのファイル名の形式が無効です。';

  @override
  String get attachmentPlaintextBlockLengthVerificationFailed =>
      '添付ファイルの平文ブロックの長さの検証に失敗しました。';

  @override
  String get invalidAttachmentPlaintextDigestFormat =>
      '添付ファイルの平文のダイジェストの形式が無効です。';

  @override
  String get invalidAttachmentManifestEntryFormat =>
      '添付ファイルのマニフェストの項目の形式が無効です。';

  @override
  String get theAttachmentSourceReturnsOnlyEmpty => '添付ファイルのソースが空のブロックしか返しません。';

  @override
  String get theAttachmentSourceKeepsReturningEmpty =>
      '添付ファイルのソースがファイルの末尾で空のブロックを返し続けています。';

  @override
  String get theAttachmentSourceEndedEarlyIts =>
      '添付ファイルのソースが途中で終了し、長さがファイル情報と一致しません。';

  @override
  String get anAttachmentSourceBlockExceedsThe =>
      '添付ファイルのソースのブロックが読み取り上限の 4 MiB を超えています。';

  @override
  String get theAttachmentSourceLengthExceedsThe =>
      '添付ファイルのソースの長さがファイル情報を超えています。';

  @override
  String get invalidAttachmentDirectoryNonceFormat =>
      '添付ファイルのディレクトリの nonce の形式が無効です。';

  @override
  String get theAttachmentDirectoryBlockCountDoesnt =>
      '添付ファイルのディレクトリのブロック数が記述子と一致しません。';

  @override
  String get attachmentDirectoryBlockOrderLengthOr =>
      '添付ファイルのディレクトリのブロックの順序、長さ、または一意性の検証に失敗しました。';

  @override
  String get invalidAttachmentDirectoryCiphertextSize =>
      '添付ファイルのディレクトリの暗号文のサイズが無効です。';

  @override
  String get attachmentDirectoryCiphertextDigestOrLength =>
      '添付ファイルのディレクトリの暗号文のダイジェストまたは長さの検証に失敗しました。';

  @override
  String get invalidAttachmentDirectoryCiphertextLength =>
      '添付ファイルのディレクトリの暗号文の長さが無効です。';

  @override
  String get invalidAttachmentDirectoryObjectIdFormat =>
      '添付ファイルのディレクトリのオブジェクト ID の形式が無効です。';

  @override
  String get invalidAttachmentDirectoryDigestFormat =>
      '添付ファイルのディレクトリのダイジェストの形式が無効です。';

  @override
  String get theAttachmentExceedsThe1Gib =>
      '添付ファイルがクライアントのサイズ上限の 1 GiB を超えています。';

  @override
  String get theAttachmentExceedsThe256Mib =>
      '添付ファイルがクライアントのサイズ上限の 256 MiB を超えています。';

  @override
  String get theShareRequestIsMalformedOr =>
      '共有リクエストの形式が無効か、別のサーバーインスタンスからのものです。';

  @override
  String get invalidShareRequestAccountIdentifier => '共有リクエストのアカウント識別子が無効です。';

  @override
  String get invalidDeviceSelfProofPublicKey => 'デバイスの自己証明の公開鍵または署名の長さが無効です。';

  @override
  String get invalidDeviceSelfProofFields => 'デバイスの自己証明のフィールドが無効です。';

  @override
  String get invalidDeviceSelfProofSignature => 'デバイスの自己証明の署名が無効です。';

  @override
  String get invalidDeviceSelfProofAccountIdentifier =>
      'デバイスの自己証明のアカウント識別子が無効です。';

  @override
  String remoteDesktopConnectionFailedCodeLast(String last) {
    return 'リモートデスクトップの接続に失敗しました（コード $last）。認証情報、証明書の信頼、ゲートウェイのログを確認してください。';
  }

  @override
  String get remoteDesktopDisconnected => 'リモートデスクトップが切断されました。';

  @override
  String get resolutionAndScaling => '解像度とスケーリング';

  @override
  String get apply => '適用';

  @override
  String get theServerDoesntSupportResizingOnly =>
      'サーバーは解像度の変更に対応していないため、ローカルのスケーリングのみ可能です。';

  @override
  String get theServerSupportsLiveResizingDisplay =>
      'サーバーはリアルタイムの解像度の変更に対応しています（ディスプレイ制御チャネル）。';

  @override
  String get theServerSupportsResizingExtendeddesktopsize =>
      'サーバーは解像度の変更に対応しています（ExtendedDesktopSize）。';

  @override
  String get theServerDoesntOfferDisplayControl =>
      'サーバーにディスプレイ制御がないため、新しい解像度は再接続後に反映されます。';

  @override
  String get waitingForTheServerToReport => 'サーバーが解像度の変更に対応しているかの報告を待っています…';

  @override
  String get thisSessionUsesAllLocalMonitors =>
      'このセッションはすべてのローカルモニターを使用しているため、リモートの解像度はモニターの配置で決まります。';

  @override
  String get scalesThisWindowOnlyTheRemote =>
      'このウィンドウのみをスケーリングし、リモートの解像度は変更しません。';

  @override
  String get actualSize11Scrollable => '実際のサイズ（1:1、スクロール可能）';

  @override
  String get width => '幅';

  @override
  String get serverDefaultDontRequestAResize => 'サーバーの既定（変更をリクエストしない）';

  @override
  String get localDisplay => 'ローカルの表示';

  @override
  String get custom => 'カスタム…';

  @override
  String get remoteResolution => 'リモートの解像度';

  @override
  String get fitToWindow => 'ウィンドウに合わせる';

  @override
  String get height => '高さ';

  @override
  String get clipboardIsLimitedTo64Kib => 'クリップボードは 64 KiB までです';

  @override
  String invalidRdpOptionsMessage(String message) {
    return 'RDP オプションが無効です：$message';
  }

  @override
  String get remoteDesktopConnectionClosed => 'リモートデスクトップの接続が閉じられました。';

  @override
  String get remoteDesktopSetupTimedOutCheck =>
      'リモートデスクトップの準備がタイムアウトしました。ゲートウェイと接続先を確認してください。';

  @override
  String get remoteDesktopStreamFailed => 'リモートデスクトップのストリームに失敗しました。';

  @override
  String get unableToConnectCheckTheDesktop =>
      '接続できません。デスクトップゲートウェイ、Relay ポリシー、認証情報、証明書の信頼を確認してください。';

  @override
  String get theHostSettingsChangedReconnect => 'ホストの設定が変更されました。再接続してください。';

  @override
  String get theResolutionSettingAppliesToThis =>
      '解像度の設定はこのセッションにのみ適用され、ホストには保存できませんでした。';

  @override
  String get inAMultiMonitorSessionThe =>
      'マルチモニターのセッションでは解像度はこのコンピューターのモニターで決まります。設定するには「すべてのモニターを使用」をオフにしてください。';

  @override
  String get stoppedRequestingAResizeTheServer =>
      '解像度の変更のリクエストを停止しました。サーバーは現在の解像度を維持します。';

  @override
  String get theInstalledRdpEngineDoesntSupport =>
      'インストールされている RDP エンジンはこのホストの RDP オプションに対応していないため、既定の設定で接続しました。';

  @override
  String get couldntConnectToTheLocalGuacd =>
      'ローカルの guacd（127.0.0.1:4822）に接続できませんでした。ゲートウェイを起動するか、サインイン済みのクラウドワークスペースを使用してください。';

  @override
  String get theServerDoesntAcceptThisResolution => 'サーバーはこの解像度を受け付けません。';

  @override
  String get theServerDoesntSupportResizingOnly2 =>
      'サーバーは解像度の変更に対応していません。ローカルのスケーリングのみ利用できます。';

  @override
  String get theServerRefusedTheResize => 'サーバーが解像度の変更を拒否しました。';

  @override
  String get theServerDoesntOfferDynamicResolution =>
      'サーバーは動的な解像度に対応していないため、新しい解像度は再接続後に反映されます。';

  @override
  String get theServerLacksTheResourcesFor =>
      'サーバーのリソースが不足しているため、この解像度は使用できません。';

  @override
  String get thisRdpCertificateWasntTrustedThe =>
      'この RDP 証明書を信頼しなかったため、接続をキャンセルしました。';

  @override
  String get thisVncServerDoesntSupportResizing =>
      'この VNC サーバーは解像度の変更に対応していません（ExtendedDesktopSize がネゴシエートされていません）。ローカルのスケーリングのみ利用できます。設定は保持されています。';

  @override
  String get clipboardTextIsTurnedOffFor => 'このホストではクリップボードのテキストがオフになっています。';

  @override
  String get thisHostCantSaveCertificates => 'このホストでは証明書を保存できません。';

  @override
  String thisClientCantProvideJoinThe(String join) {
    return 'このクライアントでは次を提供できません：$join。その他のオプションは通常どおり適用されます。';
  }

  @override
  String get theCertificateCouldntBeSavedThe =>
      '証明書を保存できませんでした。ホストが変更されたか、ワークスペースがロックされている可能性があります。もう一度試すか、再接続してください。';

  @override
  String couldntSaveRemoteFilesError(Object error) {
    return 'リモートファイルを保存できませんでした：$error';
  }

  @override
  String get invalidRemoteDesktopHostSettings => 'リモートデスクトップのホストの設定が無効です。';

  @override
  String get invalidRemoteDesktopImage => 'リモートデスクトップの画像が無効です。';

  @override
  String get theRemoteDesktopConnectionFailed => 'リモートデスクトップの接続に失敗しました。';

  @override
  String get theRemoteDesktopConnectionClosed => 'リモートデスクトップの接続が閉じられました。';

  @override
  String get theRemoteDesktopConnectionTimedOut =>
      'リモートデスクトップの接続がタイムアウトしました。接続先のアドレスとネットワークを確認してください。';

  @override
  String get rdpCertificateFingerprintChanged => 'RDP 証明書のフィンガープリントが変更されました';

  @override
  String get saveRemoteClipboardFiles => 'リモートのクリップボードのファイルを保存';

  @override
  String get saveRemoteClipboardFiles2 => 'リモートのクリップボードのファイルを保存…';

  @override
  String saveRemoteClipboardFilesFilecountFiles(
    int fileCount,
    String formatTransferBytes,
  ) {
    return 'リモートのクリップボードのファイルを保存（$fileCount 個、$formatTransferBytes）…';
  }

  @override
  String get trustAndSave => '信頼して保存';

  @override
  String get trustThisRdpCertificate => 'この RDP 証明書を信頼しますか？';

  @override
  String get resolutionAndScaling2 => '解像度とスケーリング…';

  @override
  String get sendCtrlAltDelete => 'Ctrl+Alt+Delete を送信';

  @override
  String get sendLocallyCopiedFiles => 'ローカルでコピーしたファイルを送信';

  @override
  String get cancel => 'キャンセル';

  @override
  String get openInNewWindow => '新しいウィンドウで開く';

  @override
  String get copyRemoteClipboardText => 'リモートのクリップボードのテキストをコピー';

  @override
  String savedCountItems(int count) {
    return '$count 件を保存しました。';
  }

  @override
  String savedCountItemsAndPlacedThem(int count) {
    return '$count 件を保存し、このコンピューターのクリップボードに配置しました。そのまま貼り付けられます。';
  }

  @override
  String get savedSha256 => '保存済みの SHA-256';

  @override
  String get currentCertificateSha256 => '現在の証明書の SHA-256';

  @override
  String get couldntSendClipboardText => 'クリップボードのテキストを送信できませんでした。';

  @override
  String get updateAndConnect => '更新して接続';

  @override
  String get theServerCertificateDiffersFromThe =>
      'サーバーの証明書が保存済みの記録と異なります。新しいフィンガープリントを確認してください。確定すると、このホストの信頼の記録を更新して接続を続行します。';

  @override
  String get thereAreNoCopiedFilesOn => 'このコンピューターのクリップボードにコピーされたファイルはありません。';

  @override
  String get saving => '保存しています…';

  @override
  String savingRemoteFilesDoneTotal(int done, int total) {
    return 'リモートファイルを保存しています $done/$total';
  }

  @override
  String get thisCertificateIsntTrustedYetVerify =>
      'この証明書はまだ信頼されていません。フィンガープリントを確認してください。確定すると、このホストに保存して接続を続行します。';

  @override
  String get oneWindowPerMonitor => 'モニターごとに 1 ウィンドウ';

  @override
  String get pasteLocalClipboardText => 'ローカルのクリップボードのテキストを貼り付け';

  @override
  String get remoteDesktopMenu => 'リモートデスクトップのメニュー';

  @override
  String get chooseFilesForTheRemoteClipboard => 'ファイルを選んでリモートのクリップボードに配置…';

  @override
  String get theRdpCertificateIsntTrustedYet =>
      'RDP 証明書はまだ信頼されていません。SHA-256 フィンガープリントの確認が必要です。';

  @override
  String get folderNestingIsTooDeep => 'フォルダーの階層が深すぎます';

  @override
  String get noFilesToSend => '送信するファイルがありません';

  @override
  String notARegularFileOrFolder(String name) {
    return '通常のファイルまたはフォルダーではありません：$name';
  }

  @override
  String get tooManyFilesForTheClipboard => 'クリップボードのファイルが多すぎます';

  @override
  String unsupportedOrDuplicateFileNameName(String name) {
    return '対応していないか重複したファイル名：$name';
  }

  @override
  String fileTooLargeRelativepath(String relativePath) {
    return 'ファイルが大きすぎます：$relativePath';
  }

  @override
  String get theTotalSizeOfTheRemote => 'リモートファイルの合計サイズが上限を超えています。';

  @override
  String get rdpTlsHandshakeFailed20008No =>
      'RDP の TLS ハンドシェイクに失敗しました（20008）。確認可能な証明書を取得できませんでした。接続先のポートと TLS の設定を確認してください。';

  @override
  String get theRdpSessionDisconnected => 'RDP セッションが切断されました。';

  @override
  String get invalidRdpImageSize => 'RDP の画像サイズが無効です。';

  @override
  String get theRdpEngineCantBeLoaded =>
      'RDP エンジンを読み込めません。完全な Windows クライアントをインストールしてください。';

  @override
  String get theRdpEngineIsTooOld =>
      'RDP エンジンが古いため、このホストの RDP オプションを適用できません。クライアントの完全な更新をインストールしてください。';

  @override
  String rdpConnectionFailedToradixstringCheckThe(String toRadixString) {
    return 'RDP 接続に失敗しました（$toRadixString）。アドレス、ユーザー名、パスワードを確認してください。';
  }

  @override
  String get theRdpConfigurationIsInvalidOr => 'RDP の設定が無効か、エンジンの初期化に失敗しました。';

  @override
  String placedCountFilesOnTheRemote(int count) {
    return '$count 個のファイルをリモートのクリップボードに配置しました。リモート側で貼り付けられます。';
  }

  @override
  String get theCurrentRdpEngineDoesntSupport =>
      '現在の RDP エンジンはファイルのクリップボードに対応していません。';

  @override
  String couldntSendFilesMessage(String message) {
    return 'ファイルを送信できませんでした：$message';
  }

  @override
  String get couldntStartTheRdpEngineCheck =>
      'RDP エンジンを起動できませんでした。クライアントのインストールを確認してください。';

  @override
  String get couldntReadTheSelectedFiles => '選択したファイルを読み込めませんでした。';

  @override
  String get theTargetRdpSessionDoesntHave =>
      '接続先の RDP セッションでファイルのクリップボードが有効になっていないか、このホストでオフになっています。';

  @override
  String get theTargetRdpSessionDoesntHave2 =>
      '接続先の RDP セッションでテキストのクリップボードが有効になっていません。';

  @override
  String get theRemoteClipboardHasNoFiles => 'リモートのクリップボードに保存できるファイルはありません。';

  @override
  String get anUnsafeFileNameOnThe => 'リモートのクリップボード内の安全でないファイル名は無視しました。';

  @override
  String get theRemoteFilesCouldntBeSaved => 'リモートファイルを保存できませんでした。';

  @override
  String get sshHostsDontHaveRemoteDesktop => 'SSH ホストにはリモートデスクトップの画面設定がありません。';

  @override
  String get theHostChangedTheResolutionSetting =>
      'ホストが変更されたため、解像度の設定は保存されていません。';

  @override
  String get theHostOrCertificateTrustChanged =>
      'ホストまたは証明書の信頼が変更されました。再接続してください。';

  @override
  String get theHostsRdpOptionsWereSaved =>
      'ホストの RDP オプションは新しいバージョンで保存されているため、解像度の設定は保存されていません。';

  @override
  String get theHostsVncDisplaySettingsWere =>
      'ホストの VNC の画面設定は新しいバージョンで保存されているため、解像度の設定は保存されていません。';

  @override
  String get couldntSaveTheCertificate => '証明書を保存できませんでした。';

  @override
  String atMostMaxdrivesRedirectedFolders(int maxDrives) {
    return 'リダイレクトするフォルダーは最大 $maxDrives 個';
  }

  @override
  String atMostMaxusbdevicesUsbDevices(int maxUsbDevices) {
    return 'USB デバイスは最大 $maxUsbDevices 台';
  }

  @override
  String get driveFolderMustBeAnAbsolute => 'ドライブのフォルダーは絶対パスにしてください';

  @override
  String get driveNameMustBe131 => 'ドライブ名は 1〜31 文字の英字、数字、スペース、_ または - にしてください';

  @override
  String get monitorLayoutExceedsRdpLimits => 'モニターの配置が RDP の制限を超えています';

  @override
  String get redirectedFolderNamesMustBeUnique => 'リダイレクトするフォルダーの名前は一意にしてください';

  @override
  String get usbDevicesMustBeUniqueVendor =>
      'USB デバイスは一意の vendor:product の 16 進 ID にしてください';

  @override
  String get unsupportedRdpDisplayScale => '対応していない RDP の画面スケーリング';

  @override
  String get addFolder => 'フォルダーを追加';

  @override
  String get allPrinters => 'すべてのプリンター';

  @override
  String get defaultPrinter => '既定のプリンター';

  @override
  String get displayClipboardAndLocalResources => '画面、クリップボード、ローカルリソース';

  @override
  String get doNotPlay => '再生しない';

  @override
  String get eachMonitorCanBeOpenedIn => '各モニターを個別のウィンドウで開けます';

  @override
  String get leaveOnRemoteComputer => 'リモートコンピューターに残す';

  @override
  String get off2 => 'オフ';

  @override
  String get onlyDevicesAlreadyUsingTheWinusb =>
      'すでに WinUSB ドライバーを使用しているデバイスのみ。ドライバーはインストールされません。';

  @override
  String get playOnThisComputer => 'このコンピューターで再生';

  @override
  String get printers => 'プリンター';

  @override
  String get rdpOptions => 'RDP オプション';

  @override
  String get redirectedFolders => 'リダイレクトするフォルダー';

  @override
  String get remoteAudio => 'リモートオーディオ';

  @override
  String get remoteDisplayScale => 'リモート画面のスケーリング';

  @override
  String get removeFolder => 'フォルダーを削除';

  @override
  String get requiresAMatchingPrinterDriverOn =>
      'リモートコンピューターに対応するプリンタードライバーが必要です';

  @override
  String get requiresCameraRedirectionSupportOnThe =>
      'サーバーがカメラのリダイレクトに対応している必要があります';

  @override
  String get resolutionAndLocalScaling => '解像度とローカルのスケーリング';

  @override
  String get savedRdpOptionsWereWrittenBy =>
      '保存済みの RDP オプションは新しいバージョンで書き込まれたため無視されます。保存すると置き換えられます。';

  @override
  String get usbDevicesVendorProduct => 'USB デバイス（vendor:product）';

  @override
  String get vncDisplay => 'VNC の画面';

  @override
  String get theRemoteDesktopInTheMain => 'メインウィンドウのリモートデスクトップが閉じられたか、切断されました。';

  @override
  String get remoteDesktop => 'リモートデスクトップ';

  @override
  String get closeThisMonitorWindow => 'このモニターのウィンドウを閉じる';

  @override
  String get couldntOpenTheRemoteDesktopWindow =>
      'リモートデスクトップのウィンドウを開けませんでした。メインウィンドウに戻ってもう一度お試しください。';

  @override
  String titleMonitorValuevalueValuevalue2(
    String title,
    int valueValue,
    String valueValue2,
  ) {
    return '$title · モニター $valueValue$valueValue2';
  }

  @override
  String get primary => '（メイン）';

  @override
  String aHostCanHaveAtMost2(int maxHostPortForwardProfiles) {
    return '1 台のホストに設定できるポート転送プロファイルは最大 $maxHostPortForwardProfiles 個です';
  }

  @override
  String get dynamicForwardingDoesNotHaveA => 'ダイナミックフォワーディングには固定の宛先がありません';

  @override
  String get forwardDestinationHostIsInvalid => '転送先のホストが無効です';

  @override
  String get forwardDestinationPortMustBeBetween => '転送先のポートは 1〜65535 にしてください';

  @override
  String get forwardListenerAddressAndPortMust =>
      '転送の待ち受けアドレスとポートは一意である必要があります';

  @override
  String get forwardListenerAddressMustBeLocalhost =>
      '転送の待ち受けアドレスは localhost または IP アドレスである必要があります';

  @override
  String get forwardListenerPortMustBeBetween => '転送の待ち受けポートは 0〜65535 にしてください';

  @override
  String get forwardListenersMustBindToLoopback =>
      'ネットワークへの公開を確認していない限り、転送のリスナーはループバックにバインドする必要があります';

  @override
  String get forwardProfileIdIsInvalid => '転送プロファイルの ID が無効です';

  @override
  String get forwardProfileIdsMustBeUnique => '転送プロファイルの ID は一意である必要があります';

  @override
  String get forwardProfileNameMustBe1 => '転送プロファイルの名前は 1〜64 文字にしてください';

  @override
  String get hostAddressIsRequired => 'ホストのアドレスは必須です';

  @override
  String get hostLoginAndAuthenticationSettingsDo => 'ホストのサインインと認証の設定が一致しません';

  @override
  String get hostNameIsRequired => 'ホスト名は必須です';

  @override
  String get portMustBeBetween1And => 'ポートは 1〜65535 にしてください';

  @override
  String get rdpCertificateFingerprintMustContain64 =>
      'RDP 証明書のフィンガープリントは 64 桁の 16 進数の SHA-256 である必要があります';

  @override
  String get remoteDesktopsUsePasswordLoginWithout =>
      'リモートデスクトップはパスワードでサインインし、SSH の経路や転送は使用しません';

  @override
  String get remoteForwardingTargetsMustUseThis =>
      'ネットワークへの公開を確認していない限り、リモートフォワーディングの宛先はこのデバイスのループバックにする必要があります';

  @override
  String get unnamedHost => '名前のないホスト';

  @override
  String get untitledSnippet => '無題のスニペット';

  @override
  String get usernameIsRequired => 'ユーザー名は必須です';

  @override
  String get enterAValidSshPassword => '有効な SSH パスワードを入力してください';

  @override
  String get enterAValidSshPrivateKey => '有効な SSH 秘密鍵とパスフレーズを入力してください';

  @override
  String get aPortNumberIsRequiredAfter => '-p の後にポート番号が必要です';

  @override
  String get aUserNameIsRequiredBefore => '@ の前にユーザー名が必要です';

  @override
  String get serialFormatConsoleTtyCom3B =>
      'シリアルの形式：console tty @COM3 -b 115200';

  @override
  String get invalidHostOrUserNameFormat => 'ホストまたはユーザー名の形式が無効です';

  @override
  String get onlyUserHostAndPPort =>
      '[ユーザー@]ホストと -p ポートのみ対応しています。シェル引数は実行されません';

  @override
  String get dontSpecifyThePortBothIn => 'アドレスのポートと -p を重複して指定することはできません';

  @override
  String get openLocalConsole => 'ローカルコンソールを開く';

  @override
  String formatVerbValuevalueHostPValuevalue2(
    String verb,
    String valueValue,
    int valueValue2,
  ) {
    return '形式：$verb $valueValueホスト -p $valueValue2';
  }

  @override
  String get baudRateFormatB115200 => 'ボーレートの形式：-b 115200';

  @override
  String get baudRateMustBe504000000 => 'ボーレートの範囲は 50〜4000000 です';

  @override
  String get thePortCanOnlyBeSpecified => 'ポートは 1 回だけ指定できます';

  @override
  String get portMustBe165535 => 'ポートの範囲は 1〜65535 です';

  @override
  String get enterAValidSerialPortFor =>
      '有効なシリアルポートを入力してください（例：console tty @COM3）';

  @override
  String connectAddressBaudrateBaud8n1(String address, int baudRate) {
    return '$address に接続 · $baudRate baud · 8N1';
  }

  @override
  String get theActivePaneIsntInThe => 'アクティブなペインが分割内にありません。';

  @override
  String get invalidWindowSetHostPathOr => 'ウィンドウセットのホスト、パス、またはプロトコルが無効です。';

  @override
  String get theWindowSetHasTooMany => 'ウィンドウセットのセッションが多すぎます。';

  @override
  String get invalidWindowSetSplit => 'ウィンドウセットの分割が無効です。';

  @override
  String get invalidWindowSetList => 'ウィンドウセットの一覧が無効です。';

  @override
  String get invalidWindowSetNameOrSession => 'ウィンドウセットの名前またはセッションが無効です。';

  @override
  String get windowSetIsNestedTooDeeply => 'ウィンドウセットの階層が深すぎます。';

  @override
  String get aHostInThisWindowSet =>
      'このウィンドウセットが参照するホストが存在しないか、プロトコルが変更されています。セットを削除して保存し直してください。';

  @override
  String get windowSetDataIsTooLarge => 'ウィンドウセットのデータが大きすぎます。';

  @override
  String get invalidWindowSetCountOrIdentifier => 'ウィンドウセットの数または識別子が無効です。';

  @override
  String get invalidWindowSetFormat => 'ウィンドウセットの形式が無効です。';

  @override
  String get invalidWindowSetNode => 'ウィンドウセットのノードが無効です。';

  @override
  String get invalidWindowSetPaneReference => 'ウィンドウセットのペイン参照が無効です。';

  @override
  String get invalidWindowSetPane => 'ウィンドウセットのペインが無効です。';

  @override
  String get hostTags => 'ホストのタグ';

  @override
  String get addAUserDirectiveBeforeImporting =>
      'このホストをインポートする前に User ディレクティブを追加してください。';

  @override
  String get commandDirectivesAreNeverExecutedThis =>
      'コマンドのディレクティブは実行されません。このホストはインポートされません。';

  @override
  String get identityfileIsNotReadOrImported =>
      'IdentityFile は読み込まれず、インポートもされません。鍵は別途認証情報として追加してください。';

  @override
  String get identityfileNeedsOneValueThisHost =>
      'IdentityFile には値が 1 つ必要です。このホストはインポートされません。';

  @override
  String get theConfigFileExceedsThe1 => '設定ファイルがインポートの上限 1 MiB を超えています。';

  @override
  String get theConfigFileHasTooMany => '設定ファイルの行数が多すぎるため、安全に確認できません。';

  @override
  String get thisDirectiveNeedsExactlyOneValue =>
      'このディレクティブには値を 1 つだけ指定する必要があります。';

  @override
  String get thisValueIsInvalidOrUnsupported => 'この値は無効か、対応していません。';

  @override
  String get atermiusRemoteDesktop => 'Atermius · リモートデスクトップ';

  @override
  String get atermiusTerminal => 'Atermius · ターミナル';

  @override
  String get atermiusNeedsReliablePersistentBrowserStorage =>
      'Atermius では、オフラインデータと複数タブ間の同期を安全に保つため、信頼できる永続的なブラウザストレージが必要です。OPFS または共有 IndexedDB に対応したブラウザを使用し、通常のブラウズモードでこのサイトにローカルストレージの使用を許可してから、もう一度お試しください。';

  @override
  String get chooseAWorkspace => 'ワークスペースを選択';

  @override
  String get conflictingWindowRequests => 'ウィンドウのリクエストが競合しています。';

  @override
  String get continueLabel => '続行';

  @override
  String get createOrUnlockAnEncryptedHost =>
      '暗号化されたホストと認証情報の保管庫を作成またはロック解除します。アカウント、サーバー接続、デバイス間同期は不要です。';

  @override
  String get localProfileStorageIsUnavailableServer =>
      'ローカルプロファイルのストレージを利用できません。ストレージバックエンドが対応していれば、サーバーモードは引き続き使用できます。';

  @override
  String get localOnlyProfile => 'ローカル専用プロファイル';

  @override
  String get openLocally => 'ローカルで開く';

  @override
  String get opening => '開いています…';

  @override
  String get serverAccountAndSync => 'サーバーアカウントと同期';

  @override
  String get serverProfilesSyncEncryptedDataAcross =>
      'サーバープロファイルは暗号化されたデータをデバイス間で同期します。ローカル専用プロファイルはこのブラウザまたはデバイスにのみ保存され、同期されません。';

  @override
  String get useYourSelfHostedServerAccount =>
      'セルフホストサーバーのアカウントと同期された保管庫を使用します。';

  @override
  String get workspaceSwitchCouldNotBeCompleted => 'ワークスペースの切り替えを完了できませんでした。';

  @override
  String get theSecurityComponentsOrLocalStorage =>
      'セキュリティコンポーネントまたはローカルストレージを起動できませんでした。デプロイファイルが揃っていること、ブラウザがこのサイトにローカルストレージの使用を許可していることを確認してから、もう一度お試しください。';

  @override
  String get workspaceMenu => 'ワークスペースメニュー';

  @override
  String get workspaceModeSettings => 'ワークスペースモードの設定';

  @override
  String get couldntSaveOrSwitchTheWorkspace =>
      'ワークスペースモードを保存または切り替えできませんでした。ローカルストレージを確認して、もう一度お試しください。';

  @override
  String get couldntInitializeTheSecureWorkspace => 'セキュアワークスペースを初期化できませんでした';

  @override
  String get couldntOpenTheCloudWorkspaceOr =>
      'クラウドワークスペースを開くか、ワークスペースモードを保存できませんでした。ローカルストレージを確認して、もう一度お試しください。';

  @override
  String get couldntOpenLocalProfileStorageAllow =>
      'ローカルプロファイルのストレージを開けませんでした。このサイトに永続ストレージの使用を許可してから、もう一度お試しください。';

  @override
  String get couldntVerifyTheSeparateWindowTry =>
      '別ウィンドウを検証できませんでした。元のウィンドウからもう一度お試しください。';

  @override
  String get aLocalStorageWriteWasInterrupted =>
      'ローカルストレージへの書き込みが中断されました。空き容量を確保し、このサイトで開いている他の Atermius タブを閉じてから、ページを再読み込みして復旧し、もう一度お試しください。';

  @override
  String get preparingSecureWorkspace => 'セキュアワークスペースを準備しています';

  @override
  String get checkingLocalEncryptedStorage => 'ローカルの暗号化ストレージを確認しています。';

  @override
  String get reloadPage => 'ページを再読み込み';

  @override
  String get retry => '再試行';

  @override
  String get supportedBrowserStorageRequired => '対応するブラウザストレージが必要です';

  @override
  String get supportedBrowserStorageIsRequiredCheck =>
      '対応するブラウザストレージが必要です。永続ストレージの権限を確認して、もう一度お試しください。';

  @override
  String get someFileWindowsArentUnlockedAre =>
      '一部のファイルウィンドウがロック解除されていないか、切り替え中か、位置の準備ができていません。しばらく待ってから保存し直してください。';

  @override
  String theRemotePathIsntARegular(String path) {
    return 'リモートパスは通常のファイルではありません：$path';
  }

  @override
  String get scpFileListingRequiresTheSftp =>
      'SCP のファイル一覧には、この SSH 接続の SFTP ディレクトリチャネルが必要です。サーバーで SFTP が有効になっているか確認してください。';

  @override
  String get theFileActionFailedCheckThe =>
      'ファイルの操作に失敗しました。SSH/SFTP の接続とフォルダーの権限を確認してください。';

  @override
  String get invalidRemoteFolderPath => 'リモートのフォルダーのパスが無効です。';

  @override
  String get theSshSftpSessionIsClosed => 'SSH/SFTP セッションは閉じられています。';

  @override
  String get onlyRegularFilesCanBeDownloaded => 'ダウンロードできるのは通常のファイルのみです。';

  @override
  String get onlySizeBoundedRegularFilesCan =>
      'ストリーミングでダウンロードできるのは、サイズが制限された通常のファイルのみです。';

  @override
  String get invalidFileNameFormat => 'ファイル名の形式が無効です。';

  @override
  String get theFileExceedsThisPlatformsSftp =>
      'ファイルがこのプラットフォームの SFTP アップロードのサイズ上限を超えています。';

  @override
  String couldntSafelyCreateTheRemoteFile(Object error) {
    return 'リモートファイルを安全に作成できませんでした。すでに存在しているか、現在のユーザーに書き込み権限がない可能性があります。既存のファイルは上書きされません。（$error）';
  }

  @override
  String get invalidFolderNameFormat2 => 'フォルダー名の形式が無効です。';

  @override
  String get invalidRemoteFileNameFormat2 => 'リモートのファイル名の形式が無効です。';

  @override
  String get theRemoteFileExceedsTheLocal =>
      'リモートファイルがローカルのダウンロードサイズ上限を超えています。';

  @override
  String get theRemoteFileExceedsTheStreaming =>
      'リモートファイルがストリーミングダウンロードのサイズ上限を超えています。';

  @override
  String get theRemotePathIsntASize => 'リモートパスはサイズが制限された通常のファイルではありません。';

  @override
  String get theRemotePathIsntARegular2 => 'リモートパスは通常のファイルではありません。';

  @override
  String get theRemotePathIsNoLonger => 'リモートパスが通常のファイルではなくなりました。';

  @override
  String get anotherForwardAlreadyUsesThisListener =>
      '別の転送がすでにこの待ち受けアドレスとポートを使用しています。';

  @override
  String get couldNotStartThisForwardCheck =>
      'この転送を開始できませんでした。ポートが使用可能か、SSH サーバーの転送ポリシーを確認してください。';

  @override
  String get forwardStartWasCancelled => '転送の開始をキャンセルしました。';

  @override
  String get sshConnectionClosedWhileForwardingWas => '転送の開始中に SSH 接続が閉じられました';

  @override
  String get sshPortForwardingIsUnavailableHere =>
      'ここでは SSH ポートフォワーディングを利用できません。';

  @override
  String get sshPortForwardingRuntimeIsUnavailable =>
      'このプラットフォームでは SSH ポートフォワーディングのランタイムを利用できません。';

  @override
  String get theSshConnectionForThisForward =>
      'この転送の SSH 接続は終了しました。先に再接続してください。';

  @override
  String get theForwardProfileIsInvalid => '転送プロファイルが無効です。';

  @override
  String get theForwardStoppedUnexpectedly => '転送が予期せず停止しました。';

  @override
  String get thisSshPortForwardProfileIs => 'この SSH ポート転送プロファイルはすでに有効です。';

  @override
  String addressBindaddressIsNotAvailableOn(String bindAddress) {
    return 'このデバイスではアドレス $bindAddress を利用できません。';
  }

  @override
  String connectionLimitSshportforwardmaxconnectionsReachedNewClients(
    int sshPortForwardMaxConnections,
  ) {
    return '接続数の上限（$sshPortForwardMaxConnections）に達しました。他の接続が閉じるまで新しいクライアントは拒否されます。';
  }

  @override
  String couldNotOpenAnSshChannel(String target) {
    return '$target への SSH チャネルを開けませんでした。';
  }

  @override
  String portEndpointIsAlreadyInUse(String endpoint) {
    return 'このデバイスのポート $endpoint はすでに使用中です。';
  }

  @override
  String get theSshConnectionIsNoLonger => 'SSH 接続は利用できなくなりました。';

  @override
  String theSshServerCouldNotConnect(String target) {
    return 'SSH サーバーは $target に接続できませんでした。';
  }

  @override
  String theSshServerDeniedForwardingTo(String target) {
    return 'SSH サーバーは $target への転送を拒否しました（管理上禁止されています）。';
  }

  @override
  String get theSshServerDidNotAnswer =>
      'SSH サーバーがリモート転送のリクエストに時間内に応答しませんでした。遅れて作成されたリスナーはキャンセルされます。サーバーが確認しない場合は、切断して再接続してください。';

  @override
  String get theSshServerDidNotConfirm => 'SSH サーバーはリモート転送の削除を確認しませんでした。';

  @override
  String get theSshServerIsOutOf => 'SSH サーバーのリソースが不足しているため、新しいチャネルを開けません。';

  @override
  String theSshServerRefusedAChannel(String target) {
    return 'SSH サーバーは $target へのチャネルを拒否しました。';
  }

  @override
  String get theDeviceSocksListenerStoppedUnexpectedly =>
      'デバイスの SOCKS リスナーが予期せず停止しました。';

  @override
  String get theDeviceListenerStoppedUnexpectedly => 'デバイスのリスナーが予期せず停止しました。';

  @override
  String thisDeviceCouldNotListenOn(String endpoint) {
    return 'このデバイスは $endpoint で待ち受けできませんでした。';
  }

  @override
  String thisDeviceRefusedToListenOn(String endpoint) {
    return 'このデバイスは $endpoint での待ち受けを拒否しました（権限がありません。低いポートや予約済みのポート範囲はブロックされる場合があります）。';
  }

  @override
  String timedOutOpeningAnSshChannel(String target) {
    return '$target への SSH チャネルを開く処理がタイムアウトしました。';
  }

  @override
  String get thisBrowserBuildCannotOpenTcp =>
      'このブラウザ版では TCP リスナーや送信用ソケットを開けないため、ここで SSH ポートフォワーディングを実行できません。プロファイルはデスクトップアプリとモバイルアプリ向けに引き続き同期されます。';

  @override
  String get theSshRelayOriginDoesntMatch =>
      'SSH リレーのオリジンがサーバー設定と一致しません。管理者に公開サイトのアドレスを確認してもらってください。';

  @override
  String get theSshRelayTargetMustBe =>
      'SSH リレーの接続先は有効な IP アドレスとポートである必要があります。サーバーのリレーは DNS ホスト名を受け付けません。';

  @override
  String get theSshRelayTicketExpiredStart =>
      'SSH リレーのチケットが失効しました。もう一度接続してください。';

  @override
  String get tooManySshRelayRequestsTry =>
      'SSH リレーへのリクエストが多すぎます。しばらくしてからもう一度お試しください。';

  @override
  String get theSshRelayConnectionTimedOut =>
      'SSH リレー接続がタイムアウトしました。サーバーの稼働状況、ネットワーク、接続先アドレスを確認してください。';

  @override
  String get theSshHostKeyDiffersFrom =>
      'SSH ホスト鍵が保存済みのフィンガープリントと異なるため、接続を拒否しました。信頼を更新する前に、信頼できる経路で新しいフィンガープリントを確認してください。';

  @override
  String get sshHostKeyVerificationFailedThe =>
      'SSH ホスト鍵の検証に失敗したため、接続を拒否しました。サーバーの ID と接続経路を確認してください。';

  @override
  String get sshAuthenticatedButTheTerminalSession =>
      'SSH の認証は完了しましたが、ターミナルセッションを開けませんでした。';

  @override
  String get sshHandshakeFailedCheckTheSsh =>
      'SSH ハンドシェイクに失敗しました。SSH サーバーとリレー接続を確認してください。';

  @override
  String get theSshPrivateKeyCouldntBe =>
      'SSH 秘密鍵を解析できないか、パスフレーズが正しくありません。鍵の形式とパスフレーズを確認してください。';

  @override
  String get theSshNetworkConnectionWasInterrupted =>
      'SSH のネットワーク接続が中断されました。リレーと接続先サーバーを確認してください。';

  @override
  String get sshAuthenticationFailedCheckTheUser =>
      'SSH 認証に失敗しました。ユーザー名、パスワード、または秘密鍵を確認してください。';

  @override
  String get theSshConnectionDroppedBeforeAuthentication =>
      '認証が完了する前に SSH 接続が切断されました。ネットワークとサーバーを確認してから、もう一度お試しください。';

  @override
  String get theUntrustedSshHostKeyWas => '未信頼の SSH ホスト鍵を拒否し、接続をキャンセルしました。';

  @override
  String get couldntEstablishTheSshRelayWebsocket =>
      'SSH リレーの WebSocket を確立できませんでした。インスタンスの HTTPS/WSS アドレス、リレーのオリジン設定、ネットワークを確認してから、もう一度お試しください。';

  @override
  String get theServerRelayPolicyRejectedThis =>
      'サーバーのリレーポリシーにより、この接続先アドレスまたはポートは拒否されました。管理者に SSH 接続先の許可リストを確認してもらってください。';

  @override
  String get theServerHasntEnabledTheSsh =>
      'サーバーで SSH リレーが有効になっていません。管理者にリレーと接続先ネットワークの設定を依頼してください。';

  @override
  String get localStorageNeedsRecoveryReadingEditing2 =>
      'ローカルストレージの復旧が必要です。このデータベースの読み取り、編集、同期を一時停止しました。すべての Atermius タブを閉じてから開き直すと、最後に保存されたデータが復元されます。';

  @override
  String get invalidWindowSetPreferenceFormat => 'ウィンドウセットの設定の形式が無効です。';

  @override
  String get invalidStagedMigrationCiphertextContext =>
      'ステージされた移行用暗号文のコンテキストが無効です。';

  @override
  String get invalidStagedMigrationCiphertextFormat => 'ステージされた移行用暗号文の形式が無効です。';

  @override
  String get theServerHasntConfirmedAllMigration =>
      'サーバーはまだすべての移行レコードを確認していません。';

  @override
  String get theMigrationJournalContainsDuplicateOperation =>
      '移行ジャーナルに重複した操作 ID が含まれています。';

  @override
  String get theMigrationDestinationOutboxDoesntMatch =>
      '移行先の送信トレイがステージされた暗号文と一致しません。';

  @override
  String get theMigrationDestinationOutboxDoesntMatch2 =>
      '移行先の送信トレイがステージングのジャーナルと一致しません。';

  @override
  String get aStagedRecordInTheMigration => '移行先のステージ済みのレコードが削除されています。';

  @override
  String get theMigrationDestinationContainsDuplicateRecord =>
      '移行先に重複したレコードの先頭が含まれています。';

  @override
  String get theMigrationDestinationRecordDoesntMatch =>
      '移行先のレコードがステージされた暗号文と一致しません。';

  @override
  String get theMigrationRecordStillHasUnconfirmed =>
      '移行レコードに未確認の送信トレイの操作が残っています。';

  @override
  String get recycleBinSnapshotExpiredBeforeIt =>
      'ごみ箱のスナップショットは読み込む前に期限切れになりました。';

  @override
  String get snapshotExpiredBeforeRecoveryCouldStart =>
      'スナップショットは復旧の開始前に期限切れになりました。';

  @override
  String get theServerGenerationChangedSynchronizeBefore =>
      'サーバーの世代が変わりました。復元する前に同期してください。';

  @override
  String itemExitItem2(Object item, Object item2) {
    return '$item · 終了コード $item2';
  }

  @override
  String get addThisAccountInYourAuthenticator =>
      '認証アプリにこのアカウントを追加し、現在の 6 桁のコードを入力してください。セットアップシークレットは一時的なもので、このクライアントが保存することはありません。';

  @override
  String get authenticatorCode => '認証アプリのコード';

  @override
  String get disableMfa => 'MFA を無効化';

  @override
  String get disableTwoFactorSignIn => '2 要素サインインを無効化';

  @override
  String get disabled => '無効';

  @override
  String get eachCodeCanBeUsedOnce =>
      '認証アプリを使えなくなった場合、各コードは 1 回だけ使用できます。パスワードマネージャーなどの安全な場所に保管してください。すべてのコードが表示されるのは今回だけです。このクライアントはコードを保存もコピーもしません。';

  @override
  String get enabled => '有効';

  @override
  String get enterExactlySixDigits => '6 桁の数字を入力してください。';

  @override
  String get enterYourCurrentPasswordAndAuthenticator =>
      '現在のパスワードと認証コードを入力してください。';

  @override
  String get iSavedTheseCodesSecurely => 'これらのコードを安全に保管しました';

  @override
  String get mfaRecoveryCodesWereRotated => 'MFA の復旧コードを更新しました。';

  @override
  String mfaRecoveryCodesFormattedcodes(String formattedCodes) {
    return 'MFA 復旧コード：$formattedCodes';
  }

  @override
  String get newRecoveryCodesWereGeneratedBut =>
      '新しい復旧コードを生成しましたが、保存済みとして確認されていません。もう一度更新すると代わりのセットが表示されます。';

  @override
  String get provisioningUri => 'プロビジョニング URI';

  @override
  String get refreshMfaStatus => 'MFA の状態を更新';

  @override
  String get rotateMfaRecoveryCodes => 'MFA 復旧コードを更新';

  @override
  String get rotateCodes => 'コードを更新';

  @override
  String get rotateRecoveryCodes => '復旧コードを更新';

  @override
  String get saveYourMfaRecoveryCodes => 'MFA 復旧コードを保管してください';

  @override
  String get setUpAuthenticator => '認証アプリを設定';

  @override
  String get setUpAuthenticatorApp => '認証アプリを設定';

  @override
  String setupExpiresTolocal(DateTime toLocal) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '設定の有効期限：$toLocalString';
  }

  @override
  String get setupSecret => 'セットアップシークレット';

  @override
  String totpProvisioningUriProvisioninguri(String provisioningUri) {
    return 'TOTP プロビジョニング URI：$provisioningUri';
  }

  @override
  String totpSetupSecretSecret(String secret) {
    return 'TOTP セットアップシークレット：$secret';
  }

  @override
  String get theLastRecoveryCodesWereNot =>
      '前回の復旧コードは保存済みとして確認されていません。コードを更新して新しいセットを表示してください。';

  @override
  String get twoFactorSignIn => '2 要素サインイン';

  @override
  String get useAnAuthenticatorAppOrA =>
      '2 つ目のサインイン要素として、認証アプリまたは使い捨ての復旧コードを使用します。サーバーは TOTP シードを暗号化して保存し、クライアントはセットアップシークレットと復旧コードを表示に必要な間だけ保持します。';

  @override
  String get verifyAndEnable => '確認して有効化';

  @override
  String get youWillBeAbleToSign =>
      'マスターパスワードだけでサインインできるようになります。認証アプリと未使用の復旧コードは使えなくなります。';

  @override
  String valuevalueRecoveryCodesRemaining(int valueValue) {
    return '残りの復旧コード：$valueValue 個';
  }

  @override
  String get aHostChangedAfterThePreview =>
      'プレビュー後にホストが変更されました。インポーターを開き直し、最新のリビジョンを確認してください。';

  @override
  String get aHostWithThisNameWas =>
      '確認中に同じ名前のホストが保存されました。インポーターを開き直して比較してください。';

  @override
  String get applyTheseInventoryChanges => 'これらのインベントリの変更を適用しますか？';

  @override
  String applyCountChanges(int count) {
    return '$count 件の変更を適用';
  }

  @override
  String applyCountReviewedChangeSTo(int count) {
    return '確認済みの $count 件の変更を、アクティブな保管庫の暗号化ホストレコードに適用します。見つからない項目は古い項目としてマークされるだけで、ホストは削除されません。Ansible のグループはホストのタグとして保存されます。認証情報はインポートされず、インベントリや SSH コマンドは実行されません。';
  }

  @override
  String get chooseInventoryFile => 'インベントリファイルを選択';

  @override
  String get confirmChanges => '変更を確定';

  @override
  String get createANewSource => '新しいソースを作成';

  @override
  String get importAnsibleInventory => 'Ansible インベントリをインポート';

  @override
  String get inventory => 'インベントリ';

  @override
  String get inventoryFile => 'インベントリファイル';

  @override
  String get inventoryFilesAreLimitedTo1 => 'インベントリファイルは 1 MiB までです。';

  @override
  String get inventorySource => 'インベントリのソース';

  @override
  String get inventorySourcesAreLimitedTo1 => 'インベントリのソースは 1 MiB までです。';

  @override
  String get keepManual => '手動の編集を保持';

  @override
  String get markStaleKeepThisHostSaved => '古い項目としてマークし、このホストは保持';

  @override
  String get noHostsWereImportedTheVault =>
      'ホストはインポートされませんでした。保管庫が変更されたか、ホストを保存できなかった可能性があります。';

  @override
  String get noConcreteHostCandidatesWereFound => '具体的なホスト候補が見つかりませんでした。';

  @override
  String get pasteOrChooseAStaticIni =>
      '静的な INI/YAML インベントリを貼り付けるか選択してください。動的インベントリは拒否されます。このインポーターがスクリプト、プラグイン、Ansible、SSH、ネットワークリクエストを実行することはありません。確認済みのホスト接続フィールドのみをインポートし、認証情報と秘密鍵は無視します。';

  @override
  String get pastedInventory => '貼り付けたインベントリ';

  @override
  String get reviewBlockedThisInventoryCannotBe =>
      '確認がブロックされました：このインベントリはインポートできません。';

  @override
  String get reviewEachFieldConflictManualEdits =>
      '各フィールドの競合を確認してください。既定では手動の編集が保持されます。見つからない項目は保存されたままで、明示的に選択した場合にのみ古い項目としてマークできます。';

  @override
  String get reviewPastedInventory => '貼り付けたインベントリを確認';

  @override
  String get savedInEncryptedHostMetadataFile =>
      '暗号化されたホストのメタデータに保存されます。ファイルパスは保存されません。';

  @override
  String get sourceLabel => 'ソースのラベル';

  @override
  String get staticInventoryText => '静的インベントリのテキスト';

  @override
  String get theActiveVaultChangedOrBecame =>
      'インポート中にアクティブな保管庫が変更されたか、読み取り専用になりました。';

  @override
  String get theActiveVaultChangedOrIs =>
      'アクティブな保管庫が変更されたか、書き込めません。インポートする前にインベントリを再確認してください。';

  @override
  String get theInventoryCouldNotBeReviewed => 'インベントリを安全に確認できませんでした。';

  @override
  String get theSelectedFileCouldNotBe => '選択したファイルを読み込めませんでした。';

  @override
  String get theSelectedFileCouldNotBe2 => '選択したファイルを確認できませんでした。';

  @override
  String get useInventory => 'インベントリを使用';

  @override
  String restoreDeadlineFormat2(String format) {
    return ' 復元期限：$format。';
  }

  @override
  String get n0Auto => '0 = 自動';

  @override
  String get n180UnicodeCharactersUniqueWithout =>
      '1〜80 文字の Unicode。大文字と小文字を区別せず一意である必要があります。';

  @override
  String aHostCanHaveAtMost(int maxHostPortForwardProfiles) {
    return '1 台のホストに設定できるポート転送プロファイルは最大 $maxHostPortForwardProfiles 個です。';
  }

  @override
  String get aConcurrentChangeWasDetectedYour =>
      '同時に行われた変更を検出しました。名前、メンバーシップ、ポリシーの下書きは保持されています。';

  @override
  String get aNewEncryptedRevisionWillBe =>
      '現在のリモートの先頭に対して新しい暗号化リビジョンが作成されます。サーバーが解決を受け入れるまで、古いブランチは記録されたままです。';

  @override
  String get aNewerAtermiusWebBuildIs => '新しい Atermius Web のビルドを利用できます。';

  @override
  String get aNewerWebBuildIsAvailable =>
      '新しい Web ビルドを利用できます。再読み込みしても問題ないタイミングで、上の通知を確認してください。';

  @override
  String aPreviousRepairAlreadySelectedRetainedrepairid(
    String retainedRepairId,
  ) {
    return '以前の修復ですでに $retainedRepairId が選択されています。同期で削除マーカーが確認されるまで、再試行時もこのレコードを保持する必要があります。';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry(String retainedRecordId) {
    return '以前の修復で $retainedRecordId が選択されています。保管庫の同期で削除マーカーが確認されるまで、再試行時もこのレコードを保持する必要があります。';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry2(
    String retainedRecordId,
  ) {
    return '以前の修復で $retainedRecordId が選択されています。保管庫の同期で削除マーカーが確認されるまで、再試行時もこのレコードを保持する必要があります。';
  }

  @override
  String get aRandomRecoveryCodeEncryptsA =>
      'ランダムな復旧コードは、別の復旧用 ID を暗号化します。この ID には保管庫のエポック鍵の封印済みコピーが保存されます。アカウント鍵は保管庫の鍵ではありません。コードはこのデバイス以外の場所に保管してください。';

  @override
  String get aSplitWorkspaceNeedsAtLeast => '分割ワークスペースには 2 つ以上のペインが必要です';

  @override
  String get aUsersEffectiveRelayAccessAlso =>
      'ユーザーの実効 Relay アクセスは、アカウントのポリシー、他のすべてのサーバーグループ、デプロイの制限との共通部分になります。';

  @override
  String get active => 'アクティブ';

  @override
  String get apiEndpoint => 'API エンドポイント';

  @override
  String get acceptVaultInvitation => '保管庫への招待を承諾';

  @override
  String get acceptAndUnlockVault => '承諾して保管庫のロックを解除';

  @override
  String get acceptInvitation => '招待を承諾';

  @override
  String get acceptedByAdapter7UtcDays => 'アダプターが受理（UTC 7 日間）';

  @override
  String get accessExpires => 'アクセスの有効期限';

  @override
  String get account => 'アカウント';

  @override
  String get accountDevice => 'アカウントとデバイス';

  @override
  String get accountId => 'アカウント ID';

  @override
  String get accountRelayPolicy => 'アカウントの Relay ポリシー';

  @override
  String get accountRelayPolicySaveFailed => 'アカウントの Relay ポリシーを保存できませんでした';

  @override
  String get accountDeletion => 'アカウントの削除';

  @override
  String get accountDeletionImmediatelyRevokesAllSessions =>
      'アカウントを削除すると、すべてのセッションとデバイスが直ちに失効します。サーバーの期限になると、個人用保管庫とアカウントのデータが完全に削除され、他の人の保管庫におけるメンバーシップと鍵へのアクセスも削除されます。他のメンバーの共有保管庫のデータは削除されません。他のアクティブなメンバーまたは招待中のメンバーがいる共有保管庫のオーナーは、先にそのメンバーシップを解決する必要があります。';

  @override
  String get accountDeletionScheduledByTheServer => 'サーバーがアカウントの削除を予約しました。';

  @override
  String accountDeletionScheduledServerPurgeAfter(
    Object accountDeletionPurgeAfter,
  ) {
    return 'アカウントの削除を予約しました。サーバーの purge_after：$accountDeletionPurgeAfter。';
  }

  @override
  String get accountDevices => 'アカウントのデバイス';

  @override
  String get accountInvitationCreated => 'アカウントの招待を作成しました';

  @override
  String get accountInvitations => 'アカウントの招待';

  @override
  String get accountRecovery => 'アカウントの復旧';

  @override
  String accountRecoveryCodeCode(String code) {
    return 'アカウントの復旧コード：$code';
  }

  @override
  String get accountRecoveryWasDisabled => 'アカウントの復旧を無効にしました。';

  @override
  String accountRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return 'アカウントのリビジョン $revision · 更新 $formatTime';
  }

  @override
  String get accountSessions => 'アカウントのセッション';

  @override
  String get accounts => 'アカウント';

  @override
  String actionsForFilename(String filename) {
    return '$filename の操作';
  }

  @override
  String get active2 => 'アクティブ';

  @override
  String activePaneValuevalue(int valueValue) {
    return 'アクティブなペイン $valueValue';
  }

  @override
  String get activeAccountOnCurrentPage => '現在のページのアクティブなアカウント';

  @override
  String get activeDevices => 'アクティブなデバイス';

  @override
  String get activePane => 'アクティブなペイン';

  @override
  String get activeSessions => 'アクティブなセッション';

  @override
  String get actorDeviceId => '操作したデバイスの ID';

  @override
  String get actorUserId => '操作したユーザーの ID';

  @override
  String get add => '追加';

  @override
  String get addCredentialSecretParameter => '認証情報のシークレットパラメーターを追加';

  @override
  String get addAHostFirst => '先にホストを追加してください。';

  @override
  String get addAPasswordOrPrivateKey => 'パスワードまたは秘密鍵の ID を追加し、ホストに関連付けてください。';

  @override
  String get addCredential2 => '認証情報を追加';

  @override
  String get addForwardingProfile => '転送プロファイルを追加';

  @override
  String get addParameter => 'パラメーターを追加';

  @override
  String get addProfile => 'プロファイルを追加';

  @override
  String get addThisValueAsTheBearer =>
      'この値を /api/v1/admin/metrics の Bearer 認証情報として追加してください。このアプリには保存されず、後から取得することもできません。';

  @override
  String get addYourFirstHost => '最初のホストを追加';

  @override
  String get adjustTheSearchOrGroupFilter => '検索やグループの絞り込みを調整すると、他のホストも表示されます。';

  @override
  String get advanceOnlyAfterEachPageIs => '各ページの永続化後にのみ進む';

  @override
  String get afterConfirmationThisFingerprintIsSaved =>
      '確定すると、このフィンガープリントは暗号化レコードとして現在の保管庫に保存され、デバイスに同期されます。後で鍵が変わると、クライアントは接続を拒否します。';

  @override
  String algorithmAlgorithm(String algorithm) {
    return 'アルゴリズム：$algorithm';
  }

  @override
  String get allActiveVaultDevicesReportSupport =>
      'アクティブな保管庫デバイスはすべて秘匿化 v1 に対応していると報告しています。';

  @override
  String get allowFutureAutomaticPurge => '今後の自動削除を許可しますか？';

  @override
  String get allowFuturePurge => '今後の削除を許可';

  @override
  String get allowedCidrNetworks => '許可する CIDR ネットワーク';

  @override
  String get allowedCidrsOnePerLine => '許可する CIDR（1 行に 1 つ）';

  @override
  String get allowedPorts => '許可するポート';

  @override
  String anEncryptedVaultArchiveCoveringPendingcount(int pendingCount) {
    return '保留中の操作 $pendingCount 件を含む暗号化保管庫アーカイブを最近エクスポートしました。送信トレイはローカルに保存されたままで、再読み込み後に同期されます。';
  }

  @override
  String get anonymousDiagnostics => '匿名の診断情報';

  @override
  String get anonymousSyncDiagnosticsExported => '匿名の同期診断情報をエクスポートしました。';

  @override
  String appliedAppliedInventoryChangeSHost(int applied) {
    return '$applied 件のインベントリの変更を適用しました。ホストのレコードは暗号化され、同期のキューに追加されています。';
  }

  @override
  String get applyWebUpdate => 'Web 更新を適用しますか？';

  @override
  String get approvalJsonCopied => '承認 JSON をコピーしました。';

  @override
  String get approveSealKeys => '承認して鍵を封印';

  @override
  String get approveEnrollment => '登録を承認';

  @override
  String approveValuevalue(Object valueValue) {
    return '$valueValue を承認しますか？';
  }

  @override
  String get archiveBytes => 'アーカイブのバイト数';

  @override
  String get archivePassword => 'アーカイブのパスワード';

  @override
  String get archiveSaveWasCanceled => 'アーカイブの保存をキャンセルしました。';

  @override
  String get argumentsJsonArray2 => '引数（JSON 配列）';

  @override
  String get askTheServerOperatorToConfigure =>
      'スケジュールを有効にする前に、サーバーの運用者に暗号化バックアップの保存先と鍵の設定を依頼してください。';

  @override
  String get atLeast12CharactersIndependentFrom =>
      '12 文字以上。アカウントのパスワードとは別のものです。';

  @override
  String get atTheDeadlineTheServerPurges =>
      '期限になると、サーバーはこの保管庫のレコード、履歴、競合、スナップショット、暗号化オブジェクト、メンバーシップ、鍵エンベロープを完全に削除します。既存のローカル／オフラインのコピーやバックアップは別管理のため、この操作でリモートから消去することはできません。';

  @override
  String get atTheServerDeadlineRecordsHistory =>
      'サーバーの期限になると、レコード、履歴、競合、スナップショット、暗号化オブジェクト、鍵エンベロープが完全に削除されます。オフラインのコピーや保持されたバックアップは別管理のため、リモートで消去されることはありません。';

  @override
  String get atermiusWillKeepThisPageAnd =>
      '以下の手順を完了して再読み込みを確定するまで、Atermius はこのページと SSH セッションを開いたままにします。';

  @override
  String get atermiusWillReloadThisPageTo =>
      '新しいセルフホスト Web バンドルを読み込むため、Atermius はこのページを再読み込みします。確認するまでページは切り替わりません。';

  @override
  String get attemptedAt => '試行日時';

  @override
  String get auditLog2 => '監査ログ';

  @override
  String get automaticPurgeConsentRecordedForThis =>
      'この削除マーカーに対する自動削除の同意を記録しました。制限付きのメンテナンスが、復元期限とその他の必要なチェックの後に完全削除する場合があります。同意しても直ちには削除されません。オフラインのデバイスのコピーやエクスポートしたファイルは削除されません。';

  @override
  String automaticPurgeConsentValuevalue(String valueValue) {
    return '自動削除の同意：$valueValue';
  }

  @override
  String get back => '戻る';

  @override
  String get backgroundSyncNotifications => 'バックグラウンド同期の通知';

  @override
  String backupBucketAccessCheckResultNotice(String notice) {
    return 'バックアップバケットのアクセスチェック結果：$notice';
  }

  @override
  String get backupCommandFailed => 'バックアップコマンドが失敗しました';

  @override
  String baseRevisionShortauditidCurrentHeadShortauditid2(
    String shortAuditId,
    String shortAuditId2,
  ) {
    return 'ベースのリビジョン：$shortAuditId · 現在の先頭：$shortAuditId2';
  }

  @override
  String get bashNonInteractiveExecution => 'Bash の非対話実行';

  @override
  String get bashNonInteractiveExecutionRequiresA =>
      'Bash の非対話実行 · POSIX 互換のログインシェルと Bash が必要';

  @override
  String get bashOnlyEachArgvItemIs =>
      'Bash のみ。argv の各項目はリテラルまたはパラメーター参照で、1 つのシェル単語として引用符で囲まれます。';

  @override
  String get batchCommandExecution => '一括コマンド実行';

  @override
  String bindingsAreEncryptedInCurrentvaultnameAnd(String currentVaultName) {
    return 'キー割り当ては $currentVaultName で暗号化され、この保管庫にアクセスできるデバイスに同期されます。';
  }

  @override
  String get bindingsSyncAsSemanticActionsMod =>
      'キー割り当ては意味的な操作として同期されます。「mod」はローカルで Apple プラットフォームでは Command、その他では Control に解決されます。ショートカットはターミナルの入力にフォーカスがある間のみ動作し、検索フィールドでは通常のテキスト入力とキー操作が保たれます。';

  @override
  String get bothRevisionsStayEncryptedInLocal =>
      'どちらのリビジョンもローカルストレージに暗号化されたまま保持されます。現在のリモートの先頭に基づく新しいリビジョンにするブランチを選択してください。';

  @override
  String branchShortauditid(String shortAuditId) {
    return 'ブランチ $shortAuditId';
  }

  @override
  String get browseFiles2 => 'ファイルを参照';

  @override
  String browseFilesOnValuevalue(String valueValue) {
    return '$valueValue のファイルを参照';
  }

  @override
  String get byApprovingThisActiveMemberDevice =>
      '承認すると、このアクティブなメンバーデバイスは、アクセスできるすべての保管庫と鍵エポックについて封印された鍵エンベロープを送信します。新しいブラウザを管理している人と、リクエストとデバイス ID を照合してください。';

  @override
  String get conflictConnectionsBlocked => '競合 — 接続はブロック';

  @override
  String get currentVault => '現在の保管庫';

  @override
  String get cancelBatch => '一括処理をキャンセル';

  @override
  String get cancelDeletion => '削除を取り消す';

  @override
  String get cancelExecution => '実行をキャンセル';

  @override
  String get cancelScheduledDeletion => '予定された削除を取り消しますか？';

  @override
  String cancelThePendingDeletionForVaultname(
    String vaultName,
    String vaultLifecycleDate,
  ) {
    return '$vaultName の保留中の削除を取り消しますか？サーバーへの書き込みが再び可能になり、暗号化された送信トレイの同期を再開できます。取り消しは $vaultLifecycleDate より前に限り可能です。';
  }

  @override
  String get cancellationRequestedTheActiveCommandMay =>
      'キャンセルをリクエストしました。実行中のコマンドはすでに開始している可能性がありますが、以降のホストでは実行されません。';

  @override
  String get cancellationRequestedTheCommandMayAlready =>
      'キャンセルをリクエストしました。コマンドはすでに開始している可能性があります。再試行はしません。';

  @override
  String get capabilities => '機能';

  @override
  String get changeMasterPassword => 'マスターパスワードを変更';

  @override
  String changeToRole(String role) {
    return '$role に変更';
  }

  @override
  String changeUsernameFromItemToRole(
    String username,
    Object item,
    String role,
  ) {
    return '$username のロールを $item から $role に変更しますか？新しいメンバーシップのバージョンに署名し、残りのすべてのアクティブなメンバーデバイスの保管庫鍵を更新します。保留中の招待トークンは無効になり、再発行が必要です。古い鍵のコピーをリモートで消去することはできません。';
  }

  @override
  String get changingPassword => 'パスワードを変更しています…';

  @override
  String get checkBucketAccess => 'バケットへのアクセスを確認';

  @override
  String get checkForUpdates => '更新を確認';

  @override
  String get checkingConfiguredBucketAccessWithHeadbucket =>
      'HeadBucket で設定済みバケットへのアクセスを確認しています…';

  @override
  String get checkingOnlineDevices => 'オンラインのデバイスを確認しています…';

  @override
  String get checkingThisSelfHostedInstanceFor =>
      'このセルフホストのインスタンスに新しい Web ビルドがあるか確認しています…';

  @override
  String get choose2575 => '25〜75 の範囲で選択してください';

  @override
  String get chooseConnectOnTheLeftTo => '左側の「接続」を選ぶと新しいセッションを開始します。';

  @override
  String get chooseAHost => 'ホストを選択';

  @override
  String chooseAHostForPaneValuevalue(int valueValue) {
    return 'ペイン $valueValue のホストを選択';
  }

  @override
  String get chooseAHostFromTheActive =>
      'アクティブな保管庫からホストを選択してください。置き換えは暗号化されたレイアウト更新として保存され、接続はしません。';

  @override
  String get chooseAHostOnTheLeft => '左側のホストを選択すると SSH セッションを開始します。';

  @override
  String get chooseALocalEncryptedArchiveOr =>
      'ローカルの暗号化アーカイブまたはそのリモートのレプリカを選択し、サービスをオンラインのまま別のコピーを準備します。リモートのバイトは、ステージを公開する前にダイジェストとアーカイブの認証で確認されます。この操作でコピーが有効化されたり稼働中のデータが置き換えられたりすることはありません。その後のオフラインでの切り替えは運用者が行います。';

  @override
  String get chooseALocalEncryptedArchiveTo =>
      'ローカルの暗号化アーカイブを選択し、サービスをオンラインのまま別のコピーを準備します。ステージを公開する前にアーカイブを再度確認します。この操作でコピーが有効化されたり稼働中のデータが置き換えられたりすることはありません。その後のオフラインでの切り替えは運用者が行います。';

  @override
  String get chooseANewMasterPasswordDifferent =>
      '現在とは異なる新しいマスターパスワードを選んでください。';

  @override
  String get chooseASourceForEachChanged =>
      '変更された各フィールドのソースを選択してください。競合ブランチは検証済みの不採用バージョンで、現在の保管庫のバージョンは確定済みの最新版です。';

  @override
  String get chooseActiveVaultDevicesThatMay =>
      '暗号化されたターミナル出力を閲覧できるアクティブな保管庫デバイスを選択してください。オブザーバーはホストのターミナルに入力したりサイズを変更したりできません。このリストはセッション中は固定で、デバイスは参加後に送信された出力のみを受け取り、それ以前のスクロールバックは再生されません。';

  @override
  String get chooseConnectedHosts => '接続済みのホストを選択';

  @override
  String get chooseHowOftenThisServerCreates =>
      'このサーバーが暗号化バックアップを作成する頻度を選択します。アーカイブの保存先と暗号鍵はサーバー上で非公開に保たれます。';

  @override
  String get chooseOneDeviceAlreadyApprovedFor =>
      'この共有で承認済みのデバイスを 1 台選択してください。そのデバイスは最長 5 分間この SSH セッションに入力できます。SSH 接続はこのホストデバイス上に残ります。';

  @override
  String get chooseTheDefaultPreferenceRecordTo => '保持する既定の設定レコードを選択';

  @override
  String get chooseTheDefaultWorkspaceSectionFor =>
      'アクティブな保管庫の既定のワークスペースのセクションを選択します。この設定は、保管庫にアクセスできるデバイスに同期される前に暗号化されます。';

  @override
  String get chooseTheShortcutPreferenceRecordTo => '保持するショートカット設定のレコードを選択';

  @override
  String get chooseTheTerminalFontSizeRecord => '保持するターミナルのフォントサイズのレコードを選択';

  @override
  String get chooseTheTerminalPaletteSharedBy =>
      'この保管庫で承認されたすべてのデバイスが共有するターミナルの配色を選択します。選択した配色は、許可リスト方式の暗号化された設定として保存されます。';

  @override
  String get chooseTheTerminalThemeRecordTo => '保持するターミナルテーマのレコードを選択';

  @override
  String get cleanupPending => 'クリーンアップ待ち';

  @override
  String get clearLocalHistoryOnlyRemovesThis =>
      'ローカル履歴の消去では、このデバイスの行だけが削除されます。保管庫にすでに同期されたレコードは削除されません。';

  @override
  String get clearThisHostsLocalHistory => 'このホストのローカル履歴を消去';

  @override
  String get closeActiveSshTerminalsBeforeApplying =>
      '更新を適用する前に、アクティブな SSH ターミナルを閉じてください。';

  @override
  String get closeSavedLayoutPreview => '保存済みレイアウトのプレビューを閉じる';

  @override
  String get color2 => '色';

  @override
  String get commaOrLineSeparatedPortNumbers => 'カンマまたは改行で区切ったポート番号。';

  @override
  String get commaOrNewlineSeparatedForExample => 'カンマまたは改行で区切ります（例：22, 2222）';

  @override
  String get commandHistory => 'コマンド履歴';

  @override
  String get commandSnippets => 'コマンドスニペット';

  @override
  String get commandSuggestions => 'コマンドの候補';

  @override
  String get commandsAppearHereAfterTheHook =>
      'フックを貼り付けてコマンドが完了すると、ここにコマンドが表示されます。';

  @override
  String get commandsRunOneAtATime =>
      'コマンドは 1 つずつ実行されます。失敗、ゼロ以外の終了、タイムアウト、不明な結果のいずれかでバッチは停止し、コマンドの再試行はしません。';

  @override
  String get compareEachValueAndRecordId =>
      '各値とレコード ID を比較してください。選択したレコード ID は有効なまま残り、他のレコードは暗号化された削除マーカーで削除されます。';

  @override
  String get compareThisPublicFingerprintWithAnother =>
      'この公開フィンガープリントを、別の経路で他のデバイスまたは信頼できる管理者と照合し、インスタンスの ID を確認してください。';

  @override
  String get comparedWithTheLastVerifiedServer =>
      '最後に検証したサーバーのメタデータとの比較です。オフライン中はこの値が古い場合があります。';

  @override
  String get compatibilityReportNotReported => '互換性レポート · 未報告';

  @override
  String get compatibilityReportUnverifiedDetailsHidden =>
      '互換性レポート · 未検証のため詳細は非表示';

  @override
  String get completionStatusUnknown => '完了状態は不明';

  @override
  String get concurrentLayoutEditsAreKeptAs =>
      '同時に行われたレイアウトの編集は、別々の暗号化ブランチとして保持されます。このデバイスのブランチを名前付きのコピーとして保存しても元の競合は未解決のままで、ペインは接続されません。';

  @override
  String get confirmAndReAuthenticate => '確定して再認証';

  @override
  String get confirmAndRun => '確定して実行';

  @override
  String confirmAndRunOnCountHosts(int count) {
    return '確定して $count 台のホストで実行';
  }

  @override
  String get confirmArchivePassword => 'アーカイブパスワードの確認';

  @override
  String get confirmNewMasterPassword => '新しいマスターパスワードの確認';

  @override
  String get confirmRevokeInvitation => '招待の取り消しを確定';

  @override
  String confirmTargetName(String name) {
    return '対象を確認：$name';
  }

  @override
  String get conflictBranches => '競合ブランチ';

  @override
  String get conflictResolutionSynced => '競合の解決を同期しました。';

  @override
  String conflictingSshKeysAreSavedFor(String join) {
    return '$join について競合する SSH 鍵が保存されているため、接続はブロックされています。信頼するつもりのない鍵はすべて失効させてください。どちらのフィンガープリントも未検証の場合は両方を失効させ、別の経路で確認した後でのみ鍵を承認してください。';
  }

  @override
  String get conflictingBranchesArePreservedUntilYou =>
      '保持するバージョンを選ぶまで、競合しているブランチは保持されます。';

  @override
  String get connect => '接続';

  @override
  String get connectAnSshHostToBrowse => 'リモートファイルを参照するには SSH ホストに接続してください。';

  @override
  String connectToNameToOpenAn(String name) {
    return '$name に接続すると対話型のシェルが開きます。';
  }

  @override
  String get connectionSettingsAreKeptAsOne =>
      '接続設定は 1 つのまとまりとして保持されます。元のベースと検証済みの 2 つのブランチを確認してから、1 つの完全なまとまりを選択してください。アドレス、ポート、SSH ユーザー名、認証方式、選択した認証情報、経路、プロキシ、転送ルール、ホストの信頼設定が含まれます。';

  @override
  String get connections => '接続';

  @override
  String connectionsToEndpointUsingAlgorithmWill(
    String endpoint,
    String algorithm,
  ) {
    return 'この署名付きの失効が同期されると、各デバイスで $algorithm を使った $endpoint への接続はブロックされます。フィンガープリントは履歴に残ります。';
  }

  @override
  String get consumed => '使用済み';

  @override
  String get continueToFinalConfirmation => '最終確認に進む';

  @override
  String get continueToReAuthenticate => '再認証に進む';

  @override
  String get controlActive => '操作中';

  @override
  String get copied => 'コピーしました';

  @override
  String get copiedPasteThisCommandIntoThe => 'コピーしました。このコマンドをターミナルに貼り付けてください：';

  @override
  String get copiesWaiting => '待機中のコピー';

  @override
  String get copy => 'コピー';

  @override
  String get copyCode => 'コードをコピー';

  @override
  String get copyCredential => '認証情報をコピー';

  @override
  String get copyFailedSelectTheValueManually => 'コピーに失敗しました。値を手動で選択してください';

  @override
  String get copyInvitationToken => '招待トークンをコピー';

  @override
  String get copySignedShareRequest => '署名済みの共有リクエストをコピー';

  @override
  String get copyTerminalShareId => 'ターミナル共有 ID をコピー';

  @override
  String get copyThisOneTimeInvitationToken =>
      'このワンタイムの招待トークンをコピーして、対象のアカウント所有者に共有してください。このダイアログを閉じると再表示されません。';

  @override
  String get copyThisResponseToTheNew =>
      'この応答を新しいブラウザにコピーしてください。公開 ID 情報と封印された鍵エンベロープが含まれ、秘密鍵は含まれません。';

  @override
  String get copyToken => 'トークンをコピー';

  @override
  String get copyingEncryptedArchive => '暗号化アーカイブをコピー中';

  @override
  String get couldNotClearThisHostsLocal => 'このホストのローカル履歴を消去できませんでした。';

  @override
  String get couldNotConfirmInputControlRevocation =>
      '入力操作の取り消しを確認できませんでした。ホストの SSH 接続はアクティブなままです。';

  @override
  String get couldNotCopyTheSetupCommand =>
      '設定コマンドをコピーできませんでした。リモートのシェルにはコマンドを送信していません。';

  @override
  String get couldNotEnableVaultHistorySync =>
      '保管庫の履歴の同期を有効にできませんでした。アクティブな保管庫に書き込めるか確認してから再試行してください。';

  @override
  String get couldNotExportAnonymousSyncDiagnostics =>
      '匿名の同期診断情報をエクスポートできませんでした。';

  @override
  String get couldNotGrantInputControlCheck =>
      '入力操作を付与できませんでした。セッションを確認してから再試行してください。';

  @override
  String get couldNotJoinCheckTheSession =>
      '参加できませんでした。セッション ID と保管庫へのアクセスを確認してください。';

  @override
  String couldNotLoadTheCurrentHost(String friendlyError) {
    return '現在のホストを読み込めません：$friendlyError';
  }

  @override
  String get couldNotRemoveThisForwardingProfile =>
      'この転送プロファイルを削除できませんでした。接続を確認し、同期してから再試行してください。';

  @override
  String get couldNotSaveForwardingSettingsSync =>
      '転送の設定を保存できませんでした。同期してから再試行してください。現在の設定は変更されていません。';

  @override
  String get couldNotSaveTerminalFontSize =>
      'ターミナルのフォントサイズを保存できませんでした。保管庫への書き込み権限を確認してから再試行してください。';

  @override
  String get couldNotSaveTerminalShortcutsCheck =>
      'ターミナルのショートカットを保存できませんでした。保管庫への書き込み権限を確認してから再試行してください。';

  @override
  String get couldNotSaveTerminalThemeCheck =>
      'ターミナルのテーマを保存できませんでした。保管庫への書き込み権限を確認してから再試行してください。';

  @override
  String couldNotSaveTheReviewedTuple(String friendlyError) {
    return '確認済みのまとまりを保存できません：$friendlyError';
  }

  @override
  String get couldNotSaveThisGroupYour =>
      'このグループを保存できませんでした。変更内容はフォームに残っています。保管庫へのアクセスを確認してから再試行してください。';

  @override
  String get couldNotSaveThisPreferenceCheck =>
      'この設定を保存できませんでした。保管庫への書き込み権限を確認してから再試行してください。';

  @override
  String get couldNotStartOrStopThis =>
      'この転送を開始または停止できませんでした。ポートが使用可能か、SSH サーバーの転送ポリシーを確認してください。';

  @override
  String get couldNotStartTerminalSharingCheck =>
      'ターミナルの共有を開始できませんでした。保管庫とネットワークを確認してから再試行してください。';

  @override
  String get couldNotTurnOffVaultHistory =>
      '保管庫の履歴の同期をオフにできませんでした。もう一度お試しください。';

  @override
  String get create2 => '作成';

  @override
  String get createVault => '保管庫を作成';

  @override
  String get createADedicatedReadOnlyBearer =>
      'GET /api/v1/admin/metrics 専用の読み取り専用 Bearer 認証情報を作成します。シークレットは一度だけ表示され、このアプリが保存することはありません。';

  @override
  String get createAGroupToOrganizeRelated => 'グループを作成して関連するサーバーを整理します。';

  @override
  String get createAnotherVault => '別の保管庫を作成';

  @override
  String get createCredential => '認証情報を作成';

  @override
  String get createEncryptedVault => '暗号化保管庫を作成';

  @override
  String get createGroup => 'グループを作成';

  @override
  String get createInvitation => '招待を作成';

  @override
  String get createRemoteFolder => 'リモートフォルダーを作成';

  @override
  String get createResolution => '解決を作成';

  @override
  String get createSnippet => 'スニペットを作成';

  @override
  String get createSplitWorkspace => '分割ワークスペースを作成';

  @override
  String get createUsernameBoundInvitationsAndReview =>
      'ユーザー名に紐付いた招待を作成し、その状態を確認します。';

  @override
  String get createYourFirstGroup => '最初のグループを作成';

  @override
  String get createYourFirstHostAndAttach =>
      '最初のホストを作成し、クライアント側で暗号化された SSH 認証情報を添付してください。ここにはサンプルやデモのデータはありません。';

  @override
  String get created => '作成日時';

  @override
  String get createdAt => '作成日時';

  @override
  String createdFormattimeUpdatedFormattime2(
    String formatTime,
    String formatTime2,
  ) {
    return '作成 $formatTime · 更新 $formatTime2';
  }

  @override
  String createdFormat(String format) {
    return '作成 · $format';
  }

  @override
  String get createsAV2RoomInputStays =>
      'v2 ルームを作成します。承認済みのデバイス 1 台に最長 5 分間のリースを付与するまで、入力はオフのままです。';

  @override
  String get credential => '認証情報';

  @override
  String credentialActionsName(String name) {
    return '認証情報の操作：$name';
  }

  @override
  String get credentialMergeSavedAndSyncing => '認証情報の統合を保存し、同期しています';

  @override
  String get credentialName2 => '認証情報の名前';

  @override
  String credentialReferenceNameMustPointTo(String name) {
    return '認証情報の参照 $name はパスワード認証情報を指す必要があります';
  }

  @override
  String credentialReferenceNameWasNotFound(String name) {
    return '認証情報の参照 $name がこの保管庫に見つかりません';
  }

  @override
  String get credentialSelectionProxySettingsForwardingDetails =>
      '認証情報の選択、プロキシ設定、転送の詳細、ホストの信頼情報はマスクされ、選択したブランチから引き継がれます。';

  @override
  String get credentialStatus => '認証情報の状態';

  @override
  String get credentialValuesAreSentOnlyThrough =>
      '認証情報の値は暗号化された SSH exec チャネル経由でのみ送信されます。リモートのプログラムは引数として受け取るため、同じリモートユーザーで実行されているプロセスから見える可能性があります。';

  @override
  String credentialNameUsernameValuevalue(
    String name,
    String username,
    String valueValue,
  ) {
    return '認証情報：$name、$username、$valueValue';
  }

  @override
  String get currentVault2 => '現在の保管庫';

  @override
  String get currentAccount => '現在のアカウント';

  @override
  String currentAccountValuevalue(String valueValue) {
    return '現在のアカウント：$valueValue';
  }

  @override
  String get currentDevice => '現在のデバイス';

  @override
  String currentHeadShortauditid(String shortAuditId) {
    return '現在の先頭：$shortAuditId';
  }

  @override
  String get currentMasterPassword => '現在のマスターパスワード';

  @override
  String get currentSignedInAccountAdministrativeActions =>
      '現在サインイン中のアカウント · 管理操作は非表示';

  @override
  String get cursorPolicy => 'カーソルのポリシー';

  @override
  String get deletionScheduled => '削除予定';

  @override
  String get deadLettered => 'デッドレター化';

  @override
  String get defaultLabel2 => '既定';

  @override
  String get defaultSshCredential => '既定の SSH 認証情報';

  @override
  String defaultSectionSectionlabelRecordIdId(
    String sectionLabel,
    String id,
    String revisionLabel,
  ) {
    return '既定のセクション：$sectionLabel、レコード ID：$id、リビジョン：$revisionLabel';
  }

  @override
  String get defaultWorkspaceSection => '既定のワークスペースのセクション';

  @override
  String defaultDefaultvalue(Object defaultValue) {
    return '既定値：$defaultValue';
  }

  @override
  String get delete2 => '削除';

  @override
  String get deleteForwardingProfile => '転送プロファイルを削除';

  @override
  String get deleteGroup3 => 'グループを削除';

  @override
  String get deleteGroup4 => 'グループを削除しますか？';

  @override
  String get deleteServerManagedGroup => 'サーバー管理のグループを削除';

  @override
  String get deleteServerManagedGroup2 => 'サーバー管理のグループを削除しますか？';

  @override
  String get deleteThisItem => 'この項目を削除しますか？';

  @override
  String get deletingAccountAdministrativeActionsUnavailable =>
      'アカウントを削除中 · 管理操作は利用できません';

  @override
  String get deletingThisVaultStartsTheServer =>
      'この保管庫を削除すると、サーバーで設定された猶予期間が始まります。メンバーはすぐに読み取り専用になり、完全削除の正確な期限はサーバーから返されます。';

  @override
  String get deletionCanceledPendingEncryptedSyncCan =>
      '削除を取り消しました。保留中の暗号化同期を再開できます。';

  @override
  String get deletionRequested => '削除をリクエスト済み';

  @override
  String get deletionScheduledByTheServer => 'サーバーが削除を予約しました。';

  @override
  String deletionScheduledServerPurgeAfterVaultlifecycledate(
    String vaultLifecycleDate,
  ) {
    return '削除を予約しました。サーバーは $vaultLifecycleDate 以降に完全に削除します。';
  }

  @override
  String get deliveryHistoryIsUnavailableOnThis => 'このサーバーでは配信履歴を利用できません。';

  @override
  String get deliveryWindowUtc => '配信の時間帯（UTC）';

  @override
  String get deploymentCidrLimits => 'デプロイの CIDR 制限';

  @override
  String get deploymentPortLimits => 'デプロイのポート制限';

  @override
  String get deploymentRelayAvailability => 'デプロイのリレーの利用可否';

  @override
  String get destinationOnSshTarget => 'SSH 接続先上の宛先';

  @override
  String get destinationOnThisDevice => 'このデバイス上の宛先';

  @override
  String get deviceId => 'デバイス ID';

  @override
  String get deviceSocksListenerAddress => 'デバイスの SOCKS 待ち受けアドレス';

  @override
  String get deviceAccessRevoked => 'デバイスのアクセスは失効しています';

  @override
  String get deviceApproved => 'デバイスを承認しました';

  @override
  String get deviceCapabilitySignerIsInvalid => 'デバイス機能の署名者が無効です。';

  @override
  String get deviceCompatibilityReportIsInvalid => 'デバイスの互換性レポートが無効です。';

  @override
  String get deviceListenerAddress => 'デバイスの待ち受けアドレス';

  @override
  String get deviceRevoked3 => 'デバイスは失効しています';

  @override
  String deviceSubstring(String substring) {
    return 'デバイス $substring';
  }

  @override
  String get devicesActive => 'アクティブなデバイス';

  @override
  String get diagnosticsExportCancelled => '診断情報のエクスポートをキャンセルしました。';

  @override
  String get direction => '方向';

  @override
  String get directory => 'ディレクトリ';

  @override
  String get directoryIsEmpty => 'ディレクトリは空です';

  @override
  String get disableAccount => 'アカウントを無効化';

  @override
  String get disableAccountRecovery2 => 'アカウントの復旧を無効化';

  @override
  String get disableAccountRecovery => 'アカウントの復旧を無効にしますか？';

  @override
  String get disableAccount2 => 'アカウントを無効にしますか？';

  @override
  String get disableOrReEnableAccountsAnd =>
      'アカウントの無効化や再有効化、アクティブなセッションの失効を行います。';

  @override
  String get disableRecovery => '復旧を無効化';

  @override
  String disableUsernameServerSessionsWillBe(String username) {
    return '$username を無効にしますか？サーバーのセッションは失効し、再度サインインできなくなります。キャッシュされたデバイスのデータは消去されず、既存の直接の SSH 接続は SSH サーバーが閉じるまで続く場合があります。';
  }

  @override
  String get disabledByPolicy => 'ポリシーで無効化されています';

  @override
  String get discardIsolatedCopy => '隔離コピーを破棄';

  @override
  String get discardIsolatedRestoreCopy => '隔離された復元用コピーを破棄しますか？';

  @override
  String get discarded => '破棄済み';

  @override
  String get disconnect2 => '切断';

  @override
  String get disconnected2 => '切断済み';

  @override
  String get disconnectedRecursivePreview => '切断された再帰プレビュー';

  @override
  String get disconnectedConnectTabsExplicitly => '未接続 · タブは個別に接続してください';

  @override
  String disconnectedDirectionlabelFirstpercentSecondpercentPanecountPanes(
    String directionLabel,
    int firstPercent,
    int secondPercent,
    int paneCount,
  ) {
    return '未接続 · $directionLabel · $firstPercent/$secondPercent · ペイン $paneCount 個 · ペインは個別に接続してください';
  }

  @override
  String get done2 => '完了';

  @override
  String get download2 => 'ダウンロード';

  @override
  String get due => '期限';

  @override
  String get duplicate => '複製';

  @override
  String get duplicateWorkspace => 'ワークスペースを複製';

  @override
  String get dynamicSocks5 => 'ダイナミック SOCKS5';

  @override
  String dynamicSocks5Bind(String bind) {
    return 'ダイナミック SOCKS5 · $bind';
  }

  @override
  String get dynamicForwardingIsALoopbackOnly =>
      'ダイナミックフォワーディングは、ループバック限定で SOCKS 認証のない SOCKS5 CONNECT プロキシです。信頼できるデバイスでのみ使用してください。';

  @override
  String get eachDeviceKeepsItsPrivateSigning =>
      '各デバイスは署名用と暗号化用の秘密鍵をローカルに保持します。承認時に送信されるのは、このデバイスがアクセスできる各保管庫の鍵エポックを含む不透明な封印済みエンベロープだけです。自分がリクエストしていない登録は決して承認しないでください。';

  @override
  String get eachSelectedHostReceivesReferencedCredential =>
      '選択した各ホストは、参照された認証情報のシークレットを暗号化された SSH exec チャネル経由で受け取ります。リモートのプログラムは引数として受け取るため、同じリモートユーザーで実行されているプロセスから見える可能性があります。';

  @override
  String get edit2 => '編集';

  @override
  String get editVaultQuota => '保管庫のクォータを編集';

  @override
  String get editCommandSnippet => 'コマンドスニペットを編集';

  @override
  String get editCredential2 => '認証情報を編集';

  @override
  String get editForwardingProfile => '転送プロファイルを編集';

  @override
  String get editGroup2 => 'グループを編集';

  @override
  String get editHostGroup => 'ホストグループを編集';

  @override
  String get editQuota => 'クォータを編集';

  @override
  String get editText2 => 'テキストを編集';

  @override
  String editableCeilingValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '編集可能な上限：$valueValue · CIDR：$summarize · ポート：$summarize2';
  }

  @override
  String get editorCanEditVaultRecords => '編集者 · 保管庫のレコードを編集できます';

  @override
  String get effectiveSshRelayService => '実効 SSH リレーサービス';

  @override
  String effectiveGroupStateValuevalueCidrsSummarize(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'グループの実効状態：$valueValue · CIDR：$summarize · ポート：$summarize2';
  }

  @override
  String effectiveStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '実効状態：$valueValue · CIDR：$summarize · ポート：$summarize2';
  }

  @override
  String get enableBashCommandHistory => 'Bash のコマンド履歴を有効化';

  @override
  String get enableBashIntegration => 'Bash 連携を有効化';

  @override
  String get enableRelayForThisAccount => 'このアカウントで Relay を有効化';

  @override
  String get enableRelayForThisGroup => 'このグループで Relay を有効化';

  @override
  String get enableSshRelay => 'SSH リレーを有効化';

  @override
  String get enableVaultSync => '保管庫の同期を有効化';

  @override
  String get enableAndCopy => '有効にしてコピー';

  @override
  String get enableHostApprovedInputControl => 'ホストが承認した入力操作を有効化';

  @override
  String get enableScheduledBackups => 'スケジュールバックアップを有効化';

  @override
  String get enabledForThisDeviceTheServer =>
      'このデバイスで有効になっています。サーバーは汎用的な同期のヒントのみを送信します。';

  @override
  String get enablingSyncUploadsUpTo500 =>
      '同期を有効にすると、アクティブな保管庫内のホストについて既存のローカルコマンドを最大 500 件アップロードし、その後は新しいコマンドもアップロードします。コマンドはアクティブな保管庫の鍵で暗号化され、アクセス権を持つ保管庫メンバーなら誰でも読み取れます。同期をオフにすると未送信のキュー内コマンドはキャンセルされますが、送信済みまたは確定済みのコマンドは届いて保管庫に残る場合があります。';

  @override
  String get encryptVaultArchive => '保管庫アーカイブを暗号化';

  @override
  String get encryptedVaultArchiveSaved => '暗号化された保管庫アーカイブを保存しました。';

  @override
  String get encryptedArchive => '暗号化アーカイブ';

  @override
  String get encryptedArchiveBytes => '暗号化アーカイブのバイト数';

  @override
  String get encryptedBackup => '暗号化バックアップ';

  @override
  String get encryptedBackupsAreCreatedOnThe =>
      '運用者がインスタンスのデータディレクトリの外に、オーナーのみアクセス可能な ATERMIUS_BACKUP_ARCHIVE_DIR と ATERMIUS_BACKUP_KEY_FILE のパスを設定すると、サーバーで暗号化バックアップが作成されます。このクライアントがアーカイブや鍵のパスを送信することはありません。';

  @override
  String encryptedObjectBlocksCount(int count) {
    return '暗号化オブジェクトブロック：$count';
  }

  @override
  String get encryptedRecordsImmutableRetriesAndRecovery =>
      'この保管庫の暗号化レコード、変更不可の再試行、復旧チェックポイント。';

  @override
  String get encryptedWithTheActiveVaultKey =>
      'アクティブな保管庫の鍵で暗号化されます。アクセス権を持つメンバーは読み取れます。同期をオフにすると未送信のキュー内コマンドはキャンセルされますが、送信済みまたは確定済みのコマンドは届いて保管庫に残る場合があります。';

  @override
  String get encryptionKeyFingerprint => '暗号鍵のフィンガープリント';

  @override
  String get encryptionKeyFingerprintSha256 => '暗号鍵のフィンガープリント · SHA-256';

  @override
  String get enrollmentJson => '登録 JSON';

  @override
  String get enrollmentJsonIsNotValid => '登録 JSON が無効です。';

  @override
  String get enterAWorkspaceName => 'ワークスペース名を入力してください';

  @override
  String get enterAQuotaFrom1Byte => '1 バイトから 1 TiB までのクォータを入力してください。';

  @override
  String get enterASupportedNonReservedChord =>
      'mod+alt+shift+f のような、対応していて予約されていない組み合わせを入力してください。各組み合わせは有効で重複しないものにしてください。';

  @override
  String get enterAWholeNumberFrom1 => '1〜720 の整数を入力してください。';

  @override
  String get enterAWholeNumberPercent => '整数のパーセントを入力してください';

  @override
  String get enterRequiredValuesToPreview => 'プレビューするには必須の値を入力してください。';

  @override
  String get enterTheCurrentMasterPasswordAt =>
      '現在のマスターパスワードを入力してください（12 文字以上）。';

  @override
  String get enterTheSessionUuidProvidedBy =>
      'ホストから提供されたセッション UUID を入力してください。別の読み取り専用ターミナルが開き、SSH 接続は作成されません。';

  @override
  String epochKeyVersionsCount(int count) {
    return 'エポック鍵のバージョン：$count';
  }

  @override
  String get eventId => 'イベント ID';

  @override
  String get everyActiveVaultDeviceMustSupport =>
      'このレコードを完全に削除するには、アクティブな保管庫のすべてのデバイスが秘匿化 v1 に対応している必要があります。対応していないデバイスを更新または廃止してから再試行してください。';

  @override
  String get everyRoleChangeAndRevocationCommits =>
      'ロールの変更や失効のたびに、新しい鍵エポックを伴う署名付きのメンバーシップ更新が確定されます。オーナーと残っているすべてのアクティブなメンバーデバイスが新しい鍵を受け取ります。';

  @override
  String get executionMode => '実行モード';

  @override
  String get executionPreview => '実行のプレビュー';

  @override
  String existingShellLabelShell2(String shell) {
    return '既存のシェルのラベル：$shell';
  }

  @override
  String exitCodeExitcode(Object exitCode) {
    return '終了コード：$exitCode';
  }

  @override
  String exitExitstatusCompletedat(int exitStatus, String completedAt) {
    return '終了コード $exitStatus · $completedAt';
  }

  @override
  String get expectedAJsonArray => 'JSON 配列が必要です';

  @override
  String get expired => '期限切れ';

  @override
  String get expires => '有効期限';

  @override
  String get exportArchive => 'アーカイブをエクスポート';

  @override
  String get exportDiagnostics => '診断情報をエクスポート';

  @override
  String get exportTheFixedServerHistoryCurrent =>
      '確定済みのサーバー履歴、現在の削除マーカー、ローカルの送信トレイ／競合ブランチ、暗号化オブジェクトブロックをエクスポートします。ファイルは別のアーカイブパスワードにより Argon2id と XChaCha20-Poly1305 で保護されます。';

  @override
  String get failed2 => '失敗';

  @override
  String get failureCategory => '失敗のカテゴリ';

  @override
  String get favorite => 'お気に入り';

  @override
  String get file => 'ファイル';

  @override
  String get filterCommands => 'コマンドを絞り込み';

  @override
  String get fingerprintsApprovedDuringSshConnectionAre =>
      'SSH 接続中に承認したフィンガープリントは、この保管庫で暗号化され、そのデバイスに同期されます。失効も暗号化され、承認の履歴は表示されたまま残ります。古いデバイス限定のピン留めは保管庫の信頼としてインポートされません。';

  @override
  String get finish => '完了';

  @override
  String get finishedAt => '完了日時';

  @override
  String get firstChild => '最初の子要素（%）';

  @override
  String get focus => 'フォーカス';

  @override
  String get folderName => 'フォルダー名';

  @override
  String get forExample104000 => '例：10.40.0.0/16';

  @override
  String get forwardType => '転送の種類';

  @override
  String get freeFormScriptLegacy => '自由形式のスクリプト（旧形式）';

  @override
  String get futureAutomaticPurgeConsentWithdrawn => '今後の自動削除の同意を取り消しました。';

  @override
  String get generatedAt => '生成日時';

  @override
  String get generation => '世代';

  @override
  String get generationCheckpoint => '世代のチェックポイント';

  @override
  String get generationMatches => '世代が一致';

  @override
  String get generationMismatch => '世代が不一致';

  @override
  String get go => '移動';

  @override
  String get goToPath => 'パスへ移動';

  @override
  String get goToRemotePath => 'リモートパスへ移動';

  @override
  String get grantFor5Minutes => '5 分間許可';

  @override
  String get grantInputControl => '入力の操作権を付与';

  @override
  String get groupRelayPolicy => 'グループの Relay ポリシー';

  @override
  String groupActionsName2(String name) {
    return 'グループの操作：$name';
  }

  @override
  String get groupName3 => 'グループ名';

  @override
  String groupRevisionRevisionMembershipRevisionMembershiprevision(
    int revision,
    int membershipRevision,
    int revision2,
  ) {
    return 'グループのリビジョン $revision · メンバーシップのリビジョン $membershipRevision · ポリシーのリビジョン $revision2';
  }

  @override
  String groupGroupname(Object groupName) {
    return 'グループ：$groupName';
  }

  @override
  String headShortauditid(String shortAuditId) {
    return '先頭 $shortAuditId';
  }

  @override
  String get hideRelayPolicy => 'Relay ポリシーを隠す';

  @override
  String get hidePasswordSecret => 'パスワードのシークレットを隠す';

  @override
  String get hideSessions => 'セッションを隠す';

  @override
  String get host => 'ホスト';

  @override
  String get hostConnectionSettingsReviewedAndQueued =>
      'ホストの接続設定を確認し、同期のキューに追加しました。';

  @override
  String get hostGroups => 'ホストグループ';

  @override
  String get hostIsNoLongerAvailableSync => 'ホストは利用できなくなりました。同期してから再試行してください。';

  @override
  String get hostUnavailable => 'ホストを利用できません';

  @override
  String hostPaneValuevalue(int valueValue) {
    return 'ホスト · ペイン $valueValue';
  }

  @override
  String get hostApprovedTerminalInput => 'ホストが承認したターミナル入力';

  @override
  String hostNameUsernameEndpointValuevalue(
    String name,
    String username,
    String endpoint,
    String valueValue,
  ) {
    return 'ホスト：$name、$username@$endpoint$valueValue';
  }

  @override
  String get hostsWithoutAnOverrideInheritThe =>
      '上書きしていないホストは、最も近いグループの既定値を継承します。';

  @override
  String get iStoredThisCodeSecurely => 'このコードを安全に保管しました';

  @override
  String get iUnderstandBoundedMaintenanceMayPurge =>
      '制限付きのメンテナンスが、復元期限と必要なチェックの後にこの削除マーカーを完全削除する場合があることを理解しています。';

  @override
  String get iUnderstandThisPermanentlyRemovesThe =>
      'この操作でレコードがサーバーのアクティブな状態から完全に削除されることを理解しています。';

  @override
  String get iveSavedIt => '保存しました';

  @override
  String get idle => '待機中';

  @override
  String get ifCopyingIsUnavailableSelectThe => 'コピーできない場合は、上の値を選択してください。';

  @override
  String get ifYouOwnASharedVault =>
      '他のアクティブなメンバーまたは招待中のメンバーがいる共有保管庫を所有している場合、サーバーは削除を拒否し、所有権は移転されません。猶予期間中は、ログインページでアカウント名とマスターパスワードを使って取り消し、再度サインインできます。続行する前に暗号化アーカイブを保存してください。';

  @override
  String get importSshConfig => 'SSH 設定をインポート';

  @override
  String get importArchive => 'アーカイブをインポート';

  @override
  String get importToThisVault => 'この保管庫にインポート';

  @override
  String get importVerifiedVaultArchive => '検証済みの保管庫アーカイブをインポートしますか？';

  @override
  String importedImportedHostSRecordsAre(int imported) {
    return '$imported 台のホストをインポートしました。レコードは暗号化され、同期のキューに追加されています。';
  }

  @override
  String get includesTheInstanceAccountAndEvery =>
      'インスタンス、アカウント、割り当て済みのすべてのサーバーグループを含みます。';

  @override
  String get inputControlOff => '入力操作：オフ';

  @override
  String get inputControlRevoking => '入力操作：取り消し中';

  @override
  String inputControlControllerlabel(Object controllerLabel) {
    return '入力操作：$controllerLabel';
  }

  @override
  String get inputIsEncryptedToTheHost =>
      '入力はホスト宛てに暗号化され、ホストが承認したリースの期限とともに失効します。サイズ変更は引き続き無効で、ライブ出力のみ利用できます。';

  @override
  String get installationWideEventsSeparateFromAccount =>
      'インストール全体のイベントです。アカウントや保管庫の監査ページとは別に表示されます。';

  @override
  String get instance => 'インスタンス';

  @override
  String get instanceId => 'インスタンス ID';

  @override
  String get instanceVaultQuotas => 'インスタンスの保管庫クォータ';

  @override
  String get instanceAccountsAndSessions => 'インスタンスのアカウントとセッション';

  @override
  String get instanceAdminAudit => 'インスタンス管理者の監査';

  @override
  String get instanceAdminOverview => 'インスタンス管理の概要';

  @override
  String get instanceBackupStatus => 'インスタンスのバックアップ状態';

  @override
  String get instanceJobs => 'インスタンスのジョブ';

  @override
  String instanceRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return 'インスタンスのリビジョン $revision · 更新 $formatTime';
  }

  @override
  String get instanceSigningKeyFingerprintSha256 =>
      'インスタンス署名鍵のフィンガープリント · SHA-256';

  @override
  String get instanceWideBootstrapAndNetworkPolicy =>
      'インスタンス全体のブートストラップとネットワークポリシーは、セルフホストサーバーの運用者が管理します。';

  @override
  String get interrupted => '中断';

  @override
  String get interruptedRetryPending => '中断 · 再試行待ち';

  @override
  String get intervalInHours => '間隔（時間）';

  @override
  String get invalidFontSizeValue => 'フォントサイズの値が無効です';

  @override
  String get invalidToken7UtcDays => '無効なトークン（UTC 7 日間）';

  @override
  String get inventoryEntryStale => 'インベントリの項目が古くなっています';

  @override
  String get invitationCreated => '招待を作成しました';

  @override
  String get invitationExpired => '招待は期限切れです';

  @override
  String get invitationExpiresInDays => '招待の有効日数';

  @override
  String invitationExpiresFormattedexpiry(String formattedExpiry) {
    return '招待の有効期限：$formattedExpiry';
  }

  @override
  String get invitationNeedsReissue => '招待の再発行が必要です';

  @override
  String get invitationPending => '招待は承諾待ちです';

  @override
  String get invitationToken => '招待トークン';

  @override
  String get invitationTokenCopied => '招待トークンをコピーしました。';

  @override
  String get invitationUsername => '招待するユーザー名';

  @override
  String get inviteMember => 'メンバーを招待';

  @override
  String inviteToCurrentvaultname(String currentVaultName) {
    return '$currentVaultName に招待';
  }

  @override
  String get issueAccountInvitation => 'アカウントの招待を発行';

  @override
  String get issueCategory => '問題のカテゴリ';

  @override
  String get join => '参加';

  @override
  String get joinASharedTerminal => '共有ターミナルに参加';

  @override
  String get joinHostGrantedControl => 'ホストが許可した操作に参加';

  @override
  String get keepVault => '保管庫を維持';

  @override
  String get keepAccess => 'アクセスを維持';

  @override
  String get keepAccount => 'アカウントを維持';

  @override
  String get keepCurrentOwner => '現在のオーナーを維持';

  @override
  String get keepRepeatableCommandsInTheSame =>
      '繰り返し使うコマンドを、ホストと同じ暗号化保管庫に保存します。';

  @override
  String get keepScheduledDeletion => '予定された削除を維持';

  @override
  String get keepSelectedBindingsAndRemoveDuplicates => '選択したキー割り当てを保持して重複を削除';

  @override
  String get keepSelectedFontSizeAndRemove => '選択したフォントサイズを保持して重複を削除';

  @override
  String get keepSelectedRecordAndRemoveDuplicates => '選択したレコードを保持して重複を削除';

  @override
  String get keepSelectedThemeAndRemoveDuplicates => '選択したテーマを保持して重複を削除';

  @override
  String get keepThisDeviceVersion => 'このデバイスのバージョンを保持';

  @override
  String get keepThisDeviceVersion2 => 'このデバイスのバージョンを保持しますか？';

  @override
  String get keyPassphraseOptional => '鍵のパスフレーズ（任意）';

  @override
  String get keyUpdateNeeded => '鍵の更新が必要';

  @override
  String get knownHost => '既知のホスト';

  @override
  String get lastChanged => '最終変更';

  @override
  String get lastPull => '前回の取得';

  @override
  String get lastRun => '前回の実行';

  @override
  String get lastRunStatus => '前回の実行状態';

  @override
  String get lastSuccessfulSync => '最後に成功した同期';

  @override
  String get lastUpdated => '最終更新';

  @override
  String lastVerifiedServerShortkey(String shortKey) {
    return '最後に検証したサーバー：$shortKey';
  }

  @override
  String get latestCopy => '最新のコピー';

  @override
  String get leased => 'リース中';

  @override
  String get leaveSharedTerminal => '共有ターミナルから退出';

  @override
  String get loadRelayPolicies => 'Relay ポリシーを読み込む';

  @override
  String get loadVaults => '保管庫を読み込む';

  @override
  String get loadAccountInvitations => 'アカウントの招待を読み込む';

  @override
  String get loadAccountsToAddMembers => 'アカウントを読み込んでメンバーを追加';

  @override
  String get loadAdminAccounts => '管理者用のアカウントを読み込む';

  @override
  String get loadAdminAudit => '管理者の監査を読み込む';

  @override
  String get loadBackupSchedule => 'バックアップのスケジュールを読み込む';

  @override
  String get loadBackupStatus => 'バックアップの状態を読み込む';

  @override
  String get loadInstanceJobs => 'インスタンスのジョブを読み込む';

  @override
  String get loadOverview => '概要を読み込む';

  @override
  String get loadPushHealth => 'プッシュの状態を読み込む';

  @override
  String get loadRelayPolicy => 'リレーのポリシーを読み込む';

  @override
  String get loadReplicationStatus => 'レプリケーションの状態を読み込む';

  @override
  String get loadRestoreSources => '復元元を読み込む';

  @override
  String get loadServerManagedGroups => 'サーバー管理のグループを読み込む';

  @override
  String get loadStatus => '状態を読み込む';

  @override
  String get loadingSshRelayPolicy => 'SSH リレーのポリシーを読み込んでいます…';

  @override
  String get loadingAccountAndInstancePolicyRevisions =>
      'アカウントとインスタンスのポリシーのリビジョンを読み込んでいます…';

  @override
  String get loadingAccountInvitations => 'アカウントの招待を読み込んでいます…';

  @override
  String get loadingAccountSessions => 'アカウントのセッションを読み込んでいます…';

  @override
  String get loadingBackupSchedule => 'バックアップのスケジュールを読み込んでいます…';

  @override
  String get loadingEncryptedArchiveSources => '暗号化アーカイブのソースを読み込んでいます…';

  @override
  String get loadingGroupMembershipAndRelayPolicy =>
      'グループのメンバーシップと Relay ポリシーを読み込んでいます…';

  @override
  String get loadingServerManagedGroups => 'サーバー管理のグループを読み込んでいます…';

  @override
  String get local => 'ローカル';

  @override
  String get localArchive => 'ローカルのアーカイブ';

  @override
  String get localDevice => 'ローカルデバイス';

  @override
  String get localEditsAreEncryptedAndCommitted =>
      'ローカルの編集は、ネットワークリクエストの前に暗号化されて永続的な送信トレイに確定されます。再試行では同じ操作 ID と暗号文が再利用されます。サーバーが認証情報や保管庫の鍵を受け取ることはありません。';

  @override
  String get localEncryptedArchiveUnavailable => 'ローカルの暗号化アーカイブを利用できません';

  @override
  String localRevisionItem(Object item) {
    return 'ローカルのリビジョン  $item';
  }

  @override
  String localBindDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return 'ローカル · $bind → $destinationAddress:$destinationPort';
  }

  @override
  String get localOnlyProfiles => 'ローカル専用プロファイル';

  @override
  String get lockWorkspace => 'ワークスペースをロック';

  @override
  String get loopbackOnly => 'ループバックのみ';

  @override
  String get maintenance => 'メンテナンス';

  @override
  String get maintenanceRunsTheConfiguredRetentionAnd =>
      'メンテナンスでは、設定された保持期間の処理と期限切れオブジェクトのクリーンアップを実行します。利用可能なインスタンス操作はサーバーが報告します。';

  @override
  String get makeEditor => '編集者にする';

  @override
  String get makeViewer => '閲覧者にする';

  @override
  String makeUsernameTheSoleOwnerYour(String username) {
    return '$username を唯一のオーナーにします。あなたのアカウントはアクティブな編集者のままです。この操作では新しいメンバーシップのバージョンに署名し、1 回のアトミックな更新ですべてのアクティブなメンバーデバイスの保管庫鍵を更新します。保留中の招待トークンは無効になり、再発行が必要です。新しいオーナーはメンバーの管理と保管庫の削除ができるようになります。';
  }

  @override
  String get manageVaultMembers => '保管庫のメンバーを管理';

  @override
  String get masterPasswordIsUsedOnlyFor => 'マスターパスワードはクライアント側の鍵導出にのみ使用されます。';

  @override
  String get maxSshRelayConnectionsPerUser => 'ユーザーあたりの最大 SSH リレー接続数';

  @override
  String get maxRelayConnectionsPerUser => 'ユーザーあたりの最大リレー接続数';

  @override
  String memberEffectiveRelayAccessValuevalueCidrs(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'メンバーの実効 Relay アクセス：$valueValue · CIDR：$summarize · ポート：$summarize2';
  }

  @override
  String get members => 'メンバー';

  @override
  String membersCurrentvaultname(String currentVaultName) {
    return 'メンバー · $currentVaultName';
  }

  @override
  String get mergePasswordFields => 'パスワードフィールドを統合';

  @override
  String get migrationVersion => '移行バージョン';

  @override
  String get missingHost => 'ホストなし';

  @override
  String get moveEncryptedLocalHostsCredentialsGroups =>
      '暗号化されたローカルのホスト、認証情報、グループ、スニペット、対応するワークスペースの設定を、新しい空の同期保管庫に移動します。ローカルプロファイルはそのまま残り、ステージしたすべてのレコードがサーバーで確認されるまで、移行中はローカルの編集が一時停止されます。';

  @override
  String moveOrUnassignHostcountHostS(
    int hostCount,
    int childCount,
    String name,
  ) {
    return '「$name」を削除する前に、$hostCount 台のホストと $childCount 個のサブグループを移動するか割り当てを解除してください。';
  }

  @override
  String get name2 => '名前';

  @override
  String get needsMoreVaultKeys => '保管庫の鍵がさらに必要です';

  @override
  String get needsOperatorAttention => '運用者の対応が必要';

  @override
  String get networkUnavailable => 'ネットワークを利用できません';

  @override
  String get newSshCredential => '新しい SSH 認証情報';

  @override
  String get newArchivePassword => '新しいアーカイブパスワード';

  @override
  String get newCommandSnippet => '新しいコマンドスニペット';

  @override
  String get newDevice => '新しいデバイス';

  @override
  String get newFirstChild => '新しい最初の子要素（%）';

  @override
  String get newFolder2 => '新しいフォルダー';

  @override
  String get newGroup2 => '新しいグループ';

  @override
  String get newHostGroup => '新しいホストグループ';

  @override
  String get newMasterPassword => '新しいマスターパスワード';

  @override
  String get newServerGroupName => '新しいサーバーグループの名前';

  @override
  String get newSnippet => '新しいスニペット';

  @override
  String get newSplitSideBySide => '新しい分割：左右';

  @override
  String get newSplitStacked => '新しい分割：上下';

  @override
  String get newTab => '新しいタブ';

  @override
  String get next => '次へ';

  @override
  String get nextAccounts => '次のアカウント';

  @override
  String get nextInvitations => '次の招待';

  @override
  String get nextRun => '次回の実行';

  @override
  String get nextSessions => '次のセッション';

  @override
  String get noCliOrServerTriggeredBackup => 'CLI またはサーバーによるバックアップの試行記録はありません。';

  @override
  String get noVaultIsCurrentlyAvailableTo =>
      'このデバイスで現在利用できる保管庫はありません。招待を承諾してアクセスを復元するか、独立した暗号化保管庫を作成してください。';

  @override
  String get noVaultsFound => '保管庫が見つかりません。';

  @override
  String get noVaultsOnThisPage => 'このページに保管庫はありません。';

  @override
  String get noAccessibleVaults => 'アクセスできる保管庫はありません';

  @override
  String get noAccountInvitationsFound => 'アカウントの招待が見つかりません。';

  @override
  String get noAccountsFound => 'アカウントが見つかりません。';

  @override
  String get noAccountsOnThisPage => 'このページにアカウントはありません。';

  @override
  String get noActiveSshSession => 'アクティブな SSH セッションはありません';

  @override
  String get noActiveVaultDeviceReportsAre => '利用できるアクティブな保管庫デバイスのレポートはありません。';

  @override
  String get noActiveCredential => '有効な認証情報はありません';

  @override
  String get noCheckpoint => 'チェックポイントなし';

  @override
  String get noCommandEventsReceivedYetPaste =>
      'コマンドのイベントはまだ受信していません。コピーした設定コマンドを対話型の Bash シェルに貼り付けて Enter を押してください。';

  @override
  String get noCredentialsSaved => '保存された認証情報はありません';

  @override
  String get noDefaultCredential2 => '既定の認証情報なし';

  @override
  String get noDeletedRecordsInThisVault => 'この保管庫に削除済みのレコードはありません。';

  @override
  String get noDeviceListLoaded => 'デバイス一覧が読み込まれていません';

  @override
  String get noDevicesOnline => 'オンラインのデバイスはありません';

  @override
  String get noForwardingProfilesSavedForThis => 'このホストには転送プロファイルが保存されていません。';

  @override
  String get noHostGroupsYet => 'ホストグループはまだありません';

  @override
  String get noHostKeysHaveBeenApproved => 'この保管庫で承認されたホスト鍵はありません。';

  @override
  String get noHostsSavedYet => '保存されたホストはまだありません';

  @override
  String get noInstanceAdminAuditEvents => 'インスタンス管理者の監査イベントはありません。';

  @override
  String get noInstanceJobs => 'インスタンスのジョブはありません。';

  @override
  String get noInvitationsOnThisPage => 'このページに招待はありません。';

  @override
  String get noJobs => 'ジョブはありません';

  @override
  String get noMatchingHosts2 => '一致するホストはありません';

  @override
  String get noMatchingSingleLineCommands => '一致する 1 行のコマンドはありません。';

  @override
  String get noMembersWereReturned => 'メンバーは返されませんでした。';

  @override
  String get noNewerBundleIsAvailableAt =>
      'このアドレスにはまだ新しいバンドルがありません。セルフホストの Web アセットを更新してから、もう一度確認してください。';

  @override
  String get noOpenConflicts => '未解決の競合はありません';

  @override
  String get noOtherActiveVaultDevicesCan =>
      'このターミナルの共有を受け取れる他のアクティブな保管庫デバイスはありません。';

  @override
  String get noPushProviderSnapshotIsAvailable => 'プッシュプロバイダーのスナップショットはありません。';

  @override
  String get noRemoteCopyAttemptRecordedYet => 'リモートコピーの試行記録はまだありません。';

  @override
  String get noResult => '結果なし';

  @override
  String get noSavedWorkspaces => '保存済みのワークスペースはありません';

  @override
  String get noScheduledBackupRunsRecorded => 'スケジュールバックアップの実行記録はありません';

  @override
  String get noServerManagedGroupsYet => 'サーバー管理のグループはまだありません。';

  @override
  String get noSessionsFound => 'セッションが見つかりません。';

  @override
  String get noSessionsOnThisPage => 'このページにセッションはありません。';

  @override
  String get noSnippetsYet2 => 'スニペットはまだありません';

  @override
  String get noSupportedEncryptedArchivesAreAvailable =>
      'このページに対応する暗号化アーカイブはありません。';

  @override
  String get noVerifiedCandidateIsAvailableRetry =>
      '検証済みの候補はありません。保管庫の同期を再試行してください。不正な形式の修復状態はロックされたままです。';

  @override
  String get noVerifiedCandidateIsAvailableRetry2 =>
      '検証済みの候補はありません。保管庫の同期を再試行してください。不正な形式の修復状態はロックされたままです。';

  @override
  String get noVerifiedCandidateIsAvailableRetry3 =>
      '検証済みの候補はありません。保管庫の同期を再試行してください。不正な形式の修復状態は、手動での復旧のためにロックされたままです。';

  @override
  String get none => 'なし';

  @override
  String get notConfigured => '未設定';

  @override
  String get notScheduledYet => '未予定';

  @override
  String get notStarted => '未開始';

  @override
  String get owner => 'オーナー';

  @override
  String observerState(String state) {
    return 'オブザーバー $state';
  }

  @override
  String get occurredAt => '発生日時';

  @override
  String get offByDefaultEnablingUploadsUp =>
      '既定ではオフです。有効にすると、この保管庫内のホストについて既存のローカルコマンドを最大 500 件と、以降のコマンドをアップロードします。';

  @override
  String get offSiteEncryptedBackupCopies => 'オフサイトの暗号化バックアップコピー';

  @override
  String get offline => 'オフライン';

  @override
  String get offlineDeviceCopiesAndExportsAre =>
      'オフラインのデバイスのコピーやエクスポートしたファイルは削除されません。';

  @override
  String get offlineDeviceCopiesAndRetainedBackups =>
      'オフラインのデバイスのコピーや保持されたバックアップがリモートで消去されることはありません。';

  @override
  String get offlineFirstCiphertextOnly => 'オフラインファースト、暗号文のみ';

  @override
  String get oneCanonicalNetworkCidrPerLine => '1 行に 1 つの正規化されたネットワーク CIDR。';

  @override
  String get oneTimePrometheusScrapeCredential => 'ワンタイムの Prometheus スクレイプ認証情報';

  @override
  String get oneTimeInvitationToken => 'ワンタイムの招待トークン';

  @override
  String get oneTimeToken => 'ワンタイムトークン';

  @override
  String onlineDeviceStatusCouldNotBe(Object vaultPresenceError) {
    return 'オンラインのデバイスの状態を読み込めません：$vaultPresenceError';
  }

  @override
  String get onlineStatusUnavailable => 'オンライン状態を利用できません';

  @override
  String get onlyASignedEnrollmentFromAn =>
      'このアカウントに参加できるのは、アクティブなデバイスからの署名付き登録のみです。デバイスは、アクセスできる保管庫があればその封印済みの鍵を受け取ります。';

  @override
  String get onlyAlreadyConnectedSshSessionsAre =>
      '使用できるのは接続済みの SSH セッションのみです。2 台以上のホストを選択してください。コマンドを送信する前に各ホストを確認します。';

  @override
  String get openSettingsDataAndMigrationTo =>
      '「設定」→「データと移行」を開いて暗号化アーカイブをエクスポート';

  @override
  String get openTerminal => 'ターミナルを開く';

  @override
  String get openTerminalChooseAHostAnd =>
      'ターミナルを開いてホストを選び、接続してください。SFTP は同じ検証済みの SSH トランスポートを使用します。';

  @override
  String get openVault => '保管庫を開く';

  @override
  String get openAVaultToReadOr => '同期する設定を読み込みまたは保存するには、保管庫を開いてください。';

  @override
  String get openAVaultToReadOr2 => 'これらの同期する設定を読み込みまたは保存するには、保管庫を開いてください。';

  @override
  String get openAVaultToReadOr3 => 'この同期する設定を読み込みまたは保存するには、保管庫を開いてください。';

  @override
  String get openANewTerminalTab => '新しいターミナルタブを開く';

  @override
  String get openActiveTerminals => 'アクティブなターミナルを開く';

  @override
  String get openConflicts => '未解決の競合';

  @override
  String get openTerminal2 => 'ターミナルを開く';

  @override
  String get optionalBackgroundSyncHintsForThis =>
      'このデバイスのオプションのバックグラウンド同期のヒントです。iOS では利用可能な場合 APNs が優先されます。';

  @override
  String get organizeYourHostsIntoGroups => 'ホストをグループに整理します。';

  @override
  String get otherSyncIssue => 'その他の同期の問題';

  @override
  String get outboxItems => '送信トレイの項目';

  @override
  String get outputIsEncryptedForThisDevice =>
      '出力はこのデバイス向けに暗号化されます。ホストがこのデバイスに明示的に操作権を付与するまで、入力とサイズ変更は無効のままです。それ以前のスクロールバックは利用できません。';

  @override
  String get ownerAccountId => 'オーナーのアカウント ID';

  @override
  String get ownerUserId => 'オーナーのユーザー ID';

  @override
  String get pemPrivateKey => 'PEM 秘密鍵';

  @override
  String get private => 'プライベート';

  @override
  String pageValuevalue(int valueValue) {
    return '$valueValue ページ';
  }

  @override
  String paneValuevalue(int valueValue) {
    return 'ペイン $valueValue';
  }

  @override
  String paneValuevalueValuevalue2(int valueValue, String valueValue2) {
    return 'ペイン $valueValue · $valueValue2';
  }

  @override
  String paneValuevalueValuevalue2Valuevalue3(
    int valueValue,
    String valueValue2,
    String valueValue3,
  ) {
    return 'ペイン $valueValue · $valueValue2 · $valueValue3';
  }

  @override
  String paneValuevalueValuevalue22(int valueValue, int valueValue2) {
    return 'ペイン $valueValue · $valueValue2%';
  }

  @override
  String get parameterDefinitionsJsonArray2 => 'パラメーター定義（JSON 配列）';

  @override
  String get parameterName => 'パラメーター名';

  @override
  String get parentGroup2 => '親グループ';

  @override
  String get password => 'パスワード';

  @override
  String get passwordCredential => 'パスワード認証情報';

  @override
  String get passwordFieldMergeIsNoLonger =>
      'パスワードフィールドの統合は利用できなくなりました。検証済みのブランチの操作を使ってください。';

  @override
  String get passwordSecret => 'パスワードのシークレット';

  @override
  String get passwordsPrivateKeysAndPassphrasesAre =>
      'パスワード、秘密鍵、パスフレーズは同期前にこのデバイスで暗号化されます。平文のシークレットはロック解除されたセッションでのみ使用されます。';

  @override
  String get pasteThePublicRequestFromThe =>
      '新しいブラウザの公開リクエストを貼り付けてください。秘密鍵が含まれることはありません。';

  @override
  String get pasteTheRecipientsSignedPublicDevice =>
      '受信者の署名付き公開デバイスカードを貼り付けてください。アカウントがこのインスタンスにすでに存在し、カードが招待を承諾するアクティブなデバイスと一致している必要があります。';

  @override
  String get pending => '保留中';

  @override
  String get permanentPurgeAfter => '完全削除の予定';

  @override
  String get permanentPurgeBecomesAvailableAfterThis =>
      'この期限を過ぎると完全削除が可能になります。';

  @override
  String get permanentPurgeIsUnavailableBecauseThis =>
      'このサーバーが復元期限を提供していないため、完全削除はできません。';

  @override
  String permanentlyDeleteNameItsMembershipAnd(String name) {
    return '「$name」とそのメンバーシップ、Relay ポリシーを完全に削除しますか？メンバーの未使用の Relay チケットは失効し、このグループで許可されたアクティブなセッションはポリシーの再チェック後に閉じられます。';
  }

  @override
  String get permanentlyPurge => '完全に削除';

  @override
  String get permanentlyPurgeThisRecord => 'このレコードを完全に削除しますか？';

  @override
  String get policyRevision => 'ポリシーのリビジョン';

  @override
  String policyRevisionRevisionInstanceRevisionInstancepolicyrevision(
    int revision,
    int instancePolicyRevision,
    String formatTime,
  ) {
    return 'ポリシーのリビジョン $revision · インスタンスのリビジョン $instancePolicyRevision · 更新 $formatTime';
  }

  @override
  String get port => 'ポート';

  @override
  String get portableEncryptedVaultArchive => 'ポータブル暗号化保管庫アーカイブ';

  @override
  String get preference => '設定';

  @override
  String get preflightFailedBeforeAnyTargetReceived =>
      'どの対象にもコマンドが送信される前に事前チェックが失敗しました。';

  @override
  String get prepareIsolatedCopy => '隔離コピーを準備';

  @override
  String get prepareIsolatedRestoreCopy => '隔離された復元用コピーを準備';

  @override
  String get prepareIsolatedRestoreCopy2 => '隔離された復元用コピーを準備しますか？';

  @override
  String get prepared => '準備済み';

  @override
  String get preparingIsolatedCopy => '隔離コピーを準備中';

  @override
  String get preparingLocalEncryptedArchive => 'ローカルの暗号化アーカイブを準備中';

  @override
  String get previewDisconnectedLayout => '未接続のレイアウトをプレビュー';

  @override
  String get previewMemberEffectiveRelayAccess => 'メンバーの実効 Relay アクセスをプレビュー';

  @override
  String get previewOnly => 'プレビューのみ';

  @override
  String get previewStructuredCommandsOrReviewAnd =>
      '構造化コマンドをプレビューするか、アクティブなターミナルに送信する前にスクリプトを確認して確定します。';

  @override
  String get previous => '前へ';

  @override
  String get previousAccounts => '前のアカウント';

  @override
  String get previousInvitations => '前の招待';

  @override
  String get previousSessions => '前のセッション';

  @override
  String get privateKey => '秘密鍵';

  @override
  String get privateSigningAndEncryptionKeysStay =>
      '署名用と暗号化用の秘密鍵は、このデバイスのセキュアストレージに保持されます。';

  @override
  String get profileName => 'プロファイル名';

  @override
  String get profilesAreEncryptedAndSyncWith =>
      'プロファイルは暗号化されて保管庫と同期されます。このブラウザでは、ポート転送の実行に必要なローカルの TCP リスナーを開けません。';

  @override
  String get profilesAreEncryptedInThisHost =>
      'プロファイルはこのホストに暗号化して保存され、保管庫と同期されます。実行中のリスナーはこのデバイス上にあり、この SSH タブが切断されると停止します。';

  @override
  String get profilesAreEncryptedInsideThisHost =>
      'プロファイルはこのホストのレコード内で暗号化され、保管庫と同期されます。実行状態とソケットは同期されません。';

  @override
  String get program2 => 'プログラム';

  @override
  String get prometheusRequestsUsingThisCredentialWill =>
      'この認証情報を使った Prometheus のリクエストはすぐに機能しなくなります。後で代わりの認証情報を作成できます。';

  @override
  String get prometheusScrapeCredential => 'Prometheus のスクレイプ認証情報';

  @override
  String get protocol => 'プロトコル';

  @override
  String get protocolVersion => 'プロトコルのバージョン';

  @override
  String get providerAdapter => 'プロバイダーのアダプター';

  @override
  String get publicDeviceCard => '公開デバイスカード';

  @override
  String get publicDeviceCardJson => '公開デバイスカード JSON';

  @override
  String get pushIsABestEffortWake =>
      'プッシュはベストエフォートの起動ヒントであり、配信や同期を保証するものではありません。';

  @override
  String get pushProviderHealth => 'プッシュプロバイダーの状態';

  @override
  String get queuedNotTrusted => 'キュー済み — 未信頼';

  @override
  String get queueApprovalAndStop => '承認をキューに追加して停止';

  @override
  String get queued => 'キュー済み';

  @override
  String get quota => 'クォータ';

  @override
  String get quotaInBytes => 'クォータ（バイト）';

  @override
  String get readOnly2 => '読み取り専用';

  @override
  String get reissueRequired => '再発行が必要';

  @override
  String get revoked2 => '失効済み';

  @override
  String get reAuthenticateToCancel => '再認証して取り消す';

  @override
  String get reEnterAccountMasterPassword => 'アカウントのマスターパスワードを再入力';

  @override
  String get readOnlyGracePeriodAllMembers =>
      '読み取り専用の猶予期間 · すべてのメンバーは引き続き読み取れますが、書き込みとメンバーの変更は一時停止しています。「設定」で別のパスワードで保護された暗号化アーカイブを作成できます。';

  @override
  String get readOnlyInstanceIdentityUsageAnd =>
      '読み取り専用のインスタンス ID、使用状況、リレーポリシー。';

  @override
  String get readOnlyProviderConfigurationAggregateQueue =>
      '読み取り専用のプロバイダー設定、キューの集計数、アダプターの結果です。';

  @override
  String get ready => '準備完了';

  @override
  String get rebuildSnapshot => 'スナップショットを再構築';

  @override
  String get rebuildingSnapshot => 'スナップショットを再構築中';

  @override
  String get rebuildingSnapshot2 => 'スナップショットを再構築しています…';

  @override
  String get reconnectObserver => 'オブザーバーを再接続';

  @override
  String get record => 'レコード';

  @override
  String recordIdIdRevisionRevisionlabel(String id, String revisionLabel) {
    return 'レコード ID：$id\nリビジョン：$revisionLabel';
  }

  @override
  String recordIdIdRevisionValuevalue(String id, String valueValue) {
    return 'レコード ID：$id\nリビジョン：$valueValue';
  }

  @override
  String get recordConsent => '同意を記録';

  @override
  String get recordPermanentlyRemovedFromActiveServer =>
      'レコードをサーバーのアクティブな状態から完全に削除しました。オフラインのデバイスのコピーや保持されたバックアップは消去されません。';

  @override
  String get recordsAndConflictsRemainEncryptedExisting =>
      'レコードと競合は暗号化されたままです。既存のローカルブランチと他の保管庫は保持されます。スペース間の移行や ID の再マッピングには対応していません。';

  @override
  String get recordsAreDecryptedOnlyOnThis =>
      'レコードはこのデバイス上でのみ復号されます。同じ削除マーカーがまだ最新であれば、復元すると新しい署名付きリビジョンが作成されます。';

  @override
  String get recoveryDetails => '復旧の詳細';

  @override
  String get recoveryInProgress => '復旧中';

  @override
  String get recoveryIsEnabledButThisCode =>
      '復旧は有効ですが、このコードは保存済みとして確認されていません。今すぐ更新して新しいコードを表示してください。';

  @override
  String recoveryIsStatusCoveredcontextsOfRequiredcontexts(
    String status,
    int coveredContexts,
    int requiredContexts,
  ) {
    return '復旧は $status です。現在のコンテキスト $requiredContexts 個のうち $coveredContexts 個がカバーされています。このデバイスは不足している鍵をバックグラウンドで再試行します。';
  }

  @override
  String get recoveryRequired => '復旧が必要';

  @override
  String get recoveryRequiredSyncing => '復旧が必要 · 同期中…';

  @override
  String get recycleBin => 'ごみ箱';

  @override
  String recycleBinRecordDisplaynameIdSubstring(
    String displayName,
    String substring,
    String automaticPurgeConsentText,
    String restoreDeadlineSemantics,
  ) {
    return 'ごみ箱のレコード：$displayName、ID $substring、$automaticPurgeConsentText、$restoreDeadlineSemantics';
  }

  @override
  String redactionProofItem(Object item) {
    return '秘匿化の証明  $item';
  }

  @override
  String get redactionReadiness => '秘匿化の準備状況';

  @override
  String get refresh2 => '更新';

  @override
  String get refreshVaultList => '保管庫の一覧を更新';

  @override
  String get refreshVaultStates => '保管庫の状態を更新';

  @override
  String get refreshAccountInvitations => 'アカウントの招待を更新';

  @override
  String get refreshAccountSessions => 'アカウントのセッションを更新';

  @override
  String get refreshAdminAccounts => '管理者用のアカウントを更新';

  @override
  String get refreshAdminAudit => '管理者の監査を更新';

  @override
  String get refreshBackupStatus => 'バックアップの状態を更新';

  @override
  String get refreshDevices => 'デバイスを更新';

  @override
  String get refreshExpires => '更新の期限';

  @override
  String get refreshInstanceJobs => 'インスタンスのジョブを更新';

  @override
  String get refreshKeyCoverage => '鍵のカバー範囲を更新';

  @override
  String get refreshMembersAndOnlineDevices => 'メンバーとオンラインのデバイスを更新';

  @override
  String get refreshOverview => '概要を更新';

  @override
  String get refreshPushHealth => 'プッシュの状態を更新';

  @override
  String get refreshReadiness => '準備状況を更新';

  @override
  String get refreshRelayPolicy => 'リレーのポリシーを更新';

  @override
  String get refreshReplicationStatus => 'レプリケーションの状態を更新';

  @override
  String get refreshRestoreSources => '復元元を更新';

  @override
  String get refreshRestoreStatus => '復元の状態を更新';

  @override
  String get refreshSchedule => 'スケジュールを更新';

  @override
  String get refreshServerManagedGroups => 'サーバー管理のグループを更新';

  @override
  String get refreshStatus => '状態を更新';

  @override
  String get refreshToLoadApprovedDevicesFrom => '更新するとサーバーから承認済みのデバイスを読み込みます。';

  @override
  String get registeredEndpoints => '登録済みのエンドポイント';

  @override
  String get reject2 => '拒否';

  @override
  String get relayCidrs => 'リレーの CIDR';

  @override
  String get relayAvailable => 'リレーを利用可能';

  @override
  String get relayPolicy => 'Relay ポリシー';

  @override
  String get relayPorts => 'リレーのポート';

  @override
  String get relayUnavailable => 'リレーは利用できません';

  @override
  String get reloadAccountAndInstanceRelayPolicies =>
      'アカウントとインスタンスの Relay ポリシーを再読み込み';

  @override
  String get reloadFirstPage => '最初のページを再読み込み';

  @override
  String get reloadGroupAndInstancePoliciesKeep =>
      'グループとインスタンスのポリシーを再読み込みし、下書きを保持';

  @override
  String get reloadLatestGroupKeepDrafts => '最新のグループを再読み込みし、下書きを保持';

  @override
  String get reloadLatestPolicy => '最新のポリシーを再読み込み';

  @override
  String get reloadLatestPolicyKeepDraft => '最新のポリシーを再読み込みし、下書きを保持';

  @override
  String get remote => 'リモート';

  @override
  String get remoteSshListenerAddress => 'リモート SSH の待ち受けアドレス';

  @override
  String get remoteArchiveIntegrityMismatch => 'リモートアーカイブの整合性が一致しません';

  @override
  String get remoteCompletionUnknownNotRetried => 'リモートでの完了は不明 · 再試行なし';

  @override
  String get remoteCopyFailed => 'リモートコピーに失敗しました';

  @override
  String get remoteCopyVerified => 'リモートコピーを検証済み';

  @override
  String get remoteCredentialsUnavailable => 'リモートの認証情報を利用できません';

  @override
  String remoteFilesEndpoint(Object endpoint) {
    return 'リモートファイル · $endpoint';
  }

  @override
  String get remoteHeadIsAbsent => 'リモートの先頭がありません';

  @override
  String get remotePath2 => 'リモートパス';

  @override
  String remotePathSftppath(String sftpPath) {
    return 'リモートパス：$sftpPath';
  }

  @override
  String get remoteReplica => 'リモートのレプリカ';

  @override
  String get remoteReplication => 'リモートレプリケーション';

  @override
  String remoteRevisionItem(Object item) {
    return 'リモートのリビジョン $item';
  }

  @override
  String get remoteStorageUnavailable => 'リモートストレージを利用できません';

  @override
  String remoteSshBindDeviceDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return 'リモート · SSH $bind → デバイス $destinationAddress:$destinationPort';
  }

  @override
  String removePaneValuevalue(int valueValue) {
    return 'ペイン $valueValue を削除';
  }

  @override
  String get removeFavorite => 'お気に入りから削除';

  @override
  String get removeReference => '参照を削除';

  @override
  String get removeTmuxSessionReference2 => 'tmux セッションの参照を削除';

  @override
  String get removeTmuxSessionReference => 'tmux セッションの参照を削除しますか？';

  @override
  String removeUsernameFromGroupDraft(String username) {
    return 'グループの下書きから $username を削除';
  }

  @override
  String get rename => '名前を変更';

  @override
  String get renameWorkspace => 'ワークスペースの名前を変更';

  @override
  String get repairAHost => 'ホストを修復';

  @override
  String get repairAGroup => 'グループを修復';

  @override
  String get repairIsNotConfirmedYetSync =>
      '修復はまだ確認されていません。アクティブな保管庫を同期し、同じレコード ID で再試行してください。';

  @override
  String get replaceHost => 'ホストを置き換え';

  @override
  String get replaceMissingHost => '見つからないホストを置き換え';

  @override
  String get requestedAt => 'リクエスト日時';

  @override
  String get requiredTextValue => '必須のテキスト値';

  @override
  String get reservedUploads => '予約済みのアップロード';

  @override
  String get resetToInherit => '継承にリセット';

  @override
  String get resolutionSavedOnThisDeviceWaiting =>
      '解決をこのデバイスに保存しました。同期の確認を待っています。';

  @override
  String get resolveOrDiscardThisRecordsOutstanding =>
      'このレコードを完全に削除する前に、未解決の競合を解決するか破棄してください。';

  @override
  String get resourceIdHmacSha256 => 'リソース ID（HMAC-SHA-256）';

  @override
  String get resourceType => 'リソースの種類';

  @override
  String responseValuevalue(int valueValue) {
    return '応答 $valueValue';
  }

  @override
  String get responsesAreSentOnlyForThis => '応答はこの SSH 認証にのみ送信され、保存されません。';

  @override
  String get restore => '元に戻す';

  @override
  String get restoreDeadlinePassedAccordingToThis =>
      'このデバイスの時計では復元期限を過ぎています。最終的な判断はサーバーが行います。';

  @override
  String restoreDeadlineFormat3(String format) {
    return '復元期限 $format';
  }

  @override
  String restoreDeadlineFormatTheServerChecks(String format) {
    return '復元期限：$format。確定時にサーバーがこの期限を再度確認します。';
  }

  @override
  String get restoreDefaults => '既定値に戻す';

  @override
  String get restoreIsRestrictedToTheSame =>
      '復元は同じサーバースペースと保管庫に限られます。サーバーで完全に削除されたデータは含まれません。ダウンロードしたアーカイブとパスワードは、このデバイスとは別に保管してください。';

  @override
  String get restorePreparesAnIsolatedCopyWhile =>
      '復元では、サービスをオンラインのまま隔離コピーを準備します。その後のオフラインでの切り替えは運用者が行います。';

  @override
  String get restoreStaging => '復元のステージ';

  @override
  String restoreStagingAdminrestorejobstatuslabel(
    String adminRestoreJobStatusLabel,
  ) {
    return '復元のステージ · $adminRestoreJobStatusLabel';
  }

  @override
  String get restoreThisRecord => 'このレコードを復元しますか？';

  @override
  String restoreUsernameInGroupDraft(String username) {
    return 'グループの下書きで $username を元に戻す';
  }

  @override
  String get result => '結果';

  @override
  String get resumeSession => 'セッションを再開';

  @override
  String get resumeTmuxSession2 => 'tmux セッションを再開';

  @override
  String get resumeTmuxSession => 'tmux セッションを再開しますか？';

  @override
  String get retry2 => '再試行';

  @override
  String get retryAccountInvitations => 'アカウントの招待を再読み込み';

  @override
  String get retryAccountList => 'アカウント一覧を再読み込み';

  @override
  String get retryAndVerifyRepair => '再試行して修復を確認';

  @override
  String get retryBackupRequestSafely => 'バックアップのリクエストを安全に再試行';

  @override
  String get retryDiscard => '破棄を再試行';

  @override
  String get retryDiscardSafely => '破棄を安全に再試行';

  @override
  String get retryGroupDetails => 'グループの詳細を再読み込み';

  @override
  String get retryGroupList => 'グループ一覧を再読み込み';

  @override
  String get retryPasswordChange => 'パスワードの変更を再試行';

  @override
  String get retryPending => '再試行待ち';

  @override
  String get retryQueued => '再試行をキューに追加済み';

  @override
  String get retryRequestSafely => 'リクエストを安全に再試行';

  @override
  String get retryScheduled => '再試行を予定';

  @override
  String get retrySessionList => 'セッション一覧を再読み込み';

  @override
  String get retryWaiting => '再試行待ち';

  @override
  String get retryableFailure7UtcDays => '再試行可能な失敗（UTC 7 日間）';

  @override
  String get revealPasswordSecret => 'パスワードのシークレットを表示';

  @override
  String get reviewHostConnectionSettings => 'ホストの接続設定を確認';

  @override
  String get reviewAndRun => '確認して実行';

  @override
  String get reviewBatchCommand => '一括コマンドを確認';

  @override
  String get reviewCommandExecution => 'コマンドの実行を確認';

  @override
  String get reviewCurrentVersion => '現在のバージョンを確認';

  @override
  String get reviewDeviceEnrollment => 'デバイスの登録を確認';

  @override
  String get reviewEachSynchronizedBindingAndRecord =>
      '同期された各バインドとレコード ID を確認してください。重複するレコードは暗号化された削除マーカーで削除されます。';

  @override
  String get reviewKeys => '鍵を確認';

  @override
  String get reviewLocalProfileMigration => 'ローカルプロファイルの移行を確認';

  @override
  String reviewOnCountConnectedHosts(int count) {
    return '接続済みの $count 台のホストで確認';
  }

  @override
  String get reviewThePaletteAndRecordId =>
      '配色とレコード ID を確認してください。選択したレコードは有効なまま残り、重複は暗号化された削除マーカーで削除されます。';

  @override
  String get reviewTheSizeAndRecordId =>
      'サイズとレコード ID を確認してください。選択したレコード ID は有効なまま残り、他のレコードは暗号化された削除マーカーで削除されます。';

  @override
  String get reviewTrustedDevices => '信頼済みデバイスを確認';

  @override
  String get reviewUpdate => '更新を確認';

  @override
  String reviewCountHosts(int count) {
    return '$count 台のホストを確認';
  }

  @override
  String get revokePrometheusScrapeCredential =>
      'Prometheus のスクレイプ認証情報を失効させますか？';

  @override
  String revokeSshHostKeyTrustFor(String endpoint, String fingerprint) {
    return '$endpoint（$fingerprint）の SSH ホスト鍵の信頼を取り消す';
  }

  @override
  String get revokeSshHostKeyTrust2 => 'SSH ホスト鍵の信頼を取り消しますか？';

  @override
  String get revokeAccess => 'アクセスを取り消す';

  @override
  String get revokeAccountInvitation => 'アカウントの招待を取り消しますか？';

  @override
  String get revokeAllSessions => 'すべてのセッションを失効';

  @override
  String get revokeAllSessions2 => 'すべてのセッションを失効させますか？';

  @override
  String get revokeAndRotateKey => '失効させて鍵を更新';

  @override
  String get revokeCredential => '認証情報を失効';

  @override
  String get revokeDevice => 'デバイスを失効';

  @override
  String get revokeDevice2 => 'デバイスを失効させますか？';

  @override
  String revokeEveryActiveSessionForUsername(String username) {
    return '$username のすべてのアクティブなセッションを失効させますか？これらのセッションからの次のリクエストでは再度サインインが必要になります。';
  }

  @override
  String get revokeInputControl => '入力操作を取り消す';

  @override
  String get revokeInvitation => '招待を取り消す';

  @override
  String get revokeInvitation2 => '招待を取り消しますか？';

  @override
  String get revokeMemberAccess => 'メンバーのアクセスを取り消しますか？';

  @override
  String get revokeSession => 'セッションを失効';

  @override
  String get revokeSessions => 'セッションを失効';

  @override
  String revokeTheSessionOnDevicenameFor(String deviceName, String username) {
    return '$deviceName 上の $username のセッションを失効させますか？';
  }

  @override
  String get revokeThisSession => 'このセッションを失効させますか？';

  @override
  String get revokeTrust2 => '信頼を取り消す';

  @override
  String get revoked3 => '失効済み';

  @override
  String get revokedAt => '失効日時';

  @override
  String revokedFormat(String format) {
    return '失効 $format';
  }

  @override
  String revokedFormat2(String format) {
    return '失効 · $format';
  }

  @override
  String get role => 'ロール';

  @override
  String get rotatePrometheusScrapeCredential =>
      'Prometheus のスクレイプ認証情報を更新しますか？';

  @override
  String get rotateCredential => '認証情報を更新';

  @override
  String get rotateKeyAndChangeRole => '鍵を更新してロールを変更しますか？';

  @override
  String get rotateRecoveryCode => '復旧コードを更新';

  @override
  String get rotationImmediatelyInvalidatesTheCurrentCredential =>
      '更新すると現在の認証情報はすぐに無効になります。新しい値をコピーした後、Prometheus のスクレイプ設定を更新してください。値は一度だけ表示されます。';

  @override
  String get runEncryptedBackup => '暗号化バックアップを実行';

  @override
  String get runMaintenanceNow => '今すぐメンテナンスを実行';

  @override
  String get running => '実行中';

  @override
  String get runningOnceThroughANonPty =>
      'PTY を使わない SSH exec チャネルで 1 回実行します。出力は 64 KiB までです。';

  @override
  String get scpUpload => 'SCP アップロード…';

  @override
  String get scpDownload => 'SCP ダウンロード…';

  @override
  String get scpFileManager => 'SCP ファイルマネージャー';

  @override
  String get sftpFileBrowser => 'SFTP ファイルブラウザー';

  @override
  String get sftpFileManager => 'SFTP ファイルマネージャー';

  @override
  String get socks5ConnectOnlyNoSocksUser =>
      'SOCKS5 CONNECT のみで、SOCKS のユーザー認証はありません。プロキシはこのデバイスのループバックアドレスで待ち受けます。';

  @override
  String get sshRelayConnected => 'SSH Relay に接続しました';

  @override
  String get sshTerminal => 'SSH ターミナル';

  @override
  String get sshAuthenticationChallenge => 'SSH 認証チャレンジ';

  @override
  String get sshConnected => 'SSH 接続済み';

  @override
  String get sshConnecting => 'SSH 接続中';

  @override
  String get sshConnectionFailed => 'SSH 接続に失敗しました';

  @override
  String get sshCredentials => 'SSH の認証情報';

  @override
  String get sshDisconnected => 'SSH 切断';

  @override
  String get sshExecFailedAfterDispatchThe =>
      'SSH exec は送信後に失敗しました。コマンドは開始されている可能性があり、リモートでの完了は不明です。再試行はしていません。';

  @override
  String get sshHostKeyChangesAreRejected =>
      '初回に検証して信頼した後は、SSH ホスト鍵の変更は拒否されます。';

  @override
  String sshHostKeyFingerprintFingerprint(String fingerprint) {
    return 'SSH ホスト鍵のフィンガープリント：$fingerprint';
  }

  @override
  String get sshHostKeyTrust => 'SSH ホスト鍵の信頼';

  @override
  String get sshPortForwarding => 'SSH ポートフォワーディング';

  @override
  String get sshRelay => 'SSH リレー';

  @override
  String get sshRelayPolicy => 'SSH リレーのポリシー';

  @override
  String get sshSessionIsDisconnected => 'SSH セッションは切断されています。';

  @override
  String get sshTerminalInput => 'SSH ターミナルの入力';

  @override
  String get sshUsername => 'SSH ユーザー名';

  @override
  String get sshHostTrust => 'SSH ホストの信頼';

  @override
  String sameOnBothBranchesValuevalue(String valueValue) {
    return '両方のブランチで同じ · $valueValue';
  }

  @override
  String get save => '保存';

  @override
  String get saveConflictBranchAsWorkspaceCopy => '競合ブランチをワークスペースのコピーとして保存';

  @override
  String get saveCurrentTabs => '現在のタブを保存';

  @override
  String get saveEncryptedCredential2 => '暗号化した認証情報を保存';

  @override
  String get saveEncryptedGroup => '暗号化グループを保存';

  @override
  String get saveEncryptedProfile => '暗号化プロファイルを保存';

  @override
  String get saveGroupOverride => 'グループの上書きを保存';

  @override
  String get saveLocalLayoutAsNamedCopy => 'ローカルのレイアウトに名前を付けて保存';

  @override
  String get saveMembership => 'メンバーシップを保存';

  @override
  String get saveMergedCredential => '統合した認証情報を保存';

  @override
  String get saveOverride => '上書きを保存';

  @override
  String get saveQuota => 'クォータを保存';

  @override
  String get saveRelayPolicy => 'リレーのポリシーを保存';

  @override
  String get saveReviewedTuple => '確認済みのまとまりを保存';

  @override
  String get saveSchedule => 'スケジュールを保存';

  @override
  String get saveShortcuts2 => 'ショートカットを保存';

  @override
  String get saveSnippet => 'スニペットを保存';

  @override
  String get saveSplitWorkspace => '分割ワークスペースを保存';

  @override
  String get saveSyncedPreference => '同期する設定を保存';

  @override
  String get saveTerminalColorTheme => 'ターミナルの配色テーマを保存';

  @override
  String get saveTerminalFontSize2 => 'ターミナルのフォントサイズを保存';

  @override
  String get saveThisCredentialNow => 'この認証情報を今すぐ保存';

  @override
  String get saveWorkspace => 'ワークスペースを保存';

  @override
  String savedAsItemThisPreferenceIs(Object item) {
    return '$item として保存しました。この設定はアクティブな保管庫で暗号化され、承認済みのデバイスに同期されます。';
  }

  @override
  String savedCheckpointShortkey(String shortKey) {
    return '保存済みのチェックポイント：$shortKey';
  }

  @override
  String get savedSettingsCanOnlyNarrowThe =>
      '保存した設定で可能なのは、サーバー運用者が設定した変更不可の制限を狭めることだけです。';

  @override
  String get savedWorkspaces => '保存済みのワークスペース';

  @override
  String savedFontsizePxThisEncryptedPreference(int fontSize) {
    return '$fontSize px で保存しました。この暗号化された設定は、この保管庫にアクセスできるデバイスに同期されます。';
  }

  @override
  String savedLabelThisEncryptedPreferenceWill(String label) {
    return '$label を保存しました。この暗号化された設定は、この保管庫にアクセスできるデバイスに同期されます。';
  }

  @override
  String get savingAndPreviewingDoNotConnect =>
      '保存とプレビューでは接続しません。任意のペインを選択し、分割して別のホストを追加してください。';

  @override
  String get scheduleVaultDeletion => '保管庫の削除を予約';

  @override
  String get scheduleVaultDeletion2 => '保管庫の削除を予約しますか？';

  @override
  String get scheduleAccountDeletion => 'アカウントの削除を予約';

  @override
  String get scheduleAccountDeletion2 => 'アカウントの削除を予約しますか？';

  @override
  String get scheduleDeletion => '削除を予約';

  @override
  String get scheduledEncryptedBackups => 'スケジュールされた暗号化バックアップ';

  @override
  String get scheduledFor => '予定日時';

  @override
  String get scriptBody2 => 'スクリプト本文';

  @override
  String get searchThisHostsCompletedCommandsPlain =>
      'このホストで完了したコマンド、通常の Bash スニペット、ローカルの Bash コマンド名を検索します。候補を選ぶと現在のターミナルのカーソル位置に 1 行入力されますが、Enter が押されることはありません。';

  @override
  String searchValuevalueScrollback(String valueValue) {
    return '$valueValue のスクロールバックを検索';
  }

  @override
  String get secureTerminalWorkspace => 'セキュアなターミナルワークスペース';

  @override
  String get securityPolicy => 'セキュリティポリシー';

  @override
  String get selectAnActiveVaultBeforeEnabling =>
      '同期を有効にする前にアクティブな保管庫を選択してください。';

  @override
  String get selectFirstHost => '最初のホストを選択';

  @override
  String get selectedArchive => '選択したアーカイブ';

  @override
  String get selectedServerManagedGroup => '選択したサーバー管理のグループ';

  @override
  String selectedStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '選択した状態：$valueValue · CIDR：$summarize · ポート：$summarize2';
  }

  @override
  String get sendANewInvitationFromSettings => '「設定」>「メンバーを招待」から新しい招待を送ってください。';

  @override
  String get sendResponses => '応答を送信';

  @override
  String get serverBackupConfigurationNotReady => 'サーバーのバックアップ設定の準備ができていません';

  @override
  String get serverBackupConfigurationReady => 'サーバーのバックアップ設定の準備ができています';

  @override
  String get serverGenerationUnknown => 'サーバーの世代は不明';

  @override
  String get serverSpaceId => 'サーバースペース ID';

  @override
  String serverSpaceServerspaceid(String serverSpaceId) {
    return 'サーバースペース：$serverSpaceId';
  }

  @override
  String get serverManagedAccessGroups => 'サーバー管理のアクセスグループ';

  @override
  String get serverManagedGroupActionFailed => 'サーバー管理のグループの操作に失敗しました';

  @override
  String get serverManagedGroupSaveFailed => 'サーバー管理のグループを保存できませんでした';

  @override
  String serverLocalConflictBranchesConflictcount(int conflictCount) {
    return 'サーバー／ローカルの競合ブランチ：$conflictCount';
  }

  @override
  String get sessionId => 'セッション ID';

  @override
  String get setTheIntervalBelowThenSave => '下で間隔を設定してから、変更を保存してください。';

  @override
  String setTheSharedTerminalTextSize(
    String join,
    int defaultTerminalFontSize,
  ) {
    return 'この保管庫で共有するターミナルの文字サイズを設定します。選択可能なサイズ：$join px。既定：$defaultTerminalFontSize px。';
  }

  @override
  String get setUpAccountRecovery => 'アカウントの復旧を設定';

  @override
  String get setUpRecovery => '復旧を設定';

  @override
  String get shareThisTerminal => 'このターミナルを共有';

  @override
  String get sharedTerminalOutputReadOnly => '共有されたターミナル出力（読み取り専用）';

  @override
  String get sharedTerminalHostApprovedControl => '共有ターミナル · ホストが承認した操作';

  @override
  String get sharedTerminalReadOnly => '共有ターミナル · 読み取り専用';

  @override
  String get shellLabel2 => 'シェルのラベル';

  @override
  String shellLabelShellSentToThe(String shell) {
    return 'シェルのラベル：$shell · アクティブな SSH PTY に送信';
  }

  @override
  String showingCountLocalArchivesOnThis(int count) {
    return 'このページに $count 件のローカルアーカイブを表示';
  }

  @override
  String showingFirstLastOfAdmincountAccounts(
    int first,
    int last,
    String adminCount,
  ) {
    return '$adminCount 件のアカウントのうち $first〜$last 件を表示';
  }

  @override
  String showingFirstLastOfAdmincountInvitations(
    int first,
    int last,
    String adminCount,
  ) {
    return '$adminCount 件の招待のうち $first〜$last 件を表示';
  }

  @override
  String showingFirstLastOfAdmincountSessions(
    int first,
    int last,
    String adminCount,
  ) {
    return '$adminCount 件のセッションのうち $first〜$last 件を表示';
  }

  @override
  String showingStartEndOfAdmincountVaults(
    int start,
    int end,
    String adminCount,
  ) {
    return '$adminCount 件の保管庫のうち $start〜$end 件を表示';
  }

  @override
  String showingValuevalueValuevalue2OfTotal(
    int valueValue,
    int valueValue2,
    int total,
  ) {
    return '$total 件中 $valueValue〜$valueValue2 件を表示';
  }

  @override
  String get showsTheLatestCompletedBackupAttempt =>
      'このサーバーが記録した直近の完了済みバックアップの試行を表示します。このノードでアーカイブを利用できなくなった場合、サイズは不明になることがあります。アーカイブがまだ存在することや、隔離された復元が成功することを保証するものではありません。';

  @override
  String get sideBySide => '左右に並べる';

  @override
  String get sideBySideLeftRight => '横並び（左右）';

  @override
  String get signAndCreateInvitation => '署名して招待を作成';

  @override
  String get signInNeeded => 'サインインが必要';

  @override
  String get signedVaultShareRequest => '署名済みの保管庫共有リクエスト';

  @override
  String get signedShareRequestCopied => '署名済みの共有リクエストをコピーしました。';

  @override
  String get signingKeyFingerprint => '署名鍵のフィンガープリント';

  @override
  String get signingKeyFingerprintSha256 => '署名鍵のフィンガープリント · SHA-256';

  @override
  String get snapshotExceedsClientLimit => 'スナップショットがクライアントの上限を超えています';

  @override
  String get snapshotGenerated => 'スナップショットの生成日時';

  @override
  String get snapshotLimitReached => 'スナップショットの上限に達しました';

  @override
  String get snapshotNeeded => 'スナップショットが必要';

  @override
  String get snapshotSizeLimit => 'スナップショットのサイズ上限';

  @override
  String get snapshotVerificationIsInProgressLocal =>
      'スナップショットを検証中です。ローカルの編集は一時停止しています。マニフェスト全体の検証が完了するまで、既存のキャッシュと送信トレイはそのまま保持されます。';

  @override
  String get snippet2 => 'スニペット';

  @override
  String get snippetScriptIsRequired => 'スニペットのスクリプトは必須です';

  @override
  String get snippetTitleIsRequired => 'スニペットのタイトルは必須です';

  @override
  String snippetTitle3(String title) {
    return 'スニペット：$title';
  }

  @override
  String get source => 'ソース';

  @override
  String get splitWorkspaceSavedEncryptedToThis =>
      '分割ワークスペースをこの保管庫に暗号化して保存しました。';

  @override
  String splitControlsCountDividersEachRatio(int count) {
    return '分割の操作 · 区切り線 $count 本 · 各比率で最初の子要素のサイズを決定';
  }

  @override
  String get splitSelectedPane => '選択したペインを分割';

  @override
  String splitValuevalue(int valueValue) {
    return '分割 $valueValue';
  }

  @override
  String splitValuevalueAxisFirstpercentValuevalue2(
    int valueValue,
    String axis,
    int firstPercent,
    int valueValue2,
  ) {
    return '分割 $valueValue · $axis · $firstPercent/$valueValue2';
  }

  @override
  String splitFirstpercentSecondpercent(int firstPercent, int secondPercent) {
    return '分割 · $firstPercent/$secondPercent';
  }

  @override
  String get stacked => '上下に並べる';

  @override
  String get stackedTopBottom => '上下に並べる（上／下）';

  @override
  String get stageId => 'ステージ ID';

  @override
  String get startForwarding => '転送を開始';

  @override
  String get startResumableSession => '再開可能なセッションを開始';

  @override
  String get startResumableTmuxSession => '再開可能な tmux セッションを開始しますか？';

  @override
  String get startSession => 'セッションを開始';

  @override
  String get startSharing => '共有を開始';

  @override
  String get startedAt => '開始日時';

  @override
  String get stopAuthentication => '認証を中止';

  @override
  String get stopForwarding => '転送を停止';

  @override
  String get stopLocalCapture => 'ローカルでの取得を停止';

  @override
  String get stopTerminalSharing => 'ターミナルの共有を停止';

  @override
  String get stopThisForwardBeforeEditingIts => 'プロファイルを編集する前にこの転送を停止してください。';

  @override
  String get storeYourRecoveryCode => '復旧コードを保管してください';

  @override
  String get stored => '保存済み';

  @override
  String get storedData => '保存されたデータ';

  @override
  String get structuredBashCommand2 => '構造化 Bash コマンド';

  @override
  String get submitBackupRequest => 'バックアップのリクエストを送信';

  @override
  String get submittingBackup => 'バックアップを送信しています…';

  @override
  String get succeeded2 => '成功';

  @override
  String get syncCommandHistoryToVault => 'コマンド履歴を保管庫に同期';

  @override
  String get syncCommandHistoryToThisVault => 'コマンド履歴をこの保管庫に同期しますか？';

  @override
  String get syncError => '同期エラー';

  @override
  String get syncHealth => '同期の状態';

  @override
  String get syncNow => '今すぐ同期';

  @override
  String get syncPendingChanges => '保留中の変更を同期';

  @override
  String get syncServiceError => '同期サービスのエラー';

  @override
  String get syncStatus => '同期の状態';

  @override
  String get syncing => '同期中';

  @override
  String get thisDevice => 'このデバイス';

  @override
  String tabValuevalue(int valueValue) {
    return 'タブ $valueValue';
  }

  @override
  String tabValuevalueMissingHost(int valueValue) {
    return 'タブ $valueValue · ホストなし';
  }

  @override
  String tabValuevalueName(int valueValue, String name) {
    return 'タブ $valueValue · $name';
  }

  @override
  String get tagsSeparatedByCommas => 'タグ（カンマ区切り）';

  @override
  String targetValuevalueOfCountValuevalue2(
    int valueValue,
    int count,
    String valueValue2,
  ) {
    return '対象 $valueValue/$count：$valueValue2';
  }

  @override
  String targetValuevalueHostnameEndpoint(
    int valueValue,
    String hostName,
    String endpoint,
  ) {
    return '対象 $valueValue：$hostName · $endpoint';
  }

  @override
  String targetHostnameEndpoint(String hostName, String endpoint) {
    return '接続先：$hostName · $endpoint';
  }

  @override
  String get targetsRunSequentiallyNoTargetStarts =>
      '対象は順番に実行されます。すべての確認が完了するまで、どの対象も開始しません。最初にゼロ以外または不明な結果が出た時点でバッチは停止し、再試行はしません。';

  @override
  String get terminal => 'ターミナル';

  @override
  String get terminalColorTheme => 'ターミナルの配色テーマ';

  @override
  String get terminalFontSize3 => 'ターミナルのフォントサイズ';

  @override
  String terminalFontSizeValuevaluePxRecord(
    Object valueValue,
    String id,
    String revisionLabel,
  ) {
    return 'ターミナルのフォントサイズ：$valueValue px、レコード ID：$id、リビジョン：$revisionLabel';
  }

  @override
  String get terminalHistory => 'ターミナルの履歴';

  @override
  String get terminalKeyboardShortcuts => 'ターミナルのキーボードショートカット';

  @override
  String terminalPanesCountMaxworkspacepanes(int count, int maxWorkspacePanes) {
    return 'ターミナルペイン · $count/$maxWorkspacePanes';
  }

  @override
  String terminalSharePhase(String phase) {
    return 'ターミナルの共有 $phase';
  }

  @override
  String terminalThemeThemelabelRecordIdId(
    String themeLabel,
    String id,
    String valueValue,
  ) {
    return 'ターミナルテーマ：$themeLabel、レコード ID：$id、リビジョン：$valueValue';
  }

  @override
  String get theHostConflictCanNoLonger => 'このホストの競合は安全に確認できなくなりました。';

  @override
  String get theSshServerGatewayportsSettingMay =>
      'SSH サーバーの GatewayPorts 設定によって、このループバックへのバインド要求が拡大される場合があります。リモートフォワーディングを使う前にサーバーの設定を確認してください。';

  @override
  String get theSshServerRequestedTooMany =>
      'SSH サーバーが要求した応答が多すぎるため、認証を停止しました。';

  @override
  String get theVaultChangedReopenPortForwarding =>
      '保管庫が変更されました。ポート転送を開き直してください。';

  @override
  String get theVaultOrOneOfThe => '保管庫または選択したホストの一部を利用できなくなりました。';

  @override
  String get theArchiveHasPassedSignatureMembership =>
      'アーカイブは署名、メンバーシップ、エンベロープ、オブジェクトのハッシュ、スキーマのチェックに合格しました。インポートはこの保管庫にのみマージされます。不足している暗号化オブジェクトは同じ保管庫にアップロードされる場合があります。セッショントークンやデバイスの秘密鍵はインポートに含まれません。他のデバイスが作成した送信トレイの項目はローカルの競合として残り、このデバイスの ID で再送されることはありません。';

  @override
  String get theCommittedHostChangedAfterThis =>
      'このプレビューの後に確定済みのホストが変更されました。編集はステージされていません。最新の先頭を確認してから選択し直してください。';

  @override
  String get theCommittedHostChangedReviewIts =>
      '確定済みのホストが変更されています。マージする前に最新の接続設定を確認してください。';

  @override
  String get theCommittedVaultVersionChangedReview =>
      '確定済みの保管庫のバージョンが変更されました。マージする前に再度確認してください。';

  @override
  String get theCredentialIsNoLongerAvailable =>
      'この認証情報は現在のセッションでは利用できなくなりました。更新が完了している場合は、状態を確認してからもう一度更新し、新しいワンタイムの値を取得してください。';

  @override
  String get theCurrentVaultVersionChangedWhile =>
      '確認中に現在の保管庫のバージョンが変更されたため、選択はクリアされました。現在のバージョンを確認してから選択し直してください。';

  @override
  String get theDefaultPreferenceWasConfirmedAfter => '既定の設定は保管庫の同期後に確認されました。';

  @override
  String get theDeploymentGateIsAvailableWith =>
      'ATERMIUS_RELAY_ENABLED=true の場合、デプロイの設定を利用できます。実効的な許可は常に設定された CIDR とポートで制限されます。';

  @override
  String get theExportContainsARandomReport =>
      'エクスポートには、ランダムなレポート ID、固定のエラーコード、クライアントのバージョン、同期の件数、UTC の日単位に丸めた日付が含まれます。保管庫のレコード、アカウントの詳細、サーバーのアドレス、デバイスの識別子は決して含まれません。';

  @override
  String get theFullScriptIsReviewedBefore =>
      'スクリプト全体はアクティブな PTY に送信する前に確認されます。';

  @override
  String get theLastResponseWasNotConfirmed =>
      '前回の応答は確認されませんでした。サーバーですでにパスワードが変更されている可能性があります。再試行ではまったく同じリクエストが送信され、再試行のためにパスワードが保存されることはありません。新しいパスワードを覚えておいてください。サインアウトするとこの再試行リクエストは消去されます。';

  @override
  String get theLocalBranchAndItsOriginal =>
      'ローカルのブランチと元の CAS ベースは、ローカルストレージに暗号化されたまま保持されます。スナップショットにはこのレコードの現在のリモートの先頭がないため、ローカルのブランチを保持すると新しいルートのリビジョンが作成されます。';

  @override
  String get theLocalLayoutBranchWasSaved =>
      'ローカルのレイアウトのブランチを新しい暗号化ワークスペースとして保存しました。';

  @override
  String get theOperatingSystemWillAskFor =>
      'これをオンにしたときにのみ、OS が通知の権限を求めます。保管庫のデータは引き続き認証済みの WebSocket またはポーリングで同期されます。';

  @override
  String get theOptInRemoteBashHook =>
      'オプトインのリモート Bash フックは、完了したコマンドを最大 500 件、暗号化されたローカルストレージに保存します。リモートホストは OSC の項目を偽造できます。パスワードの入力プロンプトは読み取りませんが、コマンドとして入力した秘密情報は取得される場合があります。「ローカルでの取得を停止」では新しいイベントを無視します。フックを止めるには Bash で \"atermius_off\" を実行するか、シェルを閉じてください。';

  @override
  String get thePasswordStaysInThisForm =>
      'パスワードはこのフォーム内にのみ保持され、送信されることはありません。';

  @override
  String thePendingInvitationForUsernameWill(String username) {
    return '$username への保留中の招待は受け付けられなくなります。';
  }

  @override
  String get thePreviousCodeWasNotConfirmed =>
      '前回のコードは保存済みとして確認されていません。復旧を更新して代わりのコードを表示してください。';

  @override
  String get theSavedPolicyExceedsTheCurrent =>
      '保存されたポリシーが現在のデプロイの上限を超えています。実効的な許可は引き続き現在の制限で制約されます。保存する前に下の CIDR とポートを狭めてください。リレーサービスの実行には ATERMIUS_RELAY_ENABLED=true も必要です。';

  @override
  String get theSavedPolicyRemainsSelectedAs =>
      '保存されたポリシーは有効のまま選択されていますが、デプロイの設定がオフの間は実効的なリレーサービスを利用できません。ATERMIUS_RELAY_ENABLED=true が必要です。他の変更を保存する前に、この選択をオフにしてください。Web UI からこの設定は変更できません。';

  @override
  String get theSecretIsReadFromThe =>
      'シークレットはこのスニペットの実行時に暗号化された認証情報から読み取られ、スニペットのレコードやプレビューにコピーされることはありません。';

  @override
  String get theSelectedDefaultPreferenceWasConfirmed =>
      '選択した既定の設定は保管庫の同期後に確認されました。';

  @override
  String get theSelectedShortcutBindingsWereConfirmed =>
      '選択したキー割り当ては保管庫の同期後に確認されました。';

  @override
  String get theSelectedTerminalFontSizeWas =>
      '選択したターミナルのフォントサイズは保管庫の同期後に確認されました。';

  @override
  String get theSelectedTerminalThemeWasConfirmed =>
      '選択したターミナルのテーマは保管庫の同期後に確認されました。';

  @override
  String get theServerCanCopyEncryptedInstance =>
      'サーバーは、暗号化されたインスタンスアーカイブを運用者が設定した S3 互換の保存先にコピーできます。保存先と認証情報はサーバー上に保持されます。アクセスチェックは HeadBucket のみを実行し、アップロード、マルチパート操作、復元、プロバイダー全体の互換性は検証しません。';

  @override
  String get theServerDeploymentGateMustAlso => 'サーバーのデプロイ設定も有効にする必要があります。';

  @override
  String get theServerDidNotRequestA => 'サーバーは応答を要求しませんでした。';

  @override
  String get theServerFirstValidatesThatThis =>
      'サーバーはまず、このコピーと受領情報がこの復元ジョブに属することを検証し、検証できない場合はファイルに手を加えません。クリーンアップを確定すると、この隔離コピーだけが完全に削除され、元の暗号化アーカイブと稼働中のサービスデータは変更されません。後で元のアーカイブから別の隔離コピーを準備できます。';

  @override
  String get theServerReceivesPasswordDerivedVerifiers =>
      'サーバーが受け取るのは、パスワードから導出した検証値と新たに暗号化されたアカウント鍵のエンベロープです。マスターパスワードとアカウント鍵はこのデバイスに残ります。';

  @override
  String get theServerRequiresANewerWeb => 'サーバーには新しい Web クライアントのプロトコルが必要です。';

  @override
  String get theServerRequiresANewerClient =>
      'サーバーには新しいクライアントプロトコルが必要です。デプロイされた Web バンドルが想定どおりの互換リリースであることを確認してください。';

  @override
  String theServerRestorePeriodHasNot2(String deadlineText) {
    return 'サーバーの復元期間はまだ終了していません。$deadlineTextごみ箱を更新して、しばらくしてからもう一度お試しください。';
  }

  @override
  String get theServerWillDeleteTheEncrypted =>
      'サーバーは暗号化された復旧パッケージとすべての復旧用キーボックスを削除します。再設定するには承認済みのデバイスが必要になります。';

  @override
  String get theServerWillStartItsConfigured =>
      'サーバーで設定された猶予期間が始まります。すべてのアクティブなメンバーはすぐに読み取り専用になり、サーバーの期限までは読み取りが可能です。期限までにポータブル暗号化アーカイブを作成して別に保管してください。このクライアントは同じサーバースペースと保管庫にのみ復元できます。確定後、サーバーが正確な完全削除の日時を返します。';

  @override
  String get theServiceStaysOnlineWhileIt =>
      '選択したローカルのアーカイブから別のコピーを準備する間もサービスはオンラインのままです。稼働中のデータベースに復元ジョブと監査イベントを記録し、メンテナンスのロックを使用しますが、アクティブなアカウント、保管庫、セッション、世代のデータは変更せず、稼働中のデータを有効化したり置き換えたりもしません。ワーカーは隔離ステージを公開する前にアーカイブを再度確認します。';

  @override
  String get theServiceStaysOnlineWhileIt2 =>
      '別のコピーを準備する間もサービスはオンラインのままです。稼働中のデータベースに復元ジョブと監査イベントを記録し、メンテナンスのロックを使用しますが、アクティブなアカウント、保管庫、セッション、世代のデータは変更せず、稼働中のデータを有効化したり置き換えたりもしません。ワーカーは隔離ステージを公開する前に、選択したローカルまたはリモートのアーカイブを再度確認します。';

  @override
  String get theShareExpiresAfter15Minutes =>
      '共有は 15 分後に期限切れになります。ターミナル出力とホストのリサイズイベントは、選択した各デバイス向けに暗号化されます。';

  @override
  String get theSyncCursorExpiredOrThe =>
      '同期カーソルが期限切れになったか、サーバーの世代が変わりました。検証済みのスナップショットからキャッシュを再構築してください。保留中のローカルの操作は保持され、リモートの先頭と比較されます。';

  @override
  String get theTerminalChangedBeforeTheSuggestion =>
      '候補を入力する前にターミナルが変更されました。候補を開き直してから再試行してください。';

  @override
  String get theUpdateCheckCouldNotConfirm => '更新の確認で現在の Web ビルドを確認できませんでした。';

  @override
  String get theseInstanceGroupsControlSshRelay =>
      'これらのインスタンスグループは SSH Relay へのアクセスを制御します。暗号化されたワークスペースのグループとは別のもので、保管庫のデータは含みません。';

  @override
  String get thisGroupDefaultIsUnavailableChoose =>
      'このグループの既定値は利用できません。既定なし、または有効な認証情報を選択してください。';

  @override
  String get thisHostConflictHasNoSafely =>
      'このホストの競合には安全に確認できる接続設定のまとまりがありません。検証済みのブランチの操作を使ってください。';

  @override
  String thisSshKeyIsNotTrusted(String endpoint) {
    return 'この SSH 鍵は $endpoint に対して信頼されていません。承諾する前に、信頼できる経路でフィンガープリントを照合してください。';
  }

  @override
  String get thisVaultIsReadOnlyFor =>
      'この保管庫は現在のアカウントでは読み取り専用です。サーバーが許可する範囲で読み取りは引き続き可能です。「設定」からポータブル暗号化アーカイブを作成できます。';

  @override
  String get thisVaultIsReadOnlyMember => 'この保管庫は読み取り専用のため、メンバーを変更できません。';

  @override
  String get thisVaultIsReadOnlyYou => 'この保管庫は読み取り専用です。設定は表示できますが変更できません。';

  @override
  String get thisVaultIsReadOnlyYou2 =>
      'この保管庫は読み取り専用です。共有のショートカットは表示できますが変更できません。';

  @override
  String get thisVaultIsReadOnlyYou3 =>
      'この保管庫は読み取り専用です。共有のターミナルの配色テーマは表示できますが変更できません。';

  @override
  String get thisVaultIsReadOnlyYou4 =>
      'この保管庫は読み取り専用です。共有のターミナルのフォントサイズは表示できますが変更できません。';

  @override
  String get thisWebBuildIsCurrent => 'この Web ビルドは最新です。';

  @override
  String get thisAccountHasNoVaultAvailable =>
      'このアカウントには、このデバイスで利用できる保管庫がありません。新しい暗号化保管庫を作成するか、既存メンバーからの招待を承諾するか、オーナーにアクセスの復元を依頼してください。既存の暗号化データは新しい保管庫とは別に保持されます。';

  @override
  String get thisAttachesTheCurrentSshPane =>
      '現在の SSH ペインを保存済みの tmux セッションにアタッチします。他のアタッチ済みのクライアントは接続されたままです。';

  @override
  String get thisCardContainsTheAccountAnd =>
      'このカードにはアカウントとデバイスの公開鍵、自己証明の署名が含まれます。秘密鍵や保管庫の鍵は含まれません。信頼できる経路で保管庫のオーナーに送ってください。';

  @override
  String get thisCodeIsShownOnceAnyone =>
      'このコードは一度だけ表示されます。このコードを持つ人は誰でも、このアカウントの保管庫の鍵を復旧できます。パスワードマネージャーなどの安全な場所に保管してください。このクライアントが保存することはありません。';

  @override
  String get thisConflictNoLongerSupportsPassword =>
      'この競合ではパスワードフィールドの統合ができなくなりました。検証済みのブランチの操作を使ってください。';

  @override
  String get thisCreatesATmuxSessionOn =>
      '現在の SSH ホストに tmux セッションを作成し、その参照をこの暗号化ワークスペースに保存します。';

  @override
  String get thisDeviceLoopbackOnly => 'このデバイスのループバックのみ';

  @override
  String get thisExactFingerprintWasRevokedBefore =>
      'このフィンガープリントは以前に失効しています。再承認すると、この保管庫に新しい暗号化された信頼レコードが作成され、デバイスに同期されます。続行する前に別の経路で確認してください。';

  @override
  String get thisFormNeverSubmitsCredentialText =>
      'このフォームが認証情報のテキストをサーバーに直接送信することはありません。';

  @override
  String thisGrantsRoleAccessToAll(String role) {
    return 'この保管庫内のすべての暗号化レコードへの $role アクセスを付与します。現在の保管庫鍵はこのデバイスに封印され、オーナーが新しいメンバーシップのバージョンに署名します。続行する前に、受信者とアカウントおよび両方のフィンガープリントを照合してください。';
  }

  @override
  String get thisGroupChangedOnAnotherDevice =>
      'このグループは別のデバイスで変更されました。同期して開き直してから再試行してください。';

  @override
  String get thisGroupHasNoMembers => 'このグループにはメンバーがいません。';

  @override
  String get thisImmediatelyRevokesEverySessionAnd =>
      'すべてのセッションとデバイスが直ちに失効します。サーバーの完全削除期限になると、個人用保管庫とアカウントのデータが削除され、共有保管庫へのアクセスも削除されます。他のメンバーの共有保管庫のデータは削除されません。';

  @override
  String get thisInstance => 'このインスタンス';

  @override
  String get thisInvitationWasInvalidatedAfterA =>
      '保管庫のメンバーシップの変更により、この招待は無効になりました。「設定」>「メンバーを招待」から新しい招待を送ってください。';

  @override
  String get thisInvitationsValidityCouldNotBe =>
      'この招待の有効性を確認できませんでした。「設定」>「メンバーを招待」から新しい招待を送ってください。';

  @override
  String get thisIsABearerTokenShare =>
      'これはベアラートークンです。信頼できる経路で、対象の受信者にのみ共有してください。表示は一度だけで、対象のアカウントとデバイスに紐付けられています。';

  @override
  String get thisIsOptInAndBash =>
      'これはオプトインで Bash 専用です。シェルの起動ファイルを編集したり、リモートにファイルを書き込んだりはしません。コマンドをコピーしたら、接続中のシェルに貼り付けて Enter を押してください。完了したコマンドはこのデバイスに暗号化して保存されます（最大 500 件）。リモートホストは項目を偽造できます。パスワードの入力プロンプトは読み取りませんが、コマンドとして入力した秘密情報は取得される場合があります。';

  @override
  String get thisMobileAppBuildHasNo =>
      'このモバイルアプリのビルドには Firebase プロジェクトが設定されていません。プロバイダーのトークン登録を有効にするには、このアプリの Firebase オプションでビルドしてください。FCM で配信するには、Firebase プロジェクトがサーバーのサービスアカウントのプロジェクトと一致している必要があります。iOS の APNs 配信にはサーバーの APNs 設定が使われます。WebSocket とポーリングによる同期は引き続き利用できます。';

  @override
  String get thisPasswordIsUsedOnlyTo => 'このパスワードはこのアーカイブの復号にのみ使用されます。';

  @override
  String thisRecordsConsentForThisExact(String recordDisplayName) {
    return 'この削除マーカー（$recordDisplayName）に対する同意のみを記録します。同意すると、制限付きのメンテナンスが復元期限とその他の必要なチェックの後に自動で完全削除する場合があります。同意しても直ちに削除されるわけではありません。';
  }

  @override
  String get thisRecordsDeletedVersionChangedThe =>
      'このレコードの削除済みのバージョンが変更されました。ごみ箱を更新しています。確認してから再試行してください。';

  @override
  String get thisRemovesTheEncryptedWorkspaceReference =>
      '暗号化されたワークスペースの参照を削除します。リモートの tmux セッションは停止も削除もされません。';

  @override
  String get thisRequestBelongsToAnotherAccount => 'このリクエストは別のアカウントのものです。';

  @override
  String get thisServerBackendDoesNotSupport =>
      'このサーバーのバックエンドはレコードの完全削除にまだ対応していません。削除は行われていません。';

  @override
  String get thisServerIsNotCurrentlyAccepting =>
      'このサーバーは現在、復元リクエストを受け付けていません。既存の隔離ステージと稼働中のデータは変更されていません。';

  @override
  String thisSettingIsEncryptedInCurrentvaultname(String currentVaultName) {
    return 'この設定は $currentVaultName で暗号化され、この保管庫にアクセスできるデバイスに同期されます。';
  }

  @override
  String thisSettingIsStoredAsAn(String currentVaultName) {
    return 'この設定は $currentVaultName に暗号化レコードとして保存され、その保管庫と同期されます。';
  }

  @override
  String get thisSignedOutboxBranchCameFrom =>
      'この署名済みの送信トレイのブランチは別のデバイスからのものです。操作 ID とエンベロープはローカルに保持されますが、このデバイスが別の署名 ID で再送することはありません。ローカルのブランチを保持すると、このデバイスで署名した新しいリビジョンが作成されます。';

  @override
  String get thisSnapshotExceedsThisClientsLimit =>
      'このスナップショットは、このクライアントの上限（シリアライズされたマニフェストデータ 64 MiB、または先頭 100,000 件）を超えています。既存のキャッシュ、チェックポイント、送信待ちの送信トレイは保持されます。復旧を繰り返しても解決しないため、移行についてはプロジェクトのメンテナーに相談してください。';

  @override
  String get title => 'タイトル';

  @override
  String get toEnableSshRelayTheServer =>
      'SSH リレーを有効にするには、サーバーの運用者が ATERMIUS_RELAY_ENABLED=true を設定し、デプロイの制限を構成する必要があります。Web UI からこの設定は変更できません。';

  @override
  String get topLevelGroup2 => '最上位グループ';

  @override
  String get transferVaultOwnership => '保管庫の所有権を移転しますか？';

  @override
  String get transferAndRotateKey => '移転して鍵を更新';

  @override
  String get transferOwnership => '所有権を移転';

  @override
  String get trustAfterVerification => '確認して信頼';

  @override
  String get trustedDevices => '信頼済みのデバイス';

  @override
  String get typeDeleteToConfirm => '確認のため DELETE と入力してください';

  @override
  String get typeEnableAutomaticPurge => 'ENABLE AUTOMATIC PURGE と入力してください';

  @override
  String get typeACommandFragmentToSee => 'コマンドの一部を入力すると候補が表示されます。';

  @override
  String typeVaultnameToConfirm(String vaultName) {
    return '確認のため「$vaultName」と入力してください';
  }

  @override
  String unableToCheckBackupBucketAccess(String error) {
    return 'バックアップバケットへのアクセスを確認できません：$error';
  }

  @override
  String unableToDiscardIsolatedRestoreCopy(String error) {
    return '隔離された復元用コピーを破棄できません：$error';
  }

  @override
  String get unableToLoadAccountRelayPolicy => 'アカウントの Relay ポリシーを読み込めません';

  @override
  String get unableToLoadMemberEffectiveRelay => 'メンバーの実効 Relay アクセスを読み込めません';

  @override
  String unableToLoadOffSiteBackup(String error) {
    return 'オフサイトバックアップの状態を読み込めません：$error';
  }

  @override
  String unableToLoadRestoreSourcesError(String error) {
    return '復元元を読み込めません：$error';
  }

  @override
  String unableToLoadScheduledBackupsError(String error) {
    return 'スケジュールバックアップを読み込めません：$error';
  }

  @override
  String get unableToLoadServerManagedGroup => 'サーバー管理のグループの詳細を読み込めません';

  @override
  String get unableToLoadServerManagedGroups => 'サーバー管理のグループを読み込めません';

  @override
  String unableToPrepareIsolatedRestoreCopy(String error) {
    return '隔離された復元用コピーを準備できません：$error';
  }

  @override
  String unableToRefreshRestoreStageStatus(String error) {
    return '復元のステージの状態を更新できません：$error';
  }

  @override
  String unableToReviewPasswordFieldsFriendlyerror(String friendlyError) {
    return 'パスワードフィールドを確認できません：$friendlyError';
  }

  @override
  String unableToSaveScheduledBackupsError(String error) {
    return 'スケジュールバックアップを保存できません：$error';
  }

  @override
  String get unavailableCredential2 => '利用できない認証情報';

  @override
  String get unavailableCredential => '利用できない認証情報';

  @override
  String get unavailableGroup => '利用できないグループ';

  @override
  String get unavailableInWeb => 'Web 版では利用できません';

  @override
  String get unavailableOnThisNode => 'このノードでは利用できません';

  @override
  String get unavailableParentChooseAgain => '親が利用できません。選択し直してください';

  @override
  String uncommittedOperationsCount(int count) {
    return '未確定の操作：$count';
  }

  @override
  String get unknown => '不明';

  @override
  String get unknownPushProvider => '不明なプッシュプロバイダー';

  @override
  String get unlockArchive => 'アーカイブのロックを解除';

  @override
  String get unnamedDevice => '名前のないデバイス';

  @override
  String get unsupportedTheme => '対応していないテーマ';

  @override
  String get unverified => '未検証';

  @override
  String get upOneDirectory => '1 つ上のディレクトリへ';

  @override
  String get updateAndReload => '更新して再読み込み';

  @override
  String get updateReadinessChangedFinishTheVisible =>
      '更新の準備状況が変わりました。表示されている問題を解決してから確定してください。';

  @override
  String get updatingThisDevice => 'このデバイスを更新しています…';

  @override
  String get upload => 'アップロード';

  @override
  String get uploadAFileOrCreateA => 'ファイルをアップロードするかフォルダーを作成して始めましょう。';

  @override
  String get useAtLeast12CharactersIf =>
      '12 文字以上を使用してください。応答が失われた場合でも、クライアントがメモリに保持するのは同一の再試行リクエストだけで、どちらのパスワードも保持しません。';

  @override
  String get useConflictBranch => '競合ブランチを使用';

  @override
  String get useCurrentVaultVersion => '現在の保管庫のバージョンを使用';

  @override
  String get useSyncedVersion => '同期済みのバージョンを使用';

  @override
  String get useTheAccountAndApprovedDevice =>
      '招待で指定されたアカウントと承認済みデバイスを使用してください。トークンは認証済みリクエストの本文で送信され、URL に追加されることはありません。';

  @override
  String get useTheConflictBranchTuple => '競合ブランチのまとまりを使用';

  @override
  String get useTheCurrentVaultTuple => '現在の保管庫のまとまりを使用';

  @override
  String get useTheSyncedVersion => '同期済みのバージョンを使用しますか？';

  @override
  String get userId => 'ユーザー ID';

  @override
  String get username => 'ユーザー名';

  @override
  String get validatingAllSelectedHostsBeforeSending =>
      '最初のコマンドを送信する前に、選択したすべてのホストを検証しています。';

  @override
  String get vaultId => '保管庫 ID';

  @override
  String get vaultArchiveImportedAndLocalState =>
      '保管庫アーカイブをインポートし、ローカルの状態を復元しました。';

  @override
  String vaultChangedWhileSavingCheckThe(String startingVaultName) {
    return '保存中に保管庫が切り替わりました。$startingVaultName の設定を確認してください。アクティブな保管庫は保存済みになっていません。';
  }

  @override
  String vaultChangedWhileSavingCheckThe2(String startingVaultName) {
    return '保存中に保管庫が切り替わりました。$startingVaultName のショートカットの設定を確認してください。アクティブな保管庫は保存済みになっていません。';
  }

  @override
  String vaultChangedWhileSavingTheEncrypted(String startingVaultName) {
    return '保存中に保管庫が切り替わりました。暗号化された変更は $startingVaultName のキューに残っており、アクティブな保管庫には保存されていません。';
  }

  @override
  String vaultChangedWhileSavingTheFont(String startingVaultName) {
    return '保存中に保管庫が切り替わりました。フォントサイズの変更は $startingVaultName のキューに残っており、アクティブな保管庫には保存されていません。';
  }

  @override
  String vaultChangedWhileSavingTheShortcut(String startingVaultName) {
    return '保存中に保管庫が切り替わりました。ショートカットの変更は $startingVaultName のキューに残っており、アクティブな保管庫には保存されていません。';
  }

  @override
  String vaultChangedWhileSavingTheTheme(String startingVaultName) {
    return '保存中に保管庫が切り替わりました。テーマの変更は $startingVaultName のキューに残っており、アクティブな保管庫には保存されていません。';
  }

  @override
  String vaultDeletionIsScheduledThisVault(String vaultLifecycleDate) {
    return '保管庫の削除が予定されています。この保管庫は読み取り専用で、$vaultLifecycleDate 以降にサーバーから完全に削除されます。未送信の変更はこのデバイスに残り、オーナーが削除を取り消した場合にのみ再開されます。';
  }

  @override
  String get vaultDeletionPendingReadOnly => '保管庫の削除予定 · 読み取り専用';

  @override
  String vaultDeviceNameStatuslabel(String name, String statusLabel) {
    return '保管庫のデバイス $name、$statusLabel';
  }

  @override
  String vaultIsInItsDeletionGrace(int pendingCount) {
    return '保管庫は削除の猶予期間中です。取得と読み取りは引き続き可能ですが、競合のアップロードと送信トレイのプッシュは一時停止しています。「設定」のポータブル暗号化アーカイブでローカルバックアップを作成してください。サーバーは表示された期限に稼働中の保管庫データを完全に削除します。保留中の操作 $pendingCount 件はこのデバイスに暗号化されたまま残り、オーナーが期限前に削除を取り消した場合にのみ再開されます。';
  }

  @override
  String get vaultKeyState => '保管庫の鍵の状態';

  @override
  String get vaultMetadataAndStorageLimitsEncrypted =>
      '保管庫のメタデータとストレージの制限です。暗号化された名前や内容が表示されることはありません。';

  @override
  String get vaultName => '保管庫名';

  @override
  String get vaultNameHostsCredentialsAndSnippets =>
      '保管庫の名前、ホスト、認証情報、スニペットは同期前に暗号化されます。';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore =>
      'これらのショートカットを変更する前に、保管庫の設定データに対処する必要があります。';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore2 =>
      'この設定を変更する前に、保管庫の設定データに対処する必要があります。';

  @override
  String get vaultRole => '保管庫のロール';

  @override
  String get vaultStatesRefreshedFromTheServer => 'サーバーから保管庫の状態を更新しました。';

  @override
  String get vaultSyncIsUnreachableThisConfirmation =>
      '保管庫の同期に接続できません。この確認では、初めて検出されたフィンガープリントが暗号化レコードとしてこのデバイスのキューに追加され、保管庫の同期で確認されるまで現在の SSH 接続は停止します。オフライン中は他のデバイスの承認や失効を確認できません。';

  @override
  String vaultVaultid(String vaultId) {
    return '保管庫 $vaultId';
  }

  @override
  String get vaultConflictResolved => '保管庫の競合を解決しました';

  @override
  String get vaultDeletionCancelled => '保管庫の削除を取り消しました';

  @override
  String get vaultDeletionScheduled => '保管庫の削除を予約しました';

  @override
  String get vaultEncryptedDataSynced => '保管庫の暗号化データを同期しました';

  @override
  String get vaultKeyGeneration => '保管庫鍵の世代';

  @override
  String get vaultKeyRotated => '保管庫の鍵を更新しました';

  @override
  String get vaultCreated => '保管庫を作成しました';

  @override
  String get vaultPurged => '保管庫を完全に削除しました';

  @override
  String get vaultOwnershipTransferred => '保管庫の所有権を移転しました';

  @override
  String get vaultScopedAuditIsAvailableOnly =>
      '保管庫の範囲の監査は、現在の保管庫のオーナーと編集者のみが利用できます。現在の権限では保管庫のイベントは返されません。';

  @override
  String get vaultSyncedPreferences => '保管庫と同期する設定';

  @override
  String vaultVaultid2(String vaultId) {
    return '保管庫：$vaultId';
  }

  @override
  String vaultVaultname(String vaultName) {
    return '保管庫：$vaultName';
  }

  @override
  String get vaults => '保管庫';

  @override
  String verifiedCapabilitiesReportRevisionRevisionRecord(
    int revision,
    int maxRecordSchema,
    String attachmentVersions,
    String formatAdminBytes,
  ) {
    return '検証済みの機能 · レポートのリビジョン $revision\nレコードスキーマ ≤ $maxRecordSchema · 添付ファイル形式 $attachmentVersions · 添付ファイルの上限 $formatAdminBytes';
  }

  @override
  String verifiedRevisionsRecordcount(int recordCount) {
    return '検証済みのリビジョン：$recordCount';
  }

  @override
  String get verifySshHostKey => 'SSH ホスト鍵を確認';

  @override
  String get verifyAndDiscard => '検証して破棄';

  @override
  String get verifyAndReview => '検証して確認';

  @override
  String get verifyArchive => 'アーカイブを検証';

  @override
  String viaJumpHostJumphostname(Object jumpHostName) {
    return '踏み台ホスト経由：$jumpHostName';
  }

  @override
  String get viewVaultMembers => '保管庫のメンバーを表示';

  @override
  String get viewCommandHistory => 'コマンド履歴を表示';

  @override
  String get viewSessions => 'セッションを表示';

  @override
  String get viewerReadOnlyVaultAccess => '閲覧者 · 保管庫への読み取り専用アクセス';

  @override
  String get workspace2 => 'ワークスペース';

  @override
  String get waitForVaultSyncOrRecovery =>
      'メンバーを変更する前に、保管庫の同期または復旧が完了するまでお待ちください。';

  @override
  String get waitForVaultSynchronizationOrRecovery =>
      '保管庫の同期または復旧が完了するまでお待ちください。';

  @override
  String get waitingForRemoteCopy => 'リモートコピーを待機中';

  @override
  String get waitingToSync => '同期待ち';

  @override
  String get webApplicationUpdates => 'Web アプリの更新';

  @override
  String get wholeHoursFrom1To720 => '1〜720 の整数（時間）';

  @override
  String get withdrawConsent => '同意を取り消す';

  @override
  String get workspace3 => 'ワークスペース';

  @override
  String get workspaceActions => 'ワークスペースの操作';

  @override
  String get workspaceName => 'ワークスペース名';

  @override
  String get workspaceSavedEncryptedToThisVault => 'ワークスペースをこの保管庫に暗号化して保存しました。';

  @override
  String get youHaveReadOnlyAccessTo => 'この保管庫へのアクセスは読み取り専用です。';

  @override
  String get activePane2 => 'アクティブなペイン';

  @override
  String get eGGrep => '例：grep';

  @override
  String get redactedDraft => '秘匿化済みの下書き';

  @override
  String actionFriendlyerror(String action, String friendlyError) {
    return '$action：$friendlyError';
  }

  @override
  String countGroupParentRelationshipSAre(int count) {
    return '$count 件のグループの親子関係が欠落しているか循環しています。影響を受けるグループを編集し、有効な親または最上位グループを選択してください。';
  }

  @override
  String countHosts(int count) {
    return '$count 台のホスト';
  }

  @override
  String countOfCount2VaultKeyContexts(int count, int count2) {
    return '$count2 個の保管庫鍵コンテキストのうち $count 個に復旧ボックスがあります。';
  }

  @override
  String countSuggestions(int count) {
    return '候補 $count 件';
  }

  @override
  String countTabs(int count) {
    return '$count 個のタブ';
  }

  @override
  String countTargetSReportedAKnown(
    int count,
    int count2,
    int count3,
    int count4,
  ) {
    return '結果が判明した対象 $count 件、リモートでの完了が不明 $count2 件、送信前に停止 $count3 件、未開始 $count4 件。';
  }

  @override
  String countPendingReview(int count) {
    return '確認待ち $count 件';
  }

  @override
  String displaynameAndItsEncryptedPayloadsWill(String displayName) {
    return '$displayName とその暗号化ペイロードは、サーバーのアクティブな状態から削除されます。アプリから元に戻すことはできません。';
  }

  @override
  String displaynameWillBeRestoredFromIts(String displayName) {
    return '$displayName は最後に検証された有効なリビジョンから復元されます。対応する削除マーカーがまだサーバーの現在の先頭である場合にのみ成功します。';
  }

  @override
  String filenameWillBeRemovedFromThe(String filename) {
    return '$filename はリモートホストから削除されます。';
  }

  @override
  String itemSigningKeyShortkey(Object item, String shortKey) {
    return '$item\n署名鍵 · $shortKey';
  }

  @override
  String labelforIdSubstringDeletedFormat(
    String labelFor,
    String substring,
    String format,
  ) {
    return '$labelFor · ID $substring · 削除 $format';
  }

  @override
  String membercountMembersValuevalueRevisionRevision(
    int memberCount,
    String valueValue,
    int revision,
  ) {
    return 'メンバー $memberCount 人 · $valueValue · リビジョン $revision';
  }

  @override
  String missingcountMissing(int missingCount) {
    return '$missingCount 件不足';
  }

  @override
  String nameWillLoseAccountAccessAnd(String name) {
    return '$name はアカウントにアクセスできなくなり、アクティブなセッションは失効します。';
  }

  @override
  String nameValuevaluePasswordHiddenFromPreview(
    String name,
    String valueValue,
  ) {
    return '$name：$valueValue · パスワードはプレビューで非表示';
  }

  @override
  String pendingcountEncryptedLocalChangeSAre(int pendingCount) {
    return '暗号化されたローカルの変更 $pendingCount 件がまだ送信トレイにあります。保管庫が読み取り専用の間は送信されず、このブラウザに残ります。期限前に削除が取り消された場合にのみ同期を再開できます。';
  }

  @override
  String roleKeyEpochActivekeyepochMembershipMembershipversion(
    String role,
    String activeKeyEpoch,
    String membershipVersion,
  ) {
    return '$role · 鍵エポック $activeKeyEpoch · メンバーシップ $membershipVersion';
  }

  @override
  String tolocalExitExitstatus(DateTime toLocal, int exitStatus) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$toLocalString · 終了コード $exitStatus';
  }

  @override
  String unavailablerecordcountEncryptedRecordSCouldNot(
    int unavailableRecordCount,
  ) {
    return '$unavailableRecordCount 件の暗号化レコードを、現在の保管庫の鍵／デバイスディレクトリで検証できないか、対応するレコードとしてデコードできませんでした。暗号文はローカルに保存されたまま、信頼済みデータからは非表示になっています。';
  }

  @override
  String unresolvedconflictcountNeedsReview(int unresolvedConflictCount) {
    return '確認が必要 $unresolvedConflictCount 件';
  }

  @override
  String valuevalueMoreDeviceSNeedReview(int valueValue) {
    return 'ほか $valueValue 台のデバイスの確認が必要です。';
  }

  @override
  String valuevalueUsernameAndRotateTheVault(
    String valueValue,
    String username,
  ) {
    return '$username を$valueValueし、残りのすべてのアクティブなメンバーデバイスの保管庫鍵を更新しますか？削除されたアカウントには新しい鍵は渡されません。既存の古いコピーをリモートで消去することはできません。保留中の他の招待トークンは無効になり、再発行が必要です。';
  }

  @override
  String get configuredMeansThisServerProcessLoaded =>
      '「設定済み」は、このサーバープロセスがプロバイダーのアダプターを読み込んだことを意味し、接続性やワーカーの稼働を保証するものではありません。プッシュはベストエフォートの起動ヒントであり、配信や同期の証明にはなりません。正しい状態は認証済みの WebSocket またはポーリングで判断されます。';

  @override
  String get previousPage => '前のページ';

  @override
  String lastArchiveVerificationFailedAtArchivefailurephase(
    Object archiveFailurePhase,
  ) {
    return '前回のアーカイブ検証が失敗した段階：$archiveFailurePhase';
  }

  @override
  String get nextPage => '次のページ';

  @override
  String get doesntExist => '存在しません';

  @override
  String get masterPasswordChanged => 'マスターパスワードを変更しました';

  @override
  String get couldntChangeTheMasterPassword => 'マスターパスワードを変更できませんでした';

  @override
  String get hosts => 'ホスト';

  @override
  String get onlyTheHostIdTabOrder =>
      '同期されるのはホスト ID、タブの順序、分割の向きと比率のみです。認証情報、実行中の SSH セッション、ターミナル出力、SFTP パス、ファイルの状態はワークスペースレコードに書き込まれません。';

  @override
  String get retryFromTheFirstPage => '最初のページから再試行';

  @override
  String get saveAndConnect => '保存して接続';

  @override
  String get saveCurrentWindowLayout => '現在のウィンドウレイアウトを保存';

  @override
  String get saveTheCurrentTerminalTabsTo =>
      '現在のターミナルタブを保存すると、承認済みの他のデバイスで同じレイアウトをプレビューできます。';

  @override
  String get keepTheCurrentCommittedVersion => '現在の確定済みバージョンを保持しますか？';

  @override
  String get keepCurrentVersion => '現在のバージョンを保持';

  @override
  String get couldntKeepTheCurrentVersion => '現在のバージョンを保持できませんでした';

  @override
  String get vaultsAndMembers => '保管庫とメンバー';

  @override
  String get change => '変更';

  @override
  String get openOneOrMoreTabsOn =>
      '先にターミナルページで 1 つ以上のタブを開いてから、名前付きレイアウトとして保存してください。';

  @override
  String get conflictResolved => '競合を解決しました。';

  @override
  String get setTheTerminalFontSizeColors2 =>
      'ターミナルのフォントサイズ、配色、ショートカットを個別に設定します。設定は現在の保管庫と同期されます。';

  @override
  String get branchsOriginalBase => 'ブランチの元のベース';

  @override
  String get branchNotVerifiedYetKeptRead => 'ブランチはまだ検証されていないため、読み取り専用で保持しています';

  @override
  String get branchSavedOnThisDeviceWaiting => 'ブランチはこのデバイスに保存され、同期の確認を待っています。';

  @override
  String get branchSavedEncryptedOnThisDevice =>
      'ブランチはこのデバイスに暗号化して保存され、同期の確認を待っています。';

  @override
  String branchSequenceSeqValuevalue(String seq, String valueValue) {
    return 'ブランチの連番 $seq · $valueValue';
  }

  @override
  String get branchActions => 'ブランチの操作';

  @override
  String get branchVersion => 'ブランチのバージョン';

  @override
  String get groupLayoutReset => 'グループレイアウトをリセットしました。';

  @override
  String get refresh => '更新';

  @override
  String get encryptedSessionUnlocked => '暗号化セッションのロックを解除しました';

  @override
  String get namedTerminalLayoutsSyncEncryptedIncluding =>
      '名前付きのターミナルレイアウトは、タブの順序や分割の向きと比率を含めて暗号化して同期されます。プレビューでは接続せず、各ペインで個別に「接続」を確認する必要があります。';

  @override
  String get encryptedBackupJobSubmitted => '暗号化バックアップのジョブを送信しました';

  @override
  String get readOnlyViewOfCommittedAccount =>
      '確定済みのアカウント操作と現在の保管庫の管理操作を読み取り専用で表示します。SSH コマンド、ホスト名、認証情報は記録されません。';

  @override
  String get syncAndConflicts => '同期と競合';

  @override
  String get snippets => 'スニペット';

  @override
  String get completedCommandsAreRecordedAfterEnabling2 =>
      '「記録の設定」で Bash 連携を有効にすると、完了したコマンドが記録されます。パスワード入力プロンプトでの入力は取得されません。';

  @override
  String get working => '処理中…';

  @override
  String get backupRestoreAndMaintenance => 'バックアップ、復元、メンテナンス';

  @override
  String get backupCompleted => 'バックアップが完了しました';

  @override
  String get multiFactorRecoveryCodesRotated => '多要素認証の復旧コードを更新しました';

  @override
  String get instanceOverview => 'インスタンスの概要';

  @override
  String get instanceAdminInvitationRevoked => 'インスタンス管理者の招待を取り消しました';

  @override
  String get instanceAdminInvitationIssued => 'インスタンス管理者の招待を発行しました';

  @override
  String get instanceMaintenanceJobSubmitted => 'インスタンスのメンテナンスジョブを送信しました';

  @override
  String get auditLog => '監査ログ';

  @override
  String get auditRecords => '監査記録';

  @override
  String get importAndExportEncryptedArchivesOr =>
      '暗号化アーカイブのインポート／エクスポートや、ローカルプロファイルの移行を行います。';

  @override
  String get notVerifiedYet => '未検証';

  @override
  String get properties => 'プロパティ';

  @override
  String get workspace => 'ワークスペース';

  @override
  String get workspaceLayouts => 'ワークスペースのレイアウト';

  @override
  String get theCurrentWindowLayoutForThis => 'このグループの現在のウィンドウレイアウトを保存しました。';

  @override
  String get multiFactorAuthenticationTurnedOff => '多要素認証をオフにしました';

  @override
  String get memberInvitationCreated => 'メンバーの招待を作成しました';

  @override
  String get deleted => '削除済み';

  @override
  String deletedValuevalue(String valueValue) {
    return '$valueValueを削除しました';
  }

  @override
  String get bashRecordingIsOnUpTo =>
      'Bash の記録が有効です（最大 500 件）。クリックで入力し、Enter で実行します。';

  @override
  String get multiFactorAuthenticationEnabled => '多要素認証を有効にしました';

  @override
  String processedBranchesCount(int count) {
    return '処理済みのブランチ · $count';
  }

  @override
  String get multiFactorSignInStarted => '多要素サインインを開始しました';

  @override
  String get committed => '確定済み';

  @override
  String get committedAdminActionsAppearHereNew =>
      '確定済みの管理操作がここに表示されます。新しいイベントは閲覧中のページカーソルには挿入されません。';

  @override
  String get sshRelayConnectionTicketIssued => 'SSH Relay の接続チケットを発行しました';

  @override
  String get resolved => '解決済み';

  @override
  String get signedOut => 'サインアウトしました';

  @override
  String get multiFactorAuthenticationWasResetAfter =>
      'アーカイブからの復元後に多要素認証がリセットされました';

  @override
  String get currentVault3 => '現在の保管庫';

  @override
  String get hostsCantBeAddedInThe => '現在のワークスペースではホストを追加できません。';

  @override
  String showingEventsForCurrentvaultnameSwitchingThe(String currentVaultName) {
    return '$currentVaultName のイベントを表示しています。上部で保管庫を切り替えると、最初のページから再読み込みします。';
  }

  @override
  String get currentServerVersion => '現在のサーバーのバージョン';

  @override
  String get theCurrentServerVersionIsCommitted =>
      '現在のサーバーのバージョンは確定済みです。この競合の選択として記録され、古いブランチの再アップロードや新しいレコードバージョンの作成は行われません。';

  @override
  String get theCurrentVersionChangedChooseAgain =>
      '現在のバージョンが変更されました。選択し直してください';

  @override
  String get theCurrentVersionIsCommittedWaiting =>
      '現在のバージョンを確定しました。サーバーで競合の解決が確認されるのを待っています。';

  @override
  String get thisWindowHasNoSshLayout => 'このウィンドウには保存できる SSH レイアウトがありません。';

  @override
  String get noAuditRecordsInTheCurrent => '現在の範囲には監査記録がありません';

  @override
  String get yourCurrentRoleCantViewThe => '現在のロールでは保管庫の監査を表示できません';

  @override
  String get restore3 => '復元';

  @override
  String get recoveryKeyDeviceEnvelopesUpdated => '復旧鍵のデバイスエンベロープを更新しました';

  @override
  String get succeeded => '成功';

  @override
  String get memberPermissionsChanged => 'メンバーの権限を変更しました';

  @override
  String get membershipVersion => 'メンバーシップのバージョン';

  @override
  String get memberAccessRevoked => 'メンバーのアクセスを取り消しました';

  @override
  String get memberInvitationAccepted => 'メンバーの招待が承諾されました';

  @override
  String get theSelectedBranchIsCommittedWaiting =>
      '選択したブランチを確定しました。サーバーで競合の解決が確認されるのを待っています。';

  @override
  String get theSelectedVersionIsCommittedWaiting =>
      '選択したバージョンを確定しました。サーバーで競合の解決が確認されるのを待っています。';

  @override
  String get dataAndMigration => 'データと移行';

  @override
  String get files => 'ファイル';

  @override
  String get theHostSpecifiedByTheFile => 'ファイルウィンドウで指定されたホストは利用できません。';

  @override
  String get fileManager => 'ファイル管理';

  @override
  String get passwordsAndKeysForNewHosts2 => '新しいホストのパスワードと鍵はホストの詳細で設定します。';

  @override
  String get newBranchesSyncAutomaticallyWithConflict =>
      '新しいブランチは競合の通知とともに自動で同期されます。上部の「同期」でサーバーの受信トレイを確認することもできます。';

  @override
  String get newLabel => '新規';

  @override
  String newTouppercaseHost(String toUpperCase) {
    return '新しい $toUpperCase ホスト';
  }

  @override
  String get newWindow => '新しいウィンドウ';

  @override
  String get theNewWindowWasntReadyThe =>
      '新しいウィンドウの準備ができませんでした。元の SSH セッションは接続されたままです。';

  @override
  String get theNewWindowWasntReadyThe2 =>
      '新しいウィンドウの準備ができませんでした。リモートデスクトップは現在のウィンドウに残ります。';

  @override
  String couldntLoadTheVaultListError(String error) {
    return '保管庫の一覧を読み込めません：$error';
  }

  @override
  String couldntLoadTheSessionListError(String error) {
    return 'セッション一覧を読み込めません：$error';
  }

  @override
  String get couldntLoadBackupCommandStatus => 'バックアップコマンドの状態を読み込めません';

  @override
  String couldntLoadBackupCommandStatusError(String error) {
    return 'バックアップコマンドの状態を読み込めません：$error';
  }

  @override
  String get couldntLoadInstanceOverview => 'インスタンスの概要を読み込めません';

  @override
  String couldntLoadInstanceOverviewError(String error) {
    return 'インスタンスの概要を読み込めません：$error';
  }

  @override
  String get couldntLoadInstanceAdminAuditRecords => 'インスタンス管理者の監査記録を読み込めません';

  @override
  String couldntLoadInstanceAdminAuditRecords2(String error) {
    return 'インスタンス管理者の監査記録を読み込めません：$error';
  }

  @override
  String get couldntLoadAuditRecords => '監査記録を読み込めません';

  @override
  String get couldntLoadPushServiceStatus => 'プッシュサービスの状態を読み込めません';

  @override
  String couldntLoadPushServiceStatusError(String error) {
    return 'プッシュサービスの状態を読み込めません：$error';
  }

  @override
  String get couldntLoadTheAdminVaultList => '管理者用の保管庫一覧を読み込めません';

  @override
  String get couldntLoadTheAdminAccountList => '管理者用のアカウント一覧を読み込めません';

  @override
  String get couldntLoadTheAccountSessionList => 'アカウントのセッション一覧を読み込めません';

  @override
  String couldntLoadTheAccountListError(String error) {
    return 'アカウント一覧を読み込めません：$error';
  }

  @override
  String get couldntLoadTheAccountInvitationList => 'アカウントの招待一覧を読み込めません';

  @override
  String couldntLoadTheInvitationListError(String error) {
    return '招待一覧を読み込めません：$error';
  }

  @override
  String get couldntOpenTheFileWindow => 'ファイルウィンドウを開けませんでした。';

  @override
  String get couldntSubmitTheEncryptedBackupJob => '暗号化バックアップのジョブを送信できません';

  @override
  String couldntSubmitTheEncryptedBackupJob2(String error) {
    return '暗号化バックアップのジョブを送信できません：$error';
  }

  @override
  String get couldntUpdateTheVaultQuota => '保管庫のクォータを更新できません';

  @override
  String couldntUpdateTheVaultQuotaError(String error) {
    return '保管庫のクォータを更新できません：$error';
  }

  @override
  String get unreadable => '読み取り不可';

  @override
  String get couldntReadOrSubmitInstanceJobs => 'インスタンスのジョブを読み込みまたは送信できませんでした';

  @override
  String couldntReadOrSubmitInstanceJobs2(String error) {
    return 'インスタンスのジョブを読み込みまたは送信できません：$error';
  }

  @override
  String get legacySharedCredentials => '旧形式の共有認証情報';

  @override
  String missingPlural11MonitorWindow(int missing) {
    return '$missing 個のモニターウィンドウを開けませんでした。もう一度選ぶと再試行できます。';
  }

  @override
  String get theServerProvidedASignedCleanup =>
      'サーバーからこのレコードの署名付きクリーンアップ証明が提供されました。ローカルの同期待ちの変更は読み取り専用の下書きとして隔離されています。クリーンアップ済みのレコードを再作成しないよう、ここでは下書きを保持、マージ、アップロードできません。';

  @override
  String get theServerMarksTheCurrentCommitted =>
      'サーバーは現在の確定済みバージョンを保持としてマークし、新しいメインレコードのバージョンは作成しません。デバイス間のブランチは処理済みの履歴として残ります。';

  @override
  String get serverBranch => 'サーバーのブランチ';

  @override
  String get theServerPageContainsSeveralVisible =>
      'サーバーのページには複数の表示範囲が含まれています。現在の範囲のイベントを探すには、ページを進めてください。';

  @override
  String get unknownAction => '不明な操作';

  @override
  String get unknownResult => '不明な結果';

  @override
  String get unknownDevice => '不明なデバイス';

  @override
  String get localStorageNeedsRecoveryReadingEditing =>
      'ローカルストレージの復旧が必要です。読み取り、編集、同期は一時停止しています。すべての Atermius タブを閉じてから開き直すと、最後に保存されたデータが復元されます。';

  @override
  String get notCommittedLocally => 'ローカルで未確定';

  @override
  String get noEventsInThisScopeOn => 'このページにはこの範囲のイベントはありません';

  @override
  String get sourceDevice => '送信元のデバイス';

  @override
  String get viewInstanceAndPushServiceStatus =>
      'インスタンスとプッシュサービスの状態を表示し、監視用の認証情報を管理します。';

  @override
  String get viewTheCurrentAccountDevicesAnd => '現在のアカウント、デバイス、サーバーの情報を表示します。';

  @override
  String get reviewInstanceActionsAndAccessAudit =>
      'インスタンスの操作とアクセスの監査記録を確認します。';

  @override
  String get reviewTrustedHostKeysAndTheir => '信頼済みのホスト鍵とその変更を確認します。';

  @override
  String get refreshCredentialReplayDetectedTheRelated =>
      'リフレッシュ認証情報の再利用を検出したため、関連するセッションを失効させました';

  @override
  String get readingVaultList => '保管庫の一覧を読み込んでいます…';

  @override
  String get readingInstanceJobs => 'インスタンスのジョブを読み込んでいます…';

  @override
  String get readingInstanceOverview => 'インスタンスの概要を読み込んでいます…';

  @override
  String get readingInstanceAdminAuditRecords => 'インスタンス管理者の監査記録を読み込んでいます…';

  @override
  String get readingAuditRecords => '監査記録を読み込んでいます…';

  @override
  String get readingOffSiteBackupStatus => 'オフサイトバックアップの状態を読み込んでいます…';

  @override
  String get readingPushServiceStatus => 'プッシュサービスの状態を読み込んでいます…';

  @override
  String get readingTheLatestBackupCommandStatus =>
      '最新のバックアップコマンドの状態を読み込んでいます…';

  @override
  String get readingAdminAccountList => '管理者用のアカウント一覧を読み込んでいます…';

  @override
  String get thisGroupHasNoConnectableSsh => 'このグループには接続できる SSH ホストがありません。';

  @override
  String get eachGroupLayoutCanConnectUp =>
      '1 つのグループレイアウトで接続できるホストは最大 32 台です。グループを分けてから、もう一度お試しください。';

  @override
  String get noPendingCrossDeviceBranches => '保留中のデバイス間ブランチはありません';

  @override
  String get browseFiles => 'ファイルを参照';

  @override
  String get addGroup => 'グループを追加';

  @override
  String get versionCommittedWaitingForTheServer =>
      'バージョンを確定しました。サーバーでの解決の確認を待っています';

  @override
  String get signInFailed => 'サインインに失敗しました';

  @override
  String get signedIn => 'サインインしました';

  @override
  String get confirmKeptVersion => '保持するバージョンを確定';

  @override
  String get windowSetSavedEncrypted => 'ウィンドウセットを暗号化して保存しました。';

  @override
  String windowSetOpenedCountCount2Sessions(
    int count,
    int count2,
    int failures,
  ) {
    return 'ウィンドウセットで $count/$count2 個のセッションを開きました。$failures 個は接続できませんでした。';
  }

  @override
  String pageValuevalue2(int valueValue) {
    return '$valueValue ページ';
  }

  @override
  String get waitingForThisDeviceToSync => 'このデバイスが選択したバージョンを同期するのを待っています';

  @override
  String get manageTheMasterPasswordTwoFactor =>
      'マスターパスワード、2 要素サインイン、復旧方法、アカウント削除を管理します。';

  @override
  String get manageVaultsMembersAndInvitations => '保管庫、メンバー、招待を管理します。';

  @override
  String get adminBackupFailed => '管理者バックアップが失敗しました';

  @override
  String get adminBackupInterrupted => '管理者バックアップが中断されました';

  @override
  String get adminBackupCompleted => '管理者バックアップが完了しました';

  @override
  String get adminBackupStarted => '管理者バックアップを開始しました';

  @override
  String get anAdministratorDiscardedTheIsolatedRestore =>
      '管理者が隔離された復元用コピーを破棄しました';

  @override
  String get anAdministratorDisabledTheAccount => '管理者がアカウントを無効にしました';

  @override
  String get anAdministratorCreatedAnSshRelay =>
      '管理者が SSH Relay アクセスグループを作成しました';

  @override
  String get anAdministratorDeletedAnSshRelay =>
      '管理者が SSH Relay アクセスグループを削除しました';

  @override
  String get anAdministratorEnabledTheAccount => '管理者がアカウントを有効にしました';

  @override
  String get anAdministratorRevokedThePrometheusScrape =>
      '管理者が Prometheus のスクレイプ認証情報を失効させました';

  @override
  String get anAdministratorRevokedAnAccountSession =>
      '管理者がアカウントのセッションを失効させました';

  @override
  String get anAdministratorRevokedAllOfThe => '管理者がアカウントのすべてのセッションを失効させました';

  @override
  String get anAdministratorChangedSshRelayAccess =>
      '管理者が SSH Relay アクセスグループのメンバーを変更しました';

  @override
  String get anAdministratorChangedTheSshRelay =>
      '管理者が SSH Relay アクセスグループのポリシーを変更しました';

  @override
  String get anAdministratorChangedTheVaultQuota => '管理者が保管庫のクォータを変更しました';

  @override
  String get anAdministratorChangedTheScheduledBackup =>
      '管理者がスケジュールされたバックアップを変更しました';

  @override
  String get anAdministratorUpdatedTheSshRelay => '管理者が SSH Relay のポリシーを更新しました';

  @override
  String get anAdministratorRequestedABackup => '管理者がバックアップをリクエストしました';

  @override
  String get anAdministratorRequestedARestoreJob => '管理者が復元ジョブをリクエストしました';

  @override
  String get anAdministratorRequestedAMaintenanceJob =>
      '管理者がメンテナンスジョブをリクエストしました';

  @override
  String get anAdministratorRotatedThePrometheusScrape =>
      '管理者が Prometheus のスクレイプ認証情報を更新しました';

  @override
  String get anAdministratorRenamedAnSshRelay =>
      '管理者が SSH Relay アクセスグループの名前を変更しました';

  @override
  String get anAdministratorResetTheSshRelay =>
      '管理者が SSH Relay アクセスグループのポリシーをリセットしました';

  @override
  String get adminRestoreJobFailed => '管理者の復元ジョブが失敗しました';

  @override
  String get adminRestoreJobInterrupted => '管理者の復元ジョブが中断されました';

  @override
  String get adminRestoreJobCompleted => '管理者の復元ジョブが完了しました';

  @override
  String get adminRestoreJobStarted => '管理者の復元ジョブを開始しました';

  @override
  String get adminMaintenanceJobFailed => '管理者のメンテナンスジョブが失敗しました';

  @override
  String get adminMaintenanceJobInterrupted => '管理者のメンテナンスジョブが中断されました';

  @override
  String get adminMaintenanceJobCompleted => '管理者のメンテナンスジョブが完了しました';

  @override
  String get adminMaintenanceJobStarted => '管理者のメンテナンスジョブを開始しました';

  @override
  String get adminAccountActionFailed => '管理者のアカウント操作に失敗しました';

  @override
  String get adminAccountInvitationActionFailed => '管理者のアカウント招待操作に失敗しました';

  @override
  String get manageBackupsAndRestoreCopiesAnd =>
      'バックアップと復元用コピーを管理し、インスタンスのメンテナンスジョブを確認します。';

  @override
  String get manageInstanceAccountsInvitationsRelayGroups =>
      'インスタンスのアカウント、招待、リレーグループ、接続ポリシーを管理します。';

  @override
  String get manageNotificationsAndClientUpdates => '通知とクライアントの更新を管理します。';

  @override
  String get theBranchAndTheCurrentRecord =>
      'ブランチと現在のレコードを検証した後、このデバイスで再署名して同期します。元の暗号化ブランチは保持されます。';

  @override
  String get terminal2 => 'ターミナル';

  @override
  String get terminalAndShortcuts => 'ターミナルとショートカット';

  @override
  String get maintenanceJobs => 'メンテナンスジョブ';

  @override
  String get editGroup => 'グループを編集';

  @override
  String get letExternalAiAccessTheCurrent2 => '外部 AI を現在のワークスペースに接続します。';

  @override
  String get theRecordChangedAgainDuringCommit =>
      '確定中にレコードが再度変更されました。現在のバージョンを確認して、選択し直してください。';

  @override
  String get theRecordChangedCheckTheCurrent =>
      'レコードが変更されました。現在のバージョンを確認して、選択し直してください。';

  @override
  String get devices => 'デバイス';

  @override
  String get deviceApproved2 => 'デバイスを承認しました';

  @override
  String get deviceRevoked => 'デバイスを失効させました';

  @override
  String get settings => '設定';

  @override
  String get account2 => 'アカウント';

  @override
  String accountShortauditidDeviceShortauditid2Valuevalue(
    String shortAuditId,
    String shortAuditId2,
    String valueValue,
  ) {
    return 'アカウント $shortAuditId  ·  デバイス $shortAuditId2  ·  $valueValue';
  }

  @override
  String get accountAndDeviceInformation => 'アカウントとデバイスの情報';

  @override
  String get accountsAndAccessPolicies => 'アカウントとアクセスポリシー';

  @override
  String get accountEventsAreStillVisibleOnly =>
      'アカウントのイベントは引き続き表示できます。保管庫の範囲の記録を表示できるのは、この保管庫のオーナーと編集者のみです。';

  @override
  String get accountSessionUnlocked => 'アカウントのセッションのロックを解除しました';

  @override
  String get accountCreated => 'アカウントの作成';

  @override
  String get accountSecurity => 'アカウントのセキュリティ';

  @override
  String get multiFactorAuthenticationWasResetAfter2 =>
      'アカウント復旧後に多要素認証がリセットされました';

  @override
  String get accountRecoveryKeyRotated => 'アカウントの復旧鍵を更新しました';

  @override
  String get accountRecoveryDisabled => 'アカウントの復旧を無効にしました';

  @override
  String get accountRecoveryEnabled => 'アカウントの復旧を有効にしました';

  @override
  String get accountRecoveryCompleted => 'アカウントの復旧が完了しました';

  @override
  String accountActionFailedError(String error) {
    return 'アカウントの操作に失敗しました：$error';
  }

  @override
  String get accountDataCleared => 'アカウントのデータを消去しました';

  @override
  String get accountDeletionCancelled => 'アカウントの削除を取り消しました';

  @override
  String get accountDeletionScheduled => 'アカウントの削除を予約しました';

  @override
  String get crossDeviceConflictInbox => 'デバイス間の競合の受信トレイ';

  @override
  String get theCrossDeviceBranchIsntVerified =>
      'デバイス間のブランチはまだ検証されていないため、操作とサーバーのバージョンの詳細は非表示です。';

  @override
  String get thisDeviceDecryptsTheVerifiedBranch =>
      'このデバイスは検証済みのブランチを復号し、このデバイスの ID で再署名してから、現在キャッシュされているバージョンに対して CAS コミットを実行します。元のブランチの暗号文は保持され、コミットまたはサーバーでの解決が確認されるまで、受信トレイにはこの競合が表示されます。';

  @override
  String get concurrentBranchesSubmittedToTheServer =>
      '他のデバイスがサーバーに送信した同時編集のブランチがここに表示されます。署名、保管庫の所属、鍵の世代が検証された後にのみ選択できます。受信トレイを表示しても現在のレコードは書き換えられません。';

  @override
  String get remoteDesktop2 => 'リモートデスクトップ';

  @override
  String get connect2 => '接続';

  @override
  String get connectEverySshHostInThe => 'グループ内のすべての SSH ホストに接続してレイアウトを復元';

  @override
  String get chooseTheWorkspaceModeAndThe2 => 'ワークスペースモードと既定で開くページを選択します。';

  @override
  String get choiceSavedOnThisDeviceWaiting => '選択はこのデバイスに保存され、同期の確認を待っています。';

  @override
  String get choiceSavedTheInboxUpdatesAfter =>
      '選択を保存しました。受信トレイは次回の同期後に更新されます。';

  @override
  String get choiceSavedEncryptedOnThisDevice =>
      '選択はこのデバイスに暗号化して保存され、同期の確認を待っています。';

  @override
  String get choiceSavedEncryptedOnThisDevice2 =>
      '選択はこのデバイスに暗号化して保存され、同期を待っています。ネットワークが回復したら再試行できます。';

  @override
  String get notificationsAndUpdates => '通知と更新';

  @override
  String invitationActionFailedError(String error) {
    return '招待の操作に失敗しました：$error';
  }

  @override
  String get couldntAdoptTheBranch => 'ブランチを採用できませんでした';

  @override
  String get adoptTheVerifiedDeviceBranch => '検証済みのデバイスのブランチを採用しますか？';

  @override
  String get adoptThisBranch => 'このブランチを採用';

  @override
  String get reSignAndSync => '再署名して同期';

  @override
  String get resetLayout => 'レイアウトをリセット';

  @override
  String get attachments => '添付ファイル';

  @override
  String get needsANewChoice => '再選択が必要です';

  @override
  String get aDeviceKeyPairIsGenerated =>
      'デバイスの鍵ペアはこのブラウザ内でのみ生成・保存されます。公開リクエストを承認済みのデバイスに送ってください。';

  @override
  String get aPrivateSshWorkspaceThatSyncs =>
      '暗号化された接続、認証情報、スニペットをデバイス間で同期するプライベート SSH ワークスペース。';

  @override
  String get aTrustedDeviceSignsEnvelopesFor =>
      '信頼済みのデバイスが新しいデバイスごとにエンベロープに署名します。';

  @override
  String get accountEmail => 'アカウントのメールアドレス';

  @override
  String get accountName => 'アカウント名';

  @override
  String get accountRecoveredSignInWithThe =>
      'アカウントを復旧しました。新しいマスターパスワードでサインインしてください。';

  @override
  String get accountRecoveredSignInWithYour =>
      'アカウントを復旧しました。新しいマスターパスワードでサインインしてください。';

  @override
  String get addThisDevice => 'このデバイスを追加';

  @override
  String get approveEveryDevice => 'すべてのデバイスを承認';

  @override
  String get cancelRecovery => '復旧をキャンセル';

  @override
  String get cancelScheduledAccountDeletion => '予定されたアカウント削除を取り消す';

  @override
  String get cancelSignIn => 'サインインをキャンセル';

  @override
  String get changeServer => 'サーバーを変更';

  @override
  String get commitRecovery => '復旧を確定';

  @override
  String get confirmFingerprintAndContinue => 'フィンガープリントを確認して続行';

  @override
  String get confirmMasterPassword => 'マスターパスワードの確認';

  @override
  String get connectSecurely => '安全に接続';

  @override
  String get connectToYourServer => 'サーバーに接続';

  @override
  String get copyThisEnrollmentJson => 'この登録 JSON をコピー';

  @override
  String get createInvitedAccount => '招待されたアカウントを作成';

  @override
  String get createOwnerAccount => 'オーナーのアカウントを作成';

  @override
  String get deviceName => 'デバイス名';

  @override
  String get emailOnTheInvitation => '招待に記載されたメールアドレス';

  @override
  String get emailOrUsername => 'メールアドレスまたはユーザー名';

  @override
  String get encryptedOutboxKeepsEditsSafeBetween =>
      '暗号化された送信トレイが、接続の合間も編集内容を安全に保持します。';

  @override
  String get endToEndEncryptedVault => 'エンドツーエンド暗号化の保管庫';

  @override
  String get enterAValidRecoveryCodeAnd =>
      '有効な復旧コードと、一致する新しいマスターパスワードを入力してください。';

  @override
  String get enterTheUrlOfYourSelf => 'セルフホストの Atermius インスタンスの URL を入力してください。';

  @override
  String get fingerprintReturnedByThisServerSha =>
      'このサーバーが返したフィンガープリント · SHA-256';

  @override
  String fingerprintReturnedByThisServerSha2(String candidateFingerprint) {
    return 'このサーバーが返したフィンガープリント · SHA-256：$candidateFingerprint';
  }

  @override
  String get firstVault => '最初の保管庫';

  @override
  String get generateRequest => 'リクエストを生成';

  @override
  String get haveAnInstanceInvitationCreateAccount =>
      'インスタンスの招待がありますか？アカウントを作成';

  @override
  String get importApproval => '承認をインポート';

  @override
  String get importApprovedDevice => '承認済みデバイスをインポート';

  @override
  String get importDeviceKeys => 'デバイスの鍵をインポート';

  @override
  String get instanceInvitationToken => 'インスタンスの招待トークン';

  @override
  String get masterPassword => 'マスターパスワード';

  @override
  String get masterPassword12Characters => 'マスターパスワード · 12 文字以上';

  @override
  String newAccountRecoveryCodeCode(String code) {
    return '新しいアカウント復旧コード：$code';
  }

  @override
  String get newDeviceName => '新しいデバイス名';

  @override
  String get newMasterPassword12Characters => '新しいマスターパスワード · 12 文字以上';

  @override
  String get offlineFirstSync => 'オフラインファーストの同期';

  @override
  String get onlyYourUnlockedDevicesCanRead =>
      '保存されたデータを読み取れるのは、ロックを解除したあなたのデバイスだけです。';

  @override
  String get ownerEmail => 'オーナーのメールアドレス';

  @override
  String get pasteApprovalJson => '承認 JSON を貼り付け';

  @override
  String get personalVault => '個人用保管庫';

  @override
  String get previouslyTrustedFingerprintSha256 => '以前に信頼したフィンガープリント · SHA-256';

  @override
  String previouslyTrustedFingerprintSha256Pinnedfingerprint(
    String pinnedFingerprint,
  ) {
    return '以前に信頼したフィンガープリント · SHA-256：$pinnedFingerprint';
  }

  @override
  String get recoverAccount => 'アカウントを復旧';

  @override
  String get recoverAccountWithRecoveryCode => '復旧コードでアカウントを復旧';

  @override
  String get recoveredDevice => '復旧したデバイス';

  @override
  String get recoveryCode => '復旧コード';

  @override
  String get recoveryWasCancelledNoAccountChanges =>
      '復旧をキャンセルしました。アカウントの変更は確定されていません。';

  @override
  String get remoteServersRequireHttpsHttpIs =>
      'リモートサーバーには HTTPS が必要です。HTTP は localhost、127.0.0.1、::1 での開発時のみ使用できます。';

  @override
  String get requestThisDevice => 'このデバイスをリクエスト';

  @override
  String get restoredServerIdentityNeedsConfirmation => '復元されたサーバー ID の確認が必要です';

  @override
  String get retryRecoveryCompletion => '復旧の完了を再試行';

  @override
  String get selfHosted => 'セルフホスト';

  @override
  String get secretsAreEncryptedInThisClient => '秘密情報は同期前にこのクライアントで暗号化されます。';

  @override
  String get serverUrl => 'サーバー URL';

  @override
  String get setUpYourPrivateVault => 'プライベートな保管庫を設定';

  @override
  String get signInAndUnlock => 'サインインしてロック解除';

  @override
  String get storeTheNewRecoveryCode => '新しい復旧コードを保管';

  @override
  String get theBootstrapTokenIsOneUse =>
      'ブートストラップトークンは 1 回限りです。サーバーがマスターパスワードや生成された保管庫の鍵を受け取ることはありません。';

  @override
  String get theFirstAccountCreatesItsVault => '最初のアカウントは、このデバイスで保管庫の鍵を作成します。';

  @override
  String get theServerReturnedADifferentSigning =>
      'サーバーが同じインスタンスに対して異なる署名鍵を返しました。候補のフィンガープリントを、別の経路で管理者または他の信頼済みデバイスと照合してください。確認するまで、アカウントへのサインインや認証リクエストは送信されません。';

  @override
  String get thisOneUseInvitationIsBound =>
      'このワンタイムの招待は上に表示されたメールアドレスに紐付いています。サーバーがマスターパスワードや生成された保管庫の鍵を受け取ることはありません。';

  @override
  String get thisReplacesTheOldCodeStore =>
      '古いコードは置き換えられます。このデバイス以外の場所に保管してください。再表示はできません。';

  @override
  String get typeTheCandidateFingerprintExactly => '候補のフィンガープリントを正確に入力';

  @override
  String get unlockYourWorkspace => 'ワークスペースのロックを解除';

  @override
  String get useARecoveryCode => '復旧コードを使用';

  @override
  String get useAuthenticatorCode => '認証アプリのコードを使用';

  @override
  String get useTheAccountNameAndMaster =>
      'アカウント名とマスターパスワードを使用します。この復旧ではセッションは復元されないため、後でもう一度サインインしてください。';

  @override
  String get useTheSaved256BitRecovery =>
      '保存しておいた 256 ビットの復旧コードを使って保管庫の鍵へのアクセスを復元し、このデバイスを登録します。新しいマスターパスワードを設定してください。サーバーが復旧コードや平文の保管庫鍵を受け取ることはありません。';

  @override
  String get verifyAndUnlock => '確認してロック解除';

  @override
  String get verifyRecoveryCode => '復旧コードを確認';

  @override
  String get verifyYourIdentity => '本人確認';

  @override
  String get yourPasswordUnlocksTheAccountKey => 'パスワードでアカウントの鍵をローカルでロック解除します。';

  @override
  String get yourServersYourKeysYourWorkspace =>
      'あなたのサーバー。\nあなたの鍵。\nあなたのワークスペース。';

  @override
  String get theMasterPasswordsDontMatch => 'マスターパスワードが一致しません';

  @override
  String get couldntCancelAccountDeletion => 'アカウント削除の取り消しに失敗しました';

  @override
  String get couldntConnectToTheServer => 'サーバーに接続できません';

  @override
  String get registrationFailed => '登録に失敗しました';

  @override
  String get requestJsonCopied => 'リクエスト JSON をコピーしました';

  @override
  String get browserStorage => 'ブラウザストレージ';

  @override
  String get checkAgain => '再確認';

  @override
  String get checkingPersistentStorage => '永続ストレージを確認しています…';

  @override
  String get checkingStorageUsageEstimate => 'ストレージ使用量の推定を確認しています…';

  @override
  String estimatedUsageFormatbytesOfFormatbytes2For(
    String formatBytes,
    String formatBytes2,
  ) {
    return 'このサイトの推定使用量：$formatBytes2 中 $formatBytes';
  }

  @override
  String get persistentStorageCanReduceAutomaticEviction =>
      '永続ストレージは自動削除の可能性を減らしますが、バックアップの代わりにはなりません。';

  @override
  String get persistentStorageIsEnabled => '永続ストレージは有効です';

  @override
  String get persistentStorageIsNotEnabled => '永続ストレージは無効です';

  @override
  String get persistentStorageStatusIsUnavailable => '永続ストレージの状態を利用できません';

  @override
  String get requestPersistentStorage => '永続ストレージをリクエスト';

  @override
  String get storageUsageEstimateIsUnavailable => 'ストレージ使用量の推定を利用できません';

  @override
  String get theBrowserCouldNotConfirmPersistent =>
      'ブラウザで永続ストレージの状態を確認できませんでした。';

  @override
  String get theBrowserCurrentlyReportsPersistentStorage =>
      'ブラウザは現在、永続ストレージが有効であると報告しています。';

  @override
  String get theBrowserDidNotEnablePersistent => 'ブラウザは永続ストレージを有効にしませんでした。';

  @override
  String get theRequestReturnedSuccessButThe =>
      'リクエストは成功しましたが、ブラウザは引き続きストレージが永続的ではないと報告しています。';

  @override
  String get theRequestReturnedSuccessButThe2 =>
      'リクエストは成功しましたが、現在の永続化の状態を確認できませんでした。';

  @override
  String pendingcountEncryptedChangeSAreWaiting(int pendingCount) {
    return '$pendingCount 件の暗号化された変更がこのブラウザのローカル送信トレイで待機しています。サーバーはまだ受信を確認していません。同期前にこのサイトのブラウザデータを消去すると、これらの変更はこのブラウザから削除されます。';
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
  String get fileWorkspaceIsClosed => 'ファイルのワークスペースは閉じられています。';

  @override
  String get theSavedGroupLayoutIsInvalid =>
      '保存されたグループレイアウトが無効です。レイアウトをリセットしてから、もう一度お試しください。';

  @override
  String get invalidGroupSessionMapping => 'グループセッションの対応付けが無効です。';

  @override
  String get aGroupLayoutNeeds1To => 'グループレイアウトには 1〜32 台の SSH ホストが必要です。';

  @override
  String get invalidLayoutHostsOrMoreThan => 'レイアウトのホストが無効か、ペインが 32 を超えています。';

  @override
  String get invalidLayoutRatio => 'レイアウトの比率が無効です。';

  @override
  String get thisWindowHasNoSshSessions => 'このウィンドウにはこのグループの SSH セッションがありません。';

  @override
  String get upTo32PanesCanBe => '保存できるペインは最大 32 個です。';

  @override
  String get attachFile => 'ファイルを添付';

  @override
  String get attachmentDownload => '添付ファイルのダウンロード';

  @override
  String get attachmentUpload => '添付ファイルのアップロード';

  @override
  String attachmentsName(String name) {
    return '添付ファイル · $name';
  }

  @override
  String get cancel2 => 'キャンセル';

  @override
  String get chooseAFileToAttach => '添付するファイルを選択…';

  @override
  String get close => '閉じる';

  @override
  String get discardDownloadedCopy => 'ダウンロード済みのコピーを破棄';

  @override
  String get discardOrphanTransfer => '孤立した転送を破棄';

  @override
  String get downloadAttachment => '添付ファイルをダウンロード';

  @override
  String downloadUnavailableAboveFormatsize(String formatSize) {
    return '$formatSize を超えるとダウンロードできません';
  }

  @override
  String get downloadingAndVerifyingAttachment => '添付ファイルをダウンロードして検証しています…';

  @override
  String get encryptingAndTransferring => '暗号化して転送しています…';

  @override
  String get filesAreEncryptedOnThisDevice =>
      'ファイルはアップロード前にこのデバイスで暗号化されます。名前、種類、ファイル鍵、内容はすべて暗号化されたホストレコード内に保持されます。';

  @override
  String get noAttachmentsSavedForThisHost => 'このホストには添付ファイルが保存されていません。';

  @override
  String get preparingAttachment => '添付ファイルを準備しています…';

  @override
  String get removeAttachment => '添付ファイルを削除';

  @override
  String get removeAttachmentFromThisHost => 'このホストから添付ファイルを削除しますか？';

  @override
  String get removeFromHost => 'ホストから削除';

  @override
  String removeFilenameFromTheCurrentEncrypted(String fileName) {
    return '現在の暗号化ホストレコードから $fileName を削除しますか？サーバーの保持期間によるクリーンアップまでは、以前のホストのリビジョンに添付ファイルの参照が残る場合があります。';
  }

  @override
  String get removingAttachment => '添付ファイルを削除しています…';

  @override
  String get resumeDownload => 'ダウンロードを再開';

  @override
  String get resumeUpload => 'アップロードを再開';

  @override
  String get resumingEncryptedUpload => '暗号化アップロードを再開しています…';

  @override
  String get saveCancelled => '保存をキャンセルしました。';

  @override
  String get saveCancelledTheVerifiedEncryptedDownload =>
      '保存をキャンセルしました。検証済みの暗号化ダウンロードは再試行のために保持されます。';

  @override
  String get savingDecryptedAttachment => '復号した添付ファイルを保存しています…';

  @override
  String get thisFileCannotBeLoadedInto =>
      'このファイルをクライアントのメモリに読み込めません。小さいファイルでお試しください。';

  @override
  String get transferTasks => '転送タスク';

  @override
  String valuevalueMoreTasks(int valueValue) {
    return 'ほか $valueValue 件のタスク';
  }

  @override
  String get addAHost => 'ホストを追加';

  @override
  String get authentication => '認証';

  @override
  String get directConnection => '直接接続';

  @override
  String get displayName => '表示名';

  @override
  String get editHost => 'ホストを編集';

  @override
  String get editPrivateKey => '秘密鍵を編集';

  @override
  String get group => 'グループ';

  @override
  String get hidePrivateKey => '秘密鍵を隠す';

  @override
  String get hostnameOrIp => 'ホスト名または IP';

  @override
  String get jumpHost => '踏み台ホスト';

  @override
  String get loginDetailsBelongToThisHost => 'サインイン情報はこのホストに属し、ホストとともに暗号化されます。';

  @override
  String get noGroup => 'グループなし';

  @override
  String get noKeyEntered => '鍵が入力されていません';

  @override
  String get pinTheCertificateFingerprintSuppliedBy =>
      '管理者から提供された証明書のフィンガープリントを固定します。';

  @override
  String get rdpCertificateSha256Optional => 'RDP 証明書の SHA-256（任意）';

  @override
  String get routeThroughUpTo8Hosts => 'このホストを開く前に、最大 8 台のホストを経由します。';

  @override
  String get saveEncryptedHost => '暗号化ホストを保存';

  @override
  String get separateTagsWithCommas => 'タグはカンマで区切ります。';

  @override
  String get tags => 'タグ';

  @override
  String get thisSavedGroupIsUnavailableChoose =>
      '保存されたグループは利用できません。「グループなし」を選択してクリアしてください。';

  @override
  String get thisSavedJumpHostIsUnavailable =>
      '保存された踏み台ホストが利用できないか、循環しているか、8 ホップを超えています。「直接接続」または有効なホストを選択して修復してください。';

  @override
  String get unavailableJumpHost => '利用できない踏み台ホスト';

  @override
  String get signInDetailsAreStoredEncrypted =>
      'サインイン情報は暗号化して保存されます。接続時は、信頼済みのリモートデスクトップゲートウェイがサインイン資格情報と画面を処理します。';

  @override
  String get directDesktopSignInHint =>
      'サインイン情報は暗号化して保存されます。このデバイスはホストに直接接続し、その接続にのみ使用します。ゲートウェイは経由しません。';

  @override
  String labelPressEnterToConnect(String label) {
    return '$label  ·  Enter で接続';
  }

  @override
  String get searchHostsOrTypeAnSsh =>
      'ホストを検索、または ssh / rdp / vnc / console コマンドを入力';

  @override
  String get clearSearch => '検索をクリア';

  @override
  String get chooseAHostToConnectTo => '接続するホストを選択';

  @override
  String countHosts2(int count) {
    return '$count 台のホスト';
  }

  @override
  String get all => 'すべて';

  @override
  String get closeSearch => '検索を閉じる';

  @override
  String get allGroups => 'すべてのグループ';

  @override
  String get filterByGroup => 'グループで絞り込み';

  @override
  String get searchAndQuickConnect => '検索とクイック接続';

  @override
  String get favorites => 'お気に入り';

  @override
  String get noMatchingHostsTypeAnSsh =>
      '一致するホストはありません。ssh / rdp / vnc コマンドを入力すると新しいアドレスに接続できます。';

  @override
  String get operatingSystemNotIdentifiedYet => 'OS はまだ識別されていません';

  @override
  String operatingSystemLabel(String label) {
    return 'OS：$label';
  }

  @override
  String get originalSshSessionConnected => '元の SSH セッション · 接続済み';

  @override
  String get tools => '機能';

  @override
  String get originalSshSessionLive => '元の SSH セッション · ライブ接続';

  @override
  String get filesSftpScp => 'ファイル · SFTP / SCP';

  @override
  String get couldntOpenTheTerminalWindowGo =>
      'ターミナルウィンドウを開けませんでした。メインウィンドウに戻って接続を確認してください。';

  @override
  String get thisWindowKeepsUsingTheOriginal =>
      'このウィンドウは元の SSH セッションを引き続き使用します。';

  @override
  String get terminalProperties => 'ターミナルのプロパティ';

  @override
  String get earlierOutputExceedsThisWindowsDisplay =>
      '以前の出力はこのウィンドウの表示上限を超えています。実行中のコマンドには影響しません。';

  @override
  String get connectionLostReturnToTheOriginal =>
      '接続が切断されました · 元のウィンドウに戻ってください';

  @override
  String get connectionLost => '接続が切断されました';

  @override
  String get sshOutputStreamError => '\n[SSH 出力ストリームのエラー]\n';

  @override
  String get sshConnectionClosed => '\n[SSH 接続が閉じられました]\n';

  @override
  String get sshErrorStreamUnavailable => '\n[SSH エラーストリームを利用できません]\n';

  @override
  String get anotherOperationIsRunningRetryWhen =>
      '別の操作が実行中です。終了してから再試行してください。';

  @override
  String get bashInputHistory => 'Bash の入力履歴';

  @override
  String get console => 'コンソール';

  @override
  String get couldNotSaveForwardingSettingsNothing =>
      '転送の設定を保存できませんでした。変更は行われていません。';

  @override
  String get home => 'ホーム';

  @override
  String hostHostid(String hostId) {
    return 'ホスト $hostId';
  }

  @override
  String get theHostSaveResultCouldntBe =>
      'ホストの保存結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get theHostWasSavedButThe =>
      'ホストは保存されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theHostWasDeletedButThe =>
      'ホストは削除されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theHostWasChangedByAnother =>
      'ホストは別の操作で変更されています。開き直してから、もう一度お試しください。';

  @override
  String get theHostWasUpdatedButThe =>
      'ホストは更新されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get hostActions => 'ホストの操作';

  @override
  String get whenAHostDoesntSelectA =>
      'ホストで認証情報を明示的に選択していない場合は、最も近い祖先グループの既定の認証情報が使われます。';

  @override
  String get localHostRevisionIsMissing => 'ローカルのホストのリビジョンがありません。';

  @override
  String get localDefaultWorkspacePreferenceIsInvalid =>
      'ローカルの既定のワークスペースの設定が無効です。';

  @override
  String get localProfileCleanupFailed => 'ローカルプロファイルのクリーンアップに失敗しました。';

  @override
  String get localvaultHostKeyTrust => 'LocalVault のホスト鍵の信頼';

  @override
  String get noLocalProfile => 'ローカルプロファイルがありません。';

  @override
  String get notStartedFromASingleConnected =>
      '接続済みの単一の SSH タブから開始されていません。ここでプロファイルを編集し、接続済みのタブで SSH ポートフォワーディングを使って開始してください。';

  @override
  String get preferencesCannotBeTheDefaultWorkspace =>
      '設定を既定のワークスペースにすることはできません。';

  @override
  String get profilesAreEncryptedInsideThisHost2 =>
      'プロファイルは、このデバイスのローカルプロファイルにあるホストのレコード内で暗号化されます。実行状態とソケットは保存されません。';

  @override
  String get protectedDeviceKeyUnavailable => '保護されたデバイスの鍵を利用できません。';

  @override
  String get theSshHostKeyChangedOr =>
      'SSH ホスト鍵が変更されたか、信頼レコードが競合しているため、接続を拒否しました。先に古い信頼を確認して取り消してください。';

  @override
  String get theSshHostKeyWasntApproved => 'SSH ホスト鍵が承認されなかったため、接続を拒否しました。';

  @override
  String get sshPrivateKey => 'SSH 秘密鍵';

  @override
  String get sshPortForwarding2 => 'SSH ポートフォワーディング';

  @override
  String get shellLabel => 'シェルのラベル';

  @override
  String get snippetChanged => 'スニペットが変更されました';

  @override
  String get theLocalProfileChanged => 'ローカルプロファイルが変更されました。';

  @override
  String get thisHostChangedInAnotherOperation =>
      'このホストは別の操作で変更されました。一覧を更新しました。確認してから再試行してください。';

  @override
  String get webLocalvaultDoesntSupportSshSftp =>
      'Web 版 LocalVault は SSH / SFTP にまだ対応していません';

  @override
  String algorithmFingerprintOriginallyApprovedInArchive(
    String algorithm,
    String fingerprint,
    DateTime toLocal,
  ) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$algorithm\n$fingerprint\nアーカイブでの元の承認：$toLocalString';
  }

  @override
  String groupparentlabelHostscountHostsChildrencountSubgroups(
    String groupParentLabel,
    int hostsCount,
    int childrenCount,
  ) {
    return '$groupParentLabel · ホスト $hostsCount 台 · サブグループ $childrenCount 個';
  }

  @override
  String hostPortPendingReview(String host, int port) {
    return '$host:$port · 確認待ち';
  }

  @override
  String nameWillBeDeletedFromThis(String name) {
    return '「$name」はこのローカルプロファイルから削除されます。';
  }

  @override
  String titleWillBeDeletedFromThis(String title) {
    return '「$title」はこのローカルプロファイルから削除されます。';
  }

  @override
  String get previousMatch2 => '前の一致';

  @override
  String get nextMatch2 => '次の一致';

  @override
  String get noDefaultCredential => '既定の認証情報なし';

  @override
  String get theLocalArchivePassphrasesDontMatch => 'ローカルアーカイブのパスフレーズが一致しません。';

  @override
  String theMasterPasswordMustBeAt(int minimumPasswordLength) {
    return 'マスターパスワードは $minimumPasswordLength 文字以上にしてください。';
  }

  @override
  String get masterPasswordAtLeast12Characters => 'マスターパスワード（12 文字以上）';

  @override
  String get hostsAndSignInDetailsAre => 'ホストとサインイン情報はローカルプロファイルに保存されます';

  @override
  String get couldntSaveTheHostCheckThe =>
      'ホストを保存できませんでした。設定を確認してから、もう一度お試しください。';

  @override
  String get useTheModAltAndShift =>
      '修飾キーには mod、alt、shift を使います。mod は Apple プラットフォームでは Command、その他では Control を表します。各ショートカットは重複できず、ブラウザや OS が予約している組み合わせは使用できません。';

  @override
  String get saveGroup => 'グループを保存';

  @override
  String get saveEncryptedCredential => '暗号化した認証情報を保存';

  @override
  String get saveEncryptedSnippet => '暗号化スニペットを保存';

  @override
  String get saveShortcuts => 'ショートカットを保存';

  @override
  String get theSavedGroupLayoutIsInvalid2 =>
      '保存されたグループレイアウトが無効です。先にレイアウトをリセットしてください。';

  @override
  String get saveTerminalTheme => 'ターミナルのテーマを保存';

  @override
  String get saveTerminalFontSize => 'ターミナルのフォントサイズを保存';

  @override
  String get saveDefaultWorkspace => '既定のワークスペースを保存';

  @override
  String get trustReviewFailedTheExistingSsh =>
      '信頼の再確認に失敗しました。既存の SSH 信頼状態は変更されていません。再読み込みして確認してください。';

  @override
  String get thePreferenceSaveResultCouldntBe =>
      '設定の保存結果を確認できませんでした。再読み込みしてから、保存し直すかどうかを判断してください。';

  @override
  String get preferencesSavedAndApplied => '設定を保存して適用しました。';

  @override
  String get preferencesAreSavedEncryptedInThis =>
      '設定はこのローカルプロファイルに暗号化して保存されています。';

  @override
  String get preferencesWereChangedByAnotherOperation =>
      '設定は別の操作で変更されたため、現在の値を再読み込みしました。確認してから保存してください。';

  @override
  String get stopConnecting => '接続を中止';

  @override
  String get stopCapture => '取得を停止';

  @override
  String get otherLocalRecords => 'その他のローカルレコード';

  @override
  String get credentials => '認証情報';

  @override
  String get theCredentialSaveResultCouldntBe =>
      '認証情報の保存結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get theCredentialDeletionResultCouldntBe =>
      '認証情報の削除結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String credentialParameterNameMustReferenceA(String name) {
    return '認証情報パラメーター $name は、このローカルプロファイル内のパスワード認証情報を参照する必要があります。';
  }

  @override
  String get credentialName => '認証情報の名前';

  @override
  String get theCredentialNoLongerExistsRefresh => '認証情報はもう存在しません。一覧を更新してください。';

  @override
  String get theCredentialWasSavedButThe =>
      '認証情報は保存されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theCredentialWasDeletedButThe =>
      '認証情報は削除されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theCredentialWasChangedByAnother =>
      '認証情報は別の操作で変更されています。一覧を更新してから、もう一度お試しください。';

  @override
  String get theCredentialWasUpdatedButThe =>
      '認証情報は更新されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get credentialActions => '認証情報の操作';

  @override
  String get theCredentialUpdateResultCouldntBe =>
      '認証情報の更新結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get setTheTerminalFontSizeColors =>
      'ターミナルのフォントサイズ、配色、ショートカットを個別に設定します。';

  @override
  String groupGroupid(String groupId) {
    return 'グループ $groupId';
  }

  @override
  String groupName(String name) {
    return 'グループ「$name」';
  }

  @override
  String get theGroupIsStillUsedBy =>
      'このグループはまだサブグループまたはホストで使われています。それらを移動または削除してから、このグループを削除してください。';

  @override
  String get theGroupSaveResultCouldntBe =>
      'グループの保存結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get theGroupDeletionResultCouldntBe =>
      'グループの削除結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get groupName2 => 'グループ名';

  @override
  String get theGroupWasSavedButThe =>
      'グループは保存されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theGroupWasDeletedButThe =>
      'グループは削除されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theGroupChangedRefreshAndSave =>
      'グループが変更されました。更新してからレイアウトを保存し直してください。';

  @override
  String get theGroupWasChangedByAnother =>
      'グループは別の操作で変更されています。一覧を更新してから、もう一度お試しください。';

  @override
  String get theGroupWasChangedByAnother2 =>
      'グループは別の操作で変更されています。開き直してから、もう一度お試しください。';

  @override
  String get theGroupWasUpdatedButThe =>
      'グループは更新されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String groupActionsName(String name) {
    return 'グループの操作：$name';
  }

  @override
  String get theGroupUpdateResultCouldntBe =>
      'グループの更新結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get groupWindowLayoutSaved => 'グループのウィンドウレイアウトを保存しました。';

  @override
  String get theGroupRecordWasChangedBy =>
      'グループレコードは別の操作で変更されています。一覧を更新してから、もう一度お試しください。';

  @override
  String get listView => 'リスト表示';

  @override
  String get afterCreatingALocalProfileYou =>
      'ローカルプロファイルを作成すると、ホストとサインイン用の認証情報をこのデバイスに暗号化して保存できます。';

  @override
  String createdFormatdate(String formatDate) {
    return '作成日：$formatDate';
  }

  @override
  String get createGroupsToOrganizeHostsGroups =>
      'グループを作成してホストを整理します。グループと親子関係はこのローカルプロファイルにのみ保存されます。';

  @override
  String get createAndUnlock => '作成してロック解除';

  @override
  String get createNewProfile => '新しいプロファイルを作成';

  @override
  String get couldntDeleteTheHostTryAgain => 'ホストを削除できませんでした。もう一度お試しください。';

  @override
  String get deleteHost => 'ホストを削除しますか？';

  @override
  String get deleteCredential => '認証情報を削除';

  @override
  String get deleteCredential2 => '認証情報を削除しますか？';

  @override
  String get deleteGroup => 'グループを削除';

  @override
  String get deleteGroup2 => 'グループを削除しますか？';

  @override
  String get deleteSnippet => 'スニペットを削除';

  @override
  String get deleteSnippet2 => 'スニペットを削除しますか？';

  @override
  String get couldntSaveHistoryCommandsInMemory =>
      '履歴を保存できませんでした。今回はメモリ上のコマンドを引き続き表示できます。ローカルストレージを確認してください。';

  @override
  String get previousParentUnavailable => '以前の親は利用できません';

  @override
  String get previousDefaultCredentialUnavailable => '以前の既定の認証情報は利用できません';

  @override
  String get argumentList => '引数リスト';

  @override
  String get parameterDefinitions => 'パラメーター定義';

  @override
  String get parameterDefinitionsJsonArray => 'パラメーター定義（JSON 配列）';

  @override
  String get argumentsJsonArray => '引数（JSON 配列）';

  @override
  String windowfailuresPlural11MoreWindow(int windowFailures) {
    return 'ほかに $windowFailures 個のウィンドウまたは位置を復元できませんでした。';
  }

  @override
  String onlyContinueAfterVerifyingTheFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
  ) {
    return '信頼できる経路でフィンガープリントを照合した場合にのみ続行してください。確認すると、このデバイスは次のエンドポイントに対する新しいローカルの信頼レコードを作成します：\n\n$host:$port\n$algorithm\n$fingerprint\n\nアーカイブ内の古い承認だけでは接続は許可されません。';
  }

  @override
  String get afterEnablingCopyTheSetupCommand =>
      '有効にした後、設定コマンドをコピーして現在の Bash に貼り付け、Enter を押してください。記録されるのは完了したコマンドだけで、パスワード入力プロンプトでの入力は取得されませんが、コマンドに含まれる秘密情報は記録される場合があります。履歴はこのデバイスのプロファイルに暗号化して保存され、ホストごとに最大 500 件 / 48 KiB です。取得を停止した後、Bash で atermius_off を実行するとフックを削除できます。';

  @override
  String get enableAndCopySetupCommand => '有効にして設定コマンドをコピー';

  @override
  String get completedCommandsAreRecordedAfterEnabling =>
      '「記録の設定」で Bash 連携を有効にすると、完了したコマンドが記録されます。';

  @override
  String get reviewAndTrust => '確認して信頼';

  @override
  String get reviewSshHostKeysFromThe => 'アーカイブ内の SSH ホスト鍵を確認';

  @override
  String get wrongPasswordOrTheLocalProfile =>
      'パスワードが間違っているか、ローカルプロファイルのロックを解除できません。';

  @override
  String get importLocalEncryptedArchive => 'ローカルの暗号化アーカイブをインポート';

  @override
  String get exportLocalEncryptedArchive => 'ローカルの暗号化アーカイブをエクスポート';

  @override
  String get trusted => '信頼済み';

  @override
  String get savingTheLocalEncryptedArchiveWas => 'ローカルの暗号化アーカイブの保存をキャンセルしました。';

  @override
  String get bashRecordingIsOnClickTo => 'Bash の記録が有効です。クリックで入力し、Enter で実行します。';

  @override
  String get revoked => '失効済み';

  @override
  String get disconnected => '切断済み';

  @override
  String get theArchiveWasImportedButSome =>
      'アーカイブはインポートされましたが、一部の一覧を更新できませんでした。プロファイルを再読み込みしてください。';

  @override
  String get thereAreTooManySplitsTo => '分割が多すぎるため、このグループレイアウトを保存できません。';

  @override
  String get thisWindowHasNoSessionLayout =>
      'このウィンドウにはこのグループのセッションレイアウトがありません。';

  @override
  String get invalidShortcutUseSupportedLetterDigit =>
      'ショートカットが無効です。対応している英字、数字、F1〜F12 の組み合わせを使い、すべての組み合わせが重複しないようにしてください。';

  @override
  String get aShortcutIsInvalidOrDuplicated =>
      'ショートカットの形式が無効か、重複しています。修正してから保存してください。';

  @override
  String get restoreDefaultShortcuts => '既定のショートカットに戻す';

  @override
  String get theSelectedParentGroupNoLonger =>
      '選択した親グループはもう存在しません。一覧を更新してから、もう一度お試しください。';

  @override
  String get openLocalWorkspace => 'ローカルワークスペースを開く';

  @override
  String get executionType => '実行の種類';

  @override
  String get reject => '拒否';

  @override
  String get searchTerminal => 'ターミナルを検索';

  @override
  String get searchTerminalHistory => 'ターミナルの履歴を検索';

  @override
  String get revokeSshHostKeyTrust => 'SSH ホスト鍵の信頼を取り消しますか？';

  @override
  String afterRevokingThisKeyForHost(String host, int port) {
    return '$host:$port のこの鍵を失効させると、以降の接続では再度確認して明示的に承認する必要があります。';
  }

  @override
  String get revokeTrust => '信頼を取り消す';

  @override
  String get revokingFailedTheTrustStateIs =>
      '失効に失敗しました。信頼状態は変更されていません。もう一度お試しください。';

  @override
  String get revokeTrustForThisKey => 'この鍵の信頼を取り消す';

  @override
  String get theFileWindowDidntOpenTry => 'ファイルウィンドウを開けませんでした。もう一度お試しください。';

  @override
  String get theHostRequestedByTheFile => 'ファイルウィンドウが要求したホストは存在しません。';

  @override
  String get theLocalProfileRequestedByThe =>
      'ファイルウィンドウが要求したローカルプロファイルは存在しません。';

  @override
  String get textParametersAndPasswordCredentialReferences =>
      'テキストパラメーターとパスワード認証情報の参照は、サーバーのスニペットと同じ構造です。本文と既定値はすべて暗号化されます。';

  @override
  String get disconnectCurrentTerminal => '現在のターミナルを切断';

  @override
  String get disconnect => '切断';

  @override
  String get passwordsAndKeysForNewHosts => '新しいホストのパスワードと鍵は、ホストの詳細で直接設定します。';

  @override
  String get newGroup => '新しいグループ';

  @override
  String get theNewWindowDidntOpenThe =>
      '新しいウィンドウを開けませんでした。セッションは現在のウィンドウに残ります。';

  @override
  String get theNewWindowDidntOpenThe2 =>
      '新しいウィンドウを開けませんでした。リモートデスクトップは現在のウィンドウに残ります。';

  @override
  String get couldntSaveTheGroupLayoutTry =>
      'グループレイアウトを保存できませんでした。もう一度お試しください。';

  @override
  String get couldntSaveTheWindowSetCheck =>
      'ウィンドウセットを保存できませんでした。名前とセッション数を確認するか、再度ロックを解除してから再試行してください。';

  @override
  String get couldntCreateTheLocalProfileTry =>
      'ローカルプロファイルを作成できませんでした。もう一度お試しください。';

  @override
  String get couldntDeleteTheWindowSet => 'ウィンドウセットを削除できませんでした。';

  @override
  String get couldntRefreshTheHostListThe =>
      'ホストの一覧を更新できませんでした。書き込みは確定している可能性があるため、再読み込みしてから操作してください。';

  @override
  String get couldntRefreshTheLocalCredentialList =>
      'ローカルの認証情報一覧を更新できませんでした。書き込みは確定している可能性があるため、再読み込みしてから操作してください。';

  @override
  String get couldntRefreshTheLocalGroupList =>
      'ローカルのグループ一覧を更新できませんでした。書き込みは確定している可能性があるため、再読み込みしてから操作してください。';

  @override
  String get couldntRefreshTheLocalSnippetList =>
      'ローカルのスニペット一覧を更新できませんでした。書き込みは確定している可能性があるため、再読み込みしてから操作してください。';

  @override
  String get couldntStartTheConsole => 'コンソールを起動できませんでした。';

  @override
  String get couldntSafelySaveTheDeviceUnlock =>
      'デバイスのロック解除キーを安全に保存できませんでした。システムのセキュアストレージを確認して再試行するか、パスワードで保護されたプロファイルを手動で作成してください。';

  @override
  String get couldntExitTheLocalProfileSafely =>
      'ローカルプロファイルを安全に終了できませんでした。もう一度お試しください。';

  @override
  String get couldntImportTheLocalArchiveNothing =>
      'ローカルアーカイブをインポートできませんでした。移行先のプロファイルには何も書き込まれていません。';

  @override
  String get couldntExportTheLocalProfileTry =>
      'ローカルプロファイルをエクスポートできませんでした。もう一度お試しください。ローカルデータは変更されていません。';

  @override
  String get couldntOpenANewWindowTry => '新しいウィンドウを開けませんでした。もう一度お試しください。';

  @override
  String get couldntOpenTheWindowSet => 'ウィンドウセットを開けませんでした。';

  @override
  String get couldntOpenTheRequestedFileWindow =>
      '要求されたファイルウィンドウを開けませんでした。接続とホスト鍵の信頼を確認してください。';

  @override
  String get couldntConfirmThatTheTargetProfile =>
      '移行先のプロファイルが空であることを確認できませんでした。もう一度お試しください。';

  @override
  String get couldntReadLocalSshHostKey => 'ローカルの SSH ホスト鍵の信頼情報を読み込めませんでした。';

  @override
  String get couldntReadLocalPreferencesTheSave =>
      'ローカルの設定を読み込めませんでした。保存は確定している可能性があるため、再読み込みしてから操作してください。';

  @override
  String get couldntReadLocalPreferencesYouCan =>
      'ローカルの設定を読み込めませんでした。設定ページで再試行できます。';

  @override
  String get couldntReadTheLocalCredentialList =>
      'ローカルの認証情報一覧を読み込めませんでした。認証情報ページで再試行できます。';

  @override
  String get couldntReadTheLocalGroupList =>
      'ローカルのグループ一覧を読み込めませんでした。グループページで再試行できます。';

  @override
  String get couldntReadTheLocalArchiveFile =>
      'ローカルアーカイブファイルを読み込めませんでした。もう一度お試しください。';

  @override
  String get couldntReadTheLocalSnippetList =>
      'ローカルのスニペット一覧を読み込めませんでした。スニペットページで再試行できます。';

  @override
  String get couldntReadTheLocalProfileList2 =>
      'ローカルプロファイルの一覧を読み込めませんでした。再試行してからプロファイルを作成してください。';

  @override
  String get couldntReadThisHostsSignIn => 'このホストのサインイン情報を読み込めませんでした。';

  @override
  String get couldntConnectToTheLocalSsh =>
      'ローカルの SSH ホストに接続できませんでした。ネットワークと認証情報を確認してから、もう一度お試しください。';

  @override
  String get showKey => '鍵を表示';

  @override
  String get couldntUpdateTheHostTryAgain => 'ホストを更新できませんでした。もう一度お試しください。';

  @override
  String valuevaluePlural11MonitorWindow(int valueValue) {
    return '$valueValue 個のモニターウィンドウを開けませんでした。もう一度選ぶと再試行できます。';
  }

  @override
  String get localUnlocked => 'ローカル · ロック解除済み';

  @override
  String get localLocked => 'ローカル · ロック中';

  @override
  String get localEncryptedArchiveSaved => 'ローカルの暗号化アーカイブを保存しました。';

  @override
  String get theLocalEncryptedArchiveWasImported =>
      'ローカルの暗号化アーカイブをインポートしました。アーカイブ内の有効な SSH ホスト鍵は「ホスト鍵の信頼」で 1 件ずつ確認する必要があります。';

  @override
  String get localArchivePassphrase => 'ローカルアーカイブのパスフレーズ';

  @override
  String get theLocalArchivePassphraseCanBe =>
      'ローカルアーカイブのパスフレーズは最大 1024 UTF-8 バイトです。';

  @override
  String get theLocalArchiveFileIsInvalid => 'ローカルアーカイブファイルが無効か、サイズ上限を超えています。';

  @override
  String get theLocalArchiveFileExceedsThe => 'ローカルアーカイブファイルがサイズ上限を超えています。';

  @override
  String get localModeOnlyManagesEncryptedSnippets =>
      'ローカルモードでは暗号化スニペットの管理のみ行えます。ホストに接続してスニペットを実行するには、サーバー同期モードに切り替えてください。';

  @override
  String get localProfile2 => 'ローカルプロファイル';

  @override
  String localProfileSubstring2(String substring) {
    return 'ローカルプロファイル · $substring';
  }

  @override
  String get localProfileMasterPassword => 'ローカルプロファイルのマスターパスワード';

  @override
  String get localProfileDataIsMissingOr =>
      'ローカルプロファイルのデータが見つからないか、読み込めません。空のデータベースが有効なプロファイルとして扱われないよう、ロック解除をブロックしました。ローカルデータを復元するか、バックアップを使用してください。';

  @override
  String get tagsCommaSeparated => 'タグ（カンマ区切り）';

  @override
  String get verifyAndTrustThisKey => 'この鍵を確認して信頼';

  @override
  String get thisLocalvaultSshRouteIsntSupported =>
      'この LocalVault の SSH 経路には対応していません。';

  @override
  String get thisLocalvaultHasNoSshHost =>
      'この LocalVault にはまだ SSH ホスト鍵の信頼レコードがありません。';

  @override
  String get thisHostKeyWasRevokedBefore => 'このホスト鍵は以前に失効しています';

  @override
  String thisCredentialIsStillReferencedBy(String credentialReferenceLabel) {
    return 'この認証情報はまだ$credentialReferenceLabelから参照されています。参照を変更または削除してから削除してください。';
  }

  @override
  String get thisGroupDoesntHaveAnyConnectable =>
      'このグループにはまだ接続できる SSH ホストがありません。';

  @override
  String get thisPassphraseIsSeparateFromThe =>
      'このパスフレーズはローカルプロファイルのマスターパスワードとは別のものです。別途保管してください。アーカイブの内容は Argon2id と XChaCha20-Poly1305 で暗号化されます。';

  @override
  String get thisWorkspaceIsProtectedByThe =>
      'このワークスペースは OS アカウントのセキュアストレージで保護されています。ロックすると現在のセッションが閉じます。';

  @override
  String get thisConsoleIsntSupportedOnThis => 'このプラットフォームではこのコンソールに対応していません。';

  @override
  String get eachLayoutCanHaveUpTo =>
      '1 つのレイアウトに含められる SSH ホストは最大 32 台です。サブグループに分けてください。';

  @override
  String get noMatchingHosts => '一致するホストはありません';

  @override
  String get localvaultInTheBrowserCanManage =>
      'ブラウザの LocalVault ではホストと認証情報をローカルで暗号化して管理できますが、ここから SSH や SFTP 接続を確立することはできません。ワークスペースの選択に戻ってサーバーワークスペースに入ると、Web Relay 経由で同期保管庫のホストに接続できます。';

  @override
  String get addHostDetailsToStoreThem =>
      'ホストの情報を追加すると、このローカルプロファイルに暗号化して保存されます。';

  @override
  String get addCredential => '認証情報を追加';

  @override
  String get addLocalCredential => 'ローカルの認証情報を追加';

  @override
  String get addLocalGroup => 'ローカルグループを追加';

  @override
  String get addLocalSnippet => 'ローカルスニペットを追加';

  @override
  String get addSnippet => 'スニペットを追加';

  @override
  String get addASignInPasswordOr =>
      'サインイン用のパスワードまたは SSH 秘密鍵を追加します。暗号文はこのローカルプロファイルにのみ保存されます。';

  @override
  String get addAScriptOrAStructured =>
      'スクリプトまたは構造化された Bash コマンドを追加します。本文は暗号化されたローカルプロファイルにのみ保存されます。';

  @override
  String get parentGroup => '親グループ';

  @override
  String get theParentGroupNoLongerExists =>
      '親グループがもう存在しないか、この階層では循環が発生します。選択し直してから再試行してください。';

  @override
  String get parentMissing => '親が見つかりません';

  @override
  String parentName(String name) {
    return '親：$name';
  }

  @override
  String get snippet => 'スニペット';

  @override
  String snippetSnippetid(String snippetId) {
    return 'スニペット $snippetId';
  }

  @override
  String snippetTitle(String title) {
    return 'スニペット「$title」';
  }

  @override
  String get theSnippetSaveResultCouldntBe =>
      'スニペットの保存結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get theSnippetDeletionResultCouldntBe =>
      'スニペットの削除結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get theSnippetNoLongerExistsRefresh => 'スニペットはもう存在しません。一覧を更新してください。';

  @override
  String get theSnippetWasSavedButThe =>
      'スニペットは保存されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theSnippetWasDeletedButThe =>
      'スニペットは削除されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String get theSnippetWasChangedByAnother =>
      'スニペットは別の操作で変更されています。一覧を更新してから、もう一度お試しください。';

  @override
  String get theSnippetWasUpdatedButThe =>
      'スニペットは更新されましたが、一覧を更新できませんでした。一覧の更新を再試行してください。';

  @override
  String snippetActionsTitle(String title) {
    return 'スニペットの操作：$title';
  }

  @override
  String get theSnippetUpdateResultCouldntBe =>
      'スニペットの更新結果を確認できませんでした。一覧を更新してから、再試行するかどうかを判断してください。';

  @override
  String get snippetTitle2 => 'スニペットのタイトル';

  @override
  String existingShellLabelShell(String shell) {
    return '既存のシェルのラベル：$shell';
  }

  @override
  String get leaveBlankToKeepTheCurrent =>
      '空欄のままにすると現在の鍵が保持され、入力すると現在の鍵が置き換えられます。';

  @override
  String targetHostPortAlgorithmAlgorithmFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
    String valueValue,
  ) {
    return '接続先：$host:$port\nアルゴリズム：$algorithm\nフィンガープリント：$fingerprint\n\n$valueValue';
  }

  @override
  String get confirmTrustingThisKey => 'この鍵を信頼することを確認';

  @override
  String get confirmLocalArchivePassphrase => 'ローカルアーカイブのパスフレーズの確認';

  @override
  String get privateKeyPassphraseOptional => '秘密鍵のパスフレーズ（任意）';

  @override
  String get program => 'プログラム';

  @override
  String get windowSetSavedSomeSeparateWindows =>
      'ウィンドウセットを保存しました。一部の独立ウィンドウは位置の読み取りに対応していません。';

  @override
  String windowSetOpenedValuevalueCountSessions(
    int valueValue,
    int count,
    int failures,
  ) {
    return 'ウィンドウセットで $valueValue/$count 個のセッションを開きました。$failures 個は接続できませんでした。';
  }

  @override
  String get portForwarding => 'ポート転送';

  @override
  String get manageSshHostKeyTrust => 'SSH ホスト鍵の信頼を管理';

  @override
  String get terminalTheme => 'ターミナルのテーマ';

  @override
  String get terminalFontSize2 => 'ターミナルの文字サイズ';

  @override
  String get structuredBashCommand => '構造化 Bash コマンド';

  @override
  String get structuredCommandsSupportBashOnlyHere =>
      '構造化コマンドは Bash のみに対応しています。ここでは暗号化して保存するだけで、ローカルモードでは実行されません。';

  @override
  String get continueLabel2 => '続行';

  @override
  String get editCredential => '認証情報を編集';

  @override
  String get editLocalCredential => 'ローカルの認証情報を編集';

  @override
  String get editLocalGroup => 'ローカルグループを編集';

  @override
  String get editLocalSnippet => 'ローカルスニペットを編集';

  @override
  String get editSnippet => 'スニペットを編集';

  @override
  String get gridView => 'グリッド表示';

  @override
  String get script => 'スクリプト';

  @override
  String scriptShell(String shell) {
    return 'スクリプト · $shell';
  }

  @override
  String get scriptBody => 'スクリプト本文';

  @override
  String get unlockLocalProfile => 'ローカルプロファイルのロックを解除';

  @override
  String get authenticationType => '認証の種類';

  @override
  String get letExternalAiAccessTheCurrent => '外部 AI を現在のローカルワークスペースに接続します。';

  @override
  String get setLocalArchivePassphrase => 'ローカルアーカイブのパスフレーズを設定';

  @override
  String get thisPreferenceAlreadyExistsAndThe =>
      'この設定はすでに存在するため、現在の値を再読み込みしました。確認してから保存してください。';

  @override
  String get thisKeyWasRevokedBeforeOnly =>
      'この鍵は以前に失効しています。サーバーの ID を再確認した場合にのみ、再度承認してください。';

  @override
  String get thisSnippetIdAlreadyExistsCreate =>
      'このスニペット ID はすでに存在します。作成し直してください。';

  @override
  String get createAnEmptyLocalProfileFirst =>
      '先に空のローカルプロファイルを作成してから、アーカイブをインポートしてください。';

  @override
  String get unlockTheLocalProfileFirst => '先にローカルプロファイルのロックを解除してください。';

  @override
  String get chooseALocalProfileFirst => '先にローカルプロファイルを選択してください。';

  @override
  String get unlockTheTargetLocalProfileTo =>
      'ファイルウィンドウを開くには、対象のローカルプロファイルのロックを解除してください。';

  @override
  String get enterTheSshPrivateKey => 'SSH 秘密鍵を入力してください。';

  @override
  String get enterACredentialNameAndUser => '認証情報の名前とユーザー名を入力してください。';

  @override
  String get enterAPassword => 'パスワードを入力してください。';

  @override
  String get enterTheLocalProfileMasterPassword =>
      'ローカルプロファイルのマスターパスワードを入力してください。';

  @override
  String get enterASnippetTitle => 'スニペットのタイトルを入力してください。';

  @override
  String get enterTheScriptBody => 'スクリプト本文を入力してください。';

  @override
  String get verifyThisFingerprintOverATrusted =>
      '信頼できる経路でこのフィンガープリントを確認してください。承認後はこの LocalVault にのみ保存されます。';

  @override
  String get enterLocalArchivePassphrase => 'ローカルアーカイブのパスフレーズを入力';

  @override
  String get backToWorkspaceSelection => 'ワークスペースの選択に戻る';

  @override
  String get noHostsYet => 'ホストはまだありません';

  @override
  String get noCredentialsYet => '認証情報はまだありません';

  @override
  String get noGroupsYet => 'グループはまだありません';

  @override
  String get noLocalProfilesYet => 'ローカルプロファイルはまだありません';

  @override
  String get noSnippetsYet => 'スニペットはまだありません';

  @override
  String get connectGroup => 'グループに接続';

  @override
  String get connectionClosed => '接続が閉じられました';

  @override
  String get connectDirectFromThisDevice => '接続（このデバイスから直接）';

  @override
  String get exitLocalProfile => 'ローカルプロファイルを終了';

  @override
  String get chooseTheWorkspaceModeAndThe =>
      'ワークスペースモードと既定で開くページを選択します。設定は現在のローカルプロファイルに保存されます。';

  @override
  String get chooseAProfileToUnlock => 'ロックを解除するプロファイルを選択';

  @override
  String get someSeparateWindowsOrWindowPositions =>
      '一部の独立ウィンドウまたはウィンドウの位置を復元できませんでした。セッションは現在のウィンドウに残ります。';

  @override
  String profileSubstring(String substring) {
    return 'プロファイル $substring';
  }

  @override
  String get profileHostAndCredentialRecordsAre =>
      'プロファイル、ホスト、認証情報のレコードはローカルの暗号鍵で保護されています。';

  @override
  String get theProfileWasClosedButAutomatic =>
      'プロファイルは閉じましたが、自動ロック解除を取り消せませんでした。もう一度ロックを解除してからロックし、再試行してください。';

  @override
  String get retryRefresh => '更新を再試行';

  @override
  String get retryReading => '再読み込み';

  @override
  String get retryReadingProfiles => 'プロファイルを再読み込み';

  @override
  String get lockAndReturnToProfiles => 'ロックしてプロファイル一覧に戻る';

  @override
  String get lockProfile => 'プロファイルをロック';

  @override
  String get hideKey => '鍵を隠す';

  @override
  String get topLevelGroup => '最上位グループ';

  @override
  String get color => '色';

  @override
  String get firstConnectionUnknownSshHostKey => '初回接続：不明な SSH ホスト鍵';

  @override
  String get defaultLabel => '既定';

  @override
  String get defaultCredential => '既定の認証情報';

  @override
  String get allLocalRecordsArePreflightedBefore =>
      '新しい保管庫を作成する前に、すべてのローカルレコードを事前チェックします。未対応の設定、削除マーカー、欠落した参照、添付オブジェクトの参照があると、サーバーへの書き込み前に移行を停止します。';

  @override
  String get cancelEmptyPreparation => '空の準備をキャンセル';

  @override
  String get continueMigration => '移行を続行';

  @override
  String get importedLocalProfiles => 'インポートしたローカルプロファイル';

  @override
  String get localProfile => 'ローカルプロファイル';

  @override
  String get localProfilePassword => 'ローカルプロファイルのパスワード';

  @override
  String localProfileUnlockedCountResumableMigration(int count) {
    return 'ローカルプロファイルのロックを解除しました · 再開可能な移行 $count 件';
  }

  @override
  String localProfileSubstring(String substring) {
    return 'ローカルプロファイル · $substring';
  }

  @override
  String get lock => 'ロック';

  @override
  String get migrateLocalProfiles => 'ローカルプロファイルを移行';

  @override
  String get migrationCompleted => '移行が完了しました';

  @override
  String get migrationNeedsRecovery => '移行には復旧が必要です';

  @override
  String get migrationStoppedLocalSourceKept => '移行を停止 · ローカルの移行元を保持';

  @override
  String get moveLocalEncryptedRecordsToA => 'ローカルの暗号化レコードを新しい同期保管庫に移動';

  @override
  String get newSyncVaultName => '新しい同期保管庫の名前';

  @override
  String get noLocalOnlyProfileExistsIn =>
      'このブラウザにはまだローカル専用プロファイルがありません。ローカルプロファイルのワークスペースで作成し、必要なレコードを追加してから、ここに戻ってください。';

  @override
  String get preflightAndMigrate => '事前チェックして移行';

  @override
  String get startANewMigration => '新しい移行を開始';

  @override
  String get stopAndKeepBoth => '停止して両方を保持';

  @override
  String get stopAndKeepLocalData => '停止してローカルデータを保持';

  @override
  String get stopMigrationAndKeepLocalData => '移行を停止してローカルデータを保持しますか？';

  @override
  String get theClientDecryptsAndValidatesEvery =>
      'クライアントは移行元の各レコードを復号・検証し、承認済みのサーバーデバイス向けに再暗号化します。サーバーが受け取るのは署名済みの暗号文だけです。既存のローカルレコードは変更されず、移行先がすべてのレコードを確認するまでローカルプロファイルへの書き込みは凍結されます。';

  @override
  String get theLocalSourceWillBecomeWritable =>
      'ローカルの移行元は再び書き込み可能になり、レコードは変更されません。移行先の保管庫、確定済みのレコード、キュー内の操作は削除も取り消しもされないため、移行先に一部のコピーが残る場合があります。';

  @override
  String get unlockALocalOnlyProfile => 'ローカル専用プロファイルのロックを解除';

  @override
  String get unlockAndValidate => 'ロック解除して検証';

  @override
  String stagedcountTotalcountEncryptedRecordsStaged(
    int stagedCount,
    int totalCount,
  ) {
    return '$stagedCount / $totalCount 件の暗号化レコードをステージ済み';
  }

  @override
  String stageditemcountItemcountEncryptedRecordsStagedTarget(
    int stagedItemCount,
    int itemCount,
    String substring,
  ) {
    return '$stagedItemCount / $itemCount 件の暗号化レコードをステージ済み · 移行先 $substring…';
  }

  @override
  String get theSyncServiceIdentityIsntVerified =>
      '同期サービスの ID はまだ検証されていません。もう一度サインインしてから再試行してください。';

  @override
  String countCount2EncryptedRecordsSafelyStaged(int count, int count2) {
    return '$count / $count2 件の暗号化レコードを安全にステージしました。';
  }

  @override
  String get destinationDataIsAlreadyStagedThis =>
      '移行先のデータがすでにステージされているため、この移行はキャンセルできません。';

  @override
  String get couldntStopTheMigrationTheSource =>
      '移行を停止できませんでした。元データとステージ済みの暗号文は保持されています。もう一度試すか、移行を続行してください。';

  @override
  String get thisMigrationCantBeResumedSafely =>
      'この移行は安全に再開できません。元データとステージ済みの暗号文は変更されていません。現在のデバイスとサーバーの状態を確認してください。';

  @override
  String get couldntUnlockOrVerifyThisLocal =>
      'このローカルプロファイルのロック解除または検証ができませんでした。パスワードとローカルストレージを確認してから、もう一度お試しください。';

  @override
  String get couldntReadTheLocalProfileList =>
      'ローカルプロファイルの一覧を読み込めませんでした。このページを閉じてから、もう一度お試しください。';

  @override
  String get theStagedDestinationCiphertextHasAn => 'ステージ済みの移行先暗号文の形式が無効です。';

  @override
  String get noVaultCreationRequestWasSent =>
      '保管庫の作成リクエストは送信されていません。準備ジャーナルは安全にキャンセルされました。';

  @override
  String get localDataWasFullyPreflightedAnd =>
      'ローカルデータの事前チェックと凍結が完了しました。新しい同期保管庫を準備しています…';

  @override
  String get localSourceSnapshotVerifiedResumingThe =>
      'ローカル移行元のスナップショットを検証しました。同じ同期先を再開しています…';

  @override
  String get theLocalProfileIsLocked => 'ローカルプロファイルはロックされています。';

  @override
  String get encryptingAndStagingRecordsWithThe =>
      '移行先の保管庫の鍵でレコードを暗号化してステージしています…';

  @override
  String get syncingEncryptedRecordsToTheNew => '暗号化レコードを新しい保管庫に同期しています…';

  @override
  String get confirmingTheSameDestinationVaultAnd =>
      '同じ移行先の保管庫であることを確認し、以前ステージしたレコードを照合しています…';

  @override
  String get reVerifyingTheLocalSourceSnapshot =>
      'ローカル移行元のスナップショットとステージ済みの暗号化データを再検証しています…';

  @override
  String get preflightingAllLocalRecordsWritesTo =>
      'すべてのローカルレコードを事前チェックしています。移行元プロファイルへの書き込みは一時的に禁止されています…';

  @override
  String get verifyingTheLocalProfileAndChecking =>
      'ローカルプロファイルを検証し、復旧ジャーナルを確認しています…';

  @override
  String get thisMigrationCantBeCancelledSafely =>
      'この移行は安全にキャンセルできません。元の移行先への復旧を続けてください。元データは凍結されたままです。';

  @override
  String get theDestinationVaultsSyncPreferencesConflict =>
      '移行先の保管庫の同期設定が競合しているため、移行はまだ完全には検証されていません。';

  @override
  String get recordsAreSavedEncryptedInThe =>
      'レコードは同期キューに暗号化して保存されましたが、サーバーからの確認はまだすべて届いていません。元のプロファイルは凍結されたままです。「移行を続行」をクリックすると安全に再試行できます。';

  @override
  String get migrationPreparationHasntSavedTheVault =>
      '移行の準備で保管庫の作成データがまだ保存されていません。';

  @override
  String get migrationCiphertextStagingIsIncomplete => '移行用暗号文のステージが完了していません。';

  @override
  String get migrationStoppedTheLocalSourceData =>
      '移行を停止しました。ローカルの元データはそのまま残り、再び書き込み可能です。移行先の保管庫で確定済みまたは同期待ちのデータは保持されます。';

  @override
  String get migrationCompleteTheServerConfirmedEvery =>
      '移行が完了しました。すべてのレコードがサーバーで確認されました。ローカルプロファイルには元のデータが残っています。';

  @override
  String get theMigrationJournalDoesntMatchThe =>
      '移行ジャーナルが、現在検証済みのローカル移行元のスナップショットと一致しません。';

  @override
  String get theMigrationJournalContainsDuplicateOr =>
      '移行ジャーナルに重複または余分なレコードが含まれています。';

  @override
  String get migrationIncompleteTheSourceDataIs =>
      '移行は完了していません。元データは変更されていません。復旧ジャーナルが作成されている場合は、下で同じ移行先を続行してください。';

  @override
  String get theMigrationDestinationBelongsToA => '移行先は別のサーバーインスタンスに属しています。';

  @override
  String get accountPassword => 'アカウントのパスワード';

  @override
  String get accountSessionExpiredSignInAgain =>
      'アカウントのセッションが期限切れです。もう一度サインインしてください';

  @override
  String get encryptedChangesAreUpToDate => '暗号化された変更は最新です';

  @override
  String get encryptedSyncWillRetryWhenThe => '接続が回復すると暗号化同期を再試行します';

  @override
  String get noVaultIsCurrentlyAvailable => '現在利用できる保管庫はありません';

  @override
  String get receiveEncryptedChangesNow => '暗号化された変更を今すぐ受信';

  @override
  String get receivingSignedEncryptedChanges => '署名済みの暗号化された変更を受信中';

  @override
  String get signOut => 'サインアウト';

  @override
  String get thisDeviceOrVaultAccessWas => 'このデバイスまたは保管庫へのアクセスは失効しています';

  @override
  String get unlockToVerifyTheLatestVault => 'ロックを解除して最新の保管庫の状態を確認';

  @override
  String get unlockWorkspace => 'ワークスペースのロックを解除';

  @override
  String get workspaceLocked => 'ワークスペースはロックされています';

  @override
  String get yourAccountStaysSignedInWhile =>
      'アカウントはサインインしたままです。ロック中、このデバイスは署名済みの暗号文を受信・保存できますが、レコードの復号や、変更の作成・アップロードはできません。';

  @override
  String get sshConsoleSupportReadingTextAnd =>
      'SSH / コンソールはテキストの読み取りと入力に対応し、SSH は単独のコマンド実行と SFTP テキストファイルの読み書きにも対応します。RDP / VNC は接続とタブ管理に対応していますが、画面認識やマウス操作にはまだ対応していません。';

  @override
  String get onlyTheLast50ToolNames =>
      'メモリ内に保持するのは直近 50 件のツール名と結果のみで、コマンド、ファイルの内容、トークンは記録しません。';

  @override
  String get listensOn127001 =>
      '127.0.0.1 でのみ待ち受けます。有効にするたびに新しいトークンが生成され、ロック、サインアウト、保管庫の切り替え後は認可が無効になります。ウィンドウごとに異なるポートを使用できます。MCP を停止しても、開いているセッションは閉じません。';

  @override
  String get stopAndRevokeToken => '停止してトークンを失効';

  @override
  String get allowExternalAiToPerformActions => '外部 AI による操作を許可';

  @override
  String get actionsAllowed => '操作を許可';

  @override
  String get allowsConnectingClosingSessionsTerminalInput =>
      'セッションの接続／切断、ターミナル入力、コマンド実行、ファイルの書き込みを許可します。変更後は MCP を有効にし直す必要があります。';

  @override
  String get readOnly => '読み取り専用';

  @override
  String get readOnlyModeCanStillRead =>
      '読み取り専用モードでも、機密情報を含む可能性のあるターミナル出力やファイルの内容は読み取れます。接続設定は信頼できる AI にのみ渡してください。保存済みのパスワード、秘密鍵、ロック解除キーが MCP のフィールドとして提供されることはありません。';

  @override
  String get availableTools => '利用可能なツール';

  @override
  String get enableMcp => 'MCP を有効化';

  @override
  String get copyConnectionConfigIncludesToken => '接続設定をコピー（トークンを含む）';

  @override
  String get externalAiAccess => '外部 AI 連携';

  @override
  String get failed => '失敗';

  @override
  String get done => '完了';

  @override
  String get off => 'オフ';

  @override
  String get copiedIncludesAccessToken => 'コピーしました（アクセストークンを含む）';

  @override
  String get couldntStartMcpMakeSureThe =>
      'MCP を起動できませんでした。ワークスペースのロックが解除されていること、ポートが他のウィンドウで使われていないことを確認してください。';

  @override
  String get couldntCopyTheConfigurationCheckClipboard =>
      '設定をコピーできませんでした。クリップボードの権限を確認してください。';

  @override
  String get noCallsYet => '呼び出しはまだありません';

  @override
  String get recentCalls => '最近の呼び出し';

  @override
  String get localListeningPort => 'ローカルの待ち受けポート';

  @override
  String get starting => '起動しています…';

  @override
  String get theBrowserAndMobileAppsDont =>
      'このバージョンの Atermius ではローカルの MCP リスナーを利用できません。Windows、Linux、macOS、Android のアプリでワークスペースを開いてから有効にしてください。';

  @override
  String get portMustBe102465535 => 'ポートの範囲は 1024〜65535 です。';

  @override
  String runningValuevalue(String valueValue) {
    return '実行中 · $valueValue';
  }

  @override
  String get letExternalAiUseTheHosts =>
      'MCP を通じて、外部 AI が現在のワークスペースのホスト、セッション、ターミナル、リモートファイルを使用できるようにします。Atermius 内でモデル API を設定する必要はありません。';

  @override
  String get rdpRemoteDesktop => 'RDP リモートデスクトップ';

  @override
  String get sshHost => 'SSH ホスト';

  @override
  String get vncRemoteDesktop => 'VNC リモートデスクトップ';

  @override
  String get newSession => '新しいセッション';

  @override
  String get unableToOpenANewWindow => '新しいウィンドウを開けません。';

  @override
  String get couldntOpenANewWindow => '新しいウィンドウを開けませんでした。';

  @override
  String get newWindowsRequireADesktop => '新しいウィンドウにはデスクトップクライアントが必要です。';

  @override
  String get fileWindowsRequireADesktop => 'ファイルウィンドウにはデスクトップクライアントが必要です。';

  @override
  String get independentFileWindowsRequireADesktop =>
      '独立したファイルウィンドウにはデスクトップクライアントが必要です。';

  @override
  String get chooseSshConfigFile => 'SSH 設定ファイルを選択';

  @override
  String get confirmImport => 'インポートを確定';

  @override
  String createCountEncryptedHostRecordS(int count) {
    return '$count 件の暗号化ホストレコードを作成します。既存のホストは変更されず、SSH 接続も開きません。';
  }

  @override
  String get importHosts => 'ホストをインポート';

  @override
  String get importOpensshConfig => 'OpenSSH 設定をインポート';

  @override
  String get importTheseHosts => 'これらのホストをインポートしますか？';

  @override
  String importCountHosts(int count) {
    return '$count 台のホストをインポート';
  }

  @override
  String lineLineMessage(int line, String message) {
    return '$line 行目 · $message';
  }

  @override
  String get noConcreteHostAliasesWereFound => '具体的な Host エイリアスが見つかりませんでした。';

  @override
  String get proxyjumpReferencesCouldNotBeSaved =>
      'ProxyJump の参照を安全な順序で保存できませんでした。';

  @override
  String get reviewBlockedNoRecordsCanBe =>
      '確認がブロックされました：このファイルにはインポートできるレコードがありません。';

  @override
  String get reviewLiteralHostAliasesHostnameUser =>
      '保存する前に、リテラルの Host エイリアス、HostName、User、Port、単一の ProxyJump エイリアスを確認してください。Include、Match、ワイルドカードパターン、ProxyCommand、LocalCommand はブロックされます。IdentityFile のパスが開かれることはありません。';

  @override
  String get theActiveVaultChangedDuringImport =>
      'インポート中にアクティブな保管庫が変更されたため、残りのホストは保存されませんでした。';

  @override
  String get theActiveVaultIsReadOnly =>
      'アクティブな保管庫は読み取り専用のため、ホストはインポートされませんでした。';

  @override
  String get theConfigFileCouldNotBe => '設定ファイルを読み込めませんでした。';

  @override
  String get theSelectedConfigCouldNotBe => '選択した設定を読み込めませんでした。';

  @override
  String get theSelectedConfigExceedsThe1 => '選択した設定が上限の 1 MiB を超えています。';

  @override
  String get thisProxyjumpChainContainsACycle =>
      'この ProxyJump のチェーンは循環しています。影響を受ける経路のホストはインポートされません。';

  @override
  String thisProxyjumpChainExceedsTheMaxjumphosthops(int maxJumpHostHops) {
    return 'この ProxyJump のチェーンは $maxJumpHostHops ホップの上限を超えています。';
  }

  @override
  String get thisProxyjumpChainPointsToA =>
      'この ProxyJump のチェーンは存在しない保存済みのホストを指しています。';

  @override
  String valuevalueAdditionalFindingsAreHidden(int valueValue) {
    return 'ほか $valueValue 件の検出結果は非表示です。';
  }

  @override
  String filenameActions(String filename) {
    return '$filename の操作';
  }

  @override
  String get uploadFile => 'ファイルをアップロード';

  @override
  String get parentFolder => '上のフォルダー';

  @override
  String get download => 'ダウンロード';

  @override
  String get modified => '更新日時';

  @override
  String get create => '作成';

  @override
  String deleteFilenameFoldersMustBeEmpty(String filename) {
    return '「$filename」を削除しますか？フォルダーは空である必要があります。この操作は元に戻せません。';
  }

  @override
  String get size => 'サイズ';

  @override
  String get fileActions => 'ファイル操作';

  @override
  String get newFolder => '新しいフォルダー';

  @override
  String get thisFolderIsEmpty => 'このフォルダーは空です';

  @override
  String get confirmDeletion => '削除の確認';

  @override
  String get editText => 'テキストを編集';

  @override
  String get remotePath => 'リモートパス';

  @override
  String get closePane => 'ペインを閉じる';

  @override
  String get unsplit => '分割を解除';

  @override
  String get invalidLayoutSession => 'レイアウトのセッションが無効です。';

  @override
  String get layoutIsNestedTooDeeply => 'レイアウトの階層が深すぎます。';

  @override
  String get dropToSplit => 'ドロップして分割';

  @override
  String paneActionsLabel(String label) {
    return 'ペイン操作 · $label';
  }

  @override
  String get paneActionsTapTheWhiteHandle =>
      'ペイン操作：上部の白いハンドルをタップするか、Alt+Shift+P を押す';

  @override
  String get paneActionsHoverNearTheTop =>
      'ペイン操作：上端に近づける、上端をタッチする、または Alt+Shift+P を押す';

  @override
  String get settingsCategories => '設定カテゴリ';

  @override
  String get backToConflict => '競合に戻る';

  @override
  String get compare => '比較';

  @override
  String get compareRemoteFileVersions => 'リモートファイルのバージョンを比較';

  @override
  String get editRemoteTextFile => 'リモートのテキストファイルを編集';

  @override
  String get fileName => 'ファイル名';

  @override
  String get latestRemote => '最新のリモート';

  @override
  String get overwriteRemoteFile => 'リモートファイルを上書き';

  @override
  String get remoteFileChanged => 'リモートファイルが変更されました';

  @override
  String get remoteFileContents => 'リモートファイルの内容';

  @override
  String get saveAs => '名前を付けて保存';

  @override
  String get saveRemoteFileAs => 'リモートファイルに名前を付けて保存';

  @override
  String get theRemoteFileChangedAfterYou =>
      '開いた後にリモートファイルが変更されました。下書きはまだ保存されていません。バージョンを比較するか、新しいコピーとして保存するか、最新版を明示的に上書きしてください。';

  @override
  String get utf8TextUpTo10 =>
      '最大 10 MiB の UTF-8 テキスト。下書きはメモリ上にのみ保持され、同期されません。SFTP では、リモートパスが同時に変更された場合の比較交換やシンボリックリンクを辿らないオープンを保証できません。共有の書き込み可能なディレクトリ内のファイルは編集しないでください。';

  @override
  String get yourDraft => 'あなたの下書き';

  @override
  String get advanced => '詳細設定';

  @override
  String get allowNetworkExposure => 'ネットワークへの公開を許可';

  @override
  String get anotherProfileOfThisHostAlready =>
      'このホストの別のプロファイルがすでにこの待ち受けアドレスとポートを使用しています。';

  @override
  String get connectThisHostOverSshTo => '転送を開始するには、このホストに SSH で接続してください。';

  @override
  String get couldNotRemoveThisForwardingProfile2 => 'この転送プロファイルを削除できませんでした。';

  @override
  String get destinationReachedFromTheSshServer => 'SSH サーバーから到達する宛先';

  @override
  String get destinationReachedFromThisDevice => 'このデバイスから到達する宛先';

  @override
  String get dynamicSocksD => 'ダイナミック SOCKS (-D)';

  @override
  String dynamicSocksDBind(String bind) {
    return 'ダイナミック SOCKS (-D) · $bind';
  }

  @override
  String get dynamicForwardingIsASocks44a =>
      'ダイナミックフォワーディングは、SOCKS 認証のない SOCKS4/4a/5 CONNECT プロキシです。リスナーに到達できる人は誰でもあなたの SSH 接続を使用できます。';

  @override
  String get expose => '公開';

  @override
  String get exposeThisForwardBeyondLoopback => 'この転送をループバック以外に公開しますか？';

  @override
  String lastConnectionLastconnectionerror(Object lastConnectionError) {
    return '前回の接続：$lastConnectionError';
  }

  @override
  String get localL => 'ローカル (-L)';

  @override
  String localLBindDestinationViaSsh(String bind, String destination) {
    return 'ローカル (-L) · $bind → SSH 経由で $destination';
  }

  @override
  String get loopbackOrAnIpAddress => 'ループバックまたは IP アドレス';

  @override
  String get permitANonLoopbackListenerFor =>
      'ループバック以外のリスナー（例：0.0.0.0）、またはリモートフォワーディングではネットワーク上のデバイス側の宛先を許可します。保存の前と毎回の開始前に確認を求められます。';

  @override
  String get reachableBeyondLoopback => 'ループバック以外から到達可能';

  @override
  String get remoteR => 'リモート (-R)';

  @override
  String remoteRSshServerBindThis(String bind, String destination) {
    return 'リモート (-R) · SSH サーバー $bind → このデバイス $destination';
  }

  @override
  String get socks44a5ConnectWithoutSocks =>
      'SOCKS 認証のない SOCKS4/4a/5 CONNECT。接続先は SSH サーバーが解決します。';

  @override
  String sshPortForwardingHostname(String hostName) {
    return 'SSH ポートフォワーディング · $hostName';
  }

  @override
  String get sshServerListenerAddress => 'SSH サーバーの待ち受けアドレス';

  @override
  String get theSshServerGatewayportsSettingMay2 =>
      'SSH サーバーの GatewayPorts 設定によって、ループバックへのバインド要求が拡大される場合があります。リモートフォワーディングを使う前にサーバーの設定を確認してください。';

  @override
  String get thisHostIsNoLongerAvailable => 'このホストは利用できなくなりました。';

  @override
  String get thisHostIsNotSavedIn =>
      'このホストは現在のプロファイルまたは保管庫に保存されていません（または削除されています）。転送プロファイルを残すにはホストを保存してください。下の実行中の転送は引き続き停止できます。';

  @override
  String sshportforwardprofiledescriptionNoLongerSavedForThis(
    String sshPortForwardProfileDescription,
  ) {
    return '$sshPortForwardProfileDescription\nこのホストには保存されていませんが、この接続ではまだ実行中です。';
  }

  @override
  String whatOnlyContinueOnANetwork(String what) {
    return '$what信頼できるネットワークでのみ続行してください。';
  }

  @override
  String get downArrow => '下矢印';

  @override
  String get leftArrow => '左矢印';

  @override
  String get lockAltModifier => 'Alt 修飾キーを固定';

  @override
  String get lockControlModifier => 'Control 修飾キーを固定';

  @override
  String get moreTerminalKeys => 'その他のターミナルキー';

  @override
  String get pasteClipboard => 'クリップボードを貼り付け';

  @override
  String get releaseControlAndAlt => 'Control と Alt を解除';

  @override
  String get rightArrow => '右矢印';

  @override
  String get upArrow => '上矢印';

  @override
  String get nextMatch => '次の一致';

  @override
  String get previousMatch => '前の一致';

  @override
  String get searchTerminalScrollback => 'ターミナルのスクロールバックを検索';

  @override
  String get closeSidebar => 'サイドバーを閉じる';

  @override
  String get delete => '削除';

  @override
  String get refreshQuickCommands => 'クイックコマンドを更新';

  @override
  String get saveEncryptedAsSnippets => 'スニペットとして暗号化保存';

  @override
  String get singleLineCommand => '1 行のコマンド';

  @override
  String get insertIntoTerminal => 'ターミナルに入力';

  @override
  String get quickCommands => 'クイックコマンド';

  @override
  String get quickCommandActions => 'クイックコマンドの操作';

  @override
  String get searchTermsAreRecordedWhenYou => 'Enter を押すか検索を閉じると検索語が記録されます';

  @override
  String get search => '検索';

  @override
  String get search2 => '検索…';

  @override
  String get searchHistory => '検索履歴';

  @override
  String get searchCurrentTerminalOutput => '現在のターミナル出力を検索';

  @override
  String get theActionDidntCompleteRefreshAnd =>
      '操作が完了しませんでした。更新してから、もう一度お試しください。';

  @override
  String get cantInsertSelectASessionThat =>
      '入力できません：接続中のセッションを選択し、コマンドは 1 行のテキストにしてください。';

  @override
  String get couldntReadQuickCommandsRefreshAnd =>
      'クイックコマンドを読み込めませんでした。更新してから、もう一度お試しください。';

  @override
  String get showsCommandsCompletedOnTheCurrent =>
      '現在のホストで完了したコマンドを表示します。クリックで入力され、自動では実行されません。';

  @override
  String get noMatchingEntries => '一致する項目はありません';

  @override
  String get addQuickCommand => 'クイックコマンドを追加';

  @override
  String get clear => '消去';

  @override
  String get clearLocalHistory => 'ローカル履歴を消去';

  @override
  String get clickToInsertPressEnterTo =>
      'クリックで入力し、Enter で実行します。パラメーターのない 1 行の Bash コマンドを表示します。';

  @override
  String get removeSearchTerm => '検索語を削除';

  @override
  String get filterInputHistory => '入力履歴を絞り込み';

  @override
  String get filterByNameOrCommand => '名前またはコマンドで絞り込み';

  @override
  String get terminalTools => 'ターミナルツール';

  @override
  String get edit => '編集';

  @override
  String get editQuickCommand => 'クイックコマンドを編集';

  @override
  String get recordingSettings => '記録の設定';

  @override
  String get enterANameAndASingle => '名前と、制御文字を含まない 1 行のコマンドを入力してください。';

  @override
  String get inputHistory => '入力履歴';

  @override
  String get cancelTransfer => '転送をキャンセル';

  @override
  String get chooseLocalFile => 'ローカルのファイルを選択';

  @override
  String get couldNotOpenAStreamingFile => 'ストリーミングのファイルソースを開けませんでした。';

  @override
  String get downloadFile => 'ファイルをダウンロード';

  @override
  String get downloadingWithSftpCompatibilityModeUp =>
      'SFTP の互換モードでダウンロードしています（最大 16 MiB）…';

  @override
  String get fileExceeds1GibTransferLimit => 'ファイルが転送上限の 1 GiB を超えています。';

  @override
  String get mobileDownloadsUpTo16Mib =>
      'モバイルでは最大 16 MiB までダウンロードできます。ファイル全体の検証後に保存先の選択画面が開きます。';

  @override
  String get preparingTransfer => '転送を準備しています…';

  @override
  String get remoteFilePath => 'リモートファイルのパス';

  @override
  String get sftpCompatibilityDownloadsUpTo16 =>
      'SFTP の互換モードでは最大 16 MiB までダウンロードできます。このプラットフォームでは、SCP にストリーミングの保存先が必要です。';

  @override
  String get singleFilesUpTo1Gib =>
      '1 ファイルあたり最大 1 GiB。既存の保存先が置き換えられることはありません。SFTP のファイルはアップロード中も表示されます。';

  @override
  String get streamingFileSavesAreUnavailableOn =>
      'このプラットフォームではストリーミングでのファイル保存を利用できません。';

  @override
  String get streamingTransferIsUnavailableOnThis =>
      'このプラットフォームではストリーミング転送を利用できません。';

  @override
  String get theSelectedProviderReturnedAnUnsafe =>
      '選択したプロバイダーが安全でないファイル名を返しました。';

  @override
  String get thisFilePickerDoesNotProvide => 'このファイルピッカーはストリーミングのソースを提供しません。';

  @override
  String get transferCancelled => '転送をキャンセルしました。';

  @override
  String get transferFailedCheckThePathPermissions =>
      '転送に失敗しました。パス、権限、宛先が存在するかを確認してください。';

  @override
  String get uploadFile2 => 'ファイルをアップロード';

  @override
  String get closeWindow => 'ウィンドウを閉じる';

  @override
  String get maximize => '最大化';

  @override
  String get minimize => '最小化';

  @override
  String get closeWindow2 => 'ウィンドウを閉じる';

  @override
  String get maximize2 => '最大化';

  @override
  String get minimize2 => '最小化';

  @override
  String get restore2 => '元に戻す';

  @override
  String get save2 => '保存';

  @override
  String get saveWindowSet => 'ウィンドウセットを保存';

  @override
  String get thisWindowHasSessionsThatCant =>
      'このウィンドウには保存できないセッションがあります。閉じてから、もう一度お試しください。';

  @override
  String get thisWindowHasNoSessionsTo => 'このウィンドウには保存できるセッションがありません。';

  @override
  String get openWindowSet => 'ウィンドウセットを開く';

  @override
  String get couldntDeleteTheWindowSetUnlock =>
      'ウィンドウセットを削除できませんでした。再度ロックを解除するか同期してから、もう一度お試しください。';

  @override
  String get couldntReadWindowSetsUnlockAgain =>
      'ウィンドウセットを読み込めませんでした。再度ロックを解除するか同期してから、もう一度お試しください。';

  @override
  String get thereAreNoReadySessionsTo => '保存できる準備済みのセッションはありません。';

  @override
  String get windowSets => 'ウィンドウセット';

  @override
  String get setName => 'セット名';

  @override
  String get sshKey => 'SSH 鍵';

  @override
  String get close2 => '閉じる';

  @override
  String get password2 => 'パスワード';

  @override
  String get theActionDidntCompleteTryAgain => '操作が完了しませんでした。もう一度お試しください。';

  @override
  String get more => 'その他の機能';

  @override
  String get directConnection2 => '直接接続';

  @override
  String get connectionProperties => '接続のプロパティ';

  @override
  String get viaJumpHost => '踏み台ホスト経由';

  @override
  String get theAppOpensInTheCurrent =>
      '次回起動時は現在のモードで開きます。モードを切り替えると現在の接続は閉じますが、保存済みのデータは保持されます。';

  @override
  String get cloudSyncMode => 'クラウド同期モード';

  @override
  String get switchToCloudMode => 'クラウドモードに切り替え';

  @override
  String get switchToLocalMode => 'ローカルモードに切り替え';

  @override
  String get workspaceMode => 'ワークスペースモード';

  @override
  String get couldntSwitchTheWorkspaceModeCheck =>
      'ワークスペースモードを切り替えられませんでした。ローカルストレージを確認して、もう一度お試しください。';

  @override
  String get localMode => 'ローカルモード';

  @override
  String closeTitle(String title) {
    return '$title を閉じる';
  }

  @override
  String get newWindowCtrlShiftN => '新しいウィンドウ (Ctrl+Shift+N)';

  @override
  String countCount2Connected(int count, int count2) {
    return '$count/$count2 接続済み';
  }

  @override
  String get splitTopBottom => '上下に分割';

  @override
  String get hostMenuClickToOpen => 'ホストメニュー · クリックで展開';

  @override
  String get closeOtherTabs => '他のタブを閉じる';

  @override
  String get closeTab => 'タブを閉じる';

  @override
  String get closeThisSplitGroup => 'この分割グループを閉じる';

  @override
  String get unsplitCurrentPane => '現在のペインの分割を解除';

  @override
  String get duplicateTab => 'タブを複製';

  @override
  String get splitLeftRight => '左右に分割';

  @override
  String get connected => '接続済み';

  @override
  String get searchHostsOrQuickConnect => 'ホストを検索またはクイック接続';

  @override
  String get notConnected => '未接続';

  @override
  String get moveToNewWindow => '新しいウィンドウに移動…';

  @override
  String get terminalSidebar => 'ターミナルのサイドバー';

  @override
  String get desktopRdpEngineFeatureUnavailable => 'この RDP エンジンでは利用できません';

  @override
  String get desktopChooseAbsoluteLocalFolder => '絶対パスのローカルフォルダーを選択してください';

  @override
  String get desktopRdpMultimonResolutionHelp =>
      '「すべてのローカルモニターを使用」が有効な場合、この設定は無視され、各モニターのサイズが維持されます。';

  @override
  String get desktopRdpAutomaticResolutionHelp =>
      '自動では RDP の表示制御でウィンドウサイズに追従します。固定サイズは接続時に要求されます。';

  @override
  String get desktopUseAllLocalMonitors => 'すべてのローカルモニターを使用';

  @override
  String get desktopClipboardText => 'クリップボードのテキスト';

  @override
  String get desktopClipboardFiles => 'クリップボードのファイル';

  @override
  String get desktopMicrophone => 'マイク';

  @override
  String get desktopSmartCards => 'スマートカード';

  @override
  String get desktopCameras => 'カメラ';

  @override
  String get desktopVncResizeHelp =>
      'サイズ変更には ExtendedDesktopSize 対応サーバー（TigerVNC、または -xrandr を指定した x11vnc など）が必要です。他のサーバーではサイズを維持し、表示のみローカルで拡大縮小します。';

  @override
  String get desktopAutomaticFitWindow => '自動（ウィンドウに合わせる）';

  @override
  String desktopResolutionSideBounds(int minSide, int maxSide) {
    return '解像度の各辺は $minSide～$maxSide ピクセルで指定してください';
  }

  @override
  String desktopResolutionPixelLimit(int megapixels) {
    return '解像度が $megapixels メガピクセルを超えています';
  }

  @override
  String get inventoryTooLarge => 'インベントリがインポート上限の 1 MiB を超えています。';

  @override
  String get inventoryTooManyLines => 'インベントリの行数が多すぎるため、安全に確認できません。';

  @override
  String get inventoryLineTooLong => 'インベントリの行が長すぎるため、安全に確認できません。';

  @override
  String get inventoryControlCharacter => 'インベントリファイルに制御文字は使用できません。';

  @override
  String get inventoryUnsupportedFormat => 'このインベントリ形式には対応していません。';

  @override
  String get inventoryParseError => 'インベントリの構文を安全に解析できませんでした。';

  @override
  String get inventoryUnsupportedConstruct => 'インベントリに未対応の構文が含まれています。';

  @override
  String get inventoryDynamicUnsupported => '動的インベントリとプラグイン設定には対応していません。';

  @override
  String get inventoryInvalidGroup => 'グループ宣言の形式が不正か、未対応です。';

  @override
  String get inventoryInvalidHost => 'ホスト宣言の形式が不正か、未対応です。';

  @override
  String get inventoryInvalidVariable => '許可された接続フィールドの値が無効です。';

  @override
  String get inventoryUnsupportedConnection => '静的な SSH インベントリホストのみインポートできます。';

  @override
  String get inventoryIgnoredVariable => '未対応のインベントリ変数は無視され、インポートされません。';

  @override
  String get inventoryConflictingVariable =>
      'インベントリの値が競合しているため、このホストを一意に解釈できません。';

  @override
  String get inventoryDuplicateVariable => '接続フィールドが重複しているため、このホストを一意に解釈できません。';

  @override
  String get inventoryGroupCycle => 'グループの継承に循環があります。';

  @override
  String get inventoryLimitExceeded => 'インベントリが安全な解析の上限を超えています。';

  @override
  String get inventoryEmpty => 'このインベントリに静的ホストが見つかりませんでした。';

  @override
  String get inventoryBlockedSource => 'ブロックされたインベントリは保存済みソースの状態を変更できません。';

  @override
  String get inventoryEmptySource => '空のインベントリでは保存済みホストを欠落としてマークできません。';

  @override
  String get inventoryPartialSource =>
      '不完全または曖昧なインベントリでは保存済みホストを欠落としてマークできません。';

  @override
  String get inventoryBlockedPlan => 'インベントリにブロックする問題があり、変更は予定されていません。';

  @override
  String get inventoryBlockedEntry => 'この項目にはブロックする問題があるため、変更されません。';

  @override
  String get inventoryDuplicateIdentity => 'このソースに曖昧な重複ホスト識別子があります。';

  @override
  String get inventoryUsernameRequired => 'ホストを保存するにはユーザー名が必要です。';

  @override
  String get inventoryMultipleSaved => 'このソース識別子を持つ保存済みホストが複数あります。';

  @override
  String get inventoryKeepOtherSource =>
      '保存済みです。既存ホストは別のソースに属するか、ソース識別子がないため、変更されません。';

  @override
  String get inventoryRevisionUnavailable =>
      '保存済みホストのリビジョンを取得できません。ホストページを更新して再確認してください。';

  @override
  String get inventoryTagLimit =>
      '統合後のホストがタグ数の上限 128 を超えます。タグまたはグループを削除して再確認してください。';

  @override
  String get inventoryRestoreActive => 'このホストはソース内でアクティブな状態に復元されます。';

  @override
  String get inventoryMissingRevision =>
      '保存済みホストのリビジョンを取得できないため、欠落項目を古い状態としてマークしませんでした。';

  @override
  String get inventoryAbsentHost => '完全なインベントリにこの保存済みホストがありません。';

  @override
  String get sshImportLineTooLong => 'この行は長すぎるため確認できません。';

  @override
  String get sshImportControlCharacter => 'SSH 設定ファイルに制御文字は使用できません。';

  @override
  String get sshImportUnterminatedQuote =>
      '引用符またはエスケープが閉じていません。インポート前にこの行を修正してください。';

  @override
  String get sshImportAliasRequired => 'Host 行には具体的なエイリアスが必要です。';

  @override
  String get sshImportUnsupportedPattern =>
      'ワイルドカード、否定、不正な Host パターンには対応していません。具体的なエイリアスを使用してください。';

  @override
  String get sshImportHostLimit => '設定ファイルがホスト数のインポート上限 256 を超えています。';

  @override
  String get sshImportInclude => 'Include ファイルは開きません。設定を 1 つにまとめてから確認してください。';

  @override
  String get sshImportMatch =>
      'Match ブロックは評価しません。具体的な Host ブロックに変換してからインポートしてください。';

  @override
  String get sshImportGlobalCommand =>
      'コマンド指令は実行しません。インポート前にこのグローバル指令を削除してください。';

  @override
  String get sshImportGlobalIdentity =>
      'IdentityFile には値が 1 つ必要です。インポート時にファイルは開きません。';

  @override
  String get sshImportUnknownDirective => 'この指令はインポートされません。接続前に確認または削除してください。';

  @override
  String get sshImportGlobalValueCount => 'このグローバル指令には値を 1 つだけ指定してください。';

  @override
  String get sshImportGlobalInvalidValue => 'このグローバル値は無効か、未対応です。';

  @override
  String get importStatusCreate => '作成';

  @override
  String get importStatusUpdate => '更新';

  @override
  String get importStatusUnchanged => '変更なし';

  @override
  String get importStatusMissing => '欠落';

  @override
  String get importStatusSkipped => 'スキップ';

  @override
  String get importStatusBlocked => 'ブロック';

  @override
  String get sshImportBlockedFile => 'ファイルに未対応の構造があるためブロックされました。';

  @override
  String get sshImportAmbiguousName => 'この名前の保存済みホストが複数あるため、上書きしません。';

  @override
  String get sshImportBlockedHost => 'このホストにはブロックする問題があるため、インポートされません。';

  @override
  String get sshImportNotImportable => 'このホストはインポートできません。';

  @override
  String get importUsernameMissing => 'ユーザー名なし';

  @override
  String importPlannedEndpoint(String endpoint) {
    return '予定: $endpoint';
  }

  @override
  String importSavedEndpoint(String endpoint) {
    return '保存済み: $endpoint';
  }

  @override
  String importHostTags(String tags) {
    return '保存するホストタグ: $tags';
  }

  @override
  String importSshEndpointLine(
    int line,
    String username,
    String address,
    int port,
  ) {
    return '行 $line · $username@$address:$port';
  }

  @override
  String importProxyJumpLine(String alias, int line) {
    return 'ProxyJump $alias · 行 $line';
  }

  @override
  String sshImportSavedName(String name) {
    return '「$name」として保存済みです。上書きしません。';
  }

  @override
  String sshImportJumpAmbiguous(int line) {
    return '行 $line の ProxyJump は同名の保存済みホストが複数あるため曖昧です。';
  }

  @override
  String sshImportJumpMissing(int line) {
    return '行 $line の ProxyJump を一意のインポート対象または保存済みホストに解決できません。';
  }

  @override
  String sshImportJumpSelf(int line) {
    return '行 $line の ProxyJump はホスト自身を指しています。';
  }

  @override
  String sshImportPreviewCounts(int count) {
    return 'プレビュー: ホストを $count 件作成します。競合およびブロックされた項目はスキップします。';
  }

  @override
  String inventoryPreviewCounts(
    int created,
    int updated,
    int unchanged,
    int missing,
  ) {
    return 'プレビュー: ホストを $created 件作成、$updated 件更新、$unchanged 件変更なし、$missing 件欠落。';
  }

  @override
  String get keybarPaste => '貼り付け';

  @override
  String get keybarReset => '解除';

  @override
  String get keybarCtrlGuidance => 'Ctrl: タップで次のキーのみ、ダブルタップでロック';

  @override
  String get keybarAltGuidance => 'Alt: タップで次のキーのみ、ダブルタップでロック';

  @override
  String get keybarModifierOff => 'オフ';

  @override
  String get keybarModifierArmed => '次のキーのみ';

  @override
  String get keybarModifierLocked => 'ロック中';

  @override
  String get keybarPinExpanded => '追加キーを常に表示';

  @override
  String get keybarShowKeyboard => 'キーボードを表示';

  @override
  String get keybarHideKeyboard => 'キーボードを隠す';

  @override
  String get terminalSearchQueryTooLong => '検索語が長すぎます';

  @override
  String get terminalSearchSearching => '検索中…';

  @override
  String terminalSearchMatchCount(int total, int position) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$total 件中 $position 件目',
      zero: '一致なし',
    );
    return '$_temp0';
  }

  @override
  String terminalSearchLimitedCount(String countLabel) {
    return '$countLabel · 検索結果は制限されています';
  }

  @override
  String get r7UiPaletteGalleryTitle => 'カラースキーム';

  @override
  String get r7UiPaletteGalleryDescription =>
      'このデバイスのすべてのターミナル（ローカル、クラウド、別ウィンドウのターミナル）に適用されます。このデバイスにのみ保存され、保存済みのターミナルテーマは変更されません。';

  @override
  String r7UiPaletteFollowSynced(String name) {
    return '保存済みのテーマ（$name）';
  }

  @override
  String get r7UiPaletteSearchHint => 'カラースキームを検索';

  @override
  String get r7UiPaletteFilterAll => 'すべて';

  @override
  String get r7UiPaletteFilterDark => 'ダーク';

  @override
  String get r7UiPaletteFilterLight => 'ライト';

  @override
  String get r7UiPaletteNoMatches => '一致するカラースキームはありません。';

  @override
  String r7UiPaletteActiveOverride(String name) {
    return 'このデバイスのターミナルは $name を使用しています。';
  }

  @override
  String get r7UiPaletteFollowingSynced => 'このデバイスのターミナルは保存済みのターミナルテーマに従います。';

  @override
  String get r7UiPaletteSaveFailed =>
      'このデバイスにカラースキームを保存できませんでした。アプリを閉じるまで適用されます。';

  @override
  String r7UiShortcutRecordTooltip(String action) {
    return '「$action」の新しいショートカットを記録';
  }

  @override
  String get r7UiShortcutRecording => 'キーの組み合わせを押してください… Esc でキャンセル';

  @override
  String r7UiShortcutReset(String action) {
    return '「$action」を既定値に戻す';
  }

  @override
  String get r7UiShortcutDuplicate => '他の操作でも使用されています';

  @override
  String get r7UiShortcutInvalid => '未対応または予約済みの組み合わせです';

  @override
  String get r7NavLogTranscriptNone => 'このセッションの記録はありません。';

  @override
  String get r7NavCertAnyPrincipal => '任意のプリンシパル';

  @override
  String get r7NavKindKeyWithCertificate => '秘密鍵 + 証明書';

  @override
  String get r7NavHomeNavigation => 'ホームナビゲーション';

  @override
  String get r7NavKeychainSubtitle =>
      'ホストとグループで共有する SSH 鍵、ユーザー証明書、パスワード。ホストは個別のサインインも引き続き使えます。';

  @override
  String get r7NavAdd => '追加';

  @override
  String get r7NavImportCertificateFile => '証明書ファイルをインポート';

  @override
  String get r7NavLogs => 'ログ';

  @override
  String get r7NavLogHost => 'ホスト';

  @override
  String r7NavUsedBy(int count, String names) {
    return '$count 件で使用中: $names';
  }

  @override
  String get r7NavLogTranscriptLiveNotRecorded => 'このセッション開始時は記録がオフでした。';

  @override
  String get r7NavLogTranscript => '出力の記録';

  @override
  String get r7NavCertUnsupported =>
      'この証明書アルゴリズムには対応していません（DSA とセキュリティキー証明書は非対応）。';

  @override
  String get r7NavLogSearchHint => 'ホストまたはアドレスを検索';

  @override
  String get r7NavKeychainSearchHint => '名前、ユーザー、フィンガープリント、ホストを検索';

  @override
  String get r7NavImportExport => 'インポート / エクスポート';

  @override
  String get r7NavLogProtocol => 'プロトコル';

  @override
  String get r7NavLogRecordTranscripts => 'ターミナル出力の記録を保存';

  @override
  String get r7NavLogFailureCredential => 'サインイン情報がないか読み取れません';

  @override
  String get r7NavLogFailureNetwork => 'ネットワークまたはハンドシェイクのエラー';

  @override
  String get r7NavLogNoMatches => '現在の検索やフィルターに一致する項目はありません。';

  @override
  String get r7NavLogCopyTranscript => '記録をコピー';

  @override
  String get r7NavFilterCertificates => '証明書';

  @override
  String get r7NavLogStatusConnecting => '接続中';

  @override
  String get r7NavSignInKeychainNote =>
      'キーチェーン項目（証明書を含む）を使用します。編集はキーチェーンで行い、他のホストとの共有は維持されます。';

  @override
  String r7NavCertCa(String fingerprint) {
    return 'CA $fingerprint';
  }

  @override
  String get r7NavDeleteBlocked => '使用中 — 先に該当するホストやグループを変更してください';

  @override
  String get r7NavLogFilterClosed => '終了';

  @override
  String get r7NavKeychain => 'キーチェーン';

  @override
  String get r7NavLogStorageMemory =>
      'このアプリセッションの接続ログ（メモリ内のみ、ロック時に消去）。コマンド履歴とは別です。';

  @override
  String get r7NavLogConnectedAt => '接続';

  @override
  String get r7NavCertificateOptional => 'OpenSSH ユーザー証明書（任意）';

  @override
  String get r7NavLogStorageFailed => 'ログを保存または読み取れませんでした。一覧が不完全な可能性があります。';

  @override
  String get r7NavLogFilterAll => 'すべて';

  @override
  String get r7NavFilterKeys => '鍵';

  @override
  String get r7NavKindPassword => 'パスワード';

  @override
  String get r7NavSnippets => 'クイックコマンド';

  @override
  String get r7NavLogStorageLocal =>
      'このデバイスの接続ログ。このローカルプロファイル内に暗号化して保存され、コマンド履歴とは別です。';

  @override
  String get r7NavLogDuration => '時間';

  @override
  String get r7NavImportKeyFile => '鍵ファイルをインポート';

  @override
  String get r7NavLogStatusFailed => '失敗';

  @override
  String get r7NavCertificateHelper =>
      'CA が署名した *-cert.pub を貼り付けるかインポートします。この秘密鍵の証明書である必要があり、通常の鍵より先に提示されます。';

  @override
  String get r7NavCertKeyUnreadable =>
      '証明書を確認するための秘密鍵を読み取れません（鍵とパスフレーズを確認してください）。';

  @override
  String get r7NavLogRoute => '経路';

  @override
  String r7NavSignInKeychainItem(String name) {
    return 'キーチェーン: $name';
  }

  @override
  String get r7NavLogFailureTimeout => 'タイムアウト';

  @override
  String get r7NavLogStatusConnected => '接続済み';

  @override
  String get r7NavNotUsed => 'どのホストやグループでも未使用';

  @override
  String r7NavLogRecordPolicy(int count, int kib) {
    return '既定ではオフ。有効化後に開いたセッションにのみ適用されます。ターミナルに表示された内容（サーバーがエコーした文字を含む）を保存し、キー入力は保存しません。非表示のパスワード入力は記録されません。記録中は機密情報を表示しないでください。最新 $count 件、各 $kib KiB まで保持します。';
  }

  @override
  String get r7NavLogStatus => '状態';

  @override
  String get r7NavLogFailureUnsupported => '非対応の経路';

  @override
  String get r7NavLogFailureOther => 'その他のエラー';

  @override
  String get r7NavPortForwarding => 'ポートフォワーディング';

  @override
  String get r7NavLogFailureHostKeyRejected => 'ホストキーが承認されませんでした';

  @override
  String get r7NavCertKeyMismatch => 'この証明書はこの秘密鍵のものではありません。';

  @override
  String get r7NavLogStarted => '開始';

  @override
  String get r7NavLogStatusEndedByRemote => 'サーバーにより終了';

  @override
  String r7NavCertPrincipals(String principals) {
    return 'プリンシパル: $principals';
  }

  @override
  String get r7NavLogFailureCancelled => 'キャンセル';

  @override
  String get r7NavCertInKeyField => '秘密鍵欄に証明書が入力されています。証明書欄に入力してください。';

  @override
  String get r7NavSignInOwn => 'このホスト固有のサインイン';

  @override
  String get r7NavCertValidForever => '有効期限なし';

  @override
  String get r7NavImportFileNotText => '選択したファイルはテキスト形式の鍵や証明書ではありません。';

  @override
  String get r7NavLogReason => '理由';

  @override
  String get r7NavFilterPasswords => 'パスワード';

  @override
  String get r7NavLogFilterActive => 'アクティブ';

  @override
  String get r7NavLogEmpty => 'まだセッションログはありません。開いた接続がここに表示されます。';

  @override
  String get r7NavLogStatusLost => '接続が切れました';

  @override
  String r7NavCertExpired(String date) {
    return '$date に期限切れ';
  }

  @override
  String get r7NavLogStatusClosed => '終了';

  @override
  String get r7NavSignInSource => 'サインイン方法';

  @override
  String get r7NavSignInInherited => 'グループの既定';

  @override
  String get r7NavLogFailureHostKeyChanged => 'ホストキーが変更されました';

  @override
  String get r7NavKindPrivateKey => '秘密鍵';

  @override
  String get r7NavLogFailureAuthentication => '認証が拒否されました';

  @override
  String get r7NavImportFileTooLarge => '選択したファイルは鍵や証明書としては大きすぎます。';

  @override
  String r7NavCertValidUntil(String date) {
    return '$date まで有効';
  }

  @override
  String get r7NavLogEnded => '終了';

  @override
  String get r7NavLogRouteJump => '踏み台ホスト経由';

  @override
  String get r7NavKeychainEmpty => '鍵、証明書、パスワードはまだありません。';

  @override
  String get r7NavLogClearTitle => '終了したログを消去';

  @override
  String get r7NavCertMalformed => '有効な OpenSSH 証明書ではありません。';

  @override
  String get r7NavNotAPrivateKey => 'このファイルは秘密鍵ではありません（.pub や証明書は証明書欄に入力します）。';

  @override
  String get r7NavLogFilterFailed => '失敗';

  @override
  String get r7NavLogClearBody =>
      '終了したすべてのセッションログと記録をこのデバイスから削除しますか？アクティブなセッションは残ります。';

  @override
  String r7NavCertNotYetValid(String date) {
    return '$date より前は無効';
  }

  @override
  String get r7NavLogEndpoint => '接続先';

  @override
  String get r7NavCertNotUser => 'これはホスト証明書です。サインインにはユーザー証明書が必要です。';

  @override
  String get r7NavLogTranscriptTruncated => 'サイズ上限のため古い出力は破棄されました。';

  @override
  String get r7NavSignInInheritedNote =>
      'グループ既定のサインインを使用します。上書きするにはこのホスト固有のサインインを選択します。';

  @override
  String r7ForwardSessionLabel(String host, int index) {
    return '$host #$index';
  }

  @override
  String get r7ForwardHostNotConnected => '未接続';

  @override
  String get r7ForwardNoRules => '転送ルールはまだありません。「新しいルール」でホストに追加できます。';

  @override
  String get r7ForwardConnectAndStart => '接続して開始';

  @override
  String get r7ForwardDuplicateTitle => '転送ルールを複製';

  @override
  String get r7ForwardDeleteTitle => '転送ルールを削除しますか？';

  @override
  String get r7ForwardWaitForSession => 'セッションの接続完了をお待ちください';

  @override
  String get r7ForwardStartCancelled => '開始を取り消しました。接続が完了した場合は通常のセッションとして残ります。';

  @override
  String get r7ForwardDuplicate => '複製';

  @override
  String get r7ForwardRuleChanged => 'ルールまたはホストが変更・削除されたため、開始されませんでした。';

  @override
  String r7ForwardHostSessions(int count) {
    return '$count 個のセッション';
  }

  @override
  String get r7ForwardMoreActions => 'その他の操作';

  @override
  String get r7ForwardScopeChanged =>
      '接続中に Vault またはプロファイルが変わったため、ルールは開始されませんでした。';

  @override
  String get r7ForwardChooseHost => 'ホストを選択';

  @override
  String get r7ForwardSearchHint => 'ホストまたはルールを検索';

  @override
  String r7ForwardDeleteBody(String name) {
    return '「$name」をこのホストから削除します。実行中の場合は先に停止します。';
  }

  @override
  String get r7ForwardHostConnecting => '接続中…';

  @override
  String get r7ForwardNoMatches => '検索に一致する項目はありません。';

  @override
  String r7ForwardCopyName(String name) {
    return '$name のコピー';
  }

  @override
  String get r7ForwardTitle => 'SSH ポート転送';

  @override
  String get r7ForwardRuleConflict =>
      'このルールは別の場所で変更されました。ここでは何も変更していません。現在のルールを確認してやり直してください。';

  @override
  String get r7ForwardOpenSession => 'セッションを開く';

  @override
  String get r7ForwardNotConnected => '接続が完了しなかったため、ルールは開始されませんでした。';

  @override
  String r7ForwardSummary(int rules, int hosts, int running) {
    return '$hosts 台のホストに $rules 件のルール · $running 件実行中';
  }

  @override
  String get r7ForwardRemovedHost => 'ホストは保存されていません — 転送は実行中です';

  @override
  String get r7ForwardChooseSession => 'ルールを開始するセッションを選択してください';

  @override
  String get r7ForwardHostConnected => '接続済み';

  @override
  String get r7ForwardNewRule => '新しいルール';

  @override
  String r7ForwardOnSession(String session, String status) {
    return '$session：$status';
  }

  @override
  String get r7ForwardConnectingStart => '接続中…認証後にルールを開始します';

  @override
  String get r7ForwardNoHosts => 'SSH ホストがまだありません。先に SSH ホストを追加してください。';

  @override
  String get r7ForwardNoAutoStart =>
      'ルールは手動で開始したときだけ、ホストの認証済み SSH セッション上で動作します。';

  @override
  String get r7ForwardShowAllHosts => 'ルールのないホストも表示';

  @override
  String get r7ImportMenuAction => 'Termius インポート / エクスポート';

  @override
  String get r7ImportIssueCertificateNotStored =>
      '証明書が見つかりましたが、このビルドでは証明書を保存できないため、秘密鍵のみインポートします。';

  @override
  String r7ImportIssueBundleIdentityExtra(String name) {
    return '各ホストで最初の $name だけを使用し、ほかは無視しました。';
  }

  @override
  String r7ImportRowJump(String alias) {
    return 'ジャンプホスト: $alias';
  }

  @override
  String r7ImportIssueExportHostSkipped(String name) {
    return 'ホスト「$name」は、安全に書き出せない値があるためスキップしました。';
  }

  @override
  String get r7ImportIssueBundleConfigMissing =>
      'バンドルに OpenSSH の「config」ファイルがありません。';

  @override
  String get r7ImportExportSave => 'ファイルを保存';

  @override
  String get r7ImportConfirmTitle => 'Termius からインポートしますか？';

  @override
  String get r7ImportIssueSshJumpCycle => 'ProxyJump のチェーンがループしているか、長すぎます。';

  @override
  String get r7ImportExportSecretWarning =>
      'ファイルには読み取り可能な平文のパスワードまたは秘密鍵が含まれます。ファイルを入手した人は誰でもこれらのホストにサインインできます。安全に保管し、使用後は削除してください。';

  @override
  String r7ImportIssueExportFormulaRisk(int count) {
    return '$count 行に =、+、-、@、タブで始まる値があります。値はそのまま書き出されます。このファイルは表計算アプリではなく、Termius またはテキストエディターでのみ開いてください。';
  }

  @override
  String get r7ImportIssueInvalidTag => 'タグが多すぎるか、長すぎるタグがあります。';

  @override
  String get r7ImportDispositionCreate => '作成されます';

  @override
  String get r7ImportIssueCsvUnterminatedQuote => '引用符で囲まれたフィールドが閉じられていません。';

  @override
  String r7ImportIssueExportSecretsOmitted(int count) {
    return '$count 件のホストの保存済みパスワードは、このファイルに含まれません。';
  }

  @override
  String r7ImportIssueExportKeysOmitted(int count) {
    return '$count 件のホストが使用する秘密鍵はこのエクスポートに含まれません。鍵を含めるには、OpenSSH バンドルで鍵ファイルを有効にしてください。';
  }

  @override
  String get r7ImportFileUnreadable => 'ファイルを読み込めませんでした。';

  @override
  String r7ImportIssueExportCertificatesOmitted(int count) {
    return '鍵ファイルが無効なため、証明書 $count 件はエクスポートされませんでした。';
  }

  @override
  String get r7ImportExportIntro =>
      'ホストを Termius CSV テンプレート形式または OpenSSH 設定としてエクスポートします。有効にしない限り機密情報は含まれません。CSV で扱えるのはパスワードのみです。鍵ファイルには OpenSSH バンドルを使用してください。';

  @override
  String get r7ImportIssueCsvInvalid => 'CSV の構造が無効です。';

  @override
  String get r7ImportApplyNone => 'ホストをインポート';

  @override
  String r7ImportMoreRowsHidden(int count) {
    return 'ほかに $count 行が非表示ですが、件数には含まれています。';
  }

  @override
  String get r7ImportFailScopeChanged =>
      'インポート中に保管庫が切り替わったため中止しました。切り替え前に書き込まれたレコードは元の保管庫に残っています。再試行の前に確認してください。';

  @override
  String get r7ImportIssueBundleTooLarge => 'バンドルまたはその中のファイルがインポートの上限を超えています。';

  @override
  String get r7ImportReadOnly => 'この保管庫は読み取り専用です。エクスポートは可能です。';

  @override
  String get r7ImportIssueBundleInvalid => 'ファイルが有効な ZIP バンドルではありません。';

  @override
  String get r7ImportIssueCsvNul => 'ファイルに NUL 文字が含まれています。';

  @override
  String get r7ImportConfirmAccept => 'インポート';

  @override
  String get r7ImportIssueMoshAsSsh =>
      'Mosh には対応していないため、このホストは同じポートの SSH としてインポートします。';

  @override
  String r7ImportIssueTooManyRows(int count) {
    return 'ファイル内のホストが $count 件を超えています。';
  }

  @override
  String r7ImportApply(int count) {
    return '$count 件のホストをインポート';
  }

  @override
  String get r7ImportIssueNotUtf8 =>
      'ファイルが有効な UTF-8 テキストではありません。UTF-8 で保存して再試行してください。';

  @override
  String get r7ImportIssueBundleConfigAmbiguous =>
      'バンドルの同じ階層に「config」ファイルが複数あります。1 つだけにしてください。';

  @override
  String r7ImportDone(int hosts, int groups) {
    return '$hosts 件のホストと $groups 件のグループをインポートし、暗号化して保存しました。';
  }

  @override
  String get r7ImportBlockedFile => 'このファイルはインポートできません。以下の問題を修正してから再度選択してください。';

  @override
  String get r7ImportIssueInvalidRecord => 'このホストは Atermius の検証に通りません。';

  @override
  String get r7ImportIssueInvalidPrivateKey => 'SSH_KEY の秘密鍵が大きすぎるか無効です。';

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
    return 'バンドル内の項目「$name」を拒否しました（リンク、安全でないパス、暗号化、または未対応の圧縮）。';
  }

  @override
  String get r7ImportIssueFileTooLarge => 'ファイルがインポートの上限を超えています。';

  @override
  String get r7ImportDispositionBlocked => 'インポートできません';

  @override
  String get r7ImportChooseCsv => 'Termius CSV を選択';

  @override
  String get r7ImportIssueKeyIgnoredForProtocol =>
      '秘密鍵は SSH でのみ使用されるため、このホストにはインポートされませんでした。';

  @override
  String r7ImportIssueExportCertificatesNotRepresented(int count) {
    return '$count 件のホストが証明書付きの鍵を使用しています。Termius CSV では証明書を扱えません。';
  }

  @override
  String r7ImportIssueDuplicateInFile(int row) {
    return '$row 行目と同じホストです。';
  }

  @override
  String r7ImportIssueSshForwardBlocked(String name) {
    return '$name はインポートしませんでした。ループバックのみで固定ポートの転送だけをインポートします。その他の転送は転送エディターで追加してください。';
  }

  @override
  String r7ImportIssueUnknownColumnValue(String name) {
    return '列「$name」の値はインポートされませんでした。';
  }

  @override
  String get r7ImportIssuePasswordDroppedForKey =>
      'パスワードと秘密鍵の両方が指定されています。Atermius はホストごとにサインイン方法を 1 つだけ保存するため、秘密鍵を使用し、パスワードはインポートしません。';

  @override
  String r7ImportIssueDuplicateTags(int count) {
    return '重複したタグ $count 件を統合しました。';
  }

  @override
  String get r7ImportIssueSshBlocked => 'この OpenSSH 設定はそのままではインポートできません。';

  @override
  String get r7ImportDispositionExcluded => '除外済み';

  @override
  String get r7ImportTransferTitle => 'Termius のインポートとエクスポート';

  @override
  String get r7ImportIssueMissingAddress => 'Hostname/IP が空です。';

  @override
  String get r7ImportChooseBundle => 'OpenSSH バンドル（.zip）を選択';

  @override
  String get r7ImportRowPrivateKey => '秘密鍵あり（暗号化して保存、表示されません）';

  @override
  String r7ImportIssueExportKeysNotRepresented(int count) {
    return '$count 件のホストが秘密鍵でサインインします。Termius CSV テンプレートには鍵の列がないため、鍵はエクスポートされません。';
  }

  @override
  String r7ImportIssueExportGroupWhitespace(String name) {
    return 'ホスト「$name」: グループ名の先頭または末尾に空白があり、Termius では削除されます。';
  }

  @override
  String get r7ImportExported => '選択した場所にエクスポートを保存しました。';

  @override
  String r7ImportIssueNonTemplateColumn(String name) {
    return '列「$name」は Termius テンプレートにありません。Atermius は読み込みますが、Termius 自体はこの列を含むファイルを受け付けません。';
  }

  @override
  String get r7ImportExportFormatBundle => 'OpenSSH バンドル（.zip）: 設定と鍵ファイル';

  @override
  String r7ImportIssueGroupTooDeep(int count) {
    return 'グループの入れ子は最大 $count 階層です。';
  }

  @override
  String get r7ImportNativeUnsupported =>
      '暗号化された Termius アプリデータ、Termius クラウド保管庫、ネイティブバックアップは読み込みません。代わりに Termius から CSV をエクスポートするか、OpenSSH エクスポートを使用してください。';

  @override
  String get r7ImportIssueMissingHostname => 'ヘッダーに「Hostname/IP」列がありません。';

  @override
  String get r7ImportRowPassword => 'パスワードあり（暗号化して保存、表示されません）';

  @override
  String get r7ImportIssueInvalidPassword =>
      'パスワードが長すぎるか NUL 文字を含むため、インポートされませんでした。';

  @override
  String get r7ImportIssueInvalidAddress =>
      'Hostname/IP が有効なホスト名またはアドレスではありません。';

  @override
  String get r7ImportIssueMissingFields => 'この行はヘッダーより列が少ないため、不足分は空として扱います。';

  @override
  String get r7ImportIssueSshKeyNotInline =>
      'SSH_KEY は直接記載された秘密鍵ではありません。鍵の名前やファイルパスは読み込みません。インポート後にホストへ鍵を追加してください。';

  @override
  String r7ImportMoreIssuesHidden(int count) {
    return 'ほかに $count 件の指摘が非表示です。';
  }

  @override
  String r7ImportRowGroup(String path) {
    return 'グループ: $path';
  }

  @override
  String get r7ImportFailReadOnly => 'この保管庫は読み取り専用です。何もインポートされていません。';

  @override
  String r7ImportIssueExportTagComma(String name) {
    return 'ホスト「$name」: タグに「,」または前後の空白があります。Termius はタグを「,」で分割し、空白を削除します。';
  }

  @override
  String get r7ImportIssueBundleCertificateMissing =>
      'CertificateFile がバンドル内にないか、OpenSSH のユーザー証明書ではありません。';

  @override
  String r7ImportRowForwards(int count) {
    return 'ポートフォワード: $count 件';
  }

  @override
  String get r7ImportIssueMissingUsername =>
      'Atermius の SSH ホストにはユーザー名が必要です。Username 列を入力してください。';

  @override
  String get r7ImportIssueBundleKeyMissing =>
      'IdentityFile が選択したバンドル内にありません。ほかのファイルは読み込みません。インポート後に鍵を追加してください。';

  @override
  String get r7ImportExportFormatOpenSsh => 'OpenSSH 設定';

  @override
  String r7ImportIssueExportJumpHost(String name) {
    return 'ホスト「$name」: ジャンプホストがこのエクスポートに含まれないため、ProxyJump を省略しました。';
  }

  @override
  String get r7ImportIssueCertificateWithoutKey =>
      '証明書に対応する秘密鍵がないため、インポートしませんでした。';

  @override
  String r7ImportFailPartial(int hosts, int groups, int credentials) {
    return 'インポートに失敗し、完全には取り消せませんでした。失敗前に保存済み: ホスト $hosts 件、グループ $groups 件、キーチェーンの認証情報 $credentials 件。ほかで変更されたレコードや、保管庫の切り替えで中断された書き込みは残ります。再試行の前にホストとキーチェーンを確認してください。';
  }

  @override
  String get r7ImportExportSecretConfirmTitle => '読み取り可能な機密情報をエクスポートしますか？';

  @override
  String r7ImportIssueExportAliasRewritten(String name) {
    return 'ホスト「$name」に OpenSSH で安全な別名を付けました。';
  }

  @override
  String get r7ImportExportSecretConfirmBody =>
      'エクスポートしたファイルは暗号化されません。ファイルにアクセスできる人やアプリ（同期・バックアップツールを含む）は、中のパスワードや秘密鍵を読み取れます。';

  @override
  String get r7ImportExportIncludeKeys => '秘密鍵ファイル（と証明書）を含める';

  @override
  String get r7ImportDispositionDuplicate => 'スキップ: 重複した行';

  @override
  String get r7ImportIssueInvalidLabel => 'ラベルに制御文字が含まれているか、長すぎます。';

  @override
  String get r7ImportExportIncludePasswords => 'パスワードを含める';

  @override
  String get r7ImportIssueBundleKeyInvalid =>
      'バンドル内の IdentityFile が秘密鍵ではない（または大きすぎる）ため、インポートしませんでした。';

  @override
  String r7ImportIssueExportForwards(int count) {
    return '$count 件のホストにポートフォワードがありますが、Termius CSV では表現できません。';
  }

  @override
  String get r7ImportIssueEmptyGroupSegment => 'パス内の空のグループ名は無視しました。';

  @override
  String r7ImportExportSummary(int count) {
    return '$count 件のホストをエクスポートします。';
  }

  @override
  String r7ImportIssueSshJumpMissing(String name) {
    return 'ProxyJump「$name」が、インポート可能または保存済みのホスト 1 件と一致しません。';
  }

  @override
  String get r7ImportModeImport => 'インポート';

  @override
  String get r7ImportImportDuplicates => '既存のホストと一致する行もインポートする';

  @override
  String get r7ImportIssueExportTooLarge =>
      'このエクスポートは Atermius で再インポートできる上限を超えています（1 つのファイルに含めるホストやデータが多すぎます）。何も保存されません。エクスポートするホストを減らしてください。';

  @override
  String get r7ImportExportSecretConfirmAccept => '機密情報を含めてエクスポート';

  @override
  String r7ImportIssueExportSharedCredential(int count) {
    return '$count 件のホストが共有キーチェーンのパスワードでサインインします。パスワードを含める場合のみ、各ホストの行に書き出されます。';
  }

  @override
  String r7ImportIssueAlreadyExists(String name) {
    return '保存済みのホスト「$name」と一致します。';
  }

  @override
  String get r7ImportChooseOpenSsh => 'OpenSSH 設定を選択';

  @override
  String r7ImportSummary(int create, int groups, int skipped, int blocked) {
    return '作成 $create 件 · 新規グループ $groups 件 · スキップ $skipped 件 · インポート不可 $blocked 件';
  }

  @override
  String get r7ImportTemplateColumns =>
      'Termius CSV の列: Groups、Label、Tags、Hostname/IP、Protocol、Port、Username、Password。サブグループは「/」、タグは「,」で区切ります。秘密鍵を直接記載した追加の SSH_KEY 列はインポート時のみ受け付けます。';

  @override
  String get r7ImportExportOpenSshNoSecrets =>
      'この設定にはパスワードや鍵ファイルは含まれません。鍵を含めるには OpenSSH バンドルを使用してください。';

  @override
  String get r7ImportExportBundleHelp =>
      '~/.ssh に展開する標準の OpenSSH ファイルです（同梱の README を参照）。Termius の保管庫ではなく、Termius 10.4 は証明書ファイルを読み込みません。';

  @override
  String get r7ImportIssueControlCharacter => '値に制御文字が含まれています。';

  @override
  String r7ImportIssueAtLine(int line, String message) {
    return '$line 行目: $message';
  }

  @override
  String r7ImportIssueSshHostKeyPolicyIgnored(String name) {
    return '$name は無視しました。Atermius は常に独自の既知ホスト一覧でホスト鍵を検証します。';
  }

  @override
  String r7ImportIssueDuplicateHeader(String name) {
    return '列「$name」が複数あります。';
  }

  @override
  String get r7ImportFailStale =>
      'プレビュー後にホストまたはグループが変更されました。何もインポートされていません。ファイルを選択し直してください。';

  @override
  String get r7ImportIssueEmptyFile => 'ファイルが空です。';

  @override
  String get r7ImportExportFailed => 'エクスポートファイルを保存できませんでした。';

  @override
  String r7ImportRowTags(String tags) {
    return 'タグ: $tags';
  }

  @override
  String get r7ImportIntro =>
      'Termius の CSV テンプレート、または OpenSSH 設定（termius export-ssh-config の出力を含む）からホストをインポートします。プレビューを確認して確定するまで何も保存されません。';

  @override
  String get r7ImportExportIncludeDesktops =>
      'RDP と VNC のホストを含める（Atermius の拡張。Termius では接続設定なしでインポートされます）';

  @override
  String get r7ImportIssueInvalidUsername => 'ユーザー名に空白や制御文字が含まれているか、長すぎます。';

  @override
  String r7ImportIssueExportPasswordsNotRepresented(int count) {
    return '$count 件のホストがパスワードでサインインしますが、OpenSSH のファイルにはパスワードを保存できません。';
  }

  @override
  String get r7ImportIssueCsvTooManyFields => '列が多すぎる行があります。';

  @override
  String get r7ImportModeExport => 'エクスポート';

  @override
  String get r7ImportIssueExtraFields => 'この行にはヘッダーの列を超える値があります。';

  @override
  String r7ImportRowEndpointNoUser(
    String address,
    String port,
    String protocol,
  ) {
    return '$address:$port · $protocol';
  }

  @override
  String get r7ImportIssueCsvStrayQuote => '引用符で囲まれていないフィールドに引用符があります。';

  @override
  String r7ImportIssueUnsupportedProtocol(String name) {
    return 'プロトコル「$name」はサポートされていません（SSH、RDP、VNC に対応）。';
  }

  @override
  String r7ImportIssueExportGroupSlash(String name) {
    return 'ホスト「$name」: グループ名に「/」が含まれており、Termius はサブグループの区切りとして読み取ります。';
  }

  @override
  String get r7ImportIssueNoTemplateHeader =>
      '1 行目が Termius CSV のヘッダーではありません（Label や Hostname/IP などの列が必要です）。';

  @override
  String get r7ImportExportCancelled => 'エクスポートをキャンセルしました。ファイルは書き込まれていません。';

  @override
  String get r7ImportIssueHeaderOrderNotTermius =>
      'ヘッダーが Termius テンプレートの順序と異なります。Atermius は列名で読み込みますが、Termius はこのファイルをインポートしません。';

  @override
  String get r7ImportIssueNameAlreadyUsed => 'この名前はほかの保存済みホストで使われています。';

  @override
  String r7ImportIssueExtensionProtocol(String name) {
    return 'プロトコル「$name」は Atermius の拡張です。Termius の CSV テンプレートでは受け付けられない場合があります。';
  }

  @override
  String get r7ImportDispositionExisting => 'スキップ: 保存済み';

  @override
  String r7ImportIssueExportSkippedProtocol(int count) {
    return 'この形式では RDP/VNC ホスト $count 件をエクスポートしません。';
  }

  @override
  String get r7ImportIssueInvalidPort => 'ポートは 1〜65535 の数値で指定してください。';

  @override
  String r7ImportIssueUnknownHeader(String name) {
    return '列「$name」は Termius テンプレートにないため、値はインポートされません。';
  }

  @override
  String r7ImportIssueExportJumpCount(int count) {
    return '$count 件のホストがジャンプホストを使用していますが、この形式では表現できません。';
  }

  @override
  String r7ImportIssueSshOptionIgnored(String name) {
    return '$name は Atermius では適用されないため無視しました。';
  }

  @override
  String r7ImportConfirmBody(int hosts, int groups, int secrets) {
    return '現在の保管庫に暗号化されたホスト $hosts 件とグループ $groups 件を作成します。このうち $secrets 件のホストにはパスワードまたは秘密鍵が含まれ、そのホスト内にのみ暗号化して保存されます。';
  }

  @override
  String r7ImportIssueSshFinding(String directive, String message) {
    return '$directive: $message';
  }

  @override
  String r7ImportIssueExportPassphraseNotExported(int count) {
    return 'エクスポートした鍵のうち $count 件にパスフレーズが保存されています。パスフレーズは書き出されず、暗号化された鍵は使用時に入力を求めます。';
  }

  @override
  String get r7ImportExportFormatCsv => 'Termius CSV';

  @override
  String get r7ImportIssueInvalidGroup => 'グループ名に制御文字が含まれているか、長すぎます。';

  @override
  String get r7ImportIssueCsvFieldTooLong => '長すぎるフィールドがあります。';

  @override
  String get r7ImportFailRolledBack => 'インポートに失敗したため取り消しました。何も保存されていません。';

  @override
  String get shellLocalInputTooLarge => '入力が大きすぎるため、ローカルシェルに送信しませんでした';

  @override
  String get shellLocalKindSystem => 'システム既定のシェル';

  @override
  String get shellLocalKindCmd => 'コマンド プロンプト (cmd)';

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
  String get shellLocalOptions => 'ローカルシェルのオプション…';

  @override
  String get shellLocalOptionsTitle => 'ローカルシェルを開始';

  @override
  String get shellLocalShellLabel => 'シェル';

  @override
  String get shellLocalWorkingDirectoryLabel => '作業ディレクトリ（任意）';

  @override
  String get shellLocalWorkingDirectoryHint => '絶対パスまたは ~/フォルダー。空欄の場合はホームフォルダー';

  @override
  String get shellLocalStart => 'シェルを開始';

  @override
  String get shellLocalInvalidWorkingDirectory =>
      '絶対フォルダーパスまたは ~/フォルダーを入力してください。';

  @override
  String get shellLocalWorkingDirectoryNotFound => 'その作業ディレクトリは存在しません。';

  @override
  String get shellLocalNotInstalled => 'このコンピューターにはそのシェルがインストールされていません。';

  @override
  String get shellLocalUnavailable => 'ローカルシェル（デスクトップアプリのみ）';

  @override
  String get shellLocalUnavailableDetail =>
      'ここではお使いのコンピューターでシェルを開始できません。また、Atermius がサーバー上でシェルを実行することはありません。ローカルシェルには Atermius デスクトップアプリを使用してください。';

  @override
  String shellLocalTabTitle(String shell) {
    return 'ローカル · $shell';
  }

  @override
  String shellLocalNewShell(String shell) {
    return '新しい $shell';
  }

  @override
  String get telnetHost => 'Telnet ホスト';

  @override
  String get telnetProtocolUnencrypted => 'Telnet（暗号化なし）';

  @override
  String get telnetInteractiveLogin => 'ターミナルで対話的にログイン（保存済み情報は送信しません）';

  @override
  String get telnetLoginInteractiveHint =>
      'Telnet のログインは対話式です。ターミナルでユーザー名とパスワードを入力してください。保存済みのパスワード、鍵、キーチェーン項目が Telnet で送信されることはありません。';

  @override
  String get telnetPlaintextWarningTitle => 'Telnet は暗号化されません';

  @override
  String get telnetPlaintextWarningBody =>
      'Telnet で送信される内容（入力したパスワードを含む）はすべて平文で送られ、ネットワーク上で読み取りや改ざんが可能です。信頼できるネットワーク、または SSH 非対応の機器でのみ使用してください。保存されたホスト情報自体は暗号化されたままです。';

  @override
  String telnetPlaintextTerminalNotice(String endpoint) {
    return '$endpoint への Telnet は暗号化されていません。入力した内容（パスワードを含む）は平文で送信されます。';
  }

  @override
  String telnetConnectedToEndpoint(String endpoint) {
    return 'Telnet で $endpoint に接続しました（暗号化なし）';
  }

  @override
  String get telnetConnectedUnencrypted => 'Telnet 接続済み（暗号化なし）';

  @override
  String get telnetConnecting => 'Telnet 接続中';

  @override
  String get telnetDisconnected => 'Telnet 切断';

  @override
  String get telnetConnectionClosedTerminal => '\r\n[Telnet 接続が閉じられました]\r\n';

  @override
  String get telnetConnectionRefused => 'Telnet サーバーが接続を拒否しました。';

  @override
  String get telnetConnectionTimedOut => 'Telnet 接続がタイムアウトしました。';

  @override
  String get telnetHostLookupFailed => 'Telnet ホスト名を解決できませんでした。';

  @override
  String get telnetHostUnreachable => 'Telnet ホストに到達できませんでした。';

  @override
  String get telnetRelayUnavailable => 'サーバーのリレー経由で Telnet を開けませんでした。';

  @override
  String get telnetUnsupportedInBrowser =>
      'ブラウザーで Telnet を使うには、サインイン済みで、この宛先へのリレーが有効な Atermius サーバーが必要です。ブラウザーのローカルプロファイルでは生の TCP 接続を開けません。';

  @override
  String get telnetProtocolError =>
      'Telnet サーバーから不正または過剰なネゴシエーションが送られたため、接続を閉じました。';

  @override
  String get telnetConnectionLost => 'Telnet 接続が切断されました。';

  @override
  String get telnetConnectCancelled => 'Telnet 接続をキャンセルしました。';

  @override
  String get telnetHostSettingsInvalid =>
      'Telnet ホストでは保存済みのサインイン情報、キーチェーン項目、ジャンプホスト、ポート転送は使用できません。ターミナルで対話的にログインしてください。';

  @override
  String get telnetQuickConnectNoUser =>
      'Telnet はユーザー名を自動送信しません。telnet ホスト[:ポート] の形式で接続し、ターミナルでログインしてください。';

  @override
  String get telnetInputTooLarge =>
      '貼り付けた内容が大きすぎるため Telnet で送信できません（上限 1 MiB）。何も送信していません。';

  @override
  String get accountSettingsTitle => 'アカウントとサインイン';

  @override
  String get accountSettingsDescription =>
      'このデバイスが使用しているアカウントとサーバーの確認、セッションの管理、アカウントへのサインインを行います。';

  @override
  String get accountSettingsCurrentMode => '現在のモード';

  @override
  String get accountSettingsModeAccount => 'アカウントと同期';

  @override
  String get accountSettingsModeLocal => 'ローカルのみ（このデバイス）';

  @override
  String get accountSettingsSignedInAs => 'サインイン中のユーザー';

  @override
  String get accountSettingsServer => 'サーバー';

  @override
  String get accountSettingsSessionUnlocked => 'このデバイスでサインイン済み・ロック解除中';

  @override
  String get accountSettingsActiveVault => '現在の保管庫';

  @override
  String get accountSettingsNoVault => '保管庫が選択されていません';

  @override
  String get accountSettingsInstanceAdmin => 'インスタンス管理者';

  @override
  String get accountSettingsSessionActions => 'セッション';

  @override
  String get accountSettingsSecurityAction => 'パスワード・2 段階認証・復旧';

  @override
  String get accountSettingsSignOutTitle => 'このアカウントからサインアウトしますか？';

  @override
  String get accountSettingsSignOutBody =>
      'このデバイスで開いているこのアカウントのセッションは閉じられます。暗号化された保管庫のデータはサーバーに残り、再度サインインするにはアカウントのパスワードが必要です。';

  @override
  String get accountSettingsSwitchToLocalTitle => 'ローカルモードに切り替えますか？';

  @override
  String get accountSettingsSwitchToLocalBody =>
      'このデバイスのアカウントワークスペースと開いているセッションは閉じられます。アカウントの内容がローカルプロファイルにコピーされることはありません。';

  @override
  String get accountSettingsLocalNotSignedIn => 'アカウントにサインインしていません';

  @override
  String get accountSettingsLocalSyncRequiresAccount =>
      'ローカルプロファイルはこのデバイスにのみ保存され、同期されません。デバイス間でホストを同期するには、Atermius サーバーのアカウントにサインインしてください。';

  @override
  String get accountSettingsSignIn => 'サインインまたはサーバーに接続';

  @override
  String get accountSettingsSignInTitle => 'アカウントのサインインを開きますか？';

  @override
  String get accountSettingsSignInBody =>
      'ローカルプロファイルはロックされ、開いているセッションは閉じられます。ローカルのホストはこのデバイスに残り、アップロードされません。サインイン後、「データと移行」で移行を確認できます。';

  @override
  String get themeSettingTitle => 'テーマ';

  @override
  String themeSettingSystemResolved(Object theme) {
    return 'システムに合わせる · 現在は$theme';
  }

  @override
  String get themeOptionSystem => 'システムに合わせる';

  @override
  String get themeSettingDescription =>
      'アプリのウィンドウ、メニュー、パネルの表示を変更します。ターミナルの色とリモートデスクトップの画面は、それぞれ独自の配色のままです。';

  @override
  String get themeOptionLight => 'ライト';

  @override
  String get themeOptionDark => 'ダーク';

  @override
  String get themeSettingSaveFailed =>
      'テーマはこのセッションで切り替わりましたが、このデバイスに保存できませんでした。';

  @override
  String get syncSettingsPreferenceSaveFailed =>
      'この設定をこのデバイスに保存できませんでした。アプリを再起動するまで有効です。';

  @override
  String get syncSettingsSyncingNow => '同期しています…';

  @override
  String get syncSettingsDeviceOnly => 'これらの同期設定はこのデバイスにのみ適用されます。';

  @override
  String get syncSettingsPreferenceSaving => '保存しています…';

  @override
  String get syncSettingsAutomaticOffDescription =>
      'このデバイスではオフです。編集は「今すぐ同期」を選ぶか自動同期をオンに戻すまで、暗号化されたままこのデバイスのキューに保持されます。';

  @override
  String get syncSettingsNever => 'なし';

  @override
  String get syncSettingsSignInRequired =>
      '同期するには、このデバイスでアカウントにサインインする必要があります。';

  @override
  String syncSettingsResultNotCompleted(String status) {
    return '同期は完了しませんでした。現在の状態：$status。';
  }

  @override
  String get syncSettingsWaitingToUpload => 'アップロード待ち';

  @override
  String syncSettingsResultFailed(String error) {
    return '同期は完了しませんでした：$error';
  }

  @override
  String syncSettingsQueuedWhileOff(int count) {
    return 'このデバイスのキューにある暗号化された変更：$count。「今すぐ同期」を選ぶか自動同期をオンにするとアップロードされます。';
  }

  @override
  String get syncSettingsTitle => '同期';

  @override
  String syncSettingsResultPending(int count) {
    return '同期は実行されましたが、アップロード待ちの暗号化された変更が残っています：$count。';
  }

  @override
  String get syncSettingsAutomaticTitle => '自動同期';

  @override
  String get syncSettingsPreferenceLoading =>
      'このデバイスの同期設定を読み込んでいます…読み込み後に自動同期が始まります。';

  @override
  String get syncSettingsPreferenceReadFailedShort =>
      '保存された設定を読み取れるまで自動同期は一時停止したままです。再試行するか、設定を選び直してください。';

  @override
  String get syncSettingsResultCompleted => '同期が完了しました。アップロード待ちはありません。';

  @override
  String get syncSettingsAutomaticOnDescription =>
      '編集はバックグラウンドでアップロードされ、他のデバイスの変更もバックグラウンドでダウンロードされます。';

  @override
  String get syncSettingsPreferenceReadFailed =>
      '一時停止中：このデバイスに保存された設定を読み取れませんでした。';

  @override
  String get syncSettingsSyncNow => '今すぐ同期';

  @override
  String get syncSettingsStatus => '状態';

  @override
  String get settingsThemeShortcutsTitle => 'ショートカット';

  @override
  String get settingsThemeShortcutsDescription => 'ターミナルで使うキーボードショートカットを選択します。';

  @override
  String get settingsThemeTitle => 'テーマ';

  @override
  String settingsThemeOverlayActive(String name) {
    return 'このデバイスのターミナルは現在、代わりにデバイス配色 $name を表示しています。保存済みのテーマを選択するか、別のテーマを保存すると元に戻ります。';
  }

  @override
  String get settingsThemeDescription =>
      'アプリのライト／ダークモード、ターミナルのフォントサイズと配色を選択します。';

  @override
  String get wallpaperSettingTitle => '壁紙';

  @override
  String get wallpaperSettingDescription =>
      'アプリとターミナルペインの背後に画像を表示します。ぼかすのは画像だけで、文字、操作部品、ターミナルの文字、リモートデスクトップの画面は鮮明なままです。';

  @override
  String get wallpaperChooseImage => '画像を選択…';

  @override
  String get wallpaperReplaceImage => '画像を変更…';

  @override
  String get wallpaperReset => '壁紙を削除';

  @override
  String get wallpaperNoImage => '壁紙なし';

  @override
  String get wallpaperPreviewLabel => '壁紙のプレビュー';

  @override
  String get wallpaperLoading => '壁紙を読み込んでいます…';

  @override
  String get wallpaperMissing =>
      '保存された壁紙の画像が見つからないか、読み込めません。新しい画像を選択するか、壁紙を削除してください。';

  @override
  String get wallpaperModeTitle => 'レイアウト';

  @override
  String get wallpaperModeWindow => 'ウィンドウ全体';

  @override
  String get wallpaperModeWindowHint => '1 枚の画像をウィンドウ全体に表示します。';

  @override
  String get wallpaperModePanes => '分割に合わせる';

  @override
  String get wallpaperModePanesHint => '各ターミナルペインがそれぞれ画像を表示し、サイズ変更や並べ替えに追従します。';

  @override
  String wallpaperBlurValue(String value) {
    return 'ぼかし: $value';
  }

  @override
  String wallpaperErrorTooLarge(int limit) {
    return 'この画像は $limit MB を超えています。';
  }

  @override
  String get wallpaperErrorUnsupported => 'PNG、JPEG、または静止画の WebP 画像を選択してください。';

  @override
  String get wallpaperErrorCorrupt => 'この画像を読み込めません。破損している可能性があります。';

  @override
  String wallpaperErrorDimensions(int side) {
    return 'この画像は大きすぎて使用できません（1 辺 $side px まで）。';
  }

  @override
  String get wallpaperErrorStorage => 'このデバイスに壁紙を保存できませんでした。';

  @override
  String get wallpaperSaveFailed => '壁紙はこのセッションで変更されましたが、このデバイスに保存できませんでした。';

  @override
  String get wallpaperDeviceNote =>
      '画像のコピーはこのデバイスのアプリ専用ストレージに保存されます。別ウィンドウも開いたときに同じ壁紙を使います。';

  @override
  String get fileManagerPasteInto => 'フォルダーに貼り付け';

  @override
  String get fileManagerPathCopied => 'パスをコピーしました';

  @override
  String fileManagerCopying(String name) {
    return '「$name」をコピー中…';
  }

  @override
  String get fileManagerDropFailed => 'ドロップした項目を読み取れませんでした。何もアップロードされていません。';

  @override
  String get fileManagerOperationUnsupported => 'この接続ではファイル管理操作を利用できません。';

  @override
  String fileManagerDeleteConfirm(String name) {
    return '「$name」を削除しますか？この操作は元に戻せません。';
  }

  @override
  String get fileManagerOpen => '開く';

  @override
  String get fileManagerPasteHere => 'ここに貼り付け';

  @override
  String fileManagerUploading(String name, int index, int count) {
    return '「$name」をアップロード中（$index/$count）…';
  }

  @override
  String fileManagerMoveConfirm(String name, String folder) {
    return '「$name」を「$folder」に移動しますか？';
  }

  @override
  String get fileManagerNameConflictTitle => '名前は既に使われています';

  @override
  String get fileManagerSkip => 'スキップ';

  @override
  String fileManagerClipboardCut(String name) {
    return '「$name」を切り取りました — このタブで貼り付けると移動します';
  }

  @override
  String fileManagerRenameTitle(String name) {
    return '「$name」の名前を変更';
  }

  @override
  String fileManagerDeleteFolderConfirm(String name, int count) {
    return 'フォルダー「$name」と中の $count 個の項目を削除しますか？シンボリックリンクはリンク自体のみ削除され、リンク先はたどりません。この操作は元に戻せません。';
  }

  @override
  String get fileManagerClearClipboard => 'ファイルのクリップボードをクリア';

  @override
  String get fileManagerRename => '名前を変更';

  @override
  String fileManagerErrorUnsupportedEntry(String name) {
    return '「$name」はシンボリックリンク、特殊ファイル、または未対応の名前です。フォルダーのコピーではこれらを追跡・再作成しないため、何もコピーされていません。';
  }

  @override
  String get fileManagerKeepBoth => '両方を残す';

  @override
  String fileManagerErrorFileTooLarge(String name) {
    return '「$name」はファイルあたり 1 GiB のコピー上限を超えています。';
  }

  @override
  String get fileManagerCut => '切り取り';

  @override
  String get fileManagerDropNothingAccepted =>
      'ここにドロップできるのはファイルのみです。フォルダーや他の場所へのリンクはアップロードされません。';

  @override
  String get fileManagerPaste => '貼り付け';

  @override
  String get fileManagerErrorSourceChanged =>
      '項目がサーバー上で変更または削除されました。更新してもう一度お試しください。';

  @override
  String fileManagerErrorExists(String name) {
    return 'ここには既に「$name」があります。何も置き換えられていません。';
  }

  @override
  String get fileManagerMoveTitle => '項目を移動';

  @override
  String get fileManagerErrorIntoItself => 'フォルダーをそれ自身の中に移動またはコピーすることはできません。';

  @override
  String get fileManagerCancelled => 'キャンセルしました。他には何も変更されていません。';

  @override
  String fileManagerDropTooManyFiles(int count) {
    return '一度にドロップできるファイルは $count 個までです。';
  }

  @override
  String get fileManagerBusy => '別のファイル操作がまだ実行中です。';

  @override
  String get fileManagerCopyPath => 'パスをコピー';

  @override
  String fileManagerNameConflictKeepBoth(String name) {
    return 'このフォルダーには既に「$name」があります。新しい名前に「(copy)」を付けて両方を残しますか？既存の項目は置き換えられません。';
  }

  @override
  String fileManagerMoving(String name) {
    return '「$name」を移動中…';
  }

  @override
  String fileManagerClipboardCopied(String name) {
    return '「$name」をコピーしました — このタブで貼り付けできます';
  }

  @override
  String get fileManagerDropNeedsSftp =>
      'ドロップしたファイルは SFTP でアップロードされます。このフォルダーを SFTP で開いてください。';

  @override
  String fileManagerDeleting(String name) {
    return '「$name」を削除中…';
  }

  @override
  String fileManagerUploadSummary(int uploaded, int skipped, int failed) {
    return 'アップロード $uploaded · スキップ $skipped · 失敗 $failed';
  }

  @override
  String get fileManagerInvalidName => 'スラッシュ、バックスラッシュ、制御文字を含まない名前を入力してください。';

  @override
  String fileManagerErrorLimitExceeded(int entries, int depth) {
    return 'このフォルダーはファイル管理操作には大きすぎます（上限 $entries 項目、深さ $depth 階層、または 2 GiB）。何も変更されていません。';
  }

  @override
  String get fileManagerCopy => 'コピー';

  @override
  String get fileManagerDropTargetChanged =>
      'ドロップを確認している間に、このファイルタブのフォルダーまたは接続が変わりました。何もアップロードされていません。もう一度ドロップしてください。';

  @override
  String fileManagerUploadConflict(String name) {
    return 'このフォルダーには既に「$name」があります。「(copy)」を付けた新しい名前でアップロードするか、スキップしますか？既存のファイルは置き換えられません。';
  }

  @override
  String get fileManagerMove => '移動';

  @override
  String get homeAddSerialConsoleDetail =>
      'このコンピューターの COM ポートを 8N1 で開きます。サーバー上では何も実行されません。';

  @override
  String get homeSharingThisDevice => 'このデバイスでオンライン';

  @override
  String get homeAddShell => 'Shell（システム既定）';

  @override
  String homeSharingSharedPresenceUnknown(int members) {
    return '共有中 · メンバー $members 人 · 状態不明';
  }

  @override
  String get homeSharingLoading => 'メンバーを読み込み中…';

  @override
  String get homeAddTooltip => 'ホストを追加、またはローカル Shell / シリアル Console を開く';

  @override
  String get homeAddButton => '追加';

  @override
  String get homeSharingLocalOnly => 'ローカルのみ';

  @override
  String get homeAddSerialConsolePort => 'シリアルポート';

  @override
  String homeSharingMore(int count, String names) {
    return '他 $count 人:\n$names';
  }

  @override
  String get homeAddSerialConsoleOpen => 'Console を開く';

  @override
  String homeSharingSharedOnline(int members, int online) {
    return '共有中 · メンバー $members 人 · $online 人オンライン';
  }

  @override
  String get homeAddSerialConsoleBaud => 'ボーレート';

  @override
  String homeSharingYou(String name) {
    return '$name（自分）';
  }

  @override
  String get homeAddSerialConsoleTitle => 'シリアル Console を開く';

  @override
  String get homeAddSerialConsole => 'シリアル Console（COM）…';

  @override
  String get homeSharingLocalDetail =>
      'このローカルプロファイルはこのデバイスにのみ暗号化して保存されます。Vault メンバーはおらず、他の人からは見えず、オンライン状態も送信されません。ホストを共有するにはアカウントの Vault にサインインしてください。';

  @override
  String get homeAddSerialConsoleUnavailable => 'シリアル Console（Windows アプリのみ）';

  @override
  String get homeSharingPresenceUnknown => '状態不明';

  @override
  String get homeSharingOffline => 'オフライン';

  @override
  String get homeSharingMembersUnavailable => 'メンバー未読み込み';

  @override
  String get homeSharingLocalTooltip => 'このデバイスのローカルプロファイル — 誰とも共有されていません';

  @override
  String get homeSharingDetailsTooltip => 'Vault メンバーとオンライン状態を表示';

  @override
  String get homeSharingIndividual => '自分のみ';

  @override
  String get homeSharingOnline => 'オンライン';

  @override
  String sidebarResizeWidthValue(int width) {
    return '幅 $width px';
  }

  @override
  String get sidebarResizeHint => 'ドラッグするか、左右の矢印キーで幅を変更します';

  @override
  String get sidebarResizeHandle => 'サイドバーの幅を変更';

  @override
  String get fileEditLaunchFailed => 'このファイルを開けるアプリがありません。';

  @override
  String get fileEditAtomicUnsupported =>
      'このサーバーはファイルをアトミックに置き換えられないため、何もアップロードされていません。';

  @override
  String get fileEditUpload => 'アップロード';

  @override
  String get fileEditLocalRejected =>
      'ローカルコピーがプライベートフォルダー内の通常ファイルではなくなりました。何もアップロードされていません。';

  @override
  String get fileEditConflictTitle => 'サーバー上のコピーが変更されました';

  @override
  String fileEditUploadedChangedAgain(String name) {
    return '「$name」をアップロードしましたが、送信中にローカルで再度変更されました。準備ができたら再度アップロードしてください。';
  }

  @override
  String get fileEditBlockedType =>
      'この種類のファイルは開くと実行される可能性があるため、外部では開きません。「テキストを編集」または「ダウンロード」を使用してください。';

  @override
  String get fileEditStatusRejected => 'ローカルコピーは拒否されました';

  @override
  String fileEditFooterTitle(int count) {
    return '外部で編集中（$count）';
  }

  @override
  String get fileEditOpenExternal => '外部アプリで開く';

  @override
  String get fileEditSessionChanged =>
      'このファイルタブの接続が閉じられたか変更されました。何もアップロードされていません。';

  @override
  String get fileEditStatusChanged => 'ローカルで変更済み — 未アップロード';

  @override
  String fileEditTooMany(int count) {
    return '外部で同時に編集できるファイルは最大 $count 個です。';
  }

  @override
  String get fileEditLocalMissing => 'ローカルコピーが見つかりません。何もアップロードされていません。';

  @override
  String get fileEditNotRegular => '外部で編集できるのは通常のリモートファイルのみです。';

  @override
  String get fileEditStatusWatching => '保存を監視中';

  @override
  String get fileEditIgnore => '無視';

  @override
  String fileEditOpened(String name) {
    return '「$name」を外部で開きました。保存したら下の「アップロード」を選択してください。';
  }

  @override
  String get fileEditTooLarge => '外部で編集できるのは 10 MiB までのファイルです。';

  @override
  String get fileEditLocalTooLarge =>
      'ローカルコピーが 10 MiB を超えています。何もアップロードされていません。';

  @override
  String get fileEditStatusUploading => 'アップロード中…';

  @override
  String get fileEditUnavailable =>
      '外部編集にはデスクトップアプリが必要です。ここで変更するには「テキストを編集」を使用してください。';

  @override
  String fileEditConflictMessage(String name) {
    return '開いた後にサーバー上の「$name」が変更されました。サーバー上のコピーをローカル版で置き換えますか？';
  }

  @override
  String get fileEditStatusConflict => 'サーバー上でも変更されています';

  @override
  String fileEditUploaded(String name) {
    return '「$name」をアップロードしました。';
  }

  @override
  String get fileEditStop => '監視を停止';

  @override
  String get fileEditStatusFailed => 'アップロード失敗 — ローカルの変更は保持されています';

  @override
  String get fileEditKeepLocal => 'ローカルに保持';

  @override
  String get fileEditReplace => 'サーバー上のコピーを置き換える';

  @override
  String get cloudAccessShareMenu => '共有…';

  @override
  String cloudAccessShareTitle(String name) {
    return '$name を共有';
  }

  @override
  String get cloudAccessClose => '閉じる';

  @override
  String get cloudAccessTabMembers => 'メンバーとチーム';

  @override
  String get cloudAccessTabLinks => '一時リンク';

  @override
  String get cloudAccessGatewayTrustNotice =>
      'ゲストはこのサーバーのゲートウェイ経由で接続します。そのため、この Host のログイン情報はリンクが取り消されるか期限切れになるまでサーバーのゲートウェイ鍵で封印されます。サーバー運営者（またはサーバーを侵害した者）はそれを開き、セッションを見ることができます。ゲストはこの機能でパスワードや鍵を受け取りませんが、セッション内ではそのアカウントで許される操作を何でも行えます。専用の低権限アカウントを使用してください。';

  @override
  String get cloudAccessLinksHeading => 'この Host のリンク';

  @override
  String get cloudAccessNewLink => '新しいリンク';

  @override
  String get cloudAccessNoLinks => '一時リンクはまだありません。';

  @override
  String get cloudAccessStatusActive => '有効';

  @override
  String get cloudAccessStatusScheduled => '予定';

  @override
  String get cloudAccessStatusExpired => '期限切れ';

  @override
  String get cloudAccessStatusPaused => '一時停止';

  @override
  String get cloudAccessStatusSuspended => '停止中';

  @override
  String get cloudAccessStatusRevoked => '取り消し済み';

  @override
  String cloudAccessValidUntil(String time) {
    return '$time まで';
  }

  @override
  String cloudAccessRedemptionCount(String used, String max) {
    return '$used/$max 回使用';
  }

  @override
  String cloudAccessActiveSessions(String count) {
    return '$count 件アクティブ';
  }

  @override
  String get cloudAccessMore => 'その他';

  @override
  String get cloudAccessActivity => 'アクティビティ';

  @override
  String get cloudAccessPause => '一時停止';

  @override
  String get cloudAccessResume => '再開';

  @override
  String get cloudAccessRotate => 'シークレットを更新';

  @override
  String get cloudAccessRevoke => '取り消す';

  @override
  String get cloudAccessRevokeLinkTitle => 'このリンクを取り消しますか？';

  @override
  String get cloudAccessRevokeLinkMessage =>
      'リンクはすぐに無効になり、アクティブなゲストセッションは数秒以内に閉じられます。ゲストがすでに Host 上で行った操作は取り消せません。';

  @override
  String get cloudAccessRotateTitle => '新しいシークレットを発行しますか？';

  @override
  String get cloudAccessRotateMessage =>
      '現在の URL は無効になり、そのゲストは切断されます。送信用の新しい URL が発行されます。';

  @override
  String get cloudAccessScheduleStart => '後で開始';

  @override
  String get cloudAccessStartsNow => '今すぐ開始';

  @override
  String get cloudAccessPickStart => '開始時刻を選択してください';

  @override
  String get cloudAccessLifetime => '有効期間';

  @override
  String get cloudAccessOneHour => '1 時間';

  @override
  String get cloudAccessOneDay => '24 時間';

  @override
  String get cloudAccessOneWeek => '7 日';

  @override
  String get cloudAccessCustom => 'カスタム…';

  @override
  String cloudAccessWindowSummary(String start, String end, String utc) {
    return '$start から $end まで（ローカル時刻、UTC $utc）。サーバーの時計が基準です。';
  }

  @override
  String get cloudAccessEndBeforeStart => '終了は開始より後で、未来の時刻にしてください。';

  @override
  String get cloudAccessMaxRedemptions => 'リンクを開ける回数';

  @override
  String get cloudAccessMaxRedemptionsHelp =>
      '既定は 1。「続行」をクリックしたブラウザーごとに 1 回使います。';

  @override
  String get cloudAccessUnlimited => '無制限';

  @override
  String get cloudAccessRedemptionsRange => '1〜1000 を入力するか、「無制限」を選んでください。';

  @override
  String get cloudAccessMaxConnections => '接続試行回数（任意）';

  @override
  String get cloudAccessMaxConnectionsHelp => '空欄で無制限。拒否された試行は数えません。';

  @override
  String get cloudAccessConnectionsRange => '正の数を入力するか空欄にしてください。';

  @override
  String get cloudAccessConcurrent => '同時接続数';

  @override
  String get cloudAccessViewOnly => '閲覧のみ';

  @override
  String get cloudAccessViewOnlyHelp => 'キーボード、マウス、貼り付けはサーバーがブロックします。';

  @override
  String get cloudAccessClipboardToRemote => 'Host への貼り付けを許可';

  @override
  String get cloudAccessClipboardFromRemote => 'Host からのコピーを許可';

  @override
  String get cloudAccessFilesLocked => 'ゲストのファイル転送、ドライブ、印刷、録画はオフです。';

  @override
  String get cloudAccessCustomSlug => 'カスタムアドレス（任意）';

  @override
  String get cloudAccessCustomSlugHelp =>
      '3〜48 文字の英小文字・数字・ハイフン。アドレスはパスワードではなく推測され得るため、機密語は避けてください。';

  @override
  String get cloudAccessGuestTitle => 'ゲストに表示するタイトル（任意）';

  @override
  String get cloudAccessGuestTitleHelp => 'リンクのシークレットで暗号化され、サーバーは読めません。';

  @override
  String get cloudAccessCancel => 'キャンセル';

  @override
  String get cloudAccessCreateLink => 'リンクを作成';

  @override
  String get cloudAccessLinkReady => 'リンクを作成しました';

  @override
  String get cloudAccessCopyLink => 'リンクをコピー';

  @override
  String get cloudAccessCopied => 'コピーしました';

  @override
  String get cloudAccessShownOnce =>
      '完全なリンクが表示されるのはこの一度だけです。失った場合は新しいシークレットを発行してください。';

  @override
  String get cloudAccessSendSafely =>
      'このリンクを持つ人は誰でも開けます。信頼できる経路でのみ送信してください。一部のメールスキャナーはリンクを開いて使い切ることがあります。';

  @override
  String get cloudAccessDone => '完了';

  @override
  String get cloudAccessBack => '戻る';

  @override
  String cloudAccessActivityFor(String link) {
    return 'アクティビティ · $link';
  }

  @override
  String get cloudAccessGuestSessions => 'ゲストセッション';

  @override
  String get cloudAccessNoSessions => 'まだ誰もこのリンクを開いていません。';

  @override
  String cloudAccessSessionSince(String time) {
    return '$time からアクティブ';
  }

  @override
  String cloudAccessSessionEnded(String reason) {
    return '終了（$reason）';
  }

  @override
  String get cloudAccessTerminate => 'セッションを終了';

  @override
  String get cloudAccessAuditEvents => '監査（メタデータのみ）';

  @override
  String get cloudAccessMembersExplainer =>
      'メンバーは暗号化された Vault を通じてこの Host を受け取ります。受信者が Vault 鍵を受け取るのは、あなたが各デバイスを確認した後だけです。組織管理者が単独で入手することはできません。';

  @override
  String get cloudAccessDedicatedVault => 'この Host だけを共有';

  @override
  String get cloudAccessDedicatedVaultHelp =>
      'この Host のコピーと下記の項目だけを含む新しい共有 Vault を作成します。現在の Vault の他の Host や認証情報は非公開のままです。';

  @override
  String get cloudAccessSharingVaultName => '共有 Vault の名前';

  @override
  String cloudAccessSharingVaultDefaultName(String name) {
    return '共有 · $name';
  }

  @override
  String get cloudAccessWillCopy => 'コピーされる項目:';

  @override
  String cloudAccessDependencyJumpHost(String name) {
    return '踏み台ホスト $name';
  }

  @override
  String cloudAccessDependencyCredential(String name) {
    return '認証情報 $name';
  }

  @override
  String cloudAccessDependencyKnownHost(String key) {
    return '信頼済みホスト鍵 $key';
  }

  @override
  String cloudAccessDependencyGroup(String name) {
    return 'グループ $name はコピーしません';
  }

  @override
  String cloudAccessBlockerMissingJump(String name) {
    return '$name はこの Vault にない踏み台ホストを使います。';
  }

  @override
  String cloudAccessBlockerMissingCredential(String name) {
    return '$name はこの Vault にない認証情報を参照しています。';
  }

  @override
  String cloudAccessBlockerJumpLoop(String name) {
    return '$name の踏み台チェーンがループしています。';
  }

  @override
  String get cloudAccessConsentCopy => '上記の項目だけを新しい Vault にコピーすることを承認します。';

  @override
  String get cloudAccessCreateSharingVault => '共有 Vault を作成';

  @override
  String get cloudAccessWholeVaultHeading => 'または Vault 全体を共有';

  @override
  String get cloudAccessWholeVaultHelp =>
      '受信者は現在の Vault のすべての Host、認証情報、スニペットを見られます。';

  @override
  String get cloudAccessManageWholeVault => 'Vault 全体のアクセスを管理';

  @override
  String get cloudAccessAttachOrg => '組織を選択';

  @override
  String get cloudAccessAttachOrgHelp => '付与は、あなたが管理する組織のメンバーとチームに対して行います。';

  @override
  String get cloudAccessAttach => '使用';

  @override
  String get cloudAccessManageOrganizations => '組織を管理';

  @override
  String cloudAccessGrantsIn(String org) {
    return '$org のアクセス';
  }

  @override
  String get cloudAccessAddGrant => 'メンバーまたはチームを追加';

  @override
  String cloudAccessTeamLabel(String name) {
    return 'チーム $name';
  }

  @override
  String get cloudAccessRoleViewer => '閲覧者';

  @override
  String get cloudAccessRoleEditor => '編集者';

  @override
  String get cloudAccessRemove => '削除';

  @override
  String get cloudAccessKeyDistribution => '鍵の配布待ち';

  @override
  String get cloudAccessKeyDistributionHelp =>
      'Vault 鍵を配布する前に、別の経路で受信者と各フィンガープリントを照合してください。';

  @override
  String get cloudAccessWaitingForDevice => '受信者がデバイスで「組織」を開くのを待っています';

  @override
  String get cloudAccessWaitingForOwner => '確認待ち';

  @override
  String get cloudAccessWaitingForRecipient => '鍵を送信済み。受信者の承認待ち';

  @override
  String get cloudAccessRoleDiffers =>
      '署名済みの役割が付与と異なります。変更するにはローテーションか再招待が必要です';

  @override
  String cloudAccessDeviceFingerprint(String fingerprint) {
    return 'デバイス $fingerprint';
  }

  @override
  String get cloudAccessConfirmFingerprintTitle => 'このデバイスを確認';

  @override
  String cloudAccessConfirmFingerprintMessage(String user, String fingerprint) {
    return '$user のデバイス $fingerprint に Vault 鍵を配布しますか？ $user がこのフィンガープリントを確認した場合のみ続行してください。';
  }

  @override
  String get cloudAccessDeliverKey => '鍵を配布';

  @override
  String get cloudAccessRemovalPending =>
      'サーバーアクセスはすでにブロックされています。暗号的に削除するには Vault 鍵をローテーションし、相手が見た認証情報を変更してください。';

  @override
  String get cloudAccessKeepDirect => '直接メンバーとして残す';

  @override
  String get cloudAccessRotateToRemove => '鍵をローテーション';

  @override
  String get cloudAccessRestrictedToViewer => '署名済みの役割が更新されるまで閲覧のみ';

  @override
  String get cloudAccessOrganizations => '組織';

  @override
  String get cloudAccessOrganizationsSubtitle => 'メンバー、チーム、招待';

  @override
  String get cloudAccessOrganizationsExplainer =>
      '組織名、メンバー、役割、チームはこのサーバーから見えます。組織に参加するだけで Vault 鍵が得られることはありません。';

  @override
  String get cloudAccessPendingJoin => '組織の招待を開きました — 確認してください';

  @override
  String get cloudAccessJoinOrganization => '組織に参加';

  @override
  String get cloudAccessJoinLinkField => '招待リンク';

  @override
  String get cloudAccessJoinInvalid => '有効な招待リンクではありません。';

  @override
  String get cloudAccessReview => '確認';

  @override
  String cloudAccessJoinSummary(String inviter, String role) {
    return '$inviter から $role として招待されました';
  }

  @override
  String get cloudAccessJoin => '参加';

  @override
  String get cloudAccessJoined =>
      '参加しました。共有 Vault を受け取るには、Vault 所有者があなたのデバイスを確認する必要があります。';

  @override
  String get cloudAccessSharedVaultKeys => '共有 Vault の鍵';

  @override
  String get cloudAccessSharedVaultKeysHelp =>
      'このデバイスの公開鍵を公開し、所有者がこのデバイスを確認した Vault を受け入れます。';

  @override
  String get cloudAccessCheckDeliveries => '共有 Vault を確認';

  @override
  String cloudAccessDeliveriesAccepted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '共有 Vault を $count 件追加しました。',
      zero: '新しい共有 Vault はありません。',
    );
    return '$_temp0';
  }

  @override
  String get cloudAccessYourOrganizations => 'あなたの組織';

  @override
  String get cloudAccessNewOrganization => '新しい組織';

  @override
  String get cloudAccessOrganizationName => '組織名';

  @override
  String get cloudAccessNoOrganizations => 'まだどの組織にも属していません。';

  @override
  String cloudAccessMemberCount(String count) {
    return 'メンバー $count 人';
  }

  @override
  String get cloudAccessOrgRoleOwner => 'オーナー';

  @override
  String get cloudAccessOrgRoleAdmin => '管理者';

  @override
  String get cloudAccessOrgRoleMember => 'メンバー';

  @override
  String get cloudAccessSave => '保存';

  @override
  String get cloudAccessMembers => 'メンバー';

  @override
  String get cloudAccessInviteMember => '招待';

  @override
  String get cloudAccessInviteUsername => 'ユーザー名（任意）';

  @override
  String get cloudAccessInviteUsernameHelp =>
      '招待を既存の 1 アカウントに限定します。新しい人は先にインスタンス管理者からアカウント招待を受ける必要があります。';

  @override
  String get cloudAccessRole => '役割';

  @override
  String get cloudAccessInitialTeam => 'チーム';

  @override
  String get cloudAccessNoTeam => 'チームなし';

  @override
  String get cloudAccessCreateInvitation => '招待を作成';

  @override
  String get cloudAccessInvitationReady => '招待リンクを作成しました';

  @override
  String get cloudAccessCopyInvitation => '招待リンクをコピー';

  @override
  String get cloudAccessLeave => '退出';

  @override
  String get cloudAccessRemoveMemberTitle => '組織から削除しますか？';

  @override
  String get cloudAccessRemoveMemberMessage =>
      '組織の付与によるアクセスは直ちにブロックされます。その後、Vault 所有者は影響を受ける Vault の鍵をローテーションしてください。';

  @override
  String get cloudAccessTeams => 'チーム';

  @override
  String get cloudAccessNewTeam => '新しいチーム';

  @override
  String get cloudAccessTeamName => 'チーム名';

  @override
  String cloudAccessTeamMembers(String team) {
    return '$team のメンバー';
  }

  @override
  String get cloudAccessInvitations => '招待';

  @override
  String get cloudAccessAnyAccount => '任意のアカウント';

  @override
  String get cloudAccessErrorGeneric => 'リクエストを完了できませんでした。';

  @override
  String get cloudAccessErrorLinksUnavailable => 'このサーバーでは一時リンクが設定されていません。';

  @override
  String get cloudAccessErrorOrganizationsUnavailable =>
      'このサーバーでは組織が有効になっていません。';

  @override
  String get cloudAccessErrorProtocolUnavailable =>
      'この Host のプロトコルはこのサーバーでは共有できません。';

  @override
  String get cloudAccessErrorOwnerRequired => 'リンクで共有できるのは Vault の所有者だけです。';

  @override
  String get cloudAccessErrorJumpHost => '踏み台ホストを使う Host はゲートウェイで共有できません。';

  @override
  String get cloudAccessErrorPortForward =>
      'ポート転送プロファイルを持つ Host はゲートウェイで共有できません。';

  @override
  String get cloudAccessErrorHostKeyRequired =>
      '共有する前に一度接続し、この Host の SSH 鍵を信頼してください。';

  @override
  String get cloudAccessErrorCertificateRequired =>
      '共有する前に一度接続し、この Host の RDP 証明書を信頼してください。';

  @override
  String get cloudAccessErrorLoginRequired => '共有する前にこの Host にログイン情報を保存してください。';

  @override
  String get cloudAccessErrorHostChanged =>
      'Host が変更されたか、まだ同期されていません。同期してから再試行してください。';

  @override
  String get cloudAccessErrorPlanBlocked => '先に一覧の問題を解決してください。';

  @override
  String get cloudAccessErrorTargetDenied =>
      'この Host のアドレスはサーバーの共有ポリシーで許可されていません。';

  @override
  String get cloudAccessErrorSlugTaken => 'このアドレスは使用できません。';

  @override
  String get cloudAccessErrorSlugInvalid => '3〜48 文字の英小文字・数字・途中のハイフンを使ってください。';

  @override
  String get cloudAccessErrorTooManyLinks => 'アクティブなリンクが多すぎます。先にいくつか取り消してください。';

  @override
  String get cloudAccessErrorInvalidOptions => 'これらのリンク設定はサーバーで許可されていません。';

  @override
  String get cloudAccessErrorOrgRoleRequired => '組織のオーナーまたは管理者の役割が必要です。';

  @override
  String get cloudAccessErrorOrgCreationRestricted =>
      'ここで組織を作成できるのはインスタンス管理者だけです。';

  @override
  String get cloudAccessErrorLastOwner => '組織には少なくとも 1 人のオーナーが必要です。';

  @override
  String get cloudAccessErrorInvitationUnavailable => 'この招待は利用できません。';

  @override
  String get cloudAccessErrorAccountNotFound => 'このユーザー名のアクティブなアカウントはありません。';

  @override
  String get cloudAccessErrorRateLimited => '試行回数が多すぎます。しばらくしてから再試行してください。';

  @override
  String get cloudAccessGuestWindowTitle => 'Atermius 共有アクセス';

  @override
  String get cloudAccessGuestLanding => 'Atermius の一時アクセスリンクを受け取りました';

  @override
  String get cloudAccessGuestLandingHelp =>
      '続行するまで何も起こりません。続行するとリンクの使用回数を 1 回消費する場合があります。';

  @override
  String get cloudAccessGuestContinue => '続行';

  @override
  String get cloudAccessGuestHeading => '共有アクセス';

  @override
  String cloudAccessGuestValidUntil(String time) {
    return 'このセッションは $time に終了します';
  }

  @override
  String get cloudAccessGuestViewOnly => '閲覧のみ';

  @override
  String get cloudAccessGuestInteractive => '操作可能';

  @override
  String get cloudAccessGuestClipboardOn => 'クリップボード可';

  @override
  String get cloudAccessGuestClipboardOff => 'クリップボード不可';

  @override
  String get cloudAccessGuestConnect => '接続';

  @override
  String get cloudAccessGuestDisconnect => '切断';

  @override
  String get cloudAccessGuestLeave => 'アクセスを終了';

  @override
  String get cloudAccessGuestLeft => 'アクセスは終了しました。このタブを閉じてかまいません。';

  @override
  String get cloudAccessGuestTrustNote =>
      'このセッションは共有者の Atermius サーバーを経由し、サーバーはその内容を見られます。';

  @override
  String get cloudAccessGuestUnavailable => 'このリンクは利用できません。';

  @override
  String get cloudAccessGuestAskOwner => '共有した人に新しいリンクを送ってもらってください。';

  @override
  String get cloudAccessGuestNotYetValid => 'このリンクはまだ有効ではありません。';

  @override
  String get cloudAccessGuestExpired => 'このリンクは期限切れです。';

  @override
  String get cloudAccessGuestExhausted => 'このリンクはすでに使用されています。';

  @override
  String get cloudAccessGuestSuspended => 'このリンクは所有者によって一時停止または取り消されました。';

  @override
  String get cloudAccessGuestSessionEnded => 'セッションは終了しました。';

  @override
  String get cloudAccessGuestBusy => '現在接続が多すぎます。しばらくしてから再試行してください。';

  @override
  String get cloudAccessGuestExpiringSoon => '5 分後に終了';

  @override
  String get cloudAccessGuestClosed => '接続が閉じられました。';

  @override
  String get cloudAccessGuestClosedRevoked => 'アクセスは所有者により取り消されたか変更されました。';

  @override
  String get cloudAccessGuestClosedExpired => 'アクセス時間が終了しました。';

  @override
  String get cloudAccessGuestClosedTarget =>
      'Host に接続できないか、信頼済みの識別情報と一致しませんでした。';

  @override
  String get cloudAccessGuestClosedProtocol => '予期しないメッセージのため接続が閉じられました。';

  @override
  String cloudAccessApplyRole(String role) {
    return '$roleにする';
  }

  @override
  String get cloudAccessApplyRoleTitle => 'このメンバーの役割を変更しますか？';

  @override
  String cloudAccessApplyRoleMessage(String user, String role) {
    return '$user は$roleになります。このデバイスから新しいメンバー一覧に署名し、Vault 鍵をローテーションします。';
  }

  @override
  String get cloudAccessErrorScopeChanged =>
      'この操作中にアカウント、サーバー、または選択中の Vault が変わりました。何も送信していません。もう一度お試しください。';

  @override
  String get cloudAccessErrorNotSynced =>
      '共有 Vault は作成されましたがまだ同期されていません。メンバーを追加する前に同期してください。';

  @override
  String get cloudAccessErrorScopeEndedCommitted =>
      'サーバーがこの操作の一部（Vault や招待の作成など）を完了した後に、アカウント、サーバー、または選択中の Vault が変わりました。その部分は取り消されていません。確認してから再試行してください。';

  @override
  String get mcpAccessModeDenied => '拒否';

  @override
  String get mcpAccessModeReadOnly => '読み取り専用';

  @override
  String get mcpAccessModeReadWrite => '読み書き';

  @override
  String get mcpAccessModeDeniedDescription =>
      '外部 AI はこのマシンを参照も使用もできません。ホストとセッションの一覧にも表示されません。';

  @override
  String get mcpAccessModeReadOnlyDescription =>
      '外部 AI はマシンを一覧表示し、既に開いているセッションの出力とファイルを読み取れます。接続、入力、コマンド実行、ファイルの変更はできません。';

  @override
  String get mcpAccessModeReadWriteDescription =>
      '外部 AI はさらに、セッションの接続・切り替え・切断、ターミナル入力、コマンド実行、ファイルの書き込みを行えます。ホストキーとサインインの確認は引き続き表示されます。';

  @override
  String get mcpMachineAccessTitle => 'マシンへのアクセス';

  @override
  String get mcpMachineAccessDescription =>
      '外部 AI が各マシンで行えることを選択します。この設定は現在のワークスペースごとにこのデバイスに保存され、同期されません。MCP を停止すると、ここでの選択にかかわらずすべてのアクセスが取り消されます。';

  @override
  String get mcpDefaultAccessTitle => 'すべてのマシンの既定';

  @override
  String get mcpDefaultAccessDescription =>
      '個別に設定していないすべてのマシンに適用されます。後から追加したマシンも含みます。';

  @override
  String get mcpPerMachineTitle => 'マシンごとの設定';

  @override
  String mcpCustomizedCount(int count) {
    return '個別設定のマシン: $count';
  }

  @override
  String get mcpLocalDeviceName => 'このデバイス（ローカルコンソール）';

  @override
  String get mcpLocalDeviceDetail => '保存済みホストに関連付けられていないローカルターミナルセッション';

  @override
  String mcpHostUseDefault(String mode) {
    return '既定（$mode）';
  }

  @override
  String get mcpHostCustom => '個別設定';

  @override
  String mcpHostAccessFor(String name) {
    return '$name のアクセス';
  }

  @override
  String get mcpSearchMachines => 'マシンを検索';

  @override
  String mcpNoMachinesMatch(String query) {
    return '「$query」に一致するマシンはありません。';
  }

  @override
  String get mcpNoSavedMachines => 'このワークスペースにはまだ保存済みのホストがありません。';

  @override
  String mcpShowMoreMachines(int count) {
    return 'さらに $count 台を表示';
  }

  @override
  String get mcpAccessLoading => 'マシンのアクセス設定を読み込んでいます…';

  @override
  String get mcpAccessUnavailable =>
      'マシンのアクセス設定を現在利用できません。読み込まれるまで、外部 AI はすべてのマシンで拒否されます。';

  @override
  String get mcpAccessSaveFailed => 'アクセス設定を保存できませんでした。もう一度お試しください。';

  @override
  String get mcpConfirmReadWriteDefaultTitle => 'すべてのマシンで読み書きを許可しますか？';

  @override
  String get mcpConfirmReadWriteDefaultBody =>
      '接続トークンを持つ AI は、個別に設定していないすべてのマシン（後から追加したマシンを含む）に接続し、入力し、コマンドを実行し、ファイルを変更できます。ホストキーとサインインの確認は引き続き表示されます。';

  @override
  String get mcpConfirmReadWriteDefaultConfirm => '読み書きを許可';

  @override
  String mcpRunningDefaultAccess(String mode) {
    return '実行中 · 既定: $mode';
  }

  @override
  String get mcpAndroidForwardingHint =>
      'MCP はこのデバイスのループバックアドレスでのみ待ち受けます。USB デバッグで接続したコンピューター上の AI から使用するには、コンピューターで次のコマンドを実行し、コピーした設定をそこで使用してください:';

  @override
  String get mcpAndroidBackgroundHint =>
      'MCP の実行中は通知が表示され、他のアプリに切り替えた後も外部 AI が引き続き使用できます。通知から停止する、ロックする、またはサインアウトするとトークンは取り消されます。通知を表示できない場合、アプリを離れると MCP は停止します。';

  @override
  String get mcpForegroundNotificationTitle => '外部 AI 連携がオンです';

  @override
  String mcpForegroundNotificationText(int port) {
    return 'MCP は 127.0.0.1:$port で待ち受けています。停止するとアクセストークンが取り消されます。';
  }

  @override
  String get mcpForegroundNotificationStop => 'MCP を停止';

  @override
  String get mcpAndroidProtected => 'MCP 通知によりバックグラウンドでも接続できます。';

  @override
  String get mcpAndroidForegroundOnly =>
      'アプリの表示中のみ MCP を利用できます。アプリを離れるとアクセスは失効します。';

  @override
  String get mcpAndroidStarting => 'Android のバックグラウンド保護を開始しています…';

  @override
  String get desktopKeyboardShow => 'キーボードと特殊キーを開く';

  @override
  String get desktopKeyboardHide => 'キーボードと特殊キーを閉じる';

  @override
  String get desktopTouchMode => 'タッチ操作';

  @override
  String get desktopTrackpadMode => 'トラックパッド（マウス）操作';

  @override
  String get enterFullscreen => '全画面表示';

  @override
  String get exitFullscreen => '全画面表示を終了';

  @override
  String get fullscreenUnavailable => 'このウィンドウでは全画面表示に切り替えられません。';

  @override
  String get restoreConnection => '再接続';

  @override
  String get reconnectEveryFiveSeconds => '5 秒ごとに自動再接続';

  @override
  String get desktopKeyboardModeTitle => 'リモートデスクトップのキーボード';

  @override
  String get desktopKeyboardOverlay => '重ねて表示（解像度を維持）';

  @override
  String get desktopKeyboardResize => 'キーボードに合わせてサイズ変更';

  @override
  String get desktopKeyboardOverlayDescription =>
      'キーボードと特殊キーを画面に重ねて表示し、リモートの解像度と表示倍率を維持します。';

  @override
  String get desktopKeyboardResizeDescription =>
      'キーボードの上の領域にデスクトップを縮小します。ウィンドウサイズに追従する接続ではリモート解像度も変更します。';

  @override
  String get desktopKeyboardSaveFailed =>
      '今回の選択は適用されましたが、保存できませんでした。もう一度お試しください。';

  @override
  String get rdpAddDisk => 'ドライブを追加';

  @override
  String get rdpChooseDisk => 'ドライブを選択';

  @override
  String get rdpLocalStorage => 'ローカルストレージ';

  @override
  String rdpStorageFolderUnavailable(String name) {
    return 'このデバイスでフォルダー「$name」にアクセスできません。ドライブを接続するか、このデバイスでフォルダーを選び直してください。';
  }

  @override
  String get rdpStoragePermissionRequired =>
      'ドライブまたはフォルダーを共有するには、Android 設定で Atermius のファイルアクセスを許可してから再試行してください。このホストに追加したフォルダーだけを共有します。';

  @override
  String get rdpStoragePickerFailed =>
      'ローカルフォルダーを選択できません。このデバイス上の別のフォルダーをお試しください。';

  @override
  String get rdpDriveMappingHelp =>
      '共有ドライブとフォルダーはリモートセッションの \\\\tsclient に表示されます。変更は再接続後に反映されます。Android のライブ共有にはファイルアクセスの許可が必要です。';

  @override
  String get rdpRenameMapping => '共有名を変更';

  @override
  String get rdpMappingName => '共有名';

  @override
  String get rdpMappingReconnect => '共有設定の変更を反映するにはリモートセッションに再接続してください。';

  @override
  String get keybarShiftGuidance => 'Shift：タップで次のキーのみ有効、ダブルタップで固定';

  @override
  String get lockShiftModifier => 'Shift を固定';

  @override
  String get releaseModifiers => 'Ctrl・Alt・Shift を解除';

  @override
  String connectProgressConnectingTo(String name) {
    return '$name に接続しています';
  }

  @override
  String connectProgressFailedTo(String name) {
    return '$name に接続できませんでした';
  }

  @override
  String get connectProgressStoppedTitle => '読み込みを中止しました';

  @override
  String get connectProgressStoppedDetail =>
      '接続の試行を中止しました。「再試行」でこのタブから新しく接続します。';

  @override
  String get connectProgressStagePreparing => 'ホスト設定とサインイン情報を確認しています';

  @override
  String get connectProgressStageConnecting => '接続を確立しています';

  @override
  String get connectProgressStageVerifyingHost => 'ホストの身元を確認しています';

  @override
  String get connectProgressStageAwaitingUser => '応答を待っています';

  @override
  String get connectProgressStageAuthenticating => 'サインインしています';

  @override
  String get connectProgressStageStartingSession => 'セッションを開始しています';

  @override
  String get connectProgressStop => '読み込みを中止';

  @override
  String get connectProgressRetry => '再試行';

  @override
  String get connectProgressClose => '閉じる';

  @override
  String get connectProgressRetryUnavailable =>
      'このタブは以前のサインイン、保管庫またはプロファイルのものなので再試行できません。閉じてから接続し直してください。';

  @override
  String get connectProgressNoCredential =>
      'このホストには使用できる保存済みのサインイン情報がありません。認証情報を追加または修正してから再試行してください。';

  @override
  String get termiusLocalOneClickAction => 'Termius 一括取り込み';

  @override
  String get termiusLocalDetectedTitle => 'この端末で Termius デスクトップが見つかりました';

  @override
  String get termiusLocalDetectedBody =>
      'エクスポートは不要です。Atermius はこの端末の Termius データを変更せずに読み取り、システムのキーチェーンにある Termius の鍵で解錠し（確認が表示されたら「許可」を選択）、メモリ上で復号してホスト、グループ、タグ、パスワード、SSH 鍵、ポート転送、踏み台ホストを取り込みます。既存のホストはスキップされます。';

  @override
  String get termiusLocalImportButton => 'この端末の Termius から取り込む';

  @override
  String get termiusLocalProgress =>
      'この端末の Termius から取り込んでいます…キーチェーンへのアクセスを求められたら「許可」を選択してください。';

  @override
  String termiusLocalAllExist(int count) {
    return 'Termius の $count 件のホストはすべて登録済みのため、何も取り込みませんでした。';
  }

  @override
  String get termiusLocalNothingNew => 'この端末の Termius に取り込める新しいホストはありません。';

  @override
  String get termiusLocalFailNotInstalled =>
      'この端末に Termius デスクトップのデータが見つかりません。一度 Termius デスクトップを開いてから再試行してください。';

  @override
  String get termiusLocalFailKeyNotFound =>
      'システムのキーチェーンまたは資格情報マネージャーから Termius の鍵を読み取れませんでした。確認が表示されたら「許可」を選び、この端末で Termius を開いたことがあるか確認してから再試行してください。';

  @override
  String get termiusLocalFailKeyRejected =>
      'システムのキーチェーンにある Termius の鍵ではこの Termius データを解錠できないため、何も取り込みませんでした。App Store 版とダウンロード版を切り替えた場合は、使用中の方を一度開いてから再試行してください。';

  @override
  String termiusLocalFailUnsupportedCipher(String header) {
    return 'この Termius のバージョンは不明な暗号形式（$header）を使用しているため、何も取り込みませんでした。代わりに Termius の CSV エクスポートを使用してください。';
  }

  @override
  String get termiusLocalFailEmpty => 'この端末の Termius データには取り込めるホストがありません。';

  @override
  String get termiusLocalFailReadFailed =>
      'この端末の Termius データを読み取れなかったため、何も取り込みませんでした。Termius が同期中の場合は、しばらく待ってから再試行してください。';

  @override
  String get termiusLocalFailTooLarge =>
      'この端末の Termius データが取り込みの安全上限を超えているため、何も取り込みませんでした。代わりに Termius の CSV エクスポートを使用してください。';

  @override
  String get termiusLocalReviewNeeded =>
      '取り込む前に確認が必要な Termius ホストがあります（ユーザー名が未設定など）。まだ何も推測・取り込みしていません。下の指摘を確認し、既定のユーザー名を入力するか行を除外してから取り込んでください。';

  @override
  String get cvSectionTitle => '認証情報の可視性';

  @override
  String get cvModePrivateShort => 'プライベート';

  @override
  String get cvModeAdminVisibleShort => '管理者に表示';

  @override
  String get cvModePrivateBody =>
      'プライベート：保存したホストのパスワードや秘密鍵などの認証情報は、あなたのデバイス上でのみ復号されます。サーバー管理者は閲覧できません。マスターパスワードを忘れた場合、管理者もこのデータを復元できません。';

  @override
  String get cvModeAdminVisibleBody =>
      '管理者に表示：このサーバーの管理者は、あなたが保存したホストのパスワード、秘密鍵、パスフレーズを閲覧できます。アカウントのマスターパスワードはサーバーに送信されないため、管理者には見えません。管理者が閲覧するたびに記録され、ここに表示されます。';

  @override
  String get cvModeSetByAdmin => 'この設定はインスタンス管理者のみが変更できます。';

  @override
  String cvChangedAt(String time) {
    return 'モード変更日時：$time';
  }

  @override
  String get cvEscrowStatusLabel => 'エスクローの状態';

  @override
  String get cvEscrowNotRequired => '不要';

  @override
  String get cvEscrowNoKey => 'エスクロー鍵なし';

  @override
  String get cvEscrowPending => '保留中';

  @override
  String get cvEscrowComplete => '完了';

  @override
  String get cvEscrowNoKeyDetail => '管理者がエスクロー鍵を設定するのを待っています。';

  @override
  String get cvEscrowPendingDetail =>
      '一部の Vault 鍵はまだ管理者に提供されていません。デバイスが鍵を保持していれば自動的に送信されます。';

  @override
  String get cvEscrowCompleteDetail => '管理者は、あなたがアクセスできるすべての Vault を開くことができます。';

  @override
  String get cvEscrowKeyRejected =>
      'サーバーから受け取ったエスクロー鍵が署名検証に失敗したため、何も共有されていません。管理者に連絡してください。';

  @override
  String get cvRefreshFailed => '認証情報の可視性の状態を更新できませんでした。自動的に再試行されます。';

  @override
  String get cvAdminViewsTitle => '最近の管理者による閲覧';

  @override
  String get cvAdminViewsEmpty => '管理者による認証情報の閲覧はありません。';

  @override
  String cvAdminViewEntry(String admin, String time) {
    return '$admin が $time にあなたの認証情報を閲覧しました';
  }

  @override
  String get cvAdminViewDeletedAdmin => '削除された管理者';

  @override
  String cvAdminViewVault(String name) {
    return 'Vault：$name';
  }

  @override
  String get cvIndicatorTooltip =>
      'このサーバーの管理者は、保存された認証情報を閲覧できます。詳細は設定を開いてください。';

  @override
  String get cvVaultBadgeTooltip => 'インスタンス管理者はこの Vault 内の認証情報を閲覧できます。';

  @override
  String get cvSharedVaultNotice =>
      'この共有 Vault には「管理者に表示」モードのメンバーがいるため、管理者は中の認証情報を閲覧できます。';

  @override
  String get cvNoticeAdminVisibleTitle => '管理者は保存された認証情報を閲覧できます';

  @override
  String get cvNoticeSwitchedAdminVisibleTitle => 'アカウントが「管理者に表示」に切り替わりました';

  @override
  String get cvNoticeAdminVisibleDeposit =>
      '次回の同期時に、デバイスは Vault 鍵を管理者のエスクロー鍵に預けます。';

  @override
  String get cvNoticePrivateTitle => '保存された認証情報はプライベートです';

  @override
  String get cvNoticeSwitchedPrivateTitle => 'アカウントがプライベートに切り替わりました';

  @override
  String get cvNoticeSwitchedPrivateBody =>
      'エスクローされた Vault 鍵はサーバーから削除され、管理者はあなたの認証情報を開けなくなりました。共有 Vault は、他のメンバーが「管理者に表示」のままの間は閲覧可能で、Vault 一覧に表示されます。「管理者に表示」だった期間に管理者がすでに認証情報を閲覧またはコピーした可能性があるため、重要なパスワードや鍵の変更を検討してください。';

  @override
  String get cvNoticeAcknowledge => '了解しました';

  @override
  String get cvNoticeOpenSettings => '詳細を表示';

  @override
  String get cvRegistrationNoticeTitle => 'このサーバーでは管理者が保存された認証情報を閲覧できます';

  @override
  String get cvRegistrationNoticeBody =>
      'このサーバーの新規アカウントは既定で「管理者に表示」です。管理者は、保存したホストのパスワード、秘密鍵、パスフレーズを閲覧できます。マスターパスワードはサーバーに送信されません。招待で別のモードが指定されている場合は、サインイン後に通知されます。';

  @override
  String get cvAdminDescription =>
      '新規アカウントをプライベートにするか「管理者に表示」にするかを選び、エスクロー鍵を管理し、エスクローされた認証情報を閲覧します。閲覧はすべて記録され、ユーザーに表示されます。';

  @override
  String get cvAdminLoad => '認証情報の可視性を読み込む';

  @override
  String get cvAdminDefaultMode => '新規アカウントの既定';

  @override
  String cvAdminCounts(int adminVisible, int privateCount, int pending) {
    return '管理者に表示 $adminVisible 件 · プライベート $privateCount 件 · 保留中 $pending 件';
  }

  @override
  String get cvAdminKeyTitle => 'エスクロー鍵';

  @override
  String get cvAdminKeyMissing =>
      'エスクロー鍵はまだありません。作成されるまで「管理者に表示」のアカウントは認証情報を共有できません。';

  @override
  String cvAdminKeyReady(String keyId, String time) {
    return '鍵 $keyId · 作成日時 $time';
  }

  @override
  String get cvAdminKeyInvalid =>
      'サーバーから受け取ったエスクロー鍵が署名検証に失敗しました。使用せずにリセットしてください。';

  @override
  String get cvAdminKeyNoWrap =>
      'あなたのアカウントはまだエスクロー鍵を開けません。リカバリーコードでロック解除してください。';

  @override
  String get cvAdminCreateKey => 'エスクロー鍵を作成';

  @override
  String get cvAdminUnlockWithRecovery => 'リカバリーコードでロック解除';

  @override
  String get cvAdminResetKey => 'エスクロー鍵をリセット';

  @override
  String get cvAdminPasswordTitle => 'マスターパスワードの確認';

  @override
  String get cvAdminPasswordBody =>
      'マスターパスワードはこのデバイス上でエスクロー鍵のロックを解除するためだけに使われ、サーバーには送信されません。';

  @override
  String get cvMasterPassword => 'マスターパスワード';

  @override
  String get cvAdminRecoveryTitle => 'エスクローのリカバリーコードを保管';

  @override
  String get cvAdminRecoveryBody =>
      'このコードは一度だけ表示されます。どの管理者アカウントもエスクロー鍵を開けなくなった場合でも、このコードで開くことができます。サーバーとは別にオフラインで保管してください。';

  @override
  String get cvAdminRecoveryCopied => 'リカバリーコードをコピーしました';

  @override
  String get cvAdminRecoveryStored => 'リカバリーコードを保管しました';

  @override
  String get cvAdminRecoveryCodeLabel => 'リカバリーコード';

  @override
  String get cvAdminKeyCreated =>
      'エスクロー鍵を作成しました。「管理者に表示」のアカウントは次回の同期時に Vault 鍵を共有します。';

  @override
  String get cvAdminUnlocked => 'あなたのアカウントでエスクロー鍵を開けるようになりました。';

  @override
  String get cvAdminResetTitle => 'エスクロー鍵をリセットしますか？';

  @override
  String cvAdminResetBody(String word) {
    return 'エスクロー鍵、すべての管理者のコピー、エスクローされたすべての Vault 鍵が削除されます。新しい鍵を作成すると「管理者に表示」のアカウントは再び共有します。すでに閲覧された認証情報は取り消せません。確認のため $word と入力してください。';
  }

  @override
  String get cvAdminResetDone => 'エスクロー鍵をリセットしました。';

  @override
  String cvAdminModeChanged(String username, String mode) {
    return '$username の認証情報の可視性を「$mode」にしました。';
  }

  @override
  String cvAdminConfirmAdminVisibleTitle(String username) {
    return '$username を「管理者に表示」にしますか？';
  }

  @override
  String get cvAdminConfirmAdminVisibleBody =>
      'このユーザーのデバイスは次回の同期時に Vault 鍵をエスクロー鍵に預け、管理者が認証情報を閲覧できることが通知されます。';

  @override
  String cvAdminConfirmPrivateTitle(String username) {
    return '$username をプライベートにしますか？';
  }

  @override
  String get cvAdminConfirmPrivateBody =>
      '他のメンバーが「管理者に表示」のままでない限り、このユーザーの Vault のエスクロー鍵は削除されます。すでに閲覧された認証情報は取り消せません。';

  @override
  String get cvAdminViewCredentials => '認証情報を閲覧';

  @override
  String get cvInstanceDefaultOption => 'インスタンスの既定';

  @override
  String cvViewerTitle(String username) {
    return '$username の認証情報';
  }

  @override
  String get cvViewerBanner => 'この閲覧は記録され、ユーザーに通知されます。';

  @override
  String get cvViewerVaults => 'Vault';

  @override
  String cvViewerVaultUnnamed(String id) {
    return 'Vault $id';
  }

  @override
  String get cvViewerVaultNotEscrowed => 'エスクローされた鍵がないため開けません';

  @override
  String get cvViewerNoVaults => 'このアカウントには Vault がありません。';

  @override
  String get cvViewerOpenVault => '開く';

  @override
  String get cvViewerHosts => 'ホスト';

  @override
  String get cvViewerKeychain => 'キーチェーン';

  @override
  String get cvViewerNoItems => 'ホストやキーチェーン項目はありません。';

  @override
  String cvViewerUndecryptable(int count) {
    return '$count 件の項目を復号できませんでした（鍵エポックがエスクローされていないか、検証に失敗しました）。';
  }

  @override
  String get cvViewerAddress => 'アドレス';

  @override
  String get cvViewerUsername => 'ユーザー名';

  @override
  String get cvViewerPassword => 'パスワード';

  @override
  String get cvViewerPrivateKey => '秘密鍵';

  @override
  String get cvViewerPassphrase => 'パスフレーズ';

  @override
  String cvViewerUsesKeychain(String name) {
    return 'キーチェーン項目 $name を使用';
  }

  @override
  String get cvViewerReveal => '表示';

  @override
  String get cvViewerHide => '隠す';

  @override
  String get cvViewerCopied => 'コピーしました';

  @override
  String get cvClipboardAutoClear => '1分後、またはこのウィンドウを閉じると、クリップボードから消去されます。';

  @override
  String get cvViewerReadOnly => '読み取り専用';

  @override
  String get cvErrorWrongPassword => 'マスターパスワードが正しくありません。';

  @override
  String get cvErrorWrongRecoveryCode => 'リカバリーコードが正しくありません。';

  @override
  String get cvErrorNoKey => 'エスクロー鍵が存在しません。';

  @override
  String get cvErrorKeyExists =>
      '別の管理者が先にエスクロー鍵を作成しました。再読み込みしてから、リカバリーコードでロック解除してください。';

  @override
  String get cvErrorWrapInvalid =>
      'あなたのアカウントではエスクロー鍵を開けません（別のアカウント鍵用に設定されています）。リカバリーコードでロック解除してください。';

  @override
  String get cvErrorScopeChanged => 'サインイン状態が変わりました。もう一度開いてください。';

  @override
  String get cvErrorNotAvailable =>
      'この認証情報は閲覧できません。ユーザーがプライベートであるか、Vault にエスクローされた鍵がありません。';

  @override
  String get cvErrorNotAdmin => 'このアカウントはインスタンス管理者ではありません。';

  @override
  String get cvErrorSignedOut => '続行するには再度サインインしてください。';

  @override
  String get cvModePrivateBodySharedException =>
      'プライベート：保存したホストのパスワードや秘密鍵などの認証情報は、あなたのデバイス上でのみ復号され、サーバー管理者は閲覧できません。ただし「管理者に表示」と表示された共有 Vault は例外です。これらの Vault には「管理者に表示」モードの他のメンバーがいるため、管理者はあなたが保存したものを含むすべての内容を閲覧できます。マスターパスワードを忘れた場合、管理者もプライベートなデータを復元できません。';

  @override
  String get cvShareRecipientChecking => '共有先の認証情報の可視性を確認しています…';

  @override
  String get cvShareRecipientAdminVisibleTitle => '共有先は「管理者に表示」モードです';

  @override
  String cvShareRecipientAdminVisibleBody(String user) {
    return '$user は「管理者に表示」モードです。参加すると、このサーバーの管理者は、あなたが保存したパスワードや鍵を含め、この Vault のすべての内容を閲覧できるようになります。';
  }

  @override
  String get cvShareRecipientConfirm => '管理者がこの Vault を閲覧できるようになることを理解しました';

  @override
  String get cvShareRecipientCheckFailed =>
      '共有先が「管理者に表示」モードかどうかを確認できませんでした。そうであれば、参加後に管理者はこの Vault のすべての内容を閲覧できるようになります。';

  @override
  String get cvShareAnyway => '共有する';

  @override
  String get cvDatabaseNotEncryptedTitle => 'データベースは保存時に暗号化されていません';

  @override
  String get cvDatabaseNotEncryptedBody =>
      'サーバーはデータベースを暗号化せずに保存しています。データベースファイルやバックアップのスナップショットをコピーした人は、アカウントのメタデータを読み取り、管理者のマスターパスワードをオフラインで推測できます。1 回でも当たれば、「管理者に表示」のすべてのアカウントが開かれます。サーバーを停止し、データベース鍵を設定してから、オフラインでデータベースを暗号化してください：';

  @override
  String cvDatabaseEncryptionGuide(String path) {
    return '手順・鍵のバックアップ・制限：$path';
  }

  @override
  String get cvDatabaseEncryptedAtRest => 'データベースは保存時に暗号化されています（SQLCipher）';
}
