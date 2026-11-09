import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'settings_scaffold.dart';

/// Non-secret snapshot of the sync controls shown in account settings.
@immutable
class SyncSettingsSummary {
  const SyncSettingsSummary({
    required this.scopeKey,
    required this.preference,
    required this.automaticEnabled,
    required this.saving,
    required this.saveFailed,
    required this.syncing,
    required this.syncNowRunning,
    required this.status,
    required this.pendingCount,
    required this.lastSuccessfulSyncAt,
  });

  factory SyncSettingsSummary.fromController(AppController app) =>
      SyncSettingsSummary(
        scopeKey:
            '${app.serverUrl}\u0000${app.currentAccountId}\u0000'
            '${app.identity?.deviceId}\u0000${app.activeVault?.id}\u0000'
            '${app.vaultSelectionGeneration}',
        preference: app.automaticSyncPreference,
        automaticEnabled: app.automaticSyncEnabled,
        saving: app.automaticSyncSaving,
        saveFailed: app.automaticSyncSaveFailed,
        syncing: app.syncing,
        syncNowRunning: app.syncNowRunning,
        status: app.syncStatus,
        pendingCount: app.pendingCount,
        lastSuccessfulSyncAt: app.lastSuccessfulSyncAt,
      );

  /// Identifies the account/device/Vault the controls act on. A manual sync
  /// result is only shown while this stays the same.
  final String scopeKey;
  final AutomaticSyncPreferenceState preference;
  final bool automaticEnabled;
  final bool saving;
  final bool saveFailed;
  final bool syncing;
  final bool syncNowRunning;
  final String status;
  final int pendingCount;
  final DateTime? lastSuccessfulSyncAt;
}

/// Sync card for a signed-in account workspace.
class SyncSettingsPanel extends StatelessWidget {
  const SyncSettingsPanel({required this.app, super.key});

  final AppController app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => SyncSettingsView(
      summary: SyncSettingsSummary.fromController(app),
      onSetAutomatic: app.setAutomaticSyncEnabled,
      onRetryPreference: app.retryAutomaticSyncPreference,
      onSyncNow: app.syncNow,
      describeError: app.friendlyError,
    ),
  );
}

class SyncSettingsView extends StatefulWidget {
  const SyncSettingsView({
    required this.summary,
    required this.onSetAutomatic,
    required this.onRetryPreference,
    required this.onSyncNow,
    required this.describeError,
    super.key,
  });

  final SyncSettingsSummary summary;
  final Future<Object?> Function(bool enabled) onSetAutomatic;
  final Future<void> Function() onRetryPreference;
  final Future<SyncNowResult> Function() onSyncNow;
  final String Function(Object error) describeError;

  @override
  State<SyncSettingsView> createState() => _SyncSettingsViewState();
}

class _SyncSettingsViewState extends State<SyncSettingsView> {
  SyncNowResult? _result;
  String? _resultScope;
  bool _requested = false;

  @override
  void didUpdateWidget(SyncSettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.summary.scopeKey != widget.summary.scopeKey) {
      _result = null;
      _resultScope = null;
    }
  }

  Future<void> _syncNow() async {
    if (_requested || widget.summary.syncNowRunning) return;
    final scope = widget.summary.scopeKey;
    setState(() {
      _requested = true;
      _result = null;
    });
    SyncNowResult result;
    try {
      result = await widget.onSyncNow();
    } on Object catch (error) {
      result = SyncNowResult(SyncNowOutcome.notCompleted, error: error);
    }
    if (!mounted) return;
    setState(() {
      _requested = false;
      // A result for a previous account/Vault is never shown for the new one.
      if (result.outcome != SyncNowOutcome.superseded &&
          widget.summary.scopeKey == scope) {
        _result = result;
        _resultScope = scope;
      }
    });
  }

  String _statusLabel(String status) {
    final l10n = context.l10n;
    return switch (status) {
      'idle' => l10n.idle,
      'pending' => l10n.pending,
      'syncing' => l10n.syncing,
      'deletion_pending' => l10n.vaultDeletionPendingReadOnly,
      'read_only' => l10n.readOnly,
      'snapshot_recovering' => l10n.rebuildingSnapshot,
      'retry_wait' => l10n.retryQueued,
      'resnapshot_required' => l10n.snapshotNeeded,
      'snapshot_too_large' => l10n.snapshotExceedsClientLimit,
      'epoch_update_required' => l10n.keyUpdateNeeded,
      'revoked' => l10n.deviceRevoked3,
      'auth_required' => l10n.signInNeeded,
      'offline' => l10n.offline,
      _ => l10n.syncError,
    };
  }

  String? _resultMessage(SyncNowResult result) {
    final l10n = context.l10n;
    final summary = widget.summary;
    return switch (result.outcome) {
      SyncNowOutcome.completed => l10n.syncSettingsResultCompleted,
      SyncNowOutcome.completedWithPending => l10n.syncSettingsResultPending(
        summary.pendingCount,
      ),
      SyncNowOutcome.notCompleted =>
        result.error == null
            ? l10n.syncSettingsResultNotCompleted(_statusLabel(summary.status))
            : l10n.syncSettingsResultFailed(
                widget.describeError(result.error!),
              ),
      SyncNowOutcome.signInRequired => l10n.syncSettingsSignInRequired,
      SyncNowOutcome.superseded => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final summary = widget.summary;
    final loading = summary.preference == AutomaticSyncPreferenceState.loading;
    final readFailed =
        summary.preference == AutomaticSyncPreferenceState.readFailed;
    final automaticOn =
        summary.preference == AutomaticSyncPreferenceState.ready &&
        summary.automaticEnabled;
    final running = _requested || summary.syncNowRunning;
    final busy = running || summary.syncing;
    final result = _resultScope == summary.scopeKey ? _result : null;
    final resultMessage = result == null || running
        ? null
        : _resultMessage(result);
    final resultIsError =
        result != null &&
        (result.outcome == SyncNowOutcome.notCompleted ||
            result.outcome == SyncNowOutcome.signInRequired);
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    String automaticDescription;
    if (loading) {
      automaticDescription = l10n.syncSettingsPreferenceLoading;
    } else if (readFailed) {
      automaticDescription = l10n.syncSettingsPreferenceReadFailed;
    } else if (automaticOn) {
      automaticDescription = l10n.syncSettingsAutomaticOnDescription;
    } else {
      automaticDescription = l10n.syncSettingsAutomaticOffDescription;
    }

    return SettingsCard(
      child: Column(
        key: const ValueKey('sync_settings_card'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.syncSettingsTitle, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(l10n.syncSettingsDeviceOnly, style: secondary),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const ValueKey('sync_settings_automatic'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.syncSettingsAutomaticTitle),
            subtitle: Text(
              automaticDescription,
              key: const ValueKey('sync_settings_automatic_description'),
            ),
            value: automaticOn,
            onChanged: loading
                ? null
                : (value) => unawaited(widget.onSetAutomatic(value)),
          ),
          if (summary.saving)
            Text(l10n.syncSettingsPreferenceSaving, style: secondary),
          if (readFailed || summary.saveFailed)
            _SyncNotice(
              key: const ValueKey('sync_settings_preference_error'),
              message: readFailed
                  ? l10n.syncSettingsPreferenceReadFailedShort
                  : l10n.syncSettingsPreferenceSaveFailed,
              actionLabel: l10n.retry,
              onAction: summary.saving
                  ? null
                  : () => unawaited(widget.onRetryPreference()),
            ),
          const SizedBox(height: 12),
          _SyncDetailRow(
            label: l10n.syncSettingsStatus,
            value: busy ? l10n.syncing : _statusLabel(summary.status),
            valueKey: const ValueKey('sync_settings_status'),
          ),
          _SyncDetailRow(
            label: l10n.syncSettingsWaitingToUpload,
            value: '${summary.pendingCount}',
            valueKey: const ValueKey('sync_settings_pending'),
          ),
          _SyncDetailRow(
            label: l10n.lastSuccessfulSync,
            value: summary.lastSuccessfulSyncAt == null
                ? l10n.syncSettingsNever
                : DateFormat.yMMMd().add_jm().format(
                    summary.lastSuccessfulSyncAt!.toLocal(),
                  ),
          ),
          if (!automaticOn && summary.pendingCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              l10n.syncSettingsQueuedWhileOff(summary.pendingCount),
              key: const ValueKey('sync_settings_queued_while_off'),
              style: secondary,
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FilledButton.tonalIcon(
              key: const ValueKey('sync_settings_sync_now'),
              onPressed: running ? null : _syncNow,
              icon: const Icon(Icons.sync),
              label: Text(
                running
                    ? l10n.syncSettingsSyncingNow
                    : l10n.syncSettingsSyncNow,
              ),
            ),
          ),
          if (running) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (resultMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              resultMessage,
              key: const ValueKey('sync_settings_result'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: resultIsError ? scheme.error : scheme.onSurface,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SyncNotice extends StatelessWidget {
  const _SyncNotice({
    required this.message,
    required this.actionLabel,
    required this.onAction,
    super.key,
  });

  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

class _SyncDetailRow extends StatelessWidget {
  const _SyncDetailRow({
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              key: valueKey,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
