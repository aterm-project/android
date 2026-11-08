import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

class LockedWorkspaceScreen extends StatefulWidget {
  const LockedWorkspaceScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<LockedWorkspaceScreen> createState() => _LockedWorkspaceScreenState();
}

class _LockedWorkspaceScreenState extends State<LockedWorkspaceScreen> {
  final _password = TextEditingController();

  AppController get app => widget.controller;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    try {
      await app.unlockLockedWorkspace(password: _password.text);
      _password.clear();
    } catch (_) {
      // AppController retains the safe, user-facing error.
    }
  }

  Future<void> _receiveNow() async {
    try {
      await app.synchronize(background: false, suppressSuccessNotice: true);
    } catch (_) {
      // AppController retains the safe, user-facing error.
    }
  }

  Future<void> _signOut() async {
    try {
      await app.logout();
    } catch (_) {
      // AppController clears local credentials even if the server is offline.
    }
  }

  String get _statusLabel => switch (app.syncStatus) {
    'locked_receiving' => context.l10n.receivingSignedEncryptedChanges,
    'locked_ready' => context.l10n.encryptedChangesAreUpToDate,
    'locked_no_vault' => context.l10n.noVaultIsCurrentlyAvailable,
    'unlock_required' => context.l10n.unlockToVerifyTheLatestVault,
    'auth_required' => context.l10n.accountSessionExpiredSignInAgain,
    'revoked' => context.l10n.thisDeviceOrVaultAccessWas,
    'retry_wait' => context.l10n.encryptedSyncWillRetryWhenThe,
    _ => app.syncStatus,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 24).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: appDialogWidth(context, 460)),
                  child: Card(
                    margin: const EdgeInsets.all(24),
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Icon(Icons.lock_outline, size: 38),
                          const SizedBox(height: 18),
                          Text(
                            context.l10n.workspaceLocked,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            context.l10n.yourAccountStaysSignedInWhile,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 18),
                          Semantics(
                            container: true,
                            liveRegion: true,
                            label: _statusLabel,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (app.syncStatus == 'locked_receiving') ...[
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                ],
                                Flexible(child: Text(_statusLabel)),
                              ],
                            ),
                          ),
                          if (app.errorMessage != null) ...[
                            const SizedBox(height: 14),
                            Text(
                              app.errorMessage!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ],
                          const SizedBox(height: 22),
                          TextField(
                            controller: _password,
                            obscureText: true,
                            enabled: !app.busy,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _unlock(),
                            decoration: InputDecoration(
                              labelText: context.l10n.accountPassword,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            onPressed: app.busy ? null : _unlock,
                            icon: const Icon(Icons.lock_open),
                            label: Text(context.l10n.unlockWorkspace),
                          ),
                          if (app.activeVault != null &&
                              app.syncStatus != 'unlock_required' &&
                              app.syncStatus != 'revoked') ...[
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: app.syncing ? null : _receiveNow,
                              icon: const Icon(Icons.sync),
                              label: Text(
                                context.l10n.receiveEncryptedChangesNow,
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: app.busy ? null : _signOut,
                            icon: const Icon(Icons.logout),
                            label: Text(context.l10n.signOut),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
