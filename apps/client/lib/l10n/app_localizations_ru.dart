// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get languageSystemDefault => 'Как в системе';

  @override
  String get languageSettingTitle => 'Язык';

  @override
  String get languageSettingDescription =>
      'Выберите язык интерфейса на этом устройстве. «Как в системе» использует язык устройства, а если он не поддерживается — английский.';

  @override
  String languageSettingSystemResolved(Object language) {
    return 'Как в системе · сейчас $language';
  }

  @override
  String get languageSettingSaveFailed =>
      'Язык изменён для этого сеанса, но его не удалось сохранить на устройстве.';

  @override
  String get languageSettingDevicePreference =>
      'Сохраняется только на этом устройстве. Не синхронизируется и не хранится в сейфе.';

  @override
  String tabSemanticsLabel(Object title, Object status, Object selection) {
    return 'Вкладка терминала $title, $status, $selection';
  }

  @override
  String get tabSemanticsConnected => 'подключено';

  @override
  String get tabSemanticsDisconnected => 'не подключено';

  @override
  String get tabSemanticsActive => 'активна';

  @override
  String get tabSemanticsInactive => 'неактивна';

  @override
  String mfaChallengeTotp(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return 'Чтобы продолжить, введите шестизначный код из приложения-аутентификатора. Срок действия запроса истекает $expiresAtString.';
  }

  @override
  String mfaChallengeRecovery(DateTime expiresAt) {
    final intl.DateFormat expiresAtDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String expiresAtString = expiresAtDateFormat.format(expiresAt);

    return 'Чтобы продолжить, введите одноразовый код восстановления. Срок действия запроса истекает $expiresAtString.';
  }

  @override
  String get propertyAuthentication => 'Аутентификация';

  @override
  String get propertyStatus => 'Состояние';

  @override
  String get propertyRoute => 'Маршрут';

  @override
  String get propertyTags => 'Теги';

  @override
  String keyEpochLocalMismatch(int epoch) {
    return 'Эпохе ключа $epoch на этом устройстве соответствуют разные локальные ключи.';
  }

  @override
  String get recoveryCodeCopiedFeedback => 'Код восстановления скопирован.';

  @override
  String get recoveryCodeCopyFailedFeedback =>
      'Не удалось скопировать код восстановления. Выделите и скопируйте его вручную.';

  @override
  String sessionsRevokedForSelectedAccount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Для выбранной учётной записи отозвано $count сеанса.',
      many: 'Для выбранной учётной записи отозвано $count сеансов.',
      few: 'Для выбранной учётной записи отозвано $count сеанса.',
      one: 'Для выбранной учётной записи отозван $count сеанс.',
    );
    return '$_temp0';
  }

  @override
  String get usernameOptional => 'Имя пользователя (необязательно)';

  @override
  String get forwardRuntimeUnsupported =>
      'На этой платформе переадресация портов SSH недоступна.';

  @override
  String get forwardRuntimeDisconnected =>
      'Не подключено. Профили можно изменить сейчас; чтобы запустить их, подключитесь к хосту по SSH.';

  @override
  String get forwardRuntimeRunningNote =>
      'Работающая переадресация остаётся на этом устройстве и автоматически останавливается, когда SSH-соединение завершается.';

  @override
  String forwardStatusRunning(int active, int total) {
    return 'Работает · активных: $active · всего: $total';
  }

  @override
  String get forwardStatusStopping => 'Остановка…';

  @override
  String get forwardStatusStopped => 'Остановлено';

  @override
  String forwardStatusFailed(Object error) {
    return 'Ошибка: $error';
  }

  @override
  String get forwardStatusUnknownError => 'неизвестная ошибка';

  @override
  String forwardExposureLocal(Object bind, Object destination) {
    return 'Другие устройства в ваших сетях, которые могут достучаться до $bind, смогут подключаться к $destination через ваш вход SSH.';
  }

  @override
  String forwardExposureDynamic(Object bind) {
    return 'Другие устройства, которые могут достучаться до $bind, смогут использовать SOCKS-прокси без аутентификации через ваш вход SSH.';
  }

  @override
  String forwardExposureRemoteLoopback(Object destination) {
    return 'Подключения, поступающие на SSH-сервер, будут ретранслироваться этим устройством на $destination.';
  }

  @override
  String forwardExposureRemotePublic(Object destination) {
    return 'Подключения, поступающие на SSH-сервер, будут ретранслироваться этим устройством на $destination, и сервер может принимать их с других машин.';
  }

  @override
  String forwardRemoteListenerRejected(Object endpoint) {
    return 'SSH-сервер отклонил слушатель на $endpoint. Порт может быть занят на сервере или запрещён AllowTcpForwarding/PermitListen.';
  }

  @override
  String forwardLocalDestinationUnreachable(Object endpoint) {
    return 'Это устройство не смогло подключиться к $endpoint.';
  }

  @override
  String get keybarMore => 'Ещё';

  @override
  String get keybarLess => 'Меньше';

  @override
  String get invalidAttachedFileOwner =>
      'Недопустимый владелец прикреплённого файла.';

  @override
  String get unexpectedWindowCombinationOwnerField =>
      'Неожиданное поле владельца.';

  @override
  String get fileSessionSshOwnerMissingFromWindowSet =>
      'SSH-владелец файлового сеанса не входит в набор окон.';

  @override
  String get terminalStateConnected => 'подключено';

  @override
  String get terminalStateConnecting => 'подключение';

  @override
  String get terminalStateReconnecting => 'переподключение';

  @override
  String get terminalStateDisconnected => 'отключено';

  @override
  String get terminalStateClosed => 'закрыто';

  @override
  String get terminalStateEnded => 'завершено';

  @override
  String get terminalStateFailed => 'ошибка';

  @override
  String get sshPasswordLabel => 'Пароль SSH';

  @override
  String get passwordOptionalLabel => 'Пароль (необязательно)';

  @override
  String quotedHostName(Object name) {
    return 'Хост «$name»';
  }

  @override
  String hostsReferenceUnavailableGroups(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count хоста ссылаются',
      many: '$count хостов ссылаются',
      few: '$count хоста ссылаются',
      one: '$count хост ссылается',
    );
    return '$_temp0 на недоступные группы. Измените затронутые хосты: выберите текущую группу или явно укажите «Без группы».';
  }

  @override
  String pendingCountShort(int count) {
    return 'ожидает: $count';
  }

  @override
  String get purgeConsentEnabled => 'Включено';

  @override
  String get purgeConsentOff => 'Выключено';

  @override
  String get restoreDeadlineStatusUnavailable =>
      'Срок восстановления: недоступен';

  @override
  String get restoreDeadlineStatusPassed =>
      'Срок восстановления: истёк по часам этого устройства; окончательное решение принимает сервер';

  @override
  String restoreDeadlineStatusFuture(DateTime deadline) {
    final intl.DateFormat deadlineDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String deadlineString = deadlineDateFormat.format(deadline);

    return 'Срок восстановления: ещё не наступил, $deadlineString';
  }

  @override
  String get groupParentNeedsRepair => 'Связь с родителем требует исправления';

  @override
  String groupInsideParent(Object parent) {
    return 'Внутри $parent';
  }

  @override
  String groupHostCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count хоста',
      many: '$count хостов',
      few: '$count хоста',
      one: '$count хост',
    );
    return '$_temp0';
  }

  @override
  String groupSubgroupCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count подгруппы',
      many: '$count подгрупп',
      few: '$count подгруппы',
      one: '$count подгруппа',
    );
    return '$_temp0';
  }

  @override
  String get groupDefaultCredentialUnavailable =>
      'Учётные данные по умолчанию недоступны';

  @override
  String groupDefaultCredentialName(Object name) {
    return 'Учётные данные по умолчанию: $name';
  }

  @override
  String get credentialPasswordStoredEncrypted =>
      'Пароль хранится в зашифрованном виде';

  @override
  String get credentialPrivateKeyStoredEncrypted =>
      'Закрытый ключ хранится в зашифрованном виде';

  @override
  String get splitAxisSideBySide => 'Рядом';

  @override
  String get splitAxisStacked => 'Друг над другом';

  @override
  String get execCancelledUnknown =>
      'Отменено. Завершение на удалённой стороне неизвестно; команда не повторялась.';

  @override
  String get execOpenTimedOut =>
      'Истекло время ожидания запроса SSH exec. Перед повтором отключитесь и переподключитесь; завершение на удалённой стороне неизвестно.';

  @override
  String get execTimedOutUnknown =>
      'Истекло время ожидания. Завершение на удалённой стороне неизвестно; команда не повторялась.';

  @override
  String get execOutputTruncated =>
      'Вывод превысил лимит 64 КиБ. Канал exec закрыт; состояние завершения неизвестно.';

  @override
  String get execBashUnavailable =>
      'На этой цели нет Bash или оболочка входа несовместима с POSIX. Содержимое сниппета не выполнялось.';

  @override
  String unableToReviewHostConnectionSettings(Object error) {
    return 'Не удалось проверить параметры подключения хоста: $error';
  }

  @override
  String get adminJobBackupCompleted =>
      'Зашифрованное резервное копирование на сервере завершено';

  @override
  String get adminJobBackupFailed =>
      'Зашифрованное резервное копирование не выполнено; проверьте настройки резервного копирования на сервере';

  @override
  String get adminJobBackupInterrupted =>
      'Задание зашифрованного резервного копирования прервано';

  @override
  String get adminJobRestorePrepared =>
      'Изолированная копия для восстановления подготовлена; она не активирована';

  @override
  String get adminJobRestoreFailed =>
      'Не удалось подготовить изолированную копию; рабочие данные не изменены';

  @override
  String get adminJobRestorePreparedStatusInterrupted =>
      'Копия для восстановления подготовлена; обновление состояния задания прервано';

  @override
  String get adminJobRestoreInterrupted =>
      'Подготовка изолированной копии прервана';

  @override
  String get adminJobMaintenanceFailed =>
      'Обслуживание не выполнено; проверьте состояние сервера перед повтором';

  @override
  String get adminJobMaintenanceInterrupted =>
      'Обслуживание прервано; обновите список заданий перед повтором';

  @override
  String adminJobResultCode(Object code) {
    return 'Результат $code';
  }

  @override
  String get masterPasswordChangedSessionsRevoked =>
      'Мастер-пароль изменён. Остальные сеансы отозваны.';

  @override
  String get masterPasswordChangeConfirmedSessionsRevoked =>
      'Смена мастер-пароля подтверждена. Остальные сеансы отозваны.';

  @override
  String confirmRemoveMemberAndRotate(Object username) {
    return 'Удалить $username и сменить ключ сейфа для всех оставшихся активных устройств участников? Удалённая учётная запись не получит новый ключ. Уже существующие старые копии удалённо стереть нельзя. Другие ожидающие токены приглашений станут недействительными, и их нужно будет выдать заново.';
  }

  @override
  String confirmCancelInvitationAndRotate(Object username) {
    return 'Отменить ожидающее приглашение для $username и сменить ключ сейфа для всех оставшихся активных устройств участников? Удалённая учётная запись не получит новый ключ. Уже существующие старые копии удалённо стереть нельзя. Другие ожидающие токены приглашений станут недействительными, и их нужно будет выдать заново.';
  }

  @override
  String recycleBinPurgeConsentLine(Object consent) {
    return '$consent.';
  }

  @override
  String recycleBinPurgeConsentLineOwner(Object consent) {
    return '$consent. Согласие относится только к этой метке удаления. Если оно включено, ограниченное обслуживание может удалить её после срока восстановления и других обязательных проверок. Включение согласия не удаляет её сразу; офлайн-копии на устройствах и экспорты не удаляются.';
  }

  @override
  String get objectDownloadFailed => 'Не удалось скачать объект.';

  @override
  String get objectRangeDownloadFailed =>
      'Не удалось скачать диапазон объекта.';

  @override
  String get requestFailed => 'Запрос не выполнен.';

  @override
  String get theServerReturnedAnInvalidResponse =>
      'Сервер вернул недопустимый ответ.';

  @override
  String consoleExitedCode(int code) {
    return '\n[Консоль завершилась: $code]\n';
  }

  @override
  String get thisDevicesSecureStorageCouldntDelete =>
      ' Защищённое хранилище устройства не смогло удалить старый токен обновления; на сервере токен отозван.';

  @override
  String get someLocalStateCleanupHitAn =>
      ' При очистке части локального состояния произошла ошибка; приложение принудительно завершило текущий сеанс.';

  @override
  String get aVaultRecoveryContextHasNo =>
      'У контекста восстановления сейфа нет действительной подписанной версии членства.';

  @override
  String get aCommandSnippetIsAlreadyRunning =>
      'Сниппет команды уже выполняется.';

  @override
  String get aDisabledRecoveryAccountReturnedActive =>
      'Учётная запись с отключённым восстановлением вернула активные данные восстановления.';

  @override
  String get aNewRecoveryKeyboxFailedIts =>
      'Новый ящик ключей восстановления не прошёл локальную проверку.';

  @override
  String get aNewDeviceKeyEnvelopeFailed =>
      'Новый конверт ключа устройства не прошёл локальную проверку.';

  @override
  String get aPreviousSshExecRequestIs =>
      'Предыдущий запрос SSH exec ещё ожидает. Отключитесь и переподключитесь, прежде чем запускать другую команду.';

  @override
  String get aRecoveryConfirmationIsAlreadyPending =>
      'Подтверждение восстановления уже ожидается.';

  @override
  String get aReferencedSnippetCredentialChangedAfter =>
      'После проверки изменились учётные данные, на которые ссылается сниппет. Проверьте весь пакет заново.';

  @override
  String get aRequiredVaultKeyCouldNot =>
      'Не удалось восстановить нужный ключ сейфа. Проверьте состояние восстановления и попробуйте на зарегистрированном устройстве.';

  @override
  String get aSelectedHostConnectionOrSnippet =>
      'После проверки изменились выбранный хост, подключение или сниппет. Проверьте весь пакет заново.';

  @override
  String get accountRecoveredSignInWithThe2 =>
      'Учётная запись восстановлена. Войдите на этом устройстве с новым мастер-паролем.';

  @override
  String get accountRecoveryIsBusy => 'Восстановление учётной записи занято.';

  @override
  String get accountRelayPolicyResetToInherit =>
      'Политика ретрансляции учётной записи сброшена на наследование.';

  @override
  String get accountRelayPolicySaved =>
      'Политика ретрансляции учётной записи сохранена.';

  @override
  String accountStatusUpdatedToStatusRevokedsessions(
    String status,
    int revokedSessions,
  ) {
    return 'Состояние учётной записи обновлено: $status; отозвано сеансов: $revokedSessions.';
  }

  @override
  String get anExistingRecoveryKeyboxCouldNot =>
      'Существующий ящик ключей восстановления не удаётся проверить или открыть; ротация, которая удалила бы единственную копию, отклонена.';

  @override
  String get bashExecutionRequiresACancellationHandle =>
      'Для выполнения Bash нужен дескриптор отмены.';

  @override
  String get batchExecutionIsOnlySupportedFor =>
      'Пакетное выполнение поддерживается только для структурированных сниппетов Bash.';

  @override
  String get batchTargetsMustBeDistinctConnected =>
      'Цели пакета должны быть разными подключёнными хостами.';

  @override
  String get bucketAccessVerifiedWithHeadbucketThis =>
      'Доступ к бакету подтверждён через HeadBucket. Эта проверка не проверяет отправку, многочастные операции, восстановление и совместимость с провайдером в целом.';

  @override
  String chooseBetweenTwoAndMaxterminaltabsConnected(int maxTerminalTabs) {
    return 'Выберите от 2 до $maxTerminalTabs подключённых хостов.';
  }

  @override
  String get commandExecutionIsUnavailableNoCommand =>
      'Выполнение команд недоступно. Команда не отправлена.';

  @override
  String get conflictingSignedRecoveryKeyboxesExistFor =>
      'Для эпохи сейфа есть конфликтующие подписанные ящики ключей восстановления.';

  @override
  String get connectThisTerminalBeforeEnablingShell =>
      'Подключите этот терминал, прежде чем включать интеграцию с оболочкой.';

  @override
  String get connectToTheServerBeforeChecking =>
      'Подключитесь к серверу, прежде чем проверять доступ к бакету резервных копий.';

  @override
  String get theConsoleOutputStreamClosed => 'Поток вывода консоли закрыт.';

  @override
  String get couldNotDisableBackgroundSyncNotifications =>
      'Не удалось отключить уведомления фоновой синхронизации.';

  @override
  String get couldNotEnableBackgroundSyncNotifications =>
      'Не удалось включить уведомления фоновой синхронизации.';

  @override
  String get couldNotPersistTheMobilePush =>
      'Не удалось сохранить отказ от мобильных push-уведомлений.';

  @override
  String get couldNotRemoveThisDevicesPush =>
      'Не удалось удалить push-адрес этого устройства.';

  @override
  String credentialReferenceNameIsMissingOr(String name) {
    return 'Ссылка на учётные данные $name отсутствует или это не парольные учётные данные';
  }

  @override
  String get currentAccountSessionExpired =>
      'Сеанс текущей учётной записи истёк.';

  @override
  String get enterTheAccountName => 'Введите имя учётной записи.';

  @override
  String get groupRelayPolicyResetToInherit =>
      'Политика Relay группы сброшена на наследование.';

  @override
  String get groupRelayPolicySaved => 'Политика Relay группы сохранена.';

  @override
  String get groupDefault => 'Значение группы по умолчанию';

  @override
  String get groupDefaultIsUnavailableChooseA =>
      'Значение по умолчанию группы недоступно. Выберите переопределение хоста или исправьте значение группы.';

  @override
  String get groupMembershipSaved => 'Членство в группе сохранено.';

  @override
  String get hostChangedRepeatedlyWhileSavingReopen =>
      'Хост несколько раз изменился во время сохранения; откройте заново и повторите попытку.';

  @override
  String get hostIdentityChangedWhileTheEditor =>
      'Идентичность хоста изменилась, пока был открыт редактор.';

  @override
  String get hostOverrideIsUnavailableChooseInherit =>
      'Переопределение хоста недоступно. Выберите «Наследовать от группы» или другие учётные данные.';

  @override
  String hostOverrideIdentity(String identity) {
    return 'Переопределение хоста: $identity';
  }

  @override
  String get theHostsTagsFieldWasAlso =>
      'Поле хоста «Теги» тоже изменилось во время правки. Откройте его заново, проверьте и повторите попытку.';

  @override
  String theHostsLabelFieldWasAlso(String label) {
    return 'Поле хоста «$label» тоже изменилось во время правки. Откройте его заново, проверьте и повторите попытку.';
  }

  @override
  String inheritedFromValuevalueIdentity(String valueValue, String identity) {
    return 'Унаследовано от $valueValue: $identity';
  }

  @override
  String get instanceAdminAccessIsRequiredTo =>
      'Для проверки доступа к бакету резервных копий нужны права администратора экземпляра.';

  @override
  String get invalidAdminVaultPaginationResponse =>
      'Недопустимый ответ постраничного списка сейфов для администратора.';

  @override
  String get invalidAdminAccountInvitationPaginationResponse =>
      'Недопустимый ответ постраничного списка приглашений.';

  @override
  String get invalidAdminAccountPaginationResponse =>
      'Недопустимый ответ постраничного списка учётных записей.';

  @override
  String get invalidAdminAccountSessionsPaginationResponse =>
      'Недопустимый ответ постраничного списка сеансов учётной записи.';

  @override
  String get invalidAdminMaintenancePaginationResponse =>
      'Недопустимый ответ постраничного списка обслуживания.';

  @override
  String get invalidMobilePushToken =>
      'Недопустимый токен мобильных push-уведомлений.';

  @override
  String get invalidRestoreJobReceipt =>
      'Недопустимое подтверждение задания восстановления.';

  @override
  String get invalidRestoreSourcePageResponse =>
      'Недопустимый ответ страницы источников восстановления.';

  @override
  String invitationCreatedForUsername(String username) {
    return 'Приглашение для $username создано.';
  }

  @override
  String get invitationRevoked => 'Приглашение отозвано.';

  @override
  String jumpHostCredentialForHostnameChanged(String hostName) {
    return 'Учётные данные промежуточного хоста для $hostName изменились до отправки. Оставшаяся часть пакета остановлена.';
  }

  @override
  String jumpHostRoutingForHostnameChanged(String hostName) {
    return 'Маршрут через промежуточный хост для $hostName изменился до отправки. Проверьте пакет заново.';
  }

  @override
  String couldntResolveTheSshCredentialFor(
    String name,
    String connectionError,
  ) {
    return 'Не удалось определить учётные данные SSH для промежуточного хоста $name: $connectionError';
  }

  @override
  String get theJumpHostMustUseThe =>
      'Промежуточный хост должен использовать протокол SSH.';

  @override
  String get theJumpHostRouteChangedWhile =>
      'Маршрут промежуточного хоста изменился во время подготовки подключения. Переподключитесь.';

  @override
  String get theJumpHostRouteOrCredential =>
      'Маршрут или учётные данные промежуточного хоста изменились во время подготовки подключения. Переподключитесь.';

  @override
  String get theJumpHostChainCantForm =>
      'Цепочка промежуточных хостов не может быть циклической.';

  @override
  String get theJumpHostChainContainsA =>
      'Цепочка промежуточных хостов содержит несуществующий хост; измените и исправьте эту ссылку.';

  @override
  String theJumpHostChainSupportsUp(int maxJumpHostHops) {
    return 'Цепочка промежуточных хостов поддерживает не более $maxJumpHostHops переходов.';
  }

  @override
  String get loadAConsistentAccountAndInstance =>
      'Перед сбросом загрузите согласованные политики учётной записи и экземпляра.';

  @override
  String get loadAConsistentAccountAndInstance2 =>
      'Перед сохранением загрузите согласованные политики учётной записи и экземпляра.';

  @override
  String get loadTheLatestSshRelayPolicy =>
      'Перед сохранением загрузите последнюю политику SSH-ретранслятора.';

  @override
  String get theMfaSignInResponseDoesnt =>
      'Ответ входа с MFA не соответствует текущей учётной записи или устройству.';

  @override
  String get mfaSettingsAreBeingProcessed => 'Настройки MFA обрабатываются.';

  @override
  String get mfaVerificationFailedTheCodeIs =>
      'Проверка MFA не пройдена: код недействителен или уже использован, либо истёк запрос входа. Войдите снова и введите новый код.';

  @override
  String get mfaVerifiedAndUnlockedLocallyThe =>
      'MFA подтверждена, разблокировка выполнена локально; сервер по-прежнему хранит только зашифрованные записи и конверты ключей.';

  @override
  String get mustBeBetween0And1000000 => 'Должно быть от 0 до 1000000.';

  @override
  String get mustNotBeNegative => 'Не может быть отрицательным.';

  @override
  String get noS3BackupBucketIsConfigured =>
      'На сервере не настроен бакет S3 для резервных копий.';

  @override
  String get noSshCredentialIsConfiguredChoose =>
      'Учётные данные SSH не настроены. Выберите переопределение хоста или задайте значение для группы.';

  @override
  String get noAccountRecoveryIsAwaitingConfirmation =>
      'Нет восстановления учётной записи, ожидающего подтверждения.';

  @override
  String get noAuthenticatedSession => 'Нет аутентифицированного сеанса.';

  @override
  String get noEffectiveSshCredentialIsSet =>
      'Действующие учётные данные SSH не заданы. Выберите переопределение хоста или задайте значение для группы.';

  @override
  String get notStartedBecauseBatchCancellationWas =>
      'Не запущено: во время предварительной проверки запрошена отмена пакета.';

  @override
  String get notStartedBecauseBatchCancellationWas2 =>
      'Не запущено: запрошена отмена пакета.';

  @override
  String get notStartedBecauseThePreviousHost =>
      'Не запущено: предыдущий хост не завершился успешно.';

  @override
  String get notStartedBecauseThePreviousHost2 =>
      'Не запущено: предыдущий хост не прошёл проверку или выполнение.';

  @override
  String get offlineKnownhostApprovalIsLimitedTo =>
      'Офлайн-одобрение KnownHost возможно только для впервые встреченной конечной точки без локальной истории доверия или отзыва.';

  @override
  String get offlineKnownhostQueueDidNotMatch =>
      'Офлайн-очередь KnownHost не совпала с явно проверенным SSH-ключом.';

  @override
  String get prometheusScrapeCredentialRevoked =>
      'Учётные данные Prometheus для сбора метрик отозваны.';

  @override
  String get rdpCertificate => 'Сертификат RDP';

  @override
  String get recoveryCouldNotBeStartedCheck =>
      'Не удалось начать восстановление. Проверьте имя учётной записи и код.';

  @override
  String get recoveryDescriptorHashIsInvalid =>
      'Хеш дескриптора восстановления недействителен.';

  @override
  String get recoveryDescriptorPublicKeysDoNot =>
      'Открытые ключи дескриптора восстановления не соответствуют обёрнутой идентичности.';

  @override
  String get recoveryIdentityEnvelopeIsMissing =>
      'Отсутствует конверт идентичности восстановления.';

  @override
  String get referencedCredentialChangedAfterPreviewReview =>
      'После предпросмотра изменились учётные данные, на которые есть ссылка. Проверьте команду и повторите попытку.';

  @override
  String get reloadTheLatestAccountAndInstance =>
      'Перед сбросом перезагрузите последние политики учётной записи и экземпляра.';

  @override
  String get reloadTheLatestAccountAndInstance2 =>
      'Перед сохранением перезагрузите последние политики учётной записи и экземпляра.';

  @override
  String get reloadTheLatestGroupAndInstance =>
      'Перед сбросом перезагрузите последние политики группы и экземпляра.';

  @override
  String get reloadTheLatestGroupAndInstance2 =>
      'Перед сохранением перезагрузите последние политики группы и экземпляра.';

  @override
  String get reloadTheLatestPolicyAfterThe =>
      'После конфликта версий перезагрузите последнюю политику и повторите попытку.';

  @override
  String get restoreIsEncryptedAndQueuedOn =>
      'Восстановление зашифровано и поставлено в очередь на этом устройстве; состояние синхронизации будет проверено снова.';

  @override
  String get restoreIsEncryptedLocallyAndWaiting =>
      'Восстановление зашифровано локально и ждёт синхронизации.';

  @override
  String get restoreIsSafelyQueuedOnThis =>
      'Восстановление безопасно поставлено в очередь на этом устройстве и будет повторено, когда сервер станет доступен.';

  @override
  String get restoreStageResponseDidNotMatch =>
      'Ответ подготовки восстановления не совпал.';

  @override
  String get retryThePendingAccountRecoveryCompletion =>
      'Перед входом повторите завершение ожидающего восстановления учётной записи.';

  @override
  String get theSftpDocumentBelongsToA =>
      'Документ SFTP относится к другому SSH-сеансу.';

  @override
  String get theSftpServerVersionDoesntSupport =>
      'Версия SFTP-сервера не поддерживает безопасную отправку файлов.';

  @override
  String get theSftpServerVersionIsBelow =>
      'Версия SFTP-сервера ниже 3, безопасное редактирование текста не поддерживается.';

  @override
  String sshCredentialForHostnameChangedBefore(String hostName) {
    return 'Учётные данные SSH для $hostName изменились до отправки. Оставшаяся часть пакета остановлена.';
  }

  @override
  String get sshConnectionOrHostChangedAfter =>
      'После предпросмотра изменились SSH-подключение или хост. Проверьте цель и повторите попытку.';

  @override
  String get sshExecFailedAfterDispatchRemote =>
      'SSH exec завершился ошибкой после отправки. Завершение на удалённой стороне неизвестно; команда не повторялась.';

  @override
  String get sshHostKeyApprovalProofAccount =>
      'Учётная запись или область сейфа подтверждения одобрения ключа SSH-хоста изменились.';

  @override
  String get sshHostKeyTestDecisionBecame =>
      'Тестовое решение по ключу SSH-хоста устарело.';

  @override
  String sshHostKeyTrustChangedFor(String hostName) {
    return 'Доверие к ключу SSH-хоста $hostName изменилось. Переподключитесь и проверьте пакет заново.';
  }

  @override
  String sshHostKeyVerificationEvidenceIs(String hostName) {
    return 'Отсутствует подтверждение проверки ключа SSH-хоста для $hostName. Переподключитесь перед запуском пакета.';
  }

  @override
  String get sshRelayPolicySaved => 'Политика SSH-ретранслятора сохранена.';

  @override
  String get sshHostKeyTrustWasConfirmed =>
      'Доверие к ключу SSH-хоста подтверждено синхронизацией в текущем сейфе.';

  @override
  String get sshHostKeyTrustWasRevoked =>
      'Доверие к ключу SSH-хоста отозвано и сохранено в текущем сейфе в зашифрованном виде.';

  @override
  String get theSshHostKeyApprovalWas =>
      'Одобрение ключа SSH-хоста поставлено в очередь в зашифрованном виде; текущее подключение остановлено. Подключитесь после подтверждения синхронизацией сейфа.';

  @override
  String get theSshHostOrJumpHost =>
      'Маршрут SSH-хоста или промежуточного хоста изменился. Переподключитесь и повторите попытку.';

  @override
  String get theSshHostSettingsChangedReconnect =>
      'Настройки SSH-хоста изменились; переподключите текущую панель рабочего пространства.';

  @override
  String get sshSessionClosed => 'SSH-сеанс закрыт';

  @override
  String get sshCredentials2 => 'Учётные данные SSH';

  @override
  String get theSshCredentialWasSavedEncrypted =>
      'Учётные данные SSH сохранены в зашифрованном виде и добавлены в локальную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get sshCredentialSavedEncryptedPlaintextIs =>
      'Учётные данные SSH сохранены в зашифрованном виде; открытый текст хранится только в разблокированном сеансе.';

  @override
  String get theSshCredentialChangedReconnectThe =>
      'Учётные данные SSH изменились; переподключите текущую панель рабочего пространства.';

  @override
  String get theSshCredentialOrHostSettings =>
      'Учётные данные SSH или настройки хоста изменились; переподключите текущую панель рабочего пространства.';

  @override
  String get sshStoppedTheFirstHostKey =>
      'SSH остановлен: первое одобрение ключа хоста поставлено в очередь в зашифрованном виде. Переподключитесь после подтверждения синхронизацией сейфа.';

  @override
  String sshConnectedToEndpoint(String endpoint) {
    return 'SSH подключён к $endpoint.';
  }

  @override
  String get sshSignInDetails => 'Данные для входа SSH';

  @override
  String get theSshTerminalIsClosedSo =>
      'SSH-терминал закрыт, поэтому передать управление вводом нельзя.';

  @override
  String get theSshConnectionClosedReconnectThe =>
      'SSH-соединение закрыто; переподключите текущую панель рабочего пространства.';

  @override
  String get selectAVaultBeforeResolvingThis =>
      'Выберите сейф, прежде чем использовать эти учётные данные.';

  @override
  String get selectAVaultBeforeResolvingThis2 =>
      'Выберите сейф, прежде чем использовать этот хост.';

  @override
  String get selectAnActiveMemberOfThis =>
      'Выберите активного участника этой группы, управляемой сервером.';

  @override
  String get selectedSessionRevoked => 'Выбранный сеанс отозван.';

  @override
  String get selectedSessionWasAlreadyRevoked =>
      'Выбранный сеанс уже был отозван.';

  @override
  String get serverActivationWasSuperseded =>
      'Активация сервера заменена другой.';

  @override
  String get serverCommittedTheRotationButThe =>
      'Сервер зафиксировал ротацию, но новое локальное состояние ключей не прошло проверку.';

  @override
  String get serverStateAdvancedUnexpectedlyDuringRotation =>
      'Состояние сервера неожиданно продвинулось во время восстановления после ротации.';

  @override
  String get signOutBeforeStartingFullAccount =>
      'Выйдите, прежде чем начинать полное восстановление учётной записи.';

  @override
  String get snippetArgumentsChangedAfterPreviewReview =>
      'После предпросмотра изменились аргументы сниппета. Проверьте их и повторите попытку.';

  @override
  String get snippetArgumentsChangedAfterReviewReview =>
      'После проверки изменились аргументы сниппета. Проверьте весь пакет заново.';

  @override
  String get snippetDefinitionChangedAfterPreviewReview =>
      'После предпросмотра изменилось определение сниппета. Проверьте его и повторите попытку.';

  @override
  String get snippetScriptIsEmpty => 'Скрипт сниппета пуст';

  @override
  String get splitWorkspacesRequireExactlyTwoHosts =>
      'Для разделённого рабочего пространства нужно ровно два хоста.';

  @override
  String get storedNextRecoveryPackageIsInvalid =>
      'Сохранённый следующий пакет восстановления недействителен.';

  @override
  String get storedRecoveryChallengeIsInvalid =>
      'Сохранённый запрос восстановления недействителен.';

  @override
  String get storedRecoveryDeviceKeyIsInvalid =>
      'Сохранённый ключ устройства восстановления недействителен.';

  @override
  String get storedRecoveryDeviceProofIsInvalid =>
      'Сохранённое подтверждение устройства восстановления недействительно.';

  @override
  String get storedRecoveryRequestDoesNotMatch =>
      'Сохранённый запрос восстановления не соответствует этому экземпляру сервера.';

  @override
  String get theGroupInheritanceChainIsUnavailable =>
      'Цепочка наследования групп недоступна. Выберите допустимую группу или переопределение хоста.';

  @override
  String get theHostGroupInheritanceChainIs =>
      'Цепочка наследования групп хоста недоступна. Выберите допустимую группу или переопределение учётных данных хоста.';

  @override
  String get theHostDidNotReturnA =>
      'Хост не вернул результат выполнения Bash.';

  @override
  String get theSshExecRequestFailedAfter =>
      'Запрос SSH exec завершился ошибкой после отправки.';

  @override
  String get theAccountNowInheritsTheInstance =>
      'Теперь учётная запись наследует политику ретрансляции экземпляра.';

  @override
  String get theEffectiveSshCredentialIsUnavailable =>
      'Действующие учётные данные SSH недоступны. Выберите допустимое переопределение хоста или исправьте значение группы.';

  @override
  String get theEnabledRecoveryIdentityHasAn =>
      'Поколение включённой идентичности восстановления недействительно.';

  @override
  String get theEncryptedSshHostKeyApproval =>
      'Зашифрованное одобрение ключа SSH-хоста не удалось надёжно поставить в очередь.';

  @override
  String get theExistingRecoveryDescriptorDoesNot =>
      'Существующий дескриптор восстановления не соответствует обёрнутой идентичности.';

  @override
  String get theGroupNowInheritsTheInstance =>
      'Теперь группа наследует политику Relay экземпляра.';

  @override
  String get theInstanceRelayPolicyChangedWhile =>
      'Политика Relay экземпляра изменилась во время загрузки группы. Перезагрузите для согласованного снимка.';

  @override
  String get theInstanceRelayPolicyChangedReload =>
      'Политика Relay экземпляра изменилась. Перезагрузите группу, прежде чем проверять фактический доступ.';

  @override
  String get theInstancePolicyChangedWhileResetting =>
      'Политика экземпляра изменилась во время сброса. Перезагрузите последние политики; ваш черновик сохранён.';

  @override
  String get theInstancePolicyChangedWhileSaving =>
      'Политика экземпляра изменилась во время сохранения. Перезагрузите последние политики; ваш черновик сохранён.';

  @override
  String get theInstanceRelayPolicyChangedWhile2 =>
      'Политика ретрансляции экземпляра изменилась во время загрузки политики учётной записи. Перезагрузите для согласованного снимка.';

  @override
  String get theMergedHostRecordIsInvalid =>
      'Объединённая запись хоста недействительна.';

  @override
  String get theNewMasterPasswordMustContain =>
      'Новый мастер-пароль должен содержать не менее 12 символов.';

  @override
  String get theNewMasterPasswordsDoNot => 'Новые мастер-пароли не совпадают.';

  @override
  String get theRecoveryChallengeExpiredStartAgain =>
      'Срок запроса восстановления истёк. Начните заново.';

  @override
  String get theRecoveryCodeOrServerDescriptor =>
      'Код восстановления или дескриптор сервера недействителен.';

  @override
  String get theRecoveryCompletionReceiptIsInvalid =>
      'Недопустимое подтверждение завершения восстановления.';

  @override
  String get theRecoveryResponseDidNotMatch =>
      'Ответ восстановления не соответствует этой учётной записи.';

  @override
  String get theRelayPolicyChangedElsewhereReload =>
      'Политика ретрансляции изменена в другом месте. Перезагрузите последние настройки и повторите попытку.';

  @override
  String theReviewedSshSessionForHostname(String hostName) {
    return 'Проверенный SSH-сеанс $hostName изменился до отправки.';
  }

  @override
  String get theServerCouldNotVerifyAccess =>
      'Сервер не смог проверить доступ к настроенному бакету S3 для резервных копий.';

  @override
  String get theServerDeploymentDoesNotCurrently =>
      'Развёртывание сервера сейчас не разрешает этот параметр ретрансляции. Ваши правки сохранены; проверьте ограничения развёртывания и повторите попытку.';

  @override
  String get theServerOrAuthenticationStateChanged =>
      'Во время восстановления изменилось состояние сервера или аутентификации. Начните заново.';

  @override
  String get theServerRestorePeriodHasNot =>
      'Срок восстановления на сервере ещё не истёк.';

  @override
  String get thisSnippetReferencesACredentialThat =>
      'Этот сниппет ссылается на недоступные учётные данные. Сначала восстановите их.';

  @override
  String get thisCommandPreviewHasAlreadyBeen =>
      'Этот предпросмотр команды уже подтверждён.';

  @override
  String get thisRecordTypeCannotBeRestored =>
      'Эта версия клиента не может восстановить записи такого типа.';

  @override
  String get thisRecoveryCodeBelongsToAnother =>
      'Этот код восстановления относится к другому экземпляру сервера.';

  @override
  String get thisWorkspaceReferencesAHostThat =>
      'Это рабочее пространство ссылается на недоступный хост. Сначала восстановите хост.';

  @override
  String get tooManySshHostKeyChecks =>
      'Для этого маршрута запрошено слишком много проверок ключей SSH-хостов.';

  @override
  String get unableToLoadTheSshRelay =>
      'Не удалось загрузить политику SSH-ретранслятора. Проверьте подключение и повторите попытку.';

  @override
  String get unableToSaveTheSshRelay =>
      'Не удалось сохранить политику SSH-ретранслятора. Проверьте подключение и повторите попытку.';

  @override
  String get vaultChangedWhileSshHostKey =>
      'Сейф изменился во время проверки одобрения ключа SSH-хоста.';

  @override
  String get vaultChangedWhileSshHostKey2 =>
      'Сейф изменился во время сохранения одобрения ключа SSH-хоста.';

  @override
  String get vaultChangedWhileSshHostKey3 =>
      'Сейф изменился во время синхронизации одобрения ключа SSH-хоста.';

  @override
  String get vaultChangedWhileSshHostKey4 =>
      'Сейф изменился во время сохранения отзыва ключа SSH-хоста.';

  @override
  String get vaultContainsAnUnsupportedReferenceRecord =>
      'Сейф содержит неподдерживаемый тип записи-ссылки.';

  @override
  String get vaultContainsDuplicateCredentialIdentities =>
      'Сейф содержит повторяющиеся идентичности учётных данных.';

  @override
  String get vaultKeysAreBeingCleared => 'Ключи сейфа удаляются.';

  @override
  String vaultQuotaUpdatedToQuotabytesBytes(int quotaBytes) {
    return 'Квота сейфа обновлена: $quotaBytes байт.';
  }

  @override
  String get vaultReferenceRecordIdentityIsMalformed =>
      'Идентичность записи-ссылки сейфа повреждена.';

  @override
  String get vaultSyncDidNotConfirmThe =>
      'Синхронизация сейфа не подтвердила проверенное одобрение ключа SSH-хоста.';

  @override
  String get vaultSyncDidNotConfirmThis =>
      'Синхронизация сейфа не подтвердила одобрение этого SSH-ключа. Подключение остановлено; синхронизируйте сейф и проверьте ключ снова.';

  @override
  String get vaultSyncIsUnavailableExistingSsh =>
      'Синхронизация сейфа недоступна. Чтобы продолжить подключение, историю ключей SSH-хоста нужно проверить онлайн.';

  @override
  String vaultIdHasConflictingDeviceKeys(String id) {
    return 'У сейфа $id для одной эпохи ключа есть конфликтующие ключи устройств.';
  }

  @override
  String vaultIdHasNoKeyEnvelope(String id) {
    return 'У сейфа $id нет конверта ключа для активной эпохи.';
  }

  @override
  String vaultIdHasNoKeyEnvelope2(String id) {
    return 'У сейфа $id нет конверта ключа для текущего устройства.';
  }

  @override
  String vaultIdKeyEnvelopeEpochDoes(String id) {
    return 'Эпоха конверта ключа сейфа $id не соответствует версии членства.';
  }

  @override
  String vaultIdKeyEnvelopeRefersTo(String id) {
    return 'Конверт ключа сейфа $id ссылается на неизвестную версию членства.';
  }

  @override
  String vaultIdKeyEnvelopeSignerIs(String id) {
    return 'Подписавший конверт ключа сейфа $id не был участником в подписанной версии.';
  }

  @override
  String vaultIdLatestSignedMembershipEpoch(String id) {
    return 'Эпоха последнего подписанного членства сейфа $id не совпадает с описанием сервера.';
  }

  @override
  String vaultIdLegacyDisplayNameEnvelope(String id) {
    return 'Устаревший конверт отображаемого имени сейфа $id не открывается ни одним доступным ключом эпохи.';
  }

  @override
  String vaultIdMembershipDoesNotInclude(String id) {
    return 'Членство сейфа $id не включает эту учётную запись как активного участника.';
  }

  @override
  String vaultIdSignedDisplayNameEnvelope(String id) {
    return 'Подписанный конверт отображаемого имени сейфа $id недействителен.';
  }

  @override
  String theEpochEpochKeyForVault(String id, int epoch) {
    return 'Ключ эпохи $epoch для сейфа $id отсутствует; одобрение прервано.';
  }

  @override
  String theCurrentKeyEpochOfVault(String id) {
    return 'Текущей эпохи ключа сейфа $id нет на этом устройстве, поэтому одобрить то устройство нельзя.';
  }

  @override
  String theSigningDeviceForVaultId(String id) {
    return 'Устройство, подписавшее сейф $id, неизвестно, поэтому конверт ключа нельзя проверить.';
  }

  @override
  String vaultSubstring(String substring) {
    return 'Сейф $substring';
  }

  @override
  String vaultVaultidChangedOwnerWithoutA(String vaultId) {
    return 'Владелец сейфа $vaultId сменился без передачи, подписанной прежним владельцем.';
  }

  @override
  String vaultVaultidHasAnOwnershipTransfer(String vaultId) {
    return 'У сейфа $vaultId есть передача владения, подписанная новым владельцем.';
  }

  @override
  String vaultVaultidMembershipHasAnInvalid(String vaultId) {
    return 'Членство сейфа $vaultId содержит недопустимого участника.';
  }

  @override
  String vaultVaultidMembershipHasNoMembers(String vaultId) {
    return 'В членстве сейфа $vaultId нет участников.';
  }

  @override
  String vaultVaultidMembershipMustContainExactly(String vaultId) {
    return 'Членство сейфа $vaultId должно содержать ровно одного активного владельца.';
  }

  @override
  String vaultVaultidMembershipSignerIsAbsent(String vaultId) {
    return 'Подписавший членство сейфа $vaultId отсутствует в каталоге устройств.';
  }

  @override
  String vaultVaultidMembershipWasNotSigned(String vaultId) {
    return 'Членство сейфа $vaultId не подписано активным владельцем.';
  }

  @override
  String vaultVaultidOwnershipTransferChangedUnrelated(String vaultId) {
    return 'Передача владения сейфом $vaultId изменила посторонние данные членства.';
  }

  @override
  String vaultVaultidOwnershipTransferDoesNot(String vaultId) {
    return 'Передача владения сейфом $vaultId не соответствует подписанной цепочке владельцев и эпох.';
  }

  @override
  String vaultVaultidOwnershipTransferMetadataIs(String vaultId) {
    return 'Метаданные передачи владения сейфом $vaultId недействительны.';
  }

  @override
  String vaultVaultidOwnershipTransferUnexpectedlyChanged(String vaultId) {
    return 'Передача владения сейфом $vaultId неожиданно изменила состав участников.';
  }

  @override
  String theApprovalKeyEnvelopeSignatureFor(String vaultId) {
    return 'Подпись конверта ключа одобрения для сейфа $vaultId недействительна.';
  }

  @override
  String theApprovedKeyForVaultVaultid(String vaultId) {
    return 'Одобренный ключ сейфа $vaultId не удалось распечатать как ключ сервера.';
  }

  @override
  String theServerKeyEnvelopeForVault(String vaultId) {
    return 'Конверт ключа сейфа $vaultId на сервере не совпадает с файлом одобрения.';
  }

  @override
  String get someActiveDevicesInTheVault =>
      'Некоторые активные устройства сейфа не поддерживают схему 2 или вложения до 1 ГиБ. Обновите эти устройства или удалите из сейфа неиспользуемые, затем повторите попытку.';

  @override
  String get vaultCreationReturnedSuccessButThe =>
      'Создание сейфа завершилось успешно, но сервер пока не смог проверить подготовленные данные; журнал миграции сохранён.';

  @override
  String get theVaultCreationResultCantBe =>
      'Результат создания сейфа сейчас нельзя подтвердить; журнал миграции сохранён. Продолжите позже.';

  @override
  String get theVaultDeletionGracePeriodHas =>
      'Льготный период удаления сейфа истёк; отменить удаление нельзя.';

  @override
  String get theVaultDeletionScheduleWasCreated =>
      'Удаление сейфа запланировано; срок на сервере обновлён.';

  @override
  String get theVaultDeletionScheduleWasCancelled =>
      'Запланированное удаление сейфа отменено, запись снова разрешена.';

  @override
  String get theVaultSyncStateIsAbnormal =>
      'Состояние синхронизации сейфа нарушено, поэтому безопасно проверить ключи SSH-хостов нельзя.';

  @override
  String get theVaultNameHasntBeenVerified =>
      'Имя сейфа не проверено ключом; создание приглашения остановлено.';

  @override
  String get theVaultNameHasntBeenVerified2 =>
      'Имя сейфа не проверено ключом; смена ключа участников остановлена.';

  @override
  String get theVaultWasSwitchedWhilePreparing =>
      'Сейф переключён во время подготовки подключения рабочего пространства. Переподключитесь.';

  @override
  String get theVaultKeyStateStillCant =>
      'Состояние ключа сейфа по-прежнему не удаётся проверить; ожидающие синхронизации локальные данные сохранены.';

  @override
  String get youCantSwitchVaultsWhileThe =>
      'Во время смены ключа сейфа переключать сейфы нельзя.';

  @override
  String get theVaultHasntFinishedFullySyncing =>
      'Сейф ещё не полностью синхронизировал текущую версию. Выполните синхронизацию и повторите попытку.';

  @override
  String get theVaultWasSwitchedReopenThe =>
      'Сейф переключён. Откройте хост заново и повторите попытку.';

  @override
  String get theVaultWasSwitchedReopenThe2 =>
      'Сейф переключён. Откройте учётные данные заново и повторите попытку.';

  @override
  String get theVaultWasSwitchedReopenThe4 =>
      'Сейф переключён. Откройте группу заново и повторите попытку.';

  @override
  String get theVaultWasSwitchedReopenThe3 =>
      'Сейф переключён. Откройте корзину заново.';

  @override
  String get theVaultWasSwitchedReopenThe5 =>
      'Сейф переключён. Откройте сниппет заново и повторите попытку.';

  @override
  String get theVaultWasSwitchedThePreference =>
      'Сейф переключён; исправление настроек приостановлено.';

  @override
  String get theVaultWasSwitchedCommandHistory =>
      'Сейф переключён; синхронизация истории команд не включена.';

  @override
  String get vaultCreatedItsKeyWasGenerated =>
      'Сейф создан; его ключ сгенерирован и подписан этим устройством.';

  @override
  String get theVaultsCurrentEpochOrMembership =>
      'Текущая эпоха или версия членства сейфа недействительна.';

  @override
  String get theVaultsCurrentKeyEpochDoesnt =>
      'Текущая эпоха ключа сейфа не совпадает с подписанным списком участников.';

  @override
  String get aVaultMemberChangeIsIn =>
      'Выполняется изменение участников сейфа. Повторите попытку позже.';

  @override
  String get localChangesArePausedDuringThe =>
      'Во время смены ключа участников сейфа локальные изменения приостановлены. Повторите попытку после завершения.';

  @override
  String get theVaultMemberKeyRotationIs =>
      'Фиксируется смена ключа участников сейфа. Дождитесь завершения, прежде чем блокировать рабочее пространство.';

  @override
  String get theVaultMemberKeyRotationIs2 =>
      'Фиксируется смена ключа участников сейфа. Дождитесь завершения, прежде чем блокировать учётную запись.';

  @override
  String get vaultMembersOrTheSignedIn =>
      'Участники сейфа или устройство входа изменились. Выберите устройства-наблюдатели заново.';

  @override
  String get invalidVaultMembershipVersionSyncAnd =>
      'Недопустимая версия членства в сейфе. Выполните синхронизацию и повторите попытку.';

  @override
  String get vaultMembershipChangedUnlockToVerify =>
      'Членство в сейфе изменилось; разблокируйте, чтобы проверить актуальные права и ключи.';

  @override
  String get theVaultOrSshConnectionChanged =>
      'Сейф или SSH-соединение изменились; переподключите текущую панель рабочего пространства.';

  @override
  String get theVaultOrSignInSession =>
      'Сейф или сеанс входа переключены. Откройте корзину заново.';

  @override
  String get theVaultOrSignedInDevice =>
      'Сейф или устройство входа изменились; присоединение к общему терминалу отменено.';

  @override
  String get theVaultOrSignedInDevice2 =>
      'Сейф или устройство входа изменились; переподключение к общему терминалу отменено.';

  @override
  String get theVaultOrDeviceStateChanged =>
      'Состояние сейфа или устройства изменилось. Откройте общий терминал заново.';

  @override
  String get vaultOwnershipWasTransferredThisAccount =>
      'Владение сейфом передано. У этой учётной записи остаётся доступ редактора; новый владелец и все оставшиеся активные устройства получили ключ новой эпохи. Ожидающие токены приглашений недействительны — новый владелец должен выдать их заново.';

  @override
  String get theVaultIsRestoringOrChanging =>
      'Сейф восстанавливается или меняет состав участников, поэтому ключи SSH-хостов сейчас нельзя проверить.';

  @override
  String get aVaultStateActionIsIn =>
      'Выполняется действие с состоянием сейфа. Повторите попытку позже.';

  @override
  String get theVaultDeviceDirectoryIsMissing =>
      'В каталоге устройств сейфа нет действительной учётной записи или открытого ключа подписи.';

  @override
  String get theTmuxSessionStartedAndWas =>
      'Сеанс tmux запущен и сохранён в рабочем пространстве в зашифрованном виде.';

  @override
  String get theTmuxActionTimedOutCheck =>
      'Истекло время действия tmux. Проверьте состояние хоста и повторите попытку.';

  @override
  String theLabelPreferenceConflictWasRepaired(String label) {
    return 'Конфликт настройки «$label» исправлен и подтверждён синхронизацией с сервером.';
  }

  @override
  String theLabelPreferenceConflictWasConfirmed(String label) {
    return 'Конфликт настройки «$label» подтверждён синхронизацией.';
  }

  @override
  String messageCode(String message, String code) {
    return '$message ($code)';
  }

  @override
  String noticemessageThisDeviceCouldntSaveThe(Object noticeMessage) {
    return '$noticeMessage Устройству не удалось сохранить состояние синхронизации текущего сеанса; в других открытых вкладках может потребоваться повторный вход.';
  }

  @override
  String get uploadMissingEncryptedObjectsAndRestore =>
      'Отправить недостающие зашифрованные объекты и атомарно восстановить локальное состояние';

  @override
  String get youCantRevokeThisDeviceFrom =>
      'Нельзя отозвать текущее устройство с него самого';

  @override
  String get theCurrentlySignedInAdminAccount =>
      'Учётной записью администратора, под которой выполнен вход, отсюда управлять нельзя.';

  @override
  String get aGroupCantBeMovedInto =>
      'Группу нельзя переместить в саму себя или в её подгруппу.';

  @override
  String get theCurrentVaultOwnerCantBe =>
      'Текущего владельца сейфа нельзя отозвать или понизить через ротацию участников.';

  @override
  String get theVaultOwnerCantBeRevoked =>
      'Владельца сейфа нельзя отозвать или понизить этим действием.';

  @override
  String get theNewMasterPasswordsDontMatch =>
      'Новые мастер-пароли не совпадают.';

  @override
  String get thePersonalVaultWasGeneratedAnd =>
      'Личный сейф создан и зашифрован на этом устройстве; его ключ никогда не отправляется на сервер.';

  @override
  String get aMasterPasswordChangeIsIn =>
      'Выполняется смена мастер-пароля. Дождитесь её завершения, прежде чем удалять учётную запись.';

  @override
  String get aMasterPasswordChangeIsIn2 =>
      'Выполняется смена мастер-пароля. Повторите попытку позже.';

  @override
  String get theMasterPasswordChangeIsBeing =>
      'Фиксируется смена мастер-пароля. Дождитесь завершения, прежде чем блокировать рабочее пространство.';

  @override
  String get theMasterPasswordChangeIsBeing2 =>
      'Фиксируется смена мастер-пароля. Дождитесь завершения, прежде чем блокировать учётную запись.';

  @override
  String get masterPasswordChangedOtherSignIn =>
      'Мастер-пароль изменён; остальные сеансы входа отозваны.';

  @override
  String get theMasterPasswordWasCommittedBut =>
      'Мастер-пароль зафиксирован, но обновлённый профиль учётной записи противоречив; повторите попытку для подтверждения.';

  @override
  String get theMasterPasswordMustBeAt2 =>
      'Мастер-пароль должен содержать не менее 12 символов';

  @override
  String get theMasterPasswordMustBeAt3 =>
      'Мастер-пароль должен содержать не менее 12 символов.';

  @override
  String get masterPasswordVerificationFailedTheDeletion =>
      'Проверка мастер-пароля не пройдена; график удаления не изменён. Введите мастер-пароль снова.';

  @override
  String get aHostCantUseItselfAs =>
      'Хост не может быть промежуточным для самого себя.';

  @override
  String get theHostCouldntBeReadBack =>
      'Не удалось перечитать хост после сохранения.';

  @override
  String get theHostHasntGrantedThisDevice =>
      'Хост не предоставил этому устройству действующего управления вводом.';

  @override
  String get theHostNoLongerExistsResync =>
      'Хост больше не существует. Синхронизируйте заново и повторите попытку.';

  @override
  String get theHostWasSavedEncryptedAnd =>
      'Хост сохранён в зашифрованном виде и добавлен в локальную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get theHostWasSavedEncryptedLocally =>
      'Хост сохранён локально в зашифрованном виде и ждёт синхронизации.';

  @override
  String get theHostRevokedOrEndedInput =>
      'Хост отозвал или завершил управление вводом.';

  @override
  String get theHostOrJumpHostRoute =>
      'Маршрут хоста или промежуточного хоста изменился во время подготовки подключения. Переподключитесь.';

  @override
  String get hostInputControlEnded => 'Управление вводом хоста завершено.';

  @override
  String get hostInputControlAuthorizationExpired =>
      'Срок разрешения на управление вводом хоста истёк.';

  @override
  String get onlyIsolatedRestoreCopiesInThe =>
      'Удалить можно только изолированные копии в состоянии «подготовлено». Обновите список заданий.';

  @override
  String get theJobIsStillRunningAnd =>
      'Задание ещё выполняется, автоматическая проверка состояния приостановлена. Состояние можно обновить вручную.';

  @override
  String get theJobStatusIsTemporarilyUnavailable =>
      'Состояние задания временно недоступно, автоматическая проверка приостановлена. Состояние можно обновить вручную.';

  @override
  String get theSessionWasRefreshedButThe =>
      'Сеанс обновлён, но новый снимок сеанса не удалось безопасно сохранить; эта вкладка пока может работать, а в других потребуется повторный вход.';

  @override
  String get theSavedTmuxSessionNoLonger =>
      'Сохранённый сеанс tmux больше не существует; новый сеанс автоматически не создаётся.';

  @override
  String get theRepairTombstoneHasntBeenConfirmed =>
      'Метка исправления ещё не подтверждена курсором изменений сервера. Выполните синхронизацию и повторите попытку.';

  @override
  String get theCandidateRecordIsMissingA =>
      'У записи-кандидата нет проверенной текущей версии; исправление приостановлено.';

  @override
  String get aPreferenceRepairIsInProgress =>
      'Выполняется исправление настроек. Дождитесь завершения и повторите попытку.';

  @override
  String get thePreferenceRepairStateCantBe =>
      'Состояние исправления настроек нельзя проверить. Повторите синхронизацию, прежде чем продолжать.';

  @override
  String get thePreferenceRepairStateCantBe2 =>
      'Состояние исправления настроек нельзя проверить; синхронизируйте заново, прежде чем продолжать.';

  @override
  String get theSharedSessionEndedAndThe =>
      'Общий сеанс завершён, аренда управления вводом отозвана.';

  @override
  String get compatibleSftpDownloadsOnlySupportFiles =>
      'Совместимое скачивание по SFTP поддерживает файлы не больше 16 МиБ';

  @override
  String get invalidCompatibleDownloadSizeLimit =>
      'Недопустимый лимит размера совместимого скачивания';

  @override
  String get preparingExport => 'Подготовка экспорта';

  @override
  String get preparingVerification => 'Подготовка проверки';

  @override
  String get theCredentialNameCantBeEmpty =>
      'Имя учётных данных не может быть пустым';

  @override
  String get theCredentialUserNameCantBe =>
      'Имя пользователя в учётных данных не может быть пустым';

  @override
  String get theShareRequestComesFromA =>
      'Запрос на доступ получен с другого экземпляра сервера.';

  @override
  String get groups => 'Группы';

  @override
  String get theGroupDeletionWasSavedEncrypted =>
      'Удаление группы сохранено в зашифрованном виде и добавлено в локальную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get theGroupDeletionWasSavedEncrypted2 =>
      'Удаление группы сохранено в зашифрованном виде и распространится на другие устройства после синхронизации.';

  @override
  String get theGroupNameCantExceed256 =>
      'Имя группы не может превышать 256 байт UTF-8.';

  @override
  String get theGroupNameContainsUnsupportedControl =>
      'Имя группы содержит неподдерживаемые управляющие символы.';

  @override
  String get theGroupWasSavedEncryptedAnd =>
      'Группа сохранена в зашифрованном виде и добавлена в локальную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get groupSavedEncryptedWaitingToSync =>
      'Группа сохранена в зашифрованном виде и ждёт синхронизации.';

  @override
  String get invalidGroupColor => 'Недопустимый цвет группы.';

  @override
  String get anAccountBeingDeletedCantPerform =>
      'Удаляемая учётная запись не может выполнить это действие.';

  @override
  String get anAccountBeingDeletedCantRevoke =>
      'Удаляемая учётная запись не может отзывать сеансы.';

  @override
  String get theDeletionTombstoneIsStillWaiting =>
      'Метка удаления ещё ждёт подтверждения в потоке изменений. Повторите синхронизацию.';

  @override
  String get theDeletionTombstoneWasSavedEncrypted =>
      'Метка удаления сохранена в зашифрованном виде и добавлена в локальную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get theDeletionWasSavedAsAn =>
      'Удаление сохранено как зашифрованная метка и распространится на другие устройства после синхронизации.';

  @override
  String get encryptedBackupJobSubmittedItsStatus =>
      'Задание зашифрованного резервного копирования отправлено. Его состояние появится в списке ниже.';

  @override
  String get protocol2 => 'Протокол';

  @override
  String get anotherSyncTaskIsStillRunning =>
      'Ещё выполняется другая задача синхронизации. Повторите исправление настроек после её завершения.';

  @override
  String get anotherInstanceAdminJobIsRunning =>
      'Выполняется другое задание администрирования экземпляра. Повторите попытку позже.';

  @override
  String get onlyTheVaultOwnerCanManage =>
      'Управлять удалением может только владелец сейфа.';

  @override
  String get onlyTheVaultOwnerCanManage2 =>
      'Управлять участниками может только владелец сейфа.';

  @override
  String get onlyTheVaultOwnerCanInvite =>
      'Приглашать участников может только владелец сейфа.';

  @override
  String get onlyTheCurrentVaultOwnerCan =>
      'Изменять согласие на автоматическое удаление может только владелец текущего сейфа.';

  @override
  String get onlyTheCurrentVaultOwnerCan2 =>
      'Окончательно удалять записи может только владелец текущего сейфа.';

  @override
  String get inputControlCanOnlyBeGranted =>
      'Управление вводом можно передать только устройствам, явно одобренным для этого доступа.';

  @override
  String get onlyExistingHostsInTheCurrent =>
      'Ссылаться можно только на существующие хосты текущего сейфа.';

  @override
  String get aVaultWithThisIdAlready =>
      'Сейф с этим ID уже существует, но это не новый пустой сейф, подготовленный сейчас.';

  @override
  String get aGroupWithThisNameAlready =>
      'В этом родителе уже есть группа с таким именем. Измените имя или выберите другого родителя.';

  @override
  String get theSyncVaultWasSwitchedOr =>
      'Синхронизируемый сейф переключён или больше не доступен для записи; миграция приостановлена.';

  @override
  String get theSyncVaultWasSwitchedMigration =>
      'Синхронизируемый сейф переключён; миграция приостановлена.';

  @override
  String get aSyncIsStillRunningThe =>
      'Синхронизация ещё выполняется; изменение участников отменено. Повторите попытку позже.';

  @override
  String get aSyncIsStillRunningRetry =>
      'Синхронизация ещё выполняется. Повторите исправление настроек после её завершения.';

  @override
  String get theConflictCandidatesOrVersionsChanged =>
      'После синхронизации варианты или версии конфликта изменились. Проверьте список и выберите заново.';

  @override
  String syncCompleteReceivedcountChangesReceived(int receivedCount) {
    return 'Синхронизация завершена: получено изменений — $receivedCount.';
  }

  @override
  String get theMasterPasswordCantBeChanged =>
      'Во время синхронизации или восстановления снимка мастер-пароль сменить нельзя. Повторите попытку после завершения.';

  @override
  String get theAccountCantBeDeletedDuring =>
      'Во время синхронизации или восстановления снимка удалить учётную запись нельзя. Повторите попытку после завершения.';

  @override
  String get name => 'Имя';

  @override
  String get address => 'Адрес';

  @override
  String get theBackupIntervalMustBe1 =>
      'Интервал резервного копирования должен составлять от 1 до 720 часов.';

  @override
  String get aMasterPasswordChangeIsWaiting =>
      'Смена мастер-пароля ожидает подтверждения; сначала повторите исходное действие.';

  @override
  String get theInstanceIsAlreadyInitializedFirst =>
      'Экземпляр уже инициализирован; регистрация первой учётной записи больше недоступна.';

  @override
  String get theAuditCursorExpiredTheServer =>
      'Курсор аудита истёк. Возможно, сервер сменил поколение; загрузите заново с первой страницы.';

  @override
  String get thePasswordCantBeEmpty => 'Пароль не может быть пустым';

  @override
  String get thePasswordChangeOperationStateConflicts =>
      'Состояние операции смены пароля конфликтует. Чтобы не сменить пароль дважды, сохраните текущий сеанс и обратитесь к администратору.';

  @override
  String get noServerInstanceIsConfiguredYet =>
      'Экземпляр сервера ещё не настроен.';

  @override
  String get nestedWorkspacesCanOnlyReferenceExisting =>
      'Вложенные рабочие пространства могут ссылаться только на существующие хосты текущего сейфа.';

  @override
  String get theWorkspaceTmuxReferenceChangedReload =>
      'Ссылка tmux в рабочем пространстве изменилась. Перезагрузите и повторите попытку.';

  @override
  String get theWorkspaceHostWasRemovedFrom =>
      'Хост рабочего пространства удалён из текущего сейфа во время подготовки подключения; сначала исправьте ссылку.';

  @override
  String get theWorkspaceDeletionWasAddedTo =>
      'Удаление рабочего пространства добавлено в локальную зашифрованную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get theWorkspaceDeletionWasSavedEncrypted =>
      'Удаление рабочего пространства сохранено в зашифрованном виде и распространится на другие устройства после синхронизации.';

  @override
  String get workspacesCanOnlyAddReferencesTo =>
      'Рабочие пространства могут добавлять ссылки только на существующие хосты текущего сейфа.';

  @override
  String get theWorkspaceNoLongerExistsIn =>
      'Рабочего пространства больше нет в текущем сейфе.';

  @override
  String get theWorkspaceWasSwitchedTryAgain =>
      'Рабочее пространство переключено. Повторите попытку.';

  @override
  String get theWorkspaceWasSavedEncryptedAnd =>
      'Рабочее пространство сохранено в зашифрованном виде и добавлено в локальную очередь синхронизации; обновить состояние синхронизации не удалось, попытка будет повторена позже.';

  @override
  String get workspaceSavedEncryptedWaitingToSync =>
      'Рабочее пространство сохранено в зашифрованном виде и ждёт синхронизации.';

  @override
  String get theWorkspaceChanged => 'Рабочее пространство изменилось.';

  @override
  String get theWorkspaceIsLockedButThis =>
      'Рабочее пространство заблокировано, но запись автоматической разблокировки на устройстве очистить не удалось; исправьте локальное хранилище, затем войдите снова и заблокируйте.';

  @override
  String get theWorkspaceIsntLockedRightNow =>
      'Рабочее пространство сейчас не заблокировано.';

  @override
  String get theWorkspacePaneNoLongerExists =>
      'Панель рабочего пространства больше не существует.';

  @override
  String get theWorkspacePaneOrHostReference =>
      'Панель рабочего пространства или ссылка на хост изменились. Переподключитесь и повторите попытку.';

  @override
  String get localChangesAreBlockedWhileThe =>
      'Пока рабочее пространство заблокировано, локальные изменения запрещены. Сначала разблокируйте его.';

  @override
  String uploadedName(String name) {
    return 'Отправлено: $name';
  }

  @override
  String savedName(String name) {
    return 'Сохранено: $name';
  }

  @override
  String savedNameButCouldntConfirmThe(String name) {
    return '$name сохранён, но не удалось подтвердить восстановление исходных прав; проверьте права удалённого файла.';
  }

  @override
  String get thePinnedServerIdentityChangedDuring =>
      'Закреплённая идентичность сервера изменилась во время подтверждения. Переподключитесь и повторите попытку.';

  @override
  String get unlockedLocallyTheServerStillStores =>
      'Разблокировано локально; сервер по-прежнему хранит только зашифрованные записи и конверты ключей.';

  @override
  String get memberInvitationAcceptedTheVaultIs =>
      'Приглашение принято; сейф разблокирован, синхронизация началась.';

  @override
  String get anExistingRepairTombstoneAlreadySpecifies =>
      'Существующая метка исправления уже указывает сохраняемую запись; повторите исправление с этой записью.';

  @override
  String get theRecordRetainedByAnExisting =>
      'Запись, сохранённая существующей меткой исправления, противоречива и требует ручной проверки.';

  @override
  String get aServerAccessGroupWithThe =>
      'Группа доступа к серверу с таким именем уже существует (без учёта регистра и совместимых символов Unicode).';

  @override
  String get thePreviouslySubmittedMasterPasswordChange =>
      'Ранее отправленная смена мастер-пароля подтверждена; остальные сеансы входа отозваны.';

  @override
  String get attachedToTheSavedTmuxSession =>
      'Подключено к сохранённому сеансу tmux.';

  @override
  String theKeyKeyInTheArchive(String key) {
    return 'Ключ $key в архиве не совпадает с локально разблокированным ключом.';
  }

  @override
  String get theArchiveNoLongerCorrespondsTo =>
      'Архив больше не соответствует текущему пространству сервера или сейфу; импорт не выполнен.';

  @override
  String get theArchiveWasVerifiedAndRestored =>
      'Архив проверен и восстановлен. Исторические ключи хранятся только в памяти этого клиента; локальная очередь отправки и ветки конфликтов сохранены.';

  @override
  String get lockTheWorkspaceAfterTheArchive =>
      'Блокируйте рабочее пространство после завершения операции с архивом.';

  @override
  String get theCurrentOwnerDeviceIsntIn =>
      'Текущее устройство владельца не входит в набор активных устройств оставшихся участников; ротация прервана.';

  @override
  String get theCurrentPostgresqlModeSupportsInstance =>
      'Текущий режим PostgreSQL поддерживает обслуживание экземпляра; серверное зашифрованное резервное копирование и восстановление пока недоступны.';

  @override
  String get theCurrentVaultIsntWritable =>
      'Текущий сейф недоступен для записи.';

  @override
  String theCurrentVaultIsntWritableSo(String label) {
    return 'Текущий сейф недоступен для записи, поэтому настройку «$label» исправить нельзя.';
  }

  @override
  String get theCurrentVaultIsReadOnly6 =>
      'Текущий сейф доступен только для чтения или удаляется; синхронизацию истории команд включить нельзя.';

  @override
  String get theCurrentVaultIsReadOnly =>
      'Текущий сейф доступен только для чтения; изменять настройки нельзя.';

  @override
  String get theCurrentVaultIsReadOnly2 =>
      'Текущий сейф доступен только для чтения; изменять группы нельзя.';

  @override
  String get theCurrentVaultIsReadOnly3 =>
      'Текущий сейф доступен только для чтения; удалять группы нельзя.';

  @override
  String get theCurrentVaultIsReadOnly4 =>
      'Текущий сейф доступен только для чтения; согласие на автоматическое удаление изменить нельзя.';

  @override
  String get theCurrentVaultIsReadOnly5 =>
      'Текущий сейф доступен только для чтения; окончательно удалять записи нельзя.';

  @override
  String get theCurrentVaultSyncRepositoryIsnt =>
      'Репозиторий синхронизации текущего сейфа ещё не готов.';

  @override
  String get theCurrentVaultSyncTimedOut =>
      'Истекло время синхронизации текущего сейфа; проверка доверия к ключу SSH-хоста остановлена.';

  @override
  String get theCurrentVaultIsLockedSo =>
      'Текущий сейф заблокирован, поэтому ключи SSH-хостов нельзя проверить.';

  @override
  String get theCurrentVaultOrSignedIn =>
      'Текущий сейф или устройство входа нельзя использовать для общего терминала.';

  @override
  String get refreshingTheCurrentVaultStateTimed =>
      'Истекло время обновления состояния текущего сейфа; проверка доверия к ключу SSH-хоста остановлена.';

  @override
  String get theCurrentMasterPasswordOrSix =>
      'Текущий мастер-пароль или шестизначный код аутентификатора недействителен или уже использован. Снова введите мастер-пароль и новый шестизначный код.';

  @override
  String get theCurrentMasterPasswordOrAccount =>
      'Не удаётся проверить текущий мастер-пароль или конверт ключа учётной записи.';

  @override
  String get theCurrentMasterPasswordMustBe =>
      'Текущий мастер-пароль должен содержать не менее 12 символов.';

  @override
  String get theCurrentMasterPasswordCouldntBe =>
      'Не удалось подтвердить текущий мастер-пароль; учётные данные не изменены. Проверьте пароль и повторите попытку.';

  @override
  String get theCurrentHostOrVaultIs => 'Текущий хост или сейф недоступен.';

  @override
  String get tmuxIsntAvailableOnTheCurrent =>
      'На текущем хосте tmux недоступен.';

  @override
  String get theCurrentSessionIsMissingThe =>
      'В текущем сеансе отсутствует имя учётной записи.';

  @override
  String get theCurrentSyncHasntFinishedWait =>
      'Текущая синхронизация не завершена. Дождитесь её, прежде чем создавать приглашение.';

  @override
  String get theCurrentSyncHasntFinishedWait2 =>
      'Текущая синхронизация не завершена. Дождитесь её, прежде чем менять участников сейфа.';

  @override
  String get anInputControlLeaseIsAlready =>
      'Аренда управления вводом уже активна. Сначала отзовите её.';

  @override
  String get theCurrentMemberRoleCantBe =>
      'Текущую роль участника нельзя отозвать этим действием.';

  @override
  String get theCurrentServerDoesntDeclareSupport =>
      'Текущий сервер не заявляет поддержку удаления изолированных копий для восстановления.';

  @override
  String get theresNoSignedInAccountWhose =>
      'Нет учётной записи, в которой можно сменить пароль.';

  @override
  String get noAccountIsSignedIn => 'Ни одна учётная запись не выполнила вход.';

  @override
  String thereAreNoPendingLabelPreference(String label) {
    return 'Нет ожидающих конфликтов настройки «$label».';
  }

  @override
  String get theCurrentTestSshConnectorDoesnt =>
      'Текущий тестовый SSH-коннектор не поддерживает промежуточные хосты.';

  @override
  String get theCurrentTestSshConnectorDoesnt2 =>
      'Текущий тестовый SSH-коннектор не поддерживает многоступенчатые промежуточные хосты.';

  @override
  String get thisBrowserHasNoRegisteredDevice =>
      'В этом браузере нет зарегистрированного ключа устройства. Добавьте устройство заново с авторизованного устройства.';

  @override
  String get thisBrowserHasNoRegisteredDevice2 =>
      'В этом браузере нет зарегистрированного ключа устройства. Сначала добавьте это устройство с авторизованного устройства.';

  @override
  String get theCurrentDeviceKeyIsMissing =>
      'Ключ текущего устройства отсутствует или не соответствует сеансу. Авторизуйте устройство заново.';

  @override
  String get thisDeviceDoesntHaveKeysFor =>
      'У этого устройства нет ключей всех сейфов, поэтому одобрить то устройство нельзя.';

  @override
  String get theCurrentDeviceIdentityDoesntMatch =>
      'Идентичность текущего устройства не соответствует сеансу входа.';

  @override
  String get theCurrentAccountOrVaultChanged =>
      'Текущая учётная запись или сейф изменились, поэтому ключ SSH-хоста проверить нельзя.';

  @override
  String get theCurrentAccountDoesntHaveInstance =>
      'У текущей учётной записи нет прав администратора экземпляра.';

  @override
  String get theCurrentAccountIdentityIsUnavailable =>
      'Идентичность текущей учётной записи недоступна. Войдите снова.';

  @override
  String get theCurrentAccountVerificationDetailsDont =>
      'Данные проверки текущей учётной записи не совпадают.';

  @override
  String get theRoleOfAPendingInvitation =>
      'Роль в ожидающем приглашении нельзя изменить напрямую. Отзовите его и пригласите заново с новой ролью.';

  @override
  String get thePendingMasterPasswordChangeRequest =>
      'Ожидающий запрос на смену мастер-пароля удалён.';

  @override
  String get theServerIdentityAwaitingConfirmationWas =>
      'Ожидавшая подтверждения идентичность сервера отменена. Переподключитесь и повторите попытку.';

  @override
  String get theSnapshotWasRestoredSafelySome =>
      'Снимок безопасно восстановлен; часть операций ещё ждёт отправки или конфликты ждут повтора. Исходная очередь отправки сохранена.';

  @override
  String snapshotRestoreCompleteReceivedcountRecordsVerified(
    int receivedCount,
  ) {
    return 'Восстановление снимка завершено: проверено и восстановлено записей — $receivedCount.';
  }

  @override
  String get youCantSwitchVaultsDuringSnapshot =>
      'Во время восстановления снимка переключать сейфы нельзя.';

  @override
  String get localChangesArePausedDuringSnapshot =>
      'Во время восстановления снимка локальные изменения приостановлены. Повторите попытку после завершения.';

  @override
  String get theMemberRoleCanOnlyBe =>
      'Роль участника можно установить только как editor или viewer.';

  @override
  String get theMemberRoleWasUpdatedAnd =>
      'Роль участника обновлена, ключи сменены для всех оставшихся устройств участников.';

  @override
  String get theMemberRoleWasUpdatedAnd2 =>
      'Роль участника обновлена, ключи сменены для всех оставшихся устройств. Ожидающие приглашения сохраняются, но старые токены недействительны; пригласите заново.';

  @override
  String get memberRoleUpdatedTheServerCommitted =>
      'Роль участника обновлена; сервер зафиксировал новую эпоху ключа.';

  @override
  String get memberAccessWasRevokedAndThe =>
      'Доступ участника отозван, ключ сейфа сменён для оставшихся участников. Ожидающие приглашения сохраняются, но старые токены недействительны; пригласите заново.';

  @override
  String get memberAccessWasRevokedAndThe3 =>
      'Доступ участника отозван, ключ сейфа сменён для оставшихся участников. Отозванный участник не получит ключ новой эпохи; уже сохранённые им копии удалённо удалить нельзя.';

  @override
  String get memberAccessWasRevokedAndThe2 =>
      'Доступ участника отозван, сервер зафиксировал новую эпоху ключа. Учтите, что уже сохранённые им копии удалённо удалить нельзя.';

  @override
  String get invalidMemberAccountIdFormat =>
      'Недопустимый формат ID учётной записи участника.';

  @override
  String get theMemberRotationResultCantBe =>
      'Результат ротации участников сейчас нельзя подтвердить, поэтому сейф заблокирован, чтобы не использовать старый ключ. Войдите снова и проверьте состояние членства, прежде чем продолжать.';

  @override
  String get ownershipCanOnlyBeTransferredTo =>
      'Владение можно передать только активному участнику, принявшему приглашение.';

  @override
  String get theSelectedJumpHostNoLonger =>
      'Выбранный промежуточный хост больше не существует. Выберите допустимый хост или удалите устаревшую ссылку.';

  @override
  String get theSelectedSshCredentialNoLonger =>
      'Выбранные учётные данные SSH больше не существуют. Выберите действительные или очистите это переопределение.';

  @override
  String get theSelectedSessionNoLongerExists =>
      'Выбранный сеанс больше не существует или уже отозван. Обновите список сеансов.';

  @override
  String get theSelectedRetainedRecordChangedCheck =>
      'Выбранная сохраняемая запись изменилась. Проверьте варианты ещё раз.';

  @override
  String get theSelectedGroupNoLongerExists =>
      'Выбранная группа больше не существует. Выберите допустимую группу или уберите её.';

  @override
  String get theSelectedEncryptedArchiveIsUnavailable =>
      'Выбранный зашифрованный архив недоступен. Обновите список источников и повторите попытку.';

  @override
  String get theSelectedArchiveIsInvalidRefresh =>
      'Выбранный архив недействителен. Обновите список источников и повторите попытку.';

  @override
  String get theSelectedArchiveSourceIsInvalid =>
      'Выбранный источник архива недействителен. Обновите список источников и повторите попытку.';

  @override
  String get theSelectedServerAccessGroupNo =>
      'Выбранная группа доступа к серверу больше не существует. Обновите список.';

  @override
  String get theApprovalFileDoesntMatchThe =>
      'Файл одобрения не соответствует запросу устройства, созданному этим браузером.';

  @override
  String get theVaultKeyEnvelopeContextIn =>
      'Контекст конверта ключа сейфа в файле одобрения недействителен.';

  @override
  String get theVaultKeyEnvelopeInThe2 =>
      'Недопустимый формат конверта ключа сейфа в файле одобрения.';

  @override
  String get theDeviceCapabilityReportInThe =>
      'Недопустимый формат отчёта о возможностях устройства в файле одобрения.';

  @override
  String get theApprovalFileContainsDuplicateVault =>
      'Файл одобрения содержит повторяющиеся конверты ключей сейфа.';

  @override
  String get theApprovalFileBelongsToA =>
      'Файл одобрения относится к другой учётной записи или экземпляру сервера.';

  @override
  String get theApprovalFileIsStagedAfter =>
      'Файл одобрения подготовлен. После входа клиент проверит сертификат владельца и каждый конверт ключа сейфа, прежде чем разблокировать данные.';

  @override
  String get theDeviceSelfProofInThe =>
      'Самоподтверждение устройства в файле одобрения не совпадает с локальным ключом устройства.';

  @override
  String get theApproverOrCurrentDeviceIsnt =>
      'Одобряющее или текущее устройство отсутствует в каталоге устройств учётной записи на сервере.';

  @override
  String get theApproverCertificateFieldsAreInvalid =>
      'Поля сертификата одобряющего недействительны.';

  @override
  String get theApproverCertificateSignatureIsInvalid =>
      'Подпись сертификата одобряющего недействительна.';

  @override
  String get thisHostCouldntBeFound => 'Хост не найден.';

  @override
  String get theVaultOnThisDeviceCouldnt =>
      'Сейф на этом устройстве не найден.';

  @override
  String get theScrapeCredentialWasRotatedThe =>
      'Учётные данные для сбора метрик сменены; значение показывается только один раз.';

  @override
  String get toCancelAccountDeletionSignOut =>
      'Чтобы отменить удаление учётной записи, сначала выйдите и воспользуйтесь восстановлением на странице входа.';

  @override
  String theFileWasSavedButThe(String friendlyError) {
    return 'Файл сохранён, но папку не удалось обновить: $friendlyError';
  }

  @override
  String get theNewMasterPasswordMustDiffer =>
      'Новый мастер-пароль должен отличаться от текущего.';

  @override
  String get theNewMasterPasswordMustBe =>
      'Новый мастер-пароль должен содержать не менее 12 символов.';

  @override
  String get couldntDiscardTheIsolatedRestoreCopy =>
      'Не удалось удалить изолированную копию для восстановления. Обновите список заданий и повторите попытку.';

  @override
  String get couldntSaveChangesToTheTmux =>
      'Не удалось сохранить изменения ссылки на сеанс tmux. Повторите попытку позже.';

  @override
  String get couldntSaveTheScheduledBackupSettings =>
      'Не удалось сохранить настройки планового резервного копирования. Повторите попытку.';

  @override
  String get couldntPrepareTheIsolatedRestoreCopy =>
      'Не удалось подготовить изолированную копию для восстановления. Рабочие данные не изменены.';

  @override
  String get couldntCreateANewTmuxSession =>
      'Не удалось создать новый сеанс tmux. Повторите попытку.';

  @override
  String get couldntJoinInputControlMakeSure =>
      'Не удалось присоединиться к управлению вводом. Убедитесь, что хост всё ещё предоставляет управление этому устройству.';

  @override
  String get couldntStartTheLocalShell =>
      'Не удалось запустить локальную оболочку.';

  @override
  String get couldntStartTerminalSharingCheckThe =>
      'Не удалось начать общий доступ к терминалу. Проверьте подключение и членство в сейфе и повторите попытку.';

  @override
  String couldntSafelyCreateRemoteFileName(String name, Object error) {
    return 'Не удалось безопасно создать удалённый файл $name. Возможно, он уже существует или у текущего пользователя нет прав на запись; существующие файлы не перезаписываются. ($error)';
  }

  @override
  String get couldntSafelyRestoreTheSignIn =>
      'Не удалось безопасно восстановить сеанс входа. Войдите снова.';

  @override
  String get theRefreshRequestStateCouldntBe =>
      'Не удалось безопасно записать состояние запроса обновления, поэтому запрос заблокирован. Проверьте защищённое хранилище устройства и повторите попытку.';

  @override
  String get couldntCompleteTheTmuxSessionAction =>
      'Не удалось выполнить действие с сеансом tmux. Проверьте состояние хоста и повторите попытку.';

  @override
  String couldntFinishSyncingTheCurrentVault(String syncStatus) {
    return 'Не удалось завершить синхронизацию текущего сейфа ($syncStatus); проверка доверия к ключу SSH-хоста остановлена.';
  }

  @override
  String get couldntConfirmTheTmuxSessionStarted =>
      'Не удалось подтвердить запуск сеанса tmux. Проверьте хост и повторите попытку.';

  @override
  String get couldntReadEncryptedArchiveSourcesTry =>
      'Не удалось прочитать источники зашифрованных архивов. Повторите попытку позже.';

  @override
  String get couldntReadLocalSecuritySettingsCheck =>
      'Не удалось прочитать локальные настройки безопасности. Проверьте хранилище браузера и повторите попытку.';

  @override
  String get couldntReadThisTerminalShare =>
      'Не удалось прочитать этот общий терминал.';

  @override
  String get couldntReadTheScheduledBackupSettings =>
      'Не удалось прочитать настройки планового резервного копирования. Повторите попытку.';

  @override
  String get couldntReadTheRestoreJobStatus2 =>
      'Не удалось прочитать состояние задания восстановления. Повторите попытку позже.';

  @override
  String get couldntRejoinTheShareMayHave =>
      'Не удалось присоединиться снова; возможно, общий доступ завершён или доступ к сейфу изменился.';

  @override
  String get couldntVerifyTheCurrentDeviceApproval =>
      'Не удалось проверить одобрение текущего устройства.';

  @override
  String get thePendingVaultRecordsCouldntBe =>
      'Не удалось проверить ожидающие отправки записи сейфа; синхронизация отключена, но офлайн-очередь не очищена.';

  @override
  String get thePendingCommandHistoryCouldntBe =>
      'Не удалось проверить ожидающую отправки историю команд; синхронизация отключена, но офлайн-очередь не очищена.';

  @override
  String get theStagedVaultCreationDataDoesnt =>
      'Подготовленные данные создания сейфа не соответствуют целевому ID.';

  @override
  String get theStagedVaultCreationDataHas =>
      'Недопустимый формат подготовленных данных создания сейфа.';

  @override
  String get couldntReadTheRestoreJobStatus3 =>
      'Сейчас не удаётся прочитать состояние задания восстановления; система продолжит попытки.';

  @override
  String get couldntReadTheRestoreJobStatus =>
      'Сейчас не удаётся прочитать состояние задания восстановления. Повторите вручную.';

  @override
  String upToMaxterminaltabsSshTerminalTabs(int maxTerminalTabs) {
    return 'Одновременно можно открыть не более $maxTerminalTabs вкладок SSH-терминала; сначала закройте одну из них.';
  }

  @override
  String get aVaultIsInItsDeletion =>
      'Один из сейфов в льготном периоде удаления, поэтому сервер сейчас не разрешает одобрять новые устройства.';

  @override
  String get theServerSyncGenerationChangedUnlock =>
      'Поколение синхронизации на сервере изменилось; разблокируйте сейф, чтобы безопасно возобновить синхронизацию.';

  @override
  String get theServerHasntConfiguredEncryptedBackups =>
      'На сервере не настроено зашифрованное резервное копирование. Попросите оператора экземпляра задать ATERMIUS_BACKUP_ARCHIVE_DIR (каталог вне каталога данных, доступный только владельцу) и ATERMIUS_BACKUP_KEY_FILE (32-байтовый файл ключа вне каталога данных, доступный только владельцу). Клиент никогда не отправляет и не показывает эти пути, имена архивов или ключи.';

  @override
  String get theServerHasntConfiguredIsolatedRestore =>
      'На сервере не настроено хранилище изолированного восстановления. Обратитесь к оператору экземпляра.';

  @override
  String get theServerAccessGroupWasUpdated =>
      'Группа доступа к серверу обновлена другим администратором. Загрузите последние данные; текущий черновик сохранён.';

  @override
  String get theServersInitialVaultMembershipRecord =>
      'Недопустимый формат начальной записи участников сейфа на сервере.';

  @override
  String get theServerVaultKeyEnvelopeDoesnt =>
      'Конверт ключа сейфа на сервере не совпадает с данными создания, подготовленными на этом устройстве.';

  @override
  String get theServersVaultMembershipListHas =>
      'Недопустимый формат списка участников сейфа на сервере; смена ключа остановлена.';

  @override
  String get theServerVaultMembershipChainDoesnt =>
      'Цепочка членства сейфа на сервере не совпадает с данными создания, подготовленными на этом устройстве.';

  @override
  String get theServersEncryptedArchiveConfigurationIs =>
      'Конфигурация зашифрованных архивов на сервере недоступна. Обратитесь к оператору сервера.';

  @override
  String get theServerSyncCursorExpiredA =>
      'Курсор синхронизации сервера истёк; требуется новый снимок.';

  @override
  String get theServerInstanceIdChangedAnd =>
      'ID экземпляра сервера изменился, подтвердить его через восстановление ключа нельзя.';

  @override
  String get theServerInstanceIdentityChangedTo =>
      'Идентичность экземпляра сервера изменилась. Чтобы защитить локальный сейф, клиент отказался подключаться.';

  @override
  String theServerHasntConfirmedThatOnly(String label) {
    return 'Сервер ещё не подтвердил, что осталась только выбранная запись настройки «$label». Выполните синхронизацию и повторите попытку.';
  }

  @override
  String get theServerHasntConfiguredAUsable =>
      'На сервере не настроены пригодные место назначения и ключ зашифрованных резервных копий; расписание не изменено.';

  @override
  String get theServerAcceptedTheRevocationRequest =>
      'Сервер принял запрос на отзыв. Старый сеанс не будет восстановлен; войдите снова.';

  @override
  String get theServerAcceptedTheDeletionRequest2 =>
      'Сервер принял запрос на удаление, но вернул недопустимое состояние льготного периода.';

  @override
  String get theServerAcceptedTheDeletionRequest =>
      'Сервер принял запрос на удаление; текущий сеанс и ключ разблокировки этого устройства удалены. Воспользуйтесь восстановлением учётной записи на странице входа; в льготный период удаление можно отменить, после чего нужно войти снова.';

  @override
  String get theServerCommittedTheVaultOwnership =>
      'Сервер зафиксировал передачу владения сейфом и новую эпоху ключа; эта учётная запись понижена до редактора.';

  @override
  String get theServerSnapshotContainsRecordsThis =>
      'Снимок сервера содержит записи, ранее окончательно удалённые на этом устройстве. Чтобы старые данные не вернулись, клиент сохраняет текущий кэш, курсор синхронизации и локальные черновики и останавливает автоматическую синхронизацию. Если сервер только что восстановлен из резервной копии до очистки, администратор должен сначала проверить и повторно обработать состояние восстановления сервера; это устройство не удаляет сохранённые подтверждения очистки автоматически.';

  @override
  String get theServerCommittedTheMemberRotation =>
      'Сервер зафиксировал ротацию участников, но новую эпоху и членство не удаётся проверить локально; дальнейшие действия остановлены.';

  @override
  String get theServerMembershipChainBelongsTo =>
      'Цепочка членства на сервере относится к другому сейфу.';

  @override
  String get theServerRejectedThisBackupSchedule =>
      'Сервер отклонил запрос на расписание резервного копирования. Обновите и повторите попытку.';

  @override
  String get theServerRejectedThisIsolatedRestore =>
      'Сервер отклонил запрос изолированного восстановления. Обновите список источников и повторите попытку.';

  @override
  String get theServerDidntReturnTheVault =>
      'Сервер не вернул ID сейфа для принятого приглашения.';

  @override
  String get theServerDidntReturnAValid =>
      'Сервер не вернул допустимый льготный период и срок удаления.';

  @override
  String get theServerDidntProvideAVerifiable =>
      'Сервер не предоставил проверяемый срок восстановления, поэтому окончательное удаление заблокировано.';

  @override
  String get theServerDidntProvideAValid =>
      'Сервер не предоставил действительную идентичность подписи экземпляра.';

  @override
  String get theServerDidntReturnAnAccount =>
      'Сервер не вернул идентификатор учётной записи, поэтому запрос устройства создать нельзя.';

  @override
  String get theServerSigningKeyDoesntMatch =>
      'Ключ подписи сервера не совпадает с закреплённой идентичностью. Сначала сверьте предлагаемый отпечаток по отдельному доверенному каналу.';

  @override
  String get theServerSigningKeyDoesntMatch2 =>
      'Ключ подписи сервера не совпадает с закреплённой идентичностью. Сравните предлагаемый отпечаток по отдельному доверенному каналу; до подтверждения подключение к учётной записи и запросы аутентификации не выполняются.';

  @override
  String get theServerIsMissingTheExisting =>
      'На сервере нет существующего конверта идентичности восстановления, поэтому безопасно выполнить ротацию нельзя.';

  @override
  String get theServerDeviceDirectoryDoesntMatch =>
      'Каталог устройств сервера не совпадает с учётной записью или открытым ключом в файле одобрения.';

  @override
  String get theServersDeviceCapabilityReportDoesnt =>
      'Отчёт о возможностях устройства на сервере не совпадает с файлом одобрения.';

  @override
  String get theServerIdentityChangedDuringConfirmation =>
      'Идентичность сервера изменилась во время подтверждения. Переподключитесь и сверьте новый отпечаток.';

  @override
  String get serverIdentityConfirmationIsInProgress =>
      'Выполняется подтверждение идентичности сервера.';

  @override
  String get serverIdentityConfirmationIsInProgress2 =>
      'Выполняется подтверждение идентичности сервера; сейчас его нельзя отменить.';

  @override
  String get serverIdentityConfirmationIsInProgress3 =>
      'Выполняется подтверждение идентичности сервера. Дождитесь завершения текущего действия.';

  @override
  String get theServerRotationResultDoesntMatch =>
      'Результат ротации на сервере не совпадает с подписанной эпохой или версией членства.';

  @override
  String get theServerReturnedADifferentMigration =>
      'Сервер вернул другой ID сейфа назначения миграции.';

  @override
  String get theVaultOwnerStateReturnedBy =>
      'Состояние владельца сейфа от сервера не совпадает.';

  @override
  String get theServerReturnedAnInvalidMaster =>
      'Сервер вернул недействительное подтверждение смены мастер-пароля.';

  @override
  String get theServerReturnedAnInvalidRecovery =>
      'Сервер вернул недействительное подтверждение настройки восстановления.';

  @override
  String get theMembershipVersionReturnedByThe =>
      'Версия членства от сервера не совпадает с локальной подписью.';

  @override
  String get theRevocationStateReturnedByThe =>
      'Состояние отзыва от сервера недействительно; сейф остаётся заблокированным.';

  @override
  String get theAccountRevocationStateReturnedBy =>
      'Состояние отзыва учётной записи от сервера недействительно.';

  @override
  String get theServerReturnedDuplicateMigrationDestination =>
      'Сервер вернул повторяющиеся сейфы назначения миграции.';

  @override
  String get noIsolatedRestoreCopyToDiscard =>
      'Изолированная копия для удаления не найдена. Обновите список заданий.';

  @override
  String get thereAreUncommittedLocalChangesRotate =>
      'Есть незафиксированные локальные изменения. Меняйте ключи участников после завершения синхронизации, чтобы старые записи можно было зафиксировать.';

  @override
  String get thereAreUncommittedLocalChangesCreate =>
      'Есть незафиксированные локальные изменения. Создайте приглашение после успешной синхронизации, чтобы старые записи можно было зафиксировать.';

  @override
  String get theLocalFileNameIsntA =>
      'Локальное имя файла не является безопасным именем удалённого файла.';

  @override
  String get localConsole => 'Локальная консоль';

  @override
  String get theLocalConsoleRequiresTheDesktop =>
      'Для локальной консоли нужен настольный клиент.';

  @override
  String get thisDevicesEncryptedHistoryRepositoryIsnt =>
      'Зашифрованный репозиторий истории на этом устройстве ещё не готов.';

  @override
  String get thisDeviceHasNoCurrentSession =>
      'На этом устройстве нет снимка текущего сеанса, который можно безопасно восстановить. Войдите снова.';

  @override
  String get thisSignInCanContinueBut =>
      'Этот вход можно продолжить, но запомнить состояние входа нельзя.';

  @override
  String get refreshingVaultMembershipTryChangingIt =>
      'Обновляется членство в сейфе. Попробуйте изменить чуть позже.';

  @override
  String get anotherVaultMemberInvitationIsBeing =>
      'Принимается другое приглашение в сейф. Повторите попытку позже.';

  @override
  String get confirmingTheInputControlRevocationTry =>
      'Подтверждается отзыв управления вводом. Повторите попытку чуть позже.';

  @override
  String get connectingHostApprovedInputControl =>
      'Подключение управления вводом, одобренного хостом.';

  @override
  String get thisHostChangedAfterThePreview =>
      'Хост изменился после предпросмотра. Синхронизируйте заново и проверьте различия.';

  @override
  String get thisHostNoLongerExistsOr =>
      'Хост больше не существует или не читается однозначно; синхронизируйте заново перед правкой.';

  @override
  String get thisHostsLocalEncryptedRecordCouldnt =>
      'Не удалось проверить локальную зашифрованную запись хоста; сохранение остановлено, чтобы не перезаписать и не потерять данные.';

  @override
  String get thisHostIsMissingAVerifiable =>
      'У хоста нет проверяемой локальной версии; сохранение остановлено, чтобы не нарушить историю синхронизации.';

  @override
  String thisSshCredentialIsStillReferenced(
    int groupCount,
    int hostCount,
    int snippetParameterCount,
  ) {
    return 'На эти учётные данные SSH всё ещё ссылаются: значения по умолчанию групп — $groupCount, переопределения хостов — $hostCount, секретные параметры сниппетов — $snippetParameterCount. Сначала замените или удалите эти ссылки.';
  }

  @override
  String get thisSshCredentialNoLongerExists =>
      'Эти учётные данные SSH больше не существуют или не проходят проверку; сначала заново синхронизируйте сейф.';

  @override
  String get theTerminalFontSizePreferenceIn =>
      'У настройки размера шрифта терминала в этом сейфе есть дубликаты или неподтверждённое исправление. Выполните явное исправление.';

  @override
  String get theTerminalShortcutPreferenceInThis =>
      'У настройки сочетаний клавиш терминала в этом сейфе есть дубликаты или неподтверждённое исправление. Выполните явное исправление.';

  @override
  String get theTerminalColorPreferenceInThis =>
      'У настройки цветов терминала в этом сейфе есть дубликаты или неподтверждённое исправление. Выполните явное исправление.';

  @override
  String get theDefaultWorkspacePreferenceInThis =>
      'У настройки рабочего пространства по умолчанию в этом сейфе есть дубликаты или неподтверждённое исправление. Выполните явное исправление.';

  @override
  String get thisVaultContainsUnsupportedPreferenceRecords =>
      'В сейфе есть неподдерживаемые записи настроек; исправление приостановлено.';

  @override
  String get thisVaultContainsPreferencesThatThis =>
      'В этом сейфе есть настройки, которые не поддерживаются этим клиентом.';

  @override
  String get thisVaultCantBeUsedTo =>
      'Этот сейф сейчас нельзя использовать для создания общего терминала.';

  @override
  String get thisVaultIsntCurrentlyInAn =>
      'Сейф сейчас не находится в активном состоянии, допускающем удаление.';

  @override
  String get thisVaultIsCurrentlyReadOnly =>
      'Сейф сейчас доступен только для чтения; изменять участников нельзя.';

  @override
  String get thisVaultHasNoDeletionSchedule =>
      'У этого сейфа нет запланированного удаления, которое можно отменить.';

  @override
  String get thisVaultIsInItsDeletion =>
      'Сейф находится в льготном периоде удаления и сейчас доступен только для чтения.';

  @override
  String get thisVaultIsInItsDeletion2 =>
      'Сейф в льготном периоде удаления и доступен только для чтения; владелец может отменить удаление до срока.';

  @override
  String thisHostIsStillUsedAs(int dependants) {
    String _temp0 = intl.Intl.pluralLogic(
      dependants,
      locale: localeName,
      other:
          'Этот хост всё ещё используется как промежуточный $dependants хоста',
      many:
          'Этот хост всё ещё используется как промежуточный $dependants хостами',
      few:
          'Этот хост всё ещё используется как промежуточный $dependants хостами',
      one:
          'Этот хост всё ещё используется как промежуточный $dependants хостом',
    );
    return '$_temp0; сначала замените или удалите эти ссылки.';
  }

  @override
  String get thisSessionWasSignedOutIn =>
      'В этом сеансе выполнен выход на другой вкладке. Войдите снова.';

  @override
  String get thisSessionsRefreshTokenStateCant =>
      'Состояние токена обновления этого сеанса нельзя безопасно восстановить. Войдите снова.';

  @override
  String get thisSharedSessionDoesntHaveHost =>
      'В этом общем сеансе управление вводом с одобрения хоста не включено.';

  @override
  String thisGroupIsStillReferencedBy(int hostCount, int childCount) {
    return 'На эту группу всё ещё ссылаются хосты ($hostCount) и подгруппы ($childCount); сначала переместите эти записи.';
  }

  @override
  String get thisGroupNoLongerExistsOr =>
      'Эта группа больше не существует или не может быть проверена; сначала заново синхронизируйте сейф.';

  @override
  String thisDeletedRecordIsPastThe(String dateText) {
    return 'Срок восстановления этой удалённой записи на сервере истёк$dateText. Метка удаления продолжает занимать этот ID; чтобы продолжить, создайте новую запись с новым ID.';
  }

  @override
  String get thisInstanceIsntInitializedYetCreate =>
      'Экземпляр ещё не инициализирован. Создайте первую учётную запись с одноразовым токеном начальной настройки, выданным администратором.';

  @override
  String get thisWorkspaceHostNoLongerExists =>
      'Хоста этого рабочего пространства больше нет в текущем сейфе. Сначала исправьте ссылку.';

  @override
  String get thisWorkspacePaneAlreadyHasA =>
      'У этой панели рабочего пространства уже есть ссылка на сеанс tmux; используйте «Возобновить».';

  @override
  String get thisWorkspacePaneIsAlreadyAttached =>
      'Эта панель рабочего пространства уже подключена к tmux.';

  @override
  String get thisWorkspacePaneIsRunningA =>
      'Эта панель рабочего пространства выполняет действие tmux.';

  @override
  String get thisWorkspacePaneHasNoSaved =>
      'У этой панели рабочего пространства нет сохранённой ссылки на сеанс tmux.';

  @override
  String get mobilePushIsntSupportedOnThis =>
      'Мобильные push-уведомления не поддерживаются на этой платформе.';

  @override
  String get thisAppBuildDoesntHaveFirebase =>
      'В этой сборке приложения не настроен Firebase Cloud Messaging.';

  @override
  String get thisMembersAccessWasRevokedTo =>
      'Доступ этого участника отозван; чтобы снова предоставить его, создайте новое приглашение.';

  @override
  String get thisBrowserCantSafelyCoordinateSession =>
      'Этот браузер не может безопасно согласовать обновление сеанса между вкладками, поэтому токен обновления не сменён. Обновите браузер для безопасной синхронизации сеансов.';

  @override
  String get thisBrowserHasNoDeviceKey =>
      'В этом браузере нет ключа устройства, ожидающего одобрения. Сначала создайте запрос устройства.';

  @override
  String get youLeftThisTerminalShareEnter =>
      'Вы покинули этот общий терминал. Введите UUID сеанса снова.';

  @override
  String get thisTerminalIsAlreadyBeingShared =>
      'Этот терминал уже используется совместно.';

  @override
  String get thisRecordIdIsReservedBy =>
      'Этот ID записи занят меткой удаления и не может быть создан заново. Восстановите запись из корзины или создайте новую с другим ID.';

  @override
  String get thisRecordWasUpdatedOnAnother =>
      'Запись обновлена на другом устройстве; ветка конфликта сохранена.';

  @override
  String get thisRecordHasNoHistoricalVersion =>
      'У этой записи нет предыдущих версий для восстановления.';

  @override
  String get thisRecordsHostIdentityCantBe =>
      'Идентичность хоста этой записи нельзя проверить; сохранение остановлено, чтобы не перезаписать другие данные.';

  @override
  String get backgroundSyncNotificationsAreTurnedOff =>
      'Уведомления фоновой синхронизации на этом устройстве отключены.';

  @override
  String get backgroundSyncNotificationsAreOnFor =>
      'Уведомления фоновой синхронизации на этом устройстве включены.';

  @override
  String get thisDeviceWasRevokedSignIn =>
      'Это устройство отозвано. Войдите снова на устройстве, одобренном администратором.';

  @override
  String get thisAccountIsntAMemberOf =>
      'Эта учётная запись не является участником текущего сейфа.';

  @override
  String get thisAccountNameDoesntMatchThe =>
      'Это имя учётной записи не совпадает с текущей.';

  @override
  String get thisChangeCantBeMadeIn =>
      'В текущем состоянии учётной записи это изменение невозможно.';

  @override
  String get theresNoMasterPasswordChangeWaiting =>
      'Нет смены мастер-пароля, ожидающей подтверждения.';

  @override
  String get theresNoServerIdentityRecoveryWaiting =>
      'Нет восстановления идентичности сервера, ожидающего подтверждения.';

  @override
  String get theresNoActivePrometheusScrapeCredential =>
      'Нет активных учётных данных Prometheus для сбора метрик.';

  @override
  String get theParentGroupNoLongerExists2 =>
      'Родительская группа больше не существует. Выберите другого родителя или верхний уровень.';

  @override
  String get invalidParentGroupChooseAValid =>
      'Недопустимая родительская группа. Выберите допустимую группу или верхний уровень.';

  @override
  String thePasswordCredentialReferencedBySnippet(String name) {
    return 'Парольные учётные данные, на которые ссылается параметр сниппета «$name», не существуют или недоступны; сохранение остановлено.';
  }

  @override
  String get theSnippetCommandCantBeEmpty =>
      'Команда сниппета не может быть пустой';

  @override
  String get theSnippetTitleCantBeEmpty =>
      'Название сниппета не может быть пустым';

  @override
  String get userName => 'Имя пользователя';

  @override
  String get theSignInSessionWasRestored =>
      'Сеанс входа восстановлен. Введите мастер-пароль, чтобы разблокировать зашифрованное рабочее пространство.';

  @override
  String get theSignInSessionDeviceId =>
      'ID устройства сеанса входа не соответствует идентичности локального устройства.';

  @override
  String get theSignInResponseDoesntMatch =>
      'Ответ входа не соответствует текущей учётной записи или устройству.';

  @override
  String get theSignInStateChangedTry =>
      'Состояние входа изменилось. Повторите попытку.';

  @override
  String get theSignInStateExpiredSign =>
      'Срок действия входа истёк. Войдите снова.';

  @override
  String get theSignedInAccountChangedSign =>
      'Учётная запись входа изменилась; выйдите и войдите снова с новым мастер-паролем.';

  @override
  String get invalidFolderNameFormat => 'Недопустимый формат имени папки';

  @override
  String get theDestinationVaultsCurrentServerState =>
      'Текущее состояние сейфа назначения на сервере ещё не проверено; продолжите миграцию после восстановления снимка.';

  @override
  String get theTargetHostsSshCredentialChanged =>
      'Учётные данные SSH целевого хоста изменились во время подготовки подключения. Переподключитесь.';

  @override
  String get theTargetMemberHasNoActive =>
      'У целевого участника нет активного устройства, способного получить новый ключ сейфа; передача владения отменена.';

  @override
  String get theTargetAccountIsNoLonger =>
      'Целевой учётной записи больше нет в текущем списке. Обновите и повторите попытку.';

  @override
  String get thePrivateKeyCantBeEmpty => 'Закрытый ключ не может быть пустым';

  @override
  String get theWindowSetHasASync =>
      'У набора окон есть конфликт синхронизации. Сначала решите его.';

  @override
  String get theWindowSetIsBeingSaved =>
      'Набор окон сохраняется. Повторите попытку чуть позже.';

  @override
  String get port2 => 'Порт';

  @override
  String get theSignedMembershipEntryHasAn =>
      'Недопустимый формат подписанной записи членства.';

  @override
  String get theSignedMembershipListDoesntMatch =>
      'Подписанный список участников не совпадает с состоянием ACL на сервере; обновите и повторите попытку.';

  @override
  String get theSignedMembershipListDoesntMatch2 =>
      'Подписанный список участников не совпадает с каталогом участников на сервере.';

  @override
  String get theSignedMembershipListContainsInvalid =>
      'Подписанный список участников содержит недопустимых или повторяющихся участников.';

  @override
  String get theSignedMembershipListIsMissing =>
      'В подписанном списке участников отсутствуют существующие участники на сервере.';

  @override
  String get theAdminAuditCursorExpiredThe =>
      'Курсор аудита администратора истёк. Возможно, изменилось поколение экземпляра или сервера; загрузите заново с первой страницы.';

  @override
  String get theAdminAuditCursorIsInvalid =>
      'Курсор аудита администратора недействителен или не относится к текущему администратору или экземпляру. Загрузите заново с первой страницы.';

  @override
  String get theTerminalVaultOrSignedIn =>
      'Терминал, сейф или устройство входа изменились; общий доступ отменён.';

  @override
  String get terminalSharingStoppedBecauseAnObservers =>
      'Общий доступ к терминалу остановлен из-за слишком медленного подключения наблюдателя; SSH-соединение можно использовать дальше.';

  @override
  String get terminalSharingHasntDisconnectedYet =>
      'Общий доступ к терминалу ещё не отключён.';

  @override
  String get terminalSharingDisconnectedTheSshConnection =>
      'Общий доступ к терминалу отключён. SSH-соединение можно использовать дальше.';

  @override
  String get terminalSharingDisconnectedTheSshConnection2 =>
      'Общий доступ к терминалу отключён; SSH-соединение можно использовать дальше.';

  @override
  String get theTerminalSharingConnectionWasDisconnected =>
      'Соединение общего терминала разорвано.';

  @override
  String get terminalFontSize => 'Размер шрифта терминала';

  @override
  String get terminalFontSizePreferenceSavedEncrypted =>
      'Настройка размера шрифта терминала сохранена в зашифрованном виде и синхронизируется на другие устройства через текущий сейф.';

  @override
  String get theTerminalFontSizePreferenceNeeds =>
      'Настройку размера шрифта терминала сначала нужно явно исправить.';

  @override
  String get aHostReferencedByTheTerminal =>
      'Хоста, на который ссылается терминал, больше нет в текущем сейфе; откройте хост заново перед сохранением макета.';

  @override
  String get terminalShortcuts => 'Сочетания клавиш терминала';

  @override
  String get terminalShortcutPreferenceSavedEncryptedIt =>
      'Настройка сочетаний клавиш терминала сохранена в зашифрованном виде и синхронизируется на другие устройства через текущий сейф.';

  @override
  String get theTerminalShortcutPreferenceNeedsAn =>
      'Настройку сочетаний клавиш терминала сначала нужно явно исправить.';

  @override
  String get theTerminalControlChannelDisconnectedThe =>
      'Канал управления терминалом отключён; SSH-соединение можно использовать дальше.';

  @override
  String get terminalColors => 'Цвета терминала';

  @override
  String get terminalColorPreferenceSavedEncryptedIt =>
      'Настройка цветов терминала сохранена в зашифрованном виде и синхронизируется на другие устройства через текущий сейф.';

  @override
  String get theTerminalColorPreferenceNeedsAn =>
      'Настройку цветов терминала сначала нужно явно исправить.';

  @override
  String get maintenanceJobSubmittedRefreshTheJob =>
      'Задание обслуживания отправлено. Обновите список заданий, чтобы увидеть состояние.';

  @override
  String get automaticStatusChecksArePausedYou =>
      'Автоматическая проверка состояния приостановлена. Состояние задания можно обновить вручную.';

  @override
  String get scheduledBackupsTurnedOff =>
      'Плановое резервное копирование отключено.';

  @override
  String get scheduledBackupSettingsSaved =>
      'Настройки планового резервного копирования сохранены.';

  @override
  String get authenticationMethod => 'Способ аутентификации';

  @override
  String get theRecordWasClearedFromThis =>
      'Запись удалена из активного кэша устройства, получено подписанное подтверждение сервера; догнать курсор синхронизации не удалось. Повторная синхронизация сначала получит метку очистки, затем обработает ожидающие данные.';

  @override
  String thePublicKeysForDeviceDeviceid(String deviceId) {
    return 'Открытые ключи устройства $deviceId в каталоге учётной записи и каталоге сейфа не совпадают.';
  }

  @override
  String theEncryptionPublicKeyOfDevice(String deviceId) {
    return 'Недопустимая длина открытого ключа шифрования устройства $deviceId.';
  }

  @override
  String theKeyEnvelopeTargetForDevice(String deviceId) {
    return 'Получатель конверта ключа для устройства $deviceId недопустим или повторяется.';
  }

  @override
  String theSigningPublicKeyOfDevice(String deviceId) {
    return 'Недопустимая длина открытого ключа подписи устройства $deviceId.';
  }

  @override
  String get deviceRevoked2 => 'Устройство отозвано.';

  @override
  String get deviceAddedGiveTheApprovalResult =>
      'Устройство добавлено. Передайте результат одобрения на новое устройство и импортируйте его там.';

  @override
  String get theVaultKeyEnvelopeInThe =>
      'Недопустимый формат конверта ключа сейфа в одобрении устройства.';

  @override
  String get theKeyEnvelopeContextInThe =>
      'Контекст конверта ключа в одобрении устройства недействителен.';

  @override
  String get theDeviceApprovalContainsDuplicateVault =>
      'Одобрение устройства содержит повторяющиеся конверты ключей сейфа.';

  @override
  String get theDeviceApprovalFileHasAn =>
      'Недопустимый формат файла одобрения устройства.';

  @override
  String get theDeviceApprovalFilesAccountOr =>
      'Учётная запись или структура файла одобрения устройства недействительны.';

  @override
  String get theDeviceApprovalCertificateFieldsAre =>
      'Отсутствуют поля сертификата одобрения устройства.';

  @override
  String get theDeviceRequestIsMalformedOr =>
      'Запрос устройства повреждён или относится к другой учётной записи.';

  @override
  String get thisAccountIsAlreadyAnActive =>
      'Эта учётная запись уже является активным участником сейфа; используйте одобрение через авторизованное устройство.';

  @override
  String get thisInvitationIsNoLongerWaiting =>
      'Это приглашение больше не ожидает принятия. Обновите и повторите попытку.';

  @override
  String get closeASessionTabFirst => 'Сначала закройте одну вкладку сеанса.';

  @override
  String get joinTheHostsTerminalShareFirst =>
      'Сначала присоединитесь к общему терминалу хоста.';

  @override
  String get openThisAccountsSessionListFirst =>
      'Сначала откройте список сеансов этой учётной записи.';

  @override
  String get openAtLeastOneTerminalTab =>
      'Сначала откройте хотя бы одну вкладку терминала.';

  @override
  String get signInAndUnlockTheAccount =>
      'Сначала войдите и разблокируйте учётную запись на доверенном устройстве.';

  @override
  String get signInFirst => 'Сначала войдите.';

  @override
  String get signInBeforeChangingMfaSettings =>
      'Войдите, прежде чем менять настройки MFA.';

  @override
  String get signInBeforeViewingMfaSettings =>
      'Войдите, прежде чем просматривать настройки MFA.';

  @override
  String get signInBeforeManagingThisDevices =>
      'Войдите, чтобы управлять уведомлениями фоновой синхронизации на этом устройстве.';

  @override
  String get signInAndUnlockTheSync =>
      'Сначала войдите и разблокируйте учётную запись синхронизации.';

  @override
  String get signInAndUnlockTheTarget =>
      'Сначала войдите и разблокируйте целевой сейф.';

  @override
  String get signInAndUnlockTheAccount2 =>
      'Сначала войдите и разблокируйте учётную запись.';

  @override
  String get signInToThisAccountAnd =>
      'Сначала войдите в эту учётную запись и разблокируйте текущее устройство.';

  @override
  String get resolveThePreferenceReadErrorFirst =>
      'Сначала устраните ошибку чтения настроек.';

  @override
  String get unlockTheVaultFirst => 'Сначала разблокируйте сейф';

  @override
  String get unlockTheVaultFirst2 => 'Сначала разблокируйте сейф.';

  @override
  String get unlockAVaultBeforeSharingA =>
      'Разблокируйте сейф, прежде чем делиться терминалом.';

  @override
  String get unlockTheWorkspaceFirst =>
      'Сначала разблокируйте рабочее пространство.';

  @override
  String get unlockTheCurrentVaultBeforeVerifying =>
      'Разблокируйте текущий сейф, прежде чем проверять ключи SSH-хостов.';

  @override
  String get unlockTheWorkspaceThatContainsThe =>
      'Сначала разблокируйте рабочее пространство с текущим хостом.';

  @override
  String get unlockTheVaultThatOwnsThis =>
      'Сначала разблокируйте сейф, которому принадлежит этот общий сеанс.';

  @override
  String get unlockTheAccountBeforeExportingA =>
      'Разблокируйте учётную запись перед экспортом запроса на доступ.';

  @override
  String get connectToAnSshHostFirst => 'Сначала подключитесь к SSH-хосту';

  @override
  String get connectSshBeforeStartingTerminalSharing =>
      'Подключитесь по SSH, прежде чем начинать общий доступ к терминалу.';

  @override
  String get connectToTheServerFirst => 'Сначала подключитесь к серверу.';

  @override
  String get connectTheHostForThisWorkspace =>
      'Сначала подключите хост этой панели рабочего пространства.';

  @override
  String get chooseAVaultFirst => 'Сначала выберите сейф.';

  @override
  String get chooseAndUnlockAVaultFirst =>
      'Сначала выберите и разблокируйте сейф.';

  @override
  String get configureTheServerAddressFirst => 'Сначала укажите адрес сервера';

  @override
  String get retryThePendingMasterPasswordChange =>
      'Повторите ожидающую смену мастер-пароля, прежде чем удалять учётную запись.';

  @override
  String get tooManyRequestsTryAgainLater =>
      'Слишком много запросов. Повторите попытку позже.';

  @override
  String get waitForTheCurrentSyncOr =>
      'Дождитесь завершения текущей синхронизации или операции с архивом.';

  @override
  String get enterAVaultName => 'Введите имя сейфа';

  @override
  String get enterTheBootstrapToken => 'Введите токен начальной настройки';

  @override
  String get enterAGroupName => 'Введите имя группы.';

  @override
  String get enterTheCurrentMasterPassword => 'Введите текущий мастер-пароль.';

  @override
  String get enterTheCurrentAccountNameAnd =>
      'Введите имя текущей учётной записи и мастер-пароль для повторной проверки.';

  @override
  String get enterANameForTheNew => 'Введите имя нового сейфа.';

  @override
  String get enterAValidTerminalSharingSession =>
      'Введите действительный UUID сеанса общего терминала.';

  @override
  String get enterAValidAccountNameAnd =>
      'Введите допустимое имя учётной записи и срок от 1 до 30 дней.';

  @override
  String get enterTheServerAddress => 'Введите адрес сервера';

  @override
  String get enterAnMfaCodeValidFor =>
      'Введите действительный для этой учётной записи код MFA.';

  @override
  String get enterTheAccountInvitationTokenIssued =>
      'Введите токен приглашения, выданный администратором';

  @override
  String get enterTheAccountNameAndMaster =>
      'Введите имя учётной записи и мастер-пароль.';

  @override
  String get enterTheAccountPassword => 'Введите пароль учётной записи.';

  @override
  String get enterTheAccountEmailUserName =>
      'Введите электронную почту или имя пользователя учётной записи';

  @override
  String get enterTheInvitationToken => 'Введите токен приглашения.';

  @override
  String get choose1To8ActiveVault =>
      'Выберите от 1 до 8 активных устройств сейфа.';

  @override
  String chooseALabelPreferenceFromThe(String label) {
    return 'Выберите настройку «$label» из текущего списка конфликтов.';
  }

  @override
  String get theAccountIsStillTheOwner =>
      'Учётная запись по-прежнему владеет общим сейфом с другими участниками. Сервер не передаёт владение и не удаляет данные других учётных записей автоматически; удалите других участников и повторите попытку.';

  @override
  String get theAccountSessionChangedSignIn =>
      'Сеанс учётной записи изменился. Войдите снова, затем разблокируйте.';

  @override
  String get theAccountDeletionGracePeriodHas =>
      'Льготный период удаления учётной записи истёк; отменить нельзя.';

  @override
  String theAccountDeletionWasCancelledThe(String valueValue) {
    return 'Удаление учётной записи отменено. Сервер не восстанавливает старые сеансы; введите пароль, чтобы войти снова.$valueValue';
  }

  @override
  String get theAccountResponseDoesntMatchThe =>
      'Ответ учётной записи не соответствует текущему сеансу.';

  @override
  String get accountSecuritySettingsAreBeingProcessed =>
      'Настройки безопасности учётной записи обрабатываются. Повторите попытку позже.';

  @override
  String get invalidAccountKeyLength =>
      'Недопустимая длина ключа учётной записи.';

  @override
  String get invalidAccountKeyLengthTheMaster =>
      'Недопустимая длина ключа учётной записи; смена мастер-пароля остановлена.';

  @override
  String get theAccountAlreadyHasAPending =>
      'Для учётной записи уже запланировано удаление; отмените его через восстановление учётной записи на странице входа.';

  @override
  String theAccountEnteredItsDeletionGrace(
    String deadline,
    String valueValue,
    String valueValue2,
  ) {
    return 'Учётная запись перешла в льготный период удаления. purge_after на сервере: $deadline. Текущий сеанс и ключ разблокировки устройства удалены; в льготный период удаление можно отменить на странице входа, после чего нужно войти снова.$valueValue$valueValue2';
  }

  @override
  String get accountRecoverySettingsAreBeingProcessed =>
      'Настройки восстановления учётной записи обрабатываются.';

  @override
  String get theAccountStateJustChangedSign =>
      'Состояние учётной записи только что изменилось. Войдите снова, чтобы просмотреть его.';

  @override
  String get anAccountStateActionIsIn =>
      'Выполняется действие с состоянием учётной записи. Повторите попытку позже.';

  @override
  String get theInputControlAuthorizationOrVault =>
      'Разрешение на управление вводом или состояние сейфа изменилось; присоединение отменено.';

  @override
  String get theInputControlConnectionWasDisconnected =>
      'Соединение управления вводом разорвано.';

  @override
  String get theFingerprintYouEnteredDoesntMatch =>
      'Введённый отпечаток не совпадает с предлагаемым ключом подписи экземпляра.';

  @override
  String get invalidMigrationDestinationVaultId =>
      'Недопустимый ID сейфа назначения миграции.';

  @override
  String get theMigrationDestinationVaultCouldntBe =>
      'Не удалось проверить, что сейф назначения миграции — доступный для записи сейф владельца на этом устройстве.';

  @override
  String get theMigrationDestinationVaultCouldntBe2 =>
      'Не удалось открыть сейф назначения миграции; локальный журнал миграции можно возобновить.';

  @override
  String get theMigrationDestinationVaultIsMissing =>
      'У сейфа назначения миграции нет начальной подписанной цепочки членства.';

  @override
  String get invalidMigrationRecordId => 'Недопустимый ID записи миграции.';

  @override
  String get theRestoreJobFinishedButThe =>
      'Задание восстановления завершено, но состояние изолированной копии не проверено, и управлять ею отсюда нельзя.';

  @override
  String get remoteDesktopRequiresASignIn =>
      'Для удалённого рабочего стола нужен шлюз входа.';

  @override
  String get invalidRemoteFileNameFormat =>
      'Недопустимый формат имени удалённого файла';

  @override
  String get invalidRemoteFilePathFormat =>
      'Недопустимый формат пути к удалённому файлу';

  @override
  String get notificationPermissionWasntGrantedBackgroundSync =>
      'Разрешение на уведомления не предоставлено; уведомления фоновой синхронизации не зарегистрированы.';

  @override
  String get invitationCreatedGiveTheOneTime =>
      'Приглашение создано. Передайте одноразовый токен целевой учётной записи по доверенному каналу.';

  @override
  String get theInvitationWasAcceptedButThis =>
      'Приглашение принято, но устройство не смогло переключиться на этот сейф. Выберите сейф снова и выполните синхронизацию.';

  @override
  String get theInvitationWasAcceptedButThis2 =>
      'Приглашение принято, но это устройство не получило конверт ключа сейфа, который может расшифровать. Попросите пригласившего проверить открытый ключ устройства.';

  @override
  String get theInvitationRoleCanOnlyBe =>
      'Роль в приглашении может быть только editor или viewer.';

  @override
  String get someLocalRecordsCouldntBeVerified3 =>
      'Некоторые локальные записи не прошли проверку, поэтому ссылки хоста на группу, учётные данные или промежуточный хост нельзя безопасно проверить. Сначала исправьте или заново синхронизируйте сейф.';

  @override
  String get someLocalRecordsCouldntBeVerified4 =>
      'Некоторые локальные записи не прошли проверку, поэтому ссылки на учётные данные нельзя безопасно проверить. Сначала исправьте или заново синхронизируйте сейф.';

  @override
  String get someLocalRecordsCouldntBeVerified =>
      'Некоторые локальные записи не прошли проверку, поэтому ссылки на группы нельзя безопасно проверить. Сначала исправьте или заново синхронизируйте сейф.';

  @override
  String get someLocalRecordsCouldntBeVerified2 =>
      'Некоторые локальные записи не прошли проверку, поэтому ссылки сниппета на учётные данные SSH нельзя безопасно проверить. Сначала исправьте или заново синхронизируйте сейф.';

  @override
  String get theQuotaMustBeBetween1 => 'Квота должна быть от 1 байта до 1 ТиБ.';

  @override
  String get theReVerifiedAccountMustMatch =>
      'Повторно проверяемая учётная запись должна совпадать с текущей.';

  @override
  String get theIsolatedCopyIsntVerifiedYet =>
      'Изолированная копия ещё не проверена. Сервер проверяет принадлежность и целостность перед очисткой.';

  @override
  String get theIsolatedCopyWasDiscardedYou =>
      'Изолированная копия удалена. Её можно подготовить заново из исходного архива.';

  @override
  String get isolatedCopyCleanupHasntFinishedYou =>
      'Очистка изолированной копии не завершена. Её можно безопасно повторить.';

  @override
  String get isolatedCopyCleanupDidntFinishYou =>
      'Очистка изолированной копии не завершена; её можно безопасно повторить.';

  @override
  String get theIsolatedRestoreCopyPreparationJob3 =>
      'Задание подготовки изолированной копии для восстановления прервано. Рабочие данные не изменены.';

  @override
  String get theIsolatedRestoreCopyPreparationJob =>
      'Задание подготовки изолированной копии для восстановления принято. Оно не активирует копию и не заменяет рабочие данные.';

  @override
  String get theIsolatedRestoreCopyPreparationJob2 =>
      'Задание подготовки изолированной копии для восстановления завершено. Рабочие данные не изменены.';

  @override
  String get theIsolatedRestoreCopyWasDiscarded =>
      'Изолированная копия для восстановления удалена. Исходный архив и рабочие данные не изменены.';

  @override
  String get theIsolatedRestoreCopyIsReady =>
      'Изолированная копия для восстановления готова. Рабочие данные не изменены.';

  @override
  String get theIsolatedRestoreCopyIsReady2 =>
      'Изолированная копия для восстановления готова, но обновление состояния задания прервалось. Рабочие данные не изменены.';

  @override
  String get theIsolatedRestoreCopyIsInvalid =>
      'Изолированная копия для восстановления недействительна. Обновите список заданий и повторите попытку.';

  @override
  String get theIsolatedRestoreCopyFailedVerification =>
      'Изолированная копия для восстановления не прошла проверку; сервер не удалял неизвестных файлов. Обратитесь к оператору экземпляра.';

  @override
  String get theIsolatedRestoreCopyStateChanged =>
      'Состояние изолированной копии для восстановления изменилось. Обновите список заданий и повторите попытку.';

  @override
  String get theDefaultSshCredentialNoLonger =>
      'Учётные данные SSH по умолчанию больше не существуют. Выберите действительные или очистите значение по умолчанию.';

  @override
  String get defaultWorkspace => 'Рабочее пространство по умолчанию';

  @override
  String get defaultWorkspacePreferenceSavedEncryptedIt =>
      'Настройка рабочего пространства по умолчанию сохранена в зашифрованном виде и синхронизируется на другие устройства через текущий сейф.';

  @override
  String get theDefaultWorkspacePreferenceNeedsAn =>
      'Настройку рабочего пространства по умолчанию сначала нужно явно исправить.';

  @override
  String restoreDeadlineFormat(String format) {
    return '(срок восстановления: $format)';
  }

  @override
  String get unsupportedArgon2idParameters =>
      'Неподдерживаемые параметры Argon2id.';

  @override
  String get notASupportedAtermiusEncryptedArchive =>
      'Это не поддерживаемый зашифрованный архив Atermius.';

  @override
  String get anEncryptedArchiveChunkIsTruncated =>
      'Блок зашифрованного архива обрезан.';

  @override
  String get theEncryptedArchiveExceedsTheFile =>
      'Зашифрованный архив превышает лимит размера файла.';

  @override
  String get anArchiveObjectIsEmptyOr =>
      'Объект архива пуст или превышает лимит 32 МиБ.';

  @override
  String get invalidArchiveArgon2idSaltLength =>
      'Недопустимая длина соли Argon2id в архиве.';

  @override
  String get theArchiveContentExceedsTheSize =>
      'Содержимое архива превышает обрабатываемый размер.';

  @override
  String get theArchiveChunkLengthDoesntMatch =>
      'Длина блока архива не совпадает.';

  @override
  String get theArchiveHeaderIsntCanonicalJson =>
      'Заголовок архива не является каноническим JSON.';

  @override
  String get theArchiveHeaderHasUnknownOr =>
      'В заголовке архива неизвестные или неполные поля.';

  @override
  String get theArchiveHeaderExceedsTheSize =>
      'Заголовок архива превышает допустимый размер.';

  @override
  String get invalidArchiveHeaderLength =>
      'Недопустимая длина заголовка архива.';

  @override
  String get wrongArchivePasswordOrTheArchive =>
      'Неверный пароль архива или содержимое архива не прошло проверку целостности.';

  @override
  String get theTotalArchiveObjectDataExceeds =>
      'Общий объём данных объектов архива превышает лимит.';

  @override
  String get theNumberOfArchiveObjectsExceeds =>
      'Количество объектов архива превышает лимит.';

  @override
  String get theArchiveHasTrailingDataOr =>
      'В архиве лишние данные в конце или неполное содержимое.';

  @override
  String get theArchiveFileSizeIsInvalid =>
      'Размер файла архива недопустим или превышает лимит.';

  @override
  String get theArchiveFileIsTruncated => 'Файл архива обрезан.';

  @override
  String get invalidArchivePlaintextSize =>
      'Недопустимый размер открытого текста архива.';

  @override
  String get invalidArchivePlaintextType =>
      'Недопустимый тип открытого текста архива.';

  @override
  String get theArchivePlaintextExceedsTheFile =>
      'Открытый текст архива превышает лимит размера файла.';

  @override
  String get theArchiveManifestIsntCanonicalJson =>
      'Манифест архива не является каноническим JSON.';

  @override
  String get theArchiveManifestExceedsThe16 =>
      'Манифест архива превышает лимит 16 МиБ.';

  @override
  String get invalidArchiveManifestLength =>
      'Недопустимая длина манифеста архива.';

  @override
  String get theArchiveVersionServerSpaceOr =>
      'Версия архива, пространство сервера или сейф не совпадают с текущей целью. Импорт между пространствами и сейфами пока не поддерживается.';

  @override
  String get theArchiveLengthOrChunkParameters =>
      'Длина архива или параметры блоков превышают лимиты ресурсов.';

  @override
  String get theSeparateArchivePasswordMustBe =>
      'Отдельный пароль архива должен занимать не менее 12 байт UTF-8.';

  @override
  String get invalidDecryptedArchiveChunkLength =>
      'Недопустимая длина расшифрованного блока архива.';

  @override
  String get notASupportedLocalEncryptedArchive =>
      'Это не поддерживаемый локальный зашифрованный архив.';

  @override
  String get aLocalEncryptedArchiveChunkIs =>
      'Блок локального зашифрованного архива обрезан.';

  @override
  String get theLocalEncryptedArchiveExceedsThe =>
      'Локальный зашифрованный архив превышает лимит размера файла.';

  @override
  String get unsupportedLocalArchiveArgon2idParameters =>
      'Неподдерживаемые параметры Argon2id локального архива.';

  @override
  String get invalidSshTrustRecordMetadataIn =>
      'Недопустимые метаданные записи доверия SSH в локальном архиве.';

  @override
  String get invalidOrderOrUniquenessOfSsh =>
      'Недопустимый порядок или уникальность записей доверия SSH в локальном архиве.';

  @override
  String get theNumberOfSshTrustRecords =>
      'Количество записей доверия SSH в локальном архиве превышает лимит.';

  @override
  String get invalidSshTrustRecordInThe =>
      'Недопустимая запись доверия SSH в локальном архиве.';

  @override
  String get invalidBase64urlEncodingInTheLocal =>
      'Недопустимая кодировка base64url в локальном архиве.';

  @override
  String get invalidLocalArchiveSaltLength =>
      'Недопустимая длина соли локального архива.';

  @override
  String get theLocalArchiveContentIsntCanonical =>
      'Содержимое локального архива не является каноническим JSON.';

  @override
  String get theLocalArchiveContentIsEmpty =>
      'Содержимое локального архива пусто или превышает допустимый размер.';

  @override
  String get unsupportedLocalArchiveContentFormatOr =>
      'Неподдерживаемый формат или версия содержимого локального архива.';

  @override
  String get theLocalArchiveChunkLengthDoesnt =>
      'Длина блока локального архива не совпадает.';

  @override
  String get theLocalArchivePassphraseMustBe =>
      'Парольная фраза локального архива должна занимать от 12 до 1024 байт UTF-8.';

  @override
  String get theLocalArchiveContainsDuplicateRecord =>
      'Локальный архив содержит повторяющиеся ID записей.';

  @override
  String get theLocalArchiveSizeIsInvalid =>
      'Размер локального архива недопустим или превышает лимит.';

  @override
  String get theLocalArchiveHeaderIsntCanonical =>
      'Заголовок локального архива не является каноническим JSON.';

  @override
  String get theLocalArchiveHeaderHasUnknown =>
      'В заголовке локального архива неизвестные или неполные поля.';

  @override
  String get theLocalArchiveHeaderExceedsThe =>
      'Заголовок локального архива превышает допустимый размер.';

  @override
  String get invalidLocalArchiveHeaderLength =>
      'Недопустимая длина заголовка локального архива.';

  @override
  String get wrongLocalArchivePasswordOrThe =>
      'Неверный пароль локального архива или архив не прошёл проверку целостности.';

  @override
  String get theLocalArchiveHasTrailingData =>
      'В локальном архиве лишние данные в конце или неполное содержимое.';

  @override
  String get theLocalArchiveFileIsTruncated =>
      'Файл локального архива обрезан.';

  @override
  String get theLocalArchivePlaintextIsEmpty =>
      'Открытый текст локального архива пуст или превышает лимит.';

  @override
  String get theLocalArchivePlaintextExceedsThe =>
      'Открытый текст локального архива превышает допустимый размер.';

  @override
  String get unsupportedLocalArchiveFormatOrVersion =>
      'Неподдерживаемый формат или версия локального архива.';

  @override
  String get invalidDecryptedChunkLengthInThe =>
      'Недопустимая длина расшифрованного блока локального архива.';

  @override
  String get theLocalArchiveRecordListExceeds =>
      'Список записей локального архива превышает лимит.';

  @override
  String get invalidRecordOrderOrUniquenessIn =>
      'Недопустимый порядок или уникальность записей в локальном архиве.';

  @override
  String get theNumberOfRecordsInThe =>
      'Количество записей в локальном архиве превышает лимит.';

  @override
  String get invalidLocalArchiveRecord =>
      'Недопустимая запись локального архива.';

  @override
  String get theLocalArchiveLengthOrChunk =>
      'Длина локального архива или параметры блоков превышают лимиты.';

  @override
  String get theVaultMembershipChainIsMissing =>
      'Цепочка членства сейфа отсутствует или превышает лимит.';

  @override
  String get aDeviceSequenceFloorIsOut =>
      'device sequence floor вне безопасного диапазона.';

  @override
  String get invalidDeviceSequenceFloorsFormat =>
      'Недопустимый формат device sequence floors.';

  @override
  String get theEpochKeySha256Doesnt =>
      'SHA-256 ключа эпохи не совпадает с двоичным блоком.';

  @override
  String get theEpochKeyDescriptorsDontMatch =>
      'Дескрипторы ключей эпох не соответствуют набору конвертов ключей.';

  @override
  String get invalidDeviceSignatureOnTheEpoch =>
      'Недопустимая подпись устройства для ключа эпохи.';

  @override
  String get theEpochKeyProofSignerIsnt =>
      'Подписавший подтверждение ключа эпохи не является участником сейфа в этой версии.';

  @override
  String epochEpochMapsToInconsistentVault(int epoch) {
    return 'Эпохе $epoch соответствуют несогласованные ключи сейфа.';
  }

  @override
  String get theUnsealedKeyEnvelopeDoesntMatch =>
      'Распечатанный конверт ключа не совпадает с локальным ключом эпохи.';

  @override
  String get invalidMembershipEncryptionFingerprint =>
      'Недопустимый отпечаток шифрования членства.';

  @override
  String get invalidMembershipMemberRoleStateId =>
      'Недопустимые роль, состояние или ID участника членства.';

  @override
  String get theMembershipSignerWasntAnActive =>
      'Подписавший членство не был активным владельцем в соответствующей подписанной версии.';

  @override
  String get objectRefsMustBeUniqueLowercase =>
      'object_refs должны быть уникальными UUID в нижнем регистре в строго возрастающем порядке.';

  @override
  String get objectRefsIsntAnArrayOr =>
      'object_refs не является массивом или содержит больше 1024 записей.';

  @override
  String get theSnapshotCurrentHeadIsInconsistent =>
      'Текущая голова снимка не согласуется с той же зафиксированной отметкой истории.';

  @override
  String get theSnapshotHeadCommitSeqDoesnt =>
      'commit_seq головы снимка не совпадает с зафиксированной отметкой истории.';

  @override
  String get theSnapshotHeadCommitSeqExceeds =>
      'commit_seq головы снимка превышает зафиксированную отметку снимка.';

  @override
  String get aSnapshotHeadIsMissingFields =>
      'У головы снимка отсутствуют поля или она повторяется.';

  @override
  String get theSnapshotHeadSetDoesntCover =>
      'Набор голов снимка не охватывает все записи истории.';

  @override
  String fieldMustBeADecimalString(String field) {
    return '$field должно быть десятичной строкой.';
  }

  @override
  String labelMustBeAJsonObject(String label) {
    return '$label должно быть объектом JSON.';
  }

  @override
  String uploadedObjectObjectidFailedReadBack(String objectId) {
    return 'Отправленный объект $objectId не прошёл проверку обратным чтением.';
  }

  @override
  String get revisionCommitSeqIsntMonotonicOr =>
      'commit_seq версий не монотонен или превышает отметку снимка.';

  @override
  String get theRevisionHistoryCursorIsInvalid =>
      'Курсор истории версий недопустим или повторяется.';

  @override
  String get theRevisionHistoryExceedsTheArchive =>
      'История версий превышает лимит записей архива.';

  @override
  String get theServerGenerationDiffersBetweenRevision =>
      'Поколение сервера различается между страницами истории версий и конфликтов.';

  @override
  String get conflictSeqIsntMonotonicOrExceeds =>
      'conflict_seq не монотонен или превышает отметку снимка.';

  @override
  String get aConflictBranchReferencesABase =>
      'Ветка конфликта ссылается на базовую версию вне снимка.';

  @override
  String get theConflictHistoryCursorIsInvalid =>
      'Курсор истории конфликтов недопустим или повторяется.';

  @override
  String get theConflictHistoryExceedsTheArchive =>
      'История конфликтов превышает лимит записей архива.';

  @override
  String get aConflictResolutionReferencesARevision =>
      'Решение конфликта ссылается на версию вне снимка.';

  @override
  String get theConflictResolutionStateAndResolution =>
      'Состояние решения конфликта и resolution_seq не совпадают.';

  @override
  String get encryptedArchiveFile => 'Файл зашифрованного архива';

  @override
  String get theHistorySnapshotContainsADuplicate =>
      'Снимок истории содержит повторяющийся conflict_id.';

  @override
  String get theHistorySnapshotContainsADuplicate2 =>
      'Снимок истории содержит повторяющийся revision_id.';

  @override
  String historicalSigningDeviceIdIsntIn(String id) {
    return 'Устройство $id, подписывавшее историю, отсутствует в проверяемом каталоге сейфа.';
  }

  @override
  String get historyEntriesExceedTheArchiveResource =>
      'Записи истории превышают лимит ресурсов архива.';

  @override
  String get aHistoryPageDoesntMatchThe =>
      'Страница истории не соответствует контексту зафиксированного снимка сейфа.';

  @override
  String get theSameDeviceIdHasConflicting =>
      'Для одного ID устройства есть конфликтующие записи каталога открытых ключей.';

  @override
  String get pinningTheServerHistorySnapshot =>
      'Фиксация снимка истории сервера';

  @override
  String sha256OfObjectIdDoesnt(String id) {
    return 'SHA-256 объекта $id не совпадает с дайджестом содержимого.';
  }

  @override
  String objectIdIsReferencedByVerified(String id) {
    return 'На объект $id ссылаются проверенные записи, но его содержимого нет ни на сервере, ни в локальном кэше архива; неполный архив создан не будет.';
  }

  @override
  String get unsupportedArchiveBinaryBlockKind =>
      'Неподдерживаемый тип двоичного блока архива.';

  @override
  String get archiveBinaryBlockOffsetsHaveGaps =>
      'Смещения двоичных блоков архива содержат пропуски, перекрытия или выходят за пределы.';

  @override
  String get tooManyArchiveBinaryBlocks =>
      'Слишком много двоичных блоков в архиве.';

  @override
  String get theArchiveBinaryBlocksDontCover =>
      'Двоичные блоки архива не покрывают всю полезную нагрузку.';

  @override
  String get duplicateArchiveBinaryObjectId =>
      'Повторяющийся двоичный object_id в архиве.';

  @override
  String get invalidArchiveConflictResolutionOutboxLink =>
      'Недопустимая связь решения конфликта и очереди отправки в архиве.';

  @override
  String get invalidArchiveConflictOrderWatermarkOr =>
      'Недопустимый порядок, отметка или уникальность конфликтов в архиве.';

  @override
  String get theArchiveCreatedAtIsntAn =>
      'created_at архива не является временем в формате RFC3339.';

  @override
  String get invalidArchiveEpochKeyBinaryBlock =>
      'Недопустимый двоичный блок ключа эпохи в архиве.';

  @override
  String get theArchiveEpochKeyBlockDoesnt =>
      'Блок ключа эпохи в архиве не соответствует подписанному дескриптору.';

  @override
  String archiveEpochKeyKeyDoesntMatch(String key) {
    return 'Ключ эпохи архива $key не совпадает с ключом этого устройства.';
  }

  @override
  String get theArchiveGraveyardCountDoesntMatch =>
      'Количество в списке удалённого архива не совпадает с метками удаления снимка.';

  @override
  String get theArchiveGraveyardDoesntMatchThe =>
      'Список удалённого в архиве не соответствует проверенным меткам удаления.';

  @override
  String get invalidArchiveKeyEnvelopeContextOr =>
      'Недопустимый контекст или уникальность конверта ключа в архиве.';

  @override
  String get invalidArchiveKeyEnvelopeSealingFormat =>
      'Недопустимый формат запечатывания конверта ключа в архиве.';

  @override
  String get invalidArchiveKeyEnvelopeSignature =>
      'Недопустимая подпись конверта ключа в архиве.';

  @override
  String get invalidArchiveLocalPendingSchema =>
      'Недопустимая схема local_pending в архиве.';

  @override
  String get theArchiveMembershipDoesntIncludeThe =>
      'Членство в архиве не включает текущую учётную запись.';

  @override
  String get theArchiveMembershipIsntAValid =>
      'Членство в архиве не является допустимым префиксом текущей цепочки сейфа.';

  @override
  String get theArchiveMembershipIsNewerThan =>
      'Членство в архиве новее текущей цепочки сейфа.';

  @override
  String get theArchiveObjectBlockSetDiffers =>
      'Набор блоков объектов архива отличается от проверенных object_refs.';

  @override
  String get theArchiveOutboxBaseEnvelopeIs =>
      'В базовом конверте очереди отправки архива нет базовой версии.';

  @override
  String get anArchiveOutboxDeviceSeqIs =>
      'device_seq очереди отправки в архиве вне безопасного диапазона целых чисел.';

  @override
  String get invalidArchiveOutboxState =>
      'Недопустимое состояние очереди отправки архива.';

  @override
  String get anArchiveRevisionIsDuplicatedOr =>
      'Версия архива повторяется или её базовая цепочка прерывается.';

  @override
  String get anArchiveSignedEnvelopeIsMissing =>
      'У подписанного конверта архива нет заголовка.';

  @override
  String get invalidArchiveSnapshotCursorGeneration =>
      'Недопустимый курсор или поколение снимка в архиве.';

  @override
  String get anArchiveTombstoneDoesntMatchThe =>
      'Метка удаления в архиве не соответствует последней записи истории.';

  @override
  String get unsupportedArchiveVaultRole =>
      'Неподдерживаемый vault_role в архиве.';

  @override
  String get invalidArchiveRevisionOrderOrWatermark =>
      'Недопустимый порядок версий или отметка архива.';

  @override
  String get theArchiveConflictBaseRevisionDoesnt =>
      'Базовая версия конфликта в архиве не существует.';

  @override
  String get anArchiveConflictEnvelopeHasNo =>
      'У конверта конфликта в архиве нет подписанного заголовка.';

  @override
  String get anArchiveConflictResolutionPointsTo =>
      'Решение конфликта в архиве ссылается на недопустимую цель.';

  @override
  String get duplicateExternalDeviceOutboxConflictId =>
      'Повторяющийся ID конфликта очереди отправки другого устройства в архиве.';

  @override
  String archiveFieldKeyIsMissingOr(String key) {
    return 'Поле архива $key отсутствует или недопустимо.';
  }

  @override
  String get invalidArchiveFieldType => 'Недопустимый тип поля архива.';

  @override
  String get anArchiveObjectIdLengthOr =>
      'ID, длина или SHA-256 объекта архива не прошли проверку перед применением; ничего не отправлено и не записано в локальную базу данных.';

  @override
  String sha256MismatchForArchiveObject(String objectId) {
    return 'Не совпадает SHA-256 объекта архива $objectId.';
  }

  @override
  String get theNumberOfEncryptedObjectsReferenced =>
      'Количество зашифрованных объектов, на которые ссылается архив, превышает лимит.';

  @override
  String get theArchiveMustBeBoundTo =>
      'Архив должен быть привязан к набору конвертов ключей одного экспортирующего устройства.';

  @override
  String get unsupportedArchiveLocalConflictKindState =>
      'Неподдерживаемый тип или состояние локального конфликта в архиве.';

  @override
  String get invalidLinkBetweenArchiveLocalConflict =>
      'Недопустимая связь состояния решения локального конфликта в архиве.';

  @override
  String get duplicateArchiveLocalConflictId =>
      'Повторяющийся локальный conflict_id в архиве.';

  @override
  String get theArchivesLocalOutboxBaseRevision =>
      'base_revision локальной очереди отправки в архиве не удаётся проверить.';

  @override
  String get theArchivesLocalOutboxMetadataIs =>
      'Метаданные локальной очереди отправки в архиве недопустимы или повторяются.';

  @override
  String get theArchiveFormatFieldsAreInvalid =>
      'Поля формата архива недопустимы или отличаются от текущего пространства службы или сейфа.';

  @override
  String get anArchiveRecordDeviceSeqIs =>
      'device_seq записи архива вне безопасного диапазона.';

  @override
  String get anArchiveDevicePublicKeyIs =>
      'Открытый ключ устройства в архиве недопустим или повторяется.';

  @override
  String archiveDeviceDirectoryKeyDoesntMatch(String key) {
    return 'Каталог устройств архива $key не совпадает с текущим каталогом сейфа.';
  }

  @override
  String get invalidArchiveDeviceDirectoryOrMembership =>
      'Недопустимый формат каталога устройств или цепочки членства в архиве.';

  @override
  String get theCurrentVaultMembershipChainIs =>
      'Текущая цепочка членства сейфа недействительна.';

  @override
  String get theCurrentVaultDeviceIsntUnlocked =>
      'Текущий сейф или устройство не разблокированы, поэтому архив создать нельзя.';

  @override
  String get thisDeviceHasNoVaultEpoch =>
      'На этом устройстве нет ключа эпохи сейфа для экспорта.';

  @override
  String get theCurrentDevicesKeyEnvelopeSource =>
      'Не удалось проверить источник или контекст конверта ключа текущего устройства.';

  @override
  String get theCurrentAccountIsntInThe =>
      'Текущей учётной записи нет в последнем подписанном членстве.';

  @override
  String get theSnapshotExceedsTheArchiveCapacity =>
      'Снимок превышает ёмкость архива (100 000 записей); архив не создан.';

  @override
  String get collectingAndCheckingEncryptedObjects =>
      'Сбор и проверка зашифрованных объектов';

  @override
  String get theTombstoneGraveyardCouldntBeRebuilt =>
      'Не удалось восстановить список меток удаления из зафиксированной истории.';

  @override
  String get theLastSnapshotPageStillContains =>
      'Последняя страница снимка всё ещё содержит курсор продолжения.';

  @override
  String get duplicateServerKeyEnvelopeContext =>
      'Повторяющийся контекст конверта ключа сервера.';

  @override
  String serverObjectObjectidConflictsWithThe(String objectId) {
    return 'Объект сервера $objectId конфликтует с содержимым архива; неизменяемый объект перезаписан не будет.';
  }

  @override
  String get theServerSnapshotItemCountDoesnt =>
      'item_count снимка сервера не совпадает с числом записей постраничного манифеста.';

  @override
  String get theServerSnapshotItemCountDoesnt2 =>
      'item_count снимка сервера не совпадает с числом записей полного манифеста.';

  @override
  String get theServerSnapshotItemCountIs =>
      'item_count снимка сервера различается между страницами.';

  @override
  String get invalidServerSnapshotItemCount =>
      'Недопустимый item_count снимка сервера.';

  @override
  String get theServerSnapshotItemCountIs2 =>
      'item_count снимка сервера недопустим или изменился.';

  @override
  String get theServerSnapshotPageManifestHas =>
      'В манифесте страниц снимка сервера слишком много записей.';

  @override
  String get invalidServerSnapshotPageBoundaryOr =>
      'Недопустимая граница страницы или формат манифеста снимка сервера.';

  @override
  String get theServerSnapshotContainsInvalidRecords =>
      'Снимок сервера содержит недопустимые записи.';

  @override
  String get theServerSnapshotReturnedAnEmpty =>
      'Снимок сервера вернул пустую страницу до завершения.';

  @override
  String get theServerSnapshotManifestExceedsThe =>
      'Манифест снимка сервера превышает лимит клиента 64 МиБ.';

  @override
  String get theServerSnapshotContinuationCursorIs =>
      'Курсор продолжения снимка сервера пуст, повторяется или недопустим.';

  @override
  String get aLocalConflictKindStateIs =>
      'Тип или состояние локального конфликта недопустимы или повторяются.';

  @override
  String get invalidLinkToTheLocalConflict =>
      'Недопустимая связь с состоянием решения локального конфликта.';

  @override
  String get invalidLocalConflictResolutionOutboxLink =>
      'Недопустимая связь локального решения конфликта и очереди отправки.';

  @override
  String invalidLocalEpochKeyIdentifierValuevalue(String valueValue) {
    return 'Недопустимый идентификатор локального ключа эпохи: $valueValue';
  }

  @override
  String get theLocalOutboxBaseEnvelopeDoesnt =>
      'Базовый конверт локальной очереди отправки не соответствует версии.';

  @override
  String get theLocalOutboxBaseRevisionCant =>
      'base_revision локальной очереди отправки нельзя проверить для архивации.';

  @override
  String get aLocalOutboxRevisionIdIs =>
      'revision_id локальной очереди отправки отсутствует или повторяется.';

  @override
  String get theLocalOutboxMetadataDoesntMatch =>
      'Метаданные локальной очереди отправки не соответствуют заголовку подписи.';

  @override
  String get theLocalOutboxContainsADuplicate =>
      'Локальная очередь отправки содержит повторяющийся op_id.';

  @override
  String get theLocalOutboxStateCantSafely =>
      'Состояние локальной очереди отправки нельзя безопасно передать через архив.';

  @override
  String get localOutboxConflictsExceedTheArchive =>
      'Локальная очередь отправки или конфликты превышают лимит записей архива.';

  @override
  String get thisDevicesEpochKeysDontFully =>
      'Ключи эпох этого устройства не полностью соответствуют набору конвертов ключей.';

  @override
  String get thisDevicesPublicKeyDoesntMatch =>
      'Открытый ключ этого устройства не совпадает с каталогом сейфа на сервере, поэтому экспорт невозможен.';

  @override
  String get thisDevicesIdentityCouldntBeMatched =>
      'Идентичность этого устройства не удалось сопоставить с текущим каталогом устройств сейфа.';

  @override
  String get checkingArchiveConflictBranchFields =>
      'Проверка полей веток конфликтов архива';

  @override
  String get checkingArchiveConflictFields =>
      'Проверка полей конфликтов архива';

  @override
  String get checkingArchiveManifestFieldTypes =>
      'Проверка типов полей манифеста архива';

  @override
  String get checkingArchiveManifestEntryLimits =>
      'Проверка лимитов записей манифеста архива';

  @override
  String get checkingArchiveManifestIdentityAndRole =>
      'Проверка идентичности и роли в манифесте архива';

  @override
  String get checkingArchiveManifestTopLevelFields =>
      'Проверка полей верхнего уровня манифеста архива';

  @override
  String get checkingArchiveMembershipFields =>
      'Проверка полей членства архива';

  @override
  String get checkingArchiveOutboxFields =>
      'Проверка полей очереди отправки архива';

  @override
  String get checkingArchiveRevisionFields => 'Проверка полей версий архива';

  @override
  String get checkingArchiveSnapshotHeadFields =>
      'Проверка полей голов снимка архива';

  @override
  String get checkingArchiveSnapshotSchema => 'Проверка схемы снимка архива';

  @override
  String get checkingArchiveDeviceDirectoryFields =>
      'Проверка полей каталога устройств архива';

  @override
  String get theSignedObjectRefsDontMatch =>
      'Подписанные object_refs не соответствуют зашифрованному манифесту открытого текста.';

  @override
  String get decryptingTheArchiveContainer => 'Расшифровка контейнера архива';

  @override
  String get aRecordEnvelopeIsMissingIts =>
      'У конверта записи нет заголовка подписи.';

  @override
  String get theRecordSignerEpochDoesntBelong =>
      'Подписавший или эпоха записи не относятся к этой версии членства.';

  @override
  String theBaseRevisionChainForRecord(String recordId) {
    return 'Цепочка base_revision записи $recordId прерывается.';
  }

  @override
  String get trustCouldntBeEstablishedForThe =>
      'Не удалось установить доверие к подписавшему или эпохе ключа записи.';

  @override
  String get theRecordSignatureHeaderDoesntMatch =>
      'Заголовок подписи записи не соответствует индексу архива.';

  @override
  String get invalidDeviceSigningKeyLength =>
      'Недопустимая длина ключа подписи устройства.';

  @override
  String theHistoryDirectoryOfDeviceId(String id) {
    return 'Исторический каталог устройства $id конфликтует с текущим каталогом сейфа.';
  }

  @override
  String get readingEveryHistoryPageOfThe =>
      'Чтение всех страниц истории зафиксированного снимка';

  @override
  String get readingTheArchiveManifestAndBinary =>
      'Чтение манифеста и двоичных блоков архива';

  @override
  String get verifyingArchiveKeyEnvelopesAndEpoch =>
      'Проверка конвертов ключей и ключей эпох архива';

  @override
  String get verifyingArchiveEncryptedObjectBlocks =>
      'Проверка зашифрованных блоков объектов архива';

  @override
  String get verifyingArchiveHistoryConflicts =>
      'Проверка конфликтов истории архива';

  @override
  String get verifyingArchiveHistoryRevisions =>
      'Проверка версий истории архива';

  @override
  String get verifyingTheArchivesLocalOutboxAnd =>
      'Проверка локальной очереди отправки и веток конфликтов архива';

  @override
  String get verifyingArchiveFormatAndTarget =>
      'Проверка формата и цели архива';

  @override
  String get verifyingArchiveDeviceSequenceWatermarks =>
      'Проверка отметок последовательностей устройств архива';

  @override
  String get verifyingTheMemberSignatureChainAnd =>
      'Проверка цепочки подписей участников и доверия к устройствам';

  @override
  String get verifyingSignaturesKeyEpochsAndObject =>
      'Проверка подписей, эпох ключей и ссылок на объекты';

  @override
  String get verifyingTheDeviceDirectoryAndSigned =>
      'Проверка каталога устройств и подписанной цепочки членства';

  @override
  String get attachmentsAreLimitedTo1Gib => 'Размер вложения ограничен 1 ГиБ.';

  @override
  String get theVaultHasNoActiveDevice =>
      'В сейфе нет активных отчётов о возможностях устройств.';

  @override
  String get theVaultHasNoActiveDevices =>
      'В сейфе нет активных устройств, способных читать вложения v2.';

  @override
  String get theServerDoesNotSupportSigned =>
      'Сервер не поддерживает подписанные отчёты о возможностях устройств, необходимые для вложений v2.';

  @override
  String get theServerReturnedAnInvalidVault =>
      'Сервер вернул недопустимый перечень устройств сейфа; отправка v2 заблокирована.';

  @override
  String get thisClientCannotAuthenticateOtherDevices =>
      'Этот клиент не может проверить подписанные отчёты о возможностях других устройств; отправка v2 заблокирована.';

  @override
  String get thisDeviceCapabilityReportCouldNot =>
      'Не удалось опубликовать отчёт о возможностях устройства; данные вложения не подготовлены.';

  @override
  String get thisDeviceHasNotPublishedIts =>
      'Это устройство ещё не опубликовало подписанный отчёт о возможностях вложений.';

  @override
  String get thisPlatformCannotSafelySaveAttachments =>
      'Эта платформа не может безопасно сохранять вложения больше 256 МиБ; данные вложения не подготовлены.';

  @override
  String get someDevicesInTheVaultDont =>
      'Некоторые устройства сейфа не поддерживают такой размер вложения.';

  @override
  String get v2PreflightIsOnlyRequiredAbove =>
      'Предварительная проверка v2 нужна только для файлов больше 256 МиБ.';

  @override
  String devicenameHasNoValidSignedReport(String deviceName) {
    return 'У $deviceName нет действительного подписанного отчёта для записей вложений до 1 ГиБ; обновите или удалите это активное устройство, прежде чем включать v2.';
  }

  @override
  String get theDownloadedAttachmentCiphertextDigestOr =>
      'Дайджест или длина скачанного шифротекста вложения не совпадают.';

  @override
  String get differentAttachmentsReferenceTheSameObject =>
      'Разные вложения ссылаются на один и тот же объект.';

  @override
  String get hostObjectRefsMustBeUnique =>
      'object_refs хоста должны быть уникальными UUID в нижнем регистре в строго возрастающем порядке.';

  @override
  String get hostObjectRefsMustBeAn =>
      'object_refs хоста должен быть массивом не более чем из 1024 элементов.';

  @override
  String get duplicateHostAttachmentBlobId =>
      'Повторяющийся ID blob-объекта вложения хоста.';

  @override
  String get invalidHostAttachmentManifestFormat =>
      'Недопустимый формат манифеста вложений хоста.';

  @override
  String get theHostAttachmentManifestExceedsThe =>
      'Манифест вложений хоста превышает лимит хранения 32 КиБ.';

  @override
  String get localIntegrityVerificationOfTheEncrypted =>
      'Локальная проверка целостности зашифрованного объекта вложения не пройдена.';

  @override
  String get theEncryptedAttachmentManifestDoesntMatch =>
      'Зашифрованный манифест вложений не соответствует object_refs.';

  @override
  String get invalidPersistedUploadChunkSize =>
      'Недопустимый сохранённый размер блока отправки.';

  @override
  String get invalidPersistedUploadProgress =>
      'Недопустимый сохранённый прогресс отправки.';

  @override
  String get integrityVerificationOfAPersistedAttachment =>
      'Проверка целостности сохранённого блока шифротекста вложения не пройдена.';

  @override
  String get theServerReturnedAnInvalidUpload =>
      'Сервер вернул недопустимое резервирование отправки.';

  @override
  String get anAttachmentObjectAlreadyOnThe =>
      'Объект вложения на сервере не совпадает с сохранённым шифротекстом.';

  @override
  String get theServerAttachmentUploadReceiptDoesnt =>
      'Подтверждение отправки вложения от сервера не соответствует объекту шифротекста.';

  @override
  String get integrityVerificationOfTheLocalAttachment =>
      'Проверка целостности локального шифротекста вложения, ожидающего отправки, не пройдена.';

  @override
  String get theLocalAttachmentObjectWaitingFor =>
      'Локальный объект вложения, ожидающий отправки, отсутствует.';

  @override
  String get theLocalAttachmentEncryptionDirectoryIs =>
      'Локальный каталог шифрования вложений отсутствует или не прошёл проверку целостности.';

  @override
  String get thisV2AttachmentExceeds256Mib =>
      'Это вложение v2 больше 256 МиБ; этот клиент пока не поддерживает ограниченную расшифровку и потоковое сохранение.';

  @override
  String get thisHostsAttachmentObjectReferencesExceed =>
      'Ссылок на объекты вложений этого хоста больше допустимых 1024.';

  @override
  String get theAttachmentIsntInThisHosts =>
      'Вложения нет в зашифрованном манифесте этого хоста.';

  @override
  String get theAttachmentObjectIdDuplicatesAn =>
      'ID объекта вложения совпадает с существующей ссылкой хоста.';

  @override
  String get theTotalAttachmentPlaintextLengthExceeds =>
      'Общая длина открытого текста вложения превышает заявленную в манифесте.';

  @override
  String get attachmentPlaintextDigestOrTotalLength =>
      'Не пройдена проверка дайджеста или общей длины открытого текста вложения.';

  @override
  String get theComSerialConsoleRequiresThe =>
      'Для консоли последовательного порта COM нужен клиент для Windows.';

  @override
  String get theBrowserCantStartALocal =>
      'Браузер не может напрямую запустить локальную оболочку; используйте настольный клиент.';

  @override
  String get theSerialInputQueueIsFull =>
      '\n[Очередь ввода последовательного порта заполнена; этот ввод не отправлен. Вводите частями.]\n';

  @override
  String get couldntStartTheSerialConsole =>
      '\n[Не удалось запустить консоль последовательного порта]\n';

  @override
  String get theSerialConsoleFailedToStart =>
      'Не удалось запустить консоль последовательного порта.';

  @override
  String get theSerialPortDoesntSupportThis =>
      'Последовательный порт не поддерживает эти настройки.';

  @override
  String get serialWriteFailedOrTheDevice =>
      'Ошибка записи в последовательный порт или устройство отключено.';

  @override
  String get serialWriteTimedOut =>
      'Истекло время записи в последовательный порт.';

  @override
  String get invalidSerialPortOrBaudRate =>
      'Недопустимый последовательный порт или скорость.';

  @override
  String get serialReadFailedOrTheDevice =>
      'Ошибка чтения последовательного порта или устройство отключено.';

  @override
  String get serialInputExceedsTheLimit =>
      'Ввод в последовательный порт превышает лимит.';

  @override
  String couldntOpenItemWindowsGetlasterrorCheck(
    Object item,
    int GetLastError,
  ) {
    return 'Не удалось открыть $item (Windows $GetLastError). Проверьте имя последовательного порта и не занят ли он.';
  }

  @override
  String get couldntReadTheSerialPortConfiguration =>
      'Не удалось прочитать настройки последовательного порта.';

  @override
  String get unsupportedAttachmentManifestFormat =>
      'Неподдерживаемый формат манифеста вложений.';

  @override
  String get invalidAttachmentMimeTypeFormat =>
      'Недопустимый формат MIME-типа вложения.';

  @override
  String get invalidAttachmentBlobIdFormat =>
      'Недопустимый формат ID blob-объекта вложения.';

  @override
  String get invalidAttachmentEncryptionDirectoryFormat =>
      'Недопустимый формат каталога шифрования вложений.';

  @override
  String get attachmentEncryptionDirectoryAuthenticationOrParsing =>
      'Не удалось проверить подлинность или разобрать каталог шифрования вложений.';

  @override
  String get theAttachmentEncryptionDirectoryExceedsThe =>
      'Каталог шифрования вложений превышает допустимый размер.';

  @override
  String get invalidAttachmentBlockFieldFormat =>
      'Недопустимый формат поля блока вложения.';

  @override
  String get theAttachmentBlockCountDoesntMatch =>
      'Количество блоков вложения не соответствует длине файла.';

  @override
  String get invalidAttachmentBlockCount =>
      'Недопустимое количество блоков вложения.';

  @override
  String get theNumberOfAttachmentBlocksExceeds =>
      'Количество блоков вложения превышает лимит формата v2.';

  @override
  String get theNumberOfAttachmentBlocksExceeds2 =>
      'Количество блоков вложения превышает лимит текущего формата.';

  @override
  String get invalidAttachmentBlockEntryFormat =>
      'Недопустимый формат записи блока вложения.';

  @override
  String get invalidAttachmentBlockManifestFormat =>
      'Недопустимый формат манифеста блоков вложения.';

  @override
  String get attachmentBlockAuthenticationFailedTheFile =>
      'Аутентификация блока вложения не пройдена; возможно, файл был изменён.';

  @override
  String get attachmentBlockOrderLengthOrUniqueness =>
      'Не пройдена проверка порядка, длины или уникальности блоков вложения.';

  @override
  String get theAttachmentSizeIsOutsideThe =>
      'Размер вложения вне диапазона, поддерживаемого клиентом.';

  @override
  String get attachmentIntegrityOrFinalLengthVerification =>
      'Не пройдена проверка целостности или итоговой длины вложения.';

  @override
  String get theAttachmentCiphertextObjectIsMissing =>
      'Объект шифротекста вложения отсутствует.';

  @override
  String get attachmentCiphertextDigestOrLengthVerification =>
      'Не пройдена проверка дайджеста или длины шифротекста вложения.';

  @override
  String get invalidAttachmentCiphertextLength =>
      'Недопустимая длина шифротекста вложения.';

  @override
  String get invalidAttachmentKeyFormat =>
      'Недопустимый формат ключа вложения.';

  @override
  String get theAttachmentObjectIdIsInvalid =>
      'ID объекта вложения недопустим или повторяется.';

  @override
  String get invalidAttachmentFileNameOrMime =>
      'Недопустимый формат имени файла или MIME-типа вложения.';

  @override
  String get invalidAttachmentFileNameFormat =>
      'Недопустимый формат имени файла вложения.';

  @override
  String get attachmentPlaintextBlockLengthVerificationFailed =>
      'Не пройдена проверка длины блока открытого текста вложения.';

  @override
  String get invalidAttachmentPlaintextDigestFormat =>
      'Недопустимый формат дайджеста открытого текста вложения.';

  @override
  String get invalidAttachmentManifestEntryFormat =>
      'Недопустимый формат записи манифеста вложений.';

  @override
  String get theAttachmentSourceReturnsOnlyEmpty =>
      'Источник вложения возвращает только пустые блоки.';

  @override
  String get theAttachmentSourceKeepsReturningEmpty =>
      'Источник вложения продолжает возвращать пустые блоки в конце файла.';

  @override
  String get theAttachmentSourceEndedEarlyIts =>
      'Источник вложения закончился раньше времени; длина не совпадает со сведениями о файле.';

  @override
  String get anAttachmentSourceBlockExceedsThe =>
      'Блок источника вложения превышает лимит чтения 4 МиБ.';

  @override
  String get theAttachmentSourceLengthExceedsThe =>
      'Длина источника вложения превышает сведения о файле.';

  @override
  String get invalidAttachmentDirectoryNonceFormat =>
      'Недопустимый формат nonce каталога вложений.';

  @override
  String get theAttachmentDirectoryBlockCountDoesnt =>
      'Количество блоков каталога вложений не соответствует дескриптору.';

  @override
  String get attachmentDirectoryBlockOrderLengthOr =>
      'Не пройдена проверка порядка, длины или уникальности блоков каталога вложений.';

  @override
  String get invalidAttachmentDirectoryCiphertextSize =>
      'Недопустимый размер шифротекста каталога вложений.';

  @override
  String get attachmentDirectoryCiphertextDigestOrLength =>
      'Не пройдена проверка дайджеста или длины шифротекста каталога вложений.';

  @override
  String get invalidAttachmentDirectoryCiphertextLength =>
      'Недопустимая длина шифротекста каталога вложений.';

  @override
  String get invalidAttachmentDirectoryObjectIdFormat =>
      'Недопустимый формат ID объекта каталога вложений.';

  @override
  String get invalidAttachmentDirectoryDigestFormat =>
      'Недопустимый формат дайджеста каталога вложений.';

  @override
  String get theAttachmentExceedsThe1Gib =>
      'Вложение превышает лимит клиента 1 ГиБ.';

  @override
  String get theAttachmentExceedsThe256Mib =>
      'Вложение превышает лимит клиента 256 МиБ.';

  @override
  String get theShareRequestIsMalformedOr =>
      'Запрос на доступ повреждён или получен с другого экземпляра сервера.';

  @override
  String get invalidShareRequestAccountIdentifier =>
      'Недопустимый идентификатор учётной записи в запросе на доступ.';

  @override
  String get invalidDeviceSelfProofPublicKey =>
      'Недопустимая длина открытого ключа или подписи самоподтверждения устройства.';

  @override
  String get invalidDeviceSelfProofFields =>
      'Недопустимые поля самоподтверждения устройства.';

  @override
  String get invalidDeviceSelfProofSignature =>
      'Недопустимая подпись самоподтверждения устройства.';

  @override
  String get invalidDeviceSelfProofAccountIdentifier =>
      'Недопустимый идентификатор учётной записи в самоподтверждении устройства.';

  @override
  String remoteDesktopConnectionFailedCodeLast(String last) {
    return 'Не удалось подключиться к удалённому рабочему столу (код $last). Проверьте учётные данные, доверие к сертификату и журналы шлюза.';
  }

  @override
  String get remoteDesktopDisconnected => 'Удалённый рабочий стол отключён.';

  @override
  String get resolutionAndScaling => 'Разрешение и масштаб';

  @override
  String get apply => 'Применить';

  @override
  String get theServerDoesntSupportResizingOnly =>
      'Сервер не поддерживает изменение разрешения; возможно только локальное масштабирование.';

  @override
  String get theServerSupportsLiveResizingDisplay =>
      'Сервер поддерживает изменение разрешения на лету (канал управления дисплеем).';

  @override
  String get theServerSupportsResizingExtendeddesktopsize =>
      'Сервер поддерживает изменение разрешения (ExtendedDesktopSize).';

  @override
  String get theServerDoesntOfferDisplayControl =>
      'Сервер не предоставляет управление дисплеем; новое разрешение вступит в силу после переподключения.';

  @override
  String get waitingForTheServerToReport =>
      'Ожидание сведений от сервера о поддержке изменения разрешения…';

  @override
  String get thisSessionUsesAllLocalMonitors =>
      'Этот сеанс использует все локальные мониторы; удалённое разрешение определяется их расположением.';

  @override
  String get scalesThisWindowOnlyTheRemote =>
      'Масштабируется только это окно; удалённое разрешение не меняется.';

  @override
  String get actualSize11Scrollable => 'Реальный размер (1:1, с прокруткой)';

  @override
  String get width => 'Ширина';

  @override
  String get serverDefaultDontRequestAResize =>
      'По умолчанию сервера (без запроса изменения)';

  @override
  String get localDisplay => 'Локальное отображение';

  @override
  String get custom => 'Другое…';

  @override
  String get remoteResolution => 'Удалённое разрешение';

  @override
  String get fitToWindow => 'По размеру окна';

  @override
  String get height => 'Высота';

  @override
  String get clipboardIsLimitedTo64Kib => 'Буфер обмена ограничен 64 КиБ';

  @override
  String invalidRdpOptionsMessage(String message) {
    return 'Недопустимые параметры RDP: $message';
  }

  @override
  String get remoteDesktopConnectionClosed =>
      'Подключение к удалённому рабочему столу закрыто.';

  @override
  String get remoteDesktopSetupTimedOutCheck =>
      'Истекло время настройки удалённого рабочего стола. Проверьте шлюз и цель.';

  @override
  String get remoteDesktopStreamFailed =>
      'Сбой потока удалённого рабочего стола.';

  @override
  String get unableToConnectCheckTheDesktop =>
      'Не удалось подключиться. Проверьте шлюз рабочего стола, политику Relay, учётные данные и доверие к сертификату.';

  @override
  String get theHostSettingsChangedReconnect =>
      'Настройки хоста изменились. Переподключитесь.';

  @override
  String get theResolutionSettingAppliesToThis =>
      'Настройка разрешения действует только в этом сеансе; сохранить её для хоста не удалось.';

  @override
  String get inAMultiMonitorSessionThe =>
      'В многомониторном сеансе разрешение определяется мониторами этого компьютера; чтобы задать его, отключите «Использовать все мониторы».';

  @override
  String get stoppedRequestingAResizeTheServer =>
      'Запросы изменения размера прекращены; сервер сохраняет текущее разрешение.';

  @override
  String get theInstalledRdpEngineDoesntSupport =>
      'Установленный движок RDP не поддерживает параметры RDP этого хоста; подключение выполнено с настройками по умолчанию.';

  @override
  String get couldntConnectToTheLocalGuacd =>
      'Не удалось подключиться к локальному guacd (127.0.0.1:4822). Запустите шлюз или используйте облачное рабочее пространство после входа.';

  @override
  String get theServerDoesntAcceptThisResolution =>
      'Сервер не принимает это разрешение.';

  @override
  String get theServerDoesntSupportResizingOnly2 =>
      'Сервер не поддерживает изменение разрешения; доступно только локальное масштабирование.';

  @override
  String get theServerRefusedTheResize =>
      'Сервер отклонил изменение разрешения.';

  @override
  String get theServerDoesntOfferDynamicResolution =>
      'Сервер не поддерживает динамическое разрешение; новое разрешение вступит в силу после переподключения.';

  @override
  String get theServerLacksTheResourcesFor =>
      'У сервера недостаточно ресурсов для этого разрешения.';

  @override
  String get thisRdpCertificateWasntTrustedThe =>
      'Сертификат RDP не принят как доверенный; подключение отменено.';

  @override
  String get thisVncServerDoesntSupportResizing =>
      'Этот VNC-сервер не поддерживает изменение разрешения (ExtendedDesktopSize не согласован); доступно только локальное масштабирование. Настройка сохранена.';

  @override
  String get clipboardTextIsTurnedOffFor =>
      'Для этого хоста текстовый буфер обмена отключён.';

  @override
  String get thisHostCantSaveCertificates =>
      'Этот хост не может сохранять сертификаты.';

  @override
  String thisClientCantProvideJoinThe(String join) {
    return 'Этот клиент не может предоставить: $join. Остальные параметры действуют как обычно.';
  }

  @override
  String get theCertificateCouldntBeSavedThe =>
      'Не удалось сохранить сертификат. Возможно, хост изменён или рабочее пространство заблокировано; повторите попытку или переподключитесь.';

  @override
  String couldntSaveRemoteFilesError(Object error) {
    return 'Не удалось сохранить удалённые файлы: $error';
  }

  @override
  String get invalidRemoteDesktopHostSettings =>
      'Недопустимые настройки хоста удалённого рабочего стола.';

  @override
  String get invalidRemoteDesktopImage =>
      'Недопустимое изображение удалённого рабочего стола.';

  @override
  String get theRemoteDesktopConnectionFailed =>
      'Не удалось подключиться к удалённому рабочему столу.';

  @override
  String get theRemoteDesktopConnectionClosed =>
      'Подключение к удалённому рабочему столу закрыто.';

  @override
  String get theRemoteDesktopConnectionTimedOut =>
      'Истекло время подключения к удалённому рабочему столу. Проверьте адрес и сеть.';

  @override
  String get rdpCertificateFingerprintChanged =>
      'Отпечаток сертификата RDP изменился';

  @override
  String get saveRemoteClipboardFiles =>
      'Сохранить файлы из удалённого буфера обмена';

  @override
  String get saveRemoteClipboardFiles2 =>
      'Сохранить файлы из удалённого буфера обмена…';

  @override
  String saveRemoteClipboardFilesFilecountFiles(
    int fileCount,
    String formatTransferBytes,
  ) {
    return 'Сохранить файлы из удалённого буфера обмена (файлов: $fileCount, $formatTransferBytes)…';
  }

  @override
  String get trustAndSave => 'Доверять и сохранить';

  @override
  String get trustThisRdpCertificate => 'Доверять этому сертификату RDP?';

  @override
  String get resolutionAndScaling2 => 'Разрешение и масштаб…';

  @override
  String get sendCtrlAltDelete => 'Отправить Ctrl+Alt+Delete';

  @override
  String get sendLocallyCopiedFiles => 'Отправить локально скопированные файлы';

  @override
  String get cancel => 'Отмена';

  @override
  String get openInNewWindow => 'Открыть в новом окне';

  @override
  String get copyRemoteClipboardText =>
      'Скопировать текст из удалённого буфера обмена';

  @override
  String savedCountItems(int count) {
    return 'Сохранено элементов: $count.';
  }

  @override
  String savedCountItemsAndPlacedThem(int count) {
    return 'Сохранено элементов: $count; они помещены в локальный буфер обмена и готовы к вставке.';
  }

  @override
  String get savedSha256 => 'Сохранённый SHA-256';

  @override
  String get currentCertificateSha256 => 'SHA-256 текущего сертификата';

  @override
  String get couldntSendClipboardText =>
      'Не удалось отправить текст из буфера обмена.';

  @override
  String get updateAndConnect => 'Обновить и подключиться';

  @override
  String get theServerCertificateDiffersFromThe =>
      'Сертификат сервера отличается от сохранённого. Сверьте новый отпечаток; после подтверждения запись доверия этого хоста обновится и подключение продолжится.';

  @override
  String get thereAreNoCopiedFilesOn =>
      'В локальном буфере обмена нет скопированных файлов.';

  @override
  String get saving => 'Сохранение…';

  @override
  String savingRemoteFilesDoneTotal(int done, int total) {
    return 'Сохранение удалённых файлов: $done/$total';
  }

  @override
  String get thisCertificateIsntTrustedYetVerify =>
      'Этот сертификат ещё не доверенный. Сверьте отпечаток; после подтверждения он сохранится для хоста и подключение продолжится.';

  @override
  String get oneWindowPerMonitor => 'Отдельное окно для каждого монитора';

  @override
  String get pasteLocalClipboardText =>
      'Вставить текст из локального буфера обмена';

  @override
  String get remoteDesktopMenu => 'Меню удалённого рабочего стола';

  @override
  String get chooseFilesForTheRemoteClipboard =>
      'Выбрать файлы для удалённого буфера обмена…';

  @override
  String get theRdpCertificateIsntTrustedYet =>
      'Сертификат RDP ещё не доверенный; требуется подтвердить его отпечаток SHA-256.';

  @override
  String get folderNestingIsTooDeep => 'Слишком глубокая вложенность папок';

  @override
  String get noFilesToSend => 'Нет файлов для отправки';

  @override
  String notARegularFileOrFolder(String name) {
    return 'Не обычный файл или папка: $name';
  }

  @override
  String get tooManyFilesForTheClipboard =>
      'Слишком много файлов для буфера обмена';

  @override
  String unsupportedOrDuplicateFileNameName(String name) {
    return 'Неподдерживаемое или повторяющееся имя файла: $name';
  }

  @override
  String fileTooLargeRelativepath(String relativePath) {
    return 'Файл слишком большой: $relativePath';
  }

  @override
  String get theTotalSizeOfTheRemote =>
      'Общий размер удалённых файлов превышает лимит.';

  @override
  String get rdpTlsHandshakeFailed20008No =>
      'Ошибка TLS-рукопожатия RDP (20008). Проверяемый сертификат не получен; проверьте порт назначения и настройки TLS.';

  @override
  String get theRdpSessionDisconnected => 'Сеанс RDP отключён.';

  @override
  String get invalidRdpImageSize => 'Недопустимый размер изображения RDP.';

  @override
  String get theRdpEngineCantBeLoaded =>
      'Не удаётся загрузить движок RDP. Установите полный клиент для Windows.';

  @override
  String get theRdpEngineIsTooOld =>
      'Движок RDP слишком старый для параметров RDP этого хоста. Установите полное обновление клиента.';

  @override
  String rdpConnectionFailedToradixstringCheckThe(String toRadixString) {
    return 'Не удалось подключиться по RDP ($toRadixString). Проверьте адрес, имя пользователя и пароль.';
  }

  @override
  String get theRdpConfigurationIsInvalidOr =>
      'Конфигурация RDP недопустима или движок не удалось инициализировать.';

  @override
  String placedCountFilesOnTheRemote(int count) {
    return 'Файлов помещено в удалённый буфер обмена: $count; их можно вставить на удалённой стороне.';
  }

  @override
  String get theCurrentRdpEngineDoesntSupport =>
      'Текущий движок RDP не поддерживает файловый буфер обмена.';

  @override
  String couldntSendFilesMessage(String message) {
    return 'Не удалось отправить файлы: $message';
  }

  @override
  String get couldntStartTheRdpEngineCheck =>
      'Не удалось запустить движок RDP. Проверьте установку клиента.';

  @override
  String get couldntReadTheSelectedFiles =>
      'Не удалось прочитать выбранные файлы.';

  @override
  String get theTargetRdpSessionDoesntHave =>
      'В целевом сеансе RDP файловый буфер обмена не включён или отключён для этого хоста.';

  @override
  String get theTargetRdpSessionDoesntHave2 =>
      'В целевом сеансе RDP текстовый буфер обмена не включён.';

  @override
  String get theRemoteClipboardHasNoFiles =>
      'В удалённом буфере обмена нет файлов для сохранения.';

  @override
  String get anUnsafeFileNameOnThe =>
      'Небезопасное имя файла в удалённом буфере обмена проигнорировано.';

  @override
  String get theRemoteFilesCouldntBeSaved =>
      'Не удалось сохранить удалённые файлы.';

  @override
  String get sshHostsDontHaveRemoteDesktop =>
      'У SSH-хостов нет настроек экрана удалённого рабочего стола.';

  @override
  String get theHostChangedTheResolutionSetting =>
      'Хост изменился; настройка разрешения не сохранена.';

  @override
  String get theHostOrCertificateTrustChanged =>
      'Хост или доверие к сертификату изменились. Переподключитесь.';

  @override
  String get theHostsRdpOptionsWereSaved =>
      'Параметры RDP хоста сохранены более новой версией; настройка разрешения не сохранена.';

  @override
  String get theHostsVncDisplaySettingsWere =>
      'Настройки экрана VNC хоста сохранены более новой версией; настройка разрешения не сохранена.';

  @override
  String get couldntSaveTheCertificate => 'Не удалось сохранить сертификат.';

  @override
  String atMostMaxdrivesRedirectedFolders(int maxDrives) {
    return 'Не более $maxDrives перенаправляемых папок';
  }

  @override
  String atMostMaxusbdevicesUsbDevices(int maxUsbDevices) {
    return 'Не более $maxUsbDevices USB-устройств';
  }

  @override
  String get driveFolderMustBeAnAbsolute =>
      'Папка диска должна быть абсолютным путём';

  @override
  String get driveNameMustBe131 =>
      'Имя диска: 1–31 символ из букв, цифр, пробелов, _ или -';

  @override
  String get monitorLayoutExceedsRdpLimits =>
      'Расположение мониторов превышает ограничения RDP';

  @override
  String get redirectedFolderNamesMustBeUnique =>
      'Имена перенаправляемых папок должны быть уникальными';

  @override
  String get usbDevicesMustBeUniqueVendor =>
      'USB-устройства должны быть уникальными шестнадцатеричными ID vendor:product';

  @override
  String get unsupportedRdpDisplayScale =>
      'Неподдерживаемый масштаб экрана RDP';

  @override
  String get addFolder => 'Добавить папку';

  @override
  String get allPrinters => 'Все принтеры';

  @override
  String get defaultPrinter => 'Принтер по умолчанию';

  @override
  String get displayClipboardAndLocalResources =>
      'Экран, буфер обмена и локальные ресурсы';

  @override
  String get doNotPlay => 'Не воспроизводить';

  @override
  String get eachMonitorCanBeOpenedIn =>
      'Каждый монитор можно открыть в отдельном окне';

  @override
  String get leaveOnRemoteComputer => 'Оставить на удалённом компьютере';

  @override
  String get off2 => 'Выключено';

  @override
  String get onlyDevicesAlreadyUsingTheWinusb =>
      'Только устройства, уже использующие драйвер WinUSB. Драйверы не устанавливаются.';

  @override
  String get playOnThisComputer => 'Воспроизводить на этом компьютере';

  @override
  String get printers => 'Принтеры';

  @override
  String get rdpOptions => 'Параметры RDP';

  @override
  String get redirectedFolders => 'Перенаправляемые папки';

  @override
  String get remoteAudio => 'Удалённый звук';

  @override
  String get remoteDisplayScale => 'Масштаб удалённого экрана';

  @override
  String get removeFolder => 'Удалить папку';

  @override
  String get requiresAMatchingPrinterDriverOn =>
      'На удалённом компьютере нужен подходящий драйвер принтера';

  @override
  String get requiresCameraRedirectionSupportOnThe =>
      'Требуется поддержка перенаправления камеры на сервере';

  @override
  String get resolutionAndLocalScaling =>
      'Разрешение и локальное масштабирование';

  @override
  String get savedRdpOptionsWereWrittenBy =>
      'Сохранённые параметры RDP записаны более новой версией и игнорируются. Сохранение заменит их.';

  @override
  String get usbDevicesVendorProduct => 'USB-устройства (vendor:product)';

  @override
  String get vncDisplay => 'Экран VNC';

  @override
  String get theRemoteDesktopInTheMain =>
      'Удалённый рабочий стол в главном окне закрыт или отключён.';

  @override
  String get remoteDesktop => 'Удалённый рабочий стол';

  @override
  String get closeThisMonitorWindow => 'Закрыть окно этого монитора';

  @override
  String get couldntOpenTheRemoteDesktopWindow =>
      'Не удалось открыть окно удалённого рабочего стола. Вернитесь в главное окно и повторите попытку.';

  @override
  String titleMonitorValuevalueValuevalue2(
    String title,
    int valueValue,
    String valueValue2,
  ) {
    return '$title · монитор $valueValue$valueValue2';
  }

  @override
  String get primary => '(основной)';

  @override
  String aHostCanHaveAtMost2(int maxHostPortForwardProfiles) {
    return 'У хоста может быть не более $maxHostPortForwardProfiles профилей переадресации портов';
  }

  @override
  String get dynamicForwardingDoesNotHaveA =>
      'У динамической переадресации нет фиксированного назначения';

  @override
  String get forwardDestinationHostIsInvalid => 'Недопустимый хост назначения';

  @override
  String get forwardDestinationPortMustBeBetween =>
      'Порт назначения должен быть от 1 до 65535';

  @override
  String get forwardListenerAddressAndPortMust =>
      'Адрес и порт прослушивания должны быть уникальными';

  @override
  String get forwardListenerAddressMustBeLocalhost =>
      'Адрес прослушивания должен быть localhost или IP-адресом';

  @override
  String get forwardListenerPortMustBeBetween =>
      'Порт прослушивания должен быть от 0 до 65535';

  @override
  String get forwardListenersMustBindToLoopback =>
      'Если доступ из сети не подтверждён, слушатель должен быть привязан к loopback';

  @override
  String get forwardProfileIdIsInvalid =>
      'Недопустимый ID профиля переадресации';

  @override
  String get forwardProfileIdsMustBeUnique =>
      'ID профилей переадресации должны быть уникальными';

  @override
  String get forwardProfileNameMustBe1 =>
      'Имя профиля переадресации должно содержать от 1 до 64 символов';

  @override
  String get hostAddressIsRequired => 'Адрес хоста обязателен';

  @override
  String get hostLoginAndAuthenticationSettingsDo =>
      'Настройки входа и аутентификации хоста не совпадают';

  @override
  String get hostNameIsRequired => 'Имя хоста обязательно';

  @override
  String get portMustBeBetween1And => 'Порт должен быть от 1 до 65535';

  @override
  String get rdpCertificateFingerprintMustContain64 =>
      'Отпечаток сертификата RDP должен содержать 64 шестнадцатеричные цифры SHA-256';

  @override
  String get remoteDesktopsUsePasswordLoginWithout =>
      'Удалённые рабочие столы используют вход по паролю без SSH-маршрутов и переадресации';

  @override
  String get remoteForwardingTargetsMustUseThis =>
      'Если доступ из сети не подтверждён, назначение удалённой переадресации должно быть loopback этого устройства';

  @override
  String get unnamedHost => 'Безымянный хост';

  @override
  String get untitledSnippet => 'Сниппет без названия';

  @override
  String get usernameIsRequired => 'Имя пользователя обязательно';

  @override
  String get enterAValidSshPassword => 'Введите действительный пароль SSH';

  @override
  String get enterAValidSshPrivateKey =>
      'Введите действительный закрытый ключ SSH и парольную фразу';

  @override
  String get aPortNumberIsRequiredAfter => 'После -p требуется номер порта';

  @override
  String get aUserNameIsRequiredBefore => 'Перед @ требуется имя пользователя';

  @override
  String get serialFormatConsoleTtyCom3B =>
      'Формат последовательного порта: console tty @COM3 -b 115200';

  @override
  String get invalidHostOrUserNameFormat =>
      'Недопустимый формат хоста или имени пользователя';

  @override
  String get onlyUserHostAndPPort =>
      'Поддерживаются только [пользователь@]хост и -p порт; аргументы оболочки не выполняются';

  @override
  String get dontSpecifyThePortBothIn =>
      'Нельзя указывать порт одновременно в адресе и через -p';

  @override
  String get openLocalConsole => 'Открыть локальную консоль';

  @override
  String formatVerbValuevalueHostPValuevalue2(
    String verb,
    String valueValue,
    int valueValue2,
  ) {
    return 'Формат: $verb $valueValueхост -p $valueValue2';
  }

  @override
  String get baudRateFormatB115200 => 'Формат скорости: -b 115200';

  @override
  String get baudRateMustBe504000000 =>
      'Скорость должна быть в диапазоне 50–4000000 бод';

  @override
  String get thePortCanOnlyBeSpecified => 'Порт можно указать только один раз';

  @override
  String get portMustBe165535 => 'Порт должен быть в диапазоне 1–65535';

  @override
  String get enterAValidSerialPortFor =>
      'Введите допустимый последовательный порт, например console tty @COM3';

  @override
  String connectAddressBaudrateBaud8n1(String address, int baudRate) {
    return 'Подключиться к $address · $baudRate бод · 8N1';
  }

  @override
  String get theActivePaneIsntInThe =>
      'Активная панель не входит в разделение.';

  @override
  String get invalidWindowSetHostPathOr =>
      'Недопустимый хост, путь или протокол набора окон.';

  @override
  String get theWindowSetHasTooMany => 'В наборе окон слишком много сеансов.';

  @override
  String get invalidWindowSetSplit => 'Недопустимое разделение набора окон.';

  @override
  String get invalidWindowSetList => 'Недопустимый список наборов окон.';

  @override
  String get invalidWindowSetNameOrSession =>
      'Недопустимое имя или сеанс набора окон.';

  @override
  String get windowSetIsNestedTooDeeply =>
      'Слишком глубокая вложенность набора окон.';

  @override
  String get aHostInThisWindowSet =>
      'Хост из этого набора окон больше не существует или его протокол изменился. Удалите набор и сохраните его заново.';

  @override
  String get windowSetDataIsTooLarge => 'Данные набора окон слишком велики.';

  @override
  String get invalidWindowSetCountOrIdentifier =>
      'Недопустимое количество или идентификатор наборов окон.';

  @override
  String get invalidWindowSetFormat => 'Недопустимый формат набора окон.';

  @override
  String get invalidWindowSetNode => 'Недопустимый узел набора окон.';

  @override
  String get invalidWindowSetPaneReference =>
      'Недопустимая ссылка на панель набора окон.';

  @override
  String get invalidWindowSetPane => 'Недопустимая панель набора окон.';

  @override
  String get hostTags => 'Теги хоста';

  @override
  String get addAUserDirectiveBeforeImporting =>
      'Добавьте директиву User, прежде чем импортировать этот хост.';

  @override
  String get commandDirectivesAreNeverExecutedThis =>
      'Директивы команд никогда не выполняются; этот хост не будет импортирован.';

  @override
  String get identityfileIsNotReadOrImported =>
      'IdentityFile не читается и не импортируется. Добавьте ключ отдельно как учётные данные.';

  @override
  String get identityfileNeedsOneValueThisHost =>
      'У IdentityFile должно быть одно значение; этот хост не будет импортирован.';

  @override
  String get theConfigFileExceedsThe1 =>
      'Файл конфигурации превышает лимит импорта в 1 МиБ.';

  @override
  String get theConfigFileHasTooMany =>
      'В файле конфигурации слишком много строк для безопасной проверки.';

  @override
  String get thisDirectiveNeedsExactlyOneValue =>
      'У этой директивы должно быть ровно одно значение.';

  @override
  String get thisValueIsInvalidOrUnsupported =>
      'Значение недопустимо или не поддерживается.';

  @override
  String get atermiusRemoteDesktop => 'Atermius · Удалённый рабочий стол';

  @override
  String get atermiusTerminal => 'Atermius · Терминал';

  @override
  String get atermiusNeedsReliablePersistentBrowserStorage =>
      'Atermius требуется надёжное постоянное хранилище браузера, чтобы безопасно хранить офлайн-данные и синхронизировать вкладки. Используйте браузер с поддержкой OPFS или общего IndexedDB, разрешите этому сайту локальное хранилище в обычном (не приватном) режиме и повторите попытку.';

  @override
  String get chooseAWorkspace => 'Выберите рабочее пространство';

  @override
  String get conflictingWindowRequests => 'Конфликтующие запросы окон.';

  @override
  String get continueLabel => 'Продолжить';

  @override
  String get createOrUnlockAnEncryptedHost =>
      'Создайте или разблокируйте зашифрованный сейф хостов и учётных данных. Без учётной записи, подключения к серверу и синхронизации между устройствами.';

  @override
  String get localProfileStorageIsUnavailableServer =>
      'Хранилище локальных профилей недоступно. Серверный режим можно использовать, если поддерживается его хранилище.';

  @override
  String get localOnlyProfile => 'Только локальный профиль';

  @override
  String get openLocally => 'Открыть локально';

  @override
  String get opening => 'Открытие…';

  @override
  String get serverAccountAndSync => 'Учётная запись сервера и синхронизация';

  @override
  String get serverProfilesSyncEncryptedDataAcross =>
      'Серверные профили синхронизируют зашифрованные данные между устройствами. Локальные профили остаются в этом браузере или на этом устройстве и не синхронизируются.';

  @override
  String get useYourSelfHostedServerAccount =>
      'Используйте учётную запись своего сервера и синхронизируемый сейф.';

  @override
  String get workspaceSwitchCouldNotBeCompleted =>
      'Не удалось завершить переключение рабочего пространства.';

  @override
  String get theSecurityComponentsOrLocalStorage =>
      'Не удалось запустить компоненты безопасности или локальное хранилище. Убедитесь, что файлы развёртывания полные и браузер разрешает этому сайту локальное хранилище, затем повторите попытку.';

  @override
  String get workspaceMenu => 'Меню рабочего пространства';

  @override
  String get workspaceModeSettings => 'Настройки режима рабочего пространства';

  @override
  String get couldntSaveOrSwitchTheWorkspace =>
      'Не удалось сохранить или переключить режим рабочего пространства. Проверьте локальное хранилище и повторите попытку.';

  @override
  String get couldntInitializeTheSecureWorkspace =>
      'Не удалось инициализировать защищённое рабочее пространство';

  @override
  String get couldntOpenTheCloudWorkspaceOr =>
      'Не удалось открыть облачное рабочее пространство или сохранить режим. Проверьте локальное хранилище и повторите попытку.';

  @override
  String get couldntOpenLocalProfileStorageAllow =>
      'Не удалось открыть хранилище локальных профилей. Разрешите этому сайту постоянное хранилище и повторите попытку.';

  @override
  String get couldntVerifyTheSeparateWindowTry =>
      'Не удалось проверить отдельное окно. Повторите попытку из исходного окна.';

  @override
  String get aLocalStorageWriteWasInterrupted =>
      'Запись в локальное хранилище была прервана. Освободите место, закройте другие вкладки Atermius этого сайта, затем перезагрузите страницу для восстановления и повторите попытку.';

  @override
  String get preparingSecureWorkspace =>
      'Подготовка защищённого рабочего пространства';

  @override
  String get checkingLocalEncryptedStorage =>
      'Проверка локального зашифрованного хранилища.';

  @override
  String get reloadPage => 'Перезагрузить страницу';

  @override
  String get retry => 'Повторить';

  @override
  String get supportedBrowserStorageRequired =>
      'Требуется поддерживаемое хранилище браузера';

  @override
  String get supportedBrowserStorageIsRequiredCheck =>
      'Требуется поддерживаемое хранилище браузера. Проверьте разрешение на постоянное хранилище и повторите попытку.';

  @override
  String get someFileWindowsArentUnlockedAre =>
      'Некоторые окна файлов ещё не разблокированы, переключаются или их положение не готово; подождите и сохраните снова.';

  @override
  String theRemotePathIsntARegular(String path) {
    return 'Удалённый путь не является обычным файлом: $path';
  }

  @override
  String get scpFileListingRequiresTheSftp =>
      'Для списка файлов SCP нужен канал каталогов SFTP этого SSH-соединения. Проверьте, включён ли SFTP на сервере.';

  @override
  String get theFileActionFailedCheckThe =>
      'Действие с файлом не выполнено. Проверьте подключение SSH/SFTP и права на папку.';

  @override
  String get invalidRemoteFolderPath => 'Недопустимый путь к удалённой папке.';

  @override
  String get theSshSftpSessionIsClosed => 'Сеанс SSH/SFTP закрыт.';

  @override
  String get onlyRegularFilesCanBeDownloaded =>
      'Скачивать можно только обычные файлы.';

  @override
  String get onlySizeBoundedRegularFilesCan =>
      'Потоком можно скачивать только обычные файлы ограниченного размера.';

  @override
  String get invalidFileNameFormat => 'Недопустимый формат имени файла.';

  @override
  String get theFileExceedsThisPlatformsSftp =>
      'Файл превышает лимит размера отправки по SFTP на этой платформе.';

  @override
  String couldntSafelyCreateTheRemoteFile(Object error) {
    return 'Не удалось безопасно создать удалённый файл. Возможно, он уже существует или у текущего пользователя нет прав на запись; существующие файлы не перезаписываются. ($error)';
  }

  @override
  String get invalidFolderNameFormat2 => 'Недопустимый формат имени папки.';

  @override
  String get invalidRemoteFileNameFormat2 =>
      'Недопустимый формат имени удалённого файла.';

  @override
  String get theRemoteFileExceedsTheLocal =>
      'Удалённый файл превышает лимит размера локального скачивания.';

  @override
  String get theRemoteFileExceedsTheStreaming =>
      'Удалённый файл превышает лимит размера потокового скачивания.';

  @override
  String get theRemotePathIsntASize =>
      'Удалённый путь не является обычным файлом ограниченного размера.';

  @override
  String get theRemotePathIsntARegular2 =>
      'Удалённый путь не является обычным файлом.';

  @override
  String get theRemotePathIsNoLonger =>
      'Удалённый путь больше не является обычным файлом.';

  @override
  String get anotherForwardAlreadyUsesThisListener =>
      'Другая переадресация уже использует этот адрес и порт прослушивания.';

  @override
  String get couldNotStartThisForwardCheck =>
      'Не удалось запустить переадресацию. Проверьте доступность порта и политику переадресации SSH-сервера.';

  @override
  String get forwardStartWasCancelled => 'Запуск переадресации отменён.';

  @override
  String get sshConnectionClosedWhileForwardingWas =>
      'SSH-соединение закрылось во время запуска переадресации';

  @override
  String get sshPortForwardingIsUnavailableHere =>
      'Здесь переадресация портов SSH недоступна.';

  @override
  String get sshPortForwardingRuntimeIsUnavailable =>
      'Среда выполнения переадресации портов SSH недоступна на этой платформе.';

  @override
  String get theSshConnectionForThisForward =>
      'SSH-соединение этой переадресации завершено. Сначала переподключитесь.';

  @override
  String get theForwardProfileIsInvalid =>
      'Профиль переадресации недействителен.';

  @override
  String get theForwardStoppedUnexpectedly =>
      'Переадресация неожиданно остановилась.';

  @override
  String get thisSshPortForwardProfileIs =>
      'Этот профиль переадресации портов SSH уже активен.';

  @override
  String addressBindaddressIsNotAvailableOn(String bindAddress) {
    return 'Адрес $bindAddress недоступен на этом устройстве.';
  }

  @override
  String connectionLimitSshportforwardmaxconnectionsReachedNewClients(
    int sshPortForwardMaxConnections,
  ) {
    return 'Достигнут лимит подключений ($sshPortForwardMaxConnections); новые клиенты отклоняются, пока не закроются другие.';
  }

  @override
  String couldNotOpenAnSshChannel(String target) {
    return 'Не удалось открыть SSH-канал к $target.';
  }

  @override
  String portEndpointIsAlreadyInUse(String endpoint) {
    return 'Порт $endpoint на этом устройстве уже используется.';
  }

  @override
  String get theSshConnectionIsNoLonger => 'SSH-соединение больше недоступно.';

  @override
  String theSshServerCouldNotConnect(String target) {
    return 'SSH-серверу не удалось подключиться к $target.';
  }

  @override
  String theSshServerDeniedForwardingTo(String target) {
    return 'SSH-сервер запретил переадресацию на $target (запрещено администратором).';
  }

  @override
  String get theSshServerDidNotAnswer =>
      'SSH-сервер вовремя не ответил на запрос удалённой переадресации. Запоздавший слушатель будет отменён; если сервер не подтвердит, отключитесь и переподключитесь.';

  @override
  String get theSshServerDidNotConfirm =>
      'SSH-сервер не подтвердил удаление удалённой переадресации.';

  @override
  String get theSshServerIsOutOf =>
      'У SSH-сервера недостаточно ресурсов для новых каналов.';

  @override
  String theSshServerRefusedAChannel(String target) {
    return 'SSH-сервер отказал в канале к $target.';
  }

  @override
  String get theDeviceSocksListenerStoppedUnexpectedly =>
      'SOCKS-слушатель на устройстве неожиданно остановился.';

  @override
  String get theDeviceListenerStoppedUnexpectedly =>
      'Слушатель на устройстве неожиданно остановился.';

  @override
  String thisDeviceCouldNotListenOn(String endpoint) {
    return 'Устройство не смогло слушать $endpoint.';
  }

  @override
  String thisDeviceRefusedToListenOn(String endpoint) {
    return 'Устройство отказалось слушать $endpoint (нет прав; низкие или зарезервированные порты могут быть заблокированы).';
  }

  @override
  String timedOutOpeningAnSshChannel(String target) {
    return 'Истекло время открытия SSH-канала к $target.';
  }

  @override
  String get thisBrowserBuildCannotOpenTcp =>
      'Эта веб-сборка не может открывать TCP-слушатели и исходящие сокеты, поэтому переадресация портов SSH здесь не работает. Профили по-прежнему синхронизируются для настольных и мобильных приложений.';

  @override
  String get theSshRelayOriginDoesntMatch =>
      'Источник SSH-ретранслятора не совпадает с настройками сервера. Попросите администратора проверить публичный адрес сайта.';

  @override
  String get theSshRelayTargetMustBe =>
      'Целью SSH-ретранслятора должен быть допустимый IP-адрес и порт; ретранслятор сервера не принимает DNS-имена.';

  @override
  String get theSshRelayTicketExpiredStart =>
      'Билет SSH-ретранслятора истёк. Подключитесь заново.';

  @override
  String get tooManySshRelayRequestsTry =>
      'Слишком много запросов к SSH-ретранслятору. Повторите попытку позже.';

  @override
  String get theSshRelayConnectionTimedOut =>
      'Истекло время ожидания подключения к SSH-ретранслятору. Проверьте доступность сервера, сеть и целевой адрес.';

  @override
  String get theSshHostKeyDiffersFrom =>
      'Ключ SSH-хоста отличается от сохранённого отпечатка, подключение отклонено. Сверьте новый отпечаток по доверенному каналу, прежде чем обновлять доверие.';

  @override
  String get sshHostKeyVerificationFailedThe =>
      'Проверка ключа SSH-хоста не пройдена, подключение отклонено. Проверьте идентичность сервера и путь подключения.';

  @override
  String get sshAuthenticatedButTheTerminalSession =>
      'Аутентификация SSH пройдена, но открыть сеанс терминала не удалось.';

  @override
  String get sshHandshakeFailedCheckTheSsh =>
      'Ошибка SSH-рукопожатия. Проверьте SSH-сервер и подключение к ретранслятору.';

  @override
  String get theSshPrivateKeyCouldntBe =>
      'Не удалось разобрать закрытый ключ SSH или неверна парольная фраза. Проверьте формат ключа и фразу.';

  @override
  String get theSshNetworkConnectionWasInterrupted =>
      'Сетевое SSH-соединение прервано. Проверьте ретранслятор и целевой сервер.';

  @override
  String get sshAuthenticationFailedCheckTheUser =>
      'Ошибка аутентификации SSH. Проверьте имя пользователя, пароль или закрытый ключ.';

  @override
  String get theSshConnectionDroppedBeforeAuthentication =>
      'SSH-соединение прервалось до завершения аутентификации. Проверьте сеть и сервер и повторите попытку.';

  @override
  String get theUntrustedSshHostKeyWas =>
      'Недоверенный ключ SSH-хоста отклонён, подключение отменено.';

  @override
  String get couldntEstablishTheSshRelayWebsocket =>
      'Не удалось установить WebSocket SSH-ретранслятора. Проверьте адрес HTTPS/WSS экземпляра, настройки источника ретранслятора и сеть, затем повторите попытку.';

  @override
  String get theServerRelayPolicyRejectedThis =>
      'Политика ретрансляции сервера отклонила этот адрес или порт. Попросите администратора проверить список разрешённых SSH-целей.';

  @override
  String get theServerHasntEnabledTheSsh =>
      'На сервере не включён SSH-ретранслятор. Попросите администратора настроить ретранслятор и целевые сети.';

  @override
  String get localStorageNeedsRecoveryReadingEditing2 =>
      'Локальное хранилище требует восстановления. Чтение, правка и синхронизация этой базы данных приостановлены; закройте все вкладки Atermius и откройте снова, чтобы восстановить последние сохранённые данные.';

  @override
  String get invalidWindowSetPreferenceFormat =>
      'Недопустимый формат настройки наборов окон.';

  @override
  String get invalidStagedMigrationCiphertextContext =>
      'Недопустимый контекст подготовленного шифротекста миграции.';

  @override
  String get invalidStagedMigrationCiphertextFormat =>
      'Недопустимый формат подготовленного шифротекста миграции.';

  @override
  String get theServerHasntConfirmedAllMigration =>
      'Сервер ещё не подтвердил все записи миграции.';

  @override
  String get theMigrationJournalContainsDuplicateOperation =>
      'Журнал миграции содержит повторяющиеся ID операций.';

  @override
  String get theMigrationDestinationOutboxDoesntMatch =>
      'Очередь отправки назначения миграции не соответствует подготовленному шифротексту.';

  @override
  String get theMigrationDestinationOutboxDoesntMatch2 =>
      'Очередь отправки назначения миграции не соответствует журналу подготовки.';

  @override
  String get aStagedRecordInTheMigration =>
      'Подготовленная запись в назначении миграции удалена.';

  @override
  String get theMigrationDestinationContainsDuplicateRecord =>
      'Назначение миграции содержит повторяющиеся головы записей.';

  @override
  String get theMigrationDestinationRecordDoesntMatch =>
      'Запись назначения миграции не соответствует подготовленному шифротексту.';

  @override
  String get theMigrationRecordStillHasUnconfirmed =>
      'У записи миграции ещё есть неподтверждённые операции в очереди отправки.';

  @override
  String get recycleBinSnapshotExpiredBeforeIt =>
      'Срок снимка корзины истёк до его чтения.';

  @override
  String get snapshotExpiredBeforeRecoveryCouldStart =>
      'Срок снимка истёк до начала восстановления.';

  @override
  String get theServerGenerationChangedSynchronizeBefore =>
      'Поколение сервера изменилось; синхронизируйте перед восстановлением.';

  @override
  String itemExitItem2(Object item, Object item2) {
    return '$item · код выхода $item2';
  }

  @override
  String get addThisAccountInYourAuthenticator =>
      'Добавьте эту учётную запись в приложение-аутентификатор и введите текущий шестизначный код. Секрет настройки временный и никогда не сохраняется этим клиентом.';

  @override
  String get authenticatorCode => 'Код из приложения-аутентификатора';

  @override
  String get disableMfa => 'Отключить MFA';

  @override
  String get disableTwoFactorSignIn => 'Отключить двухфакторный вход';

  @override
  String get disabled => 'Отключено';

  @override
  String get eachCodeCanBeUsedOnce =>
      'Если вы потеряете доступ к аутентификатору, каждый код можно использовать один раз. Сохраните их в менеджере паролей или другом надёжном месте. Полностью коды показываются только сейчас; этот клиент их не сохраняет и не копирует.';

  @override
  String get enabled => 'Включено';

  @override
  String get enterExactlySixDigits => 'Введите ровно шесть цифр.';

  @override
  String get enterYourCurrentPasswordAndAuthenticator =>
      'Введите текущий пароль и код аутентификатора.';

  @override
  String get iSavedTheseCodesSecurely => 'Я надёжно сохранил(а) эти коды';

  @override
  String get mfaRecoveryCodesWereRotated =>
      'Коды восстановления MFA обновлены.';

  @override
  String mfaRecoveryCodesFormattedcodes(String formattedCodes) {
    return 'Коды восстановления MFA: $formattedCodes';
  }

  @override
  String get newRecoveryCodesWereGeneratedBut =>
      'Новые коды восстановления созданы, но их сохранение не подтверждено. Обновите ещё раз, чтобы показать новый набор.';

  @override
  String get provisioningUri => 'URI для настройки';

  @override
  String get refreshMfaStatus => 'Обновить статус MFA';

  @override
  String get rotateMfaRecoveryCodes => 'Обновить коды восстановления MFA';

  @override
  String get rotateCodes => 'Обновить коды';

  @override
  String get rotateRecoveryCodes => 'Обновить коды восстановления';

  @override
  String get saveYourMfaRecoveryCodes => 'Сохраните коды восстановления MFA';

  @override
  String get setUpAuthenticator => 'Настроить аутентификатор';

  @override
  String get setUpAuthenticatorApp => 'Настроить приложение-аутентификатор';

  @override
  String setupExpiresTolocal(DateTime toLocal) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return 'Настройка истекает $toLocalString.';
  }

  @override
  String get setupSecret => 'Секрет настройки';

  @override
  String totpProvisioningUriProvisioninguri(String provisioningUri) {
    return 'URI настройки TOTP: $provisioningUri';
  }

  @override
  String totpSetupSecretSecret(String secret) {
    return 'Секрет настройки TOTP: $secret';
  }

  @override
  String get theLastRecoveryCodesWereNot =>
      'Сохранение последних кодов восстановления не подтверждено. Обновите коды, чтобы показать новый набор.';

  @override
  String get twoFactorSignIn => 'Двухфакторный вход';

  @override
  String get useAnAuthenticatorAppOrA =>
      'Используйте приложение-аутентификатор или одноразовый код восстановления как второй фактор входа. Сервер хранит seed TOTP в зашифрованном виде; клиент держит секреты настройки и коды восстановления только на время показа.';

  @override
  String get verifyAndEnable => 'Проверить и включить';

  @override
  String get youWillBeAbleToSign =>
      'Вы сможете входить только с мастер-паролем. Аутентификатор и неиспользованные коды восстановления перестанут работать.';

  @override
  String valuevalueRecoveryCodesRemaining(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: 'Осталось $valueValue кода восстановления.',
      many: 'Осталось $valueValue кодов восстановления.',
      few: 'Осталось $valueValue кода восстановления.',
      one: 'Остался $valueValue код восстановления.',
    );
    return '$_temp0';
  }

  @override
  String get aHostChangedAfterThePreview =>
      'После предпросмотра хост изменился. Откройте импорт заново и проверьте последнюю версию.';

  @override
  String get aHostWithThisNameWas =>
      'Во время проверки сохранён хост с таким же именем. Откройте импорт заново, чтобы сравнить.';

  @override
  String get applyTheseInventoryChanges => 'Применить эти изменения инвентаря?';

  @override
  String applyCountChanges(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Применить $count изменения',
      many: 'Применить $count изменений',
      few: 'Применить $count изменения',
      one: 'Применить $count изменение',
    );
    return '$_temp0';
  }

  @override
  String applyCountReviewedChangeSTo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Применить $count проверенного изменения',
      many: 'Применить $count проверенных изменений',
      few: 'Применить $count проверенных изменения',
      one: 'Применить $count проверенное изменение',
    );
    return '$_temp0 к зашифрованным записям хостов в активном сейфе. Отсутствующие записи будут только помечены устаревшими; хосты не удаляются. Группы Ansible сохраняются как теги хостов. Учётные данные не импортируются, инвентарь и SSH-команды не выполняются.';
  }

  @override
  String get chooseInventoryFile => 'Выбрать файл инвентаря';

  @override
  String get confirmChanges => 'Подтвердить изменения';

  @override
  String get createANewSource => 'Создать новый источник';

  @override
  String get importAnsibleInventory => 'Импорт инвентаря Ansible';

  @override
  String get inventory => 'Инвентарь';

  @override
  String get inventoryFile => 'Файл инвентаря';

  @override
  String get inventoryFilesAreLimitedTo1 => 'Файлы инвентаря ограничены 1 МиБ.';

  @override
  String get inventorySource => 'Источник инвентаря';

  @override
  String get inventorySourcesAreLimitedTo1 =>
      'Источники инвентаря ограничены 1 МиБ.';

  @override
  String get keepManual => 'Оставить ручную правку';

  @override
  String get markStaleKeepThisHostSaved =>
      'Пометить устаревшим; сохранить хост';

  @override
  String get noHostsWereImportedTheVault =>
      'Хосты не импортированы. Возможно, сейф изменился или хост не удалось сохранить.';

  @override
  String get noConcreteHostCandidatesWereFound =>
      'Конкретные хосты-кандидаты не найдены.';

  @override
  String get pasteOrChooseAStaticIni =>
      'Вставьте или выберите статический инвентарь INI/YAML. Динамический инвентарь отклоняется; импорт никогда не запускает скрипты, плагины, Ansible, SSH или сетевые запросы. Импортируются только проверенные поля подключения хостов; учётные данные и закрытые ключи игнорируются.';

  @override
  String get pastedInventory => 'Вставленный инвентарь';

  @override
  String get reviewBlockedThisInventoryCannotBe =>
      'Проверка заблокирована: этот инвентарь нельзя импортировать.';

  @override
  String get reviewEachFieldConflictManualEdits =>
      'Проверьте каждый конфликт полей. По умолчанию ручные правки сохраняются. Отсутствующие записи остаются сохранёнными и помечаются устаревшими только при явном выборе.';

  @override
  String get reviewPastedInventory => 'Проверить вставленный инвентарь';

  @override
  String get savedInEncryptedHostMetadataFile =>
      'Сохраняется в зашифрованных метаданных хоста; пути к файлам не хранятся.';

  @override
  String get sourceLabel => 'Метка источника';

  @override
  String get staticInventoryText => 'Текст статического инвентаря';

  @override
  String get theActiveVaultChangedOrBecame =>
      'Во время импорта активный сейф изменился или стал доступен только для чтения.';

  @override
  String get theActiveVaultChangedOrIs =>
      'Активный сейф изменился или недоступен для записи; проверьте инвентарь снова перед импортом.';

  @override
  String get theInventoryCouldNotBeReviewed =>
      'Не удалось безопасно проверить инвентарь.';

  @override
  String get theSelectedFileCouldNotBe =>
      'Не удалось прочитать выбранный файл.';

  @override
  String get theSelectedFileCouldNotBe2 =>
      'Не удалось проверить выбранный файл.';

  @override
  String get useInventory => 'Использовать инвентарь';

  @override
  String restoreDeadlineFormat2(String format) {
    return ' Срок восстановления: $format.';
  }

  @override
  String get n0Auto => '0 = авто';

  @override
  String get n180UnicodeCharactersUniqueWithout =>
      '1–80 символов Unicode; должно быть уникальным без учёта регистра.';

  @override
  String aHostCanHaveAtMost(int maxHostPortForwardProfiles) {
    return 'У хоста может быть не более $maxHostPortForwardProfiles профилей переадресации портов.';
  }

  @override
  String get aConcurrentChangeWasDetectedYour =>
      'Обнаружено одновременное изменение. Черновики имени, членства и политики сохранены.';

  @override
  String get aNewEncryptedRevisionWillBe =>
      'Будет создана новая зашифрованная версия относительно текущей удалённой головы. Старая ветка остаётся записанной, пока сервер не примет решение.';

  @override
  String get aNewerAtermiusWebBuildIs =>
      'Доступна более новая веб-сборка Atermius.';

  @override
  String get aNewerWebBuildIsAvailable =>
      'Доступна более новая веб-сборка. Когда будет удобно перезагрузить, ознакомьтесь с уведомлением выше.';

  @override
  String aPreviousRepairAlreadySelectedRetainedrepairid(
    String retainedRepairId,
  ) {
    return 'Предыдущее исправление уже выбрало $retainedRepairId. При повторе эту запись нужно сохранить, пока синхронизация не подтвердит метки удаления.';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry(String retainedRecordId) {
    return 'Предыдущее исправление выбрало $retainedRecordId. При повторе эту запись нужно сохранить, пока синхронизация сейфа не подтвердит метки удаления.';
  }

  @override
  String aPreviousRepairSelectedRetainedrecordidRetry2(
    String retainedRecordId,
  ) {
    return 'Предыдущее исправление выбрало $retainedRecordId. При повторе эту запись нужно сохранить, пока синхронизация сейфа не подтвердит метки удаления.';
  }

  @override
  String get aRandomRecoveryCodeEncryptsA =>
      'Случайный код восстановления шифрует отдельную идентичность восстановления. Она хранит запечатанные копии ключей эпох сейфа; ключ учётной записи не является ключом сейфа. Храните код вне этого устройства.';

  @override
  String get aSplitWorkspaceNeedsAtLeast =>
      'Для разделённого рабочего пространства нужно не менее двух панелей';

  @override
  String get aUsersEffectiveRelayAccessAlso =>
      'Фактический доступ пользователя к Relay также ограничивается политикой его учётной записи, всеми остальными серверными группами и ограничениями развёртывания.';

  @override
  String get active => 'АКТИВНО';

  @override
  String get apiEndpoint => 'Конечная точка API';

  @override
  String get acceptVaultInvitation => 'Принять приглашение в сейф';

  @override
  String get acceptAndUnlockVault => 'Принять и разблокировать сейф';

  @override
  String get acceptInvitation => 'Принять приглашение';

  @override
  String get acceptedByAdapter7UtcDays => 'Принято адаптером (7 дней UTC)';

  @override
  String get accessExpires => 'Доступ истекает';

  @override
  String get account => 'Учётная запись';

  @override
  String get accountDevice => 'Учётная запись и устройство';

  @override
  String get accountId => 'ID учётной записи';

  @override
  String get accountRelayPolicy => 'Политика Relay учётной записи';

  @override
  String get accountRelayPolicySaveFailed =>
      'Не удалось сохранить политику Relay учётной записи';

  @override
  String get accountDeletion => 'Удаление учётной записи';

  @override
  String get accountDeletionImmediatelyRevokesAllSessions =>
      'Удаление учётной записи сразу отзывает все сеансы и устройства. В срок, установленный сервером, личные сейфы и данные учётной записи удаляются; ваше членство и доступ к ключам чужих сейфов прекращаются. Данные общих сейфов других участников не удаляются. Владелец общего сейфа, в котором есть другие активные или приглашённые участники, должен сначала решить вопрос с членством.';

  @override
  String get accountDeletionScheduledByTheServer =>
      'Сервер запланировал удаление учётной записи.';

  @override
  String accountDeletionScheduledServerPurgeAfter(
    Object accountDeletionPurgeAfter,
  ) {
    return 'Удаление учётной записи запланировано. purge_after на сервере: $accountDeletionPurgeAfter.';
  }

  @override
  String get accountDevices => 'Устройства учётной записи';

  @override
  String get accountInvitationCreated => 'Приглашение в учётную запись создано';

  @override
  String get accountInvitations => 'Приглашения в учётную запись';

  @override
  String get accountRecovery => 'Восстановление учётной записи';

  @override
  String accountRecoveryCodeCode(String code) {
    return 'Код восстановления учётной записи: $code';
  }

  @override
  String get accountRecoveryWasDisabled =>
      'Восстановление учётной записи отключено.';

  @override
  String accountRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return 'Версия учётной записи $revision · обновлено $formatTime';
  }

  @override
  String get accountSessions => 'Сеансы учётной записи';

  @override
  String get accounts => 'Учётные записи';

  @override
  String actionsForFilename(String filename) {
    return 'Действия для $filename';
  }

  @override
  String get active2 => 'Активен';

  @override
  String activePaneValuevalue(int valueValue) {
    return 'Активная панель $valueValue';
  }

  @override
  String get activeAccountOnCurrentPage =>
      'Активная учётная запись на текущей странице';

  @override
  String get activeDevices => 'Активные устройства';

  @override
  String get activePane => 'Активная панель';

  @override
  String get activeSessions => 'Активные сеансы';

  @override
  String get actorDeviceId => 'ID устройства-инициатора';

  @override
  String get actorUserId => 'ID пользователя-инициатора';

  @override
  String get add => 'Добавить';

  @override
  String get addCredentialSecretParameter =>
      'Добавить параметр-секрет учётных данных';

  @override
  String get addAHostFirst => 'Сначала добавьте хост.';

  @override
  String get addAPasswordOrPrivateKey =>
      'Добавьте пароль или закрытый ключ и свяжите его с хостом.';

  @override
  String get addCredential2 => 'Добавить учётные данные';

  @override
  String get addForwardingProfile => 'Добавить профиль переадресации';

  @override
  String get addParameter => 'Добавить параметр';

  @override
  String get addProfile => 'Добавить профиль';

  @override
  String get addThisValueAsTheBearer =>
      'Добавьте это значение как учётные данные Bearer для /api/v1/admin/metrics. Оно не хранится в приложении, и получить его позже нельзя.';

  @override
  String get addYourFirstHost => 'Добавьте первый хост';

  @override
  String get adjustTheSearchOrGroupFilter =>
      'Измените поиск или фильтр группы, чтобы увидеть больше хостов.';

  @override
  String get advanceOnlyAfterEachPageIs =>
      'Переход только после сохранения каждой страницы';

  @override
  String get afterConfirmationThisFingerprintIsSaved =>
      'После подтверждения отпечаток сохраняется как зашифрованная запись в текущем сейфе и синхронизируется на его устройства. Если ключ изменится, клиент отклонит последующие подключения.';

  @override
  String algorithmAlgorithm(String algorithm) {
    return 'Алгоритм: $algorithm';
  }

  @override
  String get allActiveVaultDevicesReportSupport =>
      'Все активные устройства сейфа сообщают о поддержке скрытия данных v1.';

  @override
  String get allowFutureAutomaticPurge =>
      'Разрешить автоматическое удаление в будущем?';

  @override
  String get allowFuturePurge => 'Разрешить удаление в будущем';

  @override
  String get allowedCidrNetworks => 'Разрешённые сети CIDR';

  @override
  String get allowedCidrsOnePerLine => 'Разрешённые CIDR (по одному в строке)';

  @override
  String get allowedPorts => 'Разрешённые порты';

  @override
  String anEncryptedVaultArchiveCoveringPendingcount(int pendingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingCount,
      locale: localeName,
      other:
          'Недавно экспортирован зашифрованный архив сейфа с $pendingCount ожидающей операции.',
      many:
          'Недавно экспортирован зашифрованный архив сейфа с $pendingCount ожидающими операциями.',
      few:
          'Недавно экспортирован зашифрованный архив сейфа с $pendingCount ожидающими операциями.',
      one:
          'Недавно экспортирован зашифрованный архив сейфа с $pendingCount ожидающей операцией.',
    );
    return '$_temp0 Очередь отправки хранится локально и синхронизируется после перезагрузки.';
  }

  @override
  String get anonymousDiagnostics => 'Анонимная диагностика';

  @override
  String get anonymousSyncDiagnosticsExported =>
      'Анонимная диагностика синхронизации экспортирована.';

  @override
  String appliedAppliedInventoryChangeSHost(int applied) {
    return 'Применено изменений инвентаря: $applied; записи хостов зашифрованы и поставлены в очередь синхронизации.';
  }

  @override
  String get applyWebUpdate => 'Применить веб-обновление?';

  @override
  String get approvalJsonCopied => 'JSON одобрения скопирован.';

  @override
  String get approveSealKeys => 'Одобрить и запечатать ключи';

  @override
  String get approveEnrollment => 'Одобрить регистрацию';

  @override
  String approveValuevalue(Object valueValue) {
    return 'Одобрить $valueValue?';
  }

  @override
  String get archiveBytes => 'Размер архива в байтах';

  @override
  String get archivePassword => 'Пароль архива';

  @override
  String get archiveSaveWasCanceled => 'Сохранение архива отменено.';

  @override
  String get argumentsJsonArray2 => 'Аргументы (массив JSON)';

  @override
  String get askTheServerOperatorToConfigure =>
      'Перед включением расписания попросите оператора сервера настроить место назначения и ключ зашифрованных резервных копий.';

  @override
  String get atLeast12CharactersIndependentFrom =>
      'Не менее 12 символов. Не связан с паролем учётной записи.';

  @override
  String get atTheDeadlineTheServerPurges =>
      'В установленный срок сервер удаляет записи, историю, конфликты, снимки, зашифрованные объекты, членство и конверты ключей этого сейфа. Существующие локальные и офлайн-копии и резервные копии хранятся отдельно; удалённо стереть их это действие не может.';

  @override
  String get atTheServerDeadlineRecordsHistory =>
      'В срок, установленный сервером, удаляются записи, история, конфликты, снимки, зашифрованные объекты и конверты ключей. Офлайн-копии и сохранённые резервные копии хранятся отдельно и удалённо не стираются.';

  @override
  String get atermiusWillKeepThisPageAnd =>
      'Atermius оставит страницу и SSH-сеансы открытыми, пока вы не выполните шаги ниже и не подтвердите перезагрузку.';

  @override
  String get atermiusWillReloadThisPageTo =>
      'Atermius перезагрузит страницу, чтобы загрузить более новую веб-сборку с вашего сервера. Страница не переключится без подтверждения.';

  @override
  String get attemptedAt => 'Попытка';

  @override
  String get auditLog2 => 'Журнал аудита';

  @override
  String get automaticPurgeConsentRecordedForThis =>
      'Согласие на автоматическое удаление записано для этой метки удаления. Ограниченное обслуживание может удалить её после срока восстановления и других обязательных проверок; включение согласия не удаляет её сразу. Офлайн-копии на устройствах и экспорты не удаляются.';

  @override
  String automaticPurgeConsentValuevalue(String valueValue) {
    return 'Согласие на автоматическое удаление: $valueValue';
  }

  @override
  String get back => 'Назад';

  @override
  String get backgroundSyncNotifications => 'Уведомления фоновой синхронизации';

  @override
  String backupBucketAccessCheckResultNotice(String notice) {
    return 'Результат проверки доступа к бакету резервных копий: $notice';
  }

  @override
  String get backupCommandFailed =>
      'Команда резервного копирования не выполнена';

  @override
  String baseRevisionShortauditidCurrentHeadShortauditid2(
    String shortAuditId,
    String shortAuditId2,
  ) {
    return 'Базовая версия: $shortAuditId · текущая голова: $shortAuditId2';
  }

  @override
  String get bashNonInteractiveExecution => 'Неинтерактивное выполнение Bash';

  @override
  String get bashNonInteractiveExecutionRequiresA =>
      'Неинтерактивное выполнение Bash · нужны POSIX-совместимая оболочка входа и Bash';

  @override
  String get bashOnlyEachArgvItemIs =>
      'Только Bash. Каждый элемент argv — литерал или ссылка на параметр и заключается в кавычки как одно слово оболочки.';

  @override
  String get batchCommandExecution => 'Пакетное выполнение команд';

  @override
  String bindingsAreEncryptedInCurrentvaultnameAnd(String currentVaultName) {
    return 'Привязки зашифрованы в $currentVaultName и синхронизируются на устройства с доступом к сейфу.';
  }

  @override
  String get bindingsSyncAsSemanticActionsMod =>
      'Привязки синхронизируются как смысловые действия. «mod» локально означает Command на платформах Apple и Control на остальных. Сочетание срабатывает только при фокусе на вводе терминала; поле поиска сохраняет обычное поведение текста и клавиатуры.';

  @override
  String get bothRevisionsStayEncryptedInLocal =>
      'Обе версии хранятся зашифрованными в локальном хранилище. Выберите ветку, которая станет новой версией на основе текущей удалённой головы.';

  @override
  String branchShortauditid(String shortAuditId) {
    return 'Ветка $shortAuditId';
  }

  @override
  String get browseFiles2 => 'Обзор файлов';

  @override
  String browseFilesOnValuevalue(String valueValue) {
    return 'Обзор файлов на $valueValue';
  }

  @override
  String get byApprovingThisActiveMemberDevice =>
      'После одобрения это активное устройство участника отправит запечатанные конверты ключей для каждого доступного ему сейфа и эпохи ключей. Сверьте запрос и идентичность устройства с владельцем нового браузера.';

  @override
  String get conflictConnectionsBlocked =>
      'КОНФЛИКТ — ПОДКЛЮЧЕНИЯ ЗАБЛОКИРОВАНЫ';

  @override
  String get currentVault => 'ТЕКУЩИЙ СЕЙФ';

  @override
  String get cancelBatch => 'Отменить пакет';

  @override
  String get cancelDeletion => 'Отменить удаление';

  @override
  String get cancelExecution => 'Отменить выполнение';

  @override
  String get cancelScheduledDeletion => 'Отменить запланированное удаление?';

  @override
  String cancelThePendingDeletionForVaultname(
    String vaultName,
    String vaultLifecycleDate,
  ) {
    return 'Отменить ожидающее удаление $vaultName? Запись на сервер снова станет доступна, и зашифрованная очередь отправки сможет продолжить синхронизацию. Отменить можно только до $vaultLifecycleDate.';
  }

  @override
  String get cancellationRequestedTheActiveCommandMay =>
      'Запрошена отмена. Текущая команда могла уже начаться; на следующих хостах она не запустится.';

  @override
  String get cancellationRequestedTheCommandMayAlready =>
      'Запрошена отмена. Команда могла уже начаться; повтора не будет.';

  @override
  String get capabilities => 'Возможности';

  @override
  String get changeMasterPassword => 'Сменить мастер-пароль';

  @override
  String changeToRole(String role) {
    return 'Изменить на $role';
  }

  @override
  String changeUsernameFromItemToRole(
    String username,
    Object item,
    String role,
  ) {
    return 'Изменить роль $username с $item на $role? Будет подписана новая версия членства, а ключ сейфа сменится для всех оставшихся активных устройств участников. Ожидающие токены приглашений станут недействительными, и их нужно будет выдать заново. Старые копии ключа удалённо стереть нельзя.';
  }

  @override
  String get changingPassword => 'Смена пароля…';

  @override
  String get checkBucketAccess => 'Проверить доступ к бакету';

  @override
  String get checkForUpdates => 'Проверить обновления';

  @override
  String get checkingConfiguredBucketAccessWithHeadbucket =>
      'Проверка доступа к настроенному бакету с помощью HeadBucket…';

  @override
  String get checkingOnlineDevices => 'Проверка устройств в сети…';

  @override
  String get checkingThisSelfHostedInstanceFor =>
      'Проверка новой веб-сборки на вашем экземпляре…';

  @override
  String get choose2575 => 'Выберите от 25 до 75';

  @override
  String get chooseConnectOnTheLeftTo =>
      'Нажмите «Подключить» слева, чтобы начать новый сеанс.';

  @override
  String get chooseAHost => 'Выберите хост';

  @override
  String chooseAHostForPaneValuevalue(int valueValue) {
    return 'Выберите хост для панели $valueValue';
  }

  @override
  String get chooseAHostFromTheActive =>
      'Выберите хост из активного сейфа. Замена сохраняется как зашифрованное обновление макета; подключение не выполняется.';

  @override
  String get chooseAHostOnTheLeft =>
      'Выберите хост слева, чтобы начать SSH-сеанс.';

  @override
  String get chooseALocalEncryptedArchiveOr =>
      'Выберите локальный зашифрованный архив или его удалённую реплику, чтобы подготовить отдельную копию без остановки службы. Удалённые данные проверяются по дайджесту и аутентификации архива перед публикацией. Действие не активирует копию и не заменяет рабочие данные; последующее переключение офлайн выполняет оператор.';

  @override
  String get chooseALocalEncryptedArchiveTo =>
      'Выберите локальный зашифрованный архив, чтобы подготовить отдельную копию без остановки службы. Перед публикацией архив проверяется повторно. Действие не активирует копию и не заменяет рабочие данные; последующее переключение офлайн выполняет оператор.';

  @override
  String get chooseANewMasterPasswordDifferent =>
      'Выберите новый мастер-пароль, отличный от текущего.';

  @override
  String get chooseASourceForEachChanged =>
      'Выберите источник для каждого изменённого поля. Ветка конфликта — это проверенная отклонённая версия; текущая версия сейфа — зафиксированная головная.';

  @override
  String get chooseActiveVaultDevicesThatMay =>
      'Выберите активные устройства сейфа, которые смогут наблюдать зашифрованный вывод терминала. Наблюдатели не могут вводить текст или менять размер терминала хоста. Список фиксируется на весь сеанс; устройство получает только вывод после подключения, без воспроизведения прежней истории.';

  @override
  String get chooseConnectedHosts => 'Выберите подключённые хосты';

  @override
  String get chooseHowOftenThisServerCreates =>
      'Выберите, как часто сервер создаёт зашифрованную резервную копию. Место хранения архива и ключ шифрования остаются закрытыми на сервере.';

  @override
  String get chooseOneDeviceAlreadyApprovedFor =>
      'Выберите одно устройство, уже одобренное для этого доступа. Оно сможет вводить в этот SSH-сеанс до пяти минут; само SSH-соединение остаётся на этом устройстве.';

  @override
  String get chooseTheDefaultPreferenceRecordTo =>
      'Выберите запись настройки по умолчанию, которую нужно сохранить';

  @override
  String get chooseTheDefaultWorkspaceSectionFor =>
      'Выберите раздел рабочего пространства по умолчанию для активного сейфа. Настройка шифруется перед синхронизацией на устройства с доступом к сейфу.';

  @override
  String get chooseTheShortcutPreferenceRecordTo =>
      'Выберите запись настроек сочетаний, которую нужно сохранить';

  @override
  String get chooseTheTerminalFontSizeRecord =>
      'Выберите запись размера шрифта терминала, которую нужно сохранить';

  @override
  String get chooseTheTerminalPaletteSharedBy =>
      'Выберите палитру терминала, общую для всех устройств с доступом к этому сейфу. Выбранная палитра хранится как зашифрованная настройка из разрешённого списка.';

  @override
  String get chooseTheTerminalThemeRecordTo =>
      'Выберите запись темы терминала, которую нужно сохранить';

  @override
  String get cleanupPending => 'Ожидает очистки';

  @override
  String get clearLocalHistoryOnlyRemovesThis =>
      'Очистка локальной истории удаляет только строки на этом устройстве. Записи, уже синхронизированные в сейф, не удаляются.';

  @override
  String get clearThisHostsLocalHistory =>
      'Очистить локальную историю этого хоста';

  @override
  String get closeActiveSshTerminalsBeforeApplying =>
      'Закройте активные SSH-терминалы перед применением обновления.';

  @override
  String get closeSavedLayoutPreview =>
      'Закрыть предпросмотр сохранённого макета';

  @override
  String get color2 => 'Цвет';

  @override
  String get commaOrLineSeparatedPortNumbers =>
      'Номера портов через запятую или с новой строки.';

  @override
  String get commaOrNewlineSeparatedForExample =>
      'Через запятую или с новой строки, например 22, 2222';

  @override
  String get commandHistory => 'История команд';

  @override
  String get commandSnippets => 'Сниппеты команд';

  @override
  String get commandSuggestions => 'Подсказки команд';

  @override
  String get commandsAppearHereAfterTheHook =>
      'Команды появятся здесь после вставки хука и завершения команды.';

  @override
  String get commandsRunOneAtATime =>
      'Команды выполняются по одной. Ошибка, ненулевой код выхода, тайм-аут или неизвестный результат останавливают пакет; команды не повторяются.';

  @override
  String get compareEachValueAndRecordId =>
      'Сравните каждое значение и ID записи. Выбранный ID остаётся активным; остальные записи удаляются с помощью зашифрованных меток удаления.';

  @override
  String get compareThisPublicFingerprintWithAnother =>
      'Сверьте этот открытый отпечаток с другим устройством или доверенным администратором по отдельному каналу, чтобы подтвердить идентичность экземпляра.';

  @override
  String get comparedWithTheLastVerifiedServer =>
      'Сравнивается с последними проверенными метаданными сервера; в офлайне значение может быть устаревшим.';

  @override
  String get compatibilityReportNotReported =>
      'Отчёт о совместимости · не предоставлен';

  @override
  String get compatibilityReportUnverifiedDetailsHidden =>
      'Отчёт о совместимости · не проверен; подробности скрыты';

  @override
  String get completionStatusUnknown => 'Состояние завершения неизвестно';

  @override
  String get concurrentLayoutEditsAreKeptAs =>
      'Параллельные правки макета хранятся как отдельные зашифрованные ветки. Сохранение ветки этого устройства как именованной копии оставляет исходный конфликт открытым; панели не подключаются.';

  @override
  String get confirmAndReAuthenticate =>
      'Подтвердить и пройти аутентификацию повторно';

  @override
  String get confirmAndRun => 'Подтвердить и запустить';

  @override
  String confirmAndRunOnCountHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Подтвердить и запустить на $count хоста',
      many: 'Подтвердить и запустить на $count хостах',
      few: 'Подтвердить и запустить на $count хостах',
      one: 'Подтвердить и запустить на $count хосте',
    );
    return '$_temp0';
  }

  @override
  String get confirmArchivePassword => 'Подтвердите пароль архива';

  @override
  String get confirmNewMasterPassword => 'Подтвердите новый мастер-пароль';

  @override
  String get confirmRevokeInvitation => 'Подтвердить отзыв приглашения';

  @override
  String confirmTargetName(String name) {
    return 'Подтвердите цель: $name';
  }

  @override
  String get conflictBranches => 'Ветки конфликтов';

  @override
  String get conflictResolutionSynced => 'Решение конфликта синхронизировано.';

  @override
  String conflictingSshKeysAreSavedFor(String join) {
    return 'Для $join сохранены конфликтующие SSH-ключи, подключения заблокированы. Отзовите все ключи, которым не собираетесь доверять; если ни один отпечаток не проверен, отзовите оба и одобряйте ключ только после проверки по отдельному каналу.';
  }

  @override
  String get conflictingBranchesArePreservedUntilYou =>
      'Конфликтующие ветки сохраняются, пока вы не выберете версию, которую нужно оставить.';

  @override
  String get connect => 'Подключить';

  @override
  String get connectAnSshHostToBrowse =>
      'Подключитесь к SSH-хосту, чтобы просматривать удалённые файлы.';

  @override
  String connectToNameToOpenAn(String name) {
    return 'Подключитесь к $name, чтобы открыть интерактивную оболочку.';
  }

  @override
  String get connectionSettingsAreKeptAsOne =>
      'Параметры подключения хранятся как единый набор. Проверьте исходную базу и обе проверенные ветки, затем выберите один полный набор. Он включает адрес, порт, имя пользователя SSH, способ аутентификации, выбранные учётные данные, маршрут, прокси, правила переадресации и параметры доверия к хосту.';

  @override
  String get connections => 'Подключения';

  @override
  String connectionsToEndpointUsingAlgorithmWill(
    String endpoint,
    String algorithm,
  ) {
    return 'После синхронизации этого подписанного отзыва подключения к $endpoint с $algorithm будут блокироваться на устройствах. Отпечаток остаётся в истории.';
  }

  @override
  String get consumed => 'Использовано';

  @override
  String get continueToFinalConfirmation =>
      'Перейти к окончательному подтверждению';

  @override
  String get continueToReAuthenticate => 'Продолжить повторную аутентификацию';

  @override
  String get controlActive => 'Управление активно';

  @override
  String get copied => 'Скопировано';

  @override
  String get copiedPasteThisCommandIntoThe =>
      'Скопировано. Вставьте эту команду в терминал:';

  @override
  String get copiesWaiting => 'Копии в ожидании';

  @override
  String get copy => 'Копировать';

  @override
  String get copyCode => 'Копировать код';

  @override
  String get copyCredential => 'Копировать учётные данные';

  @override
  String get copyFailedSelectTheValueManually =>
      'Не удалось скопировать; выделите значение вручную';

  @override
  String get copyInvitationToken => 'Копировать токен приглашения';

  @override
  String get copySignedShareRequest =>
      'Копировать подписанный запрос на доступ';

  @override
  String get copyTerminalShareId => 'Копировать ID общего терминала';

  @override
  String get copyThisOneTimeInvitationToken =>
      'Скопируйте этот одноразовый токен приглашения и передайте его нужному владельцу учётной записи. После закрытия окна он больше не будет показан.';

  @override
  String get copyThisResponseToTheNew =>
      'Скопируйте этот ответ в новый браузер. Он содержит открытые данные идентичности и запечатанные конверты ключей, но не закрытые ключи.';

  @override
  String get copyToken => 'Копировать токен';

  @override
  String get copyingEncryptedArchive => 'Копирование зашифрованного архива';

  @override
  String get couldNotClearThisHostsLocal =>
      'Не удалось очистить локальную историю этого хоста.';

  @override
  String get couldNotConfirmInputControlRevocation =>
      'Не удалось подтвердить отзыв управления вводом. SSH-подключение хоста остаётся активным.';

  @override
  String get couldNotCopyTheSetupCommand =>
      'Не удалось скопировать команду настройки. В удалённую оболочку ничего не отправлено.';

  @override
  String get couldNotEnableVaultHistorySync =>
      'Не удалось включить синхронизацию истории с сейфом. Проверьте, что активный сейф доступен для записи, и повторите попытку.';

  @override
  String get couldNotExportAnonymousSyncDiagnostics =>
      'Не удалось экспортировать анонимную диагностику синхронизации.';

  @override
  String get couldNotGrantInputControlCheck =>
      'Не удалось передать управление вводом. Проверьте сеанс и повторите попытку.';

  @override
  String get couldNotJoinCheckTheSession =>
      'Не удалось присоединиться. Проверьте ID сеанса и доступ к сейфу.';

  @override
  String couldNotLoadTheCurrentHost(String friendlyError) {
    return 'Не удалось загрузить текущий хост: $friendlyError';
  }

  @override
  String get couldNotRemoveThisForwardingProfile =>
      'Не удалось удалить профиль переадресации. Проверьте подключение, синхронизируйте и повторите попытку.';

  @override
  String get couldNotSaveForwardingSettingsSync =>
      'Не удалось сохранить настройки переадресации. Синхронизируйте и повторите попытку; текущие настройки не изменены.';

  @override
  String get couldNotSaveTerminalFontSize =>
      'Не удалось сохранить размер шрифта терминала. Проверьте права записи в сейф и повторите попытку.';

  @override
  String get couldNotSaveTerminalShortcutsCheck =>
      'Не удалось сохранить сочетания клавиш терминала. Проверьте права записи в сейф и повторите попытку.';

  @override
  String get couldNotSaveTerminalThemeCheck =>
      'Не удалось сохранить тему терминала. Проверьте права записи в сейф и повторите попытку.';

  @override
  String couldNotSaveTheReviewedTuple(String friendlyError) {
    return 'Не удалось сохранить проверенный набор: $friendlyError';
  }

  @override
  String get couldNotSaveThisGroupYour =>
      'Не удалось сохранить группу. Изменения остались в форме; проверьте доступ к сейфу и повторите попытку.';

  @override
  String get couldNotSaveThisPreferenceCheck =>
      'Не удалось сохранить настройку. Проверьте права записи в сейф и повторите попытку.';

  @override
  String get couldNotStartOrStopThis =>
      'Не удалось запустить или остановить переадресацию. Проверьте доступность порта и политику переадресации SSH-сервера.';

  @override
  String get couldNotStartTerminalSharingCheck =>
      'Не удалось начать общий доступ к терминалу. Проверьте сейф и сеть и повторите попытку.';

  @override
  String get couldNotTurnOffVaultHistory =>
      'Не удалось отключить синхронизацию истории с сейфом. Повторите попытку.';

  @override
  String get create2 => 'Создать';

  @override
  String get createVault => 'Создать сейф';

  @override
  String get createADedicatedReadOnlyBearer =>
      'Создайте отдельные учётные данные Bearer только для чтения для GET /api/v1/admin/metrics. Секрет показывается один раз и никогда не сохраняется приложением.';

  @override
  String get createAGroupToOrganizeRelated =>
      'Создайте группу, чтобы упорядочить связанные серверы.';

  @override
  String get createAnotherVault => 'Создать ещё один сейф';

  @override
  String get createCredential => 'Создать учётные данные';

  @override
  String get createEncryptedVault => 'Создать зашифрованный сейф';

  @override
  String get createGroup => 'Создать группу';

  @override
  String get createInvitation => 'Создать приглашение';

  @override
  String get createRemoteFolder => 'Создать удалённую папку';

  @override
  String get createResolution => 'Создать решение';

  @override
  String get createSnippet => 'Создать сниппет';

  @override
  String get createSplitWorkspace => 'Создать разделённое рабочее пространство';

  @override
  String get createUsernameBoundInvitationsAndReview =>
      'Создавайте приглашения, привязанные к имени пользователя, и отслеживайте их состояние.';

  @override
  String get createYourFirstGroup => 'Создайте первую группу';

  @override
  String get createYourFirstHostAndAttach =>
      'Создайте первый хост и прикрепите учётные данные SSH, зашифрованные на стороне клиента. Здесь нет примеров или демо-данных.';

  @override
  String get created => 'Создано';

  @override
  String get createdAt => 'Создано';

  @override
  String createdFormattimeUpdatedFormattime2(
    String formatTime,
    String formatTime2,
  ) {
    return 'Создано $formatTime · обновлено $formatTime2';
  }

  @override
  String createdFormat(String format) {
    return 'Создано · $format';
  }

  @override
  String get createsAV2RoomInputStays =>
      'Создаёт комнату v2. Ввод остаётся выключенным, пока вы не выдадите одному одобренному устройству аренду до пяти минут.';

  @override
  String get credential => 'Учётные данные';

  @override
  String credentialActionsName(String name) {
    return 'Действия с учётными данными: $name';
  }

  @override
  String get credentialMergeSavedAndSyncing =>
      'Объединение учётных данных сохранено и синхронизируется';

  @override
  String get credentialName2 => 'Имя учётных данных';

  @override
  String credentialReferenceNameMustPointTo(String name) {
    return 'Ссылка на учётные данные $name должна указывать на парольные учётные данные';
  }

  @override
  String credentialReferenceNameWasNotFound(String name) {
    return 'Ссылка на учётные данные $name не найдена в этом сейфе';
  }

  @override
  String get credentialSelectionProxySettingsForwardingDetails =>
      'Выбор учётных данных, настройки прокси, сведения о переадресации и материалы доверия хоста скрыты; они сохраняются из выбранной ветки.';

  @override
  String get credentialStatus => 'Состояние учётных данных';

  @override
  String get credentialValuesAreSentOnlyThrough =>
      'Значения учётных данных передаются только по зашифрованному каналу SSH exec. Удалённая программа получает их как аргументы и может раскрыть процессам того же удалённого пользователя.';

  @override
  String credentialNameUsernameValuevalue(
    String name,
    String username,
    String valueValue,
  ) {
    return 'Учётные данные: $name; $username; $valueValue';
  }

  @override
  String get currentVault2 => 'Текущий сейф';

  @override
  String get currentAccount => 'Текущая учётная запись';

  @override
  String currentAccountValuevalue(String valueValue) {
    return 'Текущая учётная запись: $valueValue';
  }

  @override
  String get currentDevice => 'Текущее устройство';

  @override
  String currentHeadShortauditid(String shortAuditId) {
    return 'Текущая голова: $shortAuditId';
  }

  @override
  String get currentMasterPassword => 'Текущий мастер-пароль';

  @override
  String get currentSignedInAccountAdministrativeActions =>
      'Текущая учётная запись · действия администратора скрыты';

  @override
  String get cursorPolicy => 'Политика курсора';

  @override
  String get deletionScheduled => 'УДАЛЕНИЕ ЗАПЛАНИРОВАНО';

  @override
  String get deadLettered => 'В очереди недоставленных';

  @override
  String get defaultLabel2 => 'По умолчанию';

  @override
  String get defaultSshCredential => 'Учётные данные SSH по умолчанию';

  @override
  String defaultSectionSectionlabelRecordIdId(
    String sectionLabel,
    String id,
    String revisionLabel,
  ) {
    return 'Раздел по умолчанию: $sectionLabel; ID записи: $id; версия: $revisionLabel';
  }

  @override
  String get defaultWorkspaceSection =>
      'Раздел рабочего пространства по умолчанию';

  @override
  String defaultDefaultvalue(Object defaultValue) {
    return 'По умолчанию: $defaultValue';
  }

  @override
  String get delete2 => 'Удалить';

  @override
  String get deleteForwardingProfile => 'Удалить профиль переадресации';

  @override
  String get deleteGroup3 => 'Удалить группу';

  @override
  String get deleteGroup4 => 'Удалить группу?';

  @override
  String get deleteServerManagedGroup => 'Удалить группу, управляемую сервером';

  @override
  String get deleteServerManagedGroup2 =>
      'Удалить группу, управляемую сервером?';

  @override
  String get deleteThisItem => 'Удалить этот элемент?';

  @override
  String get deletingAccountAdministrativeActionsUnavailable =>
      'Удаление учётной записи · действия администратора недоступны';

  @override
  String get deletingThisVaultStartsTheServer =>
      'Удаление сейфа запускает льготный период, заданный на сервере. Участники сразу переходят в режим только чтения; точный срок окончательного удаления сообщает сервер.';

  @override
  String get deletionCanceledPendingEncryptedSyncCan =>
      'Удаление отменено; ожидающая зашифрованная синхронизация может продолжиться.';

  @override
  String get deletionRequested => 'Запрошено удаление';

  @override
  String get deletionScheduledByTheServer => 'Сервер запланировал удаление.';

  @override
  String deletionScheduledServerPurgeAfterVaultlifecycledate(
    String vaultLifecycleDate,
  ) {
    return 'Удаление запланировано. Сервер окончательно удалит данные после $vaultLifecycleDate.';
  }

  @override
  String get deliveryHistoryIsUnavailableOnThis =>
      'История доставки на этом сервере недоступна.';

  @override
  String get deliveryWindowUtc => 'Окно доставки (UTC)';

  @override
  String get deploymentCidrLimits => 'Ограничения CIDR развёртывания';

  @override
  String get deploymentPortLimits => 'Ограничения портов развёртывания';

  @override
  String get deploymentRelayAvailability =>
      'Доступность ретранслятора в развёртывании';

  @override
  String get destinationOnSshTarget => 'Назначение на SSH-цели';

  @override
  String get destinationOnThisDevice => 'Назначение на этом устройстве';

  @override
  String get deviceId => 'ID устройства';

  @override
  String get deviceSocksListenerAddress =>
      'Адрес прослушивания SOCKS на устройстве';

  @override
  String get deviceAccessRevoked => 'Доступ устройства отозван';

  @override
  String get deviceApproved => 'Устройство одобрено';

  @override
  String get deviceCapabilitySignerIsInvalid =>
      'Подписавший отчёт о возможностях устройства недействителен.';

  @override
  String get deviceCompatibilityReportIsInvalid =>
      'Отчёт о совместимости устройства недействителен.';

  @override
  String get deviceListenerAddress => 'Адрес прослушивания на устройстве';

  @override
  String get deviceRevoked3 => 'Устройство отозвано';

  @override
  String deviceSubstring(String substring) {
    return 'Устройство $substring';
  }

  @override
  String get devicesActive => 'Активные устройства';

  @override
  String get diagnosticsExportCancelled => 'Экспорт диагностики отменён.';

  @override
  String get direction => 'Направление';

  @override
  String get directory => 'Каталог';

  @override
  String get directoryIsEmpty => 'Каталог пуст';

  @override
  String get disableAccount => 'Отключить учётную запись';

  @override
  String get disableAccountRecovery2 =>
      'Отключить восстановление учётной записи';

  @override
  String get disableAccountRecovery =>
      'Отключить восстановление учётной записи?';

  @override
  String get disableAccount2 => 'Отключить учётную запись?';

  @override
  String get disableOrReEnableAccountsAnd =>
      'Отключайте и снова включайте учётные записи и отзывайте их активные сеансы.';

  @override
  String get disableRecovery => 'Отключить восстановление';

  @override
  String disableUsernameServerSessionsWillBe(String username) {
    return 'Отключить $username? Сеансы на сервере будут отозваны, и войти снова будет нельзя. Кэшированные данные устройств не стираются, а существующие прямые SSH-подключения могут продолжаться, пока SSH-серверы их не закроют.';
  }

  @override
  String get disabledByPolicy => 'Отключено политикой';

  @override
  String get discardIsolatedCopy => 'Удалить изолированную копию';

  @override
  String get discardIsolatedRestoreCopy =>
      'Удалить изолированную копию для восстановления?';

  @override
  String get discarded => 'Удалено';

  @override
  String get disconnect2 => 'Отключить';

  @override
  String get disconnected2 => 'Отключено';

  @override
  String get disconnectedRecursivePreview =>
      'Отключённый рекурсивный предпросмотр';

  @override
  String get disconnectedConnectTabsExplicitly =>
      'Не подключено · подключайте вкладки явно';

  @override
  String disconnectedDirectionlabelFirstpercentSecondpercentPanecountPanes(
    String directionLabel,
    int firstPercent,
    int secondPercent,
    int paneCount,
  ) {
    return 'Не подключено · $directionLabel · $firstPercent/$secondPercent · панелей: $paneCount · подключайте панели явно';
  }

  @override
  String get done2 => 'Готово';

  @override
  String get download2 => 'Скачать';

  @override
  String get due => 'Срок';

  @override
  String get duplicate => 'Дублировать';

  @override
  String get duplicateWorkspace => 'Дублировать рабочее пространство';

  @override
  String get dynamicSocks5 => 'Динамический SOCKS5';

  @override
  String dynamicSocks5Bind(String bind) {
    return 'Динамический SOCKS5 · $bind';
  }

  @override
  String get dynamicForwardingIsALoopbackOnly =>
      'Динамическая переадресация — это прокси SOCKS5 CONNECT только на loopback-адресе без аутентификации SOCKS. Используйте её только на доверенном устройстве.';

  @override
  String get eachDeviceKeepsItsPrivateSigning =>
      'Каждое устройство хранит свои закрытые ключи подписи и шифрования локально. При одобрении отправляются только непрозрачные запечатанные конверты с эпохами ключей сейфов, доступными этому устройству. Никогда не одобряйте регистрацию, которую вы не запрашивали.';

  @override
  String get eachSelectedHostReceivesReferencedCredential =>
      'Каждый выбранный хост получает секреты указанных учётных данных через зашифрованный канал SSH exec. Удалённая программа получает их как аргументы и может раскрыть процессам того же удалённого пользователя.';

  @override
  String get edit2 => 'Изменить';

  @override
  String get editVaultQuota => 'Изменить квоту сейфа';

  @override
  String get editCommandSnippet => 'Изменить сниппет команды';

  @override
  String get editCredential2 => 'Изменить учётные данные';

  @override
  String get editForwardingProfile => 'Изменить профиль переадресации';

  @override
  String get editGroup2 => 'Изменить группу';

  @override
  String get editHostGroup => 'Изменить группу хостов';

  @override
  String get editQuota => 'Изменить квоту';

  @override
  String get editText2 => 'Редактировать текст';

  @override
  String editableCeilingValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Допустимый максимум: $valueValue · CIDR: $summarize · порты: $summarize2';
  }

  @override
  String get editorCanEditVaultRecords =>
      'Редактор · может изменять записи сейфа';

  @override
  String get effectiveSshRelayService => 'Фактическая служба SSH-ретрансляции';

  @override
  String effectiveGroupStateValuevalueCidrsSummarize(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Фактическое состояние группы: $valueValue · CIDR: $summarize · порты: $summarize2';
  }

  @override
  String effectiveStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Фактическое состояние: $valueValue · CIDR: $summarize · порты: $summarize2';
  }

  @override
  String get enableBashCommandHistory => 'Включить историю команд Bash';

  @override
  String get enableBashIntegration => 'Включить интеграцию с Bash';

  @override
  String get enableRelayForThisAccount =>
      'Включить Relay для этой учётной записи';

  @override
  String get enableRelayForThisGroup => 'Включить Relay для этой группы';

  @override
  String get enableSshRelay => 'Включить SSH-ретранслятор';

  @override
  String get enableVaultSync => 'Включить синхронизацию с сейфом';

  @override
  String get enableAndCopy => 'Включить и скопировать';

  @override
  String get enableHostApprovedInputControl =>
      'Включить управление вводом с одобрения хоста';

  @override
  String get enableScheduledBackups =>
      'Включить плановое резервное копирование';

  @override
  String get enabledForThisDeviceTheServer =>
      'Включено для этого устройства. Сервер отправляет только общую подсказку синхронизации.';

  @override
  String get enablingSyncUploadsUpTo500 =>
      'При включении синхронизации сначала отправляется до 500 существующих локальных команд для хостов активного сейфа, затем — новые команды. Команды шифруются ключом активного сейфа, и их может читать любой участник с доступом. Отключение синхронизации отменяет неотправленные команды из очереди; уже отправленные или зафиксированные команды всё равно могут поступить и остаться в сейфе.';

  @override
  String get encryptVaultArchive => 'Зашифровать архив сейфа';

  @override
  String get encryptedVaultArchiveSaved =>
      'Зашифрованный архив сейфа сохранён.';

  @override
  String get encryptedArchive => 'Зашифрованный архив';

  @override
  String get encryptedArchiveBytes => 'Размер зашифрованного архива в байтах';

  @override
  String get encryptedBackup => 'Зашифрованное резервное копирование';

  @override
  String get encryptedBackupsAreCreatedOnThe =>
      'Зашифрованные резервные копии создаются на сервере после того, как оператор настроит доступные только владельцу пути ATERMIUS_BACKUP_ARCHIVE_DIR и ATERMIUS_BACKUP_KEY_FILE вне каталога данных экземпляра. Клиент не отправляет пути к архивам или ключам.';

  @override
  String encryptedObjectBlocksCount(int count) {
    return 'Зашифрованных блоков объектов: $count';
  }

  @override
  String get encryptedRecordsImmutableRetriesAndRecovery =>
      'Зашифрованные записи, неизменяемые повторы и контрольные точки восстановления этого сейфа.';

  @override
  String get encryptedWithTheActiveVaultKey =>
      'Шифруется ключом активного сейфа; участники с доступом могут читать. Отключение синхронизации отменяет неотправленные команды из очереди; уже отправленные или зафиксированные могут поступить и остаться в сейфе.';

  @override
  String get encryptionKeyFingerprint => 'Отпечаток ключа шифрования';

  @override
  String get encryptionKeyFingerprintSha256 =>
      'Отпечаток ключа шифрования · SHA-256';

  @override
  String get enrollmentJson => 'JSON регистрации';

  @override
  String get enrollmentJsonIsNotValid => 'JSON регистрации недействителен.';

  @override
  String get enterAWorkspaceName => 'Введите имя рабочего пространства';

  @override
  String get enterAQuotaFrom1Byte => 'Введите квоту от 1 байта до 1 ТиБ.';

  @override
  String get enterASupportedNonReservedChord =>
      'Введите поддерживаемое незарезервированное сочетание, например mod+alt+shift+f. Каждое сочетание должно быть допустимым и уникальным.';

  @override
  String get enterAWholeNumberFrom1 => 'Введите целое число от 1 до 720.';

  @override
  String get enterAWholeNumberPercent => 'Введите целое число процентов';

  @override
  String get enterRequiredValuesToPreview =>
      'Введите обязательные значения для предпросмотра.';

  @override
  String get enterTheCurrentMasterPasswordAt =>
      'Введите текущий мастер-пароль (не менее 12 символов).';

  @override
  String get enterTheSessionUuidProvidedBy =>
      'Введите UUID сеанса, полученный от хоста. Откроется отдельный терминал только для чтения; SSH-подключение не создаётся.';

  @override
  String epochKeyVersionsCount(int count) {
    return 'Версии ключей эпох: $count';
  }

  @override
  String get eventId => 'ID события';

  @override
  String get everyActiveVaultDeviceMustSupport =>
      'Чтобы удалить запись, все активные устройства сейфа должны поддерживать скрытие данных v1. Обновите или выведите из использования неподдерживающие устройства и повторите попытку.';

  @override
  String get everyRoleChangeAndRevocationCommits =>
      'Каждое изменение роли и отзыв фиксирует подписанное обновление членства с новой эпохой ключа. Владелец и все оставшиеся активные устройства участников получают новый ключ.';

  @override
  String get executionMode => 'Режим выполнения';

  @override
  String get executionPreview => 'Предпросмотр выполнения';

  @override
  String existingShellLabelShell2(String shell) {
    return 'Текущая метка оболочки: $shell';
  }

  @override
  String exitCodeExitcode(Object exitCode) {
    return 'Код выхода: $exitCode';
  }

  @override
  String exitExitstatusCompletedat(int exitStatus, String completedAt) {
    return 'Код выхода $exitStatus · $completedAt';
  }

  @override
  String get expectedAJsonArray => 'Ожидается массив JSON';

  @override
  String get expired => 'Истекло';

  @override
  String get expires => 'Истекает';

  @override
  String get exportArchive => 'Экспорт архива';

  @override
  String get exportDiagnostics => 'Экспорт диагностики';

  @override
  String get exportTheFixedServerHistoryCurrent =>
      'Экспортирует зафиксированную историю сервера, текущие метки удаления, локальную очередь отправки и ветки конфликтов, а также зашифрованные блоки объектов. Отдельный пароль архива защищает файл с помощью Argon2id и XChaCha20-Poly1305.';

  @override
  String get failed2 => 'Ошибка';

  @override
  String get failureCategory => 'Категория сбоя';

  @override
  String get favorite => 'Избранное';

  @override
  String get file => 'Файл';

  @override
  String get filterCommands => 'Фильтр команд';

  @override
  String get fingerprintsApprovedDuringSshConnectionAre =>
      'Отпечатки, одобренные при SSH-подключении, шифруются в этом сейфе и синхронизируются на его устройства. Отзыв тоже шифруется, а история одобрений остаётся видимой. Старые закрепления только на устройстве не импортируются как доверие сейфа.';

  @override
  String get finish => 'Готово';

  @override
  String get finishedAt => 'Завершено';

  @override
  String get firstChild => 'Первый элемент (%)';

  @override
  String get focus => 'Фокус';

  @override
  String get folderName => 'Имя папки';

  @override
  String get forExample104000 => 'Например: 10.40.0.0/16';

  @override
  String get forwardType => 'Тип переадресации';

  @override
  String get freeFormScriptLegacy => 'Скрипт в свободной форме (устаревший)';

  @override
  String get futureAutomaticPurgeConsentWithdrawn =>
      'Согласие на автоматическое удаление в будущем отозвано.';

  @override
  String get generatedAt => 'Создано';

  @override
  String get generation => 'Поколение';

  @override
  String get generationCheckpoint => 'Контрольная точка поколения';

  @override
  String get generationMatches => 'Поколение совпадает';

  @override
  String get generationMismatch => 'Поколение не совпадает';

  @override
  String get go => 'Перейти';

  @override
  String get goToPath => 'Перейти к пути';

  @override
  String get goToRemotePath => 'Перейти к удалённому пути';

  @override
  String get grantFor5Minutes => 'Разрешить на 5 минут';

  @override
  String get grantInputControl => 'Передать управление вводом';

  @override
  String get groupRelayPolicy => 'Политика Relay группы';

  @override
  String groupActionsName2(String name) {
    return 'Действия с группой: $name';
  }

  @override
  String get groupName3 => 'Имя группы';

  @override
  String groupRevisionRevisionMembershipRevisionMembershiprevision(
    int revision,
    int membershipRevision,
    int revision2,
  ) {
    return 'Версия группы $revision · версия членства $membershipRevision · версия политики $revision2';
  }

  @override
  String groupGroupname(Object groupName) {
    return 'Группа: $groupName';
  }

  @override
  String headShortauditid(String shortAuditId) {
    return 'Голова $shortAuditId';
  }

  @override
  String get hideRelayPolicy => 'Скрыть политику Relay';

  @override
  String get hidePasswordSecret => 'Скрыть секрет пароля';

  @override
  String get hideSessions => 'Скрыть сеансы';

  @override
  String get host => 'Хост';

  @override
  String get hostConnectionSettingsReviewedAndQueued =>
      'Параметры подключения хоста проверены и поставлены в очередь синхронизации.';

  @override
  String get hostGroups => 'Группы хостов';

  @override
  String get hostIsNoLongerAvailableSync =>
      'Хост больше недоступен; синхронизируйте и повторите попытку.';

  @override
  String get hostUnavailable => 'Хост недоступен';

  @override
  String hostPaneValuevalue(int valueValue) {
    return 'Хост · панель $valueValue';
  }

  @override
  String get hostApprovedTerminalInput => 'Ввод в терминал с одобрения хоста';

  @override
  String hostNameUsernameEndpointValuevalue(
    String name,
    String username,
    String endpoint,
    String valueValue,
  ) {
    return 'Хост: $name; $username@$endpoint$valueValue';
  }

  @override
  String get hostsWithoutAnOverrideInheritThe =>
      'Хосты без переопределения наследуют значение по умолчанию ближайшей группы.';

  @override
  String get iStoredThisCodeSecurely => 'Я надёжно сохранил(а) этот код';

  @override
  String get iUnderstandBoundedMaintenanceMayPurge =>
      'Я понимаю, что ограниченное обслуживание может удалить эту метку удаления после срока восстановления и обязательных проверок.';

  @override
  String get iUnderstandThisPermanentlyRemovesThe =>
      'Я понимаю, что запись будет окончательно удалена из активного состояния сервера.';

  @override
  String get iveSavedIt => 'Я сохранил(а)';

  @override
  String get idle => 'Ожидание';

  @override
  String get ifCopyingIsUnavailableSelectThe =>
      'Если копирование недоступно, выделите значение выше.';

  @override
  String get ifYouOwnASharedVault =>
      'Если вы владеете общим сейфом с другими активными или приглашёнными участниками, сервер отклонит удаление; владение не передаётся. В льготный период можно отменить удаление на странице входа, указав имя учётной записи и мастер-пароль, а затем войти снова. Перед продолжением сохраните зашифрованный архив.';

  @override
  String get importSshConfig => 'Импорт конфигурации SSH';

  @override
  String get importArchive => 'Импорт архива';

  @override
  String get importToThisVault => 'Импортировать в этот сейф';

  @override
  String get importVerifiedVaultArchive =>
      'Импортировать проверенный архив сейфа?';

  @override
  String importedImportedHostSRecordsAre(int imported) {
    return 'Импортировано хостов: $imported; записи зашифрованы и поставлены в очередь синхронизации.';
  }

  @override
  String get includesTheInstanceAccountAndEvery =>
      'Включает экземпляр, учётную запись и все назначенные серверные группы.';

  @override
  String get inputControlOff => 'Управление вводом: выключено';

  @override
  String get inputControlRevoking => 'Управление вводом: отзыв';

  @override
  String inputControlControllerlabel(Object controllerLabel) {
    return 'Управление вводом: $controllerLabel';
  }

  @override
  String get inputIsEncryptedToTheHost =>
      'Ввод шифруется для хоста и истекает вместе с арендой, одобренной хостом. Изменение размера отключено; доступен только живой вывод.';

  @override
  String get installationWideEventsSeparateFromAccount =>
      'События всей установки, отдельно от страниц аудита учётной записи и сейфа.';

  @override
  String get instance => 'Экземпляр';

  @override
  String get instanceId => 'ID экземпляра';

  @override
  String get instanceVaultQuotas => 'Квоты сейфов экземпляра';

  @override
  String get instanceAccountsAndSessions =>
      'Учётные записи и сеансы экземпляра';

  @override
  String get instanceAdminAudit => 'Аудит администратора экземпляра';

  @override
  String get instanceAdminOverview => 'Обзор администрирования экземпляра';

  @override
  String get instanceBackupStatus =>
      'Состояние резервного копирования экземпляра';

  @override
  String get instanceJobs => 'Задания экземпляра';

  @override
  String instanceRevisionRevisionUpdatedFormattime(
    int revision,
    String formatTime,
  ) {
    return 'Версия экземпляра $revision · обновлено $formatTime';
  }

  @override
  String get instanceSigningKeyFingerprintSha256 =>
      'Отпечаток ключа подписи экземпляра · SHA-256';

  @override
  String get instanceWideBootstrapAndNetworkPolicy =>
      'Начальная настройка и сетевая политика всего экземпляра управляются оператором собственного сервера.';

  @override
  String get interrupted => 'Прервано';

  @override
  String get interruptedRetryPending => 'Прервано · ожидает повтора';

  @override
  String get intervalInHours => 'Интервал (часы)';

  @override
  String get invalidFontSizeValue => 'Недопустимый размер шрифта';

  @override
  String get invalidToken7UtcDays => 'Недействительный токен (7 дней UTC)';

  @override
  String get inventoryEntryStale => 'Запись инвентаря устарела';

  @override
  String get invitationCreated => 'Приглашение создано';

  @override
  String get invitationExpired => 'Приглашение истекло';

  @override
  String get invitationExpiresInDays => 'Срок действия приглашения (дни)';

  @override
  String invitationExpiresFormattedexpiry(String formattedExpiry) {
    return 'Приглашение истекает $formattedExpiry';
  }

  @override
  String get invitationNeedsReissue => 'Приглашение нужно выдать заново';

  @override
  String get invitationPending => 'Приглашение ожидает принятия';

  @override
  String get invitationToken => 'Токен приглашения';

  @override
  String get invitationTokenCopied => 'Токен приглашения скопирован.';

  @override
  String get invitationUsername => 'Имя приглашаемого пользователя';

  @override
  String get inviteMember => 'Пригласить участника';

  @override
  String inviteToCurrentvaultname(String currentVaultName) {
    return 'Пригласить в $currentVaultName';
  }

  @override
  String get issueAccountInvitation => 'Выдать приглашение в учётную запись';

  @override
  String get issueCategory => 'Категория проблемы';

  @override
  String get join => 'Присоединиться';

  @override
  String get joinASharedTerminal => 'Присоединиться к общему терминалу';

  @override
  String get joinHostGrantedControl =>
      'Присоединиться к управлению, выданному хостом';

  @override
  String get keepVault => 'Сохранить сейф';

  @override
  String get keepAccess => 'Сохранить доступ';

  @override
  String get keepAccount => 'Сохранить учётную запись';

  @override
  String get keepCurrentOwner => 'Оставить текущего владельца';

  @override
  String get keepRepeatableCommandsInTheSame =>
      'Храните повторяющиеся команды в том же зашифрованном сейфе, что и хосты.';

  @override
  String get keepScheduledDeletion => 'Оставить запланированное удаление';

  @override
  String get keepSelectedBindingsAndRemoveDuplicates =>
      'Оставить выбранные привязки и удалить дубликаты';

  @override
  String get keepSelectedFontSizeAndRemove =>
      'Оставить выбранный размер шрифта и удалить дубликаты';

  @override
  String get keepSelectedRecordAndRemoveDuplicates =>
      'Оставить выбранную запись и удалить дубликаты';

  @override
  String get keepSelectedThemeAndRemoveDuplicates =>
      'Оставить выбранную тему и удалить дубликаты';

  @override
  String get keepThisDeviceVersion => 'Оставить версию этого устройства';

  @override
  String get keepThisDeviceVersion2 => 'Оставить версию этого устройства?';

  @override
  String get keyPassphraseOptional => 'Парольная фраза ключа (необязательно)';

  @override
  String get keyUpdateNeeded => 'Требуется обновление ключа';

  @override
  String get knownHost => 'Известный хост';

  @override
  String get lastChanged => 'Последнее изменение';

  @override
  String get lastPull => 'Последнее получение';

  @override
  String get lastRun => 'Последний запуск';

  @override
  String get lastRunStatus => 'Состояние последнего запуска';

  @override
  String get lastSuccessfulSync => 'Последняя успешная синхронизация';

  @override
  String get lastUpdated => 'Последнее обновление';

  @override
  String lastVerifiedServerShortkey(String shortKey) {
    return 'Последний проверенный сервер: $shortKey';
  }

  @override
  String get latestCopy => 'Последняя копия';

  @override
  String get leased => 'Арендовано';

  @override
  String get leaveSharedTerminal => 'Покинуть общий терминал';

  @override
  String get loadRelayPolicies => 'Загрузить политики Relay';

  @override
  String get loadVaults => 'Загрузить сейфы';

  @override
  String get loadAccountInvitations => 'Загрузить приглашения';

  @override
  String get loadAccountsToAddMembers =>
      'Загрузите учётные записи, чтобы добавить участников';

  @override
  String get loadAdminAccounts => 'Загрузить учётные записи администратора';

  @override
  String get loadAdminAudit => 'Загрузить аудит администратора';

  @override
  String get loadBackupSchedule =>
      'Загрузить расписание резервного копирования';

  @override
  String get loadBackupStatus => 'Загрузить состояние резервного копирования';

  @override
  String get loadInstanceJobs => 'Загрузить задания экземпляра';

  @override
  String get loadOverview => 'Загрузить обзор';

  @override
  String get loadPushHealth => 'Загрузить состояние push';

  @override
  String get loadRelayPolicy => 'Загрузить политику ретрансляции';

  @override
  String get loadReplicationStatus => 'Загрузить состояние репликации';

  @override
  String get loadRestoreSources => 'Загрузить источники восстановления';

  @override
  String get loadServerManagedGroups =>
      'Загрузить группы, управляемые сервером';

  @override
  String get loadStatus => 'Загрузить состояние';

  @override
  String get loadingSshRelayPolicy => 'Загрузка политики SSH-ретранслятора…';

  @override
  String get loadingAccountAndInstancePolicyRevisions =>
      'Загрузка версий политик учётной записи и экземпляра…';

  @override
  String get loadingAccountInvitations => 'Загрузка приглашений…';

  @override
  String get loadingAccountSessions => 'Загрузка сеансов учётной записи…';

  @override
  String get loadingBackupSchedule =>
      'Загрузка расписания резервного копирования…';

  @override
  String get loadingEncryptedArchiveSources =>
      'Загрузка источников зашифрованных архивов…';

  @override
  String get loadingGroupMembershipAndRelayPolicy =>
      'Загрузка членства группы и политики Relay…';

  @override
  String get loadingServerManagedGroups =>
      'Загрузка групп, управляемых сервером…';

  @override
  String get local => 'Локально';

  @override
  String get localArchive => 'Локальный архив';

  @override
  String get localDevice => 'Локальное устройство';

  @override
  String get localEditsAreEncryptedAndCommitted =>
      'Локальные правки шифруются и фиксируются в постоянной очереди отправки до любых сетевых запросов. Повтор использует те же ID операций и шифротекст. Сервер никогда не получает учётные данные или ключ сейфа.';

  @override
  String get localEncryptedArchiveUnavailable =>
      'Локальный зашифрованный архив недоступен';

  @override
  String localRevisionItem(Object item) {
    return 'Локальная версия  $item';
  }

  @override
  String localBindDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return 'Локальная · $bind → $destinationAddress:$destinationPort';
  }

  @override
  String get localOnlyProfiles => 'Локальные профили';

  @override
  String get lockWorkspace => 'Заблокировать рабочее пространство';

  @override
  String get loopbackOnly => 'Только loopback';

  @override
  String get maintenance => 'Обслуживание';

  @override
  String get maintenanceRunsTheConfiguredRetentionAnd =>
      'Обслуживание выполняет настроенную очистку по сроку хранения и удаление просроченных объектов. Сервер сообщает, какие действия с экземпляром доступны.';

  @override
  String get makeEditor => 'Сделать редактором';

  @override
  String get makeViewer => 'Сделать читателем';

  @override
  String makeUsernameTheSoleOwnerYour(String username) {
    return 'Сделать $username единственным владельцем. Ваша учётная запись останется активным редактором. Действие подписывает новую версию членства и за одно атомарное обновление меняет ключ сейфа для всех активных устройств участников. Ожидающие токены приглашений станут недействительными и их нужно будет выдать заново. Новый владелец сможет управлять участниками и удалить сейф.';
  }

  @override
  String get manageVaultMembers => 'Управлять участниками сейфа';

  @override
  String get masterPasswordIsUsedOnlyFor =>
      'Мастер-пароль используется только для вывода ключей на стороне клиента.';

  @override
  String get maxSshRelayConnectionsPerUser =>
      'Максимум подключений к SSH-ретранслятору на пользователя';

  @override
  String get maxRelayConnectionsPerUser =>
      'Максимум подключений к ретранслятору на пользователя';

  @override
  String memberEffectiveRelayAccessValuevalueCidrs(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Фактический доступ участника к Relay: $valueValue · CIDR: $summarize · порты: $summarize2';
  }

  @override
  String get members => 'Участники';

  @override
  String membersCurrentvaultname(String currentVaultName) {
    return 'Участники · $currentVaultName';
  }

  @override
  String get mergePasswordFields => 'Объединить поля паролей';

  @override
  String get migrationVersion => 'Версия миграции';

  @override
  String get missingHost => 'Хост отсутствует';

  @override
  String get moveEncryptedLocalHostsCredentialsGroups =>
      'Перенесите зашифрованные локальные хосты, учётные данные, группы, сниппеты и поддерживаемые настройки рабочего пространства в новый пустой синхронизируемый сейф. Локальный профиль остаётся без изменений; на время миграции локальные правки приостанавливаются, пока сервер не подтвердит все подготовленные записи.';

  @override
  String moveOrUnassignHostcountHostS(
    int hostCount,
    int childCount,
    String name,
  ) {
    return 'Перед удалением «$name» переместите или открепите хосты ($hostCount) и дочерние группы ($childCount).';
  }

  @override
  String get name2 => 'Имя';

  @override
  String get needsMoreVaultKeys => 'Нужны дополнительные ключи сейфа';

  @override
  String get needsOperatorAttention => 'Требуется вмешательство оператора';

  @override
  String get networkUnavailable => 'Сеть недоступна';

  @override
  String get newSshCredential => 'Новые учётные данные SSH';

  @override
  String get newArchivePassword => 'Новый пароль архива';

  @override
  String get newCommandSnippet => 'Новый сниппет команды';

  @override
  String get newDevice => 'Новое устройство';

  @override
  String get newFirstChild => 'Новый первый элемент (%)';

  @override
  String get newFolder2 => 'Новая папка';

  @override
  String get newGroup2 => 'Новая группа';

  @override
  String get newHostGroup => 'Новая группа хостов';

  @override
  String get newMasterPassword => 'Новый мастер-пароль';

  @override
  String get newServerGroupName => 'Имя новой серверной группы';

  @override
  String get newSnippet => 'Новый сниппет';

  @override
  String get newSplitSideBySide => 'Новое разделение: слева и справа';

  @override
  String get newSplitStacked => 'Новое разделение: сверху и снизу';

  @override
  String get newTab => 'Новая вкладка';

  @override
  String get next => 'Далее';

  @override
  String get nextAccounts => 'Следующие учётные записи';

  @override
  String get nextInvitations => 'Следующие приглашения';

  @override
  String get nextRun => 'Следующий запуск';

  @override
  String get nextSessions => 'Следующие сеансы';

  @override
  String get noCliOrServerTriggeredBackup =>
      'Попыток резервного копирования из CLI или сервера не записано.';

  @override
  String get noVaultIsCurrentlyAvailableTo =>
      'На этом устройстве сейчас нет доступных сейфов. Примите приглашение, чтобы восстановить доступ, или создайте отдельный зашифрованный сейф.';

  @override
  String get noVaultsFound => 'Сейфы не найдены.';

  @override
  String get noVaultsOnThisPage => 'На этой странице нет сейфов.';

  @override
  String get noAccessibleVaults => 'Нет доступных сейфов';

  @override
  String get noAccountInvitationsFound => 'Приглашения не найдены.';

  @override
  String get noAccountsFound => 'Учётные записи не найдены.';

  @override
  String get noAccountsOnThisPage => 'На этой странице нет учётных записей.';

  @override
  String get noActiveSshSession => 'Нет активного SSH-сеанса';

  @override
  String get noActiveVaultDeviceReportsAre =>
      'Нет отчётов активных устройств сейфа.';

  @override
  String get noActiveCredential => 'Нет активных учётных данных';

  @override
  String get noCheckpoint => 'Нет контрольной точки';

  @override
  String get noCommandEventsReceivedYetPaste =>
      'События команд ещё не получены. Вставьте скопированную команду настройки в интерактивную оболочку Bash и нажмите Enter.';

  @override
  String get noCredentialsSaved => 'Нет сохранённых учётных данных';

  @override
  String get noDefaultCredential2 => 'Без учётных данных по умолчанию';

  @override
  String get noDeletedRecordsInThisVault =>
      'В этом сейфе нет удалённых записей.';

  @override
  String get noDeviceListLoaded => 'Список устройств не загружен';

  @override
  String get noDevicesOnline => 'Нет устройств в сети';

  @override
  String get noForwardingProfilesSavedForThis =>
      'Для этого хоста нет сохранённых профилей переадресации.';

  @override
  String get noHostGroupsYet => 'Групп хостов пока нет';

  @override
  String get noHostKeysHaveBeenApproved =>
      'В этом сейфе не одобрено ни одного ключа хоста.';

  @override
  String get noHostsSavedYet => 'Сохранённых хостов пока нет';

  @override
  String get noInstanceAdminAuditEvents =>
      'Событий аудита администратора экземпляра нет.';

  @override
  String get noInstanceJobs => 'Заданий экземпляра нет.';

  @override
  String get noInvitationsOnThisPage => 'На этой странице нет приглашений.';

  @override
  String get noJobs => 'Заданий нет';

  @override
  String get noMatchingHosts2 => 'Подходящих хостов нет';

  @override
  String get noMatchingSingleLineCommands =>
      'Подходящих однострочных команд нет.';

  @override
  String get noMembersWereReturned => 'Участники не получены.';

  @override
  String get noNewerBundleIsAvailableAt =>
      'По этому адресу пока нет новой сборки. Обновите веб-ресурсы на своём сервере и проверьте снова.';

  @override
  String get noOpenConflicts => 'Нет открытых конфликтов';

  @override
  String get noOtherActiveVaultDevicesCan =>
      'Нет других активных устройств сейфа, которые могут получить этот общий терминал.';

  @override
  String get noPushProviderSnapshotIsAvailable =>
      'Снимок провайдеров push недоступен.';

  @override
  String get noRemoteCopyAttemptRecordedYet =>
      'Попыток удалённого копирования пока не было.';

  @override
  String get noResult => 'Нет результата';

  @override
  String get noSavedWorkspaces => 'Нет сохранённых рабочих пространств';

  @override
  String get noScheduledBackupRunsRecorded =>
      'Запусков планового резервного копирования не записано';

  @override
  String get noServerManagedGroupsYet =>
      'Групп, управляемых сервером, пока нет.';

  @override
  String get noSessionsFound => 'Сеансы не найдены.';

  @override
  String get noSessionsOnThisPage => 'На этой странице нет сеансов.';

  @override
  String get noSnippetsYet2 => 'Сниппетов пока нет';

  @override
  String get noSupportedEncryptedArchivesAreAvailable =>
      'На этой странице нет поддерживаемых зашифрованных архивов.';

  @override
  String get noVerifiedCandidateIsAvailableRetry =>
      'Нет проверенного варианта. Повторите синхронизацию сейфа; некорректное состояние исправления остаётся заблокированным.';

  @override
  String get noVerifiedCandidateIsAvailableRetry2 =>
      'Нет проверенного варианта. Повторите синхронизацию сейфа; некорректное состояние исправления остаётся заблокированным.';

  @override
  String get noVerifiedCandidateIsAvailableRetry3 =>
      'Нет проверенного варианта. Повторите синхронизацию сейфа; некорректное состояние исправления остаётся заблокированным для ручного восстановления.';

  @override
  String get none => 'Нет';

  @override
  String get notConfigured => 'Не настроено';

  @override
  String get notScheduledYet => 'Ещё не запланировано';

  @override
  String get notStarted => 'Не начато';

  @override
  String get owner => 'ВЛАДЕЛЕЦ';

  @override
  String observerState(String state) {
    return 'Наблюдатель $state';
  }

  @override
  String get occurredAt => 'Время события';

  @override
  String get offByDefaultEnablingUploadsUp =>
      'По умолчанию выключено. При включении отправляется до 500 существующих локальных команд для хостов этого сейфа и последующие команды.';

  @override
  String get offSiteEncryptedBackupCopies =>
      'Внешние зашифрованные резервные копии';

  @override
  String get offline => 'Офлайн';

  @override
  String get offlineDeviceCopiesAndExportsAre =>
      'Офлайн-копии на устройствах и экспортированные файлы не удаляются.';

  @override
  String get offlineDeviceCopiesAndRetainedBackups =>
      'Офлайн-копии на устройствах и сохранённые резервные копии удалённо не стираются.';

  @override
  String get offlineFirstCiphertextOnly =>
      'Офлайн в приоритете, только шифротекст';

  @override
  String get oneCanonicalNetworkCidrPerLine =>
      'По одной канонической сети CIDR в строке.';

  @override
  String get oneTimePrometheusScrapeCredential =>
      'Одноразовые учётные данные Prometheus для сбора метрик';

  @override
  String get oneTimeInvitationToken => 'Одноразовый токен приглашения';

  @override
  String get oneTimeToken => 'Одноразовый токен';

  @override
  String onlineDeviceStatusCouldNotBe(Object vaultPresenceError) {
    return 'Не удалось загрузить состояние устройств в сети: $vaultPresenceError';
  }

  @override
  String get onlineStatusUnavailable => 'Состояние в сети недоступно';

  @override
  String get onlyASignedEnrollmentFromAn =>
      'Присоединиться к этой учётной записи может только подписанная регистрация с активного устройства. Устройства получают запечатанные ключи доступных сейфов, если они есть.';

  @override
  String get onlyAlreadyConnectedSshSessionsAre =>
      'Доступны только уже подключённые SSH-сеансы. Выберите не менее двух хостов; каждый будет проверен перед отправкой команд.';

  @override
  String get openSettingsDataAndMigrationTo =>
      'Откройте «Настройки» → «Данные и миграция», чтобы экспортировать зашифрованный архив';

  @override
  String get openTerminal => 'Открыть терминал';

  @override
  String get openTerminalChooseAHostAnd =>
      'Откройте терминал, выберите хост и подключитесь. SFTP использует тот же проверенный SSH-транспорт.';

  @override
  String get openVault => 'Открыть сейф';

  @override
  String get openAVaultToReadOr =>
      'Откройте сейф, чтобы читать или сохранять синхронизируемые настройки.';

  @override
  String get openAVaultToReadOr2 =>
      'Откройте сейф, чтобы читать или сохранять эти синхронизируемые настройки.';

  @override
  String get openAVaultToReadOr3 =>
      'Откройте сейф, чтобы читать или сохранять эту синхронизируемую настройку.';

  @override
  String get openANewTerminalTab => 'Открыть новую вкладку терминала';

  @override
  String get openActiveTerminals => 'Открыть активные терминалы';

  @override
  String get openConflicts => 'Открытые конфликты';

  @override
  String get openTerminal2 => 'Открыть терминал';

  @override
  String get optionalBackgroundSyncHintsForThis =>
      'Необязательные подсказки фоновой синхронизации для этого устройства. На iOS по возможности используется APNs.';

  @override
  String get organizeYourHostsIntoGroups => 'Распределите хосты по группам.';

  @override
  String get otherSyncIssue => 'Другая проблема синхронизации';

  @override
  String get outboxItems => 'Элементы очереди отправки';

  @override
  String get outputIsEncryptedForThisDevice =>
      'Вывод шифруется для этого устройства. Ввод и изменение размера отключены, пока хост явно не передаст управление этому устройству. Предыдущая история прокрутки недоступна.';

  @override
  String get ownerAccountId => 'ID учётной записи владельца';

  @override
  String get ownerUserId => 'ID пользователя-владельца';

  @override
  String get pemPrivateKey => 'Закрытый ключ PEM';

  @override
  String get private => 'ЛИЧНЫЙ';

  @override
  String pageValuevalue(int valueValue) {
    return 'Страница $valueValue';
  }

  @override
  String paneValuevalue(int valueValue) {
    return 'Панель $valueValue';
  }

  @override
  String paneValuevalueValuevalue2(int valueValue, String valueValue2) {
    return 'Панель $valueValue · $valueValue2';
  }

  @override
  String paneValuevalueValuevalue2Valuevalue3(
    int valueValue,
    String valueValue2,
    String valueValue3,
  ) {
    return 'Панель $valueValue · $valueValue2 · $valueValue3';
  }

  @override
  String paneValuevalueValuevalue22(int valueValue, int valueValue2) {
    return 'Панель $valueValue · $valueValue2%';
  }

  @override
  String get parameterDefinitionsJsonArray2 =>
      'Определения параметров (массив JSON)';

  @override
  String get parameterName => 'Имя параметра';

  @override
  String get parentGroup2 => 'Родительская группа';

  @override
  String get password => 'Пароль';

  @override
  String get passwordCredential => 'Парольные учётные данные';

  @override
  String get passwordFieldMergeIsNoLonger =>
      'Объединение полей паролей больше недоступно. Используйте действия с проверенными ветками.';

  @override
  String get passwordSecret => 'Секрет пароля';

  @override
  String get passwordsPrivateKeysAndPassphrasesAre =>
      'Пароли, закрытые ключи и парольные фразы шифруются на этом устройстве до синхронизации. Секреты в открытом виде используются только в разблокированном сеансе.';

  @override
  String get pasteThePublicRequestFromThe =>
      'Вставьте открытый запрос из нового браузера. Закрытые ключи в него никогда не входят.';

  @override
  String get pasteTheRecipientsSignedPublicDevice =>
      'Вставьте подписанную публичную карточку устройства получателя. Учётная запись уже должна существовать на этом экземпляре, а карточка — соответствовать активному устройству, которое примет приглашение.';

  @override
  String get pending => 'Ожидает';

  @override
  String get permanentPurgeAfter => 'Окончательное удаление после';

  @override
  String get permanentPurgeBecomesAvailableAfterThis =>
      'Окончательное удаление станет доступно после этого срока.';

  @override
  String get permanentPurgeIsUnavailableBecauseThis =>
      'Окончательное удаление недоступно: сервер не сообщил срок восстановления.';

  @override
  String permanentlyDeleteNameItsMembershipAnd(String name) {
    return 'Окончательно удалить «$name», его членство и политику Relay? Неиспользованные билеты Relay его участников будут отозваны, а активные сеансы, разрешённые этой группой, закроются после повторной проверки политики.';
  }

  @override
  String get permanentlyPurge => 'Удалить окончательно';

  @override
  String get permanentlyPurgeThisRecord => 'Окончательно удалить эту запись?';

  @override
  String get policyRevision => 'Версия политики';

  @override
  String policyRevisionRevisionInstanceRevisionInstancepolicyrevision(
    int revision,
    int instancePolicyRevision,
    String formatTime,
  ) {
    return 'Версия политики $revision · версия экземпляра $instancePolicyRevision · обновлено $formatTime';
  }

  @override
  String get port => 'Порт';

  @override
  String get portableEncryptedVaultArchive =>
      'Переносимый зашифрованный архив сейфа';

  @override
  String get preference => 'Настройка';

  @override
  String get preflightFailedBeforeAnyTargetReceived =>
      'Предварительная проверка не пройдена до отправки команд какой-либо цели.';

  @override
  String get prepareIsolatedCopy => 'Подготовить изолированную копию';

  @override
  String get prepareIsolatedRestoreCopy =>
      'Подготовить изолированную копию для восстановления';

  @override
  String get prepareIsolatedRestoreCopy2 =>
      'Подготовить изолированную копию для восстановления?';

  @override
  String get prepared => 'Подготовлено';

  @override
  String get preparingIsolatedCopy => 'Подготовка изолированной копии';

  @override
  String get preparingLocalEncryptedArchive =>
      'Подготовка локального зашифрованного архива';

  @override
  String get previewDisconnectedLayout => 'Предпросмотр макета без подключения';

  @override
  String get previewMemberEffectiveRelayAccess =>
      'Предпросмотр фактического доступа участника к Relay';

  @override
  String get previewOnly => 'Только предпросмотр';

  @override
  String get previewStructuredCommandsOrReviewAnd =>
      'Просмотрите структурированные команды или проверьте и подтвердите скрипты перед отправкой в активный терминал.';

  @override
  String get previous => 'Назад';

  @override
  String get previousAccounts => 'Предыдущие учётные записи';

  @override
  String get previousInvitations => 'Предыдущие приглашения';

  @override
  String get previousSessions => 'Предыдущие сеансы';

  @override
  String get privateKey => 'Закрытый ключ';

  @override
  String get privateSigningAndEncryptionKeysStay =>
      'Закрытые ключи подписи и шифрования остаются в защищённом хранилище этого устройства.';

  @override
  String get profileName => 'Имя профиля';

  @override
  String get profilesAreEncryptedAndSyncWith =>
      'Профили шифруются и синхронизируются с сейфом. Этот браузер не может открывать локальные TCP-слушатели, необходимые для переадресации портов.';

  @override
  String get profilesAreEncryptedInThisHost =>
      'Профили шифруются в этом хосте и синхронизируются с сейфом. Активные слушатели работают на этом устройстве и останавливаются при отключении этой вкладки SSH.';

  @override
  String get profilesAreEncryptedInsideThisHost =>
      'Профили шифруются в записи хоста и синхронизируются с сейфом. Состояние работы и сокеты никогда не синхронизируются.';

  @override
  String get program2 => 'Программа';

  @override
  String get prometheusRequestsUsingThisCredentialWill =>
      'Запросы Prometheus с этими учётными данными сразу перестанут работать. Позже можно создать замену.';

  @override
  String get prometheusScrapeCredential =>
      'Учётные данные Prometheus для сбора метрик';

  @override
  String get protocol => 'Протокол';

  @override
  String get protocolVersion => 'Версия протокола';

  @override
  String get providerAdapter => 'Адаптер провайдера';

  @override
  String get publicDeviceCard => 'Публичная карточка устройства';

  @override
  String get publicDeviceCardJson => 'JSON публичной карточки устройства';

  @override
  String get pushIsABestEffortWake =>
      'Push — это лишь подсказка для пробуждения без гарантий; она не подтверждает доставку или синхронизацию.';

  @override
  String get pushProviderHealth => 'Состояние провайдеров push';

  @override
  String get queuedNotTrusted => 'В ОЧЕРЕДИ — НЕ ДОВЕРЕН';

  @override
  String get queueApprovalAndStop =>
      'Поставить одобрение в очередь и остановить';

  @override
  String get queued => 'В очереди';

  @override
  String get quota => 'Квота';

  @override
  String get quotaInBytes => 'Квота (байты)';

  @override
  String get readOnly2 => 'ТОЛЬКО ЧТЕНИЕ';

  @override
  String get reissueRequired => 'ТРЕБУЕТСЯ ПОВТОРНАЯ ВЫДАЧА';

  @override
  String get revoked2 => 'ОТОЗВАНО';

  @override
  String get reAuthenticateToCancel =>
      'Пройдите аутентификацию, чтобы отменить';

  @override
  String get reEnterAccountMasterPassword =>
      'Повторно введите мастер-пароль учётной записи';

  @override
  String get readOnlyGracePeriodAllMembers =>
      'Льготный период только для чтения · все участники могут читать, но запись и изменение участников приостановлены. В настройках можно создать зашифрованный архив с отдельным паролем.';

  @override
  String get readOnlyInstanceIdentityUsageAnd =>
      'Идентичность экземпляра, использование и политика ретрансляции (только чтение).';

  @override
  String get readOnlyProviderConfigurationAggregateQueue =>
      'Настройки провайдера (только чтение), сводные счётчики очереди и результаты адаптеров.';

  @override
  String get ready => 'Готово';

  @override
  String get rebuildSnapshot => 'Перестроить снимок';

  @override
  String get rebuildingSnapshot => 'Перестроение снимка';

  @override
  String get rebuildingSnapshot2 => 'Перестроение снимка…';

  @override
  String get reconnectObserver => 'Переподключить наблюдателя';

  @override
  String get record => 'Запись';

  @override
  String recordIdIdRevisionRevisionlabel(String id, String revisionLabel) {
    return 'ID записи: $id\nВерсия: $revisionLabel';
  }

  @override
  String recordIdIdRevisionValuevalue(String id, String valueValue) {
    return 'ID записи: $id\nВерсия: $valueValue';
  }

  @override
  String get recordConsent => 'Записать согласие';

  @override
  String get recordPermanentlyRemovedFromActiveServer =>
      'Запись окончательно удалена из активного состояния сервера. Офлайн-копии на устройствах и сохранённые резервные копии не стираются.';

  @override
  String get recordsAndConflictsRemainEncryptedExisting =>
      'Записи и конфликты остаются зашифрованными. Существующие локальные ветки и другие сейфы сохраняются. Перенос между пространствами и переназначение ID не поддерживаются.';

  @override
  String get recordsAreDecryptedOnlyOnThis =>
      'Записи расшифровываются только на этом устройстве. Если та же метка удаления всё ещё актуальна, восстановление создаёт новую подписанную версию.';

  @override
  String get recoveryDetails => 'Сведения о восстановлении';

  @override
  String get recoveryInProgress => 'Выполняется восстановление';

  @override
  String get recoveryIsEnabledButThisCode =>
      'Восстановление включено, но сохранение кода не подтверждено. Обновите его сейчас, чтобы показать новый код.';

  @override
  String recoveryIsStatusCoveredcontextsOfRequiredcontexts(
    String status,
    int coveredContexts,
    int requiredContexts,
  ) {
    return 'Восстановление: $status. Покрыто текущих контекстов: $coveredContexts из $requiredContexts; устройство будет повторять получение недостающих ключей в фоне.';
  }

  @override
  String get recoveryRequired => 'Требуется восстановление';

  @override
  String get recoveryRequiredSyncing =>
      'Требуется восстановление · синхронизация…';

  @override
  String get recycleBin => 'Корзина';

  @override
  String recycleBinRecordDisplaynameIdSubstring(
    String displayName,
    String substring,
    String automaticPurgeConsentText,
    String restoreDeadlineSemantics,
  ) {
    return 'Запись в корзине: $displayName, ID $substring, $automaticPurgeConsentText, $restoreDeadlineSemantics';
  }

  @override
  String redactionProofItem(Object item) {
    return 'Подтверждение скрытия  $item';
  }

  @override
  String get redactionReadiness => 'Готовность к скрытию данных';

  @override
  String get refresh2 => 'Обновить';

  @override
  String get refreshVaultList => 'Обновить список сейфов';

  @override
  String get refreshVaultStates => 'Обновить состояние сейфов';

  @override
  String get refreshAccountInvitations => 'Обновить приглашения';

  @override
  String get refreshAccountSessions => 'Обновить сеансы учётной записи';

  @override
  String get refreshAdminAccounts => 'Обновить учётные записи администратора';

  @override
  String get refreshAdminAudit => 'Обновить аудит администратора';

  @override
  String get refreshBackupStatus => 'Обновить состояние резервного копирования';

  @override
  String get refreshDevices => 'Обновить устройства';

  @override
  String get refreshExpires => 'Обновление истекает';

  @override
  String get refreshInstanceJobs => 'Обновить задания экземпляра';

  @override
  String get refreshKeyCoverage => 'Обновить покрытие ключей';

  @override
  String get refreshMembersAndOnlineDevices =>
      'Обновить участников и устройства в сети';

  @override
  String get refreshOverview => 'Обновить обзор';

  @override
  String get refreshPushHealth => 'Обновить состояние push';

  @override
  String get refreshReadiness => 'Обновить готовность';

  @override
  String get refreshRelayPolicy => 'Обновить политику ретрансляции';

  @override
  String get refreshReplicationStatus => 'Обновить состояние репликации';

  @override
  String get refreshRestoreSources => 'Обновить источники восстановления';

  @override
  String get refreshRestoreStatus => 'Обновить состояние восстановления';

  @override
  String get refreshSchedule => 'Обновить расписание';

  @override
  String get refreshServerManagedGroups =>
      'Обновить группы, управляемые сервером';

  @override
  String get refreshStatus => 'Обновить состояние';

  @override
  String get refreshToLoadApprovedDevicesFrom =>
      'Обновите, чтобы загрузить одобренные устройства с сервера.';

  @override
  String get registeredEndpoints => 'Зарегистрированные конечные точки';

  @override
  String get reject2 => 'Отклонить';

  @override
  String get relayCidrs => 'CIDR ретранслятора';

  @override
  String get relayAvailable => 'Ретранслятор доступен';

  @override
  String get relayPolicy => 'Политика Relay';

  @override
  String get relayPorts => 'Порты ретранслятора';

  @override
  String get relayUnavailable => 'Ретранслятор недоступен';

  @override
  String get reloadAccountAndInstanceRelayPolicies =>
      'Перезагрузить политики Relay учётной записи и экземпляра';

  @override
  String get reloadFirstPage => 'Перезагрузить первую страницу';

  @override
  String get reloadGroupAndInstancePoliciesKeep =>
      'Перезагрузить политики группы и экземпляра, сохранив черновики';

  @override
  String get reloadLatestGroupKeepDrafts =>
      'Перезагрузить последнюю версию группы, сохранив черновики';

  @override
  String get reloadLatestPolicy => 'Перезагрузить последнюю политику';

  @override
  String get reloadLatestPolicyKeepDraft =>
      'Перезагрузить последнюю политику, сохранив черновик';

  @override
  String get remote => 'Удалённо';

  @override
  String get remoteSshListenerAddress => 'Адрес прослушивания на удалённом SSH';

  @override
  String get remoteArchiveIntegrityMismatch =>
      'Целостность удалённого архива не совпадает';

  @override
  String get remoteCompletionUnknownNotRetried =>
      'Завершение на удалённой стороне неизвестно · без повтора';

  @override
  String get remoteCopyFailed => 'Удалённое копирование не выполнено';

  @override
  String get remoteCopyVerified => 'Удалённая копия проверена';

  @override
  String get remoteCredentialsUnavailable =>
      'Удалённые учётные данные недоступны';

  @override
  String remoteFilesEndpoint(Object endpoint) {
    return 'Удалённые файлы · $endpoint';
  }

  @override
  String get remoteHeadIsAbsent => 'Удалённая голова отсутствует';

  @override
  String get remotePath2 => 'Удалённый путь';

  @override
  String remotePathSftppath(String sftpPath) {
    return 'Удалённый путь: $sftpPath';
  }

  @override
  String get remoteReplica => 'Удалённая реплика';

  @override
  String get remoteReplication => 'Удалённая репликация';

  @override
  String remoteRevisionItem(Object item) {
    return 'Удалённая версия $item';
  }

  @override
  String get remoteStorageUnavailable => 'Удалённое хранилище недоступно';

  @override
  String remoteSshBindDeviceDestinationaddressDestinationport(
    String bind,
    Object destinationAddress,
    Object destinationPort,
  ) {
    return 'Удалённая · SSH $bind → устройство $destinationAddress:$destinationPort';
  }

  @override
  String removePaneValuevalue(int valueValue) {
    return 'Удалить панель $valueValue';
  }

  @override
  String get removeFavorite => 'Убрать из избранного';

  @override
  String get removeReference => 'Удалить ссылку';

  @override
  String get removeTmuxSessionReference2 => 'Удалить ссылку на сеанс tmux';

  @override
  String get removeTmuxSessionReference => 'Удалить ссылку на сеанс tmux?';

  @override
  String removeUsernameFromGroupDraft(String username) {
    return 'Удалить $username из черновика группы';
  }

  @override
  String get rename => 'Переименовать';

  @override
  String get renameWorkspace => 'Переименовать рабочее пространство';

  @override
  String get repairAHost => 'Исправить хост';

  @override
  String get repairAGroup => 'Исправить группу';

  @override
  String get repairIsNotConfirmedYetSync =>
      'Исправление ещё не подтверждено. Синхронизируйте активный сейф и повторите с тем же ID записи.';

  @override
  String get replaceHost => 'Заменить хост';

  @override
  String get replaceMissingHost => 'Заменить отсутствующий хост';

  @override
  String get requestedAt => 'Запрошено';

  @override
  String get requiredTextValue => 'Обязательное текстовое значение';

  @override
  String get reservedUploads => 'Зарезервированные загрузки';

  @override
  String get resetToInherit => 'Сбросить на наследование';

  @override
  String get resolutionSavedOnThisDeviceWaiting =>
      'Решение сохранено на этом устройстве; ожидается подтверждение синхронизации.';

  @override
  String get resolveOrDiscardThisRecordsOutstanding =>
      'Перед окончательным удалением записи решите или отклоните её открытый конфликт.';

  @override
  String get resourceIdHmacSha256 => 'ID ресурса (HMAC-SHA-256)';

  @override
  String get resourceType => 'Тип ресурса';

  @override
  String responseValuevalue(int valueValue) {
    return 'Ответ $valueValue';
  }

  @override
  String get responsesAreSentOnlyForThis =>
      'Ответы отправляются только для этой SSH-аутентификации и не сохраняются.';

  @override
  String get restore => 'Восстановить';

  @override
  String get restoreDeadlinePassedAccordingToThis =>
      'По часам этого устройства срок восстановления истёк; окончательное решение принимает сервер.';

  @override
  String restoreDeadlineFormat3(String format) {
    return 'Срок восстановления $format';
  }

  @override
  String restoreDeadlineFormatTheServerChecks(String format) {
    return 'Срок восстановления: $format. Сервер повторно проверит его при подтверждении.';
  }

  @override
  String get restoreDefaults => 'Восстановить значения по умолчанию';

  @override
  String get restoreIsRestrictedToTheSame =>
      'Восстановление возможно только в то же пространство сервера и сейф. Данные, удалённые сервером, не включаются; храните скачанный архив и пароль отдельно от этого устройства.';

  @override
  String get restorePreparesAnIsolatedCopyWhile =>
      'Восстановление готовит изолированную копию, пока служба работает. Последующее переключение офлайн выполняет оператор.';

  @override
  String get restoreStaging => 'Подготовка восстановления';

  @override
  String restoreStagingAdminrestorejobstatuslabel(
    String adminRestoreJobStatusLabel,
  ) {
    return 'Подготовка восстановления · $adminRestoreJobStatusLabel';
  }

  @override
  String get restoreThisRecord => 'Восстановить эту запись?';

  @override
  String restoreUsernameInGroupDraft(String username) {
    return 'Вернуть $username в черновик группы';
  }

  @override
  String get result => 'Результат';

  @override
  String get resumeSession => 'Возобновить сеанс';

  @override
  String get resumeTmuxSession2 => 'Возобновить сеанс tmux';

  @override
  String get resumeTmuxSession => 'Возобновить сеанс tmux?';

  @override
  String get retry2 => 'Повторить';

  @override
  String get retryAccountInvitations => 'Повторить загрузку приглашений';

  @override
  String get retryAccountList => 'Повторить загрузку учётных записей';

  @override
  String get retryAndVerifyRepair => 'Повторить и проверить исправление';

  @override
  String get retryBackupRequestSafely =>
      'Безопасно повторить запрос резервного копирования';

  @override
  String get retryDiscard => 'Повторить удаление';

  @override
  String get retryDiscardSafely => 'Безопасно повторить удаление';

  @override
  String get retryGroupDetails => 'Повторить загрузку сведений о группе';

  @override
  String get retryGroupList => 'Повторить загрузку списка групп';

  @override
  String get retryPasswordChange => 'Повторить смену пароля';

  @override
  String get retryPending => 'Ожидает повтора';

  @override
  String get retryQueued => 'Повтор поставлен в очередь';

  @override
  String get retryRequestSafely => 'Безопасно повторить запрос';

  @override
  String get retryScheduled => 'Повтор запланирован';

  @override
  String get retrySessionList => 'Повторить загрузку списка сеансов';

  @override
  String get retryWaiting => 'Ожидает повтора';

  @override
  String get retryableFailure7UtcDays =>
      'Сбой с возможностью повтора (7 дней UTC)';

  @override
  String get revealPasswordSecret => 'Показать секрет пароля';

  @override
  String get reviewHostConnectionSettings =>
      'Проверить параметры подключения хоста';

  @override
  String get reviewAndRun => 'Проверить и запустить';

  @override
  String get reviewBatchCommand => 'Проверить пакетную команду';

  @override
  String get reviewCommandExecution => 'Проверить выполнение команды';

  @override
  String get reviewCurrentVersion => 'Проверить текущую версию';

  @override
  String get reviewDeviceEnrollment => 'Проверить регистрацию устройства';

  @override
  String get reviewEachSynchronizedBindingAndRecord =>
      'Проверьте каждую синхронизированную привязку и ID записи. Дубликаты удаляются с помощью зашифрованных меток удаления.';

  @override
  String get reviewKeys => 'Проверить ключи';

  @override
  String get reviewLocalProfileMigration =>
      'Проверить перенос локальных профилей';

  @override
  String reviewOnCountConnectedHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Проверить на $count подключённого хоста',
      many: 'Проверить на $count подключённых хостах',
      few: 'Проверить на $count подключённых хостах',
      one: 'Проверить на $count подключённом хосте',
    );
    return '$_temp0';
  }

  @override
  String get reviewThePaletteAndRecordId =>
      'Проверьте палитру и ID записи. Выбранная запись остаётся активной; дубликаты удаляются с помощью зашифрованных меток удаления.';

  @override
  String get reviewTheSizeAndRecordId =>
      'Проверьте размер и ID записи. Выбранный ID остаётся активным; остальные записи удаляются с помощью зашифрованных меток удаления.';

  @override
  String get reviewTrustedDevices => 'Проверить доверенные устройства';

  @override
  String get reviewUpdate => 'Проверить обновление';

  @override
  String reviewCountHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Проверить $count хоста',
      many: 'Проверить $count хостов',
      few: 'Проверить $count хоста',
      one: 'Проверить $count хост',
    );
    return '$_temp0';
  }

  @override
  String get revokePrometheusScrapeCredential =>
      'Отозвать учётные данные Prometheus для сбора метрик?';

  @override
  String revokeSshHostKeyTrustFor(String endpoint, String fingerprint) {
    return 'Отозвать доверие к ключу SSH-хоста $endpoint ($fingerprint)';
  }

  @override
  String get revokeSshHostKeyTrust2 => 'Отозвать доверие к ключу SSH-хоста?';

  @override
  String get revokeAccess => 'Отозвать доступ';

  @override
  String get revokeAccountInvitation => 'Отозвать приглашение?';

  @override
  String get revokeAllSessions => 'Отозвать все сеансы';

  @override
  String get revokeAllSessions2 => 'Отозвать все сеансы?';

  @override
  String get revokeAndRotateKey => 'Отозвать и сменить ключ';

  @override
  String get revokeCredential => 'Отозвать учётные данные';

  @override
  String get revokeDevice => 'Отозвать устройство';

  @override
  String get revokeDevice2 => 'Отозвать устройство?';

  @override
  String revokeEveryActiveSessionForUsername(String username) {
    return 'Отозвать все активные сеансы $username? Следующий запрос из этих сеансов потребует нового входа.';
  }

  @override
  String get revokeInputControl => 'Отозвать управление вводом';

  @override
  String get revokeInvitation => 'Отозвать приглашение';

  @override
  String get revokeInvitation2 => 'Отозвать приглашение?';

  @override
  String get revokeMemberAccess => 'Отозвать доступ участника?';

  @override
  String get revokeSession => 'Отозвать сеанс';

  @override
  String get revokeSessions => 'Отозвать сеансы';

  @override
  String revokeTheSessionOnDevicenameFor(String deviceName, String username) {
    return 'Отозвать сеанс $username на $deviceName?';
  }

  @override
  String get revokeThisSession => 'Отозвать этот сеанс?';

  @override
  String get revokeTrust2 => 'Отозвать доверие';

  @override
  String get revoked3 => 'Отозвано';

  @override
  String get revokedAt => 'Отозвано';

  @override
  String revokedFormat(String format) {
    return 'Отозвано $format';
  }

  @override
  String revokedFormat2(String format) {
    return 'Отозвано · $format';
  }

  @override
  String get role => 'Роль';

  @override
  String get rotatePrometheusScrapeCredential =>
      'Сменить учётные данные Prometheus для сбора метрик?';

  @override
  String get rotateCredential => 'Сменить учётные данные';

  @override
  String get rotateKeyAndChangeRole => 'Сменить ключ и изменить роль?';

  @override
  String get rotateRecoveryCode => 'Обновить код восстановления';

  @override
  String get rotationImmediatelyInvalidatesTheCurrentCredential =>
      'Ротация сразу делает текущие учётные данные недействительными. Скопировав новое значение, обновите конфигурацию сбора Prometheus — оно будет показано только один раз.';

  @override
  String get runEncryptedBackup =>
      'Запустить зашифрованное резервное копирование';

  @override
  String get runMaintenanceNow => 'Запустить обслуживание сейчас';

  @override
  String get running => 'Выполняется';

  @override
  String get runningOnceThroughANonPty =>
      'Однократный запуск через канал SSH exec без PTY. Вывод ограничен 64 КиБ.';

  @override
  String get scpUpload => 'Отправка по SCP…';

  @override
  String get scpDownload => 'Загрузка по SCP…';

  @override
  String get scpFileManager => 'Файловый менеджер SCP';

  @override
  String get sftpFileBrowser => 'Файловый браузер SFTP';

  @override
  String get sftpFileManager => 'Файловый менеджер SFTP';

  @override
  String get socks5ConnectOnlyNoSocksUser =>
      'Только SOCKS5 CONNECT, без аутентификации пользователей SOCKS. Прокси слушает loopback-адрес этого устройства.';

  @override
  String get sshRelayConnected => 'SSH Relay подключён';

  @override
  String get sshTerminal => 'SSH-терминал';

  @override
  String get sshAuthenticationChallenge => 'Запрос SSH-аутентификации';

  @override
  String get sshConnected => 'SSH подключён';

  @override
  String get sshConnecting => 'SSH подключается';

  @override
  String get sshConnectionFailed => 'Не удалось подключиться по SSH';

  @override
  String get sshCredentials => 'Учётные данные SSH';

  @override
  String get sshDisconnected => 'SSH отключён';

  @override
  String get sshExecFailedAfterDispatchThe =>
      'SSH exec завершился ошибкой после отправки. Команда могла начаться; её завершение на удалённой стороне неизвестно. Повтор не выполнялся.';

  @override
  String get sshHostKeyChangesAreRejected =>
      'После первого проверенного доверия изменения ключа SSH-хоста отклоняются.';

  @override
  String sshHostKeyFingerprintFingerprint(String fingerprint) {
    return 'Отпечаток ключа SSH-хоста: $fingerprint';
  }

  @override
  String get sshHostKeyTrust => 'Доверие к ключам SSH-хостов';

  @override
  String get sshPortForwarding => 'Переадресация портов SSH';

  @override
  String get sshRelay => 'SSH-ретранслятор';

  @override
  String get sshRelayPolicy => 'Политика SSH-ретранслятора';

  @override
  String get sshSessionIsDisconnected => 'SSH-сеанс отключён.';

  @override
  String get sshTerminalInput => 'Ввод в SSH-терминал';

  @override
  String get sshUsername => 'Имя пользователя SSH';

  @override
  String get sshHostTrust => 'Доверие к SSH-хостам';

  @override
  String sameOnBothBranchesValuevalue(String valueValue) {
    return 'Одинаково в обеих ветках · $valueValue';
  }

  @override
  String get save => 'Сохранить';

  @override
  String get saveConflictBranchAsWorkspaceCopy =>
      'Сохранить ветку конфликта как копию рабочего пространства';

  @override
  String get saveCurrentTabs => 'Сохранить текущие вкладки';

  @override
  String get saveEncryptedCredential2 =>
      'Сохранить зашифрованные учётные данные';

  @override
  String get saveEncryptedGroup => 'Сохранить зашифрованную группу';

  @override
  String get saveEncryptedProfile => 'Сохранить зашифрованный профиль';

  @override
  String get saveGroupOverride => 'Сохранить переопределение группы';

  @override
  String get saveLocalLayoutAsNamedCopy =>
      'Сохранить локальный макет как именованную копию';

  @override
  String get saveMembership => 'Сохранить членство';

  @override
  String get saveMergedCredential => 'Сохранить объединённые учётные данные';

  @override
  String get saveOverride => 'Сохранить переопределение';

  @override
  String get saveQuota => 'Сохранить квоту';

  @override
  String get saveRelayPolicy => 'Сохранить политику ретрансляции';

  @override
  String get saveReviewedTuple => 'Сохранить проверенный набор';

  @override
  String get saveSchedule => 'Сохранить расписание';

  @override
  String get saveShortcuts2 => 'Сохранить сочетания клавиш';

  @override
  String get saveSnippet => 'Сохранить сниппет';

  @override
  String get saveSplitWorkspace => 'Сохранить разделённое рабочее пространство';

  @override
  String get saveSyncedPreference => 'Сохранить синхронизируемую настройку';

  @override
  String get saveTerminalColorTheme => 'Сохранить цветовую тему терминала';

  @override
  String get saveTerminalFontSize2 => 'Сохранить размер шрифта терминала';

  @override
  String get saveThisCredentialNow => 'Сохраните эти учётные данные сейчас';

  @override
  String get saveWorkspace => 'Сохранить рабочее пространство';

  @override
  String savedAsItemThisPreferenceIs(Object item) {
    return 'Сохранено как $item. Настройка зашифрована в активном сейфе и синхронизируется на его авторизованные устройства.';
  }

  @override
  String savedCheckpointShortkey(String shortKey) {
    return 'Сохранённая контрольная точка: $shortKey';
  }

  @override
  String get savedSettingsCanOnlyNarrowThe =>
      'Сохранённые настройки могут только сужать неизменяемые ограничения, заданные оператором сервера.';

  @override
  String get savedWorkspaces => 'Сохранённые рабочие пространства';

  @override
  String savedFontsizePxThisEncryptedPreference(int fontSize) {
    return 'Сохранено: $fontSize px. Эта зашифрованная настройка синхронизируется на устройства с доступом к сейфу.';
  }

  @override
  String savedLabelThisEncryptedPreferenceWill(String label) {
    return 'Сохранено: $label. Эта зашифрованная настройка синхронизируется на устройства с доступом к сейфу.';
  }

  @override
  String get savingAndPreviewingDoNotConnect =>
      'Сохранение и предпросмотр не выполняют подключение. Выберите панель и разделите её, чтобы добавить ещё один хост.';

  @override
  String get scheduleVaultDeletion => 'Запланировать удаление сейфа';

  @override
  String get scheduleVaultDeletion2 => 'Запланировать удаление сейфа?';

  @override
  String get scheduleAccountDeletion => 'Запланировать удаление учётной записи';

  @override
  String get scheduleAccountDeletion2 =>
      'Запланировать удаление учётной записи?';

  @override
  String get scheduleDeletion => 'Запланировать удаление';

  @override
  String get scheduledEncryptedBackups =>
      'Плановое зашифрованное резервное копирование';

  @override
  String get scheduledFor => 'Запланировано на';

  @override
  String get scriptBody2 => 'Текст скрипта';

  @override
  String get searchThisHostsCompletedCommandsPlain =>
      'Поиск выполненных команд этого хоста, простых сниппетов Bash и локальных имён команд Bash. Выбор подсказки вводит одну строку в позиции курсора терминала; Enter никогда не нажимается.';

  @override
  String searchValuevalueScrollback(String valueValue) {
    return 'Поиск в истории прокрутки $valueValue';
  }

  @override
  String get secureTerminalWorkspace =>
      'Защищённое рабочее пространство терминала';

  @override
  String get securityPolicy => 'Политика безопасности';

  @override
  String get selectAnActiveVaultBeforeEnabling =>
      'Выберите активный сейф, прежде чем включать синхронизацию.';

  @override
  String get selectFirstHost => 'Выберите первый хост';

  @override
  String get selectedArchive => 'Выбранный архив';

  @override
  String get selectedServerManagedGroup =>
      'Выбранная группа, управляемая сервером';

  @override
  String selectedStateValuevalueCidrsSummarizePorts(
    String valueValue,
    String summarize,
    String summarize2,
  ) {
    return 'Выбранное состояние: $valueValue · CIDR: $summarize · порты: $summarize2';
  }

  @override
  String get sendANewInvitationFromSettings =>
      'Отправьте новое приглашение в «Настройки» > «Пригласить участника».';

  @override
  String get sendResponses => 'Отправить ответы';

  @override
  String get serverBackupConfigurationNotReady =>
      'Настройка резервного копирования на сервере не готова';

  @override
  String get serverBackupConfigurationReady =>
      'Настройка резервного копирования на сервере готова';

  @override
  String get serverGenerationUnknown => 'Поколение сервера неизвестно';

  @override
  String get serverSpaceId => 'ID пространства на сервере';

  @override
  String serverSpaceServerspaceid(String serverSpaceId) {
    return 'Пространство сервера: $serverSpaceId';
  }

  @override
  String get serverManagedAccessGroups =>
      'Группы доступа, управляемые сервером';

  @override
  String get serverManagedGroupActionFailed =>
      'Действие с группой, управляемой сервером, не выполнено';

  @override
  String get serverManagedGroupSaveFailed =>
      'Не удалось сохранить группу, управляемую сервером';

  @override
  String serverLocalConflictBranchesConflictcount(int conflictCount) {
    return 'Ветки конфликтов сервера и локальные: $conflictCount';
  }

  @override
  String get sessionId => 'ID сеанса';

  @override
  String get setTheIntervalBelowThenSave =>
      'Задайте интервал ниже и сохраните изменения.';

  @override
  String setTheSharedTerminalTextSize(
    String join,
    int defaultTerminalFontSize,
  ) {
    return 'Задайте общий размер текста терминала для этого сейфа. Допустимые размеры: $join px. По умолчанию: $defaultTerminalFontSize px.';
  }

  @override
  String get setUpAccountRecovery => 'Настроить восстановление учётной записи';

  @override
  String get setUpRecovery => 'Настроить восстановление';

  @override
  String get shareThisTerminal => 'Поделиться этим терминалом';

  @override
  String get sharedTerminalOutputReadOnly =>
      'Общий вывод терминала, только чтение';

  @override
  String get sharedTerminalHostApprovedControl =>
      'Общий терминал · управление с одобрения хоста';

  @override
  String get sharedTerminalReadOnly => 'Общий терминал · только чтение';

  @override
  String get shellLabel2 => 'Метка оболочки';

  @override
  String shellLabelShellSentToThe(String shell) {
    return 'Метка оболочки: $shell · отправляется в активный SSH PTY';
  }

  @override
  String showingCountLocalArchivesOnThis(int count) {
    return 'Локальных архивов на этой странице: $count';
  }

  @override
  String showingFirstLastOfAdmincountAccounts(
    int first,
    int last,
    String adminCount,
  ) {
    return 'Показаны учётные записи $first–$last из $adminCount';
  }

  @override
  String showingFirstLastOfAdmincountInvitations(
    int first,
    int last,
    String adminCount,
  ) {
    return 'Показаны приглашения $first–$last из $adminCount';
  }

  @override
  String showingFirstLastOfAdmincountSessions(
    int first,
    int last,
    String adminCount,
  ) {
    return 'Показаны сеансы $first–$last из $adminCount';
  }

  @override
  String showingStartEndOfAdmincountVaults(
    int start,
    int end,
    String adminCount,
  ) {
    return 'Показаны сейфы $start–$end из $adminCount';
  }

  @override
  String showingValuevalueValuevalue2OfTotal(
    int valueValue,
    int valueValue2,
    int total,
  ) {
    return 'Показаны $valueValue–$valueValue2 из $total';
  }

  @override
  String get showsTheLatestCompletedBackupAttempt =>
      'Показывает последнюю завершённую попытку резервного копирования, записанную этим сервером. Размер может быть неизвестен, если архив больше недоступен этому узлу. Это не подтверждает, что архив существует и что изолированное восстановление пройдёт успешно.';

  @override
  String get sideBySide => 'Рядом';

  @override
  String get sideBySideLeftRight => 'Рядом (слева/справа)';

  @override
  String get signAndCreateInvitation => 'Подписать и создать приглашение';

  @override
  String get signInNeeded => 'Требуется вход';

  @override
  String get signedVaultShareRequest => 'Подписанный запрос на доступ к сейфу';

  @override
  String get signedShareRequestCopied =>
      'Подписанный запрос на доступ скопирован.';

  @override
  String get signingKeyFingerprint => 'Отпечаток ключа подписи';

  @override
  String get signingKeyFingerprintSha256 => 'Отпечаток ключа подписи · SHA-256';

  @override
  String get snapshotExceedsClientLimit => 'Снимок превышает лимит клиента';

  @override
  String get snapshotGenerated => 'Снимок создан';

  @override
  String get snapshotLimitReached => 'Достигнут лимит снимка';

  @override
  String get snapshotNeeded => 'Нужен снимок';

  @override
  String get snapshotSizeLimit => 'Лимит размера снимка';

  @override
  String get snapshotVerificationIsInProgressLocal =>
      'Выполняется проверка снимка. Локальные правки приостановлены; кэш и очередь отправки сохраняются, пока не будет проверен весь манифест.';

  @override
  String get snippet2 => 'Сниппет';

  @override
  String get snippetScriptIsRequired => 'Скрипт сниппета обязателен';

  @override
  String get snippetTitleIsRequired => 'Название сниппета обязательно';

  @override
  String snippetTitle3(String title) {
    return 'Сниппет: $title';
  }

  @override
  String get source => 'Источник';

  @override
  String get splitWorkspaceSavedEncryptedToThis =>
      'Разделённое рабочее пространство сохранено в этом сейфе в зашифрованном виде.';

  @override
  String splitControlsCountDividersEachRatio(int count) {
    return 'Управление разделением · разделителей: $count · каждая пропорция задаёт размер первого элемента';
  }

  @override
  String get splitSelectedPane => 'Разделить выбранную панель';

  @override
  String splitValuevalue(int valueValue) {
    return 'Разделение $valueValue';
  }

  @override
  String splitValuevalueAxisFirstpercentValuevalue2(
    int valueValue,
    String axis,
    int firstPercent,
    int valueValue2,
  ) {
    return 'Разделение $valueValue · $axis · $firstPercent/$valueValue2';
  }

  @override
  String splitFirstpercentSecondpercent(int firstPercent, int secondPercent) {
    return 'Разделение · $firstPercent/$secondPercent';
  }

  @override
  String get stacked => 'Друг над другом';

  @override
  String get stackedTopBottom => 'Друг над другом (сверху/снизу)';

  @override
  String get stageId => 'ID подготовки';

  @override
  String get startForwarding => 'Начать переадресацию';

  @override
  String get startResumableSession => 'Начать возобновляемый сеанс';

  @override
  String get startResumableTmuxSession => 'Начать возобновляемый сеанс tmux?';

  @override
  String get startSession => 'Начать сеанс';

  @override
  String get startSharing => 'Начать общий доступ';

  @override
  String get startedAt => 'Начало';

  @override
  String get stopAuthentication => 'Остановить аутентификацию';

  @override
  String get stopForwarding => 'Остановить переадресацию';

  @override
  String get stopLocalCapture => 'Остановить локальную запись';

  @override
  String get stopTerminalSharing => 'Остановить общий доступ к терминалу';

  @override
  String get stopThisForwardBeforeEditingIts =>
      'Остановите эту переадресацию, прежде чем менять её профиль.';

  @override
  String get storeYourRecoveryCode => 'Сохраните код восстановления';

  @override
  String get stored => 'Сохранено';

  @override
  String get storedData => 'Хранимые данные';

  @override
  String get structuredBashCommand2 => 'Структурированная команда Bash';

  @override
  String get submitBackupRequest => 'Отправить запрос резервного копирования';

  @override
  String get submittingBackup => 'Отправка резервного копирования…';

  @override
  String get succeeded2 => 'Успешно';

  @override
  String get syncCommandHistoryToVault =>
      'Синхронизировать историю команд с сейфом';

  @override
  String get syncCommandHistoryToThisVault =>
      'Синхронизировать историю команд с этим сейфом?';

  @override
  String get syncError => 'Ошибка синхронизации';

  @override
  String get syncHealth => 'Состояние синхронизации';

  @override
  String get syncNow => 'Синхронизировать сейчас';

  @override
  String get syncPendingChanges => 'Синхронизировать ожидающие изменения';

  @override
  String get syncServiceError => 'Ошибка службы синхронизации';

  @override
  String get syncStatus => 'Состояние синхронизации';

  @override
  String get syncing => 'Синхронизация';

  @override
  String get thisDevice => 'ЭТО УСТРОЙСТВО';

  @override
  String tabValuevalue(int valueValue) {
    return 'Вкладка $valueValue';
  }

  @override
  String tabValuevalueMissingHost(int valueValue) {
    return 'Вкладка $valueValue · хост отсутствует';
  }

  @override
  String tabValuevalueName(int valueValue, String name) {
    return 'Вкладка $valueValue · $name';
  }

  @override
  String get tagsSeparatedByCommas => 'Теги через запятую';

  @override
  String targetValuevalueOfCountValuevalue2(
    int valueValue,
    int count,
    String valueValue2,
  ) {
    return 'Цель $valueValue из $count: $valueValue2';
  }

  @override
  String targetValuevalueHostnameEndpoint(
    int valueValue,
    String hostName,
    String endpoint,
  ) {
    return 'Цель $valueValue: $hostName · $endpoint';
  }

  @override
  String targetHostnameEndpoint(String hostName, String endpoint) {
    return 'Цель: $hostName · $endpoint';
  }

  @override
  String get targetsRunSequentiallyNoTargetStarts =>
      'Цели выполняются по очереди. Ни одна не начнётся, пока не подтверждена полная проверка. Пакет останавливается на первом ненулевом или неизвестном результате и не повторяется.';

  @override
  String get terminal => 'Терминал';

  @override
  String get terminalColorTheme => 'Цветовая тема терминала';

  @override
  String get terminalFontSize3 => 'Размер шрифта терминала';

  @override
  String terminalFontSizeValuevaluePxRecord(
    Object valueValue,
    String id,
    String revisionLabel,
  ) {
    return 'Размер шрифта терминала: $valueValue px; ID записи: $id; версия: $revisionLabel';
  }

  @override
  String get terminalHistory => 'История терминала';

  @override
  String get terminalKeyboardShortcuts => 'Сочетания клавиш терминала';

  @override
  String terminalPanesCountMaxworkspacepanes(int count, int maxWorkspacePanes) {
    return 'Панели терминала · $count/$maxWorkspacePanes';
  }

  @override
  String terminalSharePhase(String phase) {
    return 'Общий терминал: $phase';
  }

  @override
  String terminalThemeThemelabelRecordIdId(
    String themeLabel,
    String id,
    String valueValue,
  ) {
    return 'Тема терминала: $themeLabel; ID записи: $id; версия: $valueValue';
  }

  @override
  String get theHostConflictCanNoLonger =>
      'Этот конфликт хоста больше нельзя безопасно проверить.';

  @override
  String get theSshServerGatewayportsSettingMay =>
      'Параметр GatewayPorts на SSH-сервере может расширить этот запрос привязки к loopback. Проверьте настройки сервера перед использованием удалённой переадресации.';

  @override
  String get theSshServerRequestedTooMany =>
      'SSH-сервер запросил слишком много ответов. Аутентификация остановлена.';

  @override
  String get theVaultChangedReopenPortForwarding =>
      'Сейф изменился; откройте переадресацию портов заново.';

  @override
  String get theVaultOrOneOfThe =>
      'Сейф или один из выбранных хостов больше недоступен.';

  @override
  String get theArchiveHasPassedSignatureMembership =>
      'Архив прошёл проверки подписи, членства, конвертов, хешей объектов и схемы. Импорт объединяет данные только с этим сейфом. Отсутствующие зашифрованные объекты могут быть отправлены в тот же сейф; токены сеансов и закрытые ключи устройств не импортируются. Записи очереди отправки, созданные другим устройством, остаются локальными конфликтами и не воспроизводятся от имени этого устройства.';

  @override
  String get theCommittedHostChangedAfterThis =>
      'После этого предпросмотра зафиксированный хост изменился. Правки не подготовлены; проверьте последнюю голову и выберите заново.';

  @override
  String get theCommittedHostChangedReviewIts =>
      'Зафиксированный хост изменился. Перед объединением проверьте его последние параметры подключения.';

  @override
  String get theCommittedVaultVersionChangedReview =>
      'Зафиксированная версия сейфа изменилась. Проверьте её ещё раз перед объединением.';

  @override
  String get theCredentialIsNoLongerAvailable =>
      'Эти учётные данные больше недоступны в этом сеансе. Если ротация завершена, проверьте статус и выполните ротацию снова, чтобы получить новое одноразовое значение.';

  @override
  String get theCurrentVaultVersionChangedWhile =>
      'Пока вы проверяли, текущая версия сейфа изменилась, и ваш выбор сброшен. Проверьте текущую версию и выберите снова.';

  @override
  String get theDefaultPreferenceWasConfirmedAfter =>
      'Настройка по умолчанию подтверждена после синхронизации сейфа.';

  @override
  String get theDeploymentGateIsAvailableWith =>
      'Переключатель развёртывания доступен при ATERMIUS_RELAY_ENABLED=true. Фактическое разрешение всегда ограничено настроенными CIDR и портами.';

  @override
  String get theExportContainsARandomReport =>
      'Экспорт содержит случайный ID отчёта, фиксированный код ошибки, версию клиента, счётчики синхронизации и даты с точностью до дня UTC. Записи сейфа, сведения об учётной записи, адреса серверов и идентификаторы устройств никогда не включаются.';

  @override
  String get theFullScriptIsReviewedBefore =>
      'Весь скрипт проверяется перед отправкой в активный PTY.';

  @override
  String get theLastResponseWasNotConfirmed =>
      'Последний ответ не подтверждён. Возможно, сервер уже сменил пароль. Повтор отправит точно такой же запрос; пароли для повтора не сохраняются. Запомните новый пароль. Выход из учётной записи удаляет этот повторный запрос.';

  @override
  String get theLocalBranchAndItsOriginal =>
      'Локальная ветка и её исходная база CAS хранятся зашифрованными в локальном хранилище. В снимке нет текущей удалённой головы для этой записи; сохранение локальной ветки создаст новую корневую версию.';

  @override
  String get theLocalLayoutBranchWasSaved =>
      'Локальная ветка макета сохранена как новое зашифрованное рабочее пространство.';

  @override
  String get theOperatingSystemWillAskFor =>
      'Система запросит разрешение на уведомления только при включении. Данные сейфа по-прежнему синхронизируются через аутентифицированный WebSocket или опрос.';

  @override
  String get theOptInRemoteBashHook =>
      'Необязательный удалённый хук Bash хранит до 500 выполненных команд в зашифрованном локальном хранилище. Удалённый хост может подделывать записи OSC. Запросы пароля не читаются, но секреты, введённые как текст команды, могут быть записаны. «Остановить локальную запись» игнорирует новые события; чтобы остановить хук, выполните \"atermius_off\" в Bash или закройте оболочку.';

  @override
  String get thePasswordStaysInThisForm =>
      'Пароль остаётся в этой форме и никогда не отправляется.';

  @override
  String thePendingInvitationForUsernameWill(String username) {
    return 'Ожидающее приглашение для $username больше не будет приниматься.';
  }

  @override
  String get thePreviousCodeWasNotConfirmed =>
      'Сохранение предыдущего кода не подтверждено. Обновите восстановление, чтобы показать новый код.';

  @override
  String get theSavedPolicyExceedsTheCurrent =>
      'Сохранённая политика превышает текущие лимиты развёртывания; фактическое разрешение остаётся ограничено текущими лимитами. Сузьте CIDR и порты ниже перед сохранением; для работы службы также нужен ATERMIUS_RELAY_ENABLED=true.';

  @override
  String get theSavedPolicyRemainsSelectedAs =>
      'Сохранённая политика остаётся включённой, но фактическая служба ретрансляции недоступна, пока переключатель развёртывания выключен. Требуется ATERMIUS_RELAY_ENABLED=true; отключите этот выбор, прежде чем сохранять другие изменения. Веб-интерфейс не может изменить этот переключатель.';

  @override
  String get theSecretIsReadFromThe =>
      'Секрет считывается из зашифрованных учётных данных при запуске сниппета и никогда не копируется в запись или предпросмотр сниппета.';

  @override
  String get theSelectedDefaultPreferenceWasConfirmed =>
      'Выбранная настройка по умолчанию подтверждена после синхронизации сейфа.';

  @override
  String get theSelectedShortcutBindingsWereConfirmed =>
      'Выбранные привязки клавиш подтверждены после синхронизации сейфа.';

  @override
  String get theSelectedTerminalFontSizeWas =>
      'Выбранный размер шрифта терминала подтверждён после синхронизации сейфа.';

  @override
  String get theSelectedTerminalThemeWasConfirmed =>
      'Выбранная тема терминала подтверждена после синхронизации сейфа.';

  @override
  String get theServerCanCopyEncryptedInstance =>
      'Сервер может копировать зашифрованные архивы экземпляра в S3-совместимое хранилище, настроенное оператором. Адрес назначения и учётные данные остаются на сервере. Проверка доступа выполняет только HeadBucket и не проверяет загрузку, многочастные операции, восстановление или совместимость с провайдером в целом.';

  @override
  String get theServerDeploymentGateMustAlso =>
      'Также должен быть включён соответствующий переключатель развёртывания на сервере.';

  @override
  String get theServerDidNotRequestA => 'Сервер не запросил ответ.';

  @override
  String get theServerFirstValidatesThatThis =>
      'Сначала сервер проверяет, что эта копия и её квитанция относятся к данному заданию восстановления; если проверить не удаётся, файлы не трогаются. Подтверждённая очистка безвозвратно удаляет только эту изолированную копию; исходный зашифрованный архив и рабочие данные службы не меняются. Позже можно подготовить новую изолированную копию из исходного архива.';

  @override
  String get theServerReceivesPasswordDerivedVerifiers =>
      'Сервер получает производные от пароля верификаторы и заново зашифрованный конверт ключа учётной записи. Мастер-пароль и ключ учётной записи остаются на этом устройстве.';

  @override
  String get theServerRequiresANewerWeb =>
      'Серверу требуется более новый протокол веб-клиента.';

  @override
  String get theServerRequiresANewerClient =>
      'Серверу требуется более новый протокол клиента. Убедитесь, что развёрнута нужная совместимая веб-сборка.';

  @override
  String theServerRestorePeriodHasNot2(String deadlineText) {
    return 'Срок восстановления на сервере ещё не истёк.$deadlineText Обновите корзину и повторите попытку позже.';
  }

  @override
  String get theServerWillDeleteTheEncrypted =>
      'Сервер удалит зашифрованный пакет восстановления и все ящики ключей восстановления. Чтобы настроить его снова, понадобится одобренное устройство.';

  @override
  String get theServerWillStartItsConfigured =>
      'Сервер запустит настроенный льготный период. Все активные участники сразу перейдут в режим только чтения; чтение доступно до срока сервера. До срока создайте и сохраните отдельно переносимый зашифрованный архив; этот клиент восстанавливает данные только в то же пространство сервера и сейф. После подтверждения сервер сообщит точное время удаления.';

  @override
  String get theServiceStaysOnlineWhileIt =>
      'Служба остаётся в сети, пока готовит отдельную копию из выбранного локального архива. В рабочей базе записываются задание восстановления и событие аудита, используется блокировка обслуживания, но активные данные учётных записей, сейфов, сеансов и поколений не меняются, а рабочие данные не активируются и не заменяются. Перед публикацией изолированной копии воркер повторно проверяет архив.';

  @override
  String get theServiceStaysOnlineWhileIt2 =>
      'Служба остаётся в сети, пока готовит отдельную копию. В рабочей базе записываются задание восстановления и событие аудита, используется блокировка обслуживания, но активные данные учётных записей, сейфов, сеансов и поколений не меняются, а рабочие данные не активируются и не заменяются. Перед публикацией изолированной копии воркер повторно проверяет выбранный локальный или удалённый архив.';

  @override
  String get theShareExpiresAfter15Minutes =>
      'Доступ истекает через 15 минут. Вывод терминала и события изменения размера шифруются для каждого выбранного устройства.';

  @override
  String get theSyncCursorExpiredOrThe =>
      'Курсор синхронизации истёк или поколение сервера изменилось. Перестройте кэш из проверенного снимка; ожидающие локальные операции сохраняются и сравниваются с удалёнными головами.';

  @override
  String get theTerminalChangedBeforeTheSuggestion =>
      'Терминал изменился до вставки подсказки. Откройте подсказки снова и повторите попытку.';

  @override
  String get theUpdateCheckCouldNotConfirm =>
      'Проверке обновлений не удалось подтвердить текущую веб-сборку.';

  @override
  String get theseInstanceGroupsControlSshRelay =>
      'Эти группы экземпляра управляют доступом к SSH Relay. Они не связаны с зашифрованными группами рабочего пространства и не содержат данных сейфа.';

  @override
  String get thisGroupDefaultIsUnavailableChoose =>
      'Значение по умолчанию этой группы недоступно. Выберите «без значения по умолчанию» или действительные учётные данные.';

  @override
  String get thisHostConflictHasNoSafely =>
      'У этого конфликта хоста нет набора параметров подключения, который можно безопасно проверить. Используйте действия с проверенными ветками.';

  @override
  String thisSshKeyIsNotTrusted(String endpoint) {
    return 'Этот SSH-ключ не является доверенным для $endpoint. Перед принятием сверьте его отпечаток по доверенному каналу.';
  }

  @override
  String get thisVaultIsReadOnlyFor =>
      'Для текущей учётной записи этот сейф доступен только для чтения. Чтение доступно там, где это разрешает сервер. Переносимый зашифрованный архив можно создать в настройках.';

  @override
  String get thisVaultIsReadOnlyMember =>
      'Сейф доступен только для чтения; изменение участников недоступно.';

  @override
  String get thisVaultIsReadOnlyYou =>
      'Сейф доступен только для чтения. Настройку можно просматривать, но не изменять.';

  @override
  String get thisVaultIsReadOnlyYou2 =>
      'Сейф доступен только для чтения. Общие сочетания клавиш можно просматривать, но не изменять.';

  @override
  String get thisVaultIsReadOnlyYou3 =>
      'Сейф доступен только для чтения. Общую цветовую тему терминала можно просматривать, но не изменять.';

  @override
  String get thisVaultIsReadOnlyYou4 =>
      'Сейф доступен только для чтения. Общий размер шрифта терминала можно просматривать, но не изменять.';

  @override
  String get thisWebBuildIsCurrent => 'Эта веб-сборка актуальна.';

  @override
  String get thisAccountHasNoVaultAvailable =>
      'У этой учётной записи нет сейфов, доступных на этом устройстве. Создайте новый зашифрованный сейф, примите приглашение от участника или попросите владельца восстановить доступ. Существующие зашифрованные данные хранятся отдельно от нового сейфа.';

  @override
  String get thisAttachesTheCurrentSshPane =>
      'Текущая SSH-панель будет подключена к сохранённому сеансу tmux. Другие подключённые клиенты останутся подключены.';

  @override
  String get thisCardContainsTheAccountAnd =>
      'Карточка содержит открытые ключи учётной записи и устройства и подпись-самоподтверждение. Закрытого ключа и ключа сейфа в ней нет. Отправьте её владельцу сейфа по доверенному каналу.';

  @override
  String get thisCodeIsShownOnceAnyone =>
      'Этот код показывается один раз. Любой, у кого он есть, может восстановить ключи сейфов этой учётной записи. Сохраните его в менеджере паролей или другом надёжном месте. Этот клиент его никогда не сохраняет.';

  @override
  String get thisConflictNoLongerSupportsPassword =>
      'Этот конфликт больше не поддерживает объединение полей паролей. Используйте действия с проверенными ветками.';

  @override
  String get thisCreatesATmuxSessionOn =>
      'На текущем SSH-хосте будет создан сеанс tmux, а ссылка на него сохранится в этом зашифрованном рабочем пространстве.';

  @override
  String get thisDeviceLoopbackOnly => 'Только loopback этого устройства';

  @override
  String get thisExactFingerprintWasRevokedBefore =>
      'Именно этот отпечаток ранее был отозван. Повторное одобрение создаст новую зашифрованную запись доверия в сейфе и синхронизирует её на устройства. Перед продолжением проверьте его по отдельному каналу.';

  @override
  String get thisFormNeverSubmitsCredentialText =>
      'Эта форма никогда не отправляет текст учётных данных напрямую на сервер.';

  @override
  String thisGrantsRoleAccessToAll(String role) {
    return 'Это предоставит доступ $role ко всем зашифрованным записям этого сейфа. Текущий ключ сейфа запечатывается для этого устройства, а владелец подписывает новую версию членства. Перед продолжением сверьте с получателем учётную запись и оба отпечатка.';
  }

  @override
  String get thisGroupChangedOnAnotherDevice =>
      'Группа изменена на другом устройстве. Синхронизируйте и откройте её заново, затем повторите попытку.';

  @override
  String get thisGroupHasNoMembers => 'В этой группе нет участников.';

  @override
  String get thisImmediatelyRevokesEverySessionAnd =>
      'Это сразу отзывает все сеансы и устройства. В срок окончательного удаления на сервере личные сейфы и данные учётной записи удаляются, а ваш доступ к общим сейфам прекращается. Данные общих сейфов других участников не удаляются.';

  @override
  String get thisInstance => 'Этот экземпляр';

  @override
  String get thisInvitationWasInvalidatedAfterA =>
      'Приглашение стало недействительным после изменения членства в сейфе. Отправьте новое в «Настройки» > «Пригласить участника».';

  @override
  String get thisInvitationsValidityCouldNotBe =>
      'Не удалось подтвердить действительность приглашения. Отправьте новое в «Настройки» > «Пригласить участника».';

  @override
  String get thisIsABearerTokenShare =>
      'Это токен на предъявителя. Передавайте его только нужному получателю по доверенному каналу. Он показывается один раз и привязан к целевой учётной записи и устройству.';

  @override
  String get thisIsOptInAndBash =>
      'Это необязательно и только для Bash. Файлы запуска оболочки не меняются, удалённые файлы не записываются. Скопируйте команду, вставьте её в подключённую оболочку и нажмите Enter. Выполненные команды хранятся на этом устройстве в зашифрованном виде (до 500). Удалённый хост может подделывать записи. Запросы пароля не читаются, но секреты, введённые как текст команды, могут быть записаны.';

  @override
  String get thisMobileAppBuildHasNo =>
      'В этой сборке мобильного приложения не настроен проект Firebase. Соберите приложение с его параметрами Firebase, чтобы включить регистрацию токенов провайдера. Для доставки FCM проект Firebase должен совпадать с проектом сервисного аккаунта сервера; доставка APNs на iOS использует настройки APNs сервера. Синхронизация через WebSocket и опрос остаётся доступной.';

  @override
  String get thisPasswordIsUsedOnlyTo =>
      'Этот пароль используется только для расшифровки архива.';

  @override
  String thisRecordsConsentForThisExact(String recordDisplayName) {
    return 'Согласие записывается только для этой метки удаления ($recordDisplayName). При согласии ограниченное обслуживание может автоматически удалить её после срока восстановления и других обязательных проверок. Включение согласия не удаляет её немедленно.';
  }

  @override
  String get thisRecordsDeletedVersionChangedThe =>
      'Удалённая версия этой записи изменилась. Корзина обновляется; проверьте её, прежде чем повторять.';

  @override
  String get thisRemovesTheEncryptedWorkspaceReference =>
      'Удаляется зашифрованная ссылка в рабочем пространстве. Удалённый сеанс tmux не останавливается и не удаляется.';

  @override
  String get thisRequestBelongsToAnotherAccount =>
      'Этот запрос относится к другой учётной записи.';

  @override
  String get thisServerBackendDoesNotSupport =>
      'Бэкенд этого сервера пока не поддерживает окончательное удаление записей. Удаление не выполнено.';

  @override
  String get thisServerIsNotCurrentlyAccepting =>
      'Этот сервер сейчас не принимает запросы на восстановление. Существующая изолированная копия и рабочие данные не изменены.';

  @override
  String thisSettingIsEncryptedInCurrentvaultname(String currentVaultName) {
    return 'Этот параметр зашифрован в $currentVaultName и синхронизируется на устройства с доступом к сейфу.';
  }

  @override
  String thisSettingIsStoredAsAn(String currentVaultName) {
    return 'Этот параметр хранится как зашифрованная запись в $currentVaultName и синхронизируется с этим сейфом.';
  }

  @override
  String get thisSignedOutboxBranchCameFrom =>
      'Эта подписанная ветка очереди отправки пришла с другого устройства. Её ID операции и конверт сохраняются локально, но это устройство не воспроизводит её под другой подписью. Сохранение локальной ветки создаст новую версию, подписанную этим устройством.';

  @override
  String get thisSnapshotExceedsThisClientsLimit =>
      'Снимок превышает лимит клиента: 64 МиБ сериализованного манифеста или 100 000 голов. Кэш, контрольная точка и ожидающая очередь отправки сохранены. Повтор восстановления не поможет; за рекомендациями по миграции обратитесь к сопровождающему проекта.';

  @override
  String get title => 'Название';

  @override
  String get toEnableSshRelayTheServer =>
      'Чтобы включить SSH-ретранслятор, оператор сервера должен задать ATERMIUS_RELAY_ENABLED=true и настроить лимиты развёртывания. Веб-интерфейс не может изменить этот переключатель.';

  @override
  String get topLevelGroup2 => 'Группа верхнего уровня';

  @override
  String get transferVaultOwnership => 'Передать владение сейфом?';

  @override
  String get transferAndRotateKey => 'Передать и сменить ключ';

  @override
  String get transferOwnership => 'Передать владение';

  @override
  String get trustAfterVerification => 'Доверять после проверки';

  @override
  String get trustedDevices => 'Доверенные устройства';

  @override
  String get typeDeleteToConfirm => 'Введите DELETE для подтверждения';

  @override
  String get typeEnableAutomaticPurge => 'Введите ENABLE AUTOMATIC PURGE';

  @override
  String get typeACommandFragmentToSee =>
      'Введите часть команды, чтобы увидеть подсказки.';

  @override
  String typeVaultnameToConfirm(String vaultName) {
    return 'Введите «$vaultName» для подтверждения';
  }

  @override
  String unableToCheckBackupBucketAccess(String error) {
    return 'Не удалось проверить доступ к бакету резервных копий: $error';
  }

  @override
  String unableToDiscardIsolatedRestoreCopy(String error) {
    return 'Не удалось удалить изолированную копию для восстановления: $error';
  }

  @override
  String get unableToLoadAccountRelayPolicy =>
      'Не удалось загрузить политику Relay учётной записи';

  @override
  String get unableToLoadMemberEffectiveRelay =>
      'Не удалось загрузить фактический доступ участника к Relay';

  @override
  String unableToLoadOffSiteBackup(String error) {
    return 'Не удалось загрузить состояние внешнего резервного копирования: $error';
  }

  @override
  String unableToLoadRestoreSourcesError(String error) {
    return 'Не удалось загрузить источники восстановления: $error';
  }

  @override
  String unableToLoadScheduledBackupsError(String error) {
    return 'Не удалось загрузить плановое резервное копирование: $error';
  }

  @override
  String get unableToLoadServerManagedGroup =>
      'Не удалось загрузить сведения о группе, управляемой сервером';

  @override
  String get unableToLoadServerManagedGroups =>
      'Не удалось загрузить группы, управляемые сервером';

  @override
  String unableToPrepareIsolatedRestoreCopy(String error) {
    return 'Не удалось подготовить изолированную копию для восстановления: $error';
  }

  @override
  String unableToRefreshRestoreStageStatus(String error) {
    return 'Не удалось обновить состояние подготовки восстановления: $error';
  }

  @override
  String unableToReviewPasswordFieldsFriendlyerror(String friendlyError) {
    return 'Не удалось проверить поля паролей: $friendlyError';
  }

  @override
  String unableToSaveScheduledBackupsError(String error) {
    return 'Не удалось сохранить плановое резервное копирование: $error';
  }

  @override
  String get unavailableCredential2 => 'Недоступные учётные данные';

  @override
  String get unavailableCredential => 'Недоступные учётные данные';

  @override
  String get unavailableGroup => 'Недоступная группа';

  @override
  String get unavailableInWeb => 'Недоступно в веб-версии';

  @override
  String get unavailableOnThisNode => 'Недоступно на этом узле';

  @override
  String get unavailableParentChooseAgain =>
      'Родитель недоступен; выберите заново';

  @override
  String uncommittedOperationsCount(int count) {
    return 'Незафиксированных операций: $count';
  }

  @override
  String get unknown => 'Неизвестно';

  @override
  String get unknownPushProvider => 'Неизвестный провайдер push';

  @override
  String get unlockArchive => 'Разблокировать архив';

  @override
  String get unnamedDevice => 'Безымянное устройство';

  @override
  String get unsupportedTheme => 'Неподдерживаемая тема';

  @override
  String get unverified => 'Не проверено';

  @override
  String get upOneDirectory => 'На уровень вверх';

  @override
  String get updateAndReload => 'Обновить и перезагрузить';

  @override
  String get updateReadinessChangedFinishTheVisible =>
      'Готовность к обновлению изменилась. Устраните показанную проблему, прежде чем подтверждать.';

  @override
  String get updatingThisDevice => 'Обновление этого устройства…';

  @override
  String get upload => 'Отправить';

  @override
  String get uploadAFileOrCreateA =>
      'Отправьте файл или создайте папку, чтобы начать.';

  @override
  String get useAtLeast12CharactersIf =>
      'Используйте не менее 12 символов. Если ответ потеряется, клиент хранит в памяти только точный повторный запрос, но не пароли.';

  @override
  String get useConflictBranch => 'Использовать ветку конфликта';

  @override
  String get useCurrentVaultVersion => 'Использовать текущую версию сейфа';

  @override
  String get useSyncedVersion => 'Использовать синхронизированную версию';

  @override
  String get useTheAccountAndApprovedDevice =>
      'Используйте учётную запись и одобренное устройство, указанные в приглашении. Токен передаётся в теле аутентифицированного запроса и никогда не добавляется в URL.';

  @override
  String get useTheConflictBranchTuple =>
      'Использовать набор из ветки конфликта';

  @override
  String get useTheCurrentVaultTuple =>
      'Использовать набор из текущей версии сейфа';

  @override
  String get useTheSyncedVersion => 'Использовать синхронизированную версию?';

  @override
  String get userId => 'ID пользователя';

  @override
  String get username => 'Имя пользователя';

  @override
  String get validatingAllSelectedHostsBeforeSending =>
      'Проверка всех выбранных хостов перед отправкой первой команды.';

  @override
  String get vaultId => 'ID сейфа';

  @override
  String get vaultArchiveImportedAndLocalState =>
      'Архив сейфа импортирован, локальное состояние восстановлено.';

  @override
  String vaultChangedWhileSavingCheckThe(String startingVaultName) {
    return 'Сейф изменился во время сохранения. Проверьте настройку в $startingVaultName; активный сейф не отмечен как сохранённый.';
  }

  @override
  String vaultChangedWhileSavingCheckThe2(String startingVaultName) {
    return 'Сейф изменился во время сохранения. Проверьте настройку сочетаний в $startingVaultName; активный сейф не отмечен как сохранённый.';
  }

  @override
  String vaultChangedWhileSavingTheEncrypted(String startingVaultName) {
    return 'Сейф изменился во время сохранения. Зашифрованное изменение осталось в очереди $startingVaultName; в активный сейф оно не сохранено.';
  }

  @override
  String vaultChangedWhileSavingTheFont(String startingVaultName) {
    return 'Сейф изменился во время сохранения. Изменение размера шрифта осталось в очереди $startingVaultName; в активный сейф оно не сохранено.';
  }

  @override
  String vaultChangedWhileSavingTheShortcut(String startingVaultName) {
    return 'Сейф изменился во время сохранения. Изменение сочетаний осталось в очереди $startingVaultName; в активный сейф оно не сохранено.';
  }

  @override
  String vaultChangedWhileSavingTheTheme(String startingVaultName) {
    return 'Сейф изменился во время сохранения. Изменение темы осталось в очереди $startingVaultName; в активный сейф оно не сохранено.';
  }

  @override
  String vaultDeletionIsScheduledThisVault(String vaultLifecycleDate) {
    return 'Удаление сейфа запланировано. Сейф доступен только для чтения; сервер удалит данные после $vaultLifecycleDate. Неотправленные изменения остаются на устройстве и продолжат отправку, только если владелец отменит удаление.';
  }

  @override
  String get vaultDeletionPendingReadOnly =>
      'Сейф ожидает удаления · только чтение';

  @override
  String vaultDeviceNameStatuslabel(String name, String statusLabel) {
    return 'Устройство сейфа $name, $statusLabel';
  }

  @override
  String vaultIsInItsDeletionGrace(int pendingCount) {
    return 'Сейф находится в льготном периоде удаления. Получение и чтение доступны, но отправка конфликтов и очереди приостановлена. Сделайте локальную резервную копию через переносимый зашифрованный архив в настройках; сервер удалит рабочие данные сейфа в указанный срок. Ожидающих операций, зашифрованных на этом устройстве: $pendingCount; они продолжатся, только если владелец отменит удаление до срока.';
  }

  @override
  String get vaultKeyState => 'Состояние ключа сейфа';

  @override
  String get vaultMetadataAndStorageLimitsEncrypted =>
      'Метаданные и лимиты хранения сейфов. Зашифрованные имена и содержимое никогда не отображаются.';

  @override
  String get vaultName => 'Имя сейфа';

  @override
  String get vaultNameHostsCredentialsAndSnippets =>
      'Имя сейфа, хосты, учётные данные и сниппеты шифруются до синхронизации.';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore =>
      'Прежде чем менять эти сочетания, нужно разобраться с данными настроек сейфа.';

  @override
  String get vaultPreferenceDataNeedsAttentionBefore2 =>
      'Прежде чем менять этот параметр, нужно разобраться с данными настроек сейфа.';

  @override
  String get vaultRole => 'Роль в сейфе';

  @override
  String get vaultStatesRefreshedFromTheServer =>
      'Состояние сейфов обновлено с сервера.';

  @override
  String get vaultSyncIsUnreachableThisConfirmation =>
      'Синхронизация сейфа недоступна. Это подтверждение ставит впервые встреченный отпечаток в очередь как зашифрованную запись на этом устройстве; текущее SSH-подключение остановится, пока синхронизация сейфа его не подтвердит. Офлайн нельзя проверить одобрения и отзывы с других устройств.';

  @override
  String vaultVaultid(String vaultId) {
    return 'Сейф $vaultId';
  }

  @override
  String get vaultConflictResolved => 'Конфликт сейфа решён';

  @override
  String get vaultDeletionCancelled => 'Удаление сейфа отменено';

  @override
  String get vaultDeletionScheduled => 'Удаление сейфа запланировано';

  @override
  String get vaultEncryptedDataSynced =>
      'Зашифрованные данные сейфа синхронизированы';

  @override
  String get vaultKeyGeneration => 'Поколение ключа сейфа';

  @override
  String get vaultKeyRotated => 'Ключ сейфа сменён';

  @override
  String get vaultCreated => 'Сейф создан';

  @override
  String get vaultPurged => 'Сейф окончательно удалён';

  @override
  String get vaultOwnershipTransferred => 'Владение сейфом передано';

  @override
  String get vaultScopedAuditIsAvailableOnly =>
      'Аудит уровня сейфа доступен только владельцу и редакторам текущего сейфа; с вашими правами события сейфа не возвращаются.';

  @override
  String get vaultSyncedPreferences => 'Настройки, синхронизируемые с сейфом';

  @override
  String vaultVaultid2(String vaultId) {
    return 'Сейф: $vaultId';
  }

  @override
  String vaultVaultname(String vaultName) {
    return 'Сейф: $vaultName';
  }

  @override
  String get vaults => 'Сейфы';

  @override
  String verifiedCapabilitiesReportRevisionRevisionRecord(
    int revision,
    int maxRecordSchema,
    String attachmentVersions,
    String formatAdminBytes,
  ) {
    return 'Проверенные возможности · версия отчёта $revision\nСхема записей ≤ $maxRecordSchema · форматы вложений $attachmentVersions · лимит вложений $formatAdminBytes';
  }

  @override
  String verifiedRevisionsRecordcount(int recordCount) {
    return 'Проверенных версий: $recordCount';
  }

  @override
  String get verifySshHostKey => 'Проверьте ключ SSH-хоста';

  @override
  String get verifyAndDiscard => 'Проверить и удалить';

  @override
  String get verifyAndReview => 'Проверить и просмотреть';

  @override
  String get verifyArchive => 'Проверить архив';

  @override
  String viaJumpHostJumphostname(Object jumpHostName) {
    return 'Через промежуточный хост: $jumpHostName';
  }

  @override
  String get viewVaultMembers => 'Просмотреть участников сейфа';

  @override
  String get viewCommandHistory => 'Показать историю команд';

  @override
  String get viewSessions => 'Показать сеансы';

  @override
  String get viewerReadOnlyVaultAccess =>
      'Читатель · доступ к сейфу только для чтения';

  @override
  String get workspace2 => 'РАБОЧЕЕ ПРОСТРАНСТВО';

  @override
  String get waitForVaultSyncOrRecovery =>
      'Дождитесь завершения синхронизации или восстановления сейфа, прежде чем менять участников.';

  @override
  String get waitForVaultSynchronizationOrRecovery =>
      'Дождитесь завершения синхронизации или восстановления сейфа.';

  @override
  String get waitingForRemoteCopy => 'Ожидание удалённого копирования';

  @override
  String get waitingToSync => 'Ожидает синхронизации';

  @override
  String get webApplicationUpdates => 'Обновления веб-приложения';

  @override
  String get wholeHoursFrom1To720 => 'Целое число часов от 1 до 720';

  @override
  String get withdrawConsent => 'Отозвать согласие';

  @override
  String get workspace3 => 'Рабочее пространство';

  @override
  String get workspaceActions => 'Действия с рабочим пространством';

  @override
  String get workspaceName => 'Имя рабочего пространства';

  @override
  String get workspaceSavedEncryptedToThisVault =>
      'Рабочее пространство сохранено в этом сейфе в зашифрованном виде.';

  @override
  String get youHaveReadOnlyAccessTo =>
      'У вас доступ к этому сейфу только для чтения.';

  @override
  String get activePane2 => 'активная панель';

  @override
  String get eGGrep => 'например, grep';

  @override
  String get redactedDraft => 'черновик со скрытыми данными';

  @override
  String actionFriendlyerror(String action, String friendlyError) {
    return '$action: $friendlyError';
  }

  @override
  String countGroupParentRelationshipSAre(int count) {
    return 'Отсутствующих или циклических связей групп с родителями: $count. Измените затронутую группу и выберите допустимого родителя или верхний уровень.';
  }

  @override
  String countHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count хоста',
      many: '$count хостов',
      few: '$count хоста',
      one: '$count хост',
    );
    return '$_temp0';
  }

  @override
  String countOfCount2VaultKeyContexts(int count, int count2) {
    return 'Ящики восстановления есть у $count из $count2 контекстов ключей сейфа.';
  }

  @override
  String countSuggestions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count подсказки',
      many: '$count подсказок',
      few: '$count подсказки',
      one: '$count подсказка',
    );
    return '$_temp0';
  }

  @override
  String countTabs(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count вкладки',
      many: '$count вкладок',
      few: '$count вкладки',
      one: '$count вкладка',
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
    return 'Известный результат: $count; завершение на удалённой стороне неизвестно: $count2; остановлено до отправки: $count3; не запущено: $count4.';
  }

  @override
  String countPendingReview(int count) {
    return 'Ожидают проверки: $count';
  }

  @override
  String displaynameAndItsEncryptedPayloadsWill(String displayName) {
    return '$displayName и его зашифрованные данные будут удалены из активного состояния сервера. Отменить это в приложении нельзя.';
  }

  @override
  String displaynameWillBeRestoredFromIts(String displayName) {
    return '$displayName будет восстановлен из последней проверенной активной версии. Это удастся, только пока соответствующая метка удаления остаётся текущей головой на сервере.';
  }

  @override
  String filenameWillBeRemovedFromThe(String filename) {
    return '$filename будет удалён с удалённого хоста.';
  }

  @override
  String itemSigningKeyShortkey(Object item, String shortKey) {
    return '$item\nКлюч подписи · $shortKey';
  }

  @override
  String labelforIdSubstringDeletedFormat(
    String labelFor,
    String substring,
    String format,
  ) {
    return '$labelFor · ID $substring · удалено $format';
  }

  @override
  String membercountMembersValuevalueRevisionRevision(
    int memberCount,
    String valueValue,
    int revision,
  ) {
    return 'Участников: $memberCount · $valueValue · версия $revision';
  }

  @override
  String missingcountMissing(int missingCount) {
    return 'Отсутствует: $missingCount';
  }

  @override
  String nameWillLoseAccountAccessAnd(String name) {
    return '$name потеряет доступ к учётной записи, а активные сеансы будут отозваны.';
  }

  @override
  String nameValuevaluePasswordHiddenFromPreview(
    String name,
    String valueValue,
  ) {
    return '$name: $valueValue · пароль скрыт в предпросмотре';
  }

  @override
  String pendingcountEncryptedLocalChangeSAre(int pendingCount) {
    return 'В очереди отправки остаются зашифрованные локальные изменения: $pendingCount. Пока сейф доступен только для чтения, они не отправляются; они остаются в этом браузере и смогут синхронизироваться, только если удаление отменят до срока.';
  }

  @override
  String roleKeyEpochActivekeyepochMembershipMembershipversion(
    String role,
    String activeKeyEpoch,
    String membershipVersion,
  ) {
    return '$role · эпоха ключа $activeKeyEpoch · членство $membershipVersion';
  }

  @override
  String tolocalExitExitstatus(DateTime toLocal, int exitStatus) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$toLocalString · код выхода $exitStatus';
  }

  @override
  String unavailablerecordcountEncryptedRecordSCouldNot(
    int unavailableRecordCount,
  ) {
    return 'Зашифрованных записей, которые не удалось проверить текущим ключом сейфа и каталогом устройств или декодировать как поддерживаемые: $unavailableRecordCount. Их шифротекст хранится локально и скрыт из доверенных данных.';
  }

  @override
  String unresolvedconflictcountNeedsReview(int unresolvedConflictCount) {
    return 'Требуют проверки: $unresolvedConflictCount';
  }

  @override
  String valuevalueMoreDeviceSNeedReview(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: 'Ещё $valueValue устройства требуют проверки.',
      many: 'Ещё $valueValue устройств требуют проверки.',
      few: 'Ещё $valueValue устройства требуют проверки.',
      one: 'Ещё $valueValue устройство требует проверки.',
    );
    return '$_temp0';
  }

  @override
  String valuevalueUsernameAndRotateTheVault(
    String valueValue,
    String username,
  ) {
    return '$valueValue $username и сменить ключ сейфа для всех оставшихся активных устройств участников? Удалённая учётная запись не получит новый ключ. Уже существующие старые копии удалённо стереть нельзя. Другие ожидающие токены приглашений станут недействительными, и их нужно будет выдать заново.';
  }

  @override
  String get configuredMeansThisServerProcessLoaded =>
      '«Настроено» означает, что процесс сервера загрузил адаптер провайдера; это не подтверждает связность или работоспособность воркеров. Push — лишь подсказка для пробуждения без гарантий, а не подтверждение доставки или синхронизации; источником истины остаются аутентифицированный WebSocket или опрос.';

  @override
  String get previousPage => 'Предыдущая страница';

  @override
  String lastArchiveVerificationFailedAtArchivefailurephase(
    Object archiveFailurePhase,
  ) {
    return 'Последняя проверка архива не пройдена на этапе: $archiveFailurePhase';
  }

  @override
  String get nextPage => 'Следующая страница';

  @override
  String get doesntExist => 'Не существует';

  @override
  String get masterPasswordChanged => 'Мастер-пароль изменён';

  @override
  String get couldntChangeTheMasterPassword =>
      'Не удалось сменить мастер-пароль';

  @override
  String get hosts => 'Хосты';

  @override
  String get onlyTheHostIdTabOrder =>
      'Синхронизируются только ID хоста, порядок вкладок, направление и пропорции разделения. Учётные данные, активные SSH-сеансы, вывод терминала, пути SFTP и состояние файлов в записи рабочего пространства не попадают.';

  @override
  String get retryFromTheFirstPage => 'Повторить с первой страницы';

  @override
  String get saveAndConnect => 'Сохранить и подключиться';

  @override
  String get saveCurrentWindowLayout => 'Сохранить текущий макет окна';

  @override
  String get saveTheCurrentTerminalTabsTo =>
      'Сохраните текущие вкладки терминала, чтобы просмотреть тот же макет на других авторизованных устройствах.';

  @override
  String get keepTheCurrentCommittedVersion =>
      'Оставить текущую зафиксированную версию?';

  @override
  String get keepCurrentVersion => 'Оставить текущую версию';

  @override
  String get couldntKeepTheCurrentVersion =>
      'Не удалось оставить текущую версию';

  @override
  String get vaultsAndMembers => 'Сейфы и участники';

  @override
  String get change => 'Изменить';

  @override
  String get openOneOrMoreTabsOn =>
      'Сначала откройте одну или несколько вкладок на странице терминала, затем сохраните их как именованный макет.';

  @override
  String get conflictResolved => 'Конфликт решён.';

  @override
  String get setTheTerminalFontSizeColors2 =>
      'Отдельно настройте размер шрифта, цвета и сочетания клавиш терминала; они синхронизируются с текущим сейфом.';

  @override
  String get branchsOriginalBase => 'Исходная база ветки';

  @override
  String get branchNotVerifiedYetKeptRead =>
      'Ветка ещё не проверена; хранится только для чтения';

  @override
  String get branchSavedOnThisDeviceWaiting =>
      'Ветка сохранена на этом устройстве и ждёт подтверждения синхронизации.';

  @override
  String get branchSavedEncryptedOnThisDevice =>
      'Ветка сохранена в зашифрованном виде на этом устройстве и ждёт подтверждения синхронизации.';

  @override
  String branchSequenceSeqValuevalue(String seq, String valueValue) {
    return 'Номер ветки $seq · $valueValue';
  }

  @override
  String get branchActions => 'Действия с веткой';

  @override
  String get branchVersion => 'Версия ветки';

  @override
  String get groupLayoutReset => 'Макет группы сброшен.';

  @override
  String get refresh => 'Обновить';

  @override
  String get encryptedSessionUnlocked => 'Зашифрованный сеанс разблокирован';

  @override
  String get namedTerminalLayoutsSyncEncryptedIncluding =>
      'Именованные макеты терминала синхронизируются в зашифрованном виде, включая порядок вкладок или направление и пропорции разделения. Предпросмотр не подключается; для каждой панели нужно отдельно подтвердить подключение.';

  @override
  String get encryptedBackupJobSubmitted =>
      'Задание зашифрованного резервного копирования отправлено';

  @override
  String get readOnlyViewOfCommittedAccount =>
      'Просмотр (только чтение) зафиксированных действий с учётной записью и текущим сейфом; SSH-команды, имена хостов и учётные данные не записываются.';

  @override
  String get syncAndConflicts => 'Синхронизация и конфликты';

  @override
  String get snippets => 'Сниппеты';

  @override
  String get completedCommandsAreRecordedAfterEnabling2 =>
      'Выполненные команды записываются после включения интеграции с Bash в настройках записи; ввод в запросах пароля не перехватывается.';

  @override
  String get working => 'Обработка…';

  @override
  String get backupRestoreAndMaintenance =>
      'Резервное копирование, восстановление и обслуживание';

  @override
  String get backupCompleted => 'Резервное копирование завершено';

  @override
  String get multiFactorRecoveryCodesRotated =>
      'Коды восстановления многофакторной аутентификации обновлены';

  @override
  String get instanceOverview => 'Обзор экземпляра';

  @override
  String get instanceAdminInvitationRevoked =>
      'Приглашение администратора экземпляра отозвано';

  @override
  String get instanceAdminInvitationIssued =>
      'Приглашение администратора экземпляра выдано';

  @override
  String get instanceMaintenanceJobSubmitted =>
      'Задание обслуживания экземпляра отправлено';

  @override
  String get auditLog => 'Журнал аудита';

  @override
  String get auditRecords => 'Записи аудита';

  @override
  String get importAndExportEncryptedArchivesOr =>
      'Импорт и экспорт зашифрованных архивов или перенос локальных профилей.';

  @override
  String get notVerifiedYet => 'Ещё не проверено';

  @override
  String get properties => 'Свойства';

  @override
  String get workspace => 'Рабочее пространство';

  @override
  String get workspaceLayouts => 'Макеты рабочего пространства';

  @override
  String get theCurrentWindowLayoutForThis =>
      'Текущий макет окон для этой группы сохранён.';

  @override
  String get multiFactorAuthenticationTurnedOff =>
      'Многофакторная аутентификация отключена';

  @override
  String get memberInvitationCreated => 'Приглашение участника создано';

  @override
  String get deleted => 'Удалено';

  @override
  String deletedValuevalue(String valueValue) {
    return 'Удалено: $valueValue';
  }

  @override
  String get bashRecordingIsOnUpTo =>
      'Запись Bash включена (до 500 записей). Нажмите, чтобы вставить, затем Enter для запуска.';

  @override
  String get multiFactorAuthenticationEnabled =>
      'Многофакторная аутентификация включена';

  @override
  String processedBranchesCount(int count) {
    return 'Обработано веток: $count';
  }

  @override
  String get multiFactorSignInStarted => 'Начат многофакторный вход';

  @override
  String get committed => 'Зафиксировано';

  @override
  String get committedAdminActionsAppearHereNew =>
      'Здесь отображаются зафиксированные действия администратора. Новые события не вставляются в просматриваемую страницу.';

  @override
  String get sshRelayConnectionTicketIssued =>
      'Выдан билет подключения SSH Relay';

  @override
  String get resolved => 'Решено';

  @override
  String get signedOut => 'Вы вышли';

  @override
  String get multiFactorAuthenticationWasResetAfter =>
      'Многофакторная аутентификация сброшена после восстановления из архива';

  @override
  String get currentVault3 => 'Текущий сейф';

  @override
  String get hostsCantBeAddedInThe =>
      'В текущем рабочем пространстве нельзя добавлять хосты.';

  @override
  String showingEventsForCurrentvaultnameSwitchingThe(String currentVaultName) {
    return 'Показаны события сейфа $currentVaultName. При смене сейфа вверху загрузка начнётся с первой страницы.';
  }

  @override
  String get currentServerVersion => 'Текущая версия на сервере';

  @override
  String get theCurrentServerVersionIsCommitted =>
      'Текущая версия на сервере зафиксирована. Она записывается как выбор для этого конфликта; старая ветка не отправляется повторно и новая версия записи не создаётся.';

  @override
  String get theCurrentVersionChangedChooseAgain =>
      'Текущая версия изменилась; выберите заново';

  @override
  String get theCurrentVersionIsCommittedWaiting =>
      'Текущая версия зафиксирована; ожидание подтверждения решения конфликта сервером.';

  @override
  String get thisWindowHasNoSshLayout =>
      'В этом окне нет SSH-макета для сохранения.';

  @override
  String get noAuditRecordsInTheCurrent =>
      'В текущей области нет записей аудита';

  @override
  String get yourCurrentRoleCantViewThe =>
      'Ваша текущая роль не позволяет просматривать аудит сейфа';

  @override
  String get restore3 => 'Восстановить';

  @override
  String get recoveryKeyDeviceEnvelopesUpdated =>
      'Конверты ключа восстановления для устройств обновлены';

  @override
  String get succeeded => 'Успешно';

  @override
  String get memberPermissionsChanged => 'Права участника изменены';

  @override
  String get membershipVersion => 'Версия членства';

  @override
  String get memberAccessRevoked => 'Доступ участника отозван';

  @override
  String get memberInvitationAccepted => 'Приглашение участника принято';

  @override
  String get theSelectedBranchIsCommittedWaiting =>
      'Выбранная ветка зафиксирована; ожидание подтверждения решения конфликта сервером.';

  @override
  String get theSelectedVersionIsCommittedWaiting =>
      'Выбранная версия зафиксирована; ожидание подтверждения решения конфликта сервером.';

  @override
  String get dataAndMigration => 'Данные и миграция';

  @override
  String get files => 'Файлы';

  @override
  String get theHostSpecifiedByTheFile =>
      'Хост, указанный окном файлов, недоступен.';

  @override
  String get fileManager => 'Файловый менеджер';

  @override
  String get passwordsAndKeysForNewHosts2 =>
      'Пароли и ключи новых хостов задаются в сведениях о хосте.';

  @override
  String get newBranchesSyncAutomaticallyWithConflict =>
      'Новые ветки синхронизируются автоматически вместе с уведомлениями о конфликтах; можно также нажать «Синхронизировать» вверху, чтобы проверить входящие на сервере.';

  @override
  String get newLabel => 'Создать';

  @override
  String newTouppercaseHost(String toUpperCase) {
    return 'Новый хост $toUpperCase';
  }

  @override
  String get newWindow => 'Новое окно';

  @override
  String get theNewWindowWasntReadyThe =>
      'Новое окно не готово; исходный SSH-сеанс остаётся подключённым.';

  @override
  String get theNewWindowWasntReadyThe2 =>
      'Новое окно не готово; удалённый рабочий стол остаётся в текущем окне.';

  @override
  String couldntLoadTheVaultListError(String error) {
    return 'Не удалось загрузить список сейфов: $error';
  }

  @override
  String couldntLoadTheSessionListError(String error) {
    return 'Не удалось загрузить список сеансов: $error';
  }

  @override
  String get couldntLoadBackupCommandStatus =>
      'Не удалось загрузить состояние команды резервного копирования';

  @override
  String couldntLoadBackupCommandStatusError(String error) {
    return 'Не удалось загрузить состояние команды резервного копирования: $error';
  }

  @override
  String get couldntLoadInstanceOverview =>
      'Не удалось загрузить обзор экземпляра';

  @override
  String couldntLoadInstanceOverviewError(String error) {
    return 'Не удалось загрузить обзор экземпляра: $error';
  }

  @override
  String get couldntLoadInstanceAdminAuditRecords =>
      'Не удалось загрузить журнал аудита администратора экземпляра';

  @override
  String couldntLoadInstanceAdminAuditRecords2(String error) {
    return 'Не удалось загрузить журнал аудита администратора экземпляра: $error';
  }

  @override
  String get couldntLoadAuditRecords => 'Не удалось загрузить журнал аудита';

  @override
  String get couldntLoadPushServiceStatus =>
      'Не удалось загрузить состояние службы push';

  @override
  String couldntLoadPushServiceStatusError(String error) {
    return 'Не удалось загрузить состояние службы push: $error';
  }

  @override
  String get couldntLoadTheAdminVaultList =>
      'Не удалось загрузить список сейфов для администратора';

  @override
  String get couldntLoadTheAdminAccountList =>
      'Не удалось загрузить список учётных записей для администратора';

  @override
  String get couldntLoadTheAccountSessionList =>
      'Не удалось загрузить список сеансов учётной записи';

  @override
  String couldntLoadTheAccountListError(String error) {
    return 'Не удалось загрузить список учётных записей: $error';
  }

  @override
  String get couldntLoadTheAccountInvitationList =>
      'Не удалось загрузить список приглашений';

  @override
  String couldntLoadTheInvitationListError(String error) {
    return 'Не удалось загрузить список приглашений: $error';
  }

  @override
  String get couldntOpenTheFileWindow => 'Не удалось открыть окно файлов.';

  @override
  String get couldntSubmitTheEncryptedBackupJob =>
      'Не удалось отправить задание зашифрованного резервного копирования';

  @override
  String couldntSubmitTheEncryptedBackupJob2(String error) {
    return 'Не удалось отправить задание зашифрованного резервного копирования: $error';
  }

  @override
  String get couldntUpdateTheVaultQuota => 'Не удалось обновить квоту сейфа';

  @override
  String couldntUpdateTheVaultQuotaError(String error) {
    return 'Не удалось обновить квоту сейфа: $error';
  }

  @override
  String get unreadable => 'Не читается';

  @override
  String get couldntReadOrSubmitInstanceJobs =>
      'Не удалось прочитать или отправить задания экземпляра';

  @override
  String couldntReadOrSubmitInstanceJobs2(String error) {
    return 'Не удалось прочитать или отправить задания экземпляра: $error';
  }

  @override
  String get legacySharedCredentials => 'Устаревшие общие учётные данные';

  @override
  String missingPlural11MonitorWindow(int missing) {
    return 'Не удалось открыть окна мониторов: $missing; выберите снова, чтобы повторить.';
  }

  @override
  String get theServerProvidedASignedCleanup =>
      'Сервер предоставил подписанное подтверждение очистки этой записи. Ожидающие локальные изменения изолированы как черновик только для чтения; чтобы не воссоздать очищенную запись, черновик нельзя здесь сохранить, объединить или отправить.';

  @override
  String get theServerMarksTheCurrentCommitted =>
      'Сервер помечает текущую зафиксированную версию как сохранённую, не создавая новой версии основной записи. Ветки с других устройств остаются в обработанной истории.';

  @override
  String get serverBranch => 'Ветка сервера';

  @override
  String get theServerPageContainsSeveralVisible =>
      'Страница сервера содержит несколько видимых областей; листайте дальше, чтобы найти события текущей области.';

  @override
  String get unknownAction => 'Неизвестное действие';

  @override
  String get unknownResult => 'Неизвестный результат';

  @override
  String get unknownDevice => 'Неизвестное устройство';

  @override
  String get localStorageNeedsRecoveryReadingEditing =>
      'Локальное хранилище требует восстановления. Чтение, правка и синхронизация приостановлены; закройте все вкладки Atermius и откройте снова, чтобы восстановить последние сохранённые данные.';

  @override
  String get notCommittedLocally => 'Не зафиксировано локально';

  @override
  String get noEventsInThisScopeOn =>
      'На этой странице нет событий в этой области';

  @override
  String get sourceDevice => 'Исходное устройство';

  @override
  String get viewInstanceAndPushServiceStatus =>
      'Просмотр состояния экземпляра и службы push, управление учётными данными мониторинга.';

  @override
  String get viewTheCurrentAccountDevicesAnd =>
      'Просмотр текущей учётной записи, устройств и сведений о сервере.';

  @override
  String get reviewInstanceActionsAndAccessAudit =>
      'Проверьте действия с экземпляром и журнал аудита доступа.';

  @override
  String get reviewTrustedHostKeysAndTheir =>
      'Проверьте доверенные ключи хостов и их изменения.';

  @override
  String get refreshCredentialReplayDetectedTheRelated =>
      'Обнаружено повторное использование токена обновления; связанные сеансы отозваны';

  @override
  String get readingVaultList => 'Чтение списка сейфов…';

  @override
  String get readingInstanceJobs => 'Чтение заданий экземпляра…';

  @override
  String get readingInstanceOverview => 'Чтение обзора экземпляра…';

  @override
  String get readingInstanceAdminAuditRecords =>
      'Чтение журнала аудита администратора экземпляра…';

  @override
  String get readingAuditRecords => 'Чтение журнала аудита…';

  @override
  String get readingOffSiteBackupStatus =>
      'Чтение состояния внешнего резервного копирования…';

  @override
  String get readingPushServiceStatus => 'Чтение состояния службы push…';

  @override
  String get readingTheLatestBackupCommandStatus =>
      'Чтение состояния последней команды резервного копирования…';

  @override
  String get readingAdminAccountList =>
      'Чтение списка учётных записей для администратора…';

  @override
  String get thisGroupHasNoConnectableSsh =>
      'В этой группе нет SSH-хостов для подключения.';

  @override
  String get eachGroupLayoutCanConnectUp =>
      'Макет группы может подключать не более 32 хостов. Разделите группу и повторите попытку.';

  @override
  String get noPendingCrossDeviceBranches =>
      'Нет ожидающих веток с других устройств';

  @override
  String get browseFiles => 'Обзор файлов';

  @override
  String get addGroup => 'Добавить группу';

  @override
  String get versionCommittedWaitingForTheServer =>
      'Версия зафиксирована, ожидание подтверждения решения сервером';

  @override
  String get signInFailed => 'Не удалось войти';

  @override
  String get signedIn => 'Вход выполнен';

  @override
  String get confirmKeptVersion => 'Подтвердить сохраняемую версию';

  @override
  String get windowSetSavedEncrypted =>
      'Набор окон сохранён в зашифрованном виде.';

  @override
  String windowSetOpenedCountCount2Sessions(
    int count,
    int count2,
    int failures,
  ) {
    return 'Набор окон открыл сеансы: $count из $count2; не удалось подключить: $failures.';
  }

  @override
  String pageValuevalue2(int valueValue) {
    return 'Страница $valueValue';
  }

  @override
  String get waitingForThisDeviceToSync =>
      'Ожидание синхронизации выбранной версии на этом устройстве';

  @override
  String get manageTheMasterPasswordTwoFactor =>
      'Управление мастер-паролем, двухфакторным входом, восстановлением и удалением учётной записи.';

  @override
  String get manageVaultsMembersAndInvitations =>
      'Управление сейфами, участниками и приглашениями.';

  @override
  String get adminBackupFailed =>
      'Резервное копирование администратора не выполнено';

  @override
  String get adminBackupInterrupted =>
      'Резервное копирование администратора прервано';

  @override
  String get adminBackupCompleted =>
      'Резервное копирование администратора завершено';

  @override
  String get adminBackupStarted =>
      'Резервное копирование администратора начато';

  @override
  String get anAdministratorDiscardedTheIsolatedRestore =>
      'Администратор удалил изолированную копию для восстановления';

  @override
  String get anAdministratorDisabledTheAccount =>
      'Администратор отключил учётную запись';

  @override
  String get anAdministratorCreatedAnSshRelay =>
      'Администратор создал группу доступа SSH Relay';

  @override
  String get anAdministratorDeletedAnSshRelay =>
      'Администратор удалил группу доступа SSH Relay';

  @override
  String get anAdministratorEnabledTheAccount =>
      'Администратор включил учётную запись';

  @override
  String get anAdministratorRevokedThePrometheusScrape =>
      'Администратор отозвал учётные данные Prometheus для сбора метрик';

  @override
  String get anAdministratorRevokedAnAccountSession =>
      'Администратор отозвал сеанс учётной записи';

  @override
  String get anAdministratorRevokedAllOfThe =>
      'Администратор отозвал все сеансы учётной записи';

  @override
  String get anAdministratorChangedSshRelayAccess =>
      'Администратор изменил состав группы доступа SSH Relay';

  @override
  String get anAdministratorChangedTheSshRelay =>
      'Администратор изменил политику группы доступа SSH Relay';

  @override
  String get anAdministratorChangedTheVaultQuota =>
      'Администратор изменил квоту сейфа';

  @override
  String get anAdministratorChangedTheScheduledBackup =>
      'Администратор изменил плановое резервное копирование';

  @override
  String get anAdministratorUpdatedTheSshRelay =>
      'Администратор обновил политику SSH Relay';

  @override
  String get anAdministratorRequestedABackup =>
      'Администратор запросил резервное копирование';

  @override
  String get anAdministratorRequestedARestoreJob =>
      'Администратор запросил задание восстановления';

  @override
  String get anAdministratorRequestedAMaintenanceJob =>
      'Администратор запросил задание обслуживания';

  @override
  String get anAdministratorRotatedThePrometheusScrape =>
      'Администратор сменил учётные данные Prometheus для сбора метрик';

  @override
  String get anAdministratorRenamedAnSshRelay =>
      'Администратор переименовал группу доступа SSH Relay';

  @override
  String get anAdministratorResetTheSshRelay =>
      'Администратор сбросил политику группы доступа SSH Relay';

  @override
  String get adminRestoreJobFailed =>
      'Задание восстановления администратора не выполнено';

  @override
  String get adminRestoreJobInterrupted =>
      'Задание восстановления администратора прервано';

  @override
  String get adminRestoreJobCompleted =>
      'Задание восстановления администратора завершено';

  @override
  String get adminRestoreJobStarted =>
      'Задание восстановления администратора начато';

  @override
  String get adminMaintenanceJobFailed =>
      'Задание обслуживания администратора не выполнено';

  @override
  String get adminMaintenanceJobInterrupted =>
      'Задание обслуживания администратора прервано';

  @override
  String get adminMaintenanceJobCompleted =>
      'Задание обслуживания администратора завершено';

  @override
  String get adminMaintenanceJobStarted =>
      'Задание обслуживания администратора начато';

  @override
  String get adminAccountActionFailed =>
      'Действие администратора с учётной записью не выполнено';

  @override
  String get adminAccountInvitationActionFailed =>
      'Действие администратора с приглашением не выполнено';

  @override
  String get manageBackupsAndRestoreCopiesAnd =>
      'Управление резервными копиями и копиями для восстановления, проверка заданий обслуживания экземпляра.';

  @override
  String get manageInstanceAccountsInvitationsRelayGroups =>
      'Управление учётными записями экземпляра, приглашениями, группами ретрансляции и политиками подключения.';

  @override
  String get manageNotificationsAndClientUpdates =>
      'Управление уведомлениями и обновлениями клиента.';

  @override
  String get theBranchAndTheCurrentRecord =>
      'Ветка и текущая запись проверяются, затем это устройство заново подписывает и синхронизирует её. Исходная зашифрованная ветка сохраняется.';

  @override
  String get terminal2 => 'Терминал';

  @override
  String get terminalAndShortcuts => 'Терминал и сочетания клавиш';

  @override
  String get maintenanceJobs => 'Задания обслуживания';

  @override
  String get editGroup => 'Изменить группу';

  @override
  String get letExternalAiAccessTheCurrent2 =>
      'Подключите внешний ИИ к текущему рабочему пространству.';

  @override
  String get theRecordChangedAgainDuringCommit =>
      'Запись снова изменилась во время фиксации. Проверьте текущую версию и выберите заново.';

  @override
  String get theRecordChangedCheckTheCurrent =>
      'Запись изменилась. Проверьте текущую версию и выберите заново.';

  @override
  String get devices => 'Устройства';

  @override
  String get deviceApproved2 => 'Устройство одобрено';

  @override
  String get deviceRevoked => 'Устройство отозвано';

  @override
  String get settings => 'Настройки';

  @override
  String get account2 => 'Учётная запись';

  @override
  String accountShortauditidDeviceShortauditid2Valuevalue(
    String shortAuditId,
    String shortAuditId2,
    String valueValue,
  ) {
    return 'Учётная запись $shortAuditId  ·  устройство $shortAuditId2  ·  $valueValue';
  }

  @override
  String get accountAndDeviceInformation =>
      'Сведения об учётной записи и устройстве';

  @override
  String get accountsAndAccessPolicies => 'Учётные записи и политики доступа';

  @override
  String get accountEventsAreStillVisibleOnly =>
      'События учётной записи по-прежнему видны. Записи уровня сейфа могут просматривать только владелец и редакторы этого сейфа.';

  @override
  String get accountSessionUnlocked => 'Сеанс учётной записи разблокирован';

  @override
  String get accountCreated => 'Учётная запись создана';

  @override
  String get accountSecurity => 'Безопасность учётной записи';

  @override
  String get multiFactorAuthenticationWasResetAfter2 =>
      'Многофакторная аутентификация сброшена после восстановления учётной записи';

  @override
  String get accountRecoveryKeyRotated =>
      'Ключ восстановления учётной записи сменён';

  @override
  String get accountRecoveryDisabled =>
      'Восстановление учётной записи отключено';

  @override
  String get accountRecoveryEnabled => 'Восстановление учётной записи включено';

  @override
  String get accountRecoveryCompleted =>
      'Восстановление учётной записи завершено';

  @override
  String accountActionFailedError(String error) {
    return 'Действие с учётной записью не выполнено: $error';
  }

  @override
  String get accountDataCleared => 'Данные учётной записи очищены';

  @override
  String get accountDeletionCancelled => 'Удаление учётной записи отменено';

  @override
  String get accountDeletionScheduled =>
      'Удаление учётной записи запланировано';

  @override
  String get crossDeviceConflictInbox =>
      'Входящие конфликтов между устройствами';

  @override
  String get theCrossDeviceBranchIsntVerified =>
      'Ветка с другого устройства ещё не проверена; сведения о действии и версии сервера скрыты.';

  @override
  String get thisDeviceDecryptsTheVerifiedBranch =>
      'Это устройство расшифрует проверенную ветку, заново подпишет её своей идентичностью и выполнит CAS-фиксацию относительно текущей кэшированной версии. Исходный шифротекст ветки сохраняется; конфликт отображается во входящих, пока фиксация или решение на сервере не будут подтверждены.';

  @override
  String get concurrentBranchesSubmittedToTheServer =>
      'Здесь показаны параллельные ветки, отправленные на сервер другими устройствами. Выбрать их можно только после проверки подписи, принадлежности к сейфу и поколения ключа; просмотр входящих не меняет текущую запись.';

  @override
  String get remoteDesktop2 => 'Удалённый рабочий стол';

  @override
  String get connect2 => 'Подключить';

  @override
  String get connectEverySshHostInThe =>
      'Подключить все SSH-хосты группы и восстановить макет';

  @override
  String get chooseTheWorkspaceModeAndThe2 =>
      'Выберите режим рабочего пространства и страницу по умолчанию.';

  @override
  String get choiceSavedOnThisDeviceWaiting =>
      'Выбор сохранён на этом устройстве и ждёт подтверждения синхронизации.';

  @override
  String get choiceSavedTheInboxUpdatesAfter =>
      'Выбор сохранён; входящие обновятся после следующей синхронизации.';

  @override
  String get choiceSavedEncryptedOnThisDevice =>
      'Выбор сохранён в зашифрованном виде на этом устройстве и ждёт подтверждения синхронизации.';

  @override
  String get choiceSavedEncryptedOnThisDevice2 =>
      'Выбор сохранён в зашифрованном виде на этом устройстве и ждёт синхронизации; повторите попытку, когда сеть восстановится.';

  @override
  String get notificationsAndUpdates => 'Уведомления и обновления';

  @override
  String invitationActionFailedError(String error) {
    return 'Действие с приглашением не выполнено: $error';
  }

  @override
  String get couldntAdoptTheBranch => 'Не удалось принять ветку';

  @override
  String get adoptTheVerifiedDeviceBranch =>
      'Принять проверенную ветку устройства?';

  @override
  String get adoptThisBranch => 'Принять эту ветку';

  @override
  String get reSignAndSync => 'Переподписать и синхронизировать';

  @override
  String get resetLayout => 'Сбросить макет';

  @override
  String get attachments => 'Вложения';

  @override
  String get needsANewChoice => 'Требуется выбрать заново';

  @override
  String get aDeviceKeyPairIsGenerated =>
      'Пара ключей устройства создаётся и хранится только в этом браузере. Отправьте открытый запрос на уже одобренное устройство.';

  @override
  String get aPrivateSshWorkspaceThatSyncs =>
      'Приватное SSH-пространство, которое синхронизирует зашифрованные подключения, учётные данные и сниппеты между вашими устройствами.';

  @override
  String get aTrustedDeviceSignsEnvelopesFor =>
      'Доверенное устройство подписывает конверты для каждого нового устройства.';

  @override
  String get accountEmail => 'Электронная почта учётной записи';

  @override
  String get accountName => 'Имя учётной записи';

  @override
  String get accountRecoveredSignInWithThe =>
      'Учётная запись восстановлена. Войдите с новым мастер-паролем.';

  @override
  String get accountRecoveredSignInWithYour =>
      'Учётная запись восстановлена. Войдите с новым мастер-паролем.';

  @override
  String get addThisDevice => 'Добавить это устройство';

  @override
  String get approveEveryDevice => 'Одобрение каждого устройства';

  @override
  String get cancelRecovery => 'Отменить восстановление';

  @override
  String get cancelScheduledAccountDeletion =>
      'Отменить запланированное удаление учётной записи';

  @override
  String get cancelSignIn => 'Отменить вход';

  @override
  String get changeServer => 'Сменить сервер';

  @override
  String get commitRecovery => 'Завершить восстановление';

  @override
  String get confirmFingerprintAndContinue =>
      'Подтвердить отпечаток и продолжить';

  @override
  String get confirmMasterPassword => 'Подтвердите мастер-пароль';

  @override
  String get connectSecurely => 'Безопасное подключение';

  @override
  String get connectToYourServer => 'Подключитесь к своему серверу';

  @override
  String get copyThisEnrollmentJson => 'Скопируйте этот JSON регистрации';

  @override
  String get createInvitedAccount => 'Создать приглашённую учётную запись';

  @override
  String get createOwnerAccount => 'Создать учётную запись владельца';

  @override
  String get deviceName => 'Имя устройства';

  @override
  String get emailOnTheInvitation => 'Почта из приглашения';

  @override
  String get emailOrUsername => 'Электронная почта или имя пользователя';

  @override
  String get encryptedOutboxKeepsEditsSafeBetween =>
      'Зашифрованная очередь отправки сохраняет правки между подключениями.';

  @override
  String get endToEndEncryptedVault => 'Сейф со сквозным шифрованием';

  @override
  String get enterAValidRecoveryCodeAnd =>
      'Введите действительный код восстановления и совпадающий новый мастер-пароль.';

  @override
  String get enterTheUrlOfYourSelf => 'Введите URL вашего экземпляра Atermius.';

  @override
  String get fingerprintReturnedByThisServerSha =>
      'Отпечаток, полученный от этого сервера · SHA-256';

  @override
  String fingerprintReturnedByThisServerSha2(String candidateFingerprint) {
    return 'Отпечаток, полученный от этого сервера · SHA-256: $candidateFingerprint';
  }

  @override
  String get firstVault => 'Первый сейф';

  @override
  String get generateRequest => 'Создать запрос';

  @override
  String get haveAnInstanceInvitationCreateAccount =>
      'Есть приглашение на сервер? Создайте учётную запись';

  @override
  String get importApproval => 'Импортировать одобрение';

  @override
  String get importApprovedDevice => 'Импортировать одобренное устройство';

  @override
  String get importDeviceKeys => 'Импортировать ключи устройства';

  @override
  String get instanceInvitationToken => 'Токен приглашения на сервер';

  @override
  String get masterPassword => 'Мастер-пароль';

  @override
  String get masterPassword12Characters =>
      'Мастер-пароль · не менее 12 символов';

  @override
  String newAccountRecoveryCodeCode(String code) {
    return 'Новый код восстановления учётной записи: $code';
  }

  @override
  String get newDeviceName => 'Имя нового устройства';

  @override
  String get newMasterPassword12Characters =>
      'Новый мастер-пароль · не менее 12 символов';

  @override
  String get offlineFirstSync => 'Синхронизация с приоритетом офлайн';

  @override
  String get onlyYourUnlockedDevicesCanRead =>
      'Сохранённые данные могут читать только ваши разблокированные устройства.';

  @override
  String get ownerEmail => 'Почта владельца';

  @override
  String get pasteApprovalJson => 'Вставьте JSON одобрения';

  @override
  String get personalVault => 'Личный сейф';

  @override
  String get previouslyTrustedFingerprintSha256 =>
      'Ранее доверенный отпечаток · SHA-256';

  @override
  String previouslyTrustedFingerprintSha256Pinnedfingerprint(
    String pinnedFingerprint,
  ) {
    return 'Ранее доверенный отпечаток · SHA-256: $pinnedFingerprint';
  }

  @override
  String get recoverAccount => 'Восстановить учётную запись';

  @override
  String get recoverAccountWithRecoveryCode =>
      'Восстановить учётную запись с помощью кода восстановления';

  @override
  String get recoveredDevice => 'Восстановленное устройство';

  @override
  String get recoveryCode => 'Код восстановления';

  @override
  String get recoveryWasCancelledNoAccountChanges =>
      'Восстановление отменено. Изменения учётной записи не зафиксированы.';

  @override
  String get remoteServersRequireHttpsHttpIs =>
      'Для удалённых серверов требуется HTTPS. HTTP разрешён только для разработки на localhost, 127.0.0.1 или ::1.';

  @override
  String get requestThisDevice => 'Запросить добавление устройства';

  @override
  String get restoredServerIdentityNeedsConfirmation =>
      'Требуется подтвердить восстановленную идентичность сервера';

  @override
  String get retryRecoveryCompletion => 'Повторить завершение восстановления';

  @override
  String get selfHosted => 'СОБСТВЕННЫЙ СЕРВЕР';

  @override
  String get secretsAreEncryptedInThisClient =>
      'Секреты шифруются в этом клиенте до синхронизации.';

  @override
  String get serverUrl => 'URL сервера';

  @override
  String get setUpYourPrivateVault => 'Настройте личный сейф';

  @override
  String get signInAndUnlock => 'Войти и разблокировать';

  @override
  String get storeTheNewRecoveryCode => 'Сохраните новый код восстановления';

  @override
  String get theBootstrapTokenIsOneUse =>
      'Токен начальной настройки одноразовый. Сервер никогда не получает ваш мастер-пароль или созданный ключ сейфа.';

  @override
  String get theFirstAccountCreatesItsVault =>
      'Первая учётная запись создаёт ключ своего сейфа на этом устройстве.';

  @override
  String get theServerReturnedADifferentSigning =>
      'Сервер вернул другой ключ подписи для того же экземпляра. Сравните предлагаемый отпечаток с администратором или другим доверенным устройством по отдельному каналу. До подтверждения вход в учётную запись и запросы аутентификации не отправляются.';

  @override
  String get thisOneUseInvitationIsBound =>
      'Это одноразовое приглашение привязано к указанной выше почте. Сервер никогда не получает ваш мастер-пароль или созданный ключ сейфа.';

  @override
  String get thisReplacesTheOldCodeStore =>
      'Он заменяет старый код. Храните его вне этого устройства — повторно он показан не будет.';

  @override
  String get typeTheCandidateFingerprintExactly =>
      'Введите предлагаемый отпечаток точно';

  @override
  String get unlockYourWorkspace => 'Разблокируйте рабочее пространство';

  @override
  String get useARecoveryCode => 'Использовать код восстановления';

  @override
  String get useAuthenticatorCode => 'Использовать код аутентификатора';

  @override
  String get useTheAccountNameAndMaster =>
      'Используйте имя учётной записи и мастер-пароль. Восстановление не возобновляет сеанс — после него войдите снова.';

  @override
  String get useTheSaved256BitRecovery =>
      'Используйте сохранённый 256-битный код восстановления, чтобы вернуть доступ к ключам сейфа и зарегистрировать это устройство. Задайте новый мастер-пароль. Сервер никогда не получает код восстановления или ключи сейфа в открытом виде.';

  @override
  String get verifyAndUnlock => 'Проверить и разблокировать';

  @override
  String get verifyRecoveryCode => 'Проверить код восстановления';

  @override
  String get verifyYourIdentity => 'Подтвердите личность';

  @override
  String get yourPasswordUnlocksTheAccountKey =>
      'Пароль локально разблокирует ключ учётной записи.';

  @override
  String get yourServersYourKeysYourWorkspace =>
      'Ваши серверы.\nВаши ключи.\nВаше рабочее пространство.';

  @override
  String get theMasterPasswordsDontMatch => 'Мастер-пароли не совпадают';

  @override
  String get couldntCancelAccountDeletion =>
      'Не удалось отменить удаление учётной записи';

  @override
  String get couldntConnectToTheServer => 'Не удалось подключиться к серверу';

  @override
  String get registrationFailed => 'Не удалось зарегистрироваться';

  @override
  String get requestJsonCopied => 'JSON запроса скопирован';

  @override
  String get browserStorage => 'Хранилище браузера';

  @override
  String get checkAgain => 'Проверить снова';

  @override
  String get checkingPersistentStorage => 'Проверка постоянного хранилища…';

  @override
  String get checkingStorageUsageEstimate =>
      'Проверка оценки использования хранилища…';

  @override
  String estimatedUsageFormatbytesOfFormatbytes2For(
    String formatBytes,
    String formatBytes2,
  ) {
    return 'Оценка использования для сайта: $formatBytes из $formatBytes2';
  }

  @override
  String get persistentStorageCanReduceAutomaticEviction =>
      'Постоянное хранилище снижает риск автоматической очистки, но не заменяет резервные копии.';

  @override
  String get persistentStorageIsEnabled => 'Постоянное хранилище включено';

  @override
  String get persistentStorageIsNotEnabled =>
      'Постоянное хранилище не включено';

  @override
  String get persistentStorageStatusIsUnavailable =>
      'Состояние постоянного хранилища недоступно';

  @override
  String get requestPersistentStorage => 'Запросить постоянное хранилище';

  @override
  String get storageUsageEstimateIsUnavailable =>
      'Оценка использования хранилища недоступна';

  @override
  String get theBrowserCouldNotConfirmPersistent =>
      'Браузер не смог подтвердить состояние постоянного хранилища.';

  @override
  String get theBrowserCurrentlyReportsPersistentStorage =>
      'Браузер сообщает, что постоянное хранилище включено.';

  @override
  String get theBrowserDidNotEnablePersistent =>
      'Браузер не включил постоянное хранилище.';

  @override
  String get theRequestReturnedSuccessButThe =>
      'Запрос выполнен, но браузер по-прежнему сообщает, что хранилище не постоянное.';

  @override
  String get theRequestReturnedSuccessButThe2 =>
      'Запрос выполнен, но текущее состояние постоянного хранения не удалось проверить.';

  @override
  String pendingcountEncryptedChangeSAreWaiting(int pendingCount) {
    String _temp0 = intl.Intl.pluralLogic(
      pendingCount,
      locale: localeName,
      other: '$pendingCount зашифрованного изменения ожидают',
      many: '$pendingCount зашифрованных изменений ожидают',
      few: '$pendingCount зашифрованных изменения ожидают',
      one: '$pendingCount зашифрованное изменение ожидает',
    );
    return '$_temp0 в локальной очереди отправки этого браузера. Сервер ещё не подтвердил их получение; если очистить данные этого сайта до синхронизации, они будут удалены из этого браузера.';
  }

  @override
  String roundGib(int round) {
    return '$round ГиБ';
  }

  @override
  String roundKib(int round) {
    return '$round КиБ';
  }

  @override
  String roundMib(int round) {
    return '$round МиБ';
  }

  @override
  String get fileWorkspaceIsClosed => 'Рабочее пространство файлов закрыто.';

  @override
  String get theSavedGroupLayoutIsInvalid =>
      'Сохранённый макет группы недействителен. Сбросьте макет и повторите попытку.';

  @override
  String get invalidGroupSessionMapping =>
      'Недопустимое сопоставление сеансов группы.';

  @override
  String get aGroupLayoutNeeds1To =>
      'Для макета группы нужно от 1 до 32 SSH-хостов.';

  @override
  String get invalidLayoutHostsOrMoreThan =>
      'Недопустимые хосты макета или больше 32 панелей.';

  @override
  String get invalidLayoutRatio => 'Недопустимые пропорции макета.';

  @override
  String get thisWindowHasNoSshSessions =>
      'В этом окне нет SSH-сеансов этой группы.';

  @override
  String get upTo32PanesCanBe => 'Можно сохранить не более 32 панелей.';

  @override
  String get attachFile => 'Прикрепить файл';

  @override
  String get attachmentDownload => 'Скачивание вложения';

  @override
  String get attachmentUpload => 'Отправка вложения';

  @override
  String attachmentsName(String name) {
    return 'Вложения · $name';
  }

  @override
  String get cancel2 => 'Отмена';

  @override
  String get chooseAFileToAttach => 'Выберите файл для вложения…';

  @override
  String get close => 'Закрыть';

  @override
  String get discardDownloadedCopy => 'Удалить скачанную копию';

  @override
  String get discardOrphanTransfer => 'Удалить потерянную передачу';

  @override
  String get downloadAttachment => 'Скачать вложение';

  @override
  String downloadUnavailableAboveFormatsize(String formatSize) {
    return 'Скачивание недоступно для файлов больше $formatSize';
  }

  @override
  String get downloadingAndVerifyingAttachment =>
      'Скачивание и проверка вложения…';

  @override
  String get encryptingAndTransferring => 'Шифрование и передача…';

  @override
  String get filesAreEncryptedOnThisDevice =>
      'Файлы шифруются на этом устройстве до отправки. Имена, типы, ключи и содержимое файлов остаются внутри зашифрованной записи хоста.';

  @override
  String get noAttachmentsSavedForThisHost =>
      'Для этого хоста нет сохранённых вложений.';

  @override
  String get preparingAttachment => 'Подготовка вложения…';

  @override
  String get removeAttachment => 'Удалить вложение';

  @override
  String get removeAttachmentFromThisHost => 'Удалить вложение с этого хоста?';

  @override
  String get removeFromHost => 'Удалить с хоста';

  @override
  String removeFilenameFromTheCurrentEncrypted(String fileName) {
    return 'Удалить $fileName из текущей зашифрованной записи хоста? Более ранние версии хоста могут сохранять ссылки на вложение до очистки по сроку хранения на сервере.';
  }

  @override
  String get removingAttachment => 'Удаление вложения…';

  @override
  String get resumeDownload => 'Продолжить скачивание';

  @override
  String get resumeUpload => 'Продолжить отправку';

  @override
  String get resumingEncryptedUpload => 'Возобновление зашифрованной отправки…';

  @override
  String get saveCancelled => 'Сохранение отменено.';

  @override
  String get saveCancelledTheVerifiedEncryptedDownload =>
      'Сохранение отменено. Проверенная зашифрованная загрузка сохранена для повтора.';

  @override
  String get savingDecryptedAttachment =>
      'Сохранение расшифрованного вложения…';

  @override
  String get thisFileCannotBeLoadedInto =>
      'Этот файл нельзя загрузить в память клиента. Попробуйте файл поменьше.';

  @override
  String get transferTasks => 'Задачи передачи';

  @override
  String valuevalueMoreTasks(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: 'Ещё $valueValue задачи',
      many: 'Ещё $valueValue задач',
      few: 'Ещё $valueValue задачи',
      one: 'Ещё $valueValue задача',
    );
    return '$_temp0';
  }

  @override
  String get addAHost => 'Добавить хост';

  @override
  String get authentication => 'Аутентификация';

  @override
  String get directConnection => 'Прямое подключение';

  @override
  String get displayName => 'Отображаемое имя';

  @override
  String get editHost => 'Изменить хост';

  @override
  String get editPrivateKey => 'Изменить закрытый ключ';

  @override
  String get group => 'Группа';

  @override
  String get hidePrivateKey => 'Скрыть закрытый ключ';

  @override
  String get hostnameOrIp => 'Имя хоста или IP';

  @override
  String get jumpHost => 'Промежуточный хост';

  @override
  String get loginDetailsBelongToThisHost =>
      'Данные для входа относятся к этому хосту и шифруются вместе с ним.';

  @override
  String get noGroup => 'Без группы';

  @override
  String get noKeyEntered => 'Ключ не введён';

  @override
  String get pinTheCertificateFingerprintSuppliedBy =>
      'Закрепите отпечаток сертификата, предоставленный администратором.';

  @override
  String get rdpCertificateSha256Optional =>
      'SHA-256 сертификата RDP (необязательно)';

  @override
  String get routeThroughUpTo8Hosts =>
      'Маршрут через не более чем 8 хостов перед подключением к этому хосту.';

  @override
  String get saveEncryptedHost => 'Сохранить зашифрованный хост';

  @override
  String get separateTagsWithCommas => 'Разделяйте теги запятыми.';

  @override
  String get tags => 'Теги';

  @override
  String get thisSavedGroupIsUnavailableChoose =>
      'Сохранённая группа недоступна. Выберите «Без группы», чтобы очистить поле.';

  @override
  String get thisSavedJumpHostIsUnavailable =>
      'Сохранённый промежуточный хост недоступен, образует цикл или превышает 8 переходов. Выберите «Прямое подключение» или допустимый хост.';

  @override
  String get unavailableJumpHost => 'Недоступный промежуточный хост';

  @override
  String get signInDetailsAreStoredEncrypted =>
      'Данные для входа хранятся в зашифрованном виде. При подключении доверенный шлюз удалённого рабочего стола обрабатывает учётные данные и изображение.';

  @override
  String labelPressEnterToConnect(String label) {
    return '$label  ·  Enter — подключиться';
  }

  @override
  String get searchHostsOrTypeAnSsh =>
      'Поиск хостов или команда ssh / rdp / vnc / console';

  @override
  String get clearSearch => 'Очистить поиск';

  @override
  String get chooseAHostToConnectTo => 'Выберите хост для подключения';

  @override
  String countHosts2(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count хоста',
      many: '$count хостов',
      few: '$count хоста',
      one: '$count хост',
    );
    return '$_temp0';
  }

  @override
  String get all => 'Все';

  @override
  String get closeSearch => 'Закрыть поиск';

  @override
  String get allGroups => 'Все группы';

  @override
  String get filterByGroup => 'Фильтр по группе';

  @override
  String get searchAndQuickConnect => 'Поиск и быстрое подключение';

  @override
  String get favorites => 'Избранное';

  @override
  String get noMatchingHostsTypeAnSsh =>
      'Подходящих хостов нет. Введите команду ssh / rdp / vnc, чтобы подключиться к новому адресу.';

  @override
  String get operatingSystemNotIdentifiedYet =>
      'Операционная система ещё не определена';

  @override
  String operatingSystemLabel(String label) {
    return 'Операционная система: $label';
  }

  @override
  String get originalSshSessionConnected => 'Исходный SSH-сеанс · подключено';

  @override
  String get tools => 'Функции';

  @override
  String get originalSshSessionLive =>
      'Исходный SSH-сеанс · активное подключение';

  @override
  String get filesSftpScp => 'Файлы · SFTP / SCP';

  @override
  String get couldntOpenTheTerminalWindowGo =>
      'Не удалось открыть окно терминала. Вернитесь в главное окно и проверьте подключение.';

  @override
  String get thisWindowKeepsUsingTheOriginal =>
      'Это окно продолжает использовать исходный SSH-сеанс.';

  @override
  String get terminalProperties => 'Свойства терминала';

  @override
  String get earlierOutputExceedsThisWindowsDisplay =>
      'Более ранний вывод превышает лимит отображения этого окна. Выполняемые команды не затронуты.';

  @override
  String get connectionLostReturnToTheOriginal =>
      'Соединение потеряно · вернитесь в исходное окно';

  @override
  String get connectionLost => 'Соединение потеряно';

  @override
  String get sshOutputStreamError => '\n[Ошибка потока вывода SSH]\n';

  @override
  String get sshConnectionClosed => '\n[SSH-соединение закрыто]\n';

  @override
  String get sshErrorStreamUnavailable => '\n[Поток ошибок SSH недоступен]\n';

  @override
  String get anotherOperationIsRunningRetryWhen =>
      'Выполняется другая операция. Повторите после её завершения.';

  @override
  String get bashInputHistory => 'История ввода Bash';

  @override
  String get console => 'Консоль';

  @override
  String get couldNotSaveForwardingSettingsNothing =>
      'Не удалось сохранить настройки переадресации; ничего не изменено.';

  @override
  String get home => 'Главная';

  @override
  String hostHostid(String hostId) {
    return 'Хост $hostId';
  }

  @override
  String get theHostSaveResultCouldntBe =>
      'Не удалось подтвердить сохранение хоста. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get theHostWasSavedButThe =>
      'Хост сохранён, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theHostWasDeletedButThe =>
      'Хост удалён, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theHostWasChangedByAnother =>
      'Хост изменён другой операцией. Откройте его заново и повторите попытку.';

  @override
  String get theHostWasUpdatedButThe =>
      'Хост обновлён, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get hostActions => 'Действия с хостом';

  @override
  String get whenAHostDoesntSelectA =>
      'Если для хоста учётные данные не выбраны явно, используются учётные данные по умолчанию ближайшей родительской группы.';

  @override
  String get localHostRevisionIsMissing =>
      'Отсутствует локальная версия хоста.';

  @override
  String get localDefaultWorkspacePreferenceIsInvalid =>
      'Локальная настройка рабочего пространства по умолчанию недействительна.';

  @override
  String get localProfileCleanupFailed =>
      'Не удалось очистить локальный профиль.';

  @override
  String get localvaultHostKeyTrust => 'Доверие к ключам хостов LocalVault';

  @override
  String get noLocalProfile => 'Нет локального профиля.';

  @override
  String get notStartedFromASingleConnected =>
      'Не запущено из одной подключённой вкладки SSH. Измените профили здесь, затем запустите их через переадресацию портов SSH в подключённой вкладке.';

  @override
  String get preferencesCannotBeTheDefaultWorkspace =>
      'Настройки не могут быть рабочим пространством по умолчанию.';

  @override
  String get profilesAreEncryptedInsideThisHost2 =>
      'Профили шифруются в записи хоста локального профиля на этом устройстве. Состояние работы и сокеты никогда не сохраняются.';

  @override
  String get protectedDeviceKeyUnavailable =>
      'Защищённый ключ устройства недоступен.';

  @override
  String get theSshHostKeyChangedOr =>
      'Ключ SSH-хоста изменился или записи доверия конфликтуют; подключение отклонено. Сначала проверьте и отзовите старое доверие.';

  @override
  String get theSshHostKeyWasntApproved =>
      'Ключ SSH-хоста не одобрен, подключение отклонено.';

  @override
  String get sshPrivateKey => 'Закрытый ключ SSH';

  @override
  String get sshPortForwarding2 => 'Переадресация портов SSH';

  @override
  String get shellLabel => 'Метка оболочки';

  @override
  String get snippetChanged => 'Сниппет изменён';

  @override
  String get theLocalProfileChanged => 'Локальный профиль изменился.';

  @override
  String get thisHostChangedInAnotherOperation =>
      'Хост изменён другой операцией. Список обновлён; проверьте и повторите попытку.';

  @override
  String get webLocalvaultDoesntSupportSshSftp =>
      'Веб-версия LocalVault пока не поддерживает SSH / SFTP';

  @override
  String algorithmFingerprintOriginallyApprovedInArchive(
    String algorithm,
    String fingerprint,
    DateTime toLocal,
  ) {
    final intl.DateFormat toLocalDateFormat = intl.DateFormat.yMMMd(localeName)
        .add_jm();
    final String toLocalString = toLocalDateFormat.format(toLocal);

    return '$algorithm\n$fingerprint\nИсходное одобрение в архиве: $toLocalString';
  }

  @override
  String groupparentlabelHostscountHostsChildrencountSubgroups(
    String groupParentLabel,
    int hostsCount,
    int childrenCount,
  ) {
    return '$groupParentLabel · хостов: $hostsCount · подгрупп: $childrenCount';
  }

  @override
  String hostPortPendingReview(String host, int port) {
    return '$host:$port · ожидает проверки';
  }

  @override
  String nameWillBeDeletedFromThis(String name) {
    return '«$name» будет удалён из этого локального профиля.';
  }

  @override
  String titleWillBeDeletedFromThis(String title) {
    return '«$title» будет удалён из этого локального профиля.';
  }

  @override
  String get previousMatch2 => 'Предыдущее совпадение';

  @override
  String get nextMatch2 => 'Следующее совпадение';

  @override
  String get noDefaultCredential => 'Без учётных данных по умолчанию';

  @override
  String get theLocalArchivePassphrasesDontMatch =>
      'Парольные фразы локального архива не совпадают.';

  @override
  String theMasterPasswordMustBeAt(int minimumPasswordLength) {
    String _temp0 = intl.Intl.pluralLogic(
      minimumPasswordLength,
      locale: localeName,
      other:
          'Мастер-пароль должен содержать не менее $minimumPasswordLength символа.',
      many:
          'Мастер-пароль должен содержать не менее $minimumPasswordLength символов.',
      few:
          'Мастер-пароль должен содержать не менее $minimumPasswordLength символов.',
      one:
          'Мастер-пароль должен содержать не менее $minimumPasswordLength символа.',
    );
    return '$_temp0';
  }

  @override
  String get masterPasswordAtLeast12Characters =>
      'Мастер-пароль (не менее 12 символов)';

  @override
  String get hostsAndSignInDetailsAre =>
      'Хосты и данные для входа хранятся в локальном профиле';

  @override
  String get couldntSaveTheHostCheckThe =>
      'Не удалось сохранить хост. Проверьте настройки и повторите попытку.';

  @override
  String get useTheModAltAndShift =>
      'Используйте модификаторы mod, alt и shift; mod означает Command на платформах Apple и Control на остальных. Каждое сочетание должно быть уникальным; зарезервированные браузером или ОС сочетания использовать нельзя.';

  @override
  String get saveGroup => 'Сохранить группу';

  @override
  String get saveEncryptedCredential =>
      'Сохранить зашифрованные учётные данные';

  @override
  String get saveEncryptedSnippet => 'Сохранить зашифрованный сниппет';

  @override
  String get saveShortcuts => 'Сохранить сочетания клавиш';

  @override
  String get theSavedGroupLayoutIsInvalid2 =>
      'Сохранённый макет группы недействителен. Сначала сбросьте макет.';

  @override
  String get saveTerminalTheme => 'Сохранить тему терминала';

  @override
  String get saveTerminalFontSize => 'Сохранить размер шрифта терминала';

  @override
  String get saveDefaultWorkspace =>
      'Сохранить рабочее пространство по умолчанию';

  @override
  String get trustReviewFailedTheExistingSsh =>
      'Повторная проверка доверия не удалась. Текущее состояние доверия SSH не изменено; перезагрузите и проверьте снова.';

  @override
  String get thePreferenceSaveResultCouldntBe =>
      'Не удалось подтвердить сохранение настроек. Перезагрузите их, прежде чем решать, сохранять ли снова.';

  @override
  String get preferencesSavedAndApplied => 'Настройки сохранены и применены.';

  @override
  String get preferencesAreSavedEncryptedInThis =>
      'Настройки хранятся в зашифрованном виде в этом локальном профиле.';

  @override
  String get preferencesWereChangedByAnotherOperation =>
      'Настройки изменены другой операцией; текущие значения перезагружены. Проверьте их перед сохранением.';

  @override
  String get stopConnecting => 'Остановить подключение';

  @override
  String get stopCapture => 'Остановить запись';

  @override
  String get otherLocalRecords => 'Другие локальные записи';

  @override
  String get credentials => 'Учётные данные';

  @override
  String get theCredentialSaveResultCouldntBe =>
      'Не удалось подтвердить сохранение учётных данных. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get theCredentialDeletionResultCouldntBe =>
      'Не удалось подтвердить удаление учётных данных. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String credentialParameterNameMustReferenceA(String name) {
    return 'Параметр учётных данных $name должен ссылаться на парольные учётные данные этого локального профиля.';
  }

  @override
  String get credentialName => 'Имя учётных данных';

  @override
  String get theCredentialNoLongerExistsRefresh =>
      'Учётные данные больше не существуют. Обновите список.';

  @override
  String get theCredentialWasSavedButThe =>
      'Учётные данные сохранены, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theCredentialWasDeletedButThe =>
      'Учётные данные удалены, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theCredentialWasChangedByAnother =>
      'Учётные данные изменены другой операцией. Обновите список и повторите попытку.';

  @override
  String get theCredentialWasUpdatedButThe =>
      'Учётные данные обновлены, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get credentialActions => 'Действия с учётными данными';

  @override
  String get theCredentialUpdateResultCouldntBe =>
      'Не удалось подтвердить обновление учётных данных. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get setTheTerminalFontSizeColors =>
      'Отдельно настройте размер шрифта, цвета и сочетания клавиш терминала.';

  @override
  String groupGroupid(String groupId) {
    return 'Группа $groupId';
  }

  @override
  String groupName(String name) {
    return 'Группа «$name»';
  }

  @override
  String get theGroupIsStillUsedBy =>
      'Группа ещё используется подгруппами или хостами. Переместите или удалите их, прежде чем удалять группу.';

  @override
  String get theGroupSaveResultCouldntBe =>
      'Не удалось подтвердить сохранение группы. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get theGroupDeletionResultCouldntBe =>
      'Не удалось подтвердить удаление группы. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get groupName2 => 'Имя группы';

  @override
  String get theGroupWasSavedButThe =>
      'Группа сохранена, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theGroupWasDeletedButThe =>
      'Группа удалена, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theGroupChangedRefreshAndSave =>
      'Группа изменилась. Обновите и сохраните макет заново.';

  @override
  String get theGroupWasChangedByAnother =>
      'Группа изменена другой операцией. Обновите список и повторите попытку.';

  @override
  String get theGroupWasChangedByAnother2 =>
      'Группа изменена другой операцией. Откройте её заново и повторите попытку.';

  @override
  String get theGroupWasUpdatedButThe =>
      'Группа обновлена, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String groupActionsName(String name) {
    return 'Действия с группой: $name';
  }

  @override
  String get theGroupUpdateResultCouldntBe =>
      'Не удалось подтвердить результат обновления группы. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get groupWindowLayoutSaved => 'Макет окон группы сохранён.';

  @override
  String get theGroupRecordWasChangedBy =>
      'Запись группы изменена другой операцией. Обновите список и повторите попытку.';

  @override
  String get listView => 'Список';

  @override
  String get afterCreatingALocalProfileYou =>
      'Создав локальный профиль, вы сможете хранить хосты и учётные данные в зашифрованном виде на этом устройстве.';

  @override
  String createdFormatdate(String formatDate) {
    return 'Создан $formatDate';
  }

  @override
  String get createGroupsToOrganizeHostsGroups =>
      'Создавайте группы, чтобы упорядочить хосты; группы и их иерархия хранятся только в этом локальном профиле.';

  @override
  String get createAndUnlock => 'Создать и разблокировать';

  @override
  String get createNewProfile => 'Создать профиль';

  @override
  String get couldntDeleteTheHostTryAgain =>
      'Не удалось удалить хост. Повторите попытку.';

  @override
  String get deleteHost => 'Удалить хост?';

  @override
  String get deleteCredential => 'Удалить учётные данные';

  @override
  String get deleteCredential2 => 'Удалить учётные данные?';

  @override
  String get deleteGroup => 'Удалить группу';

  @override
  String get deleteGroup2 => 'Удалить группу?';

  @override
  String get deleteSnippet => 'Удалить сниппет';

  @override
  String get deleteSnippet2 => 'Удалить сниппет?';

  @override
  String get couldntSaveHistoryCommandsInMemory =>
      'Не удалось сохранить историю; команды в памяти пока доступны для просмотра. Проверьте локальное хранилище.';

  @override
  String get previousParentUnavailable => 'Прежний родитель недоступен';

  @override
  String get previousDefaultCredentialUnavailable =>
      'Прежние учётные данные по умолчанию недоступны';

  @override
  String get argumentList => 'Список аргументов';

  @override
  String get parameterDefinitions => 'Определения параметров';

  @override
  String get parameterDefinitionsJsonArray =>
      'Определения параметров (массив JSON)';

  @override
  String get argumentsJsonArray => 'Аргументы (массив JSON)';

  @override
  String windowfailuresPlural11MoreWindow(int windowFailures) {
    return 'Не удалось восстановить ещё окна или положения: $windowFailures.';
  }

  @override
  String onlyContinueAfterVerifyingTheFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
  ) {
    return 'Продолжайте только после сверки отпечатка по доверенному каналу. После подтверждения это устройство создаст новую локальную запись доверия для конечной точки:\n\n$host:$port\n$algorithm\n$fingerprint\n\nСтарое одобрение из архива само по себе не разрешает подключения.';
  }

  @override
  String get afterEnablingCopyTheSetupCommand =>
      'После включения скопируйте команду настройки, вставьте её в текущий Bash и нажмите Enter. Записываются только выполненные команды; ввод в запросах пароля не перехватывается, но секреты в самих командах могут попасть в запись. История хранится в зашифрованном виде в профиле этого устройства, до 500 записей / 48 КиБ на хост. После остановки записи выполните atermius_off в Bash, чтобы удалить хук.';

  @override
  String get enableAndCopySetupCommand =>
      'Включить и скопировать команду настройки';

  @override
  String get completedCommandsAreRecordedAfterEnabling =>
      'Выполненные команды записываются после включения интеграции с Bash в настройках записи.';

  @override
  String get reviewAndTrust => 'Проверить и доверять';

  @override
  String get reviewSshHostKeysFromThe => 'Проверьте ключи SSH-хостов из архива';

  @override
  String get wrongPasswordOrTheLocalProfile =>
      'Неверный пароль или локальный профиль не удаётся разблокировать.';

  @override
  String get importLocalEncryptedArchive =>
      'Импорт локального зашифрованного архива';

  @override
  String get exportLocalEncryptedArchive =>
      'Экспорт локального зашифрованного архива';

  @override
  String get trusted => 'Доверенный';

  @override
  String get savingTheLocalEncryptedArchiveWas =>
      'Сохранение локального зашифрованного архива отменено.';

  @override
  String get bashRecordingIsOnClickTo =>
      'Запись Bash включена. Нажмите, чтобы вставить, затем Enter для запуска.';

  @override
  String get revoked => 'Отозван';

  @override
  String get disconnected => 'Отключено';

  @override
  String get theArchiveWasImportedButSome =>
      'Архив импортирован, но некоторые списки не удалось обновить. Перезагрузите профиль.';

  @override
  String get thereAreTooManySplitsTo =>
      'Слишком много разделений, чтобы сохранить этот макет группы.';

  @override
  String get thisWindowHasNoSessionLayout =>
      'В этом окне нет макета сеансов этой группы.';

  @override
  String get invalidShortcutUseSupportedLetterDigit =>
      'Недопустимое сочетание: используйте поддерживаемые буквы, цифры или F1–F12, и все сочетания должны быть уникальными.';

  @override
  String get aShortcutIsInvalidOrDuplicated =>
      'Сочетание недопустимо или повторяется. Исправьте его перед сохранением.';

  @override
  String get restoreDefaultShortcuts => 'Восстановить сочетания по умолчанию';

  @override
  String get theSelectedParentGroupNoLonger =>
      'Выбранная родительская группа больше не существует. Обновите список и повторите попытку.';

  @override
  String get openLocalWorkspace => 'Открыть локальное рабочее пространство';

  @override
  String get executionType => 'Тип выполнения';

  @override
  String get reject => 'Отклонить';

  @override
  String get searchTerminal => 'Поиск в терминале';

  @override
  String get searchTerminalHistory => 'Поиск в истории терминала';

  @override
  String get revokeSshHostKeyTrust => 'Отозвать доверие к ключу SSH-хоста?';

  @override
  String afterRevokingThisKeyForHost(String host, int port) {
    return 'После отзыва этого ключа для $host:$port последующие подключения придётся снова проверить и явно одобрить.';
  }

  @override
  String get revokeTrust => 'Отозвать доверие';

  @override
  String get revokingFailedTheTrustStateIs =>
      'Отзыв не удался. Состояние доверия не изменено; повторите попытку.';

  @override
  String get revokeTrustForThisKey => 'Отозвать доверие к этому ключу';

  @override
  String get theFileWindowDidntOpenTry =>
      'Окно файлов не открылось. Повторите попытку.';

  @override
  String get theHostRequestedByTheFile =>
      'Хост, запрошенный окном файлов, не существует.';

  @override
  String get theLocalProfileRequestedByThe =>
      'Локальный профиль, запрошенный окном файлов, не существует.';

  @override
  String get textParametersAndPasswordCredentialReferences =>
      'Текстовые параметры и ссылки на парольные учётные данные имеют ту же структуру, что и серверные сниппеты; все тексты и значения по умолчанию зашифрованы.';

  @override
  String get disconnectCurrentTerminal => 'Отключить текущий терминал';

  @override
  String get disconnect => 'Отключить';

  @override
  String get passwordsAndKeysForNewHosts =>
      'Пароли и ключи новых хостов задаются прямо в сведениях о хосте.';

  @override
  String get newGroup => 'Новая группа';

  @override
  String get theNewWindowDidntOpenThe =>
      'Новое окно не открылось; сеанс остаётся в текущем окне.';

  @override
  String get theNewWindowDidntOpenThe2 =>
      'Новое окно не открылось; удалённый рабочий стол остаётся в текущем окне.';

  @override
  String get couldntSaveTheGroupLayoutTry =>
      'Не удалось сохранить макет группы. Повторите попытку.';

  @override
  String get couldntSaveTheWindowSetCheck =>
      'Не удалось сохранить набор окон. Проверьте имя и количество сеансов или разблокируйте снова и повторите попытку.';

  @override
  String get couldntCreateTheLocalProfileTry =>
      'Не удалось создать локальный профиль. Повторите попытку.';

  @override
  String get couldntDeleteTheWindowSet => 'Не удалось удалить набор окон.';

  @override
  String get couldntRefreshTheHostListThe =>
      'Не удалось обновить список хостов. Запись могла быть выполнена; перезагрузите данные, прежде чем продолжать.';

  @override
  String get couldntRefreshTheLocalCredentialList =>
      'Не удалось обновить список локальных учётных данных. Запись могла быть выполнена; перезагрузите данные, прежде чем продолжать.';

  @override
  String get couldntRefreshTheLocalGroupList =>
      'Не удалось обновить список локальных групп. Запись могла быть выполнена; перезагрузите данные, прежде чем продолжать.';

  @override
  String get couldntRefreshTheLocalSnippetList =>
      'Не удалось обновить список локальных сниппетов. Запись могла быть выполнена; перезагрузите данные, прежде чем продолжать.';

  @override
  String get couldntStartTheConsole => 'Не удалось запустить консоль.';

  @override
  String get couldntSafelySaveTheDeviceUnlock =>
      'Не удалось безопасно сохранить ключ разблокировки устройства. Проверьте системное защищённое хранилище и повторите попытку или создайте профиль с паролем вручную.';

  @override
  String get couldntExitTheLocalProfileSafely =>
      'Не удалось безопасно выйти из локального профиля. Повторите попытку.';

  @override
  String get couldntImportTheLocalArchiveNothing =>
      'Не удалось импортировать локальный архив; в целевой профиль ничего не записано.';

  @override
  String get couldntExportTheLocalProfileTry =>
      'Не удалось экспортировать локальный профиль. Повторите попытку; локальные данные не изменены.';

  @override
  String get couldntOpenANewWindowTry =>
      'Не удалось открыть новое окно. Повторите попытку.';

  @override
  String get couldntOpenTheWindowSet => 'Не удалось открыть набор окон.';

  @override
  String get couldntOpenTheRequestedFileWindow =>
      'Не удалось открыть запрошенное окно файлов. Проверьте подключение и доверие к ключу хоста.';

  @override
  String get couldntConfirmThatTheTargetProfile =>
      'Не удалось подтвердить, что целевой профиль пуст. Повторите попытку.';

  @override
  String get couldntReadLocalSshHostKey =>
      'Не удалось прочитать локальное доверие к ключам SSH-хостов.';

  @override
  String get couldntReadLocalPreferencesTheSave =>
      'Не удалось прочитать локальные настройки. Сохранение могло быть выполнено; перезагрузите их, прежде чем продолжать.';

  @override
  String get couldntReadLocalPreferencesYouCan =>
      'Не удалось прочитать локальные настройки. Повторите попытку на странице настроек.';

  @override
  String get couldntReadTheLocalCredentialList =>
      'Не удалось прочитать список локальных учётных данных. Повторите попытку на странице учётных данных.';

  @override
  String get couldntReadTheLocalGroupList =>
      'Не удалось прочитать список локальных групп. Повторите попытку на странице групп.';

  @override
  String get couldntReadTheLocalArchiveFile =>
      'Не удалось прочитать файл локального архива. Повторите попытку.';

  @override
  String get couldntReadTheLocalSnippetList =>
      'Не удалось прочитать список локальных сниппетов. Повторите попытку на странице сниппетов.';

  @override
  String get couldntReadTheLocalProfileList2 =>
      'Не удалось прочитать список локальных профилей. Повторите попытку перед созданием профиля.';

  @override
  String get couldntReadThisHostsSignIn =>
      'Не удалось прочитать данные для входа на этот хост.';

  @override
  String get couldntConnectToTheLocalSsh =>
      'Не удалось подключиться к локальному SSH-хосту. Проверьте сеть и учётные данные и повторите попытку.';

  @override
  String get showKey => 'Показать ключ';

  @override
  String get couldntUpdateTheHostTryAgain =>
      'Не удалось обновить хост. Повторите попытку.';

  @override
  String valuevaluePlural11MonitorWindow(int valueValue) {
    return 'Не удалось открыть окна мониторов: $valueValue; выберите снова, чтобы повторить.';
  }

  @override
  String get localUnlocked => 'Локально · разблокировано';

  @override
  String get localLocked => 'Локально · заблокировано';

  @override
  String get localEncryptedArchiveSaved =>
      'Локальный зашифрованный архив сохранён.';

  @override
  String get theLocalEncryptedArchiveWasImported =>
      'Локальный зашифрованный архив импортирован; каждый активный ключ SSH-хоста из архива нужно проверить в разделе «Доверие к ключам хостов».';

  @override
  String get localArchivePassphrase => 'Парольная фраза локального архива';

  @override
  String get theLocalArchivePassphraseCanBe =>
      'Парольная фраза локального архива может занимать не более 1024 байт UTF-8.';

  @override
  String get theLocalArchiveFileIsInvalid =>
      'Файл локального архива недействителен или превышает допустимый размер.';

  @override
  String get theLocalArchiveFileExceedsThe =>
      'Файл локального архива превышает допустимый размер.';

  @override
  String get localModeOnlyManagesEncryptedSnippets =>
      'В локальном режиме доступно только управление зашифрованными сниппетами; чтобы подключаться к хостам и запускать сниппеты, переключитесь на режим синхронизации с сервером.';

  @override
  String get localProfile2 => 'Локальный профиль';

  @override
  String localProfileSubstring2(String substring) {
    return 'Локальный профиль · $substring';
  }

  @override
  String get localProfileMasterPassword => 'Мастер-пароль локального профиля';

  @override
  String get localProfileDataIsMissingOr =>
      'Данные локального профиля отсутствуют или не читаются. Разблокировка заблокирована, чтобы пустая база не считалась действительным профилем; восстановите локальные данные или используйте резервную копию.';

  @override
  String get tagsCommaSeparated => 'Теги (через запятую)';

  @override
  String get verifyAndTrustThisKey => 'Проверить ключ и доверять ему';

  @override
  String get thisLocalvaultSshRouteIsntSupported =>
      'Этот SSH-маршрут LocalVault не поддерживается.';

  @override
  String get thisLocalvaultHasNoSshHost =>
      'В этом LocalVault пока нет записей доверия к ключам SSH-хостов.';

  @override
  String get thisHostKeyWasRevokedBefore => 'Этот ключ хоста ранее был отозван';

  @override
  String thisCredentialIsStillReferencedBy(String credentialReferenceLabel) {
    return 'На эти учётные данные всё ещё ссылается $credentialReferenceLabel. Измените или удалите ссылку, прежде чем удалять их.';
  }

  @override
  String get thisGroupDoesntHaveAnyConnectable =>
      'В этой группе пока нет SSH-хостов для подключения.';

  @override
  String get thisPassphraseIsSeparateFromThe =>
      'Эта парольная фраза не связана с мастер-паролем локального профиля; храните её отдельно. Содержимое архива шифруется с помощью Argon2id и XChaCha20-Poly1305.';

  @override
  String get thisWorkspaceIsProtectedByThe =>
      'Это рабочее пространство защищено защищённым хранилищем учётной записи ОС; блокировка закрывает текущий сеанс.';

  @override
  String get thisConsoleIsntSupportedOnThis =>
      'Эта консоль не поддерживается на этой платформе.';

  @override
  String get eachLayoutCanHaveUpTo =>
      'В одном макете не более 32 SSH-хостов. Разделите его на подгруппы.';

  @override
  String get noMatchingHosts => 'Подходящих хостов нет';

  @override
  String get localvaultInTheBrowserCanManage =>
      'LocalVault в браузере позволяет управлять хостами и учётными данными с локальным шифрованием, но не может открывать отсюда SSH- или SFTP-подключения. Вернитесь к выбору рабочего пространства и откройте серверное пространство, чтобы подключаться к хостам синхронизируемого сейфа через Web Relay.';

  @override
  String get addHostDetailsToStoreThem =>
      'Добавьте сведения о хосте, чтобы сохранить их в зашифрованном виде в этом локальном профиле.';

  @override
  String get addCredential => 'Добавить учётные данные';

  @override
  String get addLocalCredential => 'Добавить локальные учётные данные';

  @override
  String get addLocalGroup => 'Добавить локальную группу';

  @override
  String get addLocalSnippet => 'Добавить локальный сниппет';

  @override
  String get addSnippet => 'Добавить сниппет';

  @override
  String get addASignInPasswordOr =>
      'Добавьте пароль для входа или закрытый ключ SSH; шифротекст хранится только в этом локальном профиле.';

  @override
  String get addAScriptOrAStructured =>
      'Добавьте скрипт или структурированную команду Bash; текст хранится только в зашифрованном локальном профиле.';

  @override
  String get parentGroup => 'Родительская группа';

  @override
  String get theParentGroupNoLongerExists =>
      'Родительская группа больше не существует, или такая иерархия образует цикл. Выберите заново и повторите попытку.';

  @override
  String get parentMissing => 'Родитель отсутствует';

  @override
  String parentName(String name) {
    return 'Родитель: $name';
  }

  @override
  String get snippet => 'Сниппет';

  @override
  String snippetSnippetid(String snippetId) {
    return 'Сниппет $snippetId';
  }

  @override
  String snippetTitle(String title) {
    return 'Сниппет «$title»';
  }

  @override
  String get theSnippetSaveResultCouldntBe =>
      'Не удалось подтвердить сохранение сниппета. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get theSnippetDeletionResultCouldntBe =>
      'Не удалось подтвердить удаление сниппета. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get theSnippetNoLongerExistsRefresh =>
      'Сниппет больше не существует. Обновите список.';

  @override
  String get theSnippetWasSavedButThe =>
      'Сниппет сохранён, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theSnippetWasDeletedButThe =>
      'Сниппет удалён, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String get theSnippetWasChangedByAnother =>
      'Сниппет изменён другой операцией. Обновите список и повторите попытку.';

  @override
  String get theSnippetWasUpdatedButThe =>
      'Сниппет обновлён, но список не удалось обновить. Обновите список ещё раз.';

  @override
  String snippetActionsTitle(String title) {
    return 'Действия со сниппетом: $title';
  }

  @override
  String get theSnippetUpdateResultCouldntBe =>
      'Не удалось подтвердить обновление сниппета. Обновите список, прежде чем решать, повторять ли действие.';

  @override
  String get snippetTitle2 => 'Название сниппета';

  @override
  String existingShellLabelShell(String shell) {
    return 'Текущая метка оболочки: $shell';
  }

  @override
  String get leaveBlankToKeepTheCurrent =>
      'Оставьте пустым, чтобы сохранить текущий ключ; введённое значение заменит его.';

  @override
  String targetHostPortAlgorithmAlgorithmFingerprint(
    String host,
    int port,
    String algorithm,
    String fingerprint,
    String valueValue,
  ) {
    return 'Цель: $host:$port\nАлгоритм: $algorithm\nОтпечаток: $fingerprint\n\n$valueValue';
  }

  @override
  String get confirmTrustingThisKey => 'Подтвердить доверие к этому ключу';

  @override
  String get confirmLocalArchivePassphrase =>
      'Подтвердите парольную фразу локального архива';

  @override
  String get privateKeyPassphraseOptional =>
      'Парольная фраза закрытого ключа (необязательно)';

  @override
  String get program => 'Программа';

  @override
  String get windowSetSavedSomeSeparateWindows =>
      'Набор окон сохранён; некоторые отдельные окна не поддерживают чтение положения.';

  @override
  String windowSetOpenedValuevalueCountSessions(
    int valueValue,
    int count,
    int failures,
  ) {
    return 'Набор окон открыл сеансы: $valueValue из $count; не удалось подключить: $failures.';
  }

  @override
  String get portForwarding => 'Переадресация портов';

  @override
  String get manageSshHostKeyTrust => 'Управление доверием к ключам SSH-хостов';

  @override
  String get terminalTheme => 'Тема терминала';

  @override
  String get terminalFontSize2 => 'Размер шрифта в терминале';

  @override
  String get structuredBashCommand => 'Структурированная команда Bash';

  @override
  String get structuredCommandsSupportBashOnlyHere =>
      'Структурированные команды поддерживают только Bash; здесь они лишь сохраняются в зашифрованном виде и не выполняются в локальном режиме.';

  @override
  String get continueLabel2 => 'Продолжить';

  @override
  String get editCredential => 'Изменить учётные данные';

  @override
  String get editLocalCredential => 'Изменить локальные учётные данные';

  @override
  String get editLocalGroup => 'Изменить локальную группу';

  @override
  String get editLocalSnippet => 'Изменить локальный сниппет';

  @override
  String get editSnippet => 'Изменить сниппет';

  @override
  String get gridView => 'Сетка';

  @override
  String get script => 'Скрипт';

  @override
  String scriptShell(String shell) {
    return 'Скрипт · $shell';
  }

  @override
  String get scriptBody => 'Текст скрипта';

  @override
  String get unlockLocalProfile => 'Разблокировать локальный профиль';

  @override
  String get authenticationType => 'Тип аутентификации';

  @override
  String get letExternalAiAccessTheCurrent =>
      'Подключите внешний ИИ к текущему локальному рабочему пространству.';

  @override
  String get setLocalArchivePassphrase =>
      'Задать парольную фразу локального архива';

  @override
  String get thisPreferenceAlreadyExistsAndThe =>
      'Эта настройка уже существует; текущее значение перезагружено. Проверьте его перед сохранением.';

  @override
  String get thisKeyWasRevokedBeforeOnly =>
      'Этот ключ ранее был отозван. Одобряйте его снова только после повторной проверки идентичности сервера.';

  @override
  String get thisSnippetIdAlreadyExistsCreate =>
      'Сниппет с таким ID уже существует. Создайте его заново.';

  @override
  String get createAnEmptyLocalProfileFirst =>
      'Сначала создайте пустой локальный профиль, затем импортируйте архив.';

  @override
  String get unlockTheLocalProfileFirst =>
      'Сначала разблокируйте локальный профиль.';

  @override
  String get chooseALocalProfileFirst => 'Сначала выберите локальный профиль.';

  @override
  String get unlockTheTargetLocalProfileTo =>
      'Разблокируйте целевой локальный профиль, чтобы открыть окно файлов.';

  @override
  String get enterTheSshPrivateKey => 'Введите закрытый ключ SSH.';

  @override
  String get enterACredentialNameAndUser =>
      'Введите имя учётных данных и имя пользователя.';

  @override
  String get enterAPassword => 'Введите пароль.';

  @override
  String get enterTheLocalProfileMasterPassword =>
      'Введите мастер-пароль локального профиля.';

  @override
  String get enterASnippetTitle => 'Введите название сниппета.';

  @override
  String get enterTheScriptBody => 'Введите текст скрипта.';

  @override
  String get verifyThisFingerprintOverATrusted =>
      'Сверьте этот отпечаток по доверенному каналу. После одобрения он сохраняется только в текущем LocalVault.';

  @override
  String get enterLocalArchivePassphrase =>
      'Введите парольную фразу локального архива';

  @override
  String get backToWorkspaceSelection =>
      'Вернуться к выбору рабочего пространства';

  @override
  String get noHostsYet => 'Хостов пока нет';

  @override
  String get noCredentialsYet => 'Учётных данных пока нет';

  @override
  String get noGroupsYet => 'Групп пока нет';

  @override
  String get noLocalProfilesYet => 'Локальных профилей пока нет';

  @override
  String get noSnippetsYet => 'Сниппетов пока нет';

  @override
  String get connectGroup => 'Подключить группу';

  @override
  String get connectionClosed => 'Соединение закрыто';

  @override
  String get connectDirectFromThisDevice =>
      'Подключиться (напрямую с этого устройства)';

  @override
  String get exitLocalProfile => 'Выйти из локального профиля';

  @override
  String get chooseTheWorkspaceModeAndThe =>
      'Выберите режим рабочего пространства и страницу по умолчанию. Настройки сохраняются в текущем локальном профиле.';

  @override
  String get chooseAProfileToUnlock => 'Выберите профиль для разблокировки';

  @override
  String get someSeparateWindowsOrWindowPositions =>
      'Не удалось восстановить некоторые отдельные окна или их положение; сеансы остаются в текущем окне.';

  @override
  String profileSubstring(String substring) {
    return 'Профиль $substring';
  }

  @override
  String get profileHostAndCredentialRecordsAre =>
      'Записи профиля, хостов и учётных данных защищены локальным ключом шифрования.';

  @override
  String get theProfileWasClosedButAutomatic =>
      'Профиль закрыт, но автоматическую разблокировку отозвать не удалось. Разблокируйте и снова заблокируйте, чтобы повторить.';

  @override
  String get retryRefresh => 'Повторить обновление';

  @override
  String get retryReading => 'Повторить чтение';

  @override
  String get retryReadingProfiles => 'Повторить чтение профилей';

  @override
  String get lockAndReturnToProfiles => 'Заблокировать и вернуться к профилям';

  @override
  String get lockProfile => 'Заблокировать профиль';

  @override
  String get hideKey => 'Скрыть ключ';

  @override
  String get topLevelGroup => 'Группа верхнего уровня';

  @override
  String get color => 'Цвет';

  @override
  String get firstConnectionUnknownSshHostKey =>
      'Первое подключение: неизвестный ключ SSH-хоста';

  @override
  String get defaultLabel => 'По умолчанию';

  @override
  String get defaultCredential => 'Учётные данные по умолчанию';

  @override
  String get allLocalRecordsArePreflightedBefore =>
      'Перед созданием нового сейфа все локальные записи проходят предварительную проверку. Неподдерживаемые настройки, метки удаления, отсутствующие ссылки или ссылки на объекты вложений останавливают миграцию до любой записи на сервер.';

  @override
  String get cancelEmptyPreparation => 'Отменить пустую подготовку';

  @override
  String get continueMigration => 'Продолжить миграцию';

  @override
  String get importedLocalProfiles => 'Импортированные локальные профили';

  @override
  String get localProfile => 'Локальный профиль';

  @override
  String get localProfilePassword => 'Пароль локального профиля';

  @override
  String localProfileUnlockedCountResumableMigration(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Локальный профиль разблокирован · $count миграции могут быть продолжены',
      many:
          'Локальный профиль разблокирован · $count миграций могут быть продолжены',
      few:
          'Локальный профиль разблокирован · $count миграции могут быть продолжены',
      one:
          'Локальный профиль разблокирован · $count миграция может быть продолжена',
    );
    return '$_temp0';
  }

  @override
  String localProfileSubstring(String substring) {
    return 'Локальный профиль · $substring';
  }

  @override
  String get lock => 'Заблокировать';

  @override
  String get migrateLocalProfiles => 'Перенос локальных профилей';

  @override
  String get migrationCompleted => 'Миграция завершена';

  @override
  String get migrationNeedsRecovery => 'Миграция требует восстановления';

  @override
  String get migrationStoppedLocalSourceKept =>
      'Миграция остановлена · локальный источник сохранён';

  @override
  String get moveLocalEncryptedRecordsToA =>
      'Перенести локальные зашифрованные записи в новый синхронизируемый сейф';

  @override
  String get newSyncVaultName => 'Имя нового синхронизируемого сейфа';

  @override
  String get noLocalOnlyProfileExistsIn =>
      'В этом браузере ещё нет локального профиля. Создайте его в рабочем пространстве локального профиля, добавьте нужные записи и вернитесь сюда.';

  @override
  String get preflightAndMigrate => 'Проверить и перенести';

  @override
  String get startANewMigration => 'Начать новую миграцию';

  @override
  String get stopAndKeepBoth => 'Остановить и сохранить оба';

  @override
  String get stopAndKeepLocalData => 'Остановить и сохранить локальные данные';

  @override
  String get stopMigrationAndKeepLocalData =>
      'Остановить миграцию и сохранить локальные данные?';

  @override
  String get theClientDecryptsAndValidatesEvery =>
      'Клиент расшифровывает и проверяет каждую исходную запись, затем шифрует её заново для одобренного серверного устройства. Сервер получает только подписанный шифротекст. Существующие локальные записи не меняются, а запись в локальный профиль заморожена, пока назначение не подтвердит все записи.';

  @override
  String get theLocalSourceWillBecomeWritable =>
      'Локальный источник снова станет доступен для записи, его записи не изменятся. Сейф назначения, зафиксированные записи и операции в очереди не удаляются и не отзываются; в назначении может остаться частичная копия.';

  @override
  String get unlockALocalOnlyProfile => 'Разблокировать локальный профиль';

  @override
  String get unlockAndValidate => 'Разблокировать и проверить';

  @override
  String stagedcountTotalcountEncryptedRecordsStaged(
    int stagedCount,
    int totalCount,
  ) {
    return 'Подготовлено зашифрованных записей: $stagedCount из $totalCount';
  }

  @override
  String stageditemcountItemcountEncryptedRecordsStagedTarget(
    int stagedItemCount,
    int itemCount,
    String substring,
  ) {
    return 'Подготовлено зашифрованных записей: $stagedItemCount из $itemCount · цель $substring…';
  }

  @override
  String get theSyncServiceIdentityIsntVerified =>
      'Идентичность службы синхронизации ещё не проверена. Войдите снова и повторите попытку.';

  @override
  String countCount2EncryptedRecordsSafelyStaged(int count, int count2) {
    return 'Безопасно подготовлено зашифрованных записей: $count из $count2.';
  }

  @override
  String get destinationDataIsAlreadyStagedThis =>
      'Данные назначения уже подготовлены; эту миграцию нельзя отменить.';

  @override
  String get couldntStopTheMigrationTheSource =>
      'Не удалось остановить миграцию. Исходные данные и подготовленный шифротекст сохранены; повторите попытку или продолжите миграцию.';

  @override
  String get thisMigrationCantBeResumedSafely =>
      'Эту миграцию нельзя безопасно возобновить. Исходные данные и подготовленный шифротекст не изменены; проверьте состояние устройства и сервера.';

  @override
  String get couldntUnlockOrVerifyThisLocal =>
      'Не удалось разблокировать или проверить локальный профиль. Проверьте пароль и локальное хранилище и повторите попытку.';

  @override
  String get couldntReadTheLocalProfileList =>
      'Не удалось прочитать список локальных профилей. Закройте страницу и повторите попытку.';

  @override
  String get theStagedDestinationCiphertextHasAn =>
      'Недопустимый формат подготовленного шифротекста назначения.';

  @override
  String get noVaultCreationRequestWasSent =>
      'Запрос на создание сейфа не отправлялся; журнал подготовки безопасно отменён.';

  @override
  String get localDataWasFullyPreflightedAnd =>
      'Локальные данные полностью проверены и заморожены; подготовка нового синхронизируемого сейфа…';

  @override
  String get localSourceSnapshotVerifiedResumingThe =>
      'Снимок локального источника проверен; возобновление того же назначения синхронизации…';

  @override
  String get theLocalProfileIsLocked => 'Локальный профиль заблокирован.';

  @override
  String get encryptingAndStagingRecordsWithThe =>
      'Шифрование и подготовка записей ключом сейфа назначения…';

  @override
  String get syncingEncryptedRecordsToTheNew =>
      'Синхронизация зашифрованных записей в новый сейф…';

  @override
  String get confirmingTheSameDestinationVaultAnd =>
      'Подтверждение того же сейфа назначения и проверка ранее подготовленных записей…';

  @override
  String get reVerifyingTheLocalSourceSnapshot =>
      'Повторная проверка снимка локального источника и подготовленных зашифрованных данных…';

  @override
  String get preflightingAllLocalRecordsWritesTo =>
      'Предварительная проверка всех локальных записей; запись в исходный профиль временно запрещена…';

  @override
  String get verifyingTheLocalProfileAndChecking =>
      'Проверка локального профиля и журнала восстановления…';

  @override
  String get thisMigrationCantBeCancelledSafely =>
      'Эту миграцию нельзя безопасно отменить. Продолжите восстановление исходного назначения; исходные данные остаются замороженными.';

  @override
  String get theDestinationVaultsSyncPreferencesConflict =>
      'Настройки синхронизации сейфа назначения конфликтуют; миграция ещё не полностью проверена.';

  @override
  String get recordsAreSavedEncryptedInThe =>
      'Записи сохранены в зашифрованном виде в очереди синхронизации, но не все подтверждения сервера получены. Исходный профиль остаётся заморожен; нажмите «Продолжить миграцию», чтобы безопасно повторить.';

  @override
  String get migrationPreparationHasntSavedTheVault =>
      'Подготовка миграции ещё не сохранила данные для создания сейфа.';

  @override
  String get migrationCiphertextStagingIsIncomplete =>
      'Подготовка шифротекста миграции не завершена.';

  @override
  String get migrationStoppedTheLocalSourceData =>
      'Миграция остановлена. Локальные исходные данные целы и снова доступны для записи; данные, зафиксированные или ожидающие синхронизации в сейфе назначения, сохраняются.';

  @override
  String get migrationCompleteTheServerConfirmedEvery =>
      'Миграция завершена. Сервер подтвердил все записи; локальный профиль по-прежнему хранит исходные данные.';

  @override
  String get theMigrationJournalDoesntMatchThe =>
      'Журнал миграции не соответствует проверенному снимку локального источника.';

  @override
  String get theMigrationJournalContainsDuplicateOr =>
      'Журнал миграции содержит повторяющиеся или лишние записи.';

  @override
  String get migrationIncompleteTheSourceDataIs =>
      'Миграция не завершена. Исходные данные не изменены; если журнал восстановления создан, продолжите то же назначение ниже.';

  @override
  String get theMigrationDestinationBelongsToA =>
      'Назначение миграции принадлежит другому экземпляру сервера.';

  @override
  String get accountPassword => 'Пароль учётной записи';

  @override
  String get accountSessionExpiredSignInAgain =>
      'Сеанс учётной записи истёк; войдите снова';

  @override
  String get encryptedChangesAreUpToDate => 'Зашифрованные изменения актуальны';

  @override
  String get encryptedSyncWillRetryWhenThe =>
      'Зашифрованная синхронизация повторится, когда соединение восстановится';

  @override
  String get noVaultIsCurrentlyAvailable => 'Сейчас нет доступных сейфов';

  @override
  String get receiveEncryptedChangesNow =>
      'Получить зашифрованные изменения сейчас';

  @override
  String get receivingSignedEncryptedChanges =>
      'Получение подписанных зашифрованных изменений';

  @override
  String get signOut => 'Выйти';

  @override
  String get thisDeviceOrVaultAccessWas =>
      'Доступ этого устройства или к сейфу отозван';

  @override
  String get unlockToVerifyTheLatestVault =>
      'Разблокируйте, чтобы проверить актуальное состояние сейфа';

  @override
  String get unlockWorkspace => 'Разблокировать рабочее пространство';

  @override
  String get workspaceLocked => 'Рабочее пространство заблокировано';

  @override
  String get yourAccountStaysSignedInWhile =>
      'Вы остаётесь в учётной записи. Пока пространство заблокировано, устройство может получать и сохранять подписанный шифротекст, но не может расшифровывать записи, а также создавать или отправлять изменения.';

  @override
  String get sshConsoleSupportReadingTextAnd =>
      'SSH и консоль поддерживают чтение текста и ввод; SSH также поддерживает отдельное выполнение команд и чтение/запись текстовых файлов по SFTP. RDP и VNC поддерживают подключение и управление вкладками; распознавание экрана и управление мышью пока недоступны.';

  @override
  String get onlyTheLast50ToolNames =>
      'В памяти хранятся только названия и результаты последних 50 вызовов инструментов; команды, содержимое файлов и токены не записываются.';

  @override
  String get listensOn127001 =>
      'Прослушивается только 127.0.0.1. При каждом включении создаётся новый токен; авторизация прекращается после блокировки, выхода или смены сейфа. Разные окна могут использовать разные порты. Остановка MCP не закрывает открытые сеансы.';

  @override
  String get stopAndRevokeToken => 'Остановить и отозвать токен';

  @override
  String get allowExternalAiToPerformActions =>
      'Разрешить внешнему ИИ выполнять действия';

  @override
  String get actionsAllowed => 'Действия разрешены';

  @override
  String get allowsConnectingClosingSessionsTerminalInput =>
      'Разрешает подключать и закрывать сеансы, вводить в терминал, выполнять команды и записывать файлы. После изменения включите MCP заново.';

  @override
  String get readOnly => 'Только чтение';

  @override
  String get readOnlyModeCanStillRead =>
      'Даже в режиме только чтения доступны вывод терминала и содержимое файлов, которые могут содержать конфиденциальные данные. Передавайте конфигурацию подключения только доверенному ИИ. Сохранённые пароли, закрытые ключи и ключи разблокировки никогда не передаются в полях MCP.';

  @override
  String get availableTools => 'Доступные инструменты';

  @override
  String get enableMcp => 'Включить MCP';

  @override
  String get copyConnectionConfigIncludesToken =>
      'Копировать конфигурацию подключения (с токеном)';

  @override
  String get externalAiAccess => 'Доступ внешнего ИИ';

  @override
  String get failed => 'Ошибка';

  @override
  String get done => 'Готово';

  @override
  String get off => 'Выключено';

  @override
  String get copiedIncludesAccessToken => 'Скопировано (включая токен доступа)';

  @override
  String get couldntStartMcpMakeSureThe =>
      'Не удалось запустить MCP. Убедитесь, что рабочее пространство разблокировано, а порт не занят другим окном.';

  @override
  String get couldntCopyTheConfigurationCheckClipboard =>
      'Не удалось скопировать конфигурацию. Проверьте разрешения буфера обмена.';

  @override
  String get noCallsYet => 'Вызовов пока нет';

  @override
  String get recentCalls => 'Последние вызовы';

  @override
  String get localListeningPort => 'Локальный порт прослушивания';

  @override
  String get starting => 'Запуск…';

  @override
  String get theBrowserAndMobileAppsDont =>
      'В браузере и мобильных приложениях локальный MCP-слушатель недоступен. Включите его, открыв рабочее пространство в настольном клиенте для Windows, Linux или macOS.';

  @override
  String get portMustBe102465535 => 'Порт должен быть в диапазоне 1024–65535.';

  @override
  String runningValuevalue(String valueValue) {
    return 'Работает · $valueValue';
  }

  @override
  String get letExternalAiUseTheHosts =>
      'Позвольте внешнему ИИ использовать хосты, сеансы, терминалы и удалённые файлы текущего рабочего пространства через MCP. Настраивать API модели в Atermius не нужно.';

  @override
  String get rdpRemoteDesktop => 'Удалённый рабочий стол RDP';

  @override
  String get sshHost => 'SSH-хост';

  @override
  String get vncRemoteDesktop => 'Удалённый рабочий стол VNC';

  @override
  String get newSession => 'Новый сеанс';

  @override
  String get unableToOpenANewWindow => 'Не удалось открыть новое окно.';

  @override
  String get couldntOpenANewWindow => 'Не удалось открыть новое окно.';

  @override
  String get newWindowsRequireADesktop =>
      'Для новых окон нужен настольный клиент.';

  @override
  String get fileWindowsRequireADesktop =>
      'Для окон файлов нужен настольный клиент.';

  @override
  String get independentFileWindowsRequireADesktop =>
      'Для отдельных окон файлов нужен настольный клиент.';

  @override
  String get chooseSshConfigFile => 'Выбрать файл конфигурации SSH';

  @override
  String get confirmImport => 'Подтвердить импорт';

  @override
  String createCountEncryptedHostRecordS(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Будут созданы $count зашифрованной записи хостов.',
      many: 'Будут созданы $count зашифрованных записей хостов.',
      few: 'Будут созданы $count зашифрованные записи хостов.',
      one: 'Будет создана $count зашифрованная запись хоста.',
    );
    return '$_temp0 Существующие хосты не изменятся, SSH-подключения не открываются.';
  }

  @override
  String get importHosts => 'Импортировать хосты';

  @override
  String get importOpensshConfig => 'Импорт конфигурации OpenSSH';

  @override
  String get importTheseHosts => 'Импортировать эти хосты?';

  @override
  String importCountHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Импортировать $count хоста',
      many: 'Импортировать $count хостов',
      few: 'Импортировать $count хоста',
      one: 'Импортировать $count хост',
    );
    return '$_temp0';
  }

  @override
  String lineLineMessage(int line, String message) {
    return 'Строка $line · $message';
  }

  @override
  String get noConcreteHostAliasesWereFound =>
      'Конкретные псевдонимы Host не найдены.';

  @override
  String get proxyjumpReferencesCouldNotBeSaved =>
      'Не удалось сохранить ссылки ProxyJump в безопасном порядке.';

  @override
  String get reviewBlockedNoRecordsCanBe =>
      'Проверка заблокирована: в этом файле нет записей для импорта.';

  @override
  String get reviewLiteralHostAliasesHostnameUser =>
      'Перед сохранением проверьте буквальные псевдонимы Host, HostName, User, Port и один псевдоним ProxyJump. Include, Match, шаблоны с подстановкой, ProxyCommand и LocalCommand блокируются. Пути IdentityFile никогда не открываются.';

  @override
  String get theActiveVaultChangedDuringImport =>
      'Во время импорта активный сейф изменился; остальные хосты не сохранены.';

  @override
  String get theActiveVaultIsReadOnly =>
      'Активный сейф доступен только для чтения; хосты не импортированы.';

  @override
  String get theConfigFileCouldNotBe =>
      'Не удалось прочитать файл конфигурации.';

  @override
  String get theSelectedConfigCouldNotBe =>
      'Не удалось прочитать выбранную конфигурацию.';

  @override
  String get theSelectedConfigExceedsThe1 =>
      'Выбранная конфигурация превышает лимит 1 МиБ.';

  @override
  String get thisProxyjumpChainContainsACycle =>
      'Цепочка ProxyJump содержит цикл; хосты затронутого маршрута не будут импортированы.';

  @override
  String thisProxyjumpChainExceedsTheMaxjumphosthops(int maxJumpHostHops) {
    return 'Цепочка ProxyJump превышает лимит в $maxJumpHostHops переходов.';
  }

  @override
  String get thisProxyjumpChainPointsToA =>
      'Цепочка ProxyJump указывает на отсутствующий сохранённый хост.';

  @override
  String valuevalueAdditionalFindingsAreHidden(int valueValue) {
    String _temp0 = intl.Intl.pluralLogic(
      valueValue,
      locale: localeName,
      other: 'Ещё $valueValue замечания скрыты.',
      many: 'Ещё $valueValue замечаний скрыто.',
      few: 'Ещё $valueValue замечания скрыты.',
      one: 'Ещё $valueValue замечание скрыто.',
    );
    return '$_temp0';
  }

  @override
  String filenameActions(String filename) {
    return 'Действия: $filename';
  }

  @override
  String get uploadFile => 'Отправить файл';

  @override
  String get parentFolder => 'Родительская папка';

  @override
  String get download => 'Скачать';

  @override
  String get modified => 'Изменён';

  @override
  String get create => 'Создать';

  @override
  String deleteFilenameFoldersMustBeEmpty(String filename) {
    return 'Удалить «$filename»? Папка должна быть пустой. Это действие нельзя отменить.';
  }

  @override
  String get size => 'Размер';

  @override
  String get fileActions => 'Действия с файлами';

  @override
  String get newFolder => 'Новая папка';

  @override
  String get thisFolderIsEmpty => 'Эта папка пуста';

  @override
  String get confirmDeletion => 'Подтвердите удаление';

  @override
  String get editText => 'Редактировать текст';

  @override
  String get remotePath => 'Удалённый путь';

  @override
  String get closePane => 'Закрыть панель';

  @override
  String get unsplit => 'Отменить разделение';

  @override
  String get invalidLayoutSession => 'Недопустимый сеанс макета.';

  @override
  String get layoutIsNestedTooDeeply => 'Слишком глубокая вложенность макета.';

  @override
  String get dropToSplit => 'Перетащите, чтобы разделить';

  @override
  String paneActionsLabel(String label) {
    return 'Действия с панелью · $label';
  }

  @override
  String get paneActionsTapTheWhiteHandle =>
      'Действия с панелью: коснитесь белого маркера вверху или нажмите Alt+Shift+P';

  @override
  String get paneActionsHoverNearTheTop =>
      'Действия с панелью: наведите на верхний край, коснитесь его или нажмите Alt+Shift+P';

  @override
  String get settingsCategories => 'Категории настроек';

  @override
  String get backToConflict => 'Вернуться к конфликту';

  @override
  String get compare => 'Сравнить';

  @override
  String get compareRemoteFileVersions => 'Сравнение версий удалённого файла';

  @override
  String get editRemoteTextFile => 'Редактирование удалённого текстового файла';

  @override
  String get fileName => 'Имя файла';

  @override
  String get latestRemote => 'Последняя удалённая версия';

  @override
  String get overwriteRemoteFile => 'Перезаписать удалённый файл';

  @override
  String get remoteFileChanged => 'Удалённый файл изменён';

  @override
  String get remoteFileContents => 'Содержимое удалённого файла';

  @override
  String get saveAs => 'Сохранить как';

  @override
  String get saveRemoteFileAs => 'Сохранить удалённый файл как';

  @override
  String get theRemoteFileChangedAfterYou =>
      'Удалённый файл изменился после открытия. Ваш черновик не сохранён. Сравните версии, сохраните новую копию или явно перезапишите последнюю версию.';

  @override
  String get utf8TextUpTo10 =>
      'Текст UTF-8 до 10 МиБ. Черновик хранится только в памяти и не синхронизируется. SFTP не гарантирует сравнение с заменой и открытие без перехода по ссылкам при одновременном изменении удалённого пути; не редактируйте файлы в общих каталогах с правом записи.';

  @override
  String get yourDraft => 'Ваш черновик';

  @override
  String get advanced => 'Дополнительно';

  @override
  String get allowNetworkExposure => 'Разрешить доступ из сети';

  @override
  String get anotherProfileOfThisHostAlready =>
      'Другой профиль этого хоста уже использует этот адрес и порт прослушивания.';

  @override
  String get connectThisHostOverSshTo =>
      'Подключитесь к хосту по SSH, чтобы запускать переадресацию.';

  @override
  String get couldNotRemoveThisForwardingProfile2 =>
      'Не удалось удалить профиль переадресации.';

  @override
  String get destinationReachedFromTheSshServer =>
      'Назначение, доступное с SSH-сервера';

  @override
  String get destinationReachedFromThisDevice =>
      'Назначение, доступное с этого устройства';

  @override
  String get dynamicSocksD => 'Динамический SOCKS (-D)';

  @override
  String dynamicSocksDBind(String bind) {
    return 'Динамический SOCKS (-D) · $bind';
  }

  @override
  String get dynamicForwardingIsASocks44a =>
      'Динамическая переадресация — это прокси SOCKS4/4a/5 CONNECT без аутентификации SOCKS. Любой, кто может достучаться до слушателя, может использовать ваше SSH-соединение.';

  @override
  String get expose => 'Открыть доступ';

  @override
  String get exposeThisForwardBeyondLoopback =>
      'Открыть эту переадресацию за пределами loopback?';

  @override
  String lastConnectionLastconnectionerror(Object lastConnectionError) {
    return 'Последнее подключение: $lastConnectionError';
  }

  @override
  String get localL => 'Локальная (-L)';

  @override
  String localLBindDestinationViaSsh(String bind, String destination) {
    return 'Локальная (-L) · $bind → $destination через SSH';
  }

  @override
  String get loopbackOrAnIpAddress => 'Loopback или IP-адрес';

  @override
  String get permitANonLoopbackListenerFor =>
      'Разрешает слушатель вне loopback (например, 0.0.0.0) или, для удалённой переадресации, назначение на стороне устройства в вашей сети. Подтверждение потребуется перед сохранением и перед каждым запуском.';

  @override
  String get reachableBeyondLoopback => 'Доступно за пределами loopback';

  @override
  String get remoteR => 'Удалённая (-R)';

  @override
  String remoteRSshServerBindThis(String bind, String destination) {
    return 'Удалённая (-R) · SSH-сервер $bind → это устройство $destination';
  }

  @override
  String get socks44a5ConnectWithoutSocks =>
      'SOCKS4/4a/5 CONNECT без аутентификации SOCKS. Адреса назначения разрешает SSH-сервер.';

  @override
  String sshPortForwardingHostname(String hostName) {
    return 'Переадресация портов SSH · $hostName';
  }

  @override
  String get sshServerListenerAddress => 'Адрес прослушивания на SSH-сервере';

  @override
  String get theSshServerGatewayportsSettingMay2 =>
      'Параметр GatewayPorts на SSH-сервере может расширить запрос привязки к loopback. Проверьте настройки сервера перед использованием удалённой переадресации.';

  @override
  String get thisHostIsNoLongerAvailable => 'Хост больше недоступен.';

  @override
  String get thisHostIsNotSavedIn =>
      'Хост не сохранён в текущем профиле или сейфе (или удалён). Сохраните хост, чтобы сохранить профили переадресации; работающую переадресацию ниже всё ещё можно остановить.';

  @override
  String sshportforwardprofiledescriptionNoLongerSavedForThis(
    String sshPortForwardProfileDescription,
  ) {
    return '$sshPortForwardProfileDescription\nБольше не сохранено для этого хоста, но всё ещё работает в этом подключении.';
  }

  @override
  String whatOnlyContinueOnANetwork(String what) {
    return '$what Продолжайте только в доверенной сети.';
  }

  @override
  String get downArrow => 'Стрелка вниз';

  @override
  String get leftArrow => 'Стрелка влево';

  @override
  String get lockAltModifier => 'Зафиксировать модификатор Alt';

  @override
  String get lockControlModifier => 'Зафиксировать модификатор Control';

  @override
  String get moreTerminalKeys => 'Другие клавиши терминала';

  @override
  String get pasteClipboard => 'Вставить из буфера обмена';

  @override
  String get releaseControlAndAlt => 'Отпустить Control и Alt';

  @override
  String get rightArrow => 'Стрелка вправо';

  @override
  String get upArrow => 'Стрелка вверх';

  @override
  String get nextMatch => 'Следующее совпадение';

  @override
  String get previousMatch => 'Предыдущее совпадение';

  @override
  String get searchTerminalScrollback => 'Поиск в истории прокрутки терминала';

  @override
  String get closeSidebar => 'Закрыть боковую панель';

  @override
  String get delete => 'Удалить';

  @override
  String get refreshQuickCommands => 'Обновить быстрые команды';

  @override
  String get saveEncryptedAsSnippets =>
      'Сохранить в зашифрованном виде как сниппеты';

  @override
  String get singleLineCommand => 'Однострочная команда';

  @override
  String get insertIntoTerminal => 'Вставить в терминал';

  @override
  String get quickCommands => 'Быстрые команды';

  @override
  String get quickCommandActions => 'Действия с быстрой командой';

  @override
  String get searchTermsAreRecordedWhenYou =>
      'Запрос сохраняется при нажатии Enter или закрытии поиска';

  @override
  String get search => 'Поиск';

  @override
  String get search2 => 'Поиск…';

  @override
  String get searchHistory => 'История поиска';

  @override
  String get searchCurrentTerminalOutput => 'Поиск в выводе текущего терминала';

  @override
  String get theActionDidntCompleteRefreshAnd =>
      'Действие не завершено. Обновите и повторите попытку.';

  @override
  String get cantInsertSelectASessionThat =>
      'Не удалось вставить: выберите подключённый сеанс; команда должна быть однострочной.';

  @override
  String get couldntReadQuickCommandsRefreshAnd =>
      'Не удалось прочитать быстрые команды. Обновите и повторите попытку.';

  @override
  String get showsCommandsCompletedOnTheCurrent =>
      'Показывает команды, выполненные на текущем хосте. Нажмите, чтобы вставить; ничего не запускается автоматически.';

  @override
  String get noMatchingEntries => 'Нет подходящих записей';

  @override
  String get addQuickCommand => 'Добавить быструю команду';

  @override
  String get clear => 'Очистить';

  @override
  String get clearLocalHistory => 'Очистить локальную историю';

  @override
  String get clickToInsertPressEnterTo =>
      'Нажмите, чтобы вставить, затем Enter для запуска. Показаны однострочные команды Bash без параметров.';

  @override
  String get removeSearchTerm => 'Удалить поисковый запрос';

  @override
  String get filterInputHistory => 'Фильтр истории ввода';

  @override
  String get filterByNameOrCommand => 'Фильтр по имени или команде';

  @override
  String get terminalTools => 'Инструменты терминала';

  @override
  String get edit => 'Изменить';

  @override
  String get editQuickCommand => 'Изменить быструю команду';

  @override
  String get recordingSettings => 'Настройки записи';

  @override
  String get enterANameAndASingle =>
      'Укажите имя и однострочную команду без управляющих символов.';

  @override
  String get inputHistory => 'История ввода';

  @override
  String get cancelTransfer => 'Отменить передачу';

  @override
  String get chooseLocalFile => 'Выбрать локальный файл';

  @override
  String get couldNotOpenAStreamingFile =>
      'Не удалось открыть потоковый источник файла.';

  @override
  String get downloadFile => 'Скачать файл';

  @override
  String get downloadingWithSftpCompatibilityModeUp =>
      'Скачивание в режиме совместимости SFTP (до 16 МиБ)…';

  @override
  String get fileExceeds1GibTransferLimit =>
      'Файл превышает лимит передачи 1 ГиБ.';

  @override
  String get mobileDownloadsUpTo16Mib =>
      'На мобильных устройствах можно скачать до 16 МиБ. Окно сохранения откроется после проверки всего файла.';

  @override
  String get preparingTransfer => 'Подготовка передачи…';

  @override
  String get remoteFilePath => 'Путь к удалённому файлу';

  @override
  String get sftpCompatibilityDownloadsUpTo16 =>
      'В режиме совместимости SFTP можно скачать до 16 МиБ. На этой платформе для SCP нужно потоковое место сохранения.';

  @override
  String get singleFilesUpTo1Gib =>
      'Отдельные файлы до 1 ГиБ. Существующие файлы назначения никогда не заменяются. Файлы SFTP видны во время отправки.';

  @override
  String get streamingFileSavesAreUnavailableOn =>
      'Потоковое сохранение файлов недоступно на этой платформе.';

  @override
  String get streamingTransferIsUnavailableOnThis =>
      'Потоковая передача недоступна на этой платформе.';

  @override
  String get theSelectedProviderReturnedAnUnsafe =>
      'Выбранный провайдер вернул небезопасное имя файла.';

  @override
  String get thisFilePickerDoesNotProvide =>
      'Этот выбор файлов не предоставляет потоковый источник.';

  @override
  String get transferCancelled => 'Передача отменена.';

  @override
  String get transferFailedCheckThePathPermissions =>
      'Передача не выполнена. Проверьте путь, права и наличие места назначения.';

  @override
  String get uploadFile2 => 'Отправить файл';

  @override
  String get closeWindow => 'Закрыть окно';

  @override
  String get maximize => 'Развернуть';

  @override
  String get minimize => 'Свернуть';

  @override
  String get closeWindow2 => 'Закрыть окно';

  @override
  String get maximize2 => 'Развернуть';

  @override
  String get minimize2 => 'Свернуть';

  @override
  String get restore2 => 'Восстановить';

  @override
  String get save2 => 'Сохранить';

  @override
  String get saveWindowSet => 'Сохранить набор окон';

  @override
  String get thisWindowHasSessionsThatCant =>
      'В этом окне есть сеансы, которые нельзя сохранить. Закройте их и повторите попытку.';

  @override
  String get thisWindowHasNoSessionsTo =>
      'В этом окне нет сеансов для сохранения.';

  @override
  String get openWindowSet => 'Открыть набор окон';

  @override
  String get couldntDeleteTheWindowSetUnlock =>
      'Не удалось удалить набор окон. Разблокируйте снова или выполните синхронизацию и повторите попытку.';

  @override
  String get couldntReadWindowSetsUnlockAgain =>
      'Не удалось прочитать наборы окон. Разблокируйте снова или выполните синхронизацию и повторите попытку.';

  @override
  String get thereAreNoReadySessionsTo => 'Нет готовых сеансов для сохранения.';

  @override
  String get windowSets => 'Наборы окон';

  @override
  String get setName => 'Название набора';

  @override
  String get sshKey => 'SSH-ключ';

  @override
  String get close2 => 'Закрыть';

  @override
  String get password2 => 'Пароль';

  @override
  String get theActionDidntCompleteTryAgain =>
      'Действие не завершено. Повторите попытку.';

  @override
  String get more => 'Ещё';

  @override
  String get directConnection2 => 'Прямое подключение';

  @override
  String get connectionProperties => 'Свойства подключения';

  @override
  String get viaJumpHost => 'Через промежуточный хост';

  @override
  String get theAppOpensInTheCurrent =>
      'При следующем запуске откроется текущий режим. Переключение режима закрывает текущие подключения; сохранённые данные остаются.';

  @override
  String get cloudSyncMode => 'Режим облачной синхронизации';

  @override
  String get switchToCloudMode => 'Переключиться на облачный режим';

  @override
  String get switchToLocalMode => 'Переключиться на локальный режим';

  @override
  String get workspaceMode => 'Режим рабочего пространства';

  @override
  String get couldntSwitchTheWorkspaceModeCheck =>
      'Не удалось переключить режим рабочего пространства. Проверьте локальное хранилище и повторите попытку.';

  @override
  String get localMode => 'Локальный режим';

  @override
  String closeTitle(String title) {
    return 'Закрыть $title';
  }

  @override
  String get newWindowCtrlShiftN => 'Новое окно (Ctrl+Shift+N)';

  @override
  String countCount2Connected(int count, int count2) {
    return 'Подключено: $count/$count2';
  }

  @override
  String get splitTopBottom => 'Разделить сверху и снизу';

  @override
  String get hostMenuClickToOpen => 'Меню хостов · нажмите, чтобы открыть';

  @override
  String get closeOtherTabs => 'Закрыть другие вкладки';

  @override
  String get closeTab => 'Закрыть вкладку';

  @override
  String get closeThisSplitGroup => 'Закрыть эту группу панелей';

  @override
  String get unsplitCurrentPane => 'Отменить разделение текущей панели';

  @override
  String get duplicateTab => 'Дублировать вкладку';

  @override
  String get splitLeftRight => 'Разделить слева и справа';

  @override
  String get connected => 'Подключено';

  @override
  String get searchHostsOrQuickConnect =>
      'Поиск хостов или быстрое подключение';

  @override
  String get notConnected => 'Не подключено';

  @override
  String get moveToNewWindow => 'Переместить в новое окно…';

  @override
  String get terminalSidebar => 'Боковая панель терминала';

  @override
  String get desktopRdpEngineFeatureUnavailable =>
      'Недоступно в этой сборке RDP';

  @override
  String get desktopChooseAbsoluteLocalFolder =>
      'Выберите локальную папку с абсолютным путём';

  @override
  String get desktopRdpMultimonResolutionHelp =>
      'Игнорируется при включении «Использовать все локальные мониторы»: каждый монитор сохраняет свой размер.';

  @override
  String get desktopRdpAutomaticResolutionHelp =>
      'Автоматический режим следует размеру окна через управление дисплеем RDP; фиксированный размер запрашивается при подключении.';

  @override
  String get desktopUseAllLocalMonitors =>
      'Использовать все локальные мониторы';

  @override
  String get desktopClipboardText => 'Текст буфера обмена';

  @override
  String get desktopClipboardFiles => 'Файлы буфера обмена';

  @override
  String get desktopMicrophone => 'Микрофон';

  @override
  String get desktopSmartCards => 'Смарт-карты';

  @override
  String get desktopCameras => 'Камеры';

  @override
  String get desktopVncResizeHelp =>
      'Для изменения размера нужен сервер с ExtendedDesktopSize (например, TigerVNC или x11vnc с -xrandr). Другие серверы сохраняют размер, а масштабирование выполняется локально.';

  @override
  String get desktopAutomaticFitWindow => 'Автоматически (по размеру окна)';

  @override
  String desktopResolutionSideBounds(int minSide, int maxSide) {
    return 'Каждая сторона разрешения должна быть от $minSide до $maxSide пикселей';
  }

  @override
  String desktopResolutionPixelLimit(int megapixels) {
    return 'Разрешение превышает $megapixels мегапикселей';
  }

  @override
  String get inventoryTooLarge =>
      'Инвентарь превышает ограничение импорта в 1 МиБ.';

  @override
  String get inventoryTooManyLines =>
      'В инвентаре слишком много строк для безопасной проверки.';

  @override
  String get inventoryLineTooLong =>
      'Строка инвентаря слишком длинная для безопасной проверки.';

  @override
  String get inventoryControlCharacter =>
      'Управляющие символы в файлах инвентаря запрещены.';

  @override
  String get inventoryUnsupportedFormat =>
      'Этот формат инвентаря не поддерживается.';

  @override
  String get inventoryParseError =>
      'Не удалось безопасно разобрать синтаксис инвентаря.';

  @override
  String get inventoryUnsupportedConstruct =>
      'Инвентарь содержит неподдерживаемую конструкцию.';

  @override
  String get inventoryDynamicUnsupported =>
      'Динамический инвентарь и настройки плагинов не поддерживаются.';

  @override
  String get inventoryInvalidGroup =>
      'Объявление группы некорректно или не поддерживается.';

  @override
  String get inventoryInvalidHost =>
      'Объявление хоста некорректно или не поддерживается.';

  @override
  String get inventoryInvalidVariable =>
      'Разрешённое поле подключения содержит недопустимое значение.';

  @override
  String get inventoryUnsupportedConnection =>
      'Можно импортировать только статические SSH-хосты инвентаря.';

  @override
  String get inventoryIgnoredVariable =>
      'Неподдерживаемая переменная инвентаря проигнорирована и не будет импортирована.';

  @override
  String get inventoryConflictingVariable =>
      'Конфликтующие значения инвентаря делают этот хост неоднозначным.';

  @override
  String get inventoryDuplicateVariable =>
      'Поле подключения повторяется, делая этот хост неоднозначным.';

  @override
  String get inventoryGroupCycle => 'Наследование групп содержит цикл.';

  @override
  String get inventoryLimitExceeded =>
      'Инвентарь превышает ограничение безопасного разбора.';

  @override
  String get inventoryEmpty => 'В этом инвентаре не найдены статические хосты.';

  @override
  String get inventoryBlockedSource =>
      'Заблокированный инвентарь не может изменить состояние сохранённого источника.';

  @override
  String get inventoryEmptySource =>
      'Пустой инвентарь не может пометить сохранённые хосты как отсутствующие.';

  @override
  String get inventoryPartialSource =>
      'Неполный или неоднозначный инвентарь не может пометить сохранённые хосты как отсутствующие.';

  @override
  String get inventoryBlockedPlan =>
      'В инвентаре есть блокирующая проблема; изменения не запланированы.';

  @override
  String get inventoryBlockedEntry =>
      'В этой записи есть блокирующая проблема; она не будет изменена.';

  @override
  String get inventoryDuplicateIdentity =>
      'Этот источник содержит неоднозначный повторяющийся идентификатор хоста.';

  @override
  String get inventoryUsernameRequired =>
      'Для сохранения хоста требуется имя пользователя.';

  @override
  String get inventoryMultipleSaved =>
      'Этот идентификатор источника принадлежит нескольким сохранённым хостам.';

  @override
  String get inventoryKeepOtherSource =>
      'Уже сохранён. Существующий хост останется без изменений: он принадлежит другому источнику или не имеет идентификатора источника.';

  @override
  String get inventoryRevisionUnavailable =>
      'Версия сохранённого хоста недоступна. Обновите страницу хостов и повторите проверку.';

  @override
  String get inventoryTagLimit =>
      'После объединения хост превысит ограничение в 128 тегов. Удалите теги или группы и проверьте инвентарь снова.';

  @override
  String get inventoryRestoreActive =>
      'Этот хост будет восстановлен как активный в своём источнике.';

  @override
  String get inventoryMissingRevision =>
      'Версия сохранённого хоста недоступна; отсутствующая запись не помечена как устаревшая.';

  @override
  String get inventoryAbsentHost =>
      'Этот сохранённый хост отсутствует в полном инвентаре.';

  @override
  String get sshImportLineTooLong => 'Эта строка слишком длинная для проверки.';

  @override
  String get sshImportControlCharacter =>
      'Управляющие символы в файле конфигурации SSH запрещены.';

  @override
  String get sshImportUnterminatedQuote =>
      'Незакрытая кавычка или экранирование; исправьте строку перед импортом.';

  @override
  String get sshImportAliasRequired =>
      'В строке Host требуется конкретный псевдоним.';

  @override
  String get sshImportUnsupportedPattern =>
      'Шаблоны Host с подстановками, отрицанием или ошибками не поддерживаются; используйте конкретные псевдонимы.';

  @override
  String get sshImportHostLimit =>
      'Файл конфигурации превышает ограничение импорта в 256 хостов.';

  @override
  String get sshImportInclude =>
      'Файлы Include не открываются. Объедините конфигурацию в один файл и проверьте её перед импортом.';

  @override
  String get sshImportMatch =>
      'Блоки Match не обрабатываются. Перед импортом преобразуйте файл в конкретные блоки Host.';

  @override
  String get sshImportGlobalCommand =>
      'Командные директивы никогда не выполняются; удалите эту глобальную директиву перед импортом.';

  @override
  String get sshImportGlobalIdentity =>
      'Для IdentityFile требуется одно значение; при импорте файлы не открываются.';

  @override
  String get sshImportUnknownDirective =>
      'Эта директива не импортируется. Проверьте или удалите её перед подключением.';

  @override
  String get sshImportGlobalValueCount =>
      'У этой глобальной директивы должно быть ровно одно значение.';

  @override
  String get sshImportGlobalInvalidValue =>
      'Это глобальное значение некорректно или не поддерживается.';

  @override
  String get importStatusCreate => 'создать';

  @override
  String get importStatusUpdate => 'обновить';

  @override
  String get importStatusUnchanged => 'без изменений';

  @override
  String get importStatusMissing => 'отсутствует';

  @override
  String get importStatusSkipped => 'пропущено';

  @override
  String get importStatusBlocked => 'заблокировано';

  @override
  String get sshImportBlockedFile =>
      'Импорт заблокирован: файл содержит неподдерживаемую структуру.';

  @override
  String get sshImportAmbiguousName =>
      'Это имя принадлежит нескольким сохранённым хостам; ничего не будет перезаписано.';

  @override
  String get sshImportBlockedHost =>
      'У этого хоста есть блокирующая проблема; он не будет импортирован.';

  @override
  String get sshImportNotImportable => 'Этот хост нельзя импортировать.';

  @override
  String get importUsernameMissing => 'имя пользователя отсутствует';

  @override
  String importPlannedEndpoint(String endpoint) {
    return 'План: $endpoint';
  }

  @override
  String importSavedEndpoint(String endpoint) {
    return 'Сохранено: $endpoint';
  }

  @override
  String importHostTags(String tags) {
    return 'Теги хоста для сохранения: $tags';
  }

  @override
  String importSshEndpointLine(
    int line,
    String username,
    String address,
    int port,
  ) {
    return 'Строка $line · $username@$address:$port';
  }

  @override
  String importProxyJumpLine(String alias, int line) {
    return 'ProxyJump $alias · строка $line';
  }

  @override
  String sshImportSavedName(String name) {
    return 'Уже сохранён как «$name»; он не будет перезаписан.';
  }

  @override
  String sshImportJumpAmbiguous(int line) {
    return 'ProxyJump в строке $line неоднозначен: это имя принадлежит нескольким сохранённым хостам.';
  }

  @override
  String sshImportJumpMissing(int line) {
    return 'ProxyJump в строке $line не указывает на один импортированный или сохранённый хост.';
  }

  @override
  String sshImportJumpSelf(int line) {
    return 'ProxyJump в строке $line указывает на сам хост.';
  }

  @override
  String sshImportPreviewCounts(int count) {
    return 'Предпросмотр: будет создано хостов: $count; конфликтующие и заблокированные записи будут пропущены.';
  }

  @override
  String inventoryPreviewCounts(
    int created,
    int updated,
    int unchanged,
    int missing,
  ) {
    return 'Предпросмотр: создать хостов: $created; обновить: $updated, без изменений: $unchanged, отсутствует: $missing.';
  }

  @override
  String get keybarPaste => 'Вставить';

  @override
  String get keybarReset => 'Сброс';

  @override
  String get terminalSearchQueryTooLong => 'Слишком длинный запрос';

  @override
  String get terminalSearchSearching => 'Поиск…';

  @override
  String terminalSearchMatchCount(int total, int position) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$position из $total совпадений',
      one: '$position из $total совпадения',
      zero: 'Нет совпадений',
    );
    return '$_temp0';
  }

  @override
  String terminalSearchLimitedCount(String countLabel) {
    return '$countLabel · результаты ограничены';
  }

  @override
  String get r7UiPaletteGalleryTitle => 'Цветовые схемы';

  @override
  String get r7UiPaletteGalleryDescription =>
      'Применяется ко всем терминалам на этом устройстве, включая локальные, облачные и отдельные окна терминала. Хранится только на этом устройстве; сохранённая тема терминала не меняется.';

  @override
  String r7UiPaletteFollowSynced(String name) {
    return 'Сохранённая тема ($name)';
  }

  @override
  String get r7UiPaletteSearchHint => 'Поиск цветовых схем';

  @override
  String get r7UiPaletteFilterAll => 'Все';

  @override
  String get r7UiPaletteFilterDark => 'Тёмные';

  @override
  String get r7UiPaletteFilterLight => 'Светлые';

  @override
  String get r7UiPaletteNoMatches => 'Нет подходящих цветовых схем.';

  @override
  String r7UiPaletteActiveOverride(String name) {
    return 'Терминалы на этом устройстве используют $name.';
  }

  @override
  String get r7UiPaletteFollowingSynced =>
      'Терминалы на этом устройстве используют сохранённую тему терминала.';

  @override
  String get r7UiPaletteSaveFailed =>
      'Не удалось сохранить цветовую схему на этом устройстве. Она действует до закрытия приложения.';

  @override
  String r7UiShortcutRecordTooltip(String action) {
    return 'Записать новое сочетание для «$action»';
  }

  @override
  String get r7UiShortcutRecording => 'Нажмите сочетание клавиш… Esc — отмена';

  @override
  String r7UiShortcutReset(String action) {
    return 'Сбросить «$action» по умолчанию';
  }

  @override
  String get r7UiShortcutDuplicate => 'Уже используется другим действием';

  @override
  String get r7UiShortcutInvalid =>
      'Неподдерживаемое или зарезервированное сочетание';

  @override
  String get r7NavLogTranscriptNone => 'Для этого сеанса запись не велась.';

  @override
  String get r7NavCertAnyPrincipal => 'любой принципал';

  @override
  String get r7NavKindKeyWithCertificate => 'Закрытый ключ + сертификат';

  @override
  String get r7NavHomeNavigation => 'Навигация главной';

  @override
  String get r7NavKeychainSubtitle =>
      'SSH-ключи, пользовательские сертификаты и пароли, общие для хостов и групп. У хостов по-прежнему может быть собственный вход.';

  @override
  String get r7NavAdd => 'Добавить';

  @override
  String get r7NavImportCertificateFile => 'Импортировать файл сертификата';

  @override
  String get r7NavLogs => 'Журналы';

  @override
  String get r7NavLogHost => 'Хост';

  @override
  String r7NavUsedBy(int count, String names) {
    return 'Используется ($count): $names';
  }

  @override
  String get r7NavLogTranscriptLiveNotRecorded =>
      'При запуске этого сеанса запись была выключена.';

  @override
  String get r7NavLogTranscript => 'Запись вывода';

  @override
  String get r7NavCertUnsupported =>
      'Алгоритм сертификата не поддерживается (DSA и сертификаты аппаратных ключей не поддерживаются).';

  @override
  String get r7NavLogSearchHint => 'Поиск хоста или адреса';

  @override
  String get r7NavKeychainSearchHint =>
      'Поиск по имени, пользователю, отпечатку или хосту';

  @override
  String get r7NavImportExport => 'Импорт / экспорт';

  @override
  String get r7NavLogProtocol => 'Протокол';

  @override
  String get r7NavLogRecordTranscripts => 'Записывать вывод терминала';

  @override
  String get r7NavLogFailureCredential =>
      'данные входа отсутствуют или не читаются';

  @override
  String get r7NavLogFailureNetwork => 'ошибка сети или рукопожатия';

  @override
  String get r7NavLogNoMatches => 'Ничего не соответствует поиску или фильтру.';

  @override
  String get r7NavLogCopyTranscript => 'Копировать запись';

  @override
  String get r7NavFilterCertificates => 'Сертификаты';

  @override
  String get r7NavLogStatusConnecting => 'Подключение';

  @override
  String get r7NavSignInKeychainNote =>
      'Используется элемент связки ключей (включая сертификат). Изменяйте его в связке ключей; он остаётся общим с другими хостами.';

  @override
  String r7NavCertCa(String fingerprint) {
    return 'ЦС $fingerprint';
  }

  @override
  String get r7NavDeleteBlocked =>
      'Используется — сначала измените эти хосты или группы';

  @override
  String get r7NavLogFilterClosed => 'Закрытые';

  @override
  String get r7NavKeychain => 'Связка ключей';

  @override
  String get r7NavLogStorageMemory =>
      'Журнал подключений текущего сеанса приложения (только в памяти, очищается при блокировке). Отдельно от истории команд.';

  @override
  String get r7NavLogConnectedAt => 'Подключено';

  @override
  String get r7NavCertificateOptional =>
      'Пользовательский сертификат OpenSSH (необязательно)';

  @override
  String get r7NavLogStorageFailed =>
      'Не удалось сохранить или прочитать журналы; список может быть неполным.';

  @override
  String get r7NavLogFilterAll => 'Все';

  @override
  String get r7NavFilterKeys => 'Ключи';

  @override
  String get r7NavKindPassword => 'Пароль';

  @override
  String get r7NavSnippets => 'Быстрые команды';

  @override
  String get r7NavLogStorageLocal =>
      'Журнал подключений этого устройства, зашифрован в этом локальном профиле. Отдельно от истории команд.';

  @override
  String get r7NavLogDuration => 'Длительность';

  @override
  String get r7NavImportKeyFile => 'Импортировать файл ключа';

  @override
  String get r7NavLogStatusFailed => 'Ошибка';

  @override
  String get r7NavCertificateHelper =>
      'Вставьте или импортируйте файл *-cert.pub, подписанный вашим ЦС. Он должен заверять этот закрытый ключ и предлагается раньше обычного ключа.';

  @override
  String get r7NavCertKeyUnreadable =>
      'Не удалось прочитать закрытый ключ для проверки сертификата (проверьте ключ и парольную фразу).';

  @override
  String get r7NavLogRoute => 'Маршрут';

  @override
  String r7NavSignInKeychainItem(String name) {
    return 'Связка ключей: $name';
  }

  @override
  String get r7NavLogFailureTimeout => 'превышено время ожидания';

  @override
  String get r7NavLogStatusConnected => 'Подключено';

  @override
  String get r7NavNotUsed => 'Не используется хостами или группами';

  @override
  String r7NavLogRecordPolicy(int count, int kib) {
    return 'По умолчанию выключено. Действует для сеансов, открытых после включения. Сохраняет то, что показывает терминал (включая эхо сервера), но не нажатия клавиш; скрытый ввод паролей не записывается. Не выводите секреты во время записи. Хранятся последние $count записей до $kib КиБ.';
  }

  @override
  String get r7NavLogStatus => 'Состояние';

  @override
  String get r7NavLogFailureUnsupported => 'маршрут не поддерживается';

  @override
  String get r7NavLogFailureOther => 'другая ошибка';

  @override
  String get r7NavPortForwarding => 'Переадресация портов';

  @override
  String get r7NavLogFailureHostKeyRejected => 'ключ хоста не одобрен';

  @override
  String get r7NavCertKeyMismatch =>
      'Сертификат не соответствует этому закрытому ключу.';

  @override
  String get r7NavLogStarted => 'Начало';

  @override
  String get r7NavLogStatusEndedByRemote => 'Завершено сервером';

  @override
  String r7NavCertPrincipals(String principals) {
    return 'принципалы: $principals';
  }

  @override
  String get r7NavLogFailureCancelled => 'отменено';

  @override
  String get r7NavCertInKeyField =>
      'В поле закрытого ключа указан сертификат; перенесите его в поле сертификата.';

  @override
  String get r7NavSignInOwn => 'Собственный вход этого хоста';

  @override
  String get r7NavCertValidForever => 'без срока действия';

  @override
  String get r7NavImportFileNotText =>
      'Выбранный файл не является текстовым ключом или сертификатом.';

  @override
  String get r7NavLogReason => 'Причина';

  @override
  String get r7NavFilterPasswords => 'Пароли';

  @override
  String get r7NavLogFilterActive => 'Активные';

  @override
  String get r7NavLogEmpty =>
      'Сеансов пока нет. Здесь появятся открытые вами подключения.';

  @override
  String get r7NavLogStatusLost => 'Соединение потеряно';

  @override
  String r7NavCertExpired(String date) {
    return 'истёк $date';
  }

  @override
  String get r7NavLogStatusClosed => 'Закрыто';

  @override
  String get r7NavSignInSource => 'Способ входа';

  @override
  String get r7NavSignInInherited => 'По умолчанию группы';

  @override
  String get r7NavLogFailureHostKeyChanged => 'ключ хоста изменился';

  @override
  String get r7NavKindPrivateKey => 'Закрытый ключ';

  @override
  String get r7NavLogFailureAuthentication => 'аутентификация отклонена';

  @override
  String get r7NavImportFileTooLarge =>
      'Выбранный файл слишком велик для ключа или сертификата.';

  @override
  String r7NavCertValidUntil(String date) {
    return 'действителен до $date';
  }

  @override
  String get r7NavLogEnded => 'Окончание';

  @override
  String get r7NavLogRouteJump => 'через промежуточный хост';

  @override
  String get r7NavKeychainEmpty => 'Ключей, сертификатов и паролей пока нет.';

  @override
  String get r7NavLogClearTitle => 'Очистить завершённые журналы';

  @override
  String get r7NavCertMalformed => 'Это недействительный сертификат OpenSSH.';

  @override
  String get r7NavNotAPrivateKey =>
      'Этот файл не является закрытым ключом (.pub или сертификат указывается в поле сертификата).';

  @override
  String get r7NavLogFilterFailed => 'Ошибки';

  @override
  String get r7NavLogClearBody =>
      'Удалить с этого устройства все завершённые журналы сеансов и их записи? Активные сеансы останутся.';

  @override
  String r7NavCertNotYetValid(String date) {
    return 'недействителен до $date';
  }

  @override
  String get r7NavLogEndpoint => 'Адрес';

  @override
  String get r7NavCertNotUser =>
      'Это сертификат хоста; для входа нужен пользовательский сертификат.';

  @override
  String get r7NavLogTranscriptTruncated =>
      'Ранний вывод отброшен из-за ограничения размера.';

  @override
  String get r7NavSignInInheritedNote =>
      'Используется вход группы по умолчанию. Выберите собственный вход хоста, чтобы переопределить его.';

  @override
  String r7ForwardSessionLabel(String host, int index) {
    return '$host #$index';
  }

  @override
  String get r7ForwardHostNotConnected => 'Не подключён';

  @override
  String get r7ForwardNoRules =>
      'Правил переадресации пока нет. Нажмите «Новое правило», чтобы добавить его к хосту.';

  @override
  String get r7ForwardConnectAndStart => 'Подключить и запустить';

  @override
  String get r7ForwardDuplicateTitle => 'Дублировать правило переадресации';

  @override
  String get r7ForwardDeleteTitle => 'Удалить правило переадресации?';

  @override
  String get r7ForwardWaitForSession =>
      'Дождитесь завершения подключения сеанса';

  @override
  String get r7ForwardStartCancelled =>
      'Запуск отменён. Если подключение завершится, оно останется обычным сеансом.';

  @override
  String get r7ForwardDuplicate => 'Дублировать';

  @override
  String get r7ForwardRuleChanged =>
      'Правило или хост изменены или удалены; запуск отменён.';

  @override
  String r7ForwardHostSessions(int count) {
    return 'Сеансов: $count';
  }

  @override
  String get r7ForwardMoreActions => 'Другие действия';

  @override
  String get r7ForwardScopeChanged =>
      'Во время подключения сменилось хранилище или профиль; правило не запущено.';

  @override
  String get r7ForwardChooseHost => 'Выберите хост';

  @override
  String get r7ForwardSearchHint => 'Поиск хостов или правил';

  @override
  String r7ForwardDeleteBody(String name) {
    return '«$name» будет удалено с этого хоста. Если правило запущено, оно сначала остановится.';
  }

  @override
  String get r7ForwardHostConnecting => 'Подключение…';

  @override
  String get r7ForwardNoMatches => 'Ничего не найдено.';

  @override
  String r7ForwardCopyName(String name) {
    return '$name (копия)';
  }

  @override
  String get r7ForwardTitle => 'SSH-переадресация';

  @override
  String get r7ForwardRuleConflict =>
      'Это правило было изменено в другом месте. Здесь ничего не изменено; проверьте текущее правило и повторите.';

  @override
  String get r7ForwardOpenSession => 'Открыть сеанс';

  @override
  String get r7ForwardNotConnected =>
      'Подключение не завершено; правило не запущено.';

  @override
  String r7ForwardSummary(int rules, int hosts, int running) {
    return 'Правил: $rules на хостах: $hosts · запущено: $running';
  }

  @override
  String get r7ForwardRemovedHost =>
      'Хост больше не сохранён — переадресация ещё работает';

  @override
  String get r7ForwardChooseSession => 'Выберите сеанс для запуска правил';

  @override
  String get r7ForwardHostConnected => 'Подключён';

  @override
  String get r7ForwardNewRule => 'Новое правило';

  @override
  String r7ForwardOnSession(String session, String status) {
    return 'В $session: $status';
  }

  @override
  String get r7ForwardConnectingStart =>
      'Подключение… правило запустится после аутентификации';

  @override
  String get r7ForwardNoHosts =>
      'SSH-хостов пока нет. Сначала добавьте SSH-хост.';

  @override
  String get r7ForwardNoAutoStart =>
      'Правила запускаются только вручную, через аутентифицированный SSH-сеанс хоста.';

  @override
  String get r7ForwardShowAllHosts => 'Показать хосты без правил';

  @override
  String get r7ImportMenuAction => 'Импорт / экспорт Termius';

  @override
  String get r7ImportIssueCertificateNotStored =>
      'Найден сертификат, но эта сборка не может его сохранить; импортируется только закрытый ключ.';

  @override
  String r7ImportIssueBundleIdentityExtra(String name) {
    return 'Для каждого хоста используется только первый $name; остальные пропущены.';
  }

  @override
  String r7ImportRowJump(String alias) {
    return 'Промежуточный хост: $alias';
  }

  @override
  String r7ImportIssueExportHostSkipped(String name) {
    return 'Хост «$name» пропущен: одно из значений нельзя безопасно записать.';
  }

  @override
  String get r7ImportIssueBundleConfigMissing =>
      'В пакете нет файла OpenSSH «config».';

  @override
  String get r7ImportExportSave => 'Сохранить файл';

  @override
  String get r7ImportConfirmTitle => 'Импортировать из Termius?';

  @override
  String get r7ImportIssueSshJumpCycle =>
      'Цепочка ProxyJump зациклена или слишком длинная.';

  @override
  String get r7ImportExportSecretWarning =>
      'Файл будет содержать пароли или закрытые ключи в открытом виде. Любой, у кого есть файл, сможет войти на эти хосты. Храните его надёжно и удалите после использования.';

  @override
  String r7ImportIssueExportFormulaRisk(int count) {
    return 'В строках ($count) есть значения, начинающиеся с =, +, -, @ или табуляции. Они записаны без изменений; открывайте файл только в Termius или текстовом редакторе, не в табличном редакторе.';
  }

  @override
  String get r7ImportIssueInvalidTag =>
      'Слишком много тегов или слишком длинный тег.';

  @override
  String get r7ImportDispositionCreate => 'Будет создан';

  @override
  String get r7ImportIssueCsvUnterminatedQuote => 'Поле в кавычках не закрыто.';

  @override
  String r7ImportIssueExportSecretsOmitted(int count) {
    return 'Сохранённые пароли хостов ($count) не включены в этот файл.';
  }

  @override
  String r7ImportIssueExportKeysOmitted(int count) {
    return 'Закрытые ключи хостов ($count) не включены в экспорт. Чтобы включить ключи, используйте пакет OpenSSH с файлами ключей.';
  }

  @override
  String get r7ImportFileUnreadable => 'Не удалось прочитать файл.';

  @override
  String r7ImportIssueExportCertificatesOmitted(int count) {
    return 'Сертификаты ($count) не экспортированы, так как файлы ключей выключены.';
  }

  @override
  String get r7ImportExportIntro =>
      'Экспорт хостов в файл по шаблону CSV Termius или в конфигурацию OpenSSH. Секреты не включаются, пока вы их не включите. CSV может содержать только пароли; для файлов ключей используйте пакет OpenSSH.';

  @override
  String get r7ImportIssueCsvInvalid => 'Некорректная структура CSV.';

  @override
  String get r7ImportApplyNone => 'Импортировать хосты';

  @override
  String r7ImportMoreRowsHidden(int count) {
    return 'Ещё строк не показано: $count; они учтены в итогах.';
  }

  @override
  String get r7ImportFailScopeChanged =>
      'Во время импорта хранилище сменилось, импорт остановлен. Записи, сохранённые до переключения, остались в прежнем хранилище; проверьте его перед повторной попыткой.';

  @override
  String get r7ImportIssueBundleTooLarge =>
      'Пакет или один из его файлов превышает ограничения импорта.';

  @override
  String get r7ImportReadOnly =>
      'Это хранилище доступно только для чтения. Экспорт по-прежнему доступен.';

  @override
  String get r7ImportIssueBundleInvalid =>
      'Файл не является корректным ZIP-пакетом.';

  @override
  String get r7ImportIssueCsvNul => 'Файл содержит символ NUL.';

  @override
  String get r7ImportConfirmAccept => 'Импортировать';

  @override
  String get r7ImportIssueMoshAsSsh =>
      'Mosh не поддерживается; хост импортируется как SSH с тем же портом.';

  @override
  String r7ImportIssueTooManyRows(int count) {
    return 'В файле больше $count хостов.';
  }

  @override
  String r7ImportApply(int count) {
    return 'Импортировать хосты: $count';
  }

  @override
  String get r7ImportIssueNotUtf8 =>
      'Файл не является корректным текстом UTF-8. Сохраните его в UTF-8 и повторите.';

  @override
  String get r7ImportIssueBundleConfigAmbiguous =>
      'В пакете несколько файлов «config» на одном уровне; оставьте один.';

  @override
  String r7ImportDone(int hosts, int groups) {
    return 'Импортировано хостов: $hosts, групп: $groups. Данные сохранены в зашифрованном виде.';
  }

  @override
  String get r7ImportBlockedFile =>
      'Этот файл нельзя импортировать. Исправьте указанные ниже проблемы и выберите его снова.';

  @override
  String get r7ImportIssueInvalidRecord =>
      'Этот хост не прошёл проверку Atermius.';

  @override
  String get r7ImportIssueInvalidPrivateKey =>
      'Закрытый ключ в SSH_KEY слишком большой или некорректный.';

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
    return 'Элемент пакета «$name» отклонён (ссылка, небезопасный путь, шифрование или неподдерживаемое сжатие).';
  }

  @override
  String get r7ImportIssueFileTooLarge =>
      'Файл превышает допустимый для импорта размер.';

  @override
  String get r7ImportDispositionBlocked => 'Нельзя импортировать';

  @override
  String get r7ImportChooseCsv => 'Выбрать CSV Termius';

  @override
  String get r7ImportIssueKeyIgnoredForProtocol =>
      'Закрытые ключи применяются только к SSH; для этого хоста ключ не импортирован.';

  @override
  String r7ImportIssueExportCertificatesNotRepresented(int count) {
    return 'Хосты ($count) используют ключ с сертификатом; CSV Termius не может передать сертификаты.';
  }

  @override
  String r7ImportIssueDuplicateInFile(int row) {
    return 'Тот же хост, что и в строке $row.';
  }

  @override
  String r7ImportIssueSshForwardBlocked(String name) {
    return '$name не импортирован: импортируются только перенаправления на loopback с фиксированными портами. Остальные добавьте в редакторе перенаправлений.';
  }

  @override
  String r7ImportIssueUnknownColumnValue(String name) {
    return 'Значение в столбце «$name» не импортировано.';
  }

  @override
  String get r7ImportIssuePasswordDroppedForKey =>
      'Указаны и пароль, и закрытый ключ. Atermius хранит один способ входа на хост, поэтому используется ключ, а пароль не импортируется.';

  @override
  String r7ImportIssueDuplicateTags(int count) {
    return 'Объединено повторяющихся тегов: $count.';
  }

  @override
  String get r7ImportIssueSshBlocked =>
      'Эту конфигурацию OpenSSH нельзя импортировать в текущем виде.';

  @override
  String get r7ImportDispositionExcluded => 'Исключено вами';

  @override
  String get r7ImportTransferTitle => 'Импорт и экспорт Termius';

  @override
  String get r7ImportIssueMissingAddress => 'Hostname/IP не заполнен.';

  @override
  String get r7ImportChooseBundle => 'Выбрать пакет OpenSSH (.zip)';

  @override
  String get r7ImportRowPrivateKey =>
      'Закрытый ключ есть (хранится зашифрованным, не показывается)';

  @override
  String r7ImportIssueExportKeysNotRepresented(int count) {
    return 'Хосты ($count) входят по закрытому ключу. В шаблоне CSV Termius нет столбца для ключей, поэтому ключи не экспортируются.';
  }

  @override
  String r7ImportIssueExportGroupWhitespace(String name) {
    return 'Хост «$name»: имя группы начинается или заканчивается пробелами, которые Termius удаляет.';
  }

  @override
  String get r7ImportExported => 'Экспорт сохранён в выбранный файл.';

  @override
  String r7ImportIssueNonTemplateColumn(String name) {
    return 'Столбца «$name» нет в шаблоне Termius. Atermius его читает, но сам Termius отклоняет файлы с этим столбцом.';
  }

  @override
  String get r7ImportExportFormatBundle =>
      'Пакет OpenSSH (.zip): конфигурация и файлы ключей';

  @override
  String r7ImportIssueGroupTooDeep(int count) {
    return 'Группы могут быть вложены не более чем на $count уровней.';
  }

  @override
  String get r7ImportNativeUnsupported =>
      'Зашифрованные данные приложения Termius, облачные хранилища Termius и нативные резервные копии не читаются. Экспортируйте CSV из Termius или используйте его экспорт OpenSSH.';

  @override
  String get r7ImportIssueMissingHostname =>
      'В заголовке нет столбца «Hostname/IP».';

  @override
  String get r7ImportRowPassword =>
      'Пароль есть (хранится зашифрованным, не показывается)';

  @override
  String get r7ImportIssueInvalidPassword =>
      'Пароль слишком длинный или содержит символ NUL; он не импортирован.';

  @override
  String get r7ImportIssueInvalidAddress =>
      'Hostname/IP не является допустимым именем хоста или адресом.';

  @override
  String get r7ImportIssueMissingFields =>
      'В строке меньше столбцов, чем в заголовке; недостающие значения считаются пустыми.';

  @override
  String get r7ImportIssueSshKeyNotInline =>
      'SSH_KEY не содержит закрытый ключ целиком. Имена ключей и пути к файлам не читаются; добавьте ключ к хосту после импорта.';

  @override
  String r7ImportMoreIssuesHidden(int count) {
    return 'Ещё скрыто замечаний: $count.';
  }

  @override
  String r7ImportRowGroup(String path) {
    return 'Группа: $path';
  }

  @override
  String get r7ImportFailReadOnly =>
      'Хранилище доступно только для чтения. Ничего не импортировано.';

  @override
  String r7ImportIssueExportTagComma(String name) {
    return 'Хост «$name»: тег содержит «,» или пробелы по краям; Termius делит теги по «,» и обрезает пробелы.';
  }

  @override
  String get r7ImportIssueBundleCertificateMissing =>
      'CertificateFile отсутствует в пакете или не является пользовательским сертификатом OpenSSH.';

  @override
  String r7ImportRowForwards(int count) {
    return 'Перенаправления портов: $count';
  }

  @override
  String get r7ImportIssueMissingUsername =>
      'Для SSH-хостов в Atermius нужно имя пользователя. Заполните столбец Username.';

  @override
  String get r7ImportIssueBundleKeyMissing =>
      'IdentityFile нет в выбранном пакете; другие файлы не читаются. Добавьте ключ после импорта.';

  @override
  String get r7ImportExportFormatOpenSsh => 'Конфигурация OpenSSH';

  @override
  String r7ImportIssueExportJumpHost(String name) {
    return 'Хост «$name»: его промежуточного хоста нет в экспорте, поэтому ProxyJump не записан.';
  }

  @override
  String get r7ImportIssueCertificateWithoutKey =>
      'Для сертификата нет закрытого ключа; он не импортирован.';

  @override
  String r7ImportFailPartial(int hosts, int groups, int credentials) {
    return 'Импорт не удался и не был полностью отменён. Сохранено до сбоя: хостов $hosts, групп $groups, учётных данных в связке ключей $credentials; записи, изменённые в другом месте, и записи, прерванные сменой хранилища, сохраняются. Проверьте хосты и связку ключей перед повторной попыткой.';
  }

  @override
  String get r7ImportExportSecretConfirmTitle =>
      'Экспортировать секреты в открытом виде?';

  @override
  String r7ImportIssueExportAliasRewritten(String name) {
    return 'Хосту «$name» назначен безопасный для OpenSSH псевдоним.';
  }

  @override
  String get r7ImportExportSecretConfirmBody =>
      'Экспортированный файл не зашифрован. Пароли или закрытые ключи в нём может прочитать любой человек или приложение с доступом к файлу, включая средства синхронизации и резервного копирования.';

  @override
  String get r7ImportExportIncludeKeys =>
      'Включить файлы закрытых ключей (и сертификаты)';

  @override
  String get r7ImportDispositionDuplicate => 'Пропущено: повторяющаяся строка';

  @override
  String get r7ImportIssueInvalidLabel =>
      'Метка содержит управляющие символы или слишком длинная.';

  @override
  String get r7ImportExportIncludePasswords => 'Включить пароли';

  @override
  String get r7ImportIssueBundleKeyInvalid =>
      'IdentityFile в пакете не является закрытым ключом (или слишком велик) и не импортирован.';

  @override
  String r7ImportIssueExportForwards(int count) {
    return 'У хостов ($count) есть перенаправления портов, которые CSV Termius не может представить.';
  }

  @override
  String get r7ImportIssueEmptyGroupSegment =>
      'Пустые имена групп в пути пропущены.';

  @override
  String r7ImportExportSummary(int count) {
    return 'Будет экспортировано хостов: $count.';
  }

  @override
  String r7ImportIssueSshJumpMissing(String name) {
    return 'ProxyJump «$name» не соответствует ровно одному импортируемому или сохранённому хосту.';
  }

  @override
  String get r7ImportModeImport => 'Импорт';

  @override
  String get r7ImportImportDuplicates =>
      'Импортировать и строки, совпадающие с существующими хостами';

  @override
  String get r7ImportIssueExportTooLarge =>
      'Экспорт превышает объём, который Atermius может импортировать обратно (слишком много хостов или данных для одного файла). Ничего не будет сохранено; экспортируйте меньше хостов.';

  @override
  String get r7ImportExportSecretConfirmAccept => 'Экспортировать с секретами';

  @override
  String r7ImportIssueExportSharedCredential(int count) {
    return 'Хосты ($count) входят с общим паролем из связки ключей; он записывается в строку каждого хоста только при включении паролей.';
  }

  @override
  String r7ImportIssueAlreadyExists(String name) {
    return 'Совпадает с сохранённым хостом «$name».';
  }

  @override
  String get r7ImportChooseOpenSsh => 'Выбрать конфигурацию OpenSSH';

  @override
  String r7ImportSummary(int create, int groups, int skipped, int blocked) {
    return 'Будет создано: $create · новых групп: $groups · пропущено: $skipped · нельзя импортировать: $blocked';
  }

  @override
  String get r7ImportTemplateColumns =>
      'Столбцы CSV Termius: Groups, Label, Tags, Hostname/IP, Protocol, Port, Username, Password. Подгруппы разделяются «/», теги — «,». Дополнительный столбец SSH_KEY с закрытым ключом принимается только при импорте.';

  @override
  String get r7ImportExportOpenSshNoSecrets =>
      'Эта конфигурация не содержит паролей и файлов ключей. Чтобы включить ключи, используйте пакет OpenSSH.';

  @override
  String get r7ImportExportBundleHelp =>
      'Стандартные файлы OpenSSH для распаковки в ~/.ssh (см. README внутри). Это не хранилище Termius; Termius 10.4 не читает из него файлы сертификатов.';

  @override
  String get r7ImportIssueControlCharacter =>
      'Значение содержит управляющие символы.';

  @override
  String r7ImportIssueAtLine(int line, String message) {
    return 'Строка $line: $message';
  }

  @override
  String r7ImportIssueSshHostKeyPolicyIgnored(String name) {
    return '$name пропущен: Atermius всегда проверяет ключи хостов по собственному списку известных хостов.';
  }

  @override
  String r7ImportIssueDuplicateHeader(String name) {
    return 'Столбец «$name» встречается несколько раз.';
  }

  @override
  String get r7ImportFailStale =>
      'После предпросмотра хосты или группы изменились. Ничего не импортировано; выберите файл снова.';

  @override
  String get r7ImportIssueEmptyFile => 'Файл пуст.';

  @override
  String get r7ImportExportFailed => 'Не удалось сохранить файл экспорта.';

  @override
  String r7ImportRowTags(String tags) {
    return 'Теги: $tags';
  }

  @override
  String get r7ImportIntro =>
      'Импорт хостов из CSV-шаблона Termius или конфигурации OpenSSH (включая вывод termius export-ssh-config). Ничего не сохраняется, пока вы не просмотрите предпросмотр и не подтвердите импорт.';

  @override
  String get r7ImportExportIncludeDesktops =>
      'Включить хосты RDP и VNC (расширение Atermius; Termius импортирует их без параметров подключения)';

  @override
  String get r7ImportIssueInvalidUsername =>
      'Имя пользователя содержит пробелы или управляющие символы либо слишком длинное.';

  @override
  String r7ImportIssueExportPasswordsNotRepresented(int count) {
    return 'Хосты ($count) входят по паролю, а файлы OpenSSH не могут хранить пароли.';
  }

  @override
  String get r7ImportIssueCsvTooManyFields =>
      'В строке слишком много столбцов.';

  @override
  String get r7ImportModeExport => 'Экспорт';

  @override
  String get r7ImportIssueExtraFields =>
      'В строке есть значения за пределами столбцов заголовка.';

  @override
  String r7ImportRowEndpointNoUser(
    String address,
    String port,
    String protocol,
  ) {
    return '$address:$port · $protocol';
  }

  @override
  String get r7ImportIssueCsvStrayQuote => 'Кавычка внутри поля без кавычек.';

  @override
  String r7ImportIssueUnsupportedProtocol(String name) {
    return 'Протокол «$name» не поддерживается (поддерживаются SSH, RDP и VNC).';
  }

  @override
  String r7ImportIssueExportGroupSlash(String name) {
    return 'Хост «$name»: имя группы содержит «/», который Termius читает как разделитель подгрупп.';
  }

  @override
  String get r7ImportIssueNoTemplateHeader =>
      'Первая строка не является заголовком CSV Termius (ожидаются столбцы вроде Label и Hostname/IP).';

  @override
  String get r7ImportExportCancelled => 'Экспорт отменён. Файл не записан.';

  @override
  String get r7ImportIssueHeaderOrderNotTermius =>
      'Заголовок отличается от порядка шаблона Termius; Atermius читает его по именам столбцов, но Termius этот файл не импортирует.';

  @override
  String get r7ImportIssueNameAlreadyUsed =>
      'Это имя уже использует другой сохранённый хост.';

  @override
  String r7ImportIssueExtensionProtocol(String name) {
    return 'Протокол «$name» — расширение Atermius; шаблон CSV Termius может его не принять.';
  }

  @override
  String get r7ImportDispositionExisting => 'Пропущено: уже сохранён';

  @override
  String r7ImportIssueExportSkippedProtocol(int count) {
    return 'Хосты RDP/VNC ($count) не экспортируются в этом формате.';
  }

  @override
  String get r7ImportIssueInvalidPort =>
      'Порт должен быть числом от 1 до 65535.';

  @override
  String r7ImportIssueUnknownHeader(String name) {
    return 'Столбец «$name» не входит в шаблон Termius; его значения не импортируются.';
  }

  @override
  String r7ImportIssueExportJumpCount(int count) {
    return 'Хосты с промежуточным хостом ($count) нельзя представить в этом формате.';
  }

  @override
  String r7ImportIssueSshOptionIgnored(String name) {
    return '$name не применяется в Atermius и пропущен.';
  }

  @override
  String r7ImportConfirmBody(int hosts, int groups, int secrets) {
    return 'В текущем хранилище будут созданы зашифрованные хосты ($hosts) и группы ($groups). У $secrets из этих хостов есть пароль или закрытый ключ; он хранится в зашифрованном виде только внутри своего хоста.';
  }

  @override
  String r7ImportIssueSshFinding(String directive, String message) {
    return '$directive: $message';
  }

  @override
  String r7ImportIssueExportPassphraseNotExported(int count) {
    return 'У экспортированных ключей ($count) сохранена парольная фраза; она не записывается, и зашифрованные ключи её запросят.';
  }

  @override
  String get r7ImportExportFormatCsv => 'CSV Termius';

  @override
  String get r7ImportIssueInvalidGroup =>
      'Имя группы содержит управляющие символы или слишком длинное.';

  @override
  String get r7ImportIssueCsvFieldTooLong => 'Слишком длинное поле.';

  @override
  String get r7ImportFailRolledBack =>
      'Импорт не удался и был отменён. Ничего не сохранено.';

  @override
  String get shellLocalInputTooLarge =>
      'Ввод слишком большой для локальной оболочки и не был отправлен';

  @override
  String get shellLocalKindSystem => 'Оболочка по умолчанию';

  @override
  String get shellLocalKindCmd => 'Командная строка (cmd)';

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
  String get shellLocalOptions => 'Параметры локальной оболочки…';

  @override
  String get shellLocalOptionsTitle => 'Запуск локальной оболочки';

  @override
  String get shellLocalShellLabel => 'Оболочка';

  @override
  String get shellLocalWorkingDirectoryLabel =>
      'Рабочий каталог (необязательно)';

  @override
  String get shellLocalWorkingDirectoryHint =>
      'Абсолютный путь или ~/папка; пусто — домашняя папка';

  @override
  String get shellLocalStart => 'Запустить оболочку';

  @override
  String get shellLocalInvalidWorkingDirectory =>
      'Введите абсолютный путь к папке или ~/папка.';

  @override
  String get shellLocalWorkingDirectoryNotFound =>
      'Этот рабочий каталог не существует.';

  @override
  String get shellLocalNotInstalled =>
      'Эта оболочка не установлена на этом компьютере.';

  @override
  String get shellLocalUnavailable =>
      'Локальная оболочка (только в настольном приложении)';

  @override
  String get shellLocalUnavailableDetail =>
      'Здесь нельзя запустить оболочку на вашем компьютере, а Atermius никогда не запускает её на сервере. Используйте настольное приложение Atermius для локальных оболочек.';

  @override
  String shellLocalTabTitle(String shell) {
    return 'Локально · $shell';
  }

  @override
  String shellLocalNewShell(String shell) {
    return 'Новая $shell';
  }

  @override
  String get telnetHost => 'Хост Telnet';

  @override
  String get telnetProtocolUnencrypted => 'Telnet (без шифрования)';

  @override
  String get telnetInteractiveLogin =>
      'Интерактивно в терминале (сохранённые данные не отправляются)';

  @override
  String get telnetLoginInteractiveHint =>
      'Вход по Telnet интерактивный: введите имя пользователя и пароль в терминале. Сохранённые пароли, ключи и элементы связки ключей никогда не отправляются по Telnet.';

  @override
  String get telnetPlaintextWarningTitle => 'Telnet не шифруется';

  @override
  String get telnetPlaintextWarningBody =>
      'Всё, что передаётся по Telnet, включая вводимые пароли, идёт открытым текстом и может быть прочитано или изменено в сети. Используйте только в доверенных сетях или для устройств без SSH. Сама сохранённая запись хоста остаётся зашифрованной.';

  @override
  String telnetPlaintextTerminalNotice(String endpoint) {
    return 'Telnet-подключение к $endpoint не зашифровано: всё, что вы вводите, включая пароли, передаётся открытым текстом.';
  }

  @override
  String telnetConnectedToEndpoint(String endpoint) {
    return 'Telnet подключён к $endpoint (без шифрования)';
  }

  @override
  String get telnetConnectedUnencrypted => 'Telnet подключён (без шифрования)';

  @override
  String get telnetConnecting => 'Подключение Telnet';

  @override
  String get telnetDisconnected => 'Telnet отключён';

  @override
  String get telnetConnectionClosedTerminal =>
      '\r\n[Соединение Telnet закрыто]\r\n';

  @override
  String get telnetConnectionRefused => 'Сервер Telnet отклонил подключение.';

  @override
  String get telnetConnectionTimedOut =>
      'Истекло время ожидания подключения Telnet.';

  @override
  String get telnetHostLookupFailed => 'Не удалось разрешить имя хоста Telnet.';

  @override
  String get telnetHostUnreachable => 'Не удалось связаться с хостом Telnet.';

  @override
  String get telnetRelayUnavailable =>
      'Не удалось открыть Telnet через ретранслятор сервера.';

  @override
  String get telnetUnsupportedInBrowser =>
      'Для Telnet в браузере нужен сервер Atermius, в который выполнен вход и где для этого адреса включён ретранслятор. Локальные профили браузера не могут открывать прямые TCP-подключения.';

  @override
  String get telnetProtocolError =>
      'Сервер Telnet прислал некорректные или чрезмерные данные согласования, поэтому соединение закрыто.';

  @override
  String get telnetConnectionLost => 'Соединение Telnet потеряно.';

  @override
  String get telnetConnectCancelled => 'Подключение Telnet отменено.';

  @override
  String get telnetHostSettingsInvalid =>
      'Хосты Telnet не могут использовать сохранённые данные входа, элементы связки ключей, промежуточные хосты или переадресацию портов. Входите интерактивно в терминале.';

  @override
  String get telnetQuickConnectNoUser =>
      'Telnet не отправляет имя пользователя автоматически. Используйте: telnet хост[:порт] и войдите в терминале.';

  @override
  String get telnetInputTooLarge =>
      'Вставленный текст слишком велик для отправки по Telnet (предел 1 МиБ). Ничего не отправлено.';

  @override
  String get accountSettingsTitle => 'Аккаунт и вход';

  @override
  String get accountSettingsDescription =>
      'Аккаунт и сервер, которые использует это устройство, управление сеансом и вход в аккаунт.';

  @override
  String get accountSettingsCurrentMode => 'Текущий режим';

  @override
  String get accountSettingsModeAccount => 'Аккаунт и синхронизация';

  @override
  String get accountSettingsModeLocal => 'Только локально (это устройство)';

  @override
  String get accountSettingsSignedInAs => 'Вход выполнен как';

  @override
  String get accountSettingsServer => 'Сервер';

  @override
  String get accountSettingsSessionUnlocked =>
      'Вход выполнен, на этом устройстве разблокировано';

  @override
  String get accountSettingsActiveVault => 'Текущее хранилище';

  @override
  String get accountSettingsNoVault => 'Хранилище не выбрано';

  @override
  String get accountSettingsInstanceAdmin => 'Администратор экземпляра';

  @override
  String get accountSettingsSessionActions => 'Сеанс';

  @override
  String get accountSettingsSecurityAction =>
      'Пароль, двухфакторная защита и восстановление';

  @override
  String get accountSettingsSignOutTitle => 'Выйти из этого аккаунта?';

  @override
  String get accountSettingsSignOutBody =>
      'Открытые сеансы этого аккаунта на этом устройстве будут закрыты. Зашифрованные данные хранилища остаются на сервере; для повторного входа потребуется пароль аккаунта.';

  @override
  String get accountSettingsSwitchToLocalTitle =>
      'Переключиться на локальный режим?';

  @override
  String get accountSettingsSwitchToLocalBody =>
      'Рабочее пространство аккаунта и его открытые сеансы на этом устройстве будут закрыты. Ничего из аккаунта не копируется в локальные профили.';

  @override
  String get accountSettingsLocalNotSignedIn => 'Вход в аккаунт не выполнен';

  @override
  String get accountSettingsLocalSyncRequiresAccount =>
      'Локальные профили хранятся только на этом устройстве и не синхронизируются. Чтобы синхронизировать хосты между устройствами, войдите в аккаунт на своём сервере Atermius.';

  @override
  String get accountSettingsSignIn => 'Войти или подключиться к серверу';

  @override
  String get accountSettingsSignInTitle => 'Открыть вход в аккаунт?';

  @override
  String get accountSettingsSignInBody =>
      'Локальный профиль будет заблокирован, а его открытые сеансы закрыты. Локальные хосты остаются на этом устройстве и не выгружаются. После входа перенос можно проверить в разделе «Данные и миграция».';

  @override
  String get themeSettingTitle => 'Тема';

  @override
  String themeSettingSystemResolved(Object theme) {
    return 'Как в системе · сейчас $theme';
  }

  @override
  String get themeOptionSystem => 'Как в системе';

  @override
  String get themeSettingDescription =>
      'Меняет вид окон, меню и панелей приложения. Цвета терминала и изображение удалённого рабочего стола сохраняют свою палитру.';

  @override
  String get themeOptionLight => 'Светлая';

  @override
  String get themeOptionDark => 'Тёмная';

  @override
  String get themeSettingSaveFailed =>
      'Тема изменена для этого сеанса, но её не удалось сохранить на этом устройстве.';

  @override
  String get syncSettingsPreferenceSaveFailed =>
      'Не удалось сохранить эту настройку на устройстве. Она действует до перезапуска приложения.';

  @override
  String get syncSettingsSyncingNow => 'Синхронизация…';

  @override
  String get syncSettingsDeviceOnly =>
      'Эти настройки синхронизации действуют только на этом устройстве.';

  @override
  String get syncSettingsPreferenceSaving => 'Сохранение…';

  @override
  String get syncSettingsAutomaticOffDescription =>
      'Выключено на этом устройстве. Изменения хранятся в зашифрованной очереди устройства, пока вы не нажмёте «Синхронизировать сейчас» или снова не включите автоматическую синхронизацию.';

  @override
  String get syncSettingsNever => 'Никогда';

  @override
  String get syncSettingsSignInRequired =>
      'Для синхронизации войдите в аккаунт на этом устройстве.';

  @override
  String syncSettingsResultNotCompleted(String status) {
    return 'Синхронизация не завершена. Текущее состояние: $status.';
  }

  @override
  String get syncSettingsWaitingToUpload => 'Ожидают отправки';

  @override
  String syncSettingsResultFailed(String error) {
    return 'Синхронизация не завершена: $error';
  }

  @override
  String syncSettingsQueuedWhileOff(int count) {
    return 'Зашифрованных изменений в очереди устройства: $count. Они будут отправлены после нажатия «Синхронизировать сейчас» или включения автоматической синхронизации.';
  }

  @override
  String get syncSettingsTitle => 'Синхронизация';

  @override
  String syncSettingsResultPending(int count) {
    return 'Синхронизация выполнена, но зашифрованные изменения ещё ожидают отправки: $count.';
  }

  @override
  String get syncSettingsAutomaticTitle => 'Автоматическая синхронизация';

  @override
  String get syncSettingsPreferenceLoading =>
      'Загрузка настройки синхронизации этого устройства… Автоматическая синхронизация начнётся после загрузки.';

  @override
  String get syncSettingsPreferenceReadFailedShort =>
      'Автоматическая синхронизация остаётся приостановленной, пока сохранённую настройку не удастся прочитать. Повторите попытку или выберите настройку заново.';

  @override
  String get syncSettingsResultCompleted =>
      'Синхронизация завершена. Ничего не ожидает отправки.';

  @override
  String get syncSettingsAutomaticOnDescription =>
      'Изменения отправляются, а изменения с других устройств загружаются в фоне.';

  @override
  String get syncSettingsPreferenceReadFailed =>
      'Приостановлено: не удалось прочитать сохранённую настройку устройства.';

  @override
  String get syncSettingsSyncNow => 'Синхронизировать сейчас';

  @override
  String get syncSettingsStatus => 'Состояние';

  @override
  String get settingsThemeShortcutsTitle => 'Сочетания клавиш';

  @override
  String get settingsThemeShortcutsDescription =>
      'Выберите сочетания клавиш для работы в терминалах.';

  @override
  String get settingsThemeTitle => 'Тема';

  @override
  String settingsThemeOverlayActive(String name) {
    return 'Сейчас терминалы на этом устройстве используют палитру устройства $name. Выберите сохранённую тему или сохраните другую, чтобы вернуться к ней.';
  }

  @override
  String get settingsThemeDescription =>
      'Выберите светлый или тёмный режим приложения, размер шрифта и цвета терминала.';

  @override
  String get wallpaperSettingTitle => 'Обои';

  @override
  String get wallpaperSettingDescription =>
      'Показывает изображение за приложением и панелями терминала. Размывается только изображение: текст, элементы управления, текст терминала и удалённый рабочий стол остаются чёткими.';

  @override
  String get wallpaperChooseImage => 'Выбрать изображение…';

  @override
  String get wallpaperReplaceImage => 'Заменить изображение…';

  @override
  String get wallpaperReset => 'Убрать обои';

  @override
  String get wallpaperNoImage => 'Обои не выбраны';

  @override
  String get wallpaperPreviewLabel => 'Предпросмотр обоев';

  @override
  String get wallpaperLoading => 'Загрузка обоев…';

  @override
  String get wallpaperMissing =>
      'Сохранённое изображение обоев отсутствует или не читается. Выберите новое изображение или уберите обои.';

  @override
  String get wallpaperModeTitle => 'Расположение';

  @override
  String get wallpaperModeWindow => 'Всё окно';

  @override
  String get wallpaperModeWindowHint => 'Одно изображение на всё окно.';

  @override
  String get wallpaperModePanes => 'По панелям';

  @override
  String get wallpaperModePanesHint =>
      'Каждая панель терминала показывает своё изображение и следует за изменением размера и порядка.';

  @override
  String wallpaperBlurValue(String value) {
    return 'Размытие: $value';
  }

  @override
  String wallpaperErrorTooLarge(int limit) {
    return 'Изображение больше $limit МБ.';
  }

  @override
  String get wallpaperErrorUnsupported =>
      'Выберите изображение PNG, JPEG или статичный WebP.';

  @override
  String get wallpaperErrorCorrupt =>
      'Не удалось прочитать изображение. Возможно, файл повреждён.';

  @override
  String wallpaperErrorDimensions(int side) {
    return 'Изображение слишком большое (не более $side пикс. по стороне).';
  }

  @override
  String get wallpaperErrorStorage =>
      'Не удалось сохранить обои на этом устройстве.';

  @override
  String get wallpaperSaveFailed =>
      'Обои изменены для этого сеанса, но их не удалось сохранить на этом устройстве.';

  @override
  String get wallpaperDeviceNote =>
      'Копия изображения хранится в хранилище приложения на этом устройстве. Отдельные окна при открытии используют те же обои.';

  @override
  String get fileManagerPasteInto => 'Вставить в папку';

  @override
  String get fileManagerPathCopied => 'Путь скопирован';

  @override
  String fileManagerCopying(String name) {
    return 'Копирование «$name»…';
  }

  @override
  String get fileManagerDropFailed =>
      'Не удалось прочитать перетащенные элементы. Ничего не загружено.';

  @override
  String get fileManagerOperationUnsupported =>
      'Это подключение не поддерживает операции файлового менеджера.';

  @override
  String fileManagerDeleteConfirm(String name) {
    return 'Удалить «$name»? Это действие нельзя отменить.';
  }

  @override
  String get fileManagerOpen => 'Открыть';

  @override
  String get fileManagerPasteHere => 'Вставить сюда';

  @override
  String fileManagerUploading(String name, int index, int count) {
    return 'Загрузка «$name» ($index/$count)…';
  }

  @override
  String fileManagerMoveConfirm(String name, String folder) {
    return 'Переместить «$name» в «$folder»?';
  }

  @override
  String get fileManagerNameConflictTitle => 'Имя уже занято';

  @override
  String get fileManagerSkip => 'Пропустить';

  @override
  String fileManagerClipboardCut(String name) {
    return 'Вырезано «$name» — вставьте в этой вкладке, чтобы переместить';
  }

  @override
  String fileManagerRenameTitle(String name) {
    return 'Переименовать «$name»';
  }

  @override
  String fileManagerDeleteFolderConfirm(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count элемента',
      many: '$count элементов',
      few: '$count элемента',
      one: '$count элемент',
    );
    return 'Удалить папку «$name» и $_temp0 внутри? Символические ссылки удаляются, а не раскрываются. Это действие нельзя отменить.';
  }

  @override
  String get fileManagerClearClipboard => 'Очистить буфер файлов';

  @override
  String get fileManagerRename => 'Переименовать';

  @override
  String fileManagerErrorUnsupportedEntry(String name) {
    return '«$name» — символическая ссылка, специальный файл или имя не поддерживается. Копирование папок не следует по ним и не воссоздаёт их, поэтому ничего не скопировано.';
  }

  @override
  String get fileManagerKeepBoth => 'Сохранить оба';

  @override
  String fileManagerErrorFileTooLarge(String name) {
    return '«$name» превышает лимит копирования 1 ГиБ на файл.';
  }

  @override
  String get fileManagerCut => 'Вырезать';

  @override
  String get fileManagerDropNothingAccepted =>
      'Сюда можно перетаскивать только файлы. Папки и ссылки на другие места не загружаются.';

  @override
  String get fileManagerPaste => 'Вставить';

  @override
  String get fileManagerErrorSourceChanged =>
      'Элемент изменён или удалён на сервере. Обновите список и повторите.';

  @override
  String fileManagerErrorExists(String name) {
    return '«$name» здесь уже существует. Ничего не заменено.';
  }

  @override
  String get fileManagerMoveTitle => 'Переместить элемент';

  @override
  String get fileManagerErrorIntoItself =>
      'Нельзя переместить или скопировать папку в саму себя.';

  @override
  String get fileManagerCancelled => 'Отменено. Больше ничего не изменено.';

  @override
  String fileManagerDropTooManyFiles(int count) {
    return 'За один раз можно перетащить не более $count файлов.';
  }

  @override
  String get fileManagerBusy => 'Другое действие с файлами ещё выполняется.';

  @override
  String get fileManagerCopyPath => 'Копировать путь';

  @override
  String fileManagerNameConflictKeepBoth(String name) {
    return '«$name» уже есть в этой папке. Сохранить оба, добавив «(copy)» к новому имени? Существующий элемент не будет заменён.';
  }

  @override
  String fileManagerMoving(String name) {
    return 'Перемещение «$name»…';
  }

  @override
  String fileManagerClipboardCopied(String name) {
    return 'Скопировано «$name» — вставьте в этой вкладке';
  }

  @override
  String get fileManagerDropNeedsSftp =>
      'Перетащенные файлы загружаются по SFTP. Откройте эту папку через SFTP.';

  @override
  String fileManagerDeleting(String name) {
    return 'Удаление «$name»…';
  }

  @override
  String fileManagerUploadSummary(int uploaded, int skipped, int failed) {
    return 'Загружено: $uploaded · пропущено: $skipped · ошибок: $failed';
  }

  @override
  String get fileManagerInvalidName =>
      'Используйте одно имя без косой черты, обратной косой черты и управляющих символов.';

  @override
  String fileManagerErrorLimitExceeded(int entries, int depth) {
    return 'Папка слишком велика для этого действия (лимит $entries элементов, $depth уровней вложенности или 2 ГиБ). Ничего не изменено.';
  }

  @override
  String get fileManagerCopy => 'Копировать';

  @override
  String get fileManagerDropTargetChanged =>
      'Пока проверялись перетащенные файлы, папка или подключение вкладки изменились. Ничего не загружено — перетащите файлы снова.';

  @override
  String fileManagerUploadConflict(String name) {
    return '«$name» уже есть в этой папке. Загрузить под новым именем с «(copy)» или пропустить? Существующий файл не будет заменён.';
  }

  @override
  String get fileManagerMove => 'Переместить';

  @override
  String get homeAddSerialConsoleDetail =>
      'Открывает COM-порт этого компьютера в режиме 8N1. На сервере ничего не запускается.';

  @override
  String get homeSharingThisDevice => 'В сети на этом устройстве';

  @override
  String get homeAddShell => 'Shell (по умолчанию в системе)';

  @override
  String homeSharingSharedPresenceUnknown(int members) {
    return 'Общий доступ · участников: $members · статус неизвестен';
  }

  @override
  String get homeSharingLoading => 'Загрузка участников…';

  @override
  String get homeAddTooltip =>
      'Добавить хост или открыть локальный Shell / последовательную консоль';

  @override
  String get homeAddButton => 'Добавить';

  @override
  String get homeSharingLocalOnly => 'Только локально';

  @override
  String get homeAddSerialConsolePort => 'Последовательный порт';

  @override
  String homeSharingMore(int count, String names) {
    return 'Ещё $count:\n$names';
  }

  @override
  String get homeAddSerialConsoleOpen => 'Открыть консоль';

  @override
  String homeSharingSharedOnline(int members, int online) {
    return 'Общий доступ · участников: $members · в сети: $online';
  }

  @override
  String get homeAddSerialConsoleBaud => 'Скорость (бод)';

  @override
  String homeSharingYou(String name) {
    return '$name (вы)';
  }

  @override
  String get homeAddSerialConsoleTitle => 'Открыть последовательную консоль';

  @override
  String get homeAddSerialConsole => 'Последовательная консоль (COM)…';

  @override
  String get homeSharingLocalDetail =>
      'Этот локальный профиль хранится в зашифрованном виде только на этом устройстве. У него нет участников хранилища, другие его не видят, и статус присутствия не отправляется. Войдите в хранилище аккаунта, чтобы делиться хостами с другими.';

  @override
  String get homeAddSerialConsoleUnavailable =>
      'Последовательная консоль (только приложение для Windows)';

  @override
  String get homeSharingPresenceUnknown => 'Статус неизвестен';

  @override
  String get homeSharingOffline => 'Не в сети';

  @override
  String get homeSharingMembersUnavailable => 'Участники не загружены';

  @override
  String get homeSharingLocalTooltip =>
      'Локальный профиль на этом устройстве — ни с кем не общий';

  @override
  String get homeSharingDetailsTooltip =>
      'Показать участников хранилища и статус в сети';

  @override
  String get homeSharingIndividual => 'Только вы';

  @override
  String get homeSharingOnline => 'В сети';

  @override
  String sidebarResizeWidthValue(int width) {
    return 'Ширина $width пикс.';
  }

  @override
  String get sidebarResizeHint =>
      'Перетащите или используйте стрелки влево и вправо, чтобы изменить ширину';

  @override
  String get sidebarResizeHandle => 'Изменить ширину боковой панели';

  @override
  String get fileEditLaunchFailed =>
      'Не найдено приложение, которое может открыть этот файл.';

  @override
  String get fileEditAtomicUnsupported =>
      'Этот сервер не поддерживает атомарную замену файлов, поэтому ничего не загружено.';

  @override
  String get fileEditUpload => 'Загрузить';

  @override
  String get fileEditLocalRejected =>
      'Локальная копия больше не является обычным файлом в своей личной папке. Ничего не загружено.';

  @override
  String get fileEditConflictTitle => 'Копия на сервере изменилась';

  @override
  String fileEditUploadedChangedAgain(String name) {
    return '«$name» загружен, но во время отправки он снова изменился локально. Загрузите его ещё раз, когда будете готовы.';
  }

  @override
  String get fileEditBlockedType =>
      'Файл такого типа может запуститься при открытии, поэтому он не открывается во внешнем приложении. Используйте «Редактировать текст» или «Скачать».';

  @override
  String get fileEditStatusRejected => 'Локальная копия отклонена';

  @override
  String fileEditFooterTitle(int count) {
    return 'Внешнее редактирование ($count)';
  }

  @override
  String get fileEditOpenExternal => 'Открыть во внешнем приложении';

  @override
  String get fileEditSessionChanged =>
      'Подключение этой вкладки файлов закрыто или изменилось. Ничего не загружено.';

  @override
  String get fileEditStatusChanged => 'Изменён локально — не загружен';

  @override
  String fileEditTooMany(int count) {
    return 'Одновременно во внешних приложениях можно редактировать не более $count файлов.';
  }

  @override
  String get fileEditLocalMissing =>
      'Локальная копия отсутствует. Ничего не загружено.';

  @override
  String get fileEditNotRegular =>
      'Во внешних приложениях можно редактировать только обычные удалённые файлы.';

  @override
  String get fileEditStatusWatching => 'Ожидание сохранения';

  @override
  String get fileEditIgnore => 'Игнорировать';

  @override
  String fileEditOpened(String name) {
    return '«$name» открыт во внешнем приложении. После сохранения нажмите «Загрузить» ниже.';
  }

  @override
  String get fileEditTooLarge =>
      'Во внешних приложениях можно редактировать только файлы до 10 МиБ.';

  @override
  String get fileEditLocalTooLarge =>
      'Локальная копия больше 10 МиБ. Ничего не загружено.';

  @override
  String get fileEditStatusUploading => 'Загрузка…';

  @override
  String get fileEditUnavailable =>
      'Внешнее редактирование доступно только в настольном приложении. Чтобы изменить файл здесь, используйте «Редактировать текст».';

  @override
  String fileEditConflictMessage(String name) {
    return '«$name» изменился на сервере после открытия. Заменить копию на сервере локальной версией?';
  }

  @override
  String get fileEditStatusConflict => 'Также изменён на сервере';

  @override
  String fileEditUploaded(String name) {
    return '«$name» загружен.';
  }

  @override
  String get fileEditStop => 'Прекратить отслеживание';

  @override
  String get fileEditStatusFailed =>
      'Ошибка загрузки — локальные изменения сохранены';

  @override
  String get fileEditKeepLocal => 'Оставить локально';

  @override
  String get fileEditReplace => 'Заменить копию на сервере';

  @override
  String get cloudAccessShareMenu => 'Поделиться…';

  @override
  String cloudAccessShareTitle(String name) {
    return 'Поделиться: $name';
  }

  @override
  String get cloudAccessClose => 'Закрыть';

  @override
  String get cloudAccessTabMembers => 'Участники и команды';

  @override
  String get cloudAccessTabLinks => 'Временные ссылки';

  @override
  String get cloudAccessGatewayTrustNotice =>
      'Гости подключаются через шлюз этого сервера. Для этого данные входа этого Host запечатываются ключом шлюза сервера до отзыва или истечения ссылки. Оператор сервера (или тот, кто взломает сервер) может их открыть и видеть сеанс. Гости не получают пароль или ключ через эту функцию, но в сеансе могут делать всё, что разрешено учётной записи. Используйте отдельную учётную запись с минимальными правами.';

  @override
  String get cloudAccessLinksHeading => 'Ссылки для этого Host';

  @override
  String get cloudAccessNewLink => 'Новая ссылка';

  @override
  String get cloudAccessNoLinks => 'Временных ссылок пока нет.';

  @override
  String get cloudAccessStatusActive => 'Активна';

  @override
  String get cloudAccessStatusScheduled => 'Запланирована';

  @override
  String get cloudAccessStatusExpired => 'Истекла';

  @override
  String get cloudAccessStatusPaused => 'Приостановлена';

  @override
  String get cloudAccessStatusSuspended => 'Заблокирована';

  @override
  String get cloudAccessStatusRevoked => 'Отозвана';

  @override
  String cloudAccessValidUntil(String time) {
    return 'до $time';
  }

  @override
  String cloudAccessRedemptionCount(String used, String max) {
    return 'открыта $used/$max';
  }

  @override
  String cloudAccessActiveSessions(String count) {
    return 'активных: $count';
  }

  @override
  String get cloudAccessMore => 'Ещё';

  @override
  String get cloudAccessActivity => 'Активность';

  @override
  String get cloudAccessPause => 'Приостановить';

  @override
  String get cloudAccessResume => 'Возобновить';

  @override
  String get cloudAccessRotate => 'Новый секрет';

  @override
  String get cloudAccessRevoke => 'Отозвать';

  @override
  String get cloudAccessRevokeLinkTitle => 'Отозвать эту ссылку?';

  @override
  String get cloudAccessRevokeLinkMessage =>
      'Ссылка сразу перестанет работать, активные гостевые сеансы закроются в течение нескольких секунд. Отзыв не отменяет того, что гости уже сделали на Host.';

  @override
  String get cloudAccessRotateTitle => 'Выпустить новый секрет?';

  @override
  String get cloudAccessRotateMessage =>
      'Текущий адрес перестанет работать, его гости будут отключены. Вы получите новый адрес для отправки.';

  @override
  String get cloudAccessScheduleStart => 'Начать позже';

  @override
  String get cloudAccessStartsNow => 'Начинается сейчас';

  @override
  String get cloudAccessPickStart => 'Выберите время начала';

  @override
  String get cloudAccessLifetime => 'Срок действия';

  @override
  String get cloudAccessOneHour => '1 час';

  @override
  String get cloudAccessOneDay => '24 часа';

  @override
  String get cloudAccessOneWeek => '7 дней';

  @override
  String get cloudAccessCustom => 'Другое…';

  @override
  String cloudAccessWindowSummary(String start, String end, String utc) {
    return 'С $start до $end (местное время; UTC $utc). Решает часы сервера.';
  }

  @override
  String get cloudAccessEndBeforeStart =>
      'Окончание должно быть позже начала и в будущем.';

  @override
  String get cloudAccessMaxRedemptions => 'Сколько раз можно открыть ссылку';

  @override
  String get cloudAccessMaxRedemptionsHelp =>
      'По умолчанию 1. Каждый браузер, нажавший «Продолжить», расходует одно открытие.';

  @override
  String get cloudAccessUnlimited => 'Без ограничений';

  @override
  String get cloudAccessRedemptionsRange =>
      'Введите от 1 до 1000 или выберите «Без ограничений».';

  @override
  String get cloudAccessMaxConnections => 'Попыток подключения (необязательно)';

  @override
  String get cloudAccessMaxConnectionsHelp =>
      'Оставьте пустым для снятия ограничения. Отклонённые попытки не считаются.';

  @override
  String get cloudAccessConnectionsRange =>
      'Введите положительное число или оставьте пустым.';

  @override
  String get cloudAccessConcurrent => 'Одновременных подключений';

  @override
  String get cloudAccessViewOnly => 'Только просмотр';

  @override
  String get cloudAccessViewOnlyHelp =>
      'Клавиатура, мышь и вставка блокируются сервером.';

  @override
  String get cloudAccessClipboardToRemote => 'Разрешить вставку в Host';

  @override
  String get cloudAccessClipboardFromRemote => 'Разрешить копирование из Host';

  @override
  String get cloudAccessFilesLocked =>
      'Передача файлов, диски, печать и запись для гостей отключены.';

  @override
  String get cloudAccessCustomSlug => 'Свой адрес (необязательно)';

  @override
  String get cloudAccessCustomSlugHelp =>
      '3–48 строчных букв, цифр или дефисов. Адрес — не пароль: его можно угадать, избегайте конфиденциальных слов.';

  @override
  String get cloudAccessGuestTitle => 'Заголовок для гостя (необязательно)';

  @override
  String get cloudAccessGuestTitleHelp =>
      'Шифруется секретом ссылки; сервер не может его прочитать.';

  @override
  String get cloudAccessCancel => 'Отмена';

  @override
  String get cloudAccessCreateLink => 'Создать ссылку';

  @override
  String get cloudAccessLinkReady => 'Ссылка создана';

  @override
  String get cloudAccessCopyLink => 'Копировать ссылку';

  @override
  String get cloudAccessCopied => 'Скопировано';

  @override
  String get cloudAccessShownOnce =>
      'Полная ссылка показывается только сейчас. Если она потеряна, выпустите новый секрет.';

  @override
  String get cloudAccessSendSafely =>
      'Открыть ссылку может любой, у кого она есть. Отправляйте только по доверенному каналу; некоторые почтовые сканеры открывают ссылки и расходуют их.';

  @override
  String get cloudAccessDone => 'Готово';

  @override
  String get cloudAccessBack => 'Назад';

  @override
  String cloudAccessActivityFor(String link) {
    return 'Активность · $link';
  }

  @override
  String get cloudAccessGuestSessions => 'Гостевые сеансы';

  @override
  String get cloudAccessNoSessions => 'Эту ссылку ещё никто не открывал.';

  @override
  String cloudAccessSessionSince(String time) {
    return 'Активен с $time';
  }

  @override
  String cloudAccessSessionEnded(String reason) {
    return 'Завершён ($reason)';
  }

  @override
  String get cloudAccessTerminate => 'Завершить сеанс';

  @override
  String get cloudAccessAuditEvents => 'Аудит (только метаданные)';

  @override
  String get cloudAccessMembersExplainer =>
      'Участники получают этот Host через зашифрованный Vault. Ключ Vault получатели получают только после того, как вы подтвердите каждое их устройство; администраторы организации не могут получить его сами.';

  @override
  String get cloudAccessDedicatedVault => 'Поделиться только этим Host';

  @override
  String get cloudAccessDedicatedVaultHelp =>
      'Будет создан новый Vault для совместного доступа с копией этого Host и только перечисленными ниже элементами. Другие Host и учётные данные текущего Vault остаются закрытыми.';

  @override
  String get cloudAccessSharingVaultName => 'Название общего Vault';

  @override
  String cloudAccessSharingVaultDefaultName(String name) {
    return 'Общий · $name';
  }

  @override
  String get cloudAccessWillCopy => 'Будет скопировано:';

  @override
  String cloudAccessDependencyJumpHost(String name) {
    return 'Промежуточный узел $name';
  }

  @override
  String cloudAccessDependencyCredential(String name) {
    return 'Учётные данные $name';
  }

  @override
  String cloudAccessDependencyKnownHost(String key) {
    return 'Доверенный ключ узла $key';
  }

  @override
  String cloudAccessDependencyGroup(String name) {
    return 'Группа $name не копируется';
  }

  @override
  String cloudAccessBlockerMissingJump(String name) {
    return '$name использует промежуточный узел не из этого Vault.';
  }

  @override
  String cloudAccessBlockerMissingCredential(String name) {
    return '$name ссылается на учётные данные не из этого Vault.';
  }

  @override
  String cloudAccessBlockerJumpLoop(String name) {
    return 'У $name цикл промежуточных узлов.';
  }

  @override
  String get cloudAccessConsentCopy =>
      'Я разрешаю скопировать в новый Vault именно эти элементы.';

  @override
  String get cloudAccessCreateSharingVault => 'Создать общий Vault';

  @override
  String get cloudAccessWholeVaultHeading => 'Или поделиться всем Vault';

  @override
  String get cloudAccessWholeVaultHelp =>
      'Получатели увидят все Host, учётные данные и фрагменты текущего Vault.';

  @override
  String get cloudAccessManageWholeVault => 'Управлять доступом ко всему Vault';

  @override
  String get cloudAccessAttachOrg => 'Выберите организацию';

  @override
  String get cloudAccessAttachOrgHelp =>
      'Права выдаются участникам и командам управляемой вами организации.';

  @override
  String get cloudAccessAttach => 'Выбрать';

  @override
  String get cloudAccessManageOrganizations => 'Управлять организациями';

  @override
  String cloudAccessGrantsIn(String org) {
    return 'Доступ в $org';
  }

  @override
  String get cloudAccessAddGrant => 'Добавить участника или команду';

  @override
  String cloudAccessTeamLabel(String name) {
    return 'Команда $name';
  }

  @override
  String get cloudAccessRoleViewer => 'Просмотр';

  @override
  String get cloudAccessRoleEditor => 'Редактор';

  @override
  String get cloudAccessRemove => 'Удалить';

  @override
  String get cloudAccessKeyDistribution => 'Ожидают ключей';

  @override
  String get cloudAccessKeyDistributionHelp =>
      'Перед передачей ключа Vault сверьте каждый отпечаток с получателем по другому каналу.';

  @override
  String get cloudAccessWaitingForDevice =>
      'Ожидается, что получатель откроет «Организации» на устройстве';

  @override
  String get cloudAccessWaitingForOwner => 'Готово к вашему подтверждению';

  @override
  String get cloudAccessWaitingForRecipient =>
      'Ключ отправлен; ожидается принятие получателем';

  @override
  String get cloudAccessRoleDiffers =>
      'Подписанная роль отличается от выданной; для изменения выполните ротацию или повторное приглашение';

  @override
  String cloudAccessDeviceFingerprint(String fingerprint) {
    return 'Устройство $fingerprint';
  }

  @override
  String get cloudAccessConfirmFingerprintTitle => 'Подтвердите устройство';

  @override
  String cloudAccessConfirmFingerprintMessage(String user, String fingerprint) {
    return 'Передать ключ Vault устройству $user $fingerprint? Продолжайте, только если $user подтвердил вам этот отпечаток.';
  }

  @override
  String get cloudAccessDeliverKey => 'Передать ключ';

  @override
  String get cloudAccessRemovalPending =>
      'Доступ на сервере уже заблокирован. Выполните ротацию ключа Vault, чтобы удалить участника криптографически, и смените учётные данные, которые он видел.';

  @override
  String get cloudAccessKeepDirect => 'Оставить прямым участником';

  @override
  String get cloudAccessRotateToRemove => 'Ротация ключа';

  @override
  String get cloudAccessRestrictedToViewer =>
      'Только просмотр, пока подписанная роль не обновлена';

  @override
  String get cloudAccessOrganizations => 'Организации';

  @override
  String get cloudAccessOrganizationsSubtitle =>
      'Участники, команды и приглашения';

  @override
  String get cloudAccessOrganizationsExplainer =>
      'Названия организаций, участники, роли и команды видны этому серверу. Вступление в организацию само по себе не даёт ключей Vault.';

  @override
  String get cloudAccessPendingJoin =>
      'Вы открыли приглашение в организацию — просмотрите его';

  @override
  String get cloudAccessJoinOrganization => 'Вступить в организацию';

  @override
  String get cloudAccessJoinLinkField => 'Ссылка-приглашение';

  @override
  String get cloudAccessJoinInvalid =>
      'Это недействительная ссылка-приглашение.';

  @override
  String get cloudAccessReview => 'Просмотреть';

  @override
  String cloudAccessJoinSummary(String inviter, String role) {
    return 'Приглашение от $inviter, роль: $role';
  }

  @override
  String get cloudAccessJoin => 'Вступить';

  @override
  String get cloudAccessJoined =>
      'Вы вступили. Владельцам Vault ещё нужно подтвердить ваше устройство, прежде чем вы получите общий Vault.';

  @override
  String get cloudAccessSharedVaultKeys => 'Ключи общих Vault';

  @override
  String get cloudAccessSharedVaultKeysHelp =>
      'Публикует открытые ключи этого устройства и принимает Vault, владельцы которых подтвердили это устройство.';

  @override
  String get cloudAccessCheckDeliveries => 'Проверить общие Vault';

  @override
  String cloudAccessDeliveriesAccepted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Добавлено $count общих Vault.',
      many: 'Добавлено $count общих Vault.',
      few: 'Добавлено $count общих Vault.',
      one: 'Добавлен $count общий Vault.',
      zero: 'Новых общих Vault нет.',
    );
    return '$_temp0';
  }

  @override
  String get cloudAccessYourOrganizations => 'Ваши организации';

  @override
  String get cloudAccessNewOrganization => 'Новая организация';

  @override
  String get cloudAccessOrganizationName => 'Название организации';

  @override
  String get cloudAccessNoOrganizations =>
      'Вы пока не состоите ни в одной организации.';

  @override
  String cloudAccessMemberCount(String count) {
    return 'участников: $count';
  }

  @override
  String get cloudAccessOrgRoleOwner => 'Владелец';

  @override
  String get cloudAccessOrgRoleAdmin => 'Администратор';

  @override
  String get cloudAccessOrgRoleMember => 'Участник';

  @override
  String get cloudAccessSave => 'Сохранить';

  @override
  String get cloudAccessMembers => 'Участники';

  @override
  String get cloudAccessInviteMember => 'Пригласить';

  @override
  String get cloudAccessInviteUsername => 'Имя пользователя (необязательно)';

  @override
  String get cloudAccessInviteUsernameHelp =>
      'Ограничьте приглашение одной существующей учётной записью. Новым людям сначала нужно приглашение учётной записи от администратора экземпляра.';

  @override
  String get cloudAccessRole => 'Роль';

  @override
  String get cloudAccessInitialTeam => 'Команда';

  @override
  String get cloudAccessNoTeam => 'Без команды';

  @override
  String get cloudAccessCreateInvitation => 'Создать приглашение';

  @override
  String get cloudAccessInvitationReady => 'Ссылка-приглашение создана';

  @override
  String get cloudAccessCopyInvitation => 'Копировать ссылку-приглашение';

  @override
  String get cloudAccessLeave => 'Выйти';

  @override
  String get cloudAccessRemoveMemberTitle => 'Удалить из организации?';

  @override
  String get cloudAccessRemoveMemberMessage =>
      'Доступ через права организации блокируется сразу. Затем владельцам Vault следует выполнить ротацию ключей затронутых Vault.';

  @override
  String get cloudAccessTeams => 'Команды';

  @override
  String get cloudAccessNewTeam => 'Новая команда';

  @override
  String get cloudAccessTeamName => 'Название команды';

  @override
  String cloudAccessTeamMembers(String team) {
    return 'Участники $team';
  }

  @override
  String get cloudAccessInvitations => 'Приглашения';

  @override
  String get cloudAccessAnyAccount => 'Любая учётная запись';

  @override
  String get cloudAccessErrorGeneric => 'Не удалось выполнить запрос.';

  @override
  String get cloudAccessErrorLinksUnavailable =>
      'На этом сервере временные ссылки не настроены.';

  @override
  String get cloudAccessErrorOrganizationsUnavailable =>
      'На этом сервере организации не включены.';

  @override
  String get cloudAccessErrorProtocolUnavailable =>
      'Протокол этого Host нельзя использовать для совместного доступа на этом сервере.';

  @override
  String get cloudAccessErrorOwnerRequired =>
      'Делиться по ссылкам может только владелец Vault.';

  @override
  String get cloudAccessErrorJumpHost =>
      'Host с промежуточным узлом нельзя открыть через шлюз.';

  @override
  String get cloudAccessErrorPortForward =>
      'Host с профилями переадресации портов нельзя открыть через шлюз.';

  @override
  String get cloudAccessErrorHostKeyRequired =>
      'Перед тем как поделиться, подключитесь один раз и доверьтесь SSH-ключу этого Host.';

  @override
  String get cloudAccessErrorCertificateRequired =>
      'Перед тем как поделиться, подключитесь один раз и доверьтесь RDP-сертификату этого Host.';

  @override
  String get cloudAccessErrorLoginRequired =>
      'Перед тем как поделиться, сохраните данные входа для этого Host.';

  @override
  String get cloudAccessErrorHostChanged =>
      'Host изменён или ещё не синхронизирован. Синхронизируйте и повторите.';

  @override
  String get cloudAccessErrorPlanBlocked =>
      'Сначала устраните перечисленные проблемы.';

  @override
  String get cloudAccessErrorTargetDenied =>
      'Адрес этого Host запрещён политикой совместного доступа сервера.';

  @override
  String get cloudAccessErrorSlugTaken => 'Этот адрес недоступен.';

  @override
  String get cloudAccessErrorSlugInvalid =>
      'Используйте 3–48 строчных букв, цифр или дефисов внутри.';

  @override
  String get cloudAccessErrorTooManyLinks =>
      'Слишком много активных ссылок. Сначала отзовите часть.';

  @override
  String get cloudAccessErrorInvalidOptions =>
      'Сервер не допускает такие параметры ссылки.';

  @override
  String get cloudAccessErrorOrgRoleRequired =>
      'Нужна роль владельца или администратора организации.';

  @override
  String get cloudAccessErrorOrgCreationRestricted =>
      'Здесь создавать организации могут только администраторы экземпляра.';

  @override
  String get cloudAccessErrorLastOwner =>
      'В организации должен быть хотя бы один владелец.';

  @override
  String get cloudAccessErrorInvitationUnavailable =>
      'Это приглашение недоступно.';

  @override
  String get cloudAccessErrorAccountNotFound =>
      'Нет активной учётной записи с таким именем.';

  @override
  String get cloudAccessErrorRateLimited =>
      'Слишком много попыток. Подождите и повторите.';

  @override
  String get cloudAccessGuestWindowTitle => 'Общий доступ Atermius';

  @override
  String get cloudAccessGuestLanding =>
      'Вы получили ссылку временного доступа Atermius';

  @override
  String get cloudAccessGuestLandingHelp =>
      'Ничего не произойдёт, пока вы не продолжите. Продолжение может израсходовать одно из разрешённых открытий ссылки.';

  @override
  String get cloudAccessGuestContinue => 'Продолжить';

  @override
  String get cloudAccessGuestHeading => 'Общий доступ';

  @override
  String cloudAccessGuestValidUntil(String time) {
    return 'Сеанс завершится $time';
  }

  @override
  String get cloudAccessGuestViewOnly => 'Только просмотр';

  @override
  String get cloudAccessGuestInteractive => 'Интерактивно';

  @override
  String get cloudAccessGuestClipboardOn => 'Буфер обмена разрешён';

  @override
  String get cloudAccessGuestClipboardOff => 'Буфер обмена отключён';

  @override
  String get cloudAccessGuestConnect => 'Подключиться';

  @override
  String get cloudAccessGuestDisconnect => 'Отключиться';

  @override
  String get cloudAccessGuestLeave => 'Завершить доступ';

  @override
  String get cloudAccessGuestLeft =>
      'Доступ завершён. Эту вкладку можно закрыть.';

  @override
  String get cloudAccessGuestTrustNote =>
      'Этот сеанс идёт через сервер Atermius владельца ссылки, и сервер может его видеть.';

  @override
  String get cloudAccessGuestUnavailable => 'Эта ссылка недоступна.';

  @override
  String get cloudAccessGuestAskOwner =>
      'Попросите отправителя прислать новую ссылку.';

  @override
  String get cloudAccessGuestNotYetValid => 'Эта ссылка ещё не действует.';

  @override
  String get cloudAccessGuestExpired => 'Срок действия ссылки истёк.';

  @override
  String get cloudAccessGuestExhausted => 'Эта ссылка уже использована.';

  @override
  String get cloudAccessGuestSuspended =>
      'Владелец приостановил или отозвал эту ссылку.';

  @override
  String get cloudAccessGuestSessionEnded => 'Ваш сеанс завершён.';

  @override
  String get cloudAccessGuestBusy =>
      'Сейчас слишком много подключений. Повторите чуть позже.';

  @override
  String get cloudAccessGuestExpiringSoon => 'Завершится через 5 минут';

  @override
  String get cloudAccessGuestClosed => 'Соединение закрыто.';

  @override
  String get cloudAccessGuestClosedRevoked =>
      'Владелец отозвал или изменил доступ.';

  @override
  String get cloudAccessGuestClosedExpired => 'Время доступа истекло.';

  @override
  String get cloudAccessGuestClosedTarget =>
      'Host недоступен или не совпал с доверенной идентичностью.';

  @override
  String get cloudAccessGuestClosedProtocol =>
      'Соединение закрыто из-за неожиданного сообщения.';

  @override
  String cloudAccessApplyRole(String role) {
    return 'Сделать: $role';
  }

  @override
  String get cloudAccessApplyRoleTitle => 'Изменить роль участника?';

  @override
  String cloudAccessApplyRoleMessage(String user, String role) {
    return '$user получит роль «$role». С этого устройства будет подписан новый список участников и выполнена ротация ключа Vault.';
  }

  @override
  String get cloudAccessErrorScopeChanged =>
      'Во время действия изменились учётная запись, сервер или выбранный Vault. Ничего не отправлено; повторите.';

  @override
  String get cloudAccessErrorNotSynced =>
      'Общий Vault создан, но ещё не синхронизирован. Синхронизируйте его перед добавлением участников.';

  @override
  String get cloudAccessErrorScopeEndedCommitted =>
      'Учётная запись, сервер или выбранный Vault изменились после того, как сервер уже выполнил часть действия (например, создал Vault или приглашение). Эта часть не отменена; проверьте её перед повтором.';

  @override
  String get directDesktopSignInHint =>
      'Данные для входа хранятся в зашифрованном виде. Это устройство подключается к хосту напрямую и использует их только для этого подключения, без шлюза.';

  @override
  String get keybarCtrlGuidance =>
      'Ctrl: нажмите для следующей клавиши, дважды — чтобы зафиксировать';

  @override
  String get keybarAltGuidance =>
      'Alt: нажмите для следующей клавиши, дважды — чтобы зафиксировать';

  @override
  String get keybarModifierOff => 'Выкл.';

  @override
  String get keybarModifierArmed => 'Только следующая клавиша';

  @override
  String get keybarModifierLocked => 'Зафиксирован';

  @override
  String get keybarPinExpanded => 'Не скрывать дополнительные клавиши';

  @override
  String get mcpAccessModeDenied => 'Запрещено';

  @override
  String get mcpAccessModeReadOnly => 'Только чтение';

  @override
  String get mcpAccessModeReadWrite => 'Чтение и запись';

  @override
  String get mcpAccessModeDeniedDescription =>
      'Внешний ИИ не видит и не может использовать машину. Она не попадает в списки хостов и сеансов.';

  @override
  String get mcpAccessModeReadOnlyDescription =>
      'Внешний ИИ видит машину и может читать вывод и файлы уже открытых сеансов. Подключаться, вводить текст, выполнять команды и изменять файлы он не может.';

  @override
  String get mcpAccessModeReadWriteDescription =>
      'Внешний ИИ также может подключать, переключать и закрывать сеансы, вводить текст в терминал, выполнять команды и записывать файлы. Запросы ключа хоста и входа по-прежнему появляются.';

  @override
  String get mcpMachineAccessTitle => 'Доступ к машинам';

  @override
  String get mcpMachineAccessDescription =>
      'Выберите, что внешний ИИ может делать на каждой машине. Настройки хранятся на этом устройстве для текущего рабочего пространства и не синхронизируются. Остановка MCP отзывает весь доступ независимо от выбранного здесь.';

  @override
  String get mcpDefaultAccessTitle => 'По умолчанию для всех машин';

  @override
  String get mcpDefaultAccessDescription =>
      'Применяется ко всем машинам без собственной настройки, включая добавленные позже.';

  @override
  String get mcpPerMachineTitle => 'Настройки для отдельных машин';

  @override
  String mcpCustomizedCount(int count) {
    return 'Машин с собственной настройкой: $count';
  }

  @override
  String get mcpLocalDeviceName => 'Это устройство (локальная консоль)';

  @override
  String get mcpLocalDeviceDetail =>
      'Локальные сеансы терминала, не связанные с сохранённым хостом';

  @override
  String mcpHostUseDefault(String mode) {
    return 'По умолчанию ($mode)';
  }

  @override
  String get mcpHostCustom => 'Своя настройка';

  @override
  String mcpHostAccessFor(String name) {
    return 'Доступ для $name';
  }

  @override
  String get mcpSearchMachines => 'Поиск машин';

  @override
  String mcpNoMachinesMatch(String query) {
    return 'Нет машин, соответствующих «$query».';
  }

  @override
  String get mcpNoSavedMachines =>
      'В этом рабочем пространстве пока нет сохранённых хостов.';

  @override
  String mcpShowMoreMachines(int count) {
    return 'Показать ещё: $count';
  }

  @override
  String get mcpAccessLoading => 'Загрузка настроек доступа к машинам…';

  @override
  String get mcpAccessUnavailable =>
      'Настройки доступа к машинам сейчас недоступны. Пока они не загрузятся, внешнему ИИ запрещён доступ ко всем машинам.';

  @override
  String get mcpAccessSaveFailed =>
      'Не удалось сохранить настройку доступа. Повторите попытку.';

  @override
  String get mcpConfirmReadWriteDefaultTitle =>
      'Разрешить чтение и запись на всех машинах?';

  @override
  String get mcpConfirmReadWriteDefaultBody =>
      'Любой ИИ с токеном подключения сможет подключаться, вводить текст, выполнять команды и изменять файлы на всех машинах без собственной настройки, включая добавленные позже. Запросы ключа хоста и входа по-прежнему появляются.';

  @override
  String get mcpConfirmReadWriteDefaultConfirm => 'Разрешить чтение и запись';

  @override
  String mcpRunningDefaultAccess(String mode) {
    return 'Работает · По умолчанию: $mode';
  }

  @override
  String get mcpAndroidForwardingHint =>
      'MCP прослушивает только адрес обратной петли этого устройства. Чтобы использовать его из ИИ на компьютере, подключённом по отладке USB, выполните на компьютере эту команду, а затем используйте там скопированную конфигурацию:';

  @override
  String get mcpAndroidBackgroundHint =>
      'Пока MCP работает, Atermius показывает уведомление, чтобы внешний ИИ мог продолжать работу после перехода в другое приложение. Остановка из уведомления, блокировка или выход отзывают токен. Если уведомление показать нельзя, MCP останавливается при выходе из приложения.';

  @override
  String get mcpForegroundNotificationTitle => 'Доступ внешнего ИИ включён';

  @override
  String mcpForegroundNotificationText(int port) {
    return 'MCP прослушивает 127.0.0.1:$port. Остановите его, чтобы отозвать токен доступа.';
  }

  @override
  String get mcpForegroundNotificationStop => 'Остановить MCP';

  @override
  String get mcpAndroidProtected =>
      'Уведомление MCP обеспечивает доступ в фоновом режиме.';

  @override
  String get mcpAndroidForegroundOnly =>
      'MCP работает, пока приложение видно. При уходе из приложения доступ отзывается.';

  @override
  String get mcpAndroidStarting => 'Запускается фоновая защита Android…';

  @override
  String get desktopKeyboardShow => 'Открыть клавиатуру и специальные клавиши';

  @override
  String get desktopKeyboardHide => 'Скрыть клавиатуру и специальные клавиши';

  @override
  String get desktopTouchMode => 'Сенсорный ввод';

  @override
  String get desktopTrackpadMode => 'Тачпад (мышь)';

  @override
  String get enterFullscreen => 'Полноэкранный режим';

  @override
  String get exitFullscreen => 'Выйти из полноэкранного режима';

  @override
  String get fullscreenUnavailable =>
      'Для этого окна недоступен полноэкранный режим.';

  @override
  String get restoreConnection => 'Восстановить соединение';

  @override
  String get reconnectEveryFiveSeconds => 'Автоподключение каждые 5 секунд';
}
