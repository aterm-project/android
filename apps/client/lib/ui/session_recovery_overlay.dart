import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../terminal/session_recovery.dart';

class SessionRecoveryOverlay extends StatelessWidget {
  const SessionRecoveryOverlay({
    super.key,
    required this.recovery,
    required this.child,
  });
  final SessionRecovery? recovery;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final model = recovery;
    if (model == null) return child;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (model.interrupted)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.l10n.connectionLost,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          key: const ValueKey('session_restore_connection'),
                          onPressed: model.busy || !model.available
                              ? null
                              : () => model.retry(),
                          icon: model.busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                          label: Text(
                            model.busy
                                ? context.l10n.terminalStateReconnecting
                                : context.l10n.restoreConnection,
                          ),
                        ),
                        if (model.automaticEnabled)
                          Text(
                            context.l10n.reconnectEveryFiveSeconds,
                            textAlign: TextAlign.center,
                          ),
                      ],
                    ),
                  ),
                )),
              ),
            ),
        ],
      ),
    );
  }
}
