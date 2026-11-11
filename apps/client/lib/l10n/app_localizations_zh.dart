// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get languageSystemDefault => '跟随系统';

  @override
  String get languageSettingTitle => '语言';

  @override
  String get languageSettingDescription =>
      '选择此设备的界面语言。“跟随系统”会使用设备语言；不受支持时显示英文。';

  @override
  String languageSettingSystemResolved(Object language) {
    return '跟随系统 · 当前为$language';
  }

  @override
  String get languageSettingSaveFailed => '语言已在本次运行中切换，但无法保存到此设备。';

  @override
  String get languageSettingDevicePreference => '仅保存在此设备，不会同步，也不存入保险库。';

  @override
  String tabSemanticsLabel(Object title, Object status, Object selection) {
    return '$title 终端标签页，$status，$selection';
  }

  @override
  String get tabSemanticsConnected => '已连接';

  @override
  String get tabSemanticsDisconnected => '未连接';

  @override
  String get tabSemanticsActive => '当前';

  @override
  String get tabSemanticsInactive => '非当前';

  @override
  String mfaChallengeTotp(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return '请输入验证器应用中的六位代码以继续。此验证将于 $expiresAtString 过期。';
  }

  @override
  String mfaChallengeRecovery(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return '请输入一次性恢复码以继续。此验证将于 $expiresAtString 过期。';
  }

  @override
  String get propertyAuthentication => '认证';

  @override
  String get propertyStatus => '状态';

  @override
  String get propertyRoute => '路由';

  @override
  String get propertyTags => '标签';

  @override
  String keyEpochLocalMismatch(int epoch) {
    return '同一 key epoch $epoch 在设备本地对应了不同密钥。';
  }

  @override
  String get recoveryCodeCopiedFeedback => '恢复码已复制。';

  @override
  String get recoveryCodeCopyFailedFeedback => '无法复制恢复码。请手动选中并复制。';

  @override
  String sessionsRevokedForSelectedAccount(int count) {
    return '已为所选账户撤销 $count 个会话。';
  }

  @override
  String get usernameOptional => '用户名（可选）';

  @override
  String get forwardRuntimeUnsupported => '此平台无法运行 SSH 端口转发。';

  @override
  String get forwardRuntimeDisconnected => '未连接。你现在可以编辑配置；通过 SSH 连接此主机后即可启动它们。';

  @override
  String get forwardRuntimeRunningNote => '运行中的转发保留在此设备上，并会在此 SSH 连接结束时自动停止。';

  @override
  String forwardStatusRunning(int active, int total) {
    return '运行中 · $active 个活动 · 共 $total 个';
  }

  @override
  String get forwardStatusStopping => '正在停止…';

  @override
  String get forwardStatusStopped => '已停止';

  @override
  String forwardStatusFailed(Object error) {
    return '失败：$error';
  }

  @override
  String get forwardStatusUnknownError => '未知错误';

  @override
  String forwardExposureLocal(Object bind, Object destination) {
    return '你网络中能够访问 $bind 的其他设备，将能够通过你的 SSH 登录连接到 $destination。';
  }

  @override
  String forwardExposureDynamic(Object bind) {
    return '能够访问 $bind 的其他设备，将能够通过你的 SSH 登录使用无需认证的 SOCKS 代理。';
  }

  @override
  String forwardExposureRemoteLoopback(Object destination) {
    return '到达 SSH 服务器的连接将由此设备转发到 $destination。';
  }

  @override
  String forwardExposureRemotePublic(Object destination) {
    return '到达 SSH 服务器的连接将由此设备转发到 $destination，且服务器可能接受来自其他机器的连接。';
  }

  @override
  String forwardRemoteListenerRejected(Object endpoint) {
    return 'SSH 服务器拒绝在 $endpoint 上监听。该端口可能已在服务器上被占用，或被 AllowTcpForwarding/PermitListen 禁止。';
  }

  @override
  String forwardLocalDestinationUnreachable(Object endpoint) {
    return '此设备无法连接到 $endpoint。';
  }

  @override
  String get keybarMore => '更多';

  @override
  String get keybarLess => '收起';

  @override
  String get invalidAttachedFileOwner => '附加文件的所属会话无效。';

  @override
  String get unexpectedWindowCombinationOwnerField => '出现了意外的所属字段。';

  @override
  String get fileSessionSshOwnerMissingFromWindowSet =>
      '文件会话的 SSH 所属会话未包含在组合中。';

  @override
  String get terminalStateConnected => '已连接';

  @override
  String get terminalStateConnecting => '正在连接';

  @override
  String get terminalStateReconnecting => '正在重新连接';

  @override
  String get terminalStateDisconnected => '已断开';

  @override
  String get terminalStateClosed => '已关闭';

  @override
  String get terminalStateEnded => '已结束';

  @override
  String get terminalStateFailed => '失败';

  @override
  String get sshPasswordLabel => 'SSH 密码';

  @override
  String get passwordOptionalLabel => '密码（可选）';

  @override
  String quotedHostName(Object name) {
    return 'Host“$name”';
  }

  @override
  String hostsReferenceUnavailableGroups(int count) {
    return '有 $count 台主机引用了不可用的分组。请编辑受影响的主机，选择当前分组或明确选择“无分组”。';
  }

  @override
  String pendingCountShort(int count) {
    return '$count 项待处理';
  }

  @override
  String get purgeConsentEnabled => '已启用';

  @override
  String get purgeConsentOff => '关闭';

  @override
  String get restoreDeadlineStatusUnavailable => '恢复截止状态：不可用';

  @override
  String get restoreDeadlineStatusPassed => '恢复截止状态：按此设备时钟已过期；最终由服务器决定';

  @override
  String restoreDeadlineStatusFuture(DateTime deadline) {
    final intl.DateFormat deadlineDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String deadlineString = deadlineDateFormat.format(deadline);

    return '恢复截止状态：未到期，$deadlineString';
  }

  @override
  String get groupParentNeedsRepair => '父级关系需要修复';

  @override
  String groupInsideParent(Object parent) {
    return '位于 $parent';
  }

  @override
  String groupHostCount(int count) {
    return '$count 台主机';
  }

  @override
  String groupSubgroupCount(int count) {
    return '$count 个子分组';
  }

  @override
  String get groupDefaultCredentialUnavailable => '默认凭据不可用';

  @override
  String groupDefaultCredentialName(Object name) {
    return '默认凭据：$name';
  }

  @override
  String get credentialPasswordStoredEncrypted => '密码已加密保存';

  @override
  String get credentialPrivateKeyStoredEncrypted => '私钥已加密保存';

  @override
  String get splitAxisSideBySide => '左右并排';

  @override
  String get splitAxisStacked => '上下堆叠';

  @override
  String get execCancelledUnknown => '已取消。远程完成状态未知；命令未重试。';

  @override
  String get execOpenTimedOut => '等待 SSH exec 请求超时。重试前请断开并重新连接；远程完成情况未知。';

  @override
  String get execTimedOutUnknown => '已超时。远程完成状态未知；命令未重试。';

  @override
  String get execOutputTruncated => '输出超过 64 KiB 上限。exec 通道已关闭；完成状态未知。';

  @override
  String get execBashUnavailable =>
      '此目标上没有 Bash，或其登录 Shell 不兼容 POSIX。未执行任何片段内容。';

  @override
  String unableToReviewHostConnectionSettings(Object error) {
    return '无法检查主机连接设置：$error';
  }

  @override
  String get adminJobBackupCompleted => '服务器上的加密备份已完成';

  @override
  String get adminJobBackupFailed => '加密备份失败；请检查服务器备份配置';

  @override
  String get adminJobBackupInterrupted => '加密备份任务已中断';

  @override
  String get adminJobRestorePrepared => '隔离恢复副本已准备完成；未激活';

  @override
  String get adminJobRestoreFailed => '隔离恢复副本准备失败；在线数据未更改';

  @override
  String get adminJobRestorePreparedStatusInterrupted => '恢复副本已准备完成；任务状态更新中断';

  @override
  String get adminJobRestoreInterrupted => '隔离恢复副本准备已中断';

  @override
  String get adminJobMaintenanceFailed => '维护失败；重试前请检查服务器健康状况';

  @override
  String get adminJobMaintenanceInterrupted => '维护已中断；重试前请刷新任务列表';

  @override
  String adminJobResultCode(Object code) {
    return '结果 $code';
  }

  @override
  String get masterPasswordChangedSessionsRevoked => '主密码已更改。其他会话已撤销。';

  @override
  String get masterPasswordChangeConfirmedSessionsRevoked =>
      '已确认主密码更改。其他会话已撤销。';

  @override
  String confirmRemoveMemberAndRotate(Object username) {
    return '移除 $username 并为每台剩余的活动成员设备轮换保险库密钥？被移除的账户不会获得新密钥。现有的旧副本无法被远程擦除。其他待处理的邀请令牌将失效，需要重新签发。';
  }

  @override
  String confirmCancelInvitationAndRotate(Object username) {
    return '取消对 $username 的待处理邀请，并为每台剩余的活动成员设备轮换保险库密钥？被移除的账户不会获得新密钥。现有的旧副本无法被远程擦除。其他待处理的邀请令牌将失效，需要重新签发。';
  }

  @override
  String recycleBinPurgeConsentLine(Object consent) {
    return '$consent。';
  }

  @override
  String recycleBinPurgeConsentLineOwner(Object consent) {
    return '$consent。同意仅适用于此删除标记。启用后，受限的维护任务可能会在其恢复截止时间和其他必要检查之后将其清除。启用同意不会立即清除；离线设备副本和导出文件不会被移除。';
  }

  @override
  String get objectDownloadFailed => '对象下载失败。';

  @override
  String get objectRangeDownloadFailed => '对象范围下载失败。';

  @override
  String get requestFailed => '请求失败。';

  @override
  String get theServerReturnedAnInvalidResponse => '服务器返回了无效的响应。';

  @override
  String consoleExitedCode(int code) {
    return '\r\n[Console 已退出：$code]\r\n';
  }

  @override
  String get thisDevicesSecureStorageCouldntDelete =>
      ' 本机安全存储未能删除旧 refresh token；该 token 已在服务端撤销。';

  @override
  String get someLocalStateCleanupHitAn => ' 本机部分状态清理遇到错误；应用已强制退出当前会话。';

  @override
  String get aVaultRecoveryContextHasNo => '某个保险库恢复上下文没有有效的签名成员资格版本。';

  @override
  String get aCommandSnippetIsAlreadyRunning => '已有命令片段正在运行。';

  @override
  String get aDisabledRecoveryAccountReturnedActive => '已停用恢复的账户返回了活动的恢复材料。';

  @override
  String get aNewRecoveryKeyboxFailedIts => '新的恢复密钥盒未通过本地检查。';

  @override
  String get aNewDeviceKeyEnvelopeFailed => '新的设备密钥信封未通过本地检查。';

  @override
  String get aPreviousSshExecRequestIs =>
      '上一个 SSH exec 请求仍在等待。请断开并重新连接后再运行其他命令。';

  @override
  String get aRecoveryConfirmationIsAlreadyPending => '已有一个待处理的恢复确认。';

  @override
  String get aReferencedSnippetCredentialChangedAfter =>
      '审阅后引用的片段凭据已更改。请重新审阅整个批处理。';

  @override
  String get aRequiredVaultKeyCouldNot => '无法恢复所需的保险库密钥。请检查恢复状态，并尝试使用已注册的设备。';

  @override
  String get aSelectedHostConnectionOrSnippet => '审阅后所选主机、连接或片段已更改。请重新审阅整个批处理。';

  @override
  String get accountRecoveredSignInWithThe2 => '账户已恢复。请在此设备上使用新的主密码登录。';

  @override
  String get accountRecoveryIsBusy => '账户恢复正忙。';

  @override
  String get accountRelayPolicyResetToInherit => '账户中继策略已重置为继承。';

  @override
  String get accountRelayPolicySaved => '账户中继策略已保存。';

  @override
  String accountStatusUpdatedToStatusRevokedsessions(
    String status,
    int revokedSessions,
  ) {
    return '账户状态已更新为 $status；已撤销 $revokedSessions 个会话。';
  }

  @override
  String get anExistingRecoveryKeyboxCouldNot => '现有恢复密钥盒无法验证或打开；拒绝轮换掉唯一的恢复副本。';

  @override
  String get bashExecutionRequiresACancellationHandle => 'Bash 执行需要取消句柄。';

  @override
  String get batchExecutionIsOnlySupportedFor => '批量执行仅支持结构化 Bash 片段。';

  @override
  String get batchTargetsMustBeDistinctConnected => '批处理目标必须是不同的已连接主机。';

  @override
  String get bucketAccessVerifiedWithHeadbucketThis =>
      '已通过 HeadBucket 验证存储桶访问。此检查不验证上传、分段操作、恢复或提供方范围的互操作性。';

  @override
  String chooseBetweenTwoAndMaxterminaltabsConnected(int maxTerminalTabs) {
    return '请选择 2 到 $maxTerminalTabs 台已连接的主机。';
  }

  @override
  String get commandExecutionIsUnavailableNoCommand => '命令执行不可用。未发送任何命令。';

  @override
  String get conflictingSignedRecoveryKeyboxesExistFor =>
      '某个保险库纪元存在冲突的已签名恢复密钥盒。';

  @override
  String get connectThisTerminalBeforeEnablingShell => '启用 Shell 集成前请先连接此终端。';

  @override
  String get connectToTheServerBeforeChecking => '检查备份存储桶访问前请先连接服务器。';

  @override
  String get theConsoleOutputStreamClosed => 'Console 输出流已关闭。';

  @override
  String get couldNotDisableBackgroundSyncNotifications => '无法停用后台同步通知。';

  @override
  String get couldNotEnableBackgroundSyncNotifications => '无法启用后台同步通知。';

  @override
  String get couldNotPersistTheMobilePush => '无法持久保存移动推送退出设置。';

  @override
  String get couldNotRemoveThisDevicesPush => '无法移除此设备的推送端点。';

  @override
  String credentialReferenceNameIsMissingOr(String name) {
    return '凭据引用 $name 缺失或不是密码凭据';
  }

  @override
  String get currentAccountSessionExpired => '当前账户会话已过期。';

  @override
  String get enterTheAccountName => '请输入账户名。';

  @override
  String get groupRelayPolicyResetToInherit => '分组 Relay 策略已重置为继承。';

  @override
  String get groupRelayPolicySaved => '分组 Relay 策略已保存。';

  @override
  String get groupDefault => '分组默认值';

  @override
  String get groupDefaultIsUnavailableChooseA => '分组默认值不可用。请选择主机覆盖或修复分组默认值。';

  @override
  String get groupMembershipSaved => '分组成员资格已保存。';

  @override
  String get hostChangedRepeatedlyWhileSavingReopen => '保存时主机多次更改；请重新打开后重试。';

  @override
  String get hostIdentityChangedWhileTheEditor => '编辑器打开期间主机身份已更改。';

  @override
  String get hostOverrideIsUnavailableChooseInherit =>
      '主机覆盖不可用。请选择“从分组继承”或其他凭据。';

  @override
  String hostOverrideIdentity(String identity) {
    return '主机覆盖：$identity';
  }

  @override
  String get theHostsTagsFieldWasAlso => 'Host 的“Tags”字段在编辑期间也被修改。请重新打开并审阅后重试。';

  @override
  String theHostsLabelFieldWasAlso(String label) {
    return 'Host 的“$label”字段在编辑期间也被修改。请重新打开并审阅后重试。';
  }

  @override
  String inheritedFromValuevalueIdentity(String valueValue, String identity) {
    return '继承自 $valueValue：$identity';
  }

  @override
  String get instanceAdminAccessIsRequiredTo => '检查备份存储桶访问需要实例管理员权限。';

  @override
  String get invalidAdminVaultPaginationResponse => '管理员保险库分页响应无效。';

  @override
  String get invalidAdminAccountInvitationPaginationResponse =>
      '管理员账户邀请分页响应无效。';

  @override
  String get invalidAdminAccountPaginationResponse => '管理员账户分页响应无效。';

  @override
  String get invalidAdminAccountSessionsPaginationResponse => '管理员账户会话分页响应无效。';

  @override
  String get invalidAdminMaintenancePaginationResponse => '管理员维护分页响应无效。';

  @override
  String get invalidMobilePushToken => '移动推送令牌无效。';

  @override
  String get invalidRestoreJobReceipt => '恢复任务回执无效。';

  @override
  String get invalidRestoreSourcePageResponse => '恢复来源分页响应无效。';

  @override
  String invitationCreatedForUsername(String username) {
    return '已为 $username 创建邀请。';
  }

  @override
  String get invitationRevoked => '邀请已撤销。';

  @override
  String jumpHostCredentialForHostnameChanged(String hostName) {
    return '在派发前，$hostName 的跳板主机凭据已更改。剩余批处理已停止。';
  }

  @override
  String jumpHostRoutingForHostnameChanged(String hostName) {
    return '在派发前，$hostName 的跳板主机路由已更改。请重新审阅批处理。';
  }

  @override
  String couldntResolveTheSshCredentialFor(
    String name,
    String connectionError,
  ) {
    return 'Jump Host $name 的 SSH 凭据无法解析：$connectionError';
  }

  @override
  String get theJumpHostMustUseThe => 'Jump Host 必须使用 SSH 协议。';

  @override
  String get theJumpHostRouteChangedWhile => 'Jump Host 路由在连接准备期间发生变化，请重新连接。';

  @override
  String get theJumpHostRouteOrCredential =>
      'Jump Host 路由或凭据在连接准备期间发生变化，请重新连接。';

  @override
  String get theJumpHostChainCantForm => 'Jump Host 链不能形成循环。';

  @override
  String get theJumpHostChainContainsA => 'Jump Host 链包含已不存在的主机；请编辑并修复此引用。';

  @override
  String theJumpHostChainSupportsUp(int maxJumpHostHops) {
    return 'Jump Host 链最多支持 $maxJumpHostHops 层。';
  }

  @override
  String get loadAConsistentAccountAndInstance => '重置前请加载一致的账户和实例策略。';

  @override
  String get loadAConsistentAccountAndInstance2 => '保存前请加载一致的账户和实例策略。';

  @override
  String get loadTheLatestSshRelayPolicy => '保存前请加载最新的 SSH 中继策略。';

  @override
  String get theMfaSignInResponseDoesnt => 'MFA 登录响应与当前账户或设备不匹配。';

  @override
  String get mfaSettingsAreBeingProcessed => 'MFA 设置正在处理中。';

  @override
  String get mfaVerificationFailedTheCodeIs =>
      'MFA 验证失败：验证码无效、已使用或登录挑战已过期。请重新登录并输入新的验证码。';

  @override
  String get mfaVerifiedAndUnlockedLocallyThe =>
      'MFA 验证成功，已在本地解锁；服务端仍只保存加密记录和密钥信封。';

  @override
  String get mustBeBetween0And1000000 => '必须介于 0 到 1000000 之间。';

  @override
  String get mustNotBeNegative => '不能为负数。';

  @override
  String get noS3BackupBucketIsConfigured => '服务器未配置 S3 备份存储桶。';

  @override
  String get noSshCredentialIsConfiguredChoose => '未配置 SSH 凭据。请选择主机覆盖或设置分组默认值。';

  @override
  String get noAccountRecoveryIsAwaitingConfirmation => '没有等待确认的账户恢复。';

  @override
  String get noAuthenticatedSession => '没有经过认证的会话。';

  @override
  String get noEffectiveSshCredentialIsSet => '未设置有效的 SSH 凭据。请选择主机覆盖或设置分组默认值。';

  @override
  String get notStartedBecauseBatchCancellationWas => '由于预检期间请求了取消批处理，未开始。';

  @override
  String get notStartedBecauseBatchCancellationWas2 => '由于请求了取消批处理，未开始。';

  @override
  String get notStartedBecauseThePreviousHost => '由于上一台主机未成功完成，未开始。';

  @override
  String get notStartedBecauseThePreviousHost2 => '由于上一台主机未通过验证或执行失败，未开始。';

  @override
  String get offlineKnownhostApprovalIsLimitedTo =>
      '离线 KnownHost 批准仅限于没有本地信任或撤销历史的首次出现端点。';

  @override
  String get offlineKnownhostQueueDidNotMatch =>
      '离线 KnownHost 队列与明确审阅的 SSH 密钥不符。';

  @override
  String get prometheusScrapeCredentialRevoked => 'Prometheus 抓取凭据已撤销。';

  @override
  String get rdpCertificate => 'RDP 证书';

  @override
  String get recoveryCouldNotBeStartedCheck => '无法开始恢复。请检查账户名和恢复码。';

  @override
  String get recoveryDescriptorHashIsInvalid => '恢复描述符哈希无效。';

  @override
  String get recoveryDescriptorPublicKeysDoNot => '恢复描述符的公钥与封装的身份不符。';

  @override
  String get recoveryIdentityEnvelopeIsMissing => '缺少恢复身份信封。';

  @override
  String get referencedCredentialChangedAfterPreviewReview =>
      '预览后引用的凭据已更改。请检查命令后重试。';

  @override
  String get reloadTheLatestAccountAndInstance => '重置前请重新加载最新的账户和实例策略。';

  @override
  String get reloadTheLatestAccountAndInstance2 => '保存前请重新加载最新的账户和实例策略。';

  @override
  String get reloadTheLatestGroupAndInstance => '重置前请重新加载最新的分组和实例策略。';

  @override
  String get reloadTheLatestGroupAndInstance2 => '保存前请重新加载最新的分组和实例策略。';

  @override
  String get reloadTheLatestPolicyAfterThe => '修订冲突后请先重新加载最新策略再重试。';

  @override
  String get restoreIsEncryptedAndQueuedOn => '恢复已加密并在此设备上排队；同步状态将重试。';

  @override
  String get restoreIsEncryptedLocallyAndWaiting => '恢复已在本地加密，正在等待同步。';

  @override
  String get restoreIsSafelyQueuedOnThis => '恢复已安全排队在此设备上，服务器可访问时会重试。';

  @override
  String get restoreStageResponseDidNotMatch => '恢复暂存响应不匹配。';

  @override
  String get retryThePendingAccountRecoveryCompletion => '登录前请重试待完成的账户恢复。';

  @override
  String get theSftpDocumentBelongsToA => 'SFTP 文档属于另一个 SSH 会话。';

  @override
  String get theSftpServerVersionDoesntSupport => 'SFTP 服务器版本不支持安全的文件上传。';

  @override
  String get theSftpServerVersionIsBelow => 'SFTP 服务器版本低于 3，不支持安全的文本编辑。';

  @override
  String sshCredentialForHostnameChangedBefore(String hostName) {
    return '在派发前，$hostName 的 SSH 凭据已更改。剩余批处理已停止。';
  }

  @override
  String get sshConnectionOrHostChangedAfter => '预览后 SSH 连接或主机已更改。请检查目标后重试。';

  @override
  String get sshExecFailedAfterDispatchRemote =>
      'SSH exec 在派发后失败。远程完成状态未知；命令未重试。';

  @override
  String get sshHostKeyApprovalProofAccount => 'SSH 主机密钥批准证明的账户或保险库范围已更改。';

  @override
  String get sshHostKeyTestDecisionBecame => 'SSH 主机密钥测试决定已过时。';

  @override
  String sshHostKeyTrustChangedFor(String hostName) {
    return '$hostName 的 SSH 主机密钥信任已更改。请重新连接并重新审阅批处理。';
  }

  @override
  String sshHostKeyVerificationEvidenceIs(String hostName) {
    return '缺少 $hostName 的 SSH 主机密钥验证证据。运行批处理前请重新连接。';
  }

  @override
  String get sshRelayPolicySaved => 'SSH 中继策略已保存。';

  @override
  String get sshHostKeyTrustWasConfirmed => 'SSH 主机密钥信任已在当前 Vault 同步确认。';

  @override
  String get sshHostKeyTrustWasRevoked => 'SSH 主机密钥信任已撤销并加密保存到当前 Vault。';

  @override
  String get theSshHostKeyApprovalWas =>
      'SSH 主机密钥审批已加密排队；当前连接已停止，待 Vault 同步确认后再连接。';

  @override
  String get theSshHostOrJumpHost => 'SSH 主机或 Jump Host 路由已变化，请重新连接后重试。';

  @override
  String get theSshHostSettingsChangedReconnect => 'SSH 主机配置已变化；请重新连接当前工作区窗格。';

  @override
  String get sshSessionClosed => 'SSH 会话已关闭';

  @override
  String get sshCredentials2 => 'SSH 凭据';

  @override
  String get theSshCredentialWasSavedEncrypted =>
      'SSH 凭据已加密保存并加入本地待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get sshCredentialSavedEncryptedPlaintextIs =>
      'SSH 凭据已加密保存；明文只在解锁会话中保留。';

  @override
  String get theSshCredentialChangedReconnectThe => 'SSH 凭据已变化；请重新连接当前工作区窗格。';

  @override
  String get theSshCredentialOrHostSettings => 'SSH 凭据或主机配置已变化；请重新连接当前工作区窗格。';

  @override
  String get sshStoppedTheFirstHostKey =>
      'SSH 已停止：首次主机密钥审批已加密排队，Vault 同步确认后请重新连接。';

  @override
  String sshConnectedToEndpoint(String endpoint) {
    return 'SSH 已连接到 $endpoint。';
  }

  @override
  String get sshSignInDetails => 'SSH 登录信息';

  @override
  String get theSshTerminalIsClosedSo => 'SSH 终端已关闭，无法授予输入控制。';

  @override
  String get theSshConnectionClosedReconnectThe => 'SSH 连接已关闭；请重新连接当前工作区窗格。';

  @override
  String get selectAVaultBeforeResolvingThis => '解析此凭据前请先选择保险库。';

  @override
  String get selectAVaultBeforeResolvingThis2 => '解析此主机前请先选择保险库。';

  @override
  String get selectAnActiveMemberOfThis => '请选择此服务器管理分组中的活动成员。';

  @override
  String get selectedSessionRevoked => '所选会话已撤销。';

  @override
  String get selectedSessionWasAlreadyRevoked => '所选会话此前已被撤销。';

  @override
  String get serverActivationWasSuperseded => '服务器激活已被取代。';

  @override
  String get serverCommittedTheRotationButThe => '服务器已提交轮换，但新的本地密钥状态未通过验证。';

  @override
  String get serverStateAdvancedUnexpectedlyDuringRotation =>
      '轮换恢复期间服务器状态意外前进。';

  @override
  String get signOutBeforeStartingFullAccount => '开始完整账户恢复前请先退出登录。';

  @override
  String get snippetArgumentsChangedAfterPreviewReview => '预览后片段参数已更改。请检查后重试。';

  @override
  String get snippetArgumentsChangedAfterReviewReview =>
      '审阅后片段参数已更改。请重新审阅整个批处理。';

  @override
  String get snippetDefinitionChangedAfterPreviewReview => '预览后片段定义已更改。请检查后重试。';

  @override
  String get snippetScriptIsEmpty => '片段脚本为空';

  @override
  String get splitWorkspacesRequireExactlyTwoHosts => '分屏工作区需要恰好两台主机。';

  @override
  String get storedNextRecoveryPackageIsInvalid => '已保存的下一个恢复包无效。';

  @override
  String get storedRecoveryChallengeIsInvalid => '已保存的恢复挑战无效。';

  @override
  String get storedRecoveryDeviceKeyIsInvalid => '已保存的恢复设备密钥无效。';

  @override
  String get storedRecoveryDeviceProofIsInvalid => '已保存的恢复设备证明无效。';

  @override
  String get storedRecoveryRequestDoesNotMatch => '已保存的恢复请求与此服务器实例不匹配。';

  @override
  String get theGroupInheritanceChainIsUnavailable => '分组继承链不可用。请选择有效分组或主机覆盖。';

  @override
  String get theHostGroupInheritanceChainIs => '主机的分组继承链不可用。请选择有效分组或主机凭据覆盖。';

  @override
  String get theHostDidNotReturnA => '主机未返回 Bash 执行结果。';

  @override
  String get theSshExecRequestFailedAfter => 'SSH exec 请求在派发后失败。';

  @override
  String get theAccountNowInheritsTheInstance => '此账户现在继承实例中继策略。';

  @override
  String get theEffectiveSshCredentialIsUnavailable =>
      '生效的 SSH 凭据不可用。请选择有效的主机覆盖或修复分组默认值。';

  @override
  String get theEnabledRecoveryIdentityHasAn => '已启用的恢复身份代次无效。';

  @override
  String get theEncryptedSshHostKeyApproval => '加密的 SSH 主机密钥批准未能持久排队。';

  @override
  String get theExistingRecoveryDescriptorDoesNot => '现有恢复描述符与其封装的身份不符。';

  @override
  String get theGroupNowInheritsTheInstance => '此分组现在继承实例 Relay 策略。';

  @override
  String get theInstanceRelayPolicyChangedWhile =>
      '加载此分组期间实例 Relay 策略已更改。请重新加载以获取一致的快照。';

  @override
  String get theInstanceRelayPolicyChangedReload =>
      '实例 Relay 策略已更改。查看实际访问权限前请重新加载此分组。';

  @override
  String get theInstancePolicyChangedWhileResetting =>
      '重置期间实例策略已更改。请重新加载最新策略；你的草稿已保留。';

  @override
  String get theInstancePolicyChangedWhileSaving =>
      '保存期间实例策略已更改。请重新加载最新策略；你的草稿已保留。';

  @override
  String get theInstanceRelayPolicyChangedWhile2 =>
      '加载此账户策略期间实例中继策略已更改。请重新加载以获取一致的快照。';

  @override
  String get theMergedHostRecordIsInvalid => '合并后的主机记录无效。';

  @override
  String get theNewMasterPasswordMustContain => '新主密码至少需要 12 个字符。';

  @override
  String get theNewMasterPasswordsDoNot => '两次输入的新主密码不一致。';

  @override
  String get theRecoveryChallengeExpiredStartAgain => '恢复挑战已过期。请重新开始。';

  @override
  String get theRecoveryCodeOrServerDescriptor => '恢复码或服务器描述符无效。';

  @override
  String get theRecoveryCompletionReceiptIsInvalid => '恢复完成回执无效。';

  @override
  String get theRecoveryResponseDidNotMatch => '恢复响应与此账户不匹配。';

  @override
  String get theRelayPolicyChangedElsewhereReload =>
      '中继策略已在其他地方更改。重试前请重新加载最新设置。';

  @override
  String theReviewedSshSessionForHostname(String hostName) {
    return '在派发前，$hostName 的已审阅 SSH 会话已更改。';
  }

  @override
  String get theServerCouldNotVerifyAccess => '服务器无法验证对已配置 S3 备份存储桶的访问。';

  @override
  String get theServerDeploymentDoesNotCurrently =>
      '服务器部署当前不允许此中继设置。你的编辑仍保留在这里；请检查部署限制后重试。';

  @override
  String get theServerOrAuthenticationStateChanged => '恢复期间服务器或认证状态已更改。请重新开始。';

  @override
  String get theServerRestorePeriodHasNot => '服务端恢复期尚未结束。';

  @override
  String get thisSnippetReferencesACredentialThat => '此片段引用的凭据当前不可用。请先恢复该凭据。';

  @override
  String get thisCommandPreviewHasAlreadyBeen => '此命令预览已确认。';

  @override
  String get thisRecordTypeCannotBeRestored => '此客户端版本无法恢复此记录类型。';

  @override
  String get thisRecoveryCodeBelongsToAnother => '此恢复码属于另一个服务器实例。';

  @override
  String get thisWorkspaceReferencesAHostThat => '此工作区引用的主机当前不可用。请先恢复该主机。';

  @override
  String get tooManySshHostKeyChecks => '此路由请求的 SSH 主机密钥检查过多。';

  @override
  String get unableToLoadTheSshRelay => '无法加载 SSH 中继策略。请检查连接后重试。';

  @override
  String get unableToSaveTheSshRelay => '无法保存 SSH 中继策略。请检查连接后重试。';

  @override
  String get vaultChangedWhileSshHostKey => '审阅 SSH 主机密钥批准期间保险库已更改。';

  @override
  String get vaultChangedWhileSshHostKey2 => '保存 SSH 主机密钥批准期间保险库已更改。';

  @override
  String get vaultChangedWhileSshHostKey3 => '同步 SSH 主机密钥批准期间保险库已更改。';

  @override
  String get vaultChangedWhileSshHostKey4 => '保存 SSH 主机密钥撤销期间保险库已更改。';

  @override
  String get vaultContainsAnUnsupportedReferenceRecord => '保险库包含不受支持的引用记录类型。';

  @override
  String get vaultContainsDuplicateCredentialIdentities => '保险库包含重复的凭据身份。';

  @override
  String get vaultKeysAreBeingCleared => '正在清除保险库密钥。';

  @override
  String vaultQuotaUpdatedToQuotabytesBytes(int quotaBytes) {
    return '保险库配额已更新为 $quotaBytes 字节。';
  }

  @override
  String get vaultReferenceRecordIdentityIsMalformed => '保险库引用记录的身份格式错误。';

  @override
  String get vaultSyncDidNotConfirmThe => '保险库同步未确认已审阅的 SSH 主机密钥批准。';

  @override
  String get vaultSyncDidNotConfirmThis =>
      '保险库同步未确认此 SSH 密钥批准。连接已停止；请同步保险库并重新审阅密钥。';

  @override
  String get vaultSyncIsUnavailableExistingSsh =>
      '保险库同步不可用。必须先在线检查现有 SSH 主机密钥历史，此连接才能继续。';

  @override
  String vaultIdHasConflictingDeviceKeys(String id) {
    return '保险库 $id 的同一密钥纪元存在冲突的设备密钥。';
  }

  @override
  String vaultIdHasNoKeyEnvelope(String id) {
    return '保险库 $id 没有其活动密钥纪元的密钥信封。';
  }

  @override
  String vaultIdHasNoKeyEnvelope2(String id) {
    return '保险库 $id 没有当前设备的密钥信封。';
  }

  @override
  String vaultIdKeyEnvelopeEpochDoes(String id) {
    return '保险库 $id 的密钥信封纪元与其成员资格版本不符。';
  }

  @override
  String vaultIdKeyEnvelopeRefersTo(String id) {
    return '保险库 $id 的密钥信封引用了未知的成员资格版本。';
  }

  @override
  String vaultIdKeyEnvelopeSignerIs(String id) {
    return '保险库 $id 的密钥信封签名者在签名版本中不是成员。';
  }

  @override
  String vaultIdLatestSignedMembershipEpoch(String id) {
    return '保险库 $id 最新签名的成员资格纪元与服务器描述不符。';
  }

  @override
  String vaultIdLegacyDisplayNameEnvelope(String id) {
    return '保险库 $id 的旧版显示名称信封无法用任何可用纪元密钥打开。';
  }

  @override
  String vaultIdMembershipDoesNotInclude(String id) {
    return '保险库 $id 的成员资格未将此账户列为活动成员。';
  }

  @override
  String vaultIdSignedDisplayNameEnvelope(String id) {
    return '保险库 $id 的签名显示名称信封无效。';
  }

  @override
  String theEpochEpochKeyForVault(String id, int epoch) {
    return 'Vault $id 的 epoch $epoch 密钥缺失；批准已中止。';
  }

  @override
  String theCurrentKeyEpochOfVault(String id) {
    return 'Vault $id 的当前密钥 epoch 不在本设备上，不能批准该设备。';
  }

  @override
  String theSigningDeviceForVaultId(String id) {
    return 'Vault $id 的签名设备未知，无法验证密钥信封。';
  }

  @override
  String vaultSubstring(String substring) {
    return '保险库 $substring';
  }

  @override
  String vaultVaultidChangedOwnerWithoutA(String vaultId) {
    return '保险库 $vaultId 在没有前任所有者签署转移的情况下更换了所有者。';
  }

  @override
  String vaultVaultidHasAnOwnershipTransfer(String vaultId) {
    return '保险库 $vaultId 存在由新所有者签署的所有权转移。';
  }

  @override
  String vaultVaultidMembershipHasAnInvalid(String vaultId) {
    return '保险库 $vaultId 的成员资格包含无效成员。';
  }

  @override
  String vaultVaultidMembershipHasNoMembers(String vaultId) {
    return '保险库 $vaultId 的成员资格中没有成员。';
  }

  @override
  String vaultVaultidMembershipMustContainExactly(String vaultId) {
    return '保险库 $vaultId 的成员资格必须恰好包含一名活动所有者。';
  }

  @override
  String vaultVaultidMembershipSignerIsAbsent(String vaultId) {
    return '保险库 $vaultId 的成员资格签名者不在其设备目录中。';
  }

  @override
  String vaultVaultidMembershipWasNotSigned(String vaultId) {
    return '保险库 $vaultId 的成员资格未由其活动所有者签署。';
  }

  @override
  String vaultVaultidOwnershipTransferChangedUnrelated(String vaultId) {
    return '保险库 $vaultId 的所有权转移更改了无关的成员资格数据。';
  }

  @override
  String vaultVaultidOwnershipTransferDoesNot(String vaultId) {
    return '保险库 $vaultId 的所有权转移不符合已签名的所有者和纪元链。';
  }

  @override
  String vaultVaultidOwnershipTransferMetadataIs(String vaultId) {
    return '保险库 $vaultId 的所有权转移元数据无效。';
  }

  @override
  String vaultVaultidOwnershipTransferUnexpectedlyChanged(String vaultId) {
    return '保险库 $vaultId 的所有权转移意外更改了成员集合。';
  }

  @override
  String theApprovalKeyEnvelopeSignatureFor(String vaultId) {
    return 'Vault $vaultId 的审批密钥信封签名无效。';
  }

  @override
  String theApprovedKeyForVaultVaultid(String vaultId) {
    return 'Vault $vaultId 的批准密钥未能解封为服务端密钥。';
  }

  @override
  String theServerKeyEnvelopeForVault(String vaultId) {
    return 'Vault $vaultId 的服务端密钥信封与批准文件不一致。';
  }

  @override
  String get someActiveDevicesInTheVault =>
      'Vault 中仍有活跃设备不支持 schema 2 或 1 GiB 附件。请更新这些设备，或将不再使用的活跃设备从 Vault 中移除后重试。';

  @override
  String get vaultCreationReturnedSuccessButThe =>
      'Vault 创建已返回成功，但服务端尚未能验证暂存数据；迁移日志已保留。';

  @override
  String get theVaultCreationResultCantBe => 'Vault 创建结果暂时无法确认；迁移日志已保留，请稍后恢复。';

  @override
  String get theVaultDeletionGracePeriodHas => 'Vault 删除宽限期已结束，无法撤销删除。';

  @override
  String get theVaultDeletionScheduleWasCreated => 'Vault 删除计划已创建；服务端截止时间已更新。';

  @override
  String get theVaultDeletionScheduleWasCancelled => 'Vault 删除计划已撤销，写入权限已恢复。';

  @override
  String get theVaultSyncStateIsAbnormal => 'Vault 同步状态异常，无法安全验证 SSH 主机密钥。';

  @override
  String get theVaultNameHasntBeenVerified => 'Vault 名称尚未通过密钥验证，已停止创建成员邀请。';

  @override
  String get theVaultNameHasntBeenVerified2 => 'Vault 名称尚未通过密钥验证，已停止成员密钥轮换。';

  @override
  String get theVaultWasSwitchedWhilePreparing => 'Vault 在工作区连接准备期间已切换，请重新连接。';

  @override
  String get theVaultKeyStateStillCant => 'Vault 密钥状态仍未能验证；本地待同步数据已保留。';

  @override
  String get youCantSwitchVaultsWhileThe => 'Vault 密钥轮换期间不能切换 Vault。';

  @override
  String get theVaultHasntFinishedFullySyncing => 'Vault 尚未完成当前版本的完整同步，请同步后重试。';

  @override
  String get theVaultWasSwitchedReopenThe => 'Vault 已切换，请重新打开 Host 后重试。';

  @override
  String get theVaultWasSwitchedReopenThe2 => 'Vault 已切换，请重新打开凭据后重试。';

  @override
  String get theVaultWasSwitchedReopenThe4 => 'Vault 已切换，请重新打开分组后重试。';

  @override
  String get theVaultWasSwitchedReopenThe3 => 'Vault 已切换，请重新打开回收站。';

  @override
  String get theVaultWasSwitchedReopenThe5 => 'Vault 已切换，请重新打开片段后重试。';

  @override
  String get theVaultWasSwitchedThePreference => 'Vault 已切换；偏好修复已暂停。';

  @override
  String get theVaultWasSwitchedCommandHistory => 'Vault 已切换；命令历史同步未启用。';

  @override
  String get vaultCreatedItsKeyWasGenerated => 'Vault 已创建，密钥由当前设备生成并签名。';

  @override
  String get theVaultsCurrentEpochOrMembership => 'Vault 当前 epoch 或成员版本无效。';

  @override
  String get theVaultsCurrentKeyEpochDoesnt => 'Vault 当前密钥 epoch 与签名成员清单不一致。';

  @override
  String get aVaultMemberChangeIsIn => 'Vault 成员变更正在处理中，请稍后重试。';

  @override
  String get localChangesArePausedDuringThe =>
      'Vault 成员密钥轮换期间已暂停本地修改，请轮换完成后重试。';

  @override
  String get theVaultMemberKeyRotationIs => 'Vault 成员密钥轮换正在提交，请完成后再锁定工作区。';

  @override
  String get theVaultMemberKeyRotationIs2 => 'Vault 成员密钥轮换正在提交，请完成后再锁定账户。';

  @override
  String get vaultMembersOrTheSignedIn => 'Vault 成员或登录设备已变化，请重新选择观察者设备。';

  @override
  String get invalidVaultMembershipVersionSyncAnd => 'Vault 成员版本无效，请同步后重试。';

  @override
  String get vaultMembershipChangedUnlockToVerify =>
      'Vault 成员状态已变化；请解锁以验证最新权限和密钥。';

  @override
  String get theVaultOrSshConnectionChanged =>
      'Vault 或 SSH 连接已变化；请重新连接当前工作区窗格。';

  @override
  String get theVaultOrSignInSession => 'Vault 或登录会话已切换，请重新打开回收站。';

  @override
  String get theVaultOrSignedInDevice => 'Vault 或登录设备已变化，已取消加入终端共享。';

  @override
  String get theVaultOrSignedInDevice2 => 'Vault 或登录设备已变化，已取消重连终端共享。';

  @override
  String get theVaultOrDeviceStateChanged => 'Vault 或设备状态已变化，请重新打开终端共享。';

  @override
  String get vaultOwnershipWasTransferredThisAccount =>
      'Vault 所有权已转移；当前账户保留 editor 访问，新 Owner 与所有保留活跃设备已收到新 epoch 密钥。待接受邀请的 token 已失效，需由新 Owner 重新邀请。';

  @override
  String get theVaultIsRestoringOrChanging =>
      'Vault 正在恢复或变更成员状态，暂时不能验证 SSH 主机密钥。';

  @override
  String get aVaultStateActionIsIn => 'Vault 状态操作正在处理中，请稍后重试。';

  @override
  String get theVaultDeviceDirectoryIsMissing => 'Vault 设备目录缺少有效账户或签名公钥。';

  @override
  String get theTmuxSessionStartedAndWas => 'tmux 会话已启动并加密保存到工作区。';

  @override
  String get theTmuxActionTimedOutCheck => 'tmux 操作超时；请检查主机状态后重试。';

  @override
  String theLabelPreferenceConflictWasRepaired(String label) {
    return '$label偏好冲突已修复并通过服务端同步确认。';
  }

  @override
  String theLabelPreferenceConflictWasConfirmed(String label) {
    return '$label偏好冲突已同步确认。';
  }

  @override
  String messageCode(String message, String code) {
    return '$message（$code）';
  }

  @override
  String noticemessageThisDeviceCouldntSaveThe(Object noticeMessage) {
    return '$noticeMessage 本机无法保存当前会话同步状态；其他已打开标签页可能需要重新登录。';
  }

  @override
  String get uploadMissingEncryptedObjectsAndRestore => '上传缺失加密对象并原子恢复本地状态';

  @override
  String get youCantRevokeThisDeviceFrom => '不能从当前设备撤销自身';

  @override
  String get theCurrentlySignedInAdminAccount => '不能从此入口操作当前登录的管理员账户。';

  @override
  String get aGroupCantBeMovedInto => '不能将分组移动到自身或其子分组中。';

  @override
  String get theCurrentVaultOwnerCantBe => '不能通过成员轮换撤销或降级当前 Vault Owner。';

  @override
  String get theVaultOwnerCantBeRevoked => '不能通过此操作撤销或降级 Vault Owner。';

  @override
  String get theNewMasterPasswordsDontMatch => '两次输入的新主密码不一致。';

  @override
  String get thePersonalVaultWasGeneratedAnd =>
      '个人 Vault 已在此设备生成并加密，密钥不会发送给服务端。';

  @override
  String get aMasterPasswordChangeIsIn => '主密码变更正在处理中，请完成后再注销账户。';

  @override
  String get aMasterPasswordChangeIsIn2 => '主密码变更正在处理中，请稍后重试。';

  @override
  String get theMasterPasswordChangeIsBeing => '主密码变更正在提交，请完成后再锁定工作区。';

  @override
  String get theMasterPasswordChangeIsBeing2 => '主密码变更正在提交，请完成后再锁定账户。';

  @override
  String get masterPasswordChangedOtherSignIn => '主密码已变更；其他登录会话已撤销。';

  @override
  String get theMasterPasswordWasCommittedBut => '主密码已提交，但账户资料刷新结果不一致；请重试以确认。';

  @override
  String get theMasterPasswordMustBeAt2 => '主密码至少需要 12 个字符';

  @override
  String get theMasterPasswordMustBeAt3 => '主密码至少需要 12 个字符。';

  @override
  String get masterPasswordVerificationFailedTheDeletion =>
      '主密码验证失败；删除计划未更改，请重新输入主密码。';

  @override
  String get aHostCantUseItselfAs => '主机不能将自身设为 Jump Host。';

  @override
  String get theHostCouldntBeReadBack => '主机保存后无法重新读取。';

  @override
  String get theHostHasntGrantedThisDevice => '主机尚未向此设备授予有效的输入控制。';

  @override
  String get theHostNoLongerExistsResync => '主机已不存在，请重新同步后重试。';

  @override
  String get theHostWasSavedEncryptedAnd => '主机已加密保存并加入本地待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get theHostWasSavedEncryptedLocally => '主机已在本地加密保存，等待同步。';

  @override
  String get theHostRevokedOrEndedInput => '主机已撤销或结束输入控制。';

  @override
  String get theHostOrJumpHostRoute => '主机或 Jump Host 路由在连接准备期间发生变化，请重新连接。';

  @override
  String get hostInputControlEnded => '主机输入控制已结束。';

  @override
  String get hostInputControlAuthorizationExpired => '主机输入控制授权已过期。';

  @override
  String get onlyIsolatedRestoreCopiesInThe => '仅可丢弃状态为“已准备”的隔离还原副本，请刷新任务列表。';

  @override
  String get theJobIsStillRunningAnd => '任务仍在运行，自动状态检查已暂停。可手动刷新任务状态。';

  @override
  String get theJobStatusIsTemporarilyUnavailable =>
      '任务状态暂不可用，自动状态检查已暂停。可手动刷新任务状态。';

  @override
  String get theSessionWasRefreshedButThe =>
      '会话已刷新，但新会话快照无法安全保存；此标签页可暂时继续使用，其他标签页需要重新登录。';

  @override
  String get theSavedTmuxSessionNoLonger => '保存的 tmux 会话已不存在；不会自动创建新会话。';

  @override
  String get theRepairTombstoneHasntBeenConfirmed =>
      '修复墓碑尚未通过服务端变更游标确认，请同步后重试。';

  @override
  String get theCandidateRecordIsMissingA => '候选记录缺少已验证的当前版本，修复已暂停。';

  @override
  String get aPreferenceRepairIsInProgress => '偏好修复正在进行，请等待完成后重试。';

  @override
  String get thePreferenceRepairStateCantBe => '偏好修复状态无法验证，请重试同步后再继续。';

  @override
  String get thePreferenceRepairStateCantBe2 => '偏好修复状态无法验证，需要重新同步后再处理。';

  @override
  String get theSharedSessionEndedAndThe => '共享会话已结束，已撤销输入控制租约。';

  @override
  String get compatibleSftpDownloadsOnlySupportFiles =>
      '兼容 SFTP 下载仅支持 16 MiB 以内的文件';

  @override
  String get invalidCompatibleDownloadSizeLimit => '兼容下载大小限制无效';

  @override
  String get preparingExport => '准备导出';

  @override
  String get preparingVerification => '准备验证';

  @override
  String get theCredentialNameCantBeEmpty => '凭据名称不能为空';

  @override
  String get theCredentialUserNameCantBe => '凭据用户名不能为空';

  @override
  String get theShareRequestComesFromA => '分享请求来自另一个服务端实例。';

  @override
  String get groups => '分组';

  @override
  String get theGroupDeletionWasSavedEncrypted =>
      '分组删除已加密保存并加入本地待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get theGroupDeletionWasSavedEncrypted2 => '分组删除已加密保存，将在同步后传播到其他设备。';

  @override
  String get theGroupNameCantExceed256 => '分组名称不能超过 256 个 UTF-8 字节。';

  @override
  String get theGroupNameContainsUnsupportedControl => '分组名称包含不支持的控制字符。';

  @override
  String get theGroupWasSavedEncryptedAnd =>
      '分组已加密保存并加入本地待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get groupSavedEncryptedWaitingToSync => '分组已加密保存，等待同步。';

  @override
  String get invalidGroupColor => '分组颜色无效。';

  @override
  String get anAccountBeingDeletedCantPerform => '删除中的账户不能执行此操作。';

  @override
  String get anAccountBeingDeletedCantRevoke => '删除中的账户不能撤销会话。';

  @override
  String get theDeletionTombstoneIsStillWaiting => '删除墓碑仍等待变更流确认，请重试同步。';

  @override
  String get theDeletionTombstoneWasSavedEncrypted =>
      '删除墓碑已加密保存并加入本地待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get theDeletionWasSavedAsAn => '删除已作为加密墓碑保存，将在同步后传播到其他设备。';

  @override
  String get encryptedBackupJobSubmittedItsStatus => '加密备份任务已提交。任务状态会显示在下方列表中。';

  @override
  String get protocol2 => '协议';

  @override
  String get anotherSyncTaskIsStillRunning => '另一个同步任务仍在进行，请完成后重试偏好修复。';

  @override
  String get anotherInstanceAdminJobIsRunning => '另一个实例管理任务正在运行，请稍后重试。';

  @override
  String get onlyTheVaultOwnerCanManage => '只有 Vault Owner 可以管理删除计划。';

  @override
  String get onlyTheVaultOwnerCanManage2 => '只有 Vault Owner 可以管理成员。';

  @override
  String get onlyTheVaultOwnerCanInvite => '只有 Vault owner 可以邀请成员。';

  @override
  String get onlyTheCurrentVaultOwnerCan => '只有当前 Vault Owner 可以更改自动清理授权。';

  @override
  String get onlyTheCurrentVaultOwnerCan2 => '只有当前 Vault Owner 可以永久清理记录。';

  @override
  String get inputControlCanOnlyBeGranted => '只能向本次共享时明确批准的设备授予输入控制。';

  @override
  String get onlyExistingHostsInTheCurrent => '只能引用当前 Vault 中现有的主机。';

  @override
  String get aVaultWithThisIdAlready => '同一 Vault ID 已存在，但不是这次暂存的新空 Vault。';

  @override
  String get aGroupWithThisNameAlready => '同一父级下已有同名分组，请修改名称或选择其他父级。';

  @override
  String get theSyncVaultWasSwitchedOr => '同步 Vault 已切换或不再可写；迁移已暂停。';

  @override
  String get theSyncVaultWasSwitchedMigration => '同步 Vault 已切换；迁移已暂停。';

  @override
  String get aSyncIsStillRunningThe => '同步仍在进行；成员变更已取消，请稍后重试。';

  @override
  String get aSyncIsStillRunningRetry => '同步仍在进行；请完成后重试偏好修复。';

  @override
  String get theConflictCandidatesOrVersionsChanged =>
      '同步后冲突候选值或版本已变化，请核对列表后重新选择。';

  @override
  String syncCompleteReceivedcountChangesReceived(int receivedCount) {
    return '同步完成：收到 $receivedCount 条变更。';
  }

  @override
  String get theMasterPasswordCantBeChanged => '同步或快照恢复期间不能变更主密码，请完成后重试。';

  @override
  String get theAccountCantBeDeletedDuring => '同步或快照恢复期间不能注销账户，请完成后重试。';

  @override
  String get name => '名称';

  @override
  String get address => '地址';

  @override
  String get theBackupIntervalMustBe1 => '备份间隔必须为 1 到 720 小时。';

  @override
  String get aMasterPasswordChangeIsWaiting => '存在待确认的主密码变更；请先重试原操作。';

  @override
  String get theInstanceIsAlreadyInitializedFirst => '实例已完成初始化，不能再使用首账号注册。';

  @override
  String get theAuditCursorExpiredTheServer =>
      '审计游标已过期。服务端可能已切换 generation，请重新从第一页加载。';

  @override
  String get thePasswordCantBeEmpty => '密码不能为空';

  @override
  String get thePasswordChangeOperationStateConflicts =>
      '密码变更操作状态冲突。为避免重复修改，请保留当前会话并联系管理员。';

  @override
  String get noServerInstanceIsConfiguredYet => '尚未配置服务端实例。';

  @override
  String get nestedWorkspacesCanOnlyReferenceExisting =>
      '嵌套工作区只能引用当前 Vault 中现有的主机。';

  @override
  String get theWorkspaceTmuxReferenceChangedReload =>
      '工作区 tmux 引用已变化，请重新加载后重试。';

  @override
  String get theWorkspaceHostWasRemovedFrom =>
      '工作区主机在连接准备期间已从当前 Vault 移除，请先修复引用。';

  @override
  String get theWorkspaceDeletionWasAddedTo =>
      '工作区删除已加入本地加密待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get theWorkspaceDeletionWasSavedEncrypted =>
      '工作区删除已加密保存，将在同步后传播到其他设备。';

  @override
  String get workspacesCanOnlyAddReferencesTo => '工作区只能新增引用当前 Vault 中现有的主机。';

  @override
  String get theWorkspaceNoLongerExistsIn => '工作区已不存在于当前 Vault。';

  @override
  String get theWorkspaceWasSwitchedTryAgain => '工作区已切换，请重试。';

  @override
  String get theWorkspaceWasSavedEncryptedAnd =>
      '工作区已加密保存并加入本地待同步队列；同步状态刷新失败，将稍后重试。';

  @override
  String get workspaceSavedEncryptedWaitingToSync => '工作区已加密保存，等待同步。';

  @override
  String get theWorkspaceChanged => '工作区已变化。';

  @override
  String get theWorkspaceIsLockedButThis =>
      '工作区已锁定，但无法清除本机自动解锁记录；请修复本机存储后重新登录并锁定。';

  @override
  String get theWorkspaceIsntLockedRightNow => '工作区当前没有锁定。';

  @override
  String get theWorkspacePaneNoLongerExists => '工作区窗格已不存在。';

  @override
  String get theWorkspacePaneOrHostReference => '工作区窗格或主机引用已变化，请重新连接后重试。';

  @override
  String get localChangesAreBlockedWhileThe => '工作区锁定期间禁止本地修改，请先解锁。';

  @override
  String uploadedName(String name) {
    return '已上传 $name';
  }

  @override
  String savedName(String name) {
    return '已保存 $name';
  }

  @override
  String savedNameButCouldntConfirmThe(String name) {
    return '已保存 $name，但无法确认原权限是否恢复；请检查远端文件权限。';
  }

  @override
  String get thePinnedServerIdentityChangedDuring =>
      '已固定的服务端身份在确认期间发生变化，请重新连接后再试。';

  @override
  String get unlockedLocallyTheServerStillStores => '已在本地解锁；服务端仍只保存加密记录和密钥信封。';

  @override
  String get memberInvitationAcceptedTheVaultIs => '已接受成员邀请；Vault 已解锁并开始同步。';

  @override
  String get anExistingRepairTombstoneAlreadySpecifies =>
      '已有修复墓碑指定了保留记录；请按该记录重试修复。';

  @override
  String get theRecordRetainedByAnExisting => '已有修复墓碑的保留记录不一致，需要人工检查。';

  @override
  String get aServerAccessGroupWithThe => '已有同名服务器访问组（忽略大小写及 Unicode 兼容字符）。';

  @override
  String get thePreviouslySubmittedMasterPasswordChange =>
      '已确认此前提交的主密码变更；其他登录会话已撤销。';

  @override
  String get attachedToTheSavedTmuxSession => '已附加到保存的 tmux 会话。';

  @override
  String theKeyKeyInTheArchive(String key) {
    return '归档中的 $key key 与本地已解锁 key 不一致。';
  }

  @override
  String get theArchiveNoLongerCorrespondsTo =>
      '归档已不再对应当前 server space/Vault，未执行导入。';

  @override
  String get theArchiveWasVerifiedAndRestored =>
      '归档已验证并恢复。历史密钥仅保存在当前客户端内存；本地 outbox 与冲突分支已保留。';

  @override
  String get lockTheWorkspaceAfterTheArchive => '归档操作完成后再锁定工作区。';

  @override
  String get theCurrentOwnerDeviceIsntIn => '当前 Owner 设备不在保留成员的活动设备集合中，已中止轮换。';

  @override
  String get theCurrentPostgresqlModeSupportsInstance =>
      '当前 PostgreSQL 运行模式支持实例维护；服务器端加密备份和恢复暂不可用。';

  @override
  String get theCurrentVaultIsntWritable => '当前 Vault 不可写。';

  @override
  String theCurrentVaultIsntWritableSo(String label) {
    return '当前 Vault 不可写，无法修复$label偏好。';
  }

  @override
  String get theCurrentVaultIsReadOnly6 => '当前 Vault 只读或正在删除，不能启用命令历史同步。';

  @override
  String get theCurrentVaultIsReadOnly => '当前 Vault 只读，不能修改偏好设置。';

  @override
  String get theCurrentVaultIsReadOnly2 => '当前 Vault 只读，不能修改分组。';

  @override
  String get theCurrentVaultIsReadOnly3 => '当前 Vault 只读，不能删除分组。';

  @override
  String get theCurrentVaultIsReadOnly4 => '当前 Vault 只读，不能更改自动清理授权。';

  @override
  String get theCurrentVaultIsReadOnly5 => '当前 Vault 只读，不能永久清理记录。';

  @override
  String get theCurrentVaultSyncRepositoryIsnt => '当前 Vault 同步仓库尚未就绪。';

  @override
  String get theCurrentVaultSyncTimedOut => '当前 Vault 同步超时，SSH 主机密钥信任检查已停止。';

  @override
  String get theCurrentVaultIsLockedSo => '当前 Vault 已锁定，无法验证 SSH 主机密钥。';

  @override
  String get theCurrentVaultOrSignedIn => '当前 Vault 或登录设备不可用于终端共享。';

  @override
  String get refreshingTheCurrentVaultStateTimed =>
      '当前 Vault 状态刷新超时，SSH 主机密钥信任检查已停止。';

  @override
  String get theCurrentMasterPasswordOrSix =>
      '当前主密码或六位验证器代码无效或已使用。请重新输入主密码和新的六位代码。';

  @override
  String get theCurrentMasterPasswordOrAccount => '当前主密码或账户密钥信封无法验证。';

  @override
  String get theCurrentMasterPasswordMustBe => '当前主密码至少需要 12 个字符。';

  @override
  String get theCurrentMasterPasswordCouldntBe =>
      '当前主密码验证失败；账户凭据没有变更。请确认密码后重试。';

  @override
  String get theCurrentHostOrVaultIs => '当前主机或 Vault 不可用。';

  @override
  String get tmuxIsntAvailableOnTheCurrent => '当前主机没有可用的 tmux。';

  @override
  String get theCurrentSessionIsMissingThe => '当前会话缺少账户名。';

  @override
  String get theCurrentSyncHasntFinishedWait => '当前同步尚未结束，请完成后再创建成员邀请。';

  @override
  String get theCurrentSyncHasntFinishedWait2 => '当前同步尚未结束，请完成后再更改 Vault 成员。';

  @override
  String get anInputControlLeaseIsAlready => '当前已有一个活动的输入控制租约，请先撤销。';

  @override
  String get theCurrentMemberRoleCantBe => '当前成员角色不能通过此操作撤销。';

  @override
  String get theCurrentServerDoesntDeclareSupport => '当前服务端未声明支持丢弃隔离还原副本。';

  @override
  String get theresNoSignedInAccountWhose => '当前没有可变更密码的已登录账户。';

  @override
  String get noAccountIsSignedIn => '当前没有已登录账户。';

  @override
  String thereAreNoPendingLabelPreference(String label) {
    return '当前没有待处理的$label偏好冲突。';
  }

  @override
  String get theCurrentTestSshConnectorDoesnt =>
      '当前测试 SSH connector 不支持 Jump Host。';

  @override
  String get theCurrentTestSshConnectorDoesnt2 =>
      '当前测试 SSH connector 不支持多跳 Jump Host。';

  @override
  String get thisBrowserHasNoRegisteredDevice =>
      '当前浏览器没有已注册的设备密钥。请从已授权设备重新添加此设备。';

  @override
  String get thisBrowserHasNoRegisteredDevice2 =>
      '当前浏览器没有已注册的设备密钥。请先从已授权设备添加此设备。';

  @override
  String get theCurrentDeviceKeyIsMissing => '当前设备密钥缺失或与会话不匹配，请重新授权此设备。';

  @override
  String get thisDeviceDoesntHaveKeysFor => '当前设备没有所有 Vault 的密钥，不能批准该设备。';

  @override
  String get theCurrentDeviceIdentityDoesntMatch => '当前设备身份与登录会话不匹配。';

  @override
  String get theCurrentAccountOrVaultChanged =>
      '当前账户或 Vault 已更改，无法验证 SSH 主机密钥。';

  @override
  String get theCurrentAccountDoesntHaveInstance => '当前账户没有实例管理员权限。';

  @override
  String get theCurrentAccountIdentityIsUnavailable => '当前账户身份不可用，请重新登录。';

  @override
  String get theCurrentAccountVerificationDetailsDont => '当前账户验证信息不匹配。';

  @override
  String get theRoleOfAPendingInvitation => '待接受邀请暂不能直接改角色。请撤销后重新邀请并选择新角色。';

  @override
  String get thePendingMasterPasswordChangeRequest => '待确认的主密码变更请求已被清除。';

  @override
  String get theServerIdentityAwaitingConfirmationWas =>
      '待确认的服务端身份已取消，请重新连接后再试。';

  @override
  String get theSnapshotWasRestoredSafelySome =>
      '快照已安全恢复；仍有操作待上传或冲突待重试。原始 outbox 已保留。';

  @override
  String snapshotRestoreCompleteReceivedcountRecordsVerified(
    int receivedCount,
  ) {
    return '快照恢复完成：已验证并重建 $receivedCount 条记录。';
  }

  @override
  String get youCantSwitchVaultsDuringSnapshot => '快照恢复期间不能切换 Vault。';

  @override
  String get localChangesArePausedDuringSnapshot => '快照恢复期间已暂停本地修改，请恢复完成后重试。';

  @override
  String get theMemberRoleCanOnlyBe => '成员角色只能设为 editor 或 viewer。';

  @override
  String get theMemberRoleWasUpdatedAnd => '成员角色已更新，并已为所有保留成员设备完成新密钥轮换。';

  @override
  String get theMemberRoleWasUpdatedAnd2 =>
      '成员角色已更新，并已为所有保留成员设备完成新密钥轮换。待接受邀请仍保持待处理，但旧 token 已失效；请重新邀请。';

  @override
  String get memberRoleUpdatedTheServerCommitted => '成员角色已更新，服务端已提交新密钥 epoch。';

  @override
  String get memberAccessWasRevokedAndThe =>
      '成员访问已撤销，并已为保留成员轮换 Vault 密钥。待接受邀请仍保持待处理，但旧 token 已失效；请重新邀请。';

  @override
  String get memberAccessWasRevokedAndThe3 =>
      '成员访问已撤销，并已为保留成员轮换 Vault 密钥。被撤销成员不会收到新 epoch 密钥；其已保存的旧副本无法远程删除。';

  @override
  String get memberAccessWasRevokedAndThe2 =>
      '成员访问已撤销，服务端已提交新密钥 epoch；请注意其已保存的旧副本无法远程删除。';

  @override
  String get invalidMemberAccountIdFormat => '成员账户 ID 格式无效。';

  @override
  String get theMemberRotationResultCantBe =>
      '成员轮换结果暂时无法确认，已锁定此 Vault 以避免使用旧密钥。重新登录并检查成员状态后再继续。';

  @override
  String get ownershipCanOnlyBeTransferredTo => '所有权只能转给已接受邀请的活跃成员。';

  @override
  String get theSelectedJumpHostNoLonger => '所选 Jump Host 已不存在，请选择有效主机或清除失效引用。';

  @override
  String get theSelectedSshCredentialNoLonger => '所选 SSH 凭据已不存在，请选择有效凭据或清除此覆盖。';

  @override
  String get theSelectedSessionNoLongerExists => '所选会话已不存在或已经撤销，请刷新会话列表。';

  @override
  String get theSelectedRetainedRecordChangedCheck => '所选保留记录已变化，请重新核对候选项。';

  @override
  String get theSelectedGroupNoLongerExists => '所选分组已不存在，请选择有效分组或取消分组。';

  @override
  String get theSelectedEncryptedArchiveIsUnavailable =>
      '所选加密归档不可用，请刷新来源列表后重试。';

  @override
  String get theSelectedArchiveIsInvalidRefresh => '所选归档无效，请刷新来源列表后重试。';

  @override
  String get theSelectedArchiveSourceIsInvalid => '所选归档来源无效，请刷新来源列表后重试。';

  @override
  String get theSelectedServerAccessGroupNo => '所选服务器访问组已不存在，请刷新列表。';

  @override
  String get theApprovalFileDoesntMatchThe => '批准文件与此浏览器生成的设备申请不匹配。';

  @override
  String get theVaultKeyEnvelopeContextIn => '批准文件中的 Vault 密钥信封上下文无效。';

  @override
  String get theVaultKeyEnvelopeInThe2 => '批准文件中的 Vault 密钥信封格式无效。';

  @override
  String get theDeviceCapabilityReportInThe => '批准文件中的设备能力报告格式无效。';

  @override
  String get theApprovalFileContainsDuplicateVault => '批准文件包含重复的 Vault 密钥信封。';

  @override
  String get theApprovalFileBelongsToA => '批准文件属于另一个账户或服务端实例。';

  @override
  String get theApprovalFileIsStagedAfter =>
      '批准文件已暂存。登录后，客户端会先验证 owner 证书和每个 Vault 密钥信封，再解锁数据。';

  @override
  String get theDeviceSelfProofInThe => '批准文件的设备自证明与本地设备密钥不一致。';

  @override
  String get theApproverOrCurrentDeviceIsnt => '批准者或当前设备不在服务端账户设备目录中。';

  @override
  String get theApproverCertificateFieldsAreInvalid => '批准者证书字段无效。';

  @override
  String get theApproverCertificateSignatureIsInvalid => '批准者证书签名无效。';

  @override
  String get thisHostCouldntBeFound => '找不到此主机。';

  @override
  String get theVaultOnThisDeviceCouldnt => '找不到此设备上的 Vault。';

  @override
  String get theScrapeCredentialWasRotatedThe => '抓取凭据已轮换；该值只显示一次。';

  @override
  String get toCancelAccountDeletionSignOut => '撤销账户注销必须先退出登录，并使用登录页的恢复入口。';

  @override
  String theFileWasSavedButThe(String friendlyError) {
    return '文件已保存，但目录刷新失败：$friendlyError';
  }

  @override
  String get theNewMasterPasswordMustDiffer => '新主密码必须与当前主密码不同。';

  @override
  String get theNewMasterPasswordMustBe => '新主密码至少需要 12 个字符。';

  @override
  String get couldntDiscardTheIsolatedRestoreCopy => '无法丢弃隔离还原副本，请刷新任务列表后重试。';

  @override
  String get couldntSaveChangesToTheTmux => '无法保存 tmux 会话引用的更改，请稍后重试。';

  @override
  String get couldntSaveTheScheduledBackupSettings => '无法保存计划备份设置，请重试。';

  @override
  String get couldntPrepareTheIsolatedRestoreCopy => '无法准备隔离还原副本。在线数据未更改。';

  @override
  String get couldntCreateANewTmuxSession => '无法创建新的 tmux 会话；请重试。';

  @override
  String get couldntJoinInputControlMakeSure => '无法加入输入控制。请确认主机仍向此设备授予控制权。';

  @override
  String get couldntStartTheLocalShell => '无法启动本机 Shell。';

  @override
  String get couldntStartTerminalSharingCheckThe =>
      '无法启动终端共享。请检查连接和 Vault 成员状态后重试。';

  @override
  String couldntSafelyCreateRemoteFileName(String name, Object error) {
    return '无法安全创建远端文件 $name。目标可能已存在，或当前用户没有写入权限；现有文件不会被覆盖。($error)';
  }

  @override
  String get couldntSafelyRestoreTheSignIn => '无法安全恢复登录会话，请重新登录。';

  @override
  String get theRefreshRequestStateCouldntBe =>
      '无法安全记录 refresh 请求状态，已阻止 refresh 请求；请检查本机安全存储后重试。';

  @override
  String get couldntCompleteTheTmuxSessionAction =>
      '无法完成 tmux 会话操作；请检查主机状态后重试。';

  @override
  String couldntFinishSyncingTheCurrentVault(String syncStatus) {
    return '无法完成当前 Vault 同步（$syncStatus），SSH 主机密钥信任检查已停止。';
  }

  @override
  String get couldntConfirmTheTmuxSessionStarted => '无法确认 tmux 会话已启动；请检查主机后重试。';

  @override
  String get couldntReadEncryptedArchiveSourcesTry => '无法读取加密归档来源，请稍后重试。';

  @override
  String get couldntReadLocalSecuritySettingsCheck => '无法读取本地安全设置，请检查浏览器存储后重试。';

  @override
  String get couldntReadThisTerminalShare => '无法读取此终端共享。';

  @override
  String get couldntReadTheScheduledBackupSettings => '无法读取计划备份设置，请重试。';

  @override
  String get couldntReadTheRestoreJobStatus2 => '无法读取还原任务状态，请稍后重试。';

  @override
  String get couldntRejoinTheShareMayHave => '无法重新加入；共享可能已结束，或 Vault 访问权限已变化。';

  @override
  String get couldntVerifyTheCurrentDeviceApproval => '无法验证当前设备批准。';

  @override
  String get thePendingVaultRecordsCouldntBe =>
      '无法验证待发送的 Vault 记录；关闭同步已生效，但离线队列未清理。';

  @override
  String get thePendingCommandHistoryCouldntBe =>
      '无法验证待发送的命令历史记录；关闭同步已生效，但离线队列未清理。';

  @override
  String get theStagedVaultCreationDataDoesnt => '暂存的 Vault 创建数据与目标 ID 不匹配。';

  @override
  String get theStagedVaultCreationDataHas => '暂存的 Vault 创建数据格式无效。';

  @override
  String get couldntReadTheRestoreJobStatus3 => '暂时无法读取还原任务状态，系统会继续尝试。';

  @override
  String get couldntReadTheRestoreJobStatus => '暂时无法读取还原任务状态，请手动重试。';

  @override
  String upToMaxterminaltabsSshTerminalTabs(int maxTerminalTabs) {
    return '最多同时打开 $maxTerminalTabs 个 SSH 终端标签；请先关闭一个标签。';
  }

  @override
  String get aVaultIsInItsDeletion => '有 Vault 正处于删除宽限期，服务端暂不允许批准新设备。';

  @override
  String get theServerSyncGenerationChangedUnlock =>
      '服务器同步代次已变化；请解锁 Vault 以安全恢复同步。';

  @override
  String get theServerHasntConfiguredEncryptedBackups =>
      '服务器尚未配置加密备份。请让实例运维人员设置 ATERMIUS_BACKUP_ARCHIVE_DIR（数据目录之外的 owner-only 目录）和 ATERMIUS_BACKUP_KEY_FILE（数据目录之外、权限为 owner-only 的 32 字节密钥文件）。此客户端不会发送或显示这些路径、归档文件名或密钥。';

  @override
  String get theServerHasntConfiguredIsolatedRestore =>
      '服务器尚未配置隔离还原存储，请联系实例运维人员。';

  @override
  String get theServerAccessGroupWasUpdated =>
      '服务器访问组在另一管理员处已更新。请重新加载最新数据；当前草稿仍保留。';

  @override
  String get theServersInitialVaultMembershipRecord => '服务端 Vault 初始成员记录格式无效。';

  @override
  String get theServerVaultKeyEnvelopeDoesnt => '服务端 Vault 密钥信封与本机暂存的创建数据不匹配。';

  @override
  String get theServersVaultMembershipListHas => '服务端 Vault 成员清单格式无效，已停止密钥轮换。';

  @override
  String get theServerVaultMembershipChainDoesnt =>
      '服务端 Vault 成员链与本机暂存的创建数据不匹配。';

  @override
  String get theServersEncryptedArchiveConfigurationIs =>
      '服务端加密归档配置不可用，请联系服务端运维人员。';

  @override
  String get theServerSyncCursorExpiredA => '服务端同步游标已过期，需要重新建立快照。';

  @override
  String get theServerInstanceIdChangedAnd => '服务端实例 ID 已改变，不能通过密钥恢复确认。';

  @override
  String get theServerInstanceIdentityChangedTo =>
      '服务端实例身份已改变。为保护本地保险库，客户端已拒绝连接。';

  @override
  String theServerHasntConfirmedThatOnly(String label) {
    return '服务端尚未确认只剩所选$label偏好记录，请同步后重试。';
  }

  @override
  String get theServerHasntConfiguredAUsable => '服务端尚未配置可用的加密备份目标和密钥，计划备份未更改。';

  @override
  String get theServerAcceptedTheRevocationRequest =>
      '服务端已接受撤销请求。旧会话不会恢复，请重新登录。';

  @override
  String get theServerAcceptedTheDeletionRequest2 => '服务端已接受注销请求，但返回的宽限期状态无效。';

  @override
  String get theServerAcceptedTheDeletionRequest =>
      '服务端已接受注销请求，当前会话与本机解锁密钥已清除。请在登录页使用账户恢复入口；如仍在宽限期内可撤销，随后必须重新登录。';

  @override
  String get theServerCommittedTheVaultOwnership =>
      '服务端已提交 Vault 所有权转移与新密钥 epoch；当前账户已降为 editor。';

  @override
  String get theServerSnapshotContainsRecordsThis =>
      '服务端快照包含此设备此前已清理的记录。为防止旧数据复活，客户端保留当前缓存、同步游标和本地草稿并停止自动同步。若服务端刚从清理前备份恢复，请先由管理员核对并重新处理服务端恢复状态；本机不会自动删除已保存的清理凭证。';

  @override
  String get theServerCommittedTheMemberRotation =>
      '服务端成员轮换已提交，但本地无法验证新 epoch 与成员状态；已停止继续操作。';

  @override
  String get theServerMembershipChainBelongsTo => '服务端成员链属于另一个 Vault。';

  @override
  String get theServerRejectedThisBackupSchedule => '服务端拒绝了此备份计划请求，请刷新后重试。';

  @override
  String get theServerRejectedThisIsolatedRestore =>
      '服务端拒绝了此隔离还原请求，请刷新来源列表后重试。';

  @override
  String get theServerDidntReturnTheVault => '服务端未返回已接受邀请的 Vault ID。';

  @override
  String get theServerDidntReturnAValid => '服务端未返回有效的删除宽限期与截止时间。';

  @override
  String get theServerDidntProvideAVerifiable => '服务端没有提供可验证的恢复期限，已阻止永久清理。';

  @override
  String get theServerDidntProvideAValid => '服务端没有提供有效的实例签名身份。';

  @override
  String get theServerDidntReturnAnAccount => '服务端没有返回账户标识，无法创建设备申请。';

  @override
  String get theServerSigningKeyDoesntMatch =>
      '服务端签名密钥与已固定身份不符。请先通过独立可信渠道核对候选 fingerprint。';

  @override
  String get theServerSigningKeyDoesntMatch2 =>
      '服务端签名密钥与已固定身份不符。请通过独立可信渠道比较候选 fingerprint；确认前不会连接账户或发送认证请求。';

  @override
  String get theServerIsMissingTheExisting => '服务端缺少现有恢复身份信封，无法安全轮换。';

  @override
  String get theServerDeviceDirectoryDoesntMatch => '服务端设备目录与批准文件中的账户或公钥不一致。';

  @override
  String get theServersDeviceCapabilityReportDoesnt => '服务端设备能力报告与批准文件不一致。';

  @override
  String get theServerIdentityChangedDuringConfirmation =>
      '服务端身份在确认期间发生变化。请重新连接并核对新的 fingerprint。';

  @override
  String get serverIdentityConfirmationIsInProgress => '服务端身份确认正在进行。';

  @override
  String get serverIdentityConfirmationIsInProgress2 => '服务端身份确认正在进行，暂时不能取消。';

  @override
  String get serverIdentityConfirmationIsInProgress3 =>
      '服务端身份确认正在进行，请等待当前操作完成。';

  @override
  String get theServerRotationResultDoesntMatch => '服务端轮换结果与已签名 epoch/成员版本不一致。';

  @override
  String get theServerReturnedADifferentMigration => '服务端返回了不同的迁移目标 Vault ID。';

  @override
  String get theVaultOwnerStateReturnedBy => '服务端返回的 Vault Owner 状态不匹配。';

  @override
  String get theServerReturnedAnInvalidMaster => '服务端返回的主密码变更回执无效。';

  @override
  String get theServerReturnedAnInvalidRecovery => '服务端返回的恢复设置回执无效。';

  @override
  String get theMembershipVersionReturnedByThe => '服务端返回的成员版本与本地签名不一致。';

  @override
  String get theRevocationStateReturnedByThe => '服务端返回的撤销状态无效，Vault 仍保持锁定状态。';

  @override
  String get theAccountRevocationStateReturnedBy => '服务端返回的账户撤销状态无效。';

  @override
  String get theServerReturnedDuplicateMigrationDestination =>
      '服务端返回重复的迁移目标 Vault。';

  @override
  String get noIsolatedRestoreCopyToDiscard => '未找到可丢弃的隔离还原副本，请刷新任务列表。';

  @override
  String get thereAreUncommittedLocalChangesRotate =>
      '本地仍有未提交变更。同步完成后再轮换成员密钥，以免旧版本记录无法提交。';

  @override
  String get thereAreUncommittedLocalChangesCreate =>
      '本地仍有未提交变更。同步成功后再创建成员邀请，以免旧版本记录无法提交。';

  @override
  String get theLocalFileNameIsntA => '本地文件名不是安全的远端文件名。';

  @override
  String get localConsole => '本机 Console';

  @override
  String get theLocalConsoleRequiresTheDesktop => '本机 Console 需要桌面客户端。';

  @override
  String get thisDevicesEncryptedHistoryRepositoryIsnt => '本机加密历史仓库尚未就绪。';

  @override
  String get thisDeviceHasNoCurrentSession => '本机没有可安全恢复的当前会话快照，请重新登录。';

  @override
  String get thisSignInCanContinueBut => '本次登录可继续使用，但无法记住登录状态。';

  @override
  String get refreshingVaultMembershipTryChangingIt =>
      '正在刷新 Vault 成员状态，请稍后再修改。';

  @override
  String get anotherVaultMemberInvitationIsBeing => '正在接受另一条 Vault 成员邀请，请稍后重试。';

  @override
  String get confirmingTheInputControlRevocationTry => '正在确认输入控制撤销，请稍后重试。';

  @override
  String get connectingHostApprovedInputControl => '正在连接主机批准的输入控制。';

  @override
  String get thisHostChangedAfterThePreview => '此 Host 在预览后已发生变化；请重新同步并审阅刷新差异。';

  @override
  String get thisHostNoLongerExistsOr => '此 Host 已不存在或无法唯一读取；请重新同步后再编辑。';

  @override
  String get thisHostsLocalEncryptedRecordCouldnt =>
      '此 Host 的本地加密记录无法验证；为避免覆盖或丢失数据，保存已停止。';

  @override
  String get thisHostIsMissingAVerifiable =>
      '此 Host 缺少可验证的本地 revision；为避免断开同步历史，保存已停止。';

  @override
  String thisSshCredentialIsStillReferenced(
    int groupCount,
    int hostCount,
    int snippetParameterCount,
  ) {
    return '此 SSH 凭据仍被 $groupCount 个分组默认值、$hostCount 个主机覆盖和 $snippetParameterCount 个片段密钥参数引用；请先更换或清除这些引用。';
  }

  @override
  String get thisSshCredentialNoLongerExists =>
      '此 SSH 凭据已不存在或无法验证；请先重新同步 Vault。';

  @override
  String get theTerminalFontSizePreferenceIn =>
      '此 Vault 中终端字号偏好存在重复记录或尚未确认的修复，请完成显式修复。';

  @override
  String get theTerminalShortcutPreferenceInThis =>
      '此 Vault 中终端快捷键偏好存在重复记录或尚未确认的修复，请完成显式修复。';

  @override
  String get theTerminalColorPreferenceInThis =>
      '此 Vault 中终端配色偏好存在重复记录或尚未确认的修复，请完成显式修复。';

  @override
  String get theDefaultWorkspacePreferenceInThis =>
      '此 Vault 中默认工作区偏好存在重复记录或尚未确认的修复，请完成显式修复。';

  @override
  String get thisVaultContainsUnsupportedPreferenceRecords =>
      '此 Vault 含有不支持的偏好记录，修复已暂停。';

  @override
  String get thisVaultContainsPreferencesThatThis => '此 Vault 含有当前客户端不支持的偏好设置。';

  @override
  String get thisVaultCantBeUsedTo => '此 Vault 当前不可用于创建终端共享。';

  @override
  String get thisVaultIsntCurrentlyInAn => '此 Vault 当前不处于可删除的活动状态。';

  @override
  String get thisVaultIsCurrentlyReadOnly => '此 Vault 当前为只读状态，不能更改成员。';

  @override
  String get thisVaultHasNoDeletionSchedule => '此 Vault 当前没有可撤销的删除计划。';

  @override
  String get thisVaultIsInItsDeletion => '此 Vault 正在删除宽限期内，目前为只读状态。';

  @override
  String get thisVaultIsInItsDeletion2 =>
      '此 Vault 正处于删除宽限期，只读；Owner 可在截止时间前撤销删除。';

  @override
  String thisHostIsStillUsedAs(int dependants) {
    return '此主机仍被 $dependants 个主机用作 Jump Host；请先更换或清除这些引用。';
  }

  @override
  String get thisSessionWasSignedOutIn => '此会话已在其他标签页退出，请重新登录。';

  @override
  String get thisSessionsRefreshTokenStateCant =>
      '此会话的 refresh token 状态无法安全恢复，请重新登录。';

  @override
  String get thisSharedSessionDoesntHaveHost => '此共享会话未启用主机批准的输入控制。';

  @override
  String thisGroupIsStillReferencedBy(int hostCount, int childCount) {
    return '此分组仍被 $hostCount 个 Host 和 $childCount 个子分组引用；请先移动这些记录。';
  }

  @override
  String get thisGroupNoLongerExistsOr => '此分组已不存在或无法验证；请先重新同步 Vault。';

  @override
  String thisDeletedRecordIsPastThe(String dateText) {
    return '此删除记录已超过服务端恢复期限$dateText。墓碑会继续保留此记录 ID；如需继续使用，请创建一条新记录并使用新的 ID。';
  }

  @override
  String get thisInstanceIsntInitializedYetCreate =>
      '此实例尚未初始化。请使用管理员生成的一次性 bootstrap token 创建首个账户。';

  @override
  String get thisWorkspaceHostNoLongerExists => '此工作区主机已不存在于当前 Vault，请先修复引用。';

  @override
  String get thisWorkspacePaneAlreadyHasA => '此工作区窗格已有 tmux 会话引用，请使用 Resume。';

  @override
  String get thisWorkspacePaneIsAlreadyAttached => '此工作区窗格已经附加到 tmux。';

  @override
  String get thisWorkspacePaneIsRunningA => '此工作区窗格正在执行 tmux 操作。';

  @override
  String get thisWorkspacePaneHasNoSaved => '此工作区窗格没有已保存的 tmux 会话引用。';

  @override
  String get mobilePushIsntSupportedOnThis => '此平台不支持移动推送。';

  @override
  String get thisAppBuildDoesntHaveFirebase =>
      '此应用构建未配置 Firebase Cloud Messaging。';

  @override
  String get thisMembersAccessWasRevokedTo => '此成员已撤销访问；如需重新授权，请创建一份新的成员邀请。';

  @override
  String get thisBrowserCantSafelyCoordinateSession =>
      '此浏览器无法安全协调多标签页会话刷新，当前未轮换 refresh token。请更新浏览器以启用安全的会话同步。';

  @override
  String get thisBrowserHasNoDeviceKey => '此浏览器没有待批准的设备密钥，请先生成设备申请。';

  @override
  String get youLeftThisTerminalShareEnter => '此终端共享已离开，请重新输入 session UUID。';

  @override
  String get thisTerminalIsAlreadyBeingShared => '此终端已经在共享。';

  @override
  String get thisRecordIdIsReservedBy =>
      '此记录 ID 已被删除墓碑保留，不能重新创建。请从回收站恢复，或创建一条使用新 ID 的记录。';

  @override
  String get thisRecordWasUpdatedOnAnother => '此记录在另一设备上已更新，冲突分支已保留。';

  @override
  String get thisRecordHasNoHistoricalVersion => '此记录没有可恢复的历史版本。';

  @override
  String get thisRecordsHostIdentityCantBe =>
      '此记录的 Host 身份无法验证；为避免覆盖其他数据，保存已停止。';

  @override
  String get backgroundSyncNotificationsAreTurnedOff => '此设备已停用后台同步通知。';

  @override
  String get backgroundSyncNotificationsAreOnFor => '此设备已启用后台同步通知。';

  @override
  String get thisDeviceWasRevokedSignIn => '此设备已被撤销，请使用管理员批准的设备重新登录。';

  @override
  String get thisAccountIsntAMemberOf => '此账户不是当前 Vault 的成员。';

  @override
  String get thisAccountNameDoesntMatchThe => '此账户名与当前登录账户不匹配。';

  @override
  String get thisChangeCantBeMadeIn => '此账户当前状态不能执行该变更。';

  @override
  String get theresNoMasterPasswordChangeWaiting => '没有待确认的主密码变更。';

  @override
  String get theresNoServerIdentityRecoveryWaiting => '没有待确认的服务端身份恢复。';

  @override
  String get theresNoActivePrometheusScrapeCredential =>
      '没有活动的 Prometheus 抓取凭据。';

  @override
  String get theParentGroupNoLongerExists2 => '父级分组已不存在，请选择其他父级或顶级分组。';

  @override
  String get invalidParentGroupChooseAValid => '父级分组无效，请选择有效分组或顶级分组。';

  @override
  String thePasswordCredentialReferencedBySnippet(String name) {
    return '片段参数“$name”引用的密码凭据不存在或不可用；保存已停止。';
  }

  @override
  String get theSnippetCommandCantBeEmpty => '片段命令不能为空';

  @override
  String get theSnippetTitleCantBeEmpty => '片段标题不能为空';

  @override
  String get userName => '用户名';

  @override
  String get theSignInSessionWasRestored => '登录会话已恢复，请输入主密码解锁加密工作区。';

  @override
  String get theSignInSessionDeviceId => '登录会话设备 ID 不匹配本地设备身份。';

  @override
  String get theSignInResponseDoesntMatch => '登录响应与当前账户或设备不匹配。';

  @override
  String get theSignInStateChangedTry => '登录状态已变化，请重试。';

  @override
  String get theSignInStateExpiredSign => '登录状态已过期，请重新登录。';

  @override
  String get theSignedInAccountChangedSign => '登录账户已变化；请退出后使用新主密码重新登录。';

  @override
  String get invalidFolderNameFormat => '目录名格式无效';

  @override
  String get theDestinationVaultsCurrentServerState =>
      '目标 Vault 的当前服务端状态尚未验证；完成快照恢复后再继续迁移。';

  @override
  String get theTargetHostsSshCredentialChanged =>
      '目标主机 SSH 凭据在连接准备期间发生变化，请重新连接。';

  @override
  String get theTargetMemberHasNoActive => '目标成员没有可接收新 Vault 密钥的活动设备，所有权转移已取消。';

  @override
  String get theTargetAccountIsNoLonger => '目标账户已不在当前管理列表中，请刷新后重试。';

  @override
  String get thePrivateKeyCantBeEmpty => '私钥不能为空';

  @override
  String get theWindowSetHasASync => '窗口组合存在同步冲突，请先解决冲突。';

  @override
  String get theWindowSetIsBeingSaved => '窗口组合正在保存，请稍后重试。';

  @override
  String get port2 => '端口';

  @override
  String get theSignedMembershipEntryHasAn => '签名成员条目格式无效。';

  @override
  String get theSignedMembershipListDoesntMatch =>
      '签名成员清单与服务端 ACL 状态不一致；请刷新后重试。';

  @override
  String get theSignedMembershipListDoesntMatch2 => '签名成员清单与服务端成员目录不一致。';

  @override
  String get theSignedMembershipListContainsInvalid => '签名成员清单包含无效或重复成员。';

  @override
  String get theSignedMembershipListIsMissing => '签名成员清单缺少服务端现有成员。';

  @override
  String get theAdminAuditCursorExpiredThe =>
      '管理员审计游标已过期。实例或服务端 generation 可能已变化，请从第一页重新加载。';

  @override
  String get theAdminAuditCursorIsInvalid => '管理员审计游标无效或不属于当前管理员/实例，请从第一页重新加载。';

  @override
  String get theTerminalVaultOrSignedIn => '终端、Vault 或登录设备已变化，已取消共享。';

  @override
  String get terminalSharingStoppedBecauseAnObservers =>
      '终端共享因观察者连接过慢而停止；SSH 连接仍可继续使用。';

  @override
  String get terminalSharingHasntDisconnectedYet => '终端共享尚未断开。';

  @override
  String get terminalSharingDisconnectedTheSshConnection =>
      '终端共享已断开。SSH 连接仍可继续使用。';

  @override
  String get terminalSharingDisconnectedTheSshConnection2 =>
      '终端共享已断开；SSH 连接仍可继续使用。';

  @override
  String get theTerminalSharingConnectionWasDisconnected => '终端共享连接已断开。';

  @override
  String get terminalFontSize => '终端字号';

  @override
  String get terminalFontSizePreferenceSavedEncrypted =>
      '终端字号偏好已加密保存，将通过当前 Vault 同步到其他设备。';

  @override
  String get theTerminalFontSizePreferenceNeeds => '终端字号偏好需要先完成显式修复。';

  @override
  String get aHostReferencedByTheTerminal =>
      '终端引用的主机已不在当前 Vault 中；请重新打开主机后再保存布局。';

  @override
  String get terminalShortcuts => '终端快捷键';

  @override
  String get terminalShortcutPreferenceSavedEncryptedIt =>
      '终端快捷键偏好已加密保存，将通过当前 Vault 同步到其他设备。';

  @override
  String get theTerminalShortcutPreferenceNeedsAn => '终端快捷键偏好需要先完成显式修复。';

  @override
  String get theTerminalControlChannelDisconnectedThe =>
      '终端控制通道已断开；SSH 连接仍可继续使用。';

  @override
  String get terminalColors => '终端配色';

  @override
  String get terminalColorPreferenceSavedEncryptedIt =>
      '终端配色偏好已加密保存，将通过当前 Vault 同步到其他设备。';

  @override
  String get theTerminalColorPreferenceNeedsAn => '终端配色偏好需要先完成显式修复。';

  @override
  String get maintenanceJobSubmittedRefreshTheJob => '维护任务已提交。刷新任务列表可查看状态。';

  @override
  String get automaticStatusChecksArePausedYou => '自动状态检查已暂停。可手动刷新任务状态。';

  @override
  String get scheduledBackupsTurnedOff => '计划备份已停用。';

  @override
  String get scheduledBackupSettingsSaved => '计划备份设置已保存。';

  @override
  String get authenticationMethod => '认证方式';

  @override
  String get theRecordWasClearedFromThis =>
      '记录已从本机活动缓存清除并收到服务端签名证明；同步游标追赶失败，重试同步会先拉取清理标记，再处理待发送内容。';

  @override
  String thePublicKeysForDeviceDeviceid(String deviceId) {
    return '设备 $deviceId 在账户目录和 Vault 目录中的公钥不一致。';
  }

  @override
  String theEncryptionPublicKeyOfDevice(String deviceId) {
    return '设备 $deviceId 的加密公钥长度无效。';
  }

  @override
  String theKeyEnvelopeTargetForDevice(String deviceId) {
    return '设备 $deviceId 的密钥信封目标无效或重复。';
  }

  @override
  String theSigningPublicKeyOfDevice(String deviceId) {
    return '设备 $deviceId 的签名公钥长度无效。';
  }

  @override
  String get deviceRevoked2 => '设备已撤销。';

  @override
  String get deviceAddedGiveTheApprovalResult => '设备已添加。请将批准结果交给新设备并在那里导入。';

  @override
  String get theVaultKeyEnvelopeInThe => '设备批准中的 Vault 密钥信封格式无效。';

  @override
  String get theKeyEnvelopeContextInThe => '设备批准中的密钥信封上下文无效。';

  @override
  String get theDeviceApprovalContainsDuplicateVault => '设备批准包含重复的 Vault 密钥信封。';

  @override
  String get theDeviceApprovalFileHasAn => '设备批准文件格式无效。';

  @override
  String get theDeviceApprovalFilesAccountOr => '设备批准文件的账户或结构无效。';

  @override
  String get theDeviceApprovalCertificateFieldsAre => '设备批准证书字段缺失。';

  @override
  String get theDeviceRequestIsMalformedOr => '设备申请格式错误，或属于另一个账户。';

  @override
  String get thisAccountIsAlreadyAnActive => '该账户已经是 Vault 活跃成员；请使用已授权设备审批流程。';

  @override
  String get thisInvitationIsNoLongerWaiting => '该邀请已不再等待接受，请刷新后重试。';

  @override
  String get closeASessionTabFirst => '请先关闭一个会话标签。';

  @override
  String get joinTheHostsTerminalShareFirst => '请先加入主机的终端共享。';

  @override
  String get openThisAccountsSessionListFirst => '请先打开此账户的会话列表。';

  @override
  String get openAtLeastOneTerminalTab => '请先打开至少一个终端标签。';

  @override
  String get signInAndUnlockTheAccount => '请先用受信任设备登录并解锁账户。';

  @override
  String get signInFirst => '请先登录。';

  @override
  String get signInBeforeChangingMfaSettings => '请先登录后再修改 MFA 设置。';

  @override
  String get signInBeforeViewingMfaSettings => '请先登录后再查看 MFA 设置。';

  @override
  String get signInBeforeManagingThisDevices => '请先登录后管理此设备的后台同步通知。';

  @override
  String get signInAndUnlockTheSync => '请先登录并解锁同步账户。';

  @override
  String get signInAndUnlockTheTarget => '请先登录并解锁目标 Vault。';

  @override
  String get signInAndUnlockTheAccount2 => '请先登录并解锁账户。';

  @override
  String get signInToThisAccountAnd => '请先登录此账户并解锁当前设备。';

  @override
  String get resolveThePreferenceReadErrorFirst => '请先解决偏好设置读取错误。';

  @override
  String get unlockTheVaultFirst => '请先解锁 Vault';

  @override
  String get unlockTheVaultFirst2 => '请先解锁 Vault。';

  @override
  String get unlockAVaultBeforeSharingA => '请先解锁一个 Vault，再共享终端。';

  @override
  String get unlockTheWorkspaceFirst => '请先解锁工作区。';

  @override
  String get unlockTheCurrentVaultBeforeVerifying =>
      '请先解锁当前 Vault 后再验证 SSH 主机密钥。';

  @override
  String get unlockTheWorkspaceThatContainsThe => '请先解锁当前主机所在的工作区。';

  @override
  String get unlockTheVaultThatOwnsThis => '请先解锁拥有该共享会话的 Vault。';

  @override
  String get unlockTheAccountBeforeExportingA => '请先解锁账户后导出共享请求。';

  @override
  String get connectToAnSshHostFirst => '请先连接 SSH 主机';

  @override
  String get connectSshBeforeStartingTerminalSharing => '请先连接 SSH，再启动终端共享。';

  @override
  String get connectToTheServerFirst => '请先连接服务端。';

  @override
  String get connectTheHostForThisWorkspace => '请先连接此工作区窗格的主机。';

  @override
  String get chooseAVaultFirst => '请先选择一个 Vault。';

  @override
  String get chooseAndUnlockAVaultFirst => '请先选择并解锁一个 Vault。';

  @override
  String get configureTheServerAddressFirst => '请先配置服务端地址';

  @override
  String get retryThePendingMasterPasswordChange => '请先重试待确认的主密码变更，再注销账户。';

  @override
  String get tooManyRequestsTryAgainLater => '请求过于频繁，请稍后再试。';

  @override
  String get waitForTheCurrentSyncOr => '请等待当前同步或归档操作完成。';

  @override
  String get enterAVaultName => '请输入 Vault 名称';

  @override
  String get enterTheBootstrapToken => '请输入 bootstrap token';

  @override
  String get enterAGroupName => '请输入分组名称。';

  @override
  String get enterTheCurrentMasterPassword => '请输入当前主密码。';

  @override
  String get enterTheCurrentAccountNameAnd => '请输入当前账户名和主密码以重新验证。';

  @override
  String get enterANameForTheNew => '请输入新 Vault 名称。';

  @override
  String get enterAValidTerminalSharingSession => '请输入有效的终端共享 session UUID。';

  @override
  String get enterAValidAccountNameAnd => '请输入有效的账户名和 1 至 30 天期限。';

  @override
  String get enterTheServerAddress => '请输入服务端地址';

  @override
  String get enterAnMfaCodeValidFor => '请输入此账户可用的 MFA 验证码。';

  @override
  String get enterTheAccountInvitationTokenIssued => '请输入管理员签发的账户邀请 token';

  @override
  String get enterTheAccountNameAndMaster => '请输入账户名和主密码。';

  @override
  String get enterTheAccountPassword => '请输入账户密码。';

  @override
  String get enterTheAccountEmailUserName => '请输入账户邮箱/用户名';

  @override
  String get enterTheInvitationToken => '请输入邀请 token。';

  @override
  String get choose1To8ActiveVault => '请选择 1 到 8 个活动 Vault 设备。';

  @override
  String chooseALabelPreferenceFromThe(String label) {
    return '请选择当前冲突列表中的一条$label偏好。';
  }

  @override
  String get theAccountIsStillTheOwner =>
      '账户仍是包含其他成员的共享 Vault Owner。服务端不会自动转移所有权或删除其他账户的数据，请先移除其他成员后再重试。';

  @override
  String get theAccountSessionChangedSignIn => '账户会话已变化，请重新登录后解锁。';

  @override
  String get theAccountDeletionGracePeriodHas => '账户删除宽限期已结束，无法撤销。';

  @override
  String theAccountDeletionWasCancelledThe(String valueValue) {
    return '账户删除计划已撤销。服务端不会恢复旧会话，请重新输入密码登录.$valueValue';
  }

  @override
  String get theAccountResponseDoesntMatchThe => '账户响应与当前会话不匹配。';

  @override
  String get accountSecuritySettingsAreBeingProcessed => '账户安全设置正在处理中，请稍后重试。';

  @override
  String get invalidAccountKeyLength => '账户密钥长度无效。';

  @override
  String get invalidAccountKeyLengthTheMaster => '账户密钥长度无效，已停止变更主密码。';

  @override
  String get theAccountAlreadyHasAPending => '账户已有待处理的删除计划；请在登录页使用账户恢复入口撤销。';

  @override
  String theAccountEnteredItsDeletionGrace(
    String deadline,
    String valueValue,
    String valueValue2,
  ) {
    return '账户已进入删除宽限期。服务端 purge_after：$deadline。当前会话与本机解锁密钥已清除；宽限期内可在登录页撤销，撤销后必须重新登录.$valueValue$valueValue2';
  }

  @override
  String get accountRecoverySettingsAreBeingProcessed => '账户恢复设置正在处理中。';

  @override
  String get theAccountStateJustChangedSign => '账户状态刚刚发生变化，请重新登录后再查看。';

  @override
  String get anAccountStateActionIsIn => '账户状态操作正在处理中，请稍后重试。';

  @override
  String get theInputControlAuthorizationOrVault =>
      '输入控制授权或 Vault 状态已变化，已取消加入。';

  @override
  String get theInputControlConnectionWasDisconnected => '输入控制连接已断开。';

  @override
  String get theFingerprintYouEnteredDoesntMatch =>
      '输入的 fingerprint 与候选实例签名密钥不一致。';

  @override
  String get invalidMigrationDestinationVaultId => '迁移目标 Vault ID 无效。';

  @override
  String get theMigrationDestinationVaultCouldntBe =>
      '迁移目标 Vault 未能作为当前设备的可写 Owner Vault 验证。';

  @override
  String get theMigrationDestinationVaultCouldntBe2 =>
      '迁移目标 Vault 未能打开；本地迁移日志仍可恢复。';

  @override
  String get theMigrationDestinationVaultIsMissing => '迁移目标 Vault 缺少初始签名成员链。';

  @override
  String get invalidMigrationRecordId => '迁移记录 ID 无效。';

  @override
  String get theRestoreJobFinishedButThe => '还原任务已完成，但隔离副本状态未验证，不能从此处操作。';

  @override
  String get remoteDesktopRequiresASignIn => '远程桌面需要登录网关。';

  @override
  String get invalidRemoteFileNameFormat => '远端文件名格式无效';

  @override
  String get invalidRemoteFilePathFormat => '远端文件路径格式无效';

  @override
  String get notificationPermissionWasntGrantedBackgroundSync =>
      '通知权限未授予，未注册后台同步通知。';

  @override
  String get invitationCreatedGiveTheOneTime =>
      '邀请已创建。请通过可信渠道把一次性 token 交给目标账户。';

  @override
  String get theInvitationWasAcceptedButThis =>
      '邀请已接受，但当前设备未能切换到受邀 Vault。请重新选择该 Vault 后同步。';

  @override
  String get theInvitationWasAcceptedButThis2 =>
      '邀请已接受，但此设备没有收到可解密的 Vault 密钥信封。请联系邀请人核对设备公钥。';

  @override
  String get theInvitationRoleCanOnlyBe => '邀请角色只能是 editor 或 viewer。';

  @override
  String get someLocalRecordsCouldntBeVerified3 =>
      '部分本地记录无法验证，无法安全检查主机的分组、凭据或 Jump Host 引用；请先修复或重新同步 Vault。';

  @override
  String get someLocalRecordsCouldntBeVerified4 =>
      '部分本地记录无法验证，无法安全检查凭据引用；请先修复或重新同步 Vault。';

  @override
  String get someLocalRecordsCouldntBeVerified =>
      '部分本地记录无法验证，无法安全检查分组引用；请先修复或重新同步 Vault。';

  @override
  String get someLocalRecordsCouldntBeVerified2 =>
      '部分本地记录无法验证，无法安全检查片段的 SSH 凭据引用；请先修复或重新同步 Vault。';

  @override
  String get theQuotaMustBeBetween1 => '配额必须在 1 字节至 1 TiB 之间。';

  @override
  String get theReVerifiedAccountMustMatch => '重新验证的账户必须与当前登录账户一致。';

  @override
  String get theIsolatedCopyIsntVerifiedYet => '隔离副本尚未验证。服务器会先验证归属和完整性再清理。';

  @override
  String get theIsolatedCopyWasDiscardedYou => '隔离副本已丢弃。可从源归档重新准备。';

  @override
  String get isolatedCopyCleanupHasntFinishedYou => '隔离副本清理尚未完成。可安全重试清理。';

  @override
  String get isolatedCopyCleanupDidntFinishYou => '隔离副本清理未完成，可安全重试。';

  @override
  String get theIsolatedRestoreCopyPreparationJob3 => '隔离还原副本准备任务已中断。在线数据未更改。';

  @override
  String get theIsolatedRestoreCopyPreparationJob =>
      '隔离还原副本准备任务已受理。此任务不会激活副本或替换在线数据。';

  @override
  String get theIsolatedRestoreCopyPreparationJob2 => '隔离还原副本准备任务已结束。在线数据未更改。';

  @override
  String get theIsolatedRestoreCopyWasDiscarded => '隔离还原副本已丢弃。源归档和在线数据未更改。';

  @override
  String get theIsolatedRestoreCopyIsReady => '隔离还原副本已准备完成。在线数据未更改。';

  @override
  String get theIsolatedRestoreCopyIsReady2 =>
      '隔离还原副本已经准备完成，但任务状态更新曾中断。在线数据未更改。';

  @override
  String get theIsolatedRestoreCopyIsInvalid => '隔离还原副本无效，请刷新任务列表后重试。';

  @override
  String get theIsolatedRestoreCopyFailedVerification =>
      '隔离还原副本校验失败，服务器未删除任何未知文件。请联系实例运维人员。';

  @override
  String get theIsolatedRestoreCopyStateChanged => '隔离还原副本状态已变化，请刷新任务列表后重试。';

  @override
  String get theDefaultSshCredentialNoLonger => '默认 SSH 凭据已不存在，请选择有效凭据或清除默认凭据。';

  @override
  String get defaultWorkspace => '默认工作区';

  @override
  String get defaultWorkspacePreferenceSavedEncryptedIt =>
      '默认工作区偏好已加密保存，将通过当前 Vault 同步到其他设备。';

  @override
  String get theDefaultWorkspacePreferenceNeedsAn => '默认工作区偏好需要先完成显式修复。';

  @override
  String restoreDeadlineFormat(String format) {
    return '（恢复期限为 $format）';
  }

  @override
  String get unsupportedArgon2idParameters => '不支持的 Argon2id 参数。';

  @override
  String get notASupportedAtermiusEncryptedArchive => '不是受支持的 Atermius 加密归档。';

  @override
  String get anEncryptedArchiveChunkIsTruncated => '加密归档分块被截断。';

  @override
  String get theEncryptedArchiveExceedsTheFile => '加密归档超过文件大小上限。';

  @override
  String get anArchiveObjectIsEmptyOr => '单个归档对象为空或超过 32 MiB 上限。';

  @override
  String get invalidArchiveArgon2idSaltLength => '归档 Argon2id salt 长度无效。';

  @override
  String get theArchiveContentExceedsTheSize => '归档内容超出可处理大小限制。';

  @override
  String get theArchiveChunkLengthDoesntMatch => '归档分块长度不匹配。';

  @override
  String get theArchiveHeaderIsntCanonicalJson => '归档头不是 canonical JSON。';

  @override
  String get theArchiveHeaderHasUnknownOr => '归档头字段未知或不完整。';

  @override
  String get theArchiveHeaderExceedsTheSize => '归档头超出大小限制。';

  @override
  String get invalidArchiveHeaderLength => '归档头长度无效。';

  @override
  String get wrongArchivePasswordOrTheArchive => '归档密码错误，或归档内容完整性校验失败。';

  @override
  String get theTotalArchiveObjectDataExceeds => '归档对象数据总量超过上限。';

  @override
  String get theNumberOfArchiveObjectsExceeds => '归档对象数量超过上限。';

  @override
  String get theArchiveHasTrailingDataOr => '归档尾部有多余数据或内容不完整。';

  @override
  String get theArchiveFileSizeIsInvalid => '归档文件大小无效或超过上限。';

  @override
  String get theArchiveFileIsTruncated => '归档文件被截断。';

  @override
  String get invalidArchivePlaintextSize => '归档明文大小无效。';

  @override
  String get invalidArchivePlaintextType => '归档明文类型无效。';

  @override
  String get theArchivePlaintextExceedsTheFile => '归档明文超过文件大小上限。';

  @override
  String get theArchiveManifestIsntCanonicalJson => '归档清单不是 canonical JSON。';

  @override
  String get theArchiveManifestExceedsThe16 => '归档清单超过 16 MiB 上限。';

  @override
  String get invalidArchiveManifestLength => '归档清单长度无效。';

  @override
  String get theArchiveVersionServerSpaceOr =>
      '归档版本、服务空间或 Vault 与当前目标不匹配。跨空间和跨 Vault 导入暂不支持。';

  @override
  String get theArchiveLengthOrChunkParameters => '归档长度或分块参数超过资源限制。';

  @override
  String get theSeparateArchivePasswordMustBe => '独立归档密码至少需要 12 个 UTF-8 字节。';

  @override
  String get invalidDecryptedArchiveChunkLength => '解密后的归档分块长度无效。';

  @override
  String get notASupportedLocalEncryptedArchive => '不是受支持的本地加密归档。';

  @override
  String get aLocalEncryptedArchiveChunkIs => '本地加密归档分块被截断。';

  @override
  String get theLocalEncryptedArchiveExceedsThe => '本地加密归档超过文件大小上限。';

  @override
  String get unsupportedLocalArchiveArgon2idParameters =>
      '本地归档 Argon2id 参数不受支持。';

  @override
  String get invalidSshTrustRecordMetadataIn => '本地归档 SSH 信任记录元数据无效。';

  @override
  String get invalidOrderOrUniquenessOfSsh => '本地归档 SSH 信任记录排序或唯一性无效。';

  @override
  String get theNumberOfSshTrustRecords => '本地归档 SSH 信任记录数量超过上限。';

  @override
  String get invalidSshTrustRecordInThe => '本地归档 SSH 信任记录无效。';

  @override
  String get invalidBase64urlEncodingInTheLocal => '本地归档 base64url 编码无效。';

  @override
  String get invalidLocalArchiveSaltLength => '本地归档 salt 长度无效。';

  @override
  String get theLocalArchiveContentIsntCanonical => '本地归档内容不是 canonical JSON。';

  @override
  String get theLocalArchiveContentIsEmpty => '本地归档内容为空或超过大小上限。';

  @override
  String get unsupportedLocalArchiveContentFormatOr => '本地归档内容格式或版本不受支持。';

  @override
  String get theLocalArchiveChunkLengthDoesnt => '本地归档分块长度不匹配。';

  @override
  String get theLocalArchivePassphraseMustBe =>
      '本地归档口令需为 12 到 1024 个 UTF-8 字节。';

  @override
  String get theLocalArchiveContainsDuplicateRecord => '本地归档含重复记录 ID。';

  @override
  String get theLocalArchiveSizeIsInvalid => '本地归档大小无效或超过上限。';

  @override
  String get theLocalArchiveHeaderIsntCanonical => '本地归档头不是 canonical JSON。';

  @override
  String get theLocalArchiveHeaderHasUnknown => '本地归档头字段未知或不完整。';

  @override
  String get theLocalArchiveHeaderExceedsThe => '本地归档头超过大小上限。';

  @override
  String get invalidLocalArchiveHeaderLength => '本地归档头长度无效。';

  @override
  String get wrongLocalArchivePasswordOrThe => '本地归档密码错误，或归档完整性校验失败。';

  @override
  String get theLocalArchiveHasTrailingData => '本地归档尾部多余或内容不完整。';

  @override
  String get theLocalArchiveFileIsTruncated => '本地归档文件被截断。';

  @override
  String get theLocalArchivePlaintextIsEmpty => '本地归档明文为空或超过上限。';

  @override
  String get theLocalArchivePlaintextExceedsThe => '本地归档明文超过大小上限。';

  @override
  String get unsupportedLocalArchiveFormatOrVersion => '本地归档格式或版本不受支持。';

  @override
  String get invalidDecryptedChunkLengthInThe => '本地归档解密分块长度无效。';

  @override
  String get theLocalArchiveRecordListExceeds => '本地归档记录列表超过限制。';

  @override
  String get invalidRecordOrderOrUniquenessIn => '本地归档记录排序或唯一性无效。';

  @override
  String get theNumberOfRecordsInThe => '本地归档记录数量超过上限。';

  @override
  String get invalidLocalArchiveRecord => '本地归档记录无效。';

  @override
  String get theLocalArchiveLengthOrChunk => '本地归档长度或分块参数超过限制。';

  @override
  String get theVaultMembershipChainIsMissing =>
      'Vault membership chain 缺失或超过上限。';

  @override
  String get aDeviceSequenceFloorIsOut => 'device sequence floor 超出安全范围。';

  @override
  String get invalidDeviceSequenceFloorsFormat =>
      'device sequence floors 格式无效。';

  @override
  String get theEpochKeySha256Doesnt => 'epoch key SHA-256 与 binary block 不匹配。';

  @override
  String get theEpochKeyDescriptorsDontMatch =>
      'epoch key descriptors 与 key envelope 集合不一致。';

  @override
  String get invalidDeviceSignatureOnTheEpoch => 'epoch key 的设备签名无效。';

  @override
  String get theEpochKeyProofSignerIsnt => 'epoch key 证明签名者不是该版本的 Vault 成员。';

  @override
  String epochEpochMapsToInconsistentVault(int epoch) {
    return 'epoch $epoch 对应了不一致的 Vault 密钥。';
  }

  @override
  String get theUnsealedKeyEnvelopeDoesntMatch =>
      'key envelope 解封结果与本地 epoch key 不一致。';

  @override
  String get invalidMembershipEncryptionFingerprint =>
      'membership encryption fingerprint 无效。';

  @override
  String get invalidMembershipMemberRoleStateId =>
      'membership member role/state/id 无效。';

  @override
  String get theMembershipSignerWasntAnActive =>
      'membership 签名者在相应签名版本不是 active Owner。';

  @override
  String get objectRefsMustBeUniqueLowercase =>
      'object_refs 必须是严格升序的唯一 lowercase UUID。';

  @override
  String get objectRefsIsntAnArrayOr => 'object_refs 缺失数组格式或超过 1024 条。';

  @override
  String get theSnapshotCurrentHeadIsInconsistent =>
      'snapshot current head 与同一固定历史水位不一致。';

  @override
  String get theSnapshotHeadCommitSeqDoesnt =>
      'snapshot head commit_seq 与固定历史水位不一致。';

  @override
  String get theSnapshotHeadCommitSeqExceeds =>
      'snapshot head commit_seq 超过固定快照水位。';

  @override
  String get aSnapshotHeadIsMissingFields => 'snapshot head 缺失字段或重复。';

  @override
  String get theSnapshotHeadSetDoesntCover => 'snapshot head 集合未覆盖所有历史记录。';

  @override
  String fieldMustBeADecimalString(String field) {
    return '$field 必须是十进制字符串。';
  }

  @override
  String labelMustBeAJsonObject(String label) {
    return '$label 必须是 JSON object。';
  }

  @override
  String uploadedObjectObjectidFailedReadBack(String objectId) {
    return '上传后的对象 $objectId 未能通过回读校验。';
  }

  @override
  String get revisionCommitSeqIsntMonotonicOr => '修订 commit_seq 不单调或超过快照水位。';

  @override
  String get theRevisionHistoryCursorIsInvalid => '修订历史游标无效或重复。';

  @override
  String get theRevisionHistoryExceedsTheArchive => '修订历史超过归档条目上限。';

  @override
  String get theServerGenerationDiffersBetweenRevision =>
      '修订和冲突历史页的服务端 generation 不一致。';

  @override
  String get conflictSeqIsntMonotonicOrExceeds => '冲突 conflict_seq 不单调或超过快照水位。';

  @override
  String get aConflictBranchReferencesABase => '冲突分支引用了快照外的 base revision。';

  @override
  String get theConflictHistoryCursorIsInvalid => '冲突历史游标无效或重复。';

  @override
  String get theConflictHistoryExceedsTheArchive => '冲突历史超过归档条目上限。';

  @override
  String get aConflictResolutionReferencesARevision => '冲突解析引用了快照外的 revision。';

  @override
  String get theConflictResolutionStateAndResolution =>
      '冲突解析状态和 resolution_seq 不匹配。';

  @override
  String get encryptedArchiveFile => '加密归档文件';

  @override
  String get theHistorySnapshotContainsADuplicate => '历史快照包含重复 conflict_id。';

  @override
  String get theHistorySnapshotContainsADuplicate2 => '历史快照包含重复 revision_id。';

  @override
  String historicalSigningDeviceIdIsntIn(String id) {
    return '历史签名设备 $id 不在可验证的 Vault 目录中。';
  }

  @override
  String get historyEntriesExceedTheArchiveResource => '历史记录条目超出归档资源上限。';

  @override
  String get aHistoryPageDoesntMatchThe => '历史页与固定 Vault 快照上下文不匹配。';

  @override
  String get theSameDeviceIdHasConflicting => '同一设备 ID 对应了冲突的公钥目录项。';

  @override
  String get pinningTheServerHistorySnapshot => '固定服务端历史快照';

  @override
  String sha256OfObjectIdDoesnt(String id) {
    return '对象 $id 的 SHA-256 与内容摘要不一致。';
  }

  @override
  String objectIdIsReferencedByVerified(String id) {
    return '对象 $id 被已验签记录引用，但服务端与本地归档缓存都没有对象内容；拒绝生成不完整归档。';
  }

  @override
  String get unsupportedArchiveBinaryBlockKind => '归档 binary block kind 不受支持。';

  @override
  String get archiveBinaryBlockOffsetsHaveGaps =>
      '归档 binary block 偏移有空洞、重叠或超限。';

  @override
  String get tooManyArchiveBinaryBlocks => '归档 binary block 数量过多。';

  @override
  String get theArchiveBinaryBlocksDontCover =>
      '归档 binary block 未覆盖完整 payload。';

  @override
  String get duplicateArchiveBinaryObjectId => '归档 binary object_id 重复。';

  @override
  String get invalidArchiveConflictResolutionOutboxLink =>
      '归档 conflict resolution/outbox 关联无效。';

  @override
  String get invalidArchiveConflictOrderWatermarkOr =>
      '归档 conflict 顺序、水位或唯一性无效。';

  @override
  String get theArchiveCreatedAtIsntAn => '归档 created_at 不是 RFC3339 时间。';

  @override
  String get invalidArchiveEpochKeyBinaryBlock =>
      '归档 epoch key binary block 无效。';

  @override
  String get theArchiveEpochKeyBlockDoesnt =>
      '归档 epoch key block 与签名 descriptor 不匹配。';

  @override
  String archiveEpochKeyKeyDoesntMatch(String key) {
    return '归档 epoch key $key 与本机密钥不匹配。';
  }

  @override
  String get theArchiveGraveyardCountDoesntMatch =>
      '归档 graveyard 与 snapshot tombstone 数量不匹配。';

  @override
  String get theArchiveGraveyardDoesntMatchThe =>
      '归档 graveyard 与验证过的 tombstone 不一致。';

  @override
  String get invalidArchiveKeyEnvelopeContextOr => '归档 key envelope 上下文或唯一性无效。';

  @override
  String get invalidArchiveKeyEnvelopeSealingFormat =>
      '归档 key envelope 密封格式无效。';

  @override
  String get invalidArchiveKeyEnvelopeSignature => '归档 key envelope 签名无效。';

  @override
  String get invalidArchiveLocalPendingSchema => '归档 local_pending schema 无效。';

  @override
  String get theArchiveMembershipDoesntIncludeThe => '归档 membership 不包含当前账户。';

  @override
  String get theArchiveMembershipIsntAValid =>
      '归档 membership 不是当前 Vault chain 的有效前缀。';

  @override
  String get theArchiveMembershipIsNewerThan =>
      '归档 membership 比当前 Vault chain 更新。';

  @override
  String get theArchiveObjectBlockSetDiffers =>
      '归档 object block 集合与已验签 object_refs 不完全相同。';

  @override
  String get theArchiveOutboxBaseEnvelopeIs =>
      '归档 outbox base envelope 缺少 base revision。';

  @override
  String get anArchiveOutboxDeviceSeqIs => '归档 outbox device_seq 超出安全整数范围。';

  @override
  String get invalidArchiveOutboxState => '归档 outbox 状态无效。';

  @override
  String get anArchiveRevisionIsDuplicatedOr => '归档 revision 重复或 base 链不连续。';

  @override
  String get anArchiveSignedEnvelopeIsMissing =>
      '归档 signed envelope 缺少 header。';

  @override
  String get invalidArchiveSnapshotCursorGeneration =>
      '归档 snapshot cursor/generation 无效。';

  @override
  String get anArchiveTombstoneDoesntMatchThe => '归档 tombstone 与最新历史记录不匹配。';

  @override
  String get unsupportedArchiveVaultRole => '归档 vault_role 不受支持。';

  @override
  String get invalidArchiveRevisionOrderOrWatermark => '归档修订顺序或水位无效。';

  @override
  String get theArchiveConflictBaseRevisionDoesnt => '归档冲突 base revision 不存在。';

  @override
  String get anArchiveConflictEnvelopeHasNo =>
      '归档冲突 envelope 没有 signed header。';

  @override
  String get anArchiveConflictResolutionPointsTo => '归档冲突解析指向无效。';

  @override
  String get duplicateExternalDeviceOutboxConflictId =>
      '归档外部设备 outbox 冲突 ID 重复。';

  @override
  String archiveFieldKeyIsMissingOr(String key) {
    return '归档字段 $key 缺失或无效。';
  }

  @override
  String get invalidArchiveFieldType => '归档字段类型无效。';

  @override
  String get anArchiveObjectIdLengthOr =>
      '归档对象 ID、长度或 SHA-256 在应用前校验失败；没有上传或写入本地数据库。';

  @override
  String sha256MismatchForArchiveObject(String objectId) {
    return '归档对象 $objectId 的 SHA-256 不匹配。';
  }

  @override
  String get theNumberOfEncryptedObjectsReferenced => '归档引用的加密对象数量超过上限。';

  @override
  String get theArchiveMustBeBoundTo => '归档必须绑定一个导出设备的 key envelope 集合。';

  @override
  String get unsupportedArchiveLocalConflictKindState =>
      '归档本地 conflict kind/state 不受支持。';

  @override
  String get invalidLinkBetweenArchiveLocalConflict =>
      '归档本地 conflict resolution 状态关联无效。';

  @override
  String get duplicateArchiveLocalConflictId => '归档本地 conflict_id 重复。';

  @override
  String get theArchivesLocalOutboxBaseRevision =>
      '归档本地 outbox base_revision 不可验证。';

  @override
  String get theArchivesLocalOutboxMetadataIs => '归档本地 outbox 元数据无效或重复。';

  @override
  String get theArchiveFormatFieldsAreInvalid =>
      '归档格式字段无效，或与当前 service space/Vault 不同。';

  @override
  String get anArchiveRecordDeviceSeqIs => '归档记录 device_seq 超出安全范围。';

  @override
  String get anArchiveDevicePublicKeyIs => '归档设备公钥无效或重复。';

  @override
  String archiveDeviceDirectoryKeyDoesntMatch(String key) {
    return '归档设备目录 $key 与当前 Vault 目录不一致。';
  }

  @override
  String get invalidArchiveDeviceDirectoryOrMembership =>
      '归档设备目录或 membership chain 格式无效。';

  @override
  String get theCurrentVaultMembershipChainIs =>
      '当前 Vault membership chain 无效。';

  @override
  String get theCurrentVaultDeviceIsntUnlocked => '当前 Vault/设备未解锁，无法创建归档。';

  @override
  String get thisDeviceHasNoVaultEpoch => '当前设备没有可导出的 Vault epoch key。';

  @override
  String get theCurrentDevicesKeyEnvelopeSource =>
      '当前设备的 key envelope 来源或上下文未能验证。';

  @override
  String get theCurrentAccountIsntInThe => '当前账户不在最新签名 membership 中。';

  @override
  String get theSnapshotExceedsTheArchiveCapacity =>
      '快照超过归档容量上限（100,000 条记录）；未生成归档。';

  @override
  String get collectingAndCheckingEncryptedObjects => '收集并核对加密对象';

  @override
  String get theTombstoneGraveyardCouldntBeRebuilt =>
      '无法从固定历史重建 tombstone graveyard。';

  @override
  String get theLastSnapshotPageStillContains => '最后一页快照仍包含续读游标。';

  @override
  String get duplicateServerKeyEnvelopeContext => '服务端 key envelope 上下文重复。';

  @override
  String serverObjectObjectidConflictsWithThe(String objectId) {
    return '服务端对象 $objectId 与归档内容冲突，拒绝覆盖不可变对象。';
  }

  @override
  String get theServerSnapshotItemCountDoesnt => '服务端快照 item_count 与分页清单数量不匹配。';

  @override
  String get theServerSnapshotItemCountDoesnt2 =>
      '服务端快照 item_count 与完整清单数量不匹配。';

  @override
  String get theServerSnapshotItemCountIs => '服务端快照 item_count 分页间不一致。';

  @override
  String get invalidServerSnapshotItemCount => '服务端快照 item_count 无效。';

  @override
  String get theServerSnapshotItemCountIs2 => '服务端快照 item_count 无效或发生变化。';

  @override
  String get theServerSnapshotPageManifestHas => '服务端快照分页清单条目过多。';

  @override
  String get invalidServerSnapshotPageBoundaryOr => '服务端快照分页边界或清单格式无效。';

  @override
  String get theServerSnapshotContainsInvalidRecords => '服务端快照包含无效记录。';

  @override
  String get theServerSnapshotReturnedAnEmpty => '服务端快照在完成前返回了空分页。';

  @override
  String get theServerSnapshotManifestExceedsThe => '服务端快照清单超过客户端 64 MiB 上限。';

  @override
  String get theServerSnapshotContinuationCursorIs => '服务端快照续读游标为空、重复或无效。';

  @override
  String get aLocalConflictKindStateIs => '本地 conflict kind/state 无效或重复。';

  @override
  String get invalidLinkToTheLocalConflict => '本地 conflict resolution 状态关联无效。';

  @override
  String get invalidLocalConflictResolutionOutboxLink =>
      '本地 conflict resolution/outbox 关联无效。';

  @override
  String invalidLocalEpochKeyIdentifierValuevalue(String valueValue) {
    return '本地 epoch key 标识无效: $valueValue';
  }

  @override
  String get theLocalOutboxBaseEnvelopeDoesnt =>
      '本地 outbox base envelope 与 revision 不匹配。';

  @override
  String get theLocalOutboxBaseRevisionCant =>
      '本地 outbox base_revision 不可归档验证。';

  @override
  String get aLocalOutboxRevisionIdIs => '本地 outbox revision_id 缺失或重复。';

  @override
  String get theLocalOutboxMetadataDoesntMatch => '本地 outbox 元数据与签名头不匹配。';

  @override
  String get theLocalOutboxContainsADuplicate => '本地 outbox 包含重复 op_id。';

  @override
  String get theLocalOutboxStateCantSafely => '本地 outbox 状态不能安全往返归档。';

  @override
  String get localOutboxConflictsExceedTheArchive =>
      '本地 outbox/conflict 超出归档条目上限。';

  @override
  String get thisDevicesEpochKeysDontFully =>
      '本机 epoch key 与 key envelope 集合不完整匹配。';

  @override
  String get thisDevicesPublicKeyDoesntMatch => '本机设备公钥与服务端 Vault 目录不匹配，不能导出。';

  @override
  String get thisDevicesIdentityCouldntBeMatched => '本机身份未能与当前 Vault 设备目录匹配。';

  @override
  String get checkingArchiveConflictBranchFields => '检查归档 conflict branch 字段';

  @override
  String get checkingArchiveConflictFields => '检查归档 conflict 字段';

  @override
  String get checkingArchiveManifestFieldTypes => '检查归档 manifest 字段类型';

  @override
  String get checkingArchiveManifestEntryLimits => '检查归档 manifest 条目上限';

  @override
  String get checkingArchiveManifestIdentityAndRole => '检查归档 manifest 身份和角色';

  @override
  String get checkingArchiveManifestTopLevelFields => '检查归档 manifest 顶层字段';

  @override
  String get checkingArchiveMembershipFields => '检查归档 membership 字段';

  @override
  String get checkingArchiveOutboxFields => '检查归档 outbox 字段';

  @override
  String get checkingArchiveRevisionFields => '检查归档 revision 字段';

  @override
  String get checkingArchiveSnapshotHeadFields => '检查归档 snapshot head 字段';

  @override
  String get checkingArchiveSnapshotSchema => '检查归档 snapshot schema';

  @override
  String get checkingArchiveDeviceDirectoryFields => '检查归档设备目录字段';

  @override
  String get theSignedObjectRefsDontMatch =>
      '签名 object_refs 与加密 plaintext manifest 不匹配。';

  @override
  String get decryptingTheArchiveContainer => '解密归档容器';

  @override
  String get aRecordEnvelopeIsMissingIts => '记录 envelope 缺少签名 header。';

  @override
  String get theRecordSignerEpochDoesntBelong =>
      '记录 signer/epoch 不属于该 membership 版本。';

  @override
  String theBaseRevisionChainForRecord(String recordId) {
    return '记录 $recordId 的 base_revision 链不连续。';
  }

  @override
  String get trustCouldntBeEstablishedForThe =>
      '记录的 signer 或 key epoch 未能建立信任。';

  @override
  String get theRecordSignatureHeaderDoesntMatch => '记录签名 header 与归档索引不匹配。';

  @override
  String get invalidDeviceSigningKeyLength => '设备 signing key 长度无效。';

  @override
  String theHistoryDirectoryOfDeviceId(String id) {
    return '设备 $id 的历史目录与当前 Vault 目录冲突。';
  }

  @override
  String get readingEveryHistoryPageOfThe => '读取固定快照的全部历史页';

  @override
  String get readingTheArchiveManifestAndBinary => '读取归档清单和 binary blocks';

  @override
  String get verifyingArchiveKeyEnvelopesAndEpoch =>
      '验证归档 key envelope 和 epoch key';

  @override
  String get verifyingArchiveEncryptedObjectBlocks => '验证归档加密对象 block';

  @override
  String get verifyingArchiveHistoryConflicts => '验证归档历史 conflicts';

  @override
  String get verifyingArchiveHistoryRevisions => '验证归档历史 revisions';

  @override
  String get verifyingTheArchivesLocalOutboxAnd =>
      '验证归档本地 outbox 和 conflict branches';

  @override
  String get verifyingArchiveFormatAndTarget => '验证归档格式和目标';

  @override
  String get verifyingArchiveDeviceSequenceWatermarks => '验证归档设备序列水位';

  @override
  String get verifyingTheMemberSignatureChainAnd => '验证成员签名链和设备信任';

  @override
  String get verifyingSignaturesKeyEpochsAndObject => '验证签名、密钥 epoch 和对象引用';

  @override
  String get verifyingTheDeviceDirectoryAndSigned => '验证设备目录和签名成员链';

  @override
  String get attachmentsAreLimitedTo1Gib => '附件大小上限为 1 GiB。';

  @override
  String get theVaultHasNoActiveDevice => '保险库没有活动的设备能力报告。';

  @override
  String get theVaultHasNoActiveDevices => '保险库中没有能够读取 v2 附件的活动设备。';

  @override
  String get theServerDoesNotSupportSigned => '服务器不支持 v2 附件所需的签名设备能力报告。';

  @override
  String get theServerReturnedAnInvalidVault => '服务器返回了无效的保险库设备清单；v2 上传已被阻止。';

  @override
  String get thisClientCannotAuthenticateOtherDevices =>
      '此客户端无法验证其他设备的签名能力报告；v2 上传已被阻止。';

  @override
  String get thisDeviceCapabilityReportCouldNot => '无法发布此设备的能力报告；未暂存任何附件数据。';

  @override
  String get thisDeviceHasNotPublishedIts => '此设备尚未发布其签名附件能力报告。';

  @override
  String get thisPlatformCannotSafelySaveAttachments =>
      '此平台无法安全保存超过 256 MiB 的附件；未暂存任何附件数据。';

  @override
  String get someDevicesInTheVaultDont => 'Vault 中仍有设备不支持此附件大小。';

  @override
  String get v2PreflightIsOnlyRequiredAbove => '仅超过 256 MiB 时才需要 v2 预检。';

  @override
  String devicenameHasNoValidSignedReport(String deviceName) {
    return '$deviceName 没有适用于 1 GiB 附件记录的有效签名报告；请先更新或移除该活动设备，再启用 v2。';
  }

  @override
  String get theDownloadedAttachmentCiphertextDigestOr => '下载的附件密文摘要或长度不匹配。';

  @override
  String get differentAttachmentsReferenceTheSameObject => '不同附件重复引用同一个对象。';

  @override
  String get hostObjectRefsMustBeUnique =>
      '主机 object_refs 必须是严格升序的唯一 lowercase UUID。';

  @override
  String get hostObjectRefsMustBeAn => '主机 object_refs 必须是最多 1024 项的数组。';

  @override
  String get duplicateHostAttachmentBlobId => '主机附件 blob ID 重复。';

  @override
  String get invalidHostAttachmentManifestFormat => '主机附件清单格式无效。';

  @override
  String get theHostAttachmentManifestExceedsThe => '主机附件清单超过 32 KiB 存储上限。';

  @override
  String get localIntegrityVerificationOfTheEncrypted => '加密附件对象本地完整性验证失败。';

  @override
  String get theEncryptedAttachmentManifestDoesntMatch =>
      '加密附件清单与 object_refs 不一致。';

  @override
  String get invalidPersistedUploadChunkSize => '持久化上传分块大小无效。';

  @override
  String get invalidPersistedUploadProgress => '持久化上传进度无效。';

  @override
  String get integrityVerificationOfAPersistedAttachment => '持久化附件密文块完整性验证失败。';

  @override
  String get theServerReturnedAnInvalidUpload => '服务端上传预约返回无效。';

  @override
  String get anAttachmentObjectAlreadyOnThe => '服务端已有附件对象与持久化密文不一致。';

  @override
  String get theServerAttachmentUploadReceiptDoesnt => '服务端附件上传回执与密文对象不一致。';

  @override
  String get integrityVerificationOfTheLocalAttachment => '本地待上传附件密文完整性验证失败。';

  @override
  String get theLocalAttachmentObjectWaitingFor => '本地待上传附件对象缺失。';

  @override
  String get theLocalAttachmentEncryptionDirectoryIs => '本地附件加密目录缺失或完整性验证失败。';

  @override
  String get thisV2AttachmentExceeds256Mib =>
      '此 v2 附件超过 256 MiB；当前客户端尚未实现有界解密和流式保存。';

  @override
  String get thisHostsAttachmentObjectReferencesExceed =>
      '此主机附件对象引用超过 1024 个上限。';

  @override
  String get theAttachmentIsntInThisHosts => '附件不在此主机的加密清单中。';

  @override
  String get theAttachmentObjectIdDuplicatesAn => '附件对象 ID 与主机现有引用重复。';

  @override
  String get theTotalAttachmentPlaintextLengthExceeds => '附件明文总长度超过清单声明。';

  @override
  String get attachmentPlaintextDigestOrTotalLength => '附件明文摘要或总长度验证失败。';

  @override
  String get theComSerialConsoleRequiresThe => 'COM 串口 Console 需要 Windows 客户端。';

  @override
  String get theBrowserCantStartALocal => '浏览器不能直接启动本机 Shell，请使用桌面客户端。';

  @override
  String get theSerialInputQueueIsFull => '\r\n[串口输入队列已满，本次输入未发送；请分批输入。]\r\n';

  @override
  String get couldntStartTheSerialConsole => '\r\n[无法启动串口 Console]\r\n';

  @override
  String get theSerialConsoleFailedToStart => '串口 Console 启动失败。';

  @override
  String get theSerialPortDoesntSupportThis => '串口不支持此配置。';

  @override
  String get serialWriteFailedOrTheDevice => '串口写入失败或设备已断开。';

  @override
  String get serialWriteTimedOut => '串口写入超时。';

  @override
  String get invalidSerialPortOrBaudRate => '串口或波特率无效。';

  @override
  String get serialReadFailedOrTheDevice => '串口读取失败或设备已断开。';

  @override
  String get serialInputExceedsTheLimit => '串口输入超过限制。';

  @override
  String couldntOpenItemWindowsGetlasterrorCheck(
    Object item,
    int GetLastError,
  ) {
    return '无法打开 $item（Windows $GetLastError），请检查串口名称和占用情况。';
  }

  @override
  String get couldntReadTheSerialPortConfiguration => '无法读取串口配置。';

  @override
  String get unsupportedAttachmentManifestFormat => '不支持的附件清单格式。';

  @override
  String get invalidAttachmentMimeTypeFormat => '附件 MIME 类型格式无效。';

  @override
  String get invalidAttachmentBlobIdFormat => '附件 blob ID 格式无效。';

  @override
  String get invalidAttachmentEncryptionDirectoryFormat => '附件加密目录格式无效。';

  @override
  String get attachmentEncryptionDirectoryAuthenticationOrParsing =>
      '附件加密目录认证或解析失败。';

  @override
  String get theAttachmentEncryptionDirectoryExceedsThe => '附件加密目录超过大小上限。';

  @override
  String get invalidAttachmentBlockFieldFormat => '附件块字段格式无效。';

  @override
  String get theAttachmentBlockCountDoesntMatch => '附件块数量与文件长度不匹配。';

  @override
  String get invalidAttachmentBlockCount => '附件块数量无效。';

  @override
  String get theNumberOfAttachmentBlocksExceeds => '附件块数量超过 v2 格式上限。';

  @override
  String get theNumberOfAttachmentBlocksExceeds2 => '附件块数量超过当前格式上限。';

  @override
  String get invalidAttachmentBlockEntryFormat => '附件块条目格式无效。';

  @override
  String get invalidAttachmentBlockManifestFormat => '附件块清单格式无效。';

  @override
  String get attachmentBlockAuthenticationFailedTheFile => '附件块认证失败；文件可能已被篡改。';

  @override
  String get attachmentBlockOrderLengthOrUniqueness => '附件块顺序、长度或唯一性验证失败。';

  @override
  String get theAttachmentSizeIsOutsideThe => '附件大小超出客户端支持范围。';

  @override
  String get attachmentIntegrityOrFinalLengthVerification => '附件完整性或终止长度验证失败。';

  @override
  String get theAttachmentCiphertextObjectIsMissing => '附件密文对象缺失。';

  @override
  String get attachmentCiphertextDigestOrLengthVerification => '附件密文摘要或长度验证失败。';

  @override
  String get invalidAttachmentCiphertextLength => '附件密文长度无效。';

  @override
  String get invalidAttachmentKeyFormat => '附件密钥格式无效。';

  @override
  String get theAttachmentObjectIdIsInvalid => '附件对象 ID 无效或重复。';

  @override
  String get invalidAttachmentFileNameOrMime => '附件文件名或 MIME 类型格式无效。';

  @override
  String get invalidAttachmentFileNameFormat => '附件文件名格式无效。';

  @override
  String get attachmentPlaintextBlockLengthVerificationFailed => '附件明文块长度验证失败。';

  @override
  String get invalidAttachmentPlaintextDigestFormat => '附件明文摘要格式无效。';

  @override
  String get invalidAttachmentManifestEntryFormat => '附件清单条目格式无效。';

  @override
  String get theAttachmentSourceReturnsOnlyEmpty => '附件源只返回空数据块。';

  @override
  String get theAttachmentSourceKeepsReturningEmpty => '附件源在文件尾部持续返回空数据块。';

  @override
  String get theAttachmentSourceEndedEarlyIts => '附件源提前结束，长度与文件信息不一致。';

  @override
  String get anAttachmentSourceBlockExceedsThe => '附件源数据块超过 4 MiB 读取上限。';

  @override
  String get theAttachmentSourceLengthExceedsThe => '附件源长度超过文件信息。';

  @override
  String get invalidAttachmentDirectoryNonceFormat => '附件目录 nonce 格式无效。';

  @override
  String get theAttachmentDirectoryBlockCountDoesnt => '附件目录块数量与描述符不匹配。';

  @override
  String get attachmentDirectoryBlockOrderLengthOr => '附件目录块顺序、长度或唯一性验证失败。';

  @override
  String get invalidAttachmentDirectoryCiphertextSize => '附件目录密文大小无效。';

  @override
  String get attachmentDirectoryCiphertextDigestOrLength => '附件目录密文摘要或长度验证失败。';

  @override
  String get invalidAttachmentDirectoryCiphertextLength => '附件目录密文长度无效。';

  @override
  String get invalidAttachmentDirectoryObjectIdFormat => '附件目录对象 ID 格式无效。';

  @override
  String get invalidAttachmentDirectoryDigestFormat => '附件目录摘要格式无效。';

  @override
  String get theAttachmentExceedsThe1Gib => '附件超过 1 GiB 客户端大小上限。';

  @override
  String get theAttachmentExceedsThe256Mib => '附件超过 256 MiB 客户端大小上限。';

  @override
  String get theShareRequestIsMalformedOr => '分享请求格式无效，或来自另一个服务端实例。';

  @override
  String get invalidShareRequestAccountIdentifier => '分享请求账户标识无效。';

  @override
  String get invalidDeviceSelfProofPublicKey => '设备自证明公钥或签名长度无效。';

  @override
  String get invalidDeviceSelfProofFields => '设备自证明字段无效。';

  @override
  String get invalidDeviceSelfProofSignature => '设备自证明签名无效。';

  @override
  String get invalidDeviceSelfProofAccountIdentifier => '设备自证明账户标识无效。';

  @override
  String remoteDesktopConnectionFailedCodeLast(String last) {
    return '远程桌面连接失败（代码 $last）。请检查凭据、证书信任和网关日志。';
  }

  @override
  String get remoteDesktopDisconnected => '远程桌面已断开。';

  @override
  String get resolutionAndScaling => '分辨率与缩放';

  @override
  String get apply => '应用';

  @override
  String get theServerDoesntSupportResizingOnly => '服务器不支持调整分辨率，只能本地缩放。';

  @override
  String get theServerSupportsLiveResizingDisplay => '服务器支持实时调整分辨率（显示控制通道）。';

  @override
  String get theServerSupportsResizingExtendeddesktopsize =>
      '服务器支持调整分辨率（ExtendedDesktopSize）。';

  @override
  String get theServerDoesntOfferDisplayControl => '服务器未提供显示控制，新分辨率在重新连接后生效。';

  @override
  String get waitingForTheServerToReport => '正在等待服务器报告是否支持调整分辨率…';

  @override
  String get thisSessionUsesAllLocalMonitors => '此会话使用全部本机显示器，远程分辨率由显示器布局决定。';

  @override
  String get scalesThisWindowOnlyTheRemote => '只缩放本窗口，不改变远程分辨率。';

  @override
  String get actualSize11Scrollable => '实际大小（1:1，可滚动）';

  @override
  String get width => '宽度';

  @override
  String get serverDefaultDontRequestAResize => '服务器默认（不请求调整）';

  @override
  String get localDisplay => '本地显示';

  @override
  String get custom => '自定义…';

  @override
  String get remoteResolution => '远程分辨率';

  @override
  String get fitToWindow => '适应窗口';

  @override
  String get height => '高度';

  @override
  String get clipboardIsLimitedTo64Kib => '剪贴板限制为 64 KiB';

  @override
  String invalidRdpOptionsMessage(String message) {
    return 'RDP 选项无效：$message';
  }

  @override
  String get remoteDesktopConnectionClosed => '远程桌面连接已关闭。';

  @override
  String get remoteDesktopSetupTimedOutCheck => '远程桌面设置超时。请检查网关和目标。';

  @override
  String get remoteDesktopStreamFailed => '远程桌面流失败。';

  @override
  String get unableToConnectCheckTheDesktop => '无法连接。请检查桌面网关、Relay 策略、凭据和证书信任。';

  @override
  String get theHostSettingsChangedReconnect => '主机配置已变化，请重新连接。';

  @override
  String get theResolutionSettingAppliesToThis => '分辨率设置仅对本次会话生效，未能保存到主机。';

  @override
  String get inAMultiMonitorSessionThe =>
      '多显示器会话的分辨率由本机显示器决定，关闭“使用所有显示器”后才能设置。';

  @override
  String get stoppedRequestingAResizeTheServer => '已停止请求调整；服务器保持当前分辨率。';

  @override
  String get theInstalledRdpEngineDoesntSupport =>
      '已安装的 RDP 引擎不支持此主机的 RDP 选项，已按默认设置连接。';

  @override
  String get couldntConnectToTheLocalGuacd =>
      '无法连接本机 guacd（127.0.0.1:4822）。请启动网关，或使用已登录的云端工作区。';

  @override
  String get theServerDoesntAcceptThisResolution => '服务器不接受此分辨率。';

  @override
  String get theServerDoesntSupportResizingOnly2 => '服务器不支持调整分辨率，仅可本地缩放。';

  @override
  String get theServerRefusedTheResize => '服务器拒绝调整分辨率。';

  @override
  String get theServerDoesntOfferDynamicResolution =>
      '服务器未提供动态分辨率，新分辨率将在重新连接后生效。';

  @override
  String get theServerLacksTheResourcesFor => '服务器资源不足，无法使用此分辨率。';

  @override
  String get thisRdpCertificateWasntTrustedThe => '未信任此 RDP 证书，连接已取消。';

  @override
  String get thisVncServerDoesntSupportResizing =>
      '此 VNC 服务器不支持调整分辨率（未协商 ExtendedDesktopSize），仅可本地缩放。设置已保留。';

  @override
  String get clipboardTextIsTurnedOffFor => '此主机已关闭剪贴板文本。';

  @override
  String get thisHostCantSaveCertificates => '此主机无法保存证书。';

  @override
  String thisClientCantProvideJoinThe(String join) {
    return '此客户端无法提供：$join。其余选项照常生效。';
  }

  @override
  String get theCertificateCouldntBeSavedThe =>
      '证书未能保存。主机可能已被修改或工作区已锁定，请重试或重新连接。';

  @override
  String couldntSaveRemoteFilesError(Object error) {
    return '远程文件未能保存：$error';
  }

  @override
  String get invalidRemoteDesktopHostSettings => '远程桌面主机配置无效。';

  @override
  String get invalidRemoteDesktopImage => '远程桌面图像无效。';

  @override
  String get theRemoteDesktopConnectionFailed => '远程桌面连接失败。';

  @override
  String get theRemoteDesktopConnectionClosed => '远程桌面连接已关闭。';

  @override
  String get theRemoteDesktopConnectionTimedOut => '远程桌面连接超时。请检查目标地址和网络。';

  @override
  String get rdpCertificateFingerprintChanged => 'RDP 证书指纹已变更';

  @override
  String get saveRemoteClipboardFiles => '保存远程剪贴板文件';

  @override
  String get saveRemoteClipboardFiles2 => '保存远程剪贴板文件…';

  @override
  String saveRemoteClipboardFilesFilecountFiles(
    int fileCount,
    String formatTransferBytes,
  ) {
    return '保存远程剪贴板文件（$fileCount 个，$formatTransferBytes）…';
  }

  @override
  String get trustAndSave => '信任并保存';

  @override
  String get trustThisRdpCertificate => '信任此 RDP 证书？';

  @override
  String get resolutionAndScaling2 => '分辨率与缩放…';

  @override
  String get sendCtrlAltDelete => '发送 Ctrl+Alt+Delete';

  @override
  String get sendLocallyCopiedFiles => '发送本机已复制的文件';

  @override
  String get cancel => '取消';

  @override
  String get openInNewWindow => '在新窗口中打开';

  @override
  String get copyRemoteClipboardText => '复制远程剪贴板文本';

  @override
  String savedCountItems(int count) {
    return '已保存 $count 项。';
  }

  @override
  String savedCountItemsAndPlacedThem(int count) {
    return '已保存 $count 项，并已放入本机剪贴板，可直接粘贴。';
  }

  @override
  String get savedSha256 => '已保存的 SHA-256';

  @override
  String get currentCertificateSha256 => '当前证书 SHA-256';

  @override
  String get couldntSendClipboardText => '无法发送剪贴板文本。';

  @override
  String get updateAndConnect => '更新并连接';

  @override
  String get theServerCertificateDiffersFromThe =>
      '服务器证书与已保存的记录不同。请核对新指纹，确认后更新此主机的信任记录并继续连接。';

  @override
  String get thereAreNoCopiedFilesOn => '本机剪贴板中没有已复制的文件。';

  @override
  String get saving => '正在保存…';

  @override
  String savingRemoteFilesDoneTotal(int done, int total) {
    return '正在保存远程文件 $done/$total';
  }

  @override
  String get thisCertificateIsntTrustedYetVerify =>
      '此证书尚未受信任。请核对指纹，确认后保存到此主机并继续连接。';

  @override
  String get oneWindowPerMonitor => '每个显示器一个窗口';

  @override
  String get pasteLocalClipboardText => '粘贴本机剪贴板文本';

  @override
  String get remoteDesktopMenu => '远程桌面菜单';

  @override
  String get chooseFilesForTheRemoteClipboard => '选择文件放入远程剪贴板…';

  @override
  String get theRdpCertificateIsntTrustedYet => 'RDP 证书尚未信任，需要确认 SHA-256 指纹。';

  @override
  String get folderNestingIsTooDeep => '文件夹嵌套过深';

  @override
  String get noFilesToSend => '没有要发送的文件';

  @override
  String notARegularFileOrFolder(String name) {
    return '不是普通文件或文件夹：$name';
  }

  @override
  String get tooManyFilesForTheClipboard => '剪贴板中的文件过多';

  @override
  String unsupportedOrDuplicateFileNameName(String name) {
    return '文件名不受支持或重复：$name';
  }

  @override
  String fileTooLargeRelativepath(String relativePath) {
    return '文件过大：$relativePath';
  }

  @override
  String get theTotalSizeOfTheRemote => '远程文件总大小超过上限。';

  @override
  String get rdpTlsHandshakeFailed20008No =>
      'RDP TLS 握手失败（20008）。未取得可确认的证书，请检查目标端口和 TLS 配置。';

  @override
  String get theRdpSessionDisconnected => 'RDP 会话已断开。';

  @override
  String get invalidRdpImageSize => 'RDP 图像尺寸无效。';

  @override
  String get theRdpEngineCantBeLoaded => 'RDP 引擎无法加载。请安装完整的 Windows 客户端。';

  @override
  String get theRdpEngineIsTooOld => 'RDP 引擎版本过旧，无法应用此主机的 RDP 选项。请安装完整的客户端更新。';

  @override
  String rdpConnectionFailedToradixstringCheckThe(String toRadixString) {
    return 'RDP 连接失败（$toRadixString）。请检查地址、用户名和密码。';
  }

  @override
  String get theRdpConfigurationIsInvalidOr => 'RDP 配置无效或引擎初始化失败。';

  @override
  String placedCountFilesOnTheRemote(int count) {
    return '已将 $count 个文件放入远程剪贴板，可在远程粘贴。';
  }

  @override
  String get theCurrentRdpEngineDoesntSupport => '当前 RDP 引擎不支持文件剪贴板。';

  @override
  String couldntSendFilesMessage(String message) {
    return '无法发送文件：$message';
  }

  @override
  String get couldntStartTheRdpEngineCheck => '无法启动 RDP 引擎。请检查客户端安装。';

  @override
  String get couldntReadTheSelectedFiles => '无法读取所选文件。';

  @override
  String get theTargetRdpSessionDoesntHave =>
      '目标 RDP 会话没有启用文件剪贴板，或此主机关闭了文件剪贴板。';

  @override
  String get theTargetRdpSessionDoesntHave2 => '目标 RDP 会话没有启用文本剪贴板。';

  @override
  String get theRemoteClipboardHasNoFiles => '远程剪贴板中没有可保存的文件。';

  @override
  String get anUnsafeFileNameOnThe => '远程剪贴板中的文件名不安全，已忽略。';

  @override
  String get theRemoteFilesCouldntBeSaved => '远程文件未能保存。';

  @override
  String get sshHostsDontHaveRemoteDesktop => 'SSH 主机没有远程桌面显示设置。';

  @override
  String get theHostChangedTheResolutionSetting => '主机已变化，分辨率设置未保存。';

  @override
  String get theHostOrCertificateTrustChanged => '主机或证书信任已变化，请重新连接。';

  @override
  String get theHostsRdpOptionsWereSaved => '主机的 RDP 选项由更新版本保存，分辨率设置未保存。';

  @override
  String get theHostsVncDisplaySettingsWere => '主机的 VNC 显示设置由更新版本保存，分辨率设置未保存。';

  @override
  String get couldntSaveTheCertificate => '证书保存失败。';

  @override
  String atMostMaxdrivesRedirectedFolders(int maxDrives) {
    return '最多 $maxDrives 个重定向文件夹';
  }

  @override
  String atMostMaxusbdevicesUsbDevices(int maxUsbDevices) {
    return '最多 $maxUsbDevices 个 USB 设备';
  }

  @override
  String get driveFolderMustBeAnAbsolute => '驱动器文件夹必须是绝对路径';

  @override
  String get driveNameMustBe131 => '驱动器名称必须为 1–31 个字母、数字、空格、_ 或 -';

  @override
  String get monitorLayoutExceedsRdpLimits => '显示器布局超出 RDP 限制';

  @override
  String get redirectedFolderNamesMustBeUnique => '重定向文件夹名称必须唯一';

  @override
  String get usbDevicesMustBeUniqueVendor =>
      'USB 设备必须是唯一的 vendor:product 十六进制 ID';

  @override
  String get unsupportedRdpDisplayScale => '不支持的 RDP 显示缩放';

  @override
  String get addFolder => '添加文件夹';

  @override
  String get allPrinters => '所有打印机';

  @override
  String get defaultPrinter => '默认打印机';

  @override
  String get displayClipboardAndLocalResources => '显示、剪贴板和本机资源';

  @override
  String get doNotPlay => '不播放';

  @override
  String get eachMonitorCanBeOpenedIn => '每个显示器都可以在单独的窗口中打开';

  @override
  String get leaveOnRemoteComputer => '保留在远程计算机上';

  @override
  String get off2 => '关闭';

  @override
  String get onlyDevicesAlreadyUsingTheWinusb =>
      '仅限已在使用 WinUSB 驱动程序的设备，不会安装驱动程序。';

  @override
  String get playOnThisComputer => '在此计算机上播放';

  @override
  String get printers => '打印机';

  @override
  String get rdpOptions => 'RDP 选项';

  @override
  String get redirectedFolders => '重定向的文件夹';

  @override
  String get remoteAudio => '远程音频';

  @override
  String get remoteDisplayScale => '远程显示缩放';

  @override
  String get removeFolder => '移除文件夹';

  @override
  String get requiresAMatchingPrinterDriverOn => '需要远程计算机上有匹配的打印机驱动程序';

  @override
  String get requiresCameraRedirectionSupportOnThe => '需要服务器支持摄像头重定向';

  @override
  String get resolutionAndLocalScaling => '分辨率与本地缩放';

  @override
  String get savedRdpOptionsWereWrittenBy => '已保存的 RDP 选项由更新版本写入，已被忽略。保存将替换它们。';

  @override
  String get usbDevicesVendorProduct => 'USB 设备（vendor:product）';

  @override
  String get vncDisplay => 'VNC 显示';

  @override
  String get theRemoteDesktopInTheMain => '主窗口中的远程桌面已关闭或断开。';

  @override
  String get remoteDesktop => '远程桌面';

  @override
  String get closeThisMonitorWindow => '关闭此显示器窗口';

  @override
  String get couldntOpenTheRemoteDesktopWindow => '无法打开远程桌面窗口，请返回主窗口重试。';

  @override
  String titleMonitorValuevalueValuevalue2(
    String title,
    int valueValue,
    String valueValue2,
  ) {
    return '$title · 显示器 $valueValue$valueValue2';
  }

  @override
  String get primary => '（主）';

  @override
  String aHostCanHaveAtMost2(int maxHostPortForwardProfiles) {
    return '一台主机最多可有 $maxHostPortForwardProfiles 个端口转发配置';
  }

  @override
  String get dynamicForwardingDoesNotHaveA => '动态转发没有固定目标';

  @override
  String get forwardDestinationHostIsInvalid => '转发目标主机无效';

  @override
  String get forwardDestinationPortMustBeBetween => '转发目标端口必须介于 1 到 65535 之间';

  @override
  String get forwardListenerAddressAndPortMust => '转发监听地址和端口必须唯一';

  @override
  String get forwardListenerAddressMustBeLocalhost =>
      '转发监听地址必须是 localhost 或 IP 地址';

  @override
  String get forwardListenerPortMustBeBetween => '转发监听端口必须介于 0 到 65535 之间';

  @override
  String get forwardListenersMustBindToLoopback => '除非已确认网络暴露，否则转发监听器必须绑定到回环地址';

  @override
  String get forwardProfileIdIsInvalid => '转发配置 ID 无效';

  @override
  String get forwardProfileIdsMustBeUnique => '转发配置 ID 必须唯一';

  @override
  String get forwardProfileNameMustBe1 => '转发配置名称必须为 1–64 个字符';

  @override
  String get hostAddressIsRequired => '主机地址为必填项';

  @override
  String get hostLoginAndAuthenticationSettingsDo => '主机登录和认证设置不匹配';

  @override
  String get hostNameIsRequired => '主机名称为必填项';

  @override
  String get portMustBeBetween1And => '端口必须介于 1 到 65535 之间';

  @override
  String get rdpCertificateFingerprintMustContain64 =>
      'RDP 证书指纹必须包含 64 位十六进制 SHA-256 数字';

  @override
  String get remoteDesktopsUsePasswordLoginWithout =>
      '远程桌面使用密码登录，不使用 SSH 路由或转发';

  @override
  String get remoteForwardingTargetsMustUseThis =>
      '除非已确认网络暴露，否则远程转发目标必须使用此设备的回环地址';

  @override
  String get unnamedHost => '未命名主机';

  @override
  String get untitledSnippet => '未命名片段';

  @override
  String get usernameIsRequired => '用户名为必填项';

  @override
  String get enterAValidSshPassword => '请输入有效的 SSH 密码';

  @override
  String get enterAValidSshPrivateKey => '请输入有效的 SSH 私钥和口令';

  @override
  String get aPortNumberIsRequiredAfter => '-p 后需要端口号';

  @override
  String get aUserNameIsRequiredBefore => '@ 前需要用户名';

  @override
  String get serialFormatConsoleTtyCom3B => '串口格式：console tty @COM3 -b 115200';

  @override
  String get invalidHostOrUserNameFormat => '主机或用户名格式无效';

  @override
  String get onlyUserHostAndPPort => '仅支持 [用户@]主机 和 -p 端口；不会执行 Shell 参数';

  @override
  String get dontSpecifyThePortBothIn => '地址端口和 -p 不能重复指定';

  @override
  String get openLocalConsole => '打开本机 Console';

  @override
  String formatVerbValuevalueHostPValuevalue2(
    String verb,
    String valueValue,
    int valueValue2,
  ) {
    return '格式：$verb $valueValue主机 -p $valueValue2';
  }

  @override
  String get baudRateFormatB115200 => '波特率格式：-b 115200';

  @override
  String get baudRateMustBe504000000 => '波特率范围为 50–4000000';

  @override
  String get thePortCanOnlyBeSpecified => '端口只能指定一次';

  @override
  String get portMustBe165535 => '端口范围为 1–65535';

  @override
  String get enterAValidSerialPortFor => '请输入有效串口，例如 console tty @COM3';

  @override
  String connectAddressBaudrateBaud8n1(String address, int baudRate) {
    return '连接 $address · $baudRate baud · 8N1';
  }

  @override
  String get theActivePaneIsntInThe => '活动面板不在分屏中。';

  @override
  String get invalidWindowSetHostPathOr => '窗口组合主机、路径或协议无效。';

  @override
  String get theWindowSetHasTooMany => '窗口组合会话过多。';

  @override
  String get invalidWindowSetSplit => '窗口组合分屏无效。';

  @override
  String get invalidWindowSetList => '窗口组合列表无效。';

  @override
  String get invalidWindowSetNameOrSession => '窗口组合名称或会话无效。';

  @override
  String get windowSetIsNestedTooDeeply => '窗口组合层级过深。';

  @override
  String get aHostInThisWindowSet => '窗口组合引用的主机不存在或协议已更改，请删除并重新保存组合。';

  @override
  String get windowSetDataIsTooLarge => '窗口组合数据过大。';

  @override
  String get invalidWindowSetCountOrIdentifier => '窗口组合数量或标识无效。';

  @override
  String get invalidWindowSetFormat => '窗口组合格式无效。';

  @override
  String get invalidWindowSetNode => '窗口组合节点无效。';

  @override
  String get invalidWindowSetPaneReference => '窗口组合面板引用无效。';

  @override
  String get invalidWindowSetPane => '窗口组合面板无效。';

  @override
  String get hostTags => '主机标签';

  @override
  String get addAUserDirectiveBeforeImporting => '导入此 Host 前请添加 User 指令。';

  @override
  String get commandDirectivesAreNeverExecutedThis =>
      '命令类指令永远不会被执行；此 Host 不会被导入。';

  @override
  String get identityfileIsNotReadOrImported =>
      'IdentityFile 不会被读取或导入。请另行将密钥添加为凭据。';

  @override
  String get identityfileNeedsOneValueThisHost =>
      'IdentityFile 只能有一个值；此 Host 不会被导入。';

  @override
  String get theConfigFileExceedsThe1 => '配置文件超过 1 MiB 的导入上限。';

  @override
  String get theConfigFileHasTooMany => '配置文件行数过多，无法安全检查。';

  @override
  String get thisDirectiveNeedsExactlyOneValue => '此指令只能有一个值。';

  @override
  String get thisValueIsInvalidOrUnsupported => '此值无效或不受支持。';

  @override
  String get atermiusRemoteDesktop => 'Atermius · 远程桌面';

  @override
  String get atermiusTerminal => 'Atermius · 终端';

  @override
  String get atermiusNeedsReliablePersistentBrowserStorage =>
      'Atermius 需要可靠的持久化浏览器存储，确保离线数据和多标签页同步安全。请使用支持 OPFS 或共享 IndexedDB 的浏览器，在普通浏览模式下允许此站点使用本地存储，然后重试。';

  @override
  String get chooseAWorkspace => '选择工作区';

  @override
  String get conflictingWindowRequests => '窗口请求冲突。';

  @override
  String get continueLabel => '继续';

  @override
  String get createOrUnlockAnEncryptedHost =>
      '创建或解锁加密的 Host 与凭据保险库。无需账户、服务器连接或跨设备同步。';

  @override
  String get localProfileStorageIsUnavailableServer =>
      '本地配置存储不可用。若服务器模式的存储后端受支持，仍可使用服务器模式。';

  @override
  String get localOnlyProfile => '仅本地配置';

  @override
  String get openLocally => '在本机打开';

  @override
  String get opening => '正在打开…';

  @override
  String get serverAccountAndSync => '服务器账户与同步';

  @override
  String get serverProfilesSyncEncryptedDataAcross =>
      '服务器配置会在你的设备之间同步加密数据。仅本地配置保留在此浏览器或设备上，不会同步。';

  @override
  String get useYourSelfHostedServerAccount => '使用你的自托管服务器账户和同步的保险库。';

  @override
  String get workspaceSwitchCouldNotBeCompleted => '无法完成工作区切换。';

  @override
  String get theSecurityComponentsOrLocalStorage =>
      '安全组件或本地存储无法启动。请确认部署文件完整，并检查浏览器是否允许此站点使用本地存储，然后重试。';

  @override
  String get workspaceMenu => '工作区菜单';

  @override
  String get workspaceModeSettings => '工作模式设置';

  @override
  String get couldntSaveOrSwitchTheWorkspace => '无法保存或切换工作模式，请检查本机存储后重试。';

  @override
  String get couldntInitializeTheSecureWorkspace => '无法初始化安全工作区';

  @override
  String get couldntOpenTheCloudWorkspaceOr => '无法打开云端工作区或保存工作模式，请检查本机存储后重试。';

  @override
  String get couldntOpenLocalProfileStorageAllow =>
      '无法打开本地配置存储。请允许此站点使用持久存储，然后重试。';

  @override
  String get couldntVerifyTheSeparateWindowTry => '无法验证独立窗口。请从原窗口重试。';

  @override
  String get aLocalStorageWriteWasInterrupted =>
      '本地存储写入中断。请先释放存储空间并关闭此站点的其他 Atermius 标签页，然后重新加载页面恢复后重试。';

  @override
  String get preparingSecureWorkspace => '正在准备安全工作区';

  @override
  String get checkingLocalEncryptedStorage => '正在检查本地加密存储。';

  @override
  String get reloadPage => '重新加载页面';

  @override
  String get retry => '重试';

  @override
  String get supportedBrowserStorageRequired => '需要受支持的浏览器存储';

  @override
  String get supportedBrowserStorageIsRequiredCheck =>
      '需要受支持的浏览器存储。请检查持久存储权限后重试。';

  @override
  String get someFileWindowsArentUnlockedAre =>
      '部分文件窗口尚未解锁、正在切换或位置尚未就绪；请等待后重新保存。';

  @override
  String theRemotePathIsntARegular(String path) {
    return '远端路径不是普通文件：$path';
  }

  @override
  String get scpFileListingRequiresTheSftp =>
      'SCP 文件列表需要此 SSH 连接的 SFTP 目录通道。请检查服务器是否启用 SFTP。';

  @override
  String get theFileActionFailedCheckThe => '文件操作失败，请检查 SSH/SFTP 连接及目录权限。';

  @override
  String get invalidRemoteFolderPath => '远端目录路径无效。';

  @override
  String get theSshSftpSessionIsClosed => 'SSH/SFTP 会话已关闭。';

  @override
  String get onlyRegularFilesCanBeDownloaded => '只能下载普通文件。';

  @override
  String get onlySizeBoundedRegularFilesCan => '只能流式下载大小受限的普通文件。';

  @override
  String get invalidFileNameFormat => '文件名格式无效。';

  @override
  String get theFileExceedsThisPlatformsSftp => '文件超过当前平台的 SFTP 上传大小上限。';

  @override
  String couldntSafelyCreateTheRemoteFile(Object error) {
    return '无法安全创建远端文件。目标可能已存在，或当前用户没有写入权限；现有文件不会被覆盖。($error)';
  }

  @override
  String get invalidFolderNameFormat2 => '目录名格式无效。';

  @override
  String get invalidRemoteFileNameFormat2 => '远端文件名格式无效。';

  @override
  String get theRemoteFileExceedsTheLocal => '远端文件超过本地下载大小上限。';

  @override
  String get theRemoteFileExceedsTheStreaming => '远端文件超过流式下载大小上限。';

  @override
  String get theRemotePathIsntASize => '远端路径不是大小受限的普通文件。';

  @override
  String get theRemotePathIsntARegular2 => '远端路径不是普通文件。';

  @override
  String get theRemotePathIsNoLonger => '远端路径已变为非普通文件。';

  @override
  String get anotherForwardAlreadyUsesThisListener => '另一个转发已使用此监听地址和端口。';

  @override
  String get couldNotStartThisForwardCheck => '无法启动此转发。请检查端口可用性和 SSH 服务器转发策略。';

  @override
  String get forwardStartWasCancelled => '转发启动已取消。';

  @override
  String get sshConnectionClosedWhileForwardingWas => '转发启动期间 SSH 连接已关闭';

  @override
  String get sshPortForwardingIsUnavailableHere => '此处无法使用 SSH 端口转发。';

  @override
  String get sshPortForwardingRuntimeIsUnavailable => '此平台不提供 SSH 端口转发运行时。';

  @override
  String get theSshConnectionForThisForward => '此转发的 SSH 连接已结束。请先重新连接。';

  @override
  String get theForwardProfileIsInvalid => '转发配置无效。';

  @override
  String get theForwardStoppedUnexpectedly => '转发意外停止。';

  @override
  String get thisSshPortForwardProfileIs => '此 SSH 端口转发配置已处于活动状态。';

  @override
  String addressBindaddressIsNotAvailableOn(String bindAddress) {
    return '此设备上不可用地址 $bindAddress。';
  }

  @override
  String connectionLimitSshportforwardmaxconnectionsReachedNewClients(
    int sshPortForwardMaxConnections,
  ) {
    return '已达到连接上限（$sshPortForwardMaxConnections）；在其他连接关闭之前将拒绝新客户端。';
  }

  @override
  String couldNotOpenAnSshChannel(String target) {
    return '无法打开到 $target 的 SSH 通道。';
  }

  @override
  String portEndpointIsAlreadyInUse(String endpoint) {
    return '此设备上的端口 $endpoint 已被占用。';
  }

  @override
  String get theSshConnectionIsNoLonger => 'SSH 连接已不可用。';

  @override
  String theSshServerCouldNotConnect(String target) {
    return 'SSH 服务器无法连接到 $target。';
  }

  @override
  String theSshServerDeniedForwardingTo(String target) {
    return 'SSH 服务器拒绝转发到 $target（被管理策略禁止）。';
  }

  @override
  String get theSshServerDidNotAnswer =>
      'SSH 服务器未及时响应远程转发请求。迟到的监听器将被取消；如果服务器未确认，请断开并重新连接。';

  @override
  String get theSshServerDidNotConfirm => 'SSH 服务器未确认移除远程转发。';

  @override
  String get theSshServerIsOutOf => 'SSH 服务器没有资源打开新通道。';

  @override
  String theSshServerRefusedAChannel(String target) {
    return 'SSH 服务器拒绝了到 $target 的通道。';
  }

  @override
  String get theDeviceSocksListenerStoppedUnexpectedly => '设备 SOCKS 监听器意外停止。';

  @override
  String get theDeviceListenerStoppedUnexpectedly => '设备监听器意外停止。';

  @override
  String thisDeviceCouldNotListenOn(String endpoint) {
    return '此设备无法在 $endpoint 上监听。';
  }

  @override
  String thisDeviceRefusedToListenOn(String endpoint) {
    return '此设备拒绝在 $endpoint 上监听（权限被拒绝；低端口或保留端口范围可能被阻止）。';
  }

  @override
  String timedOutOpeningAnSshChannel(String target) {
    return '打开到 $target 的 SSH 通道超时。';
  }

  @override
  String get thisBrowserBuildCannotOpenTcp =>
      '此浏览器版本无法打开 TCP 监听器或出站套接字，因此无法在此运行 SSH 端口转发。配置仍会为桌面和移动应用同步。';

  @override
  String get theSshRelayOriginDoesntMatch =>
      'SSH 中继来源地址与服务端配置不匹配，请联系管理员检查公开站点地址。';

  @override
  String get theSshRelayTargetMustBe =>
      'SSH 中继目标必须是有效 IP 地址和端口；当前服务端中继不接受 DNS 主机名。';

  @override
  String get theSshRelayTicketExpiredStart => 'SSH 中继票据已失效，请重新发起连接。';

  @override
  String get tooManySshRelayRequestsTry => 'SSH 中继请求过于频繁，请稍后重试。';

  @override
  String get theSshRelayConnectionTimedOut => 'SSH 中继连接超时。请检查服务端可用性、网络和目标地址。';

  @override
  String get theSshHostKeyDiffersFrom =>
      'SSH 主机密钥与已保存指纹不同，连接已拒绝。请通过可信渠道核对新指纹后再更新信任。';

  @override
  String get sshHostKeyVerificationFailedThe =>
      'SSH 主机密钥验证失败，连接已拒绝。请检查服务器身份和连接路径。';

  @override
  String get sshAuthenticatedButTheTerminalSession => 'SSH 已验证身份，但无法打开终端会话。';

  @override
  String get sshHandshakeFailedCheckTheSsh => 'SSH 握手失败。请检查 SSH 服务端和中继连接。';

  @override
  String get theSshPrivateKeyCouldntBe => 'SSH 私钥无法解析或口令不正确。请检查私钥格式和密钥口令。';

  @override
  String get theSshNetworkConnectionWasInterrupted =>
      'SSH 网络连接已中断。请检查中继和目标服务端。';

  @override
  String get sshAuthenticationFailedCheckTheUser => 'SSH 身份验证失败。请检查用户名、密码或私钥。';

  @override
  String get theSshConnectionDroppedBeforeAuthentication =>
      'SSH 连接在身份验证完成前中断。请检查网络和服务端后重试。';

  @override
  String get theUntrustedSshHostKeyWas => '已拒绝尚未信任的 SSH 主机密钥，连接已取消。';

  @override
  String get couldntEstablishTheSshRelayWebsocket =>
      '无法建立 SSH 中继 WebSocket。请检查实例的 HTTPS/WSS 地址、中继来源配置和网络后重试。';

  @override
  String get theServerRelayPolicyRejectedThis =>
      '服务端中继策略拒绝此目标地址或端口。请联系管理员检查 SSH 目标 allowlist。';

  @override
  String get theServerHasntEnabledTheSsh => '服务端尚未启用 SSH 中继，请联系管理员配置中继及目标网段。';

  @override
  String get localStorageNeedsRecoveryReadingEditing2 =>
      '本地存储状态需要恢复。已暂停此数据库的读取、修改和同步；请关闭所有 Atermius 标签页后重新打开，以恢复最后一次持久化的数据。';

  @override
  String get invalidWindowSetPreferenceFormat => '窗口组合偏好格式无效。';

  @override
  String get invalidStagedMigrationCiphertextContext => '暂存的迁移密文上下文无效。';

  @override
  String get invalidStagedMigrationCiphertextFormat => '暂存的迁移密文格式无效。';

  @override
  String get theServerHasntConfirmedAllMigration => '服务端尚未确认所有迁移记录。';

  @override
  String get theMigrationJournalContainsDuplicateOperation => '迁移日志包含重复操作 ID。';

  @override
  String get theMigrationDestinationOutboxDoesntMatch =>
      '迁移目标 outbox 与暂存密文不一致。';

  @override
  String get theMigrationDestinationOutboxDoesntMatch2 =>
      '迁移目标 outbox 与暂存日志不匹配。';

  @override
  String get aStagedRecordInTheMigration => '迁移目标中的暂存记录已被删除。';

  @override
  String get theMigrationDestinationContainsDuplicateRecord => '迁移目标包含重复的记录头。';

  @override
  String get theMigrationDestinationRecordDoesntMatch => '迁移目标记录与暂存密文不一致。';

  @override
  String get theMigrationRecordStillHasUnconfirmed => '迁移记录仍有未确认的 outbox 操作。';

  @override
  String get recycleBinSnapshotExpiredBeforeIt => '回收站快照在读取前已过期。';

  @override
  String get snapshotExpiredBeforeRecoveryCouldStart => '快照在恢复开始前已过期。';

  @override
  String get theServerGenerationChangedSynchronizeBefore => '服务器代次已变化；请先同步再恢复。';

  @override
  String itemExitItem2(Object item, Object item2) {
    return '$item · 退出码 $item2';
  }

  @override
  String get addThisAccountInYourAuthenticator =>
      '在验证器应用中添加此账户，然后输入当前的六位代码。设置密钥是临时的，此客户端永远不会保存它。';

  @override
  String get authenticatorCode => '验证器代码';

  @override
  String get disableMfa => '停用 MFA';

  @override
  String get disableTwoFactorSignIn => '停用双重验证登录';

  @override
  String get disabled => '已停用';

  @override
  String get eachCodeCanBeUsedOnce =>
      '如果无法使用验证器，每个恢复码可使用一次。请将其保存在密码管理器或其他安全位置。完整恢复码仅显示这一次；此客户端不会保存或复制它们。';

  @override
  String get enabled => '已启用';

  @override
  String get enterExactlySixDigits => '请输入六位数字。';

  @override
  String get enterYourCurrentPasswordAndAuthenticator => '请输入当前密码和验证器代码。';

  @override
  String get iSavedTheseCodesSecurely => '我已妥善保存这些恢复码';

  @override
  String get mfaRecoveryCodesWereRotated => 'MFA 恢复码已轮换。';

  @override
  String mfaRecoveryCodesFormattedcodes(String formattedCodes) {
    return 'MFA 恢复码：$formattedCodes';
  }

  @override
  String get newRecoveryCodesWereGeneratedBut =>
      '已生成新的恢复码，但未确认已保存。请再次轮换以显示替代的一组。';

  @override
  String get provisioningUri => '配置 URI';

  @override
  String get refreshMfaStatus => '刷新 MFA 状态';

  @override
  String get rotateMfaRecoveryCodes => '轮换 MFA 恢复码';

  @override
  String get rotateCodes => '轮换恢复码';

  @override
  String get rotateRecoveryCodes => '轮换恢复码';

  @override
  String get saveYourMfaRecoveryCodes => '保存你的 MFA 恢复码';

  @override
  String get setUpAuthenticator => '设置验证器';

  @override
  String get setUpAuthenticatorApp => '设置验证器应用';

  @override
  String setupExpiresTolocal(DateTime toLocal) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '设置将于 $toLocalString 过期。';
  }

  @override
  String get setupSecret => '设置密钥';

  @override
  String totpProvisioningUriProvisioninguri(String provisioningUri) {
    return 'TOTP 配置 URI：$provisioningUri';
  }

  @override
  String totpSetupSecretSecret(String secret) {
    return 'TOTP 设置密钥：$secret';
  }

  @override
  String get theLastRecoveryCodesWereNot => '上一组恢复码未确认已保存。请轮换恢复码以显示新的一组。';

  @override
  String get twoFactorSignIn => '双重验证登录';

  @override
  String get useAnAuthenticatorAppOrA =>
      '使用验证器应用或一次性恢复码作为第二登录因素。服务器以加密方式存储 TOTP 种子；客户端仅在显示所需的时间内保留设置密钥和恢复码。';

  @override
  String get verifyAndEnable => '验证并启用';

  @override
  String get youWillBeAbleToSign => '之后你只需主密码即可登录。你的验证器和未使用的恢复码将失效。';

  @override
  String valuevalueRecoveryCodesRemaining(int valueValue) {
    return '剩余 $valueValue 个恢复码。';
  }

  @override
  String get aHostChangedAfterThePreview => '预览后有主机发生了变化。请重新打开导入器并检查其最新修订版本。';

  @override
  String get aHostWithThisNameWas => '检查期间已保存同名主机。请重新打开导入器进行比较。';

  @override
  String get applyTheseInventoryChanges => '应用这些清单更改？';

  @override
  String applyCountChanges(int count) {
    return '应用 $count 项更改';
  }

  @override
  String applyCountReviewedChangeSTo(int count) {
    return '将 $count 项已检查的更改应用到当前保险库中的加密主机记录。缺失的条目只会被标记为过时，不会删除任何主机。Ansible 分组保存为主机标签。不会导入凭据，也不会执行任何清单或 SSH 命令。';
  }

  @override
  String get chooseInventoryFile => '选择清单文件';

  @override
  String get confirmChanges => '确认更改';

  @override
  String get createANewSource => '创建新来源';

  @override
  String get importAnsibleInventory => '导入 Ansible 清单';

  @override
  String get inventory => '清单';

  @override
  String get inventoryFile => '清单文件';

  @override
  String get inventoryFilesAreLimitedTo1 => '清单文件限制为 1 MiB。';

  @override
  String get inventorySource => '清单来源';

  @override
  String get inventorySourcesAreLimitedTo1 => '清单来源限制为 1 MiB。';

  @override
  String get keepManual => '保留手动编辑';

  @override
  String get markStaleKeepThisHostSaved => '标记为过时；保留此主机';

  @override
  String get noHostsWereImportedTheVault => '未导入任何主机。保险库可能已更改，或某台主机无法保存。';

  @override
  String get noConcreteHostCandidatesWereFound => '未找到具体的主机候选项。';

  @override
  String get pasteOrChooseAStaticIni =>
      '粘贴或选择静态 INI/YAML 清单。动态清单会被拒绝；此导入器绝不会运行脚本、插件、Ansible、SSH 或网络请求。只导入经检查的主机连接字段，凭据和私钥会被忽略。';

  @override
  String get pastedInventory => '粘贴的清单';

  @override
  String get reviewBlockedThisInventoryCannotBe => '检查被阻止：此清单无法导入。';

  @override
  String get reviewEachFieldConflictManualEdits =>
      '请逐一检查字段冲突。默认保留手动编辑。缺失的条目仍会保存，只有在明确选择后才能标记为过时。';

  @override
  String get reviewPastedInventory => '检查粘贴的清单';

  @override
  String get savedInEncryptedHostMetadataFile => '保存在加密的主机元数据中；不会存储文件路径。';

  @override
  String get sourceLabel => '来源标签';

  @override
  String get staticInventoryText => '静态清单文本';

  @override
  String get theActiveVaultChangedOrBecame => '导入期间当前保险库已更改或变为只读。';

  @override
  String get theActiveVaultChangedOrIs => '当前保险库已更改或不可写；导入前请重新检查清单。';

  @override
  String get theInventoryCouldNotBeReviewed => '无法安全检查该清单。';

  @override
  String get theSelectedFileCouldNotBe => '无法读取所选文件。';

  @override
  String get theSelectedFileCouldNotBe2 => '无法检查所选文件。';

  @override
  String get useInventory => '使用清单';

  @override
  String restoreDeadlineFormat2(String format) {
    return ' 恢复截止时间：$format。';
  }

  @override
  String get n0Auto => '0 = 自动';

  @override
  String get n180UnicodeCharactersUniqueWithout =>
      '1–80 个 Unicode 字符；不区分大小写且必须唯一。';

  @override
  String aHostCanHaveAtMost(int maxHostPortForwardProfiles) {
    return '一台主机最多可有 $maxHostPortForwardProfiles 个端口转发配置。';
  }

  @override
  String get aConcurrentChangeWasDetectedYour => '检测到并发更改。你的名称、成员资格和策略草稿已保留。';

  @override
  String get aNewEncryptedRevisionWillBe =>
      '将基于当前远程头部创建新的加密修订版本。在服务器接受解决方案之前，旧分支会继续保留记录。';

  @override
  String get aNewerAtermiusWebBuildIs => '有更新的 Atermius Web 版本可用。';

  @override
  String get aNewerWebBuildIsAvailable => '有更新的 Web 版本可用。适合重新加载时请查看上方提示。';

  @override
  String aPreviousRepairAlreadySelectedRetainedrepairid(
    String retainedRepairId,
  ) {
    return '之前的修复已选择 $retainedRepairId。重试时必须保留该记录，直到同步确认删除标记。';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry(String retainedRecordId) {
    return '之前的修复选择了 $retainedRecordId。重试时必须保留该记录，直到保险库同步确认删除标记。';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry2(
    String retainedRecordId,
  ) {
    return '之前的修复选择了 $retainedRecordId。重试时必须保留此记录，直到保险库同步确认删除标记。';
  }

  @override
  String get aRandomRecoveryCodeEncryptsA =>
      '随机恢复码会加密一个独立的恢复身份。该身份保存保险库纪元密钥的密封副本；你的账户密钥并不是保险库密钥。请将恢复码保存在此设备之外。';

  @override
  String get aSplitWorkspaceNeedsAtLeast => '分屏工作区至少需要两个窗格';

  @override
  String get aUsersEffectiveRelayAccessAlso =>
      '用户的实际 Relay 访问权限还会与其账户策略、所有其他服务器分组以及部署限制取交集。';

  @override
  String get active => '活动';

  @override
  String get apiEndpoint => 'API 端点';

  @override
  String get acceptVaultInvitation => '接受保险库邀请';

  @override
  String get acceptAndUnlockVault => '接受并解锁保险库';

  @override
  String get acceptInvitation => '接受邀请';

  @override
  String get acceptedByAdapter7UtcDays => '适配器已接收（7 个 UTC 日）';

  @override
  String get accessExpires => '访问到期';

  @override
  String get account => '账户';

  @override
  String get accountDevice => '账户与设备';

  @override
  String get accountId => '账户 ID';

  @override
  String get accountRelayPolicy => '账户 Relay 策略';

  @override
  String get accountRelayPolicySaveFailed => '账户 Relay 策略保存失败';

  @override
  String get accountDeletion => '账户删除';

  @override
  String get accountDeletionImmediatelyRevokesAllSessions =>
      '删除账户会立即撤销所有会话和设备。到服务器截止时间时，个人保险库和账户数据会被清除；你在他人保险库中的成员资格和密钥访问会被移除。其他成员的共享保险库数据不会被删除。如果你是仍有其他活动或受邀成员的共享保险库的所有者，必须先处理该成员资格。';

  @override
  String get accountDeletionScheduledByTheServer => '服务器已安排删除账户。';

  @override
  String accountDeletionScheduledServerPurgeAfter(
    Object accountDeletionPurgeAfter,
  ) {
    return '已安排删除账户。服务器 purge_after：$accountDeletionPurgeAfter。';
  }

  @override
  String get accountDevices => '账户设备';

  @override
  String get accountInvitationCreated => '账户邀请已创建';

  @override
  String get accountInvitations => '账户邀请';

  @override
  String get accountRecovery => '账户恢复';

  @override
  String accountRecoveryCodeCode(String code) {
    return '账户恢复码：$code';
  }

  @override
  String get accountRecoveryWasDisabled => '账户恢复已停用。';

  @override
  String accountRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return '账户修订版本 $revision · 更新于 $formatTime';
  }

  @override
  String get accountSessions => '账户会话';

  @override
  String get accounts => '账户';

  @override
  String actionsForFilename(String filename) {
    return '$filename 的操作';
  }

  @override
  String get active2 => '活动';

  @override
  String activePaneValuevalue(int valueValue) {
    return '活动窗格 $valueValue';
  }

  @override
  String get activeAccountOnCurrentPage => '当前页面上的活动账户';

  @override
  String get activeDevices => '活动设备';

  @override
  String get activePane => '活动窗格';

  @override
  String get activeSessions => '活动会话';

  @override
  String get actorDeviceId => '操作设备 ID';

  @override
  String get actorUserId => '操作用户 ID';

  @override
  String get add => '添加';

  @override
  String get addCredentialSecretParameter => '添加凭据机密参数';

  @override
  String get addAHostFirst => '请先添加一台主机。';

  @override
  String get addAPasswordOrPrivateKey => '添加密码或私钥身份，然后将其关联到主机。';

  @override
  String get addCredential2 => '添加凭据';

  @override
  String get addForwardingProfile => '添加转发配置';

  @override
  String get addParameter => '添加参数';

  @override
  String get addProfile => '添加配置';

  @override
  String get addThisValueAsTheBearer =>
      '将此值添加为 /api/v1/admin/metrics 的 Bearer 凭据。它不会存储在此应用中，之后也无法再次获取。';

  @override
  String get addYourFirstHost => '添加你的第一台主机';

  @override
  String get adjustTheSearchOrGroupFilter => '调整搜索或分组筛选以查看更多主机。';

  @override
  String get advanceOnlyAfterEachPageIs => '每页持久化后才前进';

  @override
  String get afterConfirmationThisFingerprintIsSaved =>
      '确认后，此指纹将作为加密记录保存在当前保险库中并同步到其设备。之后如果密钥变化，客户端会拒绝连接。';

  @override
  String algorithmAlgorithm(String algorithm) {
    return '算法：$algorithm';
  }

  @override
  String get allActiveVaultDevicesReportSupport => '所有活动的保险库设备都报告支持脱敏 v1。';

  @override
  String get allowFutureAutomaticPurge => '允许以后自动清除？';

  @override
  String get allowFuturePurge => '允许以后清除';

  @override
  String get allowedCidrNetworks => '允许的 CIDR 网络';

  @override
  String get allowedCidrsOnePerLine => '允许的 CIDR（每行一个）';

  @override
  String get allowedPorts => '允许的端口';

  @override
  String anEncryptedVaultArchiveCoveringPendingcount(int pendingCount) {
    return '最近导出了一个涵盖 $pendingCount 项待处理操作的加密保险库归档。发件箱仍保存在本地，重新加载后会同步。';
  }

  @override
  String get anonymousDiagnostics => '匿名诊断';

  @override
  String get anonymousSyncDiagnosticsExported => '已导出匿名同步诊断信息。';

  @override
  String appliedAppliedInventoryChangeSHost(int applied) {
    return '已应用 $applied 项清单更改；主机记录已加密并排队同步。';
  }

  @override
  String get applyWebUpdate => '应用 Web 更新？';

  @override
  String get approvalJsonCopied => '批准 JSON 已复制。';

  @override
  String get approveSealKeys => '批准并密封密钥';

  @override
  String get approveEnrollment => '批准注册';

  @override
  String approveValuevalue(Object valueValue) {
    return '批准 $valueValue？';
  }

  @override
  String get archiveBytes => '归档字节数';

  @override
  String get archivePassword => '归档密码';

  @override
  String get archiveSaveWasCanceled => '已取消保存归档。';

  @override
  String get argumentsJsonArray2 => '参数（JSON 数组）';

  @override
  String get askTheServerOperatorToConfigure => '启用计划前，请让服务器运营者配置加密备份目标和密钥。';

  @override
  String get atLeast12CharactersIndependentFrom => '至少 12 个字符，与账户密码相互独立。';

  @override
  String get atTheDeadlineTheServerPurges =>
      '到截止时间时，服务器会清除此保险库的记录、历史、冲突、快照、加密对象、成员资格和密钥信封。现有的本地/离线副本和备份是独立的；此操作无法远程擦除它们。';

  @override
  String get atTheServerDeadlineRecordsHistory =>
      '到服务器截止时间时，记录、历史、冲突、快照、加密对象和密钥信封都会被清除。离线副本和保留的备份是独立的，不会被远程擦除。';

  @override
  String get atermiusWillKeepThisPageAnd =>
      '在你完成以下步骤并确认重新加载之前，Atermius 会保持此页面及其 SSH 会话打开。';

  @override
  String get atermiusWillReloadThisPageTo =>
      'Atermius 将重新加载此页面以载入较新的自托管 Web 包。确认前页面不会切换。';

  @override
  String get attemptedAt => '尝试时间';

  @override
  String get auditLog2 => '审计日志';

  @override
  String get automaticPurgeConsentRecordedForThis =>
      '已为此确切删除标记记录自动清除同意。受限的维护任务可能会在恢复截止时间和其他必要检查之后清除它；启用同意不会立即清除。离线设备副本和导出文件不会被移除。';

  @override
  String automaticPurgeConsentValuevalue(String valueValue) {
    return '自动清除同意：$valueValue';
  }

  @override
  String get back => '返回';

  @override
  String get backgroundSyncNotifications => '后台同步通知';

  @override
  String backupBucketAccessCheckResultNotice(String notice) {
    return '备份存储桶访问检查结果：$notice';
  }

  @override
  String get backupCommandFailed => '备份命令失败';

  @override
  String baseRevisionShortauditidCurrentHeadShortauditid2(
    String shortAuditId,
    String shortAuditId2,
  ) {
    return '基线修订版本：$shortAuditId · 当前头部：$shortAuditId2';
  }

  @override
  String get bashNonInteractiveExecution => 'Bash 非交互执行';

  @override
  String get bashNonInteractiveExecutionRequiresA =>
      'Bash 非交互执行 · 需要兼容 POSIX 的登录 Shell 和 Bash';

  @override
  String get bashOnlyEachArgvItemIs =>
      '仅限 Bash。每个 argv 项都是字面值或参数引用，并作为一个 Shell 单词加引号。';

  @override
  String get batchCommandExecution => '批量命令执行';

  @override
  String bindingsAreEncryptedInCurrentvaultnameAnd(String currentVaultName) {
    return '绑定在 $currentVaultName 中加密，并同步到有权访问此保险库的设备。';
  }

  @override
  String get bindingsSyncAsSemanticActionsMod =>
      '快捷键绑定以语义操作同步。“mod”在 Apple 平台上本地解析为 Command，在其他平台上为 Control。快捷键仅在终端输入获得焦点时运行；搜索框保持正常的文本和键盘行为。';

  @override
  String get bothRevisionsStayEncryptedInLocal =>
      '两个修订版本都会加密保留在本地存储中。请选择要基于当前远程头部成为新修订版本的分支。';

  @override
  String branchShortauditid(String shortAuditId) {
    return '分支 $shortAuditId';
  }

  @override
  String get browseFiles2 => '浏览文件';

  @override
  String browseFilesOnValuevalue(String valueValue) {
    return '浏览 $valueValue 上的文件';
  }

  @override
  String get byApprovingThisActiveMemberDevice =>
      '批准后，此活动成员设备会为其可访问的每个保险库和密钥纪元发送密封的密钥信封。请与控制新浏览器的人核实请求和设备身份。';

  @override
  String get conflictConnectionsBlocked => '冲突 — 连接已阻止';

  @override
  String get currentVault => '当前保险库';

  @override
  String get cancelBatch => '取消批处理';

  @override
  String get cancelDeletion => '取消删除';

  @override
  String get cancelExecution => '取消执行';

  @override
  String get cancelScheduledDeletion => '取消计划删除？';

  @override
  String cancelThePendingDeletionForVaultname(
    String vaultName,
    String vaultLifecycleDate,
  ) {
    return '取消 $vaultName 的待处理删除？服务器写入将重新可用，加密发件箱可以继续同步。只有在 $vaultLifecycleDate 之前才能取消。';
  }

  @override
  String get cancellationRequestedTheActiveCommandMay =>
      '已请求取消。活动命令可能已经开始；之后的主机不会运行。';

  @override
  String get cancellationRequestedTheCommandMayAlready =>
      '已请求取消。命令可能已经开始；不会重试。';

  @override
  String get capabilities => '能力';

  @override
  String get changeMasterPassword => '更改主密码';

  @override
  String changeToRole(String role) {
    return '更改为 $role';
  }

  @override
  String changeUsernameFromItemToRole(
    String username,
    Object item,
    String role,
  ) {
    return '将 $username 从 $item 更改为 $role？这会签署新的成员资格版本，并为每台剩余的活动成员设备轮换保险库密钥。待处理的邀请令牌将失效，需要重新签发。旧的密钥副本无法被远程擦除。';
  }

  @override
  String get changingPassword => '正在更改密码…';

  @override
  String get checkBucketAccess => '检查存储桶访问';

  @override
  String get checkForUpdates => '检查更新';

  @override
  String get checkingConfiguredBucketAccessWithHeadbucket =>
      '正在使用 HeadBucket 检查已配置的存储桶访问…';

  @override
  String get checkingOnlineDevices => '正在检查在线设备…';

  @override
  String get checkingThisSelfHostedInstanceFor => '正在检查此自托管实例是否有更新的 Web 版本…';

  @override
  String get choose2575 => '请选择 25–75';

  @override
  String get chooseConnectOnTheLeftTo => '选择左侧的“连接”以开始新会话。';

  @override
  String get chooseAHost => '选择主机';

  @override
  String chooseAHostForPaneValuevalue(int valueValue) {
    return '为窗格 $valueValue 选择主机';
  }

  @override
  String get chooseAHostFromTheActive => '从当前保险库中选择一台主机。替换会作为加密的布局更新保存，不会建立连接。';

  @override
  String get chooseAHostOnTheLeft => '选择左侧的主机以开始 SSH 会话。';

  @override
  String get chooseALocalEncryptedArchiveOr =>
      '选择本地加密归档或其远程副本，在服务保持在线时准备独立副本。远程字节在发布暂存前会根据其摘要和归档认证进行检查。此操作不会激活副本或替换实时数据；之后的离线切换由运营者处理。';

  @override
  String get chooseALocalEncryptedArchiveTo =>
      '选择本地加密归档，在服务保持在线时准备独立副本。发布暂存前会再次检查归档。此操作不会激活副本或替换实时数据；之后的离线切换由运营者处理。';

  @override
  String get chooseANewMasterPasswordDifferent => '请选择一个与当前不同的新主密码。';

  @override
  String get chooseASourceForEachChanged =>
      '为每个已更改的字段选择来源。冲突分支是已验证的落选版本；当前保险库版本是已提交的最新版本。';

  @override
  String get chooseActiveVaultDevicesThatMay =>
      '选择可以观察加密终端输出的活动保险库设备。观察者不能输入或调整主机终端尺寸。此列表在会话期间固定；设备只会收到加入后发送的输出，不会回放之前的滚动内容。';

  @override
  String get chooseConnectedHosts => '选择已连接的主机';

  @override
  String get chooseHowOftenThisServerCreates =>
      '选择此服务器创建加密备份的频率。归档目标和加密密钥在服务器上保持私密。';

  @override
  String get chooseOneDeviceAlreadyApprovedFor =>
      '选择一台已获准访问此共享的设备。它可在最长五分钟内向此 SSH 会话输入；SSH 连接仍保留在此主机设备上。';

  @override
  String get chooseTheDefaultPreferenceRecordTo => '选择要保留的默认偏好记录';

  @override
  String get chooseTheDefaultWorkspaceSectionFor =>
      '为当前保险库选择默认工作区页面。此偏好在同步到有权访问保险库的设备之前会被加密。';

  @override
  String get chooseTheShortcutPreferenceRecordTo => '选择要保留的快捷键偏好记录';

  @override
  String get chooseTheTerminalFontSizeRecord => '选择要保留的终端字号记录';

  @override
  String get chooseTheTerminalPaletteSharedBy =>
      '选择此保险库所有授权设备共享的终端配色。所选配色会作为加密的白名单偏好保存。';

  @override
  String get chooseTheTerminalThemeRecordTo => '选择要保留的终端主题记录';

  @override
  String get cleanupPending => '等待清理';

  @override
  String get clearLocalHistoryOnlyRemovesThis =>
      '“清空本机历史”只会删除此设备上的条目，不会删除已同步到保险库的记录。';

  @override
  String get clearThisHostsLocalHistory => '清空此主机的本机历史';

  @override
  String get closeActiveSshTerminalsBeforeApplying => '应用更新前请关闭活动的 SSH 终端。';

  @override
  String get closeSavedLayoutPreview => '关闭已保存布局的预览';

  @override
  String get color2 => '颜色';

  @override
  String get commaOrLineSeparatedPortNumbers => '以逗号或换行分隔的端口号。';

  @override
  String get commaOrNewlineSeparatedForExample => '以逗号或换行分隔，例如 22, 2222';

  @override
  String get commandHistory => '命令历史';

  @override
  String get commandSnippets => '命令片段';

  @override
  String get commandSuggestions => '命令建议';

  @override
  String get commandsAppearHereAfterTheHook => '粘贴钩子并完成一条命令后，命令会显示在这里。';

  @override
  String get commandsRunOneAtATime => '命令逐个运行。失败、非零退出、超时或未知结果都会停止批处理；不会重试任何命令。';

  @override
  String get compareEachValueAndRecordId =>
      '比较每个值和记录 ID。所选记录 ID 保持生效；其他记录会通过加密删除标记移除。';

  @override
  String get compareThisPublicFingerprintWithAnother =>
      '请通过独立渠道将此公开指纹与另一台设备或可信管理员进行比对，以确认实例身份。';

  @override
  String get comparedWithTheLastVerifiedServer => '与上次验证的服务器元数据比较；离线时此值可能已过时。';

  @override
  String get compatibilityReportNotReported => '兼容性报告 · 未报告';

  @override
  String get compatibilityReportUnverifiedDetailsHidden => '兼容性报告 · 未验证；详情已隐藏';

  @override
  String get completionStatusUnknown => '完成状态未知';

  @override
  String get concurrentLayoutEditsAreKeptAs =>
      '并发的布局编辑会作为独立的加密分支保留。将此设备分支另存为命名副本会保持原冲突未解决；不会连接任何窗格。';

  @override
  String get confirmAndReAuthenticate => '确认并重新认证';

  @override
  String get confirmAndRun => '确认并运行';

  @override
  String confirmAndRunOnCountHosts(int count) {
    return '确认并在 $count 台主机上运行';
  }

  @override
  String get confirmArchivePassword => '确认归档密码';

  @override
  String get confirmNewMasterPassword => '确认新主密码';

  @override
  String get confirmRevokeInvitation => '确认撤销邀请';

  @override
  String confirmTargetName(String name) {
    return '确认目标：$name';
  }

  @override
  String get conflictBranches => '冲突分支';

  @override
  String get conflictResolutionSynced => '冲突解决已同步。';

  @override
  String conflictingSshKeysAreSavedFor(String join) {
    return '$join 保存了相互冲突的 SSH 密钥，连接已被阻止。请撤销所有你不打算信任的密钥；如果两个指纹都未验证，请全部撤销，并仅在通过独立渠道核对后再批准密钥。';
  }

  @override
  String get conflictingBranchesArePreservedUntilYou =>
      '在你选择要保留的版本之前，冲突分支会被保留。';

  @override
  String get connect => '连接';

  @override
  String get connectAnSshHostToBrowse => '连接 SSH 主机以浏览远程文件。';

  @override
  String connectToNameToOpenAn(String name) {
    return '连接到 $name 以打开交互式 Shell。';
  }

  @override
  String get connectionSettingsAreKeptAsOne =>
      '连接设置作为一个整体保存。请检查原始基线和两个已验证分支，然后选择一个完整的整体。其中包括地址、端口、SSH 用户名、认证方式、所选凭据、路由、代理、转发规则和主机信任设置。';

  @override
  String get connections => '连接';

  @override
  String connectionsToEndpointUsingAlgorithmWill(
    String endpoint,
    String algorithm,
  ) {
    return '此签名撤销同步后，各设备上使用 $algorithm 连接 $endpoint 将被阻止。指纹仍保留在历史中。';
  }

  @override
  String get consumed => '已使用';

  @override
  String get continueToFinalConfirmation => '继续进行最终确认';

  @override
  String get continueToReAuthenticate => '继续以重新认证';

  @override
  String get controlActive => '控制已激活';

  @override
  String get copied => '已复制';

  @override
  String get copiedPasteThisCommandIntoThe => '已复制。请将此命令粘贴到终端：';

  @override
  String get copiesWaiting => '等待中的副本';

  @override
  String get copy => '复制';

  @override
  String get copyCode => '复制代码';

  @override
  String get copyCredential => '复制凭据';

  @override
  String get copyFailedSelectTheValueManually => '复制失败；请手动选中该值';

  @override
  String get copyInvitationToken => '复制邀请令牌';

  @override
  String get copySignedShareRequest => '复制已签名的共享请求';

  @override
  String get copyTerminalShareId => '复制终端共享 ID';

  @override
  String get copyThisOneTimeInvitationToken =>
      '复制此一次性邀请令牌并分享给目标账户持有人。关闭此对话框后将不再显示。';

  @override
  String get copyThisResponseToTheNew =>
      '将此响应复制到新浏览器。其中包含公开身份材料和密封的密钥信封，不包含私钥。';

  @override
  String get copyToken => '复制令牌';

  @override
  String get copyingEncryptedArchive => '正在复制加密归档';

  @override
  String get couldNotClearThisHostsLocal => '无法清空此主机的本机历史。';

  @override
  String get couldNotConfirmInputControlRevocation =>
      '无法确认输入控制撤销。主机 SSH 连接仍保持活动。';

  @override
  String get couldNotCopyTheSetupCommand => '无法复制设置命令。未向远程 Shell 发送任何命令。';

  @override
  String get couldNotEnableVaultHistorySync => '无法启用保险库历史同步。请检查当前保险库是否可写后重试。';

  @override
  String get couldNotExportAnonymousSyncDiagnostics => '无法导出匿名同步诊断信息。';

  @override
  String get couldNotGrantInputControlCheck => '无法授予输入控制。请检查会话后重试。';

  @override
  String get couldNotJoinCheckTheSession => '无法加入。请检查会话 ID 和保险库访问权限。';

  @override
  String couldNotLoadTheCurrentHost(String friendlyError) {
    return '无法加载当前主机：$friendlyError';
  }

  @override
  String get couldNotRemoveThisForwardingProfile => '无法移除此转发配置。请检查连接，然后同步并重试。';

  @override
  String get couldNotSaveForwardingSettingsSync => '无法保存转发设置。请同步后重试；当前设置保持不变。';

  @override
  String get couldNotSaveTerminalFontSize => '无法保存终端字号。请检查保险库写入权限后重试。';

  @override
  String get couldNotSaveTerminalShortcutsCheck => '无法保存终端快捷键。请检查保险库写入权限后重试。';

  @override
  String get couldNotSaveTerminalThemeCheck => '无法保存终端主题。请检查保险库写入权限后重试。';

  @override
  String couldNotSaveTheReviewedTuple(String friendlyError) {
    return '无法保存已检查的设置整体：$friendlyError';
  }

  @override
  String get couldNotSaveThisGroupYour => '无法保存此分组。你的更改仍保留在表单中；请检查保险库访问权限后重试。';

  @override
  String get couldNotSaveThisPreferenceCheck => '无法保存此偏好。请检查保险库写入权限后重试。';

  @override
  String get couldNotStartOrStopThis => '无法启动或停止此转发。请检查端口可用性和 SSH 服务器转发策略。';

  @override
  String get couldNotStartTerminalSharingCheck => '无法启动终端共享。请检查保险库和网络后重试。';

  @override
  String get couldNotTurnOffVaultHistory => '无法关闭保险库历史同步。请重试。';

  @override
  String get create2 => '创建';

  @override
  String get createVault => '创建保险库';

  @override
  String get createADedicatedReadOnlyBearer =>
      '为 GET /api/v1/admin/metrics 创建专用的只读 Bearer 凭据。机密只显示一次，此应用永远不会保存它。';

  @override
  String get createAGroupToOrganizeRelated => '创建分组来整理相关服务器。';

  @override
  String get createAnotherVault => '创建另一个保险库';

  @override
  String get createCredential => '创建凭据';

  @override
  String get createEncryptedVault => '创建加密保险库';

  @override
  String get createGroup => '创建分组';

  @override
  String get createInvitation => '创建邀请';

  @override
  String get createRemoteFolder => '创建远程文件夹';

  @override
  String get createResolution => '创建解决方案';

  @override
  String get createSnippet => '创建片段';

  @override
  String get createSplitWorkspace => '创建分屏工作区';

  @override
  String get createUsernameBoundInvitationsAndReview => '创建绑定用户名的邀请并查看其状态。';

  @override
  String get createYourFirstGroup => '创建第一个分组';

  @override
  String get createYourFirstHostAndAttach =>
      '创建你的第一台主机，并附加一个客户端加密的 SSH 凭据。这里没有任何示例或演示数据。';

  @override
  String get created => '创建时间';

  @override
  String get createdAt => '创建时间';

  @override
  String createdFormattimeUpdatedFormattime2(
    String formatTime,
    String formatTime2,
  ) {
    return '创建于 $formatTime · 更新于 $formatTime2';
  }

  @override
  String createdFormat(String format) {
    return '创建于 · $format';
  }

  @override
  String get createsAV2RoomInputStays =>
      '创建 v2 房间。在你向某台已批准设备授予最长五分钟的租约之前，输入保持关闭。';

  @override
  String get credential => '凭据';

  @override
  String credentialActionsName(String name) {
    return '凭据操作：$name';
  }

  @override
  String get credentialMergeSavedAndSyncing => '凭据合并已保存并正在同步';

  @override
  String get credentialName2 => '凭据名称';

  @override
  String credentialReferenceNameMustPointTo(String name) {
    return '凭据引用 $name 必须指向密码凭据';
  }

  @override
  String credentialReferenceNameWasNotFound(String name) {
    return '在此保险库中未找到凭据引用 $name';
  }

  @override
  String get credentialSelectionProxySettingsForwardingDetails =>
      '凭据选择、代理设置、转发详情和主机信任材料已被遮蔽，它们会从所选分支保留。';

  @override
  String get credentialStatus => '凭据状态';

  @override
  String get credentialValuesAreSentOnlyThrough =>
      '凭据值只通过加密的 SSH exec 通道发送。远程程序以参数形式接收它们，可能会暴露给以同一远程用户运行的进程。';

  @override
  String credentialNameUsernameValuevalue(
    String name,
    String username,
    String valueValue,
  ) {
    return '凭据：$name；$username；$valueValue';
  }

  @override
  String get currentVault2 => '当前保险库';

  @override
  String get currentAccount => '当前账户';

  @override
  String currentAccountValuevalue(String valueValue) {
    return '当前账户：$valueValue';
  }

  @override
  String get currentDevice => '当前设备';

  @override
  String currentHeadShortauditid(String shortAuditId) {
    return '当前头部：$shortAuditId';
  }

  @override
  String get currentMasterPassword => '当前主密码';

  @override
  String get currentSignedInAccountAdministrativeActions => '当前登录账户 · 管理操作已隐藏';

  @override
  String get cursorPolicy => '游标策略';

  @override
  String get deletionScheduled => '已安排删除';

  @override
  String get deadLettered => '已进入死信队列';

  @override
  String get defaultLabel2 => '默认';

  @override
  String get defaultSshCredential => '默认 SSH 凭据';

  @override
  String defaultSectionSectionlabelRecordIdId(
    String sectionLabel,
    String id,
    String revisionLabel,
  ) {
    return '默认页面：$sectionLabel；记录 ID：$id；修订版本：$revisionLabel';
  }

  @override
  String get defaultWorkspaceSection => '默认工作区页面';

  @override
  String defaultDefaultvalue(Object defaultValue) {
    return '默认值：$defaultValue';
  }

  @override
  String get delete2 => '删除';

  @override
  String get deleteForwardingProfile => '删除转发配置';

  @override
  String get deleteGroup3 => '删除分组';

  @override
  String get deleteGroup4 => '删除分组？';

  @override
  String get deleteServerManagedGroup => '删除服务器管理的分组';

  @override
  String get deleteServerManagedGroup2 => '删除服务器管理的分组？';

  @override
  String get deleteThisItem => '删除此项？';

  @override
  String get deletingAccountAdministrativeActionsUnavailable =>
      '正在删除账户 · 管理操作不可用';

  @override
  String get deletingThisVaultStartsTheServer =>
      '删除此保险库会启动服务器配置的宽限期。成员立即变为只读；确切的清除截止时间由服务器返回。';

  @override
  String get deletionCanceledPendingEncryptedSyncCan => '已取消删除；待处理的加密同步可以继续。';

  @override
  String get deletionRequested => '已请求删除';

  @override
  String get deletionScheduledByTheServer => '服务器已安排删除。';

  @override
  String deletionScheduledServerPurgeAfterVaultlifecycledate(
    String vaultLifecycleDate,
  ) {
    return '已安排删除。服务器将在 $vaultLifecycleDate 后清除。';
  }

  @override
  String get deliveryHistoryIsUnavailableOnThis => '此服务器不提供投递历史。';

  @override
  String get deliveryWindowUtc => '投递时段（UTC）';

  @override
  String get deploymentCidrLimits => '部署 CIDR 限制';

  @override
  String get deploymentPortLimits => '部署端口限制';

  @override
  String get deploymentRelayAvailability => '部署的中继可用性';

  @override
  String get destinationOnSshTarget => 'SSH 目标上的目标';

  @override
  String get destinationOnThisDevice => '此设备上的目标';

  @override
  String get deviceId => '设备 ID';

  @override
  String get deviceSocksListenerAddress => '设备 SOCKS 监听地址';

  @override
  String get deviceAccessRevoked => '设备访问已撤销';

  @override
  String get deviceApproved => '设备已批准';

  @override
  String get deviceCapabilitySignerIsInvalid => '设备能力签名者无效。';

  @override
  String get deviceCompatibilityReportIsInvalid => '设备兼容性报告无效。';

  @override
  String get deviceListenerAddress => '设备监听地址';

  @override
  String get deviceRevoked3 => '设备已撤销';

  @override
  String deviceSubstring(String substring) {
    return '设备 $substring';
  }

  @override
  String get devicesActive => '活动设备';

  @override
  String get diagnosticsExportCancelled => '已取消导出诊断信息。';

  @override
  String get direction => '方向';

  @override
  String get directory => '目录';

  @override
  String get directoryIsEmpty => '目录为空';

  @override
  String get disableAccount => '停用账户';

  @override
  String get disableAccountRecovery2 => '停用账户恢复';

  @override
  String get disableAccountRecovery => '停用账户恢复？';

  @override
  String get disableAccount2 => '停用账户？';

  @override
  String get disableOrReEnableAccountsAnd => '停用或重新启用账户，并撤销其活动会话。';

  @override
  String get disableRecovery => '停用恢复';

  @override
  String disableUsernameServerSessionsWillBe(String username) {
    return '停用 $username？服务器会话将被撤销，且无法再次登录。缓存的设备数据不会被擦除，现有的直连 SSH 连接可能会持续到其 SSH 服务器关闭为止。';
  }

  @override
  String get disabledByPolicy => '已被策略禁用';

  @override
  String get discardIsolatedCopy => '丢弃隔离副本';

  @override
  String get discardIsolatedRestoreCopy => '丢弃隔离的恢复副本？';

  @override
  String get discarded => '已丢弃';

  @override
  String get disconnect2 => '断开连接';

  @override
  String get disconnected2 => '已断开';

  @override
  String get disconnectedRecursivePreview => '已断开的递归预览';

  @override
  String get disconnectedConnectTabsExplicitly => '未连接 · 请逐个连接标签页';

  @override
  String disconnectedDirectionlabelFirstpercentSecondpercentPanecountPanes(
    String directionLabel,
    int firstPercent,
    int secondPercent,
    int paneCount,
  ) {
    return '未连接 · $directionLabel · $firstPercent/$secondPercent · $paneCount 个窗格 · 请逐个连接窗格';
  }

  @override
  String get done2 => '完成';

  @override
  String get download2 => '下载';

  @override
  String get due => '到期';

  @override
  String get duplicate => '复制';

  @override
  String get duplicateWorkspace => '复制工作区';

  @override
  String get dynamicSocks5 => '动态 SOCKS5';

  @override
  String dynamicSocks5Bind(String bind) {
    return '动态 SOCKS5 · $bind';
  }

  @override
  String get dynamicForwardingIsALoopbackOnly =>
      '动态转发是仅限回环地址、无 SOCKS 认证的 SOCKS5 CONNECT 代理。请仅在受信任的设备上使用。';

  @override
  String get eachDeviceKeepsItsPrivateSigning =>
      '每台设备都在本地保存其私有签名和加密密钥。批准只会发送不透明的密封信封，其中包含此设备可访问的每个保险库密钥纪元。切勿批准你未发起的注册。';

  @override
  String get eachSelectedHostReceivesReferencedCredential =>
      '每台所选主机都会通过其加密的 SSH exec 通道接收引用的凭据机密。远程程序以参数形式接收它们，可能会暴露给以同一远程用户运行的进程。';

  @override
  String get edit2 => '编辑';

  @override
  String get editVaultQuota => '编辑保险库配额';

  @override
  String get editCommandSnippet => '编辑命令片段';

  @override
  String get editCredential2 => '编辑凭据';

  @override
  String get editForwardingProfile => '编辑转发配置';

  @override
  String get editGroup2 => '编辑分组';

  @override
  String get editHostGroup => '编辑主机分组';

  @override
  String get editQuota => '编辑配额';

  @override
  String get editText2 => '编辑文本';

  @override
  String editableCeilingValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '可编辑上限：$valueValue · CIDR：$summarize · 端口：$summarize2';
  }

  @override
  String get editorCanEditVaultRecords => '编辑者 · 可以编辑保险库记录';

  @override
  String get effectiveSshRelayService => '实际 SSH 中继服务';

  @override
  String effectiveGroupStateValuevalueCidrsSummarize(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '分组实际状态：$valueValue · CIDR：$summarize · 端口：$summarize2';
  }

  @override
  String effectiveStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '实际状态：$valueValue · CIDR：$summarize · 端口：$summarize2';
  }

  @override
  String get enableBashCommandHistory => '启用 Bash 命令历史';

  @override
  String get enableBashIntegration => '启用 Bash 集成';

  @override
  String get enableRelayForThisAccount => '为此账户启用 Relay';

  @override
  String get enableRelayForThisGroup => '为此分组启用 Relay';

  @override
  String get enableSshRelay => '启用 SSH 中继';

  @override
  String get enableVaultSync => '启用保险库同步';

  @override
  String get enableAndCopy => '启用并复制';

  @override
  String get enableHostApprovedInputControl => '启用由主机批准的输入控制';

  @override
  String get enableScheduledBackups => '启用计划备份';

  @override
  String get enabledForThisDeviceTheServer => '已为此设备启用。服务器只发送通用的同步提示。';

  @override
  String get enablingSyncUploadsUpTo500 =>
      '启用同步后，会先上传当前保险库中主机的最多 500 条现有本地命令，之后上传新的命令。命令使用当前保险库密钥加密，任何有访问权限的保险库成员都能读取。关闭同步会取消尚未发送的排队命令；已发送或已提交的命令仍可能到达并保留在保险库中。';

  @override
  String get encryptVaultArchive => '加密保险库归档';

  @override
  String get encryptedVaultArchiveSaved => '加密保险库归档已保存。';

  @override
  String get encryptedArchive => '加密归档';

  @override
  String get encryptedArchiveBytes => '加密归档字节数';

  @override
  String get encryptedBackup => '加密备份';

  @override
  String get encryptedBackupsAreCreatedOnThe =>
      '运营者在实例数据目录之外配置仅所有者可访问的 ATERMIUS_BACKUP_ARCHIVE_DIR 和 ATERMIUS_BACKUP_KEY_FILE 路径后，服务器才会创建加密备份。此客户端不会发送任何归档或密钥路径。';

  @override
  String encryptedObjectBlocksCount(int count) {
    return '加密对象块：$count';
  }

  @override
  String get encryptedRecordsImmutableRetriesAndRecovery =>
      '此保险库的加密记录、不可变重试和恢复检查点。';

  @override
  String get encryptedWithTheActiveVaultKey =>
      '使用当前保险库密钥加密。有访问权限的成员可以读取。关闭同步会取消未发送的排队命令；已发送或已提交的命令仍可能到达并保留在保险库中。';

  @override
  String get encryptionKeyFingerprint => '加密密钥指纹';

  @override
  String get encryptionKeyFingerprintSha256 => '加密密钥指纹 · SHA-256';

  @override
  String get enrollmentJson => '注册 JSON';

  @override
  String get enrollmentJsonIsNotValid => '注册 JSON 无效。';

  @override
  String get enterAWorkspaceName => '请输入工作区名称';

  @override
  String get enterAQuotaFrom1Byte => '请输入 1 字节到 1 TiB 之间的配额。';

  @override
  String get enterASupportedNonReservedChord =>
      '输入受支持且未被保留的组合键，例如 mod+alt+shift+f。每个组合键都必须有效且唯一。';

  @override
  String get enterAWholeNumberFrom1 => '请输入 1 到 720 之间的整数。';

  @override
  String get enterAWholeNumberPercent => '请输入整数百分比';

  @override
  String get enterRequiredValuesToPreview => '输入必填值以预览。';

  @override
  String get enterTheCurrentMasterPasswordAt => '请输入当前主密码（至少 12 个字符）。';

  @override
  String get enterTheSessionUuidProvidedBy =>
      '输入主机提供的会话 UUID。这会打开一个独立的只读终端，不会建立 SSH 连接。';

  @override
  String epochKeyVersionsCount(int count) {
    return '纪元密钥版本：$count';
  }

  @override
  String get eventId => '事件 ID';

  @override
  String get everyActiveVaultDeviceMustSupport =>
      '必须所有活动保险库设备都支持脱敏 v1，才能清除此记录。请升级或停用不支持的设备后重试。';

  @override
  String get everyRoleChangeAndRevocationCommits =>
      '每次角色变更和撤销都会提交一个带新密钥纪元的签名成员资格更新。所有者和所有保留的活动成员设备都会收到新密钥。';

  @override
  String get executionMode => '执行模式';

  @override
  String get executionPreview => '执行预览';

  @override
  String existingShellLabelShell2(String shell) {
    return '现有 Shell 标签：$shell';
  }

  @override
  String exitCodeExitcode(Object exitCode) {
    return '退出码：$exitCode';
  }

  @override
  String exitExitstatusCompletedat(int exitStatus, String completedAt) {
    return '退出码 $exitStatus · $completedAt';
  }

  @override
  String get expectedAJsonArray => '应为 JSON 数组';

  @override
  String get expired => '已过期';

  @override
  String get expires => '到期时间';

  @override
  String get exportArchive => '导出归档';

  @override
  String get exportDiagnostics => '导出诊断信息';

  @override
  String get exportTheFixedServerHistoryCurrent =>
      '导出固定的服务器历史、当前删除标记、本地发件箱/冲突分支和加密对象块。单独的归档密码会使用 Argon2id 和 XChaCha20-Poly1305 保护文件。';

  @override
  String get failed2 => '失败';

  @override
  String get failureCategory => '失败类别';

  @override
  String get favorite => '收藏';

  @override
  String get file => '文件';

  @override
  String get filterCommands => '筛选命令';

  @override
  String get fingerprintsApprovedDuringSshConnectionAre =>
      'SSH 连接期间批准的指纹会在此保险库中加密，并同步到其设备。撤销同样会被加密，并保留可见的批准历史。旧的仅设备固定记录不会作为保险库信任导入。';

  @override
  String get finish => '完成';

  @override
  String get finishedAt => '完成时间';

  @override
  String get firstChild => '第一个子项（%）';

  @override
  String get focus => '聚焦';

  @override
  String get folderName => '文件夹名称';

  @override
  String get forExample104000 => '例如：10.40.0.0/16';

  @override
  String get forwardType => '转发类型';

  @override
  String get freeFormScriptLegacy => '自由格式脚本（旧版）';

  @override
  String get futureAutomaticPurgeConsentWithdrawn => '已撤回将来的自动清除同意。';

  @override
  String get generatedAt => '生成时间';

  @override
  String get generation => '代次';

  @override
  String get generationCheckpoint => '代次检查点';

  @override
  String get generationMatches => '代次一致';

  @override
  String get generationMismatch => '代次不一致';

  @override
  String get go => '转到';

  @override
  String get goToPath => '转到路径';

  @override
  String get goToRemotePath => '转到远程路径';

  @override
  String get grantFor5Minutes => '授予 5 分钟';

  @override
  String get grantInputControl => '授予输入控制';

  @override
  String get groupRelayPolicy => '分组 Relay 策略';

  @override
  String groupActionsName2(String name) {
    return '分组操作：$name';
  }

  @override
  String get groupName3 => '分组名称';

  @override
  String groupRevisionRevisionMembershipRevisionMembershiprevision(
    int revision,
    int membershipRevision,
    int revision2,
  ) {
    return '分组修订版本 $revision · 成员资格修订版本 $membershipRevision · 策略修订版本 $revision2';
  }

  @override
  String groupGroupname(Object groupName) {
    return '分组：$groupName';
  }

  @override
  String headShortauditid(String shortAuditId) {
    return '头部 $shortAuditId';
  }

  @override
  String get hideRelayPolicy => '隐藏 Relay 策略';

  @override
  String get hidePasswordSecret => '隐藏密码机密';

  @override
  String get hideSessions => '隐藏会话';

  @override
  String get host => '主机';

  @override
  String get hostConnectionSettingsReviewedAndQueued => '主机连接设置已检查并排队同步。';

  @override
  String get hostGroups => '主机分组';

  @override
  String get hostIsNoLongerAvailableSync => '主机已不可用；请同步后重试。';

  @override
  String get hostUnavailable => '主机不可用';

  @override
  String hostPaneValuevalue(int valueValue) {
    return '主机 · 窗格 $valueValue';
  }

  @override
  String get hostApprovedTerminalInput => '由主机批准的终端输入';

  @override
  String hostNameUsernameEndpointValuevalue(
    String name,
    String username,
    String endpoint,
    String valueValue,
  ) {
    return '主机：$name；$username@$endpoint$valueValue';
  }

  @override
  String get hostsWithoutAnOverrideInheritThe => '未设置覆盖值的主机会继承最近分组的默认值。';

  @override
  String get iStoredThisCodeSecurely => '我已妥善保存此代码';

  @override
  String get iUnderstandBoundedMaintenanceMayPurge =>
      '我了解受限的维护任务可能会在恢复截止时间和必要检查之后清除此删除标记。';

  @override
  String get iUnderstandThisPermanentlyRemovesThe => '我了解这会将该记录从服务器的活动状态中永久移除。';

  @override
  String get iveSavedIt => '我已保存';

  @override
  String get idle => '空闲';

  @override
  String get ifCopyingIsUnavailableSelectThe => '如果无法复制，请选中上面的值。';

  @override
  String get ifYouOwnASharedVault =>
      '如果你拥有一个仍有其他活动或受邀成员的共享保险库，服务器会拒绝删除；所有权不会被转移。在宽限期内，你可以在登录页面使用账户名和主密码取消，然后重新登录。继续前请先保存加密归档。';

  @override
  String get importSshConfig => '导入 SSH 配置';

  @override
  String get importArchive => '导入归档';

  @override
  String get importToThisVault => '导入到此保险库';

  @override
  String get importVerifiedVaultArchive => '导入已验证的保险库归档？';

  @override
  String importedImportedHostSRecordsAre(int imported) {
    return '已导入 $imported 台主机；记录已加密并排队同步。';
  }

  @override
  String get includesTheInstanceAccountAndEvery => '包括实例、账户以及所有已分配的服务器分组。';

  @override
  String get inputControlOff => '输入控制：关闭';

  @override
  String get inputControlRevoking => '输入控制：正在撤销';

  @override
  String inputControlControllerlabel(Object controllerLabel) {
    return '输入控制：$controllerLabel';
  }

  @override
  String get inputIsEncryptedToTheHost =>
      '输入会加密发送给主机，并随主机批准的租约到期。调整尺寸仍被禁用；只提供实时输出。';

  @override
  String get installationWideEventsSeparateFromAccount =>
      '安装范围的事件，独立于账户和保险库审计页面。';

  @override
  String get instance => '实例';

  @override
  String get instanceId => '实例 ID';

  @override
  String get instanceVaultQuotas => '实例保险库配额';

  @override
  String get instanceAccountsAndSessions => '实例账户与会话';

  @override
  String get instanceAdminAudit => '实例管理员审计';

  @override
  String get instanceAdminOverview => '实例管理概览';

  @override
  String get instanceBackupStatus => '实例备份状态';

  @override
  String get instanceJobs => '实例任务';

  @override
  String instanceRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return '实例修订版本 $revision · 更新于 $formatTime';
  }

  @override
  String get instanceSigningKeyFingerprintSha256 => '实例签名密钥指纹 · SHA-256';

  @override
  String get instanceWideBootstrapAndNetworkPolicy =>
      '实例范围的引导和网络策略由自托管服务器运营者管理。';

  @override
  String get interrupted => '已中断';

  @override
  String get interruptedRetryPending => '已中断 · 等待重试';

  @override
  String get intervalInHours => '间隔（小时）';

  @override
  String get invalidFontSizeValue => '字号值无效';

  @override
  String get invalidToken7UtcDays => '无效令牌（7 个 UTC 日）';

  @override
  String get inventoryEntryStale => '清单条目已过时';

  @override
  String get invitationCreated => '邀请已创建';

  @override
  String get invitationExpired => '邀请已过期';

  @override
  String get invitationExpiresInDays => '邀请有效天数';

  @override
  String invitationExpiresFormattedexpiry(String formattedExpiry) {
    return '邀请将于 $formattedExpiry 到期';
  }

  @override
  String get invitationNeedsReissue => '邀请需要重新签发';

  @override
  String get invitationPending => '邀请待接受';

  @override
  String get invitationToken => '邀请令牌';

  @override
  String get invitationTokenCopied => '邀请令牌已复制。';

  @override
  String get invitationUsername => '邀请用户名';

  @override
  String get inviteMember => '邀请成员';

  @override
  String inviteToCurrentvaultname(String currentVaultName) {
    return '邀请加入 $currentVaultName';
  }

  @override
  String get issueAccountInvitation => '签发账户邀请';

  @override
  String get issueCategory => '问题类别';

  @override
  String get join => '加入';

  @override
  String get joinASharedTerminal => '加入共享终端';

  @override
  String get joinHostGrantedControl => '加入主机授予的控制';

  @override
  String get keepVault => '保留保险库';

  @override
  String get keepAccess => '保留访问权限';

  @override
  String get keepAccount => '保留账户';

  @override
  String get keepCurrentOwner => '保留当前所有者';

  @override
  String get keepRepeatableCommandsInTheSame => '将可重复使用的命令与主机保存在同一个加密保险库中。';

  @override
  String get keepScheduledDeletion => '保留计划删除';

  @override
  String get keepSelectedBindingsAndRemoveDuplicates => '保留所选绑定并移除重复项';

  @override
  String get keepSelectedFontSizeAndRemove => '保留所选字号并移除重复项';

  @override
  String get keepSelectedRecordAndRemoveDuplicates => '保留所选记录并移除重复项';

  @override
  String get keepSelectedThemeAndRemoveDuplicates => '保留所选主题并移除重复项';

  @override
  String get keepThisDeviceVersion => '保留此设备上的版本';

  @override
  String get keepThisDeviceVersion2 => '保留此设备版本？';

  @override
  String get keyPassphraseOptional => '密钥口令（可选）';

  @override
  String get keyUpdateNeeded => '需要更新密钥';

  @override
  String get knownHost => '已知主机';

  @override
  String get lastChanged => '上次更改';

  @override
  String get lastPull => '上次拉取';

  @override
  String get lastRun => '上次运行';

  @override
  String get lastRunStatus => '上次运行状态';

  @override
  String get lastSuccessfulSync => '上次成功同步';

  @override
  String get lastUpdated => '上次更新';

  @override
  String lastVerifiedServerShortkey(String shortKey) {
    return '上次验证的服务器：$shortKey';
  }

  @override
  String get latestCopy => '最新副本';

  @override
  String get leased => '已租用';

  @override
  String get leaveSharedTerminal => '离开共享终端';

  @override
  String get loadRelayPolicies => '加载 Relay 策略';

  @override
  String get loadVaults => '加载保险库';

  @override
  String get loadAccountInvitations => '加载账户邀请';

  @override
  String get loadAccountsToAddMembers => '加载账户以添加成员';

  @override
  String get loadAdminAccounts => '加载管理账户';

  @override
  String get loadAdminAudit => '加载管理审计';

  @override
  String get loadBackupSchedule => '加载备份计划';

  @override
  String get loadBackupStatus => '加载备份状态';

  @override
  String get loadInstanceJobs => '加载实例任务';

  @override
  String get loadOverview => '加载概览';

  @override
  String get loadPushHealth => '加载推送健康状况';

  @override
  String get loadRelayPolicy => '加载中继策略';

  @override
  String get loadReplicationStatus => '加载复制状态';

  @override
  String get loadRestoreSources => '加载恢复来源';

  @override
  String get loadServerManagedGroups => '加载服务器管理的分组';

  @override
  String get loadStatus => '加载状态';

  @override
  String get loadingSshRelayPolicy => '正在加载 SSH 中继策略…';

  @override
  String get loadingAccountAndInstancePolicyRevisions => '正在加载账户和实例策略修订版本…';

  @override
  String get loadingAccountInvitations => '正在加载账户邀请…';

  @override
  String get loadingAccountSessions => '正在加载账户会话…';

  @override
  String get loadingBackupSchedule => '正在加载备份计划…';

  @override
  String get loadingEncryptedArchiveSources => '正在加载加密归档来源…';

  @override
  String get loadingGroupMembershipAndRelayPolicy => '正在加载分组成员资格和 Relay 策略…';

  @override
  String get loadingServerManagedGroups => '正在加载服务器管理的分组…';

  @override
  String get local => '本地';

  @override
  String get localArchive => '本地归档';

  @override
  String get localDevice => '本机设备';

  @override
  String get localEditsAreEncryptedAndCommitted =>
      '本地编辑在任何网络请求之前就会被加密并提交到持久化发件箱。重试会复用相同的操作 ID 和密文。服务器永远不会收到凭据或保险库密钥。';

  @override
  String get localEncryptedArchiveUnavailable => '本地加密归档不可用';

  @override
  String localRevisionItem(Object item) {
    return '本地修订版本  $item';
  }

  @override
  String localBindDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return '本地 · $bind → $destinationAddress:$destinationPort';
  }

  @override
  String get localOnlyProfiles => '仅本地配置';

  @override
  String get lockWorkspace => '锁定工作区';

  @override
  String get loopbackOnly => '仅回环地址';

  @override
  String get maintenance => '维护';

  @override
  String get maintenanceRunsTheConfiguredRetentionAnd =>
      '维护会执行已配置的保留期和过期对象清理。服务器会报告可用的实例操作。';

  @override
  String get makeEditor => '设为编辑者';

  @override
  String get makeViewer => '设为查看者';

  @override
  String makeUsernameTheSoleOwnerYour(String username) {
    return '将 $username 设为唯一所有者。你的账户将保持为活动编辑者。此操作会签署新的成员资格版本，并在一次原子更新中为每台活动成员设备轮换保险库密钥。待处理的邀请令牌将失效，需要重新签发。新所有者将能够管理成员并删除保险库。';
  }

  @override
  String get manageVaultMembers => '管理保险库成员';

  @override
  String get masterPasswordIsUsedOnlyFor => '主密码仅用于客户端密钥派生。';

  @override
  String get maxSshRelayConnectionsPerUser => '每个用户的最大 SSH 中继连接数';

  @override
  String get maxRelayConnectionsPerUser => '每个用户的最大中继连接数';

  @override
  String memberEffectiveRelayAccessValuevalueCidrs(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '成员实际 Relay 访问：$valueValue · CIDR：$summarize · 端口：$summarize2';
  }

  @override
  String get members => '成员';

  @override
  String membersCurrentvaultname(String currentVaultName) {
    return '成员 · $currentVaultName';
  }

  @override
  String get mergePasswordFields => '合并密码字段';

  @override
  String get migrationVersion => '迁移版本';

  @override
  String get missingHost => '主机缺失';

  @override
  String get moveEncryptedLocalHostsCredentialsGroups =>
      '将加密的本地主机、凭据、分组、片段和受支持的工作区偏好迁移到一个新的空同步保险库。本地配置保持不变；在服务器确认所有暂存记录之前，迁移会暂停本地编辑。';

  @override
  String moveOrUnassignHostcountHostS(
    int hostCount,
    int childCount,
    String name,
  ) {
    return '删除“$name”前，请先移动或取消分配 $hostCount 台主机和 $childCount 个子分组。';
  }

  @override
  String get name2 => '名称';

  @override
  String get needsMoreVaultKeys => '需要更多保险库密钥';

  @override
  String get needsOperatorAttention => '需要运营者处理';

  @override
  String get networkUnavailable => '网络不可用';

  @override
  String get newSshCredential => '新建 SSH 凭据';

  @override
  String get newArchivePassword => '新归档密码';

  @override
  String get newCommandSnippet => '新建命令片段';

  @override
  String get newDevice => '新设备';

  @override
  String get newFirstChild => '新的第一个子项（%）';

  @override
  String get newFolder2 => '新建文件夹';

  @override
  String get newGroup2 => '新建分组';

  @override
  String get newHostGroup => '新建主机分组';

  @override
  String get newMasterPassword => '新主密码';

  @override
  String get newServerGroupName => '新服务器分组名称';

  @override
  String get newSnippet => '新建片段';

  @override
  String get newSplitSideBySide => '新分屏：左右';

  @override
  String get newSplitStacked => '新分屏：上下';

  @override
  String get newTab => '新建标签页';

  @override
  String get next => '下一页';

  @override
  String get nextAccounts => '下一页账户';

  @override
  String get nextInvitations => '下一页邀请';

  @override
  String get nextRun => '下次运行';

  @override
  String get nextSessions => '下一页会话';

  @override
  String get noCliOrServerTriggeredBackup => '尚无 CLI 或服务器触发的备份尝试记录。';

  @override
  String get noVaultIsCurrentlyAvailableTo =>
      '此设备当前没有可用的保险库。接受邀请以恢复访问，或创建一个独立的加密保险库。';

  @override
  String get noVaultsFound => '未找到保险库。';

  @override
  String get noVaultsOnThisPage => '此页没有保险库。';

  @override
  String get noAccessibleVaults => '没有可访问的保险库';

  @override
  String get noAccountInvitationsFound => '未找到账户邀请。';

  @override
  String get noAccountsFound => '未找到账户。';

  @override
  String get noAccountsOnThisPage => '此页没有账户。';

  @override
  String get noActiveSshSession => '没有活动的 SSH 会话';

  @override
  String get noActiveVaultDeviceReportsAre => '没有可用的活动保险库设备报告。';

  @override
  String get noActiveCredential => '没有活动的凭据';

  @override
  String get noCheckpoint => '无检查点';

  @override
  String get noCommandEventsReceivedYetPaste =>
      '尚未收到命令事件。请将复制的设置命令粘贴到交互式 Bash Shell 并按 Enter。';

  @override
  String get noCredentialsSaved => '未保存凭据';

  @override
  String get noDefaultCredential2 => '不设置默认凭据';

  @override
  String get noDeletedRecordsInThisVault => '此保险库中没有已删除的记录。';

  @override
  String get noDeviceListLoaded => '未加载设备列表';

  @override
  String get noDevicesOnline => '没有在线设备';

  @override
  String get noForwardingProfilesSavedForThis => '此主机尚未保存转发配置。';

  @override
  String get noHostGroupsYet => '还没有主机分组';

  @override
  String get noHostKeysHaveBeenApproved => '此保险库中尚未批准任何主机密钥。';

  @override
  String get noHostsSavedYet => '尚未保存主机';

  @override
  String get noInstanceAdminAuditEvents => '没有实例管理员审计事件。';

  @override
  String get noInstanceJobs => '没有实例任务。';

  @override
  String get noInvitationsOnThisPage => '此页没有邀请。';

  @override
  String get noJobs => '没有任务';

  @override
  String get noMatchingHosts2 => '没有匹配的主机';

  @override
  String get noMatchingSingleLineCommands => '没有匹配的单行命令。';

  @override
  String get noMembersWereReturned => '没有返回任何成员。';

  @override
  String get noNewerBundleIsAvailableAt => '此地址尚无更新的包。请更新自托管 Web 资源后再检查。';

  @override
  String get noOpenConflicts => '没有未解决的冲突';

  @override
  String get noOtherActiveVaultDevicesCan => '没有其他活动保险库设备可以接收此终端共享。';

  @override
  String get noPushProviderSnapshotIsAvailable => '没有可用的推送提供方快照。';

  @override
  String get noRemoteCopyAttemptRecordedYet => '尚无远程复制尝试记录。';

  @override
  String get noResult => '无结果';

  @override
  String get noSavedWorkspaces => '没有已保存的工作区';

  @override
  String get noScheduledBackupRunsRecorded => '尚无计划备份运行记录';

  @override
  String get noServerManagedGroupsYet => '还没有服务器管理的分组。';

  @override
  String get noSessionsFound => '未找到会话。';

  @override
  String get noSessionsOnThisPage => '此页没有会话。';

  @override
  String get noSnippetsYet2 => '还没有片段';

  @override
  String get noSupportedEncryptedArchivesAreAvailable => '此页没有受支持的加密归档。';

  @override
  String get noVerifiedCandidateIsAvailableRetry =>
      '没有可用的已验证候选项。请重试保险库同步；格式错误的修复状态仍保持锁定。';

  @override
  String get noVerifiedCandidateIsAvailableRetry2 =>
      '没有可用的已验证候选项。请重试保险库同步；格式错误的修复状态仍保持锁定。';

  @override
  String get noVerifiedCandidateIsAvailableRetry3 =>
      '没有可用的已验证候选项。请重试保险库同步；格式错误的修复状态将保持锁定以便手动恢复。';

  @override
  String get none => '无';

  @override
  String get notConfigured => '未配置';

  @override
  String get notScheduledYet => '尚未安排';

  @override
  String get notStarted => '未开始';

  @override
  String get owner => '所有者';

  @override
  String observerState(String state) {
    return '观察者 $state';
  }

  @override
  String get occurredAt => '发生时间';

  @override
  String get offByDefaultEnablingUploadsUp =>
      '默认关闭。启用后会上传此保险库中主机的最多 500 条现有本地命令以及之后的命令。';

  @override
  String get offSiteEncryptedBackupCopies => '异地加密备份副本';

  @override
  String get offline => '离线';

  @override
  String get offlineDeviceCopiesAndExportsAre => '离线设备副本和导出文件不会被移除。';

  @override
  String get offlineDeviceCopiesAndRetainedBackups => '离线设备副本和保留的备份不会被远程擦除。';

  @override
  String get offlineFirstCiphertextOnly => '离线优先，仅存密文';

  @override
  String get oneCanonicalNetworkCidrPerLine => '每行一个规范网络 CIDR。';

  @override
  String get oneTimePrometheusScrapeCredential => '一次性 Prometheus 抓取凭据';

  @override
  String get oneTimeInvitationToken => '一次性邀请令牌';

  @override
  String get oneTimeToken => '一次性令牌';

  @override
  String onlineDeviceStatusCouldNotBe(Object vaultPresenceError) {
    return '无法加载在线设备状态：$vaultPresenceError';
  }

  @override
  String get onlineStatusUnavailable => '在线状态不可用';

  @override
  String get onlyASignedEnrollmentFromAn =>
      '只有来自活动设备的签名注册才能加入此账户。设备会收到可访问保险库（如有）的密封密钥。';

  @override
  String get onlyAlreadyConnectedSshSessionsAre =>
      '只能使用已连接的 SSH 会话。至少选择两台主机；发送任何命令前都会逐一检查。';

  @override
  String get openSettingsDataAndMigrationTo =>
      'Open Settings → 数据与迁移 to export encrypted archive';

  @override
  String get openTerminal => '打开终端';

  @override
  String get openTerminalChooseAHostAnd => '打开终端，选择主机并连接。SFTP 使用相同的已验证 SSH 传输。';

  @override
  String get openVault => '打开保险库';

  @override
  String get openAVaultToReadOr => '打开保险库以读取或保存同步的偏好。';

  @override
  String get openAVaultToReadOr2 => '打开保险库以读取或保存这些同步偏好。';

  @override
  String get openAVaultToReadOr3 => '打开保险库以读取或保存此同步偏好。';

  @override
  String get openANewTerminalTab => '打开新的终端标签页';

  @override
  String get openActiveTerminals => '打开活动终端';

  @override
  String get openConflicts => '未解决的冲突';

  @override
  String get openTerminal2 => '打开终端';

  @override
  String get optionalBackgroundSyncHintsForThis =>
      '此设备可选的后台同步提示。iOS 在可用时优先使用 APNs。';

  @override
  String get organizeYourHostsIntoGroups => '将你的主机整理到分组中。';

  @override
  String get otherSyncIssue => '其他同步问题';

  @override
  String get outboxItems => '发件箱条目';

  @override
  String get outputIsEncryptedForThisDevice =>
      '输出已为此设备加密。在主机明确向此设备授予控制之前，输入和调整尺寸控件保持禁用。之前的滚动内容不可用。';

  @override
  String get ownerAccountId => '所有者账户 ID';

  @override
  String get ownerUserId => '所有者用户 ID';

  @override
  String get pemPrivateKey => 'PEM 私钥';

  @override
  String get private => '私有';

  @override
  String pageValuevalue(int valueValue) {
    return '第 $valueValue 页';
  }

  @override
  String paneValuevalue(int valueValue) {
    return '窗格 $valueValue';
  }

  @override
  String paneValuevalueValuevalue2(int valueValue, String valueValue2) {
    return '窗格 $valueValue · $valueValue2';
  }

  @override
  String paneValuevalueValuevalue2Valuevalue3(
    int valueValue,
    String valueValue2,
    String valueValue3,
  ) {
    return '窗格 $valueValue · $valueValue2 · $valueValue3';
  }

  @override
  String paneValuevalueValuevalue22(int valueValue, int valueValue2) {
    return '窗格 $valueValue · $valueValue2%';
  }

  @override
  String get parameterDefinitionsJsonArray2 => '参数定义（JSON 数组）';

  @override
  String get parameterName => '参数名称';

  @override
  String get parentGroup2 => '父级分组';

  @override
  String get password => '密码';

  @override
  String get passwordCredential => '密码凭据';

  @override
  String get passwordFieldMergeIsNoLonger => '密码字段合并已不可用。请改用已验证分支的操作。';

  @override
  String get passwordSecret => '密码机密';

  @override
  String get passwordsPrivateKeysAndPassphrasesAre =>
      'Passwords, private keys and passphrases are encrypted on this device before sync. 密钥明文只在解锁会话中使用。';

  @override
  String get pasteThePublicRequestFromThe => '粘贴新浏览器中的公开申请。其中永远不包含私钥。';

  @override
  String get pasteTheRecipientsSignedPublicDevice =>
      '粘贴接收者已签名的公开设备卡。该账户必须已存在于此实例上，且卡片必须与将接受邀请的活动设备匹配。';

  @override
  String get pending => '待处理';

  @override
  String get permanentPurgeAfter => '永久清除时间';

  @override
  String get permanentPurgeBecomesAvailableAfterThis => '此截止时间之后可以永久清除。';

  @override
  String get permanentPurgeIsUnavailableBecauseThis =>
      '由于此服务器未提供恢复截止时间，无法永久清除。';

  @override
  String permanentlyDeleteNameItsMembershipAnd(String name) {
    return '永久删除“$name”及其成员资格和 Relay 策略？其成员未使用的 Relay 票据将被撤销，由此分组授予的活动会话将在策略重新检查后关闭。';
  }

  @override
  String get permanentlyPurge => '永久清除';

  @override
  String get permanentlyPurgeThisRecord => '永久清除此记录？';

  @override
  String get policyRevision => '策略修订版本';

  @override
  String policyRevisionRevisionInstanceRevisionInstancepolicyrevision(
    int revision,
    int instancePolicyRevision,
    String formatTime,
  ) {
    return '策略修订版本 $revision · 实例修订版本 $instancePolicyRevision · 更新于 $formatTime';
  }

  @override
  String get port => '端口';

  @override
  String get portableEncryptedVaultArchive => '便携加密保险库归档';

  @override
  String get preference => '偏好';

  @override
  String get preflightFailedBeforeAnyTargetReceived => '预检在任何目标收到命令前失败。';

  @override
  String get prepareIsolatedCopy => '准备隔离副本';

  @override
  String get prepareIsolatedRestoreCopy => '准备隔离的恢复副本';

  @override
  String get prepareIsolatedRestoreCopy2 => '准备隔离的恢复副本？';

  @override
  String get prepared => '已准备';

  @override
  String get preparingIsolatedCopy => '正在准备隔离副本';

  @override
  String get preparingLocalEncryptedArchive => '正在准备本地加密归档';

  @override
  String get previewDisconnectedLayout => '预览未连接的布局';

  @override
  String get previewMemberEffectiveRelayAccess => '预览成员的实际 Relay 访问权限';

  @override
  String get previewOnly => '仅预览';

  @override
  String get previewStructuredCommandsOrReviewAnd =>
      '预览结构化命令，或在发送到活动终端前检查并确认脚本。';

  @override
  String get previous => '上一页';

  @override
  String get previousAccounts => '上一页账户';

  @override
  String get previousInvitations => '上一页邀请';

  @override
  String get previousSessions => '上一页会话';

  @override
  String get privateKey => '私钥';

  @override
  String get privateSigningAndEncryptionKeysStay => '私有签名和加密密钥保留在此设备的安全存储中。';

  @override
  String get profileName => '配置名称';

  @override
  String get profilesAreEncryptedAndSyncWith =>
      '配置会加密并随保险库同步。此浏览器无法打开运行端口转发所需的本地 TCP 监听器。';

  @override
  String get profilesAreEncryptedInThisHost =>
      '配置会加密保存在此主机中并随保险库同步。运行中的监听器保留在此设备上，并在此 SSH 标签页断开时停止。';

  @override
  String get profilesAreEncryptedInsideThisHost =>
      '配置在此主机记录内加密并随保险库同步。运行状态和套接字永远不会同步。';

  @override
  String get program2 => '程序';

  @override
  String get prometheusRequestsUsingThisCredentialWill =>
      '使用此凭据的 Prometheus 请求将立即停止工作。你之后可以创建替代凭据。';

  @override
  String get prometheusScrapeCredential => 'Prometheus 抓取凭据';

  @override
  String get protocol => '协议';

  @override
  String get protocolVersion => '协议版本';

  @override
  String get providerAdapter => '提供方适配器';

  @override
  String get publicDeviceCard => '公开设备卡';

  @override
  String get publicDeviceCardJson => '公开设备卡 JSON';

  @override
  String get pushIsABestEffortWake => '推送只是尽力而为的唤醒提示，不能证明已送达或已同步。';

  @override
  String get pushProviderHealth => '推送提供方健康状况';

  @override
  String get queuedNotTrusted => '已排队 — 未受信任';

  @override
  String get queueApprovalAndStop => '排队批准并停止';

  @override
  String get queued => '已排队';

  @override
  String get quota => '配额';

  @override
  String get quotaInBytes => '配额（字节）';

  @override
  String get readOnly2 => '只读';

  @override
  String get reissueRequired => '需要重新签发';

  @override
  String get revoked2 => '已撤销';

  @override
  String get reAuthenticateToCancel => '重新认证以取消';

  @override
  String get reEnterAccountMasterPassword => '重新输入账户主密码';

  @override
  String get readOnlyGracePeriodAllMembers =>
      'Read-only grace period · 所有成员可继续读取；写入与成员变更已暂停。可在 Settings 创建独立密码保护的加密归档。';

  @override
  String get readOnlyInstanceIdentityUsageAnd => '只读的实例身份、用量和中继策略。';

  @override
  String get readOnlyProviderConfigurationAggregateQueue =>
      '只读的提供方配置、汇总队列计数和适配器结果。';

  @override
  String get ready => '就绪';

  @override
  String get rebuildSnapshot => '重建快照';

  @override
  String get rebuildingSnapshot => '正在重建快照';

  @override
  String get rebuildingSnapshot2 => '正在重建快照…';

  @override
  String get reconnectObserver => '重新连接观察者';

  @override
  String get record => '记录';

  @override
  String recordIdIdRevisionRevisionlabel(String id, String revisionLabel) {
    return '记录 ID：$id\n修订版本：$revisionLabel';
  }

  @override
  String recordIdIdRevisionValuevalue(String id, String valueValue) {
    return '记录 ID：$id\n修订版本：$valueValue';
  }

  @override
  String get recordConsent => '记录同意';

  @override
  String get recordPermanentlyRemovedFromActiveServer =>
      '记录已从服务器活动状态中永久移除。离线设备副本和保留的备份不会被擦除。';

  @override
  String get recordsAndConflictsRemainEncryptedExisting =>
      '记录和冲突保持加密。现有的本地分支和其他保险库会被保留。不支持跨空间迁移和 ID 重新映射。';

  @override
  String get recordsAreDecryptedOnlyOnThis =>
      '记录只在此设备上解密。如果同一删除标记仍为当前状态，恢复会创建一个新的签名修订版本。';

  @override
  String get recoveryDetails => '恢复详情';

  @override
  String get recoveryInProgress => '正在恢复';

  @override
  String get recoveryIsEnabledButThisCode => '恢复已启用，但此恢复码未确认已保存。请立即轮换以显示新的恢复码。';

  @override
  String recoveryIsStatusCoveredcontextsOfRequiredcontexts(
    String status,
    int coveredContexts,
    int requiredContexts,
  ) {
    return '恢复状态：$status。已覆盖 $requiredContexts 个当前上下文中的 $coveredContexts 个；此设备会在后台重试缺失的密钥。';
  }

  @override
  String get recoveryRequired => '需要恢复';

  @override
  String get recoveryRequiredSyncing => '需要恢复 · 正在同步…';

  @override
  String get recycleBin => '回收站';

  @override
  String recycleBinRecordDisplaynameIdSubstring(
    String displayName,
    String substring,
    String automaticPurgeConsentText,
    String restoreDeadlineSemantics,
  ) {
    return '回收站记录：$displayName，ID $substring，$automaticPurgeConsentText，$restoreDeadlineSemantics';
  }

  @override
  String redactionProofItem(Object item) {
    return '脱敏证明  $item';
  }

  @override
  String get redactionReadiness => '脱敏就绪状态';

  @override
  String get refresh2 => '刷新';

  @override
  String get refreshVaultList => '刷新保险库列表';

  @override
  String get refreshVaultStates => '刷新保险库状态';

  @override
  String get refreshAccountInvitations => '刷新账户邀请';

  @override
  String get refreshAccountSessions => '刷新账户会话';

  @override
  String get refreshAdminAccounts => '刷新管理账户';

  @override
  String get refreshAdminAudit => '刷新管理审计';

  @override
  String get refreshBackupStatus => '刷新备份状态';

  @override
  String get refreshDevices => '刷新设备';

  @override
  String get refreshExpires => '刷新到期';

  @override
  String get refreshInstanceJobs => '刷新实例任务';

  @override
  String get refreshKeyCoverage => '刷新密钥覆盖情况';

  @override
  String get refreshMembersAndOnlineDevices => '刷新成员和在线设备';

  @override
  String get refreshOverview => '刷新概览';

  @override
  String get refreshPushHealth => '刷新推送健康状况';

  @override
  String get refreshReadiness => '刷新就绪状态';

  @override
  String get refreshRelayPolicy => '刷新中继策略';

  @override
  String get refreshReplicationStatus => '刷新复制状态';

  @override
  String get refreshRestoreSources => '刷新恢复来源';

  @override
  String get refreshRestoreStatus => '刷新恢复状态';

  @override
  String get refreshSchedule => '刷新计划';

  @override
  String get refreshServerManagedGroups => '刷新服务器管理的分组';

  @override
  String get refreshStatus => '刷新状态';

  @override
  String get refreshToLoadApprovedDevicesFrom => '刷新以从服务器加载已批准的设备。';

  @override
  String get registeredEndpoints => '已注册的端点';

  @override
  String get reject2 => '拒绝';

  @override
  String get relayCidrs => '中继 CIDR';

  @override
  String get relayAvailable => '中继可用';

  @override
  String get relayPolicy => 'Relay 策略';

  @override
  String get relayPorts => '中继端口';

  @override
  String get relayUnavailable => '中继不可用';

  @override
  String get reloadAccountAndInstanceRelayPolicies => '重新加载账户和实例 Relay 策略';

  @override
  String get reloadFirstPage => '重新加载第一页';

  @override
  String get reloadGroupAndInstancePoliciesKeep => '重新加载分组和实例策略，保留草稿';

  @override
  String get reloadLatestGroupKeepDrafts => '重新加载最新分组，保留草稿';

  @override
  String get reloadLatestPolicy => '重新加载最新策略';

  @override
  String get reloadLatestPolicyKeepDraft => '重新加载最新策略，保留草稿';

  @override
  String get remote => '远程';

  @override
  String get remoteSshListenerAddress => '远程 SSH 监听地址';

  @override
  String get remoteArchiveIntegrityMismatch => '远程归档完整性不匹配';

  @override
  String get remoteCompletionUnknownNotRetried => '远程完成情况未知 · 未重试';

  @override
  String get remoteCopyFailed => '远程复制失败';

  @override
  String get remoteCopyVerified => '远程副本已验证';

  @override
  String get remoteCredentialsUnavailable => '远程凭据不可用';

  @override
  String remoteFilesEndpoint(Object endpoint) {
    return '远程文件 · $endpoint';
  }

  @override
  String get remoteHeadIsAbsent => '远程头部不存在';

  @override
  String get remotePath2 => '远程路径';

  @override
  String remotePathSftppath(String sftpPath) {
    return '远程路径：$sftpPath';
  }

  @override
  String get remoteReplica => '远程副本';

  @override
  String get remoteReplication => '远程复制';

  @override
  String remoteRevisionItem(Object item) {
    return '远程修订版本 $item';
  }

  @override
  String get remoteStorageUnavailable => '远程存储不可用';

  @override
  String remoteSshBindDeviceDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return '远程 · SSH $bind → 设备 $destinationAddress:$destinationPort';
  }

  @override
  String removePaneValuevalue(int valueValue) {
    return '移除窗格 $valueValue';
  }

  @override
  String get removeFavorite => '取消收藏';

  @override
  String get removeReference => '移除引用';

  @override
  String get removeTmuxSessionReference2 => '移除 tmux 会话引用';

  @override
  String get removeTmuxSessionReference => '移除 tmux 会话引用？';

  @override
  String removeUsernameFromGroupDraft(String username) {
    return '从分组草稿中移除 $username';
  }

  @override
  String get rename => '重命名';

  @override
  String get renameWorkspace => '重命名工作区';

  @override
  String get repairAHost => '修复主机';

  @override
  String get repairAGroup => '修复分组';

  @override
  String get repairIsNotConfirmedYetSync => '修复尚未确认。请同步当前保险库，并使用相同的记录 ID 重试。';

  @override
  String get replaceHost => '替换主机';

  @override
  String get replaceMissingHost => '替换缺失的主机';

  @override
  String get requestedAt => '请求时间';

  @override
  String get requiredTextValue => '必填文本值';

  @override
  String get reservedUploads => '已预留的上传';

  @override
  String get resetToInherit => '重置为继承';

  @override
  String get resolutionSavedOnThisDeviceWaiting => '解决方案已保存在此设备上；等待同步确认。';

  @override
  String get resolveOrDiscardThisRecordsOutstanding =>
      '永久清除此记录前，请先解决或丢弃其未处理的冲突。';

  @override
  String get resourceIdHmacSha256 => '资源 ID（HMAC-SHA-256）';

  @override
  String get resourceType => '资源类型';

  @override
  String responseValuevalue(int valueValue) {
    return '响应 $valueValue';
  }

  @override
  String get responsesAreSentOnlyForThis => '响应仅用于此次 SSH 认证，不会被保存。';

  @override
  String get restore => '还原';

  @override
  String get restoreDeadlinePassedAccordingToThis =>
      '根据此设备时钟，恢复截止时间已过；最终由服务器决定。';

  @override
  String restoreDeadlineFormat3(String format) {
    return '恢复截止时间 $format';
  }

  @override
  String restoreDeadlineFormatTheServerChecks(String format) {
    return '恢复截止时间：$format。确认时服务器会再次检查此截止时间。';
  }

  @override
  String get restoreDefaults => '恢复默认值';

  @override
  String get restoreIsRestrictedToTheSame =>
      '恢复仅限于同一服务器空间和保险库。服务器已清除的数据不包含在内；请将下载的归档和密码与此设备分开保存。';

  @override
  String get restorePreparesAnIsolatedCopyWhile =>
      '恢复会在服务保持在线时准备隔离副本。之后的离线切换由运营者处理。';

  @override
  String get restoreStaging => '恢复暂存';

  @override
  String restoreStagingAdminrestorejobstatuslabel(
    String adminRestoreJobStatusLabel,
  ) {
    return '恢复暂存 · $adminRestoreJobStatusLabel';
  }

  @override
  String get restoreThisRecord => '恢复此记录？';

  @override
  String restoreUsernameInGroupDraft(String username) {
    return '在分组草稿中恢复 $username';
  }

  @override
  String get result => '结果';

  @override
  String get resumeSession => '恢复会话';

  @override
  String get resumeTmuxSession2 => '恢复 tmux 会话';

  @override
  String get resumeTmuxSession => '恢复 tmux 会话？';

  @override
  String get retry2 => '重试';

  @override
  String get retryAccountInvitations => '重试加载账户邀请';

  @override
  String get retryAccountList => '重试加载账户列表';

  @override
  String get retryAndVerifyRepair => '重试并验证修复';

  @override
  String get retryBackupRequestSafely => '安全重试备份请求';

  @override
  String get retryDiscard => '重试丢弃';

  @override
  String get retryDiscardSafely => '安全重试丢弃';

  @override
  String get retryGroupDetails => '重试加载分组详情';

  @override
  String get retryGroupList => '重试加载分组列表';

  @override
  String get retryPasswordChange => '重试更改密码';

  @override
  String get retryPending => '等待重试';

  @override
  String get retryQueued => '重试已排队';

  @override
  String get retryRequestSafely => '安全重试请求';

  @override
  String get retryScheduled => '已安排重试';

  @override
  String get retrySessionList => '重试加载会话列表';

  @override
  String get retryWaiting => '等待重试';

  @override
  String get retryableFailure7UtcDays => '可重试的失败（7 个 UTC 日）';

  @override
  String get revealPasswordSecret => '显示密码机密';

  @override
  String get reviewHostConnectionSettings => '检查主机连接设置';

  @override
  String get reviewAndRun => '检查并运行';

  @override
  String get reviewBatchCommand => '检查批量命令';

  @override
  String get reviewCommandExecution => '检查命令执行';

  @override
  String get reviewCurrentVersion => '检查当前版本';

  @override
  String get reviewDeviceEnrollment => '检查设备注册';

  @override
  String get reviewEachSynchronizedBindingAndRecord =>
      '请检查每个同步的绑定和记录 ID。重复的记录会通过加密删除标记移除。';

  @override
  String get reviewKeys => '检查密钥';

  @override
  String get reviewLocalProfileMigration => '检查本地配置迁移';

  @override
  String reviewOnCountConnectedHosts(int count) {
    return '在 $count 台已连接主机上检查';
  }

  @override
  String get reviewThePaletteAndRecordId =>
      '请检查配色和记录 ID。所选记录保持生效；重复项会通过加密删除标记移除。';

  @override
  String get reviewTheSizeAndRecordId =>
      '检查大小和记录 ID。所选记录 ID 保持生效；其他记录会通过加密删除标记移除。';

  @override
  String get reviewTrustedDevices => '检查受信任设备';

  @override
  String get reviewUpdate => '检查更新';

  @override
  String reviewCountHosts(int count) {
    return '检查 $count 台主机';
  }

  @override
  String get revokePrometheusScrapeCredential => '撤销 Prometheus 抓取凭据？';

  @override
  String revokeSshHostKeyTrustFor(String endpoint, String fingerprint) {
    return '撤销 $endpoint（$fingerprint）的 SSH 主机密钥信任';
  }

  @override
  String get revokeSshHostKeyTrust2 => '撤销 SSH 主机密钥信任？';

  @override
  String get revokeAccess => '撤销访问权限';

  @override
  String get revokeAccountInvitation => '撤销账户邀请？';

  @override
  String get revokeAllSessions => '撤销所有会话';

  @override
  String get revokeAllSessions2 => '撤销所有会话？';

  @override
  String get revokeAndRotateKey => '撤销并轮换密钥';

  @override
  String get revokeCredential => '撤销凭据';

  @override
  String get revokeDevice => '撤销设备';

  @override
  String get revokeDevice2 => '撤销设备？';

  @override
  String revokeEveryActiveSessionForUsername(String username) {
    return '撤销 $username 的所有活动会话？这些会话的下一次请求将需要重新登录。';
  }

  @override
  String get revokeInputControl => '撤销输入控制';

  @override
  String get revokeInvitation => '撤销邀请';

  @override
  String get revokeInvitation2 => '撤销邀请？';

  @override
  String get revokeMemberAccess => '撤销成员访问权限？';

  @override
  String get revokeSession => '撤销会话';

  @override
  String get revokeSessions => '撤销会话';

  @override
  String revokeTheSessionOnDevicenameFor(String deviceName, String username) {
    return '撤销 $username 在 $deviceName 上的会话？';
  }

  @override
  String get revokeThisSession => '撤销此会话？';

  @override
  String get revokeTrust2 => '撤销信任';

  @override
  String get revoked3 => '已撤销';

  @override
  String get revokedAt => '撤销时间';

  @override
  String revokedFormat(String format) {
    return '已撤销 $format';
  }

  @override
  String revokedFormat2(String format) {
    return '已撤销 · $format';
  }

  @override
  String get role => '角色';

  @override
  String get rotatePrometheusScrapeCredential => '轮换 Prometheus 抓取凭据？';

  @override
  String get rotateCredential => '轮换凭据';

  @override
  String get rotateKeyAndChangeRole => '轮换密钥并更改角色？';

  @override
  String get rotateRecoveryCode => '轮换恢复码';

  @override
  String get rotationImmediatelyInvalidatesTheCurrentCredential =>
      '轮换会立即使当前凭据失效。复制新值后请更新 Prometheus 抓取配置；新值只显示一次。';

  @override
  String get runEncryptedBackup => '运行加密备份';

  @override
  String get runMaintenanceNow => '立即运行维护';

  @override
  String get running => '运行中';

  @override
  String get runningOnceThroughANonPty =>
      '通过非 PTY 的 SSH exec 通道运行一次。输出限制为 64 KiB。';

  @override
  String get scpUpload => 'SCP 上传…';

  @override
  String get scpDownload => 'SCP 下载…';

  @override
  String get scpFileManager => 'SCP 文件管理';

  @override
  String get sftpFileBrowser => 'SFTP 文件浏览器';

  @override
  String get sftpFileManager => 'SFTP 文件管理';

  @override
  String get socks5ConnectOnlyNoSocksUser =>
      '仅支持 SOCKS5 CONNECT，不支持 SOCKS 用户认证。代理监听此设备的回环地址。';

  @override
  String get sshRelayConnected => 'SSH Relay 已连接';

  @override
  String get sshTerminal => 'SSH 终端';

  @override
  String get sshAuthenticationChallenge => 'SSH 认证质询';

  @override
  String get sshConnected => 'SSH 已连接';

  @override
  String get sshConnecting => 'SSH 正在连接';

  @override
  String get sshConnectionFailed => 'SSH 连接失败';

  @override
  String get sshCredentials => 'SSH 凭据';

  @override
  String get sshDisconnected => 'SSH 已断开';

  @override
  String get sshExecFailedAfterDispatchThe =>
      'SSH exec 在派发后失败。命令可能已经开始执行，其远程完成情况未知。不会重试。';

  @override
  String get sshHostKeyChangesAreRejected => '首次验证信任后，SSH 主机密钥的变更会被拒绝。';

  @override
  String sshHostKeyFingerprintFingerprint(String fingerprint) {
    return 'SSH 主机密钥指纹：$fingerprint';
  }

  @override
  String get sshHostKeyTrust => 'SSH 主机密钥信任';

  @override
  String get sshPortForwarding => 'SSH 端口转发';

  @override
  String get sshRelay => 'SSH 中继';

  @override
  String get sshRelayPolicy => 'SSH 中继策略';

  @override
  String get sshSessionIsDisconnected => 'SSH 会话已断开。';

  @override
  String get sshTerminalInput => 'SSH 终端输入';

  @override
  String get sshUsername => 'SSH 用户名';

  @override
  String get sshHostTrust => 'SSH 主机信任';

  @override
  String sameOnBothBranchesValuevalue(String valueValue) {
    return '两个分支相同 · $valueValue';
  }

  @override
  String get save => '保存';

  @override
  String get saveConflictBranchAsWorkspaceCopy => '将冲突分支另存为工作区副本';

  @override
  String get saveCurrentTabs => '保存当前标签页';

  @override
  String get saveEncryptedCredential2 => '保存加密凭据';

  @override
  String get saveEncryptedGroup => '保存加密分组';

  @override
  String get saveEncryptedProfile => '保存加密配置';

  @override
  String get saveGroupOverride => '保存分组覆盖设置';

  @override
  String get saveLocalLayoutAsNamedCopy => '将本地布局另存为命名副本';

  @override
  String get saveMembership => '保存成员资格';

  @override
  String get saveMergedCredential => '保存合并后的凭据';

  @override
  String get saveOverride => '保存覆盖设置';

  @override
  String get saveQuota => '保存配额';

  @override
  String get saveRelayPolicy => '保存中继策略';

  @override
  String get saveReviewedTuple => '保存已检查的设置整体';

  @override
  String get saveSchedule => '保存计划';

  @override
  String get saveShortcuts2 => '保存快捷键';

  @override
  String get saveSnippet => '保存片段';

  @override
  String get saveSplitWorkspace => '保存分屏工作区';

  @override
  String get saveSyncedPreference => '保存同步的偏好';

  @override
  String get saveTerminalColorTheme => '保存终端配色主题';

  @override
  String get saveTerminalFontSize2 => '保存终端字号';

  @override
  String get saveThisCredentialNow => '立即保存此凭据';

  @override
  String get saveWorkspace => '保存工作区';

  @override
  String savedAsItemThisPreferenceIs(Object item) {
    return '已保存为 $item。此偏好已在当前保险库中加密，并将同步到其授权设备。';
  }

  @override
  String savedCheckpointShortkey(String shortKey) {
    return '已保存的检查点：$shortKey';
  }

  @override
  String get savedSettingsCanOnlyNarrowThe => '保存的设置只能收窄服务器运营者配置的不可变限制。';

  @override
  String get savedWorkspaces => '已保存的工作区';

  @override
  String savedFontsizePxThisEncryptedPreference(int fontSize) {
    return '已保存 $fontSize px。此加密偏好将同步到有权访问此保险库的设备。';
  }

  @override
  String savedLabelThisEncryptedPreferenceWill(String label) {
    return '已保存 $label。此加密偏好将同步到有权访问此保险库的设备。';
  }

  @override
  String get savingAndPreviewingDoNotConnect =>
      '保存和预览不会建立连接。选择任意窗格，然后拆分它以添加另一个主机节点。';

  @override
  String get scheduleVaultDeletion => '安排删除保险库';

  @override
  String get scheduleVaultDeletion2 => '安排删除保险库？';

  @override
  String get scheduleAccountDeletion => '安排账户删除';

  @override
  String get scheduleAccountDeletion2 => '安排账户删除？';

  @override
  String get scheduleDeletion => '安排删除';

  @override
  String get scheduledEncryptedBackups => '计划的加密备份';

  @override
  String get scheduledFor => '计划时间';

  @override
  String get scriptBody2 => '脚本正文';

  @override
  String get searchThisHostsCompletedCommandsPlain =>
      '搜索此主机已完成的命令、普通 Bash 片段和本地 Bash 命令名。选择建议会在当前终端光标处输入一行；永远不会按下 Enter。';

  @override
  String searchValuevalueScrollback(String valueValue) {
    return '搜索 $valueValue 回滚内容';
  }

  @override
  String get secureTerminalWorkspace => '安全终端工作区';

  @override
  String get securityPolicy => '安全策略';

  @override
  String get selectAnActiveVaultBeforeEnabling => '启用同步前请选择活动保险库。';

  @override
  String get selectFirstHost => '选择第一台主机';

  @override
  String get selectedArchive => '所选归档';

  @override
  String get selectedServerManagedGroup => '所选的服务器管理分组';

  @override
  String selectedStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return '所选状态：$valueValue · CIDR：$summarize · 端口：$summarize2';
  }

  @override
  String get sendANewInvitationFromSettings => '请从“设置 > 邀请成员”发送新的邀请。';

  @override
  String get sendResponses => '发送响应';

  @override
  String get serverBackupConfigurationNotReady => '服务器备份配置尚未就绪';

  @override
  String get serverBackupConfigurationReady => '服务器备份配置已就绪';

  @override
  String get serverGenerationUnknown => '服务器代次未知';

  @override
  String get serverSpaceId => '服务器空间 ID';

  @override
  String serverSpaceServerspaceid(String serverSpaceId) {
    return '服务器空间：$serverSpaceId';
  }

  @override
  String get serverManagedAccessGroups => '服务器管理的访问分组';

  @override
  String get serverManagedGroupActionFailed => '服务器管理分组操作失败';

  @override
  String get serverManagedGroupSaveFailed => '服务器管理分组保存失败';

  @override
  String serverLocalConflictBranchesConflictcount(int conflictCount) {
    return '服务器/本地冲突分支：$conflictCount';
  }

  @override
  String get sessionId => '会话 ID';

  @override
  String get setTheIntervalBelowThenSave => '在下方设置间隔，然后保存更改。';

  @override
  String setTheSharedTerminalTextSize(
    String join,
    int defaultTerminalFontSize,
  ) {
    return '设置此保险库共享的终端文字大小。可选大小：$join px。默认：$defaultTerminalFontSize px。';
  }

  @override
  String get setUpAccountRecovery => '设置账户恢复';

  @override
  String get setUpRecovery => '设置恢复';

  @override
  String get shareThisTerminal => '共享此终端';

  @override
  String get sharedTerminalOutputReadOnly => '共享的终端输出，只读';

  @override
  String get sharedTerminalHostApprovedControl => '共享终端 · 主机批准的控制';

  @override
  String get sharedTerminalReadOnly => '共享终端 · 只读';

  @override
  String get shellLabel2 => 'Shell 标签';

  @override
  String shellLabelShellSentToThe(String shell) {
    return 'Shell 标签：$shell · 发送到活动 SSH PTY';
  }

  @override
  String showingCountLocalArchivesOnThis(int count) {
    return '此页显示 $count 个本地归档';
  }

  @override
  String showingFirstLastOfAdmincountAccounts(
    int first,
    int last,
    String adminCount,
  ) {
    return '显示第 $first–$last 个，共 $adminCount 个账户';
  }

  @override
  String showingFirstLastOfAdmincountInvitations(
    int first,
    int last,
    String adminCount,
  ) {
    return '显示第 $first–$last 个，共 $adminCount 个邀请';
  }

  @override
  String showingFirstLastOfAdmincountSessions(
    int first,
    int last,
    String adminCount,
  ) {
    return '显示第 $first–$last 个，共 $adminCount 个会话';
  }

  @override
  String showingStartEndOfAdmincountVaults(
    int start,
    int end,
    String adminCount,
  ) {
    return '显示第 $start–$end 个，共 $adminCount 个保险库';
  }

  @override
  String showingValuevalueValuevalue2OfTotal(
    int valueValue,
    int valueValue2,
    int total,
  ) {
    return '显示第 $valueValue–$valueValue2 项，共 $total 项';
  }

  @override
  String get showsTheLatestCompletedBackupAttempt =>
      '显示此服务器记录的最近一次已完成备份尝试。当归档在此节点上已不可用时，大小可能未知。这并不能确认归档仍然存在，也不能确认隔离恢复一定会成功。';

  @override
  String get sideBySide => '左右并排';

  @override
  String get sideBySideLeftRight => '并排（左/右）';

  @override
  String get signAndCreateInvitation => '签名并创建邀请';

  @override
  String get signInNeeded => '需要登录';

  @override
  String get signedVaultShareRequest => '已签名的保险库共享请求';

  @override
  String get signedShareRequestCopied => '已复制签名的共享请求。';

  @override
  String get signingKeyFingerprint => '签名密钥指纹';

  @override
  String get signingKeyFingerprintSha256 => '签名密钥指纹 · SHA-256';

  @override
  String get snapshotExceedsClientLimit => '快照超出客户端上限';

  @override
  String get snapshotGenerated => '快照生成时间';

  @override
  String get snapshotLimitReached => '已达快照上限';

  @override
  String get snapshotNeeded => '需要快照';

  @override
  String get snapshotSizeLimit => '快照大小上限';

  @override
  String get snapshotVerificationIsInProgressLocal =>
      '正在验证快照。本地编辑已暂停；在完整清单通过验证前，现有缓存和发件箱保持不变。';

  @override
  String get snippet2 => '片段';

  @override
  String get snippetScriptIsRequired => '片段脚本为必填项';

  @override
  String get snippetTitleIsRequired => '片段标题为必填项';

  @override
  String snippetTitle3(String title) {
    return '片段：$title';
  }

  @override
  String get source => '来源';

  @override
  String get splitWorkspaceSavedEncryptedToThis => '分屏工作区已加密保存到此保险库。';

  @override
  String splitControlsCountDividersEachRatio(int count) {
    return '分屏控件 · $count 条分隔线 · 每个比例决定第一个子项的大小';
  }

  @override
  String get splitSelectedPane => '拆分所选窗格';

  @override
  String splitValuevalue(int valueValue) {
    return '分屏 $valueValue';
  }

  @override
  String splitValuevalueAxisFirstpercentValuevalue2(
    int valueValue,
    String axis,
    int firstPercent,
    int valueValue2,
  ) {
    return '分屏 $valueValue · $axis · $firstPercent/$valueValue2';
  }

  @override
  String splitFirstpercentSecondpercent(int firstPercent, int secondPercent) {
    return '分屏 · $firstPercent/$secondPercent';
  }

  @override
  String get stacked => '上下堆叠';

  @override
  String get stackedTopBottom => '上下堆叠（上/下）';

  @override
  String get stageId => '暂存 ID';

  @override
  String get startForwarding => '开始转发';

  @override
  String get startResumableSession => '启动可恢复会话';

  @override
  String get startResumableTmuxSession => '启动可恢复的 tmux 会话？';

  @override
  String get startSession => '启动会话';

  @override
  String get startSharing => '开始共享';

  @override
  String get startedAt => '开始时间';

  @override
  String get stopAuthentication => '停止认证';

  @override
  String get stopForwarding => '停止转发';

  @override
  String get stopLocalCapture => '停止本机采集';

  @override
  String get stopTerminalSharing => '停止终端共享';

  @override
  String get stopThisForwardBeforeEditingIts => '编辑配置前请先停止此转发。';

  @override
  String get storeYourRecoveryCode => '保存你的恢复码';

  @override
  String get stored => '已存储';

  @override
  String get storedData => '存储的数据';

  @override
  String get structuredBashCommand2 => '结构化 Bash 命令';

  @override
  String get submitBackupRequest => '提交备份请求';

  @override
  String get submittingBackup => '正在提交备份…';

  @override
  String get succeeded2 => '成功';

  @override
  String get syncCommandHistoryToVault => '将命令历史同步到保险库';

  @override
  String get syncCommandHistoryToThisVault => '将命令历史同步到此保险库？';

  @override
  String get syncError => '同步错误';

  @override
  String get syncHealth => '同步健康状况';

  @override
  String get syncNow => '立即同步';

  @override
  String get syncPendingChanges => '同步待处理更改';

  @override
  String get syncServiceError => '同步服务错误';

  @override
  String get syncStatus => '同步状态';

  @override
  String get syncing => '正在同步';

  @override
  String get thisDevice => '此设备';

  @override
  String tabValuevalue(int valueValue) {
    return '标签页 $valueValue';
  }

  @override
  String tabValuevalueMissingHost(int valueValue) {
    return '标签页 $valueValue · 主机缺失';
  }

  @override
  String tabValuevalueName(int valueValue, String name) {
    return '标签页 $valueValue · $name';
  }

  @override
  String get tagsSeparatedByCommas => '标签，以逗号分隔';

  @override
  String targetValuevalueOfCountValuevalue2(
    int valueValue,
    int count,
    String valueValue2,
  ) {
    return '目标 $valueValue/$count：$valueValue2';
  }

  @override
  String targetValuevalueHostnameEndpoint(
    int valueValue,
    String hostName,
    String endpoint,
  ) {
    return '目标 $valueValue：$hostName · $endpoint';
  }

  @override
  String targetHostnameEndpoint(String hostName, String endpoint) {
    return '目标：$hostName · $endpoint';
  }

  @override
  String get targetsRunSequentiallyNoTargetStarts =>
      '目标按顺序运行。在确认完整检查之前不会启动任何目标。批处理会在第一个非零或未知结果处停止，且不会重试。';

  @override
  String get terminal => '终端';

  @override
  String get terminalColorTheme => '终端配色主题';

  @override
  String get terminalFontSize3 => '终端字号';

  @override
  String terminalFontSizeValuevaluePxRecord(
    Object valueValue,
    String id,
    String revisionLabel,
  ) {
    return '终端字号：$valueValue px；记录 ID：$id；修订版本：$revisionLabel';
  }

  @override
  String get terminalHistory => '终端历史';

  @override
  String get terminalKeyboardShortcuts => '终端快捷键';

  @override
  String terminalPanesCountMaxworkspacepanes(int count, int maxWorkspacePanes) {
    return '终端窗格 · $count/$maxWorkspacePanes';
  }

  @override
  String terminalSharePhase(String phase) {
    return '终端共享 $phase';
  }

  @override
  String terminalThemeThemelabelRecordIdId(
    String themeLabel,
    String id,
    String valueValue,
  ) {
    return '终端主题：$themeLabel；记录 ID：$id；修订版本：$valueValue';
  }

  @override
  String get theHostConflictCanNoLonger => '此主机冲突已无法安全检查。';

  @override
  String get theSshServerGatewayportsSettingMay =>
      'SSH 服务器的 GatewayPorts 设置可能会扩大此回环绑定请求。使用远程转发前请核实服务器配置。';

  @override
  String get theSshServerRequestedTooMany => 'SSH 服务器请求的响应过多，认证已停止。';

  @override
  String get theVaultChangedReopenPortForwarding => '保险库已更改；请重新打开端口转发。';

  @override
  String get theVaultOrOneOfThe => '保险库或某台所选主机已不可用。';

  @override
  String get theArchiveHasPassedSignatureMembership =>
      '归档已通过签名、成员资格、信封、对象哈希和架构检查。导入只会合并到此保险库中。缺失的加密对象可能会上传到同一保险库；导入不包含会话令牌或设备私钥。由其他设备创建的发件箱条目会保留为本地冲突，不会以此设备身份重放。';

  @override
  String get theCommittedHostChangedAfterThis =>
      '此预览之后已提交的主机发生了变化。未暂存任何编辑；请先检查最新头部再重新选择。';

  @override
  String get theCommittedHostChangedReviewIts => '已提交的主机已更改。合并前请检查其最新连接设置。';

  @override
  String get theCommittedVaultVersionChangedReview => '已提交的保险库版本已更改。合并前请再次检查。';

  @override
  String get theCredentialIsNoLongerAvailable =>
      '此凭据在本会话中已不可用。如果轮换已完成，请在检查状态后再次轮换以获取新的一次性值。';

  @override
  String get theCurrentVaultVersionChangedWhile =>
      '你检查期间当前保险库版本已更改，你的选择已被清除。请先检查当前版本再重新选择。';

  @override
  String get theDefaultPreferenceWasConfirmedAfter => '默认偏好已在保险库同步后确认。';

  @override
  String get theDeploymentGateIsAvailableWith =>
      '部署开关在 ATERMIUS_RELAY_ENABLED=true 时可用。实际授权始终受已配置的 CIDR 和端口限制。';

  @override
  String get theExportContainsARandomReport =>
      '导出内容包含随机报告 ID、固定错误代码、客户端版本、同步计数以及取整到 UTC 日的日期。绝不包含保险库记录、账户详情、服务器地址或设备标识符。';

  @override
  String get theFullScriptIsReviewedBefore => '完整脚本会在发送到活动 PTY 之前接受检查。';

  @override
  String get theLastResponseWasNotConfirmed =>
      '上一次响应未得到确认。服务器可能已更改密码。重试会发送完全相同的请求；不会为重试保存任何密码。请记住新密码。退出登录会清除此重试请求。';

  @override
  String get theLocalBranchAndItsOriginal =>
      '本地分支及其原始 CAS 基线会加密保留在本地存储中。快照中没有此记录的当前远程头部；保留本地分支会创建一个新的根修订版本。';

  @override
  String get theLocalLayoutBranchWasSaved => '本地布局分支已另存为新的加密工作区。';

  @override
  String get theOperatingSystemWillAskFor =>
      '只有在你开启此项时，操作系统才会请求通知权限。保险库数据仍通过经过认证的 WebSocket 或轮询方式同步。';

  @override
  String get theOptInRemoteBashHook =>
      '可选启用的远程 Bash 钩子会在加密的本机存储中保存最多 500 条已完成的命令。远程主机可以伪造 OSC 条目。不会读取密码提示，但以命令文本形式输入的机密可能会被采集。“停止本机采集”会忽略新事件；在 Bash 中运行 \"atermius_off\" 或关闭 Shell 可停止钩子。';

  @override
  String get thePasswordStaysInThisForm => '密码只保留在此表单中，永远不会被发送。';

  @override
  String thePendingInvitationForUsernameWill(String username) {
    return '$username 的待处理邀请将不再被接受。';
  }

  @override
  String get thePreviousCodeWasNotConfirmed => '上一个代码未确认已保存。请轮换恢复以显示替代代码。';

  @override
  String get theSavedPolicyExceedsTheCurrent =>
      '已保存的策略超出当前部署上限。实际授权仍受当前限制约束。保存前请收窄下方的 CIDR 和端口；中继服务运行还需要 ATERMIUS_RELAY_ENABLED=true。';

  @override
  String get theSavedPolicyRemainsSelectedAs =>
      '已保存的策略仍选择为启用，但在部署开关关闭期间，实际中继服务不可用。需要 ATERMIUS_RELAY_ENABLED=true；保存其他更改前请先关闭该选择。Web 界面无法更改此开关。';

  @override
  String get theSecretIsReadFromThe => '运行此片段时会从加密凭据中读取机密；它永远不会被复制到片段记录或预览中。';

  @override
  String get theSelectedDefaultPreferenceWasConfirmed => '所选默认偏好已在保险库同步后确认。';

  @override
  String get theSelectedShortcutBindingsWereConfirmed => '所选快捷键绑定已在保险库同步后确认。';

  @override
  String get theSelectedTerminalFontSizeWas => '所选终端字号已在保险库同步后确认。';

  @override
  String get theSelectedTerminalThemeWasConfirmed => '所选终端主题已在保险库同步后确认。';

  @override
  String get theServerCanCopyEncryptedInstance =>
      '服务器可将加密的实例归档复制到运营者配置的 S3 兼容目标。目标和凭据保留在服务器上。访问检查仅执行 HeadBucket，不验证上传、分段操作、恢复或提供方范围的互操作性。';

  @override
  String get theServerDeploymentGateMustAlso => '服务器部署开关也必须启用。';

  @override
  String get theServerDidNotRequestA => '服务器未请求响应。';

  @override
  String get theServerFirstValidatesThatThis =>
      '服务器会先验证此副本及其回执是否属于此恢复任务；如果无法验证，则不会改动这些文件。确认清理会永久移除这个隔离副本；源加密归档和活动服务数据保持不变。之后你可以从源归档重新准备隔离副本。';

  @override
  String get theServerReceivesPasswordDerivedVerifiers =>
      '服务器会收到由密码派生的验证器和新加密的账户密钥信封。你的主密码和账户密钥保留在此设备上。';

  @override
  String get theServerRequiresANewerWeb => '服务器需要更新的 Web 客户端协议。';

  @override
  String get theServerRequiresANewerClient =>
      '服务器需要较新的客户端协议。请确认已部署的 Web 包是预期的兼容版本。';

  @override
  String theServerRestorePeriodHasNot2(String deadlineText) {
    return '服务器恢复期尚未结束。$deadlineText请刷新回收站并稍后重试。';
  }

  @override
  String get theServerWillDeleteTheEncrypted =>
      '服务器将删除加密的恢复包和所有恢复密钥盒。之后需要一台已批准的设备才能重新设置。';

  @override
  String get theServerWillStartItsConfigured =>
      '服务器将启动其配置的宽限期。所有活动成员立即变为只读，在服务器截止时间之前仍可读取。请在截止时间前另行创建并保存一个便携加密归档；此客户端只能恢复到同一服务器空间和保险库。确认后服务器会返回确切的清除时间。';

  @override
  String get theServiceStaysOnlineWhileIt =>
      '服务在从所选本地归档准备独立副本期间保持在线。这会在实时数据库中记录一个恢复任务和审计事件并使用维护锁，但不会更改活动的账户、保险库、会话或代次数据，也不会激活或替换实时数据。工作进程在发布隔离暂存前会再次检查归档。';

  @override
  String get theServiceStaysOnlineWhileIt2 =>
      '服务在准备独立副本期间保持在线。这会在实时数据库中记录一个恢复任务和审计事件并使用维护锁，但不会更改活动的账户、保险库、会话或代次数据，也不会激活或替换实时数据。工作进程在发布隔离暂存前会再次检查所选的本地或远程归档。';

  @override
  String get theShareExpiresAfter15Minutes =>
      '共享将在 15 分钟后过期。终端输出和主机尺寸调整事件会为每台所选设备分别加密。';

  @override
  String get theSyncCursorExpiredOrThe =>
      '同步游标已过期或服务器代次已变化。请从已验证的快照重建缓存；待处理的本地操作会被保留并与远程头部比较。';

  @override
  String get theTerminalChangedBeforeTheSuggestion => '插入建议前终端已变化。请重新打开建议后重试。';

  @override
  String get theUpdateCheckCouldNotConfirm => '更新检查无法确认当前的 Web 版本。';

  @override
  String get theseInstanceGroupsControlSshRelay =>
      '这些实例分组控制 SSH Relay 访问。它们独立于加密的工作区分组，不包含保险库数据。';

  @override
  String get thisGroupDefaultIsUnavailableChoose => '此分组默认值不可用。请选择不设默认值或有效凭据。';

  @override
  String get thisHostConflictHasNoSafely => '此主机冲突没有可安全检查的连接设置整体。请改用已验证分支的操作。';

  @override
  String thisSshKeyIsNotTrusted(String endpoint) {
    return '此 SSH 密钥未被信任用于 $endpoint。接受前请通过可信渠道比对其指纹。';
  }

  @override
  String get thisVaultIsReadOnlyFor =>
      '此保险库对当前账户为只读。在服务器允许的范围内仍可读取。可以从“设置”创建便携加密归档。';

  @override
  String get thisVaultIsReadOnlyMember => '此保险库为只读，无法更改成员。';

  @override
  String get thisVaultIsReadOnlyYou => '此保险库为只读。你可以查看此偏好，但无法更改。';

  @override
  String get thisVaultIsReadOnlyYou2 => '此保险库为只读。你可以查看共享的快捷键，但无法更改。';

  @override
  String get thisVaultIsReadOnlyYou3 => '此保险库为只读。你可以查看共享的终端配色主题，但无法更改。';

  @override
  String get thisVaultIsReadOnlyYou4 => '此保险库为只读。你可以查看共享的终端字号，但无法更改。';

  @override
  String get thisWebBuildIsCurrent => '此 Web 版本已是最新。';

  @override
  String get thisAccountHasNoVaultAvailable =>
      '此账户在此设备上没有可用的保险库。请创建新的加密保险库、接受现有成员的邀请，或请所有者恢复你的访问权限。现有加密数据与任何新保险库相互独立。';

  @override
  String get thisAttachesTheCurrentSshPane =>
      '这会将当前 SSH 窗格附加到其保存的 tmux 会话。其他已附加的客户端保持连接。';

  @override
  String get thisCardContainsTheAccountAnd =>
      '此卡片包含账户和设备公钥以及自证签名，不包含私钥或保险库密钥。请通过可信渠道发送给保险库所有者。';

  @override
  String get thisCodeIsShownOnceAnyone =>
      '此代码只显示一次。任何持有它的人都能恢复此账户中的保险库密钥。请将其保存在密码管理器或其他安全位置。此客户端永远不会保存它。';

  @override
  String get thisConflictNoLongerSupportsPassword =>
      '此冲突已不再支持合并密码字段。请改用已验证分支的操作。';

  @override
  String get thisCreatesATmuxSessionOn =>
      '这会在当前 SSH 主机上创建 tmux 会话，并将其引用保存在此加密工作区中。';

  @override
  String get thisDeviceLoopbackOnly => '仅此设备回环地址';

  @override
  String get thisExactFingerprintWasRevokedBefore =>
      '此确切指纹此前已被撤销。重新批准会为此保险库创建新的加密信任记录并同步到其设备。继续前请通过独立渠道核实。';

  @override
  String get thisFormNeverSubmitsCredentialText => '此表单从不直接向服务器提交凭据文本。';

  @override
  String thisGrantsRoleAccessToAll(String role) {
    return '这会授予 $role 访问此保险库中所有加密记录的权限。当前保险库密钥会密封给此设备，并由所有者签署新的成员资格版本。继续前请与接收者核实账户和两个指纹。';
  }

  @override
  String get thisGroupChangedOnAnotherDevice => '此分组已在另一台设备上更改。请同步并重新打开后再重试。';

  @override
  String get thisGroupHasNoMembers => '此分组没有成员。';

  @override
  String get thisImmediatelyRevokesEverySessionAnd =>
      '这会立即撤销所有会话和设备。到服务器清除截止时间时，个人保险库和账户数据会被删除，你对共享保险库的访问也会被移除。其他成员的共享保险库数据不会被删除。';

  @override
  String get thisInstance => '此实例';

  @override
  String get thisInvitationWasInvalidatedAfterA =>
      '保险库成员资格变更后此邀请已失效。请从“设置 > 邀请成员”发送新的邀请。';

  @override
  String get thisInvitationsValidityCouldNotBe =>
      '无法确认此邀请的有效性。请从“设置 > 邀请成员”发送新的邀请。';

  @override
  String get thisIsABearerTokenShare =>
      '这是一个持有者令牌。请仅通过可信渠道分享给目标接收者。它只显示一次，并绑定到目标账户和设备。';

  @override
  String get thisIsOptInAndBash =>
      '这是可选的且仅限 Bash。它不会编辑 Shell 启动文件或写入远程文件。复制命令后，将其粘贴到已连接的 Shell 并按 Enter。已完成的命令会加密保存在此设备上（最多 500 条）。远程主机可以伪造条目。不会读取密码提示，但以命令文本形式输入的机密可能会被采集。';

  @override
  String get thisMobileAppBuildHasNo =>
      '此移动应用构建未配置 Firebase 项目。请使用此应用的 Firebase 选项构建以启用提供方令牌注册。对于 FCM 投递，Firebase 项目必须与服务器服务账号项目一致；iOS APNs 投递使用服务器的 APNs 配置。WebSocket 和轮询同步仍然可用。';

  @override
  String get thisPasswordIsUsedOnlyTo => '此密码仅用于解密此归档。';

  @override
  String thisRecordsConsentForThisExact(String recordDisplayName) {
    return '这只会为此删除标记（$recordDisplayName）记录同意。启用后，受限的维护任务可能会在其恢复截止时间和其他必要检查之后自动清除它。启用同意不会立即清除。';
  }

  @override
  String get thisRecordsDeletedVersionChangedThe =>
      '此记录的已删除版本已更改。回收站正在刷新；请先检查后再重试。';

  @override
  String get thisRemovesTheEncryptedWorkspaceReference =>
      '这会移除加密的工作区引用，但不会停止或删除远程 tmux 会话。';

  @override
  String get thisRequestBelongsToAnotherAccount => '此请求属于另一个账户。';

  @override
  String get thisServerBackendDoesNotSupport => '此服务器后端尚不支持永久清除记录。未执行清除。';

  @override
  String get thisServerIsNotCurrentlyAccepting =>
      '此服务器当前不接受恢复请求。现有的隔离暂存和实时数据保持不变。';

  @override
  String thisSettingIsEncryptedInCurrentvaultname(String currentVaultName) {
    return '此设置在 $currentVaultName 中加密，并同步到有权访问此保险库的设备。';
  }

  @override
  String thisSettingIsStoredAsAn(String currentVaultName) {
    return '此设置作为加密记录存储在 $currentVaultName 中，并随该保险库同步。';
  }

  @override
  String get thisSignedOutboxBranchCameFrom =>
      '此已签名的发件箱分支来自另一台设备。其操作 ID 和信封会在本地保留，但此设备不会以不同的签名身份重放它。保留本地分支会创建一个由此设备签名的新修订版本。';

  @override
  String get thisSnapshotExceedsThisClientsLimit =>
      '此快照超出此客户端 64 MiB 序列化清单数据或 100,000 个头部的上限。现有缓存、检查点和待发送的发件箱都会保留。重复恢复无济于事；请联系项目维护者获取迁移指导。';

  @override
  String get title => '标题';

  @override
  String get toEnableSshRelayTheServer =>
      '要启用 SSH 中继，服务器运营者必须设置 ATERMIUS_RELAY_ENABLED=true 并配置部署限制。Web 界面无法更改此开关。';

  @override
  String get topLevelGroup2 => '顶级分组';

  @override
  String get transferVaultOwnership => '转移保险库所有权？';

  @override
  String get transferAndRotateKey => '转移并轮换密钥';

  @override
  String get transferOwnership => '转移所有权';

  @override
  String get trustAfterVerification => '核实后信任';

  @override
  String get trustedDevices => '受信任的设备';

  @override
  String get typeDeleteToConfirm => '输入 DELETE 以确认';

  @override
  String get typeEnableAutomaticPurge => '输入 ENABLE AUTOMATIC PURGE';

  @override
  String get typeACommandFragmentToSee => '输入命令片段以查看建议。';

  @override
  String typeVaultnameToConfirm(String vaultName) {
    return '输入“$vaultName”以确认';
  }

  @override
  String unableToCheckBackupBucketAccess(String error) {
    return '无法检查备份存储桶访问：$error';
  }

  @override
  String unableToDiscardIsolatedRestoreCopy(String error) {
    return '无法丢弃隔离的恢复副本：$error';
  }

  @override
  String get unableToLoadAccountRelayPolicy => '无法加载账户 Relay 策略';

  @override
  String get unableToLoadMemberEffectiveRelay => '无法加载成员的实际 Relay 访问权限';

  @override
  String unableToLoadOffSiteBackup(String error) {
    return '无法加载异地备份状态：$error';
  }

  @override
  String unableToLoadRestoreSourcesError(String error) {
    return '无法加载恢复来源：$error';
  }

  @override
  String unableToLoadScheduledBackupsError(String error) {
    return '无法加载计划备份：$error';
  }

  @override
  String get unableToLoadServerManagedGroup => '无法加载服务器管理分组的详情';

  @override
  String get unableToLoadServerManagedGroups => '无法加载服务器管理的分组';

  @override
  String unableToPrepareIsolatedRestoreCopy(String error) {
    return '无法准备隔离的恢复副本：$error';
  }

  @override
  String unableToRefreshRestoreStageStatus(String error) {
    return '无法刷新恢复暂存状态：$error';
  }

  @override
  String unableToReviewPasswordFieldsFriendlyerror(String friendlyError) {
    return '无法检查密码字段：$friendlyError';
  }

  @override
  String unableToSaveScheduledBackupsError(String error) {
    return '无法保存计划备份：$error';
  }

  @override
  String get unavailableCredential2 => '不可用的凭据';

  @override
  String get unavailableCredential => '不可用的凭据';

  @override
  String get unavailableGroup => '不可用的分组';

  @override
  String get unavailableInWeb => 'Web 版不可用';

  @override
  String get unavailableOnThisNode => '此节点不可用';

  @override
  String get unavailableParentChooseAgain => '父级不可用，请重新选择';

  @override
  String uncommittedOperationsCount(int count) {
    return '未提交的操作：$count';
  }

  @override
  String get unknown => '未知';

  @override
  String get unknownPushProvider => '未知推送提供方';

  @override
  String get unlockArchive => '解锁归档';

  @override
  String get unnamedDevice => '未命名设备';

  @override
  String get unsupportedTheme => '不支持的主题';

  @override
  String get unverified => '未验证';

  @override
  String get upOneDirectory => '返回上一级目录';

  @override
  String get updateAndReload => '更新并重新加载';

  @override
  String get updateReadinessChangedFinishTheVisible =>
      '更新就绪状态已变化。请先解决显示的阻碍项再确认。';

  @override
  String get updatingThisDevice => '正在更新此设备…';

  @override
  String get upload => '上传';

  @override
  String get uploadAFileOrCreateA => '上传文件或创建文件夹即可开始。';

  @override
  String get useAtLeast12CharactersIf =>
      '至少使用 12 个字符。如果响应丢失，客户端只会在内存中保留完全相同的重试请求，而不会保留任一密码。';

  @override
  String get useConflictBranch => '使用冲突分支';

  @override
  String get useCurrentVaultVersion => '使用当前保险库版本';

  @override
  String get useSyncedVersion => '使用已同步版本';

  @override
  String get useTheAccountAndApprovedDevice =>
      '使用邀请中指定的账户和已批准设备。令牌在经过认证的请求正文中发送，永远不会添加到 URL 中。';

  @override
  String get useTheConflictBranchTuple => '使用冲突分支的设置整体';

  @override
  String get useTheCurrentVaultTuple => '使用当前保险库的设置整体';

  @override
  String get useTheSyncedVersion => '使用已同步版本？';

  @override
  String get userId => '用户 ID';

  @override
  String get username => '用户名';

  @override
  String get validatingAllSelectedHostsBeforeSending => '正在发送第一条命令前验证所有所选主机。';

  @override
  String get vaultId => '保险库 ID';

  @override
  String get vaultArchiveImportedAndLocalState => '保险库归档已导入，本地状态已恢复。';

  @override
  String vaultChangedWhileSavingCheckThe(String startingVaultName) {
    return '保存期间保险库已切换。请检查 $startingVaultName 中的偏好；当前保险库未标记为已保存。';
  }

  @override
  String vaultChangedWhileSavingCheckThe2(String startingVaultName) {
    return '保存期间保险库已切换。请检查 $startingVaultName 中的快捷键偏好；当前保险库未标记为已保存。';
  }

  @override
  String vaultChangedWhileSavingTheEncrypted(String startingVaultName) {
    return '保存期间保险库已切换。加密更改仍在 $startingVaultName 中排队；未保存到当前保险库。';
  }

  @override
  String vaultChangedWhileSavingTheFont(String startingVaultName) {
    return '保存期间保险库已切换。字号更改仍在 $startingVaultName 中排队；未保存到当前保险库。';
  }

  @override
  String vaultChangedWhileSavingTheShortcut(String startingVaultName) {
    return '保存期间保险库已切换。快捷键更改仍在 $startingVaultName 中排队；未保存到当前保险库。';
  }

  @override
  String vaultChangedWhileSavingTheTheme(String startingVaultName) {
    return '保存期间保险库已切换。主题更改仍在 $startingVaultName 中排队；未保存到当前保险库。';
  }

  @override
  String vaultDeletionIsScheduledThisVault(String vaultLifecycleDate) {
    return '已安排删除保险库。此保险库为只读；服务器将在 $vaultLifecycleDate 后清除数据。待发送的更改保留在此设备上，只有所有者取消删除后才会继续。';
  }

  @override
  String get vaultDeletionPendingReadOnly => '保险库待删除 · 只读';

  @override
  String vaultDeviceNameStatuslabel(String name, String statusLabel) {
    return '保险库设备 $name，$statusLabel';
  }

  @override
  String vaultIsInItsDeletionGrace(int pendingCount) {
    return '保险库处于删除宽限期。拉取和读取仍可用，但冲突上传和发件箱推送已暂停。请使用“设置”中的便携加密归档进行本地备份；服务器会在显示的截止时间清除实时保险库数据。$pendingCount 项待处理操作仍加密保存在此设备上，只有所有者在截止时间前取消删除才会继续。';
  }

  @override
  String get vaultKeyState => '保险库密钥状态';

  @override
  String get vaultMetadataAndStorageLimitsEncrypted =>
      '保险库元数据和存储限制。加密的名称和内容永远不会显示。';

  @override
  String get vaultName => '保险库名称';

  @override
  String get vaultNameHostsCredentialsAndSnippets => '保险库名称、主机、凭据和片段在同步前已加密。';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore =>
      '更改这些快捷键前，需要先处理保险库偏好数据。';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore2 => '更改此设置前，需要先处理保险库偏好数据。';

  @override
  String get vaultRole => '保险库角色';

  @override
  String get vaultStatesRefreshedFromTheServer => '已从服务器刷新保险库状态。';

  @override
  String get vaultSyncIsUnreachableThisConfirmation =>
      '保险库同步不可达。此确认会将首次出现的指纹作为加密记录在此设备上排队；在保险库同步确认之前，当前 SSH 连接将停止。离线期间无法检查其他设备的批准和撤销。';

  @override
  String vaultVaultid(String vaultId) {
    return '保险库 $vaultId';
  }

  @override
  String get vaultConflictResolved => 'Vault 冲突已解决';

  @override
  String get vaultDeletionCancelled => 'Vault 删除已取消';

  @override
  String get vaultDeletionScheduled => 'Vault 删除已安排';

  @override
  String get vaultEncryptedDataSynced => 'Vault 加密数据已同步';

  @override
  String get vaultKeyGeneration => 'Vault 密钥代次';

  @override
  String get vaultKeyRotated => 'Vault 密钥已轮换';

  @override
  String get vaultCreated => 'Vault 已创建';

  @override
  String get vaultPurged => 'Vault 已清理';

  @override
  String get vaultOwnershipTransferred => 'Vault 所有权已转移';

  @override
  String get vaultScopedAuditIsAvailableOnly =>
      'Vault 范围审计仅对当前 Vault 的 Owner 和 Editor 开放；当前权限不会返回 Vault 事件。';

  @override
  String get vaultSyncedPreferences => '随保险库同步的偏好';

  @override
  String vaultVaultid2(String vaultId) {
    return '保险库：$vaultId';
  }

  @override
  String vaultVaultname(String vaultName) {
    return '保险库：$vaultName';
  }

  @override
  String get vaults => '保险库';

  @override
  String verifiedCapabilitiesReportRevisionRevisionRecord(
    int revision,
    int maxRecordSchema,
    String attachmentVersions,
    String formatAdminBytes,
  ) {
    return '已验证的能力 · 报告修订版本 $revision\n记录架构 ≤ $maxRecordSchema · 附件格式 $attachmentVersions · 附件上限 $formatAdminBytes';
  }

  @override
  String verifiedRevisionsRecordcount(int recordCount) {
    return '已验证的修订版本：$recordCount';
  }

  @override
  String get verifySshHostKey => '验证 SSH 主机密钥';

  @override
  String get verifyAndDiscard => '验证并丢弃';

  @override
  String get verifyAndReview => '验证并检查';

  @override
  String get verifyArchive => '验证归档';

  @override
  String viaJumpHostJumphostname(Object jumpHostName) {
    return '通过跳板主机：$jumpHostName';
  }

  @override
  String get viewVaultMembers => '查看保险库成员';

  @override
  String get viewCommandHistory => '查看命令历史';

  @override
  String get viewSessions => '查看会话';

  @override
  String get viewerReadOnlyVaultAccess => '查看者 · 保险库只读访问';

  @override
  String get workspace2 => '工作区';

  @override
  String get waitForVaultSyncOrRecovery => '更改成员前请等待保险库同步或恢复完成。';

  @override
  String get waitForVaultSynchronizationOrRecovery => '请等待保险库同步或恢复完成。';

  @override
  String get waitingForRemoteCopy => '等待远程复制';

  @override
  String get waitingToSync => '等待同步';

  @override
  String get webApplicationUpdates => 'Web 应用更新';

  @override
  String get wholeHoursFrom1To720 => '1 到 720 之间的整小时数';

  @override
  String get withdrawConsent => '撤回同意';

  @override
  String get workspace3 => '工作区';

  @override
  String get workspaceActions => '工作区操作';

  @override
  String get workspaceName => '工作区名称';

  @override
  String get workspaceSavedEncryptedToThisVault => '工作区已加密保存到此保险库。';

  @override
  String get youHaveReadOnlyAccessTo => '你对此保险库只有只读访问权限。';

  @override
  String get activePane2 => '活动窗格';

  @override
  String get eGGrep => '例如 grep';

  @override
  String get redactedDraft => '已脱敏的草稿';

  @override
  String actionFriendlyerror(String action, String friendlyError) {
    return '$action：$friendlyError';
  }

  @override
  String countGroupParentRelationshipSAre(int count) {
    return '有 $count 个分组父级关系缺失或形成循环。请编辑受影响的分组并选择有效的父级或顶级分组。';
  }

  @override
  String countHosts(int count) {
    return '$count 台主机';
  }

  @override
  String countOfCount2VaultKeyContexts(int count, int count2) {
    return '$count2 个保险库密钥上下文中有 $count 个具有恢复盒。';
  }

  @override
  String countSuggestions(int count) {
    return '$count 条建议';
  }

  @override
  String countTabs(int count) {
    return '$count 个标签页';
  }

  @override
  String countTargetSReportedAKnown(
    int count,
    int count2,
    int count3,
    int count4,
  ) {
    return '$count 个目标报告了已知结果；$count2 个远程完成情况未知；$count3 个在派发前停止；$count4 个未开始。';
  }

  @override
  String countPendingReview(int count) {
    return '$count 待审阅';
  }

  @override
  String displaynameAndItsEncryptedPayloadsWill(String displayName) {
    return '$displayName 及其加密载荷将从服务器的活动状态中移除。此操作无法在应用中撤销。';
  }

  @override
  String displaynameWillBeRestoredFromIts(String displayName) {
    return '$displayName 将从其最后一个已验证的活动修订版本恢复。只有当匹配的删除标记仍是服务器当前头部时才会成功。';
  }

  @override
  String filenameWillBeRemovedFromThe(String filename) {
    return '$filename 将从远程主机中移除。';
  }

  @override
  String itemSigningKeyShortkey(Object item, String shortKey) {
    return '$item\n签名密钥 · $shortKey';
  }

  @override
  String labelforIdSubstringDeletedFormat(
    String labelFor,
    String substring,
    String format,
  ) {
    return '$labelFor · ID $substring · 删除于 $format';
  }

  @override
  String membercountMembersValuevalueRevisionRevision(
    int memberCount,
    String valueValue,
    int revision,
  ) {
    return '$memberCount 名成员 · $valueValue · 修订版本 $revision';
  }

  @override
  String missingcountMissing(int missingCount) {
    return '缺少 $missingCount 项';
  }

  @override
  String nameWillLoseAccountAccessAnd(String name) {
    return '$name 将失去账户访问权限，其活动会话将被撤销。';
  }

  @override
  String nameValuevaluePasswordHiddenFromPreview(
    String name,
    String valueValue,
  ) {
    return '$name：$valueValue · 密码已在预览中隐藏';
  }

  @override
  String pendingcountEncryptedLocalChangeSAre(int pendingCount) {
    return '仍有 $pendingCount 项加密的本地更改在发件箱中。保险库只读期间它们不会被推送；它们保留在此浏览器中，只有在截止时间前取消删除才能继续同步。';
  }

  @override
  String roleKeyEpochActivekeyepochMembershipMembershipversion(
    String role,
    String activeKeyEpoch,
    String membershipVersion,
  ) {
    return '$role · 密钥纪元 $activeKeyEpoch · 成员资格 $membershipVersion';
  }

  @override
  String tolocalExitExitstatus(DateTime toLocal, int exitStatus) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$toLocalString · 退出码 $exitStatus';
  }

  @override
  String unavailablerecordcountEncryptedRecordSCouldNot(
    int unavailableRecordCount,
  ) {
    return '有 $unavailableRecordCount 条加密记录无法使用当前保险库密钥/设备目录验证，或无法解码为受支持的记录。它们的密文仍保存在本地，并已从受信任数据中隐藏。';
  }

  @override
  String unresolvedconflictcountNeedsReview(int unresolvedConflictCount) {
    return '$unresolvedConflictCount 项待检查';
  }

  @override
  String valuevalueMoreDeviceSNeedReview(int valueValue) {
    return '还有 $valueValue 台设备需要检查。';
  }

  @override
  String valuevalueUsernameAndRotateTheVault(
    String valueValue,
    String username,
  ) {
    return '$valueValue $username 并为每台剩余的活动成员设备轮换保险库密钥？被移除的账户不会获得新密钥。现有的旧副本无法被远程擦除。其他待处理的邀请令牌将失效，需要重新签发。';
  }

  @override
  String get configuredMeansThisServerProcessLoaded =>
      '“已配置”表示此服务器进程已加载提供方适配器，并不确认连通性或工作进程是否存活。推送只是尽力而为的唤醒提示，不能证明已送达或已同步；经过认证的 WebSocket 或轮询仍是事实依据。';

  @override
  String get previousPage => '上一页';

  @override
  String lastArchiveVerificationFailedAtArchivefailurephase(
    Object archiveFailurePhase,
  ) {
    return '上次归档验证失败阶段：$archiveFailurePhase';
  }

  @override
  String get nextPage => '下一页';

  @override
  String get doesntExist => '不存在';

  @override
  String get masterPasswordChanged => '主密码已更改';

  @override
  String get couldntChangeTheMasterPassword => '主密码更改失败';

  @override
  String get hosts => '主机';

  @override
  String get onlyTheHostIdTabOrder =>
      '仅同步 Host ID、标签顺序、双窗格方向与分割比例。凭据、运行中的 SSH 会话、终端输出、SFTP 路径和文件状态不会写入工作区记录。';

  @override
  String get retryFromTheFirstPage => '从第一页重试';

  @override
  String get saveAndConnect => '保存并连接';

  @override
  String get saveCurrentWindowLayout => '保存当前窗口布局';

  @override
  String get saveTheCurrentTerminalTabsTo => '保存当前终端标签后，可在其他授权设备上预览同一布局。';

  @override
  String get keepTheCurrentCommittedVersion => '保留当前已提交版本？';

  @override
  String get keepCurrentVersion => '保留当前版本';

  @override
  String get couldntKeepTheCurrentVersion => '保留当前版本失败';

  @override
  String get vaultsAndMembers => '保险库与成员';

  @override
  String get change => '修改';

  @override
  String get openOneOrMoreTabsOn => '先在 Terminal 页面打开一个或多个标签，再保存为命名布局。';

  @override
  String get conflictResolved => '冲突已解决。';

  @override
  String get setTheTerminalFontSizeColors2 => '分别设置终端字号、配色和快捷键，随当前保险库同步。';

  @override
  String get branchsOriginalBase => '分支原始基线';

  @override
  String get branchNotVerifiedYetKeptRead => '分支尚未通过验证，只读保留';

  @override
  String get branchSavedOnThisDeviceWaiting => '分支已保存在本设备，等待同步确认。';

  @override
  String get branchSavedEncryptedOnThisDevice => '分支已加密保存在本设备，等待同步确认。';

  @override
  String branchSequenceSeqValuevalue(String seq, String valueValue) {
    return '分支序号 $seq · $valueValue';
  }

  @override
  String get branchActions => '分支操作';

  @override
  String get branchVersion => '分支版本';

  @override
  String get groupLayoutReset => '分组布局已重置。';

  @override
  String get refresh => '刷新';

  @override
  String get encryptedSessionUnlocked => '加密会话已解锁';

  @override
  String get namedTerminalLayoutsSyncEncryptedIncluding =>
      '加密同步命名终端布局，包括标签顺序或双窗格方向与分割比例。预览不会建立连接；每个窗格都要单独确认 Connect。';

  @override
  String get encryptedBackupJobSubmitted => '加密备份任务已提交';

  @override
  String get readOnlyViewOfCommittedAccount =>
      '只读查看已提交的账户与当前 Vault 管理操作；不会记录 SSH 命令、主机名或凭据。';

  @override
  String get syncAndConflicts => '同步与冲突';

  @override
  String get snippets => '命令片段';

  @override
  String get completedCommandsAreRecordedAfterEnabling2 =>
      '在“记录设置”启用 Bash 集成后记录完成的命令；密码提示中的输入不会被采集。';

  @override
  String get working => '处理中…';

  @override
  String get backupRestoreAndMaintenance => '备份、恢复与维护';

  @override
  String get backupCompleted => '备份已完成';

  @override
  String get multiFactorRecoveryCodesRotated => '多重身份验证恢复代码已轮换';

  @override
  String get instanceOverview => '实例概览';

  @override
  String get instanceAdminInvitationRevoked => '实例管理员邀请已撤销';

  @override
  String get instanceAdminInvitationIssued => '实例管理员邀请已签发';

  @override
  String get instanceMaintenanceJobSubmitted => '实例维护任务已提交';

  @override
  String get auditLog => '审计日志';

  @override
  String get auditRecords => '审计记录';

  @override
  String get importAndExportEncryptedArchivesOr => '导入导出加密归档，或迁移本地配置。';

  @override
  String get notVerifiedYet => '尚未验证';

  @override
  String get properties => '属性';

  @override
  String get workspace => '工作区';

  @override
  String get workspaceLayouts => '工作区布局';

  @override
  String get theCurrentWindowLayoutForThis => '已保存此分组的当前窗口布局。';

  @override
  String get multiFactorAuthenticationTurnedOff => '已关闭多重身份验证';

  @override
  String get memberInvitationCreated => '已创建成员邀请';

  @override
  String get deleted => '已删除';

  @override
  String deletedValuevalue(String valueValue) {
    return '已删除$valueValue';
  }

  @override
  String get bashRecordingIsOnUpTo => '已启用 Bash 记录，最多 500 条。点击填入，按 Enter 执行。';

  @override
  String get multiFactorAuthenticationEnabled => '已启用多重身份验证';

  @override
  String processedBranchesCount(int count) {
    return '已处理分支 · $count';
  }

  @override
  String get multiFactorSignInStarted => '已开始多重身份验证登录';

  @override
  String get committed => '已提交';

  @override
  String get committedAdminActionsAppearHereNew =>
      '已提交的管理操作会显示在这里。新事件不会插入正在浏览的分页游标。';

  @override
  String get sshRelayConnectionTicketIssued => '已签发 SSH Relay 连接票据';

  @override
  String get resolved => '已解决';

  @override
  String get signedOut => '已退出登录';

  @override
  String get multiFactorAuthenticationWasResetAfter => '归档恢复后已重置多重身份验证';

  @override
  String get currentVault3 => '当前 Vault';

  @override
  String get hostsCantBeAddedInThe => '当前工作区不能添加主机。';

  @override
  String showingEventsForCurrentvaultnameSwitchingThe(String currentVaultName) {
    return '当前显示 $currentVaultName 的事件。切换顶部 Vault 后会重新从第一页加载。';
  }

  @override
  String get currentServerVersion => '当前服务端版本';

  @override
  String get theCurrentServerVersionIsCommitted =>
      '当前服务端版本已提交。系统会将它记录为本次冲突的选择，不会重新上传旧分支，也不会创建新的记录版本。';

  @override
  String get theCurrentVersionChangedChooseAgain => '当前版本已变化，请重新选择';

  @override
  String get theCurrentVersionIsCommittedWaiting => '当前版本已提交，等待服务端确认冲突解决。';

  @override
  String get thisWindowHasNoSshLayout => '当前窗口没有可保存的 SSH 布局。';

  @override
  String get noAuditRecordsInTheCurrent => '当前范围暂无审计记录';

  @override
  String get yourCurrentRoleCantViewThe => '当前角色无法查看 Vault 审计';

  @override
  String get restore3 => '恢复';

  @override
  String get recoveryKeyDeviceEnvelopesUpdated => '恢复密钥设备封套已更新';

  @override
  String get succeeded => '成功';

  @override
  String get memberPermissionsChanged => '成员权限已更改';

  @override
  String get membershipVersion => '成员版本';

  @override
  String get memberAccessRevoked => '成员访问已撤销';

  @override
  String get memberInvitationAccepted => '成员邀请已接受';

  @override
  String get theSelectedBranchIsCommittedWaiting => '所选分支已提交，等待服务端确认冲突解决。';

  @override
  String get theSelectedVersionIsCommittedWaiting => '所选版本已提交，等待服务端确认冲突解决。';

  @override
  String get dataAndMigration => '数据与迁移';

  @override
  String get files => '文件';

  @override
  String get theHostSpecifiedByTheFile => '文件窗口指定的主机不可用。';

  @override
  String get fileManager => '文件管理';

  @override
  String get passwordsAndKeysForNewHosts2 => '新主机的密码和密钥在主机详情内设置。';

  @override
  String get newBranchesSyncAutomaticallyWithConflict =>
      '新分支会随冲突通知自动同步；也可以使用顶部“同步”操作检查服务端收件箱。';

  @override
  String get newLabel => '新建';

  @override
  String newTouppercaseHost(String toUpperCase) {
    return '新建 $toUpperCase 主机';
  }

  @override
  String get newWindow => '新窗口';

  @override
  String get theNewWindowWasntReadyThe => '新窗口未能就绪；原 SSH 会话保持连接。';

  @override
  String get theNewWindowWasntReadyThe2 => '新窗口未能就绪；远程桌面保留在当前窗口。';

  @override
  String couldntLoadTheVaultListError(String error) {
    return '无法加载 Vault 列表：$error';
  }

  @override
  String couldntLoadTheSessionListError(String error) {
    return '无法加载会话列表：$error';
  }

  @override
  String get couldntLoadBackupCommandStatus => '无法加载备份命令状态';

  @override
  String couldntLoadBackupCommandStatusError(String error) {
    return '无法加载备份命令状态：$error';
  }

  @override
  String get couldntLoadInstanceOverview => '无法加载实例概况';

  @override
  String couldntLoadInstanceOverviewError(String error) {
    return '无法加载实例概况：$error';
  }

  @override
  String get couldntLoadInstanceAdminAuditRecords => '无法加载实例管理员审计记录';

  @override
  String couldntLoadInstanceAdminAuditRecords2(String error) {
    return '无法加载实例管理员审计记录：$error';
  }

  @override
  String get couldntLoadAuditRecords => '无法加载审计记录';

  @override
  String get couldntLoadPushServiceStatus => '无法加载推送服务状态';

  @override
  String couldntLoadPushServiceStatusError(String error) {
    return '无法加载推送服务状态：$error';
  }

  @override
  String get couldntLoadTheAdminVaultList => '无法加载管理员 Vault 列表';

  @override
  String get couldntLoadTheAdminAccountList => '无法加载管理员账户列表';

  @override
  String get couldntLoadTheAccountSessionList => '无法加载账户会话列表';

  @override
  String couldntLoadTheAccountListError(String error) {
    return '无法加载账户列表：$error';
  }

  @override
  String get couldntLoadTheAccountInvitationList => '无法加载账户邀请列表';

  @override
  String couldntLoadTheInvitationListError(String error) {
    return '无法加载邀请列表：$error';
  }

  @override
  String get couldntOpenTheFileWindow => '无法打开文件窗口。';

  @override
  String get couldntSubmitTheEncryptedBackupJob => '无法提交加密备份任务';

  @override
  String couldntSubmitTheEncryptedBackupJob2(String error) {
    return '无法提交加密备份任务：$error';
  }

  @override
  String get couldntUpdateTheVaultQuota => '无法更新 Vault 配额';

  @override
  String couldntUpdateTheVaultQuotaError(String error) {
    return '无法更新 Vault 配额：$error';
  }

  @override
  String get unreadable => '无法读取';

  @override
  String get couldntReadOrSubmitInstanceJobs => '无法读取或提交实例任务';

  @override
  String couldntReadOrSubmitInstanceJobs2(String error) {
    return '无法读取或提交实例任务：$error';
  }

  @override
  String get legacySharedCredentials => '旧版共享凭据';

  @override
  String missingPlural11MonitorWindow(int missing) {
    return '有 $missing 个显示器窗口未能打开，可再次选择重试。';
  }

  @override
  String get theServerProvidedASignedCleanup =>
      '服务器已为此记录提供签名清理凭证。本机保留的待同步修改已隔离为只读草稿；为避免重新创建已清理的记录，不能在此保留、合并或上传该草稿。';

  @override
  String get theServerMarksTheCurrentCommitted =>
      '服务端会将当前已提交版本标记为保留，不创建新的主记录版本。跨设备分支会继续作为已处理历史保留。';

  @override
  String get serverBranch => '服务端分支';

  @override
  String get theServerPageContainsSeveralVisible =>
      '服务端分页包含多个可见范围；继续翻页以查找当前范围的事件。';

  @override
  String get unknownAction => '未知操作';

  @override
  String get unknownResult => '未知结果';

  @override
  String get unknownDevice => '未知设备';

  @override
  String get localStorageNeedsRecoveryReadingEditing =>
      '本地存储状态需要恢复。读取、修改和同步已暂停；请关闭所有 Atermius 标签页后重新打开，以恢复最后一次持久化的数据。';

  @override
  String get notCommittedLocally => '本地未提交';

  @override
  String get noEventsInThisScopeOn => '本页暂无此范围的事件';

  @override
  String get sourceDevice => '来源设备';

  @override
  String get viewInstanceAndPushServiceStatus => '查看实例和推送服务状态，管理监控凭据。';

  @override
  String get viewTheCurrentAccountDevicesAnd => '查看当前账户、设备和服务端信息。';

  @override
  String get reviewInstanceActionsAndAccessAudit => '检查实例操作和访问审计记录。';

  @override
  String get reviewTrustedHostKeysAndTheir => '检查已信任的主机密钥及其变更。';

  @override
  String get refreshCredentialReplayDetectedTheRelated => '检测到刷新凭据重放，相关会话已撤销';

  @override
  String get readingVaultList => '正在读取 Vault 列表…';

  @override
  String get readingInstanceJobs => '正在读取实例任务…';

  @override
  String get readingInstanceOverview => '正在读取实例概况…';

  @override
  String get readingInstanceAdminAuditRecords => '正在读取实例管理员审计记录…';

  @override
  String get readingAuditRecords => '正在读取审计记录…';

  @override
  String get readingOffSiteBackupStatus => '正在读取异地备份状态…';

  @override
  String get readingPushServiceStatus => '正在读取推送服务状态…';

  @override
  String get readingTheLatestBackupCommandStatus => '正在读取最近一次备份命令状态…';

  @override
  String get readingAdminAccountList => '正在读取管理员账户列表…';

  @override
  String get thisGroupHasNoConnectableSsh => '此分组没有可连接的 SSH 主机。';

  @override
  String get eachGroupLayoutCanConnectUp => '每组布局最多连接 32 台主机，请拆分分组后重试。';

  @override
  String get noPendingCrossDeviceBranches => '没有待处理的跨设备分支';

  @override
  String get browseFiles => '浏览文件';

  @override
  String get addGroup => '添加分组';

  @override
  String get versionCommittedWaitingForTheServer => '版本已提交，等待服务端确认解决';

  @override
  String get signInFailed => '登录失败';

  @override
  String get signedIn => '登录成功';

  @override
  String get confirmKeptVersion => '确认保留版本';

  @override
  String get windowSetSavedEncrypted => '窗口组合已加密保存。';

  @override
  String windowSetOpenedCountCount2Sessions(
    int count,
    int count2,
    int failures,
  ) {
    return '窗口组合已打开 $count/$count2 个会话；$failures 个未能连接。';
  }

  @override
  String pageValuevalue2(int valueValue) {
    return '第 $valueValue 页';
  }

  @override
  String get waitingForThisDeviceToSync => '等待本设备同步所选版本';

  @override
  String get manageTheMasterPasswordTwoFactor => '管理主密码、双重验证、恢复方式和账户删除。';

  @override
  String get manageVaultsMembersAndInvitations => '管理保险库、成员和邀请。';

  @override
  String get adminBackupFailed => '管理员备份失败';

  @override
  String get adminBackupInterrupted => '管理员备份已中断';

  @override
  String get adminBackupCompleted => '管理员备份已完成';

  @override
  String get adminBackupStarted => '管理员备份已开始';

  @override
  String get anAdministratorDiscardedTheIsolatedRestore => '管理员已丢弃隔离还原副本';

  @override
  String get anAdministratorDisabledTheAccount => '管理员已停用账户';

  @override
  String get anAdministratorCreatedAnSshRelay => '管理员已创建 SSH Relay 访问组';

  @override
  String get anAdministratorDeletedAnSshRelay => '管理员已删除 SSH Relay 访问组';

  @override
  String get anAdministratorEnabledTheAccount => '管理员已启用账户';

  @override
  String get anAdministratorRevokedThePrometheusScrape =>
      '管理员已撤销 Prometheus 抓取凭据';

  @override
  String get anAdministratorRevokedAnAccountSession => '管理员已撤销账户会话';

  @override
  String get anAdministratorRevokedAllOfThe => '管理员已撤销账户的全部会话';

  @override
  String get anAdministratorChangedSshRelayAccess => '管理员已更改 SSH Relay 访问组成员';

  @override
  String get anAdministratorChangedTheSshRelay => '管理员已更改 SSH Relay 访问组策略';

  @override
  String get anAdministratorChangedTheVaultQuota => '管理员已更改 Vault 配额';

  @override
  String get anAdministratorChangedTheScheduledBackup => '管理员已更改计划备份';

  @override
  String get anAdministratorUpdatedTheSshRelay => '管理员已更新 SSH Relay 策略';

  @override
  String get anAdministratorRequestedABackup => '管理员已请求备份';

  @override
  String get anAdministratorRequestedARestoreJob => '管理员已请求恢复任务';

  @override
  String get anAdministratorRequestedAMaintenanceJob => '管理员已请求维护任务';

  @override
  String get anAdministratorRotatedThePrometheusScrape =>
      '管理员已轮换 Prometheus 抓取凭据';

  @override
  String get anAdministratorRenamedAnSshRelay => '管理员已重命名 SSH Relay 访问组';

  @override
  String get anAdministratorResetTheSshRelay => '管理员已重置 SSH Relay 访问组策略';

  @override
  String get adminRestoreJobFailed => '管理员恢复任务失败';

  @override
  String get adminRestoreJobInterrupted => '管理员恢复任务已中断';

  @override
  String get adminRestoreJobCompleted => '管理员恢复任务已完成';

  @override
  String get adminRestoreJobStarted => '管理员恢复任务已开始';

  @override
  String get adminMaintenanceJobFailed => '管理员维护任务失败';

  @override
  String get adminMaintenanceJobInterrupted => '管理员维护任务已中断';

  @override
  String get adminMaintenanceJobCompleted => '管理员维护任务已完成';

  @override
  String get adminMaintenanceJobStarted => '管理员维护任务已开始';

  @override
  String get adminAccountActionFailed => '管理员账户操作失败';

  @override
  String get adminAccountInvitationActionFailed => '管理员账户邀请操作失败';

  @override
  String get manageBackupsAndRestoreCopiesAnd => '管理备份和恢复副本，检查实例维护任务。';

  @override
  String get manageInstanceAccountsInvitationsRelayGroups =>
      '管理实例账户、邀请、中继组及连接策略。';

  @override
  String get manageNotificationsAndClientUpdates => '管理通知和客户端更新。';

  @override
  String get theBranchAndTheCurrentRecord =>
      '系统会校验分支和当前记录，再由这台设备重新签名并同步。原有加密分支会保留。';

  @override
  String get terminal2 => '终端';

  @override
  String get terminalAndShortcuts => '终端与快捷键';

  @override
  String get maintenanceJobs => '维护任务';

  @override
  String get editGroup => '编辑分组';

  @override
  String get letExternalAiAccessTheCurrent2 => '让外部 AI 接入当前工作区。';

  @override
  String get theRecordChangedAgainDuringCommit => '记录在提交期间再次变化，请检查当前版本后重新选择。';

  @override
  String get theRecordChangedCheckTheCurrent => '记录已变化，请检查当前版本后重新选择。';

  @override
  String get devices => '设备';

  @override
  String get deviceApproved2 => '设备已批准';

  @override
  String get deviceRevoked => '设备已撤销';

  @override
  String get settings => '设置';

  @override
  String get account2 => '账户';

  @override
  String accountShortauditidDeviceShortauditid2Valuevalue(
    String shortAuditId,
    String shortAuditId2,
    String valueValue,
  ) {
    return '账户 $shortAuditId  ·  设备 $shortAuditId2  ·  $valueValue';
  }

  @override
  String get accountAndDeviceInformation => '账户与设备信息';

  @override
  String get accountsAndAccessPolicies => '账户与访问策略';

  @override
  String get accountEventsAreStillVisibleOnly =>
      '账户事件仍可查看。只有该 Vault 的 Owner 和 Editor 能查看 Vault 范围记录。';

  @override
  String get accountSessionUnlocked => '账户会话已解锁';

  @override
  String get accountCreated => '账户创建';

  @override
  String get accountSecurity => '账户安全';

  @override
  String get multiFactorAuthenticationWasResetAfter2 => '账户恢复后已重置多重身份验证';

  @override
  String get accountRecoveryKeyRotated => '账户恢复密钥已轮换';

  @override
  String get accountRecoveryDisabled => '账户恢复已关闭';

  @override
  String get accountRecoveryEnabled => '账户恢复已启用';

  @override
  String get accountRecoveryCompleted => '账户恢复已完成';

  @override
  String accountActionFailedError(String error) {
    return '账户操作失败：$error';
  }

  @override
  String get accountDataCleared => '账户数据已清理';

  @override
  String get accountDeletionCancelled => '账户注销已取消';

  @override
  String get accountDeletionScheduled => '账户注销已安排';

  @override
  String get crossDeviceConflictInbox => '跨设备冲突收件箱';

  @override
  String get theCrossDeviceBranchIsntVerified => '跨设备分支尚未通过验证；操作和服务端版本详情已隐藏。';

  @override
  String get thisDeviceDecryptsTheVerifiedBranch =>
      '这台设备会解密已验证分支，并以当前设备身份重新签名，再针对目前已缓存版本执行 CAS 提交。原分支密文会保留；提交或服务端解决确认前，收件箱仍显示此冲突。';

  @override
  String get concurrentBranchesSubmittedToTheServer =>
      '这里显示其他设备提交到服务端的并发分支。只有签名、Vault 归属和密钥代次验证通过后才能选择；查看收件箱不会改写当前记录。';

  @override
  String get remoteDesktop2 => '远程桌面';

  @override
  String get connect2 => '连接';

  @override
  String get connectEverySshHostInThe => '连接分组内全部 SSH 主机并恢复布局';

  @override
  String get chooseTheWorkspaceModeAndThe2 => '选择工作模式和默认打开的页面。';

  @override
  String get choiceSavedOnThisDeviceWaiting => '选择已保存在本设备，等待同步确认。';

  @override
  String get choiceSavedTheInboxUpdatesAfter => '选择已保存；收件箱将在下一次同步后更新。';

  @override
  String get choiceSavedEncryptedOnThisDevice => '选择已加密保存在本设备，等待同步确认。';

  @override
  String get choiceSavedEncryptedOnThisDevice2 => '选择已加密保存在本设备，等待同步；网络恢复后可重试。';

  @override
  String get notificationsAndUpdates => '通知与更新';

  @override
  String invitationActionFailedError(String error) {
    return '邀请操作失败：$error';
  }

  @override
  String get couldntAdoptTheBranch => '采用分支失败';

  @override
  String get adoptTheVerifiedDeviceBranch => '采用已验证的设备分支？';

  @override
  String get adoptThisBranch => '采用此分支';

  @override
  String get reSignAndSync => '重新签名并同步';

  @override
  String get resetLayout => '重置布局';

  @override
  String get attachments => '附件';

  @override
  String get needsANewChoice => '需重新选择';

  @override
  String get aDeviceKeyPairIsGenerated => '设备密钥对仅在此浏览器中生成并保存。请将公开申请发送到已获批准的设备。';

  @override
  String get aPrivateSshWorkspaceThatSyncs =>
      '私有 SSH 工作区，在你的设备之间同步加密的连接、凭据和命令片段。';

  @override
  String get aTrustedDeviceSignsEnvelopesFor => '由受信任的设备为每台新设备签署信封。';

  @override
  String get accountEmail => '账户邮箱';

  @override
  String get accountName => '账户名';

  @override
  String get accountRecoveredSignInWithThe => '账户已恢复。请使用新的主密码登录。';

  @override
  String get accountRecoveredSignInWithYour => '账户已恢复。请使用新的主密码登录。';

  @override
  String get addThisDevice => '添加此设备';

  @override
  String get approveEveryDevice => '每台设备都需批准';

  @override
  String get cancelRecovery => '取消恢复';

  @override
  String get cancelScheduledAccountDeletion => '取消已计划的账户删除';

  @override
  String get cancelSignIn => '取消登录';

  @override
  String get changeServer => '更换服务器';

  @override
  String get commitRecovery => '提交恢复';

  @override
  String get confirmFingerprintAndContinue => '确认指纹并继续';

  @override
  String get confirmMasterPassword => '确认主密码';

  @override
  String get connectSecurely => '安全连接';

  @override
  String get connectToYourServer => '连接到你的服务器';

  @override
  String get copyThisEnrollmentJson => '复制此注册 JSON';

  @override
  String get createInvitedAccount => '创建受邀账户';

  @override
  String get createOwnerAccount => '创建所有者账户';

  @override
  String get deviceName => '设备名称';

  @override
  String get emailOnTheInvitation => '邀请中的邮箱';

  @override
  String get emailOrUsername => '邮箱或用户名';

  @override
  String get encryptedOutboxKeepsEditsSafeBetween => '加密发件箱可在连接间隙安全保留编辑。';

  @override
  String get endToEndEncryptedVault => '端到端加密保险库';

  @override
  String get enterAValidRecoveryCodeAnd => '请输入有效的恢复码和匹配的新主密码。';

  @override
  String get enterTheUrlOfYourSelf => '输入你的自托管 Atermius 实例的 URL。';

  @override
  String get fingerprintReturnedByThisServerSha => '此服务器返回的指纹 · SHA-256';

  @override
  String fingerprintReturnedByThisServerSha2(String candidateFingerprint) {
    return '此服务器返回的指纹 · SHA-256：$candidateFingerprint';
  }

  @override
  String get firstVault => '第一个保险库';

  @override
  String get generateRequest => '生成申请';

  @override
  String get haveAnInstanceInvitationCreateAccount => '有实例邀请？创建账户';

  @override
  String get importApproval => '导入批准';

  @override
  String get importApprovedDevice => '导入已批准的设备';

  @override
  String get importDeviceKeys => '导入设备密钥';

  @override
  String get instanceInvitationToken => '实例邀请令牌';

  @override
  String get masterPassword => '主密码';

  @override
  String get masterPassword12Characters => '主密码 · 至少 12 个字符';

  @override
  String newAccountRecoveryCodeCode(String code) {
    return '新的账户恢复码：$code';
  }

  @override
  String get newDeviceName => '新设备名称';

  @override
  String get newMasterPassword12Characters => '新主密码 · 至少 12 个字符';

  @override
  String get offlineFirstSync => '离线优先同步';

  @override
  String get onlyYourUnlockedDevicesCanRead => '只有你已解锁的设备才能读取已保存的数据。';

  @override
  String get ownerEmail => '所有者邮箱';

  @override
  String get pasteApprovalJson => '粘贴批准 JSON';

  @override
  String get personalVault => '个人保险库';

  @override
  String get previouslyTrustedFingerprintSha256 => '之前信任的指纹 · SHA-256';

  @override
  String previouslyTrustedFingerprintSha256Pinnedfingerprint(
    String pinnedFingerprint,
  ) {
    return '之前信任的指纹 · SHA-256：$pinnedFingerprint';
  }

  @override
  String get recoverAccount => '恢复账户';

  @override
  String get recoverAccountWithRecoveryCode => '使用恢复码恢复账户';

  @override
  String get recoveredDevice => '已恢复的设备';

  @override
  String get recoveryCode => '恢复码';

  @override
  String get recoveryWasCancelledNoAccountChanges => '恢复已取消。未提交任何账户更改。';

  @override
  String get remoteServersRequireHttpsHttpIs =>
      '远程服务器必须使用 HTTPS。仅 localhost、127.0.0.1 或 ::1 开发环境允许 HTTP。';

  @override
  String get requestThisDevice => '申请添加此设备';

  @override
  String get restoredServerIdentityNeedsConfirmation => '已恢复的服务器身份需要确认';

  @override
  String get retryRecoveryCompletion => '重试完成恢复';

  @override
  String get selfHosted => '自托管';

  @override
  String get secretsAreEncryptedInThisClient => '机密信息在同步前已在此客户端加密。';

  @override
  String get serverUrl => '服务器 URL';

  @override
  String get setUpYourPrivateVault => '设置你的私有保险库';

  @override
  String get signInAndUnlock => '登录并解锁';

  @override
  String get storeTheNewRecoveryCode => '保存新的恢复码';

  @override
  String get theBootstrapTokenIsOneUse => '引导令牌只能使用一次。服务器永远不会收到你的主密码或生成的保险库密钥。';

  @override
  String get theFirstAccountCreatesItsVault => '第一个账户会在此设备上创建其保险库密钥。';

  @override
  String get theServerReturnedADifferentSigning =>
      '服务器为同一实例返回了不同的签名密钥。请通过独立渠道与管理员或另一台受信任设备比较候选指纹。确认前不会发送任何账户登录或认证请求。';

  @override
  String get thisOneUseInvitationIsBound =>
      '此一次性邀请绑定到上方显示的邮箱。服务器永远不会收到你的主密码或生成的保险库密钥。';

  @override
  String get thisReplacesTheOldCodeStore => '这会替换旧代码。请将其保存在此设备之外；它无法再次显示。';

  @override
  String get typeTheCandidateFingerprintExactly => '准确输入候选指纹';

  @override
  String get unlockYourWorkspace => '解锁你的工作区';

  @override
  String get useARecoveryCode => '使用恢复码';

  @override
  String get useAuthenticatorCode => '使用验证器代码';

  @override
  String get useTheAccountNameAndMaster => '使用账户名和主密码。此恢复不会恢复会话，之后请重新登录。';

  @override
  String get useTheSaved256BitRecovery =>
      '使用已保存的 256 位恢复码恢复保险库密钥访问并注册此设备。请设置新的主密码。服务器永远不会收到恢复码或明文保险库密钥。';

  @override
  String get verifyAndUnlock => '验证并解锁';

  @override
  String get verifyRecoveryCode => '验证恢复码';

  @override
  String get verifyYourIdentity => '验证你的身份';

  @override
  String get yourPasswordUnlocksTheAccountKey => '你的密码会在本地解锁账户密钥。';

  @override
  String get yourServersYourKeysYourWorkspace => '你的服务器。\n你的密钥。\n你的工作区。';

  @override
  String get theMasterPasswordsDontMatch => '两次输入的主密码不一致';

  @override
  String get couldntCancelAccountDeletion => '撤销账户删除失败';

  @override
  String get couldntConnectToTheServer => '无法连接到服务端';

  @override
  String get registrationFailed => '注册失败';

  @override
  String get requestJsonCopied => '申请 JSON 已复制';

  @override
  String get browserStorage => '浏览器存储';

  @override
  String get checkAgain => '重新检查';

  @override
  String get checkingPersistentStorage => '正在检查持久存储…';

  @override
  String get checkingStorageUsageEstimate => '正在检查存储用量估计…';

  @override
  String estimatedUsageFormatbytesOfFormatbytes2For(
    String formatBytes,
    String formatBytes2,
  ) {
    return '此站点的估计用量：$formatBytes，共 $formatBytes2';
  }

  @override
  String get persistentStorageCanReduceAutomaticEviction =>
      '持久存储可减少被自动清除的可能，但不能替代备份。';

  @override
  String get persistentStorageIsEnabled => '已启用持久存储';

  @override
  String get persistentStorageIsNotEnabled => '未启用持久存储';

  @override
  String get persistentStorageStatusIsUnavailable => '持久存储状态不可用';

  @override
  String get requestPersistentStorage => '请求持久存储';

  @override
  String get storageUsageEstimateIsUnavailable => '存储用量估计不可用';

  @override
  String get theBrowserCouldNotConfirmPersistent => '浏览器无法确认持久存储状态。';

  @override
  String get theBrowserCurrentlyReportsPersistentStorage => '浏览器当前报告已启用持久存储。';

  @override
  String get theBrowserDidNotEnablePersistent => '浏览器未启用持久存储。';

  @override
  String get theRequestReturnedSuccessButThe => '请求返回成功，但浏览器仍报告存储不是持久的。';

  @override
  String get theRequestReturnedSuccessButThe2 => '请求返回成功，但无法验证当前的持久化状态。';

  @override
  String pendingcountEncryptedChangeSAreWaiting(int pendingCount) {
    return '$pendingCount 项加密更改正在此浏览器的本地发件箱中等待。服务器尚未确认；如在同步前清除此站点的浏览器数据，这些更改将从此浏览器中移除。';
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
  String get fileWorkspaceIsClosed => '文件工作区已关闭。';

  @override
  String get theSavedGroupLayoutIsInvalid => '保存的分组布局无效，请重置布局后重试。';

  @override
  String get invalidGroupSessionMapping => '分组会话映射无效。';

  @override
  String get aGroupLayoutNeeds1To => '分组布局需要 1 到 32 个 SSH 主机。';

  @override
  String get invalidLayoutHostsOrMoreThan => '布局主机无效或超过 32 个窗格。';

  @override
  String get invalidLayoutRatio => '布局比例无效。';

  @override
  String get thisWindowHasNoSshSessions => '当前窗口没有此分组的 SSH 会话。';

  @override
  String get upTo32PanesCanBe => '最多保存 32 个窗格。';

  @override
  String get attachFile => '附加文件';

  @override
  String get attachmentDownload => '附件下载';

  @override
  String get attachmentUpload => '附件上传';

  @override
  String attachmentsName(String name) {
    return '附件 · $name';
  }

  @override
  String get cancel2 => '取消';

  @override
  String get chooseAFileToAttach => '选择要附加的文件…';

  @override
  String get close => '关闭';

  @override
  String get discardDownloadedCopy => '丢弃已下载的副本';

  @override
  String get discardOrphanTransfer => '丢弃孤立传输';

  @override
  String get downloadAttachment => '下载附件';

  @override
  String downloadUnavailableAboveFormatsize(String formatSize) {
    return '超过 $formatSize 时无法下载';
  }

  @override
  String get downloadingAndVerifyingAttachment => '正在下载并验证附件…';

  @override
  String get encryptingAndTransferring => '正在加密并传输…';

  @override
  String get filesAreEncryptedOnThisDevice =>
      '文件在上传前已在此设备加密。名称、类型、文件密钥和文件内容都保存在加密的主机记录中。';

  @override
  String get noAttachmentsSavedForThisHost => '此主机尚未保存附件。';

  @override
  String get preparingAttachment => '正在准备附件…';

  @override
  String get removeAttachment => '移除附件';

  @override
  String get removeAttachmentFromThisHost => '要从此主机移除附件吗？';

  @override
  String get removeFromHost => '从主机移除';

  @override
  String removeFilenameFromTheCurrentEncrypted(String fileName) {
    return '要从当前加密主机记录中移除 $fileName 吗？在服务器保留期清理之前，较早的主机修订版本可能仍保留其附件引用。';
  }

  @override
  String get removingAttachment => '正在移除附件…';

  @override
  String get resumeDownload => '继续下载';

  @override
  String get resumeUpload => '继续上传';

  @override
  String get resumingEncryptedUpload => '正在继续加密上传…';

  @override
  String get saveCancelled => '已取消保存。';

  @override
  String get saveCancelledTheVerifiedEncryptedDownload =>
      '已取消保存。已验证的加密下载会保留以便重试。';

  @override
  String get savingDecryptedAttachment => '正在保存解密后的附件…';

  @override
  String get thisFileCannotBeLoadedInto => '无法将此文件加载到客户端内存中。请尝试较小的文件。';

  @override
  String get transferTasks => '传输任务';

  @override
  String valuevalueMoreTasks(int valueValue) {
    return '还有 $valueValue 个任务';
  }

  @override
  String get addAHost => '添加主机';

  @override
  String get authentication => '认证';

  @override
  String get directConnection => '直接连接';

  @override
  String get displayName => '显示名称';

  @override
  String get editHost => '编辑主机';

  @override
  String get editPrivateKey => '编辑私钥';

  @override
  String get group => '分组';

  @override
  String get hidePrivateKey => '隐藏私钥';

  @override
  String get hostnameOrIp => '主机名或 IP';

  @override
  String get jumpHost => '跳板主机';

  @override
  String get loginDetailsBelongToThisHost => '登录信息属于此主机，并与其一起加密。';

  @override
  String get noGroup => '无分组';

  @override
  String get noKeyEntered => '未输入密钥';

  @override
  String get pinTheCertificateFingerprintSuppliedBy => '固定管理员提供的证书指纹。';

  @override
  String get rdpCertificateSha256Optional => 'RDP 证书 SHA-256（可选）';

  @override
  String get routeThroughUpTo8Hosts => '打开此主机前，最多经由 8 台主机路由。';

  @override
  String get saveEncryptedHost => '保存加密主机';

  @override
  String get separateTagsWithCommas => '用逗号分隔标签。';

  @override
  String get tags => '标签';

  @override
  String get thisSavedGroupIsUnavailableChoose => '此已保存的分组不可用。选择“无分组”以清除。';

  @override
  String get thisSavedJumpHostIsUnavailable =>
      '此已保存的跳板主机不可用、形成循环或超过 8 跳。请选择“直接连接”或有效的主机进行修复。';

  @override
  String get unavailableJumpHost => '不可用的跳板主机';

  @override
  String get signInDetailsAreStoredEncrypted =>
      '登录信息加密保存；连接时，受信任的远程桌面网关会处理登录凭据与画面。';

  @override
  String get directDesktopSignInHint => '登录信息加密保存；本设备直接连接主机，凭据仅用于该连接，不经过任何网关。';

  @override
  String labelPressEnterToConnect(String label) {
    return '$label  ·  回车连接';
  }

  @override
  String get searchHostsOrTypeAnSsh => '搜索主机，或输入 ssh / rdp / vnc / console 命令';

  @override
  String get clearSearch => '清空搜索';

  @override
  String get chooseAHostToConnectTo => '选择要连接的主机';

  @override
  String countHosts2(int count) {
    return '$count 台主机';
  }

  @override
  String get all => '全部';

  @override
  String get closeSearch => '关闭搜索';

  @override
  String get allGroups => '所有分组';

  @override
  String get filterByGroup => '按分组筛选';

  @override
  String get searchAndQuickConnect => '搜索与快捷连接';

  @override
  String get favorites => '收藏';

  @override
  String get noMatchingHostsTypeAnSsh => '没有匹配的主机，可输入 ssh / rdp / vnc 命令连接新地址。';

  @override
  String get operatingSystemNotIdentifiedYet => '尚未识别操作系统';

  @override
  String operatingSystemLabel(String label) {
    return '操作系统：$label';
  }

  @override
  String get originalSshSessionConnected => 'SSH 原会话 · 已连接';

  @override
  String get tools => '功能';

  @override
  String get originalSshSessionLive => '原 SSH 会话 · 实时连接';

  @override
  String get filesSftpScp => '文件 · SFTP / SCP';

  @override
  String get couldntOpenTheTerminalWindowGo => '无法打开终端窗口，请返回主窗口检查连接。';

  @override
  String get thisWindowKeepsUsingTheOriginal => '此窗口继续使用原有 SSH 会话。';

  @override
  String get terminalProperties => '终端属性';

  @override
  String get earlierOutputExceedsThisWindowsDisplay =>
      '较早输出超出此窗口的显示上限，正在运行的命令不受影响。';

  @override
  String get connectionLostReturnToTheOriginal => '连接中断 · 请返回原窗口';

  @override
  String get connectionLost => '连接已中断';

  @override
  String get sshOutputStreamError => '\r\n[SSH 输出流错误]\r\n';

  @override
  String get sshConnectionClosed => '\r\n[SSH 连接已关闭]\r\n';

  @override
  String get sshErrorStreamUnavailable => '\r\n[SSH 错误流不可用]\r\n';

  @override
  String get anotherOperationIsRunningRetryWhen => '另一个操作正在进行。请在其结束后重试。';

  @override
  String get bashInputHistory => 'Bash 输入历史';

  @override
  String get console => '控制台';

  @override
  String get couldNotSaveForwardingSettingsNothing => '无法保存转发设置；未做任何更改。';

  @override
  String get home => '主页';

  @override
  String hostHostid(String hostId) {
    return '主机 $hostId';
  }

  @override
  String get theHostSaveResultCouldntBe => 'Host 保存结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get theHostWasSavedButThe => 'Host 已保存，但列表刷新失败。请重试刷新列表。';

  @override
  String get theHostWasDeletedButThe => 'Host 已删除，但列表刷新失败。请重试刷新列表。';

  @override
  String get theHostWasChangedByAnother => 'Host 已在其他操作中更改，请重新打开后再试。';

  @override
  String get theHostWasUpdatedButThe => 'Host 已更新，但列表刷新失败。请重试刷新列表。';

  @override
  String get hostActions => 'Host 操作';

  @override
  String get whenAHostDoesntSelectA => 'Host 未显式选择凭据时，使用最近祖先分组的默认凭据。';

  @override
  String get localHostRevisionIsMissing => '缺少本地主机修订版本。';

  @override
  String get localDefaultWorkspacePreferenceIsInvalid => '本地默认工作区偏好无效。';

  @override
  String get localProfileCleanupFailed => '本地配置清理失败。';

  @override
  String get localvaultHostKeyTrust => 'LocalVault 主机密钥信任';

  @override
  String get noLocalProfile => '没有本地配置。';

  @override
  String get notStartedFromASingleConnected =>
      '未从单个已连接的 SSH 标签页启动。请在此编辑配置，然后在已连接的标签页中使用 SSH 端口转发启动它们。';

  @override
  String get preferencesCannotBeTheDefaultWorkspace => '偏好设置不能作为默认工作区。';

  @override
  String get profilesAreEncryptedInsideThisHost2 =>
      '配置在此设备本地配置的主机记录内加密。运行状态和套接字永远不会被保存。';

  @override
  String get protectedDeviceKeyUnavailable => '受保护的设备密钥不可用。';

  @override
  String get theSshHostKeyChangedOr => 'SSH 主机密钥已变化或信任记录冲突，连接已拒绝。请先检查并撤销旧信任。';

  @override
  String get theSshHostKeyWasntApproved => 'SSH 主机密钥未获批准，连接已拒绝。';

  @override
  String get sshPrivateKey => 'SSH 私钥';

  @override
  String get sshPortForwarding2 => 'SSH 端口转发';

  @override
  String get shellLabel => 'Shell 标签';

  @override
  String get snippetChanged => '片段已更改';

  @override
  String get theLocalProfileChanged => '本地配置已更改。';

  @override
  String get thisHostChangedInAnotherOperation => '此主机已在其他操作中更改。列表已刷新；请检查后重试。';

  @override
  String get webLocalvaultDoesntSupportSshSftp =>
      'Web LocalVault 暂不支持 SSH / SFTP';

  @override
  String algorithmFingerprintOriginallyApprovedInArchive(
    String algorithm,
    String fingerprint,
    DateTime toLocal,
  ) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$algorithm\n$fingerprint\n归档原审批：$toLocalString';
  }

  @override
  String groupparentlabelHostscountHostsChildrencountSubgroups(
    String groupParentLabel,
    int hostsCount,
    int childrenCount,
  ) {
    return '$groupParentLabel · $hostsCount 个 Host · $childrenCount 个子分组';
  }

  @override
  String hostPortPendingReview(String host, int port) {
    return '$host:$port · 待复核';
  }

  @override
  String nameWillBeDeletedFromThis(String name) {
    return '“$name”将从此本地配置中删除。';
  }

  @override
  String titleWillBeDeletedFromThis(String title) {
    return '“$title”将从此本地配置中删除。';
  }

  @override
  String get previousMatch2 => '上一个匹配项';

  @override
  String get nextMatch2 => '下一个匹配项';

  @override
  String get noDefaultCredential => '不设置默认凭据';

  @override
  String get theLocalArchivePassphrasesDontMatch => '两次输入的本地归档口令不一致。';

  @override
  String theMasterPasswordMustBeAt(int minimumPasswordLength) {
    return '主密码至少需要 $minimumPasswordLength 个字符。';
  }

  @override
  String get masterPasswordAtLeast12Characters => '主密码（至少 12 个字符）';

  @override
  String get hostsAndSignInDetailsAre => '主机与登录信息保存在本地配置';

  @override
  String get couldntSaveTheHostCheckThe => '主机保存失败，请检查配置后重试。';

  @override
  String get useTheModAltAndShift =>
      '使用 mod、alt、shift 修饰符；mod 在 Apple 平台表示 Command，在其他平台表示 Control。每个快捷键都必须唯一，浏览器和操作系统保留组合键不能使用。';

  @override
  String get saveGroup => '保存分组';

  @override
  String get saveEncryptedCredential => '保存加密凭据';

  @override
  String get saveEncryptedSnippet => '保存加密片段';

  @override
  String get saveShortcuts => '保存快捷键';

  @override
  String get theSavedGroupLayoutIsInvalid2 => '保存的分组布局无效，请先重置布局。';

  @override
  String get saveTerminalTheme => '保存终端主题';

  @override
  String get saveTerminalFontSize => '保存终端字号';

  @override
  String get saveDefaultWorkspace => '保存默认工作区';

  @override
  String get trustReviewFailedTheExistingSsh =>
      '信任复核失败。现有 SSH 信任状态未改变，请重新读取后检查。';

  @override
  String get thePreferenceSaveResultCouldntBe => '偏好保存结果无法确认。请先重试读取，再决定是否重新保存。';

  @override
  String get preferencesSavedAndApplied => '偏好已保存并应用。';

  @override
  String get preferencesAreSavedEncryptedInThis => '偏好已加密保存在此本地配置中。';

  @override
  String get preferencesWereChangedByAnotherOperation =>
      '偏好已被其他操作修改，已重新读取当前值。请确认后再保存。';

  @override
  String get stopConnecting => '停止连接';

  @override
  String get stopCapture => '停止采集';

  @override
  String get otherLocalRecords => '其他本地记录';

  @override
  String get credentials => '凭据';

  @override
  String get theCredentialSaveResultCouldntBe => '凭据保存结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get theCredentialDeletionResultCouldntBe =>
      '凭据删除结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String credentialParameterNameMustReferenceA(String name) {
    return '凭据参数 $name 必须引用此本地配置中的密码凭据。';
  }

  @override
  String get credentialName => '凭据名称';

  @override
  String get theCredentialNoLongerExistsRefresh => '凭据已不存在，请刷新列表。';

  @override
  String get theCredentialWasSavedButThe => '凭据已保存，但列表刷新失败。请重试刷新列表。';

  @override
  String get theCredentialWasDeletedButThe => '凭据已删除，但列表刷新失败。请重试刷新列表。';

  @override
  String get theCredentialWasChangedByAnother => '凭据已在其他操作中更改，请刷新列表后重试。';

  @override
  String get theCredentialWasUpdatedButThe => '凭据已更新，但列表刷新失败。请重试刷新列表。';

  @override
  String get credentialActions => '凭据操作';

  @override
  String get theCredentialUpdateResultCouldntBe => '凭据更新结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get setTheTerminalFontSizeColors => '分别设置终端字号、配色和快捷键。';

  @override
  String groupGroupid(String groupId) {
    return '分组 $groupId';
  }

  @override
  String groupName(String name) {
    return '分组“$name”';
  }

  @override
  String get theGroupIsStillUsedBy => '分组仍被子分组或 Host 使用。请先移动或删除这些记录，再删除该分组。';

  @override
  String get theGroupSaveResultCouldntBe => '分组保存结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get theGroupDeletionResultCouldntBe => '分组删除结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get groupName2 => '分组名称';

  @override
  String get theGroupWasSavedButThe => '分组已保存，但列表刷新失败。请重试刷新列表。';

  @override
  String get theGroupWasDeletedButThe => '分组已删除，但列表刷新失败。请重试刷新列表。';

  @override
  String get theGroupChangedRefreshAndSave => '分组已变化，请刷新后重新保存布局。';

  @override
  String get theGroupWasChangedByAnother => '分组已在其他操作中更改，请刷新列表后重试。';

  @override
  String get theGroupWasChangedByAnother2 => '分组已在其他操作中更改，请重新打开后再试。';

  @override
  String get theGroupWasUpdatedButThe => '分组已更新，但列表刷新失败。请重试刷新列表。';

  @override
  String groupActionsName(String name) {
    return '分组操作：$name';
  }

  @override
  String get theGroupUpdateResultCouldntBe => '分组更新结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get groupWindowLayoutSaved => '分组窗口布局已保存。';

  @override
  String get theGroupRecordWasChangedBy => '分组记录已在其他操作中更改，请刷新列表后重试。';

  @override
  String get listView => '列表视图';

  @override
  String get afterCreatingALocalProfileYou =>
      '创建一个本地配置后，可以在此设备上加密保存 Host 和登录凭据。';

  @override
  String createdFormatdate(String formatDate) {
    return '创建于 $formatDate';
  }

  @override
  String get createGroupsToOrganizeHostsGroups =>
      '创建分组整理 Host；分组和父级关系都只保存在此本地配置中。';

  @override
  String get createAndUnlock => '创建并解锁';

  @override
  String get createNewProfile => '创建新配置';

  @override
  String get couldntDeleteTheHostTryAgain => '删除 Host 失败，请重试。';

  @override
  String get deleteHost => '删除 Host？';

  @override
  String get deleteCredential => '删除凭据';

  @override
  String get deleteCredential2 => '删除凭据？';

  @override
  String get deleteGroup => '删除分组';

  @override
  String get deleteGroup2 => '删除分组？';

  @override
  String get deleteSnippet => '删除片段';

  @override
  String get deleteSnippet2 => '删除片段？';

  @override
  String get couldntSaveHistoryCommandsInMemory =>
      '历史保存失败，本次仍可查看内存中的命令。请检查本机存储。';

  @override
  String get previousParentUnavailable => '原父级不可用';

  @override
  String get previousDefaultCredentialUnavailable => '原默认凭据不可用';

  @override
  String get argumentList => '参数列表';

  @override
  String get parameterDefinitions => '参数定义';

  @override
  String get parameterDefinitionsJsonArray => '参数定义（JSON 数组）';

  @override
  String get argumentsJsonArray => '参数（JSON 数组）';

  @override
  String windowfailuresPlural11MoreWindow(int windowFailures) {
    return '另有 $windowFailures 个窗口或位置未能恢复。';
  }

  @override
  String onlyContinueAfterVerifyingTheFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
  ) {
    return '只有在你通过可信渠道核对过指纹后才继续。确认后，本设备会为以下端点创建新的本地信任记录：\n\n$host:$port\n$algorithm\n$fingerprint\n\n归档中的旧批准本身不会自动授权连接。';
  }

  @override
  String get afterEnablingCopyTheSetupCommand =>
      '启用后复制设置命令，粘贴到当前 Bash 并按 Enter。只记录完成的命令，密码提示中的输入不会被采集；命令中的密钥仍可能被记录。历史加密保存于本机 Profile，每个主机最多 500 条 / 48 KiB。停止采集后，可在 Bash 运行 atermius_off 移除钩子。';

  @override
  String get enableAndCopySetupCommand => '启用并复制设置命令';

  @override
  String get completedCommandsAreRecordedAfterEnabling =>
      '在“记录设置”启用 Bash 集成后记录完成的命令。';

  @override
  String get reviewAndTrust => '复核并信任';

  @override
  String get reviewSshHostKeysFromThe => '复核归档中的 SSH 主机密钥';

  @override
  String get wrongPasswordOrTheLocalProfile => '密码错误，或本地配置无法解锁。';

  @override
  String get importLocalEncryptedArchive => '导入本地加密归档';

  @override
  String get exportLocalEncryptedArchive => '导出本地加密归档';

  @override
  String get trusted => '已信任';

  @override
  String get savingTheLocalEncryptedArchiveWas => '已取消保存本地加密归档。';

  @override
  String get bashRecordingIsOnClickTo => '已启用 Bash 记录。点击填入，按 Enter 执行。';

  @override
  String get revoked => '已撤销';

  @override
  String get disconnected => '已断开';

  @override
  String get theArchiveWasImportedButSome => '归档已导入；部分列表刷新失败，请重新读取配置。';

  @override
  String get thereAreTooManySplitsTo => '当前分屏过多，无法保存此分组布局。';

  @override
  String get thisWindowHasNoSessionLayout => '当前窗口没有此分组的会话布局。';

  @override
  String get invalidShortcutUseSupportedLetterDigit =>
      '快捷键无效：请使用支持的字母、数字或 F1–F12 组合，并确保所有组合唯一。';

  @override
  String get aShortcutIsInvalidOrDuplicated => '快捷键格式无效或存在重复，请修正后再保存。';

  @override
  String get restoreDefaultShortcuts => '恢复默认快捷键';

  @override
  String get theSelectedParentGroupNoLonger => '所选父级分组已不存在，请刷新列表后重试。';

  @override
  String get openLocalWorkspace => '打开本机工作区';

  @override
  String get executionType => '执行类型';

  @override
  String get reject => '拒绝';

  @override
  String get searchTerminal => '搜索终端';

  @override
  String get searchTerminalHistory => '搜索终端历史';

  @override
  String get revokeSshHostKeyTrust => '撤销 SSH 主机密钥信任？';

  @override
  String afterRevokingThisKeyForHost(String host, int port) {
    return '撤销 $host:$port 的此密钥后，后续连接必须重新核验并明确批准。';
  }

  @override
  String get revokeTrust => '撤销信任';

  @override
  String get revokingFailedTheTrustStateIs => '撤销失败。信任状态未改变，请重试。';

  @override
  String get revokeTrustForThisKey => '撤销此密钥信任';

  @override
  String get theFileWindowDidntOpenTry => '文件窗口未能打开，请重试。';

  @override
  String get theHostRequestedByTheFile => '文件窗口请求的主机不存在。';

  @override
  String get theLocalProfileRequestedByThe => '文件窗口请求的本地配置不存在。';

  @override
  String get textParametersAndPasswordCredentialReferences =>
      '文本参数与密码凭据引用的结构与服务器片段相同；所有正文与默认值均加密。';

  @override
  String get disconnectCurrentTerminal => '断开当前终端';

  @override
  String get disconnect => '断开连接';

  @override
  String get passwordsAndKeysForNewHosts => '新主机的密码和密钥直接在主机详情内设置。';

  @override
  String get newGroup => '新建分组';

  @override
  String get theNewWindowDidntOpenThe => '新窗口未能打开，会话保留在当前窗口。';

  @override
  String get theNewWindowDidntOpenThe2 => '新窗口未能打开，远程桌面保留在当前窗口。';

  @override
  String get couldntSaveTheGroupLayoutTry => '无法保存分组布局，请重试。';

  @override
  String get couldntSaveTheWindowSetCheck => '无法保存窗口组合，请检查名称、会话数量或重新解锁后重试。';

  @override
  String get couldntCreateTheLocalProfileTry => '无法创建本地配置，请重试。';

  @override
  String get couldntDeleteTheWindowSet => '无法删除窗口组合。';

  @override
  String get couldntRefreshTheHostListThe =>
      '无法刷新 Host 列表。写入结果可能已提交，请重新读取后再操作。';

  @override
  String get couldntRefreshTheLocalCredentialList =>
      '无法刷新本地凭据列表。写入结果可能已提交，请重新读取后再操作。';

  @override
  String get couldntRefreshTheLocalGroupList =>
      '无法刷新本地分组列表。写入结果可能已提交，请重新读取后再操作。';

  @override
  String get couldntRefreshTheLocalSnippetList =>
      '无法刷新本地片段列表。写入结果可能已提交，请重新读取后再操作。';

  @override
  String get couldntStartTheConsole => '无法启动 Console。';

  @override
  String get couldntSafelySaveTheDeviceUnlock =>
      '无法安全保存本机解锁密钥。请检查系统安全存储后重试，或手动创建密码保护的配置。';

  @override
  String get couldntExitTheLocalProfileSafely => '无法安全退出本地配置，请重试。';

  @override
  String get couldntImportTheLocalArchiveNothing => '无法导入本地归档；目标配置没有部分写入。';

  @override
  String get couldntExportTheLocalProfileTry => '无法导出本地配置。请重试；本地数据保持不变。';

  @override
  String get couldntOpenANewWindowTry => '无法打开新窗口，请重试。';

  @override
  String get couldntOpenTheWindowSet => '无法打开窗口组合。';

  @override
  String get couldntOpenTheRequestedFileWindow => '无法打开请求的文件窗口，请检查连接和主机密钥信任。';

  @override
  String get couldntConfirmThatTheTargetProfile => '无法确认目标配置为空，请重试。';

  @override
  String get couldntReadLocalSshHostKey => '无法读取本地 SSH 主机密钥信任。';

  @override
  String get couldntReadLocalPreferencesTheSave =>
      '无法读取本地偏好设置。保存结果可能已提交，请重试读取后再操作。';

  @override
  String get couldntReadLocalPreferencesYouCan => '无法读取本地偏好设置。可以在偏好设置页重试。';

  @override
  String get couldntReadTheLocalCredentialList => '无法读取本地凭据列表。可以在凭据页重试。';

  @override
  String get couldntReadTheLocalGroupList => '无法读取本地分组列表。可以在分组页重试。';

  @override
  String get couldntReadTheLocalArchiveFile => '无法读取本地归档文件。请重试。';

  @override
  String get couldntReadTheLocalSnippetList => '无法读取本地片段列表。可以在片段页重试。';

  @override
  String get couldntReadTheLocalProfileList2 => '无法读取本地配置列表。请重试后再创建配置。';

  @override
  String get couldntReadThisHostsSignIn => '无法读取此主机的登录信息。';

  @override
  String get couldntConnectToTheLocalSsh => '无法连接本地 SSH Host。请检查网络和凭据后重试。';

  @override
  String get showKey => '显示密钥';

  @override
  String get couldntUpdateTheHostTryAgain => '更新 Host 失败，请重试。';

  @override
  String valuevaluePlural11MonitorWindow(int valueValue) {
    return '有 $valueValue 个显示器窗口未能打开，可再次选择重试。';
  }

  @override
  String get localUnlocked => '本地 · 已解锁';

  @override
  String get localLocked => '本地 · 已锁定';

  @override
  String get localEncryptedArchiveSaved => '本地加密归档已保存。';

  @override
  String get theLocalEncryptedArchiveWasImported =>
      '本地加密归档已导入；归档中的活动 SSH 主机密钥需要在“主机密钥信任”中逐项复核。';

  @override
  String get localArchivePassphrase => '本地归档口令';

  @override
  String get theLocalArchivePassphraseCanBe => '本地归档口令最多为 1024 个 UTF-8 字节。';

  @override
  String get theLocalArchiveFileIsInvalid => '本地归档文件无效或超过大小上限。';

  @override
  String get theLocalArchiveFileExceedsThe => '本地归档文件超过大小上限。';

  @override
  String get localModeOnlyManagesEncryptedSnippets =>
      '本地模式只管理加密片段；连接主机并执行片段需要切换到服务器同步模式。';

  @override
  String get localProfile2 => '本地配置';

  @override
  String localProfileSubstring2(String substring) {
    return '本地配置 · $substring';
  }

  @override
  String get localProfileMasterPassword => '本地配置主密码';

  @override
  String get localProfileDataIsMissingOr =>
      '本地配置数据缺失或无法读取。为避免将空数据库当成有效配置，已阻止解锁；请恢复本地数据或使用备份。';

  @override
  String get tagsCommaSeparated => '标签（逗号分隔）';

  @override
  String get verifyAndTrustThisKey => '核实并信任此密钥';

  @override
  String get thisLocalvaultSshRouteIsntSupported => '此 LocalVault SSH 路由不受支持。';

  @override
  String get thisLocalvaultHasNoSshHost => '此 LocalVault 尚无 SSH 主机密钥信任记录。';

  @override
  String get thisHostKeyWasRevokedBefore => '此主机密钥此前已撤销';

  @override
  String thisCredentialIsStillReferencedBy(String credentialReferenceLabel) {
    return '此凭据仍被$credentialReferenceLabel引用。请先更改或移除该引用，再删除。';
  }

  @override
  String get thisGroupDoesntHaveAnyConnectable => '此分组还没有可连接的 SSH 主机。';

  @override
  String get thisPassphraseIsSeparateFromThe =>
      '此口令独立于本地配置主密码；请另行保存。归档内容采用 Argon2id 和 XChaCha20-Poly1305 加密。';

  @override
  String get thisWorkspaceIsProtectedByThe => '此工作区由操作系统账户的安全存储保护；锁定会关闭当前会话。';

  @override
  String get thisConsoleIsntSupportedOnThis => '此平台不支持该 Console。';

  @override
  String get eachLayoutCanHaveUpTo => '每组布局最多 32 个 SSH 主机，请拆分子组。';

  @override
  String get noMatchingHosts => '没有匹配的主机';

  @override
  String get localvaultInTheBrowserCanManage =>
      '浏览器中的 LocalVault 可在本地加密管理 Host 和凭据，但不能从这里建立 SSH 或 SFTP 连接。返回工作区选择后，可进入服务器工作区使用 Web Relay 连接同步 Vault 中的 Host。';

  @override
  String get addHostDetailsToStoreThem => '添加主机信息以加密保存在此本地配置中。';

  @override
  String get addCredential => '添加凭据';

  @override
  String get addLocalCredential => '添加本地凭据';

  @override
  String get addLocalGroup => '添加本地分组';

  @override
  String get addLocalSnippet => '添加本地片段';

  @override
  String get addSnippet => '添加片段';

  @override
  String get addASignInPasswordOr => '添加登录密码或 SSH 私钥，密文只保存在此本地配置。';

  @override
  String get addAScriptOrAStructured => '添加脚本或结构化 Bash 命令；正文只保存在本地加密配置中。';

  @override
  String get parentGroup => '父级分组';

  @override
  String get theParentGroupNoLongerExists => '父级分组已不存在，或此层级会形成循环。请重新选择后再试。';

  @override
  String get parentMissing => '父级缺失';

  @override
  String parentName(String name) {
    return '父级：$name';
  }

  @override
  String get snippet => '片段';

  @override
  String snippetSnippetid(String snippetId) {
    return '片段 $snippetId';
  }

  @override
  String snippetTitle(String title) {
    return '片段“$title”';
  }

  @override
  String get theSnippetSaveResultCouldntBe => '片段保存结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get theSnippetDeletionResultCouldntBe => '片段删除结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get theSnippetNoLongerExistsRefresh => '片段已不存在，请刷新列表。';

  @override
  String get theSnippetWasSavedButThe => '片段已保存，但列表刷新失败。请重试刷新列表。';

  @override
  String get theSnippetWasDeletedButThe => '片段已删除，但列表刷新失败。请重试刷新列表。';

  @override
  String get theSnippetWasChangedByAnother => '片段已在其他操作中更改，请刷新列表后重试。';

  @override
  String get theSnippetWasUpdatedButThe => '片段已更新，但列表刷新失败。请重试刷新列表。';

  @override
  String snippetActionsTitle(String title) {
    return '片段操作：$title';
  }

  @override
  String get theSnippetUpdateResultCouldntBe => '片段更新结果无法确认。请先刷新列表，再决定是否重试。';

  @override
  String get snippetTitle2 => '片段标题';

  @override
  String existingShellLabelShell(String shell) {
    return '现有 Shell 标签：$shell';
  }

  @override
  String get leaveBlankToKeepTheCurrent => '留空以保留当前密钥；输入内容将替换当前密钥。';

  @override
  String targetHostPortAlgorithmAlgorithmFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
    String valueValue,
  ) {
    return '目标：$host:$port\n算法：$algorithm\n指纹：$fingerprint\n\n$valueValue';
  }

  @override
  String get confirmTrustingThisKey => '确认信任此密钥';

  @override
  String get confirmLocalArchivePassphrase => '确认本地归档口令';

  @override
  String get privateKeyPassphraseOptional => '私钥口令（可选）';

  @override
  String get program => '程序';

  @override
  String get windowSetSavedSomeSeparateWindows => '窗口组合已保存，部分独立窗口不支持位置读取。';

  @override
  String windowSetOpenedValuevalueCountSessions(
    int valueValue,
    int count,
    int failures,
  ) {
    return '窗口组合已打开 $valueValue/$count 个会话；$failures 个未能连接。';
  }

  @override
  String get portForwarding => '端口转发';

  @override
  String get manageSshHostKeyTrust => '管理 SSH 主机密钥信任';

  @override
  String get terminalTheme => '终端主题';

  @override
  String get terminalFontSize2 => '终端字体大小';

  @override
  String get structuredBashCommand => '结构化 Bash 命令';

  @override
  String get structuredCommandsSupportBashOnlyHere =>
      '结构化命令仅支持 Bash；此处只加密保存，不会在本地模式下执行。';

  @override
  String get continueLabel2 => '继续';

  @override
  String get editCredential => '编辑凭据';

  @override
  String get editLocalCredential => '编辑本地凭据';

  @override
  String get editLocalGroup => '编辑本地分组';

  @override
  String get editLocalSnippet => '编辑本地片段';

  @override
  String get editSnippet => '编辑片段';

  @override
  String get gridView => '网格视图';

  @override
  String get script => '脚本';

  @override
  String scriptShell(String shell) {
    return '脚本 · $shell';
  }

  @override
  String get scriptBody => '脚本正文';

  @override
  String get unlockLocalProfile => '解锁本地配置';

  @override
  String get authenticationType => '认证类型';

  @override
  String get letExternalAiAccessTheCurrent => '让外部 AI 接入当前本地工作区。';

  @override
  String get setLocalArchivePassphrase => '设置本地归档口令';

  @override
  String get thisPreferenceAlreadyExistsAndThe => '该偏好已存在，已重新读取当前值。请确认后再保存。';

  @override
  String get thisKeyWasRevokedBeforeOnly => '该密钥此前被撤销。只有在你重新核实服务器身份后才应重新批准。';

  @override
  String get thisSnippetIdAlreadyExistsCreate => '该片段 ID 已存在，请重新创建。';

  @override
  String get createAnEmptyLocalProfileFirst => '请先创建一个空白本地配置，再导入归档。';

  @override
  String get unlockTheLocalProfileFirst => '请先解锁本地档案。';

  @override
  String get chooseALocalProfileFirst => '请先选择一个本地配置。';

  @override
  String get unlockTheTargetLocalProfileTo => '请解锁目标本地配置以打开文件窗口。';

  @override
  String get enterTheSshPrivateKey => '请输入 SSH 私钥。';

  @override
  String get enterACredentialNameAndUser => '请输入凭据名称和用户名。';

  @override
  String get enterAPassword => '请输入密码。';

  @override
  String get enterTheLocalProfileMasterPassword => '请输入本地配置主密码。';

  @override
  String get enterASnippetTitle => '请输入片段标题。';

  @override
  String get enterTheScriptBody => '请输入脚本正文。';

  @override
  String get verifyThisFingerprintOverATrusted =>
      '请通过可信渠道核实此指纹。批准后只保存在当前 LocalVault 中。';

  @override
  String get enterLocalArchivePassphrase => '输入本地归档口令';

  @override
  String get backToWorkspaceSelection => '返回工作区选择';

  @override
  String get noHostsYet => '还没有 Host';

  @override
  String get noCredentialsYet => '还没有凭据';

  @override
  String get noGroupsYet => '还没有分组';

  @override
  String get noLocalProfilesYet => '还没有本地配置';

  @override
  String get noSnippetsYet => '还没有片段';

  @override
  String get connectGroup => '连接分组';

  @override
  String get connectionClosed => '连接已关闭';

  @override
  String get connectDirectFromThisDevice => '连接（本机直连）';

  @override
  String get exitLocalProfile => '退出本地配置';

  @override
  String get chooseTheWorkspaceModeAndThe => '选择工作模式和默认打开的页面，设置保存在当前本地配置中。';

  @override
  String get chooseAProfileToUnlock => '选择配置解锁';

  @override
  String get someSeparateWindowsOrWindowPositions =>
      '部分独立窗口或窗口位置未能恢复，会话保留在当前窗口。';

  @override
  String profileSubstring(String substring) {
    return '配置 $substring';
  }

  @override
  String get profileHostAndCredentialRecordsAre => '配置、Host 和凭据记录使用本地加密密钥保护。';

  @override
  String get theProfileWasClosedButAutomatic =>
      '配置已关闭，但无法撤销自动解锁。请重新解锁后再次锁定以重试。';

  @override
  String get retryRefresh => '重试刷新';

  @override
  String get retryReading => '重试读取';

  @override
  String get retryReadingProfiles => '重试读取配置';

  @override
  String get lockAndReturnToProfiles => '锁定并返回配置列表';

  @override
  String get lockProfile => '锁定配置';

  @override
  String get hideKey => '隐藏密钥';

  @override
  String get topLevelGroup => '顶级分组';

  @override
  String get color => '颜色';

  @override
  String get firstConnectionUnknownSshHostKey => '首次连接：未知 SSH 主机密钥';

  @override
  String get defaultLabel => '默认';

  @override
  String get defaultCredential => '默认凭据';

  @override
  String get allLocalRecordsArePreflightedBefore =>
      '创建新保险库前会预检所有本地记录。不受支持的偏好、删除标记、缺失的引用或附件对象引用会在任何服务器写入前停止迁移。';

  @override
  String get cancelEmptyPreparation => '取消空的准备';

  @override
  String get continueMigration => '继续迁移';

  @override
  String get importedLocalProfiles => '导入的本地配置';

  @override
  String get localProfile => '本地配置';

  @override
  String get localProfilePassword => '本地配置密码';

  @override
  String localProfileUnlockedCountResumableMigration(int count) {
    return '本地配置已解锁 · $count 个可继续的迁移';
  }

  @override
  String localProfileSubstring(String substring) {
    return '本地配置 · $substring';
  }

  @override
  String get lock => '锁定';

  @override
  String get migrateLocalProfiles => '迁移本地配置';

  @override
  String get migrationCompleted => '迁移已完成';

  @override
  String get migrationNeedsRecovery => '迁移需要恢复';

  @override
  String get migrationStoppedLocalSourceKept => '迁移已停止 · 本地源已保留';

  @override
  String get moveLocalEncryptedRecordsToA => '将本地加密记录迁移到新的同步保险库';

  @override
  String get newSyncVaultName => '新同步保险库名称';

  @override
  String get noLocalOnlyProfileExistsIn =>
      '此浏览器中还没有仅本地配置。请先在“本地配置”工作区中创建一个并添加需要的记录，然后返回此处。';

  @override
  String get preflightAndMigrate => '预检并迁移';

  @override
  String get startANewMigration => '开始新的迁移';

  @override
  String get stopAndKeepBoth => '停止并保留两者';

  @override
  String get stopAndKeepLocalData => '停止并保留本地数据';

  @override
  String get stopMigrationAndKeepLocalData => '停止迁移并保留本地数据？';

  @override
  String get theClientDecryptsAndValidatesEvery =>
      '客户端会解密并验证每条源记录，然后为已批准的服务器设备重新加密。服务器只会收到已签名的密文。现有本地记录保持不变；在目标确认每条记录之前，本地配置会被冻结写入。';

  @override
  String get theLocalSourceWillBecomeWritable =>
      '本地源将恢复可写，其记录保持不变。目标保险库、已提交的记录和排队的操作不会被删除或撤回；目标中可能包含部分副本。';

  @override
  String get unlockALocalOnlyProfile => '解锁仅本地配置';

  @override
  String get unlockAndValidate => '解锁并验证';

  @override
  String stagedcountTotalcountEncryptedRecordsStaged(
    int stagedCount,
    int totalCount,
  ) {
    return '已暂存 $stagedCount / $totalCount 条加密记录';
  }

  @override
  String stageditemcountItemcountEncryptedRecordsStagedTarget(
    int stagedItemCount,
    int itemCount,
    String substring,
  ) {
    return '已暂存 $stagedItemCount / $itemCount 条加密记录 · 目标 $substring…';
  }

  @override
  String get theSyncServiceIdentityIsntVerified => '同步服务身份尚未验证，请重新登录后重试。';

  @override
  String countCount2EncryptedRecordsSafelyStaged(int count, int count2) {
    return '已安全暂存 $count / $count2 条加密记录。';
  }

  @override
  String get destinationDataIsAlreadyStagedThis => '已有目标数据暂存，不能取消该迁移。';

  @override
  String get couldntStopTheMigrationTheSource =>
      '无法停止迁移。源数据与已暂存密文仍保留，请重试或继续迁移。';

  @override
  String get thisMigrationCantBeResumedSafely =>
      '无法安全恢复此迁移。源数据和已暂存密文保持不变，请检查当前设备与服务端状态。';

  @override
  String get couldntUnlockOrVerifyThisLocal => '无法解锁或验证此本地配置。请检查密码和本地存储后重试。';

  @override
  String get couldntReadTheLocalProfileList => '无法读取本地配置列表。请关闭此页面后重试。';

  @override
  String get theStagedDestinationCiphertextHasAn => '暂存的目标密文格式无效。';

  @override
  String get noVaultCreationRequestWasSent => '未发送任何 Vault 创建请求，准备日志已安全取消。';

  @override
  String get localDataWasFullyPreflightedAnd => '本地数据已完整预检并冻结，正在准备新的同步 Vault…';

  @override
  String get localSourceSnapshotVerifiedResumingThe => '本地源快照已验证，正在恢复同一个同步目标…';

  @override
  String get theLocalProfileIsLocked => '本地配置已锁定。';

  @override
  String get encryptingAndStagingRecordsWithThe => '正在使用目标 Vault 密钥加密并暂存记录…';

  @override
  String get syncingEncryptedRecordsToTheNew => '正在将加密记录同步到新 Vault…';

  @override
  String get confirmingTheSameDestinationVaultAnd =>
      '正在确认同一目标 Vault，并核对先前暂存的记录…';

  @override
  String get reVerifyingTheLocalSourceSnapshot => '正在重新验证本地源快照和已暂存的加密数据…';

  @override
  String get preflightingAllLocalRecordsWritesTo => '正在预检全部本地记录；源配置暂时禁止写入…';

  @override
  String get verifyingTheLocalProfileAndChecking => '正在验证本地配置并检查恢复日志…';

  @override
  String get thisMigrationCantBeCancelledSafely =>
      '此迁移不能安全取消。请继续恢复原目标，源数据仍保持冻结。';

  @override
  String get theDestinationVaultsSyncPreferencesConflict =>
      '目标 Vault 的同步偏好存在冲突，迁移尚未完整验证。';

  @override
  String get recordsAreSavedEncryptedInThe =>
      '记录已加密保存在同步队列中，服务端确认尚未全部到达。源配置保持冻结；点击“继续迁移”可安全重试。';

  @override
  String get migrationPreparationHasntSavedTheVault => '迁移准备尚未保存 Vault 创建数据。';

  @override
  String get migrationCiphertextStagingIsIncomplete => '迁移密文暂存不完整。';

  @override
  String get migrationStoppedTheLocalSourceData =>
      '迁移已停止。本地源数据保持完整并恢复可写；目标 Vault 中已提交或待同步的数据仍会保留。';

  @override
  String get migrationCompleteTheServerConfirmedEvery =>
      '迁移已完成。所有记录均由服务端确认；本地配置仍保留原始数据。';

  @override
  String get theMigrationJournalDoesntMatchThe => '迁移日志与当前已验证的本地源快照不匹配。';

  @override
  String get theMigrationJournalContainsDuplicateOr => '迁移日志包含重复或额外的记录。';

  @override
  String get migrationIncompleteTheSourceDataIs =>
      '迁移未完成。源数据保持不变；如已建立恢复日志，请从下方继续同一目标。';

  @override
  String get theMigrationDestinationBelongsToA => '迁移目标属于另一个服务端实例。';

  @override
  String get accountPassword => '账户密码';

  @override
  String get accountSessionExpiredSignInAgain => '账户会话已过期；请重新登录';

  @override
  String get encryptedChangesAreUpToDate => '加密更改已是最新';

  @override
  String get encryptedSyncWillRetryWhenThe => '连接恢复后将重试加密同步';

  @override
  String get noVaultIsCurrentlyAvailable => '当前没有可用的保险库';

  @override
  String get receiveEncryptedChangesNow => '立即接收加密更改';

  @override
  String get receivingSignedEncryptedChanges => '正在接收签名的加密更改';

  @override
  String get signOut => '退出登录';

  @override
  String get thisDeviceOrVaultAccessWas => '此设备或保险库访问权限已被撤销';

  @override
  String get unlockToVerifyTheLatestVault => '解锁以验证最新的保险库状态';

  @override
  String get unlockWorkspace => '解锁工作区';

  @override
  String get workspaceLocked => '工作区已锁定';

  @override
  String get yourAccountStaysSignedInWhile =>
      '你的账户保持登录。锁定期间，此设备可以接收并保存已签名的密文，但无法解密记录，也无法创建或上传更改。';

  @override
  String get sshConsoleSupportReadingTextAnd =>
      'SSH / Console 支持文本读取与输入；SSH 支持独立命令执行和 SFTP 文本文件读写。RDP / VNC 支持连接和标签管理，暂不提供画面识别或鼠标控制。';

  @override
  String get onlyTheLast50ToolNames => '仅在内存中保留最近 50 次工具名称和结果，不记录命令、文件内容或令牌。';

  @override
  String get listensOn127001 =>
      '仅监听 127.0.0.1。每次启用生成新令牌；锁定、退出或切换保险库后授权失效。不同窗口可使用不同端口。停止 MCP 不会关闭你已打开的会话。';

  @override
  String get stopAndRevokeToken => '停止并撤销令牌';

  @override
  String get allowExternalAiToPerformActions => '允许外部 AI 执行操作';

  @override
  String get actionsAllowed => '允许操作';

  @override
  String get allowsConnectingClosingSessionsTerminalInput =>
      '允许连接/关闭会话、终端输入、执行命令和写入文件。修改后需重新启用 MCP。';

  @override
  String get readOnly => '只读';

  @override
  String get readOnlyModeCanStillRead =>
      '只读模式仍可读取终端输出和文件内容，其中可能包含敏感信息。仅将连接配置交给你信任的 AI。已保存的密码、私钥和解锁密钥不会作为 MCP 字段提供。';

  @override
  String get availableTools => '可用工具';

  @override
  String get enableMcp => '启用 MCP';

  @override
  String get copyConnectionConfigIncludesToken => '复制连接配置（含令牌）';

  @override
  String get externalAiAccess => '外部 AI 接入';

  @override
  String get failed => '失败';

  @override
  String get done => '完成';

  @override
  String get off => '已关闭';

  @override
  String get copiedIncludesAccessToken => '已复制（含访问令牌）';

  @override
  String get couldntStartMcpMakeSureThe => '无法启动 MCP。请确认工作区已解锁，并检查端口是否被其他窗口占用。';

  @override
  String get couldntCopyTheConfigurationCheckClipboard => '无法复制配置，请检查剪贴板权限。';

  @override
  String get noCallsYet => '暂无调用';

  @override
  String get recentCalls => '最近调用';

  @override
  String get localListeningPort => '本机监听端口';

  @override
  String get starting => '正在启动…';

  @override
  String get theBrowserAndMobileAppsDont =>
      '此版本的 Atermius 不提供本机 MCP 监听。请在 Windows、Linux、macOS 或 Android 应用中打开工作区后启用。';

  @override
  String get portMustBe102465535 => '端口范围为 1024–65535。';

  @override
  String runningValuevalue(String valueValue) {
    return '运行中 · $valueValue';
  }

  @override
  String get letExternalAiUseTheHosts =>
      '通过 MCP 让外部 AI 使用当前工作区的主机、会话、终端和远程文件。无需在 Atermius 内配置模型 API。';

  @override
  String get rdpRemoteDesktop => 'RDP 远程桌面';

  @override
  String get sshHost => 'SSH 主机';

  @override
  String get vncRemoteDesktop => 'VNC 远程桌面';

  @override
  String get newSession => '新建会话';

  @override
  String get unableToOpenANewWindow => '无法打开新窗口。';

  @override
  String get couldntOpenANewWindow => '无法打开新窗口。';

  @override
  String get newWindowsRequireADesktop => '新窗口需要桌面客户端。';

  @override
  String get fileWindowsRequireADesktop => '文件窗口需要桌面客户端。';

  @override
  String get independentFileWindowsRequireADesktop => '独立文件窗口需要桌面客户端。';

  @override
  String get chooseSshConfigFile => '选择 SSH 配置文件';

  @override
  String get confirmImport => '确认导入';

  @override
  String createCountEncryptedHostRecordS(int count) {
    return '创建 $count 条加密主机记录。现有主机不会被更改，也不会打开 SSH 连接。';
  }

  @override
  String get importHosts => '导入主机';

  @override
  String get importOpensshConfig => '导入 OpenSSH 配置';

  @override
  String get importTheseHosts => '导入这些主机？';

  @override
  String importCountHosts(int count) {
    return '导入 $count 台主机';
  }

  @override
  String lineLineMessage(int line, String message) {
    return '第 $line 行 · $message';
  }

  @override
  String get noConcreteHostAliasesWereFound => '未找到具体的 Host 别名。';

  @override
  String get proxyjumpReferencesCouldNotBeSaved => '无法按安全顺序保存 ProxyJump 引用。';

  @override
  String get reviewBlockedNoRecordsCanBe => '检查被阻止：此文件中没有可导入的记录。';

  @override
  String get reviewLiteralHostAliasesHostnameUser =>
      '保存前请检查字面 Host 别名、HostName、User、Port 和单个 ProxyJump 别名。Include、Match、通配符模式、ProxyCommand 和 LocalCommand 会被阻止。绝不会打开 IdentityFile 路径。';

  @override
  String get theActiveVaultChangedDuringImport => '导入期间当前保险库已更改；其余主机未保存。';

  @override
  String get theActiveVaultIsReadOnly => '当前保险库为只读；未导入任何主机。';

  @override
  String get theConfigFileCouldNotBe => '无法读取配置文件。';

  @override
  String get theSelectedConfigCouldNotBe => '无法读取所选配置。';

  @override
  String get theSelectedConfigExceedsThe1 => '所选配置超过 1 MiB 上限。';

  @override
  String get thisProxyjumpChainContainsACycle =>
      '此 ProxyJump 链存在循环；受影响路由中的主机都不会被导入。';

  @override
  String thisProxyjumpChainExceedsTheMaxjumphosthops(int maxJumpHostHops) {
    return '此 ProxyJump 链超过 $maxJumpHostHops 跳上限。';
  }

  @override
  String get thisProxyjumpChainPointsToA => '此 ProxyJump 链指向不存在的已保存主机。';

  @override
  String valuevalueAdditionalFindingsAreHidden(int valueValue) {
    return '另有 $valueValue 条发现已隐藏。';
  }

  @override
  String filenameActions(String filename) {
    return '$filename 操作';
  }

  @override
  String get uploadFile => '上传文件';

  @override
  String get parentFolder => '上级目录';

  @override
  String get download => '下载';

  @override
  String get modified => '修改时间';

  @override
  String get create => '创建';

  @override
  String deleteFilenameFoldersMustBeEmpty(String filename) {
    return '删除“$filename”？文件夹必须为空，此操作无法撤销。';
  }

  @override
  String get size => '大小';

  @override
  String get fileActions => '文件操作';

  @override
  String get newFolder => '新建文件夹';

  @override
  String get thisFolderIsEmpty => '此目录为空';

  @override
  String get confirmDeletion => '确认删除';

  @override
  String get editText => '编辑文本';

  @override
  String get remotePath => '远端路径';

  @override
  String get closePane => '关闭窗格';

  @override
  String get unsplit => '取消分窗';

  @override
  String get invalidLayoutSession => '布局会话无效。';

  @override
  String get layoutIsNestedTooDeeply => '布局层级过深。';

  @override
  String get dropToSplit => '拖放以分屏';

  @override
  String paneActionsLabel(String label) {
    return '窗格操作 · $label';
  }

  @override
  String get paneActionsTapTheWhiteHandle => '窗格操作：点击顶部白色把手或按 Alt+Shift+P';

  @override
  String get paneActionsHoverNearTheTop => '窗格操作：靠近顶部、触摸顶部或按 Alt+Shift+P';

  @override
  String get settingsCategories => '设置分类';

  @override
  String get backToConflict => '返回冲突';

  @override
  String get compare => '比较';

  @override
  String get compareRemoteFileVersions => '比较远程文件版本';

  @override
  String get editRemoteTextFile => '编辑远程文本文件';

  @override
  String get fileName => '文件名';

  @override
  String get latestRemote => '最新的远程版本';

  @override
  String get overwriteRemoteFile => '覆盖远程文件';

  @override
  String get remoteFileChanged => '远程文件已更改';

  @override
  String get remoteFileContents => '远程文件内容';

  @override
  String get saveAs => '另存为';

  @override
  String get saveRemoteFileAs => '将远程文件另存为';

  @override
  String get theRemoteFileChangedAfterYou =>
      '远程文件在你打开后已被更改。你的草稿尚未保存。请比较版本、另存新副本，或明确覆盖最新版本。';

  @override
  String get utf8TextUpTo10 =>
      '最大 10 MiB 的 UTF-8 文本。草稿仅保存在内存中，不会同步。SFTP 无法在远程路径被并发修改时保证比较并交换或不跟随链接打开；请避免编辑共享可写目录中的文件。';

  @override
  String get yourDraft => '你的草稿';

  @override
  String get advanced => '高级';

  @override
  String get allowNetworkExposure => '允许网络暴露';

  @override
  String get anotherProfileOfThisHostAlready => '此主机的另一个配置已使用此监听地址和端口。';

  @override
  String get connectThisHostOverSshTo => '通过 SSH 连接此主机以启动转发。';

  @override
  String get couldNotRemoveThisForwardingProfile2 => '无法移除此转发配置。';

  @override
  String get destinationReachedFromTheSshServer => '从 SSH 服务器访问的目标';

  @override
  String get destinationReachedFromThisDevice => '从此设备访问的目标';

  @override
  String get dynamicSocksD => '动态 SOCKS (-D)';

  @override
  String dynamicSocksDBind(String bind) {
    return '动态 SOCKS (-D) · $bind';
  }

  @override
  String get dynamicForwardingIsASocks44a =>
      '动态转发是没有 SOCKS 认证的 SOCKS4/4a/5 CONNECT 代理。任何能访问其监听器的人都可以使用你的 SSH 连接。';

  @override
  String get expose => '暴露';

  @override
  String get exposeThisForwardBeyondLoopback => '将此转发暴露到回环地址以外？';

  @override
  String lastConnectionLastconnectionerror(Object lastConnectionError) {
    return '上次连接：$lastConnectionError';
  }

  @override
  String get localL => '本地 (-L)';

  @override
  String localLBindDestinationViaSsh(String bind, String destination) {
    return '本地 (-L) · $bind → 经 SSH 到 $destination';
  }

  @override
  String get loopbackOrAnIpAddress => '回环地址或 IP 地址';

  @override
  String get permitANonLoopbackListenerFor =>
      '允许非回环监听器（例如 0.0.0.0），或对于远程转发，允许你网络上的设备端目标。保存前和每次启动前都会要求你确认。';

  @override
  String get reachableBeyondLoopback => '可从回环地址以外访问';

  @override
  String get remoteR => '远程 (-R)';

  @override
  String remoteRSshServerBindThis(String bind, String destination) {
    return '远程 (-R) · SSH 服务器 $bind → 此设备 $destination';
  }

  @override
  String get socks44a5ConnectWithoutSocks =>
      '没有 SOCKS 认证的 SOCKS4/4a/5 CONNECT。目标由 SSH 服务器解析。';

  @override
  String sshPortForwardingHostname(String hostName) {
    return 'SSH 端口转发 · $hostName';
  }

  @override
  String get sshServerListenerAddress => 'SSH 服务器监听地址';

  @override
  String get theSshServerGatewayportsSettingMay2 =>
      'SSH 服务器的 GatewayPorts 设置可能会扩大回环绑定请求。使用远程转发前请核实服务器配置。';

  @override
  String get thisHostIsNoLongerAvailable => '此主机已不可用。';

  @override
  String get thisHostIsNotSavedIn =>
      '此主机未保存在当前配置或保险库中（或已被移除）。请保存主机以保留转发配置；下方正在运行的转发仍可停止。';

  @override
  String sshportforwardprofiledescriptionNoLongerSavedForThis(
    String sshPortForwardProfileDescription,
  ) {
    return '$sshPortForwardProfileDescription\n已不再为此主机保存，但仍在此连接上运行。';
  }

  @override
  String whatOnlyContinueOnANetwork(String what) {
    return '$what请仅在你信任的网络上继续。';
  }

  @override
  String get downArrow => '下方向键';

  @override
  String get leftArrow => '左方向键';

  @override
  String get lockAltModifier => '锁定 Alt 修饰键';

  @override
  String get lockControlModifier => '锁定 Control 修饰键';

  @override
  String get moreTerminalKeys => '更多终端按键';

  @override
  String get pasteClipboard => '粘贴剪贴板';

  @override
  String get releaseControlAndAlt => '释放 Control 和 Alt';

  @override
  String get rightArrow => '右方向键';

  @override
  String get upArrow => '上方向键';

  @override
  String get nextMatch => '下一个匹配项';

  @override
  String get previousMatch => '上一个匹配项';

  @override
  String get searchTerminalScrollback => '搜索终端回滚内容';

  @override
  String get closeSidebar => '关闭侧栏';

  @override
  String get delete => '删除';

  @override
  String get refreshQuickCommands => '刷新快捷指令';

  @override
  String get saveEncryptedAsSnippets => '加密保存为 Snippets';

  @override
  String get singleLineCommand => '单行指令';

  @override
  String get insertIntoTerminal => '填入终端';

  @override
  String get quickCommands => '快捷指令';

  @override
  String get quickCommandActions => '快捷指令操作';

  @override
  String get searchTermsAreRecordedWhenYou => '按 Enter 或关闭搜索后记录搜索词';

  @override
  String get search => '搜索';

  @override
  String get search2 => '搜索…';

  @override
  String get searchHistory => '搜索历史';

  @override
  String get searchCurrentTerminalOutput => '搜索当前终端输出';

  @override
  String get theActionDidntCompleteRefreshAnd => '操作未完成，请刷新后重试。';

  @override
  String get cantInsertSelectASessionThat => '无法填入：请选中仍连接的会话，且指令必须是单行文本。';

  @override
  String get couldntReadQuickCommandsRefreshAnd => '无法读取快捷指令，请刷新重试。';

  @override
  String get showsCommandsCompletedOnTheCurrent => '显示当前主机已完成的命令；点击填入，不自动执行。';

  @override
  String get noMatchingEntries => '暂无匹配条目';

  @override
  String get addQuickCommand => '添加快捷指令';

  @override
  String get clear => '清空';

  @override
  String get clearLocalHistory => '清空本机历史';

  @override
  String get clickToInsertPressEnterTo => '点击填入，按 Enter 执行。此处展示无参数的单行 Bash 指令。';

  @override
  String get removeSearchTerm => '移除搜索词';

  @override
  String get filterInputHistory => '筛选历史输入';

  @override
  String get filterByNameOrCommand => '筛选名称或指令';

  @override
  String get terminalTools => '终端工具';

  @override
  String get edit => '编辑';

  @override
  String get editQuickCommand => '编辑快捷指令';

  @override
  String get recordingSettings => '记录设置';

  @override
  String get enterANameAndASingle => '请填写名称和不含控制字符的单行指令。';

  @override
  String get inputHistory => '输入历史';

  @override
  String get cancelTransfer => '取消传输';

  @override
  String get chooseLocalFile => '选择本地文件';

  @override
  String get couldNotOpenAStreamingFile => '无法打开流式文件来源。';

  @override
  String get downloadFile => '下载文件';

  @override
  String get downloadingWithSftpCompatibilityModeUp =>
      '正在以 SFTP 兼容模式下载（最多 16 MiB）…';

  @override
  String get fileExceeds1GibTransferLimit => '文件超过 1 GiB 传输上限。';

  @override
  String get mobileDownloadsUpTo16Mib => '移动端最多下载 16 MiB。完整文件验证后才会打开保存选择器。';

  @override
  String get preparingTransfer => '正在准备传输…';

  @override
  String get remoteFilePath => '远程文件路径';

  @override
  String get sftpCompatibilityDownloadsUpTo16 =>
      'SFTP 兼容模式最多下载 16 MiB。在此平台上，SCP 需要流式保存目标。';

  @override
  String get singleFilesUpTo1Gib => '单个文件最大 1 GiB。现有目标永远不会被替换。SFTP 文件在上传期间可见。';

  @override
  String get streamingFileSavesAreUnavailableOn => '此平台不支持流式保存文件。';

  @override
  String get streamingTransferIsUnavailableOnThis => '此平台不支持流式传输。';

  @override
  String get theSelectedProviderReturnedAnUnsafe => '所选提供方返回了不安全的文件名。';

  @override
  String get thisFilePickerDoesNotProvide => '此文件选择器不提供流式来源。';

  @override
  String get transferCancelled => '传输已取消。';

  @override
  String get transferFailedCheckThePathPermissions => '传输失败。请检查路径、权限以及目标是否存在。';

  @override
  String get uploadFile2 => '上传文件';

  @override
  String get closeWindow => '关闭窗口';

  @override
  String get maximize => '最大化';

  @override
  String get minimize => '最小化';

  @override
  String get closeWindow2 => '关闭窗口';

  @override
  String get maximize2 => '最大化';

  @override
  String get minimize2 => '最小化';

  @override
  String get restore2 => '还原';

  @override
  String get save2 => '保存';

  @override
  String get saveWindowSet => '保存窗口组合';

  @override
  String get thisWindowHasSessionsThatCant => '当前窗口有无法保存的会话，请先关闭后重试。';

  @override
  String get thisWindowHasNoSessionsTo => '当前窗口没有可保存的会话。';

  @override
  String get openWindowSet => '打开窗口组合';

  @override
  String get couldntDeleteTheWindowSetUnlock => '无法删除窗口组合，请重新解锁或同步后重试。';

  @override
  String get couldntReadWindowSetsUnlockAgain => '无法读取窗口组合，请重新解锁或同步后重试。';

  @override
  String get thereAreNoReadySessionsTo => '没有可保存的已就绪会话。';

  @override
  String get windowSets => '窗口组合';

  @override
  String get setName => '组合名称';

  @override
  String get sshKey => 'SSH 密钥';

  @override
  String get close2 => '关闭';

  @override
  String get password2 => '密码';

  @override
  String get theActionDidntCompleteTryAgain => '操作未完成，请重试。';

  @override
  String get more => '更多功能';

  @override
  String get directConnection2 => '直接连接';

  @override
  String get connectionProperties => '连接属性';

  @override
  String get viaJumpHost => '通过跳板主机';

  @override
  String get theAppOpensInTheCurrent => '下次启动直接进入当前模式。切换模式会关闭当前连接，已保存的数据会保留。';

  @override
  String get cloudSyncMode => '云端同步模式';

  @override
  String get switchToCloudMode => '切换到云端模式';

  @override
  String get switchToLocalMode => '切换到本地模式';

  @override
  String get workspaceMode => '工作模式';

  @override
  String get couldntSwitchTheWorkspaceModeCheck => '无法切换工作模式，请检查本机存储后重试。';

  @override
  String get localMode => '本地模式';

  @override
  String closeTitle(String title) {
    return '关闭 $title';
  }

  @override
  String get newWindowCtrlShiftN => '新建窗口 (Ctrl+Shift+N)';

  @override
  String countCount2Connected(int count, int count2) {
    return '$count/$count2 已连接';
  }

  @override
  String get splitTopBottom => '上下分屏';

  @override
  String get hostMenuClickToOpen => '主机菜单 · 点击展开';

  @override
  String get closeOtherTabs => '关闭其他标签页';

  @override
  String get closeTab => '关闭标签页';

  @override
  String get closeThisSplitGroup => '关闭此分窗组';

  @override
  String get unsplitCurrentPane => '取消当前窗格分窗';

  @override
  String get duplicateTab => '复制标签';

  @override
  String get splitLeftRight => '左右分屏';

  @override
  String get connected => '已连接';

  @override
  String get searchHostsOrQuickConnect => '搜索主机或快捷连接';

  @override
  String get notConnected => '未连接';

  @override
  String get moveToNewWindow => '移至新窗口…';

  @override
  String get terminalSidebar => '终端侧边栏';

  @override
  String get desktopRdpEngineFeatureUnavailable => '此 RDP 引擎构建不支持此功能';

  @override
  String get desktopChooseAbsoluteLocalFolder => '请选择使用绝对路径的本地文件夹';

  @override
  String get desktopRdpMultimonResolutionHelp =>
      '启用“使用所有本地显示器”时忽略此设置：每个显示器保持自身尺寸。';

  @override
  String get desktopRdpAutomaticResolutionHelp =>
      '自动模式通过 RDP 显示控制跟随窗口尺寸；固定尺寸在连接时请求。';

  @override
  String get desktopUseAllLocalMonitors => '使用所有本地显示器';

  @override
  String get desktopClipboardText => '剪贴板文本';

  @override
  String get desktopClipboardFiles => '剪贴板文件';

  @override
  String get desktopMicrophone => '麦克风';

  @override
  String get desktopSmartCards => '智能卡';

  @override
  String get desktopCameras => '摄像头';

  @override
  String get desktopVncResizeHelp =>
      '调整尺寸需要服务器支持 ExtendedDesktopSize（例如 TigerVNC 或启用 -xrandr 的 x11vnc）。其他服务器保持原尺寸，仅在本地缩放视图。';

  @override
  String get desktopAutomaticFitWindow => '自动（适应窗口）';

  @override
  String desktopResolutionSideBounds(int minSide, int maxSide) {
    return '分辨率每边必须介于 $minSide 和 $maxSide 像素之间';
  }

  @override
  String desktopResolutionPixelLimit(int megapixels) {
    return '分辨率超过 $megapixels 百万像素';
  }

  @override
  String get inventoryTooLarge => '清单超过 1 MiB 导入上限。';

  @override
  String get inventoryTooManyLines => '清单行数过多，无法安全审核。';

  @override
  String get inventoryLineTooLong => '清单中的一行过长，无法安全审核。';

  @override
  String get inventoryControlCharacter => '清单文件中不允许控制字符。';

  @override
  String get inventoryUnsupportedFormat => '不支持此清单格式。';

  @override
  String get inventoryParseError => '无法安全解析清单语法。';

  @override
  String get inventoryUnsupportedConstruct => '清单包含不支持的结构。';

  @override
  String get inventoryDynamicUnsupported => '不支持动态清单和插件配置。';

  @override
  String get inventoryInvalidGroup => '分组声明格式错误或不受支持。';

  @override
  String get inventoryInvalidHost => '主机声明格式错误或不受支持。';

  @override
  String get inventoryInvalidVariable => '允许导入的连接字段包含无效值。';

  @override
  String get inventoryUnsupportedConnection => '只能导入静态 SSH 清单主机。';

  @override
  String get inventoryIgnoredVariable => '已忽略不支持的清单变量，该变量不会被导入。';

  @override
  String get inventoryConflictingVariable => '清单中的值互相冲突，无法确定此主机。';

  @override
  String get inventoryDuplicateVariable => '连接字段重复，无法确定此主机。';

  @override
  String get inventoryGroupCycle => '分组继承存在循环。';

  @override
  String get inventoryLimitExceeded => '清单超过安全解析上限。';

  @override
  String get inventoryEmpty => '此清单中未找到静态主机。';

  @override
  String get inventoryBlockedSource => '被阻止的清单不能更改已保存的来源状态。';

  @override
  String get inventoryEmptySource => '空清单不能将已保存的主机标记为缺失。';

  @override
  String get inventoryPartialSource => '不完整或存在歧义的清单不能将已保存的主机标记为缺失。';

  @override
  String get inventoryBlockedPlan => '清单存在阻止导入的问题；未计划任何更改。';

  @override
  String get inventoryBlockedEntry => '此条目存在阻止导入的问题，不会更改。';

  @override
  String get inventoryDuplicateIdentity => '此来源包含存在歧义的重复主机标识。';

  @override
  String get inventoryUsernameRequired => '保存主机需要用户名。';

  @override
  String get inventoryMultipleSaved => '多个已保存的主机具有此来源标识。';

  @override
  String get inventoryKeepOtherSource => '已保存。现有主机将保持不变；它属于其他来源或没有来源标识。';

  @override
  String get inventoryRevisionUnavailable => '无法获取已保存的主机修订。请刷新主机页面后重新审核。';

  @override
  String get inventoryTagLimit => '合并后的主机会超过 128 个标签的存储上限。请移除标签或分组后重新审核清单。';

  @override
  String get inventoryRestoreActive => '此主机将在其来源中恢复为活跃状态。';

  @override
  String get inventoryMissingRevision => '无法获取已保存的主机修订；未将缺失条目标记为过期。';

  @override
  String get inventoryAbsentHost => '完整清单中缺少此已保存的主机。';

  @override
  String get sshImportLineTooLong => '此行过长，无法审核。';

  @override
  String get sshImportControlCharacter => 'SSH 配置文件中不允许控制字符。';

  @override
  String get sshImportUnterminatedQuote => '引号或转义未结束；请修复此行后再导入。';

  @override
  String get sshImportAliasRequired => 'Host 行需要明确的别名。';

  @override
  String get sshImportUnsupportedPattern => '不支持通配符、否定或格式错误的 Host 模式；请使用明确的别名。';

  @override
  String get sshImportHostLimit => '配置文件超过 256 个主机的导入上限。';

  @override
  String get sshImportInclude => '不会打开 Include 文件。请展开配置后审核并导入。';

  @override
  String get sshImportMatch => '不会计算 Match 块。请将文件转换为明确的 Host 块后再导入。';

  @override
  String get sshImportGlobalCommand => '绝不会执行命令指令；请移除此全局指令后再导入。';

  @override
  String get sshImportGlobalIdentity => 'IdentityFile 需要一个值；导入期间不会打开任何文件。';

  @override
  String get sshImportUnknownDirective => '此指令不会导入。请在连接前审核或移除。';

  @override
  String get sshImportGlobalValueCount => '此全局指令只能有一个值。';

  @override
  String get sshImportGlobalInvalidValue => '此全局值无效或不受支持。';

  @override
  String get importStatusCreate => '新建';

  @override
  String get importStatusUpdate => '更新';

  @override
  String get importStatusUnchanged => '不变';

  @override
  String get importStatusMissing => '缺失';

  @override
  String get importStatusSkipped => '跳过';

  @override
  String get importStatusBlocked => '已阻止';

  @override
  String get sshImportBlockedFile => '文件包含不支持的结构，已阻止导入。';

  @override
  String get sshImportAmbiguousName => '多个已保存的主机使用此名称；不会覆盖任何内容。';

  @override
  String get sshImportBlockedHost => '此主机存在阻止导入的问题，不会导入。';

  @override
  String get sshImportNotImportable => '此主机无法导入。';

  @override
  String get importUsernameMissing => '缺少用户名';

  @override
  String importPlannedEndpoint(String endpoint) {
    return '计划：$endpoint';
  }

  @override
  String importSavedEndpoint(String endpoint) {
    return '已保存：$endpoint';
  }

  @override
  String importHostTags(String tags) {
    return '将保存的主机标签：$tags';
  }

  @override
  String importSshEndpointLine(
    int line,
    String username,
    String address,
    int port,
  ) {
    return '第 $line 行 · $username@$address:$port';
  }

  @override
  String importProxyJumpLine(String alias, int line) {
    return 'ProxyJump $alias · 第 $line 行';
  }

  @override
  String sshImportSavedName(String name) {
    return '已保存为“$name”；不会覆盖。';
  }

  @override
  String sshImportJumpAmbiguous(int line) {
    return '第 $line 行的 ProxyJump 存在歧义，因为多个已保存的主机使用该名称。';
  }

  @override
  String sshImportJumpMissing(int line) {
    return '第 $line 行的 ProxyJump 无法确定唯一的导入或已保存主机。';
  }

  @override
  String sshImportJumpSelf(int line) {
    return '第 $line 行的 ProxyJump 指向主机自身。';
  }

  @override
  String sshImportPreviewCounts(int count) {
    return '预览：将创建 $count 个主机；将跳过冲突和被阻止的条目。';
  }

  @override
  String inventoryPreviewCounts(
    int created,
    int updated,
    int unchanged,
    int missing,
  ) {
    return '预览：将创建 $created 个主机，更新 $updated 个，保持不变 $unchanged 个，缺失 $missing 个。';
  }

  @override
  String get keybarPaste => '粘贴';

  @override
  String get keybarReset => '重置';

  @override
  String get keybarCtrlGuidance => 'Ctrl：轻点仅作用于下一个按键，双击锁定';

  @override
  String get keybarAltGuidance => 'Alt：轻点仅作用于下一个按键，双击锁定';

  @override
  String get keybarModifierOff => '关闭';

  @override
  String get keybarModifierArmed => '仅下一个按键';

  @override
  String get keybarModifierLocked => '已锁定';

  @override
  String get keybarPinExpanded => '保持展开更多按键';

  @override
  String get keybarShowKeyboard => '显示键盘';

  @override
  String get keybarHideKeyboard => '隐藏键盘';

  @override
  String get terminalSearchQueryTooLong => '查询过长';

  @override
  String get terminalSearchSearching => '正在搜索…';

  @override
  String terminalSearchMatchCount(int total, int position) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '第 $position / $total 处匹配',
      zero: '0 处匹配',
    );
    return '$_temp0';
  }

  @override
  String terminalSearchLimitedCount(String countLabel) {
    return '$countLabel · 结果已限制';
  }

  @override
  String get r7UiPaletteGalleryTitle => '配色方案';

  @override
  String get r7UiPaletteGalleryDescription =>
      '应用于本设备上的所有终端，包括本地、云端和独立终端窗口。仅保存在本设备上，不会更改已保存的终端主题。';

  @override
  String r7UiPaletteFollowSynced(String name) {
    return '已保存的主题（$name）';
  }

  @override
  String get r7UiPaletteSearchHint => '搜索配色方案';

  @override
  String get r7UiPaletteFilterAll => '全部';

  @override
  String get r7UiPaletteFilterDark => '深色';

  @override
  String get r7UiPaletteFilterLight => '浅色';

  @override
  String get r7UiPaletteNoMatches => '没有匹配的配色方案。';

  @override
  String r7UiPaletteActiveOverride(String name) {
    return '本设备上的终端使用 $name。';
  }

  @override
  String get r7UiPaletteFollowingSynced => '本设备上的终端跟随已保存的终端主题。';

  @override
  String get r7UiPaletteSaveFailed => '无法在本设备上保存配色方案。它会一直生效到应用关闭。';

  @override
  String r7UiShortcutRecordTooltip(String action) {
    return '为“$action”录制新快捷键';
  }

  @override
  String get r7UiShortcutRecording => '请按下组合键… 按 Esc 取消';

  @override
  String r7UiShortcutReset(String action) {
    return '将“$action”恢复为默认值';
  }

  @override
  String get r7UiShortcutDuplicate => '已被其他操作使用';

  @override
  String get r7UiShortcutInvalid => '不支持或被保留的组合键';

  @override
  String get r7NavLogTranscriptNone => '此会话没有输出记录。';

  @override
  String get r7NavCertAnyPrincipal => '任意主体';

  @override
  String get r7NavKindKeyWithCertificate => '私钥 + 证书';

  @override
  String get r7NavHomeNavigation => '主页导航';

  @override
  String get r7NavKeychainSubtitle => '主机和分组共用的 SSH 密钥、用户证书和密码。主机仍可保留各自的登录信息。';

  @override
  String get r7NavAdd => '添加';

  @override
  String get r7NavImportCertificateFile => '导入证书文件';

  @override
  String get r7NavLogs => '日志';

  @override
  String get r7NavLogHost => '主机';

  @override
  String r7NavUsedBy(int count, String names) {
    return '被 $count 项使用：$names';
  }

  @override
  String get r7NavLogTranscriptLiveNotRecorded => '此会话开始时未开启记录。';

  @override
  String get r7NavLogTranscript => '输出记录';

  @override
  String get r7NavCertUnsupported => '不支持此证书算法（不支持 DSA 和安全密钥证书）。';

  @override
  String get r7NavLogSearchHint => '搜索主机或地址';

  @override
  String get r7NavKeychainSearchHint => '搜索名称、用户、指纹或主机';

  @override
  String get r7NavImportExport => '导入 / 导出';

  @override
  String get r7NavLogProtocol => '协议';

  @override
  String get r7NavLogRecordTranscripts => '记录终端输出记录';

  @override
  String get r7NavLogFailureCredential => '登录信息缺失或无法读取';

  @override
  String get r7NavLogFailureNetwork => '网络或握手错误';

  @override
  String get r7NavLogNoMatches => '没有符合当前搜索或筛选的项目。';

  @override
  String get r7NavLogCopyTranscript => '复制输出记录';

  @override
  String get r7NavFilterCertificates => '证书';

  @override
  String get r7NavLogStatusConnecting => '正在连接';

  @override
  String get r7NavSignInKeychainNote => '使用钥匙串项目（包括证书）。请在“钥匙串”中编辑，它仍与其他主机共享。';

  @override
  String r7NavCertCa(String fingerprint) {
    return 'CA $fingerprint';
  }

  @override
  String get r7NavDeleteBlocked => '正在使用 — 请先修改相关主机或分组';

  @override
  String get r7NavLogFilterClosed => '已关闭';

  @override
  String get r7NavKeychain => '钥匙串';

  @override
  String get r7NavLogStorageMemory => '本次应用会话的连接日志（仅保存在内存中，锁定时清除）。与命令历史分开。';

  @override
  String get r7NavLogConnectedAt => '连接时间';

  @override
  String get r7NavCertificateOptional => 'OpenSSH 用户证书（可选）';

  @override
  String get r7NavLogStorageFailed => '无法保存或读取日志；列表可能不完整。';

  @override
  String get r7NavLogFilterAll => '全部';

  @override
  String get r7NavFilterKeys => '密钥';

  @override
  String get r7NavKindPassword => '密码';

  @override
  String get r7NavSnippets => '快捷命令';

  @override
  String get r7NavLogStorageLocal => '本设备的连接日志，加密保存在此本地配置中。与命令历史分开。';

  @override
  String get r7NavLogDuration => '时长';

  @override
  String get r7NavImportKeyFile => '导入密钥文件';

  @override
  String get r7NavLogStatusFailed => '失败';

  @override
  String get r7NavCertificateHelper =>
      '粘贴或导入由 CA 签发的 *-cert.pub 文件。证书必须对应此私钥，并会先于普通密钥提交。';

  @override
  String get r7NavCertKeyUnreadable => '无法读取私钥以校验证书（请检查密钥和密码短语）。';

  @override
  String get r7NavLogRoute => '路径';

  @override
  String r7NavSignInKeychainItem(String name) {
    return '钥匙串：$name';
  }

  @override
  String get r7NavLogFailureTimeout => '超时';

  @override
  String get r7NavLogStatusConnected => '已连接';

  @override
  String get r7NavNotUsed => '未被任何主机或分组使用';

  @override
  String r7NavLogRecordPolicy(int count, int kib) {
    return '默认关闭。仅对开启后新建的会话生效。保存终端显示的内容（包括服务器回显的文字），从不记录按键；隐藏的密码输入不会被捕获。录制时请避免显示机密信息。最多保留最近 $count 份、每份不超过 $kib KiB。';
  }

  @override
  String get r7NavLogStatus => '状态';

  @override
  String get r7NavLogFailureUnsupported => '不支持的连接路径';

  @override
  String get r7NavLogFailureOther => '其他错误';

  @override
  String get r7NavPortForwarding => '端口转发';

  @override
  String get r7NavLogFailureHostKeyRejected => '主机密钥未获批准';

  @override
  String get r7NavCertKeyMismatch => '该证书与此私钥不匹配。';

  @override
  String get r7NavLogStarted => '开始时间';

  @override
  String get r7NavLogStatusEndedByRemote => '由服务器结束';

  @override
  String r7NavCertPrincipals(String principals) {
    return '主体：$principals';
  }

  @override
  String get r7NavLogFailureCancelled => '已取消';

  @override
  String get r7NavCertInKeyField => '私钥字段中填入了证书，请将其放到证书字段。';

  @override
  String get r7NavSignInOwn => '此主机自己的登录信息';

  @override
  String get r7NavCertValidForever => '永不过期';

  @override
  String get r7NavImportFileNotText => '所选文件不是文本格式的密钥或证书。';

  @override
  String get r7NavLogReason => '原因';

  @override
  String get r7NavFilterPasswords => '密码';

  @override
  String get r7NavLogFilterActive => '活动中';

  @override
  String get r7NavLogEmpty => '还没有会话日志。你打开的连接会显示在这里。';

  @override
  String get r7NavLogStatusLost => '连接中断';

  @override
  String r7NavCertExpired(String date) {
    return '已于 $date 过期';
  }

  @override
  String get r7NavLogStatusClosed => '已关闭';

  @override
  String get r7NavSignInSource => '登录方式';

  @override
  String get r7NavSignInInherited => '分组默认';

  @override
  String get r7NavLogFailureHostKeyChanged => '主机密钥已变更';

  @override
  String get r7NavKindPrivateKey => '私钥';

  @override
  String get r7NavLogFailureAuthentication => '身份验证被拒绝';

  @override
  String get r7NavImportFileTooLarge => '所选文件过大，不像密钥或证书。';

  @override
  String r7NavCertValidUntil(String date) {
    return '有效期至 $date';
  }

  @override
  String get r7NavLogEnded => '结束时间';

  @override
  String get r7NavLogRouteJump => '经由跳板机';

  @override
  String get r7NavKeychainEmpty => '还没有密钥、证书或密码。';

  @override
  String get r7NavLogClearTitle => '清除已结束的日志';

  @override
  String get r7NavCertMalformed => '这不是有效的 OpenSSH 证书。';

  @override
  String get r7NavNotAPrivateKey => '该文件不是私钥（.pub 或证书文件应填入证书字段）。';

  @override
  String get r7NavLogFilterFailed => '失败';

  @override
  String get r7NavLogClearBody => '要从本设备删除所有已结束的会话日志及其输出记录吗？活动会话仍会保留。';

  @override
  String r7NavCertNotYetValid(String date) {
    return '$date 之前无效';
  }

  @override
  String get r7NavLogEndpoint => '端点';

  @override
  String get r7NavCertNotUser => '这是主机证书；登录需要用户证书。';

  @override
  String get r7NavLogTranscriptTruncated => '为控制大小，较早的输出已被丢弃。';

  @override
  String get r7NavSignInInheritedNote => '使用分组的默认登录信息。选择“此主机自己的登录信息”可覆盖。';

  @override
  String r7ForwardSessionLabel(String host, int index) {
    return '$host #$index';
  }

  @override
  String get r7ForwardHostNotConnected => '未连接';

  @override
  String get r7ForwardNoRules => '还没有转发规则。点击“新建规则”为主机添加。';

  @override
  String get r7ForwardConnectAndStart => '连接并启动';

  @override
  String get r7ForwardDuplicateTitle => '复制转发规则';

  @override
  String get r7ForwardDeleteTitle => '删除转发规则？';

  @override
  String get r7ForwardWaitForSession => '请等待会话完成连接';

  @override
  String get r7ForwardStartCancelled => '已取消启动。若连接完成，会保留为普通会话。';

  @override
  String get r7ForwardDuplicate => '复制';

  @override
  String get r7ForwardRuleChanged => '规则或主机已更改或删除，未启动。';

  @override
  String r7ForwardHostSessions(int count) {
    return '$count 个会话';
  }

  @override
  String get r7ForwardMoreActions => '更多操作';

  @override
  String get r7ForwardScopeChanged => '连接期间保管库或配置已切换，规则未启动。';

  @override
  String get r7ForwardChooseHost => '选择主机';

  @override
  String get r7ForwardSearchHint => '搜索主机或规则';

  @override
  String r7ForwardDeleteBody(String name) {
    return '将从此主机删除“$name”。若正在运行，会先停止。';
  }

  @override
  String get r7ForwardHostConnecting => '正在连接…';

  @override
  String get r7ForwardNoMatches => '没有匹配的结果。';

  @override
  String r7ForwardCopyName(String name) {
    return '$name 副本';
  }

  @override
  String get r7ForwardTitle => 'SSH 端口转发';

  @override
  String get r7ForwardRuleConflict => '此规则已在别处被修改。此处未做任何更改，请查看当前规则后重试。';

  @override
  String get r7ForwardOpenSession => '打开会话';

  @override
  String get r7ForwardNotConnected => '连接未完成，规则未启动。';

  @override
  String r7ForwardSummary(int rules, int hosts, int running) {
    return '$hosts 台主机上共 $rules 条规则 · $running 条运行中';
  }

  @override
  String get r7ForwardRemovedHost => '主机已不在列表中 — 转发仍在运行';

  @override
  String get r7ForwardChooseSession => '请选择要运行规则的会话';

  @override
  String get r7ForwardHostConnected => '已连接';

  @override
  String get r7ForwardNewRule => '新建规则';

  @override
  String r7ForwardOnSession(String session, String status) {
    return '在 $session：$status';
  }

  @override
  String get r7ForwardConnectingStart => '正在连接…认证成功后启动规则';

  @override
  String get r7ForwardNoHosts => '还没有 SSH 主机。请先添加 SSH 主机。';

  @override
  String get r7ForwardNoAutoStart => '规则仅在你手动启动时运行，并通过该主机已认证的 SSH 会话转发。';

  @override
  String get r7ForwardShowAllHosts => '显示无规则的主机';

  @override
  String get r7ImportMenuAction => 'Termius 导入 / 导出';

  @override
  String get r7ImportIssueCertificateNotStored => '发现了证书，但当前版本无法保存证书；仅导入私钥。';

  @override
  String r7ImportIssueBundleIdentityExtra(String name) {
    return '每台主机只使用第一个 $name，其余已忽略。';
  }

  @override
  String r7ImportRowJump(String alias) {
    return '跳板主机：$alias';
  }

  @override
  String r7ImportIssueExportHostSkipped(String name) {
    return '主机“$name”已跳过，因为某个值无法安全写入。';
  }

  @override
  String get r7ImportIssueBundleConfigMissing => '包内没有 OpenSSH“config”文件。';

  @override
  String get r7ImportExportSave => '保存文件';

  @override
  String get r7ImportConfirmTitle => '从 Termius 导入？';

  @override
  String get r7ImportIssueSshJumpCycle => 'ProxyJump 链存在循环或过长。';

  @override
  String get r7ImportExportSecretWarning =>
      '文件将包含可直接读取的明文密码或私钥。任何拿到该文件的人都能登录这些主机。请妥善保管并在使用后删除。';

  @override
  String r7ImportIssueExportFormulaRisk(int count) {
    return '$count 行包含以 =、+、-、@ 或制表符开头的值。这些值按原样写入；请仅用 Termius 或文本编辑器打开该文件，不要用电子表格应用。';
  }

  @override
  String get r7ImportIssueInvalidTag => '标签过多或某个标签过长。';

  @override
  String get r7ImportDispositionCreate => '将被创建';

  @override
  String get r7ImportIssueCsvUnterminatedQuote => '有一个带引号的字段没有闭合。';

  @override
  String r7ImportIssueExportSecretsOmitted(int count) {
    return '$count 台主机保存的密码不在此文件中。';
  }

  @override
  String r7ImportIssueExportKeysOmitted(int count) {
    return '$count 台主机使用的私钥不在此次导出中。如需包含密钥，请使用 OpenSSH 包并开启密钥文件。';
  }

  @override
  String get r7ImportFileUnreadable => '无法读取该文件。';

  @override
  String r7ImportIssueExportCertificatesOmitted(int count) {
    return '由于未开启密钥文件，$count 个证书未被导出。';
  }

  @override
  String get r7ImportExportIntro =>
      '将主机导出为 Termius CSV 模板文件或 OpenSSH 配置。除非你主动开启，否则不包含机密信息。CSV 只能携带密码；如需密钥文件请使用 OpenSSH 包。';

  @override
  String get r7ImportIssueCsvInvalid => 'CSV 结构无效。';

  @override
  String get r7ImportApplyNone => '导入主机';

  @override
  String r7ImportMoreRowsHidden(int count) {
    return '另有 $count 行未显示，但仍计入统计。';
  }

  @override
  String get r7ImportFailScopeChanged =>
      '导入过程中保管库发生切换，导入已停止。切换前写入的记录保留在原保管库中，请在重试前检查。';

  @override
  String get r7ImportIssueBundleTooLarge => '包或其中某个文件超出导入限制。';

  @override
  String get r7ImportReadOnly => '此保管库为只读，但仍可导出。';

  @override
  String get r7ImportIssueBundleInvalid => '该文件不是有效的 ZIP 包。';

  @override
  String get r7ImportIssueCsvNul => '文件包含 NUL 字符。';

  @override
  String get r7ImportConfirmAccept => '导入';

  @override
  String get r7ImportIssueMoshAsSsh => '不支持 Mosh，此主机将以相同端口作为 SSH 导入。';

  @override
  String r7ImportIssueTooManyRows(int count) {
    return '文件中的主机数超过 $count。';
  }

  @override
  String r7ImportApply(int count) {
    return '导入 $count 台主机';
  }

  @override
  String get r7ImportIssueNotUtf8 => '文件不是有效的 UTF-8 文本。请另存为 UTF-8 后重试。';

  @override
  String get r7ImportIssueBundleConfigAmbiguous =>
      '包内同一层级有多个“config”文件，请只保留一个。';

  @override
  String r7ImportDone(int hosts, int groups) {
    return '已导入 $hosts 台主机和 $groups 个分组，均已加密保存。';
  }

  @override
  String get r7ImportBlockedFile => '无法导入此文件。请修正下列问题后重新选择。';

  @override
  String get r7ImportIssueInvalidRecord => '此主机未通过 Atermius 校验。';

  @override
  String get r7ImportIssueInvalidPrivateKey => 'SSH_KEY 中的私钥过大或无效。';

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
    return '已拒绝包内条目“$name”（链接、不安全路径、加密或不支持的压缩）。';
  }

  @override
  String get r7ImportIssueFileTooLarge => '文件超过导入大小上限。';

  @override
  String get r7ImportDispositionBlocked => '无法导入';

  @override
  String get r7ImportChooseCsv => '选择 Termius CSV';

  @override
  String get r7ImportIssueKeyIgnoredForProtocol => '私钥仅适用于 SSH，未为此主机导入该密钥。';

  @override
  String r7ImportIssueExportCertificatesNotRepresented(int count) {
    return '$count 台主机使用带证书的密钥；Termius CSV 无法携带证书。';
  }

  @override
  String r7ImportIssueDuplicateInFile(int row) {
    return '与第 $row 行的主机相同。';
  }

  @override
  String r7ImportIssueSshForwardBlocked(String name) {
    return '$name 未导入：只导入仅限本机回环且端口固定的转发。其他转发请在转发编辑器中添加。';
  }

  @override
  String r7ImportIssueUnknownColumnValue(String name) {
    return '列“$name”中的值未被导入。';
  }

  @override
  String get r7ImportIssuePasswordDroppedForKey =>
      '同时提供了密码和私钥。Atermius 每台主机只保存一种登录方式，因此使用私钥，不导入密码。';

  @override
  String r7ImportIssueDuplicateTags(int count) {
    return '已合并 $count 个重复标签。';
  }

  @override
  String get r7ImportIssueSshBlocked => '无法按原样导入此 OpenSSH 配置。';

  @override
  String get r7ImportDispositionExcluded => '已被你排除';

  @override
  String get r7ImportTransferTitle => 'Termius 导入与导出';

  @override
  String get r7ImportIssueMissingAddress => 'Hostname/IP 为空。';

  @override
  String get r7ImportChooseBundle => '选择 OpenSSH 包（.zip）';

  @override
  String get r7ImportRowPrivateKey => '包含私钥（加密保存，不会显示）';

  @override
  String r7ImportIssueExportKeysNotRepresented(int count) {
    return '$count 台主机使用私钥登录。Termius CSV 模板没有密钥列，因此不会导出密钥。';
  }

  @override
  String r7ImportIssueExportGroupWhitespace(String name) {
    return '主机“$name”：分组名称首尾含空格，Termius 会将其去除。';
  }

  @override
  String get r7ImportExported => '导出文件已保存到所选位置。';

  @override
  String r7ImportIssueNonTemplateColumn(String name) {
    return '列“$name”不在 Termius 模板中。Atermius 会读取它，但 Termius 本身会拒绝包含该列的文件。';
  }

  @override
  String get r7ImportExportFormatBundle => 'OpenSSH 包（.zip）：配置与密钥文件';

  @override
  String r7ImportIssueGroupTooDeep(int count) {
    return '分组最多可嵌套 $count 层。';
  }

  @override
  String get r7ImportNativeUnsupported =>
      '不会读取加密的 Termius 应用数据、Termius 云端保管库或原生备份。请改为从 Termius 导出 CSV，或使用其 OpenSSH 导出。';

  @override
  String get r7ImportIssueMissingHostname => '表头中没有“Hostname/IP”列。';

  @override
  String get r7ImportRowPassword => '包含密码（加密保存，不会显示）';

  @override
  String get r7ImportIssueInvalidPassword => '密码过长或包含 NUL 字符，未被导入。';

  @override
  String get r7ImportIssueInvalidAddress => 'Hostname/IP 不是有效的主机名或地址。';

  @override
  String get r7ImportIssueMissingFields => '此行的列数少于表头，缺失的值按空值处理。';

  @override
  String get r7ImportIssueSshKeyNotInline =>
      'SSH_KEY 不是内联私钥。不会读取密钥名称或文件路径，请在导入后为主机添加密钥。';

  @override
  String r7ImportMoreIssuesHidden(int count) {
    return '另有 $count 条问题未显示。';
  }

  @override
  String r7ImportRowGroup(String path) {
    return '分组：$path';
  }

  @override
  String get r7ImportFailReadOnly => '此保管库为只读，未导入任何内容。';

  @override
  String r7ImportIssueExportTagComma(String name) {
    return '主机“$name”：标签包含“,”或首尾空格；Termius 会按“,”拆分标签并去除空格。';
  }

  @override
  String get r7ImportIssueBundleCertificateMissing =>
      'CertificateFile 不在包内，或不是 OpenSSH 用户证书。';

  @override
  String r7ImportRowForwards(int count) {
    return '端口转发：$count 条';
  }

  @override
  String get r7ImportIssueMissingUsername =>
      'Atermius 中的 SSH 主机需要用户名，请填写 Username 列。';

  @override
  String get r7ImportIssueBundleKeyMissing =>
      'IdentityFile 不在所选包内，不会读取其他文件。请在导入后添加密钥。';

  @override
  String get r7ImportExportFormatOpenSsh => 'OpenSSH 配置';

  @override
  String r7ImportIssueExportJumpHost(String name) {
    return '主机“$name”：其跳板主机不在此次导出中，因此省略了 ProxyJump。';
  }

  @override
  String get r7ImportIssueCertificateWithoutKey => '证书没有对应的私钥，未被导入。';

  @override
  String r7ImportFailPartial(int hosts, int groups, int credentials) {
    return '导入失败且无法完全撤销。失败前已保存：主机 $hosts 台、分组 $groups 个、钥匙串凭据 $credentials 个；在别处被修改的记录或因切换保管库而中断的写入会被保留。重试前请检查主机和钥匙串。';
  }

  @override
  String get r7ImportExportSecretConfirmTitle => '导出可读的机密信息？';

  @override
  String r7ImportIssueExportAliasRewritten(String name) {
    return '已为主机“$name”生成 OpenSSH 安全别名。';
  }

  @override
  String get r7ImportExportSecretConfirmBody =>
      '导出的文件未加密。任何能访问该文件的人或应用（包括同步和备份工具）都能读取其中的密码或私钥。';

  @override
  String get r7ImportExportIncludeKeys => '包含私钥文件（及证书）';

  @override
  String get r7ImportDispositionDuplicate => '已跳过：重复行';

  @override
  String get r7ImportIssueInvalidLabel => '标签包含控制字符或过长。';

  @override
  String get r7ImportExportIncludePasswords => '包含密码';

  @override
  String get r7ImportIssueBundleKeyInvalid =>
      '包内的 IdentityFile 不是私钥（或过大），未被导入。';

  @override
  String r7ImportIssueExportForwards(int count) {
    return '$count 台主机设有端口转发，Termius CSV 无法表示。';
  }

  @override
  String get r7ImportIssueEmptyGroupSegment => '已忽略路径中的空分组名称。';

  @override
  String r7ImportExportSummary(int count) {
    return '将导出 $count 台主机。';
  }

  @override
  String r7ImportIssueSshJumpMissing(String name) {
    return 'ProxyJump“$name”未能对应到唯一一个可导入或已保存的主机。';
  }

  @override
  String get r7ImportModeImport => '导入';

  @override
  String get r7ImportImportDuplicates => '同时导入与现有主机相同的行';

  @override
  String get r7ImportIssueExportTooLarge =>
      '此次导出超出 Atermius 可重新导入的上限（单个文件中的主机或数据过多）。不会保存任何内容，请减少导出的主机数量。';

  @override
  String get r7ImportExportSecretConfirmAccept => '包含机密并导出';

  @override
  String r7ImportIssueExportSharedCredential(int count) {
    return '$count 台主机使用共享钥匙串密码登录；仅在包含密码时才会写入各主机所在行。';
  }

  @override
  String r7ImportIssueAlreadyExists(String name) {
    return '与已保存的主机“$name”相同。';
  }

  @override
  String get r7ImportChooseOpenSsh => '选择 OpenSSH 配置';

  @override
  String r7ImportSummary(int create, int groups, int skipped, int blocked) {
    return '将创建 $create 台 · 新分组 $groups 个 · 跳过 $skipped 条 · 无法导入 $blocked 条';
  }

  @override
  String get r7ImportTemplateColumns =>
      'Termius CSV 列：Groups、Label、Tags、Hostname/IP、Protocol、Port、Username、Password。子分组用“/”分隔，标签用“,”分隔。包含内联私钥的额外 SSH_KEY 列仅在导入时被接受。';

  @override
  String get r7ImportExportOpenSshNoSecrets =>
      '此配置不包含密码或密钥文件。如需包含密钥，请使用 OpenSSH 包。';

  @override
  String get r7ImportExportBundleHelp =>
      '可解压到 ~/.ssh 的标准 OpenSSH 文件（见包内 README）。不是 Termius 保管库；Termius 10.4 不会从中读取证书文件。';

  @override
  String get r7ImportIssueControlCharacter => '某个值包含控制字符。';

  @override
  String r7ImportIssueAtLine(int line, String message) {
    return '第 $line 行：$message';
  }

  @override
  String r7ImportIssueSshHostKeyPolicyIgnored(String name) {
    return '已忽略 $name；Atermius 始终使用自己的已知主机列表验证主机密钥。';
  }

  @override
  String r7ImportIssueDuplicateHeader(String name) {
    return '列“$name”出现了多次。';
  }

  @override
  String get r7ImportFailStale => '预览后主机或分组已发生变化，未导入任何内容。请重新选择文件。';

  @override
  String get r7ImportIssueEmptyFile => '文件为空。';

  @override
  String get r7ImportExportFailed => '无法保存导出文件。';

  @override
  String r7ImportRowTags(String tags) {
    return '标签：$tags';
  }

  @override
  String get r7ImportIntro =>
      '从 Termius CSV 模板或 OpenSSH 配置（包括 termius export-ssh-config 的输出）导入主机。在你检查预览并确认之前不会保存任何内容。';

  @override
  String get r7ImportExportIncludeDesktops =>
      '包含 RDP 和 VNC 主机（Atermius 扩展；Termius 导入后不含连接设置）';

  @override
  String get r7ImportIssueInvalidUsername => '用户名包含空格或控制字符，或过长。';

  @override
  String r7ImportIssueExportPasswordsNotRepresented(int count) {
    return '$count 台主机使用密码登录，OpenSSH 文件无法保存密码。';
  }

  @override
  String get r7ImportIssueCsvTooManyFields => '某行的列数过多。';

  @override
  String get r7ImportModeExport => '导出';

  @override
  String get r7ImportIssueExtraFields => '此行包含超出表头列的值。';

  @override
  String r7ImportRowEndpointNoUser(
    String address,
    String port,
    String protocol,
  ) {
    return '$address:$port · $protocol';
  }

  @override
  String get r7ImportIssueCsvStrayQuote => '未加引号的字段中出现了引号。';

  @override
  String r7ImportIssueUnsupportedProtocol(String name) {
    return '不支持协议“$name”（支持 SSH、RDP 和 VNC）。';
  }

  @override
  String r7ImportIssueExportGroupSlash(String name) {
    return '主机“$name”：分组名称包含“/”，Termius 会将其视为子分组分隔符。';
  }

  @override
  String get r7ImportIssueNoTemplateHeader =>
      '第一行不是 Termius CSV 表头（应包含 Label、Hostname/IP 等列）。';

  @override
  String get r7ImportExportCancelled => '已取消导出，未写入任何文件。';

  @override
  String get r7ImportIssueHeaderOrderNotTermius =>
      '表头与 Termius 模板顺序不同。Atermius 按列名读取，但 Termius 不会导入此文件。';

  @override
  String get r7ImportIssueNameAlreadyUsed => '已有其他已保存的主机使用此名称。';

  @override
  String r7ImportIssueExtensionProtocol(String name) {
    return '协议“$name”是 Atermius 扩展，Termius 的 CSV 模板可能不接受。';
  }

  @override
  String get r7ImportDispositionExisting => '已跳过：已存在';

  @override
  String r7ImportIssueExportSkippedProtocol(int count) {
    return '此格式不导出 $count 台 RDP/VNC 主机。';
  }

  @override
  String get r7ImportIssueInvalidPort => '端口必须是 1 到 65535 之间的数字。';

  @override
  String r7ImportIssueUnknownHeader(String name) {
    return '列“$name”不属于 Termius 模板，其值不会被导入。';
  }

  @override
  String r7ImportIssueExportJumpCount(int count) {
    return '$count 台主机使用了跳板主机，此格式无法表示。';
  }

  @override
  String r7ImportIssueSshOptionIgnored(String name) {
    return 'Atermius 不应用 $name，已忽略。';
  }

  @override
  String r7ImportConfirmBody(int hosts, int groups, int secrets) {
    return '将在当前保管库中创建 $hosts 台加密主机和 $groups 个分组。其中 $secrets 台主机包含密码或私钥，它们仅加密保存在对应主机内。';
  }

  @override
  String r7ImportIssueSshFinding(String directive, String message) {
    return '$directive：$message';
  }

  @override
  String r7ImportIssueExportPassphraseNotExported(int count) {
    return '$count 个导出的密钥保存了口令；口令不会写入，加密密钥使用时会要求输入。';
  }

  @override
  String get r7ImportExportFormatCsv => 'Termius CSV';

  @override
  String get r7ImportIssueInvalidGroup => '分组名称包含控制字符或过长。';

  @override
  String get r7ImportIssueCsvFieldTooLong => '某个字段过长。';

  @override
  String get r7ImportFailRolledBack => '导入失败并已撤销，未保留任何内容。';

  @override
  String get shellLocalInputTooLarge => '输入内容过大，未发送到本地 Shell';

  @override
  String get shellLocalKindSystem => '系统默认 Shell';

  @override
  String get shellLocalKindCmd => '命令提示符 (cmd)';

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
  String get shellLocalOptions => '本地 Shell 选项…';

  @override
  String get shellLocalOptionsTitle => '启动本地 Shell';

  @override
  String get shellLocalShellLabel => 'Shell';

  @override
  String get shellLocalWorkingDirectoryLabel => '工作目录（可选）';

  @override
  String get shellLocalWorkingDirectoryHint => '绝对路径或 ~/文件夹；留空则使用主目录';

  @override
  String get shellLocalStart => '启动 Shell';

  @override
  String get shellLocalInvalidWorkingDirectory => '请输入绝对文件夹路径或 ~/文件夹。';

  @override
  String get shellLocalWorkingDirectoryNotFound => '该工作目录不存在。';

  @override
  String get shellLocalNotInstalled => '此电脑未安装该 Shell。';

  @override
  String get shellLocalUnavailable => '本地 Shell（仅限桌面应用）';

  @override
  String get shellLocalUnavailableDetail =>
      '此处无法在你的电脑上启动 Shell，Atermius 也绝不会在服务器上运行 Shell。请使用 Atermius 桌面应用打开本地 Shell。';

  @override
  String shellLocalTabTitle(String shell) {
    return '本地 · $shell';
  }

  @override
  String shellLocalNewShell(String shell) {
    return '新建 $shell';
  }

  @override
  String get telnetHost => 'Telnet 主机';

  @override
  String get telnetProtocolUnencrypted => 'Telnet（未加密）';

  @override
  String get telnetInteractiveLogin => '在终端中交互登录（不发送任何已保存信息）';

  @override
  String get telnetLoginInteractiveHint =>
      'Telnet 采用交互式登录：请在终端中输入用户名和密码。已保存的密码、密钥和钥匙串条目绝不会通过 Telnet 发送。';

  @override
  String get telnetPlaintextWarningTitle => 'Telnet 未加密';

  @override
  String get telnetPlaintextWarningBody =>
      '通过 Telnet 发送的所有内容（包括您输入的密码）均以明文传输，可能在网络中被读取或篡改。请仅在可信网络或不支持 SSH 的设备上使用。已保存的主机条目本身仍保持加密。';

  @override
  String telnetPlaintextTerminalNotice(String endpoint) {
    return '到 $endpoint 的 Telnet 连接未加密：您输入的任何内容（包括密码）都以明文发送。';
  }

  @override
  String telnetConnectedToEndpoint(String endpoint) {
    return 'Telnet 已连接到 $endpoint（未加密）';
  }

  @override
  String get telnetConnectedUnencrypted => 'Telnet 已连接（未加密）';

  @override
  String get telnetConnecting => 'Telnet 正在连接';

  @override
  String get telnetDisconnected => 'Telnet 已断开';

  @override
  String get telnetConnectionClosedTerminal => '\r\n[Telnet 连接已关闭]\r\n';

  @override
  String get telnetConnectionRefused => 'Telnet 服务器拒绝了连接。';

  @override
  String get telnetConnectionTimedOut => 'Telnet 连接超时。';

  @override
  String get telnetHostLookupFailed => '无法解析 Telnet 主机名。';

  @override
  String get telnetHostUnreachable => '无法连接到 Telnet 主机。';

  @override
  String get telnetRelayUnavailable => '无法通过服务器中继打开 Telnet。';

  @override
  String get telnetUnsupportedInBrowser =>
      '在浏览器中使用 Telnet 需要已登录且为该目标启用了中继的 Atermius 服务器。浏览器本地配置文件无法打开原始 TCP 连接。';

  @override
  String get telnetProtocolError => 'Telnet 服务器发送了无效或过量的协商数据，连接已关闭。';

  @override
  String get telnetConnectionLost => 'Telnet 连接已断开。';

  @override
  String get telnetConnectCancelled => 'Telnet 连接已取消。';

  @override
  String get telnetHostSettingsInvalid =>
      'Telnet 主机不能使用已保存的登录信息、钥匙串条目、跳板机或端口转发。请在终端中交互登录。';

  @override
  String get telnetQuickConnectNoUser =>
      'Telnet 不会自动发送用户名。请使用：telnet 主机[:端口]，并在终端中登录。';

  @override
  String get telnetInputTooLarge => '粘贴内容过大，无法通过 Telnet 发送（上限 1 MiB）。未发送任何内容。';

  @override
  String get accountSettingsTitle => '账户与登录';

  @override
  String get accountSettingsDescription => '查看此设备使用的账户和服务器、管理会话，或登录账户。';

  @override
  String get accountSettingsCurrentMode => '当前模式';

  @override
  String get accountSettingsModeAccount => '账户与同步';

  @override
  String get accountSettingsModeLocal => '仅本地（此设备）';

  @override
  String get accountSettingsSignedInAs => '登录身份';

  @override
  String get accountSettingsServer => '服务器';

  @override
  String get accountSettingsSessionUnlocked => '已在此设备上登录并解锁';

  @override
  String get accountSettingsActiveVault => '当前保险库';

  @override
  String get accountSettingsNoVault => '未选择保险库';

  @override
  String get accountSettingsInstanceAdmin => '实例管理员';

  @override
  String get accountSettingsSessionActions => '会话';

  @override
  String get accountSettingsSecurityAction => '密码、两步验证与恢复';

  @override
  String get accountSettingsSignOutTitle => '要退出此账户吗？';

  @override
  String get accountSettingsSignOutBody =>
      '此设备上该账户的已打开会话将被关闭。加密的保险库数据仍保留在服务器上，再次登录时需要输入账户密码。';

  @override
  String get accountSettingsSwitchToLocalTitle => '要切换到本地模式吗？';

  @override
  String get accountSettingsSwitchToLocalBody =>
      '此设备上的账户工作区及其已打开的会话将被关闭。账户中的任何内容都不会复制到本地配置文件。';

  @override
  String get accountSettingsLocalNotSignedIn => '未登录账户';

  @override
  String get accountSettingsLocalSyncRequiresAccount =>
      '本地配置文件仅存储在此设备上，不会同步。如需在设备之间同步主机，请登录你的 Atermius 服务器账户。';

  @override
  String get accountSettingsSignIn => '登录或连接服务器';

  @override
  String get accountSettingsSignInTitle => '要打开账户登录吗？';

  @override
  String get accountSettingsSignInBody =>
      '本地配置文件将被锁定，其已打开的会话将被关闭。本地主机仍保留在此设备上，不会被上传。登录后，你可以在“数据与迁移”中查看是否迁移它们。';

  @override
  String get themeSettingTitle => '主题';

  @override
  String themeSettingSystemResolved(Object theme) {
    return '跟随系统 · 当前为$theme';
  }

  @override
  String get themeOptionSystem => '跟随系统';

  @override
  String get themeSettingDescription => '更改应用的窗口、菜单和面板。终端颜色和远程桌面画面保持各自的配色。';

  @override
  String get themeOptionLight => '浅色';

  @override
  String get themeOptionDark => '深色';

  @override
  String get themeSettingSaveFailed => '主题已在本次运行中切换，但无法保存到此设备。';

  @override
  String get syncSettingsPreferenceSaveFailed => '无法在此设备上保存此选项。它将在应用重启前有效。';

  @override
  String get syncSettingsSyncingNow => '正在同步…';

  @override
  String get syncSettingsDeviceOnly => '这些同步选项仅适用于此设备。';

  @override
  String get syncSettingsPreferenceSaving => '正在保存…';

  @override
  String get syncSettingsAutomaticOffDescription =>
      '此设备已关闭。编辑会以加密形式保留在此设备的队列中，直到你选择“立即同步”或重新开启自动同步。';

  @override
  String get syncSettingsNever => '从未';

  @override
  String get syncSettingsSignInRequired => '同步需要在此设备上登录账户。';

  @override
  String syncSettingsResultNotCompleted(String status) {
    return '同步未完成。当前状态：$status。';
  }

  @override
  String get syncSettingsWaitingToUpload => '等待上传';

  @override
  String syncSettingsResultFailed(String error) {
    return '同步未完成：$error';
  }

  @override
  String syncSettingsQueuedWhileOff(int count) {
    return '此设备上排队的加密更改：$count。选择“立即同步”或开启自动同步后会上传。';
  }

  @override
  String get syncSettingsTitle => '同步';

  @override
  String syncSettingsResultPending(int count) {
    return '同步已运行，但仍有加密更改等待上传：$count。';
  }

  @override
  String get syncSettingsAutomaticTitle => '自动同步';

  @override
  String get syncSettingsPreferenceLoading => '正在加载此设备的同步选项…加载完成后才会开始自动同步。';

  @override
  String get syncSettingsPreferenceReadFailedShort =>
      '在能读取已保存的选项之前，自动同步将保持暂停。请重试，或选择一个设置来替换它。';

  @override
  String get syncSettingsResultCompleted => '同步完成。没有等待上传的内容。';

  @override
  String get syncSettingsAutomaticOnDescription => '编辑会在后台上传，其他设备的更改会在后台下载。';

  @override
  String get syncSettingsPreferenceReadFailed => '已暂停：无法读取此设备保存的选项。';

  @override
  String get syncSettingsSyncNow => '立即同步';

  @override
  String get syncSettingsStatus => '状态';

  @override
  String get settingsThemeShortcutsTitle => '快捷键';

  @override
  String get settingsThemeShortcutsDescription => '选择在终端中使用的键盘快捷键。';

  @override
  String get settingsThemeTitle => '主题';

  @override
  String settingsThemeOverlayActive(String name) {
    return '本设备上的终端当前改用设备配色 $name。选择已保存的主题或保存其他主题后，将切换回来。';
  }

  @override
  String get settingsThemeDescription => '选择应用的浅色或深色模式、终端字号和终端配色。';

  @override
  String get wallpaperSettingTitle => '壁纸';

  @override
  String get wallpaperSettingDescription =>
      '在应用和终端窗格后方显示一张图片。只有图片会被模糊，文字、控件、终端文字和远程桌面画面始终保持清晰。';

  @override
  String get wallpaperChooseImage => '选择图片…';

  @override
  String get wallpaperReplaceImage => '更换图片…';

  @override
  String get wallpaperReset => '移除壁纸';

  @override
  String get wallpaperNoImage => '未设置壁纸';

  @override
  String get wallpaperPreviewLabel => '壁纸预览';

  @override
  String get wallpaperLoading => '正在加载壁纸…';

  @override
  String get wallpaperMissing => '已保存的壁纸图片丢失或无法读取。请选择新图片或移除壁纸。';

  @override
  String get wallpaperModeTitle => '布局';

  @override
  String get wallpaperModeWindow => '整个窗口';

  @override
  String get wallpaperModeWindowHint => '一张图片铺满整个窗口。';

  @override
  String get wallpaperModePanes => '跟随分屏';

  @override
  String get wallpaperModePanesHint => '每个终端窗格各自显示图片，并随调整大小和重新排列而变化。';

  @override
  String wallpaperBlurValue(String value) {
    return '模糊：$value';
  }

  @override
  String wallpaperErrorTooLarge(int limit) {
    return '此图片超过 $limit MB。';
  }

  @override
  String get wallpaperErrorUnsupported => '请选择 PNG、JPEG 或静态 WebP 图片。';

  @override
  String get wallpaperErrorCorrupt => '无法读取此图片，文件可能已损坏。';

  @override
  String wallpaperErrorDimensions(int side) {
    return '此图片尺寸过大（每边最多 $side 像素）。';
  }

  @override
  String get wallpaperErrorStorage => '无法在此设备上保存壁纸。';

  @override
  String get wallpaperSaveFailed => '壁纸已在本次运行中更改，但无法保存到此设备。';

  @override
  String get wallpaperDeviceNote => '图片副本保存在此设备上的应用存储中。独立窗口在打开时使用相同的壁纸。';

  @override
  String get fileManagerPasteInto => '粘贴到文件夹';

  @override
  String get fileManagerPathCopied => '路径已复制';

  @override
  String fileManagerCopying(String name) {
    return '正在复制“$name”…';
  }

  @override
  String get fileManagerDropFailed => '无法读取拖放的项目，未上传任何内容。';

  @override
  String get fileManagerOperationUnsupported => '此连接不支持文件管理操作。';

  @override
  String fileManagerDeleteConfirm(String name) {
    return '删除“$name”？此操作无法撤销。';
  }

  @override
  String get fileManagerOpen => '打开';

  @override
  String get fileManagerPasteHere => '粘贴到此处';

  @override
  String fileManagerUploading(String name, int index, int count) {
    return '正在上传“$name”（$index/$count）…';
  }

  @override
  String fileManagerMoveConfirm(String name, String folder) {
    return '将“$name”移动到“$folder”？';
  }

  @override
  String get fileManagerNameConflictTitle => '名称已被使用';

  @override
  String get fileManagerSkip => '跳过';

  @override
  String fileManagerClipboardCut(String name) {
    return '已剪切“$name”——在此标签页中粘贴即可移动';
  }

  @override
  String fileManagerRenameTitle(String name) {
    return '重命名“$name”';
  }

  @override
  String fileManagerDeleteFolderConfirm(String name, int count) {
    return '删除文件夹“$name”及其中的 $count 个项目？符号链接只会被移除，不会被跟随。此操作无法撤销。';
  }

  @override
  String get fileManagerClearClipboard => '清除文件剪贴板';

  @override
  String get fileManagerRename => '重命名';

  @override
  String fileManagerErrorUnsupportedEntry(String name) {
    return '“$name”是符号链接、特殊文件或名称不受支持。文件夹复制不会跟随或重建此类项目，因此未复制任何内容。';
  }

  @override
  String get fileManagerKeepBoth => '保留两者';

  @override
  String fileManagerErrorFileTooLarge(String name) {
    return '“$name”超过单个文件 1 GiB 的复制上限。';
  }

  @override
  String get fileManagerCut => '剪切';

  @override
  String get fileManagerDropNothingAccepted => '此处只能拖放文件。文件夹和指向其他位置的链接不会上传。';

  @override
  String get fileManagerPaste => '粘贴';

  @override
  String get fileManagerErrorSourceChanged => '该项目已在服务器上更改或消失。请刷新后重试。';

  @override
  String fileManagerErrorExists(String name) {
    return '此处已存在“$name”，未替换任何内容。';
  }

  @override
  String get fileManagerMoveTitle => '移动项目';

  @override
  String get fileManagerErrorIntoItself => '无法将文件夹移动或复制到其自身内部。';

  @override
  String get fileManagerCancelled => '已取消。未做其他更改。';

  @override
  String fileManagerDropTooManyFiles(int count) {
    return '每次最多拖放 $count 个文件。';
  }

  @override
  String get fileManagerBusy => '另一个文件操作仍在进行中。';

  @override
  String get fileManagerCopyPath => '复制路径';

  @override
  String fileManagerNameConflictKeepBoth(String name) {
    return '此文件夹中已存在“$name”。是否在新名称后添加“(copy)”以保留两者？现有项目不会被替换。';
  }

  @override
  String fileManagerMoving(String name) {
    return '正在移动“$name”…';
  }

  @override
  String fileManagerClipboardCopied(String name) {
    return '已复制“$name”——可在此标签页中粘贴';
  }

  @override
  String get fileManagerDropNeedsSftp => '拖放的文件通过 SFTP 上传。请使用 SFTP 打开此文件夹后再上传。';

  @override
  String fileManagerDeleting(String name) {
    return '正在删除“$name”…';
  }

  @override
  String fileManagerUploadSummary(int uploaded, int skipped, int failed) {
    return '已上传 $uploaded · 已跳过 $skipped · 失败 $failed';
  }

  @override
  String get fileManagerInvalidName => '请使用不含斜杠、反斜杠或控制字符的单个名称。';

  @override
  String fileManagerErrorLimitExceeded(int entries, int depth) {
    return '此文件夹过大，无法执行文件管理操作（上限 $entries 项、$depth 层或 2 GiB）。未做任何更改。';
  }

  @override
  String get fileManagerCopy => '复制';

  @override
  String get fileManagerDropTargetChanged =>
      '检查拖放内容时，此文件标签页的文件夹或连接已变化。未上传任何内容，请重新拖放文件。';

  @override
  String fileManagerUploadConflict(String name) {
    return '此文件夹中已存在“$name”。是否以新的“(copy)”名称上传，或跳过？现有文件不会被替换。';
  }

  @override
  String get fileManagerMove => '移动';

  @override
  String get homeAddSerialConsoleDetail => '以 8N1 打开本机的 COM 端口。不会在服务器上运行任何内容。';

  @override
  String get homeSharingThisDevice => '在本设备在线';

  @override
  String get homeAddShell => 'Shell（系统默认）';

  @override
  String homeSharingSharedPresenceUnknown(int members) {
    return '已共享 · $members 名成员 · 状态未知';
  }

  @override
  String get homeSharingLoading => '正在加载成员…';

  @override
  String get homeAddTooltip => '添加主机，或打开本地 Shell / 串口 Console';

  @override
  String get homeAddButton => '添加';

  @override
  String get homeSharingLocalOnly => '仅本地';

  @override
  String get homeAddSerialConsolePort => '串口';

  @override
  String homeSharingMore(int count, String names) {
    return '另外 $count 人：\n$names';
  }

  @override
  String get homeAddSerialConsoleOpen => '打开 Console';

  @override
  String homeSharingSharedOnline(int members, int online) {
    return '已共享 · $members 名成员 · $online 人在线';
  }

  @override
  String get homeAddSerialConsoleBaud => '波特率';

  @override
  String homeSharingYou(String name) {
    return '$name（你）';
  }

  @override
  String get homeAddSerialConsoleTitle => '打开串口 Console';

  @override
  String get homeAddSerialConsole => '串口 Console（COM）…';

  @override
  String get homeSharingLocalDetail =>
      '此本地配置文件仅加密保存在本设备上。它没有保险库成员，其他人无法看到，也不会发送在线状态。登录账户保险库即可与他人共享主机。';

  @override
  String get homeAddSerialConsoleUnavailable => '串口 Console（仅 Windows 应用）';

  @override
  String get homeSharingPresenceUnknown => '状态未知';

  @override
  String get homeSharingOffline => '离线';

  @override
  String get homeSharingMembersUnavailable => '成员未加载';

  @override
  String get homeSharingLocalTooltip => '本设备上的本地配置文件 — 未与任何人共享';

  @override
  String get homeSharingDetailsTooltip => '查看保险库成员和在线状态';

  @override
  String get homeSharingIndividual => '仅你自己';

  @override
  String get homeSharingOnline => '在线';

  @override
  String sidebarResizeWidthValue(int width) {
    return '宽 $width 像素';
  }

  @override
  String get sidebarResizeHint => '拖动，或使用左右方向键调整宽度';

  @override
  String get sidebarResizeHandle => '调整侧栏宽度';

  @override
  String get fileEditLaunchFailed => '没有应用能打开此文件。';

  @override
  String get fileEditAtomicUnsupported => '此服务器不支持原子替换文件，因此未上传任何内容。';

  @override
  String get fileEditUpload => '上传';

  @override
  String get fileEditLocalRejected => '本地副本已不再是其私有文件夹中的普通文件。未上传任何内容。';

  @override
  String get fileEditConflictTitle => '服务器副本已更改';

  @override
  String fileEditUploadedChangedAgain(String name) {
    return '已上传“$name”，但发送期间本地又发生了更改。准备好后请再次上传。';
  }

  @override
  String get fileEditBlockedType => '此类文件打开时可能会被执行，因此不会在外部打开。请改用“编辑文本”或“下载”。';

  @override
  String get fileEditStatusRejected => '本地副本已被拒绝';

  @override
  String fileEditFooterTitle(int count) {
    return '正在外部编辑（$count）';
  }

  @override
  String get fileEditOpenExternal => '在外部应用中打开';

  @override
  String get fileEditSessionChanged => '此文件标签页的连接已关闭或已更改。未上传任何内容。';

  @override
  String get fileEditStatusChanged => '本地已更改 — 未上传';

  @override
  String fileEditTooMany(int count) {
    return '最多可同时在外部编辑 $count 个文件。';
  }

  @override
  String get fileEditLocalMissing => '本地副本已丢失。未上传任何内容。';

  @override
  String get fileEditNotRegular => '只能在外部编辑普通远程文件。';

  @override
  String get fileEditStatusWatching => '正在监视保存';

  @override
  String get fileEditIgnore => '忽略';

  @override
  String fileEditOpened(String name) {
    return '已在外部打开“$name”。在那里保存后，请在下方选择“上传”。';
  }

  @override
  String get fileEditTooLarge => '只能在外部编辑不超过 10 MiB 的文件。';

  @override
  String get fileEditLocalTooLarge => '本地副本超过 10 MiB。未上传任何内容。';

  @override
  String get fileEditStatusUploading => '正在上传…';

  @override
  String get fileEditUnavailable => '外部编辑需要桌面应用。请使用“编辑文本”在此修改该文件。';

  @override
  String fileEditConflictMessage(String name) {
    return '打开后，服务器上的“$name”已被更改。要用本地版本替换服务器副本吗？';
  }

  @override
  String get fileEditStatusConflict => '服务器上的文件也已更改';

  @override
  String fileEditUploaded(String name) {
    return '已上传“$name”。';
  }

  @override
  String get fileEditStop => '停止监视';

  @override
  String get fileEditStatusFailed => '上传失败 — 已保留本地更改';

  @override
  String get fileEditKeepLocal => '保留本地';

  @override
  String get fileEditReplace => '替换服务器副本';

  @override
  String get cloudAccessShareMenu => '共享…';

  @override
  String cloudAccessShareTitle(String name) {
    return '共享 $name';
  }

  @override
  String get cloudAccessClose => '关闭';

  @override
  String get cloudAccessTabMembers => '成员与团队';

  @override
  String get cloudAccessTabLinks => '临时链接';

  @override
  String get cloudAccessGatewayTrustNotice =>
      '访客通过本服务器的网关连接。为此，该 Host 的登录信息会加密交给服务器网关保管，直到链接被撤销或过期。服务器运营者（或入侵服务器者）可以解开它并看到会话内容。访客不会通过此功能获得密码或私钥，但在会话中可以执行该账户允许的任何操作。请使用专用的低权限账户。';

  @override
  String get cloudAccessLinksHeading => '此 Host 的链接';

  @override
  String get cloudAccessNewLink => '新建链接';

  @override
  String get cloudAccessNoLinks => '尚无临时链接。';

  @override
  String get cloudAccessStatusActive => '有效';

  @override
  String get cloudAccessStatusScheduled => '已排期';

  @override
  String get cloudAccessStatusExpired => '已过期';

  @override
  String get cloudAccessStatusPaused => '已暂停';

  @override
  String get cloudAccessStatusSuspended => '已挂起';

  @override
  String get cloudAccessStatusRevoked => '已撤销';

  @override
  String cloudAccessValidUntil(String time) {
    return '有效至 $time';
  }

  @override
  String cloudAccessRedemptionCount(String used, String max) {
    return '已打开 $used/$max';
  }

  @override
  String cloudAccessActiveSessions(String count) {
    return '$count 个活动';
  }

  @override
  String get cloudAccessMore => '更多';

  @override
  String get cloudAccessActivity => '活动';

  @override
  String get cloudAccessPause => '暂停';

  @override
  String get cloudAccessResume => '恢复';

  @override
  String get cloudAccessRotate => '更换密钥';

  @override
  String get cloudAccessRevoke => '撤销';

  @override
  String get cloudAccessRevokeLinkTitle => '撤销此链接？';

  @override
  String get cloudAccessRevokeLinkMessage =>
      '链接立即失效，活动的访客会话会在几秒内关闭。撤销无法撤回访客已在 Host 上执行的操作。';

  @override
  String get cloudAccessRotateTitle => '生成新的链接密钥？';

  @override
  String get cloudAccessRotateMessage => '当前网址将失效，其访客会被断开。你将获得一个新网址用于发送。';

  @override
  String get cloudAccessScheduleStart => '稍后开始';

  @override
  String get cloudAccessStartsNow => '立即开始';

  @override
  String get cloudAccessPickStart => '请选择开始时间';

  @override
  String get cloudAccessLifetime => '有效期';

  @override
  String get cloudAccessOneHour => '1 小时';

  @override
  String get cloudAccessOneDay => '24 小时';

  @override
  String get cloudAccessOneWeek => '7 天';

  @override
  String get cloudAccessCustom => '自定义…';

  @override
  String cloudAccessWindowSummary(String start, String end, String utc) {
    return '从 $start 到 $end（本地时间；UTC $utc）。以服务器时钟为准。';
  }

  @override
  String get cloudAccessEndBeforeStart => '结束时间必须晚于开始时间且在未来。';

  @override
  String get cloudAccessMaxRedemptions => '链接可打开次数';

  @override
  String get cloudAccessMaxRedemptionsHelp => '默认 1。每个点击“继续”的浏览器消耗一次。';

  @override
  String get cloudAccessUnlimited => '不限';

  @override
  String get cloudAccessRedemptionsRange => '请输入 1–1000，或选择“不限”。';

  @override
  String get cloudAccessMaxConnections => '连接尝试次数（可选）';

  @override
  String get cloudAccessMaxConnectionsHelp => '留空表示不限。被拒绝的尝试不计数。';

  @override
  String get cloudAccessConnectionsRange => '请输入正整数或留空。';

  @override
  String get cloudAccessConcurrent => '同时连接数';

  @override
  String get cloudAccessViewOnly => '仅观看';

  @override
  String get cloudAccessViewOnlyHelp => '服务器会阻止键盘、鼠标与粘贴。';

  @override
  String get cloudAccessClipboardToRemote => '允许粘贴到 Host';

  @override
  String get cloudAccessClipboardFromRemote => '允许从 Host 复制';

  @override
  String get cloudAccessFilesLocked => '访客无法使用文件传输、驱动器、打印与录制。';

  @override
  String get cloudAccessCustomSlug => '自定义地址（可选）';

  @override
  String get cloudAccessCustomSlugHelp =>
      '3–48 个小写字母、数字或连字符。地址不是密码，可能被猜到，请避免敏感词。';

  @override
  String get cloudAccessGuestTitle => '向访客显示的标题（可选）';

  @override
  String get cloudAccessGuestTitleHelp => '使用链接密钥加密，服务器无法读取。';

  @override
  String get cloudAccessCancel => '取消';

  @override
  String get cloudAccessCreateLink => '创建链接';

  @override
  String get cloudAccessLinkReady => '链接已创建';

  @override
  String get cloudAccessCopyLink => '复制链接';

  @override
  String get cloudAccessCopied => '已复制';

  @override
  String get cloudAccessShownOnce => '完整链接仅显示这一次。如丢失，请更换密钥。';

  @override
  String get cloudAccessSendSafely =>
      '任何持有此链接的人都可以打开。请只通过可信渠道发送；部分邮件扫描器可能会打开并消耗链接。';

  @override
  String get cloudAccessDone => '完成';

  @override
  String get cloudAccessBack => '返回';

  @override
  String cloudAccessActivityFor(String link) {
    return '活动 · $link';
  }

  @override
  String get cloudAccessGuestSessions => '访客会话';

  @override
  String get cloudAccessNoSessions => '尚无人打开此链接。';

  @override
  String cloudAccessSessionSince(String time) {
    return '自 $time 起活动';
  }

  @override
  String cloudAccessSessionEnded(String reason) {
    return '已结束（$reason）';
  }

  @override
  String get cloudAccessTerminate => '结束会话';

  @override
  String get cloudAccessAuditEvents => '审计（仅元数据）';

  @override
  String get cloudAccessMembersExplainer =>
      '成员通过加密 Vault 获得此 Host。只有在你逐一确认对方设备后，接收者才会获得 Vault 密钥；组织管理员无法自行获得。';

  @override
  String get cloudAccessDedicatedVault => '仅共享此 Host';

  @override
  String get cloudAccessDedicatedVaultHelp =>
      '将创建一个新的共享 Vault，只包含此 Host 的副本及下列项目。当前 Vault 中的其他 Host 和凭据保持私密。';

  @override
  String get cloudAccessSharingVaultName => '共享 Vault 名称';

  @override
  String cloudAccessSharingVaultDefaultName(String name) {
    return '共享 · $name';
  }

  @override
  String get cloudAccessWillCopy => '将被复制：';

  @override
  String cloudAccessDependencyJumpHost(String name) {
    return '跳板主机 $name';
  }

  @override
  String cloudAccessDependencyCredential(String name) {
    return '凭据 $name';
  }

  @override
  String cloudAccessDependencyKnownHost(String key) {
    return '受信任的主机密钥 $key';
  }

  @override
  String cloudAccessDependencyGroup(String name) {
    return '不复制分组 $name';
  }

  @override
  String cloudAccessBlockerMissingJump(String name) {
    return '$name 使用的跳板主机不在此 Vault 中。';
  }

  @override
  String cloudAccessBlockerMissingCredential(String name) {
    return '$name 引用的凭据不在此 Vault 中。';
  }

  @override
  String cloudAccessBlockerJumpLoop(String name) {
    return '$name 的跳板链存在循环。';
  }

  @override
  String get cloudAccessConsentCopy => '我同意将上述项目复制到新 Vault。';

  @override
  String get cloudAccessCreateSharingVault => '创建共享 Vault';

  @override
  String get cloudAccessWholeVaultHeading => '或共享整个 Vault';

  @override
  String get cloudAccessWholeVaultHelp => '接收者将看到当前 Vault 中的所有 Host、凭据和代码片段。';

  @override
  String get cloudAccessManageWholeVault => '管理整个 Vault 的访问';

  @override
  String get cloudAccessAttachOrg => '选择组织';

  @override
  String get cloudAccessAttachOrgHelp => '授权针对你管理的某个组织的成员和团队。';

  @override
  String get cloudAccessAttach => '使用';

  @override
  String get cloudAccessManageOrganizations => '管理组织';

  @override
  String cloudAccessGrantsIn(String org) {
    return '$org 中的访问';
  }

  @override
  String get cloudAccessAddGrant => '添加成员或团队';

  @override
  String cloudAccessTeamLabel(String name) {
    return '团队 $name';
  }

  @override
  String get cloudAccessRoleViewer => '查看者';

  @override
  String get cloudAccessRoleEditor => '编辑者';

  @override
  String get cloudAccessRemove => '移除';

  @override
  String get cloudAccessKeyDistribution => '等待密钥';

  @override
  String get cloudAccessKeyDistributionHelp =>
      '在分发 Vault 密钥前，请通过其他渠道与接收者核对每个指纹。';

  @override
  String get cloudAccessWaitingForDevice => '等待接收者在设备上打开“组织”';

  @override
  String get cloudAccessWaitingForOwner => '等待你确认';

  @override
  String get cloudAccessWaitingForRecipient => '密钥已发送，等待接收者接受';

  @override
  String get cloudAccessRoleDiffers => '签名角色与授权不同；需轮换或重新邀请以更改';

  @override
  String cloudAccessDeviceFingerprint(String fingerprint) {
    return '设备 $fingerprint';
  }

  @override
  String get cloudAccessConfirmFingerprintTitle => '确认此设备';

  @override
  String cloudAccessConfirmFingerprintMessage(String user, String fingerprint) {
    return '将 Vault 密钥交付给 $user 的设备 $fingerprint？仅在 $user 已向你确认此指纹时继续。';
  }

  @override
  String get cloudAccessDeliverKey => '交付密钥';

  @override
  String get cloudAccessRemovalPending =>
      '服务器访问已被阻止。请轮换 Vault 密钥以在加密层面移除此成员，并更换其见过的凭据。';

  @override
  String get cloudAccessKeepDirect => '保留为直接成员';

  @override
  String get cloudAccessRotateToRemove => '轮换密钥';

  @override
  String get cloudAccessRestrictedToViewer => '在签名角色更新前仅可查看';

  @override
  String get cloudAccessOrganizations => '组织';

  @override
  String get cloudAccessOrganizationsSubtitle => '成员、团队与邀请';

  @override
  String get cloudAccessOrganizationsExplainer =>
      '组织名称、成员、角色与团队对本服务器可见。加入组织本身不会给你任何 Vault 密钥。';

  @override
  String get cloudAccessPendingJoin => '你打开了组织邀请——请查看';

  @override
  String get cloudAccessJoinOrganization => '加入组织';

  @override
  String get cloudAccessJoinLinkField => '邀请链接';

  @override
  String get cloudAccessJoinInvalid => '这不是有效的邀请链接。';

  @override
  String get cloudAccessReview => '查看';

  @override
  String cloudAccessJoinSummary(String inviter, String role) {
    return '$inviter 邀请你成为$role';
  }

  @override
  String get cloudAccessJoin => '加入';

  @override
  String get cloudAccessJoined => '已加入。Vault 所有者仍需确认你的设备，你才会收到共享 Vault。';

  @override
  String get cloudAccessSharedVaultKeys => '共享 Vault 密钥';

  @override
  String get cloudAccessSharedVaultKeysHelp => '发布本设备的公钥，并接受所有者已确认本设备的 Vault。';

  @override
  String get cloudAccessCheckDeliveries => '检查共享 Vault';

  @override
  String cloudAccessDeliveriesAccepted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已添加 $count 个共享 Vault。',
      zero: '没有新的共享 Vault。',
    );
    return '$_temp0';
  }

  @override
  String get cloudAccessYourOrganizations => '你的组织';

  @override
  String get cloudAccessNewOrganization => '新建组织';

  @override
  String get cloudAccessOrganizationName => '组织名称';

  @override
  String get cloudAccessNoOrganizations => '你尚未加入任何组织。';

  @override
  String cloudAccessMemberCount(String count) {
    return '$count 名成员';
  }

  @override
  String get cloudAccessOrgRoleOwner => '所有者';

  @override
  String get cloudAccessOrgRoleAdmin => '管理员';

  @override
  String get cloudAccessOrgRoleMember => '成员';

  @override
  String get cloudAccessSave => '保存';

  @override
  String get cloudAccessMembers => '成员';

  @override
  String get cloudAccessInviteMember => '邀请';

  @override
  String get cloudAccessInviteUsername => '用户名（可选）';

  @override
  String get cloudAccessInviteUsernameHelp => '将邀请限定于某个现有账户。新用户需先获得实例管理员的账户邀请。';

  @override
  String get cloudAccessRole => '角色';

  @override
  String get cloudAccessInitialTeam => '团队';

  @override
  String get cloudAccessNoTeam => '无团队';

  @override
  String get cloudAccessCreateInvitation => '创建邀请';

  @override
  String get cloudAccessInvitationReady => '邀请链接已创建';

  @override
  String get cloudAccessCopyInvitation => '复制邀请链接';

  @override
  String get cloudAccessLeave => '退出';

  @override
  String get cloudAccessRemoveMemberTitle => '从组织中移除？';

  @override
  String get cloudAccessRemoveMemberMessage =>
      '通过组织授权获得的访问将被立即阻止。随后 Vault 所有者应轮换受影响 Vault 的密钥。';

  @override
  String get cloudAccessTeams => '团队';

  @override
  String get cloudAccessNewTeam => '新建团队';

  @override
  String get cloudAccessTeamName => '团队名称';

  @override
  String cloudAccessTeamMembers(String team) {
    return '$team 的成员';
  }

  @override
  String get cloudAccessInvitations => '邀请';

  @override
  String get cloudAccessAnyAccount => '任意账户';

  @override
  String get cloudAccessErrorGeneric => '请求未能完成。';

  @override
  String get cloudAccessErrorLinksUnavailable => '此服务器未配置临时链接。';

  @override
  String get cloudAccessErrorOrganizationsUnavailable => '此服务器未启用组织。';

  @override
  String get cloudAccessErrorProtocolUnavailable => '此服务器不支持共享该 Host 的协议。';

  @override
  String get cloudAccessErrorOwnerRequired => '只有 Vault 所有者可以通过链接共享。';

  @override
  String get cloudAccessErrorJumpHost => '使用跳板主机的 Host 无法通过网关共享。';

  @override
  String get cloudAccessErrorPortForward => '带有端口转发配置的 Host 无法通过网关共享。';

  @override
  String get cloudAccessErrorHostKeyRequired => '共享前请先连接一次并信任此 Host 的 SSH 密钥。';

  @override
  String get cloudAccessErrorCertificateRequired =>
      '共享前请先连接一次并信任此 Host 的 RDP 证书。';

  @override
  String get cloudAccessErrorLoginRequired => '共享前请为此 Host 保存登录信息。';

  @override
  String get cloudAccessErrorHostChanged => 'Host 已更改或尚未同步。请同步后重试。';

  @override
  String get cloudAccessErrorPlanBlocked => '请先解决列出的问题。';

  @override
  String get cloudAccessErrorTargetDenied => '服务器的共享策略不允许此 Host 地址。';

  @override
  String get cloudAccessErrorSlugTaken => '此地址不可用。';

  @override
  String get cloudAccessErrorSlugInvalid => '请使用 3–48 个小写字母、数字或中间连字符。';

  @override
  String get cloudAccessErrorTooManyLinks => '活动链接过多，请先撤销一些。';

  @override
  String get cloudAccessErrorInvalidOptions => '服务器不允许这些链接选项。';

  @override
  String get cloudAccessErrorOrgRoleRequired => '需要组织所有者或管理员角色。';

  @override
  String get cloudAccessErrorOrgCreationRestricted => '此处只有实例管理员可以创建组织。';

  @override
  String get cloudAccessErrorLastOwner => '组织至少需要一位所有者。';

  @override
  String get cloudAccessErrorInvitationUnavailable => '此邀请不可用。';

  @override
  String get cloudAccessErrorAccountNotFound => '没有使用此用户名的活动账户。';

  @override
  String get cloudAccessErrorRateLimited => '尝试次数过多，请稍后再试。';

  @override
  String get cloudAccessGuestWindowTitle => 'Atermius 共享访问';

  @override
  String get cloudAccessGuestLanding => '你收到了一个 Atermius 临时访问链接';

  @override
  String get cloudAccessGuestLandingHelp =>
      '在你点击继续之前不会发生任何事。继续可能会消耗该链接的一次可用次数。';

  @override
  String get cloudAccessGuestContinue => '继续';

  @override
  String get cloudAccessGuestHeading => '共享访问';

  @override
  String cloudAccessGuestValidUntil(String time) {
    return '此会话于 $time 结束';
  }

  @override
  String get cloudAccessGuestViewOnly => '仅观看';

  @override
  String get cloudAccessGuestInteractive => '可交互';

  @override
  String get cloudAccessGuestClipboardOn => '允许剪贴板';

  @override
  String get cloudAccessGuestClipboardOff => '剪贴板关闭';

  @override
  String get cloudAccessGuestConnect => '连接';

  @override
  String get cloudAccessGuestDisconnect => '断开';

  @override
  String get cloudAccessGuestLeave => '结束我的访问';

  @override
  String get cloudAccessGuestLeft => '你的访问已结束，可以关闭此标签页。';

  @override
  String get cloudAccessGuestTrustNote => '此会话经由分享者的 Atermius 服务器，服务器可以看到会话内容。';

  @override
  String get cloudAccessGuestUnavailable => '此链接不可用。';

  @override
  String get cloudAccessGuestAskOwner => '请联系分享者重新发送链接。';

  @override
  String get cloudAccessGuestNotYetValid => '此链接尚未生效。';

  @override
  String get cloudAccessGuestExpired => '此链接已过期。';

  @override
  String get cloudAccessGuestExhausted => '此链接已被使用。';

  @override
  String get cloudAccessGuestSuspended => '此链接已被所有者暂停或撤销。';

  @override
  String get cloudAccessGuestSessionEnded => '你的会话已结束。';

  @override
  String get cloudAccessGuestBusy => '当前连接过多，请稍后再试。';

  @override
  String get cloudAccessGuestExpiringSoon => '5 分钟后结束';

  @override
  String get cloudAccessGuestClosed => '连接已关闭。';

  @override
  String get cloudAccessGuestClosedRevoked => '访问已被所有者撤销或更改。';

  @override
  String get cloudAccessGuestClosedExpired => '访问时间已结束。';

  @override
  String get cloudAccessGuestClosedTarget => '无法连接 Host，或其身份与受信任的身份不符。';

  @override
  String get cloudAccessGuestClosedProtocol => '因出现意外消息，连接已关闭。';

  @override
  String cloudAccessApplyRole(String role) {
    return '设为$role';
  }

  @override
  String get cloudAccessApplyRoleTitle => '更改此成员的角色？';

  @override
  String cloudAccessApplyRoleMessage(String user, String role) {
    return '$user 将成为$role。这会从本设备签署新的成员清单并轮换 Vault 密钥。';
  }

  @override
  String get cloudAccessErrorScopeChanged =>
      '此操作期间账户、服务器或所选 Vault 已变更，未发送任何内容，请重试。';

  @override
  String get cloudAccessErrorNotSynced => '共享 Vault 已创建但尚未同步。请先同步再添加成员。';

  @override
  String get cloudAccessErrorScopeEndedCommitted =>
      '服务器已完成此操作的一部分（例如已创建 Vault 或邀请）后，账户、服务器或所选 Vault 发生了变更。该部分不会被撤销；请先检查后再重试。';

  @override
  String get mcpAccessModeDenied => '拒绝';

  @override
  String get mcpAccessModeReadOnly => '只读';

  @override
  String get mcpAccessModeReadWrite => '读写';

  @override
  String get mcpAccessModeDeniedDescription =>
      '外部 AI 无法看到或使用该机器，主机和会话列表中也不会出现。';

  @override
  String get mcpAccessModeReadOnlyDescription =>
      '外部 AI 可以列出该机器，并读取已打开会话的输出和文件，但不能连接、输入、执行命令或修改文件。';

  @override
  String get mcpAccessModeReadWriteDescription =>
      '外部 AI 还可以连接、切换和关闭会话，发送终端输入，执行命令和写入文件。主机密钥和登录提示仍会照常出现。';

  @override
  String get mcpMachineAccessTitle => '机器访问权限';

  @override
  String get mcpMachineAccessDescription =>
      '选择外部 AI 在每台机器上可以执行的操作。这些设置按当前工作区保存在本设备上，不会同步。停止 MCP 会撤销所有访问，与此处的选择无关。';

  @override
  String get mcpDefaultAccessTitle => '所有机器的默认权限';

  @override
  String get mcpDefaultAccessDescription => '适用于所有未单独设置的机器，包括之后添加的机器。';

  @override
  String get mcpPerMachineTitle => '单独设置';

  @override
  String mcpCustomizedCount(int count) {
    return '单独设置的机器：$count';
  }

  @override
  String get mcpLocalDeviceName => '本设备（本地控制台）';

  @override
  String get mcpLocalDeviceDetail => '未关联已保存主机的本地终端会话';

  @override
  String mcpHostUseDefault(String mode) {
    return '默认（$mode）';
  }

  @override
  String get mcpHostCustom => '已单独设置';

  @override
  String mcpHostAccessFor(String name) {
    return '$name 的访问权限';
  }

  @override
  String get mcpSearchMachines => '搜索机器';

  @override
  String mcpNoMachinesMatch(String query) {
    return '没有与“$query”匹配的机器。';
  }

  @override
  String get mcpNoSavedMachines => '当前工作区还没有已保存的主机。';

  @override
  String mcpShowMoreMachines(int count) {
    return '再显示 $count 台';
  }

  @override
  String get mcpAccessLoading => '正在加载机器访问权限…';

  @override
  String get mcpAccessUnavailable => '机器访问权限暂时不可用。在加载完成前，外部 AI 在所有机器上均被拒绝。';

  @override
  String get mcpAccessSaveFailed => '无法保存访问权限设置，请重试。';

  @override
  String get mcpConfirmReadWriteDefaultTitle => '允许在所有机器上读写？';

  @override
  String get mcpConfirmReadWriteDefaultBody =>
      '持有连接令牌的任何 AI 都可以在所有未单独设置的机器（包括之后添加的机器）上连接、输入、执行命令和修改文件。主机密钥和登录提示仍会照常出现。';

  @override
  String get mcpConfirmReadWriteDefaultConfirm => '允许读写';

  @override
  String mcpRunningDefaultAccess(String mode) {
    return '运行中 · 默认：$mode';
  }

  @override
  String get mcpAndroidForwardingHint =>
      'MCP 仅监听本设备的回环地址。要让通过 USB 调试连接的电脑上的 AI 使用它，请在电脑上运行以下命令，然后在电脑上使用复制的配置：';

  @override
  String get mcpAndroidBackgroundHint =>
      'MCP 运行期间，Atermius 会显示一条通知，以便你切换到其他应用后外部 AI 仍可继续使用。从通知中停止、锁定或退出登录都会撤销令牌。如果无法显示通知，离开应用时 MCP 会停止。';

  @override
  String get mcpForegroundNotificationTitle => '外部 AI 接入已开启';

  @override
  String mcpForegroundNotificationText(int port) {
    return 'MCP 正在监听 127.0.0.1:$port。停止即可撤销访问令牌。';
  }

  @override
  String get mcpForegroundNotificationStop => '停止 MCP';

  @override
  String get mcpAndroidProtected => 'MCP 通知已启用，可在后台保持连接。';

  @override
  String get mcpAndroidForegroundOnly => 'MCP 仅在本应用可见时运行。离开应用将撤销访问权限。';

  @override
  String get mcpAndroidStarting => '正在启动 Android 后台保护…';

  @override
  String get desktopKeyboardShow => '打开键盘与特殊键';

  @override
  String get desktopKeyboardHide => '收起键盘与特殊键';

  @override
  String get desktopTouchMode => '触摸模式';

  @override
  String get desktopTrackpadMode => '触控板（鼠标）模式';

  @override
  String get enterFullscreen => '进入全屏';

  @override
  String get exitFullscreen => '退出全屏';

  @override
  String get fullscreenUnavailable => '当前窗口无法切换全屏。';

  @override
  String get restoreConnection => '恢复连接';

  @override
  String get reconnectEveryFiveSeconds => '每 5 秒自动重连';

  @override
  String get desktopKeyboardModeTitle => '远程桌面键盘模式';

  @override
  String get desktopKeyboardOverlay => '悬浮叠加（保持分辨率）';

  @override
  String get desktopKeyboardResize => '跟随键盘调整';

  @override
  String get desktopKeyboardOverlayDescription =>
      '键盘和特殊键栏叠加在桌面上，不改变远端分辨率或画面缩放。';

  @override
  String get desktopKeyboardResizeDescription =>
      '桌面缩小至键盘上方的可见区域；跟随窗口大小的会话也会调整远端分辨率。';

  @override
  String get desktopKeyboardSaveFailed => '当前选择已生效，但未能保存，请重试。';

  @override
  String get rdpAddDisk => '添加磁盘';

  @override
  String get rdpChooseDisk => '选择磁盘';

  @override
  String get rdpLocalStorage => '本机存储';

  @override
  String rdpStorageFolderUnavailable(String name) {
    return '本机无法访问映射文件夹“$name”。请连接磁盘，或在当前设备重新选择目录。';
  }

  @override
  String get rdpStoragePermissionRequired =>
      '映射磁盘或文件夹需要在 Android 设置中允许 Atermius 访问文件，然后重试。仅共享为此主机添加的目录。';

  @override
  String get rdpStoragePickerFailed => '无法选择本机文件夹，请换一个当前设备上的目录重试。';

  @override
  String get rdpDriveMappingHelp =>
      '映射的磁盘和文件夹显示在远程会话的 \\\\tsclient 下，重新连接后生效。Android 实时磁盘映射需要文件访问授权。';

  @override
  String get rdpRenameMapping => '重命名映射';

  @override
  String get rdpMappingName => '映射名称';

  @override
  String get rdpMappingReconnect => '重新连接远程会话后，磁盘映射改动生效。';

  @override
  String get keybarShiftGuidance => 'Shift：单击仅对下一个按键生效，双击锁定';

  @override
  String get lockShiftModifier => '锁定 Shift 修饰键';

  @override
  String get releaseModifiers => '释放 Ctrl、Alt 和 Shift';

  @override
  String connectProgressConnectingTo(String name) {
    return '正在连接 $name';
  }

  @override
  String connectProgressFailedTo(String name) {
    return '无法连接到 $name';
  }

  @override
  String get connectProgressStoppedTitle => '已终止加载';

  @override
  String get connectProgressStoppedDetail => '连接尝试已终止。点击“重试”会在此标签页中重新发起连接。';

  @override
  String get connectProgressStagePreparing => '正在检查主机设置和登录信息';

  @override
  String get connectProgressStageConnecting => '正在建立连接';

  @override
  String get connectProgressStageVerifyingHost => '正在验证主机身份';

  @override
  String get connectProgressStageAwaitingUser => '等待您的确认';

  @override
  String get connectProgressStageAuthenticating => '正在登录';

  @override
  String get connectProgressStageStartingSession => '正在启动会话';

  @override
  String get connectProgressStop => '终止加载';

  @override
  String get connectProgressRetry => '重试';

  @override
  String get connectProgressClose => '关闭';

  @override
  String get connectProgressRetryUnavailable =>
      '此标签页属于之前的登录、Vault 或配置文件，无法重试。请关闭后重新连接。';

  @override
  String get connectProgressNoCredential => '此主机没有可用的已保存登录凭据。请添加或修正凭据后重试。';
}
