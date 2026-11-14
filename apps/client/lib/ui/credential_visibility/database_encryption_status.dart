// Instance-admin view of SQLCipher encryption at rest of the server database
// (`database_encryption` in GET /api/v1/admin/overview): a clear warning when
// the database is stored unencrypted, a quiet status when it is encrypted,
// and nothing for servers that do not report it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../app_theme.dart';

/// The offline command that encrypts an existing plaintext database. Not
/// localized: it is typed as is.
const databaseEncryptCommand =
    'atermius-server database-encrypt --server-stopped';

/// Where the procedure, the key backup and the limits are documented.
const databaseEncryptionRunbookPath = 'docs/runbooks/database-encryption.md';

/// What the admin UI shows for a `database_encryption` value.
enum DatabaseEncryptionNotice {
  /// `disabled`: the database is not encrypted at rest.
  warning,

  /// `enabled`.
  encrypted,

  /// Absent (older server) or unknown: nothing is shown.
  none,
}

DatabaseEncryptionNotice databaseEncryptionNoticeFor(String? value) =>
    switch (value) {
      'disabled' => DatabaseEncryptionNotice.warning,
      'enabled' => DatabaseEncryptionNotice.encrypted,
      _ => DatabaseEncryptionNotice.none,
    };

class DatabaseEncryptionStatus extends StatelessWidget {
  const DatabaseEncryptionStatus({required this.databaseEncryption, super.key});

  /// The overview's `database_encryption` value, or null when absent.
  final String? databaseEncryption;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    switch (databaseEncryptionNoticeFor(databaseEncryption)) {
      case DatabaseEncryptionNotice.none:
        return const SizedBox.shrink();
      case DatabaseEncryptionNotice.encrypted:
        return Padding(
          key: const ValueKey('database_encryption_enabled'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 15,
                color: context.palette.muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.cvDatabaseEncryptedAtRest,
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        );
      case DatabaseEncryptionNotice.warning:
        final color = context.palette.orange;
        final mono = TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: context.palette.text,
        );
        return Container(
          key: const ValueKey('database_encryption_disabled_warning'),
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: context.palette.warningContainer,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: .5)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_open_rounded, color: color, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.cvDatabaseNotEncryptedTitle,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.cvDatabaseNotEncryptedBody,
                      style: const TextStyle(fontSize: 12.5, height: 1.45),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            databaseEncryptCommand,
                            key: const ValueKey(
                              'database_encryption_encrypt_command',
                            ),
                            style: mono,
                          ),
                        ),
                        IconButton(
                          tooltip: l10n.copy,
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Clipboard.setData(
                            const ClipboardData(text: databaseEncryptCommand),
                          ),
                          icon: const Icon(Icons.copy_outlined, size: 16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      l10n.cvDatabaseEncryptionGuide(
                        databaseEncryptionRunbookPath,
                      ),
                      key: const ValueKey('database_encryption_runbook'),
                      style: TextStyle(
                        color: context.palette.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    }
  }
}
