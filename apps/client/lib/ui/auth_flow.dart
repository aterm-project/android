import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../app_controller.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import '../l10n/l10n.dart';
import 'app_language_settings.dart';
import 'app_density.dart';
import 'credential_visibility/credential_visibility_widgets.dart';

class _RecoveryInput {
  const _RecoveryInput({
    required this.username,
    required this.recoveryCode,
    required this.newPassword,
    required this.confirmationPassword,
    required this.deviceName,
  });

  final String username;
  final String recoveryCode;
  final String newPassword;
  final String confirmationPassword;
  final String deviceName;
}

class AuthFlow extends StatefulWidget {
  const AuthFlow({required this.controller, super.key});

  final AppController controller;

  @override
  State<AuthFlow> createState() => _AuthFlowState();
}

class _AuthFlowState extends State<AuthFlow> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _mfaCode = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _bootstrap = TextEditingController();
  final _deviceName = TextEditingController(text: 'Atermius Web');
  final _vaultName = TextEditingController(text: currentL10n.personalVault);
  final _recoveryUsername = TextEditingController();
  final _recoveryCode = TextEditingController();
  final _recoveryNewPassword = TextEditingController();
  final _recoveryConfirmation = TextEditingController();
  final _recoveryDeviceName = TextEditingController();
  bool _obscure = true;
  MfaLoginChallenge? _loginChallenge;
  bool _useMfaRecoveryCode = false;

  AppController get app => widget.controller;

  @override
  void initState() {
    super.initState();
    _server.text = app.serverUrl ?? '';
  }

  @override
  void didUpdateWidget(covariant AuthFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_server.text.isEmpty && app.serverUrl != null)
      _server.text = app.serverUrl!;
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _mfaCode.clear();
    _mfaCode.dispose();
    _bootstrap.dispose();
    _deviceName.dispose();
    _vaultName.dispose();
    _recoveryUsername.clear();
    _recoveryCode.clear();
    _recoveryNewPassword.clear();
    _recoveryConfirmation.clear();
    _recoveryDeviceName.clear();
    _recoveryUsername.dispose();
    _recoveryCode.dispose();
    _recoveryNewPassword.dispose();
    _recoveryConfirmation.dispose();
    _recoveryDeviceName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stage = app.stage;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, bounds) {
          final compact = bounds.maxWidth < 850;
          return Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-0.72, -0.7),
                      radius: 1.1,
                      colors: [
                        context.palette.isDark
                            ? const Color(0xFF193061).withValues(alpha: .34)
                            : context.palette.accentContainer.withValues(
                                alpha: .6,
                              ),
                        context.palette.background,
                      ],
                    ),
                  ),
                ),
              ),
              SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1160),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 20 : 48,
                        vertical: 28,
                      ),
                      child: compact
                          ? _compactContent(stage)
                          : Row(
                              children: [
                                Expanded(flex: 6, child: _brandPanel()),
                                const SizedBox(width: 56),
                                Expanded(
                                  flex: 5,
                                  child: _formPanel(stage, compact: false),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
              if (app.busy)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: context.palette.lime,
                    backgroundColor: context.palette.surface,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _compactContent(ClientStage stage) => SingleChildScrollView(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _brandPanel(compact: true),
        const SizedBox(height: 28),
        _formPanel(stage, compact: true),
      ],
    ),
  );

  Widget _brandPanel({bool compact = false}) => Column(
    crossAxisAlignment: compact
        ? CrossAxisAlignment.center
        : CrossAxisAlignment.start,
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Row(
        mainAxisAlignment: compact
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: context.palette.accent,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(
              Icons.terminal_rounded,
              color: context.palette.onAccent,
              size: 26,
            ),
          ),
          const SizedBox(width: 13),
          const Text(
            'Atermius',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -.4,
            ),
          ),
          const SizedBox(width: 9),
          _Pill(label: context.l10n.selfHosted),
        ],
      ),
      SizedBox(height: compact ? 22 : 56),
      Text(
        context.l10n.yourServersYourKeysYourWorkspace,
        textAlign: compact ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          fontSize: compact ? 27 : 42,
          height: 1.17,
          fontWeight: FontWeight.w600,
          letterSpacing: -1.3,
        ),
      ),
      const SizedBox(height: 20),
      Text(
        context.l10n.aPrivateSshWorkspaceThatSyncs,
        textAlign: compact ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          color: context.palette.muted,
          fontSize: 15,
          height: 1.65,
        ),
      ),
      if (!compact) ...[
        const SizedBox(height: 32),
        _FeatureRow(
          icon: Icons.vpn_key_rounded,
          title: context.l10n.endToEndEncryptedVault,
          subtitle: context.l10n.onlyYourUnlockedDevicesCanRead,
        ),
        const SizedBox(height: 18),
        _FeatureRow(
          icon: Icons.sync_rounded,
          title: context.l10n.offlineFirstSync,
          subtitle: context.l10n.encryptedOutboxKeepsEditsSafeBetween,
        ),
        const SizedBox(height: 18),
        _FeatureRow(
          icon: Icons.devices_rounded,
          title: context.l10n.approveEveryDevice,
          subtitle: context.l10n.aTrustedDeviceSignsEnvelopesFor,
        ),
      ],
      if (compact) const SizedBox(height: 4),
    ],
  );

  Widget _formPanel(ClientStage stage, {required bool compact}) {
    final heading = switch (stage) {
      ClientStage.server => context.l10n.connectToYourServer,
      ClientStage.register => context.l10n.setUpYourPrivateVault,
      ClientStage.login => context.l10n.unlockYourWorkspace,
      ClientStage.workspace => context.l10n.workspace3,
    };
    final formContent = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Text(
          stage == ClientStage.server
              ? context.l10n.enterTheUrlOfYourSelf
              : stage == ClientStage.register
              ? context.l10n.theFirstAccountCreatesItsVault
              : context.l10n.yourPasswordUnlocksTheAccountKey,
          style: TextStyle(color: context.palette.muted, height: 1.5),
        ),
        const SizedBox(height: 24),
        if (stage == ClientStage.server) _serverForm(),
        if (stage == ClientStage.login) _loginForm(),
        if (stage == ClientStage.register) _registerForm(),
        if (app.errorMessage != null) ...[
          const SizedBox(height: 16),
          _MessageBox(text: app.errorMessage!, error: true),
        ],
        if (app.noticeMessage != null && stage != ClientStage.workspace) ...[
          const SizedBox(height: 16),
          _MessageBox(text: app.noticeMessage!, error: false),
        ],
        const SizedBox(height: 18),
        const Divider(height: 1),
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.shield_outlined, color: context.palette.teal, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.secretsAreEncryptedInThisClient,
                style: TextStyle(
                  fontSize: 12,
                  color: context.palette.muted.withValues(alpha: .95),
                ),
              ),
            ),
            const AppLanguageMenuButton(),
          ],
        ),
      ],
    );
    final needsDesktopScroll = !compact;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: appDialogWidth(context, 460)),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: needsDesktopScroll
              ? SingleChildScrollView(child: formContent)
              : formContent,
        ),
      ),
    );
  }

  Widget _serverForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _server,
        keyboardType: TextInputType.url,
        decoration: InputDecoration(
          labelText: context.l10n.serverUrl,
          hintText: 'https://vault.example.com',
          prefixIcon: const Icon(Icons.dns_outlined),
        ),
        onSubmitted: (_) => _connect(),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: app.busy ? null : _connect,
        icon: const Icon(Icons.arrow_forward_rounded),
        label: Text(context.l10n.connectSecurely),
      ),
      const SizedBox(height: 12),
      Text(
        context.l10n.remoteServersRequireHttpsHttpIs,
        style: TextStyle(
          color: context.palette.muted,
          fontSize: 12,
          height: 1.5,
        ),
      ),
      if (app.pendingInstanceIdentityRecovery case final recovery?) ...[
        const SizedBox(height: 16),
        _InstanceIdentityRollbackRecovery(app: app, recovery: recovery),
      ],
    ],
  );

  Widget _loginForm() =>
      _loginChallenge == null ? _standardLoginForm() : _mfaLoginForm();

  Widget _standardLoginForm() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _text(
        _username,
        context.l10n.emailOrUsername,
        icon: Icons.alternate_email_rounded,
      ),
      const SizedBox(height: 14),
      _passwordField(_password, context.l10n.masterPassword),
      const SizedBox(height: 18),
      FilledButton.icon(
        onPressed: app.busy || app.hasPreparedFullAccountRecovery
            ? null
            : _login,
        icon: const Icon(Icons.lock_open_rounded),
        label: Text(context.l10n.signInAndUnlock),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('account_recovery_open'),
          onPressed: app.busy || app.hasPreparedFullAccountRecovery
              ? null
              : _recoverAccount,
          icon: const Icon(Icons.key_rounded, size: 17),
          label: Text(context.l10n.recoverAccountWithRecoveryCode),
        ),
      ),
      if (app.hasPreparedFullAccountRecovery)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const ValueKey('account_recovery_complete_retry'),
            onPressed: app.accountRecoveryBusy
                ? null
                : _retryRecoveryCompletion,
            icon: const Icon(Icons.restart_alt_rounded, size: 17),
            label: Text(context.l10n.retryRecoveryCompletion),
          ),
        ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          TextButton.icon(
            onPressed: app.busy ? null : _requestDevice,
            icon: const Icon(Icons.add_to_home_screen_rounded, size: 17),
            label: Text(context.l10n.addThisDevice),
          ),
          TextButton.icon(
            onPressed: app.busy ? null : _importDeviceApproval,
            icon: const Icon(Icons.qr_code_2_rounded, size: 17),
            label: Text(context.l10n.importApproval),
          ),
          TextButton(
            onPressed: () {
              app.setStage(ClientStage.server);
            },
            child: Text(context.l10n.changeServer),
          ),
        ],
      ),
      const SizedBox(height: 6),
      TextButton.icon(
        onPressed: app.busy || app.accountLifecycleBusy
            ? null
            : _cancelAccountDeletion,
        icon: const Icon(Icons.restore_rounded, size: 17),
        label: Text(context.l10n.cancelScheduledAccountDeletion),
      ),
      Text(
        context.l10n.useTheAccountNameAndMaster,
        style: TextStyle(
          color: context.palette.muted,
          fontSize: 12,
          height: 1.45,
        ),
      ),
      if (app.instance?.setupRequired != true)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              app.setStage(ClientStage.register);
            },
            child: Text(context.l10n.haveAnInstanceInvitationCreateAccount),
          ),
        ),
    ],
  );

  Widget _mfaLoginForm() {
    final challenge = _loginChallenge!;
    final recoveryAvailable = challenge.methods.contains('recovery_code');
    final usingRecovery = _useMfaRecoveryCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.verifyYourIdentity,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
        const SizedBox(height: 6),
        Text(
          usingRecovery
              ? context.l10n.mfaChallengeRecovery(challenge.expiresAt.toLocal())
              : context.l10n.mfaChallengeTotp(challenge.expiresAt.toLocal()),
          style: TextStyle(color: context.palette.muted, height: 1.45),
        ),
        const SizedBox(height: 14),
        TextField(
          key: ValueKey(usingRecovery ? 'mfa_recovery_code' : 'mfa_totp_code'),
          controller: _mfaCode,
          autofocus: true,
          obscureText: usingRecovery,
          keyboardType: usingRecovery
              ? TextInputType.text
              : TextInputType.number,
          inputFormatters: usingRecovery
              ? [
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')),
                  LengthLimitingTextInputFormatter(19),
                ]
              : [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
          maxLength: usingRecovery ? 19 : 6,
          decoration: InputDecoration(
            labelText: usingRecovery
                ? context.l10n.recoveryCode
                : context.l10n.authenticatorCode,
            counterText: '',
          ),
          onSubmitted: (_) => _submitMfaLogin(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('mfa_login_continue'),
          onPressed: app.busy ? null : _submitMfaLogin,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(context.l10n.verifyAndUnlock),
        ),
        if (recoveryAvailable)
          TextButton(
            key: const ValueKey('mfa_use_recovery_code'),
            onPressed: app.busy
                ? null
                : () => setState(() {
                    _useMfaRecoveryCode = !_useMfaRecoveryCode;
                    _mfaCode.clear();
                  }),
            child: Text(
              usingRecovery
                  ? context.l10n.useAuthenticatorCode
                  : context.l10n.useARecoveryCode,
            ),
          ),
        TextButton(
          key: const ValueKey('mfa_login_cancel'),
          onPressed: app.busy ? null : _cancelMfaLogin,
          child: Text(context.l10n.cancelSignIn),
        ),
      ],
    );
  }

  void _cancelMfaLogin() {
    setState(() {
      _loginChallenge = null;
      _useMfaRecoveryCode = false;
      _mfaCode.clear();
      _password.clear();
    });
  }

  Future<void> _submitMfaLogin() async {
    final challenge = _loginChallenge;
    if (challenge == null || app.busy) return;
    var code = _mfaCode.text.trim();
    final useRecoveryCode = _useMfaRecoveryCode;
    if (useRecoveryCode) {
      code = code.toUpperCase();
      if (code.isEmpty || !challenge.methods.contains('recovery_code')) return;
    } else if (!RegExp(r'^\d{6}$').hasMatch(code) ||
        !challenge.methods.contains('totp')) {
      return;
    }
    _mfaCode.clear();
    try {
      await app.completeMfaLogin(
        username: _username.text.trim(),
        password: _password.text,
        challenge: challenge,
        code: code,
        useRecoveryCode: useRecoveryCode,
      );
      if (mounted) {
        setState(() {
          _loginChallenge = null;
          _useMfaRecoveryCode = false;
          _password.clear();
          _mfaCode.clear();
        });
      }
    } catch (_) {
      // AppController reports the safe inline login error; rebuild this form
      // because it does not otherwise listen to the controller.
      if (mounted) setState(() {});
    } finally {
      code = '';
    }
  }

  Widget _registerForm() {
    final isBootstrap = app.instance?.setupRequired ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // credential-visibility: instance default is admin-visible.
        CredentialVisibilityRegistrationNotice(instance: app.instance),
        _text(
          _username,
          isBootstrap
              ? context.l10n.ownerEmail
              : context.l10n.emailOnTheInvitation,
          icon: Icons.alternate_email_rounded,
        ),
        const SizedBox(height: 12),
        _passwordField(_password, context.l10n.masterPassword12Characters),
        const SizedBox(height: 12),
        _passwordField(_confirmPassword, context.l10n.confirmMasterPassword),
        const SizedBox(height: 12),
        _text(
          _bootstrap,
          isBootstrap
              ? 'One-time bootstrap token'
              : context.l10n.instanceInvitationToken,
          icon: Icons.key_rounded,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _text(
                _deviceName,
                context.l10n.deviceName,
                icon: Icons.devices_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _text(
                _vaultName,
                context.l10n.firstVault,
                icon: Icons.folder_outlined,
              ),
            ),
          ],
        ),
        const SizedBox(height: 17),
        FilledButton.icon(
          onPressed: app.busy ? null : _register,
          icon: const Icon(Icons.verified_user_outlined),
          label: Text(
            isBootstrap
                ? context.l10n.createOwnerAccount
                : context.l10n.createInvitedAccount,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          isBootstrap
              ? context.l10n.theBootstrapTokenIsOneUse
              : context.l10n.thisOneUseInvitationIsBound,
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _text(
    TextEditingController controller,
    String label, {
    required IconData icon,
  }) => TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
  );

  Widget _passwordField(TextEditingController controller, String label) =>
      TextField(
        controller: controller,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.password_rounded),
          suffixIcon: IconButton(
            onPressed: () => setState(() => _obscure = !_obscure),
            icon: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          ),
        ),
      );

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    try {
      await app.configureServer(_server.text);
    } catch (_) {
      if (mounted) {
        _showError(app.errorMessage ?? context.l10n.couldntConnectToTheServer);
      }
    }
  }

  Future<void> _login() async {
    FocusScope.of(context).unfocus();
    try {
      final challenge = await app.login(
        username: _username.text,
        password: _password.text,
      );
      if (challenge != null && mounted) {
        setState(() {
          _loginChallenge = challenge;
          _useMfaRecoveryCode = false;
          _mfaCode.clear();
        });
      } else if (mounted) {
        _password.clear();
      }
    } catch (_) {
      if (mounted) _showError(app.errorMessage ?? context.l10n.signInFailed);
    }
  }

  Future<void> _recoverAccount() async {
    _recoveryUsername.text = _username.text;
    _recoveryCode.clear();
    _recoveryNewPassword.clear();
    _recoveryConfirmation.clear();
    _recoveryDeviceName.text = context.l10n.recoveredDevice;
    _RecoveryInput? input;
    try {
      input = await showAppDialog<_RecoveryInput>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.l10n.recoverAccount),
          content: SizedBox(
            width: appDialogWidth(context, 470),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.l10n.useTheSaved256BitRecovery),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _recoveryUsername,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: context.l10n.accountName,
                    ),
                  ),
                  TextField(
                    controller: _recoveryCode,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: context.l10n.recoveryCode,
                    ),
                  ),
                  TextField(
                    controller: _recoveryNewPassword,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: context.l10n.newMasterPassword12Characters,
                    ),
                  ),
                  TextField(
                    controller: _recoveryConfirmation,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: context.l10n.confirmNewMasterPassword,
                    ),
                  ),
                  TextField(
                    controller: _recoveryDeviceName,
                    decoration: InputDecoration(
                      labelText: context.l10n.newDeviceName,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                  _RecoveryInput(
                    username: _recoveryUsername.text,
                    recoveryCode: _recoveryCode.text,
                    newPassword: _recoveryNewPassword.text,
                    confirmationPassword: _recoveryConfirmation.text,
                    deviceName: _recoveryDeviceName.text,
                  ),
                );
              },
              child: Text(context.l10n.verifyRecoveryCode),
            ),
          ],
        ),
      );
    } finally {
      _recoveryUsername.clear();
      _recoveryCode.clear();
      _recoveryNewPassword.clear();
      _recoveryConfirmation.clear();
      _recoveryDeviceName.clear();
    }
    if (input == null || !mounted) return;
    if (input.username.trim().isEmpty ||
        input.recoveryCode.isEmpty ||
        input.newPassword.length < 12 ||
        input.newPassword != input.confirmationPassword) {
      _showError(context.l10n.enterAValidRecoveryCodeAnd);
      return;
    }
    setState(() {});
    try {
      final prepared = await app.prepareFullAccountRecovery(
        username: input.username,
        recoveryCode: input.recoveryCode,
        newPassword: input.newPassword,
        confirmationPassword: input.confirmationPassword,
        deviceName: input.deviceName,
      );
      if (!mounted) {
        await app.cancelPreparedAccountRecovery();
        return;
      }
      final stored = await _confirmNewRecoveryCode(prepared.recoveryCode);
      if (!stored) {
        await app.cancelPreparedAccountRecovery();
        if (mounted) setState(() {});
        _showError(currentL10n.recoveryWasCancelledNoAccountChanges);
        return;
      }
      await app.completePreparedAccountRecovery();
      _username.text = input.username.trim();
      _password.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.accountRecoveredSignInWithYour)),
        );
      }
    } catch (error) {
      await app.cancelPreparedAccountRecovery();
      if (mounted) {
        setState(() {});
        _showError(app.errorMessage ?? error.toString());
      }
    }
  }

  Future<void> _retryRecoveryCompletion() async {
    try {
      await app.completePreparedAccountRecovery();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.accountRecoveredSignInWithThe)),
        );
      }
    } catch (error) {
      if (mounted) _showError(app.errorMessage ?? error.toString());
    }
  }

  Future<bool> _confirmNewRecoveryCode(String code) async {
    var confirmed = false;
    // Stable outcome (null = none); the label is formatted at render time so
    // a runtime language switch never changes the success/failure meaning.
    bool? copyFeedback;
    return await showAppDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              title: Text(context.l10n.storeTheNewRecoveryCode),
              content: SizedBox(
                width: appDialogWidth(context, 440),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.thisReplacesTheOldCodeStore),
                    const SizedBox(height: 14),
                    Semantics(
                      key: const ValueKey('full_recovery_new_code_semantics'),
                      label: context.l10n.newAccountRecoveryCodeCode(code),
                      excludeSemantics: true,
                      child: SelectableText(
                        code,
                        key: const ValueKey('full_recovery_new_code'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 16,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () async {
                          setDialogState(() => copyFeedback = null);
                          try {
                            await Clipboard.setData(ClipboardData(text: code));
                            if (dialogContext.mounted) {
                              setDialogState(() => copyFeedback = true);
                            }
                          } catch (_) {
                            if (dialogContext.mounted) {
                              setDialogState(() => copyFeedback = false);
                            }
                          }
                        },
                        icon: const Icon(Icons.copy_rounded),
                        label: Text(context.l10n.copyCode),
                      ),
                    ),
                    if (copyFeedback != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, right: 8),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            copyFeedback!
                                ? dialogContext.l10n.recoveryCodeCopiedFeedback
                                : dialogContext
                                      .l10n
                                      .recoveryCodeCopyFailedFeedback,
                            style: Theme.of(dialogContext).textTheme.bodySmall
                                ?.copyWith(
                                  color: copyFeedback!
                                      ? context.palette.teal
                                      : Theme.of(dialogContext)
                                            .colorScheme
                                            .error,
                                ),
                          ),
                        ),
                      ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: confirmed,
                      onChanged: (value) =>
                          setDialogState(() => confirmed = value == true),
                      title: Text(context.l10n.iStoredThisCodeSecurely),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(context.l10n.cancelRecovery),
                ),
                FilledButton(
                  onPressed: confirmed
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  child: Text(context.l10n.commitRecovery),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<void> _cancelAccountDeletion() async {
    FocusScope.of(context).unfocus();
    try {
      await app.cancelAccountDeletion(
        username: _username.text,
        password: _password.text,
      );
      _password.clear();
    } catch (_) {
      if (mounted) {
        _showError(
          app.errorMessage ?? context.l10n.couldntCancelAccountDeletion,
        );
      }
    }
  }

  Future<void> _register() async {
    if (_password.text != _confirmPassword.text) {
      _showError(context.l10n.theMasterPasswordsDontMatch);
      return;
    }
    FocusScope.of(context).unfocus();
    try {
      await app.register(
        username: _username.text,
        password: _password.text,
        bootstrapToken: app.instance?.setupRequired == true
            ? _bootstrap.text
            : null,
        instanceInvitationToken: app.instance?.setupRequired == true
            ? null
            : _bootstrap.text,
        deviceName: _deviceName.text,
        vaultName: _vaultName.text,
      );
    } catch (_) {
      if (mounted) {
        _showError(app.errorMessage ?? context.l10n.registrationFailed);
      }
    }
  }

  Future<void> _requestDevice() async {
    final email = TextEditingController(text: _username.text);
    final name = TextEditingController(text: 'Atermius Web');
    String? request;
    await showAppDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.l10n.requestThisDevice),
          content: SizedBox(
            width: appDialogWidth(context, 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.l10n.aDeviceKeyPairIsGenerated),
                const SizedBox(height: 16),
                TextField(
                  controller: email,
                  decoration: InputDecoration(
                    labelText: context.l10n.accountEmail,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: context.l10n.deviceName,
                  ),
                ),
                if (request != null) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 180,
                    child: TextField(
                      controller: TextEditingController(text: request),
                      readOnly: true,
                      maxLines: 8,
                      decoration: InputDecoration(
                        labelText: context.l10n.copyThisEnrollmentJson,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (request != null)
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: request!));
                  if (context.mounted) {
                    _showError(context.l10n.requestJsonCopied);
                  }
                },
                icon: const Icon(Icons.copy_rounded),
                label: Text(context.l10n.copy),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.close),
            ),
            FilledButton(
              onPressed: request == null
                  ? () async {
                      try {
                        final value = await app.createDeviceEnrollmentRequest(
                          username: email.text,
                          name: name.text,
                        );
                        setDialogState(() => request = value);
                      } catch (error) {
                        if (context.mounted)
                          _showError(app.friendlyError(error));
                      }
                    }
                  : null,
              child: Text(context.l10n.generateRequest),
            ),
          ],
        ),
      ),
    );
    email.dispose();
    name.dispose();
  }

  Future<void> _importDeviceApproval() async {
    final controller = TextEditingController();
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.importApprovedDevice),
        content: SizedBox(
          width: appDialogWidth(context, 500),
          child: TextField(
            controller: controller,
            minLines: 6,
            maxLines: 12,
            decoration: InputDecoration(
              labelText: context.l10n.pasteApprovalJson,
              hintText: '{ "format": "atermius-device-approval-v1", … }',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await app.importDeviceApproval(controller.text);
                if (context.mounted) Navigator.pop(context);
              } catch (error) {
                if (context.mounted) _showError(app.friendlyError(error));
              }
            },
            child: Text(context.l10n.importDeviceKeys),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  void _showError(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _InstanceIdentityRollbackRecovery extends StatefulWidget {
  const _InstanceIdentityRollbackRecovery({
    required this.app,
    required this.recovery,
  });

  final AppController app;
  final PendingInstanceIdentityRecovery recovery;

  @override
  State<_InstanceIdentityRollbackRecovery> createState() =>
      _InstanceIdentityRollbackRecoveryState();
}

class _InstanceIdentityRollbackRecoveryState
    extends State<_InstanceIdentityRollbackRecovery> {
  final _fingerprint = TextEditingController();

  @override
  void didUpdateWidget(covariant _InstanceIdentityRollbackRecovery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recovery.candidateFingerprint !=
        widget.recovery.candidateFingerprint) {
      _fingerprint.clear();
    }
  }

  @override
  void dispose() {
    _fingerprint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recovery = widget.recovery;
    final canConfirm =
        !widget.app.busy && _fingerprint.text == recovery.candidateFingerprint;
    return Card(
      color: context.palette.warningContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.restoredServerIdentityNeedsConfirmation,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            Text(
              context.l10n.theServerReturnedADifferentSigning,
              style: const TextStyle(fontSize: 12, height: 1.45),
            ),
            const SizedBox(height: 12),
            _identityDetail(context.l10n.serverUrl, recovery.baseUrl),
            _identityDetail(
              context.l10n.instanceId,
              recovery.candidate.instanceId,
            ),
            _identityDetail(
              'Server-space ID',
              recovery.candidate.serverSpaceId,
            ),
            const SizedBox(height: 9),
            Text(
              context.l10n.previouslyTrustedFingerprintSha256,
              style: TextStyle(color: context.palette.muted, fontSize: 11),
            ),
            SelectableText(
              recovery.pinnedFingerprint,
              semanticsLabel: context.l10n
                  .previouslyTrustedFingerprintSha256Pinnedfingerprint(
                    recovery.pinnedFingerprint,
                  ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.fingerprintReturnedByThisServerSha,
              style: TextStyle(color: context.palette.muted, fontSize: 11),
            ),
            SelectableText(
              recovery.candidateFingerprint,
              semanticsLabel: context.l10n.fingerprintReturnedByThisServerSha2(
                recovery.candidateFingerprint,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _fingerprint,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: context.l10n.typeTheCandidateFingerprintExactly,
                hintText: 'SHA256:…',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: widget.app.busy
                      ? null
                      : widget.app.cancelPendingInstanceIdentityRecovery,
                  child: Text(context.l10n.cancel2),
                ),
                FilledButton.icon(
                  key: const ValueKey('confirm_instance_identity_recovery'),
                  onPressed: canConfirm ? _confirm : null,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: Text(context.l10n.confirmFingerprintAndContinue),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _identityDetail(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 105,
          child: Text(
            label,
            style: TextStyle(color: context.palette.muted, fontSize: 11),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            semanticsLabel: '$label: $value',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    ),
  );

  Future<void> _confirm() async {
    try {
      await widget.app.confirmPendingInstanceIdentityRecovery(
        candidateFingerprint: _fingerprint.text,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.app.friendlyError(error))),
        );
      }
    }
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: context.palette.lime.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(icon, size: 20, color: context.palette.lime),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
          ],
        ),
      ),
    ],
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: context.palette.lime.withValues(alpha: .11),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: context.palette.lime.withValues(alpha: .25)),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 9,
        letterSpacing: .9,
        color: context.palette.lime,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.text, required this.error});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? context.palette.red : context.palette.teal;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        border: Border.all(color: color.withValues(alpha: .26)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline : Icons.info_outline,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, height: 1.4, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
