import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../app_controller.dart';
import '../../cloud/cloud_access_service.dart';
import '../../l10n/l10n.dart';
import '../app_theme.dart';

/// Maps stable error codes (never translated strings) to localized text.
String cloudAccessErrorText(BuildContext context, Object error) {
  final l10n = context.l10n;
  final code = switch (error) {
    CloudAccessException(:final code) => code,
    OperationScopeEndedException(:final serverCommitted) =>
      serverCommitted ? 'scope_ended_committed' : 'scope_changed',
    ApiException(:final code) => code,
    _ => '',
  };
  return switch (code) {
    'links_unavailable' ||
    'GATEWAY_DISABLED' => l10n.cloudAccessErrorLinksUnavailable,
    'protocol_unavailable' ||
    'HOST_SHARE_UNSUPPORTED' => l10n.cloudAccessErrorProtocolUnavailable,
    'owner_required' ||
    'VAULT_ROLE_REQUIRED' => l10n.cloudAccessErrorOwnerRequired,
    'jump_host' => l10n.cloudAccessErrorJumpHost,
    'port_forward' => l10n.cloudAccessErrorPortForward,
    'host_key_required' ||
    'HOST_KEY_REQUIRED' => l10n.cloudAccessErrorHostKeyRequired,
    'certificate_required' => l10n.cloudAccessErrorCertificateRequired,
    'login_required' => l10n.cloudAccessErrorLoginRequired,
    'host_not_synced' ||
    'HOST_REVISION_CHANGED' ||
    'CAPSULE_STALE' => l10n.cloudAccessErrorHostChanged,
    'share_plan_blocked' => l10n.cloudAccessErrorPlanBlocked,
    'scope_changed' ||
    'selection_superseded' ||
    'signed_out' ||
    'no_vault' => l10n.cloudAccessErrorScopeChanged,
    'scope_ended_committed' => l10n.cloudAccessErrorScopeEndedCommitted,
    'sharing_vault_not_synced' => l10n.cloudAccessErrorNotSynced,
    'TARGET_DENIED' => l10n.cloudAccessErrorTargetDenied,
    'SLUG_TAKEN' => l10n.cloudAccessErrorSlugTaken,
    'SLUG_INVALID' => l10n.cloudAccessErrorSlugInvalid,
    'SHARE_LINK_LIMIT' => l10n.cloudAccessErrorTooManyLinks,
    'SHARE_LINK_INVALID' => l10n.cloudAccessErrorInvalidOptions,
    'ORG_ROLE_REQUIRED' => l10n.cloudAccessErrorOrgRoleRequired,
    'ORG_CREATION_RESTRICTED' => l10n.cloudAccessErrorOrgCreationRestricted,
    'ORG_LAST_OWNER' => l10n.cloudAccessErrorLastOwner,
    'ORG_INVITATION_UNAVAILABLE' => l10n.cloudAccessErrorInvitationUnavailable,
    'ACCOUNT_NOT_FOUND' => l10n.cloudAccessErrorAccountNotFound,
    'SHARE_LINK_UNAVAILABLE' => l10n.cloudAccessGuestUnavailable,
    'SHARE_LINK_NOT_YET_VALID' => l10n.cloudAccessGuestNotYetValid,
    'SHARE_LINK_EXPIRED' => l10n.cloudAccessGuestExpired,
    'SHARE_LINK_EXHAUSTED' => l10n.cloudAccessGuestExhausted,
    'SHARE_LINK_SUSPENDED' ||
    'SHARE_ACCESS_REVOKED' => l10n.cloudAccessGuestSuspended,
    'GUEST_SESSION_REQUIRED' ||
    'GUEST_SESSION_ENDED' => l10n.cloudAccessGuestSessionEnded,
    'SHARE_CONCURRENCY_LIMIT' => l10n.cloudAccessGuestBusy,
    'RATE_LIMITED' => l10n.cloudAccessErrorRateLimited,
    _ => l10n.cloudAccessErrorGeneric,
  };
}

/// Plain statement of the trusted-gateway model, shown wherever an owner
/// creates gateway access.
class CloudAccessTrustNotice extends StatelessWidget {
  const CloudAccessTrustNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.warningContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 18, color: palette.orange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.l10n.cloudAccessGatewayTrustNotice,
              style: TextStyle(
                color: palette.text,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CloudAccessSection extends StatelessWidget {
  const CloudAccessSection({
    required this.title,
    required this.children,
    this.trailing,
    super.key,
  });
  final String title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Wraps the action below the title when both do not fit (narrow
        // windows, longer translations) instead of overflowing.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        ...children,
      ],
    ),
  );
}

Future<bool> confirmCloudAction(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
  bool destructive = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cloudAccessCancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: context.palette.red)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return result == true;
}

String cloudAccessShortTime(BuildContext context, String? iso) {
  if (iso == null) return '—';
  final value = DateTime.tryParse(iso)?.toLocal();
  if (value == null) return '—';
  final material = MaterialLocalizations.of(context);
  final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(value));
  return '${material.formatShortDate(value)} $time';
}
