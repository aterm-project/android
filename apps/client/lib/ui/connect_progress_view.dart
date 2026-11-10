import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../terminal/connect_progress.dart';
import 'app_theme.dart';

/// Wraps a session pane with its initial-connection surface. While an attempt
/// is loading, failed or stopped, an opaque panel with the real stage and the
/// three controls (stop loading / retry / close) covers [child]; [child] stays
/// mounted at the same position so desktop/terminal state is not rebuilt when
/// the attempt succeeds.
class ConnectProgressView extends StatelessWidget {
  const ConnectProgressView({
    super.key,
    required this.progress,
    required this.title,
    required this.child,
    required this.onStop,
    required this.onRetry,
    required this.onClose,
    this.detail,
    this.canRetry,
  });

  final ConnectProgress progress;

  /// Host/console display name.
  final String title;

  /// Optional non-secret endpoint line, for example `SSH · user@host:22`.
  final String? detail;
  final Widget child;
  final VoidCallback onStop, onRetry, onClose;

  /// Evaluated whenever the surface rebuilds. False when the owner's
  /// account/Vault/profile scope no longer matches the tab, so a retry would
  /// need authority the tab does not have.
  final bool Function()? canRetry;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: progress,
    child: child,
    builder: (context, child) {
      final visible = progress.isVisible;
      return Stack(
        fit: StackFit.expand,
        children: [
          IgnorePointer(
            ignoring: visible,
            child: ExcludeSemantics(excluding: visible, child: child),
          ),
          if (visible)
            ConnectProgressPane(
              progress: progress,
              title: title,
              detail: detail,
              canRetry: canRetry?.call() ?? true,
              onStop: onStop,
              onRetry: onRetry,
              onClose: onClose,
            ),
        ],
      );
    },
  );
}

class ConnectProgressPane extends StatelessWidget {
  const ConnectProgressPane({
    super.key,
    required this.progress,
    required this.title,
    required this.onStop,
    required this.onRetry,
    required this.onClose,
    this.detail,
    this.canRetry = true,
  });

  final ConnectProgress progress;
  final String title;
  final String? detail;
  final bool canRetry;
  final VoidCallback onStop, onRetry, onClose;

  static String stageLabel(AppLocalizations l10n, ConnectStage stage) =>
      switch (stage) {
        ConnectStage.preparing => l10n.connectProgressStagePreparing,
        ConnectStage.connecting => l10n.connectProgressStageConnecting,
        ConnectStage.verifyingHost => l10n.connectProgressStageVerifyingHost,
        ConnectStage.awaitingUser => l10n.connectProgressStageAwaitingUser,
        ConnectStage.authenticating => l10n.connectProgressStageAuthenticating,
        ConnectStage.startingSession =>
          l10n.connectProgressStageStartingSession,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final phase = progress.phase;
    final loading = phase == ConnectPhase.loading;
    final failed = phase == ConnectPhase.failed;
    final heading = switch (phase) {
      ConnectPhase.failed => l10n.connectProgressFailedTo(title),
      ConnectPhase.cancelled => l10n.connectProgressStoppedTitle,
      _ => l10n.connectProgressConnectingTo(title),
    };
    final message = loading
        ? stageLabel(l10n, progress.stage)
        : failed
        ? (progress.error ?? l10n.terminalStateFailed)
        : l10n.connectProgressStoppedDetail;
    return Material(
      key: const ValueKey('connect_progress_pane'),
      color: palette.surface,
      child: LayoutBuilder(
        builder: (context, constraints) => _content(
          context,
          l10n: l10n,
          palette: palette,
          heading: heading,
          message: message,
          loading: loading,
          failed: failed,
          // Split panes and phone sidebars can leave very little width: the
          // controls become icon buttons (same keys, tooltips) instead of
          // overflowing.
          compact: constraints.maxWidth < 260 || constraints.maxHeight < 220,
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context, {
    required AppLocalizations l10n,
    required AppPalette palette,
    required String heading,
    required String message,
    required bool loading,
    required bool failed,
    required bool compact,
  }) {
    final stop = loading ? onStop : null;
    final retry = !loading && canRetry ? onRetry : null;
    final controls = compact
        ? <Widget>[
            IconButton.outlined(
              key: const ValueKey('connect_progress_stop'),
              tooltip: l10n.connectProgressStop,
              onPressed: stop,
              icon: const Icon(Icons.stop_rounded),
            ),
            IconButton.filled(
              key: const ValueKey('connect_progress_retry'),
              tooltip: l10n.connectProgressRetry,
              onPressed: retry,
              icon: const Icon(Icons.refresh_rounded),
            ),
            IconButton(
              key: const ValueKey('connect_progress_close'),
              tooltip: l10n.connectProgressClose,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
          ]
        : <Widget>[
            OutlinedButton.icon(
              key: const ValueKey('connect_progress_stop'),
              onPressed: stop,
              icon: const Icon(Icons.stop_rounded, size: 18),
              label: Text(l10n.connectProgressStop),
            ),
            FilledButton.icon(
              key: const ValueKey('connect_progress_retry'),
              onPressed: retry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(l10n.connectProgressRetry),
            ),
            TextButton.icon(
              key: const ValueKey('connect_progress_close'),
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
              label: Text(l10n.connectProgressClose),
            ),
          ];
    final info = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 30,
          height: 30,
          child: loading
              ? const CircularProgressIndicator(strokeWidth: 2.5)
              : Icon(
                  failed
                      ? Icons.error_outline_rounded
                      : Icons.stop_circle_outlined,
                  size: 30,
                  color: failed ? palette.red : palette.muted,
                ),
        ),
        const SizedBox(height: 12),
        Text(
          heading,
          key: const ValueKey('connect_progress_title'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        if (detail != null && detail!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            detail!,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.muted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        Semantics(
          liveRegion: true,
          child: Text(
            message,
            key: ValueKey(
              loading
                  ? 'connect_progress_stage'
                  : failed
                  ? 'connect_progress_error'
                  : 'connect_progress_stopped',
            ),
            textAlign: TextAlign.center,
            style: TextStyle(color: failed ? palette.red : null, height: 1.4),
          ),
        ),
        if (!loading && !canRetry) ...[
          const SizedBox(height: 8),
          Text(
            l10n.connectProgressRetryUnavailable,
            key: const ValueKey('connect_progress_retry_unavailable'),
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted, fontSize: 12),
          ),
        ],
      ],
    );
    // The text scrolls when the pane is short; the controls stay visible
    // directly below it.
    return Padding(
      padding: EdgeInsets.all(compact ? 8 : 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: SingleChildScrollView(child: info)),
              SizedBox(height: compact ? 8 : 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: compact ? 4 : 8,
                runSpacing: compact ? 4 : 8,
                children: controls,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Non-secret one-line endpoint for the progress surface, e.g.
/// `SSH · deploy@example.test:22`. Passwords and keys are never included.
String connectProgressDetail(HostRecord host) {
  final user = host.protocol == HostProtocol.ssh && host.username.isNotEmpty
      ? '${host.username}@'
      : '';
  return '${host.protocol.label} · $user${host.endpoint}';
}
